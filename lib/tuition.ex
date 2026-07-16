defmodule Tuition do
  @moduledoc """
  Elixir conveniences for the pure-Erlang [tuition](https://github.com/ausimian/tuition)
  terminal-UI framework.

  tuition is written entirely in Erlang and keeps zero Elixir in the chain for
  Erlang/rebar3 consumers. This module — compiled only by Mix — is a thin
  courtesy layer for Elixir consumers that adds no runtime code of its own: it
  brings the framework's Erlang records and modules into scope under idiomatic
  Elixir names, the standard way Elixir consumes an Erlang library
  (`Record.defrecord/2` + `alias`).

      defmodule Dashboard do
        use Tuition.Pane, aliases: [tuition_block: Block, tuition_gauge: Gauge]

        @impl true
        def new, do: %{load: 0.0}

        @impl true
        def render(rect(w: _w) = area, buf, state) do
          inner = :tuition_block.inner(%{borders: :all, title: "Load"}, area)
          buf = Block.render(%{borders: :all, title: "Load"}, area, buf)
          {Gauge.render(%{ratio: state.load}, inner, buf), state}
        end

        # ... apply_events/2, sample/1
      end

  ## `use Tuition`

  `use Tuition` accepts two options:

    * `records:` — `true` (default) imports `Tuition.Records`, bringing the
      `rect/0,1,2`, `caps/0,1,2` and `cell/0,1,2` record macros into scope.
      `false` skips them.

    * `aliases:` — opt-in module aliases. Pass a keyword list mapping each Erlang
      module to the (bare) name you want, so *you* control any name clash:

          use Tuition, aliases: [tuition_list: ListWidget, tuition_table: Table]

      Or pass `true` for the full default set (see the table below). The default
      set includes `tuition_list` aliased to `List`, which **shadows Elixir's
      `List`** in that module — prefer a per-module keyword list unless you want
      the lot.

  Because `alias`'s `:as` accepts only a bare name (not a `Tuition.`-prefixed
  one), the aliases land in your module's top-level namespace. That is why they
  are opt-in and caller-named rather than injected wholesale.

  ## Default alias names

  `aliases: true` (and the names to reach for in a keyword list) map as:

  | Erlang module          | Alias         | Erlang module          | Alias        |
  |------------------------|---------------|------------------------|--------------|
  | `:tuition_layout`      | `Layout`      | `:tuition_paragraph`   | `Paragraph`  |
  | `:tuition_caps`        | `Caps`        | `:tuition_scrollbar`   | `Scrollbar`  |
  | `:tuition_render`      | `Render`      | `:tuition_scrollview`  | `ScrollView` |
  | `:tuition_shell`       | `Shell`       | `:tuition_sparkline`   | `Sparkline`  |
  | `:tuition_pane`        | `Pane`        | `:tuition_spinner`     | `Spinner`    |
  | `:tuition_widget`      | `Widget`      | `:tuition_table`       | `Table`      |
  | `:tuition_barchart`    | `Barchart`    | `:tuition_tabs`        | `Tabs`       |
  | `:tuition_block`       | `Block`       | `:tuition_text`        | `Text`       |
  | `:tuition_braille`     | `Braille`     | `:tuition_tree`        | `Tree`       |
  | `:tuition_canvas`      | `Canvas`      | `:tuition_input_field` | `InputField` |
  | `:tuition_chart`       | `Chart`       | `:tuition_width`       | `Width`      |
  | `:tuition_clear`       | `Clear`       | `:tuition_list`        | `List` ⚠     |
  | `:tuition_gauge`       | `Gauge`       | `:tuition_line_gauge`  | `LineGauge`  |

  Widget configs and styles are already plain maps with atom keys
  (`%{items: [...], highlight_style: %{fg: 1}}`), and every stateful widget
  already exposes a full function API — so once the records and aliases are in
  scope there is nothing further to wrap.
  """

  # The default Erlang-module -> Elixir-alias map. Values are bare aliases, so
  # they resolve to plain module atoms (`Elixir.Layout`, …) here — none of these
  # modules is defined, so there is nothing to collide with at this point;
  # `:tuition_list` -> `List` shadows the stdlib only in a consumer that opts in.
  @aliases [
    tuition_layout: Layout,
    tuition_caps: Caps,
    tuition_render: Render,
    tuition_shell: Shell,
    tuition_pane: Pane,
    tuition_widget: Widget,
    tuition_barchart: Barchart,
    tuition_block: Block,
    tuition_braille: Braille,
    tuition_canvas: Canvas,
    tuition_chart: Chart,
    tuition_clear: Clear,
    tuition_gauge: Gauge,
    tuition_line_gauge: LineGauge,
    tuition_list: List,
    tuition_paragraph: Paragraph,
    tuition_scrollbar: Scrollbar,
    tuition_scrollview: ScrollView,
    tuition_sparkline: Sparkline,
    tuition_spinner: Spinner,
    tuition_table: Table,
    tuition_tabs: Tabs,
    tuition_text: Text,
    tuition_tree: Tree,
    tuition_input_field: InputField,
    tuition_width: Width
  ]

  @doc """
  The default `{erlang_module, alias}` map used by `aliases: true`.

  Exposed so the alias set can be introspected (and coverage-tested against the
  set of public `:tuition_*` modules, so it cannot silently lag behind a newly
  added widget).
  """
  @spec default_aliases() :: [{module(), module()}]
  def default_aliases, do: @aliases

  defmacro __using__(opts) do
    build(opts, @aliases)
  end

  # Shared by `use Tuition` and `use Tuition.Pane`: the record import and the
  # requested aliases, as one spliced block.
  @doc false
  def build(opts, default_aliases) do
    import_ast =
      if Keyword.get(opts, :records, true) do
        quote(do: import(Tuition.Records))
      end

    alias_asts =
      case Keyword.get(opts, :aliases, []) do
        true -> Enum.map(default_aliases, &alias_one/1)
        list when is_list(list) -> Enum.map(list, &alias_one/1)
        _ -> []
      end

    quote do
      unquote(import_ast)
      unquote_splicing(alias_asts)
    end
  end

  defp alias_one({erlang_module, as}) do
    quote do
      alias unquote(erlang_module), as: unquote(as)
    end
  end
end
