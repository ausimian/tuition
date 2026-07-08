%%% Shared logic for the shell's test stub panes ({@link sonde_shell_pane_a} /
%%% {@link sonde_shell_pane_b}). Not a pane itself — the two thin pane modules
%%% delegate here, differing only in the `tag' their `new/0' seeds, which is drawn
%%% into the body so a test can tell which pane the shell painted.
%%%
%%% The stub mimics just enough of a real pane to exercise the generic shell
%%% without depending on any observation pane: a selection moved by Down/`j'
%%% (Up/`k' back), a filter mode entered by `/' that captures printable keys
%%% (including `q') and renders `filter: <text>', a plain `q' that quits in normal
%%% mode, and a `sample/1' that populates a row so a test can see the focused pane
%%% refresh.
-module(sonde_shell_stub_pane).

-include("sonde_layout.hrl").

-export([new/1, apply_events/2, render/3, sample/1, selection/1, rows/1]).

-record(st, {
    tag :: binary(),
    sel = 0 :: non_neg_integer(),
    mode = normal :: normal | filter,
    filter = <<>> :: binary(),
    rows = [] :: [term()]
}).

new(Tag) -> #st{tag = Tag}.

selection(#st{sel = Sel}) -> Sel.
rows(#st{rows = Rows}) -> Rows.

%% Sampling populates a row, so a test can see the focused pane refresh from the
%% live path (the stub has no live source, so it fabricates one).
sample(St) -> St#st{rows = [row]}.

apply_events([], St) ->
    {ok, St};
apply_events([Event | Rest], St) ->
    case event(Event, St) of
        quit -> quit;
        {ok, St1} -> apply_events(Rest, St1)
    end.

%% Normal mode: `q' quits (the shell honours a pane-declared quit), `/' opens the
%% filter, Down/`j' and Up/`k' move the selection. Filter mode: printable keys
%% (including `q') are captured as text, Esc leaves. Everything else is a no-op.
event({key, {char, $q}, []}, #st{mode = normal}) ->
    quit;
event({key, {char, $/}, []}, #st{mode = normal} = St) ->
    {ok, St#st{mode = filter}};
event({key, down, _}, #st{mode = normal} = St) ->
    {ok, St#st{sel = St#st.sel + 1}};
event({key, {char, $j}, []}, #st{mode = normal} = St) ->
    {ok, St#st{sel = St#st.sel + 1}};
event({key, up, _}, #st{mode = normal} = St) ->
    {ok, St#st{sel = max(0, St#st.sel - 1)}};
event({key, {char, $k}, []}, #st{mode = normal} = St) ->
    {ok, St#st{sel = max(0, St#st.sel - 1)}};
event({key, esc, _}, #st{mode = filter} = St) ->
    {ok, St#st{mode = normal, filter = <<>>}};
event({key, {char, C}, []}, #st{mode = filter} = St) ->
    {ok, St#st{filter = <<(St#st.filter)/binary, C>>}};
event(_Other, St) ->
    {ok, St}.

%% Draw the tagged body at the pane origin, plus the filter line just below when
%% filtering. A degenerate rect draws nothing (matches the real panes' guards).
render(#rect{w = W, h = H}, Buf, St) when W =< 0; H =< 0 ->
    {Buf, St};
render(#rect{x = X, y = Y, h = H}, Buf, #st{tag = Tag, mode = Mode, filter = Filter} = St) ->
    %% A non-default style so the space in the text differs from the blank
    %% baseline and survives the render diff (an all-default run would have its
    %% interior spaces diffed away, leaving the words non-adjacent in the output).
    Style = #{fg => 7},
    Buf1 = sonde_render:put_text(Buf, X, Y, <<Tag/binary, " body">>, Style),
    Buf2 =
        case Mode =:= filter andalso H > 1 of
            true -> sonde_render:put_text(Buf1, X, Y + 1, <<"filter: ", Filter/binary>>, Style);
            false -> Buf1
        end,
    {Buf2, St}.
