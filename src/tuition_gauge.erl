-module(tuition_gauge).
-moduledoc """
Gauge widget — a horizontal progress bar with sub-cell precision.

A gauge fills a fraction of its area from the left with a solid bar and
overlays a label (the percentage, by default). It is the ratatui `Gauge`: the
dashboard primitive the system-dashboard tiles show a memory
breakdown, scheduler utilization or run-queue load with — a `ratio` in
`[0, 1]` drawn as a bar the eye reads at a glance.

## Sub-cell precision

The bar is drawn with the Unicode eighth-block glyphs (U+2588 `█` down to
U+258F `▏`), so a ratio that does not land on a cell boundary still shows its
true length: whole cells are full blocks and the final boundary cell is a
partial block filled to the nearest eighth of a column. A 3-column gauge at
ratio `0.5` is thus `█▌` — one-and-a-half cells — not rounded to one or two.
This mirrors ratatui's `use_unicode` gauge; the glyphs are all one column in
`m:tuition_width`, so the bar's width and the renderer's cursor advance
agree.

## Stateless

A gauge holds no state between frames: its `ratio` is recomputed by the caller
each frame from whatever it is metering (`erlang:memory/0`, a scheduler-wall-
time delta) and passed in as config. It implements the plain `m:tuition_widget` `render/3` callback — nothing to thread across the immediate-mode
rebuild.

## Config

A `#{}` map, every key optional:

- `ratio` — the fill fraction as a number in `[0.0, 1.0]`, clamped to that
  range (so a metering glitch that overshoots can never draw past the
  area). Default `0.0`.
- `label` — `none` to draw no label, or chardata to draw instead of the
  default. Absent, the label is the rounded percentage (e.g. `"63%"`).
- `label_align` — `left` | `center` (default) | `right`, where the label
  sits within the area.
- `fill_style` — the style of the filled bar glyphs (default: unstyled — a
  default-foreground bar; set at least `fg` to colour it).
- `unfilled_style` — a style for the track behind the unfilled remainder
  (default: unstyled — the track is transparent, showing whatever the
  gauge is drawn over).
- `label_style` — the label's style (default: unstyled — drawn in the
  default foreground over the bar, punched through it where they
  overlap).

The bar fills every row of the area (a taller area is a thicker bar) and the
label sits on the vertical middle row, so a one-row gauge is the common tile
and a two/three-row gauge a bolder one.
""".
-behaviour(tuition_widget).

-include("tuition_layout.hrl").

-export([render/3]).

-type gauge() :: #{
    ratio => number(),
    label => none | unicode:chardata(),
    label_align => left | center | right,
    fill_style => tuition_render:style(),
    unfilled_style => tuition_render:style(),
    label_style => tuition_render:style()
}.

-export_type([gauge/0]).

