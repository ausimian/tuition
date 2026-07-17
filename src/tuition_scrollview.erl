-module(tuition_scrollview).
-moduledoc """
A window onto oversized virtual content (stateful).

A scroll view hosts content larger than the area it is given and pans a window
over it, so a pane can render into a big virtual buffer and scroll it in both
axes. It is the general "content bigger than the box, scroll it" primitive, the
equivalent of ratatui's `tui-scrollview` crate. The other scrollable widgets
(`tuition_list`, `tuition_table`, `tuition_paragraph`) each carry their own
offset and confine their drawing to their own rect; none of them offers a shared
way to draw arbitrary content off-screen and scroll a window across it, which is
what this widget is for.

## How it works

You declare a `content_size` — the `{W, H}` virtual extent — and paint that whole
extent, either with a `draw` fun that fills a fresh content-sized buffer or by
handing over a pre-built one. `render/4` then blits the `Area`-sized window at
the current `{x_offset, y_offset}` into the visible rect, cell by cell, clipping
at the content edges. A window narrower or shorter than the content shows a
slice, and scrolling moves which slice.

Wide (two-column) glyphs are handled at the window edges. A glyph whose right
half would fall outside the window — because the window starts in the middle of
it, or because it sits against the right edge — is dropped to a blank rather than
shown as a stray half. So the visible slice never spills a column past the
viewport, and never strands an orphaned continuation cell.

## Stateful, by necessity

The `{x_offset, y_offset}` live in a `#scrollview_state{}` (see
`include/tuition_widget.hrl`) held by the *caller*, not in this module — the same
`StatefulWidget` split `m:tuition_list` uses (see `m:tuition_widget` for why it
has to be explicit). `render/4` takes the state and returns it with both offsets
clamped to the scrollable range for the current content and viewport, so a window
left past the edge by shrunk content or a grown pane is pulled back into range.
Scrolling is a pure state transition the caller applies to input:

```
State1 = tuition_scrollview:scroll_by(State0, 0, 1), %% on Down
{Buf1, State2} = tuition_scrollview:render(Cfg, Area, Buf0, State1).
```

## Scrollbars

`scrollbars` composes `m:tuition_scrollbar` onto the edges: `vertical` takes the
rightmost column, `horizontal` the bottom row, `both` takes both (the content
window shrinks to make room). Each bar's `content_length` / `viewport_length` /
`position` are derived from the content size, the viewport size and the offsets,
so the thumbs track the window automatically. An optional `scrollbar_opts` map
supplies styles and glyphs for the bars; its geometry keys are always overridden
by the derived values.

## Config

A map:

- `content_size` — the `{W, H}` virtual extent (default `{0, 0}`).
- `draw` — a fun `(ContentBuf) -> ContentBuf` painting the virtual content,
  or a pre-built `tuition_render:buffer()` of the content size. If absent,
  the content is blank.
- `scrollbars` — `none` (default) | `vertical` | `horizontal` | `both`.
- `scrollbar_opts` — a `m:tuition_scrollbar` config for styling the bars
  (default `#{}`); the orientation/length/position keys are derived and win.
""".

-include("tuition_layout.hrl").
-include("tuition_term.hrl").
-include("tuition_widget.hrl").

-export([new/0, size/1, render/4, scroll_to/3, scroll_by/3, offset/1]).

-type scrollbars() :: none | vertical | horizontal | both.

-type scrollview_cfg() :: #{
    content_size => {non_neg_integer(), non_neg_integer()},
    draw => fun((tuition_render:buffer()) -> tuition_render:buffer()) | tuition_render:buffer(),
    scrollbars => scrollbars(),
    scrollbar_opts => tuition_scrollbar:scrollbar()
}.
-type state() :: #scrollview_state{}.

-export_type([scrollview_cfg/0, scrollbars/0, state/0]).

%%% -- state -----------------------------------------------------------

-doc """
A fresh scroll-view state: the window at the content's top-left corner.
""".
-spec new() -> state().
new() -> #scrollview_state{}.

-doc """
The virtual content size as a rect at the origin: the dimensions of the buffer
the content is painted into. A convenience for a caller that pre-builds the
content buffer itself, rather than passing a `draw` fun, and needs its size.
""".
-spec size(scrollview_cfg()) -> #rect{}.
size(Cfg) ->
    {W, H} = maps:get(content_size, Cfg, {0, 0}),
    #rect{x = 0, y = 0, w = W, h = H}.

