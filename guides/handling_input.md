# Handling Input

A terminal delivers input as a raw byte stream: printable characters, but also
multi-byte escape sequences for arrow keys and function keys, mouse reports, and
pasted text. tuition turns that stream into structured events you can match on.
This guide covers the parser, the events it produces, the one piece of timing it
needs, and how input reaches your pane.

## The parser

`tuition_input` is a pure function from bytes to events. Feed it whatever the
backend read and it returns a list of events plus an opaque state:

```erlang
{Events, State1} = tuition_input:parse(Bytes, State0).
```

The backend reads a byte or a small chunk at a time, so a single escape sequence
can arrive split across several reads. The parser handles this: it decodes every
*complete* sequence it can and keeps any trailing partial — a half-finished CSI
sequence, an incomplete UTF-8 code point — buffered in its state. The next
`parse/2` completes it from the bytes that follow. Start a fresh parser with
`tuition_input:new/0` and thread its state across reads.

## Events

Each event is one of:

- `{key, {char, C}, Mods}` — a printable Unicode code point.
- `{key, {ctrl, C}, Mods}` — a control chord, carrying the base letter (`$a`
  for Ctrl-A).
- `{key, Named, Mods}` — a named key: `enter`, `tab`, `backspace`, `esc`, the
  arrows, `home`/`'end'`, `page_up`/`page_down`, `insert`, `delete`, or
  `{f, 1..12}`.
- `{mouse, Action, Button, {Col, Row}, Mods}` — an SGR mouse report: a `press`,
  `release` or `drag`, at a 1-based column and row. A wheel notch is a `press`
  of a `wheel_up`/`wheel_down` button.
- `{paste, Bytes}` — the literal text of a bracketed paste, delivered whole and
  never re-decoded as keys.

`Mods` is a list drawn from `shift`, `alt`, `ctrl` and `meta`. Matching a key is
a plain pattern match:

```erlang
handle({key, up, _Mods}, State)        -> move_up(State);
handle({key, {char, $q}, []}, _State)  -> quit;
handle(_Other, State)                  -> State.
```

Mouse and paste events are only produced once capability probing
(`tuition_caps`) has enabled the matching terminal modes, so a terminal that
does not support them simply never emits them.

## The lone-ESC timeout

A bare `ESC` byte is ambiguous. On its own it is the Escape key, but it is also
the first byte of every arrow-key and function-key sequence. The parser cannot
tell which until it sees — or fails to see — the next byte, so a trailing `ESC`
stays buffered rather than being guessed.

The tie-breaker is time. Reads are bounded, and when a read times out with an
`ESC` still buffered, `tuition_input:flush/1` resolves it to the Escape key. So
`ESC [ A` decodes to Up straight away (its bytes arrive together), while a lone
`ESC` becomes Escape only once a short inter-byte gap has passed with nothing
following. The same timing separates a real Escape-then-key from an Alt chord a
terminal sends as a nested `ESC`.

## The read loop

`tuition_input_driver` supplies that timing. It is the seam between the pure
parser and the terminal's bounded `read/2`, advancing the parser by exactly one
read:

```erlang
loop(Handle, St0) ->
    case tuition_input_driver:poll(Handle, St0, 1000) of
        {ok, Events, St1} ->
            lists:foreach(fun handle_event/1, Events),
            loop(Handle, St1);
        {error, Reason} ->
            {stopped, Reason}
    end.
```

The third argument is the idle timeout — how long to wait for fresh input before
the read returns empty so the loop can do its periodic work. The driver
substitutes a short window only when an `ESC` is awaiting disambiguation, so a
lone Escape resolves promptly without forcing that short window onto a slow-
arriving UTF-8 character (which would corrupt it).

## Wiring it into your loop

You rarely call the driver yourself. `tuition_shell` polls input, routes its
own global keys (Tab to switch panes, Ctrl-C to quit), and hands the rest to the
focused pane's `apply_events/2` as a batch. Your pane folds that
batch into its state and, when it decides the app should exit, short-circuits to
`quit`:

```erlang
apply_events(Events, State) ->
    lists:foldl(fun apply_one/2, {ok, State}, Events).
```

Because the shell peels off its global keys first, a pane only ever sees the keys
meant for it — even a pane that captures every printable character for a filter
field never has a pane switch stolen from under it. Quitting is split so this
works: Ctrl-C always quits at the shell, while a plain `q` is pane-local, so a
pane can decline it and type it into a field instead.
