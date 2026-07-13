%%%-------------------------------------------------------------------
%%% @doc Microbenchmark for {@link tuition_layout:split/3}.
%%%
%%% Layout runs on every resize and on every frame that re-tiles a pane, so the
%%% constraint solver is on the render hot path (PRD §8). The input is a
%%% realistic dashboard-style constraint list — a fixed header, a couple of
%%% percentage panes, weighted `fill's that share the slack, and a fixed footer
%%% — solved against a large terminal-sized rect so the largest-remainder and
%%% fill-apportioning paths are all exercised.
%%%
%%% Legacy `rebar3_bench' callbacks: `split/1' prepares the (cached) input and
%%% `bench_split/2' is the timed body. Run with `rebar3 as bench bench'.
%%%
%%% The parent rect is built via {@link tuition_layout:area/1} so this module
%%% needs no access to the `#rect{}' record header.
%%% @end
%%%-------------------------------------------------------------------
-module(bench_layout).

-export([split/1, bench_split/2]).

%% Prepare the benchmark input once: a mixed constraint list + a 200x50 rect.
split({input, _}) ->
    Constraints = [
        {fixed, 1},
        {percent, 25},
        fill,
        {fill, 2},
        {percent, 10},
        {fixed, 3}
    ],
    Area = tuition_layout:area({200, 50}),
    {Constraints, Area}.

%% Timed body: tile the rect vertically along the constraint list.
bench_split({Constraints, Area}, _) ->
    tuition_layout:split(vertical, Constraints, Area).
