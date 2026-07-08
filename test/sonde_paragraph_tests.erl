-module(sonde_paragraph_tests).

-include_lib("eunit/include/eunit.hrl").
-include("sonde_layout.hrl").
-include("sonde_term.hrl").

%%% -- helpers ---------------------------------------------------------

buf(W, H) -> sonde_render:new({W, H}).
cell(B, X, Y) -> sonde_render:cell_at(B, X, Y).
ch(B, X, Y) -> (cell(B, X, Y))#cell.char.
frame(B, W, H) -> iolist_to_binary(sonde_render:diff(sonde_render:new({W, H}), B)).
rect(X, Y, W, H) -> #rect{x = X, y = Y, w = W, h = H}.

render(Cfg, W, H) ->
    sonde_paragraph:render(Cfg, rect(0, 0, W, H), buf(W, H)).

%%% -- basic drawing ---------------------------------------------------

plain_text_draws_from_origin_test() ->
    B = render(#{text => <<"hello">>}, 10, 1),
    ?assertEqual($h, ch(B, 0, 0)),
    ?assertEqual($o, ch(B, 4, 0)).

styled_text_carries_style_test() ->
    B = render(#{text => <<"x">>, style => #{fg => 3, bold => true}}, 5, 1),
    ?assertMatch(#cell{char = $x, fg = 3, bold = true}, cell(B, 0, 0)).

degenerate_area_is_a_noop_test() ->
    B0 = buf(4, 2),
    ?assertEqual(B0, sonde_paragraph:render(#{text => <<"x">>}, rect(0, 0, 0, 2), B0)),
    ?assertEqual(B0, sonde_paragraph:render(#{text => <<"x">>}, rect(0, 0, 4, 0), B0)).

%%% -- line splitting --------------------------------------------------

newline_splits_lines_test() ->
    B = render(#{text => <<"ab\ncd">>}, 10, 2),
    ?assertEqual($a, ch(B, 0, 0)),
    ?assertEqual($c, ch(B, 0, 1)).

crlf_is_tolerated_test() ->
    B = render(#{text => <<"ab\r\ncd">>}, 10, 2),
    ?assertEqual($b, ch(B, 1, 0)),
    %% No stray carriage return cell after "ab".
    ?assertEqual($\s, ch(B, 2, 0)),
    ?assertEqual($c, ch(B, 0, 1)).

height_limits_rendered_lines_test() ->
    B = render(#{text => <<"a\nb\nc">>}, 4, 2),
    ?assertEqual($a, ch(B, 0, 0)),
    ?assertEqual($b, ch(B, 0, 1)),
    ?assertEqual(nomatch, binary:match(frame(B, 4, 2), <<"c">>)).

%%% -- wrapping --------------------------------------------------------

no_wrap_clips_long_line_test() ->
    B = sonde_paragraph:render(#{text => <<"abcdef">>, wrap => none}, rect(0, 0, 3, 2), buf(6, 2)),
    ?assertEqual($c, ch(B, 2, 0)),
    %% Neither past the right edge nor wrapped onto the next row.
    ?assertEqual($\s, ch(B, 3, 0)),
    ?assertEqual($\s, ch(B, 0, 1)).

word_wrap_breaks_at_spaces_test() ->
    %% Width 5: "the cat sat" -> "the" / "cat" / "sat" (each pair is 7 > 5).
    B = render(#{text => <<"the cat sat">>, wrap => word}, 5, 5),
    ?assertEqual($t, ch(B, 0, 0)),
    ?assertEqual($c, ch(B, 0, 1)),
    ?assertEqual($s, ch(B, 0, 2)).

word_wrap_packs_words_that_fit_test() ->
    %% Width 8: "the cat" (7) shares a row, "sat" wraps to the next.
    B = render(#{text => <<"the cat sat">>, wrap => word}, 8, 3),
    ?assertEqual($t, ch(B, 0, 0)),
    ?assertEqual($c, ch(B, 4, 0)),
    ?assertEqual($s, ch(B, 0, 1)).

word_wrap_hard_splits_an_overlong_word_test() ->
    %% Width 3: "abcdefg" -> "abc" / "def" / "g".
    B = render(#{text => <<"abcdefg">>, wrap => word}, 3, 5),
    ?assertEqual($a, ch(B, 0, 0)),
    ?assertEqual($d, ch(B, 0, 1)),
    ?assertEqual($g, ch(B, 0, 2)).

word_wrap_measures_control_bytes_as_rendered_test() ->
    %% "a\t\tb" renders as 4 columns (each tab a one-column blank), so in a
    %% 3-column word wrap it must hard-split, keeping "b" on the next row. Measured
    %% with raw swidth (tabs = 0, "width 2, fits") the whole word landed on one line
    %% and put_line clipped the "b" — silent content loss.
    B = render(#{text => <<"a\t\tb">>, wrap => word}, 3, 3),
    ?assertEqual($a, ch(B, 0, 0)),
    ?assertEqual($b, ch(B, 0, 1)).

word_wrap_preserves_blank_lines_test() ->
    %% A blank source line stays a blank row, so the following line lands on row 2.
    B = render(#{text => <<"a\n\nb">>, wrap => word}, 5, 3),
    ?assertEqual($a, ch(B, 0, 0)),
    ?assertEqual($\s, ch(B, 0, 1)),
    ?assertEqual($b, ch(B, 0, 2)).

%%% -- alignment -------------------------------------------------------

right_alignment_test() ->
    %% Width 6, "hi" flush right -> columns 4 and 5.
    B = render(#{text => <<"hi">>, align => right}, 6, 1),
    ?assertEqual($h, ch(B, 4, 0)),
    ?assertEqual($i, ch(B, 5, 0)).

centre_alignment_test() ->
    %% Width 6, "hi" centred -> pad (6-2)/2 = 2.
    B = render(#{text => <<"hi">>, align => center}, 6, 1),
    ?assertEqual($h, ch(B, 2, 0)),
    ?assertEqual($i, ch(B, 3, 0)).

alignment_measures_control_bytes_as_rendered_test() ->
    %% "a\tb" renders as "a<blank>b" (3 columns). Right-aligned in width 4 it must
    %% start at column 1 (pad 4 - 3). Measured with the raw swidth (tab = 0 -> width
    %% 2) it would start at column 2 and clip the trailing "b" — the bug the
    %% sanitize-aware display_width/1 fixes.
    B = render(#{text => <<"a\tb">>, align => right}, 4, 1),
    ?assertEqual($a, ch(B, 1, 0)),
    ?assertEqual($\s, ch(B, 2, 0)),
    ?assertEqual($b, ch(B, 3, 0)).

%%% -- scroll ----------------------------------------------------------

scroll_skips_leading_lines_test() ->
    B = render(#{text => <<"a\nb\nc\nd">>, scroll => 2}, 4, 4),
    ?assertEqual($c, ch(B, 0, 0)),
    ?assertEqual($d, ch(B, 0, 1)),
    %% Nothing on the rows past the last visible line.
    ?assertEqual($\s, ch(B, 0, 2)).

scroll_past_end_draws_nothing_test() ->
    B = render(#{text => <<"a\nb">>, scroll => 10}, 4, 4),
    ?assertEqual(<<>>, frame(B, 4, 4)).
