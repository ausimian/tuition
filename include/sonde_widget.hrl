%%% Stateful-widget state records — the state that lives in the application/UI
%%% state, never inside the widget (the ratatui `StatefulWidget'/`ListState'
%%% model, PRD §8).
%%%
%%% The renderer is immediate-mode ({@link sonde_render}): every frame is rebuilt
%%% from scratch and the whole buffer is thrown away afterwards. A widget is
%%% therefore stateless across frames — so any state it needs to persist (which
%%% row is selected, how far the view is scrolled) must be threaded by the caller,
%%% not stashed in the widget. These records are that thread. {@link sonde_list}
%%% takes a `#list_state{}' and returns an updated one (its scroll offset adjusted
%%% to keep the selection in view), and the caller keeps it for the next frame.
-ifndef(SONDE_WIDGET_HRL).
-define(SONDE_WIDGET_HRL, true).

-record(list_state, {
    %% The selected item index (0-based), or `none' for no selection. {@link
    %% sonde_list} clamps it to the current item count on every render and every
    %% navigation step, so an index stranded past the end by a shrinking list can
    %% never point out of range.
    selected = none :: none | non_neg_integer(),
    %% The index of the first visible item — the scroll offset. {@link sonde_list}
    %% adjusts it at render time so `selected' stays within the visible window and
    %% returns the adjusted state, which is what makes the scroll position survive
    %% the immediate-mode rebuild each frame.
    offset = 0 :: non_neg_integer()
}).

-endif.
