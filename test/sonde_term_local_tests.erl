-module(sonde_term_local_tests).

-include_lib("eunit/include/eunit.hrl").

%% In a headless test environment there is no controlling tty, so
%% shell:start_interactive({noshell, raw}) returns {error, enotsup} (not `ok'
%% and not `already_started'). open/1 must surface that as a clean error tuple
%% rather than crashing or leaking a raw terminal. The live `already_started' ->
%% cooperative branch cannot be reached without a real shell owning the tty and
%% is covered by the pty live-verification harness (see the PR body), not here.
open_without_tty_errors_test() ->
    ?assertMatch({error, _}, sonde_term_local:open(#{})).

%% Cooperative submode: saved_opts/2 captures exactly the keys that submode
%% overrides — echo/binary/encoding — from the device. It must NOT capture the
%% whole io:getopts/1 list: restoring that back fails atomically on keys like
%% `onlcr' (which setopts rejects with enotsup) and would strand echo off. So
%% `onlcr'/`expand_fun' present in getopts must be dropped, and `echo' captured.
saved_opts_cooperative_captures_echo_binary_encoding_test() ->
    Io = sonde_fake_io:start(#{
        getopts => [
            {echo, true},
            {binary, false},
            {encoding, unicode},
            {onlcr, true},
            {expand_fun, some_fun}
        ]
    }),
    try
        ?assertEqual(
            [{echo, true}, {binary, false}, {encoding, unicode}],
            sonde_term_local:saved_opts(Io, [{echo, false}, binary, {encoding, latin1}])
        )
    after
        sonde_fake_io:stop(Io)
    end.

%% Noshell submode: its SetOpts overrides only binary/encoding (echo is left to
%% raw mode), so saved_opts/2 must NOT capture `echo' — otherwise restore would
%% reapply a raw-mode echo value after the {noshell, cooked} teardown and undo
%% the cooked-mode echo restore, regressing the escript path. Regression guard
%% for the Codex P2 on the previously byte-identical noshell restore.
saved_opts_noshell_omits_echo_test() ->
    Io = sonde_fake_io:start(#{
        getopts => [{echo, false}, {binary, false}, {encoding, unicode}, {onlcr, true}]
    }),
    try
        ?assertEqual(
            [{binary, false}, {encoding, unicode}],
            sonde_term_local:saved_opts(Io, [binary, {encoding, latin1}])
        )
    after
        sonde_fake_io:stop(Io)
    end.

%% saved_opts/2 falls back to sensible defaults when a device does not report a
%% key (a minimal io server), so restore never crashes on a missing opt.
saved_opts_defaults_when_absent_test() ->
    Io = sonde_fake_io:start(#{getopts => []}),
    try
        ?assertEqual(
            [{echo, false}, {binary, false}, {encoding, unicode}],
            sonde_term_local:saved_opts(Io, [{echo, false}, binary, {encoding, latin1}])
        )
    after
        sonde_fake_io:stop(Io)
    end.

%% The reader targets the DEVICE it is given (the group leader in the cooperative
%% submode, not `user') and forwards each scripted read to the owner as a
%% {data, Bytes} message — proving the device is parameterised and the per-byte
%% forwarding contract holds. Non-binary (list) reads are normalised to a binary.
reader_forwards_device_reads_test() ->
    Io = sonde_fake_io:start(#{chars => [<<"a">>, "b", <<27>>]}),
    Owner = self(),
    Reader = spawn(sonde_term_local, reader_loop, [Owner, Io]),
    try
        ?assertEqual(<<"a">>, recv_data(Reader)),
        ?assertEqual(<<"b">>, recv_data(Reader)),
        ?assertEqual(<<27>>, recv_data(Reader)),
        %% Script exhausted -> eof, and the reader stops (eof, not data).
        ?assertEqual(eof, recv_end(Reader))
    after
        sonde_fake_io:stop(Io)
    end.

%% A read error is forwarded verbatim and stops the reader, so read/2 can surface
%% it (e.g. the enotsup a mistargeted device would return).
reader_forwards_error_and_stops_test() ->
    Io = sonde_fake_io:start(#{chars => [{error, enotsup}]}),
    Owner = self(),
    Reader = spawn(sonde_term_local, reader_loop, [Owner, Io]),
    try
        ?assertEqual({error, enotsup}, recv_end(Reader))
    after
        sonde_fake_io:stop(Io)
    end.

%% The cooperative-submode restore (ReleaseRaw = false) writes the ANSI restore
%% payload to the device and puts back exactly the saved opts (re-enabling echo),
%% and does NOT touch global raw mode. Asserting the recorded io effects proves
%% the live shell's echo/screen are returned to pristine without a start_interactive
%% teardown that would fight the shell for the tty.
cooperative_restore_writes_seq_and_restores_opts_test() ->
    Io = sonde_fake_io:start(#{}),
    Prev = [{echo, true}, {binary, false}, {encoding, unicode}],
    Seq = <<"\e[0m\e[?25h\e[?1049l\r\n">>,
    try
        ?assertEqual(ok, sonde_term_local:do_restore(Io, Seq, Prev, false)),
        #{puts := Puts, setopts := SetOpts} = sonde_fake_io:recorded(Io),
        ?assertEqual([Seq], Puts),
        ?assertEqual([Prev], SetOpts)
    after
        sonde_fake_io:stop(Io)
    end.

%%% -- helpers ---------------------------------------------------------

recv_data(Reader) ->
    receive
        {sonde_term_local, Reader, {data, Bytes}} -> Bytes
    after 1000 -> error(no_data)
    end.

recv_end(Reader) ->
    receive
        {sonde_term_local, Reader, eof} -> eof;
        {sonde_term_local, Reader, {error, Reason}} -> {error, Reason}
    after 1000 -> error(no_end)
    end.
