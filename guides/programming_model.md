# The Programming Model

tuition is immediate-mode, the ratatui model: you do not build a tree of widget
objects and mutate it. Every frame you rebuild the whole screen from your
application state, and the renderer works out the minimal bytes to get the
terminal from the last frame to this one. This guide covers the loop that does
that, the layers it runs through, and where your state lives.

## The loop

One iteration of the loop does four things:

1. **Poll input** for a bounded time, decoding any bytes into events.
2. **Fold** those events (plus any terminal resize) into your state.
3. **Rebuild** the frame from the new state into a fresh buffer.
4. **Diff** the new buffer against the one on screen and write only what changed.

The new buffer becomes the next iteration's baseline. `tuition_render` shows
the shape directly:

```erlang
Prev0 = tuition_render:new(Size),         %% blank screen
Next  = build_frame(State),               %% put_text / widget renders
ok    = tuition_term:write(Handle, tuition_render:diff(Prev0, Next)),
loop(Handle, Next).                        %% Next is the new baseline
```

Rebuilding every frame sounds wasteful, but the diff is cheap: `diff/2` compares
row by row and only rescans the rows that actually changed, so the common case (a
few cells moving on an otherwise-static screen) touches a handful of rows.
Re-rendering an identical frame emits nothing at all, which is why an idle poll
that finds no input writes nothing.

You rarely write this loop yourself. `tuition_shell` owns it and calls your
pane's callbacks at steps 2 and 3. `tuition_demo` is the same loop written out
in full if you want to read one end to end.

## The stack

A frame is built by handing a rectangle down through four layers, each drawing
into or subdividing what the layer above gave it:

- **`tuition_render`** — the cell grid. A buffer is `Cols × Rows` styled cells;
  `put_text/5` and friends draw into it, and `diff/2` turns two buffers into the
  bytes between them. Nothing above this layer touches raw ANSI.
- **`tuition_layout`** — geometry. It splits a parent rect into child rects
  along one axis with fixed, percentage and fill constraints, so widgets get
  exact non-overlapping regions rather than a raw terminal size.
- **`tuition_widget`** — the render-into-a-rect seam. Each widget draws itself
  into the rect it is given and composes onto the buffer. This is where a block,
  a list or a gauge lives.
- **`tuition_pane`** — one screen. A pane composes widgets into the rect the
  shell allocates it, folds input, and refreshes from live data.

`tuition_shell` sits on top, hosting a set of panes under one navigable UI and
running the loop on their behalf. A build looks like: the shell hands the pane a
rect, the pane splits it with the layout engine, and draws a widget into each
child rect against the shared buffer.

```erlang
build_frame(Size, State) ->
    Area = tuition_layout:area(Size),
    [Left, Right] = tuition_layout:split(horizontal, [{percent, 30}, fill], Area),
    Buf0 = tuition_render:new(Size),
    Buf1 = draw_sidebar(Left, Buf0, State),
    draw_body(Right, Buf1, State).
```

## Where state lives

The renderer discards each buffer after diffing it, so **nothing drawn can carry
state to the next frame**. A widget's selection index or scroll offset therefore
cannot live inside the widget — there is no widget object that survives the frame
to hold it.

State lives in your application, in the pane. The shell owns each pane's state and
threads it back across frames. A stateless widget (a block, a paragraph, a gauge)
is a pure function of its config and rect. A stateful widget (a list, a table, a
tree) takes its state as an explicit argument and returns the updated value, which
you keep in the pane state and pass back next frame. This is ratatui's
`StatefulWidget` split, made explicit because Erlang has no `&mut`. See
[Building Widgets](building_widgets.md) for how that threading looks in practice.

The panes themselves are pure state machines: `new/0` seeds the state,
`apply_events/2` folds input into it, `sample/1` refreshes it from the live node,
and `render/3` draws it. Nothing spawns a process or holds a timer — the shell
supplies the one timed read the loop needs.

## The backend seam

Below the renderer sits `tuition_term`: the behaviour that carries rendered
bytes out and keystrokes in. The loop above never branches on which backend is in
use, so the same panes run over a local tty, an ssh channel, a browser terminal
or a scripted test double. See [Terminal Backends](terminal_backends.md).
