%%% Stub sidebar pane for the shell tests. It exercises the generic shell's sidebar
%%% support without depending on the real node picker: it draws "side body" so a
%%% test can see it painted, counts its `sample/1' calls (to assert the shell samples
%%% it every idle tick alongside the active main pane), and counts the Down keys it
%%% receives (to assert keys route to it while it holds focus). Enter returns
%%% `{sample, St}' — the way the real picker asks the shell to resample the other
%%% visible panes off a target switch. It never quits — the real sidebar has no quit
%%% binding either.
-module(tuition_shell_side_pane).
-behaviour(tuition_pane).

-include("tuition_layout.hrl").

-export([new/0, render/3, apply_events/2, sample/1, samples/1, moved/1]).

-record(st, {samples = 0 :: non_neg_integer(), moved = 0 :: non_neg_integer()}).

new() -> #st{}.

%% How many times the shell has sampled this pane.
samples(#st{samples = N}) -> N.

%% How many Down keys this pane has received (only when it holds focus).
moved(#st{moved = N}) -> N.

sample(#st{samples = N} = St) -> St#st{samples = N + 1}.

%% Enter mimics the picker's target switch: it asks the shell to run its sample
%% cycle now. The shell dispatches one event at a time, so returning here on the
%% first Enter is enough for the tests.
apply_events([{key, enter, _Mods} | _Rest], St) ->
    {sample, St};
apply_events([], St) ->
    {ok, St};
apply_events([{key, down, _Mods} | Rest], #st{moved = M} = St) ->
    apply_events(Rest, St#st{moved = M + 1});
apply_events([_Other | Rest], St) ->
    apply_events(Rest, St).

render(#rect{w = W, h = H}, Buf, St) when W =< 0; H =< 0 ->
    {Buf, St};
render(#rect{x = X, y = Y}, Buf, St) ->
    %% A non-default style so the interior space survives the render diff (see the
    %% main stub pane's note).
    {tuition_render:put_text(Buf, X, Y, <<"side body">>, #{fg => 7}), St}.
