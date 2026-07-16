-module(tuition_paragraph_tests).

-include_lib("eunit/include/eunit.hrl").
-include("tuition_layout.hrl").
-include("tuition_term.hrl").

%%% -- helpers ---------------------------------------------------------

buf(W, H) -> tuition_render:new({W, H}).
cell(B, X, Y) -> tuition_render:cell_at(B, X, Y).
ch(B, X, Y) -> (cell(B, X, Y))#cell.char.
frame(B, W, H) -> iolist_to_binary(tuition_render:diff(tuition_render:new({W, H}), B)).
rect(X, Y, W, H) -> #rect{x = X, y = Y, w = W, h = H}.

render(Cfg, W, H) ->
    tuition_paragraph:render(Cfg, rect(0, 0, W, H), buf(W, H)).

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
    ?assertEqual(B0, tuition_paragraph:render(#{text => <<"x">>}, rect(0, 0, 0, 2), B0)),
    ?assertEqual(B0, tuition_paragraph:render(#{text => <<"x">>}, rect(0, 0, 4, 0), B0)).

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
    B = tuition_paragraph:render(
        #{text => <<"abcdef">>, wrap => none}, rect(0, 0, 3, 2), buf(6, 2)
    ),
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

%%% -- styled spans ----------------------------------------------------

styled_line_draws_each_span_style_test() ->
    B = render(#{text => [<<"ok ">>, {<<"ERR">>, #{fg => 1}}]}, 10, 1),
    ?assertMatch(#cell{char = $o, fg = default}, cell(B, 0, 0)),
    ?assertMatch(#cell{char = $E, fg = 1}, cell(B, 3, 0)).

styled_span_overlays_paragraph_style_test() ->
    %% The paragraph style is the base; a span key overrides, others fall through.
    B = render(#{text => [{<<"x">>, #{fg => 1}}], style => #{bg => 5, fg => 9}}, 4, 1),
    ?assertMatch(#cell{char = $x, fg = 1, bg = 5}, cell(B, 0, 0)).

styled_text_multi_line_test() ->
    B = render(#{text => [[{<<"a">>, #{fg => 1}}], [{<<"b">>, #{fg => 2}}]]}, 4, 2),
    ?assertMatch(#cell{char = $a, fg = 1}, cell(B, 0, 0)),
    ?assertMatch(#cell{char = $b, fg = 2}, cell(B, 0, 1)).

styled_newline_inside_span_splits_lines_test() ->
    B = render(#{text => [{<<"a\nb">>, #{fg => 1}}]}, 4, 2),
    ?assertMatch(#cell{char = $a, fg = 1}, cell(B, 0, 0)),
    ?assertMatch(#cell{char = $b, fg = 1}, cell(B, 0, 1)).

styled_right_alignment_measures_spans_test() ->
    %% Two spans totalling 2 columns, flush right in width 6 -> columns 4, 5.
    B = render(#{text => [{<<"h">>, #{fg => 1}}, {<<"i">>, #{fg => 2}}], align => right}, 6, 1),
    ?assertMatch(#cell{char = $h, fg = 1}, cell(B, 4, 0)),
    ?assertMatch(#cell{char = $i, fg = 2}, cell(B, 5, 0)).

word_wrap_preserves_span_style_test() ->
    %% "aaa bbb" wrapped at width 3: each word on its own row, keeping its style.
    B = render(#{text => [{<<"aaa ">>, #{fg => 1}}, {<<"bbb">>, #{fg => 2}}], wrap => word}, 3, 2),
    ?assertMatch(#cell{char = $a, fg = 1}, cell(B, 0, 0)),
    ?assertMatch(#cell{char = $b, fg = 2}, cell(B, 0, 1)).

word_wrap_across_a_style_boundary_keeps_one_word_test() ->
    %% "foo" then "bar" with no space between, across a style change, is one word:
    %% it fits width 6 on one row, each half keeping its own colour.
    B = render(#{text => [{<<"foo">>, #{fg => 1}}, {<<"bar">>, #{fg => 2}}], wrap => word}, 6, 2),
    ?assertMatch(#cell{char = $o, fg = 1}, cell(B, 2, 0)),
    ?assertMatch(#cell{char = $b, fg = 2}, cell(B, 3, 0)),
    %% One row only — nothing wrapped onto the next.
    ?assertEqual($\s, ch(B, 0, 1)).

word_wrap_hard_splits_styled_word_keeping_style_test() ->
    %% A single 5-col word in one style, wrapped at width 3: "abc" / "de", both fg 1.
    B = render(#{text => [{<<"abcde">>, #{fg => 1}}], wrap => word}, 3, 2),
    ?assertMatch(#cell{char = $a, fg = 1}, cell(B, 0, 0)),
    ?assertMatch(#cell{char = $d, fg = 1}, cell(B, 0, 1)).

word_wrap_keeps_separator_span_style_test() ->
    %% When two words of one styled span share a wrapped line, the re-inserted
    %% joining space keeps the span's background rather than reverting to default,
    %% so a styled/highlighted run has no gap between its words.
    B = render(#{text => [{<<"a b">>, #{bg => 1}}], wrap => word}, 3, 1),
    ?assertMatch(#cell{char = $a, bg = 1}, cell(B, 0, 0)),
    ?assertMatch(#cell{char = $\s, bg = 1}, cell(B, 1, 0)),
    ?assertMatch(#cell{char = $b, bg = 1}, cell(B, 2, 0)).

word_wrap_keeps_split_cluster_whole_across_rows_test() ->
    %% A word whose emoji ZWJ sequence is split across a style boundary, hard-wrapped
    %% at a width that forces the break just before the emoji, keeps the emoji whole
    %% on one row (styled by its base span) instead of tearing it across two rows —
    %% which put_line, regrouping only within a line, could not have healed.
    %% Woman U+1F469, ZWJ U+200D, laptop U+1F4BB.
    WholeText = [{<<$a, 16#1F469/utf8, 16#200D/utf8, 16#1F4BB/utf8>>, #{fg => 1}}],
    SplitText = [
        {<<$a, 16#1F469/utf8>>, #{fg => 1}}, {<<16#200D/utf8, 16#1F4BB/utf8>>, #{fg => 2}}
    ],
    BWhole = render(#{text => WholeText, wrap => word}, 2, 3),
    BSplit = render(#{text => SplitText, wrap => word}, 2, 3),
    %% Row 0 is "a"; row 1 is the whole emoji — identical cells for both inputs.
    ?assertEqual(cell(BWhole, 0, 0), cell(BSplit, 0, 0)),
    ?assertEqual(cell(BWhole, 0, 1), cell(BSplit, 0, 1)),
    ?assertMatch(#cell{fg = 1}, cell(BSplit, 0, 1)).
