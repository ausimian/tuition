%%% Test-only io server implementing enough of the Erlang io protocol to drive
%%% sonde_term_local's device-facing logic headlessly (no tty). Real `io'
%%% functions (`io:getopts/1', `io:setopts/2', `io:put_chars/2', the
%%% `{get_chars, …}' request the reader issues) are exercised against it exactly
%%% as they would be against a `user'/group-leader device.
%%%
%%%   * `getopts'  — the proplist configured under the `getopts' key.
%%%   * `setopts'  — recorded (each Opts list), replying `ok'.
%%%   * `put_chars'— recorded (flattened to a binary), replying `ok'.
%%%   * `get_chars'— pops the next scripted result from the `chars' key
%%%                  (a binary/list, `eof', or `{error, Reason}'); an exhausted
%%%                  script yields `eof'.
-module(sonde_fake_io).

-export([start/1, recorded/1, stop/1, loop/1]).

%% Config: #{getopts => proplist(), chars => [binary() | list() | eof | {error, term()}]}
-spec start(map()) -> pid().
start(Config) ->
    spawn(?MODULE, loop, [#{cfg => Config, puts => [], setopts => []}]).

%% Return #{puts => [binary()], setopts => [Opts]} in the order they arrived.
-spec recorded(pid()) -> map().
recorded(Pid) ->
    Pid ! {recorded, self()},
    receive
        {Pid, Rec} -> Rec
    after 1000 -> error(fake_io_timeout)
    end.

-spec stop(pid()) -> ok.
stop(Pid) ->
    Pid ! stop,
    ok.

-spec loop(map()) -> ok.
loop(S) ->
    receive
        {io_request, From, ReplyAs, Req} ->
            {Reply, S1} = handle(Req, S),
            From ! {io_reply, ReplyAs, Reply},
            loop(S1);
        {recorded, From} ->
            From !
                {self(), #{
                    puts => lists:reverse(maps:get(puts, S)),
                    setopts => lists:reverse(maps:get(setopts, S))
                }},
            loop(S);
        stop ->
            ok
    end.

-spec handle(term(), map()) -> {term(), map()}.
handle(getopts, S) ->
    {maps:get(getopts, maps:get(cfg, S), []), S};
handle({setopts, Opts}, S) ->
    {ok, S#{setopts => [Opts | maps:get(setopts, S)]}};
handle({put_chars, _Enc, Chars}, S) ->
    {ok, record_put(Chars, S)};
handle({put_chars, _Enc, M, F, A}, S) ->
    {ok, record_put(apply(M, F, A), S)};
handle({get_chars, _Enc, _Prompt, _N}, S) ->
    next_char(S);
handle({get_line, _Enc, _Prompt}, S) ->
    next_char(S);
handle(_Other, S) ->
    {{error, request}, S}.

-spec next_char(map()) -> {term(), map()}.
next_char(S) ->
    Cfg = maps:get(cfg, S),
    case maps:get(chars, Cfg, []) of
        [H | T] -> {H, S#{cfg => Cfg#{chars => T}}};
        [] -> {eof, S}
    end.

-spec record_put(iodata(), map()) -> map().
record_put(Chars, S) ->
    S#{puts => [iolist_to_binary(Chars) | maps:get(puts, S)]}.
