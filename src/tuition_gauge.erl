-module(tuition_gauge).
-moduledoc """
A horizontal progress bar.

Give it a `ratio` between 0 and 1 and it fills that fraction of its area from
the left, drawing a label on top (the percentage, by default). It is the
equivalent of ratatui's `Gauge`: the kind of bar a dashboard uses to show
memory use, scheduler load or run-queue depth at a glance.

## Sub-cell precision

The bar is drawn with the Unicode eighth-block characters (`█` down to `▏`), so
it can end partway through a cell. Whole cells are full blocks, and the last
cell is a partial block filled to the nearest eighth. A 3-column gauge at ratio
`0.5` draws as `█▌` (one and a half cells) rather than rounding to one or two.
This matches ratatui's `use_unicode` gauge. Every glyph is one column wide in
`m:tuition_width`, so the bar's width and the renderer's cursor stay in step.

## Stateless

A gauge keeps no state between frames. The caller recomputes `ratio` each frame
from whatever it is measuring (`erlang:memory/0`, a scheduler delta) and passes
it in as config, so the gauge only needs the plain `m:tuition_widget` `render/3`
callback.

## Config

A map, every key optional:

- `ratio` — the fill fraction, a number in `[0.0, 1.0]`. Values outside that
  range are clamped, so a measurement glitch that overshoots can never draw past
  the area. Default `0.0`.
- `label` — `none` for no label, or chardata to draw instead of the default.
  Omit it and the label is the rounded percentage (e.g. `"63%"`).
- `label_align` — `left`, `center` (default) or `right`.
- `fill_style` — the style of the filled bar (default: unstyled, a
  default-foreground bar; set at least `fg` to colour it).
- `unfilled_style` — the style of the track behind the unfilled part (default:
  unstyled, so the track is transparent and whatever is underneath shows
  through).
- `label_style` — the label's style (default: unstyled, drawn in the default
  foreground over the bar).

The bar fills every row of the area, so a taller area makes a thicker bar, and
the label sits on the middle row. A one-row gauge is the usual tile; two or
three rows make a bolder one.
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
Draw the gauge into `Area`. An empty area (zero width or height) draws nothing.
See the module doc for the config map.
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
