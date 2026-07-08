-module(sonde_widget_tests).

-include_lib("eunit/include/eunit.hrl").
-include("sonde_layout.hrl").
-include("sonde_term.hrl").

%%% -- helpers ---------------------------------------------------------

buf(W, H) -> sonde_render:new({W, H}).
cell(B, X, Y) -> sonde_render:cell_at(B, X, Y).
ch(B, X, Y) -> (cell(B, X, Y))#cell.char.

%%% -- truncate --------------------------------------------------------

truncate_within_budget_test() ->
    ?assertEqual(<<"hi">>, sonde_widget:truncate(<<"hi">>, 5)).

truncate_clips_to_budget_test() ->
    ?assertEqual(<<"hel">>, sonde_widget:truncate(<<"hello">>, 3)).

truncate_zero_budget_is_empty_test() ->
    ?assertEqual(<<>>, sonde_widget:truncate(<<"hello">>, 0)).

truncate_negative_budget_is_empty_test() ->
    ?assertEqual(<<>>, sonde_widget:truncate(<<"hello">>, -3)).

truncate_stops_before_wide_glyph_that_would_overflow_test() ->
    %% "a" (1 col) then a full-width CJK glyph (2 cols): budget 2 fits only "a",
    %% since the wide glyph needs both remaining columns plus one more.
    ?assertEqual(<<"a">>, sonde_widget:truncate(<<"a世"/utf8>>, 2)).

truncate_takes_wide_glyph_when_it_fits_test() ->
    ?assertEqual(<<"世"/utf8>>, sonde_widget:truncate(<<"世界"/utf8>>, 2)).

truncate_counts_control_as_one_column_test() ->
    %% sonde_render renders a control byte as a one-column blank, so truncate must
    %% budget it as one column too: "a" + TAB fills the 2-column budget, dropping
    %% the trailing "b" — matching what the renderer would draw.
    ?assertEqual(<<"a\t">>, sonde_widget:truncate(<<"a\tb">>, 2)).

%%% -- align_offset ----------------------------------------------------

align_offset_left_test() ->
    ?assertEqual(0, sonde_widget:align_offset(left, 10, 4)).

align_offset_center_test() ->
    ?assertEqual(3, sonde_widget:align_offset(center, 10, 4)).

align_offset_right_test() ->
    ?assertEqual(6, sonde_widget:align_offset(right, 10, 4)).

align_offset_overflow_flushes_left_test() ->
    %% Content wider than the span sits flush left rather than at a negative offset.
    ?assertEqual(0, sonde_widget:align_offset(center, 4, 10)),
    ?assertEqual(0, sonde_widget:align_offset(right, 4, 10)).

%%% -- display_width ---------------------------------------------------

display_width_ascii_test() ->
    ?assertEqual(5, sonde_widget:display_width(<<"hello">>)).

display_width_wide_glyphs_count_two_test() ->
    ?assertEqual(4, sonde_widget:display_width(<<"世界"/utf8>>)).

display_width_counts_control_as_one_column_test() ->
    %% Matches truncate/2 and sonde_render: a control renders as a one-column
    %% blank, so it must measure as one — not the 0 sonde_width:swidth/1 gives it.
    ?assertEqual(3, sonde_widget:display_width(<<"a\tb">>)),
    ?assertEqual(1, sonde_widget:display_width(<<"\e">>)).

