-module(tuition_demo).
-moduledoc """
"Hello, world" reference loop — the framework's smallest end-to-end
example, and the living exercise of the capability probe.

This is the minimal immediate-mode loop a `tuition` consumer starts from: it
opens a pluggable `m:tuition_term` backend, probes its capabilities, and
paints a single "hello, world" pane, folding input and resize into the frame
each iteration. It began as the first end-to-end example;
after the framework was split out it stays here as the reference demo and the
only place the caps-probe integration is exercised end-to-end. The full app
shell (`m:tuition_shell`) supersedes it as the product entry point.

## The render/input loop

`start/1` opens a terminal backend, probes its capabilities
(`m:tuition_caps`), paints a "hello, world" pane laid out by
`m:tuition_layout`, then runs an immediate-mode loop: each iteration polls
input through `m:tuition_input_driver`, folds the decoded events (keys,
mouse, paste) plus any terminal resize into the UI state, rebuilds the frame
with `m:tuition_render` and writes only the diff. It quits on `q` (or
Ctrl-C) and always restores the terminal via `tuition_term:close/1` — on a
clean quit or a read/write error alike — so the shell is left pristine.

The probe runs once, right after the backend opens and before the first
frame, reading its replies off the same input channel the loop later uses.
Its result drives real output here: the pane is drawn in 24-bit colour on a
truecolor terminal and falls back to a 256-colour approximation otherwise,
and the status line names the enrichments the terminal reported. Because the
probe shares the input channel, any non-reply bytes it reads (a key pressed
during the probe window) are preserved and replayed as the loop's first input
rather than lost — so, e.g., a quick `q` against a silent terminal still quits.
""".

-include("tuition_layout.hrl").
-include("tuition_caps.hrl").

-export([start/0, start/1]).

%% How long a quiet input poll waits before looping to re-check the terminal
%% size (resize is polled here, not signal-driven). This is only a
%% liveness cadence: an idle poll that finds nothing changed writes nothing,
%% because the diff of an unchanged frame is empty.
-define(IDLE_TIMEOUT, 1000).

%% Full-screen erase, emitted ahead of a paint onto a fresh (blank) baseline —
%% the first frame and every post-resize repaint — so no stale cell from a prior
%% geometry can survive underneath the newly drawn frame.
-define(ERASE, <<"\e[2J">>).

%% A loop-level event: either a decoded input event from the byte parser, or a
%% terminal resize the loop synthesises when the polled size changes. Resize does
%% not arrive through the byte stream, so it is folded in here rather
%% than in {@link tuition_input}.
-type ui_event() :: tuition_input:event() | {resize, tuition_term:size()}.

%% Minimal UI state: the terminal capabilities probed at startup (which
%% style the frame) and the most recent event — key, mouse, paste or resize —
%% echoed into the status line so the input -> parse -> render pipeline is visibly
%% end-to-end. Later phases replace `last' with real view state; `caps' stays.
-record(ui, {
    caps = #caps{} :: tuition_caps:caps(),
    last = none :: none | ui_event()
}).

