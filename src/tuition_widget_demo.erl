-module(tuition_widget_demo).
-moduledoc """
Widget-layer demo — a pane composed from widgets.

This is a demo pane composed from widgets that renders and takes selection
input. It composes the widgets over the existing render/layout/loop:
`m:tuition_block` frames the pane, `m:tuition_paragraph` draws a help line, and a
stateful `m:tuition_table` shows a scrollable, selectable, sortable table of
(mock) processes — the shape of the etop/observer-parity process view later
panes will grow into. It proves the seam composes with the
real `m:tuition_render` diff renderer, `m:tuition_layout` split, and an
immediate-mode input loop — the same shape as `m:tuition_demo`'s
loop, so the two sit side by side rather than one replacing the other.

## Running it

`tuition_widget_demo:start()` runs the demo on its own, hosted by `m:tuition_shell`, until `q` (or Ctrl-C). Up/Down (or `j`/`k`) move the selection; the
table scrolls to keep it in view; Home/End jump to the ends; `s` sorts by the
Name column, toggling ascending/descending. `start/1` takes a `backend` option
(passed through to the backend's `open/1`), which is also how the loop is driven
headlessly in tests.

## Stateful widgets, threaded by the loop

The row selection and scroll offset live in this module's state, not in the
table widget (see `m:tuition_widget`). Input folds into the selection and
the sort (`apply_events/2`); `build_frame/2` then orders the rows
by the current sort and renders the table, which returns the offset it chose
to keep the selection visible, and the loop keeps that for the next frame. The
pure pieces — `new/0`, `apply_events/2`, `build_frame/2` —
are exported so the composition can be driven and asserted directly, not only
through a live terminal.
""".
-behaviour(tuition_pane).

-include("tuition_layout.hrl").

-export([start/0, start/1]).
-export([new/0, apply_events/2, sample/1, render/3, build_frame/2, selection/1]).

%% The column `s' sorts on — the Name column (0-based).
-define(SORT_COL, 1).

%% Demo UI state: the (fixed, mock) process rows in their canonical order, the
%% table widget's selection + scroll state, and the current sort. The table state
%% is threaded across frames by the loop; the rows are re-sorted for display each
%% frame rather than mutated, so the canonical order (and the row count) is stable.
-record(demo, {
    rows = [] :: [tuition_table:row()],
    table = tuition_table:new() :: tuition_table:state(),
    sort = none :: tuition_table:sort()
}).

-type state() :: #demo{}.
-export_type([state/0]).

%%% -- entry point -----------------------------------------------------

-doc """
Run the demo on its own, hosted by `m:tuition_shell`. Blocks until the
user quits; returns `ok` once the terminal is restored, or `{error, Reason}` if
the backend could not be opened.
""".
-spec start() -> ok | {error, term()}.
start() -> start(#{}).

-doc """
As `start/0`, with options. The shell opens the terminal backend
(`backend` selects it, default `m:tuition_term_local`; the whole `Opts` map is
passed to its `open/1`) and runs the shared render/input loop over this one pane
— the hook the loop is driven through in tests.
""".
-spec start(Opts :: map()) -> ok | {error, term()}.
start(Opts) ->
    tuition_shell:start([{?MODULE, <<"Widgets">>}], Opts).

%%% -- state -----------------------------------------------------------

-doc """
The demo's initial state: the mock process rows in canonical order, the
first row selected, the view unscrolled and unsorted.
""".
-spec new() -> state().
new() ->
    #demo{rows = demo_rows(), table = tuition_table:select(tuition_table:new(), 0)}.

-doc """
A no-op: the demo shows a fixed mock table, so it has no live node data to
refresh. Present to satisfy the `m:tuition_pane` contract the shell drives
every pane through on the idle tick.
""".
-spec sample(state()) -> state().
sample(State) -> State.

-doc """
The selected row index (or `none`) — exposed so a driver/test can assert
how input moved the selection.
""".
-spec selection(state()) -> none | non_neg_integer().
selection(#demo{table = Table}) -> tuition_table:selected(Table).

-doc """
Fold input events into the state in arrival order, short-circuiting to
`quit` on `q` or Ctrl-C. Up/Down (and `j`/`k`) move the selection; Home/End
jump to the ends; `s` toggles the Name-column sort; every other event is
ignored.
""".
-spec apply_events([tuition_input:event()], state()) -> {ok, state()} | quit.
apply_events([], State) ->
    {ok, State};
apply_events([Event | Rest], State) ->
    case is_quit(Event) of
        true -> quit;
        false -> apply_events(Rest, fold(Event, State))
    end.

-spec is_quit(tuition_input:event()) -> boolean().
is_quit({key, {char, $q}, []}) -> true;
is_quit({key, {ctrl, $c}, _Mods}) -> true;
is_quit(_Event) -> false.

%% Move the selection for a navigation key, toggle the sort on `s'; ignore
%% anything else. The row count is passed to tuition_table so it can clamp at the
%% ends.
-spec fold(tuition_input:event(), state()) -> state().
fold({key, up, _Mods}, State) ->
    move_prev(State);
fold({key, {char, $k}, _Mods}, State) ->
    move_prev(State);