display_width_zero_width_mark_rides_its_base_test() ->
    %% "e" + combining acute is one grapheme, one column.
    ?assertEqual(1, sonde_widget:display_width(<<"e", 16#0301/utf8>>)).

%%% -- split -----------------------------------------------------------

split_takes_fitting_prefix_test() ->
    ?assertEqual({<<"ab">>, <<"cd">>}, sonde_widget:split(<<"abcd">>, 2)).

split_whole_when_it_fits_test() ->
    ?assertEqual({<<"hi">>, <<>>}, sonde_widget:split(<<"hi">>, 5)).

split_counts_control_as_one_column_test() ->
    %% Same accounting as truncate/2 — each tab is a one-column blank.
    ?assertEqual({<<"a\t\t">>, <<"b">>}, sonde_widget:split(<<"a\t\tb">>, 3)).

split_forces_at_least_one_cluster_test() ->
    %% A wide glyph with only one column of budget is still taken so a hard-split
    %% loop makes progress; put_line/6 clips the one-column overflow at draw time.
    ?assertEqual({<<"世"/utf8>>, <<"界"/utf8>>}, sonde_widget:split(<<"世界"/utf8>>, 1)).

split_empty_test() ->
    ?assertEqual({<<>>, <<>>}, sonde_widget:split(<<>>, 5)).

%%% -- fill ------------------------------------------------------------

fill_paints_styled_spaces_over_rect_test() ->
    B = sonde_widget:fill(buf(6, 3), #rect{x = 1, y = 1, w = 3, h = 1}, #{bg => 4}),
    ?assertMatch(#cell{char = $\s, bg = 4}, cell(B, 1, 1)),
    ?assertMatch(#cell{char = $\s, bg = 4}, cell(B, 3, 1)),
    %% Cells outside the rect stay blank.
    ?assertEqual(#cell{}, cell(B, 0, 1)),
    ?assertEqual(#cell{}, cell(B, 4, 1)),
    ?assertEqual(#cell{}, cell(B, 1, 0)).

fill_default_style_is_a_noop_test() ->
    B0 = buf(6, 3),
    B1 = sonde_widget:fill(B0, #rect{x = 0, y = 0, w = 6, h = 3}, #{}),
    ?assertEqual(<<>>, iolist_to_binary(sonde_render:diff(B0, B1))).

fill_empty_style_preserves_underlying_content_test() ->
    %% An empty style must leave a parent's cells intact, not blank them with
    %% default spaces — otherwise a list/paragraph drawn over a styled block erases
    %% the block's background.
    B0 = sonde_widget:fill(buf(4, 1), #rect{x = 0, y = 0, w = 4, h = 1}, #{bg => 5}),
    B1 = sonde_widget:fill(B0, #rect{x = 0, y = 0, w = 4, h = 1}, #{}),
    ?assertEqual(B0, B1),
    ?assertMatch(#cell{bg = 5}, cell(B1, 2, 0)).

fill_degenerate_rect_is_a_noop_test() ->
    B0 = buf(6, 3),
    ?assertEqual(B0, sonde_widget:fill(B0, #rect{x = 0, y = 0, w = 0, h = 3}, #{bg => 4})),
    ?assertEqual(B0, sonde_widget:fill(B0, #rect{x = 0, y = 0, w = 6, h = 0}, #{bg => 4})).

%%% -- put_line --------------------------------------------------------

put_line_clips_to_rect_width_test() ->
    %% Width-3 rect at x=1: "abcdef" draws only "abc" and never past the rect.
    B = sonde_widget:put_line(
        buf(10, 2), #rect{x = 1, y = 0, w = 3, h = 1}, 0, 0, <<"abcdef">>, #{}
    ),
    ?assertEqual($a, ch(B, 1, 0)),
    ?assertEqual($c, ch(B, 3, 0)),
    ?assertEqual($\s, ch(B, 4, 0)).

put_line_honours_offset_column_test() ->
    B = sonde_widget:put_line(buf(10, 2), #rect{x = 0, y = 0, w = 6, h = 1}, 2, 0, <<"xy">>, #{}),
    ?assertEqual($x, ch(B, 2, 0)),
    ?assertEqual($y, ch(B, 3, 0)),
    ?assertEqual($\s, ch(B, 0, 0)).

put_line_row_out_of_range_is_a_noop_test() ->
    B0 = buf(10, 2),
    Rect = #rect{x = 0, y = 0, w = 6, h = 1},
    ?assertEqual(B0, sonde_widget:put_line(B0, Rect, 0, 1, <<"x">>, #{})),
    ?assertEqual(B0, sonde_widget:put_line(B0, Rect, 0, -1, <<"x">>, #{})).

put_line_column_out_of_range_is_a_noop_test() ->
    B0 = buf(10, 2),
    Rect = #rect{x = 0, y = 0, w = 6, h = 1},
    ?assertEqual(B0, sonde_widget:put_line(B0, Rect, 6, 0, <<"x">>, #{})),
    ?assertEqual(B0, sonde_widget:put_line(B0, Rect, -1, 0, <<"x">>, #{})).

%%% -- render/4 dispatch -----------------------------------------------

render_dispatches_to_module_test() ->
    %% render/4 is just Mod:render/3 — a block rendered through the seam matches
    %% the block rendered directly.
    B0 = buf(6, 3),
    Rect = #rect{x = 0, y = 0, w = 6, h = 3},
    Cfg = #{borders => all, title => <<"x">>},
    ?assertEqual(
        sonde_block:render(Cfg, Rect, B0),
        sonde_widget:render(sonde_block, Cfg, Rect, B0)
    ).
