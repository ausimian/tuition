-module(tuition_spinner_tests).

-include_lib("eunit/include/eunit.hrl").
-include("tuition_layout.hrl").
-include("tuition_term.hrl").

%%% -- helpers ---------------------------------------------------------

%% Glyph sets, mirrored from tuition_spinner's private defines.
-define(BRAILLE, [
    16#280B, 16#2819, 16#2839, 16#2838, 16#283C, 16#2834, 16#2826, 16#2827, 16#2807, 16#280F
]).
-define(DOTS, [16#28FE, 16#28FD, 16#28FB, 16#28BF, 16#287F, 16#28DF, 16#28EF, 16#28F7]).

buf(W, H) -> tuition_render:new({W, H}).
cell(B, X, Y) -> tuition_render:cell_at(B, X, Y).
ch(B, X, Y) -> (cell(B, X, Y))#cell.char.
rect(X, Y, W, H) -> #rect{x = X, y = Y, w = W, h = H}.

render(Cfg, W, H) ->
    tuition_spinner:render(Cfg, rect(0, 0, W, H), buf(W, H)).

%% The nth (0-based) braille frame's codepoint.
braille(N) -> lists:nth(N + 1, ?BRAILLE).

%% The whole frame as the bytes the renderer would emit, for matching label text.
bytes(Buf, W, H) ->
    iolist_to_binary(tuition_render:diff(buf(W, H), Buf)).

%%% -- the default set -------------------------------------------------

defaults_to_the_braille_set_test() ->
    B = render(#{}, 4, 1),
    ?assertEqual(braille(0), ch(B, 0, 0)).

frame_indexes_into_the_set_test() ->
    ?assertEqual(braille(0), ch(render(#{frame => 0}, 4, 1), 0, 0)),
    ?assertEqual(braille(1), ch(render(#{frame => 1}, 4, 1), 0, 0)),
    ?assertEqual(braille(9), ch(render(#{frame => 9}, 4, 1), 0, 0)).

frame_wraps_around_the_cycle_test() ->
    %% Ten braille frames: frame 10 is frame 0 again, 13 is 3.
    ?assertEqual(braille(0), ch(render(#{frame => 10}, 4, 1), 0, 0)),
    ?assertEqual(braille(3), ch(render(#{frame => 13}, 4, 1), 0, 0)).

negative_frame_counts_back_from_the_end_test() ->
    %% -1 is the last frame, not a crash; -11 wraps to the last again.
    ?assertEqual(braille(9), ch(render(#{frame => -1}, 4, 1), 0, 0)),
    ?assertEqual(braille(8), ch(render(#{frame => -2}, 4, 1), 0, 0)),
    ?assertEqual(braille(9), ch(render(#{frame => -11}, 4, 1), 0, 0)).

same_frame_is_the_same_glyph_test() ->
    %% Purely a function of frame — no clock, so it is reproducible.
    ?assertEqual(
        ch(render(#{frame => 7}, 4, 1), 0, 0),
        ch(render(#{frame => 7}, 4, 1), 0, 0)
    ).

%%% -- the other sets --------------------------------------------------

dots_set_uses_the_filled_braille_test() ->
    B = render(#{set => dots, frame => 0}, 4, 1),
    ?assertEqual(lists:nth(1, ?DOTS), ch(B, 0, 0)).

line_set_uses_the_ascii_bar_test() ->
    ?assertEqual($|, ch(render(#{set => line, frame => 0}, 4, 1), 0, 0)),
    ?assertEqual($/, ch(render(#{set => line, frame => 1}, 4, 1), 0, 0)),
    ?assertEqual($-, ch(render(#{set => line, frame => 2}, 4, 1), 0, 0)),
    ?assertEqual($\\, ch(render(#{set => line, frame => 3}, 4, 1), 0, 0)),
    %% Four frames: frame 4 wraps to `|'.
    ?assertEqual($|, ch(render(#{set => line, frame => 4}, 4, 1), 0, 0)).

custom_set_cycles_the_given_glyphs_test() ->
    Cfg = fun(F) -> #{set => [<<"A">>, <<"B">>, <<"C">>], frame => F} end,
    ?assertEqual($A, ch(render(Cfg(0), 4, 1), 0, 0)),
    ?assertEqual($B, ch(render(Cfg(1), 4, 1), 0, 0)),
    ?assertEqual($C, ch(render(Cfg(2), 4, 1), 0, 0)),
    ?assertEqual($A, ch(render(Cfg(3), 4, 1), 0, 0)).

empty_custom_set_draws_no_glyph_test() ->
    %% A misconfigured empty set draws nothing rather than crashing.
    B0 = buf(4, 1),
    ?assertEqual(B0, tuition_spinner:render(#{set => []}, rect(0, 0, 4, 1), B0)).

%%% -- the label -------------------------------------------------------

label_is_absent_by_default_test() ->
    %% Only the glyph is drawn; the cell after it stays blank.
    B = render(#{frame => 0}, 6, 1),
    ?assertEqual(braille(0), ch(B, 0, 0)),
    ?assertEqual($\s, ch(B, 1, 0)),
    ?assertEqual($\s, ch(B, 2, 0)).

label_is_drawn_one_column_after_the_glyph_test() ->
    %% glyph at col 0, a blank gap at col 1, then the label from col 2.
    B = render(#{frame => 0, label => <<"ok">>}, 8, 1),
    ?assertEqual(braille(0), ch(B, 0, 0)),
    ?assertEqual($\s, ch(B, 1, 0)),
    ?assertEqual($o, ch(B, 2, 0)),
    ?assertEqual($k, ch(B, 3, 0)).

label_after_an_empty_set_starts_at_column_zero_test() ->
    %% No glyph -> the label is flush left, no leading gap.
    B = render(#{set => [], label => <<"loading">>}, 12, 1),
    ?assertEqual($l, ch(B, 0, 0)),
    ?assertEqual($o, ch(B, 1, 0)).

label_text_is_rendered_test() ->
    B = render(#{frame => 0, label => <<"working">>}, 20, 1),
    ?assertMatch({_, _}, binary:match(bytes(B, 20, 1), <<"working">>)).

label_is_clipped_to_the_area_test() ->
    %% glyph(1) + gap(1) leaves 3 columns for the label in a 5-wide area.
    B = render(#{frame => 0, label => <<"abcdef">>}, 5, 1),
    ?assertEqual($a, ch(B, 2, 0)),
    ?assertEqual($c, ch(B, 4, 0)),
    Bytes = bytes(B, 5, 1),
    ?assertEqual(nomatch, binary:match(Bytes, <<"def">>)).

%%% -- styling ---------------------------------------------------------

style_colours_the_glyph_test() ->
    B = render(#{frame => 0, style => #{fg => 2}}, 4, 1),
    ?assertMatch(#cell{char = _, fg = 2}, cell(B, 0, 0)).

label_style_colours_the_label_only_test() ->
    B = render(
        #{frame => 0, label => <<"x">>, style => #{fg => 2}, label_style => #{fg => 5}}, 6, 1
    ),
    ?assertMatch(#cell{fg = 2}, cell(B, 0, 0)),
    ?assertMatch(#cell{char = $x, fg = 5}, cell(B, 2, 0)).

%%% -- geometry --------------------------------------------------------

draws_only_on_the_top_row_test() ->
    %% A taller area is drawn on its top row; the rows below are left untouched.
    B = render(#{frame => 0, label => <<"go">>}, 6, 3),
    ?assertEqual(braille(0), ch(B, 0, 0)),
    ?assertEqual($\s, ch(B, 0, 1)),
    ?assertEqual($\s, ch(B, 0, 2)).

%%% -- degenerate ------------------------------------------------------

degenerate_area_draws_nothing_test() ->
    B0 = buf(10, 3),
    ?assertEqual(B0, tuition_spinner:render(#{frame => 0}, rect(0, 0, 0, 3), B0)),
    ?assertEqual(B0, tuition_spinner:render(#{frame => 0}, rect(0, 0, 10, 0), B0)).
