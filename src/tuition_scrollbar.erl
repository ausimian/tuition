-module(tuition_scrollbar).
-moduledoc """
A track with a proportional thumb (stateless).

A scrollbar draws a thin track down (or across) its area and lays a `thumb` over
the slice of it the visible window covers, so a scrollable pane shows at a glance
both where you are in the content and how much of it you can see. It is the
ratatui `Scrollbar`: the position indicator every scrollable pane wants beside
its content, which otherwise scrolls with no visual cue of extent.

## Stateless

The scrollbar holds nothing between frames. The three numbers it needs —
`content_length` (how much there is), `viewport_length` (how much shows) and
`position` (how far down the top of the window sits) — are already tracked by the
scrollable widget beside it. `tuition_list` and `tuition_table` carry an `offset`
in their `#list_state{}` and know their item count; `tuition_paragraph` takes an
explicit `scroll` line offset. So the caller derives the three values at the call
site and passes them in as config, with nothing threaded across the immediate-mode
rebuild. It implements the plain `m:tuition_widget` `render/3` callback.

## Geometry

The scrollbar draws a single line along the leading edge of its area: column 0
for a `vertical` bar (spanning every row), row 0 for a `horizontal` one (spanning
every column). Give it the thin (1-column or 1-row) rect beside the content it
annotates; a thicker rect is drawn as that one line, not filled.

The thumb length is proportional to the fraction of the content the window shows
— `round(Track * viewport_length / content_length)`, floored at one cell so it
never vanishes — and its offset down the track is proportional to how far
`position` has scrolled through the `content_length - viewport_length` range. So
the thumb sits flush at the top at `position = 0` and flush at the bottom at the
last scroll position. When the content fits entirely (`content_length =<
viewport_length`) the thumb fills the whole track: there is nowhere to scroll, and
a full thumb reads as "you see everything".

## Arrow caps

Optional `begin_symbol` and `end_symbol` glyphs draw a cap at each end of the
track (ratatui's `▲`/`▼`, `◄`/`►`); the thumb then travels only the cells between
them. Absent (the default `none`), the track runs the full length of the area and
the thumb the full length of the track.

## Config

A map, every key optional:

- `orientation` — `vertical` (default) or `horizontal`.
- `content_length` — total items or lines being scrolled (default `0`).
- `viewport_length` — items or lines visible at once; defaults to the track
  length (the area's long dimension, less any arrow caps).
- `position` — the top offset of the window, clamped to the scrollable range
  `[0, content_length - viewport_length]` (default `0`).
- `style` — style of the track (and the arrow caps); default unstyled.
- `thumb_style` — style of the thumb; default unstyled.
- `track` — the track glyph (default `│` vertical / `─` horizontal).
- `thumb` — the thumb glyph (default `█`).
- `begin_symbol` / `end_symbol` — `none` (default) or an arrow-cap glyph at the
  start/end of the track. (Named `begin_symbol`/`end_symbol` rather than
  `begin`/`end` because the bare words are Erlang keywords and could not be
  written as map keys.)
""".
-behaviour(tuition_widget).

-include("tuition_layout.hrl").

-export([render/3]).

-type orientation() :: vertical | horizontal.

-type scrollbar() :: #{
    orientation => orientation(),
    content_length => non_neg_integer(),
    viewport_length => non_neg_integer(),
    position => non_neg_integer(),
    style => tuition_render:style(),
    thumb_style => tuition_render:style(),
    track => unicode:chardata(),
    thumb => unicode:chardata(),
    begin_symbol => none | unicode:chardata(),
    end_symbol => none | unicode:chardata()
}.

-export_type([scrollbar/0, orientation/0]).

