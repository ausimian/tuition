%%%-------------------------------------------------------------------
%%% @doc Sparkline widget — a compact bar chart of a numeric series.
%%%
%%% A sparkline draws one vertical bar per data point, its height proportional to
%%% the value, packing a whole time series into a single strip a few rows tall. It
%%% is the ratatui `Sparkline': the dashboard primitive (PRD §9.1) that puts a
%%% metric's recent history — memory over time, run-queue length, a scheduler's
%%% utilization trend — beside its {@link sonde_gauge} current-value bar.
%%%
%%% == Sub-cell precision ==
%%% Each bar is drawn bottom-up with the Unicode eighth-block glyphs (U+2581 `▁'
%%% up to U+2588 `█'), so a value between two whole rows still shows its true
%%% height: the bar's whole rows are full blocks and its top row a partial block
%%% filled to the nearest eighth. A one-row sparkline thus resolves eight distinct
%%% levels, not two. This is ratatui's default nine-level bar set; the glyphs are
%%% all one column in {@link sonde_width}.
%%%
%%% == Scaling and the window ==
%%% Values are scaled so `max' maps to the full height of the area. Pass `max'
%%% explicitly when the series has a known ceiling (a scheduler's utilization tops
%%% out at its sample window; a memory gauge at the node's total) so the strip's
%%% height is stable frame to frame; leave it `auto' and the tallest *visible* bar
%%% fills the height. A value above `max' is clamped to full height rather than
%%% overflowing.
%%%
%%% Only the most recent `width' points are drawn — the series is a growing
%%% history the caller keeps appending to, so the widget shows its tail. They are
%%% laid left to right (oldest visible point at the left, newest at the right), so
%%% until the history fills the strip it grows rightward from the left edge and
%%% then scrolls, the newest bar always at the rightmost filled column.
%%%
%%% == Stateless ==
%%% A sparkline holds no state between frames: the caller keeps the history (a
%%% bounded list it pushes each new sample onto) and passes it as `data'. It
%%% implements the plain {@link sonde_widget} `render/3' callback.
%%%
%%% == Config ==
%%% A `#{}' map, every key optional:
%%% <ul>
%%%   <li>`data' — the series, a list of non-negative integers (default `[]' — an
%%%       empty sparkline draws nothing). Negative values are treated as zero.</li>
%%%   <li>`max' — `auto' (default; the maximum of the visible points, at least 1)
%%%       or an explicit positive integer the bars are scaled against.</li>
%%%   <li>`style' — the style of the bar glyphs (default: unstyled — set at least
%%%       `fg' to colour the strip).</li>
%%% </ul>
%%%
%%% HARD CONSTRAINT (PRD §12): depends only on `kernel'/`stdlib'/`erts' plus the
%%% sibling render/layout/width/widget modules. No third-party code.
%%% @end
%%%-------------------------------------------------------------------
-module(sonde_sparkline).
-behaviour(sonde_widget).

-include("sonde_layout.hrl").

-export([render/3]).

-type sparkline() :: #{
    data => [integer()],
    max => auto | pos_integer(),
    style => sonde_render:style()
}.

-export_type([sparkline/0]).

%%% -- render ----------------------------------------------------------

%% @doc Draw the sparkline into `Area'. A degenerate area (no columns or rows)
%% draws nothing. See the module doc for the config map.
-spec render(sparkline(), #rect{}, sonde_render:buffer()) -> sonde_render:buffer().
render(_Spark, #rect{w = W, h = H}, Buf) when W =< 0; H =< 0 ->
    Buf;
render(Spark, #rect{w = W} = Area, Buf) ->
    Style = maps:get(style, Spark, #{}),
    %% Show only the tail that fits: the newest `W' points, laid left to right.
    Window = window(maps:get(data, Spark, []), W),
    Max = resolve_max(maps:get(max, Spark, auto), Window),
    draw_columns(Buf, Area, Window, Max, Style, 0).

