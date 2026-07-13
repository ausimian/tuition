%%% Test-only terminal backend for exercising tuition_caps:probe/2 without a tty.
%%% It records everything written (so a test can assert the probe emitted the
%%% right query sequences) and replays a scripted list of {@link tuition_term:read/2}
%%% results (the terminal's replies); an exhausted script yields `timeout', as a
%%% quiet terminal would. `write/2' returns a configurable result so the
%%% write-failure path is testable too. Use as the handle `{tuition_probe_term, Pid}'.
-module(tuition_probe_term).

-export([start/1, start/2, write/2, read/2, sent/1, loop/3]).

%% Start a backend serving `Script' (a list of read results) whose writes
%% succeed. Returns the pid to wrap in a {tuition_probe_term, Pid} handle.
-spec start([term()]) -> pid().
start(Script) ->
    start(Script, ok).

%% As start/1, but every write returns `WriteResult' (e.g. `{error, closed}' to
%% drive the probe's write-failure path).
-spec start([term()], ok | {error, term()}) -> pid().
start(Script, WriteResult) ->
    spawn(?MODULE, loop, [Script, <<>>, WriteResult]).

%% Record the write (synchronously, so it is captured before the following read)
%% and report the configured result.
-spec write(pid(), iodata()) -> ok | {error, term()}.
write(Pid, Data) ->
    Pid ! {write, self(), iolist_to_binary(Data)},
    receive
        {Pid, Result} -> Result
    end.

-spec read(pid(), timeout()) -> term().
read(Pid, _Timeout) ->
    Pid ! {read, self()},
    receive
        {Pid, Result} -> Result
    end.

%% Everything written to the backend so far (only successful writes), for
%% asserting on the emitted queries.
-spec sent(pid()) -> binary().
sent(Pid) ->
    Pid ! {sent, self()},
    receive
        {Pid, Bytes} -> Bytes
    end.

-spec loop([term()], binary(), ok | {error, term()}) -> ok.
loop(Script, Sent, WriteResult) ->
    receive
        {write, From, Data} ->
            From ! {self(), WriteResult},
            Sent1 =
                case WriteResult of
                    ok -> <<Sent/binary, Data/binary>>;
                    _ -> Sent
                end,
            loop(Script, Sent1, WriteResult);
        {read, From} ->
            case Script of
                [Result | Rest] ->
                    From ! {self(), Result},
                    loop(Rest, Sent, WriteResult);
                [] ->
                    From ! {self(), timeout},
                    loop([], Sent, WriteResult)
            end;
        {sent, From} ->
            From ! {self(), Sent},
            loop(Script, Sent, WriteResult)
    end.
