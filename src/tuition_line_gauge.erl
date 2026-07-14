%%%-------------------------------------------------------------------
%%% @doc LineGauge widget — a single-row progress indicator (stateless).
%%%
%%% A line gauge draws a label and then a thin horizontal line across the rest of
%%% one row, the leading fraction of the line drawn `filled' and the remainder
%%% `unfilled', so a `ratio' in `[0, 1]' reads at a glance in a single cell of
%%% height. It is the ratatui `LineGauge': the compact sibling of {@link
%%% tuition_gauge}, for dense dashboards where the full-height bar — which fills
%%% every row of its area — is too heavy and you want many metrics stacked one per
%%% line rather than a few thick bars.
%%%
%%% == vs. the full gauge ==
%%% {@link tuition_gauge} fills its whole area with a solid block bar (a taller area
%%% is a thicker bar) and centres the label over it. A line gauge instead commits to
%%% one row: label at the left, a one-cell-high line filling the width to its right.
%%% Give it a one-row rect (the common tile); a taller rect is drawn on its top row
%%% and the rows below are left untouched, so several line gauges tile compactly
%%% down a column.
%%%
%%% == Whole-cell fill ==
%%% Like ratatui's `LineGauge' the fill advances a whole cell at a time: the filled
%%% length is `floor(LineWidth * ratio)' cells drawn in `filled_style', the rest of
%%% the line in `unfilled_style', both using the same line glyph. There is no
%%% sub-cell boundary block — the line glyph is a rule, not a solid bar, so it has no
%%% partial-fill form; the fraction shows through the styling split, not a boundary
%%% glyph. (The full {@link tuition_gauge} keeps its eighth-block sub-cell precision;
%%% this widget trades it for the single-row footprint.)
%%%
%%% == Stateless ==
%%% A line gauge holds no state between frames: its `ratio' is recomputed by the
%%% caller each frame from whatever it is metering and passed in as config, exactly
%%% as for {@link tuition_gauge}. It implements the plain {@link tuition_widget}
%%% `render/3' callback — nothing to thread across the immediate-mode rebuild.
%%%
%%% == Config ==
%%% A `#{}' map, every key optional:
%%% <ul>
%%%   <li>`ratio' — the fill fraction as a number in `[0.0, 1.0]', clamped to that
%%%       range (so a metering glitch that overshoots can never draw a line past the
%%%       area or a negative length). Default `0.0'.</li>
%%%   <li>`label' — `none' to draw no label (the line then spans the full width), or
%%%       chardata to draw instead of the default. Absent, the label is the rounded
%%%       percentage (e.g. `"63%"'). The line begins one blank column after the
%%%       label.</li>
%%%   <li>`line' — the line glyph: `thin' (default, `─' U+2500) or `heavy' (`━'
%%%       U+2501), the ratatui light/thick pair, or custom single-cell chardata used
%%%       for the whole rule.</li>
%%%   <li>`filled_style' — the style of the filled leading run (default: unstyled — a
%%%       default-foreground line; set at least `fg' to colour it).</li>
%%%   <li>`unfilled_style' — the style of the unfilled trailing run (default:
%%%       unstyled).</li>
%%%   <li>`label_style' — the label's style (default: unstyled).</li>
%%% </ul>
%%%
%%% Because filled and unfilled share the line glyph, the fill is legible only when
%%% `filled_style' and `unfilled_style' differ (a colour, or bold) — matching
%%% ratatui, where the line set is one symbol and the styles carry the distinction.
%%%
%%% HARD CONSTRAINT (PRD §12): depends only on `kernel'/`stdlib'/`erts' plus the
%%% sibling render/layout/width/widget modules. No third-party code.
%%% @end
%%%-------------------------------------------------------------------
-module(tuition_line_gauge).
-behaviour(tuition_widget).

-include("tuition_layout.hrl").

-export([render/3]).

-type line() :: thin | heavy | unicode:chardata().

-type line_gauge() :: #{
    ratio => number(),
    label => none | unicode:chardata(),
    line => line(),
    filled_style => tuition_render:style(),
    unfilled_style => tuition_render:style(),
    label_style => tuition_render:style()
}.

-export_type([line_gauge/0, line/0]).

