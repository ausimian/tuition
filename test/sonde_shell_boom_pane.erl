%%% Test-only pane whose {@link sonde_pane:setup/0} raises, for exercising the
%%% shell's setup-crash cleanup path: hosting it after a pane that acquires a real
%%% resource proves the shell tears the earlier resource down and restores the
%%% terminal even though setup never completed. The render/input callbacks are never
%%% reached (setup raises first), so they are trivial stubs.
-module(sonde_shell_boom_pane).
-behaviour(sonde_pane).

-export([new/0, render/3, apply_events/2, sample/1, setup/0, teardown/1]).

new() -> undefined.
render(_Area, Buf, State) -> {Buf, State}.
apply_events(_Events, State) -> {ok, State}.
sample(State) -> State.

setup() -> error(boom).
teardown(_Token) -> ok.
