defmodule Tuition.Pane do
  @moduledoc """
  Author a `:tuition_pane` in idiomatic Elixir.

  A pane is any module implementing the Erlang `:tuition_pane` behaviour, which
  `:tuition_shell` hosts. `use Tuition.Pane` declares that behaviour and pulls in
  the record macros (and, optionally, module aliases) a pane needs — so the
  shell calls your module directly, no adapter layer in between.

      defmodule ClockPane do
        use Tuition.Pane, aliases: [tuition_block: Block, tuition_paragraph: Paragraph]

        @impl true
        def new, do: %{now: :calendar.local_time()}

        @impl true
        def render(rect() = area, buf, state) do
          block = %{borders: :all, title: "Clock"}
          text = :io_lib.format("~p", [state.now])
          buf = Block.render(block, area, buf)
          {Paragraph.render(%{text: text}, Block.inner(block, area), buf), state}
        end

        @impl true
        def apply_events(events, state) do
          if Enum.any?(events, &match?({:key, {:char, ?q}, []}, &1)), do: :quit, else: {:ok, state}
        end

        @impl true
        def sample(state), do: %{state | now: :calendar.local_time()}
      end

  ## The callbacks

  The shell calls the standard `:tuition_pane` callbacks; author them in Elixir:

    * `new/0` — the initial state.
    * `render/3` — `render(area, buf, state)` where `area` is a `#rect{}` record
      (match it with the `rect/0,1,2` macros this brings into scope) and `buf` is
      an opaque render buffer; returns `{buf, state}`.
    * `apply_events/2` — fold input events into the state; return `{:ok, state}`,
      `{:sample, state}`, or `:quit`.
    * `sample/1` — refresh the state from the live node (a static pane returns it
      unchanged).
    * `setup/0` / `teardown/1` — optional lifecycle hooks.

  Because the shell passes and expects the Erlang `#rect{}` record directly,
  there is nothing to convert: match `render`'s `area` with `rect(w: w, h: h)`
  and hand it straight to a widget's `render`.

  ## Options

  Same as `use Tuition`: `records:` (default `true`) and `aliases:` (a keyword
  list of `erlang_module: Alias`, or `true` for the full default set). See the
  `Tuition` moduledoc for the default alias names.
  """

  defmacro __using__(opts) do
    injected = Tuition.build(opts, Tuition.default_aliases())

    quote do
      @behaviour :tuition_pane
      unquote(injected)
    end
  end
end
