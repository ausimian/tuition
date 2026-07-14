-module(tuition_line_gauge_tests).

-include_lib("eunit/include/eunit.hrl").
-include("tuition_layout.hrl").
-include("tuition_term.hrl").

%%% -- helpers ---------------------------------------------------------

%% Line glyphs, mirrored from tuition_line_gauge's private defines.
-define(THIN, 16#2500).
-define(HEAVY, 16#2501).

buf(W, H) -> tuition_render:new({W, H}).
cell(B, X, Y) -> tuition_render:cell_at(B, X, Y).
ch(B, X, Y) -> (cell(B, X, Y))#cell.char.
rect(X, Y, W, H) -> #rect{x = X, y = Y, w = W, h = H}.

render(Cfg, W, H) ->
    tuition_line_gauge:render(Cfg, rect(0, 0, W, H), buf(W, H)).

%% The whole frame as the bytes the renderer would emit, for matching label text.
frame(Buf, W, H) ->
    iolist_to_binary(tuition_render:diff(buf(W, H), Buf)).

%%% -- the line glyph --------------------------------------------------

line_defaults_to_thin_test() ->
    B = render(#{ratio => 1.0, label => none}, 4, 1),
    ?assertEqual(?THIN, ch(B, 0, 0)),
    ?assertEqual(?THIN, ch(B, 3, 0)).

heavy_line_uses_the_thick_glyph_test() ->
    B = render(#{ratio => 1.0, label => none, line => heavy}, 4, 1),
    ?assertEqual(?HEAVY, ch(B, 0, 0)).

custom_line_glyph_test() ->
    B = render(#{ratio => 1.0, label => none, line => <<"=">>}, 4, 1),
    ?assertEqual($=, ch(B, 0, 0)),
    ?assertEqual($=, ch(B, 3, 0)).

line_spans_the_full_width_when_unlabelled_test() ->
    %% No label -> the rule runs the whole row, filled and unfilled alike drawn.
    B = render(#{ratio => 0.0, label => none}, 6, 1),
    ?assertEqual(?THIN, ch(B, 0, 0)),
    ?assertEqual(?THIN, ch(B, 5, 0)).

%%% -- the fill split --------------------------------------------------
%%
%% Filled and unfilled share the glyph, so the split is only visible through the
%% two styles — assert on the cell style, not the char.

full_ratio_fills_the_whole_line_test() ->
    B = render(#{ratio => 1.0, label => none, filled_style => #{fg => 2}}, 8, 1),
    ?assertMatch(#cell{char = ?THIN, fg = 2}, cell(B, 0, 0)),
    ?assertMatch(#cell{char = ?THIN, fg = 2}, cell(B, 7, 0)).

zero_ratio_fills_nothing_test() ->
    B = render(
        #{ratio => 0.0, label => none, filled_style => #{fg => 2}, unfilled_style => #{fg => 3}},
        8,
        1
    ),
    ?assertMatch(#cell{char = ?THIN, fg = 3}, cell(B, 0, 0)),
    ?assertMatch(#cell{char = ?THIN, fg = 3}, cell(B, 7, 0)).

half_ratio_fills_half_the_line_test() ->
    %% width 10, no label, ratio 0.5 -> 5 filled cells then 5 unfilled.
    B = render(
        #{ratio => 0.5, label => none, filled_style => #{fg => 2}, unfilled_style => #{fg => 3}},
        10,
        1
    ),
    ?assertMatch(#cell{fg = 2}, cell(B, 4, 0)),
    ?assertMatch(#cell{fg = 3}, cell(B, 5, 0)).

fill_floors_to_whole_cells_test() ->
    %% width 8, ratio 0.31 -> floor(2.48) = 2 filled cells, no partial boundary.
    B = render(
        #{ratio => 0.31, label => none, filled_style => #{fg => 2}, unfilled_style => #{fg => 3}},
        8,
        1
    ),
    ?assertMatch(#cell{fg = 2}, cell(B, 1, 0)),
    ?assertMatch(#cell{fg = 3}, cell(B, 2, 0)).

%%% -- clamping --------------------------------------------------------

ratio_above_one_is_clamped_test() ->
    %% A metering overshoot fills the line, it never draws past the area.
    B = render(#{ratio => 2.0, label => none, filled_style => #{fg => 2}}, 5, 1),
    ?assertMatch(#cell{fg = 2}, cell(B, 0, 0)),
    ?assertMatch(#cell{fg = 2}, cell(B, 4, 0)).

ratio_below_zero_is_clamped_test() ->
    B = render(#{ratio => -1.0, label => none, unfilled_style => #{fg => 3}}, 5, 1),
    ?assertMatch(#cell{fg = 3}, cell(B, 0, 0)),
    ?assertMatch(#cell{fg = 3}, cell(B, 4, 0)).

%%% -- the label -------------------------------------------------------

default_label_is_the_rounded_percentage_test() ->
    %% 0.626 rounds to 63%.
    B = render(#{ratio => 0.626}, 20, 1),
    ?assertMatch({_, _}, binary:match(frame(B, 20, 1), <<"63%">>)).

label_is_drawn_at_the_left_test() ->
    B = render(#{ratio => 0.0, label => <<"cpu">>}, 20, 1),
    ?assertEqual($c, ch(B, 0, 0)),
    ?assertEqual($p, ch(B, 1, 0)),
    ?assertEqual($u, ch(B, 2, 0)).

line_starts_one_column_after_the_label_test() ->
    %% Label "ab" (2 cols) -> col 2 is the gap, the rule begins at col 3.
    B = render(#{ratio => 1.0, label => <<"ab">>, filled_style => #{fg => 2}}, 8, 1),
    ?assertEqual($a, ch(B, 0, 0)),
    ?assertEqual($b, ch(B, 1, 0)),
    ?assertEqual($\s, ch(B, 2, 0)),
    ?assertMatch(#cell{char = ?THIN, fg = 2}, cell(B, 3, 0)).

label_none_yields_the_full_width_to_the_line_test() ->
    %% With no label the rule starts at column 0.
    B = render(#{ratio => 1.0, label => none, filled_style => #{fg => 2}}, 6, 1),
    ?assertMatch(#cell{char = ?THIN, fg = 2}, cell(B, 0, 0)).

custom_label_overrides_the_default_test() ->
    B = render(#{ratio => 0.5, label => <<"hi">>}, 12, 1),
    Bytes = frame(B, 12, 1),
    ?assertMatch({_, _}, binary:match(Bytes, <<"hi">>)),
    ?assertEqual(nomatch, binary:match(Bytes, <<"50%">>)).

label_filling_the_row_leaves_no_line_test() ->
    %% Label as wide as the area: the gap lands past the right edge, so no rule is
    %% drawn — the trailing cell stays blank rather than showing a stray glyph.
    B = render(#{ratio => 1.0, label => <<"12345678">>, filled_style => #{fg => 2}}, 9, 1),
    ?assertEqual($8, ch(B, 7, 0)),
    ?assertEqual($\s, ch(B, 8, 0)).

%%% -- styling ---------------------------------------------------------

label_style_is_applied_test() ->
    B = render(#{ratio => 0.0, label => <<"X">>, label_style => #{fg => 5, bold => true}}, 5, 1),
    ?assertMatch(#cell{char = $X, fg = 5, bold = true}, cell(B, 0, 0)).

%%% -- geometry --------------------------------------------------------

draws_only_on_the_top_row_test() ->
    %% A taller area is drawn on its top row; the rows below are left untouched.
    B = render(#{ratio => 1.0, label => none, filled_style => #{fg => 2}}, 4, 3),
    ?assertMatch(#cell{char = ?THIN, fg = 2}, cell(B, 0, 0)),
    ?assertEqual($\s, ch(B, 0, 1)),
    ?assertEqual($\s, ch(B, 0, 2)).

%%% -- degenerate ------------------------------------------------------

degenerate_area_draws_nothing_test() ->
    B0 = buf(10, 3),
    ?assertEqual(B0, tuition_line_gauge:render(#{ratio => 0.5}, rect(0, 0, 0, 3), B0)),
    ?assertEqual(B0, tuition_line_gauge:render(#{ratio => 0.5}, rect(0, 0, 10, 0), B0)).