%% U+2502 BOX DRAWINGS LIGHT VERTICAL — the default vertical track.
-define(V_TRACK, 16#2502).
%% U+2500 BOX DRAWINGS LIGHT HORIZONTAL — the default horizontal track.
-define(H_TRACK, 16#2500).
%% U+2588 FULL BLOCK — the default thumb, a solid run the eye reads at a glance.
-define(THUMB, 16#2588).

%%% -- render ----------------------------------------------------------

-doc """
Draw the scrollbar into `Area`. An empty area (no columns or rows) draws nothing.
See the module doc for the config map.
""".
-spec render(scrollbar(), #rect{}, tuition_render:buffer()) -> tuition_render:buffer().
render(_Cfg, #rect{w = W, h = H}, Buf) when W =< 0; H =< 0 ->
    Buf;
render(Cfg, Area, Buf) ->
    Orient = maps:get(orientation, Cfg, vertical),
    Track = track_len(Orient, Area),
    Begin = maps:get(begin_symbol, Cfg, none),
    End = maps:get(end_symbol, Cfg, none),
    %% The thumb travels only the cells between the arrow caps (each cap, when
    %% present, claims one end cell of the track).
    InnerStart = bool01(Begin =/= none),
    InnerLen = max(0, Track - bool01(Begin =/= none) - bool01(End =/= none)),
    Style = maps:get(style, Cfg, #{}),
    ThumbStyle = maps:get(thumb_style, Cfg, #{}),
    TrackGlyph = maps:get(track, Cfg, default_track(Orient)),
    ThumbGlyph = maps:get(thumb, Cfg, <<?THUMB/utf8>>),
    Content = maps:get(content_length, Cfg, 0),
    Viewport = maps:get(viewport_length, Cfg, InnerLen),
    Position = maps:get(position, Cfg, 0),
    {ThumbStart, ThumbLen} = thumb_geometry(InnerLen, Content, Viewport, Position),
    %% Lay the track across the inner region first, then overlay the thumb over
    %% its slice, then the caps at the two ends — later draws win where they meet.
    Buf1 = draw_run(Buf, Orient, Area, InnerStart, InnerLen, TrackGlyph, Style),
    Buf2 = draw_run(Buf1, Orient, Area, InnerStart + ThumbStart, ThumbLen, ThumbGlyph, ThumbStyle),
    Buf3 = draw_cap(Buf2, Orient, Area, 0, Begin, Style),
    draw_cap(Buf3, Orient, Area, Track - 1, End, Style).

%%% -- thumb geometry --------------------------------------------------

%% The thumb's `{StartCell, Length}' within an `InnerLen'-cell track. When the
%% content fits the window (or the track is empty), the thumb fills the whole
%% track — there is nowhere to scroll. Otherwise the length is the visible
%% fraction of the content (floored at one cell so it stays visible), and the
%% start is that fraction of the way through the remaining track, in step with how
%% far `Position' has moved through the scrollable range.
-spec thumb_geometry(
    non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()
) -> {non_neg_integer(), non_neg_integer()}.
thumb_geometry(InnerLen, _Content, _Viewport, _Position) when InnerLen =< 0 ->
    {0, 0};
thumb_geometry(InnerLen, Content, Viewport, _Position) when Content =< Viewport; Content =< 0 ->
    {0, InnerLen};
thumb_geometry(InnerLen, Content, Viewport, Position) ->
    ThumbLen = min(InnerLen, max(1, round(InnerLen * Viewport / Content))),
    MaxThumbStart = InnerLen - ThumbLen,
    MaxScroll = Content - Viewport,
    Pos = min(max(Position, 0), MaxScroll),
    ThumbStart = min(max(round(MaxThumbStart * Pos / MaxScroll), 0), MaxThumbStart),
    {ThumbStart, ThumbLen}.

%%% -- drawing ---------------------------------------------------------

%% Draw `Len' cells of `Glyph' from track offset `Off', along the bar's axis: down
%% column 0 for a vertical bar, across row 0 for a horizontal one. {@link
%% tuition_widget:put_line/6} clips each cell to `Area', so a run that overshoots a
%% miscomputed length can never spill past the widget's rect.
-spec draw_run(
    tuition_render:buffer(),
    orientation(),
    #rect{},
    integer(),
    non_neg_integer(),
    unicode:chardata(),
    tuition_render:style()
) -> tuition_render:buffer().
draw_run(Buf, _Orient, _Area, _Off, Len, _Glyph, _Style) when Len =< 0 ->
    Buf;
draw_run(Buf, Orient, Area, Off, Len, Glyph, Style) ->
    lists:foldl(
        fun(I, B) -> draw_at(B, Orient, Area, Off + I, Glyph, Style) end,
        Buf,
        lists:seq(0, Len - 1)
    ).

%% Draw an optional arrow cap at track cell `Idx' (a no-op when the glyph is
%% `none').
-spec draw_cap(
    tuition_render:buffer(),
    orientation(),
    #rect{},
    integer(),
    none | unicode:chardata(),
    tuition_render:style()
) -> tuition_render:buffer().
draw_cap(Buf, _Orient, _Area, _Idx, none, _Style) ->
    Buf;
draw_cap(Buf, Orient, Area, Idx, Sym, Style) ->
    draw_at(Buf, Orient, Area, Idx, Sym, Style).

%% One cell of the bar at axis offset `Idx': row `Idx' of column 0 (vertical) or
%% column `Idx' of row 0 (horizontal).
-spec draw_at(
    tuition_render:buffer(),
    orientation(),
    #rect{},
    integer(),
    unicode:chardata(),
    tuition_render:style()
) -> tuition_render:buffer().
draw_at(Buf, vertical, Area, Idx, Glyph, Style) ->
    tuition_widget:put_line(Buf, Area, 0, Idx, Glyph, Style);
draw_at(Buf, horizontal, Area, Idx, Glyph, Style) ->
    tuition_widget:put_line(Buf, Area, Idx, 0, Glyph, Style).

%%% -- helpers ---------------------------------------------------------

%% The track length in cells: the area's height for a vertical bar, its width for
%% a horizontal one.
-spec track_len(orientation(), #rect{}) -> non_neg_integer().
track_len(vertical, #rect{h = H}) -> H;
track_len(horizontal, #rect{w = W}) -> W.

-spec default_track(orientation()) -> binary().
default_track(vertical) -> <<?V_TRACK/utf8>>;
default_track(horizontal) -> <<?H_TRACK/utf8>>.

-spec bool01(boolean()) -> 0 | 1.
bool01(true) -> 1;
bool01(false) -> 0.
