-module(tuition_tabs).
-moduledoc """
Tabs widget — a horizontal row of titles with one selected (stateless).

A tab-bar draws a single row of titles separated by a divider glyph and
highlights the selected one, so a multi-pane UI can *show* the panes it can
switch between and which has focus. It is the ratatui `Tabs`: `m:tuition_shell` already cycles panes with Tab, but nothing on screen names the
available panes or marks the focused one — a tab-bar makes that navigation
visible, and its 0-based `selected` index is a natural fit with the shell's
existing focus model.

## Stateless

The tab-bar holds nothing between frames: which tab is selected is already
tracked by whatever owns the panes (the shell's focused-pane index), so the
caller passes it in as `selected` each frame. It implements the plain `m:tuition_widget` `render/3` callback — nothing is threaded across the
immediate-mode rebuild.

## Layout

Titles are drawn along the top row of `Area`, left to right, each surrounded
by `padding` blank columns, with a `divider` glyph between adjacent titles:

```
│ pane a │ pane b │ pane c │
```

The whole strip is aligned within `Area` by `title_align` — flush left by
default, or centred/right when the titles are narrower than the area. Give the
widget a one-row strip (reserve it with `m:tuition_layout`, typically at
the top of a pane); a taller area is filled with the base `style` but the
titles sit on its first row.

## Overflow

The row is clipped to `Area`: when the titles are wider than the area the tail
is truncated at the right edge (a wide glyph straddling the edge is dropped
whole, never split), matching how `m:tuition_render` clips any run. Keep
the leading tabs visible by ordering them so the selected pane is not pushed
off the end, or size the strip to the titles.

## Config

A `#{}` map, every key optional:

- `titles` — the tab titles, a list of chardata (default `[]`, an empty
  bar).
- `selected` — the 0-based index of the highlighted tab (default `0`). An
  index outside `[0, length(titles))` highlights nothing, so an empty bar
  or a stale index simply draws every title in the base style.
- `style` — the base style for the whole bar: the background fill and the
  style of the unselected titles and the dividers (default: unstyled, so
  the bar is transparent over whatever it is drawn onto).
- `highlight_style` — the selected title's style, overlaid on `style` (so
  it need only name the keys that differ); default unstyled, i.e. the
  selected title looks like the rest until this is set.
- `divider` — the glyph drawn between adjacent titles (default `│`).
- `padding` — columns of space on each side of every title (default `1`,
  clamped at `0`). Like the rest of the bar these follow `style`: painted
  with the base fill when it is set, and left transparent — showing the
  parent background (or whatever the bar is drawn over) — when it is not.
  They are never overwritten with default-blank cells, so an unstyled bar
  composes cleanly over a parent block's coloured strip, matching `tuition_widget:fill/3`.
- `title_align` — `left` (default) | `center` | `right`, where the strip
  sits within `Area` when it is narrower than the area.

Only the selected title's glyphs carry `highlight_style`; the padding around
it keeps the base style, matching ratatui's per-title highlight.
""".
-behaviour(tuition_widget).

-include("tuition_layout.hrl").

-export([render/3]).

-type tabs() :: #{
    titles => [unicode:chardata()],
    selected => non_neg_integer(),
    style => tuition_render:style(),
    highlight_style => tuition_render:style(),
    divider => unicode:chardata(),
    padding => non_neg_integer(),
    title_align => left | center | right
}.

-export_type([tabs/0]).

%% U+2502 BOX DRAWINGS LIGHT VERTICAL — the default divider between titles.
-define(DIVIDER, 16#2502).

%% A drawable piece of the row, laid end to end: a run of `Width' empty columns
%% (`pad', drawn as nothing — the base fill, or whatever the bar is drawn over,
%% shows through), or `Width' columns of `Text' in `Style' (a title or a
%% divider).
-type seg() ::
    {pad, non_neg_integer()}
    | {text, unicode:chardata(), non_neg_integer(), tuition_render:style()}.

%%% -- render ----------------------------------------------------------

