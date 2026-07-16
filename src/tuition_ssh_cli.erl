%%%-------------------------------------------------------------------
%%% @doc OTP ssh daemon CLI channel for hosting a tuition shell.
%%%
%%% Use this module as the daemon's custom `ssh_cli' callback:
%%%
%%% ```
%%% ssh:start(),
%%% {ok, Daemon} = ssh:daemon(Port, [
%%%     {system_dir, SystemDir},
%%%     {user_dir, UserDir},
%%%     {ssh_cli, {tuition_ssh_cli, [PaneSpecs, ShellOpts]}}
%%% ]).
%%% ```
%%%
%%% `PaneSpecs' is the same non-empty list passed to {@link tuition_shell:start/2}
%%% locally. The pane modules and {@link tuition_shell} do not learn about SSH;
%%% this channel callback starts one shell process per SSH shell request and
%%% injects {@link tuition_term_ssh} as the terminal backend.
%%%
%%% The channel process also brokers terminal backend calls because OTP ssh
%%% delivers input, pty and resize information asynchronously, while
%%% {@link tuition_term} exposes synchronous `read'/`write'/`size'/`close'
%%% callbacks.
%%% @end
%%%-------------------------------------------------------------------
-module(tuition_ssh_cli).
-behaviour(ssh_server_channel).

-export([init/1, handle_ssh_msg/2, handle_msg/2, terminate/2]).

-define(DEFAULT_SIZE, {80, 24}).
-define(MSG, tuition_ssh_term).
-define(READ_TIMEOUT, tuition_ssh_read_timeout).
-define(EXEC_ERROR_STATUS, 255).

-record(st, {
    pane_specs = [] :: [tuition_shell:pane_spec()],
    shell_opts = #{} :: map(),
    connection_mod = ssh_connection :: module(),
    cm = undefined :: undefined | pid(),
    channel_id = undefined :: undefined | integer(),
    size = ?DEFAULT_SIZE :: tuition_term:size(),
    input :: queue:queue(binary()),
    pending = none :: none | {pid(), reference(), undefined | reference()},
    eof = false :: boolean(),
    shell_pid = undefined :: undefined | pid(),
    shell_mon = undefined :: undefined | reference()
}).

-type state() :: #st{}.

%%% -- ssh_server_channel callbacks -----------------------------------

