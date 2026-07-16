%%%-------------------------------------------------------------------
%%% @doc Tree widget — a collapsible, selectable hierarchy (stateful).
%%%
%%% A tree draws a nested node structure one row per visible node, indents each
%%% row by its depth, marks the expandable ones with an open/closed symbol, and
%%% scrolls and highlights a selection just as {@link tuition_list} does. It is the
%%% widget an application/supervision tree (PRD §9.1) is built from — the shape
%%% every caller previously hand-rolled by flattening a forest into list rows and
%%% tracking the open nodes itself.
%%%
%%% == A tree is a list, once flattened ==
%%% The only thing a tree adds to a list is *which rows exist*: a node contributes
%%% a row, and its children follow it — indented — only while it is open. So this
%%% module owns the flatten (and the indent, guides and symbols that draw it), and
%%% hands the result to {@link tuition_list}: selection clamping, scroll-offset
%%% reconciliation, the full-width highlight bar and the per-row clipping are all
%%% the list's, unchanged. There is one implementation of the `ListState' logic in
%%% this library and the tree does not fork it.
%%%
%%% == Stateful, like the list ==
%%% Selection, scroll offset and the open-node set live in a `#tree_state{}' (see
%%% `include/tuition_widget.hrl') held by the *caller* — the renderer is
%%% immediate-mode and discards every frame, so state kept in the widget would not
%%% survive (see {@link tuition_widget}). {@link render/4} takes the state and
%%% returns it reconciled; navigation and open/close are pure state transitions the
%%% caller applies to input:
%%% ```
%%%   State1 = tuition_tree:next(State0, Nodes),                        %% on Down
%%%   State2 = tuition_tree:toggle(State1, tuition_tree:selected_id(State1, Nodes)),
%%%   {Buf1, State3} = tuition_tree:render(#{nodes => Nodes}, Area, Buf0, State2).
%%% '''
%%%
%%% == Indices address visible rows; the open set addresses ids ==
%%% Two different keyings meet in this widget, and the split is deliberate.
%%% Selection is a *visible-row index*, because that is what the arrow keys move
%%% through and what the list scrolls; it is reconciled against the live row count
%%% every frame, so a collapse that shortens the tree under a stale index clamps it
%%% rather than stranding it. Open/closed is keyed by *node id*, because it must
%%% outlive the row order — a caller re-rendering live data rebuilds `nodes' every
%%% frame, and an open set keyed by position would collapse the user's tree the
%%% moment a node above it appeared or vanished. {@link selected_id/2} bridges the
%%% two (index -> id) and is how a caller toggles the node under the cursor.
%%%
%%% == Nodes ==
%%% A `nodes' config value is a list of roots, each a map:
%%% ```
%%%   #{id := term(), label := unicode:chardata(), children => [tree_node()]}
%%% '''
%%% `id' is any term, and need only be unique among the nodes the caller wants to
%%% open independently. `children' defaults to `[]'; a node with no children is a
%%% leaf and cannot be opened.
%%%
%%% == Config ==
%%% A `#{}' map, every key optional:
%%% <ul>
%%%   <li>`nodes' — the root nodes (default `[]').</li>
%%%   <li>`style' — base style for every row (default: unstyled).</li>
%%%   <li>`highlight_style' — style overlaid on the selected row, across its full
%%%       width (default: unstyled — so set at least a colour to make the selection
%%%       visible).</li>
%%%   <li>`highlight_symbol' — a prefix drawn before the selected row (e.g. `"> "');
%%%       other rows are indented by its width so the tree lines up (default
%%%       `<<>>').</li>
%%%   <li>`indent' — columns per depth level (default `2'). Clamped to at least `1'
%%%       when `guides' are on, which need a column to draw in.</li>
%%%   <li>`guides' — `false' (default: indent with blanks) or `true' (draw `│ ├ └'
%%%       indent guides).</li>
%%%   <li>`open_symbol' / `closed_symbol' — the expandable-node markers (defaults
%%%       `▾' / `▸'). A leaf is blanked to the same width, so labels align down the
%%%       column whatever mix of leaves and branches a level holds.</li>
%%% </ul>
%%%
%%% HARD CONSTRAINT (PRD §12): depends only on `kernel'/`stdlib'/`erts' plus the
%%% sibling render/layout/width/widget modules. No third-party code.
%%% @end
%%%-------------------------------------------------------------------
-module(tuition_tree).

-include("tuition_layout.hrl").
-include("tuition_widget.hrl").

-export([new/0, render/4]).
-export([open/2, close/2, toggle/2, is_open/2]).
-export([next/2, prev/2, select/2, selected/1, selected_id/2, visible/2]).

-type id() :: term().
%% A node: an id, a label, and (optionally) children. Named `tree_node' rather
%% than `node' because `node()' is a builtin type and cannot be redefined.
-type tree_node() :: #{
    id := id(),
    label := unicode:chardata(),
    children => [tree_node()]
}.
%% One flattened, currently-visible row — the shape {@link visible/2} exposes so a
%% caller can implement its own navigation policy (jump to parent, step into
%% child) without re-deriving the flatten. `parent' is the visible-row index of the
%% enclosing node, which is exact because the flatten is DFS pre-order: indices are
%% assigned in the order rows are emitted, so a parent is always numbered before
%% its children.
-type row() :: #{
    id := id(),
    label := unicode:chardata(),
    depth := non_neg_integer(),
    expandable := boolean(),
    expanded := boolean(),
    parent := none | non_neg_integer()
}.
%% A row as the flatten and the render pass it around: a {@type row()} plus the
%% guide bookkeeping drawing needs and callers do not get. `bars' holds, root-most
%% first, the "was the last child" flag of each ancestor that owns an indent column,
%% which is what decides whether a guide continues through that column or stops;
%% `last' is the same flag for this row, choosing its own connector. {@link
%% public_row/1} drops both at the API boundary.
-type draw_row() :: #{
    id := id(),
    label := unicode:chardata(),
    depth := non_neg_integer(),
    expandable := boolean(),
    expanded := boolean(),
    parent := none | non_neg_integer(),
    bars := [boolean()],
    last := boolean()
}.
-type tree_cfg() :: #{
    nodes => [tree_node()],
    style => tuition_render:style(),
    highlight_style => tuition_render:style(),
    highlight_symbol => unicode:chardata(),
    indent => non_neg_integer(),
    guides => boolean(),
    open_symbol => unicode:chardata(),
    closed_symbol => unicode:chardata()
}.
-type state() :: #tree_state{}.

-export_type([id/0, tree_node/0, row/0, tree_cfg/0, state/0]).

%% Default expand markers. Both are one column wide in {@link tuition_width}, so a
%% default tree's symbol column is one cell and {@link tuition_widget:display_width/1}
%% and the renderer agree on it.
-define(OPEN_SYMBOL, <<"▾"/utf8>>).
-define(CLOSED_SYMBOL, <<"▸"/utf8>>).

%% Guide glyphs: a vertical bar continuing an ancestor's sibling run, the tee for a
%% node with siblings after it, the elbow for the last child, and the horizontal
%% that draws the connector out to the node. All one column wide.
-define(BAR, <<"│"/utf8>>).
-define(TEE, <<"├"/utf8>>).
-define(ELBOW, <<"└"/utf8>>).
-define(DASH, <<"─"/utf8>>).

-define(DEFAULT_INDENT, 2).

%%% -- state -----------------------------------------------------------

%% @doc A fresh tree state: nothing selected, unscrolled, every node closed — so a
%% tree rendered from it shows its roots alone. A caller that does not want to
%% include `tuition_widget.hrl' can start here and drive it through the API.
-spec new() -> state().
new() -> #tree_state{}.

%% @doc Open a node by id, revealing its children on the next render. Opening a
%% leaf (or an id not in the tree) is harmless — the flatten only ever consults the
%% open set for a node that has children, so the entry simply never applies.
-spec open(state(), id()) -> state().
open(#tree_state{open = Open} = State, Id) ->
    State#tree_state{open = Open#{Id => true}}.

%% @doc Close a node by id, hiding its children — and, with them, any open state
%% *within* them, which is retained rather than discarded: reopening the node
%% restores the subtree exactly as the user left it.
-spec close(state(), id()) -> state().
close(#tree_state{open = Open} = State, Id) ->
    State#tree_state{open = maps:remove(Id, Open)}.

%% @doc Flip a node's open state. `none' is a no-op, so a caller can hand
%% {@link selected_id/2} straight through without checking for an empty tree.
-spec toggle(state(), id() | none) -> state().
toggle(State, none) ->
    State;
toggle(State, Id) ->
    case is_open(State, Id) of
        true -> close(State, Id);
        false -> open(State, Id)
    end.

%% @doc Whether a node is currently open. Note this reports the *open set*, not
%% whether the node is expandable or on screen: a closed node's open children stay
%% open (see {@link close/2}).
-spec is_open(state(), id()) -> boolean().
is_open(#tree_state{open = Open}, Id) -> maps:is_key(Id, Open).

%%% -- navigation (delegated to the list) ------------------------------

%% @doc Move the selection to the next visible row, clamped to the last. From no
%% selection this selects the first row; on an empty tree it stays unselected.
%% Takes `Nodes' rather than a row count because the visible extent is not the node
%% count — it depends on which nodes are open, which only the flatten knows.
-spec next(state(), [tree_node()]) -> state().
next(State, Nodes) ->
    with_list(State, Nodes, fun tuition_list:next/2).

%% @doc Move the selection to the previous visible row, clamped to the first. From
%% no selection this selects the last row; on an empty tree it stays unselected.
-spec prev(state(), [tree_node()]) -> state().
prev(State, Nodes) ->
    with_list(State, Nodes, fun tuition_list:prev/2).

%% @doc Set the selection to a specific visible-row index (or `none'). The index is
%% clamped to the visible-row count at the next {@link render/4}, so an index that
%% is momentarily out of range is harmless.
-spec select(state(), none | non_neg_integer()) -> state().
select(State, Selected) ->
    State#tree_state{selected = Selected}.

%% @doc The selected visible-row index, or `none'. To act on the node it names, use
%% {@link selected_id/2} — an index alone is meaningless once the tree re-flattens.
-spec selected(state()) -> none | non_neg_integer().
selected(#tree_state{selected = Selected}) -> Selected.

%% @doc The id of the node under the selection, or `none' when nothing is selected
%% (or the index is stale against a tree that has since shrunk). This is the bridge
%% from the row index the arrow keys move to the node id {@link toggle/2} needs.
-spec selected_id(state(), [tree_node()]) -> id() | none.
selected_id(State, Nodes) ->
    case selected_row(State, Nodes) of
        none -> none;
        #{id := Id} -> Id
    end.

%% @doc The currently-visible rows, in draw order — the tree flattened under the
%% open set. Exported so a caller can build navigation this widget does not impose
%% (collapse-or-jump-to-parent, expand-or-step-into-child) from the same flatten
%% the render uses, rather than re-deriving it and risking a different answer.
-spec visible(state(), [tree_node()]) -> [row()].
visible(State, Nodes) ->
    [public_row(Row) || Row <- rows(State, Nodes)].

%% The flatten as the render wants it: rows still carrying the guide state (`bars',
%% `last') that drawing needs and callers have no use for.
-spec rows(state(), [tree_node()]) -> [draw_row()].
rows(#tree_state{open = Open}, Nodes) ->
    {Rows, _Next} = flatten(Nodes, 0, none, [], Open, [], 0),
    lists:reverse(Rows).

%% Drop the drawing state, leaving the published row shape. Built explicitly rather
%% than subtracted with maps:without/2 so the row() contract is stated in one place
%% and checked, instead of being whatever the flatten happens to leave behind.
-spec public_row(draw_row()) -> row().
public_row(#{
    id := Id,
    label := Label,
    depth := Depth,
    expandable := Expandable,
    expanded := Expanded,
    parent := Parent
}) ->
    #{
        id => Id,
        label => Label,
        depth => Depth,
        expandable => Expandable,
        expanded => Expanded,
        parent => Parent
    }.

%% Apply a {@link tuition_list} navigation step to the tree's selection, over the
%% current visible-row count. The list owns the clamping rules (including how a
%% stale index steps); this only supplies the extent and threads the answer back.
-spec with_list(state(), [tree_node()], fun((#list_state{}, non_neg_integer()) -> #list_state{})) ->
    state().
with_list(#tree_state{selected = Sel, offset = Off} = State, Nodes, Step) ->
    Len = length(rows(State, Nodes)),
    Moved = Step(#list_state{selected = Sel, offset = Off}, Len),
    State#tree_state{selected = Moved#list_state.selected, offset = Moved#list_state.offset}.

%% The row under the selection, or `none' — `none' also covering a selection left
%% past the end by a collapse, which must not crash a caller mid-frame.
-spec selected_row(state(), [tree_node()]) -> none | row().
selected_row(#tree_state{selected = none}, _Nodes) ->
    none;
selected_row(#tree_state{selected = Sel} = State, Nodes) ->
    Rows = rows(State, Nodes),
    case Sel >= 0 andalso Sel < length(Rows) of
        true -> public_row(lists:nth(Sel + 1, Rows));
        false -> none
    end.

%%% -- flattening ------------------------------------------------------

%% Flatten the forest to its visible rows, in draw order: a node contributes a row,
%% and (only while open) its children follow it at one greater depth. `Bars' carries
%% the guide state — see draw_bars/2 — and `Index' is the running visible-row index,
%% which is what makes each row's `parent' exact.
-spec flatten(
    [tree_node()],
    non_neg_integer(),
    none | non_neg_integer(),
    [boolean()],
    #{id() => true},
    [draw_row()],
    non_neg_integer()
) -> {[draw_row()], non_neg_integer()}.
flatten([], _Depth, _Parent, _Bars, _Open, Acc, Next) ->
    {Acc, Next};
flatten([Node | Rest], Depth, Parent, Bars, Open, Acc, Index) ->
    Children = maps:get(children, Node, []),
    Expandable = Children =/= [],
    Expanded = Expandable andalso maps:is_key(maps:get(id, Node), Open),
    IsLast = Rest =:= [],
    Row = #{
        id => maps:get(id, Node),
        label => maps:get(label, Node),
        depth => Depth,
        expandable => Expandable,
        expanded => Expanded,
        parent => Parent,
        %% Drawing state — see draw_row(); public_row/1 strips it at the boundary.
        bars => Bars,
        last => IsLast
    },
    {Acc1, Next} =
        case Expanded of
            true ->
                flatten(
                    Children,
                    Depth + 1,
                    Index,
                    child_bars(Bars, Depth, IsLast),
                    Open,
                    [Row | Acc],
                    Index + 1
                );
            false ->
                {[Row | Acc], Index + 1}
        end,
    flatten(Rest, Depth, Parent, Bars, Open, Acc1, Next).

%% The guide state a node's children inherit: this node's own "has siblings below"
%% flag appended, so each child draws a bar through this node's column if the run
%% continues past it. A depth-0 node contributes no column — roots are drawn flush,
%% with no guide to their left — so its children start from an empty run.
-spec child_bars([boolean()], non_neg_integer(), boolean()) -> [boolean()].
child_bars(_Bars, 0, _IsLast) -> [];
child_bars(Bars, _Depth, IsLast) -> Bars ++ [IsLast].

%%% -- render ----------------------------------------------------------

%% @doc Draw the visible slice of the tree into `Area', highlighting the selected
%% row, and return the buffer together with the reconciled state (selection clamped
%% to the visible-row count, offset adjusted to keep the selection in view). A
%% degenerate area draws nothing but still reconciles, so a resize that shrinks a
%% pane to nothing and back leaves a valid selection behind.
%%
%% The rows are prefixed here — indent or guides, then the expand symbol — and the
%% drawing itself is {@link tuition_list:render/4}'s, so a tree highlights, scrolls
%% and clips exactly as a list does.
-spec render(tree_cfg(), #rect{}, tuition_render:buffer(), state()) ->
    {tuition_render:buffer(), state()}.
render(Cfg, Area, Buf, #tree_state{selected = Sel, offset = Off} = State) ->
    Nodes = maps:get(nodes, Cfg, []),
    Items = [line(Row, Cfg) || Row <- rows(State, Nodes)],
    ListCfg = #{
        items => Items,
        style => maps:get(style, Cfg, #{}),
        highlight_style => maps:get(highlight_style, Cfg, #{}),
        highlight_symbol => maps:get(highlight_symbol, Cfg, <<>>)
    },
    {Buf1, Reconciled} = tuition_list:render(ListCfg, Area, Buf, #list_state{
        selected = Sel, offset = Off
    }),
    {Buf1, State#tree_state{
        selected = Reconciled#list_state.selected, offset = Reconciled#list_state.offset
    }}.

%% One row's text: its indent (blank or guides), its expand marker, then the label.
-spec line(draw_row(), tree_cfg()) -> unicode:chardata().
line(#{label := Label} = Row, Cfg) ->
    [indent(Row, Cfg), symbol(Row, Cfg), <<" ">>, Label].

%% The indent for a row: with guides off, `indent' blanks per depth level; with them
%% on, a bar (or blank) for each ancestor column followed by the connector into this
%% node. A root has no indent either way.
-spec indent(draw_row(), tree_cfg()) -> unicode:chardata().
indent(#{depth := 0}, _Cfg) ->
    <<>>;
indent(#{depth := Depth, bars := Bars, last := IsLast}, Cfg) ->
    Width = indent_width(Cfg),
    case maps:get(guides, Cfg, false) of
        false -> binary:copy(<<" ">>, Width * Depth);
        true -> [draw_bars(Bars, Width), connector(IsLast, Width)]
    end.

%% Columns per depth level. Guides need a column to draw the bar in, so an `indent'
%% of 0 (or a nonsense negative) is lifted to 1 rather than drawing a guide with
%% nowhere to go; without guides, a 0 indent is a legitimate flat list.
-spec indent_width(tree_cfg()) -> non_neg_integer().
indent_width(Cfg) ->
    Width = max(0, maps:get(indent, Cfg, ?DEFAULT_INDENT)),
    case maps:get(guides, Cfg, false) of
        true -> max(1, Width);
        false -> Width
    end.

%% One column per ancestor whose sibling run continues below this row: a bar when it
%% does, blanks when it does not (the run ended, so nothing should be drawn through
%% it). `Bars' holds the ancestors' "was last child" flags, root-most first.
-spec draw_bars([boolean()], non_neg_integer()) -> unicode:chardata().
draw_bars(Bars, Width) ->
    [
        case AncestorWasLast of
            true -> binary:copy(<<" ">>, Width);
            false -> [?BAR, binary:copy(<<" ">>, Width - 1)]
        end
     || AncestorWasLast <- Bars
    ].

%% The connector into a node: an elbow for the last child of its parent (the run
%% stops here), a tee for any other (the run continues to the next sibling), drawn
%% out to the label with horizontals.
-spec connector(boolean(), non_neg_integer()) -> unicode:chardata().
connector(IsLast, Width) ->
    Glyph =
        case IsLast of
            true -> ?ELBOW;
            false -> ?TEE
        end,
    [Glyph, lists:duplicate(Width - 1, ?DASH)].

%% A row's expand marker: the open or closed symbol for an expandable node, and for
%% a leaf a blank of the same width — so labels align down the column regardless of
%% which rows can be opened. Both symbols are measured, and the wider wins, so a
%% caller's multi-column symbols still align.
-spec symbol(draw_row(), tree_cfg()) -> unicode:chardata().
symbol(#{expandable := false}, Cfg) ->
    binary:copy(<<" ">>, symbol_width(Cfg));
symbol(#{expanded := Expanded}, Cfg) ->
    Symbol =
        case Expanded of
            true -> maps:get(open_symbol, Cfg, ?OPEN_SYMBOL);
            false -> maps:get(closed_symbol, Cfg, ?CLOSED_SYMBOL)
        end,
    Pad = symbol_width(Cfg) - tuition_widget:display_width(Symbol),
    [Symbol, binary:copy(<<" ">>, max(0, Pad))].

%% The width of the symbol column: the wider of the two configured symbols, measured
%% as the renderer will draw them (so a control byte in a caller's symbol counts the
%% column it becomes, and the column cannot drift from the cells emitted).
-spec symbol_width(tree_cfg()) -> non_neg_integer().
symbol_width(Cfg) ->
    Open = maps:get(open_symbol, Cfg, ?OPEN_SYMBOL),
    Closed = maps:get(closed_symbol, Cfg, ?CLOSED_SYMBOL),
    max(tuition_widget:display_width(Open), tuition_widget:display_width(Closed)).
