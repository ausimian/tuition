%%%-------------------------------------------------------------------
%%% @doc Braille sub-cell grid — the 2×4-dot plotting kernel.
%%%
%%% A terminal cell is the smallest thing the {@link tuition_render} buffer can
%%% address, but the Unicode braille-patterns block (U+2800–U+28FF) packs a 2×4
%%% dot matrix into a single cell: eight independently-lit dots, so a grid of
%%% braille cells resolves **8× the vertical and 2× the horizontal** of the block
%%% glyphs a {@link tuition_sparkline} draws with. This module is that grid — the
%%% genuinely reusable kernel {@link tuition_chart} rasterizes trend curves onto,
%%% and the freeform canvas (deferred) would draw shapes onto. It is ratatui's
%%% `Grid'/`BrailleGrid': the pixel buffer under `Canvas' and `Chart'.
%%%
%%% == Not a widget ==
%%% Like {@link tuition_width}, this is an internal shared helper, not a {@link
%%% tuition_widget}: it holds no config map and implements no `render/3'. A widget
%%% ({@link tuition_chart}) owns a grid for the duration of one frame, plots onto it,
%%% and {@link render_into/2} composites it into the buffer.
%%%
%%% == Coordinates ==
%%% A grid is sized by a {@link //tuition/tuition_layout:rect()} of `W'×`H'
%%% cells, giving a sub-pixel field `2W' wide and `4H' tall. Sub-pixel `{GX, GY}'
%%% has its origin top-left, `GX' increasing rightward and `GY' downward — the
%%% same orientation as the cell buffer, so a caller mapping a value to a row
%%% flips the axis itself (as {@link tuition_chart} does). A sub-pixel outside
%%% `[0, 2W)`×`[0, 4H)' is silently dropped, so a rasterizer may over-run the edge
%%% without a bounds check of its own.
%%%
%%% == One colour per cell ==
%%% Each cell carries a single `fg' shared by all eight of its dots — the braille
%%% glyph is one codepoint with one SGR. {@link set/4} claims that colour, so when
%%% two series light dots in the *same* cell the later {@link set/4} wins the whole
%%% cell's colour (their dots are OR-ed together, but the cell takes the last
%%% colour) — ratatui's canvas layering rule, and the constraint {@link
%%% tuition_chart} documents for overlapping datasets. {@link set/3} carries no
%%% colour and is the exception: it OR-s in its dot but leaves the cell's colour
%%% untouched, so a bare dot-add never disturbs a coloured cell.
%%%
%%% == Emission ==
%%% {@link render_into/2} walks the lit cells and writes each as one U+2800-based
%%% glyph (`16#2800 bor Mask') at its cell in the buffer, in the cell's colour.
%%% Every braille glyph is one column in {@link tuition_width}, so the grid
%%% composites through {@link tuition_render:diff/2} exactly as any other width-1
%%% text — no special-casing in the renderer.
%%%
%%% HARD CONSTRAINT (PRD §12): depends only on `kernel'/`stdlib'/`erts' plus the
%%% sibling {@link tuition_render} buffer. No third-party code.
%%% @end
%%%-------------------------------------------------------------------
-module(tuition_braille).

-include("tuition_layout.hrl").

-export([new/1, dims/1, set/3, set/4, line/6, render_into/2, render_into/3]).

%% A cell colour — the `fg' a braille cell paints its dots in. Mirrors the colour
%% half of {@link tuition_render:style()}; `default' leaves the cell's foreground
%% to whatever the base style ({@link render_into/3}) carries.
-type colour() :: default | 0..255 | {rgb, byte(), byte(), byte()}.

-record(grid, {
    %% The rect the grid is sized by and composited into. Its origin places the
    %% cells in the buffer; its `W'×`H' fix the sub-pixel extent (`2W'×`4H').
    rect :: #rect{},
    %% Lit cells only: a cell index `{CX, CY}' maps to its 8-bit dot mask and the
    %% colour of its most recent write. Sparse like the render buffer — an absent
    %% cell is blank (no dots), so an untouched grid is the empty map.
    cells = #{} :: #{{non_neg_integer(), non_neg_integer()} => {byte(), colour()}}
}).

-opaque grid() :: #grid{}.

-export_type([grid/0, colour/0]).

%% U+2800 BRAILLE PATTERN BLANK — the base an 8-bit dot mask is added to.
-define(BRAILLE_BASE, 16#2800).

%%% -- construction ----------------------------------------------------

%% @doc A blank grid sized by `Rect': `W'×`H' cells, a `2W'×`4H' sub-pixel field.
%% The rect's origin is where {@link render_into/2} will composite the cells, so
%% pass the (absolute) area the grid should occupy in the buffer.
-spec new(#rect{}) -> grid().
new(#rect{} = Rect) ->
    #grid{rect = Rect}.

%% @doc The sub-pixel extent `{2W, 4H}' of the grid — the exclusive upper bound on
%% `{GX, GY}'. A caller mapping samples to sub-pixels uses this to size its plot
%% (the newest `2W' samples across the width, a value scaled over `4H' dots).
-spec dims(grid()) -> {non_neg_integer(), non_neg_integer()}.
dims(#grid{rect = #rect{w = W, h = H}}) ->
    {W * 2, H * 4}.

%%% -- plotting --------------------------------------------------------

%% @doc Light the sub-pixel at `{GX, GY}' without touching the cell's colour —
%% carrying no colour argument, this is colour-neutral. The dot is OR-ed into the
%% cell's mask; the cell keeps whatever colour a prior write set (or `default' if
%% this is its first write). Use {@link set/4} to also claim the cell's colour.
-spec set(grid(), integer(), integer()) -> grid().
set(Grid, GX, GY) ->
    set_dot(Grid, GX, GY, keep).

%% @doc Light the sub-pixel at `{GX, GY}' and set its cell's colour to `Colour'.
%% The dot is OR-ed into the cell's mask, so earlier dots in the same cell stay
%% lit, and the whole cell takes `Colour' — last-writer-wins, the module doc's
%% one-colour-per-cell rule. Unlike {@link set/3}, this always claims the colour,
%% `default' included: passing `default' sets the cell back to the terminal
%% foreground, so a later dataset that overlaps an earlier one wins the shared
%% cell exactly as {@link tuition_chart} documents, whatever colour it carries. A
%% sub-pixel outside the grid is dropped, so a rasterizer need not clip.
-spec set(grid(), integer(), integer(), colour()) -> grid().
set(Grid, GX, GY, Colour) ->
    set_dot(Grid, GX, GY, {set, Colour}).

%% Light a sub-pixel, applying `ColourOp' to the cell's colour: `keep' leaves the
%% existing colour intact (the colourless {@link set/3}); `{set, C}' claims it
%% ({@link set/4}). A new cell starts `default'-coloured, so a `keep' on a fresh
%% cell leaves it `default'. Out-of-range sub-pixels are dropped.
-spec set_dot(grid(), integer(), integer(), keep | {set, colour()}) -> grid().
set_dot(#grid{rect = #rect{w = W, h = H}} = Grid, GX, GY, _ColourOp) when
    GX < 0; GY < 0; GX >= W * 2; GY >= H * 4
->
    Grid;
set_dot(#grid{cells = Cells} = Grid, GX, GY, ColourOp) ->
    CX = GX div 2,
    CY = GY div 4,
    Bit = dot_bit(GX rem 2, GY rem 4),
    {Mask0, Existing} =
        case Cells of
            #{{CX, CY} := Cell} -> Cell;
            _ -> {0, default}
        end,
    Colour =
        case ColourOp of
            keep -> Existing;
            {set, C} -> C
        end,
    Grid#grid{cells = Cells#{{CX, CY} => {Mask0 bor Bit, Colour}}}.

%% @doc Rasterize the straight line from `{X0, Y0}' to `{X1, Y1}' in `Colour',
%% lighting every sub-pixel it crosses (integer Bresenham). This is how {@link
%% tuition_chart} connects consecutive samples into a continuous curve. Endpoints
%% out of range are dropped per-sub-pixel by {@link set/4}; pass endpoints within
%% the grid ({@link dims/1}) so the walk stays bounded.
-spec line(grid(), integer(), integer(), integer(), integer(), colour()) -> grid().
line(Grid, X0, Y0, X1, Y1, Colour) ->
    DX = abs(X1 - X0),
    DY = -abs(Y1 - Y0),
    SX = step(X0, X1),
    SY = step(Y0, Y1),
    bresenham(Grid, X0, Y0, X1, Y1, DX, DY, SX, SY, DX + DY, Colour).

%% One Bresenham step: plot the current sub-pixel, stop at the endpoint, else
%% advance x and/or y by comparing twice the accumulated error against the axis
%% deltas (the canonical error-accumulation form, both branches keyed on the same
%% pre-step error `E2').
-spec bresenham(
    grid(),
    integer(),
    integer(),
    integer(),
    integer(),
    integer(),
    integer(),
    -1 | 0 | 1,
    -1 | 0 | 1,
    integer(),
    colour()
) -> grid().
bresenham(Grid, X, Y, X1, Y1, DX, DY, SX, SY, Err, Colour) ->
    Grid1 = set(Grid, X, Y, Colour),
    case X =:= X1 andalso Y =:= Y1 of
        true ->
            Grid1;
        false ->
            E2 = 2 * Err,
            {X2, ErrA} =
                case E2 >= DY of
                    true -> {X + SX, Err + DY};
                    false -> {X, Err}
                end,
            {Y2, ErrB} =
                case E2 =< DX of
                    true -> {Y + SY, ErrA + DX};
                    false -> {Y, ErrA}
                end,
            bresenham(Grid1, X2, Y2, X1, Y1, DX, DY, SX, SY, ErrB, Colour)
    end.

%%% -- emission --------------------------------------------------------

%% @doc Composite the grid into `Buf' with default base styling — {@link
%% render_into/3} with an empty style.
-spec render_into(grid(), tuition_render:buffer()) -> tuition_render:buffer().
render_into(Grid, Buf) ->
    render_into(Grid, Buf, #{}).

%% @doc Composite the grid into `Buf', one U+2800-based glyph per lit cell, placed
%% at the cell relative to the grid's rect origin. Each cell is drawn in `Style',
%% except its `fg' is overridden by the cell's own colour when it set one (a dot
%% lit through {@link set/3}'s `default' keeps `Style's foreground). `Style' thus
%% carries shared attributes (a `bg', `bold') the per-cell colour rides on top of.
-spec render_into(grid(), tuition_render:buffer(), tuition_render:style()) ->
    tuition_render:buffer().
render_into(#grid{rect = #rect{x = X, y = Y}, cells = Cells}, Buf, Style) ->
    maps:fold(
        fun({CX, CY}, {Mask, Colour}, B) ->
            Glyph = ?BRAILLE_BASE bor Mask,
            tuition_render:put_text(B, X + CX, Y + CY, <<Glyph/utf8>>, cell_style(Style, Colour))
        end,
        Buf,
        Cells
    ).

%% The style a cell is drawn with: the base style, its `fg' replaced by the cell's
%% colour unless the cell never set one (`default' — then the base's own fg, if
%% any, stands).
-spec cell_style(tuition_render:style(), colour()) -> tuition_render:style().
cell_style(Style, default) -> Style;
cell_style(Style, Colour) -> Style#{fg => Colour}.

%%% -- dot geometry ----------------------------------------------------

%% The bit a sub-pixel occupies within its cell's 8-bit mask, for the standard
%% braille dot numbering: the left column holds dots 1-3-7 and the right dots
%% 4-5-6-8, so the fourth (bottom) row is dots 7/8 rather than a continuation of
%% the first column's low bits. `PX' is the column (0 left, 1 right) and `PY' the
%% row (0 top … 3 bottom) within the cell.
-spec dot_bit(0 | 1, 0 | 1 | 2 | 3) -> byte().
dot_bit(0, 0) -> 16#01;
dot_bit(0, 1) -> 16#02;
dot_bit(0, 2) -> 16#04;
dot_bit(1, 0) -> 16#08;
dot_bit(1, 1) -> 16#10;
dot_bit(1, 2) -> 16#20;
dot_bit(0, 3) -> 16#40;
dot_bit(1, 3) -> 16#80.

%% The unit step (`-1'/`0'/`1') from `A' toward `B' along one axis.
-spec step(integer(), integer()) -> -1 | 0 | 1.
step(A, B) when A < B -> 1;
step(A, B) when A > B -> -1;
step(_, _) -> 0.
