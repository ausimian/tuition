-module(sonde_sparkline_tests).

-include_lib("eunit/include/eunit.hrl").
-include("sonde_layout.hrl").
-include("sonde_term.hrl").

%%% -- helpers ---------------------------------------------------------

%% Vertical eighth-block glyphs, mirrored from sonde_sparkline's private defines.
-define(FULL, 16#2588).
-define(E1, 16#2581).
-define(E2, 16#2582).
-define(E3, 16#2583).
-define(E4, 16#2584).
-define(E5, 16#2585).

buf(W, H) -> sonde_render:new({W, H}).
cell(B, X, Y) -> sonde_render:cell_at(B, X, Y).
ch(B, X, Y) -> (cell(B, X, Y))#cell.char.
rect(X, Y, W, H) -> #rect{x = X, y = Y, w = W, h = H}.

render(Cfg, W, H) ->
    sonde_sparkline:render(Cfg, rect(0, 0, W, H), buf(W, H)).

%%% -- bar height ------------------------------------------------------

single_full_value_fills_the_cell_test() ->
    B = render(#{data => [8], max => 8}, 1, 1),
    ?assertEqual(?FULL, ch(B, 0, 0)).

single_half_value_is_a_half_cell_test() ->
    %% 4 of 8 -> four eighths -> the half block.
    B = render(#{data => [4], max => 8}, 1, 1),
    ?assertEqual(?E4, ch(B, 0, 0)).

value_scales_across_the_full_height_test() ->
    B = render(#{data => [8], max => 8}, 1, 2),
    ?assertEqual(?FULL, ch(B, 0, 0)),
    ?assertEqual(?FULL, ch(B, 0, 1)).

partial_top_row_over_a_full_bottom_row_test() ->
    %% 12 of 16 across 2 rows -> 12 eighths: a full bottom row (8) plus a half top
    %% row (12 - 8 = 4).
    B = render(#{data => [12], max => 16}, 1, 2),
    ?assertEqual(?E4, ch(B, 0, 0)),
    ?assertEqual(?FULL, ch(B, 0, 1)).

bar_grows_from_the_bottom_test() ->
    %% One-eighth of a 3-row strip fills only the bottom row.
    B = render(#{data => [1], max => 3}, 1, 3),
    ?assertEqual($\s, ch(B, 0, 0)),
    ?assertEqual($\s, ch(B, 0, 1)),
    ?assertEqual(?FULL, ch(B, 0, 2)).

%%% -- columns ---------------------------------------------------------

bars_laid_left_to_right_test() ->
    B = render(#{data => [8, 4], max => 8}, 2, 1),
    ?assertEqual(?FULL, ch(B, 0, 0)),
    ?assertEqual(?E4, ch(B, 1, 0)).

window_shows_the_last_points_test() ->
    %% Five points into a 3-wide strip -> the last three, [3, 4, 5], left to right.
    B = render(#{data => [1, 2, 3, 4, 5], max => 8}, 3, 1),
    ?assertEqual(?E3, ch(B, 0, 0)),
    ?assertEqual(?E4, ch(B, 1, 0)),
    ?assertEqual(?E5, ch(B, 2, 0)).

short_history_leaves_the_right_columns_blank_test() ->
    B = render(#{data => [8, 8], max => 8}, 5, 1),
    ?assertEqual(?FULL, ch(B, 0, 0)),
    ?assertEqual(?FULL, ch(B, 1, 0)),
    ?assertEqual($\s, ch(B, 2, 0)),
    ?assertEqual($\s, ch(B, 4, 0)).

%%% -- scaling ---------------------------------------------------------

auto_max_uses_the_tallest_visible_bar_test() ->
    %% No max given: the tallest point (4) maps to full height.
    B = render(#{data => [2, 4]}, 2, 1),
    ?assertEqual(?E4, ch(B, 0, 0)),
    ?assertEqual(?FULL, ch(B, 1, 0)).

value_above_max_clamps_to_full_test() ->
    B = render(#{data => [100], max => 8}, 1, 1),
    ?assertEqual(?FULL, ch(B, 0, 0)).

auto_max_uses_only_the_visible_window_test() ->
    %% A tall point scrolled out of the window does not shrink the visible bars.
    B = render(#{data => [100, 4], max => auto}, 1, 1),
    ?assertEqual(?FULL, ch(B, 0, 0)).

%%% -- empty / edge ----------------------------------------------------

empty_data_draws_nothing_test() ->
    B0 = buf(5, 2),
    ?assertEqual(B0, sonde_sparkline:render(#{data => []}, rect(0, 0, 5, 2), B0)).

zero_value_draws_no_bar_test() ->
    B = render(#{data => [0], max => 8}, 1, 2),
    ?assertEqual($\s, ch(B, 0, 0)),
    ?assertEqual($\s, ch(B, 0, 1)).

negative_value_is_treated_as_zero_test() ->
    B = render(#{data => [-5], max => 8}, 1, 1),
    ?assertEqual($\s, ch(B, 0, 0)).

all_zero_auto_max_is_safe_test() ->
    %% auto max must not divide by zero on an all-zero (or empty) window.
    B = render(#{data => [0, 0], max => auto}, 2, 1),
    ?assertEqual($\s, ch(B, 0, 0)),
    ?assertEqual($\s, ch(B, 1, 0)).

%%% -- styling / degenerate --------------------------------------------

style_colours_the_bars_test() ->
    B = render(#{data => [8], max => 8, style => #{fg => 5}}, 1, 1),
    ?assertMatch(#cell{char = ?FULL, fg = 5}, cell(B, 0, 0)).

degenerate_area_draws_nothing_test() ->
    B0 = buf(10, 3),
    ?assertEqual(B0, sonde_sparkline:render(#{data => [1, 2, 3]}, rect(0, 0, 0, 3), B0)),
    ?assertEqual(B0, sonde_sparkline:render(#{data => [1, 2, 3]}, rect(0, 0, 10, 0), B0)).
