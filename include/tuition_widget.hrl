%%% Stateful-widget state records — the state that lives in the application/UI
%%% state, never inside the widget (the ratatui `StatefulWidget'/`ListState'
%%% model, PRD §8).
%%%
%%% The renderer is immediate-mode ({@link tuition_render}): every frame is rebuilt
%%% from scratch and the whole buffer is thrown away afterwards. A widget is
%%% therefore stateless across frames — so any state it needs to persist (which
%%% row is selected, how far the view is scrolled) must be threaded by the caller,
%%% not stashed in the widget. These records are that thread. {@link tuition_list}
%%% takes a `#list_state{}' and returns an updated one (its scroll offset adjusted
%%% to keep the selection in view), and the caller keeps it for the next frame.
-ifndef(TUITION_WIDGET_HRL).
-define(TUITION_WIDGET_HRL, true).

-record(list_state, {
    %% The selected item index (0-based), or `none' for no selection. {@link
    %% tuition_list} clamps it to the current item count on every render and every
    %% navigation step, so an index stranded past the end by a shrinking list can
    %% never point out of range.
    selected = none :: none | non_neg_integer(),
    %% The index of the first visible item — the scroll offset. {@link tuition_list}
    %% adjusts it at render time so `selected' stays within the visible window and
    %% returns the adjusted state, which is what makes the scroll position survive
    %% the immediate-mode rebuild each frame.
    offset = 0 :: non_neg_integer()
}).

-record(input_state, {
    %% The field's text, as a UTF-8 binary. Edited through {@link
    %% tuition_input_field:handle/2} (or replaced wholesale with `set_value/2') and
    %% read back with `value/1' — the caller never pokes at this directly.
    value = <<>> :: binary(),
    %% The caret position, as a 0-based grapheme-cluster index into `value': `0'
    %% sits before the first cluster, the cluster count sits after the last. {@link
    %% tuition_input_field} clamps it into range on every render and every edit, so
    %% an index left stale by a shrunk value can never point out of range. It counts
    %% clusters, not columns, so a wide glyph is one step under the arrow keys.
    cursor = 0 :: non_neg_integer(),
    %% Horizontal scroll offset, as the 0-based grapheme-cluster index of the
    %% leftmost visible cluster. {@link tuition_input_field} slides it at render time
    %% so the caret stays within the field's width and returns the adjusted state,
    %% which is what makes the scroll position survive the immediate-mode rebuild
    %% each frame — the horizontal analogue of `#list_state.offset'.
    offset = 0 :: non_neg_integer()
}).

-record(scrollview_state, {
    %% The top-left corner of the window onto the virtual content: the column
    %% ({@link tuition_scrollview} pans horizontally) and row (vertically) of the
    %% content cell shown at the viewport's top-left. Both are clamped at render
    %% time so the window never runs past the content edge, and the reconciled
    %% state is returned so the scroll position survives the immediate-mode rebuild
    %% each frame — the same thread {@link tuition_list} keeps for its `offset'.
    x_offset = 0 :: non_neg_integer(),
    y_offset = 0 :: non_neg_integer()
}).

-record(tree_state, {
    %% The selected *visible row* index (0-based), or `none'. It indexes the tree
    %% flattened to its currently-visible rows — not the node list — so collapsing a
    %% node above the selection shifts what it points at. {@link tuition_tree} clamps
    %% it against the live visible-row count on every render and every navigation
    %% step, so an index stranded by a collapse can never point out of range.
    selected = none :: none | non_neg_integer(),
    %% The visible-row index of the first row drawn — the scroll offset. Reconciled
    %% at render time by {@link tuition_list:reconcile/3}, exactly as for a list: the
    %% rows of an open tree *are* a list, once flattened.
    offset = 0 :: non_neg_integer(),
    %% The ids of the currently-open nodes; a node absent here is closed, so a fresh
    %% state shows the roots alone. Keyed by id rather than by position so the open
    %% set survives the tree being rebuilt each frame from fresh data — a re-sampled
    %% node keeps its open state as long as its id is stable, which is what lets an
    %% immediate-mode caller re-render live data without collapsing the user's tree
    %% under them. An id that no longer exists is simply never consulted (it costs one
    %% map entry, and is retained deliberately: a node that disappears and comes back
    %% — a restarted supervisor re-registered under the same name — returns open).
    open = #{} :: #{term() => true}
}).

-endif.
