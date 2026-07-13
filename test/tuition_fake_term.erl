%%% Test-only backend: replays a scripted list of {@link tuition_term:read/2}
%%% results so the driver's read/parse/flush wiring can be exercised without a
%%% tty. Each read pops the next scripted result; an exhausted script yields
%%% `timeout' (as a quiet real terminal would).
-module(tuition_fake_term).

-export([start/1, read/2, loop/1]).

%% Returns an opaque state usable as the handle in {tuition_fake_term, State}.
-spec start([term()]) -> pid().
start(Script) ->
    spawn(?MODULE, loop, [Script]).

-spec read(pid(), timeout()) -> term().
read(Pid, _Timeout) ->
    Pid ! {next, self()},
    receive
        {Pid, Result} -> Result
    end.

-spec loop([term()]) -> ok.
loop(Script) ->
    receive
        {next, From} ->
            case Script of
                [Result | Rest] ->
                    From ! {self(), Result},
                    loop(Rest);
                [] ->
                    From ! {self(), timeout},
                    loop([])
            end
    end.
