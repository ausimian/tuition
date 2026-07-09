%%%-------------------------------------------------------------------
%%% @doc Application shell — hosts a set of panes under one navigable UI.
%%%
%%% This is the multi-pane host a BEAM TUI drops into: it hosts the panes it is
%%% handed (each implementing the {@link sonde_pane} behaviour), switches between
%%% them, and owns the shared render/input/resize/quit loop each pane used to
%%% carry its own copy of. It is deliberately ignorant of what the panes observe —
%%% the caller names the panes and their tab titles (the standalone Sonde tool
%%% hands it the observability panes through the {@link //sonde/sonde} façade).
%%% Where Phase 0 rendered a single "hello, world" pane (issue #8) and the Phase
%%% 0.5 demos each owned the whole screen with a duplicated loop, the shell owns
%%% that loop <em>once</em> and delegates the pane-specific work through the
%%% {@link sonde_pane} behaviour.
%%%
%%% == What the shell owns ==
%%% <ul>
%%%   <li><b>The loop</b> — open the terminal backend, paint the seed frame behind a
%%%       full-screen erase, then poll input each iteration, fold it, sample the
%%%       focused pane on the idle tick, and write the render diff; a resize resets
%%%       the diff baseline to blank behind a fresh erase. This is the exact shape
%%%       the panes and demos each duplicated, lifted here.</li>
%%%   <li><b>Chrome</b> — a nav/tab bar across the top (the hosted panes, the focused
%%%       one highlighted) and a status/help line across the bottom (the global
%%%       keys), laid out around the focused pane's rect. A single-pane shell (a demo
%%%       flag, or a pane run on its own) skips the nav bar — one tab is no choice.</li>
%%%   <li><b>Input routing</b> — the <em>global</em> keys (Tab/Shift-Tab to switch
%%%       panes, Ctrl-C to quit) are handled here and never reach a pane; everything
%%%       else is passed to the focused pane's {@link sonde_pane:apply_events/2}. The
%%%       global keys are ones no pane binds (Tab is never a printable character), so
%%%       even the process view's filter mode — which captures every printable key —
%%%       never has a pane switch stolen from it, nor eats one meant for the shell.
%%%       Quitting is split: Ctrl-C always quits at the shell; a plain `q' is
%%%       pane-local, so a pane can decline it (the process view types it into an
%%%       active filter instead of exiting).</li>
%%% </ul>
%%%
%%% == Sampling ==
%%% Only the focused pane samples, and only on the idle tick (the poll timed out
%%% with no input) — the same discipline the panes keep on their own: a keystroke
%%% repaints against the frozen snapshot so rows do not churn under navigation, and
%%% a hidden pane does no work for a screen nobody is watching. A pane switched back
%%% to shows its last sample until the next idle tick refreshes it (within the poll
%%% cadence).
%%%
%%% == Running it ==
%%% `sonde_shell:start(PaneSpecs)' hosts the given `{Module, Title}' panes and runs
%%% until the user quits. `start/2' takes an option map as a second argument:
%%% `active' selects the initial pane (an index, or a pane module), and `backend'
%%% selects the terminal backend (default {@link sonde_term_local}) with the whole
%%% map passed to its `open/1' — which is how the loop is driven headlessly in
%%% tests. A single-element pane list is how one pane (a demo flag, or
%%% `--processes') runs on its own through the same loop.
%%%
%%% == Determinism ==
%%% The pure pieces — {@link new/2}, {@link apply_events/2}, {@link build_frame/2},
%%% {@link sample/1}, and the {@link active/1} accessor — are exported so pane
%%% switching, key routing and resize can be asserted directly over the scripted
%%% backend, the way the pane loops are tested today.
%%%
%%% HARD CONSTRAINT (PRD §12): depends only on `kernel'/`stdlib'/`erts' plus the
%%% sibling render/layout/input/widget modules. The hosted panes are supplied by
%%% the caller as data, so the shell has no compile-time dependency on any
%%% particular pane. No third-party code.
%%% @end
%%%-------------------------------------------------------------------
-module(sonde_shell).

-include("sonde_layout.hrl").

-export([start/1, start/2]).
-export([new/1, new/2, apply_events/2, build_frame/2, sample/1, is_idle_tick/2]).
-export([active/1, active_module/1, active_state/1, pane_count/1]).

%% Idle poll cadence — matches the panes it hosts. On each idle tick the focused
%% pane re-samples and the frame repaints; a tick that finds nothing changed writes
%% nothing (the diff of an unchanged frame is empty).
-define(IDLE_TIMEOUT, 1000).

%% Full-screen erase ahead of a paint onto a fresh (blank) baseline — the first
%% frame and every post-resize repaint — so no stale cell survives underneath.
-define(ERASE, <<"\e[2J">>).

%% A palette shared with the panes so the chrome reads as one piece with them: an
%% accent used for the focused tab, a dim grey for inactive chrome text.
-define(ACCENT, 6).
-define(DIM, 8).

%% One hosted pane: the module implementing {@link sonde_pane}, the title shown on
%% its nav tab, and its current UI state (threaded across frames — the renderer is
%% immediate-mode, so a widget's selection/scroll lives here).
-record(pane, {
    module :: module(),
    title :: binary(),
    state :: sonde_pane:state()
}).

%% Shell state: the hosted panes in tab order and the index of the focused one.
-record(shell, {
    panes :: [#pane{}],
    active = 0 :: non_neg_integer()
}).

-type pane_spec() :: {module(), binary()}.
-type state() :: #shell{}.
%% An acquired pane resource, paired with its module for teardown: `none' for a
%% pane with no {@link sonde_pane:setup/0}, else the token that `setup/0' returned.
-type pane_resource() :: {module(), none | {ok, sonde_pane:resource()}}.
-export_type([pane_spec/0, state/0]).

%%% -- entry point -----------------------------------------------------

%% @doc Run the shell hosting `PaneSpecs' — a non-empty list of `{Module, Title}'
%% panes — focused on the first. Blocks until the user quits; returns `ok' once the
%% terminal is restored, or `{error, Reason}' if the backend could not be opened.
-spec start([pane_spec()]) -> ok | {error, term()}.
start(PaneSpecs) when is_list(PaneSpecs) -> start(PaneSpecs, #{}).

%% @doc As {@link start/1}, with options. `active' selects the initial pane (an
%% index, or a pane module matched against the list); `backend' selects the terminal
%% backend (default {@link sonde_term_local}), with the whole map passed to its
%% `open/1' — the hook the tests drive the loop through. A single-element pane list
%% is how one pane (a demo flag, or `--processes') runs on its own through the
%% shared loop; the shell then skips the nav bar.
%%
%% Enables each pane's optional {@link sonde_pane:setup/0} resource for the run and
%% releases it on teardown (see the module doc), guarded so both the resource and
%% the terminal are restored on a clean quit and a crash alike.
-spec start([pane_spec()], Opts :: map()) -> ok | {error, term()}.
start(PaneSpecs, Opts) when is_list(PaneSpecs), is_map(Opts) ->
    Backend = maps:get(backend, Opts, sonde_term_local),
    case sonde_term:open(Backend, Opts) of
        {ok, Handle} ->
            %% From here the terminal is open and hosted panes may hold node-global
            %% resources, so everything runs under nested guards entered before any
            %% resource is acquired: the inner one tears every acquired pane resource
            %% down, the outer one restores the terminal. A pane `setup/0' that
            %% raises, the run crashing, or a clean quit all unwind the same way —
            %% `setup_panes/1' cleans up its own partial acquisitions if it raises
            %% before returning (so the inner guard never sees a leak it can't name).
            try
                Resources = setup_panes(PaneSpecs),
                try
                    Active = resolve_active(maps:get(active, Opts, 0), PaneSpecs),
                    run(Handle, new(PaneSpecs, Active))
                after
                    teardown_panes(Resources)
                end
            after
                sonde_term:close(Handle)
            end;
        {error, _} = Error ->
            Error
    end.

%%% -- render/input loop -----------------------------------------------

%% Paint the seed frame onto a blank baseline behind a full-screen erase, then hand
%% off to the poll loop.
-spec run(sonde_term:handle(), state()) -> ok | {error, term()}.
run(Handle, Shell) ->
    case sonde_term:size(Handle) of
        {ok, Size} ->
            {Frame, Shell1} = build_frame(Size, Shell),
            Out = [?ERASE | sonde_render:diff(sonde_render:new(Size), Frame)],
            case sonde_term:write(Handle, Out) of
                ok -> loop(Handle, Frame, Size, sonde_input:new(), Shell1);
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

%% One iteration: poll input, route it (a global quit short-circuits before any
%% repaint), sample the focused pane on an idle tick only, then repaint the diff.
%% `Prev'/`PrevSize' are the baseline the next diff is measured against.
-spec loop(
    sonde_term:handle(), sonde_render:buffer(), sonde_term:size(), sonde_input:state(), state()
) ->
    ok | {error, term()}.
loop(Handle, Prev, PrevSize, InputSt, Shell) ->
    case sonde_input_driver:poll(Handle, InputSt, ?IDLE_TIMEOUT) of
        {ok, Events, InputSt1} ->
            case apply_events(Events, Shell) of
                quit ->
                    ok;
                {ok, Shell1} ->
                    Shell2 = maybe_sample(Events, InputSt1, Shell1),
                    case render(Handle, Prev, PrevSize, Shell2) of
                        {ok, Frame, Size, Shell3} ->
                            loop(Handle, Frame, Size, InputSt1, Shell3);
                        {error, _} = Error ->
                            Error
                    end
            end;
        {error, _} = Error ->
            Error
    end.

%% Sample the focused pane on a genuine idle tick, but not when the user pressed a
%% key — a keystroke repaints against the frozen snapshot so the pane stays still
%% under navigation and typing. The idle test is {@link is_idle_tick/2}: an empty
%% event list alone is not enough, because a multi-byte key mid-flight also produces
%% one (see there).
-spec maybe_sample([sonde_input:event()], sonde_input:state(), state()) -> state().
maybe_sample(Events, InputSt, Shell) ->
    case is_idle_tick(Events, InputSt) of
        true -> sample(Shell);
        false -> Shell
    end.

%% @doc Whether this poll was a genuine idle tick — the read timed out with no input
%% pending — as opposed to a keystroke, or one still arriving. The focused pane
%% samples off this so its snapshot only refreshes between the user's actions, never
%% during one.
%%
%% An empty event list is necessary but <em>not</em> sufficient. The local backend
%% reads one byte at a time, so a multi-byte key — an arrow's `ESC [ A', Home/End,
%% PgUp/PgDn — arrives across several reads, and every prefix byte parses to zero
%% events while {@link sonde_input} buffers the partial. Treating those empty polls
%% as idle ticks re-samples on each byte of a navigation key: it churns the frozen
%% snapshot the instant the key is pressed, and — because the byte reads land
%% microseconds apart — measures any per-tick delta over a near-zero window (which is
%% what made the process view's reduction rate flicker to zero or spike). {@link
%% sonde_input:pending/1} is true while any such partial is buffered, so a true idle
%% tick is "no events AND nothing pending". Exported so the predicate can be tested
%% directly.
-spec is_idle_tick([sonde_input:event()], sonde_input:state()) -> boolean().
is_idle_tick([], InputSt) -> not sonde_input:pending(InputSt);
is_idle_tick(_Events, _InputSt) -> false.

%% Re-query the current size and write the diff. A geometry change resets the
%% baseline to blank behind a full-screen erase so stale cells never linger;
%% otherwise it diffs against `Prev'. Returns the new frame, size and shell state
%% (the focused pane may have adjusted its scroll offset, which must persist).
-spec render(sonde_term:handle(), sonde_render:buffer(), sonde_term:size(), state()) ->
    {ok, sonde_render:buffer(), sonde_term:size(), state()} | {error, term()}.
render(Handle, Prev, PrevSize, Shell) ->
    case sonde_term:size(Handle) of
        {ok, Size} ->
            {Baseline, Lead} =
                case Size =:= PrevSize of
                    true -> {Prev, []};
                    false -> {sonde_render:new(Size), [?ERASE]}
                end,
            {Frame, Shell1} = build_frame(Size, Shell),
            case sonde_term:write(Handle, [Lead | sonde_render:diff(Baseline, Frame)]) of
                ok -> {ok, Frame, Size, Shell1};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

%%% -- input routing ---------------------------------------------------

%% @doc Fold input events into the shell in arrival order, short-circuiting to
%% `quit'. Each event is either a shell-global key handled here — Ctrl-C quits,
%% Tab/Shift-Tab switch the focused pane — or is passed to the focused pane's
%% {@link sonde_pane:apply_events/2}, which may itself return `quit'. Events are
%% routed one at a time so a switch mid-batch retargets the events after it.
-spec apply_events([sonde_input:event()], state()) -> {ok, state()} | quit.
apply_events([], Shell) ->
    {ok, Shell};
apply_events([Event | Rest], Shell) ->
    case route(Event, Shell) of
        quit -> quit;
        {ok, Shell1} -> apply_events(Rest, Shell1)
    end.

%% Dispatch one event: the global keys first (so a pane can never shadow them),
%% then the focused pane. Ctrl-C always quits at the shell level, even while a pane
%% is capturing text; Tab/Shift-Tab cycle the focus.
-spec route(sonde_input:event(), state()) -> {ok, state()} | quit.
route({key, {ctrl, $c}, _Mods}, _Shell) ->
    quit;
route({key, tab, Mods}, Shell) ->
    {ok, switch(Shell, tab_delta(Mods))};
route(Event, Shell) ->
    dispatch(Event, Shell).

%% Shift-Tab steps to the previous pane, plain Tab to the next.
-spec tab_delta([sonde_input:mod()]) -> -1 | 1.
tab_delta(Mods) ->
    case lists:member(shift, Mods) of
        true -> -1;
        false -> 1
    end.

%% Pass one pane-local event to the focused pane, folding the result back into the
%% shell or propagating its `quit'. The pane's `apply_events/2' takes a batch, so a
%% single event is wrapped as a one-element list.
-spec dispatch(sonde_input:event(), state()) -> {ok, state()} | quit.
dispatch(Event, Shell) ->
    #pane{module = Mod, state = St} = active_pane(Shell),
    case Mod:apply_events([Event], St) of
        quit -> quit;
        {ok, St1} -> {ok, set_active_state(Shell, St1)}
    end.

%% Move the focus by `Delta', wrapping around the ends (so Tab off the last pane
%% returns to the first). A single-pane shell has nowhere to go, so it stays put.
-spec switch(state(), integer()) -> state().
switch(#shell{panes = Panes, active = Active} = Shell, Delta) ->
    N = length(Panes),
    Shell#shell{active = ((Active + Delta) rem N + N) rem N}.

%%% -- sampling --------------------------------------------------------

%% @doc Refresh the focused pane from the running node (impure). Only the focused
%% pane samples; the others keep their last state until switched to. Exposed so a
%% test can drive the live path directly.
-spec sample(state()) -> state().
sample(Shell) ->
    #pane{module = Mod, state = St} = active_pane(Shell),
    set_active_state(Shell, Mod:sample(St)).

%%% -- frame building --------------------------------------------------

%% @doc Build the whole frame for the current size: the nav bar (when more than one
%% pane), the focused pane rendered into the body rect, and the status line, tiled
%% by the layout engine. Returns the buffer and the updated shell state — the
%% focused pane may have reconciled its scroll offset, which must persist to the
%% next frame.
-spec build_frame(sonde_term:size(), state()) -> {sonde_render:buffer(), state()}.
build_frame(Size, #shell{panes = Panes, active = Active} = Shell) ->
    Multi = length(Panes) > 1,
    {NavArea, BodyArea, StatusArea} = layout(sonde_layout:area(Size), Multi),
    Buf0 = sonde_render:new(Size),
    Buf1 = draw_nav(Buf0, NavArea, Panes, Active),
    {Buf2, Shell1} = render_active(BodyArea, Buf1, Shell),
    Buf3 = draw_status(Buf2, StatusArea, Multi),
    {Buf3, Shell1}.

%% Split the screen into the nav/body/status rects. A multi-pane shell reserves a
%% row top and bottom for the tab bar and status line; a single-pane shell drops
%% the tab bar (`NavArea' is a zero rect the nav draw ignores) and gives the pane
%% the extra row.
-spec layout(#rect{}, boolean()) -> {#rect{}, #rect{}, #rect{}}.
layout(Area, true) ->
    [Nav, Body, Status] = sonde_layout:split(
        vertical, [{fixed, 1}, fill, {fixed, 1}], Area
    ),
    {Nav, Body, Status};
layout(Area, false) ->
    [Body, Status] = sonde_layout:split(vertical, [fill, {fixed, 1}], Area),
    {#rect{}, Body, Status}.

%% Render the focused pane into the body rect, folding the state it returns (its
%% reconciled scroll offset) back into the shell.
-spec render_active(#rect{}, sonde_render:buffer(), state()) -> {sonde_render:buffer(), state()}.
render_active(BodyArea, Buf, Shell) ->
    #pane{module = Mod, state = St} = active_pane(Shell),
    {Buf1, St1} = Mod:render(BodyArea, Buf, St),
    {Buf1, set_active_state(Shell, St1)}.

%%% -- chrome ----------------------------------------------------------

%% Draw the nav bar: one tab per hosted pane, the focused one reversed in the
%% accent colour, the rest dim, laid left to right and clipped at the bar's right
%% edge. A degenerate rect (a single-pane shell, or no room) draws nothing.
-spec draw_nav(sonde_render:buffer(), #rect{}, [#pane{}], non_neg_integer()) ->
    sonde_render:buffer().
draw_nav(Buf, #rect{w = W, h = H}, _Panes, _Active) when W =< 0; H =< 0 ->
    Buf;
draw_nav(Buf, #rect{x = X, y = Y, w = W}, Panes, Active) ->
    draw_segments(Buf, X, Y, X + W, nav_segments(Panes, Active)).

%% The nav bar as a list of `{Text, Style}' segments: a leading pad, then each
%% pane's title as a `\s title\s' tab in its focused/unfocused style.
-spec nav_segments([#pane{}], non_neg_integer()) -> [{binary(), sonde_render:style()}].
nav_segments(Panes, Active) ->
    Indexed = lists:zip(lists:seq(0, length(Panes) - 1), Panes),
    [{<<" ">>, #{}} | [tab_segment(I, P, Active) || {I, P} <- Indexed]].

%% One tab segment: the title padded with a space each side, styled by whether it
%% is the focused pane (reversed accent, bold) or not (dim label).
-spec tab_segment(non_neg_integer(), #pane{}, non_neg_integer()) ->
    {binary(), sonde_render:style()}.
tab_segment(Index, #pane{title = Title}, Active) ->
    Text = <<" ", Title/binary, " ">>,
    Style =
        case Index =:= Active of
            true -> #{fg => 0, bg => ?ACCENT, bold => true};
            false -> #{fg => 7}
        end,
    {Text, Style}.

%% Draw a run of `{Text, Style}' segments left to right from `X' on row `Y',
%% stopping at `Right' (the region's right edge). Each segment is clipped to the
%% columns still available and the cursor advanced by what actually drew, so the
%% run never spills past the bar — the width-safe accounting the widget layer uses.
-spec draw_segments(
    sonde_render:buffer(), integer(), integer(), integer(), [{binary(), sonde_render:style()}]
) -> sonde_render:buffer().
draw_segments(Buf, _X, _Y, _Right, []) ->
    Buf;
draw_segments(Buf, X, _Y, Right, _Segs) when X >= Right ->
    Buf;
draw_segments(Buf, X, Y, Right, [{Text, Style} | Rest]) ->
    Clipped = sonde_widget:truncate(Text, Right - X),
    Buf1 = sonde_render:put_text(Buf, X, Y, Clipped, Style),
    draw_segments(Buf1, X + sonde_widget:display_width(Clipped), Y, Right, Rest).

%% Draw the status/help line: the shell-global keys, dim so it reads as chrome. The
%% pane-local keys are the pane's own help line's business, so this names only what
%% the shell owns — pane switching (when there is more than one) and the guaranteed
%% Ctrl-C quit. A degenerate rect draws nothing.
-spec draw_status(sonde_render:buffer(), #rect{}, boolean()) -> sonde_render:buffer().
draw_status(Buf, #rect{w = W, h = H}, _Multi) when W =< 0; H =< 0 ->
    Buf;
draw_status(Buf, #rect{x = X, y = Y, w = W}, Multi) ->
    Text = sonde_widget:truncate(status_text(Multi), W),
    sonde_render:put_text(Buf, X, Y, Text, #{fg => ?DIM}).

-spec status_text(boolean()) -> binary().
status_text(true) -> <<"tab/shift-tab switch pane    ctrl-c quit">>;
status_text(false) -> <<"ctrl-c quit">>.

%%% -- state -----------------------------------------------------------

%% @doc The shell's initial state over a pane list, focused on the first pane.
-spec new([pane_spec()]) -> state().
new(PaneSpecs) -> new(PaneSpecs, 0).

%% @doc As {@link new/1}, focused on pane `Active' (clamped into the list). Each
%% pane is seeded with its module's {@link sonde_pane:new/0}. Exported so pane
%% switching and routing can be driven purely, without a terminal.
-spec new([pane_spec()], non_neg_integer()) -> state().
new(PaneSpecs, Active) ->
    Panes = [#pane{module = M, title = T, state = M:new()} || {M, T} <- PaneSpecs],
    #shell{panes = Panes, active = clamp(Active, 0, length(Panes) - 1)}.

%% @doc The focused pane's index — exposed so a test can assert how a switch moved
%% the focus.
-spec active(state()) -> non_neg_integer().
active(#shell{active = Active}) -> Active.

%% @doc The focused pane's module.
-spec active_module(state()) -> module().
active_module(Shell) -> (active_pane(Shell))#pane.module.

%% @doc The focused pane's UI state — exposed so a test can assert that a pane-local
%% key reached the focused pane (e.g. moved its selection).
-spec active_state(state()) -> sonde_pane:state().
active_state(Shell) -> (active_pane(Shell))#pane.state.

%% @doc How many panes the shell hosts.
-spec pane_count(state()) -> non_neg_integer().
pane_count(#shell{panes = Panes}) -> length(Panes).

-spec active_pane(state()) -> #pane{}.
active_pane(#shell{panes = Panes, active = Active}) -> lists:nth(Active + 1, Panes).

%% Replace the focused pane's state, leaving the others and the focus untouched.
-spec set_active_state(state(), sonde_pane:state()) -> state().
set_active_state(#shell{panes = Panes, active = Active} = Shell, St) ->
    Pane = lists:nth(Active + 1, Panes),
    Shell#shell{panes = set_nth(Active + 1, Panes, Pane#pane{state = St})}.

-spec set_nth(pos_integer(), [T], T) -> [T].
set_nth(1, [_ | T], V) -> [V | T];
set_nth(N, [H | T], V) -> [H | set_nth(N - 1, T, V)].

-spec clamp(integer(), integer(), integer()) -> integer().
clamp(V, Lo, Hi) -> max(Lo, min(Hi, V)).

%%% -- panes -----------------------------------------------------------

%% Resolve the `active' option to a pane index: an integer is taken as-is (clamped
%% by {@link new/2}); a module is matched against the pane list (falling back to the
%% first pane when it is not hosted), so a caller can say "focus the process view"
%% without knowing its position.
-spec resolve_active(non_neg_integer() | module(), [pane_spec()]) -> non_neg_integer().
resolve_active(Index, _PaneSpecs) when is_integer(Index) ->
    Index;
resolve_active(Module, PaneSpecs) when is_atom(Module) ->
    module_index(Module, PaneSpecs, 0).

-spec module_index(module(), [pane_spec()], non_neg_integer()) -> non_neg_integer().
module_index(Module, [{Module, _Title} | _Rest], Index) -> Index;
module_index(Module, [_Other | Rest], Index) -> module_index(Module, Rest, Index + 1);
module_index(_Module, [], _Index) -> 0.

%% Enable each pane's optional {@link sonde_pane:setup/0} resource left to right,
%% pairing each with its module for teardown; a pane without a `setup/0' contributes
%% `none'. Crash-safe: if a pane's `setup/0' raises, the resources already acquired
%% are torn down (newest first) before the error propagates, so a partial setup
%% leaks nothing — the same guarantee a clean teardown gives. Returns the resources
%% in acquisition order; {@link teardown_panes/1} unwinds them in reverse.
-spec setup_panes([pane_spec()]) -> [pane_resource()].
setup_panes(PaneSpecs) ->
    setup_panes(PaneSpecs, []).

%% `Acquired' holds the resources newest-first — already the order to unwind them
%% in should the next pane's `setup/0' raise.
-spec setup_panes([pane_spec()], [pane_resource()]) -> [pane_resource()].
setup_panes([], Acquired) ->
    lists:reverse(Acquired);
setup_panes([{Module, _Title} | Rest], Acquired) ->
    Resource =
        try
            setup_pane(Module)
        catch
            Class:Reason:Stack ->
                teardown_each(Acquired),
                erlang:raise(Class, Reason, Stack)
        end,
    setup_panes(Rest, [{Module, Resource} | Acquired]).

-spec setup_pane(module()) -> none | {ok, sonde_pane:resource()}.
setup_pane(Module) ->
    _ = code:ensure_loaded(Module),
    case erlang:function_exported(Module, setup, 0) of
        true -> {ok, Module:setup()};
        false -> none
    end.

%% Release every acquired resource, unwinding in reverse acquisition order — the
%% conventional stack discipline for nested resources, so a pane is torn down before
%% anything it was set up on top of. (Shared node-global resources like the
%% `scheduler_wall_time' flag are now ref-counted by their owner, so their final state
%% no longer depends on this order; reverse order remains the right default for
%% resources that genuinely nest.) Guarded by the caller's `after', so this runs on a
%% clean quit and a crash alike.
-spec teardown_panes([pane_resource()]) -> ok.
teardown_panes(Resources) ->
    teardown_each(lists:reverse(Resources)).

%% Tear down a list of acquired resources in the order given.
-spec teardown_each([pane_resource()]) -> ok.
teardown_each(Resources) ->
    lists:foreach(fun teardown_pane/1, Resources).

-spec teardown_pane(pane_resource()) -> ok.
teardown_pane({_Module, none}) ->
    ok;
teardown_pane({Module, {ok, Token}}) ->
    case erlang:function_exported(Module, teardown, 1) of
        true ->
            _ = Module:teardown(Token),
            ok;
        false ->
            ok
    end.
