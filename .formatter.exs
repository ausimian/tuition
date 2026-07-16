# Scoped to the Elixir surface only. `src/*.erl`, `include/*.hrl` and the eunit
# `test/*.erl` are erlfmt's (see `rebar.config`); `mix format` must not touch
# them, so they are deliberately excluded from `inputs`.
[
  inputs: ["mix.exs", ".formatter.exs", "{lib,test}/**/*.{ex,exs}"]
]
