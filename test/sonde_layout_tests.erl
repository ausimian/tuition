-module(sonde_layout_tests).

-include_lib("eunit/include/eunit.hrl").
-include("sonde_layout.hrl").

%%% -- acceptance criterion (issue #7) ---------------------------------

%% "A vertical 30%/70% split of an 80x24 area yields two correctly sized,
%% non-overlapping rects that tile the area." 30% of 24 rows floors to 7 and
%% 70% to 16 (sum 23) — the largest-remainder step must hand the leftover row
%% to the 70% pane so the two tile all 24 rows.
acceptance_vertical_30_70_test() ->
    Area = sonde_layout:area({80, 24}),
    Rects = sonde_layout:split(vertical, [{percent, 30}, {percent, 70}], Area),
    ?assertEqual(
        [
            #rect{x = 0, y = 0, w = 80, h = 7},
            #rect{x = 0, y = 7, w = 80, h = 17}
        ],
        Rects
    ),
    assert_tiles(vertical, Area, Rects).

%%% -- area/1 ----------------------------------------------------------

area_test() ->
    ?assertEqual(#rect{x = 0, y = 0, w = 80, h = 24}, sonde_layout:area({80, 24})),
    ?assertEqual(#rect{x = 0, y = 0, w = 1, h = 1}, sonde_layout:area({1, 1})).

%%% -- direction semantics ---------------------------------------------

%% A horizontal split partitions the width and keeps each child's full height.
horizontal_30_70_test() ->
    Area = sonde_layout:area({80, 24}),
    Rects = sonde_layout:split(horizontal, [{percent, 30}, {percent, 70}], Area),
    ?assertEqual(
        [
            #rect{x = 0, y = 0, w = 24, h = 24},
            #rect{x = 24, y = 0, w = 56, h = 24}
        ],
        Rects
    ),
    assert_tiles(horizontal, Area, Rects).

%% The split inherits, not resets, the parent's origin (so nesting composes).
inherits_parent_origin_test() ->
    Parent = #rect{x = 10, y = 5, w = 20, h = 10},
    Rects = sonde_layout:split(vertical, [{percent, 50}, {percent, 50}], Parent),
    ?assertEqual(
        [
            #rect{x = 10, y = 5, w = 20, h = 5},
            #rect{x = 10, y = 10, w = 20, h = 5}
        ],
        Rects
    ).

%%% -- constraint kinds ------------------------------------------------

fixed_test() ->
    Area = sonde_layout:area({80, 24}),
    %% A fixed pane takes exactly its cell count; a trailing fill takes the rest.
    ?assertEqual(
        [#rect{x = 0, y = 0, w = 80, h = 3}, #rect{x = 0, y = 3, w = 80, h = 21}],
        sonde_layout:split(vertical, [{fixed, 3}, fill], Area)
    ).

single_fill_takes_all_test() ->
    Area = sonde_layout:area({80, 24}),
    ?assertEqual(
        [#rect{x = 0, y = 0, w = 80, h = 24}],
        sonde_layout:split(vertical, [fill], Area)
    ).

equal_fills_split_evenly_test() ->
    Rects = sonde_layout:split(horizontal, [fill, fill], sonde_layout:area({80, 24})),
    ?assertEqual([40, 40], [R#rect.w || R <- Rects]).

weighted_fill_test() ->
    %% Weights 1:3 over 80 columns -> 20 and 60.
    Rects = sonde_layout:split(
        horizontal, [{fill, 1}, {fill, 3}], sonde_layout:area({80, 24})
    ),
    ?assertEqual([20, 60], [R#rect.w || R <- Rects]).

fill_absorbs_remainder_after_fixed_and_percent_test() ->
    %% fixed 10 + 25% of 100 (=25) leaves 65 for the fill.
    Rects = sonde_layout:split(
        horizontal, [{fixed, 10}, {percent, 25}, fill], sonde_layout:area({100, 24})
    ),
    ?assertEqual([10, 25, 65], [R#rect.w || R <- Rects]).

%%% -- rounding / tiling -----------------------------------------------

%% Two halves of an odd extent can't both be integers: 25/2 = 12.5 each, floors
%% sum to 24. Largest-remainder hands the spare cell to the first pane (equal
%% fractions, earlier index wins the tie) so the two tile all 25 columns.
halves_of_odd_extent_tile_test() ->
    Area = sonde_layout:area({25, 24}),
    Rects = sonde_layout:split(horizontal, [{percent, 50}, {percent, 50}], Area),
    ?assertEqual([13, 12], [R#rect.w || R <- Rects]),
    assert_tiles(horizontal, Area, Rects).

%% Three equal fills of 100 want 33.33 each; the leftover cell goes to the
%% earliest, tiling exactly rather than leaving 99 covered and 1 bare.
thirds_via_fill_tile_test() ->
    Area = sonde_layout:area({100, 24}),
    Rects = sonde_layout:split(horizontal, [fill, fill, fill], Area),
    ?assertEqual([34, 33, 33], [R#rect.w || R <- Rects]),
    assert_tiles(horizontal, Area, Rects).

%% Percentages that fall short with no fill leave the tail uncovered rather than
%% inventing space; the covered part is still gap-free.
under_subscription_leaves_gap_test() ->
    Area = sonde_layout:area({80, 24}),
    Rects = sonde_layout:split(vertical, [{percent, 25}, {percent, 25}], Area),
    ?assertEqual([6, 6], [R#rect.h || R <- Rects]),
    assert_no_overlap(vertical, Rects).

%%% -- over-subscription -----------------------------------------------

%% fixed cells beyond the extent must not overflow or overlap: the tail shrinks,
%% to zero if necessary, and the layout still fits within the parent.
over_subscription_fixed_clamps_test() ->
    Area = sonde_layout:area({80, 10}),
    Rects = sonde_layout:split(vertical, [{fixed, 8}, {fixed, 8}, {fixed, 8}], Area),
    ?assertEqual([8, 2, 0], [R#rect.h || R <- Rects]),
    assert_within(Area, Rects),
    assert_no_overlap(vertical, Rects).

over_subscription_percent_clamps_test() ->
    Area = sonde_layout:area({100, 24}),
    Rects = sonde_layout:split(horizontal, [{percent, 80}, {percent, 80}], Area),
    ?assertEqual([80, 20], [R#rect.w || R <- Rects]),
    assert_within(Area, Rects),
    assert_no_overlap(horizontal, Rects).

%%% -- degenerate inputs -----------------------------------------------

empty_constraints_test() ->
    ?assertEqual([], sonde_layout:split(vertical, [], sonde_layout:area({80, 24}))).

zero_extent_axis_test() ->
    %% A one-row area split vertically leaves the second pane no rows.
    Rects = sonde_layout:split(vertical, [fill, fill], #rect{x = 0, y = 0, w = 80, h = 1}),
    ?assertEqual([1, 0], [R#rect.h || R <- Rects]),
    assert_no_overlap(vertical, Rects).

%%% -- nesting ---------------------------------------------------------

%% A classic app frame: a fixed header, a body, a fixed footer, with the body
%% split into two columns. Nesting is just splitting a returned child.
nested_layout_test() ->
    Area = sonde_layout:area({80, 24}),
    [Header, Body, Footer] =
        sonde_layout:split(vertical, [{fixed, 1}, fill, {fixed, 1}], Area),
    ?assertEqual(#rect{x = 0, y = 0, w = 80, h = 1}, Header),
    ?assertEqual(#rect{x = 0, y = 1, w = 80, h = 22}, Body),
    ?assertEqual(#rect{x = 0, y = 23, w = 80, h = 1}, Footer),
    [Left, Right] = sonde_layout:split(horizontal, [{percent, 50}, {percent, 50}], Body),
    ?assertEqual(#rect{x = 0, y = 1, w = 40, h = 22}, Left),
    ?assertEqual(#rect{x = 40, y = 1, w = 40, h = 22}, Right),
    assert_tiles(horizontal, Body, [Left, Right]).

%%% -- helpers ---------------------------------------------------------

%% Assert the children exactly tile the parent along Direction: gap-free,
%% non-overlapping, and covering the parent's full extent.
assert_tiles(Direction, Parent, Rects) ->
    assert_no_overlap(Direction, Rects),
    assert_within(Parent, Rects),
    Extent =
        case Direction of
            vertical -> Parent#rect.h;
            horizontal -> Parent#rect.w
        end,
    Covered = lists:sum([extent(Direction, R) || R <- Rects]),
    ?assertEqual(Extent, Covered).

%% Adjacent children must abut with no gap and no overlap along the axis.
assert_no_overlap(Direction, Rects) ->
    lists:foldl(
        fun(R, ExpectedStart) ->
            ?assertEqual(ExpectedStart, start(Direction, R)),
            ExpectedStart + extent(Direction, R)
        end,
        start(Direction, hd(Rects)),
        Rects
    ).

%% Every child stays inside the parent's bounds on both axes.
assert_within(Parent, Rects) ->
    lists:foreach(
        fun(R) ->
            ?assert(R#rect.x >= Parent#rect.x),
            ?assert(R#rect.y >= Parent#rect.y),
            ?assert(R#rect.x + R#rect.w =< Parent#rect.x + Parent#rect.w),
            ?assert(R#rect.y + R#rect.h =< Parent#rect.y + Parent#rect.h)
        end,
        Rects
    ).

start(vertical, #rect{y = Y}) -> Y;
start(horizontal, #rect{x = X}) -> X.

extent(vertical, #rect{h = H}) -> H;
extent(horizontal, #rect{w = W}) -> W.
