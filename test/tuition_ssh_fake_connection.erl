%%% Test-only stand-in for ssh_connection. It records channel operations by
%%% sending messages to the fake connection ref, which the tests make their own
%%% process.
-module(tuition_ssh_fake_connection).

-export([reply_request/4, send/3, send_eof/2, exit_status/3]).

reply_request(Sink, WantReply, Status, ChannelId) ->
    Sink ! {?MODULE, reply_request, ChannelId, WantReply, Status},
    ok.

send(Sink, ChannelId, Data) ->
    Sink ! {?MODULE, send, ChannelId, iolist_to_binary(Data)},
    ok.

send_eof(Sink, ChannelId) ->
    Sink ! {?MODULE, send_eof, ChannelId},
    ok.

exit_status(Sink, ChannelId, Status) ->
    Sink ! {?MODULE, exit_status, ChannelId, Status},
    ok.

