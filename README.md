# sonde_tui

The pure-Erlang **terminal UI framework** underneath [Sonde](../README.md):
terminal backend seam, input parser, diff renderer, layout engine, a
ratatui-style widget set, and a multi-pane application shell. It is reusable by
anyone building a BEAM TUI — observation or not.

This is a **rebar3-native library** with **zero dependencies beyond OTP**
(`kernel`, `stdlib`, `erts`). It builds natively under both rebar3 and Mix, so
it can be embedded by Erlang-only and Elixir consumers alike with no Elixir in
the chain (PRD §12). Nothing here depends on the observation layer — the
[`sonde`](../sonde/) observer library depends on this, never the reverse.

```sh
rebar3 compile
rebar3 eunit
rebar3 xref
```

`sonde_tui_demo` is the smallest end-to-end example — a "hello, world" pane over
the full open/probe/render/input loop — and the starting point for a consumer.

## Layout

| Module                | Role                                                        |
|-----------------------|-------------------------------------------------------------|
| `sonde_term`          | Terminal backend **behaviour** (the pluggable seam).        |
| `sonde_term_local`    | Local raw-mode tty backend (Modes 1–3).                     |
| `sonde_caps`          | Terminal capability probing (baseline + runtime probe).     |
| `sonde_input`         | Input parser — raw byte stream to structured key events.    |
| `sonde_input_driver`  | Bounded read loop driving the parser (lone-ESC timeout).    |
| `sonde_layout`        | Constraint/split layout — tile an area into cell rects.     |
| `sonde_render`        | Double-buffered cell grid with diff-based minimal repaint.  |
| `sonde_width`         | Unicode display width (wcwidth + grapheme clustering).      |
| `sonde_braille`       | Braille 2×4 sub-cell dot grid (line rasterizer + per-cell colour). |
| `sonde_widget`        | Widget **behaviour** (the render-into-a-rect seam) + shared draw helpers. |
| `sonde_block`         | Block widget — border, title, and the inner content rect.   |
| `sonde_paragraph`     | Paragraph widget — wrapped, aligned, scrollable text.       |
| `sonde_list`          | Stateful list widget — selection + scroll (`ListState`).    |
| `sonde_table`         | Stateful table widget — columns, header, selection, sort.   |
| `sonde_gauge`         | Gauge widget — horizontal progress bar (sub-cell precision). |
| `sonde_sparkline`     | Sparkline widget — compact bar chart of a numeric series.   |
| `sonde_chart`         | Chart widget — sub-cell trend curves (braille line/scatter). |
| `sonde_pane`          | Pane **behaviour** — the contract the app shell hosts.      |
| `sonde_shell`         | Application shell — hosts panes under one navigable UI.      |
| `sonde_loop_term`     | Scripted terminal backend for headless testing (ratatui's `TestBackend` role). |
| `sonde_tui_demo`      | "Hello, world" reference loop — the smallest end-to-end example. |

## Benchmarks

Microbenchmarks for the perf-sensitive pure primitives (Unicode width, the
layout solver, the input parser, the diff renderer) live in `test/bench_*.erl`
and run via [`rebar3_bench`](https://hex.pm/packages/rebar3_bench):

```sh
rebar3 as bench bench
```

The plugin is scoped to the `bench` profile, so the default build path
(`compile`/`eunit`/`xref`) and the Mix build never fetch or load it — the
`{deps, []}` zero-dependency guarantee is unaffected.

### Perf-regression guard

`sonde_render:diff/2` is the render hot path and was optimized in #22 (row-major
scan + per-cell width cache), so a guard protects that baseline from silently
regressing:

```sh
rebar3 as bench guard
```

The guard is deterministic and **ratio-based** rather than an absolute
wall-clock budget (which flakes on shared runners): for the `full_paint` and
`wide` 120×40 frames it times `diff/2` against a cheap in-process baseline — a
bare per-cell read of the same frame via `sonde_render:cell_at/3` — and asserts
the median diff/baseline ratio stays under a generous ceiling. Both are O(cells)
walks over the same grid, so raw machine speed cancels out of the ratio and only
the *relative* cost of diffing is measured; a regression (e.g. reverting the
per-cell width cache) inflates the ratio while the baseline is unaffected.

It is a **local guard**, not CI-gated (bench timing on shared runners is noisy):
the eunit entry point compiles only under the `bench` profile, so a plain
`rebar3 eunit` and the Mix build run no timing check. See
`test/bench_render_guard.erl` for the mechanism and the tuned ceilings.
