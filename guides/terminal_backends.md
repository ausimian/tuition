# Terminal Backends

A backend is the transport under everything else: it carries rendered bytes out
to a terminal and keystrokes back in. tuition keeps this behind one seam, so the
renderer, layout, widgets and panes above it never know whether they are talking
to a local tty, an ssh session, a browser, or a test script. This guide covers the
seam and the backends that implement it.

## The seam

`tuition_term` is the behaviour every backend implements. It is deliberately
small — five callbacks:

```erlang
open(Opts)          -> {ok, State} | {error, term()}.  %% take the transport
write(State, Data)  -> ok | {error, term()}.           %% emit rendered bytes
read(State, Timeout)-> {ok, Bytes} | timeout | {error, term()}.  %% bounded read
size(State)         -> {ok, {Cols, Rows}} | {error, term()}.
close(State)        -> ok.                              %% release, crash-safe
```

Callers address a backend through an opaque `{Backend, State}` handle and use the
dispatch helpers (`tuition_term:open/2`, `write/2`, `read/2`, `size/1`,
`close/1`), so nothing above the seam branches on which backend is in use. You
select one by passing `backend => Module` to `tuition_shell:start/2` or
`tuition_demo:start/1`; the whole options map is passed through to the backend's
`open/1`, so a backend reads its own keys from it. The default is the local tty.

The two rules that keep the seam honest: `read/2` must respect its timeout (so the
render loop's lone-ESC disambiguation works — see [Handling Input](handling_input.md)),
and `close/1` must be crash-safe, restoring the terminal whether the session ends
cleanly or the owning process dies.

## Local tty

`tuition_term_local` is the default, driving the current terminal through OTP
28's raw-mode `io` system. It picks one of two submodes automatically at `open/1`:

- **Noshell** — under an escript or `erl -noshell`, it takes full raw input and
  output. This is the standalone tool and release path.
- **Cooperative** — launched from a live `iex`/`erl` that already owns the tty, it
  reads through the current shell group instead of refusing. This is why
  `tuition_demo:start()` just works at an interactive prompt.

Either way it toggles the alternate screen and cursor visibility on open and
restores them on close, with a linked guard process that restores them too if the
owner crashes, so a host VM that keeps running is left with a pristine prompt.

## SSH

To serve a TUI over ssh, `tuition_ssh_cli` plugs into OTP's `ssh:daemon` as a
custom channel, and `tuition_term_ssh` is the backend behind it — `read/2` waits
on SSH `data` messages, `write/2` sends ANSI over the channel, `size/1` tracks
pty window-change events. An application never opens the ssh backend directly: it
runs the shell through `tuition_ssh_cli`, which injects the channel during
session startup. The shell and pane contracts are unchanged, so the same panes
that run locally run for a remote user with no code differences.

## Browser

[`kino_tuition`](https://github.com/ausimian/kino_tuition) is a separate project
that hosts a tuition session inside a [Livebook](https://livebook.dev) cell,
rendering to a real browser terminal (xterm.js) with a live session behind it. It
is the backend the runnable widget showcases use, so a reader can drive a real
widget — its colour, selection highlight and scrolling — from the docs rather than
looking at a screenshot. See the widget showcase notebooks for a working example.

## Testing

`tuition_loop_term` is the public test backend, the equivalent of ratatui's
`TestBackend`. It replays a canned terminal with no tty at all, so a loop's output
can be asserted byte-for-byte. Point any host that opens a backend at it and drive
it from the `Opts` map:

```erlang
tuition_shell:start([{hello_pane, <<"Hello">>}], #{
    backend => tuition_loop_term,
    sink    => self(),                          %% receives {write, Bin} then closed
    size    => {80, 24},                        %% the size reported to the loop
    script  => [{ok, <<"q">>}]                  %% one read result per read
}).
```

`sink` collects everything the loop emits, `size` sets the geometry (a list of
sizes drives a resize), and `script` feeds one `read/2` result per read — the
script must reach a quit key or the loop spins forever. Because the shell's pure
pieces are exported, pane switching, key routing and resize can be asserted
directly over this backend, no terminal involved.
