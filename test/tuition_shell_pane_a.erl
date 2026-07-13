%%% First stub pane for the shell tests — draws "alpha body". All behaviour lives
%%% in {@link tuition_shell_stub_pane}; this module only fixes the tag so the shell
%%% hosts two panes it (and the tests) can tell apart.
-module(tuition_shell_pane_a).
-behaviour(tuition_pane).

-export([new/0, render/3, apply_events/2, sample/1, selection/1, rows/1]).

new() -> tuition_shell_stub_pane:new(<<"alpha">>).
render(Area, Buf, St) -> tuition_shell_stub_pane:render(Area, Buf, St).
apply_events(Events, St) -> tuition_shell_stub_pane:apply_events(Events, St).
sample(St) -> tuition_shell_stub_pane:sample(St).
selection(St) -> tuition_shell_stub_pane:selection(St).
rows(St) -> tuition_shell_stub_pane:rows(St).
