-module(tuition_chart).
-moduledoc """
Chart widget — time-series trend curves at sub-cell resolution.

Where `m:tuition_sparkline` draws one block bar per sample (eight vertical
levels, one column wide), a chart plots its samples as continuous curves on a
`m:tuition_braille` grid — 4× the vertical and 2× the horizontal resolution per cell
— so a BEAM trend (run-queue length, reductions/s, IO throughput over a
rolling window) reads as a smooth line rather than a staircase. It is
ratatui's `Chart` drawn with `Marker::Braille`: the dashboard primitive a
system dashboard's trend panel is built from. It is built on
`m:tuition_canvas` — a chart is a canvas with time-series semantics (a
rolling window, value bounds, an optional axis frame) layered on top: each
dataset lowers to canvas shapes, so both widgets share the one braille plotting
path rather than each rasterizing by hand.

## Datasets

One or more datasets share the plot, each a series drawn in its own colour as
a connected `line`, a `scatter` of dots, or a filled `area` (each sample's
column solid from the baseline up to its value). A series is a list of numbers
sampled over time (as `m:tuition_sparkline`'s is); the value is the y-axis
and the sample's position in the series the x-axis. Overlaying several series
(IO in and out, say) puts them on one shared value scale so they are directly
comparable. A dataset may carry a `name` — used only by the legend (below).

## The rolling window

Only the newest samples are plotted — one per sub-pixel column, and the
sub-pixel width is `2×` the cell width, so at most the newest `2W` samples
fit. `window` bounds how many of them to show: `auto` (default) uses as many
of the newest samples as the width holds; an explicit count `N` shows only the
newest `N` (clamped to the `2W` the width can draw), a fixed-duration window
that stays the same on-screen span regardless of how much history the caller
has accumulated. A caller keeps appending to a bounded history and the chart
shows its tail, scrolling as new samples arrive.

`x_align` fixes where the window sits when it is narrower than the plot (a
short history, or a `window` count below `2W`): `left` (default) grows the
curve rightward from the left edge (as `m:tuition_sparkline` does); `right`
pins the newest sample to the right edge and leaves the left blank until the
window fills — the live-trend look (newest always hard against the right), and
the anchoring that keeps multiple series aligned by recency rather than by age.

## Bounds

`y_bounds` is `auto` (default — the min and max across every visible dataset
map to the bottom and top of the plot) or an explicit `{Min, Max}` held stable
frame to frame (a metric with a known ceiling, so the curve does not rescale
under its own noise). A value outside explicit bounds is clamped into the
plot; a flat series (all one value, or `Min =:= Max`) is drawn along the
vertical middle rather than dividing by a zero range.

## One colour per cell (known constraint)

A `m:tuition_braille` cell shares one `fg` across its eight dots, so where
two datasets light dots in the *same* cell the later-drawn dataset wins that
cell's colour (its dots merge, but the colour is last-writer-wins) — ratatui's
canvas layering. Datasets are plotted in list order, so the last dataset wins
collisions. Where series must never visually collide, give each its own chart
tile (stacked by `m:tuition_layout`) rather than overlaying them.

## Optional axes and labelling

With `axes => true` the widget draws a light box-drawing y-axis and x-axis
meeting at the origin — the reference frame a bare trend strip lacks — and
insets the plot to make room. On top of the bare frame, four opt-in keys label
it (each reserving its own gutter or row, so they compose without overlapping):

- `y_ticks` — numeric labels up the y-axis (`auto` derives max/mid/min from
  the bounds, or pass explicit values). Reserves a left gutter as wide as
  the widest label; each label is right-aligned against the axis at the row
  its value maps to.
- `x_labels` — labels spread along the x-axis (e.g. oldest … newest),
  first flush-left, last flush-right. Reserves one row below the axis.
- `y_title` / `x_title` — axis titles. The y-title is written vertically in
  a reserved far-left column; the x-title is centred in a reserved row
  below the x-labels. All labelling uses `axis_style`.

With none of these set, `axes => true` reserves exactly one left column and one
bottom row — the bare frame, unchanged. Labelling is meaningless without the
frame, so these keys take effect only when `axes => true`.

## Legend

`legend => #{...}` draws a small boxed key mapping each named dataset's colour
to its `name`, floated in a corner of the plot. It resets the cells beneath it
(`m:tuition_clear`) so the curves do not show through, frames them (`m:tuition_block`), and lists one `■ name` row per dataset that carries a `name`
(unnamed datasets are omitted). `position` picks the corner; `style` colours
the box (and backs it, so it reads over a busy plot). The legend is independent
of `axes` — it floats over the plot area either way.

## Stateless

A chart holds no state between frames: the caller keeps each series' history
and passes it as config. It implements the plain `m:tuition_widget`
`render/3` callback.

## Config

A `#{}` map, every key optional:

- `datasets` — a list of dataset maps (default `[]` — an empty chart draws
  only its axes, if enabled). Each dataset:
  - `data` — the series, a list of numbers (default `[]`).
  - `color` — the dot colour (default `default` — the base foreground).
  - `marker` — `line` (default; connect consecutive samples),
    `scatter` (a dot per sample), or `area` (fill each sample's column
    from the baseline up to its value — a filled area/column chart).
  - `name` — chardata naming the series in the legend (default: unnamed,
    so absent from the legend).
- `y_bounds` — `auto` (default) or an explicit `{Min, Max}`.
- `window` — `auto` (default; as many newest samples as the width holds)
  or a positive integer count of the newest samples to show (clamped to
  the width).
- `x_align` — `left` (default; grow from the left edge) or `right` (pin the
  newest sample to the right edge).
- `axes` — `true` to draw the axis frame, `false` (default) for a bare plot.
- `axis_style` — the style of the axis glyphs, ticks, labels and titles
  (default: unstyled).
- `y_ticks` — `auto` | a list of values, labelled up the y-axis (default:
  none). Only drawn with `axes => true`.
- `x_labels` — a list of chardata spread along the x-axis (default: none).
  Only drawn with `axes => true`.
- `y_title` / `x_title` — axis titles, chardata (default: none). Only drawn
  with `axes => true`.
- `legend` — `false` (default) or `#{position => top_right (default) | top_left | bottom_right | bottom_left, style => style()}`.
""".
-behaviour(tuition_widget).

