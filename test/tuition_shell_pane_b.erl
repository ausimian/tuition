%%% Second stub pane for the shell tests — draws "beta body". See {@link
%%% tuition_shell_pane_a}; identical but for the tag.
-module(tuition_shell_pane_b).
-behaviour(tuition_pane).

-export([new/0, render/3, apply_events/2, sample/1, selection/1, rows/1]).

new() -> tuition_shell_stub_pane:new(<<"beta">>).
render(Area, Buf, St) -> tuition_shell_stub_pane:render(Area, Buf, St).
apply_events(Events, St) -> tuition_shell_stub_pane:apply_events(Events, St).
sample(St) -> tuition_shell_stub_pane:sample(St).
selection(St) -> tuition_shell_stub_pane:selection(St).
rows(St) -> tuition_shell_stub_pane:rows(St).
