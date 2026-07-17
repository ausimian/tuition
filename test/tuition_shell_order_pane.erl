%%% Test-only pane that logs its {@link tuition_pane:setup/0} / {@link
%%% tuition_pane:teardown/1} calls, so a test can assert the shell acquires and
%%% releases pane resources in the right order without depending on any real
%%% resource's semantics. `setup/0' stamps a monotonically increasing sequence
%%% number (its resource token) and logs `{setup, N}'; `teardown/1' logs
%%% `{teardown, N}' for the token it is handed. The log lives in the process
%%% dictionary — the shell runs synchronously in the caller, so the caller reads it
%%% back. The render/input callbacks are trivial stubs.
-module(tuition_shell_order_pane).
-behaviour(tuition_pane).

-export([new/0, new/1, render/3, apply_events/2, sample/1, setup/0, teardown/1]).

%% Seeded either way — a plain `{Module, Title}' spec calls `new/0', a
%% parameterised `{Module, Title, Arg}' one calls `new/1' — so the lifecycle tests
%% can assert setup/teardown runs for both spec shapes through the one stub.
new() -> undefined.
new(_Arg) -> undefined.
render(_Area, Buf, State) -> {Buf, State}.
apply_events(_Events, State) -> {ok, State}.
sample(State) -> State.

setup() ->
    N =
        case get(tuition_pane_lifecycle_seq) of
            undefined -> 1;
            Seq -> Seq + 1
        end,
    put(tuition_pane_lifecycle_seq, N),
    log({setup, N}),
    N.

teardown(N) ->
    log({teardown, N}),
    ok.

log(Event) ->
    put(tuition_pane_lifecycle, [Event | current()]).

current() ->
    case get(tuition_pane_lifecycle) of
        undefined -> [];
        L -> L
    end.
