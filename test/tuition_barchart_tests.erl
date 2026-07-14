-module(tuition_barchart_tests).

-include_lib("eunit/include/eunit.hrl").
-include("tuition_layout.hrl").
-include("tuition_term.hrl").

%%% -- helpers ---------------------------------------------------------

%% Vertical eighth-block glyphs (fill from the bottom), mirrored from
%% tuition_barchart's private defines.
-define(FULL, 16#2588).
-define(E4, 16#2584).
%% Horizontal eighth-block glyphs (fill from the left).
-define(H3, 16#258D).
-define(H4, 16#258C).

buf(W, H) -> tuition_render:new({W, H}).
cell(B, X, Y) -> tuition_render:cell_at(B, X, Y).
ch(B, X, Y) -> (cell(B, X, Y))#cell.char.
rect(X, Y, W, H) -> #rect{x = X, y = Y, w = W, h = H}.

render(Cfg, W, H) ->
    tuition_barchart:render(Cfg, rect(0, 0, W, H), buf(W, H)).

%%% -- vertical geometry -----------------------------------------------
%%% (value text suppressed with `text_value => none' so it does not punch
%%% through the bar cells under test.)

vertical_full_value_fills_the_cell_test() ->
    B = render(#{bars => [#{value => 8, text_value => none}], max => 8}, 1, 1),
    ?assertEqual(?FULL, ch(B, 0, 0)).

vertical_half_value_is_a_half_cell_test() ->
    B = render(#{bars => [#{value => 4, text_value => none}], max => 8}, 1, 1),
    ?assertEqual(?E4, ch(B, 0, 0)).

vertical_partial_top_over_a_full_bottom_test() ->
    %% 12 of 16 across 2 rows -> a full bottom row plus a half top row.
    B = render(#{bars => [#{value => 12, text_value => none}], max => 16}, 1, 2),
    ?assertEqual(?E4, ch(B, 0, 0)),
    ?assertEqual(?FULL, ch(B, 0, 1)).

vertical_bar_grows_from_the_bottom_test() ->
    %% One-eighth-of-full over 3 rows fills only the bottom row.
    B = render(#{bars => [#{value => 1, text_value => none}], max => 3}, 1, 3),
    ?assertEqual($\s, ch(B, 0, 0)),
    ?assertEqual($\s, ch(B, 0, 1)),
    ?assertEqual(?FULL, ch(B, 0, 2)).

vertical_bar_width_spans_columns_test() ->
    B = render(#{bars => [#{value => 8, text_value => none}], max => 8, bar_width => 3}, 3, 1),
    ?assertEqual(?FULL, ch(B, 0, 0)),
    ?assertEqual(?FULL, ch(B, 1, 0)),
    ?assertEqual(?FULL, ch(B, 2, 0)).

%%% -- vertical columns / gap ------------------------------------------

vertical_bars_laid_left_to_right_with_gap_test() ->
    %% Two 1-wide bars with a 1-column gap: bar, gap, bar.
    Cfg = #{
        bars => [#{value => 8, text_value => none}, #{value => 4, text_value => none}],
        max => 8,
        bar_gap => 1
    },
    B = render(Cfg, 3, 1),
    ?assertEqual(?FULL, ch(B, 0, 0)),
    ?assertEqual($\s, ch(B, 1, 0)),
    ?assertEqual(?E4, ch(B, 2, 0)).

vertical_bar_past_the_edge_is_clipped_test() ->
    %% A third bar would start at column 4, off a 3-wide area — it draws nothing.
    Cfg = #{
        bars => [
            #{value => 8, text_value => none},
            #{value => 8, text_value => none},
            #{value => 8, text_value => none}
        ],
        max => 8,
        bar_gap => 1
    },
    B0 = buf(3, 1),
    B = tuition_barchart:render(Cfg, rect(0, 0, 3, 1), B0),
    ?assertEqual(?FULL, ch(B, 0, 0)),
    ?assertEqual(?FULL, ch(B, 2, 0)).

%%% -- vertical value / label ------------------------------------------

vertical_value_printed_at_the_base_test() ->
    %% A 3-wide full bar over 2 rows: the value "8" sits centred on the base row,
    %% punched through the bar; the rest of the bar stays full.
    B = render(#{bars => [#{value => 8}], max => 8, bar_width => 3}, 3, 2),
    ?assertEqual(?FULL, ch(B, 0, 0)),
    ?assertEqual(?FULL, ch(B, 1, 0)),
    ?assertEqual(?FULL, ch(B, 0, 1)),
    ?assertEqual($8, ch(B, 1, 1)),
    ?assertEqual(?FULL, ch(B, 2, 1)).

vertical_label_reserves_the_bottom_row_test() ->
    %% With a label, the bottom row is the label row and the bar fills the row above.
    B = render(#{bars => [#{value => 8, label => <<"a">>, text_value => none}], max => 8}, 1, 2),
    ?assertEqual(?FULL, ch(B, 0, 0)),
    ?assertEqual($a, ch(B, 0, 1)).

vertical_no_label_uses_the_whole_height_test() ->
    %% No bar carries a label, so no row is reserved: the bar fills both rows.
    B = render(#{bars => [#{value => 8, text_value => none}], max => 8}, 1, 2),
    ?assertEqual(?FULL, ch(B, 0, 0)),
    ?assertEqual(?FULL, ch(B, 0, 1)).

vertical_label_centred_under_wide_bar_test() ->
    B = render(
        #{bars => [#{value => 8, label => <<"a">>, text_value => none}], max => 8, bar_width => 3},
        3,
        2
    ),
    ?assertEqual($a, ch(B, 1, 1)).

%%% -- vertical scaling ------------------------------------------------

vertical_auto_max_uses_the_largest_value_test() ->
    %% No max: the largest value (4) maps to full height, shared by both bars.
    Cfg = #{
        bars => [#{value => 2, text_value => none}, #{value => 4, text_value => none}],
        bar_gap => 0
    },
    B = render(Cfg, 2, 1),
    ?assertEqual(?E4, ch(B, 0, 0)),
    ?assertEqual(?FULL, ch(B, 1, 0)).

vertical_value_above_max_clamps_to_full_test() ->
    B = render(#{bars => [#{value => 100, text_value => none}], max => 8}, 1, 1),
    ?assertEqual(?FULL, ch(B, 0, 0)).

vertical_negative_value_is_treated_as_zero_test() ->
    B = render(#{bars => [#{value => -5, text_value => none}], max => 8}, 1, 1),
    ?assertEqual($\s, ch(B, 0, 0)).

vertical_all_zero_auto_max_is_safe_test() ->
    Cfg = #{
        bars => [#{value => 0, text_value => none}, #{value => 0, text_value => none}], bar_gap => 0
    },
    B = render(Cfg, 2, 1),
    ?assertEqual($\s, ch(B, 0, 0)),
    ?assertEqual($\s, ch(B, 1, 0)).

fractional_max_below_one_is_honoured_test() ->
    %% An explicit fractional ceiling fills the bar rather than clamping to max 1.
    B = render(#{bars => [#{value => 0.5, text_value => none}], max => 0.5}, 1, 1),
    ?assertEqual(?FULL, ch(B, 0, 0)).

fractional_auto_max_uses_the_largest_value_test() ->
    %% Ratios in [0, 1] with no explicit max: the largest (0.5) maps to full height.
    Cfg = #{
        bars => [#{value => 0.25, text_value => none}, #{value => 0.5, text_value => none}],
        bar_gap => 0
    },
    B = render(Cfg, 2, 1),
    ?assertEqual(?E4, ch(B, 0, 0)),
    ?assertEqual(?FULL, ch(B, 1, 0)).

%%% -- direction default -----------------------------------------------

default_direction_is_vertical_test() ->
    %% Vertical fills both rows of a 1x2 area; horizontal (1 row thick) would leave
    %% the second row blank.
    B = render(#{bars => [#{value => 8, text_value => none}], max => 8}, 1, 2),
    ?assertEqual(?FULL, ch(B, 0, 1)).

%%% -- horizontal geometry ---------------------------------------------

horizontal_full_bar_fills_the_track_test() ->
    Cfg = #{bars => [#{value => 8, text_value => none}], direction => horizontal, max => 8},
    B = render(Cfg, 4, 1),
    ?assertEqual(?FULL, ch(B, 0, 0)),
    ?assertEqual(?FULL, ch(B, 3, 0)).

horizontal_half_bar_fills_half_the_track_test() ->
    Cfg = #{bars => [#{value => 4, text_value => none}], direction => horizontal, max => 8},
    B = render(Cfg, 4, 1),
    ?assertEqual(?FULL, ch(B, 0, 0)),
    ?assertEqual(?FULL, ch(B, 1, 0)),
    ?assertEqual($\s, ch(B, 2, 0)),
    ?assertEqual($\s, ch(B, 3, 0)).

horizontal_partial_cell_is_an_eighth_block_test() ->
    %% 3 of 8 across a one-column track -> three eighths from the left.
    Cfg = #{bars => [#{value => 3, text_value => none}], direction => horizontal, max => 8},
    B = render(Cfg, 1, 1),
    ?assertEqual(?H3, ch(B, 0, 0)).

horizontal_full_plus_partial_test() ->
    %% 12 of 16 across a 2-column track -> one full cell then a half cell.
    Cfg = #{bars => [#{value => 12, text_value => none}], direction => horizontal, max => 16},
    B = render(Cfg, 2, 1),
    ?assertEqual(?FULL, ch(B, 0, 0)),
    ?assertEqual(?H4, ch(B, 1, 0)).

horizontal_bars_top_to_bottom_with_gap_test() ->
    Cfg = #{
        bars => [#{value => 8, text_value => none}, #{value => 8, text_value => none}],
        direction => horizontal,
        max => 8,
        bar_gap => 1
    },
    B = render(Cfg, 2, 3),
    ?assertEqual(?FULL, ch(B, 0, 0)),
    ?assertEqual($\s, ch(B, 0, 1)),
    ?assertEqual(?FULL, ch(B, 0, 2)).

horizontal_bar_width_thickens_the_band_test() ->
    Cfg = #{
        bars => [#{value => 8, text_value => none}],
        direction => horizontal,
        max => 8,
        bar_width => 2
    },
    B = render(Cfg, 2, 2),
    ?assertEqual(?FULL, ch(B, 0, 0)),
    ?assertEqual(?FULL, ch(B, 0, 1)).

%%% -- horizontal label / value columns --------------------------------

horizontal_label_and_value_columns_test() ->
    %% "cpu" (3) + gap, a 4-wide track, gap + value "8" (1) in a 10-wide row.
    Cfg = #{bars => [#{value => 8, label => <<"cpu">>}], direction => horizontal, max => 8},
    B = render(Cfg, 10, 1),
    %% Label left-aligned.
    ?assertEqual($c, ch(B, 0, 0)),
    ?assertEqual($p, ch(B, 1, 0)),
    ?assertEqual($u, ch(B, 2, 0)),
    %% Separator, then the full track.
    ?assertEqual($\s, ch(B, 3, 0)),
    ?assertEqual(?FULL, ch(B, 4, 0)),
    ?assertEqual(?FULL, ch(B, 7, 0)),
    %% Separator, then the right-aligned value.
    ?assertEqual($\s, ch(B, 8, 0)),
    ?assertEqual($8, ch(B, 9, 0)).

horizontal_values_right_align_in_their_column_test() ->
    %% Values "5" and "40": the 1-wide "5" aligns under the units of "40".
    Cfg = #{
        bars => [#{value => 40}, #{value => 5}],
        direction => horizontal,
        max => 40,
        bar_gap => 0
    },
    B = render(Cfg, 6, 2),
    %% Value column is 2 wide (widest value "40"), at columns 4..5, right-aligned.
    ?assertEqual($4, ch(B, 4, 0)),
    ?assertEqual($0, ch(B, 5, 0)),
    ?assertEqual($\s, ch(B, 4, 1)),
    ?assertEqual($5, ch(B, 5, 1)).

%%% -- text_value ------------------------------------------------------

text_value_overrides_the_printed_number_test() ->
    B = render(#{bars => [#{value => 8, text_value => <<"hi">>}], max => 8, bar_width => 2}, 2, 1),
    ?assertEqual($h, ch(B, 0, 0)),
    ?assertEqual($i, ch(B, 1, 0)).

text_value_none_prints_nothing_test() ->
    %% Suppressed value leaves the full block showing rather than a digit.
    B = render(#{bars => [#{value => 8, text_value => none}], max => 8}, 1, 1),
    ?assertEqual(?FULL, ch(B, 0, 0)).

float_value_prints_to_two_decimals_test() ->
    %% Value 1.25 formats as "1.25", right-aligned in a 4-wide value column.
    Cfg = #{bars => [#{value => 1.25}], direction => horizontal, max => 2},
    B = render(Cfg, 8, 1),
    ?assertEqual($1, ch(B, 4, 0)),
    ?assertEqual($., ch(B, 5, 0)),
    ?assertEqual($2, ch(B, 6, 0)),
    ?assertEqual($5, ch(B, 7, 0)).

%%% -- styling ---------------------------------------------------------

bar_style_colours_the_glyphs_test() ->
    Cfg = #{bars => [#{value => 8, text_value => none, style => #{fg => 5}}], max => 8},
    B = render(Cfg, 1, 1),
    ?assertMatch(#cell{char = ?FULL, fg = 5}, cell(B, 0, 0)).

value_style_colours_the_value_test() ->
    Cfg = #{bars => [#{value => 8}], max => 8, value_style => #{fg => 3}},
    B = render(Cfg, 1, 1),
    ?assertMatch(#cell{char = $8, fg = 3}, cell(B, 0, 0)).

label_style_colours_the_label_test() ->
    Cfg = #{
        bars => [#{value => 8, label => <<"a">>, text_value => none}],
        max => 8,
        label_style => #{fg => 2}
    },
    B = render(Cfg, 1, 2),
    ?assertMatch(#cell{char = $a, fg = 2}, cell(B, 0, 1)).

%%% -- empty / degenerate ----------------------------------------------

empty_bars_draws_nothing_test() ->
    B0 = buf(5, 3),
    ?assertEqual(B0, tuition_barchart:render(#{bars => []}, rect(0, 0, 5, 3), B0)).

degenerate_area_draws_nothing_test() ->
    B0 = buf(10, 3),
    ?assertEqual(B0, tuition_barchart:render(#{bars => [#{value => 3}]}, rect(0, 0, 0, 3), B0)),
    ?assertEqual(B0, tuition_barchart:render(#{bars => [#{value => 3}]}, rect(0, 0, 10, 0), B0)).

one_row_with_labels_draws_only_labels_test() ->
    %% A 1-row area entirely consumed by the label row leaves no room for bars.
    B = render(#{bars => [#{value => 8, label => <<"a">>, text_value => none}], max => 8}, 1, 1),
    ?assertEqual($a, ch(B, 0, 0)).
