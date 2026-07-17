-module(tuition_term_ssh).
-moduledoc """
The terminal backend for an SSH channel.

`m:tuition_ssh_cli` opens this backend; an application never opens it directly.
The SSH channel callback owns the channel process and brokers between OTP ssh's
asynchronous channel messages and the pull-style `m:tuition_term` callbacks the
shell already uses:

- `read/2` waits for bytes delivered by SSH `data` messages.
- `write/2` sends rendered ANSI bytes over the SSH channel.
- `size/1` reads the latest pty/window-change size.
- `close/1` asks the channel to send eof/exit-status and stop.

The shell and pane contracts are unchanged. A host selects this backend by
running the shell through `m:tuition_ssh_cli`, which injects the private
`ssh_channel` option during session startup.
""".
-behaviour(tuition_term).

-export([open/1, write/2, read/2, size/1, close/1]).

-define(MSG, tuition_ssh_term).
-define(CLOSE_TIMEOUT, 5000).

-record(st, {
    channel :: pid()
}).
-opaque state() :: #st{}.
-export_type([state/0]).

%%% -- tuition_term callbacks -----------------------------------------

-doc false.
-spec open(map()) -> {ok, state()} | {error, term()}.
open(#{ssh_channel := Channel}) when is_pid(Channel) ->
    {ok, #st{channel = Channel}};
open(_Opts) ->
    {error, missing_ssh_channel}.

-doc false.
-spec write(state(), iodata()) -> ok | {error, term()}.
write(#st{channel = Channel}, Data) ->
    case to_binary(Data) of
        {ok, Bin} -> call(Channel, {write, Bin}, infinity);
        {error, _} = Error -> Error
    end.

-doc false.
-spec read(state(), timeout()) -> {ok, binary()} | timeout | {error, term()}.
read(#st{channel = Channel}, Timeout) ->
    call(Channel, {read, Timeout}, infinity).

-doc false.
-spec size(state()) -> {ok, tuition_term:size()} | {error, term()}.
size(#st{channel = Channel}) ->
    call(Channel, size, infinity).

-doc false.
-spec close(state()) -> ok.
close(#st{channel = Channel}) ->
    case call(Channel, close, ?CLOSE_TIMEOUT) of
        ok -> ok;
        {error, _} -> ok
    end.

%%% -- broker call helper ---------------------------------------------

-spec call(pid(), term(), timeout()) -> term().
call(Channel, Request, Timeout) ->
    Ref = make_ref(),
    Mon = erlang:monitor(process, Channel),
    Channel ! {?MSG, self(), Ref, Request},
    receive
        {?MSG, Ref, Reply} ->
            erlang:demonitor(Mon, [flush]),
            Reply;
        {'DOWN', Mon, process, Channel, Reason} ->
            {error, {ssh_channel_down, Reason}}
    after Timeout ->
        erlang:demonitor(Mon, [flush]),
        {error, timeout}
    end.

-spec to_binary(iodata()) -> {ok, binary()} | {error, non_byte_payload}.
to_binary(Data) ->
    try iolist_to_binary(Data) of
        Bin -> {ok, Bin}
    catch
        error:badarg -> {error, non_byte_payload}
    end.