-doc """
The current window offset as `{X, Y}` (columns from the left, rows from the
top of the content).
""".
-spec offset(state()) -> {non_neg_integer(), non_neg_integer()}.
offset(#scrollview_state{x_offset = X, y_offset = Y}) -> {X, Y}.

-doc """
Move the window to an absolute `{X, Y}` content offset. Negative values are
floored at zero. The offset is clamped to the content extent at the next
`render/4`, so a value momentarily past the end is harmless — the same way
`m:tuition_list` defers its clamp to render time.
""".
-spec scroll_to(state(), integer(), integer()) -> state().
scroll_to(State, X, Y) ->
    State#scrollview_state{x_offset = max(0, X), y_offset = max(0, Y)}.

-doc """
Pan the window by `{DX, DY}` cells from its current offset, floored at
zero. As with `scroll_to/3`, the upper clamp is applied at render time.
""".
-spec scroll_by(state(), integer(), integer()) -> state().
scroll_by(#scrollview_state{x_offset = X, y_offset = Y} = State, DX, DY) ->
    State#scrollview_state{x_offset = max(0, X + DX), y_offset = max(0, Y + DY)}.

%%% -- render ----------------------------------------------------------

-doc """
Blit the scrolled window of the content into `Area`, drawing any scrollbars, and
return the buffer together with the reconciled state (offsets clamped to the
scrollable range). An empty area draws nothing but still reconciles, so a resize
to nothing and back leaves valid offsets behind.
""".
-spec render(scrollview_cfg(), #rect{}, tuition_render:buffer(), state()) ->
    {tuition_render:buffer(), state()}.
render(Cfg, Area, Buf, State0) ->
    Content = maps:get(content_size, Cfg, {0, 0}),
    Scrollbars = maps:get(scrollbars, Cfg, none),
    {VW, VH} = viewport_size(Area, Scrollbars),
    State1 = reconcile(State0, Content, {VW, VH}),
    Buf1 =
        case Area of
            #rect{w = W, h = H} when W =< 0; H =< 0 -> Buf;
            _ -> draw(Cfg, Area, Buf, State1, Content, {VW, VH}, Scrollbars)
        end,
    {Buf1, State1}.

%% The visible content window inside `Area', after any scrollbars have claimed
%% their edge cells: a vertical bar takes one column, a horizontal bar one row.
-spec viewport_size(#rect{}, scrollbars()) ->
    {non_neg_integer(), non_neg_integer()}.
viewport_size(#rect{w = W, h = H}, Scrollbars) ->
    {max(0, W - vbar(Scrollbars)), max(0, H - hbar(Scrollbars))}.

%% Clamp both offsets into `[0, Content - Viewport]' for each axis, so the window
%% never runs past the content edge — the reconciliation every {@link render/4}
%% begins with, returned so it survives to the next frame.
-spec reconcile(
    state(), {non_neg_integer(), non_neg_integer()}, {non_neg_integer(), non_neg_integer()}
) -> state().
reconcile(#scrollview_state{x_offset = X, y_offset = Y}, {CW, CH}, {VW, VH}) ->
    #scrollview_state{
        x_offset = min(max(X, 0), max(0, CW - VW)),
        y_offset = min(max(Y, 0), max(0, CH - VH))
    }.

-spec draw(
    scrollview_cfg(),
    #rect{},
    tuition_render:buffer(),
    state(),
    {non_neg_integer(), non_neg_integer()},
    {non_neg_integer(), non_neg_integer()},
    scrollbars()
) -> tuition_render:buffer().
draw(Cfg, Area, Buf, State, {CW, CH} = Content, {VW, VH}, Scrollbars) ->
    #scrollview_state{x_offset = XOff, y_offset = YOff} = State,
    ContentBuf = content_buffer(Cfg, Content),
    ViewRect = #rect{x = Area#rect.x, y = Area#rect.y, w = VW, h = VH},
    Buf1 = blit(Buf, ContentBuf, ViewRect, XOff, YOff),
    draw_scrollbars(Buf1, Cfg, Area, {CW, CH}, {VW, VH}, {XOff, YOff}, Scrollbars).

%% Build the buffer holding the virtual content: run the `draw' fun on a fresh
%% content-sized buffer, use a pre-built buffer as given, or leave it blank.
-spec content_buffer(scrollview_cfg(), {non_neg_integer(), non_neg_integer()}) ->
    tuition_render:buffer().
content_buffer(Cfg, {CW, CH}) ->
    case maps:get(draw, Cfg, undefined) of
        Fun when is_function(Fun, 1) -> Fun(tuition_render:new({CW, CH}));
        undefined -> tuition_render:new({CW, CH});
        Buf -> Buf
    end.

%%% -- blit ------------------------------------------------------------

%% Copy the `{XOff, YOff}'-anchored window of `Content' into the visible rect, one
%% cell at a time. A source position past the content edge reads as a blank (so the
%% slice beyond the content clears rather than leaving stale cells).
-spec blit(
    tuition_render:buffer(), tuition_render:buffer(), #rect{}, non_neg_integer(), non_neg_integer()
) -> tuition_render:buffer().
blit(Buf, _Content, #rect{w = VW, h = VH}, _XOff, _YOff) when VW =< 0; VH =< 0 ->
    Buf;
blit(Buf, Content, #rect{x = AX, y = AY, w = VW, h = VH}, XOff, YOff) ->
    lists:foldl(
        fun(DY, B0) ->
            lists:foldl(
                fun(DX, B1) ->
                    blit_cell(B1, Content, AX + DX, AY + DY, XOff + DX, YOff + DY, DX, VW)
                end,
                B0,
                lists:seq(0, VW - 1)
            )
        end,
        Buf,
        lists:seq(0, VH - 1)
    ).

%% Blit one source cell at `{SX, SY}' to the target `{TX, TY}', handling the wide
%% glyphs whose halves fall on the window boundary:
%%   * a `wide_cont' (the right half of a wide glyph) is normally painted by its
%%     partner one cell to the left; but at the window's left edge (`DX =:= 0') the
%%     partner is off-window, so a blank is drawn in place of the orphaned half.
%%   * a wide glyph whose right half would land outside the viewport (`DX + 1 >=
%%     VW') is dropped to a blank — half a wide glyph must never render.
%% A blank source cell writes the default blank, clearing whatever the window is
%% drawn over.
-spec blit_cell(
    tuition_render:buffer(),
    tuition_render:buffer(),
    integer(),
    integer(),
    integer(),
    integer(),
    non_neg_integer(),
    non_neg_integer()
) -> tuition_render:buffer().
blit_cell(Buf, Content, TX, TY, SX, SY, DX, VW) ->
    case tuition_render:cell_at(Content, SX, SY) of
        wide_cont when DX =:= 0 ->
            tuition_render:put_cell(Buf, TX, TY, #cell{});
        wide_cont ->
            Buf;
        #cell{cols = 2} when DX + 1 >= VW ->
            tuition_render:put_cell(Buf, TX, TY, #cell{});
        #cell{} = Cell ->
            tuition_render:put_cell(Buf, TX, TY, Cell)
    end.

%%% -- scrollbars ------------------------------------------------------

%% Draw the requested scrollbars on the edges the viewport left free, deriving each
%% bar's geometry from the content size, viewport size and offset.
-spec draw_scrollbars(
    tuition_render:buffer(),
    scrollview_cfg(),
    #rect{},
    {non_neg_integer(), non_neg_integer()},
    {non_neg_integer(), non_neg_integer()},
    {non_neg_integer(), non_neg_integer()},
    scrollbars()
) -> tuition_render:buffer().
draw_scrollbars(Buf, Cfg, Area, {CW, CH}, {VW, VH}, {XOff, YOff}, Scrollbars) ->
    Opts = maps:get(scrollbar_opts, Cfg, #{}),
    Buf1 =
        case vbar(Scrollbars) of
            1 ->
                Rect = #rect{x = Area#rect.x + VW, y = Area#rect.y, w = 1, h = VH},
                VCfg = Opts#{
                    orientation => vertical,
                    content_length => CH,
                    viewport_length => VH,
                    position => YOff
                },
                tuition_scrollbar:render(VCfg, Rect, Buf);
            0 ->
                Buf
        end,
    case hbar(Scrollbars) of
        1 ->
            Rect2 = #rect{x = Area#rect.x, y = Area#rect.y + VH, w = VW, h = 1},
            HCfg = Opts#{
                orientation => horizontal,
                content_length => CW,
                viewport_length => VW,
                position => XOff
            },
            tuition_scrollbar:render(HCfg, Rect2, Buf1);
        0 ->
            Buf1
    end.

%%% -- helpers ---------------------------------------------------------

%% Columns a vertical scrollbar claims from the area (1 when shown, else 0).
-spec vbar(scrollbars()) -> 0 | 1.
vbar(vertical) -> 1;
vbar(both) -> 1;
vbar(_) -> 0.

%% Rows a horizontal scrollbar claims from the area (1 when shown, else 0).
-spec hbar(scrollbars()) -> 0 | 1.
hbar(horizontal) -> 1;
hbar(both) -> 1;
hbar(_) -> 0.
