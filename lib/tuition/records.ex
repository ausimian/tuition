defmodule Tuition.Records do
  @moduledoc """
  Elixir record macros for tuition's consumer-facing records.

  tuition is pure Erlang; the geometry and terminal values it hands an Elixir
  consumer — `#rect{}`, `#caps{}`, `#cell{}` — are Erlang records, plain tagged
  tuples with no native Elixir face. This module defines the standard
  `Record.defrecord/2` macros for them (`rect/0,1,2`, `caps/0,1,2`, `cell/0,1,2`),
  so an Elixir consumer constructs, matches and updates them idiomatically:

      import Tuition.Records

      area = rect(x: 0, y: 0, w: 80, h: 24)   # construct
      rect(w: w, h: h) = area                  # pattern match / destructure
      area = rect(area, w: 40)                 # update a field
      w = rect(area, :w)                        # read one field

  The field lists are lifted straight from the shipped `.hrl`s with
  `Record.extract/2`, so these macros cannot drift from the records they wrap —
  add a field to `#rect{}` and it appears here on the next compile.

  Most consumers pull these in through `use Tuition` (which imports this module)
  rather than importing it directly. The widget *state* records (`#list_state{}`
  and friends) are deliberately absent: they already have full function APIs
  (`:tuition_list.new/0`, `next/2`, …), so a consumer never touches their fields.

  ## `.hrl` path resolution

  `from:` is resolved against the compile-time working directory. Extraction runs
  here, at *tuition's* own compile, where the cwd is the tuition project root and
  `include/*.hrl` resolves — both in-repo and when tuition is compiled as a
  dependency (Mix compiles each dep from within its own directory). Consumers
  never re-extract; they import the macros defined here.

  Each header is also declared an `@external_resource`, so Mix recompiles this
  module whenever a record's `.hrl` changes. Without that, an incremental build
  would recompile the Erlang modules that `-include` the header but leave these
  macros on stale field positions/defaults until a clean build — the very drift
  the extraction is meant to prevent.
  """

  require Record

  # Single-sourced header paths, shared by `Record.extract/2` below and the
  # `@external_resource` declarations that tie this module's recompilation to
  # them (the same pattern mix.exs uses for `src/tuition.app.src`).
  @rect_hrl "include/tuition_layout.hrl"
  @caps_hrl "include/tuition_caps.hrl"
  @cell_hrl "include/tuition_term.hrl"
  @external_resource @rect_hrl
  @external_resource @caps_hrl
  @external_resource @cell_hrl

  @doc """
  Record macros for the geometry rectangle `#rect{}` (`include/tuition_layout.hrl`):
  a zero-based `{x, y}` origin and a `w`×`h` size in cells.
  """
  Record.defrecord(:rect, Record.extract(:rect, from: @rect_hrl))

  @doc """
  Record macros for the terminal capability set `#caps{}`
  (`include/tuition_caps.hrl`): the optional enrichments a probe turns on.
  """
  Record.defrecord(:caps, Record.extract(:caps, from: @caps_hrl))

  @doc """
  Record macros for a single rendered cell `#cell{}` (`include/tuition_term.hrl`):
  a glyph plus its style and cached column width.
  """
  Record.defrecord(:cell, Record.extract(:cell, from: @cell_hrl))
end
