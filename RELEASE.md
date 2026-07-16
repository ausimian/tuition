### Added

- **`tuition_text` — a rich styled-text model (`Line` / `Span`)** — a lightweight
  `line` of styled `span`s (ratatui's `Text` / `Line` / `Span`) so text can carry
  mixed styles *within* a single line instead of one style per whole widget: colour
  a status word red, dim a timestamp prefix, bold a matched substring. A `span` is
  a `{Text, style()}` pair (or `#{text, style}` map), a `line` a list of spans, a
  `text` a list of lines. `tuition_paragraph` (`text`), `tuition_list` (`items`)
  and `tuition_table` (`columns` / `rows`) now accept this model anywhere they took
  plain chardata — backward compatible, since a bare binary/iolist is exactly one
  default-styled span and multi-line plain text still splits on `\n`. A span's
  style is layered over the widget's base style, so a span setting only
  `#{bold => true}` bolds the run while keeping the paragraph/row/cell colour
  underneath. Paragraph word wrap works across spans, carrying each run's style
  through the wrap (including a word broken by a hard split or a style boundary);
  table sort keys read a styled cell's plain text. `tuition_text` also exports the
  measure/clip/draw helpers (`line_width/1`, `truncate_line/2`, `put_line/6`) that
  align and clip a styled line the same sanitise-aware way the plain widgets
  measure, so a styled line can no more spill onto a neighbour than a plain one.
  Expanding the cell attribute set beyond `bold` / `underline` (adding
  `italic` / `reverse` / `dim` / …) is a natural follow-on, left to its own change.
- **SSH daemon shell backend** — `tuition_ssh_cli` plugs into OTP
  `ssh:daemon/2,3` as a custom `ssh_cli` channel callback and starts the normal
  `tuition_shell` with `tuition_term_ssh` underneath it, so existing pane modules
  can be hosted over an SSH pty without changing the pane contract. The channel
  callback handles pty allocation, shell requests, raw input data, window-change
  resize events, eof/close and exit status, while `tuition_term_ssh` exposes the
  same `read`/`write`/`size`/`close` backend callbacks as the local terminal.
- **`tuition_tree`** — a stateful collapsible tree: a navigable hierarchy with
  expand/collapse and selection, so a caller building an application/supervision
  view stops hand-rolling one out of flattened `tuition_list` rows. Takes `nodes`,
  a nested list of `#{id, label, children}` maps (`children` optional — a node
  without them is a leaf), and draws one row per *visible* node: a node's children
  follow it, indented, only while it is open. Indentation is `indent` columns per
  level (default `2`), either blank or — with `guides => true` — drawn as `│ ├ └`
  connectors that continue through an ancestor's column only while its sibling run
  does; `open_symbol` / `closed_symbol` (default `▾` / `▸`) mark the expandable
  rows, and a leaf blanks to the same width so labels align down the column. Since
  a flattened tree *is* a list, the drawing itself is `tuition_list`'s —
  selection clamping, offset reconciliation, the full-width highlight bar and
  per-row clipping are reused rather than forked, so `style`, `highlight_style`
  and `highlight_symbol` behave exactly as they do on a list. The two keyings are
  deliberately split: selection is a **visible-row index** (what the arrow keys
  move through, reconciled against the live row count so a collapse cannot strand
  it), while open/closed is keyed by **node id**, so a caller re-rendering live
  data every frame keeps the user's tree open across a rebuild instead of
  collapsing it whenever a node above appears or vanishes; `selected_id/2` bridges
  the two and is how the node under the cursor is toggled. Closing a node retains
  the open state *within* it, so reopening restores the subtree as the user left
  it. State (`selected` / `offset` / `open`) is a `#tree_state{}` threaded by the
  caller, with `new/0`, `open/2`, `close/2`, `toggle/2`, `toggle_selected/2`,
  `is_open/2`, `next/2`, `prev/2`, `select/2`, `selected/1` and `selected_id/2`
  (which tags its result `{ok, Id}` so every term stays a legitimate node id, `none`
  included); `visible/2` exposes the
  same flatten the render uses (each row carrying `depth`, `expandable`,
  `expanded` and its parent's visible-row index), so navigation this widget does
  not impose — jump-to-parent, step-into-child — is built from one source of truth
  rather than re-derived.
- **`tuition_block` border types and padding** — the frame every pane sits in
  gains two cosmetic controls. `border_type` selects the line/corner glyph set —
  `light` (default), `rounded` (light runs with rounded corners), `double` or
  `thick` — with the per-side subset logic unchanged, so a partial border draws
  the chosen glyphs on just the requested sides. `padding` insets the content
  rect returned by `inner/2` beyond the border: `0` (default), a uniform `N`, or
  a `{Top, Right, Bottom, Left}` tuple, clamped so the inner rect never goes
  negative; the drawn border and title are unaffected. Both default to today's
  output exactly, so existing blocks render unchanged.
- **`tuition_canvas`** — a stateless freeform drawing widget over the braille
  sub-cell kernel: the caller names its own value coordinate system
  (`x_bounds` / `y_bounds`, with the y-axis pointing up as in ordinary Cartesian
  coordinates) and draws a list of `shapes` into it — `{line, ...}`,
  `{points, ...}`, `{rect, ...}` (outline), `{fill_rect, ...}` (solid) and
  `{circle, ...}`, each in its own colour. Shapes are drawn in order onto one
  shared grid, so overlapping cells merge their dots and take the later shape's
  colour (the one-colour-per-cell rule). A coordinate outside its bounds clamps
  to the nearest edge; an unrecognised shape is ignored (forward-compatible); an
  optional `background` fills the area (and shows through under the glyph cells)
  and `style` sets the base glyph attributes. This is ratatui's `Canvas`, the
  general surface `Chart` specialises. The braille kernel gains `rect/6`,
  `fill_rect/6` and `circle/5` rasterizers (alongside `line/6`) to support it.
- **`tuition_chart` legend and labelled axes** — the chart can now label itself
  instead of leaving it all to the caller. Datasets take an optional `name`, and
  `legend => #{position, style}` floats a small boxed colour-swatch key in a plot
  corner (resetting the cells beneath it so the curves do not show through). With
  `axes => true`, four opt-in keys label the frame, each reserving its own gutter
  or row so they compose without overlap: `y_ticks` (`auto` — max/mid/min — or an
  explicit value list) draws numeric labels up the y-axis; `x_labels` spreads
  labels along the x-axis (first flush-left, last flush-right); and `y_title` /
  `x_title` add axis titles (the y-title written vertically in a reserved
  left column). Ticks share the curve's live scale, so a label sits level with the
  value it denotes. All labelling is opt-in — a chart with none of these keys is
  drawn exactly as before.
- **`tuition_input_field`** — a stateful single-line text input: a rendered,
  editable field with a caret and horizontal scroll, the affordance a filter,
  search, or command box is built from (the on-screen counterpart to the
  `tuition_input` key decoder). `handle/2` folds a decoded key event into the
  field and reports whether the *value* changed, so a caller re-runs its filter
  only on real edits: a printable char inserts at the caret; `backspace` /
  `delete` remove the cluster before / after it; `left` / `right` move one
  grapheme cluster, or by a word with `ctrl` / `alt` held; `home` / `end` jump to
  the edges; a bracketed `paste` inserts its text with control bytes (newlines
  included) stripped; and `enter`, `tab`, and other keys are left for the caller
  to act on. Movement and scrolling are grapheme-cluster and column aware (via
  `tuition_widget:display_width/1`), so a wide glyph is one caret step and is
  never split across the scroll edge; the view slides just far enough to keep the
  caret visible and pulls back after the value shrinks. The caret is drawn as a
  styled cell over the glyph beneath it (`cursor_style`, default `underline`;
  `#{}` to hide it for an unfocused field). `placeholder` shows dimmed while the
  value is empty, `mask` renders a fixed glyph for a password field, and `style`
  fills the field width. State (`value` / `cursor` / `offset`) is an
  `#input_state{}` threaded by the caller, with `new/0`, `value/1`, `set_value/2`,
  and `cursor/1`. A multi-line textarea is a separate, later widget.
- **`tuition_barchart`** — a stateless widget for labeled categorical bars,
  complementing the compact, unlabeled `tuition_sparkline` with a readable chart
  of a handful of named quantities (per-scheduler utilisation, a memory-by-type
  breakdown, top-N process bars). `vertical` (default) grows columns upward with
  labels in a row beneath and each value printed on its base; `horizontal` grows
  bars rightward, one per row, with the label in a left column and the value
  right-aligned in a right column so a top-N list's numbers align. Bars share one
  scale (`max` `auto` or an explicit ceiling) and use the eighth-block sub-cell
  fill (the sparkline's set drawn bottom-up, the gauge's drawn left-to-right), so
  a value between two cells still shows its true length; over-`max` values clamp
  and negative values count as zero. Each bar carries its own `value`, `label`,
  glyph `style`, and an optional `text_value` to print something other than the
  number (`"82%"`, `"1.2G"`, or `none` to print nothing); `bar_width` / `bar_gap`
  size and space the bars, and `label_style` / `value_style` colour the text.
  Bars past the far edge are clipped, never wrapped. Grouped bars are a later
  enhancement.
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