%% U+2588 FULL BLOCK — a whole filled cell. The eighth blocks below it (U+2589..
%% U+258F) fill a cell from the left in one-eighth steps; see {@link horiz_block/1}.
-define(FULL, 16#2588).

%%% -- render ----------------------------------------------------------

-doc """
Draw the gauge into `Area`. A degenerate area (no columns or rows) draws
nothing. See the module doc for the config map.
""".
-spec render(gauge(), #rect{}, tuition_render:buffer()) -> tuition_render:buffer().
render(_Gauge, #rect{w = W, h = H}, Buf) when W =< 0; H =< 0 ->
    Buf;
render(Gauge, #rect{w = W} = Area, Buf0) ->
    Ratio = clamp01(maps:get(ratio, Gauge, 0.0)),
    FillStyle = maps:get(fill_style, Gauge, #{}),
    UnfilledStyle = maps:get(unfilled_style, Gauge, #{}),
    %% Lay the track first so the unfilled remainder carries its style; the bar
    %% and label are drawn over it. An empty track style is a no-op fill, leaving
    %% whatever the gauge composites over to show through the remainder.
    Buf1 = tuition_widget:fill(Buf0, Area, UnfilledStyle),
    %% Split the filled length into whole cells and the eighths of the boundary
    %% cell, the way ratatui's unicode gauge does: floor for the full cells, the
    %% fraction rounded to eighths for the partial cell that follows them.
    Filled = W * Ratio,
    Full = trunc(Filled),
    Eighths = round((Filled - Full) * 8),
    Buf2 = draw_bars(Buf1, Area, Full, Eighths, FillStyle),
    draw_label(Buf2, Area, Gauge, Ratio).

%%% -- bar -------------------------------------------------------------

%% Draw the bar on every row of the area: the same `Full' full cells and boundary
%% partial cell, so a multi-row gauge is a solid block of the fill.
-spec draw_bars(
    tuition_render:buffer(), #rect{}, non_neg_integer(), 0..8, tuition_render:style()
) -> tuition_render:buffer().
draw_bars(Buf, #rect{h = H} = Area, Full, Eighths, Style) ->
    lists:foldl(
        fun(Row, B) -> draw_bar_row(B, Area, Row, Full, Eighths, Style) end,
        Buf,
        lists:seq(0, H - 1)
    ).

%% One row of the bar: a run of `Full' full blocks from the left, then the
%% eighth-block boundary cell (when the fraction rounded to a non-zero eighth and
%% a column is left for it). {@link tuition_widget:put_line/6} clips both to the
%% area, so a full ratio whose boundary cell would fall at the right edge simply
%% draws nothing there.
-spec draw_bar_row(
    tuition_render:buffer(),
    #rect{},
    non_neg_integer(),
    non_neg_integer(),
    0..8,
    tuition_render:style()
) -> tuition_render:buffer().
draw_bar_row(Buf, Area, Row, Full, Eighths, Style) ->
    Buf1 =
        case Full of
            0 ->
                Buf;
            _ ->
                tuition_widget:put_line(Buf, Area, 0, Row, binary:copy(<<?FULL/utf8>>, Full), Style)
        end,
    case Eighths of
        0 -> Buf1;
        _ -> tuition_widget:put_line(Buf1, Area, Full, Row, <<(horiz_block(Eighths))/utf8>>, Style)
    end.

%% The eighth-block glyph filling a cell from the left to `N' eighths: U+258F at
%% one eighth up to U+2588 (the full block) at eight — the fraction rounded to 8
%% (ratatui's rounding artifact) draws a whole cell at the boundary.
-spec horiz_block(1..8) -> char().
horiz_block(1) -> 16#258F;
horiz_block(2) -> 16#258E;
horiz_block(3) -> 16#258D;
horiz_block(4) -> 16#258C;
horiz_block(5) -> 16#258B;
horiz_block(6) -> 16#258A;
horiz_block(7) -> 16#2589;
horiz_block(8) -> ?FULL.

%%% -- label -----------------------------------------------------------

%% Draw the label on the vertical middle row, aligned within the area and clipped
%% to it. Absent label config draws the percentage; `label => none' draws nothing.
%% The label overwrites the bar glyphs it covers, so it reads as text punched
%% through the bar.
-spec draw_label(tuition_render:buffer(), #rect{}, gauge(), float()) -> tuition_render:buffer().
draw_label(Buf, #rect{w = W, h = H} = Area, Gauge, Ratio) ->
    case label_text(Gauge, Ratio) of
        none ->
            Buf;
        Text ->
            Align = maps:get(label_align, Gauge, center),
            Style = maps:get(label_style, Gauge, #{}),
            Width = min(tuition_widget:display_width(Text), W),
            Col = tuition_widget:align_offset(Align, W, Width),
            tuition_widget:put_line(Buf, Area, Col, H div 2, Text, Style)
    end.

-spec label_text(gauge(), float()) -> none | unicode:chardata().
label_text(Gauge, Ratio) ->
    case maps:get(label, Gauge, default) of
        default -> <<(integer_to_binary(round(Ratio * 100)))/binary, "%">>;
        Label -> Label
    end.

%%% -- helpers ---------------------------------------------------------

%% Clamp the ratio into `[0.0, 1.0]', so a caller whose metering momentarily
%% over- or under-shoots (a delta computed against a stale total) can never draw a
%% bar past the area or a negative length.
-spec clamp01(number()) -> float().
clamp01(N) when is_number(N) -> 0.0 + min(1.0, max(0.0, N)).
