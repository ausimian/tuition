defmodule Tuition.RecordsTest do
  use ExUnit.Case, async: true
  import Tuition.Records

  describe "rect/0,1,2" do
    test "constructs the same #rect{} the Erlang API builds" do
      assert rect(x: 1, y: 2, w: 3, h: 4) == :tuition_layout.rect(1, 2, 3, 4)
    end

    test "defaults match the record definition" do
      assert rect() == {:rect, 0, 0, 0, 0}
    end

    test "reads fields, agreeing with the Erlang accessors" do
      r = :tuition_layout.rect(5, 6, 7, 8)
      assert rect(r, :x) == :tuition_layout.x(r)
      assert rect(r, :y) == :tuition_layout.y(r)
      assert rect(r, :w) == :tuition_layout.w(r)
      assert rect(r, :h) == :tuition_layout.h(r)
    end

    test "updates a field" do
      r = rect(x: 1, y: 2, w: 3, h: 4)
      assert rect(r, w: 30) == rect(x: 1, y: 2, w: 30, h: 4)
    end

    test "pattern-matches and destructures" do
      rect(w: w, h: h) = :tuition_layout.rect(0, 0, 12, 9)
      assert {w, h} == {12, 9}
    end
  end

  describe "caps/0,1,2" do
    test "the zero-arg record equals the Erlang baseline" do
      assert caps() == :tuition_caps.baseline()
    end

    test "sets and reads a capability flag" do
      c = caps(truecolor: true)
      assert caps(c, :truecolor) == true
      assert caps(c, :sync_output) == false
    end
  end

  describe "cell/0,1,2" do
    test "constructs the same #cell{} the render constructor builds" do
      assert cell(char: ?x) == :tuition_render.cell(?x)
    end

    test "reads back through the render accessors" do
      c = cell(char: ?A, fg: 1, bold: true)
      assert cell(c, :char) == :tuition_render.char(c)
      assert cell(c, :fg) == :tuition_render.fg(c)
      assert cell(c, :bold) == :tuition_render.bold(c)
    end
  end
end
