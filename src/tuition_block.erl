-module(tuition_block).
-moduledoc """
Block widget — the framed region every pane sits in.

A block draws an optional border (any subset of the four sides) with an
optional title on its top edge, optionally fills its area with a background
style, and — through `inner/2` — hands back the rect *inside* the
border for its content. It is the ratatui `Block`: the frame a `Paragraph`,
`List` or `Table` is rendered into, so the observability panes get
a consistent bordered chrome.

## Composition

A block and its content are two draws against the same buffer: render the
block into an `Area`, then render the content widget into `inner(Block, Area)`. The border occupies the outer ring; the content never overdraws it
because it is confined to the inner rect. Nesting composes — split the inner
rect with `m:tuition_layout` and frame each child in its own block.

## Config

A `#{}` map, every key optional:

- `borders` — `all` (default), `none`, or a list of `top` |
  `bottom` | `left` | `right`. A corner glyph is drawn only where its two
  edges are both present.
- `border_type` — the line/corner glyph set: `light` (default),
  `rounded`, `double` or `thick`. Purely cosmetic — the per-side subset
  logic is unchanged, only the glyphs differ.
- `title` — chardata drawn on the top edge, truncated to the space
  between the left/right borders.
- `title_align` — `left` (default), `center` or `right`.
- `title_style` — the title's style (defaults to `border_style`).
- `border_style` — the border glyphs' style (default: unstyled).
- `padding` — interior space between the border and the content, on
  top of the border inset: `0` (default), a uniform `N`, or a
  `{Top, Right, Bottom, Left}` tuple. Only `inner/2` honours it (the
  border and title are unaffected); it is clamped so the inner rect never
  goes negative.
- `style` — a background fill for the whole area (default: none,
  so the block is transparent over whatever it is drawn onto).
""".
-behaviour(tuition_widget).

-include("tuition_layout.hrl").

-export([render/3, inner/2]).

-type side() :: top | bottom | left | right.
-type borders() :: all | none | [side()].
-type border_type() :: light | rounded | double | thick.
-type padding() ::
    non_neg_integer()
    | {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}.
-type block() :: #{
    borders => borders(),
    border_type => border_type(),
    title => unicode:chardata(),
    title_align => left | center | right,
    title_style => tuition_render:style(),
    border_style => tuition_render:style(),
    padding => padding(),
    style => tuition_render:style()
}.

