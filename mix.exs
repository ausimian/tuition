defmodule Tuition.MixProject do
  use Mix.Project

  # Version is single-sourced from `src/tuition.app.src` — the rebar3-native
  # application resource stays the one version of record, so a bump there flows
  # to both build systems and there is nothing to keep in sync. Consulted at
  # Mixfile-evaluation time; `@external_resource` recompiles dependents on edit.
  @app_src "src/tuition.app.src"
  @external_resource @app_src
  {:ok, [{:application, :tuition, props}]} = :file.consult(@app_src)
  @version props |> Keyword.fetch!(:vsn) |> List.to_string()

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
      # `{:d, :TUITION_NO_SSH_BEHAVIOUR}` suppresses the compile-time
      # `ssh_server_channel` behaviour lint in `tuition_ssh_cli`: Mix does not put
      # `:ssh` on the Erlang compile path (it is not a runtime dependency — see
      # `application/0`), so the lint cannot resolve here, whereas rebar3 keeps it.
      erlc_options: [:debug_info, :warnings_as_errors, {:d, :TUITION_NO_SSH_BEHAVIOUR}],
      deps: deps(),
      description: description(),
      source_url: @source_url,
      docs: docs()
    ]
  end

  # ExDoc reads the same OTP `-doc`/`-moduledoc` chunks under Mix as `rebar3
  # ex_doc` does under rebar3 (issue #46), so `mix docs` and `rebar3 ex_doc`
  # render one shared body of prose. `main: "readme"` lands the README as the
  # docs home page; the Erlang modules in `src/` and the Elixir facade in `lib/`
  # both appear, documented from their doc chunks.
  # The `notebooks/*.livemd` extras are the runnable per-widget showcases (issue
  # #56): ExDoc renders each as a docs page, copies the raw `.livemd` next to it,
  # and adds the Run-in-Livebook badge itself — pointed at that copy, resolved from
  # the page's own URL, so a notebook carries no badge markup of its own. Kept in
  # step with the `ex_doc` stanza in `rebar.config` — the two build systems each
  # carry their own copy of this list.
  defp docs do
    [
      main: "readme",
      extras: ["README.md", "notebooks/list.livemd", "LICENSE"],
      groups_for_extras: ["Widget showcases": ~r{notebooks/}],
      source_url: @source_url
    ]
  end

  # Runtime applications mirror `src/tuition.app.src` exactly: `[:kernel,
  # :stdlib]` and nothing more. `:ssh` is deliberately *not* listed — it is used
  # only by `tuition_ssh_cli`/`tuition_term_ssh`, and a consumer of the SSH
  # backend starts `:ssh` itself (via `ssh:daemon/2,3`), exactly as under rebar.
  # Listing it here — even as `{:ssh, :optional}` — puts `:ssh` in the generated
  # `.app`'s `applications` list, so `Application.ensure_all_started(:tuition)`
  # would drag `:ssh`/`:crypto`/`:asn1`/`:public_key` into the local-terminal
  # path (`:optional` only suppresses the error when ssh is *absent*; when it is
  # present it is still started). The only compile-time need for `:ssh` — the
  # `ssh_server_channel` behaviour lint — is handled by the `erlc_options` macro
  # above, not by listing it here. `:kernel`/`:stdlib` are implicit under Mix but
  # kept explicit to match the app resource one-for-one.
  def application do
    [extra_applications: [:kernel, :stdlib]]
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
