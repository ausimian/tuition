%%%-------------------------------------------------------------------
%%% @doc Widget-layer demo — the Phase 0.5 exit pane (PRD §13).
%%%
%%% This is the "demo pane composed from widgets [that] renders and takes
%%% selection input" the roadmap sets as the widget layer's exit criterion. It
%%% composes the widgets over the existing render/layout/loop: {@link
%%% sonde_block} frames the pane, {@link sonde_paragraph} draws a help line, and a
%%% stateful {@link sonde_table} shows a scrollable, selectable, sortable table of
%%% (mock) processes — the shape of the etop/observer-parity process view (PRD
%%% §9.1) the Phase 1 panes will grow into. It proves the seam composes with the
%%% real {@link sonde_render} diff renderer, {@link sonde_layout} split, and an
%%% immediate-mode input loop — the same shape as {@link sonde_core}'s Phase 0
%%% loop, so the two sit side by side rather than one replacing the other.
%%%
%%% == Running it ==
%%% `sonde_widget_demo:start()' runs the demo on its own, hosted by {@link
%%% sonde_shell}, until `q' (or Ctrl-C). Up/Down (or `j'/`k') move the selection; the
%%% table scrolls to keep it in view; Home/End jump to the ends; `s' sorts by the
%%% Name column, toggling ascending/descending. `start/1' takes a `backend' option
%%% (passed through to the backend's `open/1'), which is also how the loop is driven
%%% headlessly in tests.
%%%
%%% == Stateful widgets, threaded by the loop ==
%%% The row selection and scroll offset live in this module's state, not in the
%%% table widget (see {@link sonde_widget}). Input folds into the selection and
%%% the sort ({@link apply_events/2}); {@link build_frame/2} then orders the rows
%%% by the current sort and renders the table, which returns the offset it chose
%%% to keep the selection visible, and the loop keeps that for the next frame. The
%%% pure pieces — {@link new/0}, {@link apply_events/2}, {@link build_frame/2} —
%%% are exported so the composition can be driven and asserted directly, not only
%%% through a live terminal.
%%% @end
%%%-------------------------------------------------------------------
-module(sonde_widget_demo).
-behaviour(sonde_pane).

-include("sonde_layout.hrl").

-export([start/0, start/1]).
-export([new/0, apply_events/2, sample/1, render/3, build_frame/2, selection/1]).

