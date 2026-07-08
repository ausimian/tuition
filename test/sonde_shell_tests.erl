-module(sonde_shell_tests).

-include_lib("eunit/include/eunit.hrl").

%%% A wide canvas so the nav bar, the active pane and the status line all have room
%%% to draw; the tiny-terminal test covers the degenerate end separately.
-define(BIG, {120, 40}).

%%% Two stub panes, in tab order (see sonde_shell_pane_a/_b) — distinguishable content.
-define(PANES, [{sonde_shell_pane_a, <<"Alpha">>}, {sonde_shell_pane_b, <<"Beta">>}]).

%%% -- event helpers ---------------------------------------------------

char(C) -> {key, {char, C}, []}.
tab() -> {key, tab, []}.
backtab() -> {key, tab, [shift]}.
ctrl_c() -> {key, {ctrl, $c}, []}.

frame(Shell) ->
    {Buf, _Shell} = sonde_shell:build_frame(?BIG, Shell),
    iolist_to_binary(sonde_render:diff(sonde_render:new(?BIG), Buf)).

%%% -- construction ----------------------------------------------------

new_focuses_the_first_pane_test() ->
    Shell = sonde_shell:new(?PANES),
    ?assertEqual(0, sonde_shell:active(Shell)),
    ?assertEqual(sonde_shell_pane_a, sonde_shell:active_module(Shell)),
    ?assertEqual(2, sonde_shell:pane_count(Shell)).

new_can_focus_a_later_pane_test() ->
    Shell = sonde_shell:new(?PANES, 1),
    ?assertEqual(1, sonde_shell:active(Shell)),
    ?assertEqual(sonde_shell_pane_b, sonde_shell:active_module(Shell)).

new_clamps_an_out_of_range_focus_test() ->
    %% A focus past the end clamps onto the last pane rather than crashing.
    ?assertEqual(1, sonde_shell:active(sonde_shell:new(?PANES, 9))).

%%% -- pane switching --------------------------------------------------

tab_switches_to_the_next_pane_test() ->
    {ok, S1} = sonde_shell:apply_events([tab()], sonde_shell:new(?PANES)),
    ?assertEqual(1, sonde_shell:active(S1)),
    ?assertEqual(sonde_shell_pane_b, sonde_shell:active_module(S1)).

shift_tab_switches_to_the_previous_pane_test() ->
    {ok, S1} = sonde_shell:apply_events([backtab()], sonde_shell:new(?PANES, 1)),
    ?assertEqual(0, sonde_shell:active(S1)).

tab_wraps_around_the_ends_test() ->
    %% Tab off the last pane returns to the first; Shift-Tab off the first to the last.
    {ok, Wrapped} = sonde_shell:apply_events([tab()], sonde_shell:new(?PANES, 1)),
    ?assertEqual(0, sonde_shell:active(Wrapped)),
    {ok, Back} = sonde_shell:apply_events([backtab()], sonde_shell:new(?PANES, 0)),
    ?assertEqual(1, sonde_shell:active(Back)).

switching_shows_the_newly_focused_pane_test() ->
    %% The nav tabs are always present; the body shows whichever pane has focus.
    S0 = sonde_shell:new(?PANES),
    B0 = frame(S0),
    ?assertMatch({_, _}, binary:match(B0, <<"Alpha">>)),
    ?assertMatch({_, _}, binary:match(B0, <<"Beta">>)),
    ?assertMatch({_, _}, binary:match(B0, <<"alpha body">>)),
    ?assertEqual(nomatch, binary:match(B0, <<"beta body">>)),
    {ok, S1} = sonde_shell:apply_events([tab()], S0),
    B1 = frame(S1),
    ?assertMatch({_, _}, binary:match(B1, <<"beta body">>)),
    ?assertEqual(nomatch, binary:match(B1, <<"alpha body">>)).

single_pane_shell_draws_no_nav_bar_test() ->
    %% A one-pane shell (a demo flag, or a pane run alone) has no tabs to show, so
    %% the pane gets the top row too — only the pane's own title renders, not a tab.
    Shell = sonde_shell:new([{sonde_shell_pane_b, <<"Beta">>}]),
    ?assertEqual(1, sonde_shell:pane_count(Shell)),
    B = frame(Shell),
    ?assertMatch({_, _}, binary:match(B, <<"beta body">>)).