-doc """
Start the demo against the local node, using the default local
terminal backend. Blocks until the user quits; returns `ok` once the terminal
has been restored, or `{error, Reason}` if the backend could not be opened
(e.g. no controlling tty, or its geometry could not be read). A live
`erl`/`iex` shell that already owns the tty is *not* a failure: the
local backend borrows it through the current shell group in cooperative
submode (see `m:tuition_term_local`).
""".
-spec start() -> ok | {error, term()}.
start() -> start(#{}).

-doc """
As `start/0`, with options. `backend` selects the terminal backend
module (default `m:tuition_term_local`); the whole `Opts` map is passed
through to the backend's `open/1`, so a backend reads its own keys from it.
Selecting a backend this way is also how the loop is driven in tests.

Capability detection can be steered for a backend that cannot answer the
interactive probe — an asynchronous or high-latency transport where the query
round-trip overruns the read window: `probe => false` skips the
probe for the `tuition_caps:baseline/0` set, and `caps => Caps` supplies a
fixed `t:tuition_caps:caps/0` profile verbatim. Either way no terminal
queries are written, so no stray reply can leak into input; the default (neither
key) still probes. See `tuition_caps:resolve/2`.
""".
-spec start(Opts :: map()) -> ok | {error, term()}.
start(Opts) ->
    Backend = maps:get(backend, Opts, tuition_term_local),
    case tuition_term:open(Backend, Opts) of
        {ok, Handle} ->
            try
                run(Handle, Opts)
            after
                tuition_term:close(Handle)
            end;
        {error, _} = Error ->
            Error
    end.

%%% -- render/input loop -----------------------------------------------

%% Resolve capabilities (probing unless the host opted out via `Opts'), then paint
%% the first frame and hand off to the poll loop. When probing, the replies are read
%% off the input channel before the loop starts, so there is no contention, and any
%% non-reply bytes read back (a key pressed during the probe window) are decoded up
%% front and replayed as the loop's first input batch, seeding its parser state, so
%% an early keystroke is honoured rather than lost. A host that supplied fixed caps
%% (or `probe => false') writes no queries, so there is no residue to replay. The
%% first frame is drawn onto a blank baseline behind a full-screen erase, so every
%% non-blank cell of the pane lands on a guaranteed-clean alternate screen.
-spec run(tuition_term:handle(), map()) -> ok | {error, term()}.
run(Handle, Opts) ->
    {Caps, Residue} = probe_caps(Handle, Opts),
    {Events0, InputSt0} = tuition_input:parse(Residue, tuition_input:new()),
    Ui = #ui{caps = Caps},
    case tuition_term:size(Handle) of
        {ok, Size} ->
            Frame = build_frame(Size, Ui),
            Out = [?ERASE | tuition_render:diff(tuition_render:new(Size), Frame)],
            case tuition_term:write(Handle, Out) of
                ok -> resume(Handle, Frame, Size, InputSt0, Ui, Events0);
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

%% Apply any input recovered from the probe window as the first batch — so a key
%% pressed before the probe finished is honoured, not lost — then enter the poll
%% loop. With no recovered input (the common case) `Events' is empty and this is
%% a straight hand-off after an empty repaint.
-spec resume(
    tuition_term:handle(),
    tuition_render:buffer(),
    tuition_term:size(),
    tuition_input:state(),
    #ui{},
    [tuition_input:event()]
) -> ok | {error, term()}.
resume(Handle, Prev, Size, InputSt, Ui, Events) ->
    case apply_events(Events, Ui) of
        quit ->
            ok;
        {ok, Ui1} ->
            case render(Handle, Prev, Size, Size, Ui1) of
                {ok, Prev1} -> loop(Handle, Prev1, Size, InputSt, Ui1);
                {error, _} = Error -> Error
            end
    end.

%% Resolve the capabilities for this run from `Opts' (see {@link
%% tuition_caps:resolve/2}), then, on a probed or baseline result, fold in the
%% `COLORTERM' environment hint: some terminals advertise 24-bit colour through that
%% variable but do not answer the DECRQSS truecolor probe. The reply-based probe
%% stays a pure function of the terminal ({@link tuition_caps:probe/1}); reading the
%% environment is the host's job, so it happens here rather than inside the probe.
%% A caller-supplied `caps' profile is used verbatim — no probe and no `COLORTERM'
%% fold, since the host's environment describes the host process, not the (possibly
%% remote) terminal the caps were handed for. Returns `{Caps, Residue}': any
%% non-reply bytes a probe read (a key pressed during the probe window) are passed
%% back so {@link run/2} can replay them instead of dropping the keystroke; a skipped
%% probe leaves the residue empty.
-spec probe_caps(tuition_term:handle(), map()) -> {tuition_caps:caps(), binary()}.
probe_caps(_Handle, #{caps := Caps}) ->
    {Caps, <<>>};
probe_caps(Handle, Opts) ->
    {Caps, Residue} = tuition_caps:resolve(Handle, Opts),
    {tuition_caps:apply_colorterm(os:getenv("COLORTERM"), Caps), Residue}.

%% One iteration: poll input, re-query the terminal size (cheap, and the only
%% resize signal), fold both the decoded events and any synthesised
%% resize event into the UI state, then repaint the diff. `Prev'/`PrevSize' are
%% the baseline the next diff is measured against; `InputSt' carries any partial
%% escape/UTF-8/paste sequence across reads.
-spec loop(
    tuition_term:handle(),
    tuition_render:buffer(),
    tuition_term:size(),
    tuition_input:state(),
    #ui{}
) -> ok | {error, term()}.
loop(Handle, Prev, PrevSize, InputSt, Ui) ->
    case tuition_input_driver:poll(Handle, InputSt, ?IDLE_TIMEOUT) of
        {ok, Events, InputSt1} ->
            case tuition_term:size(Handle) of
                {ok, Size} ->
                    AllEvents = Events ++ resize_events(PrevSize, Size),
                    case apply_events(AllEvents, Ui) of
                        quit ->
                            ok;
                        {ok, Ui1} ->
                            case render(Handle, Prev, PrevSize, Size, Ui1) of
                                {ok, Prev1} -> loop(Handle, Prev1, Size, InputSt1, Ui1);
                                {error, _} = Error -> Error
                            end
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

%% Synthesise a resize event when the polled size differs from the previous
%% iteration's — a structured `{resize, Size}' the loop consumes like any other
%% event. No change yields no event, so a steady terminal is silent.
-spec resize_events(tuition_term:size(), tuition_term:size()) -> [ui_event()].
resize_events(Size, Size) -> [];
resize_events(_PrevSize, Size) -> [{resize, Size}].

