# Building Widgets

A widget draws itself into a rectangle. It is the layer above the cell buffer and
the layout engine: nothing above the widget seam touches raw cells, and a pane is
built by drawing widgets into the rects the layout engine hands out. tuition ships
a ratatui-style set — blocks, paragraphs, lists, tables, gauges, charts and more
— and this guide shows how they compose and how to write your own.

## The behaviour

A stateless widget is a module implementing one callback:

```erlang
render(Config, Area, Buf) -> Buf.
```

`Config` is the widget's content and styling (a plain map with atom keys),
`Area` is the layout rect it must stay within, and it returns the buffer with
its cells drawn in — composing with the diff renderer exactly as a
bare `tuition_render:put_text/5` would. `tuition_block`, `tuition_paragraph`,
`tuition_gauge`, `tuition_sparkline`, `tuition_tabs` and the other static
widgets all take this shape.

`tuition_widget:render/4` dispatches through the behaviour, so a caller can draw
any stateless widget uniformly by module:

```erlang
Buf1 = tuition_widget:render(tuition_gauge, #{ratio => 0.63}, Area, Buf0).
```

## Composing widgets

Widgets compose by drawing against the same buffer, one after another. The common
pattern is a frame plus its content: draw a `tuition_block` into an area, then
draw the content widget into the block's *inner* rect — the region inside the
border, which `tuition_block:inner/2` computes for you.

```erlang
Block = #{borders => all, title => <<"Load">>},
Buf1  = tuition_block:render(Block, Area, Buf0),
Inner = tuition_block:inner(Block, Area),
Buf2  = tuition_gauge:render(#{ratio => 0.63}, Inner, Buf1).
```

Nesting composes the same way: split the inner rect with `tuition_layout` and
frame each child in its own block. See [The Programming Model](programming_model.md)
for how a pane threads a rect down through the layout engine to its widgets.

## Stateless vs. stateful

A selection index or scroll offset cannot live inside a widget. The renderer is
immediate-mode and throws every buffer away, so anything a stateless `render/3`
tried to keep between frames would not survive (see
[The Programming Model](programming_model.md)). A stateful widget —
`tuition_list`, `tuition_table`, `tuition_tree`, `tuition_scrollview`,
`tuition_input_field` — therefore takes its state as an explicit argument and
returns the updated value:

```erlang
render(Config, Area, Buf, State) -> {Buf, State}.
```

The state lives in your pane's state, and you thread it across frames: pass last
frame's value in, keep the value returned. A list, for example, reconciles its
scroll offset to keep the selection visible during `render/4`, and that adjusted
offset must persist to the next frame. Input for a stateful widget goes through
its own function API (`tuition_list` navigates with `next/2`/`prev/2`, and so
on), which you call from your pane's `apply_events/2` and store the result. This
is ratatui's `StatefulWidget` split, made explicit because Erlang has no `&mut`.

## Writing your own

Implement the behaviour and draw with the shared helpers in `tuition_widget`.
The one rule that is easy to miss: **clipping to your rect is your job**.
`tuition_render:put_text/5` clips at the *buffer's* right edge, not your rect's,
so a widget that must not spill onto a neighbouring pane draws its text through
`tuition_widget:put_line/6`, which truncates to the columns your `Area` actually
offers before drawing. It measures each grapheme the way the renderer will — a
control byte as the blank it becomes, a wide glyph as two columns — so your clip
and the renderer's never disagree. A minimal widget:

```erlang
-module(banner).
-behaviour(tuition_widget).
-export([render/3]).

render(#{text := Text} = Config, Area, Buf) ->
    Style = maps:get(style, Config, #{}),
    tuition_widget:put_line(Buf, Area, 0, 0, Text, Style).
```

`tuition_widget_host` will host any widget on its own, yours included — handy for
a focused demo or a captured documentation frame.

## In Elixir

Widget configs are already plain maps with atom keys and every stateful widget
exposes a full function API, so an Elixir consumer wraps nothing. `use Tuition`
imports the record macros; add `aliases: true` (or a keyword list like
`aliases: [tuition_gauge: Gauge]`) to bring the modules into scope under
idiomatic names such as `Block` and `Gauge`. `Tuition.Pane` authors the hosting
pane. See the `Tuition` moduledoc.
