defmodule Tuition.AliasesTest do
  use ExUnit.Case, async: true

  # The anti-lag guard (issue #47, task 4): the facade must track the Erlang
  # surface so it cannot silently fall behind. There are no per-function wrappers
  # to lag here — records auto-extract from the `.hrl`s and aliases point straight
  # at the Erlang modules — so the one thing that *could* drift is the alias set
  # omitting a newly added public module. This test forces every `:tuition_*`
  # module to be classified as either aliased (public) or internal.

  # Deliberately unaliased: terminal backends, input plumbing, the ssh channel,
  # and the demos — internal seams a consumer never calls directly. Adding a
  # public module means aliasing it in `Tuition`; adding an internal one means
  # listing it here. Either way the choice is forced to be explicit.
  @internal ~w(
    tuition_term tuition_term_local tuition_term_ssh tuition_loop_term
    tuition_input tuition_input_driver tuition_ssh_cli
    tuition_demo tuition_widget_demo
  )a

  defp erlang_modules do
    Application.spec(:tuition, :modules)
    |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "tuition_"))
    |> MapSet.new()
  end

  defp aliased, do: Tuition.default_aliases() |> Keyword.keys() |> MapSet.new()

  test "every public :tuition_* module is aliased; every other is marked internal" do
    all = erlang_modules()
    aliased = aliased()
    internal = MapSet.new(@internal)

    assert MapSet.disjoint?(aliased, internal),
           "a module is both aliased and marked internal: " <>
             inspect(MapSet.to_list(MapSet.intersection(aliased, internal)))

    unclassified = MapSet.difference(all, MapSet.union(aliased, internal))

    assert MapSet.equal?(unclassified, MapSet.new()),
           "these :tuition_* modules are neither aliased in Tuition nor marked " <>
             "internal in this test — classify them: " <>
             inspect(MapSet.to_list(unclassified))
  end

  test "no stale alias or internal entries (each still names a real module)" do
    all = erlang_modules()
    assert MapSet.subset?(aliased(), all), "aliasing a module that no longer exists"
    assert MapSet.subset?(MapSet.new(@internal), all), "excluding a module that no longer exists"
  end

  test "alias targets are unique, bare (single-segment) names" do
    {mods, names} = Enum.unzip(Tuition.default_aliases())

    assert length(mods) == length(Enum.uniq(mods)), "duplicate Erlang module key"
    assert length(names) == length(Enum.uniq(names)), "duplicate alias name"

    for name <- names do
      # `alias …, as:` rejects a nested alias, so every target must be one segment.
      assert length(Module.split(name)) == 1, "#{inspect(name)} is not a bare alias"
    end
  end
end