%% Repaint for the known current `Size': rebuild the frame and write the diff
%% against the baseline. When the geometry changed (`Size' =/= `PrevSize') the
%% baseline is reset to blank behind a full-screen erase, so stale cells from the
%% old geometry never linger; otherwise it diffs against `Prev'. An unchanged
%% frame writes nothing.
-spec render(
    tuition_term:handle(), tuition_render:buffer(), tuition_term:size(), tuition_term:size(), #ui{}
) ->
    {ok, tuition_render:buffer()} | {error, term()}.
render(Handle, Prev, PrevSize, Size, Ui) ->
    {Baseline, Lead} =
        case Size =:= PrevSize of
            true -> {Prev, []};
            false -> {tuition_render:new(Size), [?ERASE]}
        end,
    Frame = build_frame(Size, Ui),
    case tuition_term:write(Handle, [Lead | tuition_render:diff(Baseline, Frame)]) of
        ok -> {ok, Frame};
        {error, _} = Error -> Error
    end.

%% Fold events into the UI state in arrival order, short-circuiting to `quit' the
%% moment a quit key (unmodified `q', or Ctrl-C) is seen. Every other event — key,
%% mouse, paste or resize — just becomes the "last" the status line echoes.
-spec apply_events([ui_event()], #ui{}) -> {ok, #ui{}} | quit.
apply_events([], Ui) ->
    {ok, Ui};
apply_events([Event | Rest], Ui) ->
    case is_quit(Event) of
        true -> quit;
        false -> apply_events(Rest, Ui#ui{last = Event})
    end.

%% Ctrl-C quits too: in raw mode it arrives as a key event (byte 0x03), not a
%% signal, so without this a user's reflex to bail would do nothing. Mouse, paste
%% and resize events never quit.
-spec is_quit(ui_event()) -> boolean().
is_quit({key, {char, $q}, []}) -> true;
is_quit({key, {ctrl, $c}, _Mods}) -> true;
is_quit(_Event) -> false.

%%% -- frame building --------------------------------------------------

%% Build the whole frame for the current size: a centred "hello, world" body
%% pane above a one-row status line, tiled by the layout engine. Both panes are
%% styled from the probed capabilities.
-spec build_frame(tuition_term:size(), #ui{}) -> tuition_render:buffer().
build_frame(Size, #ui{caps = Caps, last = Last}) ->
    [Body, Status] = tuition_layout:split(vertical, [fill, {fixed, 1}], tuition_layout:area(Size)),
    Buf0 = tuition_render:new(Size),
    Buf1 = draw_hello(Buf0, Body, Caps),
    draw_status(Buf1, Status, Caps, Last).

%% Centre "hello, world" (bold) within the body rect, coloured from the probed
%% capabilities (see hello_style/1). The text is ASCII, so its column width equals
%% its length; centring clamps at the left edge for a narrow pane, and put_text
%% clips anything past the right edge. An empty pane (no rows or columns — e.g.
%% the body rect on a one-row terminal, where the status line takes the only row)
%% draws nothing, so the body never bleeds onto the row the layout reserved for
%% something else.
-spec draw_hello(tuition_render:buffer(), #rect{}, tuition_caps:caps()) -> tuition_render:buffer().
draw_hello(Buf, #rect{w = W, h = H}, _Caps) when W =< 0; H =< 0 ->
    Buf;
draw_hello(Buf, #rect{x = X, y = Y, w = W, h = H}, Caps) ->
    Text = "hello, world",
    Cx = X + max(0, (W - length(Text)) div 2),
    Cy = Y + H div 2,
    tuition_render:put_text(Buf, Cx, Cy, Text, hello_style(Caps)).

%% Pick the hello pane's style from the capabilities: a truecolor terminal gets a
%% 24-bit RGB foreground, everything else a 256-colour approximation of the same
%% hue. This is the visible proof that capability probing drives real output.
-spec hello_style(tuition_caps:caps()) -> tuition_render:style().
hello_style(#caps{truecolor = true}) -> #{bold => true, fg => {rgb, 64, 224, 208}};
hello_style(#caps{truecolor = false}) -> #{bold => true, fg => 6}.

%% Draw the status line at the pane's origin: the quit hint, the capabilities the
%% probe reported, and the last key pressed, in a dim colour so it reads as chrome
%% rather than content. Skips an empty rect for the same reason as draw_hello, so
%% a degenerate layout can't clobber a neighbouring pane.
-spec draw_status(
    tuition_render:buffer(), #rect{}, tuition_caps:caps(), none | tuition_input:event()
) ->
    tuition_render:buffer().
draw_status(Buf, #rect{w = W, h = H}, _Caps, _Last) when W =< 0; H =< 0 ->
    Buf;
draw_status(Buf, #rect{x = X, y = Y}, Caps, Last) ->
    Text = ["press q to quit    caps: ", caps_tags(Caps), "    last: ", describe(Last)],
    tuition_render:put_text(Buf, X, Y, Text, #{fg => 8}).

%% A space-separated list of the enrichments the probe turned on, or "baseline"
%% when it found none — so the running app visibly reports what the terminal
%% supports.
-spec caps_tags(tuition_caps:caps()) -> string().
caps_tags(#caps{
    truecolor = Tc,
    sync_output = Sy,
    bracketed_paste = Bp,
    sgr_mouse = Sm,
    kitty_keyboard = Kk
}) ->
    Tags = [
        Tag
     || {true, Tag} <- [
            {Tc, "truecolor"},
            {Sy, "sync"},
            {Bp, "paste"},
            {Sm, "mouse"},
            {Kk, "kitty"}
        ]
    ],
    case Tags of
        [] -> "baseline";
        _ -> lists:flatten(lists:join(" ", Tags))
    end.

%% A short human label for the last event, for the status line. Modifiers become
%% a prefix (`C-', `A-', ...); a control chord already implies Ctrl, so it is
%% rendered from its base letter alone. Mouse reports show action/button and the
%% 1-based cell, a paste its byte count, a resize the new geometry.
-spec describe(none | ui_event()) -> string().
describe(none) ->
    "(none)";
