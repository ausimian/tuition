-module(tuition_demo_tests).

-include_lib("eunit/include/eunit.hrl").

%% Full-screen erase the loop emits ahead of a fresh-baseline paint (matches
%% tuition_demo's own ?ERASE).
-define(ERASE, <<"\e[2J">>).

%% The terminal seam dispatches through a {Backend, State} handle. In a
%% headless test environment there is no controlling tty, so the local backend
%% cannot enter raw mode and open/2 surfaces a clean error tuple ({error,
%% enotsup} with no tty, or {error, shell_active} if a shell already owns it)
%% rather than crashing or leaking a raw terminal.
term_seam_dispatch_test() ->
    ?assertMatch({error, _}, tuition_term:open(tuition_term_local, #{})).

%% A backend that cannot be opened propagates its error straight out of start/1,
%% which never enters the loop. This is the path the escript hits with no
%% controlling tty; here a fake backend makes it deterministic.
start_open_error_propagates_test() ->
    ?assertEqual(
        {error, no_tty},
        tuition_demo:start(#{backend => tuition_loop_term, open => {error, no_tty}})
    ).

%% End-to-end Phase 0 exit path over a scripted fake backend: the loop paints a
%% "hello, world" pane and a status line, then quits cleanly on `q', restoring
%% the terminal (close/1). Asserts on the bytes the loop actually wrote.
loop_renders_hello_and_quits_on_q_test() ->
    {Frames, Closed} = run_loop([{ok, <<"q">>}], {24, 6}),
    ?assert(Closed),
    ?assertMatch({_, _}, binary:match(Frames, <<"hello, world">>)),
    ?assertMatch({_, _}, binary:match(Frames, <<"press q to quit">>)).

%% Ctrl-C (byte 0x03) is the other quit key, so a user's reflex to bail always
%% works even though raw mode delivers it as a keypress, not a signal.
loop_quits_on_ctrl_c_test() ->
    {_Frames, Closed} = run_loop([{ok, <<3>>}], {24, 6}),
    ?assert(Closed).

%% A non-quit key flows through the parser and is echoed into the status line's
%% "last:" field before the next key quits: the first frame shows "(none)", and
%% the repaint after `z' emits that glyph. Proves input -> parse -> render works.
loop_echoes_last_key_test() ->
    %% Wide enough for the whole status line — "press q to quit  caps: …  last:
    %% (none)" — to render un-clipped, so the "(none)" baseline is present verbatim.
    {Frames, Closed} = run_loop([{ok, <<"z">>}, {ok, <<"q">>}], {60, 6}),
    ?assert(Closed),
    ?assertMatch({_, _}, binary:match(Frames, <<"(none)">>)),
    %% 'z' appears in no static text (hello, world / the quit hint / "(none)"),
    %% so finding it proves the keypress was rendered.
    ?assertMatch({_, _}, binary:match(Frames, <<"z">>)).

%% On a one-row terminal the layout gives the body pane zero rows and the status
%% line the only row, so the body must draw nothing rather than paint "hello,
%% world" over the reserved status row. The frame therefore carries the status
%% hint but never the body text.
loop_reserves_status_row_on_one_row_terminal_test() ->
    {Frames, Closed} = run_loop([{ok, <<"q">>}], {24, 1}),
    ?assert(Closed),
    ?assertMatch({_, _}, binary:match(Frames, <<"press q to quit">>)),
    ?assertEqual(nomatch, binary:match(Frames, <<"hello, world">>)).

%% The startup capability probe drives real output: when the terminal reports
%% truecolor + synchronized output, the status line names those caps and the
%% hello pane is painted in a 24-bit RGB foreground. The probe reply is delivered
%% ahead of the input keys (the probe consumes it before the loop reads).
loop_renders_probed_caps_test() ->
    ProbeReply = <<
        %% DECRQSS read-back echoing the probe's RGB -> truecolor.
        "\eP1$r0;38;2;1;2;3m\e\\",
        %% DECRQM ?2026 recognised (value 2) -> synchronized output.
        "\e[?2026;2$y",
        %% DA1 sentinel ends the probe.
        "\e[?62;c"
    >>,
    {Frames, Closed} = run_loop(ProbeReply, [{ok, <<"q">>}], {60, 6}),
    ?assert(Closed),
    ?assertMatch({_, _}, binary:match(Frames, <<"truecolor">>)),
    ?assertMatch({_, _}, binary:match(Frames, <<"sync">>)),
    %% The hello pane's 24-bit RGB foreground SGR (the turquoise fg), which only a
    %% truecolor result selects. Uses the full triple so it can't match the
    %% probe's own `38;2;1;2;3' query bytes that the backend also recorded.
    ?assertMatch({_, _}, binary:match(Frames, <<"38;2;64;224;208">>)).

%% A key pressed during the probe window is honoured, not lost. Here `q' is the
%% only thing a silent terminal delivers: the probe reads it, never sees a DA1
%% sentinel, times out, and hands `q' back as residue — which the loop replays as
%% its first input and quits on. Without that recovery the `q' would be dropped
%% and the loop would spin waiting for another key (the script has none), so
%% reaching a clean close is the proof it was preserved.
loop_recovers_key_pressed_during_probe_test() ->
    {_Frames, Closed} = run_loop(<<"q">>, [], {24, 6}),
    ?assert(Closed).

%% The same recovery when the keystroke trails a completed probe: the terminal
%% answers the DA1 sentinel (ending the read promptly) with `q' queued right
%% behind it. `q' is residue, replayed, and quits — no scripted key needed.
loop_recovers_key_after_sentinel_test() ->
    {_Frames, Closed} = run_loop(<<"\e[?62;c", "q">>, [], {24, 6}),
    ?assert(Closed).

%% A decoded mouse report flows through the loop into the status line's "last:"
%% field (echoed from the "(none)" baseline, so the whole label is repainted).
loop_echoes_mouse_event_test() ->
    Probe = <<"\e[?1006;1$y", "\e[?62;c">>,
    %% Left-button press at column 3, row 4, then quit.
    {Frames, Closed} = run_loop(Probe, [{ok, <<"\e[<0;3;4M">>}, {ok, <<"q">>}], {80, 6}),
    ?assert(Closed),
    ?assertMatch({_, _}, binary:match(Frames, <<"press-left@3,4">>)).

%% A bracketed paste flows through as one event, echoed by its byte count.
loop_echoes_paste_event_test() ->
    Probe = <<"\e[?2004;1$y", "\e[?62;c">>,
    %% An up-arrow first, so the "last:" field holds a value ("up") that shares no
    %% cells with the paste label; the cell-level diff then repaints "paste(2B)"
    %% whole instead of skipping a coincidentally-identical glyph.
    Script = [{ok, <<"\e[A">>}, {ok, <<"\e[200~hi\e[201~">>}, {ok, <<"q">>}],
    {Frames, Closed} = run_loop(Probe, Script, {80, 6}),
    ?assert(Closed),
    ?assertMatch({_, _}, binary:match(Frames, <<"paste(2B)">>)).

%% A terminal size change between polls surfaces as a `{resize, _}' event the
%% loop consumes: the status line echoes the new geometry and the frame is
%% repainted onto a freshly-erased baseline (a second full-screen erase). The
%% fake backend hands back {80,6} on the first size query, then {80,8}.
loop_surfaces_resize_event_test() ->
    %% `z' is a harmless non-quit key on the iteration where the resize lands, so
    %% the resize is applied and rendered before the following `q' quits.
    {Frames, Closed} = run_loop([{ok, <<"z">>}, {ok, <<"q">>}], [{80, 6}, {80, 8}]),
    ?assert(Closed),
    ?assertMatch({_, _}, binary:match(Frames, <<"resize 80x8">>)),
    %% Two full-screen erases: the first frame and the post-resize repaint.
    ?assertEqual(2, length(binary:matches(Frames, ?ERASE))).

%%% -- helpers ---------------------------------------------------------

%% Run the loop over a scripted backend with a minimal probe reply (just the DA1
%% sentinel, so the startup probe returns the baseline promptly).
run_loop(Script, Size) ->
    run_loop(<<"\e[?62;c">>, Script, Size).

%% Run the loop synchronously over a scripted backend, then collect everything the
%% backend forwarded to us: the concatenated write payloads and whether close/1
%% ran. `ProbeReply' is delivered as the first read — consumed by the startup
%% capability probe — followed by `Script' (the keys the loop then sees). start/1
%% runs the loop in *this* process, so all messages are queued by the time it
%% returns.
run_loop(ProbeReply, Script, Size) ->
    Opts = #{
        backend => tuition_loop_term,
        sink => self(),
        size => Size,
        script => [{ok, ProbeReply} | Script]
    },
    ?assertEqual(ok, tuition_demo:start(Opts)),
    drain(<<>>, false).

drain(Frames, Closed) ->
    receive
        {write, Bin} -> drain(<<Frames/binary, Bin/binary>>, Closed);
        closed -> drain(Frames, true)
    after 200 ->
        {Frames, Closed}
    end.
