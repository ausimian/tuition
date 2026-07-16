-module(tuition_ssh_cli_tests).

-include_lib("eunit/include/eunit.hrl").

-define(CHANNEL, 7).
-define(CONN, self()).

term_ssh_requires_channel_test() ->
    ?assertEqual({error, missing_ssh_channel}, tuition_term_ssh:open(#{})).

ssh_cli_brokers_backend_calls_test() ->
    Cli = start_cli([]),
    Cli ! {ssh_channel_up, ?CHANNEL, ?CONN},
    Cli ! {inject_ssh, pty(33, 9)},
    assertEvent({tuition_ssh_fake_connection, reply_request, ?CHANNEL, true, success}),

    {ok, Term} = tuition_term_ssh:open(#{ssh_channel => Cli}),
    ?assertEqual({ok, {33, 9}}, tuition_term_ssh:size(Term)),
    ?assertEqual(timeout, tuition_term_ssh:read(Term, 10)),

    Cli ! {inject_ssh, data(<<"abc">>)},
    ?assertEqual({ok, <<"abc">>}, tuition_term_ssh:read(Term, 10)),
    Cli ! {inject_ssh, data(<<"tail">>)},
    Cli ! {inject_ssh, eof()},
    ?assertEqual({ok, <<"tail">>}, tuition_term_ssh:read(Term, 10)),
    ?assertEqual({error, eof}, tuition_term_ssh:read(Term, 10)),

    Cli ! {inject_ssh, window_change(44, 12)},
    ?assertEqual({ok, {44, 12}}, tuition_term_ssh:size(Term)),

    ?assertEqual(ok, tuition_term_ssh:write(Term, <<"out">>)),
    assertEvent({tuition_ssh_fake_connection, send, ?CHANNEL, <<"out">>}),

    ?assertEqual(ok, tuition_term_ssh:close(Term)),
    assertEvent({tuition_ssh_fake_connection, send_eof, ?CHANNEL}),
    assertEvent({tuition_ssh_fake_connection, exit_status, ?CHANNEL, 0}),
    assertEvent({ssh_cli_harness, stopped, ?CHANNEL}).

ssh_cli_hosts_existing_shell_pane_test() ->
    Panes = [{tuition_shell_pane_a, <<"Alpha">>}],
    Cli = start_cli(Panes),
    Cli ! {ssh_channel_up, ?CHANNEL, ?CONN},
    Cli ! {inject_ssh, pty(32, 6)},
    Cli ! {inject_ssh, shell()},
    Cli ! {inject_ssh, data(<<"q">>)},

    {Frames, Events} = drain_until_stopped(<<>>, []),
    ?assertMatch({_, _}, binary:match(Frames, <<"alpha body">>)),
    ?assert(lists:member({reply_request, success}, Events)),
    ?assert(lists:member(send_eof, Events)),
    ?assert(lists:member({exit_status, 0}, Events)).

%%% -- harness ---------------------------------------------------------

start_cli(Panes) ->
    Test = self(),
    spawn_link(fun() ->
        Opts = #{ssh_connection_mod => tuition_ssh_fake_connection},
        {ok, State} = tuition_ssh_cli:init([Panes, Opts]),
        loop(Test, State)
    end).

loop(Test, State) ->
    receive
        {inject_ssh, Event} ->
            continue(Test, tuition_ssh_cli:handle_ssh_msg(Event, State));
        Msg ->
            continue(Test, tuition_ssh_cli:handle_msg(Msg, State))
    end.

continue(Test, {ok, State}) ->
    loop(Test, State);
continue(Test, {stop, ChannelId, State}) ->
    tuition_ssh_cli:terminate(normal, State),
    Test ! {ssh_cli_harness, stopped, ChannelId},
    ok.

drain_until_stopped(Frames, Events) ->
    receive
        {tuition_ssh_fake_connection, send, ?CHANNEL, Bin} ->
            drain_until_stopped(<<Frames/binary, Bin/binary>>, Events);
        {tuition_ssh_fake_connection, reply_request, ?CHANNEL, _WantReply, Status} ->
            drain_until_stopped(Frames, [{reply_request, Status} | Events]);
        {tuition_ssh_fake_connection, send_eof, ?CHANNEL} ->
            drain_until_stopped(Frames, [send_eof | Events]);
        {tuition_ssh_fake_connection, exit_status, ?CHANNEL, Status} ->
            drain_until_stopped(Frames, [{exit_status, Status} | Events]);
        {ssh_cli_harness, stopped, ?CHANNEL} ->
            {Frames, Events}
    after 1000 ->
        error(timeout_waiting_for_ssh_cli_harness)
    end.

%%% -- SSH event builders ---------------------------------------------

pty(Width, Height) ->
    {ssh_cm, ?CONN, {pty, ?CHANNEL, true, {"xterm-256color", Width, Height, 0, 0, []}}}.

shell() ->
    {ssh_cm, ?CONN, {shell, ?CHANNEL, true}}.

data(Bytes) ->
    {ssh_cm, ?CONN, {data, ?CHANNEL, 0, Bytes}}.

window_change(Width, Height) ->
    {ssh_cm, ?CONN, {window_change, ?CHANNEL, Width, Height, 0, 0}}.

eof() ->
    {ssh_cm, ?CONN, {eof, ?CHANNEL}}.

assertEvent(Expected) ->
    receive
        Expected -> ok
    after 1000 ->
        error({missing_event, Expected})
    end.