%%% -- global vs. pane-local key routing -------------------------------

pane_local_keys_reach_the_focused_pane_test() ->
    %% Down/j move pane B.s selection: the shell passes the keys straight
    %% through to the focused pane, whose own state records the move.
    S0 = sonde_shell:new(?PANES, 1),
    ?assertEqual(0, sonde_shell_pane_b:selection(sonde_shell:active_state(S0))),
    {ok, S1} = sonde_shell:apply_events([{key, down, []}, char($j)], S0),
    ?assertEqual(2, sonde_shell_pane_b:selection(sonde_shell:active_state(S1))).

switch_mid_batch_retargets_later_events_test() ->
    %% down (to pane B) then Tab (switch to pane A) then down: the second down
    %% lands on pane A, so pane B kept only its first move.
    S0 = sonde_shell:new(?PANES, 1),
    {ok, S1} = sonde_shell:apply_events([{key, down, []}, tab(), {key, down, []}], S0),
    ?assertEqual(0, sonde_shell:active(S1)),
    %% Switching back shows pane B advanced exactly once (row 1).
    {ok, S2} = sonde_shell:apply_events([backtab()], S1),
    ?assertEqual(1, sonde_shell_pane_b:selection(sonde_shell:active_state(S2))).

tab_switches_even_while_a_pane_captures_text_test() ->
    %% Pane B.s filter mode swallows every printable key, but Tab is not
    %% printable and is owned by the shell, so a pane switch is never eaten.
    S0 = sonde_shell:new(?PANES, 1),
    {ok, Filtering} = sonde_shell:apply_events([char($/)], S0),
    {ok, Switched} = sonde_shell:apply_events([tab()], Filtering),
    ?assertEqual(0, sonde_shell:active(Switched)).

q_is_pane_local_and_types_into_an_active_filter_test() ->
    %% `q. is not a shell-global key: routed to pane B in filter mode it
    %% is text, not a quit — the shell keeps running and the filter shows the `q'.
    S0 = sonde_shell:new(?PANES, 1),
    Result = sonde_shell:apply_events([char($/), char($q)], S0),
    ?assertMatch({ok, _}, Result),
    {ok, S1} = Result,
    ?assertMatch({_, _}, binary:match(frame(S1), <<"filter: q">>)).

%%% -- quit ------------------------------------------------------------

ctrl_c_quits_from_any_pane_test() ->
    ?assertEqual(quit, sonde_shell:apply_events([ctrl_c()], sonde_shell:new(?PANES, 0))),
    ?assertEqual(quit, sonde_shell:apply_events([ctrl_c()], sonde_shell:new(?PANES, 1))).

