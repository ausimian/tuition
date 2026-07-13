-module(tuition_gauge_tests).

-include_lib("eunit/include/eunit.hrl").
-include("tuition_layout.hrl").
-include("tuition_term.hrl").

%%% -- helpers ---------------------------------------------------------

%% Eighth-block glyphs, mirrored from tuition_gauge's private defines.
-define(FULL, 16#2588).
-define(HALF, 16#258C).

buf(W, H) -> tuition_render:new({W, H}).
cell(B, X, Y) -> tuition_render:cell_at(B, X, Y).
ch(B, X, Y) -> (cell(B, X, Y))#cell.char.
rect(X, Y, W, H) -> #rect{x = X, y = Y, w = W, h = H}.

render(Cfg, W, H) ->
    tuition_gauge:render(Cfg, rect(0, 0, W, H), buf(W, H)).

%% The whole frame as the bytes the renderer would emit, for matching label text.
frame(Buf, W, H) ->
    iolist_to_binary(tuition_render:diff(buf(W, H), Buf)).

%%% -- the bar ---------------------------------------------------------

full_ratio_fills_every_cell_test() ->
    B = render(#{ratio => 1.0, label => none}, 8, 1),
    ?assertEqual(?FULL, ch(B, 0, 0)),
    ?assertEqual(?FULL, ch(B, 7, 0)).

zero_ratio_draws_no_bar_test() ->
    B = render(#{ratio => 0.0, label => none}, 8, 1),
    ?assertEqual($\s, ch(B, 0, 0)),
    ?assertEqual($\s, ch(B, 7, 0)).

half_ratio_fills_half_the_width_test() ->
    %% width 10, ratio 0.5 -> exactly 5 full cells, no partial boundary.
    B = render(#{ratio => 0.5, label => none}, 10, 1),
    ?assertEqual(?FULL, ch(B, 4, 0)),
    ?assertEqual($\s, ch(B, 5, 0)).

fractional_ratio_draws_a_partial_boundary_cell_test() ->
    %% width 8, ratio 5/16 -> filled 2.5 cols: two full cells then a half block.
    B = render(#{ratio => 0.3125, label => none}, 8, 1),
    ?assertEqual(?FULL, ch(B, 1, 0)),
    ?assertEqual(?HALF, ch(B, 2, 0)),
    ?assertEqual($\s, ch(B, 3, 0)).

bar_fills_every_row_test() ->
    B = render(#{ratio => 1.0, label => none}, 4, 3),
    ?assertEqual(?FULL, ch(B, 0, 0)),
    ?assertEqual(?FULL, ch(B, 0, 1)),
    ?assertEqual(?FULL, ch(B, 0, 2)).

%%% -- clamping --------------------------------------------------------

ratio_above_one_is_clamped_test() ->
    %% A metering overshoot fills the bar, it never draws past the area.
    B = render(#{ratio => 2.0, label => none}, 5, 1),
    ?assertEqual(?FULL, ch(B, 0, 0)),
    ?assertEqual(?FULL, ch(B, 4, 0)).

ratio_below_zero_is_clamped_test() ->
    B = render(#{ratio => -1.0, label => none}, 5, 1),
    ?assertEqual($\s, ch(B, 0, 0)),
    ?assertEqual($\s, ch(B, 4, 0)).

%%% -- the label -------------------------------------------------------

default_label_is_the_rounded_percentage_test() ->
    %% 0.626 rounds to 63%.
    B = render(#{ratio => 0.626}, 20, 1),
    ?assertMatch({_, _}, binary:match(frame(B, 20, 1), <<"63%">>)).

label_none_suppresses_the_label_test() ->
    B = render(#{ratio => 0.0, label => none}, 12, 1),
    ?assertEqual(nomatch, binary:match(frame(B, 12, 1), <<"0%">>)).

custom_label_overrides_the_default_test() ->
    B = render(#{ratio => 0.5, label => <<"hi">>}, 12, 1),
    Bytes = frame(B, 12, 1),
    ?assertMatch({_, _}, binary:match(Bytes, <<"hi">>)),
    ?assertEqual(nomatch, binary:match(Bytes, <<"50%">>)).

label_is_centered_by_default_test() ->
    %% "X" over a 5-wide gauge centres at col 2.
    B = render(#{ratio => 0.0, label => <<"X">>}, 5, 1),
    ?assertEqual($X, ch(B, 2, 0)).

label_align_left_test() ->
    B = render(#{ratio => 0.0, label => <<"X">>, label_align => left}, 10, 1),
    ?assertEqual($X, ch(B, 0, 0)).

label_align_right_test() ->
    B = render(#{ratio => 0.0, label => <<"X">>, label_align => right}, 10, 1),
    ?assertEqual($X, ch(B, 9, 0)).

label_sits_on_the_middle_row_test() ->
    %% Three rows -> the label is on row 1, not row 0 or 2.
    B = render(#{ratio => 0.0, label => <<"X">>}, 5, 3),
    ?assertEqual($X, ch(B, 2, 1)),
    ?assertEqual($\s, ch(B, 2, 0)),
    ?assertEqual($\s, ch(B, 2, 2)).

label_punches_through_the_bar_test() ->
    %% Over a full bar the label is still drawn: its glyphs replace the blocks.
    B = render(#{ratio => 1.0, label => <<"X">>}, 5, 1),
    ?assertEqual($X, ch(B, 2, 0)),
    ?assertEqual(?FULL, ch(B, 0, 0)).

%%% -- styling ---------------------------------------------------------

fill_style_colours_the_bar_test() ->
    B = render(#{ratio => 1.0, label => none, fill_style => #{fg => 2}}, 4, 1),
    ?assertMatch(#cell{char = ?FULL, fg = 2}, cell(B, 0, 0)).

unfilled_style_paints_the_track_test() ->
    B = render(#{ratio => 0.0, label => none, unfilled_style => #{bg => 3}}, 6, 1),
    ?assertMatch(#cell{char = $\s, bg = 3}, cell(B, 5, 0)).

label_style_is_applied_test() ->
    B = render(#{ratio => 0.0, label => <<"X">>, label_style => #{fg => 5, bold => true}}, 5, 1),
    ?assertMatch(#cell{char = $X, fg = 5, bold = true}, cell(B, 2, 0)).

unstyled_gauge_leaves_the_track_transparent_test() ->
    %% No unfilled_style over a parent background: the remainder shows it through.
    Parent = tuition_widget:fill(buf(6, 1), rect(0, 0, 6, 1), #{bg => 4}),
    B = tuition_gauge:render(#{ratio => 0.0, label => none}, rect(0, 0, 6, 1), Parent),
    ?assertMatch(#cell{bg = 4}, cell(B, 5, 0)).

%%% -- degenerate ------------------------------------------------------

degenerate_area_draws_nothing_test() ->
    B0 = buf(10, 3),
    ?assertEqual(B0, tuition_gauge:render(#{ratio => 0.5}, rect(0, 0, 0, 3), B0)),
    ?assertEqual(B0, tuition_gauge:render(#{ratio => 0.5}, rect(0, 0, 10, 0), B0)).
