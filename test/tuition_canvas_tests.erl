-module(tuition_canvas_tests).

-include_lib("eunit/include/eunit.hrl").
-include("tuition_layout.hrl").
-include("tuition_term.hrl").

%%% -- helpers ---------------------------------------------------------

buf(W, H) -> tuition_render:new({W, H}).
cell(B, X, Y) -> tuition_render:cell_at(B, X, Y).
ch(B, X, Y) -> (cell(B, X, Y))#cell.char.
rect(X, Y, W, H) -> #rect{x = X, y = Y, w = W, h = H}.

render(Cfg, W, H) ->
    tuition_canvas:render(Cfg, rect(0, 0, W, H), buf(W, H)).

%% A canvas over the value square [0,10]x[0,10], the mapping most tests exercise.
unit10(Shapes, W, H) ->
    render(#{x_bounds => {0, 10}, y_bounds => {0, 10}, shapes => Shapes}, W, H).

%%% -- coordinate mapping ----------------------------------------------

ymax_maps_to_the_top_row_test() ->
    %% y at the top of the bounds -> the cell's top-left dot (0x01).
    B = unit10([{points, [{0, 10}], default}], 1, 1),
    ?assertEqual(16#2801, ch(B, 0, 0)).

ymin_maps_to_the_bottom_row_test() ->
    %% y at the bottom -> dot 7 (0x40), the lowest left dot: the y-axis points up.
    B = unit10([{points, [{0, 0}], default}], 1, 1),
    ?assertEqual(16#2840, ch(B, 0, 0)).

xmax_maps_to_the_right_column_test() ->
    %% x at the right of the bounds -> the cell's right column (dot 4, 0x08).
    B = unit10([{points, [{10, 10}], default}], 1, 1),
    ?assertEqual(16#2808, ch(B, 0, 0)).

default_bounds_are_the_unit_square_test() ->
    %% With no bounds, a coordinate is its fraction of the area: (1,1) is the
    %% top-right sub-pixel (0x08), (0,0) the bottom-left (0x40).
    B1 = render(#{shapes => [{points, [{1, 1}], default}]}, 1, 1),
    B2 = render(#{shapes => [{points, [{0, 0}], default}]}, 1, 1),
    ?assertEqual(16#2808, ch(B1, 0, 0)),
    ?assertEqual(16#2840, ch(B2, 0, 0)).

out_of_bounds_coordinates_clamp_to_the_edge_test() ->
    %% A value past the max saturates at the far edge; past the min at the near
    %% edge — never off-grid, never wrapped.
    Above = unit10([{points, [{999, 10}], default}], 1, 1),
    Below = unit10([{points, [{-5, -5}], default}], 1, 1),
    ?assertEqual(16#2808, ch(Above, 0, 0)),
    ?assertEqual(16#2840, ch(Below, 0, 0)).

degenerate_bounds_map_to_the_middle_test() ->
    %% A zero-width x-range has no gradient, so every x maps to the same (middle)
    %% column regardless of value — the flat-series fallback.
    B1 = render(
        #{x_bounds => {5, 5}, y_bounds => {0, 10}, shapes => [{points, [{0, 10}], default}]}, 3, 1
    ),
    B2 = render(
        #{x_bounds => {5, 5}, y_bounds => {0, 10}, shapes => [{points, [{999, 10}], default}]}, 3, 1
    ),
    ?assertEqual(16#2808, ch(B1, 1, 0)),
    ?assertEqual(B1, B2).

%%% -- shapes ----------------------------------------------------------

line_rasterizes_between_two_value_points_test() ->
    %% (0,0)->(10,10) maps to the sub-pixel diagonal (0,3)->(1,0): the Bresenham
    %% staircase 0x5C, not just the endpoints.
    B = unit10([{line, 0, 0, 10, 10, default}], 1, 1),
    ?assertEqual(16#285C, ch(B, 0, 0)).

points_light_each_value_point_test() ->
    %% Two points at the top corners merge into the one cell's top row (0x01|0x08).
    B = unit10([{points, [{0, 10}, {10, 10}], default}], 1, 1),
    ?assertEqual(16#2809, ch(B, 0, 0)).

points_take_their_colour_test() ->
    B = unit10([{points, [{0, 10}], 3}], 1, 1),
    ?assertMatch(#cell{char = 16#2801, fg = 3}, cell(B, 0, 0)).

rect_draws_an_outline_not_a_fill_test() ->
    %% A rectangle spanning the whole unit canvas over a 3x3 area: its border cells
    %% are lit, the fully-interior cell (1,1) stays blank.
    B = render(#{shapes => [{rect, 0, 0, 1, 1, default}]}, 3, 3),
    ?assertEqual($\s, ch(B, 1, 1)),
    ?assertNotEqual($\s, ch(B, 0, 0)),
    ?assertNotEqual($\s, ch(B, 2, 2)).

rect_takes_its_colour_test() ->
    B = render(#{shapes => [{rect, 0, 0, 1, 1, 4}]}, 3, 3),
    ?assertMatch(#cell{fg = 4}, cell(B, 0, 0)).

circle_draws_a_ring_test() ->
    %% Centre (2,2) radius 1 over [0,4]x[0,4] on a 2x1 area maps to the sub-pixel
    %% ring (1,2),(3,2),(2,1),(2,3) around centre sub-pixel (2,2), which stays dark.
    B = render(
        #{x_bounds => {0, 4}, y_bounds => {0, 4}, shapes => [{circle, 2, 2, 1, default}]}, 2, 1
    ),
    ?assertEqual(16#2820, ch(B, 0, 0)),
    ?assertEqual(16#2862, ch(B, 1, 0)).

circle_negative_radius_is_degenerate_test() ->
    %% A negative radius floors to 0 (matching the kernel) — the centre dot only,
    %% never mirrored into a positive-radius ring. Centre (2,2) over [0,4]x[0,4] on
    %% a 2x1 area is sub-pixel (2,2): cell 1's top-left-column dot (0x04), cell 0
    %% blank.
    B = render(
        #{x_bounds => {0, 4}, y_bounds => {0, 4}, shapes => [{circle, 2, 2, -1, default}]}, 2, 1
    ),
    ?assertEqual($\s, ch(B, 0, 0)),
    ?assertEqual(16#2804, ch(B, 1, 0)).

unknown_shapes_are_ignored_test() ->
    %% A forward-compatible caller may pass shapes an older build cannot draw; they
    %% are skipped, and the shapes around them still draw.
    B = unit10([{blob, 1, 2, 3}, foo, {points, [{0, 10}], default}, {rect, 0, 0}], 1, 1),
    ?assertEqual(16#2801, ch(B, 0, 0)).

%%% -- draw order / layering -------------------------------------------

later_shape_wins_a_shared_cell_colour_test() ->
    %% Two shapes lighting dots in the same cell: the dots merge (0x01|0x08) but
    %% the later shape claims the cell's colour — the one-colour-per-cell rule.
    B = unit10([{points, [{0, 10}], 2}, {points, [{10, 10}], 4}], 1, 1),
    ?assertMatch(#cell{char = 16#2809, fg = 4}, cell(B, 0, 0)).

%%% -- background / style ----------------------------------------------

background_fills_the_area_test() ->
    B = render(#{background => #{bg => 1}, shapes => []}, 2, 1),
    ?assertMatch(#cell{bg = 1}, cell(B, 0, 0)),
    ?assertMatch(#cell{bg = 1}, cell(B, 1, 0)).

background_shows_under_glyph_cells_test() ->
    %% A glyph cell inherits the backdrop's bg rather than punching a default-bg
    %% hole in the fill.
    B = render(
        #{
            x_bounds => {0, 10},
            y_bounds => {0, 10},
            background => #{bg => 1},
            shapes => [{points, [{0, 10}], 3}]
        },
        1,
        1
    ),
    ?assertMatch(#cell{char = 16#2801, fg = 3, bg = 1}, cell(B, 0, 0)).

no_background_leaves_the_buffer_untouched_test() ->
    %% Empty background + no shapes composites over whatever is underneath, drawing
    %% nothing of its own.
    B0 = buf(2, 1),
    ?assertEqual(B0, render(#{shapes => []}, 2, 1)).

base_style_colours_default_shapes_test() ->
    %% A default-coloured shape takes the base style's fg; a coloured shape
    %% overrides the fg but rides on the base's other attributes.
    Default = unit10([{points, [{0, 10}], default}], 1, 1),
    Styled = render(
        #{
            x_bounds => {0, 10},
            y_bounds => {0, 10},
            shapes => [{points, [{0, 10}], default}],
            style => #{fg => 7}
        },
        1,
        1
    ),
    Coloured = render(
        #{
            x_bounds => {0, 10},
            y_bounds => {0, 10},
            shapes => [{points, [{0, 10}], 3}],
            style => #{fg => 7, bold => true}
        },
        1,
        1
    ),
    ?assertMatch(#cell{fg = default}, cell(Default, 0, 0)),
    ?assertMatch(#cell{char = 16#2801, fg = 7}, cell(Styled, 0, 0)),
    ?assertMatch(#cell{char = 16#2801, fg = 3, bold = true}, cell(Coloured, 0, 0)).

%%% -- degenerate ------------------------------------------------------

empty_canvas_draws_nothing_test() ->
    B0 = buf(6, 3),
    ?assertEqual(B0, tuition_canvas:render(#{}, rect(0, 0, 6, 3), B0)).

degenerate_area_draws_nothing_test() ->
    B0 = buf(10, 3),
    Cfg = #{shapes => [{points, [{0, 0}], 1}]},
    ?assertEqual(B0, tuition_canvas:render(Cfg, rect(0, 0, 0, 3), B0)),
    ?assertEqual(B0, tuition_canvas:render(Cfg, rect(0, 0, 10, 0), B0)).
