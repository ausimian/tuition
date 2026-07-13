%%%-------------------------------------------------------------------
%%% @doc Block widget — the framed region every pane sits in.
%%%
%%% A block draws an optional border (any subset of the four sides) with an
%%% optional title on its top edge, optionally fills its area with a background
%%% style, and — through {@link inner/2} — hands back the rect *inside* the
%%% border for its content. It is the ratatui `Block': the frame a `Paragraph',
%%% `List' or `Table' is rendered into, so the observability panes (PRD §9.1) get
%%% a consistent bordered chrome.
%%%
%%% == Composition ==
%%% A block and its content are two draws against the same buffer: render the
%%% block into an `Area', then render the content widget into `inner(Block,
%%% Area)'. The border occupies the outer ring; the content never overdraws it
%%% because it is confined to the inner rect. Nesting composes — split the inner
%%% rect with {@link tuition_layout} and frame each child in its own block.
%%%
%%% == Config ==
%%% A `#{}' map, every key optional:
%%% <ul>
%%%   <li>`borders'      — `all' (default), `none', or a list of `top' |
%%%       `bottom' | `left' | `right'. A corner glyph is drawn only where its two
%%%       edges are both present.</li>
%%%   <li>`title'        — chardata drawn on the top edge, truncated to the space
%%%       between the left/right borders.</li>
%%%   <li>`title_align'  — `left' (default), `center' or `right'.</li>
%%%   <li>`title_style'  — the title's style (defaults to `border_style').</li>
%%%   <li>`border_style' — the border glyphs' style (default: unstyled).</li>
%%%   <li>`style'        — a background fill for the whole area (default: none,
%%%       so the block is transparent over whatever it is drawn onto).</li>
%%% </ul>
%%%
%%% HARD CONSTRAINT (PRD §12): depends only on `kernel'/`stdlib'/`erts' plus the
%%% sibling render/layout/width/widget modules. No third-party code.
%%% @end
%%%-------------------------------------------------------------------
-module(tuition_block).
-behaviour(tuition_widget).

-include("tuition_layout.hrl").

-export([render/3, inner/2]).

-type side() :: top | bottom | left | right.
-type borders() :: all | none | [side()].
-type block() :: #{
    borders => borders(),
    title => unicode:chardata(),
    title_align => left | center | right,
    title_style => tuition_render:style(),
    border_style => tuition_render:style(),
    style => tuition_render:style()
}.

-export_type([block/0, side/0, borders/0]).

%% Light box-drawing glyphs (U+2500 block). One column each.
-define(HORIZ, 16#2500).
-define(VERT, 16#2502).
-define(TOP_LEFT, 16#250C).
-define(TOP_RIGHT, 16#2510).
-define(BOT_LEFT, 16#2514).
-define(BOT_RIGHT, 16#2518).

%%% -- render ----------------------------------------------------------

%% @doc Draw the block's background, border and title into `Area'. A degenerate
%% area (no columns or rows) draws nothing. See the module doc for the config map.
-spec render(block(), #rect{}, tuition_render:buffer()) -> tuition_render:buffer().
render(_Block, #rect{w = W, h = H}, Buf) when W =< 0; H =< 0 ->
    Buf;
render(Block, Area, Buf0) ->
    Sides = sides(maps:get(borders, Block, all)),
    Buf1 = fill_background(Block, Area, Buf0),
    Buf2 = draw_border(Sides, Area, border_style(Block), Buf1),
    draw_title(Block, Sides, Area, Buf2).

%% @doc The content rect inside the block's border: `Area' inset by one cell on
%% each side that carries a border. Clamped at zero, so a block too small for its
%% border (e.g. one row with a top and bottom border) yields an empty inner rect
%% rather than a negative size — the content widget then simply draws nothing.
-spec inner(block(), #rect{}) -> #rect{}.
inner(Block, #rect{x = X, y = Y, w = W, h = H}) ->
    Sides = sides(maps:get(borders, Block, all)),
    {L, R, T, B} = insets(Sides),
    #rect{x = X + L, y = Y + T, w = max(0, W - L - R), h = max(0, H - T - B)}.

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
-spec draw_border([side()], #rect{}, tuition_render:style(), tuition_render:buffer()) ->
    tuition_render:buffer().
draw_border(Sides, #rect{x = X, y = Y, w = W, h = H}, Style, Buf0) ->
    Top = lists:member(top, Sides),
    Bottom = lists:member(bottom, Sides),
    Left = lists:member(left, Sides),
    Right = lists:member(right, Sides),
    Buf1 = edge(Top, fun(B) -> hline(B, X, Y, W, Style) end, Buf0),
    Buf2 = edge(Bottom, fun(B) -> hline(B, X, Y + H - 1, W, Style) end, Buf1),
    Buf3 = edge(Left, fun(B) -> vline(B, X, Y, H, Style) end, Buf2),
    Buf4 = edge(Right, fun(B) -> vline(B, X + W - 1, Y, H, Style) end, Buf3),
    draw_corners(Buf4, X, Y, W, H, Style, {Top, Bottom, Left, Right}).

-spec edge(
    boolean(), fun((tuition_render:buffer()) -> tuition_render:buffer()), tuition_render:buffer()
) ->
    tuition_render:buffer().
edge(true, Draw, Buf) -> Draw(Buf);
edge(false, _Draw, Buf) -> Buf.

%% A horizontal run of W box-drawing dashes from {X, Y} — a single put_text so the
%% whole edge shares one cursor move and SGR in the diff.
-spec hline(
    tuition_render:buffer(), integer(), integer(), non_neg_integer(), tuition_render:style()
) ->
    tuition_render:buffer().
hline(Buf, X, Y, W, Style) ->
    tuition_render:put_text(Buf, X, Y, binary:copy(<<?HORIZ/utf8>>, W), Style).

%% A vertical run of H box-drawing bars down column X, one cell per row.
-spec vline(
    tuition_render:buffer(), integer(), integer(), non_neg_integer(), tuition_render:style()
) ->
    tuition_render:buffer().
vline(Buf, X, Y, H, Style) ->
    lists:foldl(
        fun(Row, B) -> put_glyph(B, X, Y + Row, ?VERT, Style) end,
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
    tuition_render:style(),
    {boolean(), boolean(), boolean(), boolean()}
) -> tuition_render:buffer().
draw_corners(Buf, X, Y, W, H, Style, {Top, Bottom, Left, Right}) ->
    Corners = [
        {Top andalso Left, X, Y, ?TOP_LEFT},
        {Top andalso Right, X + W - 1, Y, ?TOP_RIGHT},
        {Bottom andalso Left, X, Y + H - 1, ?BOT_LEFT},
        {Bottom andalso Right, X + W - 1, Y + H - 1, ?BOT_RIGHT}
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

-spec border_style(block()) -> tuition_render:style().
border_style(Block) -> maps:get(border_style, Block, #{}).

-spec put_glyph(tuition_render:buffer(), integer(), integer(), char(), tuition_render:style()) ->
    tuition_render:buffer().
put_glyph(Buf, X, Y, Glyph, Style) ->
    tuition_render:put_text(Buf, X, Y, <<Glyph/utf8>>, Style).
