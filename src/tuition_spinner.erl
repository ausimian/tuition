-module(tuition_spinner).
-moduledoc """
An in-flight "working…" indicator (stateless).

A spinner draws a single animated glyph (optionally followed by a label) that a
pane shows while an async operation is pending, so the view signals "loading"
rather than looking frozen or showing stale data. It is the ratatui
`throbber-widgets-tui` idiom: the standard cue a pane raises while a slow read is
in flight, paired with the pane's "pending" flag.

## A pure function of `frame`

The spinner holds nothing between frames and owns no timer: which glyph shows is
purely `frame rem length` of the chosen glyph set. The caller keeps the tick
counter — the shell already ticks every pane (the `m:tuition_pane` idle/sample
tick that drives live refresh), so a pane increments `frame` per redraw and
passes it in as config. It implements the plain `m:tuition_widget` `render/3`
callback, with nothing to thread across the immediate-mode rebuild.

Because animation is just the frame index, the same `frame` always renders the
same glyph: a headless test can assert a whole cycle by rendering `0, 1, 2, …`
with no clock involved, and a negative `frame` is handled (indexed from the end
of the cycle) rather than crashing.

## Glyph sets

Every built-in set is single-column, so the glyph never changes width from one
frame to the next and a trailing label stays put rather than jittering:

- `braille` (default) — the light 10-frame dot-chase `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`, the spinner
  most terminals show.
- `dots` — a heavier 8-frame filled-braille rotation `⣾⣽⣻⢿⡿⣟⣯⣷`, the same family
  as `braille` but bolder.
- `line` — the 4-frame ASCII `|/-\\`, the universal fallback for a terminal
  without braille coverage.
- a custom list of glyphs (each one chardata), cycled in order — pass your own
  frames, e.g. the quadrant or half-circle spinners. Keep them a uniform width so
  the label does not shift; the widget positions the label after the glyph's
  measured width regardless, but a set of varying widths makes the label wander.
  An empty list draws no glyph.

## Layout

The glyph sits at the top-left of the area; a label, when present, is drawn one
blank column after it, both on the top row and clipped to the area (a taller area
leaves the rows below untouched, so a spinner tiles into a single line of a
larger pane). Keep it tiny — one glyph plus an optional short label is the whole
footprint.

## Config

A map, every key optional:

- `frame` — the tick, any integer (default `0`); the widget shows glyph `frame
  rem length` of the set, wrapping (and counting back from the end for a negative
  tick).
- `set` — `braille` (default), `dots`, `line`, or a non-empty list of custom
  glyphs.
- `label` — `none` (default) or chardata drawn one column after the glyph.
- `style` — the style of the spinner glyph (default: unstyled; set at least `fg`
  to colour it).
- `label_style` — the label's style (default: unstyled).
""".
-behaviour(tuition_widget).

-include("tuition_layout.hrl").

-export([render/3]).

-type set() :: braille | dots | line | [unicode:chardata()].

-type spinner() :: #{
    frame => integer(),
    set => set(),
    label => none | unicode:chardata(),
    style => tuition_render:style(),
    label_style => tuition_render:style()
}.

-export_type([spinner/0, set/0]).

