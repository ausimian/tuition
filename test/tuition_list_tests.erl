-module(tuition_list_tests).

-include_lib("eunit/include/eunit.hrl").
-include("tuition_layout.hrl").
-include("tuition_term.hrl").
-include("tuition_widget.hrl").

%%% -- helpers ---------------------------------------------------------

buf(W, H) -> tuition_render:new({W, H}).
cell(B, X, Y) -> tuition_render:cell_at(B, X, Y).
ch(B, X, Y) -> (cell(B, X, Y))#cell.char.
rect(X, Y, W, H) -> #rect{x = X, y = Y, w = W, h = H}.

%% N single-glyph items "i0".."i9" (used with N =< 10 so each stays one column).
items(N) -> [<<"i", (I + $0)>> || I <- lists:seq(0, N - 1)].

render(Cfg, W, H, State) ->
    tuition_list:render(Cfg, rect(0, 0, W, H), buf(W, H), State).

%%% -- navigation (pure) -----------------------------------------------

next_from_none_selects_first_test() ->
    ?assertEqual(0, tuition_list:selected(tuition_list:next(tuition_list:new(), 5))).

prev_from_none_selects_last_test() ->
    ?assertEqual(4, tuition_list:selected(tuition_list:prev(tuition_list:new(), 5))).

next_clamps_at_the_end_test() ->
    S = tuition_list:select(tuition_list:new(), 4),
    ?assertEqual(4, tuition_list:selected(tuition_list:next(S, 5))).

prev_clamps_at_the_start_test() ->
    S = tuition_list:select(tuition_list:new(), 0),
    ?assertEqual(0, tuition_list:selected(tuition_list:prev(S, 5))).

navigation_on_empty_list_stays_unselected_test() ->
    ?assertEqual(none, tuition_list:selected(tuition_list:next(tuition_list:new(), 0))),
    ?assertEqual(none, tuition_list:selected(tuition_list:prev(tuition_list:new(), 0))).

navigation_clamps_a_stale_index_test() ->
    %% A selection left past the end of a now-shorter list still steps sanely.
    S = tuition_list:select(tuition_list:new(), 99),
    ?assertEqual(4, tuition_list:selected(tuition_list:next(S, 5))),
    ?assertEqual(3, tuition_list:selected(tuition_list:prev(S, 5))).

%%% -- reconciliation --------------------------------------------------