%% U+2500 BOX DRAWINGS LIGHT HORIZONTAL — the default (thin) rule.
-define(THIN, 16#2500).
%% U+2501 BOX DRAWINGS HEAVY HORIZONTAL — the `heavy' rule.
-define(HEAVY, 16#2501).

%%% -- render ----------------------------------------------------------

%% @doc Draw the line gauge into `Area', on its top row. A degenerate area (no
%% columns or rows) draws nothing. See the module doc for the config map.
-spec render(line_gauge(), #rect{}, tuition_render:buffer()) -> tuition_render:buffer().
render(_Cfg, #rect{w = W, h = H}, Buf) when W =< 0; H =< 0 ->
    Buf;
render(Cfg, #rect{w = W} = Area, Buf0) ->
    Ratio = clamp01(maps:get(ratio, Cfg, 0.0)),
    Glyph = line_glyph(maps:get(line, Cfg, thin)),
    FilledStyle = maps:get(filled_style, Cfg, #{}),
    UnfilledStyle = maps:get(unfilled_style, Cfg, #{}),
    %% Lay the label first and learn where the line may begin (one column past it),
    %% then draw the filled/unfilled runs across whatever width is left.
    {Buf1, Start} = draw_label(Buf0, Area, Cfg, Ratio),
    draw_line(Buf1, Area, Start, W - Start, Ratio, Glyph, FilledStyle, UnfilledStyle).

%%% -- label -----------------------------------------------------------

%% Draw the label at the left of the top row and return `{Buf, LineStart}', the
%% column the line begins at: `0' when there is no label (the line spans the full
%% width), else one blank column past the label's clipped width — the ratatui gap
%% between label and rule. Absent label config draws the percentage; `label => none'
%% draws nothing and yields the whole width to the line.
-spec draw_label(tuition_render:buffer(), #rect{}, line_gauge(), float()) ->
    {tuition_render:buffer(), non_neg_integer()}.
draw_label(Buf, #rect{w = W} = Area, Cfg, Ratio) ->
    case label_text(Cfg, Ratio) of
        none ->
            {Buf, 0};
        Text ->
            Style = maps:get(label_style, Cfg, #{}),
            Buf1 = tuition_widget:put_line(Buf, Area, 0, 0, Text, Style),
            %% The line starts one column after the drawn (clipped) label; when the
            %% label already fills the row, `Start' lands at/after the right edge and
            %% draw_line finds no width for the rule.
            LabelW = min(tuition_widget:display_width(Text), W),
            {Buf1, LabelW + 1}
    end.

-spec label_text(line_gauge(), float()) -> none | unicode:chardata().
label_text(Cfg, Ratio) ->
    case maps:get(label, Cfg, default) of
        default -> <<(integer_to_binary(round(Ratio * 100)))/binary, "%">>;
        Label -> Label
    end.

%%% -- line ------------------------------------------------------------

%% Draw the rule from column `Start' across `LineW' cells of the top row: the
%% leading `floor(LineW * Ratio)' cells filled, the rest unfilled, both the same
%% glyph. A non-positive width (the label filled the row) draws nothing.
-spec draw_line(
    tuition_render:buffer(),
    #rect{},
    non_neg_integer(),
    integer(),
    float(),
    binary(),
    tuition_render:style(),
    tuition_render:style()
) -> tuition_render:buffer().
draw_line(Buf, _Area, _Start, LineW, _Ratio, _Glyph, _FilledStyle, _UnfilledStyle) when
    LineW =< 0
->
    Buf;
draw_line(Buf, Area, Start, LineW, Ratio, Glyph, FilledStyle, UnfilledStyle) ->
    %% Floor the filled length to whole cells (ratatui's LineGauge); the boundary
    %% cell belongs to the unfilled run, so the fill never over-reports.
    Filled = trunc(LineW * Ratio),
    Buf1 = draw_run(Buf, Area, Start, Filled, Glyph, FilledStyle),
    draw_run(Buf1, Area, Start + Filled, LineW - Filled, Glyph, UnfilledStyle).

%% Draw `N' cells of `Glyph' from column `Off' along the top row. {@link
%% tuition_widget:put_line/6} clips the run to `Area', so a length that overshoots
%% (a miscomputed split) can never spill past the widget's rect.
-spec draw_run(
    tuition_render:buffer(),
    #rect{},
    non_neg_integer(),
    integer(),
    binary(),
    tuition_render:style()
) -> tuition_render:buffer().
draw_run(Buf, _Area, _Off, N, _Glyph, _Style) when N =< 0 ->
    Buf;
draw_run(Buf, Area, Off, N, Glyph, Style) ->
    tuition_widget:put_line(Buf, Area, Off, 0, binary:copy(Glyph, N), Style).

%%% -- helpers ---------------------------------------------------------

%% The rule glyph as a UTF-8 binary: the `thin'/`heavy' presets, or custom chardata
%% (assumed a single cell wide, like the scrollbar's track/thumb glyphs) normalised
%% to a binary so a run is a plain `binary:copy/2'.
-spec line_glyph(line()) -> binary().
line_glyph(thin) -> <<?THIN/utf8>>;
line_glyph(heavy) -> <<?HEAVY/utf8>>;
line_glyph(Custom) -> to_bin(Custom).

%% Best-effort chardata -> UTF-8 binary; a malformed tail contributes whatever
%% prefix decoded, matching tuition_widget's own tolerance for untrusted content.
-spec to_bin(unicode:chardata()) -> binary().
to_bin(Text) ->
    case unicode:characters_to_binary(Text) of
        Bin when is_binary(Bin) -> Bin;
        {error, Good, _Rest} -> Good;
        {incomplete, Good, _Rest} -> Good
    end.

%% Clamp the ratio into `[0.0, 1.0]', so a caller whose metering momentarily over-
%% or under-shoots can never draw a line past the area or a negative fill length.
-spec clamp01(number()) -> float().
clamp01(N) when is_number(N) -> 0.0 + min(1.0, max(0.0, N)).
