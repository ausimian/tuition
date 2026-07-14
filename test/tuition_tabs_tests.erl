-module(tuition_tabs_tests).

-include_lib("eunit/include/eunit.hrl").
-include("tuition_layout.hrl").
-include("tuition_term.hrl").

%%% -- helpers ---------------------------------------------------------

%% U+2502 BOX DRAWINGS LIGHT VERTICAL — the default divider, mirrored from
%% tuition_tabs's private define.
-define(DIVIDER, 16#2502).

buf(W, H) -> tuition_render:new({W, H}).
cell(B, X, Y) -> tuition_render:cell_at(B, X, Y).
ch(B, X) -> (cell(B, X, 0))#cell.char.
rect(X, Y, W, H) -> #rect{x = X, y = Y, w = W, h = H}.

%% Render a bar into a W-wide, 1-tall rect at the origin.
bar(Cfg, W) ->
    tuition_tabs:render(Cfg, rect(0, 0, W, 1), buf(W, 1)).

%%% -- layout ----------------------------------------------------------

titles_are_laid_out_with_dividers_and_padding_test() ->
    %% Default padding 1 and divider │ give " A │ B │ C ": a leading blank, then
    %% each title flanked by a space, dividers between them.
    B = bar(#{titles => [<<"A">>, <<"B">>, <<"C">>]}, 20),
    ?assertEqual($\s, ch(B, 0)),
    ?assertEqual($A, ch(B, 1)),
    ?assertEqual($\s, ch(B, 2)),
    ?assertEqual(?DIVIDER, ch(B, 3)),
    ?assertEqual($\s, ch(B, 4)),
    ?assertEqual($B, ch(B, 5)),
    ?assertEqual(?DIVIDER, ch(B, 7)),
    ?assertEqual($C, ch(B, 9)),
    ?assertEqual($\s, ch(B, 10)).

zero_padding_packs_titles_against_the_dividers_test() ->
    %% padding 0: "A│B" with no surrounding blanks.
    B = bar(#{titles => [<<"A">>, <<"B">>], padding => 0}, 10),
    ?assertEqual($A, ch(B, 0)),
    ?assertEqual(?DIVIDER, ch(B, 1)),
    ?assertEqual($B, ch(B, 2)).

custom_divider_glyph_overrides_the_default_test() ->
    B = bar(#{titles => [<<"A">>, <<"B">>], padding => 0, divider => <<"|">>}, 10),
    ?assertEqual($|, ch(B, 1)).

%%% -- selection -------------------------------------------------------

selected_title_carries_the_highlight_style_test() ->
    %% selected 1 -> "B" (col 5) is highlighted; the other titles keep the base
    %% style.
    B = bar(
        #{titles => [<<"A">>, <<"B">>, <<"C">>], selected => 1, highlight_style => #{fg => 5}}, 20
    ),
    ?assertMatch(#cell{char = $B, fg = 5}, cell(B, 5, 0)),
    ?assertMatch(#cell{char = $A, fg = default}, cell(B, 1, 0)),
    ?assertMatch(#cell{char = $C, fg = default}, cell(B, 9, 0)).

selection_defaults_to_the_first_tab_test() ->
    %% No `selected' key -> index 0 is highlighted.
    B = bar(#{titles => [<<"A">>, <<"B">>], highlight_style => #{fg => 5}}, 20),
    ?assertMatch(#cell{char = $A, fg = 5}, cell(B, 1, 0)),
    ?assertMatch(#cell{char = $B, fg = default}, cell(B, 5, 0)).

out_of_range_selection_highlights_nothing_test() ->
    %% A stale index past the end draws every title in the base style rather than
    %% crashing or highlighting a phantom tab.
    B = bar(#{titles => [<<"A">>, <<"B">>], selected => 9, highlight_style => #{fg => 5}}, 20),
    ?assertMatch(#cell{char = $A, fg = default}, cell(B, 1, 0)),
    ?assertMatch(#cell{char = $B, fg = default}, cell(B, 5, 0)).

%%% -- alignment -------------------------------------------------------

center_align_offsets_the_strip_test() ->
    %% Row width 11 (" A │ B │ C ") in a 21-wide area -> offset (21-11)/2 = 5, so
    %% "A" lands at 5 + leading pad = 6.
    B = bar(#{titles => [<<"A">>, <<"B">>, <<"C">>], title_align => center}, 21),
    ?assertEqual($A, ch(B, 6)),
    ?assertEqual($\s, ch(B, 0)).

right_align_pushes_the_strip_to_the_edge_test() ->
    %% Offset 21-11 = 10, so "A" lands at 11 and "C" at 19 (trailing pad at 20).
    B = bar(#{titles => [<<"A">>, <<"B">>, <<"C">>], title_align => right}, 21),
    ?assertEqual($A, ch(B, 11)),
    ?assertEqual($C, ch(B, 19)).

%%% -- overflow --------------------------------------------------------

overflow_is_truncated_at_the_area_edge_test() ->
    %% A 5-wide area shows " A │ " then runs out; "B" (which would start at col 5)
    %% and everything after it are clipped, not wrapped.
    B = bar(#{titles => [<<"A">>, <<"B">>, <<"C">>]}, 5),
    ?assertEqual($A, ch(B, 1)),
    ?assertEqual(?DIVIDER, ch(B, 3)),
    %% Nothing beyond the divider: the last visible cell is the padding blank.
    ?assertEqual($\s, ch(B, 4)).

wide_glyph_straddling_the_edge_is_dropped_whole_test() ->
    %% "中" is two columns. With one column of room it is dropped rather than
    %% split into a stray half...
    B1 = bar(#{titles => [<<"中"/utf8>>], padding => 0}, 1),
    ?assertEqual($\s, ch(B1, 0)),
    %% ...but with two columns it renders, the trailing cell a wide-continuation.
    B2 = bar(#{titles => [<<"中"/utf8>>], padding => 0}, 2),
    ?assertEqual(16#4E2D, ch(B2, 0)),
    ?assertEqual(wide_cont, cell(B2, 1, 0)).

%%% -- styling ---------------------------------------------------------

base_style_fills_the_whole_strip_test() ->
    %% `style' paints the background across the area — padding cells included —
    %% and the selected title still carries its highlight over that fill.
    B = bar(
        #{
            titles => [<<"A">>, <<"B">>],
            selected => 0,
            style => #{bg => 3},
            highlight_style => #{fg => 5}
        },
        20
    ),
    %% A padding cell shows the base fill.
    ?assertMatch(#cell{bg = 3}, cell(B, 0, 0)),
    %% The selected title has both the base bg and the highlight fg.
    ?assertMatch(#cell{char = $A, bg = 3, fg = 5}, cell(B, 1, 0)),
    %% An unselected title keeps the base style only.
    ?assertMatch(#cell{char = $B, bg = 3, fg = default}, cell(B, 5, 0)).

%%% -- degenerate ------------------------------------------------------

empty_titles_draw_nothing_when_unstyled_test() ->
    B0 = buf(5, 1),
    ?assertEqual(B0, tuition_tabs:render(#{titles => []}, rect(0, 0, 5, 1), B0)).

degenerate_area_draws_nothing_test() ->
    B0 = buf(5, 1),
    ?assertEqual(B0, tuition_tabs:render(#{titles => [<<"A">>]}, rect(0, 0, 0, 1), B0)),
    ?assertEqual(B0, tuition_tabs:render(#{titles => [<<"A">>]}, rect(0, 0, 5, 0), B0)).