%% Draw one bar per visible point, left to right from the area's left edge, so a
%% short history leaves the right of the strip blank and a full one has its newest
%% bar at the right edge.
-spec draw_columns(
    sonde_render:buffer(),
    #rect{},
    [integer()],
    pos_integer(),
    sonde_render:style(),
    non_neg_integer()
) -> sonde_render:buffer().
draw_columns(Buf, _Area, [], _Max, _Style, _Col) ->
    Buf;
draw_columns(Buf, Area, [Value | Rest], Max, Style, Col) ->
    Buf1 = draw_bar(Buf, Area, Col, Value, Max, Style),
    draw_columns(Buf1, Area, Rest, Max, Style, Col + 1).

%% Draw one bar in column `Col' (area-relative), bottom-up: the bar's height in
%% eighths is `Value / Max' of the full height, whole rows are full blocks and the
%% topmost partial row an eighth-block, everything above it left blank. A value at
%% or above `max' fills the column; zero (or a row above the bar) draws nothing,
%% leaving whatever the sparkline composites over to show through.
-spec draw_bar(
    sonde_render:buffer(),
    #rect{},
    non_neg_integer(),
    integer(),
    pos_integer(),
    sonde_render:style()
) -> sonde_render:buffer().
draw_bar(Buf, #rect{h = H} = Area, Col, Value, Max, Style) ->
    Eighths = min(H * 8, max(0, Value) * H * 8 div Max),
    lists:foldl(
        fun(Row, B) -> draw_cell(B, Area, Col, Row, cell_eighths(Eighths, Row, H), Style) end,
        Buf,
        lists:seq(0, H - 1)
    ).

%% The eighths this row of the bar shows: the total height less the eight-per-row
%% already consumed by the rows *below* it (nearer the bottom), clamped to a
%% single cell. Row 0 is the top; row `H - 1' the bottom, which fills first.
-spec cell_eighths(non_neg_integer(), non_neg_integer(), non_neg_integer()) -> 0..8.
cell_eighths(Eighths, Row, H) ->
    min(8, max(0, Eighths - (H - 1 - Row) * 8)).

%% Draw a single bar cell — the eighth-block glyph for `N' eighths at the
%% area-relative `Col'/`Row', clipped to the area. Zero eighths draws nothing.
-spec draw_cell(
    sonde_render:buffer(), #rect{}, non_neg_integer(), non_neg_integer(), 0..8, sonde_render:style()
) -> sonde_render:buffer().
draw_cell(Buf, _Area, _Col, _Row, 0, _Style) ->
    Buf;
draw_cell(Buf, Area, Col, Row, N, Style) ->
    sonde_widget:put_line(Buf, Area, Col, Row, <<(vert_block(N))/utf8>>, Style).

%% The eighth-block glyph filling a cell from the bottom to `N' eighths: U+2581 at
%% one eighth up to U+2588 (the full block) at eight.
-spec vert_block(1..8) -> char().
vert_block(1) -> 16#2581;
vert_block(2) -> 16#2582;
vert_block(3) -> 16#2583;
vert_block(4) -> 16#2584;
vert_block(5) -> 16#2585;
vert_block(6) -> 16#2586;
vert_block(7) -> 16#2587;
vert_block(8) -> 16#2588.

%%% -- helpers ---------------------------------------------------------

%% The newest `W' points of the series (its tail), or the whole series when it is
%% shorter than the strip is wide.
-spec window([integer()], non_neg_integer()) -> [integer()].
window(Data, W) ->
    Len = length(Data),
    case Len > W of
        true -> lists:nthtail(Len - W, Data);
        false -> Data
    end.

%% The value that maps to full height: an explicit positive `max', or (for `auto')
%% the tallest visible bar — never below 1, so the scale is well defined and the
%% `div' cannot divide by zero on an empty or all-zero window.
-spec resolve_max(auto | pos_integer(), [integer()]) -> pos_integer().
resolve_max(auto, Window) -> lists:max([1 | Window]);
resolve_max(Max, _Window) when is_integer(Max), Max >= 1 -> Max;
resolve_max(_Max, _Window) -> 1.
