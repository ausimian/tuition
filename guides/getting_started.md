# Getting Started

tuition is a terminal UI framework for the BEAM: a terminal backend, an input
parser, a diff renderer, a layout engine, a ratatui-style widget set, and an app
shell that hosts your screens. This guide takes you from adding the dependency to
a working pane on screen.

## Add the dependency

tuition is not yet on Hex, so consume it as a git dependency. It has zero
dependencies beyond OTP and builds under both build tools, so an Erlang-only
project stays Erlang-only.

rebar3 (`rebar.config`):

```erlang
{deps, [{tuition, {git, "https://github.com/ausimian/tuition.git", {branch, "main"}}}]}.
```

Mix (`mix.exs`) — Mix builds it with rebar3, adding no Elixir to the chain:

```elixir
{:tuition, git: "https://github.com/ausimian/tuition.git", branch: "main"}
```

## See it running

`tuition_demo` is the smallest end-to-end example: a "hello, world" pane over
the full open/probe/render/input loop. Run it from a shell to check your terminal
is happy before you write anything:

```erlang
tuition_demo:start().
```

It paints a single pane, echoes each key you press into the status line, and
quits on `q`, restoring the terminal on the way out. It runs cooperatively
inside a live `erl`/`iex` shell, so you do not need a standalone release to try
it — and in that shell `q` is the exit, since the runtime keeps Ctrl-C for its
own interrupt (`tuition_term_local` has the details).

## Write a pane

A pane is a module that implements the `tuition_pane` behaviour. The shell
drives the shared render/input loop and calls back into your pane to build a
frame and fold input. Here is a whole one:

```erlang
-module(hello_pane).
-behaviour(tuition_pane).

-export([new/0, render/3, apply_events/2, sample/1]).

%% The initial state. This pane keeps none, so an empty map will do.
new() -> #{}.

%% Draw into the rect the shell hands us: a bordered block with a line inside it.
render(Area, Buf, State) ->
    Block = #{borders => all, title => <<"tuition">>},
    Buf1 = tuition_block:render(Block, Area, Buf),
    Inner = tuition_block:inner(Block, Area),
    Buf2 = tuition_paragraph:render(#{text => <<"hello, world">>}, Inner, Buf1),
    {Buf2, State}.

%% Fold a batch of input events. Quit on an unmodified `q`; ignore the rest.
apply_events(Events, State) ->
    case lists:member({key, {char, $q}, []}, Events) of
        true -> quit;
        false -> {ok, State}
    end.

%% No live data to refresh, so return the state unchanged.
sample(State) -> State.
```

`render/3` composes two widgets against the same buffer: a `tuition_block` for
the border and title, then a `tuition_paragraph` drawn into the block's inner
rect. It returns the buffer and the (unchanged) state. `apply_events/2` decides
when to quit. `sample/1` is where a live pane would refresh from the running
node; a static one leaves its state alone.

## Host it

Hand the pane to `tuition_shell`. It opens the terminal, runs the loop, and
paints your `render/3` each frame:

```erlang
tuition_shell:start([{hello_pane, <<"Hello">>}]).
```

A single-element pane list draws no nav bar, so your pane fills the screen. Give
the shell more panes and it puts a tab bar across the top and switches between
them with Tab. The shell owns those global keys — Tab to switch panes, and, in a
standalone `escript`/`erl -noshell` run, Ctrl-C to quit — while `q` stays the
pane-local exit `hello_pane` binds above.

That is a complete, running TUI. From here:

- [The Programming Model](programming_model.md) — the rebuild-every-frame loop
  and where state lives.
- [Building Widgets](building_widgets.md) — the widget set and how to write your
  own.
- [Handling Input](handling_input.md) — keys, mouse, paste, and the read loop.
- [Terminal Backends](terminal_backends.md) — running over ssh, in the browser,
  or headless in a test.

Writing your pane in Elixir instead? `Tuition.Pane` lets you author the same
behaviour with idiomatic record macros and aliases.