-spec init(term()) -> {ok, state()}.
init([PaneSpecs]) ->
    init([PaneSpecs, #{}]);
init([PaneSpecs, ShellOpts | _Extra]) when is_list(PaneSpecs), is_map(ShellOpts) ->
    {ok, #st{
        pane_specs = PaneSpecs,
        shell_opts = ShellOpts,
        connection_mod = maps:get(ssh_connection_mod, ShellOpts, ssh_connection),
        input = queue:new()
    }};
init([PaneSpecs | _Extra]) when is_list(PaneSpecs) ->
    init([PaneSpecs, #{}]).

-spec handle_ssh_msg(term(), state()) -> {ok, state()} | {stop, integer(), state()}.
handle_ssh_msg({ssh_cm, Cm, {pty, ChannelId, WantReply, {_Term, Width, Height, _PixW, _PixH, _Modes}}},
    State
) ->
    State1 = State#st{cm = Cm, channel_id = ChannelId, size = size(Width, Height)},
    _ = reply_request(WantReply, success, State1),
    {ok, State1};
handle_ssh_msg({ssh_cm, Cm, {shell, ChannelId, WantReply}}, State0) ->
    State1 = State0#st{cm = Cm, channel_id = ChannelId},
    case State1#st.shell_pid of
        undefined ->
            State2 = start_shell(State1),
            _ = reply_request(WantReply, success, State2),
            {ok, State2};
        _Pid ->
            _ = reply_request(WantReply, failure, State1),
            {ok, State1}
    end;
handle_ssh_msg({ssh_cm, Cm, {exec, ChannelId, WantReply, _Cmd}}, State0) ->
    State = State0#st{cm = Cm, channel_id = ChannelId},
    _ = reply_request(WantReply, failure, State),
    _ = finish_channel(?EXEC_ERROR_STATUS, State),
    {stop, ChannelId, State};
handle_ssh_msg({ssh_cm, Cm, {env, ChannelId, WantReply, _Var, _Value}}, State0) ->
    State = State0#st{cm = Cm, channel_id = ChannelId},
    _ = reply_request(WantReply, failure, State),
    {ok, State};
handle_ssh_msg({ssh_cm, _Cm, {data, _ChannelId, _Type, Data}}, State) ->
    {ok, deliver_input(iolist_to_binary(Data), State)};
handle_ssh_msg({ssh_cm, _Cm, {window_change, _ChannelId, Width, Height, _PixW, _PixH}}, State) ->
    {ok, State#st{size = size(Width, Height)}};
handle_ssh_msg({ssh_cm, _Cm, {eof, _ChannelId}}, State) ->
    {ok, mark_eof(State)};
handle_ssh_msg({ssh_cm, _Cm, {signal, _ChannelId, _Signal}}, State) ->
    {ok, State};
handle_ssh_msg({ssh_cm, _Cm, {exit_status, ChannelId, 0}}, State) ->
    {stop, ChannelId, State};
handle_ssh_msg({ssh_cm, _Cm, {exit_status, ChannelId, _Status}}, State) ->
    {stop, ChannelId, State};
handle_ssh_msg({ssh_cm, _Cm, {exit_signal, ChannelId, _Signal, _Error, _Lang}}, State) ->
    {stop, ChannelId, State};
handle_ssh_msg(_Msg, State) ->
    {ok, State}.

-spec handle_msg(term(), state()) -> {ok, state()} | {stop, integer(), state()}.
handle_msg({ssh_channel_up, ChannelId, Cm}, State) ->
    {ok, State#st{cm = Cm, channel_id = ChannelId}};
handle_msg({?MSG, From, Ref, Request}, State) ->
    handle_backend_request(From, Ref, Request, State);
handle_msg({?READ_TIMEOUT, Ref}, State) ->
    handle_read_timeout(Ref, State);
handle_msg({'DOWN', Mon, process, _Pid, Reason}, #st{shell_mon = Mon} = State) ->
    handle_shell_down(Reason, State);
handle_msg(_Msg, State) ->
    {ok, State}.

-spec terminate(term(), state()) -> term().
terminate(_Reason, #st{shell_pid = undefined}) ->
    ok;
terminate(_Reason, #st{shell_pid = Pid}) ->
    exit(Pid, shutdown),
    ok.

%%% -- shell lifecycle -------------------------------------------------

-spec start_shell(state()) -> state().
start_shell(#st{pane_specs = PaneSpecs, shell_opts = ShellOpts} = State) ->
    ChannelPid = self(),
    RunOpts = maps:merge(ShellOpts, #{
        backend => tuition_term_ssh,
        ssh_channel => ChannelPid
    }),
    {Pid, Mon} = spawn_monitor(fun() ->
        case tuition_shell:start(PaneSpecs, RunOpts) of
            ok -> ok;
            {error, Reason} -> exit({tuition_shell_error, Reason})
        end
    end),
    State#st{shell_pid = Pid, shell_mon = Mon}.

-spec handle_shell_down(term(), state()) -> {ok, state()} | {stop, integer(), state()}.
handle_shell_down(normal, #st{channel_id = ChannelId} = State) when is_integer(ChannelId) ->
    _ = finish_channel(0, State),
    {stop, ChannelId, clear_shell(State)};
handle_shell_down(_Reason, #st{channel_id = ChannelId} = State) when is_integer(ChannelId) ->
    _ = finish_channel(?EXEC_ERROR_STATUS, State),
    {stop, ChannelId, clear_shell(State)};
handle_shell_down(_Reason, State) ->
    {ok, clear_shell(State)}.

-spec clear_shell(state()) -> state().
clear_shell(#st{shell_mon = undefined} = State) ->
    State#st{shell_pid = undefined};
clear_shell(#st{shell_mon = Mon} = State) ->
    erlang:demonitor(Mon, [flush]),
    State#st{shell_pid = undefined, shell_mon = undefined}.

%%% -- backend request broker -----------------------------------------

-spec handle_backend_request(pid(), reference(), term(), state()) ->
    {ok, state()} | {stop, integer(), state()}.
handle_backend_request(From, Ref, {read, Timeout}, #st{input = Input0} = State) ->
    case queue:out(Input0) of
        {{value, Data}, Input} ->
            reply(From, Ref, {ok, Data}),
            {ok, State#st{input = Input}};
        {empty, _} when State#st.eof ->
            reply(From, Ref, {error, eof}),
            {ok, State};
        {empty, _} ->
            wait_for_input(From, Ref, Timeout, State)
    end;
handle_backend_request(From, Ref, {write, Data}, State) ->
    reply(From, Ref, send(Data, State)),
    {ok, State};
handle_backend_request(From, Ref, size, #st{size = Size} = State) ->
    reply(From, Ref, {ok, Size}),
    {ok, State};
handle_backend_request(From, Ref, close, #st{channel_id = ChannelId} = State) when
    is_integer(ChannelId)
->
    reply(From, Ref, ok),
    State1 = clear_shell(State),
    _ = finish_channel(0, State1),
    {stop, ChannelId, State1};
handle_backend_request(From, Ref, close, State) ->
    reply(From, Ref, ok),
    {ok, clear_shell(State)};
handle_backend_request(From, Ref, _Other, State) ->
    reply(From, Ref, {error, bad_ssh_backend_request}),
    {ok, State}.

-spec wait_for_input(pid(), reference(), timeout(), state()) -> {ok, state()}.
wait_for_input(From, Ref, 0, #st{pending = none} = State) ->
    reply(From, Ref, timeout),
    {ok, State};
wait_for_input(From, Ref, infinity, #st{pending = none} = State) ->
    {ok, State#st{pending = {From, Ref, undefined}}};
wait_for_input(From, Ref, Timeout, #st{pending = none} = State) ->
    Timer = erlang:send_after(Timeout, self(), {?READ_TIMEOUT, Ref}),
    {ok, State#st{pending = {From, Ref, Timer}}};
wait_for_input(From, Ref, _Timeout, State) ->
    reply(From, Ref, {error, read_already_pending}),
    {ok, State}.

-spec handle_read_timeout(reference(), state()) -> {ok, state()}.
handle_read_timeout(Ref, #st{pending = {From, Ref, _Timer}} = State) ->
    reply(From, Ref, timeout),
    {ok, State#st{pending = none}};
handle_read_timeout(_Ref, State) ->
    {ok, State}.

-spec deliver_input(binary(), state()) -> state().
deliver_input(Data, #st{pending = {From, Ref, Timer}} = State) ->
    cancel_timer(Timer),
    reply(From, Ref, {ok, Data}),
    State#st{pending = none};
deliver_input(Data, #st{input = Input} = State) ->
    State#st{input = queue:in(Data, Input)}.

-spec mark_eof(state()) -> state().
mark_eof(#st{pending = {From, Ref, Timer}} = State) ->
    cancel_timer(Timer),
    reply(From, Ref, {error, eof}),
    State#st{pending = none, eof = true};
mark_eof(State) ->
    State#st{eof = true}.

-spec cancel_timer(undefined | reference()) -> ok.
cancel_timer(undefined) ->
    ok;
cancel_timer(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.

-spec reply(pid(), reference(), term()) -> ok.
reply(To, Ref, Reply) ->
    To ! {?MSG, Ref, Reply},
    ok.

%%% -- SSH operations --------------------------------------------------

-spec reply_request(boolean(), success | failure, state()) -> ok | {error, term()}.
reply_request(false, _Status, _State) ->
    ok;
reply_request(true, Status, #st{connection_mod = Mod, cm = Cm, channel_id = ChannelId}) ->
    ssh_call(fun() -> Mod:reply_request(Cm, true, Status, ChannelId) end).

-spec send(binary(), state()) -> ok | {error, term()}.
send(Data, #st{connection_mod = Mod, cm = Cm, channel_id = ChannelId}) ->
    ssh_call(fun() -> Mod:send(Cm, ChannelId, Data) end).

-spec finish_channel(non_neg_integer(), state()) -> ok | {error, term()}.
finish_channel(Status, #st{connection_mod = Mod, cm = Cm, channel_id = ChannelId}) ->
    case ssh_call(fun() -> Mod:send_eof(Cm, ChannelId) end) of
        ok -> ssh_call(fun() -> Mod:exit_status(Cm, ChannelId, Status) end);
        {error, _} = Error -> Error
    end.

-spec ssh_call(fun(() -> term())) -> ok | {error, term()}.
ssh_call(Fun) ->
    try Fun() of
        ok -> ok;
        Other -> Other
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

%%% -- helpers ---------------------------------------------------------

-spec size(integer(), integer()) -> tuition_term:size().
size(Width, Height) ->
    {not_zero(Width, 80), not_zero(Height, 24)}.

-spec not_zero(integer(), pos_integer()) -> pos_integer().
not_zero(0, Default) -> Default;
not_zero(N, _Default) when N > 0 -> N.