describe({key, {char, C}, Mods}) ->
    mods(Mods) ++ [C];
describe({key, {ctrl, C}, _Mods}) ->
    "C-" ++ [upper(C)];
describe({key, {f, N}, Mods}) ->
    mods(Mods) ++ [$F | integer_to_list(N)];
describe({key, Named, Mods}) when is_atom(Named) -> mods(Mods) ++ atom_to_list(Named);
describe({mouse, Action, Button, {Col, Row}, Mods}) ->
    mods(Mods) ++ atom_to_list(Action) ++ "-" ++ button_label(Button) ++
        "@" ++ integer_to_list(Col) ++ "," ++ integer_to_list(Row);
describe({paste, Bytes}) ->
    "paste(" ++ integer_to_list(byte_size(Bytes)) ++ "B)";
describe({resize, {Cols, Rows}}) ->
    "resize " ++ integer_to_list(Cols) ++ "x" ++ integer_to_list(Rows).

-spec button_label(tuition_input:mouse_button()) -> string().
button_label({button, N}) -> "btn" ++ integer_to_list(N);
button_label(Button) when is_atom(Button) -> atom_to_list(Button).

-spec mods([tuition_input:mod()]) -> string().
mods(Mods) -> lists:append([mod_prefix(M) || M <- Mods]).

-spec mod_prefix(tuition_input:mod()) -> string().
mod_prefix(shift) -> "S-";
mod_prefix(alt) -> "A-";
mod_prefix(ctrl) -> "C-";
mod_prefix(meta) -> "M-".

-spec upper(char()) -> char().
upper(C) when C >= $a, C =< $z -> C - 32;
upper(C) -> C.
