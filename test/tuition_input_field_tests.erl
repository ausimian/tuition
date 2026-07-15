-module(tuition_input_field_tests).

-include_lib("eunit/include/eunit.hrl").
-include("tuition_layout.hrl").
-include("tuition_term.hrl").
-include("tuition_widget.hrl").

%%% -- helpers ---------------------------------------------------------

buf(W, H) -> tuition_render:new({W, H}).
cell(B, X, Y) -> tuition_render:cell_at(B, X, Y).
ch(B, X, Y) -> (cell(B, X, Y))#cell.char.
rect(X, Y, W, H) -> #rect{x = X, y = Y, w = W, h = H}.

render(Cfg, W, H, State) ->
    tuition_input_field:render(Cfg, rect(0, 0, W, H), buf(W, H), State).

%% Drive a sequence of events through handle/2, returning the final state.
feed(State, Events) ->
    lists:foldl(fun(E, S) -> element(1, tuition_input_field:handle(E, S)) end, State, Events).

typed(Value) -> tuition_input_field:set_value(tuition_input_field:new(), Value).

char(C) -> {key, {char, C}, []}.

%%% -- construction / accessors ----------------------------------------

new_is_empty_test() ->
    S = tuition_input_field:new(),
    ?assertEqual(<<>>, tuition_input_field:value(S)),
    ?assertEqual(0, tuition_input_field:cursor(S)).

set_value_places_caret_at_end_test() ->
    S = typed(<<"hello">>),
    ?assertEqual(<<"hello">>, tuition_input_field:value(S)),
    ?assertEqual(5, tuition_input_field:cursor(S)).

set_value_strips_control_bytes_test() ->
    %% A single-line field never stores a newline/tab typed in via set_value.
    S = typed(<<"a\nb\tc">>),
    ?assertEqual(<<"abc">>, tuition_input_field:value(S)),
    ?assertEqual(3, tuition_input_field:cursor(S)).

%%% -- editing (pure, via handle/2) ------------------------------------

insert_appends_and_reports_changed_test() ->
    {S, Changed} = tuition_input_field:handle(char($a), tuition_input_field:new()),
    ?assertEqual(<<"a">>, tuition_input_field:value(S)),
    ?assertEqual(1, tuition_input_field:cursor(S)),
    ?assert(Changed).

insert_at_the_caret_test() ->
    %% "ac", caret stepped back one, then 'b' inserted between them.
    S = feed(typed(<<"ac">>), [{key, left, []}, char($b)]),
    ?assertEqual(<<"abc">>, tuition_input_field:value(S)),
    ?assertEqual(2, tuition_input_field:cursor(S)).

insert_of_a_combining_mark_merges_and_keeps_the_caret_put_test() ->
    %% "ab", caret between a and b; insert U+0301 (combining acute). It merges with
    %% 'a' into "á", so the value is a single "á" cluster then "b" and the caret
    %% stays at index 1 — a following 'x' must land as "áxb", not "ábx".
    Acute = 16#0301,
    S0 = feed(typed(<<"ab">>), [{key, left, []}]),
    ?assertEqual(1, tuition_input_field:cursor(S0)),
    S1 = feed(S0, [char(Acute)]),
    ?assertEqual(<<$a, Acute/utf8, $b>>, tuition_input_field:value(S1)),
    ?assertEqual(1, tuition_input_field:cursor(S1)),
    S2 = feed(S1, [char($x)]),
    ?assertEqual(<<$a, Acute/utf8, $x, $b>>, tuition_input_field:value(S2)).

backspace_deletes_before_the_caret_test() ->
    {S, Changed} = tuition_input_field:handle({key, backspace, []}, typed(<<"abc">>)),
    ?assertEqual(<<"ab">>, tuition_input_field:value(S)),
    ?assertEqual(2, tuition_input_field:cursor(S)),
    ?assert(Changed).

