%%%-------------------------------------------------------------------
%%% @doc Canvas widget — freeform braille drawing in value coordinates.
%%%
%%% Where {@link tuition_chart} plots a time-series onto the {@link tuition_braille}
%%% sub-cell grid, a canvas exposes that same 2×4-dot kernel directly: the caller
%%% names its own value coordinate system (`x_bounds'/`y_bounds') and draws
%%% arbitrary shapes into it — lines, point sets, rectangles, circles — each in its
%%% own colour. It is ratatui's `Canvas': the
%%% general drawing surface `Chart' is a specialisation of, for the diagrams a
%%% trend curve cannot express (a world map, a network graph, a scatter of
%%% arbitrary marks, a geometric overlay).
%%%
%%% == Coordinate system ==
%%% `x_bounds => {Xmin, Xmax}' and `y_bounds => {Ymin, Ymax}' name the value range
%%% each axis spans across the area. A value is mapped onto the braille sub-grid —
%%% `2W' sub-pixels wide and `4H' tall for a `W'×`H' cell area — with the standard
%%% mathematical orientation: `Xmin' at the left edge and `Xmax' at the right,
%%% `Ymin' at the *bottom* and `Ymax' at the *top* (y increases upward, unlike the
%%% cell buffer's downward rows — the widget flips the axis so callers think in
%%% ordinary Cartesian coordinates). Both bounds default to `{0.0, 1.0}', so with
%%% no bounds set a coordinate is simply its fraction of the area.
%%%
%%% A coordinate outside its bounds is clamped to the nearest edge (as {@link
%%% tuition_chart} clamps an out-of-range value), so a shape drawn partly beyond
%%% the declared range is pinned to the border rather than wrapping or vanishing;
%%% keep shapes within the bounds for undistorted geometry. A degenerate bound
%%% (`Xmax =:= Xmin') maps every value on that axis to the middle, the same
%%% no-gradient fallback {@link tuition_chart} uses for a flat series.
%%%
%%% == Shapes ==
%%% `shapes' is a list drawn in order onto one shared grid, so — per the {@link
%%% tuition_braille} one-colour-per-cell rule — where two shapes light dots in the
%%% same cell the dots merge but the *later* shape wins that cell's colour. Each
%%% shape is a tagged tuple whose last element is its {@link
%%% tuition_braille:colour()}:
%%% <ul>
%%%   <li>`{line, X1, Y1, X2, Y2, Colour}' — a straight segment between two value
%%%       points (Bresenham).</li>
%%%   <li>`{points, [{X, Y}], Colour}' — a scatter of individual dots, one per
%%%       value point.</li>
%%%   <li>`{rect, X, Y, W, H, Colour}' — the outline (no fill) of the rectangle
%%%       whose corner is the value point `{X, Y}' and which extends `W' along
%%%       `+x' and `H' along `+y'.</li>
%%%   <li>`{circle, Cx, Cy, R, Colour}' — the outline of the circle centred at the
%%%       value point `{Cx, Cy}' with radius `R' measured in x-axis value units.
%%%       It is drawn round on the sub-grid; when the x and y sub-pixel scales
%%%       differ (the axes span different value ranges over the area) it therefore
%%%       reads as a circle in sub-pixels rather than in value space — match the
%%%       bounds to the area's aspect for a value-space circle.</li>
%%% </ul>
%%% An unrecognised shape tuple is ignored, so a forward-compatible caller may pass
%%% shapes a older build does not know without crashing it.
%%%
%%% == Stateless ==
%%% A canvas holds no state between frames: the caller composes the shape list each
%%% frame and passes it as config. It implements the plain {@link tuition_widget}
%%% `render/3' callback.
%%%
%%% == Config ==
%%% A `#{}' map, every key optional:
%%% <ul>
%%%   <li>`x_bounds' / `y_bounds' — `{Min, Max}' value ranges (default `{0.0,
%%%       1.0}').</li>
%%%   <li>`shapes' — the list of shape tuples (default `[]' — an empty canvas draws
%%%       only its background, if any).</li>
%%%   <li>`background' — a {@link tuition_render:style()} the area is filled with
%%%       before the shapes are drawn (default `#{}' — no fill, leaving whatever the
%%%       canvas composites over to show through). Set a `bg' to paint a backdrop.</li>
%%%   <li>`style' — the base {@link tuition_render:style()} the braille glyphs are
%%%       drawn with (default `#{}'); each shape's own colour overrides the `fg',
%%%       so this carries shared attributes (a `bold', or a default `fg' for
%%%       `default'-coloured shapes) the per-shape colour rides on. A glyph cell
%%%       inherits the `background's `bg' (so it sits on the backdrop rather than
%%%       punching a default-`bg' hole in it) unless `style' sets its own.</li>
%%% </ul>
%%%
%%% HARD CONSTRAINT (PRD §12): depends only on `kernel'/`stdlib'/`erts' plus the
%%% sibling braille/render/layout/widget modules. No third-party code.
%%% @end
%%%-------------------------------------------------------------------
-module(tuition_canvas).
-behaviour(tuition_widget).

-include("tuition_layout.hrl").

-export([render/3]).

-type bounds() :: {number(), number()}.

%% A shape spec: a tagged tuple carrying value-space geometry and a trailing
%% colour. See the module doc for the coordinate meaning of each.
-type shape() ::
    {line, number(), number(), number(), number(), tuition_braille:colour()}
    | {points, [{number(), number()}], tuition_braille:colour()}
    | {rect, number(), number(), number(), number(), tuition_braille:colour()}
    | {circle, number(), number(), number(), tuition_braille:colour()}.

-type canvas() :: #{
    x_bounds => bounds(),
    y_bounds => bounds(),
    shapes => [shape()],
    background => tuition_render:style(),
    style => tuition_render:style()
}.

-export_type([canvas/0, shape/0]).

%% The value-to-sub-pixel mapping context threaded through the shape walk: the two
%% axis bounds and the grid's sub-pixel extent `{PW, PH}'.
-record(map, {
    xmin :: number(),
    xmax :: number(),
    ymin :: number(),
    ymax :: number(),
    pw :: pos_integer(),
    ph :: pos_integer()
}).

%%% -- render ----------------------------------------------------------

%% @doc Draw the canvas into `Area'. A degenerate area (no columns or rows) draws
%% nothing. See the module doc for the config map.
-spec render(canvas(), #rect{}, tuition_render:buffer()) -> tuition_render:buffer().
render(_Cfg, #rect{w = W, h = H}, Buf) when W =< 0; H =< 0 ->
    Buf;
render(Cfg, Area, Buf0) ->
    Bg = maps:get(background, Cfg, #{}),
    Buf1 = tuition_widget:fill(Buf0, Area, Bg),
    Grid0 = tuition_braille:new(Area),
    {PW, PH} = tuition_braille:dims(Grid0),
    {Xmin, Xmax} = bounds(maps:get(x_bounds, Cfg, undefined)),
    {Ymin, Ymax} = bounds(maps:get(y_bounds, Cfg, undefined)),
    Map = #map{xmin = Xmin, xmax = Xmax, ymin = Ymin, ymax = Ymax, pw = PW, ph = PH},
    Grid1 = lists:foldl(
        fun(Shape, G) -> draw(Shape, G, Map) end, Grid0, maps:get(shapes, Cfg, [])
    ),
    tuition_braille:render_into(Grid1, Buf1, glyph_style(Bg, maps:get(style, Cfg, #{}))).

%%% -- shapes ----------------------------------------------------------

%% Rasterize one shape onto the grid. Each value point is mapped to a sub-pixel
%% via {@link point/3}; an unrecognised tuple is a no-op so an unknown shape never
%% crashes the frame.
-spec draw(shape() | term(), tuition_braille:grid(), #map{}) -> tuition_braille:grid().
draw({line, X1, Y1, X2, Y2, Colour}, Grid, Map) ->
    {C1, R1} = point(X1, Y1, Map),
    {C2, R2} = point(X2, Y2, Map),
    tuition_braille:line(Grid, C1, R1, C2, R2, Colour);
draw({points, Points, Colour}, Grid, Map) when is_list(Points) ->
    lists:foldl(
        fun({X, Y}, G) ->
            {C, R} = point(X, Y, Map),
            tuition_braille:set(G, C, R, Colour)
        end,
        Grid,
        Points
    );
draw({rect, X, Y, W, H, Colour}, Grid, Map) when is_number(W), is_number(H) ->
    {C0, R0} = point(X, Y, Map),
    {C1, R1} = point(X + W, Y + H, Map),
    tuition_braille:rect(Grid, C0, R0, C1, R1, Colour);
draw({circle, Cx, Cy, R, Colour}, Grid, Map) when is_number(R) ->
    {C, Row} = point(Cx, Cy, Map),
    tuition_braille:circle(Grid, C, Row, radius(R, Map), Colour);
draw(_Unknown, Grid, _Map) ->
    Grid.

%%% -- coordinate mapping ----------------------------------------------

%% Map a value point `{X, Y}' to its sub-pixel `{Col, Row}', clamped onto the grid.
%% `Xmin' sits at column 0 and `Xmax' at `PW - 1'; `Ymax' sits at row 0 (the top)
%% and `Ymin' at `PH - 1' (the bottom) — the y-axis flipped so the caller works in
%% upward-positive coordinates.
-spec point(number(), number(), #map{}) -> {non_neg_integer(), non_neg_integer()}.
point(X, Y, #map{xmin = Xmin, xmax = Xmax, ymin = Ymin, ymax = Ymax, pw = PW, ph = PH}) ->
    Col = scale(frac(X, Xmin, Xmax), PW),
    Row = scale(1.0 - frac(Y, Ymin, Ymax), PH),
    {Col, Row}.

%% The position of `V' within `[Lo, Hi]' as a fraction in `[0.0, 1.0]', clamped so
%% a value past the bounds saturates at an edge. A non-positive range (`Hi =< Lo',
%% a degenerate or inverted bound) has no gradient, so every value maps to the
%% middle — {@link tuition_chart}'s flat-series fallback.
-spec frac(number(), number(), number()) -> float().
frac(V, Lo, Hi) when Hi > Lo -> clamp01((V - Lo) / (Hi - Lo));
frac(_V, _Lo, _Hi) -> 0.5.

%% A `[0.0, 1.0]' fraction placed onto an `Extent'-wide sub-pixel axis: fraction 0
%% at index 0, fraction 1 at `Extent - 1'. The fraction is already clamped, so the
%% result lands in `[0, Extent - 1]'.
-spec scale(float(), pos_integer()) -> non_neg_integer().
scale(Frac, Extent) -> round(Frac * (Extent - 1)).

%% A radius in x-axis value units, expressed in sub-pixels: scaled by the x-axis'
%% sub-pixels-per-value, floored at 0 and capped at the grid's diagonal extent so a
%% pathological radius cannot drive an unbounded midpoint walk (a circle larger
%% than the grid draws no more than the grid holds anyway). A degenerate x-range
%% has no scale, so the radius collapses to 0.
-spec radius(number(), #map{}) -> non_neg_integer().
radius(R, #map{xmin = Xmin, xmax = Xmax, pw = PW, ph = PH}) when Xmax > Xmin ->
    Rpx = round(abs(R) * (PW - 1) / (Xmax - Xmin)),
    min(max(Rpx, 0), PW + PH);
radius(_R, _Map) ->
    0.

%%% -- config helpers --------------------------------------------------

%% Validate an axis bound: a `{Min, Max}' of two numbers passes through; anything
%% else (unset, or malformed) falls back to the unit range so mapping is always
%% well defined.
-spec bounds(term()) -> bounds().
bounds({Min, Max}) when is_number(Min), is_number(Max) -> {Min, Max};
bounds(_Invalid) -> {0.0, 1.0}.

%% The base style the braille glyphs are drawn with. `tuition_render:put_text/5'
%% writes a whole cell from the style rather than merging, so a glyph drawn over a
%% filled background cell would otherwise reset that cell's `bg' to the terminal
%% default — a hole in the backdrop. Fold the background's `bg' into the base so a
%% glyph sits *on* the fill; an explicit `bg' in `style' still wins.
-spec glyph_style(tuition_render:style(), tuition_render:style()) -> tuition_render:style().
glyph_style(Background, Style) ->
    case maps:find(bg, Background) of
        {ok, Bg} -> maps:merge(#{bg => Bg}, Style);
        error -> Style
    end.

-spec clamp01(float()) -> float().
clamp01(F) -> min(1.0, max(0.0, F)).
