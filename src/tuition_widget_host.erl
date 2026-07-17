-module(tuition_widget_host).
-moduledoc """
A pane that shows one widget on its own.

`m:tuition_widget_demo` composes the widget set into a single screen — the right
shape for seeing how widgets sit together, the wrong one for seeing what any one
of them does. This is the other half: a generic `m:tuition_pane` that renders
exactly one widget into the whole area it is given, so a showcase (a Livebook
notebook, a captured documentation frame) shows that widget and nothing else.

It is generic in the widget: it holds a module and a config and renders them
through the `m:tuition_widget` seam, never inspecting either. So it hosts your
widget as readily as one of `tuition`'s own.

## Hosting one

The host is seeded from a `t:spec/0` through the shell's parameterised pane spec:

```erlang
Spec = #{widget => tuition_gauge, config => #{ratio => 0.63}},
tuition_shell:start([{tuition_widget_host, <<"Gauge">>, Spec}]).
```

A single-element pane list runs one pane with no nav bar, which is what a
showcase wants. `m:tuition_shell` still owns Ctrl-C, so a host always has a way
out even when its own keys are spoken for.

## Stateless and stateful widgets

A spec with no `state` key hosts a stateless widget, rendered through
`tuition_widget:render/4`. A spec *with* one hosts a stateful widget, rendered
through the widget's own `render/4`, its reconciled state threaded back across
frames (see `m:tuition_widget` on why that state cannot live in the widget):

```erlang
#{widget => tuition_list,
  config => #{items => [<<"alpha">>, <<"beta">>]},
  state => tuition_list:new()}
```

## Input is the caller's

The stateful widgets do not share one input API — `m:tuition_list` and
`m:tuition_table` navigate through `next/2`/`prev/2`, `m:tuition_tree` also opens
and closes nodes, `m:tuition_scrollview` scrolls by offset, `m:tuition_input_field`
takes an event at a time — and a widget's key bindings are a property of the
showcase, not of the widget. So the host does not guess: an `input` fun in the
spec folds an event into the `t:model/0`, and gets to see every key. That fold is
usually the most interesting line of a showcase, and it is the caller's to write:

```erlang
#{widget => tuition_list,
  config => #{items => Items},
  state => tuition_list:new(),
  input => fun
      ({key, down, _Mods}, #{state := S} = M) -> M#{state := tuition_list:next(S, length(Items))};
      ({key, up, _Mods}, #{state := S} = M) -> M#{state := tuition_list:prev(S, length(Items))};
      (_Event, M) -> M
  end}
```

The fold reaches the config as well as the widget state, because interactivity for
a stateless widget *is* a recomputed config — a gauge's `ratio` moving under a key
press. It returns `quit` to end the run.

Without an `input` fun the host takes `q` as quit and ignores every other key,
which is all a static showcase needs. With one, the fun decides everything: a
showcase of `m:tuition_input_field` needs `q` to be a keystroke rather than an
exit, and only the fold can know that.
""".
-behaviour(tuition_pane).

-export([new/1, apply_events/2, sample/1, render/3]).
-export([build_frame/2, model/1]).

%% What the caller's `input' fun folds into: the widget's config, plus its state
%% when the widget is a stateful one. The `state' key is present here exactly when
%% it was present in the spec, so a fold can match on it to reach either.
-type model() :: #{config := term(), state => term()}.
%% Folds one event into the model, or ends the run. It sees every event the shell
%% did not claim as a global key.
-type input() :: fun((tuition_input:event(), model()) -> model() | quit).
%% The widget to show: its module, its config, the initial state of a stateful
%% widget (omitted for a stateless one) and an optional input fold.
-type spec() :: #{
    widget := module(),
    config := term(),
    state => term(),
    input => input()
}.

-export_type([model/0, input/0, spec/0]).

%% The hosted widget, the model the caller's fold owns, and that fold (`none' for
%% the default `q'-quits binding). `widget' and `input' are fixed at seed time;
%% only `model' moves.
-record(host, {
    widget :: module(),
    model :: model(),
    input :: none | input()
}).

-type state() :: #host{}.
-export_type([state/0]).

%%% -- state -----------------------------------------------------------

-doc """
Seed a host from its `t:spec/0`. Called by `m:tuition_shell` for a `{Module,
Title, Arg}` pane spec, with the spec map as `Arg`.
""".
-spec new(spec()) -> state().
%% `config' is matched but unbound: the model is lifted wholesale by `maps:with/2',
%% and the match is what makes a spec missing it fail here rather than at render.
new(#{widget := Widget, config := _Config} = Spec) ->
    #host{
        widget = Widget,
        model = maps:with([config, state], Spec),
        input = maps:get(input, Spec, none)
    }.

-doc """
The current model — the hosted widget's config, and its state when stateful.
Exposed so a driver or test can assert how input folded, the way
`tuition_widget_demo:selection/1` does for the composed demo.
""".
-spec model(state()) -> model().
model(#host{model = Model}) -> Model.

-doc """
A no-op. A showcase has no live node data to refresh; this is here to satisfy the
`m:tuition_pane` contract the shell drives every pane through on the idle tick.
""".
-spec sample(state()) -> state().
sample(State) -> State.

%%% -- input -----------------------------------------------------------

-doc """
Fold input events into the model in arrival order, short-circuiting on `quit`.

With an `input` fun in the spec, that fun decides everything, including whether a
key quits. Without one, `q` quits and every other event is ignored. Ctrl-C never
reaches here — `m:tuition_shell` quits on it globally, before a pane is offered
the event.
""".
-spec apply_events([tuition_input:event()], state()) -> {ok, state()} | quit.
apply_events([], State) ->
    {ok, State};
apply_events([Event | Rest], #host{input = none} = State) ->
    case Event of
        {key, {char, $q}, []} -> quit;
        _Other -> apply_events(Rest, State)
    end;
apply_events([Event | Rest], #host{input = Input, model = Model} = State) ->
    case Input(Event, Model) of
        quit -> quit;
        Model1 -> apply_events(Rest, State#host{model = Model1})
    end.

%%% -- frame building --------------------------------------------------

-doc """
Render the hosted widget into `Area`, the whole rect the shell allots the pane —
no chrome, no framing of the host's own, so the widget is what you see. A
stateless widget goes through the `m:tuition_widget` seam and leaves the state
untouched; a stateful one goes through its own `render/4` and the state it
returns is kept, since the scroll offset it reconciled must survive to the next
frame.
""".
-spec render(tuition_layout:rect(), tuition_render:buffer(), state()) ->
    {tuition_render:buffer(), state()}.
render(Area, Buf, #host{widget = Widget, model = #{config := Config, state := WState}} = State) ->
    {Buf1, WState1} = Widget:render(Config, Area, Buf, WState),
    {Buf1, State#host{model = (State#host.model)#{state := WState1}}};
render(Area, Buf, #host{widget = Widget, model = #{config := Config}} = State) ->
    {tuition_widget:render(Widget, Config, Area, Buf), State}.

-doc """
Render the host full-screen for the given terminal size, on a fresh buffer. The
standalone convenience the pure tests build frames through, and the seam a
captured documentation frame is rendered from — the same shape as
`tuition_widget_demo:build_frame/2`.
""".
-spec build_frame(tuition_term:size(), state()) -> {tuition_render:buffer(), state()}.
build_frame(Size, State) ->
    render(tuition_layout:area(Size), tuition_render:new(Size), State).