%% The light dot-chase (default `braille' set): U+280B U+2819 U+2839 U+2838 U+283C
%% U+2834 U+2826 U+2827 U+2807 U+280F — ten braille frames of a single dot orbiting.
-define(BRAILLE, [
    16#280B, 16#2819, 16#2839, 16#2838, 16#283C, 16#2834, 16#2826, 16#2827, 16#2807, 16#280F
]).
%% The heavier filled-braille rotation (`dots' set): U+28FE U+28FD U+28FB U+28BF
%% U+287F U+28DF U+28EF U+28F7 — eight frames of a full braille cell turning.
-define(DOTS, [16#28FE, 16#28FD, 16#28FB, 16#28BF, 16#287F, 16#28DF, 16#28EF, 16#28F7]).
%% The ASCII fallback (`line' set): the four-frame `|/-\' bar.
-define(LINE_SET, [$|, $/, $-, $\\]).

%%% -- render ----------------------------------------------------------

-doc """
Draw the spinner into `Area`, on its top row. An empty area (no columns or rows)
draws nothing. See the module doc for the config map.
""".
-spec render(spinner(), #rect{}, tuition_render:buffer()) -> tuition_render:buffer().
render(_Cfg, #rect{w = W, h = H}, Buf) when W =< 0; H =< 0 ->
    Buf;
render(Cfg, Area, Buf0) ->
    Frame = maps:get(frame, Cfg, 0),
    Glyphs = glyphs(maps:get(set, Cfg, braille)),
    Glyph = current_glyph(Glyphs, Frame),
    Style = maps:get(style, Cfg, #{}),
    %% Glyph at the top-left, then learn its drawn width so the label can follow one
    %% blank column after it (and start at column 0 when the set is empty and no
    %% glyph was drawn).
    Buf1 = tuition_widget:put_line(Buf0, Area, 0, 0, Glyph, Style),
    draw_label(Buf1, Area, Cfg, tuition_widget:display_width(Glyph)).

%%% -- label -----------------------------------------------------------

%% Draw the label one blank column after the glyph (or at column 0 when the glyph
%% is empty), on the top row, clipped to the area. `label => none' (the default)
%% draws nothing.
-spec draw_label(tuition_render:buffer(), #rect{}, spinner(), non_neg_integer()) ->
    tuition_render:buffer().
draw_label(Buf, Area, Cfg, GlyphW) ->
    case maps:get(label, Cfg, none) of
        none ->
            Buf;
        Text ->
            Style = maps:get(label_style, Cfg, #{}),
            Col = label_col(GlyphW),
            tuition_widget:put_line(Buf, Area, Col, 0, Text, Style)
    end.

%% The column the label begins at: flush left when there is no glyph, else one
%% blank column past the glyph's width.
-spec label_col(non_neg_integer()) -> non_neg_integer().
label_col(0) -> 0;
label_col(GlyphW) -> GlyphW + 1.

%%% -- glyph selection -------------------------------------------------

%% The glyph set as a list of frames: the built-in sets (lists of codepoints), or a
%% caller's custom list (chardata glyphs) passed through verbatim.
-spec glyphs(set()) -> [char() | unicode:chardata()].
glyphs(braille) -> ?BRAILLE;
glyphs(dots) -> ?DOTS;
glyphs(line) -> ?LINE_SET;
glyphs(Custom) when is_list(Custom) -> Custom.

%% The frame `Frame' selects, as a UTF-8 binary. An empty set (a custom `[]') has no
%% glyph, so it draws nothing. Otherwise the index wraps with `rem', normalised to
%% `[0, N)' so a negative tick counts back from the end of the cycle rather than
%% crashing `lists:nth/2'.
-spec current_glyph([char() | unicode:chardata()], integer()) -> binary().
current_glyph([], _Frame) ->
    <<>>;
current_glyph(Glyphs, Frame) ->
    N = length(Glyphs),
    Idx = ((Frame rem N) + N) rem N,
    to_glyph(lists:nth(Idx + 1, Glyphs)).

%% Normalise one frame to a UTF-8 binary: a built-in set's codepoint integer, or a
%% custom glyph's chardata.
-spec to_glyph(char() | unicode:chardata()) -> binary().
to_glyph(Cp) when is_integer(Cp) -> <<Cp/utf8>>;
to_glyph(Chardata) -> to_bin(Chardata).

%% Best-effort chardata -> UTF-8 binary; a malformed tail contributes whatever
%% prefix decoded, matching tuition_widget's own tolerance for untrusted content.
-spec to_bin(unicode:chardata()) -> binary().
to_bin(Text) ->
    case unicode:characters_to_binary(Text) of
        Bin when is_binary(Bin) -> Bin;
        {error, Good, _Rest} -> Good;
        {incomplete, Good, _Rest} -> Good
    end.
