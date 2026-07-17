%%% A stub pane seeded through `new/1' rather than `new/0' — the parameterised
%%% half of the pane contract, which the shell reaches via a `{Module, Title,
%%% Arg}' pane spec. All behaviour lives in {@link tuition_shell_stub_pane}; this
%%% module differs from {@link tuition_shell_pane_a} only in taking its tag from
%%% the spec instead of fixing one, so a test can assert the arg actually reached
%%% the pane by reading the tag back out of the rendered body.
-module(tuition_shell_arg_pane).
-behaviour(tuition_pane).

-export([new/1, render/3, apply_events/2, sample/1, selection/1, rows/1]).

new(Tag) -> tuition_shell_stub_pane:new(Tag).
render(Area, Buf, St) -> tuition_shell_stub_pane:render(Area, Buf, St).
apply_events(Events, St) -> tuition_shell_stub_pane:apply_events(Events, St).
sample(St) -> tuition_shell_stub_pane:sample(St).
selection(St) -> tuition_shell_stub_pane:selection(St).
rows(St) -> tuition_shell_stub_pane:rows(St).
