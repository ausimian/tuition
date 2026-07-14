%%%-------------------------------------------------------------------
%%% @doc Clear widget — reset a rect to blanks, the overlay/popup primitive
%%% (stateless).
%%%
%%% Immediate-mode rendering composites widgets into one buffer in draw order
%%% ({@link tuition_widget}), but nothing in that vocabulary *resets* a region:
%%% a widget only ever draws its own cells in. To float a modal popup, a
%%% confirm dialog or a help overlay on top of whatever is already there, the
%%% overlay is drawn last — and its region must first be wiped so the content
%%% drawn beneath it earlier in the same frame cannot show through the gaps the
%%% overlay itself leaves untouched. `tuition_clear' is that wipe: it blanks
%%% `Area', resetting every cell to a plain space, so the overlay then draws
%%% onto a clean slate. It is ratatui's `Clear', and the prerequisite for the
%%% centered-popup pattern (a `centered_rect/3' layout helper to place one is
%%% the deferred follow-up — see issue #7).
%%%
%%% == Why not {@link tuition_widget:fill/3}? ==
%%% `fill/3' does the same row-by-row space fill, but it deliberately *no-ops*
%%% an empty style: a {@link tuition_block} painting its background with the
%%% default style leaves the region untouched so a parent's background shows
%%% through, rather than stamping default-blank cells over it. Clear's contract
%%% is the exact opposite — with the default (empty) style it must still
%%% overwrite, resetting each cell to a default-blank space; that reset *is* the
%%% widget. So Clear always fills, and only the default differs: an empty style
%%% (the default) resets to a plain default/default space, while a non-empty
%%% `style' paints a styled blank instead — a coloured backdrop for the popup
%%% about to be drawn over it.
%%%
%%% Resetting a cell to the default blank composes correctly with wide glyphs:
%%% overwriting either half of a two-column glyph beneath the region dissolves
%%% its orphaned partner too ({@link tuition_render}), so no stray half is left
%%% straddling the cleared edge.
%%%
%%% == Config ==
%%% A `#{}' map, the one key optional:
%%% <ul>
%%%   <li>`style' — the blank's style (default: unstyled, i.e. a plain
%%%       default/default space). Set `bg' to lay a coloured backdrop under the
%%%       overlay; leave it out to reset to the terminal default.</li>
%%% </ul>
%%%
%%% HARD CONSTRAINT (PRD §12): depends only on `kernel'/`stdlib'/`erts' plus the
%%% sibling render/layout modules. No third-party code.
%%% @end
%%%-------------------------------------------------------------------
-module(tuition_clear).
-behaviour(tuition_widget).

-include("tuition_layout.hrl").

-export([render/3]).

-type clear() :: #{style => tuition_render:style()}.

-export_type([clear/0]).

%%% -- render ----------------------------------------------------------

%% @doc Reset every cell of `Area' to a blank space, returning the buffer with the
%% region wiped. A degenerate area (no columns or rows) draws nothing. Unlike
%% {@link tuition_widget:fill/3}, the default (empty) style still overwrites — the
%% reset is the point; a non-empty `style' paints a styled blank instead. See the
%% module doc for the config map.
-spec render(clear(), #rect{}, tuition_render:buffer()) -> tuition_render:buffer().
render(_Cfg, #rect{w = W, h = H}, Buf) when W =< 0; H =< 0 ->
    Buf;
render(Cfg, #rect{x = X, y = Y, w = W, h = H}, Buf) ->
    Style = maps:get(style, Cfg, #{}),
    Spaces = binary:copy(<<" ">>, W),
    lists:foldl(
        fun(Row, B) -> tuition_render:put_text(B, X, Y + Row, Spaces, Style) end,
        Buf,
        lists:seq(0, H - 1)
    ).
