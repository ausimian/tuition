-module(sonde_chart_tests).

-include_lib("eunit/include/eunit.hrl").
-include("sonde_layout.hrl").
-include("sonde_term.hrl").

%%% -- helpers ---------------------------------------------------------

%% Box-drawing axis glyphs, mirrored from sonde_chart's private defines.
-define(V_AXIS, 16#2502).
-define(H_AXIS, 16#2500).
-define(CORNER, 16#2514).

buf(W, H) -> sonde_render:new({W, H}).
cell(B, X, Y) -> sonde_render:cell_at(B, X, Y).
ch(B, X, Y) -> (cell(B, X, Y))#cell.char.
rect(X, Y, W, H) -> #rect{x = X, y = Y, w = W, h = H}.

render(Cfg, W, H) ->
    sonde_chart:render(Cfg, rect(0, 0, W, H), buf(W, H)).

%%% -- vertical scaling ------------------------------------------------

max_value_maps_to_the_top_row_test() ->
    %% One point at the top of the bounds -> the cell's top-left dot (0x01).
    B = render(#{datasets => [#{data => [10]}], y_bounds => {0, 10}}, 1, 1),
    ?assertEqual(16#2801, ch(B, 0, 0)).

min_value_maps_to_the_bottom_row_test() ->
    %% One point at the bottom -> the cell's dot 7 (0x40), the lowest left dot.
    B = render(#{datasets => [#{data => [0]}], y_bounds => {0, 10}}, 1, 1),
    ?assertEqual(16#2840, ch(B, 0, 0)).

flat_series_is_drawn_along_the_middle_test() ->
    %% All-equal data (a zero-height auto range) plots on the vertical middle row,
    %% not the top or bottom: row 2 of 4 -> dots 3 and 6 (0x04|0x20 = 0x24).
    B = render(#{datasets => [#{data => [5, 5, 5, 5]}]}, 1, 1),
    ?assertEqual(16#2824, ch(B, 0, 0)).

%%% -- windowing -------------------------------------------------------

window_shows_the_newest_samples_test() ->
    %% Five samples into a 2-sub-pixel-wide plot -> the newest two, both at max ->
    %% the top row of the single cell (0x01|0x08 = 0x09). The leading zeros are
    %% scrolled off, so nothing is drawn on the bottom row.
    B = render(#{datasets => [#{data => [0, 0, 0, 10, 10]}], y_bounds => {0, 10}}, 1, 1),
    ?assertEqual(16#2809, ch(B, 0, 0)).

%%% -- window / x_align ------------------------------------------------

left_align_grows_from_the_left_edge_test() ->
    %% Default: one sample sits at the left edge (cell 0), right cells blank.
    B = render(#{datasets => [#{data => [10], marker => scatter}], y_bounds => {0, 10}}, 3, 1),
    ?assertEqual(16#2801, ch(B, 0, 0)),
    ?assertEqual($\s, ch(B, 2, 0)).

right_align_pins_the_newest_to_the_right_edge_test() ->
    %% x_align => right: the same lone sample is pinned to the rightmost sub-pixel
    %% (cell 2's right dot, 0x08), and the left cells stay blank.
    Cfg = #{
        datasets => [#{data => [10], marker => scatter}], y_bounds => {0, 10}, x_align => right
    },
    B = render(Cfg, 3, 1),
    ?assertEqual(16#2808, ch(B, 2, 0)),
    ?assertEqual($\s, ch(B, 0, 0)),
    ?assertEqual($\s, ch(B, 1, 0)).

window_limits_to_the_newest_n_samples_test() ->
    %% window => 2 shows only the newest two samples (both 0 -> bottom row of
    %% cell 0, 0x40|0x80 = 0xC0); the older 10s are dropped, so cells 1+ are blank.
    Cfg = #{datasets => [#{data => [10, 10, 10, 10, 0, 0]}], y_bounds => {0, 10}, window => 2},
    B = render(Cfg, 4, 1),
    ?assertEqual(16#28C0, ch(B, 0, 0)),
    ?assertEqual($\s, ch(B, 1, 0)),
    ?assertEqual($\s, ch(B, 2, 0)).

window_clamps_to_the_width_test() ->
    %% A window wider than the plot can draw is capped at the sub-pixel width, so
    %% window => 1000 on a 1-cell plot behaves like auto: the newest two samples.
    Cfg = #{datasets => [#{data => [0, 0, 0, 10, 10]}], y_bounds => {0, 10}, window => 1000},
    B = render(Cfg, 1, 1),
    ?assertEqual(16#2809, ch(B, 0, 0)).

fixed_window_right_aligned_is_the_trend_look_test() ->
    %% The Beskope-style combo: a fixed window pinned right. The newest two of four
    %% samples ([0,10]) land in the rightmost cell (bottom-left + top-right dots,
    %% 0x40|0x08 = 0x48), the rest of the width blank.
    Cfg = #{
        datasets => [#{data => [0, 0, 0, 10], marker => scatter}],
        y_bounds => {0, 10},
        window => 2,
        x_align => right
    },
    B = render(Cfg, 4, 1),
    ?assertEqual(16#2848, ch(B, 3, 0)),
    ?assertEqual($\s, ch(B, 0, 0)),
    ?assertEqual($\s, ch(B, 1, 0)).

%%% -- bounds ----------------------------------------------------------

value_above_explicit_max_clamps_to_the_top_test() ->
    B = render(#{datasets => [#{data => [100], marker => scatter}], y_bounds => {0, 10}}, 1, 1),
    ?assertEqual(16#2801, ch(B, 0, 0)).

value_below_explicit_min_clamps_to_the_bottom_test() ->
    B = render(#{datasets => [#{data => [-5], marker => scatter}], y_bounds => {0, 10}}, 1, 1),
    ?assertEqual(16#2840, ch(B, 0, 0)).

auto_bounds_span_all_datasets_test() ->
    %% Two single-point series, min in one and max in the other: auto bounds
    %% {0,10} put the low point on the bottom dot and the high on the top,
    %% merged in the shared cell (0x40|0x01 = 0x41).
    Cfg = #{
        datasets => [
            #{data => [0], color => 2},
            #{data => [10], color => 4}
        ],
        y_bounds => auto
    },
    B = render(Cfg, 1, 1),
    ?assertMatch(#cell{char = 16#2841, fg = 4}, cell(B, 0, 0)).

default_colour_series_wins_a_shared_cell_test() ->
    %% Last dataset wins the shared cell's colour — including a default-coloured
    %% one: an earlier `color => 2' series is overridden back to the default
    %% foreground where the later, colourless series overlaps it.
    Cfg = #{
        datasets => [
            #{data => [10], color => 2},
            #{data => [0]}
        ],
        y_bounds => {0, 10}
    },
    B = render(Cfg, 1, 1),
    ?assertMatch(#cell{char = 16#2841, fg = default}, cell(B, 0, 0)).

%%% -- markers ---------------------------------------------------------

scatter_plots_only_the_sample_points_test() ->
    %% Two samples (bottom then top) as scatter -> exactly their two dots
    %% (0x40|0x08 = 0x48), no connecting staircase.
    B = render(#{datasets => [#{data => [0, 10], marker => scatter}], y_bounds => {0, 10}}, 1, 1),
    ?assertEqual(16#2848, ch(B, 0, 0)).

line_connects_consecutive_samples_test() ->
    %% The same two samples as a line fill the Bresenham steps between them
    %% (0x40|0x04|0x10|0x08 = 0x5C) — more dots than the two endpoints alone.
    B = render(#{datasets => [#{data => [0, 10], marker => line}], y_bounds => {0, 10}}, 1, 1),
    ?assertEqual(16#285C, ch(B, 0, 0)).

line_is_the_default_marker_test() ->
    B = render(#{datasets => [#{data => [0, 10]}], y_bounds => {0, 10}}, 1, 1),
    ?assertEqual(16#285C, ch(B, 0, 0)).

area_fills_a_full_column_test() ->
    %% Two samples at the top, area-filled -> both sub-pixel columns lit top to
    %% bottom -> the whole cell (0xFF).
    B = render(#{datasets => [#{data => [10, 10], marker => area}], y_bounds => {0, 10}}, 1, 1),
    ?assertEqual(16#28FF, ch(B, 0, 0)).

area_fill_stops_at_the_value_test() ->
    %% Mid-height samples fill only from their row down: the bottom two rows of
    %% both columns (dots 3/6/7/8 = 0x04|0x20|0x40|0x80 = 0xE4), top rows blank.
    B = render(#{datasets => [#{data => [5, 5], marker => area}], y_bounds => {0, 10}}, 1, 1),
    ?assertEqual(16#28E4, ch(B, 0, 0)).

area_at_the_baseline_lights_only_the_floor_test() ->
    %% Samples at the axis minimum fill just the bottom row (0x40|0x80 = 0xC0).
    B = render(#{datasets => [#{data => [0, 0], marker => area}], y_bounds => {0, 10}}, 1, 1),
    ?assertEqual(16#28C0, ch(B, 0, 0)).

area_fills_down_across_cell_rows_test() ->
    %% A full-height sample fills its column to the baseline across both cell rows
    %% of a 2-row plot -> the left column lit (0x47) in each stacked cell.
    B = render(#{datasets => [#{data => [10], marker => area}], y_bounds => {0, 10}}, 1, 2),
    ?assertEqual(16#2847, ch(B, 0, 0)),
    ?assertEqual(16#2847, ch(B, 0, 1)).

%%% -- colour ----------------------------------------------------------

series_colour_is_applied_test() ->
    B = render(#{datasets => [#{data => [5], color => 3}]}, 1, 1),
    ?assertMatch(#cell{fg = 3}, cell(B, 0, 0)).

%%% -- axes ------------------------------------------------------------

axes_draw_the_frame_test() ->
    %% Left column is the y-axis, bottom row the x-axis, meeting at a corner.
    B = render(#{datasets => [], axes => true}, 4, 3),
    ?assertEqual(?V_AXIS, ch(B, 0, 0)),
    ?assertEqual(?V_AXIS, ch(B, 0, 1)),
    ?assertEqual(?CORNER, ch(B, 0, 2)),
    ?assertEqual(?H_AXIS, ch(B, 1, 2)),
    ?assertEqual(?H_AXIS, ch(B, 3, 2)).

axes_inset_the_plot_test() ->
    %% Even a full-height series never overwrites the y-axis column: the plot is
    %% confined to the inset rect right of it.
    B = render(
        #{datasets => [#{data => [10, 10, 10, 10, 10, 10]}], y_bounds => {0, 10}, axes => true},
        4,
        3
    ),
    ?assertEqual(?V_AXIS, ch(B, 0, 0)).

no_axes_leaves_the_first_column_for_plotting_test() ->
    %% Without axes, plotting uses the whole area including column 0.
    B = render(#{datasets => [#{data => [10]}], y_bounds => {0, 10}}, 1, 1),
    ?assertEqual(16#2801, ch(B, 0, 0)).

%%% -- degenerate ------------------------------------------------------

empty_datasets_draw_nothing_test() ->
    B0 = buf(6, 3),
    ?assertEqual(B0, sonde_chart:render(#{datasets => []}, rect(0, 0, 6, 3), B0)).

degenerate_area_draws_nothing_test() ->
    B0 = buf(10, 3),
    ?assertEqual(
        B0, sonde_chart:render(#{datasets => [#{data => [1, 2, 3]}]}, rect(0, 0, 0, 3), B0)
    ),
    ?assertEqual(
        B0, sonde_chart:render(#{datasets => [#{data => [1, 2, 3]}]}, rect(0, 0, 10, 0), B0)
    ).

axes_on_a_tiny_area_do_not_crash_test() ->
    %% A 1x1 area with axes insets to a zero-width plot: the frame draws what fits
    %% and the plot is skipped, no crash.
    B = render(#{datasets => [#{data => [1]}], axes => true}, 1, 1),
    ?assertEqual({1, 1}, sonde_render:size(B)).
