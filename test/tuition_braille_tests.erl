-module(tuition_braille_tests).

-include_lib("eunit/include/eunit.hrl").
-include("tuition_layout.hrl").
-include("tuition_term.hrl").

%%% -- helpers ---------------------------------------------------------

rect(X, Y, W, H) -> #rect{x = X, y = Y, w = W, h = H}.
grid(W, H) -> tuition_braille:new(rect(0, 0, W, H)).
buf(W, H) -> tuition_render:new({W, H}).
render(Grid, W, H) -> tuition_braille:render_into(Grid, buf(W, H)).
cell(B, X, Y) -> tuition_render:cell_at(B, X, Y).
ch(B, X, Y) -> (cell(B, X, Y))#cell.char.

%% The glyph a single lit sub-pixel produces, in a one-cell grid.
single(GX, GY) ->
    ch(render(tuition_braille:set(grid(1, 1), GX, GY), 1, 1), 0, 0).

%%% -- dot geometry ----------------------------------------------------

%% Every sub-pixel maps to the standard braille dot bit: the left column carries
%% dots 1/2/3/7 and the right 4/5/6/8, the fourth row being dots 7/8.
dot_bit_mapping_test_() ->
    Cases = [
        {0, 0, 16#2801},
        {1, 0, 16#2808},
        {0, 1, 16#2802},
        {1, 1, 16#2810},
        {0, 2, 16#2804},
        {1, 2, 16#2820},
        {0, 3, 16#2840},
        {1, 3, 16#2880}
    ],
    [
        {lists:flatten(io_lib:format("dot ~p,~p", [X, Y])), ?_assertEqual(W, single(X, Y))}
     || {X, Y, W} <- Cases
    ].

all_dots_light_the_full_cell_test() ->
    G = lists:foldl(
        fun({X, Y}, A) -> tuition_braille:set(A, X, Y) end,
        grid(1, 1),
        [{X, Y} || X <- [0, 1], Y <- [0, 1, 2, 3]]
    ),
    ?assertEqual(16#28FF, ch(render(G, 1, 1), 0, 0)).

dots_accumulate_within_a_cell_test() ->
    %% Two dots in the same cell OR their bits: 0x01 | 0x02 = 0x03.
    G = tuition_braille:set(tuition_braille:set(grid(1, 1), 0, 0), 0, 1),
    ?assertEqual(16#2803, ch(render(G, 1, 1), 0, 0)).

sub_pixels_map_to_the_right_cell_test() ->
    %% A 2x2-cell grid is 4 sub-pixels wide, 8 tall. (2,4) lands in cell (1,1)'s
    %% top-left dot; (3,0) in cell (1,0)'s top-right dot; cell (0,0) stays blank.
    G = tuition_braille:set(tuition_braille:set(grid(2, 2), 2, 4), 3, 0),
    B = render(G, 2, 2),
    ?assertEqual(16#2801, ch(B, 1, 1)),
    ?assertEqual(16#2808, ch(B, 1, 0)),
    ?assertEqual($\s, ch(B, 0, 0)).

out_of_range_sub_pixels_are_dropped_test() ->
    %% Negative or past the 2W x 4H field: no-ops, leaving a blank buffer.
    G = lists:foldl(
        fun({X, Y}, A) -> tuition_braille:set(A, X, Y) end,
        grid(1, 1),
        [{-1, 0}, {0, -1}, {2, 0}, {0, 4}]
    ),
    ?assertEqual(buf(1, 1), render(G, 1, 1)).

%%% -- line rasterization ----------------------------------------------

vertical_line_lights_a_column_test() ->
    %% (0,0)->(0,3) lights the whole left column of a cell: 0x01|0x02|0x04|0x40.
    G = tuition_braille:line(grid(1, 1), 0, 0, 0, 3, default),
    ?assertEqual(16#2847, ch(render(G, 1, 1), 0, 0)).

horizontal_line_spans_cells_test() ->
    %% (0,0)->(3,0) across a 2-cell-wide grid lights the top row of both cells:
    %% each cell gets its two top dots, 0x01|0x08 = 0x09.
    G = tuition_braille:line(grid(2, 1), 0, 0, 3, 0, default),
    B = render(G, 2, 1),
    ?assertEqual(16#2809, ch(B, 0, 0)),
    ?assertEqual(16#2809, ch(B, 1, 0)).

diagonal_line_lights_intermediate_dots_test() ->
    %% (0,3)->(1,0) walks 0x40,0x04,0x10,0x08 = 0x5C — the Bresenham staircase,
    %% not just the two endpoints.
    G = tuition_braille:line(grid(1, 1), 0, 3, 1, 0, default),
    ?assertEqual(16#285C, ch(render(G, 1, 1), 0, 0)).

single_point_line_lights_one_dot_test() ->
    %% Degenerate line (start =:= end) lights exactly its one sub-pixel.
    G = tuition_braille:line(grid(1, 1), 1, 1, 1, 1, default),
    ?assertEqual(16#2810, ch(render(G, 1, 1), 0, 0)).

line_is_endpoint_symmetric_test() ->
    A = tuition_braille:line(grid(2, 2), 0, 0, 3, 7, default),
    B = tuition_braille:line(grid(2, 2), 3, 7, 0, 0, default),
    ?assertEqual(render(A, 2, 2), render(B, 2, 2)).

%%% -- colour ----------------------------------------------------------

per_cell_colour_is_applied_test() ->
    G = tuition_braille:set(grid(1, 1), 0, 0, 3),
    ?assertMatch(#cell{char = 16#2801, fg = 3}, cell(render(G, 1, 1), 0, 0)).

default_colour_keeps_base_foreground_test() ->
    %% A dot lit with the default colour takes the base style's fg, not its own.
    G = tuition_braille:set(grid(1, 1), 0, 0),
    B = tuition_braille:render_into(G, buf(1, 1), #{fg => 5}),
    ?assertMatch(#cell{char = 16#2801, fg = 5}, cell(B, 0, 0)).

cell_colour_overrides_base_foreground_test() ->
    %% The per-cell colour wins the fg; other base attributes (bg) ride along.
    G = tuition_braille:set(grid(1, 1), 0, 0, 2),
    B = tuition_braille:render_into(G, buf(1, 1), #{fg => 5, bg => 4}),
    ?assertMatch(#cell{char = 16#2801, fg = 2, bg = 4}, cell(B, 0, 0)).

last_write_wins_the_cell_colour_test() ->
    %% Both dots stay lit (0x01|0x08), but the cell takes the later colour.
    G0 = tuition_braille:set(grid(1, 1), 0, 0, 2),
    G1 = tuition_braille:set(G0, 1, 0, 4),
    ?assertMatch(#cell{char = 16#2809, fg = 4}, cell(render(G1, 1, 1), 0, 0)).

default_set_preserves_an_existing_cell_colour_test() ->
    %% A default-colour dot (set/3) added to an already-coloured cell OR-s in its
    %% dot (0x01|0x08) but leaves the prior colour intact — it has none to impose.
    G0 = tuition_braille:set(grid(1, 1), 0, 0, 3),
    G1 = tuition_braille:set(G0, 1, 0),
    ?assertMatch(#cell{char = 16#2809, fg = 3}, cell(render(G1, 1, 1), 0, 0)).

explicit_default_overrides_an_existing_colour_test() ->
    %% set/4 with `default' still claims the cell (last-writer-wins), resetting an
    %% earlier colour back to the terminal default — unlike the colourless set/3.
    G0 = tuition_braille:set(grid(1, 1), 0, 0, 3),
    G1 = tuition_braille:set(G0, 1, 0, default),
    ?assertMatch(#cell{char = 16#2809, fg = default}, cell(render(G1, 1, 1), 0, 0)).

%%% -- placement / emission --------------------------------------------

render_into_places_at_rect_origin_test() ->
    %% A grid over a rect offset into the buffer draws at that offset, nowhere else.
    G = tuition_braille:set(tuition_braille:new(rect(2, 1, 1, 1)), 0, 0),
    B = tuition_braille:render_into(G, buf(5, 3)),
    ?assertEqual(16#2801, ch(B, 2, 1)),
    ?assertEqual($\s, ch(B, 0, 0)).

dims_reports_the_sub_pixel_extent_test() ->
    ?assertEqual({6, 8}, tuition_braille:dims(grid(3, 2))),
    ?assertEqual({0, 0}, tuition_braille:dims(grid(0, 0))).

blank_grid_renders_nothing_test() ->
    ?assertEqual(buf(4, 3), render(grid(4, 3), 4, 3)).

%%% -- rectangles ------------------------------------------------------

rect_draws_the_outline_not_the_interior_test() ->
    %% A 3x3 sub-pixel box (corners (1,1) and (3,3)) lights its perimeter and
    %% leaves the interior sub-pixel (2,2) dark.
    G = tuition_braille:rect(grid(2, 1), 1, 1, 3, 3, default),
    Expected = lists:sort([
        {1, 1}, {2, 1}, {3, 1}, {1, 2}, {3, 2}, {1, 3}, {2, 3}, {3, 3}
    ]),
    ?assertEqual(Expected, lit_dots(G, 2, 1)),
    ?assertNot(lists:member({2, 2}, lit_dots(G, 2, 1))).

rect_is_corner_order_independent_test() ->
    %% The rectangle is the bounding box of the two corners — any ordering of the
    %% opposite corners draws the same outline.
    A = tuition_braille:rect(grid(2, 1), 1, 1, 3, 3, default),
    B = tuition_braille:rect(grid(2, 1), 3, 3, 1, 1, default),
    C = tuition_braille:rect(grid(2, 1), 3, 1, 1, 3, default),
    ?assertEqual(lit_dots(A, 2, 1), lit_dots(B, 2, 1)),
    ?assertEqual(lit_dots(A, 2, 1), lit_dots(C, 2, 1)).

rect_with_coincident_corners_is_a_dot_test() ->
    %% A zero-extent rectangle degenerates to the single sub-pixel of its corner.
    G = tuition_braille:rect(grid(2, 1), 2, 2, 2, 2, default),
    ?assertEqual([{2, 2}], lit_dots(G, 2, 1)).

rect_colours_the_cells_test() ->
    %% Every lit cell of the outline takes the rectangle's colour.
    G = tuition_braille:rect(grid(2, 1), 1, 1, 3, 3, 5),
    B = render(G, 2, 1),
    ?assertMatch(#cell{fg = 5}, cell(B, 0, 0)),
    ?assertMatch(#cell{fg = 5}, cell(B, 1, 0)).

%%% -- circles ---------------------------------------------------------

circle_of_zero_radius_is_the_centre_dot_test() ->
    G = tuition_braille:circle(grid(2, 1), 2, 2, 0, default),
    ?assertEqual([{2, 2}], lit_dots(G, 2, 1)).

circle_radius_one_is_the_four_axis_points_test() ->
    %% The smallest ring: the four sub-pixels one step from the centre on each
    %% axis, the centre itself left dark.
    G = tuition_braille:circle(grid(2, 1), 2, 2, 1, default),
    ?assertEqual(lists:sort([{1, 2}, {3, 2}, {2, 1}, {2, 3}]), lit_dots(G, 2, 1)),
    ?assertNot(lists:member({2, 2}, lit_dots(G, 2, 1))).

circle_radius_two_walks_the_octants_test() ->
    %% Radius 2 exercises more than one midpoint step: the full ring about centre
    %% (3,4) — the four axis points plus the eight one-off-axis points — with the
    %% interior dark. Every lit point sits a true distance ~2 from the centre.
    G = tuition_braille:circle(grid(4, 3), 3, 4, 2, default),
    Expected = lists:sort([
        {1, 3},
        {1, 4},
        {1, 5},
        {2, 2},
        {2, 6},
        {3, 2},
        {3, 6},
        {4, 2},
        {4, 6},
        {5, 3},
        {5, 4},
        {5, 5}
    ]),
    ?assertEqual(Expected, lit_dots(G, 4, 3)),
    ?assertNot(lists:member({3, 4}, lit_dots(G, 4, 3))).

circle_radius_three_stays_on_the_perimeter_test() ->
    %% Regression for the midpoint init: the walk must not pull X in a row too
    %% early. One row above the centre (y = 1) the perimeter pixel is (R,1) — here
    %% (8,6) at offset (+3,+1) from centre (5,5) — not the inward (7,6) at (+2,+1)
    %% that an `Err = 0' start would have lit instead.
    G = tuition_braille:circle(grid(5, 3), 5, 5, 3, default),
    Lit = lit_dots(G, 5, 3),
    ?assert(lists:member({8, 6}, Lit)),
    ?assertNot(lists:member({7, 6}, Lit)).

circle_clips_points_off_the_grid_test() ->
    %% Centred on a corner, only the arc that lands on-grid is drawn; the two
    %% points that fall to negative sub-pixels are dropped by set/4.
    G = tuition_braille:circle(grid(2, 1), 0, 0, 1, default),
    ?assertEqual(lists:sort([{1, 0}, {0, 1}]), lit_dots(G, 2, 1)).

circle_partly_off_grid_still_draws_its_arc_test() ->
    %% A radius that reaches past the field but whose ring still crosses it draws
    %% the on-grid arc — the bound only skips circles that miss the field entirely.
    G = tuition_braille:circle(grid(2, 1), 0, 0, 3, default),
    ?assertNotEqual([], lit_dots(G, 2, 1)).

circle_enclosing_the_grid_draws_nothing_test() ->
    %% A radius so large the whole field sits inside the ring can't put a dot
    %% on-grid, so the walk is skipped rather than run O(R) times over discards.
    G = tuition_braille:circle(grid(2, 1), 2, 2, 1000, default),
    ?assertEqual([], lit_dots(G, 2, 1)).

circle_far_from_the_grid_draws_nothing_test() ->
    %% A centre far outside the field with a radius too short to reach back is
    %% likewise skipped — the field lies entirely beyond the ring.
    G = tuition_braille:circle(grid(2, 1), 100, 100, 5, default),
    ?assertEqual([], lit_dots(G, 2, 1)).

%%% -- shape helpers ---------------------------------------------------

%% The sorted list of lit sub-pixels `{GX, GY}' of a grid, decoded from the
%% rendered braille glyphs — a blank cell contributes no dots.
lit_dots(Grid, W, H) ->
    B = render(Grid, W, H),
    lists:sort([
        {GX, GY}
     || GX <- lists:seq(0, 2 * W - 1),
        GY <- lists:seq(0, 4 * H - 1),
        dot_lit(B, GX, GY)
    ]).

%% Whether sub-pixel `{GX, GY}' is lit in the rendered buffer: decode its cell's
%% glyph back to an 8-bit mask (a non-braille cell — a blank space — is mask 0) and
%% test the dot's bit.
dot_lit(B, GX, GY) ->
    Mask =
        case ch(B, GX div 2, GY div 4) of
            C when C >= 16#2800, C =< 16#28FF -> C - 16#2800;
            _ -> 0
        end,
    Mask band dot_bit(GX rem 2, GY rem 4) =/= 0.

%% The 8-bit mask of one sub-pixel within its cell — the standard braille dot
%% numbering, mirrored from tuition_braille's private table.
dot_bit(0, 0) -> 16#01;
dot_bit(0, 1) -> 16#02;
dot_bit(0, 2) -> 16#04;
dot_bit(1, 0) -> 16#08;
dot_bit(1, 1) -> 16#10;
dot_bit(1, 2) -> 16#20;
dot_bit(0, 3) -> 16#40;
dot_bit(1, 3) -> 16#80.
