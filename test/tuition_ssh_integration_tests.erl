-module(tuition_ssh_integration_tests).

-include_lib("eunit/include/eunit.hrl").

-define(USER, "tuition-test").
-define(TIMEOUT, 5000).

real_ssh_daemon_hosts_shell_test() ->
    {ok, _Apps} = application:ensure_all_started(ssh),
    SystemDir = make_system_dir(),
    ok = write_host_key(SystemDir),
    Panes = [{tuition_shell_pane_a, <<"Alpha">>}],
    DaemonOpts = [
        {system_dir, SystemDir},
        {user_dir, SystemDir},
        {no_auth_needed, true},
        {ssh_cli, {tuition_ssh_cli, [Panes, #{}]}}
    ],
    {ok, Daemon} = ssh:daemon({127, 0, 0, 1}, 0, DaemonOpts),
    try
        {port, Port} = ssh:daemon_info(Daemon, port),
        {ok, Conn, Channel} = connect_shell(Port, SystemDir),
        try
            Frames0 = recv_until(Conn, Channel, <<"alpha body">>, <<>>, ?TIMEOUT),
            ?assertMatch({_, _}, binary:match(Frames0, <<"alpha body">>)),
            ok = ssh_connection:window_change(Conn, Channel, 42, 9),
            ok = ssh_connection:send(Conn, Channel, <<"q">>),
            {Frames, Events} = recv_until_closed(Conn, Channel, Frames0, [], ?TIMEOUT),
            ?assertMatch({_, _}, binary:match(Frames, <<"alpha body">>)),
            ?assert(lists:member(eof, Events)),
            ?assert(lists:member({exit_status, 0}, Events))
        after
            _ = ssh:close(Conn)
        end
    after
        _ = ssh:stop_daemon(Daemon),
        _ = file:del_dir_r(SystemDir)
    end.

%%% -- SSH client ------------------------------------------------------

connect_shell(Port, UserDir) ->
    ClientOpts = [
        {user, ?USER},
        {user_dir, UserDir},
        {silently_accept_hosts, true},
        {save_accepted_host, false},
        {user_interaction, false}
    ],
    {ok, Conn} = ssh:connect({127, 0, 0, 1}, Port, ClientOpts, ?TIMEOUT),
    {ok, Channel} = ssh_connection:session_channel(Conn, ?TIMEOUT),
    success = ssh_connection:ptty_alloc(
        Conn,
        Channel,
        [{term, "xterm-256color"}, {width, 40}, {height, 8}, {pty_opts, [{echo, 0}]}],
        ?TIMEOUT
    ),
    ok = ssh_connection:shell(Conn, Channel),
    {ok, Conn, Channel}.

recv_until(Conn, Channel, Needle, Acc, Timeout) ->
    receive
        {ssh_cm, Conn, {data, Channel, _Type, Data}} ->
            ok = ssh_connection:adjust_window(Conn, Channel, byte_size(Data)),
            Acc1 = <<Acc/binary, Data/binary>>,
            case binary:match(Acc1, Needle) of
                nomatch -> recv_until(Conn, Channel, Needle, Acc1, Timeout);
                {_, _} -> Acc1
            end;
        {ssh_cm, Conn, {eof, Channel}} ->
            error({unexpected_eof, Acc});
        {ssh_cm, Conn, {exit_status, Channel, Status}} ->
            error({unexpected_exit_status, Status, Acc});
        {ssh_cm, Conn, {closed, Channel}} ->
            error({unexpected_closed, Acc})
    after Timeout ->
        error({timeout_waiting_for_ssh_data, Needle, Acc})
    end.

recv_until_closed(Conn, Channel, Frames, Events, Timeout) ->
    receive
        {ssh_cm, Conn, {data, Channel, _Type, Data}} ->
            ok = ssh_connection:adjust_window(Conn, Channel, byte_size(Data)),
            recv_until_closed(Conn, Channel, <<Frames/binary, Data/binary>>, Events, Timeout);
        {ssh_cm, Conn, {eof, Channel}} ->
            recv_until_closed(Conn, Channel, Frames, [eof | Events], Timeout);
        {ssh_cm, Conn, {exit_status, Channel, Status}} ->
            recv_until_closed(Conn, Channel, Frames, [{exit_status, Status} | Events], Timeout);
        {ssh_cm, Conn, {closed, Channel}} ->
            {Frames, [closed | Events]}
    after Timeout ->
        error({timeout_waiting_for_ssh_close, Events})
    end.

%%% -- temporary host key ---------------------------------------------

make_system_dir() ->
    Base = os:getenv("TMPDIR", "/tmp"),
    make_system_dir(Base, 10).

make_system_dir(Base, Attempts) when Attempts > 0 ->
    Suffix = integer_to_list(erlang:unique_integer([monotonic, positive])),
    Path = filename:join(Base, "tuition-ssh-" ++ Suffix),
    case file:make_dir(Path) of
        ok ->
            ok = file:change_mode(Path, 8#700),
            Path;
        {error, eexist} ->
            make_system_dir(Base, Attempts - 1)
    end.

write_host_key(SystemDir) ->
    Key = public_key:generate_key({rsa, 2048, 65537}),
    Pem = public_key:pem_encode([public_key:pem_entry_encode('RSAPrivateKey', Key)]),
    Path = filename:join(SystemDir, "ssh_host_rsa_key"),
    ok = file:write_file(Path, Pem),
    ok = file:change_mode(Path, 8#600).
