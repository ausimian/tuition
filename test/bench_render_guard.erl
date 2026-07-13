%%%-------------------------------------------------------------------
%%% @doc Perf-regression guard for {@link tuition_render:diff/2} (issue #26).
%%%
%%% #22 optimized `diff/2' (row-major scan + a per-cell width cache), so there is
%%% now a much faster baseline worth protecting from silent regressions. This
%%% guard turns such a regression into a loud failure instead of a number that
%%% quietly drifts up.
%%%
%%% == Why a ratio, not a wall-clock budget ==
%%%
%%% Absolute microsecond ceilings flake on shared CI runners (a busy runner is
%%% simply slower at everything). So the guard is deterministic and *ratio-based*:
%%% for each guarded frame it times `diff/2' against a cheap in-process baseline
%%% — a bare per-cell read of the *same* frame via {@link tuition_render:cell_at/3}
%%% — and asserts the ratio stays under a generous ceiling. Both operations are
%%% O(cells) walks over the same 120x40 grid, so raw machine speed cancels out of
%%% the ratio and only the *relative* cost of diffing (scan + SGR/glyph emission)
%%% versus a bare cell read is measured. A `diff/2' regression (e.g. reverting the
%%% per-cell width cache and re-measuring glyph width on the hot path, or an
%%% O(cells^2) scan) inflates that ratio; the baseline is unaffected.
%%%
%%% The target and baseline are timed back to back *within each batch* and the
%%% guard asserts on the *median* of the per-batch ratios, so a transient load
%%% spike slows both halves of a batch together and cancels, and a single noisy
%%% batch cannot move the median.
%%%
%%% == Guarded cases ==
%%%
%%%   * `full_paint' — `diff(blank, dashboard)': every cell changes, the canonical
%%%     full repaint dominated by cursor moves, SGR changes and glyph bytes.
%%%   * `wide'       — `diff(blank, cjk_frame)': a frame of two-column glyphs, the
%%%     case that leans hardest on the per-cell width cache #22 added.
%%%
%%% The frames come straight from {@link bench_render} so the guard protects the
%%% exact inputs the microbenchmark reports on. `noop'/`single_cell' are not
%%% guarded: both settle in the row-major short-circuit and are too cheap to yield
%%% a stable ratio.
%%%
%%% == Running ==
%%%
%%% Bench-profile only, so it never burdens the default build (compile/eunit/xref)
%%% or the Mix build, and never CI-gates a noisy timing check:
%%%
%%%   rebar3 as bench guard
%%%
%%% The eunit entry point is compiled only when the `BENCH_GUARD' macro is defined
%%% (set by the `bench' profile in rebar.config), so a plain `rebar3 eunit' finds
%%% no test here. {@link check/0} can also be called directly from a bench shell.
%%% @end
%%%-------------------------------------------------------------------
-module(bench_render_guard).

-export([check/0]).

%% Ceilings on the median diff/baseline ratio. Observed locally (OTP 28, after
%% #22): full_paint ~2.7, wide ~1.65, each stable to ~+/-2% across runs. The
%% ceilings sit ~1.8x above those medians: generous enough never to flake on a
%% shared runner, tight enough that reverting the #22 optimization (which roughly
%% doubles the diff cost) trips them.
-define(FULL_PAINT_CEILING, 5.0).
-define(WIDE_CEILING, 3.0).

%% Timing shape: median of B per-batch ratios, each ratio from N diff calls over
%% N baseline calls. B is odd for a clean median; the totals stay a few seconds.
-define(ITERS, 100).
-define(BATCHES, 41).
-define(WARMUP, 300).

%%% -- eunit entry point (bench profile only) --------------------------

-ifdef(BENCH_GUARD).
-export([render_guard_test_/0]).

%% Generous timeout: the guard runs thousands of diffs across two cases.
render_guard_test_() ->
    {timeout, 120, fun check/0}.
-endif.

%%% -- guard -----------------------------------------------------------

%% @doc Run the ratio guard over every guarded case. Prints a PASS/FAIL report
%% and raises `error({perf_regression, Failures})' if any case exceeds its
%% ceiling; returns `ok' when all cases pass.
-spec check() -> ok.
check() ->
    Cases = cases(),
    {W, H} = tuition_render:size(element(3, hd(Cases))),
    report("tuition_render:diff/2 perf guard (median diff/cell_at ratio over ~b cells)", [W * H]),
    Failures = lists:filtermap(fun run_case/1, Cases),
    case Failures of
        [] ->
            report("all cases within budget", []),
            ok;
        _ ->
            erlang:error({perf_regression, Failures})
    end.

%% Each case pairs a diff/2 target with the frame whose cells the baseline reads.
cases() ->
    {FullPrev, FullNext} = bench_render:full_paint({input, guard}),
    {WidePrev, WideNext} = bench_render:wide({input, guard}),
    [
        {full_paint, fun() -> tuition_render:diff(FullPrev, FullNext) end, FullNext,
            ?FULL_PAINT_CEILING},
        {wide, fun() -> tuition_render:diff(WidePrev, WideNext) end, WideNext, ?WIDE_CEILING}
    ].

%% Measure one case; emit a report line and keep it in the failure list if over.
run_case({Name, Target, Frame, Ceiling}) ->
    Ratio = median_ratio(Target, cell_scan(Frame)),
    Status =
        case Ratio =< Ceiling of
            true -> "PASS";
            false -> "FAIL"
        end,
    report("  ~-12s ratio ~5.2f  (ceiling ~4.1f)  ~s", [Name, Ratio, Ceiling, Status]),
    case Ratio =< Ceiling of
        true -> false;
        false -> {true, {Name, Ratio, Ceiling}}
    end.

%%% -- timing ----------------------------------------------------------

%% Median of per-batch ratios. Timing the target and baseline back to back inside
%% each batch keeps a load spike correlated across the ratio; the median over the
%% batches then shrugs off any lone noisy batch.
median_ratio(Target, Baseline) ->
    _ = repeat(Target, ?WARMUP),
    _ = repeat(Baseline, ?WARMUP),
    Ratios = [per_iter(Target) / per_iter(Baseline) || _ <- lists:seq(1, ?BATCHES)],
    median(Ratios).

per_iter(Fun) ->
    {Micros, _} = timer:tc(fun() -> repeat(Fun, ?ITERS) end),
    Micros / ?ITERS.

repeat(_Fun, 0) ->
    ok;
repeat(Fun, N) ->
    _ = Fun(),
    repeat(Fun, N - 1).

%% Baseline: fold a bare cell read across every cell of the frame — the same
%% O(cells) walk diff/2 performs, minus all the diff/emit work.
cell_scan(Frame) ->
    {W, H} = tuition_render:size(Frame),
    Coords = [{X, Y} || Y <- lists:seq(0, H - 1), X <- lists:seq(0, W - 1)],
    fun() ->
        lists:foldl(
            fun({X, Y}, Acc) ->
                _ = tuition_render:cell_at(Frame, X, Y),
                Acc
            end,
            ok,
            Coords
        )
    end.

median(List) ->
    Sorted = lists:sort(List),
    Len = length(Sorted),
    case Len rem 2 of
        1 -> lists:nth((Len + 1) div 2, Sorted);
        0 -> (lists:nth(Len div 2, Sorted) + lists:nth(Len div 2 + 1, Sorted)) / 2
    end.

%% Force output to the user device so the report survives eunit's io capture.
report(Fmt, Args) ->
    io:format(user, Fmt ++ "~n", Args).
