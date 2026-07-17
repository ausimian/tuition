-module(tuition_pane).
-moduledoc """
The contract every pane implements.

Each pane the shell hosts is a module implementing this behaviour, so
`m:tuition_shell` can host any of them without knowing which. The shell drives
the shared render/input/resize/quit loop once and delegates the pane-specific
work — building a frame, folding input, taking a live sample — through these
callbacks. This is the seam between the shell chrome and the panes it switches
between. A pane may itself host a sub-view of the same render/fold/sample shape
without that sub-view being a peer the shell tabs between (e.g. a drill-down that
needs a target selected in its parent). It does so by delegating to the sub-view
from its own callbacks, rather than seeding it from a zero-arg `new/0`.

## Where the state lives

A pane is a pure state machine: `new/0` seeds it, `apply_events/2` folds input
into it, `sample/1` refreshes it from the live node, and `render/3` draws it. The
shell owns each pane's state and threads it back across frames. The renderer is
immediate-mode (see `m:tuition_widget`), so a widget's selection/scroll offset is
carried in the pane state, not the widget. Nothing here spawns a process or holds
a timer; the shell supplies the one timed read the loop needs.

## The callbacks

- `new/0` / `new/1` — the initial state, seeded so the first paint is populated
  and deterministic before any live sample. Which one the shell calls is chosen
  by the pane's spec: a plain `{Module, Title}` calls `new/0`, a parameterised
  `{Module, Title, Arg}` calls `new/1` with the spec's `Arg`. A pane implements
  whichever it is hosted by, or both. Most panes have exactly one sensible
  initial state and take `new/0`; `new/1` is for a module hosted more than once
  with different content, where the difference is data rather than a module of
  its own — `m:tuition_widget_host` is seeded with the widget it shows this way.
  The compiler cannot check that at least one is present (a behaviour has no
  "one of these" form, the same gap as the `setup/0`/`teardown/1` pair below), so
  a pane implementing neither fails at seed time rather than at compile time.
- `render/3` — draw the pane into the rect the shell allocated it (the
  screen minus the shell's nav/status chrome), compositing onto the buffer the
  shell passes in. Returns the buffer and the (possibly updated) state. A
  stateful widget may adjust its scroll offset to keep the selection visible,
  and that must persist to the next frame. A pane whose widgets are all
  stateless returns its state unchanged.
- `apply_events/2` — fold a batch of input events into the state,
  short-circuiting to `quit` when the pane decides the app should exit (an
  unmodified `q` in most panes, but *not*, say, while a text field has focus).
  The shell peels its own global keys (pane switch, Ctrl-C quit) off first, so
  a pane only ever sees the keys meant for it. A pane whose key changed *what
  the visible panes observe* — the node picker switching the active target —
  returns `{sample, State}` instead of `{ok, State}`. That asks the shell to run
  its `sample/1` cycle right after this batch, rather than leaving the other
  visible panes showing the previous target's data until the next idle tick.
  Ordinary panes never need it and return `{ok, State}`.
- `sample/1` — refresh the state from the running node. Impure. The shell
  calls it on the idle tick for the focused pane only; a static pane (no live
  data) returns its state unchanged.
- `setup/0` / `teardown/1` — optional lifecycle hooks for a pane that
  needs a node-global resource enabled while it is hosted (e.g. the dashboard's
  `scheduler_wall_time` flag). The shell calls `setup/0` once when it starts and
  passes the returned token to `teardown/1` on exit — on a clean quit or a crash
  alike — so the resource is always released. A pane that needs neither omits
  both.

## Global vs. pane-local input

The shell routes keys. It owns the *global* keys (Tab/Shift-Tab to switch panes,
Ctrl-C to quit) and passes everything else to the focused pane's
`apply_events/2`. The global keys are deliberately ones no pane binds. Tab is
never a printable character, so even a pane capturing every printable key (the
process view's filter mode) never has a pane switch stolen from under it, and
never eats one meant for the shell.
""".

%% A pane's opaque UI state — its own record, threaded by the shell across frames.
-type state() :: term().
%% An optional token returned by {@link setup/0} and handed back to {@link
%% teardown/1}, carrying whatever the pane must remember to release its resource
%% (e.g. the prior value of a system flag it enabled).
-type resource() :: term().

-export_type([state/0, resource/0]).

%% The initial state — seeded so the first paint is populated and deterministic.
%% Called for a plain `{Module, Title}' pane spec.
-callback new() -> state().

%% As `new/0', seeded from the `Arg' of a parameterised `{Module, Title, Arg}'
%% pane spec — for a module hosted more than once with different content.
-callback new(Arg :: term()) -> state().

%% Draw the pane into `Area' (the shell's body rect), compositing onto `Buf'.
%% Returns the buffer and the updated state (a stateful widget's reconciled scroll
%% offset must persist to the next frame).
-callback render(Area :: tuition_layout:rect(), Buf :: tuition_render:buffer(), state()) ->
    {tuition_render:buffer(), state()}.

%% Fold a batch of input events into the state, or short-circuit to `quit'. The
%% shell has already peeled off its own global keys, so these are the pane's.
%% `{sample, State}' additionally asks the shell to run its sample cycle right after
%% this batch — for a pane (the node picker) whose key changed what the visible panes
%% observe, so they refresh at once rather than lagging to the next idle tick.
-callback apply_events([tuition_input:event()], state()) ->
    {ok, state()} | {sample, state()} | quit.

%% Refresh the state from the running node (impure). A static pane returns its
%% state unchanged.
-callback sample(state()) -> state().

%% Enable a node-global resource for the life of the pane, returning a token for
%% teardown. Optional.
-callback setup() -> resource().

%% Release the resource {@link setup/0} enabled, given its token. Optional.
-callback teardown(resource()) -> ok.

%% `new/0' and `new/1' are both optional only because a pane implements the one
%% its spec seeds it through (or both); every pane must implement at least one.
-optional_callbacks([new/0, new/1, setup/0, teardown/1]).
