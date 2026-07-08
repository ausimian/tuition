%%%-------------------------------------------------------------------
%%% @doc Constraint/split layout — turn a terminal area into cell rects.
%%%
%%% The renderer draws into rectangles, not into a raw terminal size. This
%%% module is the step in between (PRD §8): given a parent {@type rect()} and a
%%% list of {@type constraint()}s, it splits the parent along one axis into
%%% child rects that tile it — adjacent, non-overlapping, and (for a
%%% well-formed spec) covering the parent exactly with no gap. It is the
%%% ratatui-style layout model the PRD calls for, minus the general constraint
%%% solver: enough to place panes for the Phase 0 exit criterion.
%%%
%%% == Direction ==
%%% Following ratatui (PRD §8), the axis names the direction children are
%%% *stacked*, not the orientation of the divider:
%%%   * `vertical'   stacks children top-to-bottom, partitioning the height (H).
%%%   * `horizontal' places children left-to-right, partitioning the width (W).
%%% The other dimension is inherited unchanged, so a `vertical' split keeps each
%%% child's full width and a `horizontal' split keeps each child's full height.
%%%
%%% == Constraints ==
%%%   * `{fixed, N}'   — exactly N cells, independent of the parent size.
%%%   * `{percent, P}' — P percent of the parent's extent along the split axis.
%%%   * `fill' / `{fill, W}' — share whatever the fixed/percent constraints
%%%     leave, split between the `fill's in proportion to their weight `W'
%%%     (bare `fill' is weight 1).
%%%
%%% == Tiling guarantee ==
%%% Sizes are integers (whole cells). Percentages are apportioned with the
%%% largest-remainder method, so a set that sums to 100% tiles the axis exactly
%%% rather than leaving a rounding gap — a 30%/70% split of 24 rows yields 7 and
%%% 17, not 7 and 16. Over-subscription (fixed/percent totals exceeding the
%%% extent) is clamped: earlier children keep their size and later ones shrink,
%%% to zero if need be, so results never overflow the parent or overlap.
%%% Under-subscription with no `fill' leaves the tail of the axis uncovered —
%%% add a `fill' to absorb the slack.
%%% @end
%%%-------------------------------------------------------------------
-module(sonde_layout).

-include("sonde_layout.hrl").

-export([area/1, split/3]).

-type rect() :: #rect{}.
%% An axis-aligned rectangle of cells; see `include/sonde_layout.hrl'.
-type direction() :: horizontal | vertical.
-type constraint() ::
    {fixed, non_neg_integer()}
    | {percent, 0..100}
    | fill
    | {fill, pos_integer()}.

-export_type([rect/0, direction/0, constraint/0]).

%%% -- API -------------------------------------------------------------

%% @doc Build the root rect covering a whole terminal, from a backend size.
%%
%% The origin is `{0, 0}' (top-left) and the size is taken verbatim from the
%% {@link sonde_term:size()} pair, giving the parent rect that {@link split/3}
%% subdivides.
-spec area(sonde_term:size()) -> rect().
area({Cols, Rows}) ->
    #rect{x = 0, y = 0, w = Cols, h = Rows}.

%% @doc Split `Rect' along `Direction' into one child rect per constraint.
%%
%% Children are returned in constraint order and laid out contiguously from the
%% parent's origin. See the module doc for direction and tiling semantics. An
%% empty constraint list yields `[]'.
-spec split(direction(), [constraint()], rect()) -> [rect()].
split(vertical, Constraints, #rect{x = X, y = Y, w = W, h = H}) ->
    {Rects, _} =
        lists:mapfoldl(
            fun(Size, Pos) -> {#rect{x = X, y = Pos, w = W, h = Size}, Pos + Size} end,
            Y,
            solve(Constraints, H)
        ),
    Rects;
split(horizontal, Constraints, #rect{x = X, y = Y, w = W, h = H}) ->
    {Rects, _} =
        lists:mapfoldl(
            fun(Size, Pos) -> {#rect{x = Pos, y = Y, w = Size, h = H}, Pos + Size} end,
            X,
            solve(Constraints, W)
        ),
    Rects.

%%% -- solver ----------------------------------------------------------

%% Apportion `Total' cells along one axis among the constraints, returning one
%% integer size each in constraint order. The result sums to at most `Total'
%% and, for a well-formed spec, to exactly `Total'.
-spec solve([constraint()], non_neg_integer()) -> [non_neg_integer()].
solve(Constraints, Total) ->
    Ideals = ideals(Constraints, Total),
    Rounded = largest_remainder(Ideals, round(lists:sum(Ideals))),
    clamp(Rounded, Total).

%% Real-valued target size for each constraint. Fixed and percent are computed
%% directly against the extent; the `fill's share whatever slack those leave,
%% in proportion to their weight. Every value is >= 0, so the later `trunc/1'
%% floors and never rounds toward zero incorrectly.
-spec ideals([constraint()], non_neg_integer()) -> [float()].
ideals(Constraints, Total) ->
    Rigid = [rigid_ideal(C, Total) || C <- Constraints],
    Weights = [fill_weight(C) || C <- Constraints],
    TotalWeight = lists:sum(Weights),
    Slack = max(0.0, Total - lists:sum(Rigid)),
    [
        fill_share(R, Weight, Slack, TotalWeight)
     || {R, Weight} <- lists:zip(Rigid, Weights)
    ].

%% Target size of a non-fill constraint (fill contributes nothing here — it is
%% resolved from the leftover slack afterwards).
-spec rigid_ideal(constraint(), non_neg_integer()) -> float().
rigid_ideal({fixed, N}, _Total) -> float(N);
rigid_ideal({percent, P}, Total) -> P * Total / 100;
rigid_ideal(fill, _Total) -> 0.0;
rigid_ideal({fill, _W}, _Total) -> 0.0.

%% Fill weight of a constraint; 0 for the non-fill constraints so they take no
%% share of the slack.
-spec fill_weight(constraint()) -> non_neg_integer().
fill_weight(fill) -> 1;
fill_weight({fill, W}) when W > 0 -> W;
fill_weight(_) -> 0.

%% A fill constraint's slice of the slack (Weight > 0 guarantees TotalWeight > 0,
%% so no division by zero); a non-fill constraint keeps its rigid ideal.
-spec fill_share(float(), non_neg_integer(), float(), non_neg_integer()) -> float().
fill_share(_Rigid, Weight, Slack, TotalWeight) when Weight > 0 ->
    Slack * Weight / TotalWeight;
