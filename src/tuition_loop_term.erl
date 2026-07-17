-module(tuition_loop_term).
-moduledoc """
Scripted terminal backend for driving a render/input loop headlessly,
with no tty. This is the framework's public test backend — ratatui's
`TestBackend` plays the same role: point any host that opens a `m:tuition_term` backend at it (`tuition_shell:start/2`, `tuition_demo:start/1`, or a pane test) and it replays a canned terminal so
the loop's output can be asserted byte-for-byte.

It reads its wiring from the `Opts` map the host passes straight through to
`open/1`:

  * `sink` — a pid every write and the final close are forwarded to, so a
               test can observe exactly what the loop emitted (`{write, Bin}`
               per write, then `closed`).
  * `size` — the terminal size reported to the loop. Either a single
               `{Cols, Rows}` tuple (constant, the default `{80, 24}`), or a
               list of sizes replayed one per `tuition_term:size/1` call
               with the last sticking — so a test can drive a resize by
               handing back a different size on a later poll.
  * `script` — a list of `tuition_term:read/2` results replayed one per
               read; an exhausted script yields `timeout`, as a quiet real
               terminal would. Every script MUST reach a quit key, or the loop
               spins forever.
  * `open` — an optional `{error, Reason}` that forces `open/1` to fail,
               exercising the host's backend-open error path.
""".
-behaviour(tuition_term).

-export([open/1, write/2, read/2, size/1, close/1]).
%% Internal, spawned functions.
-export([reader/1, sizer/1]).

-doc false.
open(#{open := {error, _} = Error}) ->
    Error;
open(Opts) ->
    Sink = maps:get(sink, Opts),
    Reader = spawn(?MODULE, reader, [maps:get(script, Opts, [])]),
    Sizer = spawn(?MODULE, sizer, [sizes(maps:get(size, Opts, {80, 24}))]),
    {ok, #{sink => Sink, sizer => Sizer, reader => Reader}}.

-doc false.
write(#{sink := Sink}, Data) ->
    Sink ! {write, iolist_to_binary(Data)},
    ok.

-doc false.
read(#{reader := Reader}, _Timeout) ->
    Reader ! {next, self()},
    receive
        {Reader, Result} -> Result
    end.

-doc false.
size(#{sizer := Sizer}) ->
    Sizer ! {next, self()},
    receive
        {Sizer, Size} -> {ok, Size}
    end.

-doc false.
close(#{sink := Sink, sizer := Sizer, reader := Reader}) ->
    Reader ! stop,
    Sizer ! stop,
    Sink ! closed,
    ok.

%% Normalise the `size' option into a non-empty list of sizes: a bare tuple is a
%% constant (a one-element list the sizer never advances past).
-spec sizes(tuition_term:size() | [tuition_term:size()]) -> [tuition_term:size()].
sizes({_Cols, _Rows} = Size) -> [Size];
sizes([_ | _] = List) -> List.

%% Serve one scripted size per `next', holding on the last once the list is down
%% to a single entry — so a constant size repeats and a resize sequence settles.
-doc false.
-spec sizer([tuition_term:size()]) -> ok.
sizer(Sizes) ->
    receive
        {next, From} ->
            case Sizes of
                [Size] ->
                    From ! {self(), Size},
                    sizer([Size]);
                [Size | Rest] ->
                    From ! {self(), Size},
                    sizer(Rest)
            end;
        stop ->
            ok
    end.

%% Serve one scripted read result per `next', then `timeout' forever once the
%% script is exhausted — reachable through the full backend behaviour
%% (open/write/size/close) the loop drives.
-doc false.
-spec reader([term()]) -> ok.
reader(Script) ->
    receive
        {next, From} ->
            case Script of
                [Result | Rest] ->
                    From ! {self(), Result},
                    reader(Rest);
                [] ->
                    From ! {self(), timeout},
                    reader([])
            end;
        stop ->
            ok
    end.