render_returns_reconciled_state_test() ->
    %% Viewport 3 rows, selection 5 -> offset pulled to 5 - 3 + 1 = 3.
    {_, State} = render(#{items => items(10)}, 10, 3, tuition_list:select(tuition_list:new(), 5)),
    ?assertEqual(5, State#list_state.selected),
    ?assertEqual(3, State#list_state.offset).

offset_pulls_up_when_selection_above_view_test() ->
    {_, State} = render(#{items => items(10)}, 10, 3, #list_state{selected = 2, offset = 5}),
    ?assertEqual(2, State#list_state.offset).

offset_holds_when_selection_already_visible_test() ->
    {_, State} = render(#{items => items(10)}, 10, 4, #list_state{selected = 4, offset = 3}),
    ?assertEqual(3, State#list_state.offset).

render_clamps_stale_selection_test() ->
    {_, State} = render(#{items => items(3)}, 10, 5, #list_state{selected = 8, offset = 0}),
    ?assertEqual(2, State#list_state.selected).

render_empty_list_clears_selection_test() ->
    {_, State} = render(#{items => []}, 10, 5, tuition_list:select(tuition_list:new(), 0)),
    ?assertEqual(none, State#list_state.selected),
    ?assertEqual(0, State#list_state.offset).

degenerate_area_still_reconciles_state_test() ->
    %% No width to draw, but the state is still clamped/scrolled for a later resize.
    B0 = buf(10, 5),
    {B1, State} = tuition_list:render(#{items => items(10)}, rect(0, 0, 0, 5), B0, #list_state{
        selected = 20, offset = 0
    }),
    ?assertEqual(B0, B1),
    ?assertEqual(9, State#list_state.selected),
    ?assertEqual(5, State#list_state.offset).

%%% -- drawing ---------------------------------------------------------

draws_items_from_the_offset_test() ->
    %% Offset 3, height 2 -> rows show items i3, i4.
    {B, _} = render(#{items => items(10)}, 8, 2, #list_state{selected = none, offset = 3}),
    ?assertEqual($i, ch(B, 0, 0)),
    ?assertEqual($3, ch(B, 1, 0)),
    ?assertEqual($4, ch(B, 1, 1)).

draws_the_correct_slice_at_a_deep_offset_test() ->
    %% A scrolled list draws the visible slice from the offset (not from the head),
    %% with the selected row highlighted at its viewport position.
    {B, _} = render(#{items => items(10)}, 8, 3, #list_state{selected = 9, offset = 7}),
    ?assertEqual($7, ch(B, 1, 0)),
    ?assertEqual($8, ch(B, 1, 1)),
    ?assertEqual($9, ch(B, 1, 2)).

blank_rows_past_the_last_item_test() ->
    %% Two items, five rows -> rows 2..4 are blank.
    {B, _} = render(#{items => items(2)}, 8, 5, #list_state{selected = none, offset = 0}),
    ?assertEqual($i, ch(B, 0, 0)),
    ?assertEqual($i, ch(B, 0, 1)),
    ?assertEqual($\s, ch(B, 0, 2)).

selected_row_is_highlighted_across_full_width_test() ->
    Cfg = #{
        items => [<<"aa">>, <<"bb">>, <<"cc">>],
        highlight_style => #{bg => 4},
        highlight_symbol => <<"> ">>
    },
    {B, _} = render(Cfg, 6, 3, tuition_list:select(tuition_list:new(), 1)),
    %% Row 1: "> bb" over a full-width bg-4 bar.
    ?assertMatch(#cell{char = $>, bg = 4}, cell(B, 0, 1)),
    ?assertEqual($b, ch(B, 2, 1)),
    ?assertEqual($b, ch(B, 3, 1)),
    %% The bar spans past the text to the rect's right edge.
    ?assertMatch(#cell{char = $\s, bg = 4}, cell(B, 5, 1)).

unselected_rows_indent_under_the_symbol_gutter_test() ->
    Cfg = #{
        items => [<<"aa">>, <<"bb">>],
        highlight_style => #{bg => 4},
        highlight_symbol => <<"> ">>
    },
    {B, _} = render(Cfg, 6, 2, tuition_list:select(tuition_list:new(), 1)),
    %% Row 0 is unselected: no highlight, item shifted right by the 2-col gutter.
    ?assertEqual(default, (cell(B, 0, 0))#cell.bg),
    ?assertEqual($\s, ch(B, 0, 0)),
    ?assertEqual($a, ch(B, 2, 0)).

base_style_fills_unselected_rows_full_width_test() ->
    %% A configured base row background spans the whole width of an unselected row,
    %% not just the item cells — matching the selected row's full-width highlight.
    Cfg = #{
        items => [<<"aa">>, <<"bb">>],
        style => #{bg => 2},
        highlight_style => #{bg => 4}
    },
    {B, _} = render(Cfg, 6, 2, tuition_list:select(tuition_list:new(), 0)),
    %% Row 1 (unselected): base bg to the right of the short item.
    ?assertEqual($b, ch(B, 0, 1)),
    ?assertMatch(#cell{bg = 2}, cell(B, 5, 1)),
    %% Row 0 (selected): highlight bg across the full width.
    ?assertMatch(#cell{bg = 4}, cell(B, 5, 0)).

unstyled_rows_preserve_parent_background_test() ->
    %% A list with no base style drawn over a parent background (a block's fill)
    %% must not erase it under the rows — only the item glyphs overwrite, the rest
    %% shows through.
    Parent = tuition_widget:fill(buf(6, 2), rect(0, 0, 6, 2), #{bg => 3}),
    {B, _} = tuition_list:render(
        #{items => [<<"a">>, <<"b">>]},
        rect(0, 0, 6, 2),
        Parent,
        tuition_list:select(tuition_list:new(), 0)
    ),
    ?assertMatch(#cell{bg = 3}, cell(B, 5, 0)),
    ?assertMatch(#cell{bg = 3}, cell(B, 5, 1)).

no_highlight_symbol_draws_items_at_the_left_test() ->
    {B, _} = render(
        #{items => [<<"aa">>, <<"bb">>]}, 6, 2, tuition_list:select(tuition_list:new(), 0)
    ),
    ?assertEqual($a, ch(B, 0, 0)),
    ?assertEqual($b, ch(B, 0, 1)).
