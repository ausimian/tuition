-module(tuition_widget_demo_tests).

-include_lib("eunit/include/eunit.hrl").

%% Ascending sort indicator, mirrored from tuition_table's private define.
-define(ASC, 16#25B2).

%%% -- event helpers ---------------------------------------------------

key(Named) -> {key, Named, []}.
char(C) -> {key, {char, C}, []}.

apply(Events) ->
    tuition_widget_demo:apply_events(Events, tuition_widget_demo:new()).

%%% -- selection folding (pure) ----------------------------------------

down_moves_selection_forward_test() ->
    {ok, S} = apply([key(down), key(down)]),
    ?assertEqual(2, tuition_widget_demo:selection(S)).

up_from_the_top_stays_put_test() ->
    {ok, S} = apply([key(up)]),
    ?assertEqual(0, tuition_widget_demo:selection(S)).

j_and_k_navigate_like_down_and_up_test() ->
    {ok, S} = apply([char($j), char($j), char($k)]),
    ?assertEqual(1, tuition_widget_demo:selection(S)).

home_jumps_to_the_first_row_test() ->
    {ok, S0} = apply([key(down), key(down), key(down)]),
    {ok, S1} = tuition_widget_demo:apply_events([key(home)], S0),
    ?assertEqual(0, tuition_widget_demo:selection(S1)).

end_jumps_to_the_last_row_and_is_stable_test() ->
    {ok, S1} = apply([key('end')]),
    {ok, S2} = tuition_widget_demo:apply_events([key(down)], S1),
    ?assert(tuition_widget_demo:selection(S1) > 0),
    ?assertEqual(tuition_widget_demo:selection(S1), tuition_widget_demo:selection(S2)).

unhandled_keys_are_ignored_test() ->
    {ok, S} = apply([char($x), key(left)]),
    ?assertEqual(0, tuition_widget_demo:selection(S)).

q_quits_test() ->
    ?assertEqual(quit, apply([char($q)])).

ctrl_c_quits_test() ->
    ?assertEqual(
        quit, tuition_widget_demo:apply_events([{key, {ctrl, $c}, []}], tuition_widget_demo:new())
    ).

quit_short_circuits_remaining_events_test() ->
    %% 'q' quits before the following Down is folded.
    ?assertEqual(quit, apply([char($q), key(down)])).

%%% -- frame composition -----------------------------------------------

build_frame_composes_the_widgets_test() ->
    {Buf, _} = tuition_widget_demo:build_frame({40, 12}, tuition_widget_demo:new()),
    B = iolist_to_binary(tuition_render:diff(tuition_render:new({40, 12}), Buf)),
    %% Block title, paragraph help line, table header, first row, selection symbol.
    ?assertMatch({_, _}, binary:match(B, <<"processes">>)),
    ?assertMatch({_, _}, binary:match(B, <<"to quit">>)),
    ?assertMatch({_, _}, binary:match(B, <<"Name">>)),
    ?assertMatch({_, _}, binary:match(B, <<"init">>)),
    ?assertMatch({_, _}, binary:match(B, <<"> ">>)).

build_frame_scrolls_to_keep_selection_visible_test() ->
    %% A terminal wide enough that the fill Name column shows the full names.
    {ok, State} = tuition_widget_demo:apply_events(
        lists:duplicate(28, key(down)), tuition_widget_demo:new()
    ),
    {Buf, _} = tuition_widget_demo:build_frame({80, 24}, State),
    B = iolist_to_binary(tuition_render:diff(tuition_render:new({80, 24}), Buf)),
    %% The bottom row scrolled into view; the top row scrolled off.
    ?assertMatch({_, _}, binary:match(B, <<"socket_registry">>)),
    ?assertEqual(nomatch, binary:match(B, <<"init">>)).

pressing_s_sorts_by_name_and_marks_the_header_test() ->
    {ok, State} = apply([char($s)]),
    {Buf, _} = tuition_widget_demo:build_frame({60, 20}, State),
    B = iolist_to_binary(tuition_render:diff(tuition_render:new({60, 20}), Buf)),
    %% Ascending by name: the rows are actually reordered, so "application_controller"
    %% (canonical row 4) now renders *above* "init" (canonical row 0) — a positional
    %% check, since the header ▲ alone would pass even if apply_sort were a no-op.
    {AppPos, _} = binary:match(B, <<"application_controller">>),
    {InitPos, _} = binary:match(B, <<"init">>),
    ?assert(AppPos < InitPos),
    %% ...and the Name column's header carries the ascending indicator.
    ?assertMatch({_, _}, binary:match(B, <<?ASC/utf8>>)).

%%% -- end-to-end over the scripted backend ----------------------------

renders_and_quits_on_q_test() ->
    {Frames, Closed} = run_loop([{ok, <<"q">>}], {40, 12}),
    ?assert(Closed),
    ?assertMatch({_, _}, binary:match(Frames, <<"processes">>)),
    ?assertMatch({_, _}, binary:match(Frames, <<"to quit">>)),
    ?assertMatch({_, _}, binary:match(Frames, <<"init">>)).

quits_on_ctrl_c_test() ->
    {_Frames, Closed} = run_loop([{ok, <<3>>}], {40, 12}),
    ?assert(Closed).

arrow_down_repaints_the_moved_selection_test() ->
    %% Down then quit: the second row ends up selected, so the highlight symbol
    %% precedes its pid (<0.42.0>) in the repaint the arrow triggered. Wide enough
    %% that the Name column shows the full "erts_code_purger".
    {Frames, Closed} = run_loop([{ok, <<"\e[B">>}, {ok, <<"q">>}], {80, 24}),
    ?assert(Closed),
    ?assertMatch({_, _}, binary:match(Frames, <<"> <0.42.0>">>)),
    ?assertMatch({_, _}, binary:match(Frames, <<"erts_code_purger">>)).

%%% -- helpers ---------------------------------------------------------

%% Drive the demo loop synchronously over the scripted test backend (no capability
%% probe — the demo does not probe), then collect what it wrote and whether it
%% closed the terminal. The loop runs in this process, so every message is queued
%% by the time start/1 returns.
run_loop(Script, Size) ->
    Opts = #{
        backend => tuition_loop_term,
        sink => self(),
        size => Size,
        script => Script
    },
    ?assertEqual(ok, tuition_widget_demo:start(Opts)),
    drain(<<>>, false).

drain(Frames, Closed) ->
    receive
        {write, Bin} -> drain(<<Frames/binary, Bin/binary>>, Closed);
        closed -> drain(Frames, true)
    after 200 ->
        {Frames, Closed}
    end.