fold({key, down, _Mods}, State) ->
    move_next(State);
fold({key, {char, $j}, _Mods}, State) ->
    move_next(State);
fold({key, home, _Mods}, #demo{table = Table} = State) ->
    State#demo{table = tuition_table:select(Table, 0)};
fold({key, 'end', _Mods}, #demo{rows = Rows, table = Table} = State) ->
    State#demo{table = tuition_table:select(Table, length(Rows) - 1)};
fold({key, {char, $s}, _Mods}, #demo{sort = Sort} = State) ->
    State#demo{sort = tuition_table:toggle_sort(Sort, ?SORT_COL)};
fold(_Event, State) ->
    State.

-spec move_prev(state()) -> state().
move_prev(#demo{rows = Rows, table = Table} = State) ->
    State#demo{table = tuition_table:prev(Table, length(Rows))}.

-spec move_next(state()) -> state().
move_next(#demo{rows = Rows, table = Table} = State) ->
    State#demo{table = tuition_table:next(Table, length(Rows))}.

%%% -- frame building --------------------------------------------------

-doc """
Render the demo into `Area` (the rect the shell allots it): a bordered
`m:tuition_block` framing a `m:tuition_paragraph` help line above a stateful,
sortable `m:tuition_table`. The rows are ordered by the current sort for
display; the canonical order in the state is untouched. Returns the buffer and
the updated state — the table may have adjusted its scroll offset to keep the
selection visible, and that adjustment must persist to the next frame.
""".
-spec render(tuition_layout:rect(), tuition_render:buffer(), state()) ->
    {tuition_render:buffer(), state()}.
render(Area, Buf0, #demo{rows = Rows, table = Table0, sort = Sort} = State) ->
    Block = #{
        borders => all,
        title => <<" processes ">>,
        title_align => center,
        border_style => #{fg => 6},
        title_style => #{fg => 6, bold => true}
    },
    Buf1 = tuition_widget:render(tuition_block, Block, Area, Buf0),
    [HelpArea, TableArea] = tuition_layout:split(
        vertical, [{fixed, 2}, fill], tuition_block:inner(Block, Area)
    ),
    Help = #{
        text => <<"up/down or j/k to select    s to sort    q to quit">>,
        wrap => word,
        style => #{fg => 8}
    },
    Buf2 = tuition_widget:render(tuition_paragraph, Help, HelpArea, Buf1),
    TableCfg = #{
        columns => columns(),
        rows => tuition_table:apply_sort(Rows, Sort),
        header_style => #{fg => 6, bold => true},
        highlight_style => #{fg => 0, bg => 6, bold => true},
        highlight_symbol => <<"> ">>,
        sort => Sort
    },
    {Buf3, Table1} = tuition_table:render(TableCfg, TableArea, Buf2, Table0),
    {Buf3, State#demo{table = Table1}}.

-doc """
Render the pane full-screen for the given terminal size — the standalone
convenience the pure tests build frames through. Delegates to `render/3`
over the whole area on a fresh buffer.
""".
-spec build_frame(tuition_term:size(), state()) -> {tuition_render:buffer(), state()}.
build_frame(Size, State) ->
    render(tuition_layout:area(Size), tuition_render:new(Size), State).

%% The process-table columns: a fixed-width pid, a filling name, and two
%% right-aligned numeric columns — the etop/observer shape.
-spec columns() -> [tuition_table:column()].
columns() ->
    [
        #{header => <<"PID">>, constraint => {fixed, 11}},
        #{header => <<"Name">>, constraint => fill},
        #{header => <<"Msgs">>, constraint => {fixed, 5}, align => right},
        #{header => <<"Mem (KB)">>, constraint => {fixed, 9}, align => right}
    ].

%% A fixed set of mock process rows — long enough that the table scrolls on a
%% normal terminal, so selection following the view is visible in the demo. The
%% names are real OTP process names for flavour; the pids and counters are
%% fabricated but deterministic (so a headless test sees stable output).
-spec demo_rows() -> [tuition_table:row()].
demo_rows() ->
    Names = [
        "init",
        "erts_code_purger",
        "erl_prim_loader",
        "logger",
        "application_controller",
        "proc_lib",
        "kernel_sup",
        "global_name_server",
        "inet_db",
        "erl_epmd",
        "auth",
        "net_kernel",
        "code_server",
        "file_server_2",
        "standard_error_sup",
        "user_drv",
        "kernel_safe_sup",
        "disk_log_sup",
        "disk_log_server",
        "timer_server",
        "rex",
        "sasl_sup",
        "release_handler",
        "tuition_agent",
        "tuition_demo",
        "gen_event",
        "supervisor_bridge",
        "pg",
        "socket_registry"
    ],
    [demo_row(N, Name) || {N, Name} <- lists:zip(lists:seq(1, length(Names)), Names)].

-spec demo_row(pos_integer(), string()) -> tuition_table:row().
demo_row(N, Name) ->
    [
        iolist_to_binary(io_lib:format("<0.~b.0>", [N + 40])),
        list_to_binary(Name),
        integer_to_binary((N * 7) rem 13),
        integer_to_binary(64 + (N * 137) rem 4096)
    ].