backspace_at_the_start_is_a_no_op_test() ->
    S0 = feed(typed(<<"abc">>), [{key, home, []}]),
    {S1, Changed} = tuition_input_field:handle({key, backspace, []}, S0),
    ?assertEqual(<<"abc">>, tuition_input_field:value(S1)),
    ?assertNot(Changed).

delete_deletes_after_the_caret_test() ->
    S0 = feed(typed(<<"abc">>), [{key, home, []}]),
    {S1, Changed} = tuition_input_field:handle({key, delete, []}, S0),
    ?assertEqual(<<"bc">>, tuition_input_field:value(S1)),
    ?assertEqual(0, tuition_input_field:cursor(S1)),
    ?assert(Changed).

delete_at_the_end_is_a_no_op_test() ->
    {S, Changed} = tuition_input_field:handle({key, delete, []}, typed(<<"abc">>)),
    ?assertEqual(<<"abc">>, tuition_input_field:value(S)),
    ?assertNot(Changed).

caret_moves_do_not_change_the_value_test() ->
    {S, Changed} = tuition_input_field:handle({key, left, []}, typed(<<"ab">>)),
    ?assertEqual(<<"ab">>, tuition_input_field:value(S)),
    ?assertEqual(1, tuition_input_field:cursor(S)),
    ?assertNot(Changed).

home_and_end_jump_to_the_edges_test() ->
    S1 = feed(typed(<<"abcd">>), [{key, home, []}]),
    ?assertEqual(0, tuition_input_field:cursor(S1)),
    S2 = feed(S1, [{key, 'end', []}]),
    ?assertEqual(4, tuition_input_field:cursor(S2)).

left_and_right_clamp_at_the_edges_test() ->
    AtStart = feed(typed(<<"ab">>), [{key, home, []}, {key, left, []}]),
    ?assertEqual(0, tuition_input_field:cursor(AtStart)),
    AtEnd = feed(typed(<<"ab">>), [{key, right, []}]),
    ?assertEqual(2, tuition_input_field:cursor(AtEnd)).

%%% -- word movement (ctrl/alt + arrows) -------------------------------

word_left_lands_at_the_start_of_the_word_test() ->
    %% "foo bar baz", caret at end -> start of "baz" (index 8), then "bar" (4).
    S1 = feed(typed(<<"foo bar baz">>), [{key, left, [ctrl]}]),
    ?assertEqual(8, tuition_input_field:cursor(S1)),
    S2 = feed(S1, [{key, left, [ctrl]}]),
    ?assertEqual(4, tuition_input_field:cursor(S2)).

word_motion_over_a_long_word_scans_once_test() ->
    %% A long single word: ctrl+Left from the end reaches index 0 and alt+Right from
    %% home reaches the end, each in one linear scan (not O(n^2) list indexing).
    N = 1000,
    Home = feed(typed(binary:copy(<<"a">>, N)), [{key, left, [ctrl]}]),
    ?assertEqual(0, tuition_input_field:cursor(Home)),
    End = feed(Home, [{key, right, [alt]}]),
    ?assertEqual(N, tuition_input_field:cursor(End)).

word_right_lands_past_the_word_test() ->
    %% From the start, alt+right steps to the end of "foo" (3), then "bar" (7).
    S1 = feed(typed(<<"foo bar baz">>), [{key, home, []}, {key, right, [alt]}]),
    ?assertEqual(3, tuition_input_field:cursor(S1)),
    S2 = feed(S1, [{key, right, [alt]}]),
    ?assertEqual(7, tuition_input_field:cursor(S2)).

%%% -- ignored events --------------------------------------------------

enter_and_tab_are_left_for_the_caller_test() ->
    lists:foreach(
        fun(Event) ->
            {S, Changed} = tuition_input_field:handle(Event, typed(<<"ab">>)),
            ?assertEqual(<<"ab">>, tuition_input_field:value(S)),
            ?assertEqual(2, tuition_input_field:cursor(S)),
            ?assertNot(Changed)
        end,
        [{key, enter, []}, {key, tab, []}, {key, up, []}, {key, {ctrl, $a}, [ctrl]}]
    ).

