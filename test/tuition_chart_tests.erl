-module(tuition_chart_tests).

-include_lib("eunit/include/eunit.hrl").
-include("tuition_layout.hrl").
-include("tuition_term.hrl").

%%% -- helpers ---------------------------------------------------------

%% Box-drawing axis glyphs, mirrored from tuition_chart's private defines.
-define(V_AXIS, 16#2502).
-define(H_AXIS, 16#2500).
-define(CORNER, 16#2514).
%% The legend colour swatch (tuition_chart) and box corners (tuition_block).
-define(SWATCH, 16#25A0).
-define(BOX_TL, 16#250C).
-define(BOX_BL, 16#2514).

buf(W, H) -> tuition_render:new({W, H}).
cell(B, X, Y) -> tuition_render:cell_at(B, X, Y).
ch(B, X, Y) -> (cell(B, X, Y))#cell.char.
rect(X, Y, W, H) -> #rect{x = X, y = Y, w = W, h = H}.

render(Cfg, W, H) ->
    tuition_chart:render(Cfg, rect(0, 0, W, H), buf(W, H)).

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

area_flat_series_fills_to_the_floor_test() ->
    %% A flat series (a zero-height auto range) drawn as `area' still fills each
    %% column from the vertical middle down to the baseline -> dots 3/6/7/8
    %% (0x04|0x20|0x40|0x80 = 0xE4), not a zero-height line at the middle row.
    B = render(#{datasets => [#{data => [5, 5], marker => area}]}, 1, 1),
    ?assertEqual(16#28E4, ch(B, 0, 0)).

area_degenerate_explicit_bounds_still_fill_test() ->
    %% The same mid-to-floor fill under explicit degenerate bounds `{5, 5}' (a
    %% pinned flat area chart) and under inverted bounds `{10, 0}' — the range has no
    %% gradient, but the column still fills rather than collapsing to a middle dot.
    Flat = render(#{datasets => [#{data => [5, 5], marker => area}], y_bounds => {5, 5}}, 1, 1),
    ?assertEqual(16#28E4, ch(Flat, 0, 0)),
    Inv = render(#{datasets => [#{data => [5, 5], marker => area}], y_bounds => {10, 0}}, 1, 1),
    ?assertEqual(16#28E4, ch(Inv, 0, 0)).

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
    ?assertEqual(B0, tuition_chart:render(#{datasets => []}, rect(0, 0, 6, 3), B0)).

degenerate_area_draws_nothing_test() ->
    B0 = buf(10, 3),
    ?assertEqual(
        B0, tuition_chart:render(#{datasets => [#{data => [1, 2, 3]}]}, rect(0, 0, 0, 3), B0)
    ),
    ?assertEqual(
        B0, tuition_chart:render(#{datasets => [#{data => [1, 2, 3]}]}, rect(0, 0, 10, 0), B0)
    ).

axes_on_a_tiny_area_do_not_crash_test() ->
    %% A 1x1 area with axes insets to a zero-width plot: the frame draws what fits
    %% and the plot is skipped, no crash.
    B = render(#{datasets => [#{data => [1]}], axes => true}, 1, 1),
    ?assertEqual({1, 1}, tuition_render:size(B)).

%%% -- y-ticks ---------------------------------------------------------

y_ticks_auto_labels_min_mid_max_test() ->
    %% auto ticks label the top (max), middle and bottom (min) of the bounds,
    %% right-aligned in a gutter as wide as the widest label ("10" -> 2 columns).
    B = render(#{datasets => [], axes => true, y_bounds => {0, 10}, y_ticks => auto}, 8, 5),
    %% gutter width 2 -> axis in column 2, corner at (2,4).
    ?assertEqual(?V_AXIS, ch(B, 2, 0)),
    ?assertEqual(?CORNER, ch(B, 2, 4)),
    %% "10" across the top row, "5" mid, "0" against the axis at the bottom.
    ?assertEqual($1, ch(B, 0, 0)),
    ?assertEqual($0, ch(B, 1, 0)),
    ?assertEqual($5, ch(B, 1, 2)),
    ?assertEqual($0, ch(B, 1, 3)).

y_ticks_explicit_values_test() ->
    %% An explicit list labels exactly those values; the gutter fits the widest
    %% ("100" -> 3 columns, axis in column 3).
    B = render(#{datasets => [], axes => true, y_bounds => {0, 100}, y_ticks => [0, 100]}, 8, 5),
    ?assertEqual(?V_AXIS, ch(B, 3, 0)),
    %% "100" across the top row.
    ?assertEqual($1, ch(B, 0, 0)),
    ?assertEqual($0, ch(B, 1, 0)),
    ?assertEqual($0, ch(B, 2, 0)),
    %% "0" right-aligned against the axis on the bottom plot row.
    ?assertEqual($0, ch(B, 2, 3)).

y_ticks_align_with_the_curve_scale_test() ->
    %% The tick labels use the same live bounds the curve does, so "auto" ticks on
    %% an auto-scaled single series still label its own min/max at top and bottom.
    B = render(#{datasets => [#{data => [3, 7]}], axes => true, y_ticks => auto}, 8, 5),
    ?assertEqual($7, ch(B, 0, 0)),
    ?assertEqual($3, ch(B, 0, 3)).

y_ticks_auto_gutter_fits_a_fractional_windowed_midpoint_test() ->
    %% A narrow window near a large value yields a fractional midpoint ("999.5")
    %% whose label is wider than either integer endpoint. The gutter is sized from
    %% the live labels, so it fits "999.5" in full rather than truncating to "999.".
    Cfg = #{
        datasets => [#{data => lists:seq(0, 1000)}],
        axes => true,
        y_ticks => auto,
        window => 2,
        x_align => right
    },
    B = render(Cfg, 12, 5),
    %% widest label "999.5" -> gutter 5 -> axis in column 5.
    ?assertEqual(?V_AXIS, ch(B, 5, 0)),
    %% the midpoint label, intact across the gutter on its row.
    ?assertEqual($9, ch(B, 0, 2)),
    ?assertEqual($9, ch(B, 1, 2)),
    ?assertEqual($9, ch(B, 2, 2)),
    ?assertEqual($., ch(B, 3, 2)),
    ?assertEqual($5, ch(B, 4, 2)).

y_ticks_auto_bounds_track_the_visible_window_test() ->
    %% With window => auto and a rising series, the tick gutter shrinks the plot so
    %% older (smaller) samples scroll off. The auto bounds — and thus the bottom
    %% tick — must reflect the *visible* window's minimum, not a hidden older sample
    %% (here the visible min is 95, whereas the full history starts at 0).
    B = render(#{datasets => [#{data => lists:seq(0, 100)}], axes => true, y_ticks => auto}, 8, 5),
    %% gutter fits "97.5" -> width 4 -> axis in column 4.
    ?assertEqual(?V_AXIS, ch(B, 4, 0)),
    %% top tick the visible max "100"...
    ?assertEqual($1, ch(B, 1, 0)),
    ?assertEqual($0, ch(B, 3, 0)),
    %% ...bottom tick the visible min "95", not the hidden 0.
    ?assertEqual($9, ch(B, 2, 3)),
    ?assertEqual($5, ch(B, 3, 3)).

y_ticks_need_axes_test() ->
    %% Ticks are axis chrome — without the frame they reserve no gutter and the
    %% plot uses the whole area (a lone max point at the top-left cell).
    B = render(#{datasets => [#{data => [10]}], y_bounds => {0, 10}, y_ticks => auto}, 1, 1),
    ?assertEqual(16#2801, ch(B, 0, 0)).

%%% -- x-labels --------------------------------------------------------

x_labels_span_first_left_last_right_test() ->
    B = render(#{datasets => [], axes => true, x_labels => [<<"old">>, <<"new">>]}, 10, 3),
    %% one row reserved below the axis (row 2); "old" flush-left from the plot's
    %% left edge (col 1), "new" flush-right against the right edge (cols 7-9).
    ?assertEqual($o, ch(B, 1, 2)),
    ?assertEqual($l, ch(B, 2, 2)),
    ?assertEqual($d, ch(B, 3, 2)),
    ?assertEqual($n, ch(B, 7, 2)),
    ?assertEqual($e, ch(B, 8, 2)),
    ?assertEqual($w, ch(B, 9, 2)).

%%% -- titles ----------------------------------------------------------

y_title_written_vertically_test() ->
    %% far-left column, one grapheme per row, centred over the 5-row plot; the
    %% axis sits one column right of it.
    B = render(#{datasets => [], axes => true, y_title => <<"ms">>}, 6, 6),
    ?assertEqual($m, ch(B, 0, 1)),
    ?assertEqual($s, ch(B, 0, 2)),
    ?assertEqual(?V_AXIS, ch(B, 1, 0)).

x_title_centered_test() ->
    %% centred across the 11-wide plot, in the reserved row below the axis.
    B = render(#{datasets => [], axes => true, x_title => <<"time">>}, 12, 3),
    ?assertEqual($t, ch(B, 4, 2)),
    ?assertEqual($i, ch(B, 5, 2)),
    ?assertEqual($m, ch(B, 6, 2)),
    ?assertEqual($e, ch(B, 7, 2)).

x_labels_and_title_stack_on_separate_rows_test() ->
    %% axis row (1), then x-labels row (2), then x-title row (3) — no overlap.
    B = render(#{datasets => [], axes => true, x_labels => [<<"L">>], x_title => <<"T">>}, 6, 4),
    ?assertEqual(?H_AXIS, ch(B, 2, 1)),
    ?assertEqual($L, ch(B, 1, 2)),
    ?assertEqual($T, ch(B, 3, 3)).

%%% -- legend ----------------------------------------------------------

legend_lists_named_datasets_test() ->
    Cfg = #{
        datasets => [
            #{data => [], color => 2, name => <<"cpu">>},
            #{data => [], color => 4, name => <<"mem">>}
        ],
        legend => #{position => top_left}
    },
    B = render(Cfg, 20, 8),
    %% a bordered box in the top-left; one "■ name" row per dataset, the swatch in
    %% the dataset's colour and the name beside it.
    ?assertEqual(?BOX_TL, ch(B, 0, 0)),
    ?assertMatch(#cell{char = ?SWATCH, fg = 2}, cell(B, 1, 1)),
    ?assertEqual($c, ch(B, 3, 1)),
    ?assertEqual($p, ch(B, 4, 1)),
    ?assertEqual($u, ch(B, 5, 1)),
    ?assertMatch(#cell{char = ?SWATCH, fg = 4}, cell(B, 1, 2)),
    ?assertEqual($m, ch(B, 3, 2)).

legend_omits_unnamed_datasets_test() ->
    %% Only named datasets appear; an unnamed one is skipped, so the box is one
    %% row (3 rows with borders): the sole name on row 1, bottom-left corner row 2.
    Cfg = #{
        datasets => [#{data => [], name => <<"x">>}, #{data => []}],
        legend => #{position => top_left}
    },
    B = render(Cfg, 12, 6),
    ?assertEqual($x, ch(B, 3, 1)),
    ?assertEqual(?BOX_BL, ch(B, 0, 2)).

legend_clears_cells_beneath_it_test() ->
    %% The box resets the plot under it (via tuition_clear) so curves do not show
    %% through: the gap between swatch and name is a blank space, not a dot.
    Cfg = #{
        datasets => [#{data => lists:duplicate(40, 10), marker => area, name => <<"a">>}],
        y_bounds => {0, 10},
        legend => #{position => top_left}
    },
    B = render(Cfg, 20, 8),
    ?assertEqual($\s, ch(B, 2, 1)).

legend_position_bottom_right_test() ->
    %% A 7x3 box pinned to the bottom-right corner: top-left corner at (13,5).
    Cfg = #{
        datasets => [#{data => [], color => 3, name => <<"cpu">>}],
        legend => #{position => bottom_right}
    },
    B = render(Cfg, 20, 8),
    ?assertEqual(?BOX_TL, ch(B, 13, 5)),
    ?assertMatch(#cell{char = ?SWATCH, fg = 3}, cell(B, 14, 6)).

legend_style_backs_the_box_test() ->
    %% `style` colours and backs the box: the swatch keeps its dataset fg but
    %% picks up the box background, and the name cell carries it too.
    Cfg = #{
        datasets => [#{data => [], color => 2, name => <<"a">>}],
        legend => #{position => top_left, style => #{bg => 7}}
    },
    B = render(Cfg, 12, 6),
    ?assertMatch(#cell{char = ?SWATCH, fg = 2, bg = 7}, cell(B, 1, 1)),
    ?assertMatch(#cell{char = $a, bg = 7}, cell(B, 3, 1)).

legend_floats_within_the_plot_area_with_axes_test() ->
    %% With axes the legend sits inside the inset plot (right of the y-axis), not
    %% over the frame: a top-left legend's border starts at the plot origin.
    Cfg = #{
        datasets => [#{data => [], name => <<"a">>}],
        axes => true,
        legend => #{position => top_left}
    },
    B = render(Cfg, 12, 6),
    ?assertEqual(?V_AXIS, ch(B, 0, 0)),
    ?assertEqual(?BOX_TL, ch(B, 1, 0)).

legend_off_by_default_test() ->
    %% No legend key -> no box; a named dataset alone draws only its curve.
    B = render(#{datasets => [#{data => [], name => <<"a">>}]}, 12, 6),
    ?assertEqual(buf(12, 6), B).

%%% -- composition -----------------------------------------------------

all_labelling_composes_test() ->
    %% Every opt-in feature at once renders without crashing and keeps the buffer
    %% size; the y-title still lands vertically in column 0.
    Cfg = #{
        datasets => [#{data => [1, 5, 9], color => 2, name => <<"q">>}],
        axes => true,
        y_bounds => {0, 10},
        y_ticks => auto,
        x_labels => [<<"t0">>, <<"t9">>],
        y_title => <<"v">>,
        x_title => <<"time">>,
        legend => #{position => top_right}
    },
    B = render(Cfg, 30, 12),
    ?assertEqual({30, 12}, tuition_render:size(B)),
    ?assertEqual($v, ch(B, 0, 4)).

%%% -- narrow-area hardening -------------------------------------------

axes_with_y_title_on_a_one_column_area_do_not_crash_test() ->
    %% The y-title's gutter makes the left inset as wide as the whole pane, so the
    %% x-axis column range is empty — the frame must draw what fits, not crash.
    B = render(#{datasets => [], axes => true, y_title => <<"v">>}, 1, 3),
    ?assertEqual({1, 3}, tuition_render:size(B)).

axes_with_wide_tick_gutter_on_a_narrow_area_do_not_crash_test() ->
    %% A 3-wide tick gutter ("100") on a 2-column area likewise inverts the axis
    %% range; it degrades rather than crashing.
    B = render(#{datasets => [], axes => true, y_bounds => {0, 100}, y_ticks => auto}, 2, 3),
    ?assertEqual({2, 3}, tuition_render:size(B)).

y_title_wide_cluster_does_not_overwrite_the_axis_test() ->
    %% A two-column cluster (CJK) is dropped rather than spilling its continuation
    %% onto the y-axis in the next column: the axis glyph survives on the title row
    %% and the title column stays blank there.
    B = render(#{datasets => [], axes => true, y_title => <<"中"/utf8>>}, 4, 4),
    ?assertEqual(?V_AXIS, ch(B, 1, 1)),
    ?assertEqual($\s, ch(B, 0, 1)).
