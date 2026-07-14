### Added

- **`tuition_clear`** — a stateless overlay primitive: it blanks a rect, resetting
  every cell to a plain space, so a modal popup / confirm dialog / help overlay
  drawn last in a frame starts from a clean slate instead of showing the content
  beneath it through the gaps it leaves. It is ratatui's `Clear`. Unlike the shared
  `tuition_widget:fill/3`, which no-ops an empty style (letting a parent background
  show through), Clear's default style still overwrites — the reset is the point; a
  non-empty `style` lays a coloured backdrop under the overlay instead. A wide glyph
  straddling the region is dissolved whole, leaving no orphaned half. (A
  `centered_rect/3` helper to place popups is a deferred follow-up.)
- **`tuition_spinner`** — a stateless in-flight indicator: a single animated glyph
  (optionally with a label) a pane draws while an async operation is pending, so a
  slow owner/remote read reads as "loading" rather than a frozen or stale view.
  Which glyph shows is purely `frame rem length`, so animation is a pure function
  of the caller's tick (the shell already ticks every pane) with no internal timer
  or state; a negative `frame` is handled rather than crashing. Built-in sets
  `braille` (default), `dots` and `line` are single-column so the label never
  jitters, or pass a custom glyph list; `style` / `label_style` colour the two
  parts.
- **Fixed capability profiles** — a host can now skip the interactive terminal
  capability probe and supply a known capability set instead, for an asynchronous
  or high-latency backend (such as a Livebook/xterm.js terminal) where the probe's
  query round-trip overruns its read window and late replies leak into input as
  fake keystrokes. `tuition_caps:resolve/2` reads `caps => Caps` (use that
  `tuition_caps:caps()` profile verbatim) or `probe => false` (use
  `tuition_caps:baseline/0`), and otherwise probes the terminal as before;
  `tuition_demo:start/1` threads both options through. When probing is skipped no
  terminal queries are written, so no stray reply can be injected as a keystroke.
- **`tuition_tabs`** — a stateless tab-bar widget: a horizontal row of titles
  separated by a divider glyph with one highlighted, so a multi-pane UI can show
  the panes it switches between and which one has focus. Takes `titles` (a list
  of chardata) and a 0-based `selected` index, with configurable `style` /
  `highlight_style`, `divider` glyph, per-title `padding`, and `title_align` for
  the strip within its area. The row is clipped to the area — an overflowing tail
  is truncated at the right edge, a wide glyph at the edge dropped whole rather
  than split. Composes with `tuition_layout` (reserve a 1-row strip at the top of
  a pane) and the `tuition_shell` focus model.
- **`tuition_line_gauge`** — a stateless single-row gauge: a label followed by a
  thin horizontal line whose leading fraction is drawn `filled` and the rest
  `unfilled`, for dense dashboards where the full-height `tuition_gauge` is too
  heavy and metrics want to stack one per line. `ratio` is clamped to `[0, 1]`;
  the `label` defaults to the rounded percentage (or `none`, yielding the full
  width to the line); `line` selects the `thin` (`─`) / `heavy` (`━`) rule or a
  custom glyph; and `filled_style` / `unfilled_style` / `label_style` colour the
  three parts. Whole-cell fill (ratatui's `LineGauge`), drawn on the area's top
  row.
- **`tuition_scrollview`** — a stateful viewport onto content larger than its
  area: the caller paints a virtual buffer of a chosen `content_size` (via a
  `draw` fun or a pre-built buffer) and the widget blits the scrolled window into
  the visible rect, panning in both axes. Wide glyphs clipped at a window edge are
  blanked rather than shown as stray halves; offsets are clamped to the content
  edge at render time. Optional `scrollbars` compose `tuition_scrollbar` onto the
  edges. State (`{x_offset, y_offset}`) is a `#scrollview_state{}` threaded by the
  caller, with `new/0`, `scroll_to/3`, `scroll_by/3`, `offset/1` and `size/1`.
- **`tuition_scrollbar`** — a stateless scrollbar widget: a track with a
  proportional thumb showing scroll position and extent beside a scrollable pane.
  Vertical or horizontal, proportional thumb size (floored at one cell), optional
  arrow caps, and configurable track/thumb glyphs and styles. Derives its geometry
  from the `content_length` / `viewport_length` / `position` the scrollable widget
  beside it already tracks.
- Initial extraction of `tuition`, the pure-Erlang terminal UI framework, from
  the [Sonde](https://github.com/ausimian/sonde) BEAM observer into its own
  repository. Zero dependencies beyond OTP; builds natively under both rebar3
  and Mix. Modules:
  - **Backends & input** — `tuition_term` (backend behaviour),
    `tuition_term_local` (raw-mode tty), `tuition_loop_term` (scripted test
    backend), `tuition_caps` (capability probing), `tuition_input` /
    `tuition_input_driver` (byte-stream to key events).
  - **Render & layout** — `tuition_render` (double-buffered diff renderer),
    `tuition_layout` (constraint/split layout), `tuition_width` (Unicode display
    width), `tuition_braille` (sub-cell dot grid).
  - **Widgets** — `tuition_widget` (behaviour + draw helpers), `tuition_block`,
    `tuition_paragraph`, `tuition_list`, `tuition_table`, `tuition_gauge`,
    `tuition_sparkline`, `tuition_chart`.
  - **App shell** — `tuition_pane` (pane behaviour) and `tuition_shell`
    (multi-pane host).
  - **Demo** — `tuition_demo`, a "hello, world" reference loop.

### Changed

- All modules, headers, and the application were renamed from the `sonde_*` /
  `sonde_tui` prefix to `tuition_*` / `tuition`.
