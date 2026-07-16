-module(tuition_text_tests).

-include_lib("eunit/include/eunit.hrl").
-include("tuition_layout.hrl").
-include("tuition_term.hrl").

%%% -- helpers ---------------------------------------------------------

buf(W, H) -> tuition_render:new({W, H}).
cell(B, X, Y) -> tuition_render:cell_at(B, X, Y).
ch(B, X, Y) -> (cell(B, X, Y))#cell.char.
rect(X, Y, W, H) -> #rect{x = X, y = Y, w = W, h = H}.

put(Line, Base, DCol, W) ->
    tuition_text:put_line(buf(W, 1), rect(0, 0, W, 1), DCol, 0, Line, Base).

%%% -- constructors ----------------------------------------------------

span_default_style_test() ->
    ?assertEqual({<<"hi">>, #{}}, tuition_text:span(<<"hi">>)).

span_carries_style_test() ->
    ?assertEqual({<<"hi">>, #{fg => 1}}, tuition_text:span(<<"hi">>, #{fg => 1})).

span_normalises_chardata_to_binary_test() ->
    ?assertEqual({<<"hi">>, #{}}, tuition_text:span("hi")),
    ?assertEqual({<<"ab">>, #{}}, tuition_text:span([<<"a">>, <<"b">>])).

%%% -- line/1 normalisation --------------------------------------------

line_from_binary_is_one_default_span_test() ->
    ?assertEqual([{<<"hi">>, #{}}], tuition_text:line(<<"hi">>)).

line_from_iolist_concatenates_to_one_span_test() ->
    %% A bare iolist is plain chardata: one default span, never a span-per-element.
    ?assertEqual([{<<"ab">>, #{}}], tuition_text:line([<<"a">>, <<"b">>])),
    ?assertEqual([{<<"hi">>, #{}}], tuition_text:line("hi")).

line_from_lone_tuple_span_test() ->
    ?assertEqual([{<<"x">>, #{fg => 1}}], tuition_text:line({<<"x">>, #{fg => 1}})).

line_from_lone_map_span_test() ->
    ?assertEqual(
        [{<<"x">>, #{fg => 1}}], tuition_text:line(#{text => <<"x">>, style => #{fg => 1}})
    ),
    ?assertEqual([{<<"x">>, #{}}], tuition_text:line(#{text => <<"x">>})).

line_mixes_bare_chardata_and_spans_test() ->
    ?assertEqual(
        [{<<"time ">>, #{}}, {<<"err">>, #{fg => 1}}],
        tuition_text:line([<<"time ">>, {<<"err">>, #{fg => 1}}])
    ).

line_drops_empty_spans_test() ->
    ?assertEqual([], tuition_text:line(<<>>)),
    ?assertEqual(
        [{<<"x">>, #{}}],
        tuition_text:line([{<<>>, #{fg => 1}}, {<<"x">>, #{}}])
    ).

line_accepts_improper_iolist_test() ->
    %% A plain improper iolist (binary tail) is chardata the old widgets accepted;
    %% the span-detection scan must tolerate it rather than crash.
    ?assertEqual([{<<"foobar">>, #{}}], tuition_text:line([<<"foo">> | <<"bar">>])),
    ?assertEqual([{<<"ab">>, #{}}], tuition_text:line([$a | <<"b">>])).

%%% -- lines/1 normalisation -------------------------------------------

lines_splits_plain_text_on_newline_test() ->
    ?assertEqual(
        [[{<<"a">>, #{}}], [{<<"b">>, #{}}]],
        tuition_text:lines(<<"a\nb">>)
    ).

lines_tolerates_crlf_test() ->
    ?assertEqual(
        [[{<<"a">>, #{}}], [{<<"b">>, #{}}]],
        tuition_text:lines(<<"a\r\nb">>)
    ).

lines_preserves_blank_line_as_empty_test() ->
    ?assertEqual(
        [[{<<"a">>, #{}}], [], [{<<"b">>, #{}}]],
        tuition_text:lines(<<"a\n\nb">>)
    ).

lines_empty_text_is_one_empty_line_test() ->
    ?assertEqual([[]], tuition_text:lines(<<>>)).

lines_single_styled_line_test() ->
    %% A flat list of spans (no nested line) is one line, not one line per span.
    ?assertEqual(
        [[{<<"time">>, #{}}, {<<"err">>, #{fg => 1}}]],
        tuition_text:lines([<<"time">>, {<<"err">>, #{fg => 1}}])
    ).

lines_list_of_styled_lines_test() ->
    ?assertEqual(
        [[{<<"a">>, #{fg => 1}}], [{<<"b">>, #{fg => 2}}]],
        tuition_text:lines([[{<<"a">>, #{fg => 1}}], [{<<"b">>, #{fg => 2}}]])
    ).

lines_lone_span_is_one_line_test() ->
    ?assertEqual([[{<<"x">>, #{fg => 1}}]], tuition_text:lines({<<"x">>, #{fg => 1}})).

lines_newline_inside_span_splits_and_keeps_style_test() ->
    ?assertEqual(
        [[{<<"a">>, #{fg => 1}}], [{<<"b">>, #{fg => 1}}]],
        tuition_text:lines([{<<"a\nb">>, #{fg => 1}}])
    ).

lines_newline_across_spans_test() ->
    %% The tail of the first span joins the second on the same wrapped line.
    ?assertEqual(
        [[{<<"a">>, #{fg => 1}}], [{<<"b">>, #{fg => 1}}, {<<"c">>, #{fg => 2}}]],
        tuition_text:lines([{<<"a\nb">>, #{fg => 1}}, {<<"c">>, #{fg => 2}}])
    ).

lines_accepts_improper_iolist_test() ->
    ?assertEqual([[{<<"foobar">>, #{}}]], tuition_text:lines([<<"foo">> | <<"bar">>])).

lines_keeps_mid_line_cr_across_spans_test() ->
    %% A CR at a span boundary that is not a CRLF break is kept (it renders as a
    %% blank column), so splitting `a\rb' into spans does not silently drop it.
    ?assertEqual(
        [[{<<"a\r">>, #{fg => 1}}, {<<"b">>, #{fg => 2}}]],
        tuition_text:lines([{<<"a\r">>, #{fg => 1}}, {<<"b">>, #{fg => 2}}])
    ).

lines_strips_crlf_and_trailing_cr_test() ->
    %% A `\r' before a `\n' (CRLF) and a `\r' at end-of-text are dropped, matching
    %% how the same plain text splits.
    ?assertEqual(
        [[{<<"a">>, #{fg => 1}}], [{<<"b">>, #{fg => 1}}]],
        tuition_text:lines([{<<"a\r\nb\r">>, #{fg => 1}}])
    ).

lines_strips_crlf_split_across_spans_test() ->
    %% A CRLF whose CR and LF fall in different spans is still a line break: the CR
    %% is dropped even though the `\n' arrives in the next span (whose leading empty
    %% piece must not absorb the strip), matching plain `a\r\nb'.
    ?assertEqual(
        [[{<<"a">>, #{fg => 1}}], [{<<"b">>, #{fg => 2}}]],
        tuition_text:lines([{<<"a\r">>, #{fg => 1}}, {<<"\nb">>, #{fg => 2}}])
    ).

%%% -- line_width ------------------------------------------------------

line_width_sums_spans_test() ->
    ?assertEqual(4, tuition_text:line_width([{<<"ab">>, #{}}, {<<"cd">>, #{}}])).

line_width_counts_wide_glyph_as_two_test() ->
    ?assertEqual(2, tuition_text:line_width([{<<"世"/utf8>>, #{}}])).

line_width_of_empty_line_is_zero_test() ->
    ?assertEqual(0, tuition_text:line_width([])).

line_width_regroups_cluster_split_across_spans_test() ->
    %% An emoji ZWJ sequence (👩‍💻) split across a style boundary measures as the one
    %% glyph it renders as, not double-counted from each half — so alignment stays in
    %% step with drawing. Woman U+1F469, ZWJ U+200D, laptop U+1F4BB.
    Whole = [{<<16#1F469/utf8, 16#200D/utf8, 16#1F4BB/utf8>>, #{}}],
    Split = [{<<16#1F469/utf8>>, #{}}, {<<16#200D/utf8, 16#1F4BB/utf8>>, #{fg => 1}}],
    ?assertEqual(tuition_text:line_width(Whole), tuition_text:line_width(Split)).

regroup_heals_cluster_split_across_spans_test() ->
    %% The split spans collapse to one run in the base span's style.
    Split = [{<<16#65/utf8>>, #{}}, {<<16#301/utf8>>, #{fg => 1}}],
    ?assertEqual([{<<16#65/utf8, 16#301/utf8>>, #{}}], tuition_text:regroup(Split)).

regroup_leaves_single_span_untouched_test() ->
    ?assertEqual([{<<"hi">>, #{fg => 1}}], tuition_text:regroup([{<<"hi">>, #{fg => 1}}])).

%%% -- truncate_line ---------------------------------------------------

truncate_line_clips_across_spans_test() ->
    ?assertEqual(
        [{<<"abc">>, #{fg => 1}}, {<<"d">>, #{fg => 2}}],
        tuition_text:truncate_line([{<<"abc">>, #{fg => 1}}, {<<"def">>, #{fg => 2}}], 4)
    ).

truncate_line_zero_is_empty_test() ->
    ?assertEqual([], tuition_text:truncate_line([{<<"abc">>, #{}}], 0)).

truncate_line_drops_wide_glyph_with_no_room_test() ->
    %% "a" fits in 2 columns; the following wide glyph needs 2 more and is dropped.
    ?assertEqual(
        [{<<"a">>, #{fg => 1}}],
        tuition_text:truncate_line([{<<"a世"/utf8>>, #{fg => 1}}], 2)
    ).

%%% -- put_line drawing ------------------------------------------------

put_line_draws_each_span_with_its_style_test() ->
    B = put([{<<"ab">>, #{fg => 1}}, {<<"cd">>, #{fg => 2}}], #{}, 0, 10),
    ?assertMatch(#cell{char = $a, fg = 1}, cell(B, 0, 0)),
    ?assertMatch(#cell{char = $b, fg = 1}, cell(B, 1, 0)),
    ?assertMatch(#cell{char = $c, fg = 2}, cell(B, 2, 0)),
    ?assertMatch(#cell{char = $d, fg = 2}, cell(B, 3, 0)).

put_line_span_style_overlays_base_test() ->
    %% The base supplies bg; the span supplies fg; a key the span sets overrides.
    B = put([{<<"x">>, #{fg => 1}}], #{bg => 5, fg => 9}, 0, 4),
    ?assertMatch(#cell{char = $x, fg = 1, bg = 5}, cell(B, 0, 0)).

put_line_advances_over_wide_glyph_test() ->
    B = put([{<<"世"/utf8>>, #{fg => 1}}, {<<"x">>, #{fg => 2}}], #{}, 0, 10),
    ?assertMatch(#cell{fg = 1}, cell(B, 0, 0)),
    ?assertMatch(#cell{char = $x, fg = 2}, cell(B, 2, 0)).

put_line_clips_at_area_edge_test() ->
    B = put([{<<"abcdef">>, #{}}], #{}, 0, 3),
    ?assertEqual($c, ch(B, 2, 0)),
    ?assertEqual($\s, ch(B, 3, 0)).

put_line_offsets_by_dcol_test() ->
    B = put([{<<"ab">>, #{}}], #{}, 2, 6),
    ?assertEqual($\s, ch(B, 0, 0)),
    ?assertEqual($a, ch(B, 2, 0)),
    ?assertEqual($b, ch(B, 3, 0)).

put_line_out_of_range_row_is_a_noop_test() ->
    B0 = buf(6, 2),
    Area = rect(0, 0, 6, 2),
    ?assertEqual(B0, tuition_text:put_line(B0, Area, 0, 2, [{<<"x">>, #{}}], #{})),
    ?assertEqual(B0, tuition_text:put_line(B0, Area, 0, -1, [{<<"x">>, #{}}], #{})).

put_line_out_of_range_col_is_a_noop_test() ->
    B0 = buf(6, 1),
    Area = rect(0, 0, 6, 1),
    ?assertEqual(B0, tuition_text:put_line(B0, Area, 6, 0, [{<<"x">>, #{}}], #{})),
    ?assertEqual(B0, tuition_text:put_line(B0, Area, -1, 0, [{<<"x">>, #{}}], #{})).

put_line_draws_into_area_at_its_origin_test() ->
    %% An area offset within the buffer draws relative to its own origin.
    B = tuition_text:put_line(buf(10, 3), rect(3, 1, 4, 1), 0, 0, [{<<"hi">>, #{fg => 1}}], #{}),
    ?assertMatch(#cell{char = $h, fg = 1}, cell(B, 3, 1)),
    ?assertEqual($i, ch(B, 4, 1)).

put_line_stitches_grapheme_split_across_spans_test() ->
    %% A base char in one span and its combining mark in the next render as the same
    %% single "é" cell (in the base span's style) as the whole cluster would — the
    %% accent is not lost as a lone zero-width cluster the renderer drops.
    Split = put([{<<16#65/utf8>>, #{}}, {<<16#301/utf8>>, #{fg => 1}}], #{}, 0, 4),
    Whole = put([{<<16#65/utf8, 16#301/utf8>>, #{}}], #{}, 0, 4),
    ?assertEqual(cell(Whole, 0, 0), cell(Split, 0, 0)),
    %% The composed cluster is one column wide: nothing spills into the next cell.
    ?assertEqual($\s, ch(Split, 1, 0)).
