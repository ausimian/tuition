%%%-------------------------------------------------------------------
%%% @doc Pane behaviour — the contract the app shell hosts.
%%%
%%% Every pane the shell hosts is a module implementing this behaviour, so {@link
%%% sonde_shell} can host any of them without knowing which: it drives the shared
%%% render/input/resize/quit loop once and delegates the pane-specific work —
%%% building a frame, folding input, taking a live sample — through these callbacks.
%%% This is the seam PRD §6 calls for between the shell chrome and the panes it
%%% switches between. A pane may itself host a sub-view of the same render/fold/
%%% sample shape without that sub-view being a peer the shell tabs between (e.g. a
%%% drill-down that needs a target selected in its parent), by delegating to it
%%% from its own callbacks rather than seeding it from a zero-arg `new/0'.
%%%
%%% == Where the state lives ==
%%% A pane is a pure state machine: {@link new/0} seeds it, {@link apply_events/2}
%%% folds input into it, {@link sample/1} refreshes it from the live node, and
%%% {@link render/3} draws it. The shell owns each pane's state and threads it back
%%% across frames — the renderer is immediate-mode (see {@link sonde_widget}), so a
%%% widget's selection/scroll offset is carried in the pane state, not the widget.
%%% Nothing here spawns a process or holds a timer; the shell supplies the one
%%% timed read the loop needs.
%%%
%%% == The callbacks ==
%%% <ul>
%%%   <li>{@link new/0} — the initial state, seeded so the first paint is populated
%%%       and deterministic before any live sample.</li>
%%%   <li>{@link render/3} — draw the pane into the rect the shell allocated it (the
%%%       screen minus the shell's nav/status chrome), compositing onto the buffer
%%%       the shell passes in. Returns the buffer and the (possibly updated) state,
%%%       since a stateful widget may adjust its scroll offset to keep the selection
%%%       visible, and that must persist to the next frame. A pane whose widgets are
%%%       all stateless returns its state unchanged.</li>
%%%   <li>{@link apply_events/2} — fold a batch of input events into the state,
%%%       short-circuiting to `quit' when the pane decides the app should exit (an
%%%       unmodified `q' in most panes — but <em>not</em>, say, while a text field
%%%       has focus). The shell peels its own global keys (pane switch, Ctrl-C quit)
%%%       off first, so a pane only ever sees the keys meant for it. A pane whose key
%%%       changed <em>what the visible panes observe</em> — the node picker switching
%%%       the active target — returns `{sample, State}' instead of `{ok, State}' to
%%%       ask the shell to run its {@link sample/1} cycle right after this batch,
%%%       rather than leaving the other visible panes showing the previous target's
%%%       data until the next idle tick. Ordinary panes never need it and return
%%%       `{ok, State}'.</li>
%%%   <li>{@link sample/1} — refresh the state from the running node. Impure. The
%%%       shell calls it on the idle tick for the focused pane only; a static pane
%%%       (no live data) returns its state unchanged.</li>
%%%   <li>{@link setup/0} / {@link teardown/1} — optional lifecycle hooks for a pane
%%%       that needs a node-global resource enabled while it is hosted (e.g. the
%%%       dashboard's `scheduler_wall_time' flag). The shell calls `setup/0' once
%%%       when it starts and passes the returned token to `teardown/1' on exit — on
%%%       a clean quit or a crash alike — so the resource is always released. A pane
%%%       that needs neither omits both.</li>
%%% </ul>
%%%
%%% == Global vs. pane-local input ==
%%% The shell routes keys: it owns the <em>global</em> keys (Tab/Shift-Tab to switch
%%% panes, Ctrl-C to quit) and passes everything else to the focused pane's {@link
%%% apply_events/2}. The global keys are deliberately ones no pane binds — Tab is
%%% never a printable character, so even a pane capturing every printable key (the
%%% process view's filter mode) never has a pane switch stolen from under it, and
%%% never eats one meant for the shell.
%%%
%%% HARD CONSTRAINT (PRD §12): a behaviour, not a dependency — panes and the shell
%%% depend only on `kernel'/`stdlib'/`erts' plus the sibling render/layout/widget
%%% modules. No third-party code.
%%% @end
%%%-------------------------------------------------------------------
-module(sonde_pane).

%% A pane's opaque UI state — its own record, threaded by the shell across frames.
-type state() :: term().
%% An optional token returned by {@link setup/0} and handed back to {@link
%% teardown/1}, carrying whatever the pane must remember to release its resource
%% (e.g. the prior value of a system flag it enabled).
-type resource() :: term().

-export_type([state/0, resource/0]).

%% The initial state — seeded so the first paint is populated and deterministic.
-callback new() -> state().

%% Draw the pane into `Area' (the shell's body rect), compositing onto `Buf'.
%% Returns the buffer and the updated state (a stateful widget's reconciled scroll
%% offset must persist to the next frame).
-callback render(Area :: sonde_layout:rect(), Buf :: sonde_render:buffer(), state()) ->
    {sonde_render:buffer(), state()}.

%% Fold a batch of input events into the state, or short-circuit to `quit'. The
%% shell has already peeled off its own global keys, so these are the pane's.
%% `{sample, State}' additionally asks the shell to run its sample cycle right after
%% this batch — for a pane (the node picker) whose key changed what the visible panes
%% observe, so they refresh at once rather than lagging to the next idle tick.
-callback apply_events([sonde_input:event()], state()) ->
    {ok, state()} | {sample, state()} | quit.

%% Refresh the state from the running node (impure). A static pane returns its
%% state unchanged.
-callback sample(state()) -> state().

%% Enable a node-global resource for the life of the pane, returning a token for
%% teardown. Optional.
-callback setup() -> resource().

%% Release the resource {@link setup/0} enabled, given its token. Optional.
-callback teardown(resource()) -> ok.

-optional_callbacks([setup/0, teardown/1]).
