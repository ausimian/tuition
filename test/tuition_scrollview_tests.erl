-module(tuition_scrollview_tests).

-include_lib("eunit/include/eunit.hrl").
-include("tuition_layout.hrl").
-include("tuition_term.hrl").
-include("tuition_widget.hrl").

%%% -- helpers ---------------------------------------------------------

%% Scrollbar glyphs (mirrored from tuition_scrollbar) for the scrollbar tests.
-define(THUMB, 16#2588).
-define(V_TRACK, 16#2502).
-define(H_TRACK, 16#2500).
%% 中 (U+4E2D) — a two-column CJK glyph, for the wide-glyph edge tests.
-define(WIDE, 16#4E2D).

cell(B, X, Y) -> tuition_render:cell_at(B, X, Y).
ch(B, X, Y) -> (cell(B, X, Y))#cell.char.
rect(X, Y, W, H) -> #rect{x = X, y = Y, w = W, h = H}.

%% A `draw' fun that paints one binary line per content row from the top.
lines(Rows) ->
    fun(Buf) ->
        {_, Out} = lists:foldl(
            fun(Line, {Y, Acc}) -> {Y + 1, tuition_render:put_text(Acc, 0, Y, Line)} end,
            {0, Buf},
            Rows
        ),
        Out
    end.

%% Render `Cfg' with `State' into `Area' over a roomy blank target buffer.
render(Cfg, Area, State) ->
    tuition_scrollview:render(Cfg, Area, tuition_render:new({20, 20}), State).

%% A 4x4 grid of distinct glyphs; cell (x, y) is easy to identify by eye:
%%   0123 / 4567 / 89ab / cdef
grid4() ->
    #{content_size => {4, 4}, draw => lines([<<"0123">>, <<"4567">>, <<"89ab">>, <<"cdef">>])}.

%%% -- state API -------------------------------------------------------

new_starts_at_the_origin_test() ->
    ?assertEqual({0, 0}, tuition_scrollview:offset(tuition_scrollview:new())).

scroll_to_sets_the_offset_test() ->
    ?assertEqual(
        {3, 5},
        tuition_scrollview:offset(tuition_scrollview:scroll_to(tuition_scrollview:new(), 3, 5))
    ).

scroll_by_moves_from_the_current_offset_test() ->
    S0 = tuition_scrollview:scroll_to(tuition_scrollview:new(), 2, 2),
    S1 = tuition_scrollview:scroll_by(S0, 1, -1),
    ?assertEqual({3, 1}, tuition_scrollview:offset(S1)).

scroll_never_goes_negative_test() ->
    S = tuition_scrollview:scroll_by(tuition_scrollview:new(), -5, -5),
    ?assertEqual({0, 0}, tuition_scrollview:offset(S)).

size_is_the_content_rect_test() ->
    ?assertEqual(
        #rect{x = 0, y = 0, w = 12, h = 30}, tuition_scrollview:size(#{content_size => {12, 30}})
    ).

%%% -- windowing -------------------------------------------------------

window_at_origin_shows_the_top_left_slice_test() ->
    {B, _} = render(grid4(), rect(0, 0, 2, 2), tuition_scrollview:new()),
    ?assertEqual($0, ch(B, 0, 0)),
    ?assertEqual($1, ch(B, 1, 0)),
    ?assertEqual($4, ch(B, 0, 1)),
    ?assertEqual($5, ch(B, 1, 1)).

scrolling_pans_the_window_test() ->
    %% Offset {1, 1} over the 4x4 grid shows the 5/6, 9/a slice.
    S = tuition_scrollview:scroll_to(tuition_scrollview:new(), 1, 1),
    {B, _} = render(grid4(), rect(0, 0, 2, 2), S),
    ?assertEqual($5, ch(B, 0, 0)),
    ?assertEqual($6, ch(B, 1, 0)),
    ?assertEqual($9, ch(B, 0, 1)),
    ?assertEqual($a, ch(B, 1, 1)).

vertical_scroll_moves_rows_test() ->
    S = tuition_scrollview:scroll_to(tuition_scrollview:new(), 0, 2),
    {B, _} = render(grid4(), rect(0, 0, 4, 2), S),
    ?assertEqual($8, ch(B, 0, 0)),
    ?assertEqual($c, ch(B, 0, 1)).

horizontal_scroll_moves_columns_test() ->
    S = tuition_scrollview:scroll_to(tuition_scrollview:new(), 2, 0),
    {B, _} = render(grid4(), rect(0, 0, 2, 4), S),
    ?assertEqual($2, ch(B, 0, 0)),
    ?assertEqual($3, ch(B, 1, 0)),
    ?assertEqual($a, ch(B, 0, 2)).

window_is_placed_at_the_area_origin_test() ->
    %% A non-zero area origin blits into that absolute position.
    {B, _} = render(grid4(), rect(5, 3, 2, 2), tuition_scrollview:new()),
    ?assertEqual($0, ch(B, 5, 3)),
    ?assertEqual($5, ch(B, 6, 4)).

%%% -- clamping --------------------------------------------------------

offset_is_clamped_to_the_content_edge_test() ->
    %% Scrolling far past the end lands the window flush against the bottom-right:
    %% max offset over a 4x4 grid in a 2x2 window is {2, 2}.
    S = tuition_scrollview:scroll_to(tuition_scrollview:new(), 99, 99),
    {B, State1} = render(grid4(), rect(0, 0, 2, 2), S),
    ?assertEqual({2, 2}, tuition_scrollview:offset(State1)),
    ?assertEqual($a, ch(B, 0, 0)),
    ?assertEqual($f, ch(B, 1, 1)).

content_smaller_than_the_window_clamps_to_zero_test() ->
    S = tuition_scrollview:scroll_to(tuition_scrollview:new(), 5, 5),
    {B, State1} = render(grid4(), rect(0, 0, 8, 8), S),
    ?assertEqual({0, 0}, tuition_scrollview:offset(State1)),
    ?assertEqual($0, ch(B, 0, 0)),
    %% Beyond the 4x4 content is blank.
    ?assertEqual($\s, ch(B, 5, 5)).

%%% -- wide glyphs at the window edge ----------------------------------

wide_glyph_fully_in_view_shows_both_halves_test() ->
    Cfg = #{content_size => {4, 1}, draw => lines([<<"x", ?WIDE/utf8, "y">>])},
    S = tuition_scrollview:scroll_to(tuition_scrollview:new(), 1, 0),
    {B, _} = render(Cfg, rect(0, 0, 2, 1), S),
    ?assertEqual(?WIDE, ch(B, 0, 0)),
    ?assertEqual(wide_cont, cell(B, 1, 0)).

wide_glyph_clipped_at_left_edge_is_blanked_test() ->
    %% Window starts on the wide glyph's right half — its left half is off-window,
    %% so the orphaned half is drawn as a blank, not a stray continuation cell.
    Cfg = #{content_size => {4, 1}, draw => lines([<<"x", ?WIDE/utf8, "y">>])},
    S = tuition_scrollview:scroll_to(tuition_scrollview:new(), 2, 0),
    {B, _} = render(Cfg, rect(0, 0, 2, 1), S),
    ?assertEqual($\s, ch(B, 0, 0)),
    ?assertEqual($y, ch(B, 1, 0)).

wide_glyph_clipped_at_right_edge_is_blanked_test() ->
    %% The wide glyph's right half would fall outside the 2-wide window, so the
    %% whole glyph is dropped to a blank rather than rendered as a half.
    Cfg = #{content_size => {4, 1}, draw => lines([<<"x", ?WIDE/utf8, "y">>])},
    {B, _} = render(Cfg, rect(0, 0, 2, 1), tuition_scrollview:new()),
    ?assertEqual($x, ch(B, 0, 0)),
    ?assertEqual($\s, ch(B, 1, 0)).

%%% -- pre-built content buffer ----------------------------------------

accepts_a_prebuilt_content_buffer_test() ->
    Content = tuition_render:put_text(tuition_render:new({4, 4}), 0, 0, <<"WXYZ">>),
    {B, _} = render(
        #{content_size => {4, 4}, draw => Content}, rect(0, 0, 2, 1), tuition_scrollview:new()
    ),
    ?assertEqual($W, ch(B, 0, 0)),
    ?assertEqual($X, ch(B, 1, 0)).

%%% -- scrollbars ------------------------------------------------------

vertical_scrollbar_takes_the_last_column_test() ->
    %% Content taller than the 10-row window; the bar sits in column 2 (VW = 3-1)
    %% with its thumb at the top, and columns 0..1 still show content.
    Cfg = #{content_size => {4, 20}, draw => lines([<<"0123">>]), scrollbars => vertical},
    {B, _} = render(Cfg, rect(0, 0, 3, 10), tuition_scrollview:new()),
    ?assertEqual($0, ch(B, 0, 0)),
    ?assertEqual($1, ch(B, 1, 0)),
    ?assertEqual(?THUMB, ch(B, 2, 0)),
    ?assertEqual(?V_TRACK, ch(B, 2, 9)).

horizontal_scrollbar_takes_the_bottom_row_test() ->
    Cfg = #{
        content_size => {20, 4},
        draw => lines([<<"0">>, <<"4">>, <<"8">>]),
        scrollbars => horizontal
    },
    {B, _} = render(Cfg, rect(0, 0, 10, 3), tuition_scrollview:new()),
    ?assertEqual($0, ch(B, 0, 0)),
    ?assertEqual(?THUMB, ch(B, 0, 2)),
    ?assertEqual(?H_TRACK, ch(B, 9, 2)).

both_scrollbars_shrink_the_viewport_on_both_axes_test() ->
    Cfg = #{content_size => {20, 20}, scrollbars => both},
    {B, State1} = render(Cfg, rect(0, 0, 4, 4), tuition_scrollview:new()),
    %% VW = VH = 3: vertical bar down column 3, horizontal bar along row 3.
    ?assertEqual(?THUMB, ch(B, 3, 0)),
    ?assertEqual(?THUMB, ch(B, 0, 3)),
    %% Offsets stay clamped for the reduced viewport (20 content, 3 visible).
    {_, _} = tuition_scrollview:offset(State1).

scrollbar_opts_style_the_bar_test() ->
    Cfg = #{
        content_size => {4, 20},
        scrollbars => vertical,
        scrollbar_opts => #{thumb_style => #{fg => 5}}
    },
    {B, _} = render(Cfg, rect(0, 0, 3, 10), tuition_scrollview:new()),
    ?assertMatch(#cell{char = ?THUMB, fg = 5}, cell(B, 2, 0)).

%%% -- degenerate ------------------------------------------------------

degenerate_area_draws_nothing_but_reconciles_test() ->
    B0 = tuition_render:new({20, 20}),
    S = tuition_scrollview:scroll_to(tuition_scrollview:new(), 99, 99),
    {B1, State1} = tuition_scrollview:render(grid4(), rect(0, 0, 0, 5), B0, S),
    ?assertEqual(B0, B1),
    %% With a zero-width viewport the x offset clamps against a 4-wide content.
    ?assertEqual({4, 0}, tuition_scrollview:offset(State1)).