-doc """
Draw the tab-bar into `Area`. A degenerate area (no columns or rows)
draws nothing. See the module doc for the config map.
""".
-spec render(tabs(), #rect{}, tuition_render:buffer()) -> tuition_render:buffer().
render(_Cfg, #rect{w = W, h = H}, Buf) when W =< 0; H =< 0 ->
    Buf;
render(Cfg, #rect{w = W} = Area, Buf) ->
    Style = maps:get(style, Cfg, #{}),
    HStyle = maps:get(highlight_style, Cfg, #{}),
    SelStyle = maps:merge(Style, HStyle),
    Divider = maps:get(divider, Cfg, <<?DIVIDER/utf8>>),
    Pad = max(0, maps:get(padding, Cfg, 1)),
    Align = maps:get(title_align, Cfg, left),
    Titles = maps:get(titles, Cfg, []),
    Selected = maps:get(selected, Cfg, 0),
    Segs = segments(Titles, Selected, Style, SelStyle, Divider, Pad),
    %% Paint the base style across the strip first (a no-op when unstyled), then
    %% lay the titles and dividers over it, aligned within the area.
    Buf1 = tuition_widget:fill(Buf, Area, Style),
    Total = lists:sum([seg_width(S) || S <- Segs]),
    Start = tuition_widget:align_offset(Align, W, Total),
    draw(Segs, Area, Start, Buf1).

%%% -- layout ----------------------------------------------------------

%% Build the row as a flat list of segments, left to right: each title flanked by
%% `padding' blanks, with a divider between adjacent titles. The selected title
%% (by 0-based index) is drawn in `SelStyle', every other title and the dividers
%% in the base `Style'.
-spec segments(
    [unicode:chardata()],
    non_neg_integer(),
    tuition_render:style(),
    tuition_render:style(),
    unicode:chardata(),
    non_neg_integer()
) -> [seg()].
segments(Titles, Selected, Style, SelStyle, Divider, Pad) ->
    N = length(Titles),
    DivW = tuition_widget:display_width(Divider),
    lists:append([
        tab(I, Title, N, Selected, Style, SelStyle, Divider, DivW, Pad)
     || {I, Title} <- lists:zip(lists:seq(0, N - 1), Titles)
    ]).

%% One title's segments: `[pad, title, pad]', plus a trailing divider for every
%% title but the last so it sits *between* neighbours, never after the row.
-spec tab(
    non_neg_integer(),
    unicode:chardata(),
    non_neg_integer(),
    non_neg_integer(),
    tuition_render:style(),
    tuition_render:style(),
    unicode:chardata(),
    non_neg_integer(),
    non_neg_integer()
) -> [seg()].
tab(I, Title, N, Selected, Style, SelStyle, Divider, DivW, Pad) ->
    TitleStyle =
        case I =:= Selected of
            true -> SelStyle;
            false -> Style
        end,
    TW = tuition_widget:display_width(Title),
    Base = [{pad, Pad}, {text, Title, TW, TitleStyle}, {pad, Pad}],
    case I < N - 1 of
        true -> Base ++ [{text, Divider, DivW, Style}];
        false -> Base
    end.

-spec seg_width(seg()) -> non_neg_integer().
seg_width({pad, W}) -> W;
seg_width({text, _Text, W, _Style}) -> W.

%%% -- drawing ---------------------------------------------------------

%% Lay the segments across the top row from area-relative column `Start',
%% advancing by each segment's width. {@link tuition_widget:put_line/6} clips a
%% text run to what remains of `Area' (and draws nothing once the column has run
%% off the right edge), so a segment past the area is skipped while the running
%% column still advances — the row is truncated, not wrapped or spilled.
-spec draw([seg()], #rect{}, non_neg_integer(), tuition_render:buffer()) ->
    tuition_render:buffer().
draw(Segs, Area, Start, Buf) ->
    {_X, Out} = lists:foldl(
        fun
            ({pad, PW}, {X, B}) ->
                {X + PW, B};
            ({text, Text, TW, Style}, {X, B}) ->
                {X + TW, tuition_widget:put_line(B, Area, X, 0, Text, Style)}
        end,
        {Start, Buf},
        Segs
    ),
    Out.