%% The six box-drawing glyphs for one border type: the two line runs and the
%% four corners. All are single-column, so an edge is `binary:copy'-able and a
%% corner is a one-cell overlay regardless of the chosen type.
-type glyphs() :: #{
    horiz := char(),
    vert := char(),
    top_left := char(),
    top_right := char(),
    bot_left := char(),
    bot_right := char()
}.

-export_type([block/0, side/0, borders/0, border_type/0, padding/0]).

%%% -- render ----------------------------------------------------------

-doc """
Draw the block's background, border and title into `Area`. A degenerate
area (no columns or rows) draws nothing. See the module doc for the config map.
""".
-spec render(block(), #rect{}, tuition_render:buffer()) -> tuition_render:buffer().
render(_Block, #rect{w = W, h = H}, Buf) when W =< 0; H =< 0 ->
    Buf;
render(Block, Area, Buf0) ->
    Sides = sides(maps:get(borders, Block, all)),
    Glyphs = glyphs(maps:get(border_type, Block, light)),
    Buf1 = fill_background(Block, Area, Buf0),
    Buf2 = draw_border(Sides, Area, Glyphs, border_style(Block), Buf1),
    draw_title(Block, Sides, Area, Buf2).

-doc """
The content rect inside the block's border: `Area` inset by one cell on
each side that carries a border, then by any `padding` on top. Clamped at
zero, so a block too small for its border and padding (e.g. one row with a top
and bottom border) yields an empty inner rect rather than a negative size —
the content widget then simply draws nothing.
""".
-spec inner(block(), #rect{}) -> #rect{}.
inner(Block, #rect{x = X, y = Y, w = W, h = H}) ->
    Sides = sides(maps:get(borders, Block, all)),
    {L, R, T, B} = insets(Sides),
    {PT, PR, PB, PL} = padding(maps:get(padding, Block, 0)),
    #rect{
        x = X + L + PL,
        y = Y + T + PT,
        w = max(0, W - L - R - PL - PR),
        h = max(0, H - T - B - PT - PB)
    }.

%%% -- background ------------------------------------------------------

%% Paint the background style across the whole area, if one was given. Absent
%% (the default) the block is transparent — it composes over whatever is already
%% there rather than clearing it.
-spec fill_background(block(), #rect{}, tuition_render:buffer()) -> tuition_render:buffer().
fill_background(Block, Area, Buf) ->
    case maps:find(style, Block) of
        error -> Buf;
        {ok, Style} -> tuition_widget:fill(Buf, Area, Style)
    end.

%%% -- border ----------------------------------------------------------

%% Draw the requested edges, then overlay a corner glyph wherever two edges meet.
%% Edges are drawn full-length (into the corner columns/rows) and the corners
%% overwrite the ends, so an L-shaped subset (only top+left, say) still gets a
%% proper corner where the two runs cross.
-spec draw_border([side()], #rect{}, glyphs(), tuition_render:style(), tuition_render:buffer()) ->
    tuition_render:buffer().
draw_border(Sides, #rect{x = X, y = Y, w = W, h = H}, Glyphs, Style, Buf0) ->
    #{horiz := Horiz, vert := Vert} = Glyphs,
    Top = lists:member(top, Sides),
    Bottom = lists:member(bottom, Sides),
    Left = lists:member(left, Sides),
    Right = lists:member(right, Sides),
    Buf1 = edge(Top, fun(B) -> hline(B, X, Y, W, Horiz, Style) end, Buf0),
    Buf2 = edge(Bottom, fun(B) -> hline(B, X, Y + H - 1, W, Horiz, Style) end, Buf1),
    Buf3 = edge(Left, fun(B) -> vline(B, X, Y, H, Vert, Style) end, Buf2),
    Buf4 = edge(Right, fun(B) -> vline(B, X + W - 1, Y, H, Vert, Style) end, Buf3),
    draw_corners(Buf4, X, Y, W, H, Glyphs, Style, {Top, Bottom, Left, Right}).

-spec edge(
    boolean(), fun((tuition_render:buffer()) -> tuition_render:buffer()), tuition_render:buffer()
) ->
    tuition_render:buffer().
edge(true, Draw, Buf) -> Draw(Buf);
edge(false, _Draw, Buf) -> Buf.

%% A horizontal run of W box-drawing dashes from {X, Y} — a single put_text so the
%% whole edge shares one cursor move and SGR in the diff.
-spec hline(
    tuition_render:buffer(), integer(), integer(), non_neg_integer(), char(), tuition_render:style()
) ->
    tuition_render:buffer().
hline(Buf, X, Y, W, Horiz, Style) ->
    tuition_render:put_text(Buf, X, Y, binary:copy(<<Horiz/utf8>>, W), Style).

%% A vertical run of H box-drawing bars down column X, one cell per row.
-spec vline(
    tuition_render:buffer(), integer(), integer(), non_neg_integer(), char(), tuition_render:style()
) ->
    tuition_render:buffer().
vline(Buf, X, Y, H, Vert, Style) ->
    lists:foldl(
        fun(Row, B) -> put_glyph(B, X, Y + Row, Vert, Style) end,
        Buf,
        lists:seq(0, H - 1)
    ).

%% Overlay each corner glyph where its two edges are both present.
-spec draw_corners(
    tuition_render:buffer(),
    integer(),
    integer(),
    non_neg_integer(),
    non_neg_integer(),
    glyphs(),
    tuition_render:style(),
    {boolean(), boolean(), boolean(), boolean()}
) -> tuition_render:buffer().
draw_corners(Buf, X, Y, W, H, Glyphs, Style, {Top, Bottom, Left, Right}) ->
    #{top_left := TL, top_right := TR, bot_left := BL, bot_right := BR} = Glyphs,
    Corners = [
        {Top andalso Left, X, Y, TL},
        {Top andalso Right, X + W - 1, Y, TR},
        {Bottom andalso Left, X, Y + H - 1, BL},
        {Bottom andalso Right, X + W - 1, Y + H - 1, BR}
    ],
    lists:foldl(
        fun
            ({true, Cx, Cy, Glyph}, B) -> put_glyph(B, Cx, Cy, Glyph, Style);
            ({false, _Cx, _Cy, _Glyph}, B) -> B
        end,
        Buf,
        Corners
    ).

%%% -- title -----------------------------------------------------------

%% Draw the title on the top edge, between the left/right borders, aligned within
%% that span and truncated to it — so it never overruns a corner or spills past
%% the block. Absent title, or no room between the borders, draws nothing.
-spec draw_title(block(), [side()], #rect{}, tuition_render:buffer()) -> tuition_render:buffer().
draw_title(Block, Sides, #rect{x = X, y = Y, w = W}, Buf) ->
    case maps:find(title, Block) of
        error ->
            Buf;
        {ok, Title} ->
            {L, R, _T, _B} = insets(Sides),
            Avail = W - L - R,
            case Avail =< 0 of
                true ->
                    Buf;
                false ->
                    Clipped = tuition_widget:truncate(Title, Avail),
                    Align = maps:get(title_align, Block, left),
                    Pad = tuition_widget:align_offset(
                        Align, Avail, tuition_widget:display_width(Clipped)
                    ),
                    Style = maps:get(title_style, Block, border_style(Block)),
                    tuition_render:put_text(Buf, X + L + Pad, Y, Clipped, Style)
            end
    end.

%%% -- helpers ---------------------------------------------------------

%% Per-side border insets {Left, Right, Top, Bottom}, each 0 or 1.
-spec insets([side()]) -> {0 | 1, 0 | 1, 0 | 1, 0 | 1}.
insets(Sides) ->
    {
        present(left, Sides),
        present(right, Sides),
        present(top, Sides),
        present(bottom, Sides)
    }.

-spec present(side(), [side()]) -> 0 | 1.
present(Side, Sides) ->
    case lists:member(Side, Sides) of
        true -> 1;
        false -> 0
    end.

-spec sides(borders()) -> [side()].
sides(all) -> [top, bottom, left, right];
sides(none) -> [];
sides(List) when is_list(List) -> List.

%% The glyph table for a border type. `rounded' shares `light''s straight runs
%% and only rounds the corners; `double' and `thick' swap in their own line runs
%% too. All six glyphs are single-column (U+2500 box-drawing block).
-spec glyphs(border_type()) -> glyphs().
glyphs(light) ->
    #{
        horiz => 16#2500,
        vert => 16#2502,
        top_left => 16#250C,
        top_right => 16#2510,
        bot_left => 16#2514,
        bot_right => 16#2518
    };