fill_share(Rigid, _Weight, _Slack, _TotalWeight) ->
    Rigid.

%% Round real sizes to non-negative integers summing to exactly `Target', by the
%% largest-remainder (Hamilton) method: floor every size, then hand the leftover
%% units one-by-one to the sizes with the largest fractional parts. This is what
%% makes percentages that sum to 100% tile the axis exactly. Ties go to the
%% earlier constraint, purely for determinism. `Target' is `round(sum)', so the
%% number of leftover units is in `[0, length]' and each size gains at most one.
-spec largest_remainder([float()], non_neg_integer()) -> [non_neg_integer()].
largest_remainder(Ideals, Target) ->
    Floors = [trunc(I) || I <- Ideals],
    Extra = max(0, Target - lists:sum(Floors)),
    %% Rank constraint indices by fractional part, largest first (earlier index
    %% wins ties), and bump the first `Extra' of them by one cell.
    Ranked = [I || {_Frac, I} <- lists:sort(remainders(Ideals))],
    Winners = lists:sublist(Ranked, Extra),
    [
        Floor + bump(Index, Winners)
     || {Floor, Index} <- lists:zip(Floors, lists:seq(1, length(Floors)))
    ].

%% Sort key per constraint: descending fractional part, then ascending index.
%% Negating the fraction turns a plain ascending `lists:sort/1' into descending
%% fraction order; the index is left positive so equal fractions break the tie
%% toward the earlier constraint.
-spec remainders([float()]) -> [{float(), pos_integer()}].
remainders(Ideals) ->
    [
        {-(I - trunc(I)), Index}
     || {I, Index} <- lists:zip(Ideals, lists:seq(1, length(Ideals)))
    ].

-spec bump(pos_integer(), [pos_integer()]) -> 0 | 1.
bump(Index, Winners) ->
    case lists:member(Index, Winners) of
        true -> 1;
        false -> 0
    end.

%% Cap the running total at `Total' so an over-subscribed spec never overflows
%% the axis: each size is truncated to the cells still available, zeroing any
%% that fall entirely past the boundary. A spec summing to <= `Total' (the
%% common case) passes through unchanged.
-spec clamp([non_neg_integer()], non_neg_integer()) -> [non_neg_integer()].
clamp(Sizes, Total) ->
    clamp(Sizes, Total, 0).

clamp([], _Total, _Used) ->
    [];
clamp([Size | Rest], Total, Used) ->
    Fitted = min(Size, max(0, Total - Used)),
    [Fitted | clamp(Rest, Total, Used + Fitted)].
