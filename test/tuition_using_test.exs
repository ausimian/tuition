# Consumer modules exercising each `use Tuition` / `use Tuition.Pane` variant.
# Defined at load time so the macro expansion itself is under test.

defmodule Tuition.UsingTest.RecordsOnly do
  use Tuition
  # No aliases requested: bare `Layout` must NOT resolve here, but the record
  # macros must. (A stray `Layout.area(...)` would fail to compile.)
  def build, do: rect(x: 1, y: 2, w: 3, h: 4)
end

defmodule Tuition.UsingTest.AliasesAll do
  use Tuition, aliases: true

  def area, do: Layout.area({80, 24})
  def split, do: Layout.split(:vertical, [{:fixed, 1}, :fill], Layout.area({80, 24}))
  def inner, do: Block.inner(%{borders: :all}, rect(x: 0, y: 0, w: 10, h: 4))
end

defmodule Tuition.UsingTest.NamedSubset do
  use Tuition, aliases: [tuition_layout: L, tuition_list: ListWidget]

  def area, do: L.area({10, 10})
  def list_selected, do: ListWidget.new() |> ListWidget.next(5) |> ListWidget.selected()
  # Aliasing :tuition_list as ListWidget (not List) leaves the stdlib intact:
  def stdlib_list, do: List.first([:a, :b, :c])
end

defmodule Tuition.UsingTest.NoRecords do
  use Tuition, records: false, aliases: [tuition_width: Width]
  def width(s), do: Width.width(s)
end

defmodule Tuition.UsingTest.SamplePane do
  use Tuition.Pane, aliases: [tuition_block: Block]

  @impl true
  def new, do: %{width: nil}

  @impl true
  def render(rect(w: w) = area, buf, state) do
    {Block.render(%{borders: :all, title: "t"}, area, buf), %{state | width: w}}
  end

  @impl true
  def apply_events(events, state) do
    if :quit in events, do: :quit, else: {:ok, state}
  end

  @impl true
  def sample(state), do: state
end

defmodule Tuition.UsingTest do
  use ExUnit.Case, async: true
  import Tuition.Records

  test "default `use Tuition` brings record macros into scope" do
    assert Tuition.UsingTest.RecordsOnly.build() == :tuition_layout.rect(1, 2, 3, 4)
  end

  test "`aliases: true` aliases the whole Erlang module set" do
    assert Tuition.UsingTest.AliasesAll.area() == :tuition_layout.rect(0, 0, 80, 24)
    assert [top, body] = Tuition.UsingTest.AliasesAll.split()
    assert rect(top, :h) == 1
    assert rect(body, :h) == 23

    assert Tuition.UsingTest.AliasesAll.inner() ==
             :tuition_block.inner(%{borders: :all}, {:rect, 0, 0, 10, 4})
  end

  test "a caller-named subset controls clashes and keeps the stdlib" do
    assert Tuition.UsingTest.NamedSubset.area() == :tuition_layout.rect(0, 0, 10, 10)
    assert Tuition.UsingTest.NamedSubset.list_selected() == 0
    # stdlib List was not shadowed:
    assert Tuition.UsingTest.NamedSubset.stdlib_list() == :a
  end

  test "`records: false` skips the record import but still aliases" do
    assert Tuition.UsingTest.NoRecords.width("A") == 1
  end

  describe "use Tuition.Pane" do
    alias Tuition.UsingTest.SamplePane

    test "declares the :tuition_pane behaviour" do
      behaviours =
        SamplePane.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

      assert :tuition_pane in behaviours
    end

    test "authors callbacks in Elixir, matching #rect{} directly" do
      buf = :tuition_render.new({10, 4})
      {out, state} = SamplePane.render(:tuition_layout.rect(0, 0, 10, 4), buf, SamplePane.new())
      assert state.width == 10
      assert :tuition_render.size(out) == {10, 4}
    end

    test "apply_events honours the return contract" do
      assert {:ok, %{}} = SamplePane.apply_events([], SamplePane.new())
      assert :quit = SamplePane.apply_events([:quit], SamplePane.new())
    end
  end
end