%% The column `s' sorts on — the Name column (0-based).
-define(SORT_COL, 1).

%% Demo UI state: the (fixed, mock) process rows in their canonical order, the
%% table widget's selection + scroll state, and the current sort. The table state
%% is threaded across frames by the loop; the rows are re-sorted for display each
%% frame rather than mutated, so the canonical order (and the row count) is stable.
-record(demo, {
    rows = [] :: [sonde_table:row()],
    table = sonde_table:new() :: sonde_table:state(),
    sort = none :: sonde_table:sort()
}).

-type state() :: #demo{}.
-export_type([state/0]).

%%% -- entry point -----------------------------------------------------

%% @doc Run the demo on its own, hosted by {@link sonde_shell}. Blocks until the
%% user quits; returns `ok' once the terminal is restored, or `{error, Reason}' if
%% the backend could not be opened.
-spec start() -> ok | {error, term()}.
start() -> start(#{}).

%% @doc As {@link start/0}, with options. The shell opens the terminal backend
%% (`backend' selects it, default {@link sonde_term_local}; the whole `Opts' map is
%% passed to its `open/1') and runs the shared render/input loop over this one pane
%% — the hook the loop is driven through in tests.
-spec start(Opts :: map()) -> ok | {error, term()}.
start(Opts) ->
    sonde_shell:start([{?MODULE, <<"Widgets">>}], Opts).

%%% -- state -----------------------------------------------------------

%% @doc The demo's initial state: the mock process rows in canonical order, the
%% first row selected, the view unscrolled and unsorted.
-spec new() -> state().
new() ->
    #demo{rows = demo_rows(), table = sonde_table:select(sonde_table:new(), 0)}.

%% @doc A no-op: the demo shows a fixed mock table, so it has no live node data to
%% refresh. Present to satisfy the {@link sonde_pane} contract the shell drives
%% every pane through on the idle tick.
-spec sample(state()) -> state().
sample(State) -> State.

%% @doc The selected row index (or `none') — exposed so a driver/test can assert
%% how input moved the selection.
-spec selection(state()) -> none | non_neg_integer().
selection(#demo{table = Table}) -> sonde_table:selected(Table).

%% @doc Fold input events into the state in arrival order, short-circuiting to
%% `quit' on `q' or Ctrl-C. Up/Down (and `j'/`k') move the selection; Home/End
%% jump to the ends; `s' toggles the Name-column sort; every other event is
%% ignored.
-spec apply_events([sonde_input:event()], state()) -> {ok, state()} | quit.
apply_events([], State) ->
    {ok, State};
apply_events([Event | Rest], State) ->
    case is_quit(Event) of
        true -> quit;
        false -> apply_events(Rest, fold(Event, State))
    end.

-spec is_quit(sonde_input:event()) -> boolean().
is_quit({key, {char, $q}, []}) -> true;
is_quit({key, {ctrl, $c}, _Mods}) -> true;
is_quit(_Event) -> false.

%% Move the selection for a navigation key, toggle the sort on `s'; ignore
%% anything else. The row count is passed to sonde_table so it can clamp at the
%% ends.
-spec fold(sonde_input:event(), state()) -> state().
fold({key, up, _Mods}, State) ->
    move_prev(State);
fold({key, {char, $k}, _Mods}, State) ->
    move_prev(State);
fold({key, down, _Mods}, State) ->
    move_next(State);
fold({key, {char, $j}, _Mods}, State) ->
    move_next(State);
fold({key, home, _Mods}, #demo{table = Table} = State) ->
    State#demo{table = sonde_table:select(Table, 0)};
fold({key, 'end', _Mods}, #demo{rows = Rows, table = Table} = State) ->
    State#demo{table = sonde_table:select(Table, length(Rows) - 1)};
fold({key, {char, $s}, _Mods}, #demo{sort = Sort} = State) ->
    State#demo{sort = sonde_table:toggle_sort(Sort, ?SORT_COL)};
fold(_Event, State) ->
    State.

-spec move_prev(state()) -> state().
move_prev(#demo{rows = Rows, table = Table} = State) ->
    State#demo{table = sonde_table:prev(Table, length(Rows))}.

-spec move_next(state()) -> state().
move_next(#demo{rows = Rows, table = Table} = State) ->
    State#demo{table = sonde_table:next(Table, length(Rows))}.

%%% -- frame building --------------------------------------------------

%% @doc Render the demo into `Area' (the rect the shell allots it): a bordered
%% {@link sonde_block} framing a {@link sonde_paragraph} help line above a stateful,
%% sortable {@link sonde_table}. The rows are ordered by the current sort for
%% display; the canonical order in the state is untouched. Returns the buffer and
%% the updated state — the table may have adjusted its scroll offset to keep the
%% selection visible, and that adjustment must persist to the next frame.
-spec render(sonde_layout:rect(), sonde_render:buffer(), state()) ->
    {sonde_render:buffer(), state()}.
render(Area, Buf0, #demo{rows = Rows, table = Table0, sort = Sort} = State) ->
    Block = #{
        borders => all,
        title => <<" processes ">>,
        title_align => center,
        border_style => #{fg => 6},
        title_style => #{fg => 6, bold => true}
    },
    Buf1 = sonde_widget:render(sonde_block, Block, Area, Buf0),
    [HelpArea, TableArea] = sonde_layout:split(
        vertical, [{fixed, 2}, fill], sonde_block:inner(Block, Area)
    ),
    Help = #{
        text => <<"up/down or j/k to select    s to sort    q to quit">>,
        wrap => word,
        style => #{fg => 8}
    },
    Buf2 = sonde_widget:render(sonde_paragraph, Help, HelpArea, Buf1),
    TableCfg = #{
        columns => columns(),
        rows => sonde_table:apply_sort(Rows, Sort),
        header_style => #{fg => 6, bold => true},
        highlight_style => #{fg => 0, bg => 6, bold => true},
        highlight_symbol => <<"> ">>,
        sort => Sort
    },
    {Buf3, Table1} = sonde_table:render(TableCfg, TableArea, Buf2, Table0),
    {Buf3, State#demo{table = Table1}}.

%% @doc Render the pane full-screen for the given terminal size — the standalone
%% convenience the pure tests build frames through. Delegates to {@link render/3}
%% over the whole area on a fresh buffer.
-spec build_frame(sonde_term:size(), state()) -> {sonde_render:buffer(), state()}.
build_frame(Size, State) ->
    render(sonde_layout:area(Size), sonde_render:new(Size), State).

%% The process-table columns: a fixed-width pid, a filling name, and two
%% right-aligned numeric columns — the etop/observer shape.
-spec columns() -> [sonde_table:column()].
columns() ->
    [
        #{header => <<"PID">>, constraint => {fixed, 11}},
        #{header => <<"Name">>, constraint => fill},
        #{header => <<"Msgs">>, constraint => {fixed, 5}, align => right},
        #{header => <<"Mem (KB)">>, constraint => {fixed, 9}, align => right}
    ].

%% A fixed set of mock process rows — long enough that the table scrolls on a
%% normal terminal, so selection following the view is visible in the demo. The
%% names are real OTP/Sonde process names for flavour; the pids and counters are
%% fabricated but deterministic (so a headless test sees stable output).
-spec demo_rows() -> [sonde_table:row()].
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
        "sonde_agent",
        "sonde_core",
        "gen_event",
        "supervisor_bridge",
        "pg",
        "socket_registry"
    ],
    [demo_row(N, Name) || {N, Name} <- lists:zip(lists:seq(1, length(Names)), Names)].

-spec demo_row(pos_integer(), string()) -> sonde_table:row().
demo_row(N, Name) ->
    [
        iolist_to_binary(io_lib:format("<0.~b.0>", [N + 40])),
        list_to_binary(Name),
        integer_to_binary((N * 7) rem 13),
        integer_to_binary(64 + (N * 137) rem 4096)
    ].
