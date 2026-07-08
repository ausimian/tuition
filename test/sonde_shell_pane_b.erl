%%% Second stub pane for the shell tests — draws "beta body". See {@link
%%% sonde_shell_pane_a}; identical but for the tag.
-module(sonde_shell_pane_b).
-behaviour(sonde_pane).

-export([new/0, render/3, apply_events/2, sample/1, selection/1, rows/1]).

new() -> sonde_shell_stub_pane:new(<<"beta">>).
render(Area, Buf, St) -> sonde_shell_stub_pane:render(Area, Buf, St).
apply_events(Events, St) -> sonde_shell_stub_pane:apply_events(Events, St).
sample(St) -> sonde_shell_stub_pane:sample(St).
selection(St) -> sonde_shell_stub_pane:selection(St).
rows(St) -> sonde_shell_stub_pane:rows(St).