-include("tuition_layout.hrl").

-export([render/3]).

-type dataset() :: #{
    data => [number()],
    color => tuition_braille:colour(),
    marker => line | scatter | area,
    name => unicode:chardata()
}.

-type legend_position() :: top_right | top_left | bottom_right | bottom_left.

-type legend() ::
    false
    | #{
        position => legend_position(),
        style => tuition_render:style()
    }.

-type chart() :: #{
    datasets => [dataset()],
    y_bounds => auto | {number(), number()},
    window => auto | pos_integer(),
    x_align => left | right,
    axes => boolean(),
    axis_style => tuition_render:style(),
    y_ticks => auto | [number()],
    x_labels => [unicode:chardata()],
    y_title => unicode:chardata(),
    x_title => unicode:chardata(),
    legend => legend()
}.

-export_type([chart/0, dataset/0, legend/0, legend_position/0]).

%% Light box-drawing glyphs for the optional axis frame.
-define(V_AXIS, 16#2502).
%% │
-define(H_AXIS, 16#2500).
%% ─
-define(CORNER, 16#2514).
%% └
-define(SWATCH, 16#25A0).
%% ■ — the legend colour swatch.

%% The reserved-space layout of an axed chart: the plot rect the curves draw into,
%% plus the gutter/row extents the frame and its labels occupy around it. `l' is the
%% columns left of the y-axis (`ytitle_w' + `tick_w'); `bottom_extra' the rows below
%% the x-axis (`xlabel_h' + `xtitle_h'). `pw'/`ph' are the plot's cell width/height,
%% clamped at zero so a too-small area degrades to whatever frame fits.
-record(layout, {
    ytitle_w :: 0 | 1,
    tick_w :: non_neg_integer(),
    l :: non_neg_integer(),
    xlabel_h :: 0 | 1,
    xtitle_h :: 0 | 1,
    pw :: non_neg_integer(),
    ph :: non_neg_integer(),
    plot :: #rect{}
}).

%%% -- render ----------------------------------------------------------

-doc """
Draw the chart into `Area`. A degenerate area (no columns or rows) draws
nothing. See the module doc for the config map.
""".
-spec render(chart(), #rect{}, tuition_render:buffer()) -> tuition_render:buffer().
render(_Chart, #rect{w = W, h = H}, Buf) when W =< 0; H =< 0 ->
    Buf;
render(Chart, #rect{w = W} = Area, Buf0) ->
    {PlotArea, Bounds, Buf1} =
        case maps:get(axes, Chart, false) of
            true ->
                Layout = layout(Chart, Area),
                B = plot_window_bounds(Chart, Layout#layout.pw),
                {Layout#layout.plot, B, draw_frame(Chart, Area, Layout, B, Buf0)};
            false ->
                {Area, plot_window_bounds(Chart, W), Buf0}
        end,
    Buf2 =
        case PlotArea of
            #rect{w = PW, h = PH} when PW =< 0; PH =< 0 -> Buf1;
            _ -> plot(Chart, PlotArea, Bounds, Buf1)
        end,
    draw_legend(Chart, PlotArea, Buf2).

%% The y-bounds over the newest samples a plot of `PlotCols' cells can draw — the
%% very window {@link plot/4} rasterizes (its sub-pixel width is `2 × PlotCols'), so
%% the tick labels and the curve share one scale. Resolved from the *actual* plot
%% width, after the tick gutter is subtracted, so a rolling `auto' window's bounds
%% never include older samples the gutter pushed off-screen.
-spec plot_window_bounds(chart(), non_neg_integer()) -> {number(), number()}.
plot_window_bounds(Chart, PlotCols) ->
    WinCount = resolve_window(maps:get(window, Chart, auto), PlotCols * 2),
    Series = [prepare(D, WinCount) || D <- maps:get(datasets, Chart, [])],
    resolve_bounds(maps:get(y_bounds, Chart, auto), Series).

%%% -- plotting --------------------------------------------------------

%% Lower every dataset to {@link tuition_canvas} shapes over the plot area and hand
%% them to the canvas — the single braille plotting path. The x-axis spans the
%% sub-pixel column range `{0, PW - 1}', so a sample's column index is its x value;
%% the y-axis ({@link y_axis/1}) gives the canvas bounds, the value each sample maps
%% to, and the baseline an `area' column fills down to, so the canvas does the
%% value-to-sub-pixel mapping the chart once did by hand. Shapes are listed in
%% dataset order, so the canvas folds them onto its one shared grid in that order
%% and the last dataset wins a shared cell's colour — the one-colour-per-cell rule,
%% carried over for free.
-spec plot(chart(), #rect{}, {number(), number()}, tuition_render:buffer()) ->
    tuition_render:buffer().
plot(Chart, Area, Bounds, Buf) ->
    {PW, _PH} = tuition_braille:dims(tuition_braille:new(Area)),
    WinCount = resolve_window(maps:get(window, Chart, auto), PW),
    XAlign = maps:get(x_align, Chart, left),
    Series = [prepare(D, WinCount) || D <- maps:get(datasets, Chart, [])],
    {YBounds, Baseline, MapY} = y_axis(Bounds),
    Shapes = lists:flatmap(
        fun({Colour, Marker, Window}) ->
            Col0 = col_offset(XAlign, PW, length(Window)),
            marker_shapes(Marker, series_points(Window, Col0, MapY), Baseline, Colour)
        end,
        Series
    ),
    Canvas = #{x_bounds => {0, PW - 1}, y_bounds => YBounds, shapes => Shapes},
    tuition_canvas:render(Canvas, Area, Buf).

%% The y-axis the canvas plots against: `{Bounds, Baseline, MapY}' — the canvas
%% `y_bounds', the value an `area' column fills down to, and the value each sample
%% maps through. Normally the chart's own resolved bounds, each value passed through
%% unchanged and the baseline at `Ymin' (the plot floor). A degenerate or inverted
%% range (`Ymax =< Ymin') is the exception: the canvas would collapse *every* value
%% — the baseline included — to the middle fallback row, so an `area' column would
%% span nothing (the regression this guards against). Substitute the unit range, map
%% every value to its midpoint `0.5', and drop the baseline to `0.0' (the floor):
%% samples still land on the middle exactly as the collapse placed them (so the
%% line/scatter markers draw the same flat mid-line), while an `area' column fills
%% from the middle down to the floor again — the documented column fill.
-spec y_axis({number(), number()}) ->
    {{number(), number()}, number(), fun((number()) -> number())}.
y_axis({Ymin, Ymax} = Bounds) when Ymax > Ymin ->
    {Bounds, Ymin, fun(V) -> V end};
y_axis(_Degenerate) ->
    {{0.0, 1.0}, 0.0, fun(_V) -> 0.5 end}.

%% A dataset reduced to what plotting needs: its colour, its marker, and the
%% newest `WinCount' samples of its series (the tail the window shows).
-spec prepare(dataset(), non_neg_integer()) ->
    {tuition_braille:colour(), line | scatter | area, [number()]}.
prepare(D, WinCount) ->
    Colour = maps:get(color, D, default),
    Marker = maps:get(marker, D, line),
    {Colour, Marker, window(maps:get(data, D, []), WinCount)}.

%% The number of newest samples to show: `auto' fills the width (`PW' sub-pixel
%% columns); an explicit count is clamped to `PW', since no more than one sample
%% per sub-pixel column can be drawn. A non-positive/invalid count falls back to
%% `auto'.
-spec resolve_window(auto | pos_integer(), non_neg_integer()) -> non_neg_integer().
resolve_window(auto, PW) -> PW;
resolve_window(N, PW) when is_integer(N), N > 0 -> min(N, PW);
resolve_window(_Invalid, PW) -> PW.

%% The column the leftmost sample of an `L'-wide window sits at: `left' anchors it
%% to column 0 (grow rightward); `right' places the window flush against the right
%% edge, so its newest sample lands at column `PW - 1' and the left `PW - L'
%% columns stay blank.
-spec col_offset(left | right, non_neg_integer(), non_neg_integer()) -> integer().
col_offset(right, PW, L) -> PW - L;
col_offset(_Left, _PW, _L) -> 0.

%% A window as value-space points: sample `I' (0-based, left to right) at x value
%% `Col0 + I' — its sub-pixel column, since the canvas x-axis spans `{0, PW - 1}' —
%% paired with its y value through `MapY' (identity normally; the midpoint for a
%% degenerate range, see {@link y_axis/1}). The canvas maps each `{X, Y}' to a
%% sub-pixel; the list stays in window order, so consecutive points are adjacent
%% columns a line can connect.
-spec series_points([number()], integer(), fun((number()) -> number())) ->
    [{integer(), number()}].
series_points(Window, Col0, MapY) ->
    {Points, _} = lists:mapfoldl(fun(V, Col) -> {{Col, MapY(V)}, Col + 1} end, Col0, Window),
    Points.

%% Lower one series' points to canvas shapes for its marker: `scatter' to a single
%% `points' shape (a dot per sample); `line' to a `line' segment between each
%% consecutive pair (a lone sample, with no neighbour to connect to, lowers to a
%% one-point `points' shape); `area' to one vertical `line' per sample, from the
%% sample's y down to `Baseline' (which the canvas maps to the bottom sub-pixel row)
%% — a one-column-wide vertical line reproducing the old `fill_column' fill dot for
%% dot. An empty series lowers to no shapes.
-spec marker_shapes(
    line | scatter | area, [{integer(), number()}], number(), tuition_braille:colour()
) -> [tuition_canvas:shape()].
marker_shapes(_Marker, [], _Baseline, _Colour) ->
    [];
marker_shapes(scatter, Points, _Baseline, Colour) ->
    [{points, Points, Colour}];
marker_shapes(area, Points, Baseline, Colour) ->
    [{line, X, Y, X, Baseline, Colour} || {X, Y} <- Points];
marker_shapes(line, [Point], _Baseline, Colour) ->
    [{points, [Point], Colour}];
marker_shapes(line, Points, _Baseline, Colour) ->
    line_segments(Points, Colour).

%% One `line' shape between each consecutive pair of points — the connected curve.
%% A one- or zero-point tail has no pair left to connect and ends the list.
-spec line_segments([{integer(), number()}], tuition_braille:colour()) ->
    [tuition_canvas:shape()].
line_segments([{X0, Y0} | [{X1, Y1} | _] = Rest], Colour) ->
    [{line, X0, Y0, X1, Y1, Colour} | line_segments(Rest, Colour)];
line_segments(_Fewer, _Colour) ->
    [].

%%% -- scaling ---------------------------------------------------------

%% The value that maps to the bottom of the plot and the one that maps to the top.
%% `auto' spans the min and max across every visible dataset (falling back to a
%% unit range when nothing is visible, so scaling is always well defined); an
%% explicit `{Min, Max}' passes through, clamped against per-frame.
-spec resolve_bounds(auto | {number(), number()}, [{term(), term(), [number()]}]) ->
    {number(), number()}.
resolve_bounds({Min, Max}, _Series) when is_number(Min), is_number(Max) ->
    {Min, Max};
resolve_bounds(auto, Series) ->
    case [V || {_C, _M, Window} <- Series, V <- Window] of
        [] -> {0, 1};
        Vals -> {lists:min(Vals), lists:max(Vals)}
    end.

%% The row a value maps to: `Ymax' at the top (row 0), `Ymin' at the bottom (row
%% `PH - 1'), linearly between, clamped into the plot so a value past explicit
%% bounds sits on the edge rather than off-grid. A non-positive range (a flat
%% series, or inverted explicit bounds) has no gradient, so every value is drawn
%% along the vertical middle. Places a y-tick label at the cell row its value maps
%% to; it mirrors {@link tuition_canvas}'s own value-to-sub-pixel mapping (same
%% clamp, same middle fallback) so a label sits level with the curve it denotes.
-spec value_to_row(number(), number(), number(), non_neg_integer()) -> non_neg_integer().
value_to_row(V, Ymin, Ymax, PH) ->
    Frac =
        case Ymax - Ymin of
            Range when Range =< 0 -> 0.5;
            Range -> clamp01((V - Ymin) / Range)
        end,
    round((1.0 - Frac) * (PH - 1)).

-spec clamp01(float()) -> float().
clamp01(F) -> min(1.0, max(0.0, F)).

%%% -- windowing -------------------------------------------------------

%% The newest `N' samples of a series (its tail), or the whole series when it is
%% shorter than the plot is wide. Mirrors {@link tuition_sparkline}'s window.
-spec window([number()], non_neg_integer()) -> [number()].
window(Data, N) ->
    Len = length(Data),
    case Len > N of
        true -> lists:nthtail(Len - N, Data);
        false -> Data
    end.

%%% -- axis frame + labelling ------------------------------------------

%% Draw the axis frame — y-axis, x-axis, corner — plus any ticks, x-labels and
%% titles, into the pre-computed `Layout' with the plot's `Bounds'. Every glyph is
%% placed `Area'-relative through {@link tuition_widget:put_line/6}, so a too-small
%% area degrades to just the part of the frame that fits (the plot rect, taken from
%% `Layout' by {@link render/3}, then coming back degenerate and drawn as nothing).
-spec draw_frame(chart(), #rect{}, #layout{}, {number(), number()}, tuition_render:buffer()) ->
    tuition_render:buffer().
draw_frame(Chart, #rect{w = W} = Area, #layout{l = L, ph = PH} = Layout, Bounds, Buf) ->
    Style = maps:get(axis_style, Chart, #{}),
    %% y-axis up the axis column (`L'), every row above the corner.
    Buf1 = lists:foldl(
        fun(Row, B) -> tuition_widget:put_line(B, Area, L, Row, <<?V_AXIS/utf8>>, Style) end,
        Buf,
        seq(0, PH - 1)
    ),
    %% x-axis along the axis row (`PH'), every column right of the corner. `seq/2'
    %% (not `lists:seq/2') so a gutter wider than the whole pane (`L' >= `W', e.g. a
    %% one-column area with a y-title) yields an empty range and the frame degrades
    %% to what fits, rather than crashing on an inverted range.
    Buf2 = lists:foldl(
        fun(Col, B) -> tuition_widget:put_line(B, Area, Col, PH, <<?H_AXIS/utf8>>, Style) end,
        Buf1,
        seq(L + 1, W - 1)
    ),
    Buf3 = tuition_widget:put_line(Buf2, Area, L, PH, <<?CORNER/utf8>>, Style),
    Buf4 = draw_ticks(Chart, Area, Layout, Bounds, Style, Buf3),
    Buf5 = draw_x_labels(Chart, Area, Layout, Style, Buf4),
    draw_titles(Chart, Area, Layout, Style, Buf5).

%% Compute the reserved-space layout: how many columns the y-title and y-tick
%% labels claim left of the axis, how many rows the x-labels and x-title claim
%% below it, and the plot rect that remains. With no labelling keys set this is a
%% one-column, one-row inset — the bare frame, byte-for-byte as before.
-spec layout(chart(), #rect{}) -> #layout{}.
layout(Chart, #rect{x = X, y = Y, w = W, h = H} = Area) ->
    YTitleW = has_text(y_title, Chart),
    TickW = tick_gutter(Chart, Area, YTitleW),
    L = YTitleW + TickW,
    XLabelH = has_list(x_labels, Chart),
    XTitleH = has_text(x_title, Chart),
    BottomExtra = XLabelH + XTitleH,
    PW = max(0, W - L - 1),
    PH = max(0, H - 1 - BottomExtra),
    #layout{
        ytitle_w = YTitleW,
        tick_w = TickW,
        l = L,
        xlabel_h = XLabelH,
        xtitle_h = XTitleH,
        pw = PW,
        ph = PH,
        plot = #rect{x = X + L + 1, y = Y, w = PW, h = PH}
    }.

%% 1 if `Key' holds non-empty chardata (a title present), else 0 — a reserved
%% column/row count.
-spec has_text(atom(), chart()) -> 0 | 1.
has_text(Key, Chart) ->
    case maps:get(Key, Chart, none) of
        none -> 0;
        Text -> min(1, byte_size(to_bin(Text)))
    end.

%% 1 if `Key' holds a non-empty list (x-labels present), else 0.
-spec has_list(atom(), chart()) -> 0 | 1.
has_list(Key, Chart) ->
    case maps:get(Key, Chart, []) of
        [_ | _] -> 1;
        _ -> 0
    end.

%%% -- y-ticks ---------------------------------------------------------

%% The width of the y-tick gutter, in columns, or 0 when ticks are off. The gutter
%% narrows the plot, which narrows the window, which sets the auto-bounds, which set
%% the labels, which set the gutter — a genuine cycle. We reach its fixed point by
%% growing the gutter monotonically ({@link converge_gutter/6}): a non-decreasing
%% integer bounded by the width stabilises in a couple of steps, and at the fixed
%% point the labels fit the gutter (so nothing truncates) while the bounds are those
%% of the window actually plotted (so the labels describe the visible curve, not
%% samples the gutter pushed off-screen). With explicit bounds — or a window not
%% width-limited — the label width is constant, so it settles in one step.
-spec tick_gutter(chart(), #rect{}, 0 | 1) -> non_neg_integer().
tick_gutter(Chart, Area, YTitleW) ->
    case maps:get(y_ticks, Chart, none) of
        none -> 0;
        Spec -> converge_gutter(Chart, Area, Spec, YTitleW, 0, 8)
    end.

%% One step towards the fixed point: size the labels from the bounds of the window
%% the *current* gutter guess leaves, and grow the gutter to fit them. Growing only
%% (never shrinking) keeps the sequence non-decreasing so it converges; `Fuel'
%% bounds the recursion as a backstop, though a stable width is reached well before
%% it runs out.
-spec converge_gutter(
    chart(), #rect{}, auto | [number()], 0 | 1, non_neg_integer(), non_neg_integer()
) -> non_neg_integer().
converge_gutter(_Chart, _Area, _Spec, _YTitleW, G, 0) ->
    G;
converge_gutter(Chart, #rect{w = W} = Area, Spec, YTitleW, G, Fuel) ->
    PlotCols = max(0, W - YTitleW - G - 1),
    Bounds = plot_window_bounds(Chart, PlotCols),
    Next = max(G, widest([fmt_num(V) || V <- tick_values(Spec, Bounds)])),
    case Next =:= G of
        true -> G;
        false -> converge_gutter(Chart, Area, Spec, YTitleW, Next, Fuel - 1)
    end.

%% The values the y-ticks label: `auto' derives max/mid/min from the bounds, an
%% explicit list is taken verbatim (dropping any non-numbers).
-spec tick_values(auto | [number()], {number(), number()}) -> [number()].
tick_values(auto, {Min, Max}) -> auto_ticks(Min, Max);
tick_values(List, _Bounds) when is_list(List) -> [V || V <- List, is_number(V)].

%% Draw the y-tick labels, right-aligned against the y-axis at the cell row each
%% value maps to. Values and bounds are the same {@link plot_window_bounds/2} the plot
%% uses, so a label sits level with the curve height it denotes and — the gutter
%% having been sized from these very labels — always fits without truncation. Ties
%% on a row (a short plot, or a flat series) collapse to one label.
-spec draw_ticks(
    chart(),
    #rect{},
    #layout{},
    {number(), number()},
    tuition_render:style(),
    tuition_render:buffer()
) -> tuition_render:buffer().
draw_ticks(
    Chart, Area, #layout{ytitle_w = YTitleW, tick_w = TickW, ph = PH}, {Ymin, Ymax}, Style, Buf
) ->
    case maps:get(y_ticks, Chart, none) of
        none ->
            Buf;
        _ when TickW =:= 0; PH =:= 0 ->
            Buf;
        Spec ->
            Values = tick_values(Spec, {Ymin, Ymax}),
            Rows = dedup_rows([{value_to_row(V, Ymin, Ymax, PH), V} || V <- Values]),
            lists:foldl(
                fun({Row, V}, B) ->
                    Label = fmt_num(V),
                    LW = tuition_widget:display_width(Label),
                    DCol = YTitleW + (TickW - LW),
                    tuition_widget:put_line(B, Area, DCol, Row, Label, Style)
                end,
                Buf,
                Rows
            )
    end.

%% The three auto ticks — max at the top, midpoint, min at the bottom — top to
%% bottom. A flat range still yields three values (all equal); they collapse to one
%% label once mapped to rows.
-spec auto_ticks(number(), number()) -> [number()].
auto_ticks(Min, Max) -> [Max, (Min + Max) / 2, Min].

%% Keep the first `{Row, Value}' per row, preserving order — so two tick values
%% that map to the same cell row draw one label (the topmost), not overprinted
%% ones.
-spec dedup_rows([{non_neg_integer(), number()}]) -> [{non_neg_integer(), number()}].
dedup_rows(Pairs) -> dedup_rows(Pairs, #{}, []).

-spec dedup_rows([{non_neg_integer(), number()}], map(), [{non_neg_integer(), number()}]) ->
    [{non_neg_integer(), number()}].
dedup_rows([], _Seen, Acc) ->
    lists:reverse(Acc);
dedup_rows([{Row, V} | Rest], Seen, Acc) ->
    case maps:is_key(Row, Seen) of
        true -> dedup_rows(Rest, Seen, Acc);
        false -> dedup_rows(Rest, Seen#{Row => true}, [{Row, V} | Acc])
    end.

%%% -- x-labels --------------------------------------------------------

%% Spread the x-labels along the row below the axis: the first flush-left at the
%% plot's left edge, the last flush-right at its right edge, the rest evenly by
%% index. Each is truncated to the plot width. Off (no labels) draws nothing.
-spec draw_x_labels(chart(), #rect{}, #layout{}, tuition_render:style(), tuition_render:buffer()) ->
    tuition_render:buffer().
draw_x_labels(Chart, Area, #layout{l = L, pw = PW, ph = PH, xlabel_h = 1}, Style, Buf) when
    PW > 0
->
    Labels = maps:get(x_labels, Chart, []),
    N = length(Labels),
    DRow = PH + 1,
    {Buf1, _} = lists:foldl(
        fun(Label, {B, I}) ->
            Text = tuition_widget:truncate(Label, PW),
            LW = tuition_widget:display_width(Text),
            DCol = L + 1 + x_label_offset(I, N, PW, LW),
            {tuition_widget:put_line(B, Area, DCol, DRow, Text, Style), I + 1}
        end,
        {Buf, 0},
        Labels
    ),
    Buf1;
draw_x_labels(_Chart, _Area, _Layout, _Style, Buf) ->
    Buf.

%% The plot-relative column for label `I' of `N', `LW' wide, across a `PW'-wide
%% plot: index 0 flush-left, index `N-1' flush-right, the rest centred on their
%% evenly-spaced anchor. Clamped so a label never starts left of the plot or runs
%% past its right edge.
-spec x_label_offset(non_neg_integer(), pos_integer(), non_neg_integer(), non_neg_integer()) ->
    non_neg_integer().
x_label_offset(0, _N, _PW, _LW) ->
    0;
x_label_offset(I, N, PW, LW) when I =:= N - 1 ->
    max(0, PW - LW);
x_label_offset(I, N, PW, LW) ->
    Anchor = round(I * (PW - 1) / (N - 1)),
    max(0, min(PW - LW, Anchor - LW div 2)).

%%% -- titles ----------------------------------------------------------

%% Draw the axis titles: the y-title written vertically down the far-left column,
%% the x-title centred in the row below the x-labels. Each is skipped when absent.
-spec draw_titles(chart(), #rect{}, #layout{}, tuition_render:style(), tuition_render:buffer()) ->
    tuition_render:buffer().
draw_titles(Chart, Area, Layout, Style, Buf) ->
    Buf1 = draw_y_title(Chart, Area, Layout, Style, Buf),
    draw_x_title(Chart, Area, Layout, Style, Buf1).

%% The y-title, one grapheme cluster per row in column 0, centred over the plot
%% height (clipped to it). Vertical because the left gutter is only wide enough for
%% a value label; a wide cluster in the one-column gutter is dropped by the clip.
-spec draw_y_title(chart(), #rect{}, #layout{}, tuition_render:style(), tuition_render:buffer()) ->
    tuition_render:buffer().
draw_y_title(Chart, Area, #layout{ytitle_w = 1, ph = PH}, Style, Buf) when PH > 0 ->
    Clusters = clusters(to_bin(maps:get(y_title, Chart, <<>>))),
    Take = min(length(Clusters), PH),
    Start = (PH - Take) div 2,
    %% Draw into the one-column gutter the title reserved, not the whole `Area',
    %% so a two-column cluster (CJK/emoji) is truncated away by {@link
    %% tuition_widget:put_line/6} rather than spilling its continuation onto the
    %% y-axis in the next column.
    Col = Area#rect{w = 1},
    {Buf1, _} = lists:foldl(
        fun(Cluster, {B, Row}) ->
            {tuition_widget:put_line(B, Col, 0, Row, Cluster, Style), Row + 1}
        end,
        {Buf, Start},
        lists:sublist(Clusters, Take)
    ),
    Buf1;
draw_y_title(_Chart, _Area, _Layout, _Style, Buf) ->
    Buf.

%% The x-title, centred across the plot width in the bottom-most reserved row
%% (below the x-labels when both are present), truncated to the plot width.
-spec draw_x_title(chart(), #rect{}, #layout{}, tuition_render:style(), tuition_render:buffer()) ->
    tuition_render:buffer().
draw_x_title(
    Chart, Area, #layout{l = L, pw = PW, ph = PH, xlabel_h = XLabelH, xtitle_h = 1}, Style, Buf
) when PW > 0 ->
    Text = tuition_widget:truncate(maps:get(x_title, Chart, <<>>), PW),
    Off = tuition_widget:align_offset(center, PW, tuition_widget:display_width(Text)),
    DRow = PH + 1 + XLabelH,
    tuition_widget:put_line(Buf, Area, L + 1 + Off, DRow, Text, Style);
draw_x_title(_Chart, _Area, _Layout, _Style, Buf) ->
    Buf.

%%% -- legend ----------------------------------------------------------

%% Draw the legend box in a corner of the plot, if configured and any dataset is
%% named. It resets the cells beneath ({@link tuition_clear}) so curves do not show
%% through, frames them ({@link tuition_block}), and lists one `■ name' row per
%% named dataset. Sized to its widest name and clamped to the plot, so it never
%% spills past the plot area. A degenerate plot, no legend, or no names: nothing.
-spec draw_legend(chart(), #rect{}, tuition_render:buffer()) -> tuition_render:buffer().
draw_legend(Chart, #rect{w = PW, h = PH} = Plot, Buf) when PW > 0, PH > 0 ->
    case maps:get(legend, Chart, false) of
        Cfg when is_map(Cfg) ->
            Named = [
                {maps:get(name, D), maps:get(color, D, default)}
             || D <- maps:get(datasets, Chart, []), maps:is_key(name, D)
            ],
            draw_legend_box(Named, Cfg, Plot, Buf);
        _ ->
            Buf
    end;
draw_legend(_Chart, _Plot, Buf) ->
    Buf.

-spec draw_legend_box(
    [{unicode:chardata(), tuition_braille:colour()}],
    map(),
    #rect{},
    tuition_render:buffer()
) -> tuition_render:buffer().
draw_legend_box([], _Cfg, _Plot, Buf) ->
    Buf;
draw_legend_box(Named, Cfg, #rect{x = PX, y = PY, w = PW, h = PH}, Buf) ->
    MaxName = widest([N || {N, _} <- Named]),
    %% swatch (1) + gap (1) + name, plus the border ring (2).
    BoxW = min(PW, MaxName + 2 + 2),
    BoxH = min(PH, length(Named) + 2),
    Position = maps:get(position, Cfg, top_right),
    {BX, BY} = legend_origin(Position, PX, PY, PW, PH, BoxW, BoxH),
    Box = #rect{x = BX, y = BY, w = BoxW, h = BoxH},
    Style = maps:get(style, Cfg, #{}),
    Buf1 = tuition_clear:render(#{style => Style}, Box, Buf),
    Buf2 = tuition_block:render(#{borders => all, border_style => Style}, Box, Buf1),
    Inner = tuition_block:inner(#{borders => all}, Box),
    draw_legend_rows(Named, Inner, Style, Buf2).

%% The top-left corner the legend box sits at, for each position — flush into the
%% chosen corner of the plot.
-spec legend_origin(
    legend_position(),
    integer(),
    integer(),
    non_neg_integer(),
    non_neg_integer(),
    non_neg_integer(),
    non_neg_integer()
) -> {integer(), integer()}.
legend_origin(top_left, PX, PY, _PW, _PH, _BW, _BH) -> {PX, PY};
legend_origin(bottom_left, PX, PY, _PW, PH, _BW, BH) -> {PX, PY + PH - BH};
legend_origin(bottom_right, PX, PY, PW, PH, BW, BH) -> {PX + PW - BW, PY + PH - BH};
legend_origin(_TopRight, PX, PY, PW, _PH, BW, _BH) -> {PX + PW - BW, PY}.

%% One `■ name' row per named dataset inside the box, the swatch in the dataset's
%% colour and the name in the legend style. Both clip to the inner rect, so rows
%% past its height (a box clamped shorter than its names) are dropped.
-spec draw_legend_rows(
    [{unicode:chardata(), tuition_braille:colour()}],
    #rect{},
    tuition_render:style(),
    tuition_render:buffer()
) -> tuition_render:buffer().
draw_legend_rows(Named, Inner, Style, Buf) ->
    {Buf1, _} = lists:foldl(
        fun({Name, Colour}, {B, Row}) ->
            SwStyle = Style#{fg => Colour},
            B1 = tuition_widget:put_line(B, Inner, 0, Row, <<?SWATCH/utf8>>, SwStyle),
            B2 = tuition_widget:put_line(B1, Inner, 2, Row, Name, Style),
            {B2, Row + 1}
        end,
        {Buf, 0},
        Named
    ),
    Buf1.

%%% -- text helpers ----------------------------------------------------

%% `lists:seq/2' that yields `[]' for an inverted range (`To < From') instead of
%% raising — so an axis loop over a degenerate span (a gutter as wide as, or wider
%% than, the pane) draws nothing rather than crashing.
-spec seq(integer(), integer()) -> [integer()].
seq(From, To) when To < From -> [];
seq(From, To) -> lists:seq(From, To).

%% The widest of a list of chardata in display columns (0 for an empty list).
-spec widest([unicode:chardata()]) -> non_neg_integer().
widest([]) -> 0;
widest(Texts) -> lists:max([tuition_widget:display_width(T) || T <- Texts]).

%% Format a number as a compact label: an integer (or integral float) with no
%% decimal point, else a float trimmed to two decimals.
-spec fmt_num(number()) -> binary().
fmt_num(N) when is_integer(N) ->
    integer_to_binary(N);
fmt_num(N) when is_float(N) ->
    case N == trunc(N) andalso abs(N) < 1.0e15 of
        true -> integer_to_binary(trunc(N));
        false -> float_to_binary(N, [{decimals, 2}, compact])
    end.

%% Split chardata into its grapheme clusters as UTF-8 binaries — for stacking a
%% title one cluster per row. A malformed tail stops the split cleanly.
-spec clusters(binary()) -> [binary()].
clusters(Bin) -> clusters(string:next_grapheme(Bin), []).

-spec clusters(term(), [binary()]) -> [binary()].
clusters([GC | Rest], Acc) when is_integer(GC); is_list(GC) ->
    %% Wrap the cluster in a list so a lone codepoint (an integer, not valid
    %% chardata on its own) and a multi-codepoint cluster both convert.
    clusters(string:next_grapheme(Rest), [to_bin([GC]) | Acc]);
clusters(_Done, Acc) ->
    lists:reverse(Acc).

%% Best-effort chardata -> UTF-8 binary; a malformed tail contributes whatever
%% prefix decoded, matching tuition_widget's own tolerance for untrusted content.
-spec to_bin(unicode:chardata()) -> binary().
to_bin(Text) ->
    case unicode:characters_to_binary(Text) of
        Bin when is_binary(Bin) -> Bin;
        {error, Good, _Rest} -> Good;
        {incomplete, Good, _Rest} -> Good
    end.
