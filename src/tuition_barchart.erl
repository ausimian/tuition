%%%-------------------------------------------------------------------
%%% @doc BarChart widget — labeled categorical bars (stateless).
%%%
%%% A bar chart draws one bar per discrete category, its length proportional to
%%% the category's value, with the value printed on the bar and a label beside
%%% (or beneath) it. It is the ratatui `BarChart': where {@link tuition_sparkline}
%%% packs a whole numeric series into a compact, unlabeled strip, the bar chart is
%%% the readable view of a handful of *named* quantities — per-scheduler
%%% utilization, a memory-by-type breakdown, the top-N processes by reductions
%%% (PRD §9.1).
%%%
%%% == Two directions ==
%%% `vertical' (the default) grows bars upward from a baseline with the labels in
%%% a row beneath them — the classic column chart, good for a fixed set of
%%% categories (the schedulers, the memory types). `horizontal' grows bars
%%% rightward, each on its own row with its label and value inline — good for a
%%% top-N list where the labels are words, not glyphs, and want the room a whole
%%% row gives them.
%%%
%%% == Sub-cell precision ==
%%% Bars are drawn with the Unicode eighth-block glyphs so a value that does not
%%% land on a cell boundary still shows its true length. A vertical bar fills
%%% bottom-up (U+2581 `▁' up to U+2588 `█', the sparkline's nine-level set); a
%%% horizontal bar fills left to right (U+258F `▏' up to U+2588, the gauge's set).
%%% Every glyph is one column in {@link tuition_width}, so the bar's length and the
%%% renderer's cursor advance agree.
%%%
%%% == Scaling ==
%%% All bars share one scale so their lengths are comparable: `max' maps to the
%%% full length of a bar — the bar-area height when vertical, the track width when
%%% horizontal. Pass `max' explicitly when the categories have a known ceiling
%%% (utilization tops out at 100, a memory breakdown at the node total) so the
%%% chart's proportions are stable frame to frame; leave it `auto' and the largest
%%% value fills the length. A value above `max' is clamped to full rather than
%%% overflowing; a negative value is treated as zero.
%%%
%%% == Stateless ==
%%% A bar chart holds no state between frames: the caller recomputes the bars each
%%% frame and passes them as config. It implements the plain {@link tuition_widget}
%%% `render/3' callback.
%%%
%%% == Config ==
%%% A `#{}' map, every key optional:
%%% <ul>
%%%   <li>`bars' — the categories, a list of bar maps (default `[]', an empty chart
%%%       draws nothing). Each bar is itself a `#{}', every key optional:
%%%     <ul>
%%%       <li>`value' — the bar's magnitude, a non-negative number (default `0'; a
%%%           negative value counts as zero length). An integer prints as itself; a
%%%           float to two decimals.</li>
%%%       <li>`label' — chardata drawn beneath (vertical) or left of (horizontal)
%%%           the bar (default: none). A vertical label is clipped to the bar's
%%%           width, so wide labels want `horizontal'.</li>
%%%       <li>`text_value' — chardata printed on the bar in place of the formatted
%%%           `value' (e.g. `"82%"', `"1.2G"'); `none' to print nothing.</li>
%%%       <li>`style' — the style of this bar's glyphs (default: unstyled — set at
%%%           least `fg' to colour it).</li>
%%%     </ul></li>
%%%   <li>`direction' — `vertical' (default) | `horizontal'.</li>
%%%   <li>`max' — `auto' (default; the largest bar value — a fractional largest is
%%%       honoured, so a chart of ratios in `[0, 1]' fills its bars) or an explicit
%%%       positive number every bar is scaled against. A non-positive or empty
%%%       scale falls back to 1 to keep the arithmetic well defined.</li>
%%%   <li>`bar_width' — a bar's thickness: its width in columns when vertical, its
%%%       height in rows when horizontal (default `1', floored at `1').</li>
%%%   <li>`bar_gap' — blank cells between adjacent bars (default `1', floored at
%%%       `0').</li>
%%%   <li>`label_style' — the labels' style (default: unstyled).</li>
%%%   <li>`value_style' — the on-bar values' style (default: unstyled — drawn in the
%%%       default foreground, punched through the bar where they overlap).</li>
%%% </ul>
%%%
%%% Bars are laid in the order given — left to right (vertical) or top to bottom
%%% (horizontal) — and clipped to `Area': a bar past the far edge is not drawn (the
%%% chart is truncated, never wrapped). Grouped bars (ratatui's `BarGroup') are a
%%% later enhancement.
%%%
%%% HARD CONSTRAINT (PRD §12): depends only on `kernel'/`stdlib'/`erts' plus the
%%% sibling render/layout/width/widget modules. No third-party code.
%%% @end
%%%-------------------------------------------------------------------
-module(tuition_barchart).
-behaviour(tuition_widget).

-include("tuition_layout.hrl").

-export([render/3]).

-type bar() :: #{
    value => number(),
    label => unicode:chardata(),
    text_value => none | unicode:chardata(),
    style => tuition_render:style()
}.

-type barchart() :: #{
    bars => [bar()],
    direction => vertical | horizontal,
    max => auto | number(),
    bar_width => pos_integer(),
    bar_gap => non_neg_integer(),
    label_style => tuition_render:style(),
    value_style => tuition_render:style()
}.

