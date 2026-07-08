-module(sonde_table_tests).

-include_lib("eunit/include/eunit.hrl").
-include("sonde_layout.hrl").
-include("sonde_term.hrl").
-include("sonde_widget.hrl").

%%% -- helpers ---------------------------------------------------------

buf(W, H) -> sonde_render:new({W, H}).
cell(B, X, Y) -> sonde_render:cell_at(B, X, Y).
ch(B, X, Y) -> (cell(B, X, Y))#cell.char.
rect(X, Y, W, H) -> #rect{x = X, y = Y, w = W, h = H}.

render(Cfg, W, H, State) ->
    sonde_table:render(Cfg, rect(0, 0, W, H), buf(W, H), State).

%% Collect the `{built, N}' messages a lazy `RowFun' sends itself, for asserting
%% which rows it was actually invoked for.
drain_built(Acc) ->
    receive
        {built, N} -> drain_built([N | Acc])
    after 0 -> Acc
    end.

%% Two columns: an 8-wide PID column and a filling Name column, one space apart.
%% With a "> " highlight symbol the 2-col gutter shifts the columns right, so in a
%% 20-wide table PID sits at x=2 and Name at x=11 (2 gutter + 8 PID + 1 spacer).
cols() ->
    [
        #{header => <<"PID">>, constraint => {fixed, 8}},
        #{header => <<"Name">>, constraint => fill}
    ].

base_cfg(Rows) ->
    #{columns => cols(), rows => Rows, highlight_symbol => <<"> ">>}.

