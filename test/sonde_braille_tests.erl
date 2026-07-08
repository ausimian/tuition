-module(sonde_braille_tests).

-include_lib("eunit/include/eunit.hrl").
-include("sonde_layout.hrl").
-include("sonde_term.hrl").

%%% -- helpers ---------------------------------------------------------

rect(X, Y, W, H) -> #rect{x = X, y = Y, w = W, h = H}.
grid(W, H) -> sonde_braille:new(rect(0, 0, W, H)).
buf(W, H) -> sonde_render:new({W, H}).
render(Grid, W, H) -> sonde_braille:render_into(Grid, buf(W, H)).
cell(B, X, Y) -> sonde_render:cell_at(B, X, Y).
ch(B, X, Y) -> (cell(B, X, Y))#cell.char.

%% The glyph a single lit sub-pixel produces, in a one-cell grid.
single(GX, GY) ->
    ch(render(sonde_braille:set(grid(1, 1), GX, GY), 1, 1), 0, 0).

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
        fun({X, Y}, A) -> sonde_braille:set(A, X, Y) end,
        grid(1, 1),
        [{X, Y} || X <- [0, 1], Y <- [0, 1, 2, 3]]
    ),
    ?assertEqual(16#28FF, ch(render(G, 1, 1), 0, 0)).

dots_accumulate_within_a_cell_test() ->
    %% Two dots in the same cell OR their bits: 0x01 | 0x02 = 0x03.
    G = sonde_braille:set(sonde_braille:set(grid(1, 1), 0, 0), 0, 1),
    ?assertEqual(16#2803, ch(render(G, 1, 1), 0, 0)).

sub_pixels_map_to_the_right_cell_test() ->
    %% A 2x2-cell grid is 4 sub-pixels wide, 8 tall. (2,4) lands in cell (1,1)'s
    %% top-left dot; (3,0) in cell (1,0)'s top-right dot; cell (0,0) stays blank.
    G = sonde_braille:set(sonde_braille:set(grid(2, 2), 2, 4), 3, 0),
    B = render(G, 2, 2),
    ?assertEqual(16#2801, ch(B, 1, 1)),
    ?assertEqual(16#2808, ch(B, 1, 0)),
    ?assertEqual($\s, ch(B, 0, 0)).

out_of_range_sub_pixels_are_dropped_test() ->
    %% Negative or past the 2W x 4H field: no-ops, leaving a blank buffer.
    G = lists:foldl(
        fun({X, Y}, A) -> sonde_braille:set(A, X, Y) end,
        grid(1, 1),
        [{-1, 0}, {0, -1}, {2, 0}, {0, 4}]
    ),
    ?assertEqual(buf(1, 1), render(G, 1, 1)).

%%% -- line rasterization ----------------------------------------------

vertical_line_lights_a_column_test() ->
    %% (0,0)->(0,3) lights the whole left column of a cell: 0x01|0x02|0x04|0x40.
    G = sonde_braille:line(grid(1, 1), 0, 0, 0, 3, default),
    ?assertEqual(16#2847, ch(render(G, 1, 1), 0, 0)).

horizontal_line_spans_cells_test() ->
    %% (0,0)->(3,0) across a 2-cell-wide grid lights the top row of both cells:
    %% each cell gets its two top dots, 0x01|0x08 = 0x09.
    G = sonde_braille:line(grid(2, 1), 0, 0, 3, 0, default),
    B = render(G, 2, 1),
    ?assertEqual(16#2809, ch(B, 0, 0)),
    ?assertEqual(16#2809, ch(B, 1, 0)).

diagonal_line_lights_intermediate_dots_test() ->
    %% (0,3)->(1,0) walks 0x40,0x04,0x10,0x08 = 0x5C — the Bresenham staircase,
    %% not just the two endpoints.
    G = sonde_braille:line(grid(1, 1), 0, 3, 1, 0, default),
    ?assertEqual(16#285C, ch(render(G, 1, 1), 0, 0)).

single_point_line_lights_one_dot_test() ->
    %% Degenerate line (start =:= end) lights exactly its one sub-pixel.
    G = sonde_braille:line(grid(1, 1), 1, 1, 1, 1, default),
    ?assertEqual(16#2810, ch(render(G, 1, 1), 0, 0)).

line_is_endpoint_symmetric_test() ->
    A = sonde_braille:line(grid(2, 2), 0, 0, 3, 7, default),
    B = sonde_braille:line(grid(2, 2), 3, 7, 0, 0, default),
    ?assertEqual(render(A, 2, 2), render(B, 2, 2)).

%%% -- colour ----------------------------------------------------------

per_cell_colour_is_applied_test() ->
    G = sonde_braille:set(grid(1, 1), 0, 0, 3),
    ?assertMatch(#cell{char = 16#2801, fg = 3}, cell(render(G, 1, 1), 0, 0)).

default_colour_keeps_base_foreground_test() ->
    %% A dot lit with the default colour takes the base style's fg, not its own.
    G = sonde_braille:set(grid(1, 1), 0, 0),
    B = sonde_braille:render_into(G, buf(1, 1), #{fg => 5}),
    ?assertMatch(#cell{char = 16#2801, fg = 5}, cell(B, 0, 0)).

cell_colour_overrides_base_foreground_test() ->
    %% The per-cell colour wins the fg; other base attributes (bg) ride along.
    G = sonde_braille:set(grid(1, 1), 0, 0, 2),
    B = sonde_braille:render_into(G, buf(1, 1), #{fg => 5, bg => 4}),
    ?assertMatch(#cell{char = 16#2801, fg = 2, bg = 4}, cell(B, 0, 0)).

last_write_wins_the_cell_colour_test() ->
    %% Both dots stay lit (0x01|0x08), but the cell takes the later colour.
    G0 = sonde_braille:set(grid(1, 1), 0, 0, 2),
    G1 = sonde_braille:set(G0, 1, 0, 4),
    ?assertMatch(#cell{char = 16#2809, fg = 4}, cell(render(G1, 1, 1), 0, 0)).

default_set_preserves_an_existing_cell_colour_test() ->
    %% A default-colour dot (set/3) added to an already-coloured cell OR-s in its
    %% dot (0x01|0x08) but leaves the prior colour intact — it has none to impose.
    G0 = sonde_braille:set(grid(1, 1), 0, 0, 3),
    G1 = sonde_braille:set(G0, 1, 0),
    ?assertMatch(#cell{char = 16#2809, fg = 3}, cell(render(G1, 1, 1), 0, 0)).

explicit_default_overrides_an_existing_colour_test() ->
    %% set/4 with `default' still claims the cell (last-writer-wins), resetting an
    %% earlier colour back to the terminal default — unlike the colourless set/3.
    G0 = sonde_braille:set(grid(1, 1), 0, 0, 3),
    G1 = sonde_braille:set(G0, 1, 0, default),
    ?assertMatch(#cell{char = 16#2809, fg = default}, cell(render(G1, 1, 1), 0, 0)).

%%% -- placement / emission --------------------------------------------

render_into_places_at_rect_origin_test() ->
    %% A grid over a rect offset into the buffer draws at that offset, nowhere else.
    G = sonde_braille:set(sonde_braille:new(rect(2, 1, 1, 1)), 0, 0),
    B = sonde_braille:render_into(G, buf(5, 3)),
    ?assertEqual(16#2801, ch(B, 2, 1)),
    ?assertEqual($\s, ch(B, 0, 0)).

dims_reports_the_sub_pixel_extent_test() ->
    ?assertEqual({6, 8}, sonde_braille:dims(grid(3, 2))),
    ?assertEqual({0, 0}, sonde_braille:dims(grid(0, 0))).

blank_grid_renders_nothing_test() ->
    ?assertEqual(buf(4, 3), render(grid(4, 3), 4, 3)).