-export_type([bar/0, barchart/0]).

%% U+2588 FULL BLOCK — a whole filled cell, shared by both bar sets (the top of
%% the vertical set and the right of the horizontal one).
-define(FULL, 16#2588).

%%% -- render ----------------------------------------------------------

%% @doc Draw the bar chart into `Area'. A degenerate area (no columns or rows)
%% draws nothing. See the module doc for the config map.
-spec render(barchart(), #rect{}, tuition_render:buffer()) -> tuition_render:buffer().
render(_Cfg, #rect{w = W, h = H}, Buf) when W =< 0; H =< 0 ->
    Buf;
render(Cfg, Area, Buf) ->
    Bars = maps:get(bars, Cfg, []),
    BarWidth = max(1, maps:get(bar_width, Cfg, 1)),
    BarGap = max(0, maps:get(bar_gap, Cfg, 1)),
    LabelStyle = maps:get(label_style, Cfg, #{}),
    ValueStyle = maps:get(value_style, Cfg, #{}),
    Max = resolve_max(maps:get(max, Cfg, auto), Bars),
    case maps:get(direction, Cfg, vertical) of
        horizontal ->
            draw_horizontal(Buf, Area, Bars, BarWidth, BarGap, Max, LabelStyle, ValueStyle);
        _ ->
            draw_vertical(Buf, Area, Bars, BarWidth, BarGap, Max, LabelStyle, ValueStyle)
    end.

%%% -- vertical --------------------------------------------------------

%% Column chart: bars grow up from the baseline, left to right, with a reserved
%% bottom row for the labels when any bar carries one. Each bar's value is printed
%% on its base row (the bottom of the bar area), centred over the bar and punched
%% through it.
-spec draw_vertical(
    tuition_render:buffer(),
    #rect{},
    [bar()],
    pos_integer(),
    non_neg_integer(),
    number(),
    tuition_render:style(),
    tuition_render:style()
) -> tuition_render:buffer().
draw_vertical(Buf, #rect{h = H} = Area, Bars, BarWidth, BarGap, Max, LabelStyle, ValueStyle) ->
    LabelRows =
        case lists:any(fun has_label/1, Bars) of
            true -> 1;
            false -> 0
        end,
    %% The rows above the (optional) label row that the bars fill.
    BarH = H - LabelRows,
    {_Col, Out} = lists:foldl(
        fun(Bar, {Col, B}) ->
            B1 = draw_vbar(B, Area, Col, BarWidth, Bar, Max, BarH, ValueStyle),
            B2 = draw_vlabel(B1, Area, Col, BarWidth, Bar, H, LabelRows, LabelStyle),
            {Col + BarWidth + BarGap, B2}
        end,
        {0, Buf},
        Bars
    ),
    Out.

%% One vertical bar: `BarWidth' columns filled bottom-up to the value's height in
%% eighths of the bar area, then the value text centred on the base row over it. A
%% zero-height bar area (a one-row chart that spent its only row on labels) draws
%% nothing.
-spec draw_vbar(
    tuition_render:buffer(),
    #rect{},
    non_neg_integer(),
    pos_integer(),
    bar(),
    number(),
    integer(),
    tuition_render:style()
) -> tuition_render:buffer().
draw_vbar(Buf, _Area, _Col, _BarWidth, _Bar, _Max, BarH, _ValueStyle) when BarH =< 0 ->
    Buf;
draw_vbar(Buf, Area, Col, BarWidth, Bar, Max, BarH, ValueStyle) ->
    Style = maps:get(style, Bar, #{}),
    Eighths = eighths(bar_value(Bar), Max, BarH * 8),
    Buf1 = lists:foldl(
        fun(Row, B) ->
            draw_hspan(B, Area, Col, BarWidth, Row, cell_eighths(Eighths, Row, BarH), Style)
        end,
        Buf,
        lists:seq(0, BarH - 1)
    ),
    draw_centered(Buf1, Area, Col, BarWidth, BarH - 1, value_text(Bar), ValueStyle).

%% Draw the vertical eighth-block glyph for `N' eighths across a whole bar's width
%% at `Row' (area-relative). Zero eighths draws nothing, leaving whatever the chart
%% composites over to show through.
-spec draw_hspan(
    tuition_render:buffer(),
    #rect{},
    non_neg_integer(),
    pos_integer(),
    non_neg_integer(),
    0..8,
    tuition_render:style()
) -> tuition_render:buffer().
draw_hspan(Buf, _Area, _Col, _BarWidth, _Row, 0, _Style) ->
    Buf;
draw_hspan(Buf, Area, Col, BarWidth, Row, N, Style) ->
    Glyph = <<(vert_block(N))/utf8>>,
    lists:foldl(
        fun(C, B) -> tuition_widget:put_line(B, Area, Col + C, Row, Glyph, Style) end,
        Buf,
        lists:seq(0, BarWidth - 1)
    ).

%% The category label, centred on the reserved bottom row under its bar (nothing
%% when no bar carries a label, so the whole area is bars).
-spec draw_vlabel(
    tuition_render:buffer(),
    #rect{},
    non_neg_integer(),
    pos_integer(),
    bar(),
    non_neg_integer(),
    0..1,
    tuition_render:style()
) -> tuition_render:buffer().
draw_vlabel(Buf, _Area, _Col, _BarWidth, _Bar, _H, 0, _LabelStyle) ->
    Buf;
draw_vlabel(Buf, Area, Col, BarWidth, Bar, H, 1, LabelStyle) ->
    draw_centered(Buf, Area, Col, BarWidth, H - 1, bar_label(Bar), LabelStyle).

%%% -- horizontal ------------------------------------------------------

%% Top-N list: bars grow rightward, one per row (a `bar_width'-row-thick band,
%% `bar_gap' rows apart), with the label in a reserved left column and the value
%% right-aligned in a reserved right column so the numbers line up. The columns are
%% sized to the widest label and value so the bar tracks all start and end
%% together.
-spec draw_horizontal(
    tuition_render:buffer(),
    #rect{},
    [bar()],
    pos_integer(),
    non_neg_integer(),
    number(),
    tuition_render:style(),
    tuition_render:style()
) -> tuition_render:buffer().
draw_horizontal(Buf, #rect{w = W} = Area, Bars, BarWidth, BarGap, Max, LabelStyle, ValueStyle) ->
    LabelW = max_width([bar_label(B) || B <- Bars]),
    ValueW = max_width([value_text(B) || B <- Bars]),
    %% A one-column separator flanks each reserved column, but only when it exists.
    TrackX = LabelW + gap_if(LabelW),
    TrackW = max(0, W - TrackX - gap_if(ValueW) - ValueW),
    ValueX = W - ValueW,
    {_Row, Out} = lists:foldl(
        fun(Bar, {Row, B}) ->
            B1 = draw_hbar(B, Area, TrackX, TrackW, Row, BarWidth, Bar, Max),
            %% Label and value sit on the band's middle row.
            Mid = Row + BarWidth div 2,
            B2 = draw_hlabel(B1, Area, LabelW, Mid, bar_label(Bar), LabelStyle),
            B3 = draw_hvalue(B2, Area, ValueX, ValueW, Mid, value_text(Bar), ValueStyle),
            {Row + BarWidth + BarGap, B3}
        end,
        {0, Buf},
        Bars
    ),
    Out.

%% One horizontal bar: the track filled from the left to the value's length in
%% eighths of the track width, on every row of the band. A zero-width track (the
%% label and value columns filled the area) draws no bar.
-spec draw_hbar(
    tuition_render:buffer(),
    #rect{},
    non_neg_integer(),
    non_neg_integer(),
    non_neg_integer(),
    pos_integer(),
    bar(),
    number()
) -> tuition_render:buffer().
draw_hbar(Buf, _Area, _TrackX, TrackW, _Row, _BarWidth, _Bar, _Max) when TrackW =< 0 ->
    Buf;
draw_hbar(Buf, Area, TrackX, TrackW, Row, BarWidth, Bar, Max) ->
    Style = maps:get(style, Bar, #{}),
    Eighths = eighths(bar_value(Bar), Max, TrackW * 8),
    Full = Eighths div 8,
    Rem = Eighths rem 8,
    lists:foldl(
        fun(R, B) -> draw_hbar_row(B, Area, TrackX, Row + R, Full, Rem, Style) end,
        Buf,
        lists:seq(0, BarWidth - 1)
    ).

%% One row of a horizontal bar: `Full' full blocks from the track's left, then the
%% eighth-block boundary cell for the remaining eighths. {@link
%% tuition_widget:put_line/6} drops a row outside the area, so a band thicker than
%% the rows left simply paints fewer rows.
-spec draw_hbar_row(
    tuition_render:buffer(),
    #rect{},
    non_neg_integer(),
    integer(),
    non_neg_integer(),
    0..7,
    tuition_render:style()
) -> tuition_render:buffer().
draw_hbar_row(Buf, Area, TrackX, Row, Full, Rem, Style) ->
    Buf1 =
        case Full of
            0 ->
                Buf;
            _ ->
                tuition_widget:put_line(
                    Buf, Area, TrackX, Row, binary:copy(<<?FULL/utf8>>, Full), Style
                )
        end,
    case Rem of
        0 ->
            Buf1;
        _ ->
            tuition_widget:put_line(
                Buf1, Area, TrackX + Full, Row, <<(horiz_block(Rem))/utf8>>, Style
            )
    end.

%% The category label, left-aligned in its reserved column (nothing when no bar
%% carries a label). Clipped to the column so it never runs into the track.
-spec draw_hlabel(
    tuition_render:buffer(),
    #rect{},
    non_neg_integer(),
    integer(),
    unicode:chardata(),
    tuition_render:style()
) -> tuition_render:buffer().
draw_hlabel(Buf, _Area, 0, _Mid, _Label, _Style) ->
    Buf;
draw_hlabel(Buf, Area, LabelW, Mid, Label, Style) ->
    tuition_widget:put_line(Buf, Area, 0, Mid, tuition_widget:truncate(Label, LabelW), Style).

%% The value, right-aligned in its reserved column (nothing when every bar
%% suppressed its value), so a column of numbers aligns on the units.
-spec draw_hvalue(
    tuition_render:buffer(),
    #rect{},
    non_neg_integer(),
    non_neg_integer(),
    integer(),
    unicode:chardata(),
    tuition_render:style()
) -> tuition_render:buffer().
draw_hvalue(Buf, _Area, _ValueX, 0, _Mid, _Value, _Style) ->
    Buf;
draw_hvalue(Buf, Area, ValueX, ValueW, Mid, Value, Style) ->
    Clipped = tuition_widget:truncate(Value, ValueW),
    Off = tuition_widget:align_offset(right, ValueW, tuition_widget:display_width(Clipped)),
    tuition_widget:put_line(Buf, Area, ValueX + Off, Mid, Clipped, Style).

%%% -- shared drawing --------------------------------------------------

%% Draw `Text' centred within `Width' columns from area-relative `Col' on `Row',
%% clipped to `Width' so it never spills into the neighbouring bar or gap. Empty
%% text draws nothing.
-spec draw_centered(
    tuition_render:buffer(),
    #rect{},
    non_neg_integer(),
    pos_integer(),
    integer(),
    unicode:chardata(),
    tuition_render:style()
) -> tuition_render:buffer().
draw_centered(Buf, Area, Col, Width, Row, Text, Style) ->
    case tuition_widget:truncate(Text, Width) of
        <<>> ->
            Buf;
        Clipped ->
            Off = tuition_widget:align_offset(center, Width, tuition_widget:display_width(Clipped)),
            tuition_widget:put_line(Buf, Area, Col + Off, Row, Clipped, Style)
    end.

%%% -- eighth-block glyphs ---------------------------------------------

%% The value's length in eighths of a bar `Cap' eighths long, clamped to `Cap' so
%% a value above `max' fills the bar rather than overflowing. Integer values keep
%% exact integer arithmetic (matching {@link tuition_sparkline}); a float bar
%% truncates toward the lower eighth.
-spec eighths(number(), number(), non_neg_integer()) -> non_neg_integer().
eighths(Value, Max, Cap) when is_integer(Value), is_integer(Max) ->
    min(Cap, max(0, Value) * Cap div Max);
eighths(Value, Max, Cap) ->
    min(Cap, trunc(max(0, Value) / Max * Cap)).

%% The eighths a given row of a vertical bar shows: the total height less the eight
%% per row already consumed by the rows below it, clamped to one cell. Row 0 is the
%% top; the bottom row fills first. (The sparkline's fill, per bar column.)
-spec cell_eighths(non_neg_integer(), non_neg_integer(), non_neg_integer()) -> 0..8.
cell_eighths(Eighths, Row, H) ->
    min(8, max(0, Eighths - (H - 1 - Row) * 8)).

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
vert_block(8) -> ?FULL.

%% The eighth-block glyph filling a cell from the left to `N' eighths: U+258F at
%% one eighth up to U+2588 (the full block) at eight. (The gauge's fill.)
-spec horiz_block(1..7) -> char().
horiz_block(1) -> 16#258F;
horiz_block(2) -> 16#258E;
horiz_block(3) -> 16#258D;
horiz_block(4) -> 16#258C;
horiz_block(5) -> 16#258B;
horiz_block(6) -> 16#258A;
horiz_block(7) -> 16#2589.

%%% -- bar accessors ---------------------------------------------------

%% A bar's magnitude, a non-negative number — a negative (or non-numeric) value
%% counts as zero, so a metering glitch can never draw a bar backwards.
-spec bar_value(bar()) -> number().
bar_value(Bar) ->
    case maps:get(value, Bar, 0) of
        V when is_number(V) -> max(0, V);
        _ -> 0
    end.

%% The text printed on a bar: its `text_value' override, `none' for nothing, or the
%% formatted `value' by default (an integer as itself, a float to two decimals).
-spec value_text(bar()) -> unicode:chardata().
value_text(Bar) ->
    case maps:get(text_value, Bar, default) of
        default -> default_value_text(maps:get(value, Bar, 0));
        none -> <<>>;
        Text -> Text
    end.

-spec default_value_text(term()) -> binary().
default_value_text(V) when is_integer(V) -> integer_to_binary(V);
default_value_text(V) when is_float(V) -> float_to_binary(V, [{decimals, 2}, compact]);
default_value_text(_) -> <<>>.

-spec bar_label(bar()) -> unicode:chardata().
bar_label(Bar) -> maps:get(label, Bar, <<>>).

%% Whether a bar carries a visible label — used to decide if the vertical chart
%% reserves a label row at all.
-spec has_label(bar()) -> boolean().
has_label(Bar) -> tuition_widget:display_width(bar_label(Bar)) > 0.

%%% -- helpers ---------------------------------------------------------

%% The value that maps to a full bar: an explicit positive `max', or (for `auto')
%% the largest bar value — including a fractional one, so a chart of ratios in
%% `[0, 1]' fills its bars rather than topping out at an eighth of the height. The
%% only floor is against a non-positive scale (an empty or all-zero `auto' chart,
%% or a non-positive explicit `max'): there a fallback of 1 keeps the eighth
%% arithmetic well defined instead of dividing by zero.
-spec resolve_max(auto | number(), [bar()]) -> number().
resolve_max(auto, Bars) ->
    case lists:max([0 | [bar_value(B) || B <- Bars]]) of
        Max when Max > 0 -> Max;
        _ -> 1
    end;
resolve_max(Max, _Bars) when is_number(Max), Max > 0 -> Max;
resolve_max(_Max, _Bars) ->
    1.

%% The widest of a list of texts in display columns (0 for an empty list), used to
%% size the horizontal label and value columns.
-spec max_width([unicode:chardata()]) -> non_neg_integer().
max_width(Texts) -> lists:max([0 | [tuition_widget:display_width(T) || T <- Texts]]).

%% One separator column beside a reserved column, or none when the column is empty.
-spec gap_if(non_neg_integer()) -> 0..1.
gap_if(0) -> 0;
gap_if(_) -> 1.
