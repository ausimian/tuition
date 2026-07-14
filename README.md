# tuition

A pure-Erlang **terminal UI framework** for the BEAM: a terminal backend seam,
input parser, diff renderer, layout engine, a ratatui-style widget set, and a
multi-pane application shell. Reusable by anyone building a BEAM TUI —
observation or not. It was extracted from the
[Sonde](https://github.com/ausimian/sonde) BEAM observer, which is its first
consumer.

This is a **rebar3-native library** with **zero dependencies beyond OTP**
(`kernel`, `stdlib`, `erts`). It builds natively under both rebar3 and Mix, so
it can be embedded by Erlang-only and Elixir consumers alike with no Elixir in
the chain.

```sh
rebar3 compile
rebar3 eunit
rebar3 xref
```

`tuition_demo` is the smallest end-to-end example — a "hello, world" pane over
the full open/probe/render/input loop — and the starting point for a consumer.

## Use as a dependency

Not yet published to Hex; consume it as a git dependency.

rebar3 (`rebar.config`):

```erlang
{deps, [{tuition, {git, "https://github.com/ausimian/tuition.git", {branch, "main"}}}]}.
```

Mix (`mix.exs`) — Mix builds it with rebar3 (no Elixir added):

```elixir
{:tuition, git: "https://github.com/ausimian/tuition.git", branch: "main"}
```

## Layout

| Module                | Role                                                        |
|-----------------------|-------------------------------------------------------------|
| `tuition_term`          | Terminal backend **behaviour** (the pluggable seam).        |
| `tuition_term_local`    | Local raw-mode tty backend (Modes 1–3).                     |
| `tuition_caps`          | Terminal capability probing (baseline + runtime probe).     |
| `tuition_input`         | Input parser — raw byte stream to structured key events.    |
| `tuition_input_driver`  | Bounded read loop driving the parser (lone-ESC timeout).    |
| `tuition_layout`        | Constraint/split layout — tile an area into cell rects.     |
| `tuition_render`        | Double-buffered cell grid with diff-based minimal repaint.  |
| `tuition_width`         | Unicode display width (wcwidth + grapheme clustering).      |
| `tuition_braille`       | Braille 2×4 sub-cell dot grid (line rasterizer + per-cell colour). |
| `tuition_widget`        | Widget **behaviour** (the render-into-a-rect seam) + shared draw helpers. |
| `tuition_block`         | Block widget — border, title, and the inner content rect.   |
| `tuition_paragraph`     | Paragraph widget — wrapped, aligned, scrollable text.       |
| `tuition_list`          | Stateful list widget — selection + scroll (`ListState`).    |
| `tuition_table`         | Stateful table widget — columns, header, selection, sort.   |
| `tuition_gauge`         | Gauge widget — horizontal progress bar (sub-cell precision). |
| `tuition_sparkline`     | Sparkline widget — compact bar chart of a numeric series.   |
| `tuition_chart`         | Chart widget — sub-cell trend curves (braille line/scatter). |
| `tuition_tabs`          | Tabs widget — a horizontal row of titles with one selected. |
| `tuition_pane`          | Pane **behaviour** — the contract the app shell hosts.      |
| `tuition_shell`         | Application shell — hosts panes under one navigable UI.      |
| `tuition_loop_term`     | Scripted terminal backend for headless testing (ratatui's `TestBackend` role). |
| `tuition_demo`      | "Hello, world" reference loop — the smallest end-to-end example. |

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

`tuition_render:diff/2` is the render hot path and was optimized in #22 (row-major
scan + per-cell width cache), so a guard protects that baseline from silently
regressing:

```sh
rebar3 as bench guard
```

The guard is deterministic and **ratio-based** rather than an absolute
wall-clock budget (which flakes on shared runners): for the `full_paint` and
`wide` 120×40 frames it times `diff/2` against a cheap in-process baseline — a
bare per-cell read of the same frame via `tuition_render:cell_at/3` — and asserts
the median diff/baseline ratio stays under a generous ceiling. Both are O(cells)
walks over the same grid, so raw machine speed cancels out of the ratio and only
the *relative* cost of diffing is measured; a regression (e.g. reverting the
per-cell width cache) inflates the ratio while the baseline is unaffected.

It is a **local guard**, not CI-gated (bench timing on shared runners is noisy):
the eunit entry point compiles only under the `bench` profile, so a plain
`rebar3 eunit` and the Mix build run no timing check. See
`test/bench_render_guard.erl` for the mechanism and the tuned ceilings.
