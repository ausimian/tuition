-module(tuition_block_tests).

-include_lib("eunit/include/eunit.hrl").
-include("tuition_layout.hrl").
-include("tuition_term.hrl").

%%% -- helpers ---------------------------------------------------------

buf(W, H) -> tuition_render:new({W, H}).
cell(B, X, Y) -> tuition_render:cell_at(B, X, Y).
ch(B, X, Y) -> (cell(B, X, Y))#cell.char.
frame(B, W, H) -> iolist_to_binary(tuition_render:diff(tuition_render:new({W, H}), B)).

%% Light box-drawing glyphs, mirrored from tuition_block's private defines.
-define(HORIZ, 16#2500).
-define(VERT, 16#2502).
-define(TOP_LEFT, 16#250C).
-define(TOP_RIGHT, 16#2510).
-define(BOT_LEFT, 16#2514).
-define(BOT_RIGHT, 16#2518).

%%% -- border ----------------------------------------------------------

full_border_draws_edges_and_corners_test() ->
    B = tuition_block:render(#{borders => all}, #rect{x = 0, y = 0, w = 4, h = 3}, buf(4, 3)),
    ?assertEqual(?TOP_LEFT, ch(B, 0, 0)),
    ?assertEqual(?TOP_RIGHT, ch(B, 3, 0)),
    ?assertEqual(?BOT_LEFT, ch(B, 0, 2)),
    ?assertEqual(?BOT_RIGHT, ch(B, 3, 2)),
    ?assertEqual(?HORIZ, ch(B, 1, 0)),
    ?assertEqual(?HORIZ, ch(B, 2, 2)),
    ?assertEqual(?VERT, ch(B, 0, 1)),
    ?assertEqual(?VERT, ch(B, 3, 1)),
    %% The interior is untouched.
    ?assertEqual($\s, ch(B, 1, 1)).

subset_sides_draw_only_requested_edges_test() ->
    %% Only top + left: a corner where they meet, no bottom/right runs.
    B = tuition_block:render(
        #{borders => [top, left]}, #rect{x = 0, y = 0, w = 4, h = 3}, buf(4, 3)
    ),
    ?assertEqual(?TOP_LEFT, ch(B, 0, 0)),
    ?assertEqual(?HORIZ, ch(B, 2, 0)),
    ?assertEqual(?VERT, ch(B, 0, 1)),
    %% No right edge, no bottom edge.
    ?assertEqual($\s, ch(B, 3, 1)),
    ?assertEqual($\s, ch(B, 2, 2)),
    %% No top-right corner (top present, right absent).
    ?assertEqual(?HORIZ, ch(B, 3, 0)).

border_style_applies_test() ->
    B = tuition_block:render(
        #{borders => all, border_style => #{fg => 5}},
        #rect{x = 0, y = 0, w = 4, h = 3},
        buf(4, 3)
    ),
    ?assertMatch(#cell{char = ?TOP_LEFT, fg = 5}, cell(B, 0, 0)),
    ?assertMatch(#cell{char = ?VERT, fg = 5}, cell(B, 0, 1)).

background_fills_the_area_test() ->
    B = tuition_block:render(
        #{borders => none, style => #{bg => 2}},
        #rect{x = 0, y = 0, w = 4, h = 3},
        buf(4, 3)
    ),
    ?assertMatch(#cell{bg = 2}, cell(B, 0, 0)),
    ?assertMatch(#cell{bg = 2}, cell(B, 3, 2)).

degenerate_area_is_a_noop_test() ->
    B0 = buf(4, 3),
    ?assertEqual(
        B0, tuition_block:render(#{borders => all}, #rect{x = 0, y = 0, w = 0, h = 3}, B0)
    ),
    ?assertEqual(
        B0, tuition_block:render(#{borders => all}, #rect{x = 0, y = 0, w = 4, h = 0}, B0)
    ).

%%% -- border_type -----------------------------------------------------

default_border_type_is_light_test() ->
    %% An absent border_type reproduces the light glyph set exactly.
    B = tuition_block:render(#{borders => all}, #rect{x = 0, y = 0, w = 4, h = 3}, buf(4, 3)),
    ?assertEqual(?TOP_LEFT, ch(B, 0, 0)),
    ?assertEqual(?HORIZ, ch(B, 1, 0)),
    ?assertEqual(?VERT, ch(B, 0, 1)).

rounded_border_rounds_only_the_corners_test() ->
    B = tuition_block:render(
        #{borders => all, border_type => rounded}, #rect{x = 0, y = 0, w = 4, h = 3}, buf(4, 3)
    ),
    ?assertEqual(16#256D, ch(B, 0, 0)),
    ?assertEqual(16#256E, ch(B, 3, 0)),
    ?assertEqual(16#2570, ch(B, 0, 2)),
    ?assertEqual(16#256F, ch(B, 3, 2)),
    %% The straight runs stay the light glyphs.
    ?assertEqual(?HORIZ, ch(B, 1, 0)),
    ?assertEqual(?VERT, ch(B, 0, 1)).

double_border_uses_double_glyphs_test() ->
    B = tuition_block:render(
        #{borders => all, border_type => double}, #rect{x = 0, y = 0, w = 4, h = 3}, buf(4, 3)
    ),
    ?assertEqual(16#2554, ch(B, 0, 0)),
    ?assertEqual(16#2557, ch(B, 3, 0)),
    ?assertEqual(16#255A, ch(B, 0, 2)),
    ?assertEqual(16#255D, ch(B, 3, 2)),
    ?assertEqual(16#2550, ch(B, 1, 0)),
    ?assertEqual(16#2551, ch(B, 0, 1)).

thick_border_uses_heavy_glyphs_test() ->
    B = tuition_block:render(
        #{borders => all, border_type => thick}, #rect{x = 0, y = 0, w = 4, h = 3}, buf(4, 3)
    ),
    ?assertEqual(16#250F, ch(B, 0, 0)),
    ?assertEqual(16#2513, ch(B, 3, 0)),
    ?assertEqual(16#2517, ch(B, 0, 2)),
    ?assertEqual(16#251B, ch(B, 3, 2)),
    ?assertEqual(16#2501, ch(B, 1, 0)),
    ?assertEqual(16#2503, ch(B, 0, 1)).

border_type_keeps_the_side_subset_logic_test() ->
    %% Only the glyphs change: a top+left subset draws its corner and two runs in
    %% the double set, and nothing on the absent sides.
    B = tuition_block:render(
        #{borders => [top, left], border_type => double},
        #rect{x = 0, y = 0, w = 4, h = 3},
        buf(4, 3)
    ),
    ?assertEqual(16#2554, ch(B, 0, 0)),
    ?assertEqual(16#2550, ch(B, 2, 0)),
    ?assertEqual(16#2551, ch(B, 0, 1)),
    ?assertEqual($\s, ch(B, 3, 1)),
    ?assertEqual($\s, ch(B, 2, 2)).

%%% -- title -----------------------------------------------------------

title_drawn_after_the_left_corner_test() ->
    B = tuition_block:render(
        #{borders => all, title => <<"Hi">>},
        #rect{x = 0, y = 0, w = 12, h = 3},
        buf(12, 3)
    ),
    ?assertEqual($H, ch(B, 1, 0)),
    ?assertEqual($i, ch(B, 2, 0)),
    ?assertMatch({_, _}, binary:match(frame(B, 12, 3), <<"Hi">>)).

title_centre_aligned_test() ->
    %% Width 12, both side borders -> 10 columns of span; "Hi" (2) centres with a
    %% 4-column left pad, so it starts at column 1 + 4 = 5.
    B = tuition_block:render(
        #{borders => all, title => <<"Hi">>, title_align => center},
        #rect{x = 0, y = 0, w = 12, h = 3},
        buf(12, 3)
    ),
    ?assertEqual($H, ch(B, 5, 0)),
    ?assertEqual($i, ch(B, 6, 0)).

title_right_aligned_test() ->
    %% Span 10, "Hi" flush right -> starts at column 1 + (10 - 2) = 9.
    B = tuition_block:render(
        #{borders => all, title => <<"Hi">>, title_align => right},
        #rect{x = 0, y = 0, w = 12, h = 3},
        buf(12, 3)
    ),
    ?assertEqual($H, ch(B, 9, 0)),
    ?assertEqual($i, ch(B, 10, 0)).

title_truncated_to_span_and_spares_corner_test() ->
    %% Width 4, all borders -> span of 2; "Hello" truncates to "He" and the
    %% top-right corner at column 3 is preserved.
    B = tuition_block:render(
        #{borders => all, title => <<"Hello">>},
        #rect{x = 0, y = 0, w = 4, h = 3},
        buf(4, 3)
    ),
    ?assertEqual($H, ch(B, 1, 0)),
    ?assertEqual($e, ch(B, 2, 0)),
    ?assertEqual(?TOP_RIGHT, ch(B, 3, 0)).

title_style_defaults_to_border_style_test() ->
    B = tuition_block:render(
        #{borders => all, title => <<"Hi">>, border_style => #{fg => 3}},
        #rect{x = 0, y = 0, w = 12, h = 3},
        buf(12, 3)
    ),
    ?assertMatch(#cell{char = $H, fg = 3}, cell(B, 1, 0)).

%%% -- inner -----------------------------------------------------------

inner_all_borders_inset_one_each_test() ->
    ?assertEqual(
        #rect{x = 1, y = 1, w = 2, h = 1},
        tuition_block:inner(#{borders => all}, #rect{x = 0, y = 0, w = 4, h = 3})
    ).

inner_no_borders_is_the_area_test() ->
    ?assertEqual(
        #rect{x = 0, y = 0, w = 4, h = 3},
        tuition_block:inner(#{borders => none}, #rect{x = 0, y = 0, w = 4, h = 3})
    ).

inner_subset_sides_test() ->
    ?assertEqual(
        #rect{x = 1, y = 1, w = 3, h = 2},
        tuition_block:inner(#{borders => [left, top]}, #rect{x = 0, y = 0, w = 4, h = 3})
    ).

inner_clamps_to_zero_when_too_small_test() ->
    ?assertEqual(
        #rect{x = 1, y = 1, w = 0, h = 0},
        tuition_block:inner(#{borders => all}, #rect{x = 0, y = 0, w = 1, h = 1})
    ).

inner_default_borders_are_all_test() ->
    %% An empty config borders like `all', so inner insets one cell each side.
    ?assertEqual(
        #rect{x = 3, y = 6, w = 8, h = 8},
        tuition_block:inner(#{}, #rect{x = 2, y = 5, w = 10, h = 10})
    ).

%%% -- padding ---------------------------------------------------------

inner_default_padding_is_zero_test() ->
    %% An absent padding key matches an explicit 0 — today's borders-only inset.
    ?assertEqual(
        tuition_block:inner(#{borders => all}, #rect{x = 0, y = 0, w = 10, h = 10}),
        tuition_block:inner(#{borders => all, padding => 0}, #rect{x = 0, y = 0, w = 10, h = 10})
    ).

inner_uniform_padding_insets_all_sides_test() ->
    %% All borders (1 each) plus a uniform padding of 1 -> 2 cells in on every side.
    ?assertEqual(
        #rect{x = 2, y = 2, w = 6, h = 6},
        tuition_block:inner(#{borders => all, padding => 1}, #rect{x = 0, y = 0, w = 10, h = 10})
    ).

inner_tuple_padding_is_top_right_bottom_left_test() ->
    %% No borders, padding {Top, Right, Bottom, Left} = {1, 2, 3, 4}.
    ?assertEqual(
        #rect{x = 4, y = 1, w = 20 - 4 - 2, h = 20 - 1 - 3},
        tuition_block:inner(
            #{borders => none, padding => {1, 2, 3, 4}}, #rect{x = 0, y = 0, w = 20, h = 20}
        )
    ).

inner_padding_adds_to_the_border_inset_test() ->
    %% Borders (1 each) and padding {1, 2, 3, 4} stack.
    ?assertEqual(
        #rect{x = 1 + 4, y = 1 + 1, w = 20 - 2 - 6, h = 20 - 2 - 4},
        tuition_block:inner(
            #{borders => all, padding => {1, 2, 3, 4}}, #rect{x = 0, y = 0, w = 20, h = 20}
        )
    ).

inner_padding_clamps_to_zero_when_too_big_test() ->
    %% Padding wider than the area yields an empty inner rect, not a negative one.
    ?assertEqual(
        #rect{x = 5, y = 5, w = 0, h = 0},
        tuition_block:inner(#{borders => none, padding => 5}, #rect{x = 0, y = 0, w = 4, h = 4})
    ).

padding_leaves_the_border_and_title_in_place_test() ->
    %% padding only shifts inner/2; the drawn frame and title are unaffected.
    Cfg = #{borders => all, title => <<"Hi">>, padding => 2},
    B = tuition_block:render(Cfg, #rect{x = 0, y = 0, w = 12, h = 6}, buf(12, 6)),
    ?assertEqual(?TOP_LEFT, ch(B, 0, 0)),
    ?assertEqual(?BOT_RIGHT, ch(B, 11, 5)),
    ?assertEqual($H, ch(B, 1, 0)),
    ?assertEqual($i, ch(B, 2, 0)).
