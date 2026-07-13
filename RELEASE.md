### Added

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