ctrl_c_quits_even_while_a_pane_captures_text_test() ->
    %% Ctrl-C is peeled off at the shell before the pane, so it quits even from the
    %% pane B.s filter mode (where a plain `q. would be typed instead).
    S0 = sonde_shell:new(?PANES, 1),
    {ok, Filtering} = sonde_shell:apply_events([char($/)], S0),
    ?assertEqual(quit, sonde_shell:apply_events([ctrl_c()], Filtering)).

q_quits_when_the_focused_pane_treats_it_as_quit_test() ->
    %% In normal mode both panes take a plain `q' as quit, which the shell honours.
    ?assertEqual(quit, sonde_shell:apply_events([char($q)], sonde_shell:new(?PANES, 0))),
    ?assertEqual(quit, sonde_shell:apply_events([char($q)], sonde_shell:new(?PANES, 1))).

%%% -- chrome ----------------------------------------------------------

status_line_names_the_global_keys_test() ->
    B = frame(sonde_shell:new(?PANES)),
    ?assertMatch({_, _}, binary:match(B, <<"switch pane">>)),
    ?assertMatch({_, _}, binary:match(B, <<"ctrl-c quit">>)).

tiny_terminal_does_not_crash_test() ->
    %% Undersized areas must render nothing rather than fail — the nav/status guards
    %% and the panes' own guards all hold at a degenerate geometry.
    Shell = sonde_shell:new(?PANES),
    ?assertMatch({_, _}, sonde_shell:build_frame({4, 3}, Shell)),
    ?assertMatch({_, _}, sonde_shell:build_frame({1, 1}, Shell)),
    ?assertMatch({_, _}, sonde_shell:build_frame({20, 2}, Shell)).

%%% -- live sampling ---------------------------------------------------

sample_refreshes_only_the_focused_pane_test() ->
    %% Sampling drives the focused pane.s sample callback (the stub pane fabricates a
    %% row) and still renders a populated frame.
    S0 = sonde_shell:new(?PANES, 1),
    S1 = sonde_shell:sample(S0),
    ?assert(length(sonde_shell_pane_b:rows(sonde_shell:active_state(S1))) > 0),
    ?assertMatch({_, _}, binary:match(frame(S1), <<"beta body">>)).

is_idle_tick_only_on_a_genuine_timeout_test() ->
    %% The focused pane samples only on a real idle tick — no events AND nothing
    %% buffered — so a keystroke, or a multi-byte key still arriving, never triggers
    %% a re-sample (which would churn the frozen snapshot mid-navigation).
    Clean = sonde_input:new(),
    %% A poll that produced no events and left nothing buffered: a real idle tick.
    ?assert(sonde_shell:is_idle_tick([], Clean)),
    %% A multi-byte key arriving one byte per read parses to zero events but buffers
    %% a partial — a keystroke in flight, not an idle tick.
    {[], MidEsc} = sonde_input:parse(<<16#1B>>, Clean),
    ?assertNot(sonde_shell:is_idle_tick([], MidEsc)),
    {[], MidCsi} = sonde_input:parse(<<16#1B, $[>>, Clean),
    ?assertNot(sonde_shell:is_idle_tick([], MidCsi)),
    %% A completed keystroke is never an idle tick.
    ?assertNot(sonde_shell:is_idle_tick([{key, up, []}], Clean)).

down_arrow_split_across_reads_drives_the_loop_test() ->
    %% Drive the shell loop with a down arrow (ESC [ B) arriving one byte per read —
    %% the byte-split multi-byte key the idle-tick gate hinges on. It must render and
    %% quit cleanly rather than fault on a prefix byte. (That the prefix bytes do not
    %% re-sample is asserted deterministically by the is_idle_tick test above; the
    %% frame stream can't show it, as the initial paint carries the seed regardless.)
    Script = [{ok, <<16#1B>>}, {ok, <<$[>>}, {ok, <<$B>>}, {ok, <<"q">>}],
    {Frames, Closed} = run_loop(Script, ?BIG),
    ?assert(Closed),
    ?assertMatch({_, _}, binary:match(Frames, <<"alpha body">>)).

%%% -- pane lifecycle (setup / teardown) -------------------------------
%%%
%%% These assert the *order* of setup/teardown directly, via a stub pane
%%% (sonde_shell_order_pane) that logs each `setup/0'/`teardown/1' to the process
%%% dictionary — the shell runs synchronously in this process, so the log is shared.
%%% A real resource like `scheduler_wall_time' is a poor probe here: it behaves as if
%%% reference-counted across repeated enables, so it doesn't round-trip cleanly under
%%% two panes and would test OTP's flag, not the shell's ordering.

%% The stub panes don't bind `q', so end the run with Ctrl-C, which the shell quits
%% on globally regardless of the focused pane.
lifecycle_opts() ->
    #{backend => sonde_loop_term, sink => self(), size => ?BIG, script => [{ok, <<3>>}]}.

%% The setup/teardown events the stub panes logged, in chronological order.
lifecycle_log() ->
    lists:reverse(
        case get(sonde_pane_lifecycle) of
            undefined -> [];
            L -> L
        end
    ).

%% Clear the stub panes' log and sequence counter — eunit shares the process
%% dictionary across a module's tests, so each lifecycle test starts from scratch.
reset_lifecycle() ->
    erase(sonde_pane_lifecycle),
    erase(sonde_pane_lifecycle_seq),
    ok.

teardown_unwinds_in_reverse_acquisition_order_test() ->
    %% Resources must unwind newest-first, so stacked restores of a shared resource
    %% nest correctly. Two panes set up 1 then 2; teardown must run 2 then 1.
    reset_lifecycle(),
    Panes = [{sonde_shell_order_pane, <<"A">>}, {sonde_shell_order_pane, <<"B">>}],
    ?assertEqual(ok, sonde_shell:start(Panes, lifecycle_opts())),
    drain(<<>>, false),
    ?assertEqual([{setup, 1}, {setup, 2}, {teardown, 2}, {teardown, 1}], lifecycle_log()).

setup_crash_restores_terminal_and_earlier_resources_test() ->
    %% A later pane's setup/0 raising must not leak: the earlier pane's resource is
    %% torn down and the terminal is restored, even though the shell never reaches its
    %% run loop. The error propagates out of start/2.
    reset_lifecycle(),
    Panes = [{sonde_shell_order_pane, <<"A">>}, {sonde_shell_boom_pane, <<"boom">>}],
    ?assertError(boom, sonde_shell:start(Panes, lifecycle_opts())),
    %% Terminal restored despite the crash (the scripted backend forwards `closed').
    {_Frames, Closed} = drain(<<>>, false),
    ?assert(Closed),
    %% Pane A was set up, then torn down on the unwind; boom never acquired anything.
    ?assertEqual([{setup, 1}, {teardown, 1}], lifecycle_log()).

%%% -- end-to-end over the scripted backend ----------------------------

renders_nav_and_active_pane_then_quits_on_q_test() ->
    {Frames, Closed} = run_loop([{ok, <<"q">>}], ?BIG),
    ?assert(Closed),
    %% Both nav tabs, the focused pane's content, and the global-key status line.
    ?assertMatch({_, _}, binary:match(Frames, <<"Alpha">>)),
    ?assertMatch({_, _}, binary:match(Frames, <<"Beta">>)),
    ?assertMatch({_, _}, binary:match(Frames, <<"alpha body">>)),
    ?assertMatch({_, _}, binary:match(Frames, <<"switch pane">>)).

quits_on_ctrl_c_test() ->
    {_Frames, Closed} = run_loop([{ok, <<3>>}], ?BIG),
    ?assert(Closed).

opts_focus_a_pane_by_module_test() ->
    %% Focus a pane by module: `start. with `active => module. opens the shell
    %% focused on that pane, so its content is on the very first frame before any Tab.
    Opts = #{
        backend => sonde_loop_term,
        sink => self(),
        size => ?BIG,
        script => [{ok, <<"q">>}],
        active => sonde_shell_pane_b
    },
    ?assertEqual(ok, sonde_shell:start(?PANES, Opts)),
    {Frames, Closed} = drain(<<>>, false),
    ?assert(Closed),
    ?assertMatch({_, _}, binary:match(Frames, <<"beta body">>)),
    ?assertEqual(nomatch, binary:match(Frames, <<"alpha body">>)).

tab_switches_pane_in_the_running_loop_test() ->
    %% Tab then quit: pane B is painted only after the switch, proving the
    %% running loop routes Tab to the shell and repaints the newly focused pane.
    {Frames, Closed} = run_loop([{ok, <<"\t">>}, {ok, <<"q">>}], ?BIG),
    ?assert(Closed),
    ?assertMatch({_, _}, binary:match(Frames, <<"beta body">>)).

resize_repaints_on_a_fresh_erase_test() ->
    %% A size change between polls repaints onto a freshly-erased baseline: two
    %% full-screen erases, the first frame and the post-resize repaint. `z' is a
    %% harmless key on the tick the resize lands, so it applies before `q' quits.
    {Frames, Closed} = run_loop([{ok, <<"z">>}, {ok, <<"q">>}], [{80, 24}, {80, 26}]),
    ?assert(Closed),
    ?assertEqual(2, length(binary:matches(Frames, <<"\e[2J">>))).

%%% -- helpers ---------------------------------------------------------

%% Drive the multi-pane shell's loop synchronously over the scripted test backend,
%% then collect what it wrote and whether it closed the terminal (mirrors the panes).
run_loop(Script, Size) ->
    Opts = #{
        backend => sonde_loop_term,
        sink => self(),
        size => Size,
        script => Script
    },
    ?assertEqual(ok, sonde_shell:start(?PANES, Opts)),
    drain(<<>>, false).

drain(Frames, Closed) ->
    receive
        {write, Bin} -> drain(<<Frames/binary, Bin/binary>>, Closed);
        closed -> drain(Frames, true)
    after 200 ->
        {Frames, Closed}
    end.
