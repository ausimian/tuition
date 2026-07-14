-module(tuition_clear_tests).

-include_lib("eunit/include/eunit.hrl").
-include("tuition_layout.hrl").
-include("tuition_term.hrl").

%%% -- helpers ---------------------------------------------------------

buf(W, H) -> tuition_render:new({W, H}).
cell(B, X, Y) -> tuition_render:cell_at(B, X, Y).
ch(B, X, Y) -> (cell(B, X, Y))#cell.char.
rect(X, Y, W, H) -> #rect{x = X, y = Y, w = W, h = H}.

%% A buffer with `Text' drawn at {X, Y} in the default style — the "content
%% beneath" an overlay clears away.
drawn(W, H, X, Y, Text) ->
    tuition_render:put_text(buf(W, H), X, Y, Text).

clear(Cfg, Area, Buf) -> tuition_clear:render(Cfg, Area, Buf).

%%% -- the reset -------------------------------------------------------

blanks_content_drawn_beneath_test() ->
    %% Text drawn earlier this frame; Clear over the whole area wipes it.
    B0 = drawn(6, 1, 0, 0, <<"hello">>),
    ?assertEqual($h, ch(B0, 0, 0)),
    B1 = clear(#{}, rect(0, 0, 6, 1), B0),
    ?assertEqual($\s, ch(B1, 0, 0)),
    ?assertEqual($\s, ch(B1, 4, 0)).

default_resets_to_a_canonical_blank_buffer_test() ->
    %% Clearing the whole buffer with the default style leaves it `=:=' to a
    %% fresh blank buffer — every touched cell (and row) is removed, not merely
    %% painted over.
    B0 = drawn(8, 3, 1, 1, <<"content">>),
    ?assertNotEqual(buf(8, 3), B0),
    B1 = clear(#{}, rect(0, 0, 8, 3), B0),
    ?assertEqual(buf(8, 3), B1).

clears_every_row_of_a_multi_row_region_test() ->
    B0 = lists:foldl(
        fun(Y, B) -> tuition_render:put_text(B, 0, Y, <<"XXXX">>) end,
        buf(4, 3),
        [0, 1, 2]
    ),
    B1 = clear(#{}, rect(0, 0, 4, 3), B0),
    [?assertEqual($\s, ch(B1, X, Y)) || X <- [0, 1, 2, 3], Y <- [0, 1, 2]],
    ?assertEqual(buf(4, 3), B1).

%%% -- default overwrites (unlike widget:fill) -------------------------

default_style_overwrites_where_widget_fill_would_not_test() ->
    %% The whole point of Clear: an empty style still resets. The shared
    %% tuition_widget:fill/3 deliberately no-ops an empty style (so a parent's
    %% background shows through) — Clear must not.
    B0 = drawn(5, 1, 0, 0, <<"abcde">>),
    ?assertEqual(B0, tuition_widget:fill(B0, rect(0, 0, 5, 1), #{})),
    ?assertNotEqual(B0, clear(#{}, rect(0, 0, 5, 1), B0)),
    ?assertEqual($\s, ch(clear(#{}, rect(0, 0, 5, 1), B0), 0, 0)).

%%% -- a styled backdrop -----------------------------------------------

style_paints_a_styled_blank_test() ->
    %% A non-empty style lays a coloured backdrop: every cell a space at that bg.
    B0 = drawn(4, 1, 0, 0, <<"weld">>),
    B1 = clear(#{style => #{bg => 4}}, rect(0, 0, 4, 1), B0),
    [?assertMatch(#cell{char = $\s, bg = 4}, cell(B1, X, 0)) || X <- [0, 1, 2, 3]].

%%% -- confinement -----------------------------------------------------

only_clears_within_the_area_test() ->
    %% A sub-rect Clear leaves the cells around it untouched — the overlay wipes
    %% its own region, not the pane beneath.
    B0 = lists:foldl(
        fun(Y, B) -> tuition_render:put_text(B, 0, Y, <<"#####">>) end,
        buf(5, 3),
        [0, 1, 2]
    ),
    %% Clear the middle {1,1}..{3,1}.
    B1 = clear(#{}, rect(1, 1, 3, 1), B0),
    %% Cleared span is blank.
    ?assertEqual($\s, ch(B1, 1, 1)),
    ?assertEqual($\s, ch(B1, 3, 1)),
    %% Everything around it is preserved.
    ?assertEqual($#, ch(B1, 0, 1)),
    ?assertEqual($#, ch(B1, 4, 1)),
    ?assertEqual($#, ch(B1, 1, 0)),
    ?assertEqual($#, ch(B1, 1, 2)).

%%% -- wide glyphs -----------------------------------------------------

dissolves_a_wide_glyph_in_the_region_test() ->
    %% A two-column glyph beneath the overlay is reset whole — no orphaned half
    %% left straddling the cleared area.
    B0 = tuition_render:put_text(buf(4, 1), 0, 0, <<"中x"/utf8>>),
    ?assertEqual(16#4E2D, ch(B0, 0, 0)),
    B1 = clear(#{}, rect(0, 0, 4, 1), B0),
    ?assertEqual(buf(4, 1), B1).

%%% -- degenerate / no-op ----------------------------------------------

degenerate_area_draws_nothing_test() ->
    B0 = drawn(10, 3, 0, 0, <<"keep">>),
    ?assertEqual(B0, clear(#{}, rect(0, 0, 0, 3), B0)),
    ?assertEqual(B0, clear(#{}, rect(0, 0, 10, 0), B0)).

clearing_a_blank_buffer_is_a_no_op_test() ->
    B0 = buf(6, 2),
    ?assertEqual(B0, clear(#{}, rect(0, 0, 6, 2), B0)).
