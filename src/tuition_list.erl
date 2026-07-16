%%%-------------------------------------------------------------------
%%% @doc List widget — a scrollable, selectable column of items (stateful).
%%%
%%% A list draws one item per row, tracks a selected item and a scroll offset,
%%% and highlights the selection. It is the ratatui `List' + `ListState': the
%%% widget the process view and the supervision tree (PRD §9.1) navigate with the
%%% arrow keys.
%%%
%%% == Stateful, by necessity ==
%%% The selection index and scroll offset live in a `#list_state{}' (see
%%% `include/tuition_widget.hrl') held by the *caller*, not in this module — the
%%% renderer is immediate-mode and discards every frame, so state kept inside the
%%% widget would not survive (see {@link tuition_widget}). {@link render/4} takes the
%%% state and returns it, with the scroll offset adjusted so the selection is in
%%% view; the caller keeps the returned value for the next frame. Navigation is
%%% likewise a pure state transition the caller applies to input:
%%% <pre>
%%%   State1 = tuition_list:next(State0, length(Items)),   %% on Down
%%%   {Buf1, State2} = tuition_list:render(Cfg, Area, Buf0, State1).
%%% </pre>
%%% This is ratatui's `StatefulWidget' split, made explicit because Erlang has no
%%% `&mut'.
%%%
%%% == Selection follows the view, the view follows the selection ==
%%% {@link render/4} always reconciles the state against the current item count
%%% and rect height before drawing: a selection stranded past the end of a shrunk
%%% list is clamped back into range, and the offset is nudged just far enough to
%%% keep the selection within the visible window (scrolling one row at a time at
%%% the edges, a page at a time when the selection jumps). So the caller can move
%%% the selection freely and trust the widget to keep it on screen.
%%%
%%% == Config ==
%%% A `#{}' map, every key optional:
%%% <ul>
%%%   <li>`items'            — the rows, each a {@type tuition_text:line_input()}:
%%%       plain chardata as before, or a {@link tuition_text} styled line so a row
%%%       can carry mixed per-span styles over the row's base (default `[]').</li>
%%%   <li>`style'            — base style for every row (default: unstyled).</li>
%%%   <li>`highlight_style'  — style overlaid on the selected row, across its full
%%%       width (default: unstyled — so set at least a colour to make the
%%%       selection visible).</li>
%%%   <li>`highlight_symbol' — a prefix drawn before the selected row (e.g.
%%%       `"> "'); non-selected rows are indented by its width so the columns line
%%%       up (default `<<>>').</li>
%%% </ul>
%%%
%%% HARD CONSTRAINT (PRD §12): depends only on `kernel'/`stdlib'/`erts' plus the
%%% sibling render/layout/width/widget modules. No third-party code.
%%% @end
%%%-------------------------------------------------------------------
-module(tuition_list).

-include("tuition_layout.hrl").
-include("tuition_widget.hrl").

-export([new/0, render/4, next/2, prev/2, select/2, selected/1, reconcile/3]).

-type list_cfg() :: #{
    items => [tuition_text:line_input()],
    style => tuition_render:style(),
    highlight_style => tuition_render:style(),
    highlight_symbol => unicode:chardata()
}.
-type state() :: #list_state{}.

-export_type([list_cfg/0, state/0]).

%%% -- state -----------------------------------------------------------

%% @doc A fresh list state: no selection, unscrolled. A caller that does not want
%% to include `tuition_widget.hrl' can start here and drive it through the API
%% ({@link next/2}, {@link prev/2}, {@link select/2}, {@link selected/1}).
-spec new() -> state().
new() -> #list_state{}.

%% @doc Move the selection to the next item, clamped to the last. From no
%% selection this selects the first item; on an empty list it stays unselected.
-spec next(state(), non_neg_integer()) -> state().
next(#list_state{selected = Sel} = State, Len) ->
    State#list_state{selected = move(Sel, Len, forward)}.

%% @doc Move the selection to the previous item, clamped to the first. From no
%% selection this selects the last item; on an empty list it stays unselected.
-spec prev(state(), non_neg_integer()) -> state().
prev(#list_state{selected = Sel} = State, Len) ->
    State#list_state{selected = move(Sel, Len, backward)}.

%% @doc Set the selection to a specific item (or `none'). The index is clamped to
%% the item count at the next {@link render/4}, so an index that is momentarily
%% out of range is harmless.
-spec select(state(), none | non_neg_integer()) -> state().
select(State, Selected) ->
    State#list_state{selected = Selected}.

%% @doc The currently selected item index, or `none'.
-spec selected(state()) -> none | non_neg_integer().
selected(#list_state{selected = Selected}) -> Selected.

%% One navigation step, clamping a (possibly stale) index into range first so a
%% selection left dangling by a shrunk list still moves sensibly.
-spec move(none | integer(), non_neg_integer(), forward | backward) ->
    none | non_neg_integer().
move(_Sel, 0, _Dir) ->
    none;
move(none, _Len, forward) ->
    0;
move(none, Len, backward) ->
    Len - 1;
move(N, Len, Dir) when is_integer(N) ->
    Clamped = clamp(N, Len),
    case Dir of
        forward -> min(Clamped + 1, Len - 1);
        backward -> max(Clamped - 1, 0)
    end.

%%% -- render ----------------------------------------------------------

%% @doc Draw the visible slice of the list into `Area', highlighting the selected
%% row, and return the buffer together with the reconciled state (selection
%% clamped to the item count, offset adjusted to keep the selection in view). A
%% degenerate area draws nothing but still reconciles the state, so a resize that
%% shrinks a pane to nothing and back leaves a valid selection/offset behind.
-spec render(list_cfg(), #rect{}, tuition_render:buffer(), state()) ->
    {tuition_render:buffer(), state()}.
render(Cfg, #rect{w = W, h = H} = Area, Buf, State0) ->
    Items = maps:get(items, Cfg, []),
    Len = length(Items),
    Visible = H,
    State1 = reconcile(State0, Len, Visible),
    Buf1 =
        case W =:= 0 orelse H =:= 0 of
            true -> Buf;
            false -> draw_items(Cfg, Items, Area, State1, Buf)
        end,
    {Buf1, State1}.

%% @doc Reconcile a `#list_state{}' against the current item count and viewport
%% height: clamp the selection into `[0, Len)' (dropping it to `none' on an empty
%% list) and slide the scroll offset so the selection falls within the `Visible'
%% rows. This is the reconciliation every {@link render/4} begins with, and it is
%% exported so {@link tuition_table} — whose rows are a `#list_state{}' scrolled
%% under a header — reuses the same selection/offset logic rather than
%% re-deriving it. Pure: the returned state is what survives to the next frame.
-spec reconcile(state(), non_neg_integer(), non_neg_integer()) -> state().
reconcile(#list_state{selected = Sel0, offset = Off0}, Len, Visible) ->
    Selected = clamp_selected(Sel0, Len),
    Offset = adjust_offset(Off0, Selected, Visible, Len),
    #list_state{selected = Selected, offset = Offset}.

%% A selection past the end of a shrunk list clamps back into range; an empty list
%% clears the selection entirely.
-spec clamp_selected(none | integer(), non_neg_integer()) -> none | non_neg_integer().
clamp_selected(none, _Len) -> none;
clamp_selected(_Sel, 0) -> none;
clamp_selected(Sel, Len) -> clamp(Sel, Len).

%% Nudge the scroll offset so `Selected' is within `[Offset, Offset + Visible)',
%% then clamp it to a valid range for the current list — pulling up one row when
%% the selection sits above the window, and down when it sits below, which yields
%% one-row scrolling at the edges and a page jump when the selection leaps.
-spec adjust_offset(
    non_neg_integer(), none | non_neg_integer(), non_neg_integer(), non_neg_integer()
) ->
    non_neg_integer().
adjust_offset(_Off, _Selected, 0, _Len) ->
    0;
adjust_offset(Off, Selected, Visible, Len) ->
    Nudged = follow(Off, Selected, Visible),
    MaxOff = max(0, Len - Visible),
    min(max(Nudged, 0), MaxOff).

-spec follow(non_neg_integer(), none | non_neg_integer(), non_neg_integer()) -> integer().
follow(Off, none, _Visible) -> Off;
follow(Off, Selected, _Visible) when Selected < Off -> Selected;
follow(Off, Selected, Visible) when Selected >= Off + Visible -> Selected - Visible + 1;
follow(Off, _Selected, _Visible) -> Off.

%% Draw each visible row: the item at `Offset + Row', with the selected row given
%% a full-width highlight bar and the highlight symbol, the rest indented under
%% that symbol so the item text lines up.
-spec draw_items(
    list_cfg(),
    [tuition_text:line_input()],
    #rect{},
    state(),
    tuition_render:buffer()
) -> tuition_render:buffer().
draw_items(Cfg, Items, #rect{h = H} = Area, #list_state{selected = Selected, offset = Offset}, Buf) ->
    Base = maps:get(style, Cfg, #{}),
    Highlight = maps:get(highlight_style, Cfg, #{}),
    Symbol = maps:get(highlight_symbol, Cfg, <<>>),
    Gutter = binary:copy(<<" ">>, tuition_widget:display_width(Symbol)),
    %% Drop the scrolled-past items once and walk only the visible slice, so a
    %% repaint costs O(Offset + H) rather than O(Offset * H): reconcile has clamped
    %% Offset into [0, length(Items)], so lists:nthtail/2 is safe, and a list that
    %% has scrolled far down (a process view may hold thousands of rows) stays as
    %% cheap to draw as the handful of rows actually on screen. A per-row
    %% lists:nth/2 would restart from the head each time.
    Slice = lists:sublist(lists:nthtail(Offset, Items), H),
    {Buf1, _Row} = lists:foldl(
        fun(Item, {B, Row}) ->
            Index = Offset + Row,
            B1 = draw_row(B, Area, Row, Index =:= Selected, Item, Base, Highlight, Symbol, Gutter),
            {B1, Row + 1}
        end,
        {Buf, 0},
        Slice
    ),
    Buf1.

-spec draw_row(
    tuition_render:buffer(),
    #rect{},
    non_neg_integer(),
    boolean(),
    tuition_text:line_input(),
    tuition_render:style(),
    tuition_render:style(),
    unicode:chardata(),
    binary()
) -> tuition_render:buffer().
draw_row(Buf, Area, Row, Selected, Item, Base, Highlight, Symbol, Gutter) ->
    %% Fill the whole row with its style first, then draw the prefix and item over
    %% it, so the row's background spans edge to edge — the selection highlight bar
    %% for the selected row, the configured base style for the rest. Filling with an
    %% empty style is a no-op, so an unstyled list stays blank to the right of its
    %% items. A selected row overlays the highlight onto the base; an unselected row
    %% uses the base alone and indents its item under the highlight symbol's gutter.
    {Style, Prefix} =
        case Selected of
            true -> {maps:merge(Base, Highlight), Symbol};
            false -> {Base, Gutter}
        end,
    Buf1 = tuition_widget:fill(Buf, row_rect(Area, Row), Style),
    %% Draw the plain gutter prefix in the row style, then the item's styled line
    %% starting after it (both gutter and symbol share the symbol's width, so the
    %% item lines up whether or not the row is selected). Each item span overlays
    %% its own style on the row style, so a plain item is drawn exactly as before.
    Buf2 = tuition_widget:put_line(Buf1, Area, 0, Row, Prefix, Style),
    tuition_text:put_line(
        Buf2, Area, tuition_widget:display_width(Symbol), Row, tuition_text:line(Item), Style
    ).

%% A one-row sub-rect at `Area'-relative row `Row', spanning the full width — the
%% region the highlight bar fills.
-spec row_rect(#rect{}, non_neg_integer()) -> #rect{}.
row_rect(#rect{x = X, y = Y, w = W}, Row) ->
    #rect{x = X, y = Y + Row, w = W, h = 1}.

%%% -- helpers ---------------------------------------------------------

%% Clamp an index into `[0, Len - 1]' (callers guarantee Len > 0).
-spec clamp(integer(), pos_integer()) -> non_neg_integer().
clamp(N, Len) -> min(max(N, 0), Len - 1).