%% Sort-indicator glyphs, mirrored from sonde_table's private defines.
-define(ASC, 16#25B2).
-define(DESC, 16#25BC).

%%% -- navigation (delegated to the list) ------------------------------

navigation_delegates_to_the_list_test() ->
    ?assertEqual(0, sonde_table:selected(sonde_table:next(sonde_table:new(), 5))),
    ?assertEqual(4, sonde_table:selected(sonde_table:prev(sonde_table:new(), 5))),
    ?assertEqual(2, sonde_table:selected(sonde_table:select(sonde_table:new(), 2))).

%%% -- sorting (pure) --------------------------------------------------

toggle_sort_new_column_starts_ascending_test() ->
    ?assertEqual({2, asc}, sonde_table:toggle_sort(none, 2)),
    ?assertEqual({2, asc}, sonde_table:toggle_sort({1, desc}, 2)).

toggle_sort_same_column_flips_direction_test() ->
    ?assertEqual({1, desc}, sonde_table:toggle_sort({1, asc}, 1)),
    ?assertEqual({1, asc}, sonde_table:toggle_sort({1, desc}, 1)).

apply_sort_none_is_identity_test() ->
    Rows = [[<<"b">>], [<<"a">>]],
    ?assertEqual(Rows, sonde_table:apply_sort(Rows, none)).

apply_sort_orders_ascending_by_column_text_test() ->
    Rows = [[<<"1">>, <<"charlie">>], [<<"2">>, <<"alpha">>], [<<"3">>, <<"bravo">>]],
    Sorted = sonde_table:apply_sort(Rows, {1, asc}),
    ?assertEqual([<<"alpha">>, <<"bravo">>, <<"charlie">>], [Name || [_, Name] <- Sorted]).

apply_sort_orders_descending_test() ->
    Rows = [[<<"alpha">>], [<<"bravo">>], [<<"charlie">>]],
    ?assertEqual(
        [[<<"charlie">>], [<<"bravo">>], [<<"alpha">>]],
        sonde_table:apply_sort(Rows, {0, desc})
    ).

apply_sort_missing_cell_sorts_as_empty_test() ->
    %% A row too short for the sort column sorts as the empty string — first
    %% ascending, last descending — rather than crashing.
    Rows = [[<<"b">>, <<"x">>], [<<"a">>], [<<"c">>, <<"y">>]],
    ?assertEqual(
        [[<<"a">>], [<<"b">>, <<"x">>], [<<"c">>, <<"y">>]], sonde_table:apply_sort(Rows, {1, asc})
    ).

apply_sort_is_stable_test() ->
    %% Rows equal on the sort key keep their prior order.
    Rows = [[<<"k">>, <<"first">>], [<<"k">>, <<"second">>], [<<"k">>, <<"third">>]],
    ?assertEqual(Rows, sonde_table:apply_sort(Rows, {0, asc})).

%%% -- header ----------------------------------------------------------

header_draws_labels_at_their_columns_test() ->
    {B, _} = render(base_cfg([]), 20, 5, sonde_table:new()),
    %% PID label at the first column (x=2), Name label at the second (x=11).
    ?assertEqual($P, ch(B, 2, 0)),
    ?assertEqual($I, ch(B, 3, 0)),
    ?assertEqual($D, ch(B, 4, 0)),
    ?assertEqual($N, ch(B, 11, 0)),
    ?assertEqual($e, ch(B, 14, 0)).

header_fills_full_width_with_its_style_test() ->
    Cfg = (base_cfg([]))#{header_style => #{bg => 5}},
    {B, _} = render(Cfg, 20, 5, sonde_table:new()),
    %% The header bar spans edge to edge, including the gutter and past the labels.
    ?assertMatch(#cell{bg = 5}, cell(B, 0, 0)),
    ?assertMatch(#cell{bg = 5}, cell(B, 19, 0)).

header_present_even_with_no_rows_test() ->
    {B, _} = render(base_cfg([]), 20, 1, sonde_table:new()),
    ?assertEqual($P, ch(B, 2, 0)).

sort_indicator_marks_the_sorted_column_test() ->
    %% Sort on the Name column (index 1): "Name ▼" — label at x=11, arrow two cols
    %% past its end (x=11..14 label, x=15 space, x=16 arrow).
    Cfg = (base_cfg([]))#{sort => {1, desc}},
    {B, _} = render(Cfg, 20, 5, sonde_table:new()),
    ?assertEqual(?DESC, ch(B, 16, 0)),
    %% The unsorted PID column carries no indicator.
    ?assertEqual($\s, ch(B, 6, 0)).

sort_indicator_ascending_glyph_test() ->
    Cfg = (base_cfg([]))#{sort => {0, asc}},
    {B, _} = render(Cfg, 20, 5, sonde_table:new()),
    %% "PID ▲": label x=2..4, space x=5, arrow x=6.
    ?assertEqual(?ASC, ch(B, 6, 0)).

no_sort_draws_no_indicator_test() ->
    {B, _} = render(base_cfg([]), 20, 5, sonde_table:new()),
    ?assertEqual($\s, ch(B, 6, 0)),
    ?assertEqual($\s, ch(B, 16, 0)).

%%% -- columns / cells -------------------------------------------------

columns_are_positioned_by_their_constraints_test() ->
    Rows = [[<<"p0">>, <<"alpha">>]],
    {B, _} = render(base_cfg(Rows), 20, 5, sonde_table:new()),
    %% Data row at y=1 (below the header): PID cell at x=2, Name cell at x=11.
    ?assertEqual($p, ch(B, 2, 1)),
    ?assertEqual($0, ch(B, 3, 1)),
    ?assertEqual($a, ch(B, 11, 1)),
    ?assertEqual($l, ch(B, 12, 1)).

right_aligned_cell_sits_at_the_column_right_edge_test() ->
    Cols = [#{header => <<"N">>, constraint => fill, align => right}],
    Cfg = #{columns => Cols, rows => [[<<"abc">>]]},
    {B, _} = render(Cfg, 10, 3, sonde_table:new()),
    %% One column, no gutter, spans the full width 10; "abc" flush right at x=7..9.
    ?assertEqual($a, ch(B, 7, 1)),
    ?assertEqual($b, ch(B, 8, 1)),
    ?assertEqual($c, ch(B, 9, 1)).

center_aligned_cell_is_centred_in_the_column_test() ->
    Cols = [#{header => <<"N">>, constraint => fill, align => center}],
    Cfg = #{columns => Cols, rows => [[<<"abc">>]]},
    {B, _} = render(Cfg, 9, 3, sonde_table:new()),
    %% "abc" (3 cols) centred in a 9-wide column -> offset 3, at x=3..5.
    ?assertEqual($\s, ch(B, 2, 1)),
    ?assertEqual($a, ch(B, 3, 1)),
    ?assertEqual($c, ch(B, 5, 1)).

cell_is_clipped_to_its_column_test() ->
    %% A PID cell longer than its 8-wide column is truncated and never reaches the
    %% spacer (x=10) or the Name column (x=11).
    Rows = [[<<"abcdefghXY">>, <<"nm">>]],
    {B, _} = render(base_cfg(Rows), 20, 5, sonde_table:new()),
    ?assertEqual($h, ch(B, 9, 1)),
    ?assertEqual($\s, ch(B, 10, 1)),
    ?assertEqual($n, ch(B, 11, 1)).

short_row_leaves_trailing_columns_blank_test() ->
    Rows = [[<<"p0">>]],
    {B, _} = render(base_cfg(Rows), 20, 5, sonde_table:new()),
    ?assertEqual($p, ch(B, 2, 1)),
    %% No Name cell -> the second column is blank.
    ?assertEqual($\s, ch(B, 11, 1)).

extra_cells_beyond_the_columns_are_ignored_test() ->
    %% A row with more cells than columns draws the first two and drops the rest
    %% without crashing.
    Rows = [[<<"p0">>, <<"nm">>, <<"extra">>]],
    {B, _} = render(base_cfg(Rows), 20, 5, sonde_table:new()),
    ?assertEqual($p, ch(B, 2, 1)),
    ?assertEqual($n, ch(B, 11, 1)).

%%% -- selection / rows ------------------------------------------------

selected_row_is_highlighted_across_full_width_test() ->
    Cfg = (base_cfg([[<<"p0">>, <<"nm">>], [<<"p1">>, <<"nm">>]]))#{
        highlight_style => #{bg => 4}
    },
    {B, _} = render(Cfg, 20, 5, sonde_table:select(sonde_table:new(), 0)),
    %% Row 0 (screen y=1): highlight symbol over a full-width bg-4 bar.
    ?assertMatch(#cell{char = $>, bg = 4}, cell(B, 0, 1)),
    ?assertMatch(#cell{char = $\s, bg = 4}, cell(B, 19, 1)),
    %% Row 1 (unselected) carries neither symbol nor bar.
    ?assertEqual(default, (cell(B, 0, 2))#cell.bg).

unselected_rows_have_no_symbol_in_the_gutter_test() ->
    {B, _} = render(
        base_cfg([[<<"p0">>, <<"nm">>]]), 20, 5, sonde_table:select(sonde_table:new(), none)
    ),
    ?assertEqual($\s, ch(B, 0, 1)),
    ?assertEqual($\s, ch(B, 1, 1)).

base_row_style_fills_full_width_test() ->
    Cfg = (base_cfg([[<<"p0">>, <<"nm">>]]))#{row_style => #{bg => 2}},
    {B, _} = render(Cfg, 20, 5, sonde_table:select(sonde_table:new(), none)),
    %% The base background spans the whole unselected row, gutter to right edge.
    ?assertMatch(#cell{bg = 2}, cell(B, 0, 1)),
    ?assertMatch(#cell{bg = 2}, cell(B, 19, 1)).

unstyled_rows_preserve_parent_background_test() ->
    %% An unstyled table drawn over a parent background (a block's fill) must not
    %% erase it in the gutter, the spacer, or past a short cell — only the drawn
    %% glyphs overwrite.
    Parent = sonde_widget:fill(buf(20, 5), rect(0, 0, 20, 5), #{bg => 3}),
    {B, _} = sonde_table:render(
        #{columns => cols(), rows => [[<<"p0">>, <<"nm">>]], highlight_symbol => <<"> ">>},
        rect(0, 0, 20, 5),
        Parent,
        sonde_table:select(sonde_table:new(), none)
    ),
    ?assertMatch(#cell{bg = 3}, cell(B, 0, 1)),
    ?assertMatch(#cell{bg = 3}, cell(B, 10, 1)),
    ?assertMatch(#cell{bg = 3}, cell(B, 19, 1)).

%%% -- scrolling / reconciliation --------------------------------------

render_returns_reconciled_state_test() ->
    %% Height 3 with a header row leaves 2 rows visible; selection 5 pulls the
    %% offset to 5 - 2 + 1 = 4.
    Rows = [[integer_to_binary(N)] || N <- lists:seq(0, 9)],
    Cols = [#{header => <<"N">>, constraint => fill}],
    {_, State} = render(
        #{columns => Cols, rows => Rows}, 10, 3, sonde_table:select(sonde_table:new(), 5)
    ),
    ?assertEqual(5, State#list_state.selected),
    ?assertEqual(4, State#list_state.offset).

draws_the_visible_row_slice_from_the_offset_test() ->
    Rows = [[<<($0 + N)>>] || N <- lists:seq(0, 9)],
    Cols = [#{header => <<"N">>, constraint => fill}],
    {B, _} = sonde_table:render(
        #{columns => Cols, rows => Rows},
        rect(0, 0, 8, 4),
        buf(8, 4),
        #list_state{selected = none, offset = 3}
    ),
    %% Header on y=0; rows 3,4,5 on y=1,2,3.
    ?assertEqual($N, ch(B, 0, 0)),
    ?assertEqual($3, ch(B, 0, 1)),
    ?assertEqual($4, ch(B, 0, 2)),
    ?assertEqual($5, ch(B, 0, 3)).

no_columns_draws_nothing_but_reconciles_test() ->
    B0 = buf(20, 5),
    {B1, State} = sonde_table:render(
        #{columns => [], rows => [[<<"a">>], [<<"b">>]]},
        rect(0, 0, 20, 5),
        B0,
        sonde_table:select(sonde_table:new(), 9)
    ),
    ?assertEqual(B0, B1),
    ?assertEqual(1, State#list_state.selected).

degenerate_area_still_reconciles_state_test() ->
    B0 = buf(20, 5),
    {B1, State} = sonde_table:render(
        base_cfg([[<<"a">>], [<<"b">>], [<<"c">>]]),
        rect(0, 0, 0, 5),
        B0,
        #list_state{selected = 20, offset = 0}
    ),
    ?assertEqual(B0, B1),
    ?assertEqual(2, State#list_state.selected).

%%% -- lazy rows -------------------------------------------------------

lazy_rows_render_like_eager_rows_test() ->
    %% The lazy `{Items, RowFun}' form draws identically to the eager list it
    %% would expand to — same buffer, same reconciled state.
    Cols = [#{header => <<"N">>, constraint => fill}],
    Items = lists:seq(0, 9),
    RowFun = fun(N) -> [integer_to_binary(N)] end,
    Eager = [RowFun(N) || N <- Items],
    St = sonde_table:select(sonde_table:new(), 5),
    {BE, SE} = render(#{columns => Cols, rows => Eager}, 10, 4, St),
    {BL, SL} = render(#{columns => Cols, rows => {Items, RowFun}}, 10, 4, St),
    ?assertEqual(BE, BL),
    ?assertEqual(SE, SL).

lazy_rows_only_build_the_visible_slice_test() ->
    %% The whole point: `RowFun' runs only for the rows on screen, not for every
    %% item. Height 4 leaves 3 visible rows under the header; at offset 100 only
    %% items 100..102 of 1000 are built.
    Cols = [#{header => <<"N">>, constraint => fill}],
    Items = lists:seq(0, 999),
    Self = self(),
    RowFun = fun(N) ->
        Self ! {built, N},
        [integer_to_binary(N)]
    end,
    {_, _} = sonde_table:render(
        #{columns => Cols, rows => {Items, RowFun}},
        rect(0, 0, 10, 4),
        buf(10, 4),
        #list_state{selected = none, offset = 100}
    ),
    ?assertEqual([100, 101, 102], lists:sort(drain_built([]))).

lazy_rows_scroll_extent_uses_item_count_test() ->
    %% The item count fixes the scroll extent even though rows are built lazily:
    %% selecting row 50 of 100 pulls the offset to 50 - 2 + 1 = 49 (2 rows visible
    %% at height 3), and the visible slice is built from items 49 and 50.
    Cols = [#{header => <<"N">>, constraint => fill}],
    Items = lists:seq(0, 99),
    RowFun = fun(N) -> [integer_to_binary(N)] end,
    {B, State} = render(
        #{columns => Cols, rows => {Items, RowFun}},
        10,
        3,
        sonde_table:select(sonde_table:new(), 50)
    ),
    ?assertEqual(50, State#list_state.selected),
    ?assertEqual(49, State#list_state.offset),
    ?assertEqual($4, ch(B, 0, 1)),
    ?assertEqual($5, ch(B, 0, 2)),
    %% And a selection past the end clamps to the last item — the extent comes
    %% from the item list, not a materialized row list.
    {_, Clamped} = render(
        #{columns => Cols, rows => {Items, RowFun}},
        10,
        3,
        sonde_table:select(sonde_table:new(), 200)
    ),
    ?assertEqual(99, Clamped#list_state.selected).

%%% -- misc render -----------------------------------------------------

column_spacing_widens_the_gap_between_columns_test() ->
    %% Three fixed columns of width 2 with spacing 3: column starts at x=0, 5, 10.
    Cols = [
        #{header => <<>>, constraint => {fixed, 2}},
        #{header => <<>>, constraint => {fixed, 2}},
        #{header => <<>>, constraint => {fixed, 2}}
    ],
    Cfg = #{columns => Cols, rows => [[<<"aa">>, <<"bb">>, <<"cc">>]], column_spacing => 3},
    {B, _} = render(Cfg, 12, 3, sonde_table:new()),
    ?assertEqual($a, ch(B, 0, 1)),
    ?assertEqual($b, ch(B, 5, 1)),
    ?assertEqual($c, ch(B, 10, 1)),
    %% The 3-wide gaps between them stay blank.
    ?assertEqual($\s, ch(B, 2, 1)),
    ?assertEqual($\s, ch(B, 7, 1)).
