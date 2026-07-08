%%% First stub pane for the shell tests — draws "alpha body". All behaviour lives
%%% in {@link sonde_shell_stub_pane}; this module only fixes the tag so the shell
%%% hosts two panes it (and the tests) can tell apart.
-module(sonde_shell_pane_a).
-behaviour(sonde_pane).

-export([new/0, render/3, apply_events/2, sample/1, selection/1, rows/1]).

new() -> sonde_shell_stub_pane:new(<<"alpha">>).
render(Area, Buf, St) -> sonde_shell_stub_pane:render(Area, Buf, St).
apply_events(Events, St) -> sonde_shell_stub_pane:apply_events(Events, St).
sample(St) -> sonde_shell_stub_pane:sample(St).
selection(St) -> sonde_shell_stub_pane:selection(St).
rows(St) -> sonde_shell_stub_pane:rows(St).