ctrl_modified_char_is_not_inserted_test() ->
    {S, Changed} = tuition_input_field:handle({key, {char, $x}, [ctrl]}, typed(<<"ab">>)),
    ?assertEqual(<<"ab">>, tuition_input_field:value(S)),
    ?assertNot(Changed).

%%% -- paste -----------------------------------------------------------

paste_inserts_sanitized_text_test() ->
    {S, Changed} = tuition_input_field:handle({paste, <<"a\nb">>}, tuition_input_field:new()),
    ?assertEqual(<<"ab">>, tuition_input_field:value(S)),
    ?assertEqual(2, tuition_input_field:cursor(S)),
    ?assert(Changed).

paste_of_only_control_bytes_is_a_no_op_test() ->
    {S, Changed} = tuition_input_field:handle({paste, <<"\n\t">>}, typed(<<"ab">>)),
    ?assertEqual(<<"ab">>, tuition_input_field:value(S)),
    ?assertNot(Changed).

%%% -- rendering: value + caret ----------------------------------------

renders_value_with_caret_at_the_end_test() ->
    {B, _} = render(#{}, 5, 1, typed(<<"ab">>)),
    ?assertEqual($a, ch(B, 0, 0)),
    ?assertEqual($b, ch(B, 1, 0)),
    %% The caret sits on the blank past the last char, underlined by default.
    ?assertMatch(#cell{char = $\s, underline = true}, cell(B, 2, 0)).

caret_over_a_char_carries_the_cursor_style_test() ->
    S = feed(typed(<<"ab">>), [{key, home, []}]),
    {B, _} = render(#{}, 5, 1, S),
    ?assertMatch(#cell{char = $a, underline = true}, cell(B, 0, 0)),
    ?assertMatch(#cell{char = $b, underline = false}, cell(B, 1, 0)).

custom_cursor_style_test() ->
    {B, _} = render(#{cursor_style => #{bg => 4}}, 5, 1, typed(<<"ab">>)),
    ?assertMatch(#cell{char = $\s, bg = 4}, cell(B, 2, 0)).

empty_cursor_style_draws_no_visible_caret_test() ->
    %% An unfocused field: the caret cell is left in the base style.
    {B, _} = render(#{cursor_style => #{}}, 5, 1, feed(typed(<<"ab">>), [{key, home, []}])),
    ?assertMatch(#cell{char = $a, underline = false}, cell(B, 0, 0)).

%%% -- rendering: placeholder ------------------------------------------

placeholder_shows_while_empty_test() ->
    {B, _} = render(#{placeholder => <<"hint">>}, 6, 1, tuition_input_field:new()),
    %% Dim grey placeholder, with the caret resting on its first glyph.
    ?assertMatch(#cell{char = $h, fg = 8, underline = true}, cell(B, 0, 0)),
    ?assertMatch(#cell{char = $i, fg = 8, underline = false}, cell(B, 1, 0)),
    ?assertEqual($t, ch(B, 3, 0)).

placeholder_hidden_once_text_is_typed_test() ->
    {B, _} = render(#{placeholder => <<"hint">>}, 6, 1, typed(<<"x">>)),
    ?assertEqual($x, ch(B, 0, 0)),
    %% Column 1 is the caret's blank, not the placeholder's second glyph.
    ?assertEqual($\s, ch(B, 1, 0)).

empty_field_without_placeholder_shows_a_bare_caret_test() ->
    {B, _} = render(#{}, 5, 1, tuition_input_field:new()),
    ?assertMatch(#cell{char = $\s, underline = true}, cell(B, 0, 0)).

placeholder_keeps_the_field_background_test() ->
    %% A styled input box: the base background must show through the placeholder
    %% text and the caret over it, not leave holes.
    Cfg = #{style => #{bg => 4}, placeholder => <<"hint">>},
    {B, _} = render(Cfg, 6, 1, tuition_input_field:new()),
    ?assertMatch(#cell{char = $h, bg = 4, underline = true}, cell(B, 0, 0)),
    ?assertMatch(#cell{char = $i, bg = 4}, cell(B, 1, 0)),
    ?assertMatch(#cell{char = $t, bg = 4}, cell(B, 3, 0)).

%%% -- rendering: mask -------------------------------------------------

mask_hides_the_value_test() ->
    {B, _} = render(#{mask => $*}, 5, 1, feed(typed(<<"abc">>), [{key, home, []}])),
    ?assertEqual($*, ch(B, 0, 0)),
    ?assertEqual($*, ch(B, 1, 0)),
    ?assertEqual($*, ch(B, 2, 0)),
    %% The real characters never reach the buffer.
    ?assertNotEqual($a, ch(B, 0, 0)).

%%% -- rendering: horizontal scroll ------------------------------------

scroll_keeps_the_end_caret_visible_test() ->
    %% "abcdef" in a 4-wide field, caret at the end -> shows the tail "def" + caret.
    {B, State} = render(#{}, 4, 1, typed(<<"abcdef">>)),
    ?assertEqual(3, State#input_state.offset),
    ?assertEqual($d, ch(B, 0, 0)),
    ?assertEqual($e, ch(B, 1, 0)),
    ?assertEqual($f, ch(B, 2, 0)),
    ?assertMatch(#cell{char = $\s, underline = true}, cell(B, 3, 0)).

scroll_returns_to_the_head_at_home_test() ->
    S = feed(typed(<<"abcdef">>), [{key, home, []}]),
    {B, State} = render(#{}, 4, 1, S),
    ?assertEqual(0, State#input_state.offset),
    ?assertMatch(#cell{char = $a, underline = true}, cell(B, 0, 0)),
    ?assertEqual($d, ch(B, 3, 0)).

scroll_offset_pulls_back_after_the_value_shrinks_test() ->
    %% A stale offset from a longer value is pulled back so no leading text hides.
    Stale = #input_state{value = <<"ab">>, cursor = 2, offset = 5},
    {B, State} = render(#{}, 6, 1, Stale),
    ?assertEqual(0, State#input_state.offset),
    ?assertEqual($a, ch(B, 0, 0)),
    ?assertEqual($b, ch(B, 1, 0)).

zero_width_tail_keeps_the_caret_visible_test() ->
    %% "a" + U+200B (zero-width space) in a 1-column field, caret at index 1 (before
    %% the zero-width cluster). The zero-width tail must not let the offset pull back
    %% to 0, which would push the caret column off the 1-column field and draw no
    %% caret; the offset stays at 1 so the caret is shown.
    ZWSP = 16#200B,
    State = #input_state{value = <<$a, ZWSP/utf8>>, cursor = 1, offset = 0},
    {B, S} = render(#{}, 1, 1, State),
    ?assertEqual(1, S#input_state.offset),
    ?assertMatch(#cell{underline = true}, cell(B, 0, 0)).

large_value_scrolls_to_the_caret_in_one_linear_pass_test() ->
    %% A long value with the caret at the end reconciles via prefix sums (O(n)), not
    %% by re-summing a sublist per hidden cluster (O(n^2)); it lands the offset on
    %% the tail and shows the last chars plus the caret.
    N = 1000,
    {B, S} = render(#{}, 5, 1, typed(binary:copy(<<"a">>, N))),
    ?assertEqual(N - 5 + 1, S#input_state.offset),
    ?assertEqual($a, ch(B, 0, 0)),
    ?assertMatch(#cell{char = $\s, underline = true}, cell(B, 4, 0)).

%%% -- reconciliation --------------------------------------------------

render_clamps_a_stale_cursor_test() ->
    {_, State} = render(#{}, 5, 1, #input_state{value = <<"ab">>, cursor = 99, offset = 0}),
    ?assertEqual(2, State#input_state.cursor).

degenerate_area_still_reconciles_state_test() ->
    B0 = buf(5, 1),
    {B1, State} = tuition_input_field:render(
        #{}, rect(0, 0, 0, 1), B0, #input_state{value = <<"ab">>, cursor = 99, offset = 9}
    ),
    ?assertEqual(B0, B1),
    ?assertEqual(2, State#input_state.cursor),
    ?assertEqual(0, State#input_state.offset).

%%% -- rendering: styling ----------------------------------------------

unstyled_field_preserves_the_parent_background_test() ->
    %% With no base style, the cells past the value keep a parent block's fill —
    %% and so does the caret cell, which overlays cursor_style onto the parent
    %% blank rather than punching a default-styled hole through it.
    Parent = tuition_widget:fill(buf(5, 1), rect(0, 0, 5, 1), #{bg => 3}),
    {B, _} = tuition_input_field:render(#{}, rect(0, 0, 5, 1), Parent, typed(<<"a">>)),
    %% Caret at column 1 (end of "a"): parent bg kept, cursor underline added.
    ?assertMatch(#cell{char = $\s, bg = 3, underline = true}, cell(B, 1, 0)),
    ?assertMatch(#cell{bg = 3}, cell(B, 3, 0)),
    ?assertMatch(#cell{bg = 3}, cell(B, 4, 0)).

base_style_fills_the_field_width_test() ->
    {B, _} = render(#{style => #{bg => 2}}, 5, 1, typed(<<"a">>)),
    ?assertMatch(#cell{char = $a, bg = 2}, cell(B, 0, 0)),
    %% The base background spans past the single character to the field's edge.
    ?assertMatch(#cell{bg = 2}, cell(B, 4, 0)).

%%% -- rendering: wide glyphs ------------------------------------------

%% 世 (U+4E16), a 2-column CJK glyph, written by codepoint so the test does not
%% depend on the source file's encoding.
-define(WIDE, <<16#4E16/utf8>>).

wide_glyph_occupies_two_columns_with_the_caret_after_it_test() ->
    {B, _} = render(#{}, 5, 1, typed(?WIDE)),
    ?assertMatch(#cell{cols = 2}, cell(B, 0, 0)),
    ?assertEqual(wide_cont, cell(B, 1, 0)),
    %% The caret sits two columns in, past the whole wide glyph.
    ?assertMatch(#cell{char = $\s, underline = true}, cell(B, 2, 0)).

caret_rests_on_a_whole_wide_glyph_test() ->
    S = feed(typed(?WIDE), [{key, home, []}]),
    {B, _} = render(#{}, 5, 1, S),
    ?assertMatch(#cell{cols = 2, underline = true}, cell(B, 0, 0)),
    ?assertEqual(wide_cont, cell(B, 1, 0)).

wide_glyph_under_the_caret_at_the_edge_stays_visible_test() ->
    %% "ab世" (世 wide) in a 3-column field, caret before 世 (index 2). The offset must
    %% scroll to 1 so 世 fits whole under the caret ("b世"), not stay at 0 where 世
    %% starts in the last column and is clipped to an underlined blank.
    {B, S} = render(#{}, 3, 1, feed(typed(<<"ab", ?WIDE/binary>>), [{key, left, []}])),
    ?assertEqual(1, S#input_state.offset),
    ?assertEqual($b, ch(B, 0, 0)),
    ?assertMatch(#cell{cols = 2, underline = true}, cell(B, 1, 0)),
    ?assertEqual(wide_cont, cell(B, 2, 0)).

wide_glyph_is_a_single_caret_step_test() ->
    %% 世x: one Right past the wide glyph lands the caret at cluster index 1.
    S = feed(typed(<<16#4E16/utf8, "x">>), [{key, home, []}, {key, right, []}]),
    ?assertEqual(1, tuition_input_field:cursor(S)).