glyphs(rounded) ->
    #{
        horiz => 16#2500,
        vert => 16#2502,
        top_left => 16#256D,
        top_right => 16#256E,
        bot_left => 16#2570,
        bot_right => 16#256F
    };
glyphs(double) ->
    #{
        horiz => 16#2550,
        vert => 16#2551,
        top_left => 16#2554,
        top_right => 16#2557,
        bot_left => 16#255A,
        bot_right => 16#255D
    };
glyphs(thick) ->
    #{
        horiz => 16#2501,
        vert => 16#2503,
        top_left => 16#250F,
        top_right => 16#2513,
        bot_left => 16#2517,
        bot_right => 16#251B
    }.

%% Normalise the padding config to a `{Top, Right, Bottom, Left}' tuple of
%% non-negative insets: a uniform integer expands to all four sides, a tuple maps
%% side-for-side, and every side is floored at 0. Flooring matters because a
%% negative side would flip the inset into an *out*set — moving `inner/2''s rect
%% back over the border and widening it past the frame — so a stray negative
%% clamps to "no padding" rather than corrupting the layout.
-spec padding(padding()) ->
    {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}.
padding(N) when is_integer(N) ->
    Side = max(0, N),
    {Side, Side, Side, Side};
padding({T, R, B, L}) when is_integer(T), is_integer(R), is_integer(B), is_integer(L) ->
    {max(0, T), max(0, R), max(0, B), max(0, L)}.

-spec border_style(block()) -> tuition_render:style().
border_style(Block) -> maps:get(border_style, Block, #{}).

-spec put_glyph(tuition_render:buffer(), integer(), integer(), char(), tuition_render:style()) ->
    tuition_render:buffer().
put_glyph(Buf, X, Y, Glyph, Style) ->
    tuition_render:put_text(Buf, X, Y, <<Glyph/utf8>>, Style).
