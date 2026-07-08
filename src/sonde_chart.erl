%%%-------------------------------------------------------------------
%%% @doc Chart widget — time-series trend curves at sub-cell resolution.
%%%
%%% Where {@link sonde_sparkline} draws one block bar per sample (eight vertical
%%% levels, one column wide), a chart plots its samples as continuous curves on a
%%% {@link sonde_braille} grid — 8× the vertical and 2× the horizontal resolution
%%% — so a BEAM trend (run-queue length, reductions/s, IO throughput over a
%%% rolling window) reads as a smooth line rather than a staircase. It is
%%% ratatui's `Chart' drawn with `Marker::Braille': the dashboard primitive (PRD
%%% §9.1) the Phase 1 system dashboard's trend panel is built from.
%%%
%%% == Datasets ==
%%% One or more datasets share the plot, each a series drawn in its own colour as
%%% a connected `line', a `scatter' of dots, or a filled `area' (each sample's
%%% column solid from the baseline up to its value). A series is a list of numbers
%%% sampled over time (as {@link sonde_sparkline}'s is); the value is the y-axis
%%% and the sample's position in the series the x-axis. Overlaying several series
%%% (IO in and out, say) puts them on one shared value scale so they are directly
%%% comparable.
%%%
%%% == The rolling window ==
%%% Only the newest samples are plotted — one per sub-pixel column, and the
%%% sub-pixel width is `2×' the cell width, so at most the newest `2W' samples
%%% fit. `window' bounds how many of them to show: `auto' (default) uses as many
%%% of the newest samples as the width holds; an explicit count `N' shows only the
%%% newest `N' (clamped to the `2W' the width can draw), a fixed-duration window
%%% that stays the same on-screen span regardless of how much history the caller
%%% has accumulated. A caller keeps appending to a bounded history and the chart
%%% shows its tail, scrolling as new samples arrive.
%%%
%%% `x_align' fixes where the window sits when it is narrower than the plot (a
%%% short history, or a `window' count below `2W'): `left' (default) grows the
%%% curve rightward from the left edge (as {@link sonde_sparkline} does); `right'
%%% pins the newest sample to the right edge and leaves the left blank until the
%%% window fills — the live-trend look (newest always hard against the right), and
%%% the anchoring that keeps multiple series aligned by recency rather than by age.
%%%
%%% == Bounds ==
%%% `y_bounds' is `auto' (default — the min and max across every visible dataset
%%% map to the bottom and top of the plot) or an explicit `{Min, Max}' held stable
%%% frame to frame (a metric with a known ceiling, so the curve does not rescale
%%% under its own noise). A value outside explicit bounds is clamped into the
%%% plot; a flat series (all one value, or `Min =:= Max') is drawn along the
%%% vertical middle rather than dividing by a zero range.
%%%
%%% == One colour per cell (known constraint) ==
%%% A {@link sonde_braille} cell shares one `fg' across its eight dots, so where
%%% two datasets light dots in the *same* cell the later-drawn dataset wins that
%%% cell's colour (its dots merge, but the colour is last-writer-wins) — ratatui's
%%% canvas layering. Datasets are plotted in list order, so the last dataset wins
%%% collisions. Where series must never visually collide, give each its own chart
%%% tile (stacked by {@link sonde_layout}) rather than overlaying them.
%%%
%%% == Optional axes ==
%%% With `axes => true' the widget insets the plot by one column on the left and
%%% one row at the bottom and draws a light box-drawing y-axis and x-axis meeting
%%% at the origin — the reference frame a bare trend strip lacks. Value/time
%%% labels are the caller's to compose (a {@link sonde_block} title, an adjacent
%%% {@link sonde_paragraph}), as {@link sonde_sparkline} leaves them, since their
%%% formatting is metric-specific.
%%%
%%% == Stateless ==
%%% A chart holds no state between frames: the caller keeps each series' history
%%% and passes it as config. It implements the plain {@link sonde_widget}
%%% `render/3' callback.
%%%
%%% == Config ==
%%% A `#{}' map, every key optional:
%%% <ul>
%%%   <li>`datasets' — a list of dataset maps (default `[]' — an empty chart draws
%%%       only its axes, if enabled). Each dataset:
%%%       <ul>
%%%         <li>`data' — the series, a list of numbers (default `[]').</li>
%%%         <li>`color' — the dot colour (default `default' — the base foreground).</li>
%%%         <li>`marker' — `line' (default; connect consecutive samples),
%%%             `scatter' (a dot per sample), or `area' (fill each sample's column
%%%             from the baseline up to its value — a filled area/column chart).</li>
%%%       </ul></li>
%%%   <li>`y_bounds' — `auto' (default) or an explicit `{Min, Max}'.</li>
%%%   <li>`window' — `auto' (default; as many newest samples as the width holds)
%%%       or a positive integer count of the newest samples to show (clamped to
%%%       the width).</li>
%%%   <li>`x_align' — `left' (default; grow from the left edge) or `right' (pin the
%%%       newest sample to the right edge).</li>
%%%   <li>`axes' — `true' to draw the axis frame, `false' (default) for a bare plot.</li>
%%%   <li>`axis_style' — the style of the axis glyphs (default: unstyled).</li>
%%% </ul>
%%%
%%% HARD CONSTRAINT (PRD §12): depends only on `kernel'/`stdlib'/`erts' plus the
%%% sibling braille/render/layout/widget modules. No third-party code.
%%% @end
%%%-------------------------------------------------------------------
-module(sonde_chart).
-behaviour(sonde_widget).

-include("sonde_layout.hrl").

-export([render/3]).

-type dataset() :: #{
    data => [number()],
    color => sonde_braille:colour(),
    marker => line | scatter | area
}.

-type chart() :: #{
    datasets => [dataset()],
    y_bounds => auto | {number(), number()},
    window => auto | pos_integer(),
    x_align => left | right,
    axes => boolean(),
    axis_style => sonde_render:style()
}.

-export_type([chart/0, dataset/0]).

%% Light box-drawing glyphs for the optional axis frame.
-define(V_AXIS, 16#2502).
%% │
-define(H_AXIS, 16#2500).
%% ─
-define(CORNER, 16#2514).
%% └

%%% -- render ----------------------------------------------------------

%% @doc Draw the chart into `Area'. A degenerate area (no columns or rows) draws
%% nothing. See the module doc for the config map.
-spec render(chart(), #rect{}, sonde_render:buffer()) -> sonde_render:buffer().
render(_Chart, #rect{w = W, h = H}, Buf) when W =< 0; H =< 0 ->
    Buf;
render(Chart, Area, Buf0) ->
    {PlotArea, Buf1} =
        case maps:get(axes, Chart, false) of
            true -> draw_axes(Buf0, Area, maps:get(axis_style, Chart, #{}));
            false -> {Area, Buf0}
        end,
    case PlotArea of
        #rect{w = PW, h = PH} when PW =< 0; PH =< 0 -> Buf1;
        _ -> plot(Chart, PlotArea, Buf1)
    end.

%%% -- plotting --------------------------------------------------------

%% Rasterize every dataset onto one shared braille grid over the plot area, then
%% composite it in. A shared grid is what makes overlapping cells merge their dots
%% and take the last dataset's colour (the one-colour-per-cell rule); datasets are
%% folded in list order so the last wins a collision.
-spec plot(chart(), #rect{}, sonde_render:buffer()) -> sonde_render:buffer().
plot(Chart, Area, Buf) ->
    Grid0 = sonde_braille:new(Area),
    {PW, PH} = sonde_braille:dims(Grid0),
    WinCount = resolve_window(maps:get(window, Chart, auto), PW),
    XAlign = maps:get(x_align, Chart, left),
    Series = [prepare(D, WinCount) || D <- maps:get(datasets, Chart, [])],
    {Ymin, Ymax} = resolve_bounds(maps:get(y_bounds, Chart, auto), Series),
    Grid1 = lists:foldl(
        fun({Colour, Marker, Window}, G) ->
            Col0 = col_offset(XAlign, PW, length(Window)),
            plot_series(G, points(Window, Ymin, Ymax, PH, Col0), Marker, Colour, PH)
        end,
        Grid0,
        Series
    ),
    sonde_braille:render_into(Grid1, Buf).

%% A dataset reduced to what plotting needs: its colour, its marker, and the
%% newest `WinCount' samples of its series (the tail the window shows).
-spec prepare(dataset(), non_neg_integer()) ->
    {sonde_braille:colour(), line | scatter | area, [number()]}.
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

%% Map a window to its sub-pixel points: sample `I' (0-based, left to right)
%% starting at column `Col0', its value scaled to a row. The list is in the
%% window's order, so consecutive points are adjacent columns a line can connect.
-spec points([number()], number(), number(), non_neg_integer(), integer()) ->
    [{integer(), non_neg_integer()}].
points(Window, Ymin, Ymax, PH, Col0) ->
    {Points, _} = lists:mapfoldl(
        fun(V, Col) -> {{Col, value_to_row(V, Ymin, Ymax, PH)}, Col + 1} end,
        Col0,
        Window
    ),
    Points.

%% Plot one series' points. `scatter' lights each point; `area' fills each point's
%% column from its value down to the baseline; `line' connects consecutive points
%% with a rasterized segment (a lone point is just lit, having no neighbour to
%% connect to). An empty series draws nothing. `PH' is the sub-pixel height, the
%% baseline the `area' fill reaches to.
-spec plot_series(
    sonde_braille:grid(),
    [{integer(), non_neg_integer()}],
    line | scatter | area,
    sonde_braille:colour(),
    non_neg_integer()
) -> sonde_braille:grid().
plot_series(Grid, [], _Marker, _Colour, _PH) ->
    Grid;
plot_series(Grid, Points, scatter, Colour, _PH) ->
    lists:foldl(fun({X, Y}, G) -> sonde_braille:set(G, X, Y, Colour) end, Grid, Points);
plot_series(Grid, Points, area, Colour, PH) ->
    lists:foldl(fun({X, Y}, G) -> fill_column(G, X, Y, PH, Colour) end, Grid, Points);
plot_series(Grid, [{X, Y}], line, Colour, _PH) ->
    sonde_braille:set(Grid, X, Y, Colour);
plot_series(Grid, [{X0, Y0} | [{X1, Y1} | _] = Rest], line, Colour, PH) ->
    plot_series(sonde_braille:line(Grid, X0, Y0, X1, Y1, Colour), Rest, line, Colour, PH).

%% Fill one column from `YTop' (a sample's value row) down to the baseline (the
%% bottom sub-pixel row `PH - 1') — the solid area/column fill below the curve.
%% `YTop' is already clamped into `[0, PH - 1]' by {@link value_to_row/4}, so the
%% range is never empty or inverted.
-spec fill_column(
    sonde_braille:grid(), integer(), non_neg_integer(), non_neg_integer(), sonde_braille:colour()
) -> sonde_braille:grid().
fill_column(Grid, X, YTop, PH, Colour) ->
    lists:foldl(fun(Y, G) -> sonde_braille:set(G, X, Y, Colour) end, Grid, lists:seq(YTop, PH - 1)).

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

%% The sub-pixel row a value maps to: `Ymax' at the top (row 0), `Ymin' at the
%% bottom (row `PH - 1'), linearly between, clamped into the plot so a value past
%% explicit bounds sits on the edge rather than off-grid. A non-positive range (a
%% flat series, or inverted explicit bounds) has no gradient, so every value is
%% drawn along the vertical middle.
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
%% shorter than the plot is wide. Mirrors {@link sonde_sparkline}'s window.
-spec window([number()], non_neg_integer()) -> [number()].
window(Data, N) ->
    Len = length(Data),
    case Len > N of
        true -> lists:nthtail(Len - N, Data);
        false -> Data
    end.

%%% -- axes ------------------------------------------------------------

%% Draw the axis frame in the left column and bottom row of `Area' and return the
%% inset plot rect (one narrower, one shorter) the curves are drawn into. The
%% y-axis runs up the left column, the x-axis along the bottom row, meeting at a
%% corner glyph at the bottom-left. Each glyph clips to `Area' via {@link
%% sonde_widget:put_line/6}, so a one-column or one-row area degrades to just the
%% part of the frame that fits (the plot rect then coming back degenerate, drawn
%% as nothing by {@link render/3}).
-spec draw_axes(sonde_render:buffer(), #rect{}, sonde_render:style()) ->
    {#rect{}, sonde_render:buffer()}.
draw_axes(Buf, #rect{x = X, y = Y, w = W, h = H} = Area, Style) ->
    Bottom = H - 1,
    %% y-axis: the left column, every row above the corner.
    Buf1 = lists:foldl(
        fun(Row, B) -> sonde_widget:put_line(B, Area, 0, Row, <<?V_AXIS/utf8>>, Style) end,
        Buf,
        lists:seq(0, Bottom - 1)
    ),
    %% x-axis: the bottom row, every column right of the corner.
    Buf2 = lists:foldl(
        fun(Col, B) -> sonde_widget:put_line(B, Area, Col, Bottom, <<?H_AXIS/utf8>>, Style) end,
        Buf1,
        lists:seq(1, W - 1)
    ),
    Buf3 = sonde_widget:put_line(Buf2, Area, 0, Bottom, <<?CORNER/utf8>>, Style),
    {#rect{x = X + 1, y = Y, w = W - 1, h = H - 1}, Buf3}.
