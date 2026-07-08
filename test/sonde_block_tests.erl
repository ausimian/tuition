-module(sonde_block_tests).

-include_lib("eunit/include/eunit.hrl").
-include("sonde_layout.hrl").
-include("sonde_term.hrl").

%%% -- helpers ---------------------------------------------------------

buf(W, H) -> sonde_render:new({W, H}).
cell(B, X, Y) -> sonde_render:cell_at(B, X, Y).
ch(B, X, Y) -> (cell(B, X, Y))#cell.char.
frame(B, W, H) -> iolist_to_binary(sonde_render:diff(sonde_render:new({W, H}), B)).

%% Light box-drawing glyphs, mirrored from sonde_block's private defines.
-define(HORIZ, 16#2500).
-define(VERT, 16#2502).
-define(TOP_LEFT, 16#250C).
-define(TOP_RIGHT, 16#2510).
-define(BOT_LEFT, 16#2514).
-define(BOT_RIGHT, 16#2518).

%%% -- border ----------------------------------------------------------

full_border_draws_edges_and_corners_test() ->
    B = sonde_block:render(#{borders => all}, #rect{x = 0, y = 0, w = 4, h = 3}, buf(4, 3)),
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
    B = sonde_block:render(#{borders => [top, left]}, #rect{x = 0, y = 0, w = 4, h = 3}, buf(4, 3)),
    ?assertEqual(?TOP_LEFT, ch(B, 0, 0)),
    ?assertEqual(?HORIZ, ch(B, 2, 0)),
    ?assertEqual(?VERT, ch(B, 0, 1)),
    %% No right edge, no bottom edge.
    ?assertEqual($\s, ch(B, 3, 1)),
    ?assertEqual($\s, ch(B, 2, 2)),
    %% No top-right corner (top present, right absent).
    ?assertEqual(?HORIZ, ch(B, 3, 0)).

border_style_applies_test() ->
    B = sonde_block:render(
        #{borders => all, border_style => #{fg => 5}},
        #rect{x = 0, y = 0, w = 4, h = 3},
        buf(4, 3)
    ),
    ?assertMatch(#cell{char = ?TOP_LEFT, fg = 5}, cell(B, 0, 0)),
    ?assertMatch(#cell{char = ?VERT, fg = 5}, cell(B, 0, 1)).

background_fills_the_area_test() ->
    B = sonde_block:render(
        #{borders => none, style => #{bg => 2}},
        #rect{x = 0, y = 0, w = 4, h = 3},
        buf(4, 3)
    ),
    ?assertMatch(#cell{bg = 2}, cell(B, 0, 0)),
    ?assertMatch(#cell{bg = 2}, cell(B, 3, 2)).

degenerate_area_is_a_noop_test() ->
    B0 = buf(4, 3),
    ?assertEqual(B0, sonde_block:render(#{borders => all}, #rect{x = 0, y = 0, w = 0, h = 3}, B0)),
    ?assertEqual(B0, sonde_block:render(#{borders => all}, #rect{x = 0, y = 0, w = 4, h = 0}, B0)).

%%% -- title -----------------------------------------------------------

title_drawn_after_the_left_corner_test() ->
    B = sonde_block:render(
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
    B = sonde_block:render(
        #{borders => all, title => <<"Hi">>, title_align => center},
        #rect{x = 0, y = 0, w = 12, h = 3},
        buf(12, 3)
    ),
    ?assertEqual($H, ch(B, 5, 0)),
    ?assertEqual($i, ch(B, 6, 0)).

title_right_aligned_test() ->
    %% Span 10, "Hi" flush right -> starts at column 1 + (10 - 2) = 9.
    B = sonde_block:render(
        #{borders => all, title => <<"Hi">>, title_align => right},
        #rect{x = 0, y = 0, w = 12, h = 3},
        buf(12, 3)
    ),
    ?assertEqual($H, ch(B, 9, 0)),
    ?assertEqual($i, ch(B, 10, 0)).

title_truncated_to_span_and_spares_corner_test() ->
    %% Width 4, all borders -> span of 2; "Hello" truncates to "He" and the
    %% top-right corner at column 3 is preserved.
    B = sonde_block:render(
        #{borders => all, title => <<"Hello">>},
        #rect{x = 0, y = 0, w = 4, h = 3},
        buf(4, 3)
    ),
    ?assertEqual($H, ch(B, 1, 0)),
    ?assertEqual($e, ch(B, 2, 0)),
    ?assertEqual(?TOP_RIGHT, ch(B, 3, 0)).

title_style_defaults_to_border_style_test() ->
    B = sonde_block:render(
        #{borders => all, title => <<"Hi">>, border_style => #{fg => 3}},
        #rect{x = 0, y = 0, w = 12, h = 3},
        buf(12, 3)
    ),
    ?assertMatch(#cell{char = $H, fg = 3}, cell(B, 1, 0)).

%%% -- inner -----------------------------------------------------------

inner_all_borders_inset_one_each_test() ->
    ?assertEqual(
        #rect{x = 1, y = 1, w = 2, h = 1},
        sonde_block:inner(#{borders => all}, #rect{x = 0, y = 0, w = 4, h = 3})
    ).

inner_no_borders_is_the_area_test() ->
    ?assertEqual(
        #rect{x = 0, y = 0, w = 4, h = 3},
        sonde_block:inner(#{borders => none}, #rect{x = 0, y = 0, w = 4, h = 3})
    ).

inner_subset_sides_test() ->
    ?assertEqual(
        #rect{x = 1, y = 1, w = 3, h = 2},
        sonde_block:inner(#{borders => [left, top]}, #rect{x = 0, y = 0, w = 4, h = 3})
    ).

inner_clamps_to_zero_when_too_small_test() ->
    ?assertEqual(
        #rect{x = 1, y = 1, w = 0, h = 0},
        sonde_block:inner(#{borders => all}, #rect{x = 0, y = 0, w = 1, h = 1})
    ).

inner_default_borders_are_all_test() ->
    %% An empty config borders like `all', so inner insets one cell each side.
    ?assertEqual(
        #rect{x = 3, y = 6, w = 8, h = 8},
        sonde_block:inner(#{}, #rect{x = 2, y = 5, w = 10, h = 10})
    ).
