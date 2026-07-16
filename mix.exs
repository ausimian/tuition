defmodule Tuition.MixProject do
  use Mix.Project

  # Version is single-sourced from `src/tuition.app.src` — the rebar3-native
  # application resource stays the one version of record, so a bump there flows
  # to both build systems and there is nothing to keep in sync. Consulted at
  # Mixfile-evaluation time; `@external_resource` recompiles dependents on edit.
  @app_src "src/tuition.app.src"
  @external_resource @app_src
  @version (case :file.consult(@app_src) do
              {:ok, [{:application, :tuition, props}]} ->
                props |> Keyword.fetch!(:vsn) |> List.to_string()
            end)

  @source_url "https://github.com/ausimian/tuition"

  def project do
    [
      app: :tuition,
      version: @version,
      # One minor below the preferred toolchain (Elixir 1.19), per org build
      # conventions, so consumers on 1.18 are not needlessly excluded.
      elixir: "~> 1.18",
      # Mix compiles both `src/*.erl` (built-in :erlang compiler) and `lib/*.ex`,
      # whereas rebar3 never sees `mix.exs`/`lib/` — so Erlang/rebar3 consumers
      # still pull pure Erlang, zero Elixir. `include/` is already the default
      # erlc include dir, so the `-include("tuition_*.hrl")` directives in `src/`
      # resolve; it is named explicitly here as documentation of the contract.
      erlc_paths: ["src"],
      erlc_include_path: "include",
      erlc_options: [:debug_info, :warnings_as_errors],
      deps: deps(),
      description: description(),
      source_url: @source_url
    ]
  end

  # Runtime applications mirror `src/tuition.app.src`. `:ssh` is optional — only
  # `tuition_ssh_cli`/`tuition_term_ssh` use it, so the local-terminal path must
  # not drag it in. `:kernel`/`:stdlib` are implicit under Mix but kept explicit
  # to match the app resource one-for-one.
  def application do
    [extra_applications: [:kernel, :stdlib, {:ssh, :optional}]]
  end

  defp deps do
    [
      # Consumed in Phase 2 (edoc → -doc/ex_doc, HexDocs). Dev-only and
      # non-runtime, so it never enters a consumer's dependency chain.
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Pure-Erlang terminal UI framework: backends, input, rendering, layout, " <>
      "widgets, app shell."
  end
end
