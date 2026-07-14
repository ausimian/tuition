### Added

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
