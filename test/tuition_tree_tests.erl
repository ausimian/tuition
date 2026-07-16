-module(tuition_tree_tests).

-include_lib("eunit/include/eunit.hrl").
-include("tuition_layout.hrl").
-include("tuition_term.hrl").
-include("tuition_widget.hrl").

%%% -- helpers ---------------------------------------------------------

buf(W, H) -> tuition_render:new({W, H}).
rect(X, Y, W, H) -> #rect{x = X, y = Y, w = W, h = H}.

%% A forest with two roots, one nested two levels deep and one leaf:
%%   a          (children: a1 [children: a1x, a1y], a2)
%%   b
tree() ->
    [
        #{
            id => a,
            label => <<"a">>,
            children => [
                #{
                    id => a1,
                    label => <<"a1">>,
                    children => [
                        #{id => a1x, label => <<"a1x">>},
                        #{id => a1y, label => <<"a1y">>}
                    ]
                },
                #{id => a2, label => <<"a2">>}
            ]
        },
        #{id => b, label => <<"b">>}
    ].

%% A state with every node in `Ids' opened.
opened(Ids) ->
    lists:foldl(fun(Id, S) -> tuition_tree:open(S, Id) end, tuition_tree:new(), Ids).

render(Cfg, W, H, State) ->
    tuition_tree:render(Cfg, rect(0, 0, W, H), buf(W, H), State).

%% Row `Y' of a rendered frame, as a binary — the cells the widget actually drew,
%% trailing blanks trimmed. Read back through `cell_at/3' rather than asserted
%% against a diff, so a blank cell inside a row (an indent, a leaf's symbol gutter)
%% is compared like any other rather than being skipped as an unchanged cell.
line(Cfg, W, H, State, Y) ->
    {Buf, _S} = render(Cfg, W, H, State),
    Chars = [char_at(Buf, X, Y) || X <- lists:seq(0, W - 1)],
    string:trim(unicode:characters_to_binary(Chars), trailing).

char_at(Buf, X, Y) ->
    case tuition_render:cell_at(Buf, X, Y) of
        wide_cont -> [];
        #cell{char = C} -> C
    end.

ids(Rows) -> [Id || #{id := Id} <- Rows].

%%% -- open / close / toggle -------------------------------------------

fresh_state_has_nothing_open_test() ->
    ?assertNot(tuition_tree:is_open(tuition_tree:new(), a)).

open_then_is_open_test() ->
    ?assert(tuition_tree:is_open(tuition_tree:open(tuition_tree:new(), a), a)).

close_reverses_open_test() ->
    S = tuition_tree:close(tuition_tree:open(tuition_tree:new(), a), a),
    ?assertNot(tuition_tree:is_open(S, a)).

close_an_unopened_node_is_harmless_test() ->
    ?assertNot(tuition_tree:is_open(tuition_tree:close(tuition_tree:new(), a), a)).

toggle_flips_both_ways_test() ->
    S1 = tuition_tree:toggle(tuition_tree:new(), a),
    ?assert(tuition_tree:is_open(S1, a)),
    ?assertNot(tuition_tree:is_open(tuition_tree:toggle(S1, a), a)).

toggle_none_is_a_no_op_test() ->
    %% So a caller can pipe selected_id/2 straight in on an empty tree.
    S = opened([a]),
    ?assertEqual(S, tuition_tree:toggle(S, none)).

open_ids_are_independent_test() ->
    S = opened([a, a1]),
    ?assert(tuition_tree:is_open(S, a)),
    ?assert(tuition_tree:is_open(S, a1)),
    ?assertNot(tuition_tree:is_open(S, b)).

closing_a_parent_retains_the_childs_open_state_test() ->
    %% Reopening `a' must restore the subtree as the user left it, not flatten it.
    S = tuition_tree:close(opened([a, a1]), a),
    ?assert(tuition_tree:is_open(S, a1)),
    ?assertEqual([a, b], ids(tuition_tree:visible(S, tree()))),
    ?assertEqual(
        [a, a1, a1x, a1y, a2, b], ids(tuition_tree:visible(tuition_tree:open(S, a), tree()))
    ).

opening_a_leaf_is_harmless_test() ->
    %% The flatten only consults the open set for a node with children.
    S = tuition_tree:open(tuition_tree:new(), b),
    ?assertEqual([a, b], ids(tuition_tree:visible(S, tree()))).

opening_an_unknown_id_is_harmless_test() ->
    S = tuition_tree:open(tuition_tree:new(), nonesuch),
    ?assertEqual([a, b], ids(tuition_tree:visible(S, tree()))).

%%% -- flattening ------------------------------------------------------

closed_tree_shows_roots_only_test() ->
    ?assertEqual([a, b], ids(tuition_tree:visible(tuition_tree:new(), tree()))).

open_node_reveals_its_children_test() ->
    ?assertEqual([a, a1, a2, b], ids(tuition_tree:visible(opened([a]), tree()))).

nested_open_reveals_grandchildren_in_dfs_order_test() ->
    ?assertEqual([a, a1, a1x, a1y, a2, b], ids(tuition_tree:visible(opened([a, a1]), tree()))).

an_open_node_under_a_closed_parent_stays_hidden_test() ->
    ?assertEqual([a, b], ids(tuition_tree:visible(opened([a1]), tree()))).

empty_tree_flattens_to_nothing_test() ->
    ?assertEqual([], tuition_tree:visible(tuition_tree:new(), [])).

rows_carry_depth_test() ->
    Rows = tuition_tree:visible(opened([a, a1]), tree()),
    ?assertEqual([0, 1, 2, 2, 1, 0], [D || #{depth := D} <- Rows]).

rows_carry_expandable_test() ->
    Rows = tuition_tree:visible(opened([a, a1]), tree()),
    %% a and a1 have children; a1x, a1y, a2 and b are leaves.
    ?assertEqual([true, true, false, false, false, false], [E || #{expandable := E} <- Rows]).

rows_carry_expanded_test() ->
    Rows = tuition_tree:visible(opened([a]), tree()),
    %% a is open; a1 is expandable but closed; the leaves are never expanded.
    ?assertEqual([true, false, false, false], [E || #{expanded := E} <- Rows]).

a_node_without_children_key_is_a_leaf_test() ->
    %% `children' is optional — its absence must mean "leaf", not crash.
    Rows = tuition_tree:visible(tuition_tree:new(), [#{id => x, label => <<"x">>}]),
    ?assertEqual(
        [
            #{
                id => x,
                label => <<"x">>,
                depth => 0,
                expandable => false,
                expanded => false,
                parent => none
            }
        ],
        Rows
    ).

rows_carry_parent_visible_index_test() ->
    Rows = tuition_tree:visible(opened([a, a1]), tree()),
    %% Visible order: 0:a 1:a1 2:a1x 3:a1y 4:a2 5:b — DFS pre-order, so a parent is
    %% always numbered before its children and the index is exact.
    ?assertEqual([none, 0, 1, 1, 0, none], [P || #{parent := P} <- Rows]).

parent_index_tracks_a_collapse_test() ->
    %% With a1 closed, a2 shifts up to index 2 but its parent is still a at 0.
    Rows = tuition_tree:visible(opened([a]), tree()),
    ?assertEqual([none, 0, 0, none], [P || #{parent := P} <- Rows]).

visible_rows_do_not_leak_drawing_state_test() ->
    %% The guide bookkeeping is an implementation detail of the render.
    [Row | _] = tuition_tree:visible(opened([a, a1]), tree()),
    ?assertEqual(
        lists:sort([id, label, depth, expandable, expanded, parent]), lists:sort(maps:keys(Row))
    ).

%%% -- navigation ------------------------------------------------------

next_from_none_selects_first_test() ->
    ?assertEqual(0, tuition_tree:selected(tuition_tree:next(tuition_tree:new(), tree()))).

prev_from_none_selects_last_test() ->
    %% Closed: two visible rows, so the last is 1.
    ?assertEqual(1, tuition_tree:selected(tuition_tree:prev(tuition_tree:new(), tree()))).

next_clamps_at_the_last_visible_row_test() ->
    S = tuition_tree:select(tuition_tree:new(), 1),
    ?assertEqual(1, tuition_tree:selected(tuition_tree:next(S, tree()))).

prev_clamps_at_the_first_row_test() ->
    S = tuition_tree:select(tuition_tree:new(), 0),
    ?assertEqual(0, tuition_tree:selected(tuition_tree:prev(S, tree()))).

navigation_extent_follows_the_open_set_test() ->
    %% The visible extent is not the node count: opening `a' lengthens the tree, so
    %% next/2 may now move past what the closed tree allowed.
    Closed = tuition_tree:select(tuition_tree:new(), 1),
    ?assertEqual(1, tuition_tree:selected(tuition_tree:next(Closed, tree()))),
    Open = tuition_tree:select(opened([a]), 1),
    ?assertEqual(2, tuition_tree:selected(tuition_tree:next(Open, tree()))).

navigation_on_empty_tree_stays_unselected_test() ->
    ?assertEqual(none, tuition_tree:selected(tuition_tree:next(tuition_tree:new(), []))),
    ?assertEqual(none, tuition_tree:selected(tuition_tree:prev(tuition_tree:new(), []))).

navigation_clamps_a_stale_index_test() ->
    %% A selection stranded by a collapse still steps sanely.
    S = tuition_tree:select(tuition_tree:new(), 99),
    ?assertEqual(1, tuition_tree:selected(tuition_tree:next(S, tree()))),
    ?assertEqual(0, tuition_tree:selected(tuition_tree:prev(S, tree()))).

select_sets_the_index_test() ->
    ?assertEqual(3, tuition_tree:selected(tuition_tree:select(tuition_tree:new(), 3))).

%%% -- selected_id -----------------------------------------------------

selected_id_of_no_selection_is_none_test() ->
    ?assertEqual(none, tuition_tree:selected_id(tuition_tree:new(), tree())).

selected_id_names_the_node_under_the_cursor_test() ->
    S = tuition_tree:select(opened([a, a1]), 3),
    ?assertEqual(a1y, tuition_tree:selected_id(S, tree())).

selected_id_of_a_stale_index_is_none_test() ->
    %% A collapse can strand the index between frames; that must not crash.
    S = tuition_tree:select(tuition_tree:new(), 99),
    ?assertEqual(none, tuition_tree:selected_id(S, tree())).

selected_id_tracks_a_collapse_test() ->
    %% Index 2 is a1x while a1 is open, and a2 once it closes — selection addresses
    %% visible rows, which is exactly why a caller must re-read the id each frame.
    ?assertEqual(a1x, tuition_tree:selected_id(tuition_tree:select(opened([a, a1]), 2), tree())),
    ?assertEqual(a2, tuition_tree:selected_id(tuition_tree:select(opened([a]), 2), tree())).

toggle_of_selected_id_round_trips_test() ->
    %% The documented idiom: move, read the id, toggle it.
    S0 = tuition_tree:next(tuition_tree:new(), tree()),
    S1 = tuition_tree:toggle(S0, tuition_tree:selected_id(S0, tree())),
    ?assertEqual([a, a1, a2, b], ids(tuition_tree:visible(S1, tree()))).

%%% -- render: symbols -------------------------------------------------

closed_node_draws_the_closed_symbol_test() ->
    ?assertEqual(<<"▸ a"/utf8>>, line(#{nodes => tree()}, 20, 4, tuition_tree:new(), 0)).

open_node_draws_the_open_symbol_test() ->
    ?assertEqual(<<"▾ a"/utf8>>, line(#{nodes => tree()}, 20, 4, opened([a]), 0)).

leaf_is_blanked_to_the_symbol_width_test() ->
    %% `b' is a root leaf: no marker, but indented under one so labels align with
    %% `a's. The leading blank is why these assertions read cells, not a diff.
    ?assertEqual(<<"  b">>, line(#{nodes => tree()}, 20, 4, tuition_tree:new(), 1)).

custom_symbols_are_used_test() ->
    Cfg = #{nodes => tree(), open_symbol => <<"-">>, closed_symbol => <<"+">>},
    ?assertEqual(<<"+ a">>, line(Cfg, 20, 4, tuition_tree:new(), 0)),
    ?assertEqual(<<"- a">>, line(Cfg, 20, 4, opened([a]), 0)).

symbol_column_widens_to_the_wider_symbol_test() ->
    %% A leaf must blank to the same width the symbols occupy, or labels stagger.
    Cfg = #{nodes => tree(), open_symbol => <<"[-]">>, closed_symbol => <<"[+]">>},
    ?assertEqual(<<"[+] a">>, line(Cfg, 20, 4, tuition_tree:new(), 0)),
    ?assertEqual(<<"    b">>, line(Cfg, 20, 4, tuition_tree:new(), 1)).

mismatched_symbol_widths_pad_to_the_wider_test() ->
    Cfg = #{nodes => tree(), open_symbol => <<"v">>, closed_symbol => <<"(+)">>},
    %% The open symbol is padded out to the closed symbol's three columns.
    ?assertEqual(<<"v   a">>, line(Cfg, 20, 4, opened([a]), 0)),
    ?assertEqual(<<"(+) a">>, line(Cfg, 20, 4, tuition_tree:new(), 0)).

%%% -- render: indent --------------------------------------------------

children_indent_by_two_columns_by_default_test() ->
    Cfg = #{nodes => tree()},
    ?assertEqual(<<"▾ a"/utf8>>, line(Cfg, 20, 6, opened([a]), 0)),
    ?assertEqual(<<"  ▸ a1"/utf8>>, line(Cfg, 20, 6, opened([a]), 1)).

indent_is_configurable_test() ->
    Cfg = #{nodes => tree(), indent => 4},
    ?assertEqual(<<"    ▸ a1"/utf8>>, line(Cfg, 20, 6, opened([a]), 1)).

zero_indent_flattens_without_guides_test() ->
    Cfg = #{nodes => tree(), indent => 0},
    ?assertEqual(<<"▸ a1"/utf8>>, line(Cfg, 20, 6, opened([a]), 1)).

grandchild_indents_by_depth_test() ->
    %% Depth 2 -> four columns of indent, then the symbol column a leaf blanks out.
    Cfg = #{nodes => tree()},
    ?assertEqual(<<"      a1x">>, line(Cfg, 20, 8, opened([a, a1]), 2)).

%%% -- render: guides --------------------------------------------------

guides_draw_a_tee_for_a_node_with_siblings_below_test() ->
    Cfg = #{nodes => tree(), guides => true},
    ?assertEqual(<<"├─▸ a1"/utf8>>, line(Cfg, 20, 6, opened([a]), 1)).

guides_draw_an_elbow_for_the_last_child_test() ->
    Cfg = #{nodes => tree(), guides => true},
    ?assertEqual(<<"└─  a2"/utf8>>, line(Cfg, 20, 6, opened([a]), 2)).

guides_continue_an_ancestors_run_with_a_bar_test() ->
    %% a1x/a1y sit under a1, which is *not* a's last child (a2 follows), so the run
    %% through a1's column must keep drawing.
    Cfg = #{nodes => tree(), guides => true},
    ?assertEqual(<<"│ ├─  a1x"/utf8>>, line(Cfg, 20, 8, opened([a, a1]), 2)),
    ?assertEqual(<<"│ └─  a1y"/utf8>>, line(Cfg, 20, 8, opened([a, a1]), 3)).

guides_stop_a_finished_run_with_blanks_test() ->
    %% Under a last child the ancestor column is blank, not barred. `z' is the last
    %% root, `z1' its last child, so nothing may be drawn through z1's column.
    Nodes = [
        #{
            id => z,
            label => <<"z">>,
            children => [
                #{id => z1, label => <<"z1">>, children => [#{id => z1a, label => <<"z1a">>}]}
            ]
        }
    ],
    Cfg = #{nodes => Nodes, guides => true},
    ?assertEqual(<<"  └─  z1a"/utf8>>, line(Cfg, 20, 6, opened([z, z1]), 2)).

roots_draw_flush_under_guides_test() ->
    %% A root has no parent to connect to, so no connector is drawn.
    Cfg = #{nodes => tree(), guides => true},
    ?assertEqual(<<"▾ a"/utf8>>, line(Cfg, 20, 6, opened([a]), 0)).

guides_scale_with_indent_test() ->
    Cfg = #{nodes => tree(), guides => true, indent => 4},
    ?assertEqual(<<"├───▸ a1"/utf8>>, line(Cfg, 20, 6, opened([a]), 1)).

guides_lift_a_zero_indent_to_one_column_test() ->
    %% A guide needs a column to draw in; 0 would leave it nowhere to go.
    Cfg = #{nodes => tree(), guides => true, indent => 0},
    ?assertEqual(<<"├▸ a1"/utf8>>, line(Cfg, 20, 6, opened([a]), 1)).

%%% -- render: reconciliation (delegated to the list) ------------------

render_returns_reconciled_state_test() ->
    %% Viewport 3 rows, selection 5 -> offset pulled to 5 - 3 + 1 = 3.
    S = tuition_tree:select(opened([a, a1]), 5),
    {_, State} = render(#{nodes => tree()}, 20, 3, S),
    ?assertEqual(5, tuition_tree:selected(State)),
    ?assertEqual(3, State#tree_state.offset).

render_clamps_a_selection_past_the_end_test() ->
    S = tuition_tree:select(tuition_tree:new(), 99),
    {_, State} = render(#{nodes => tree()}, 20, 4, S),
    ?assertEqual(1, tuition_tree:selected(State)).

render_clears_the_selection_on_an_empty_tree_test() ->
    S = tuition_tree:select(tuition_tree:new(), 0),
    {_, State} = render(#{nodes => []}, 20, 4, S),
    ?assertEqual(none, tuition_tree:selected(State)).

render_preserves_the_open_set_test() ->
    {_, State} = render(#{nodes => tree()}, 20, 4, opened([a])),
    ?assert(tuition_tree:is_open(State, a)).

collapsing_reconciles_the_offset_test() ->
    %% Scrolled down an open tree, then collapsed: the offset must not strand the
    %% view past the now-shorter row list.
    S0 = tuition_tree:select(opened([a, a1]), 5),
    {_, S1} = render(#{nodes => tree()}, 20, 3, S0),
    ?assertEqual(3, S1#tree_state.offset),
    {_, S2} = render(#{nodes => tree()}, 20, 3, tuition_tree:close(S1, a)),
    %% Two rows left, three visible -> nothing to scroll.
    ?assertEqual(0, S2#tree_state.offset),
    ?assertEqual(1, tuition_tree:selected(S2)).

scrolling_draws_the_visible_slice_test() ->
    %% Offset 3 of the fully-open tree puts a1y on the top row.
    S = tuition_tree:select(opened([a, a1]), 3),
    ?assertEqual(<<"      a1y">>, line(#{nodes => tree()}, 20, 1, S, 0)).

%%% -- render: degenerate areas ----------------------------------------

zero_height_area_draws_nothing_but_reconciles_test() ->
    S = tuition_tree:select(tuition_tree:new(), 99),
    {_, State} = render(#{nodes => tree()}, 20, 0, S),
    ?assertEqual(1, tuition_tree:selected(State)).

zero_width_area_draws_nothing_but_reconciles_test() ->
    S = tuition_tree:select(tuition_tree:new(), 99),
    {_, State} = render(#{nodes => tree()}, 0, 4, S),
    ?assertEqual(1, tuition_tree:selected(State)).

empty_config_renders_an_empty_tree_test() ->
    {_, State} = render(#{}, 20, 4, tuition_tree:new()),
    ?assertEqual(none, tuition_tree:selected(State)).

%%% -- render: clipping ------------------------------------------------

a_long_label_is_clipped_to_the_area_test() ->
    %% The list clips each row to the rect, so a deep label can never spill onto a
    %% neighbouring pane.
    Nodes = [#{id => x, label => <<"a-very-long-label-indeed">>}],
    ?assertEqual(<<"  a-very-l">>, line(#{nodes => Nodes}, 10, 2, tuition_tree:new(), 0)).

a_deep_indent_clips_rather_than_spilling_test() ->
    Nodes = [
        #{id => x, label => <<"x">>, children => [#{id => y, label => <<"y">>}]}
    ],
    Cfg = #{nodes => Nodes, indent => 8},
    ?assertEqual(<<"">>, line(Cfg, 6, 4, tuition_tree:open(tuition_tree:new(), x), 1)).

%%% -- render: selection styling (delegated to the list) ---------------

highlight_symbol_marks_the_selected_row_test() ->
    Cfg = #{nodes => tree(), highlight_symbol => <<"> ">>},
    S = tuition_tree:select(tuition_tree:new(), 0),
    ?assertEqual(<<"> ▸ a"/utf8>>, line(Cfg, 20, 4, S, 0)),
    %% The unselected row is indented under the symbol so the tree stays aligned.
    ?assertEqual(<<"    b">>, line(Cfg, 20, 4, S, 1)).

highlight_style_fills_the_selected_row_test() ->
    Cfg = #{nodes => tree(), highlight_style => #{bg => 4}, style => #{fg => 7}},
    S = tuition_tree:select(tuition_tree:new(), 0),
    {Buf, _} = render(Cfg, 20, 4, S),
    %% The bar spans the full width, past the label's end...
    ?assertMatch(#cell{char = $\s, fg = 7, bg = 4}, tuition_render:cell_at(Buf, 15, 0)),
    %% ...and only the selected row: the rest keep the base style alone.
    ?assertMatch(#cell{fg = 7, bg = default}, tuition_render:cell_at(Buf, 15, 1)).

%%% -- render: placement -----------------------------------------------

tree_draws_at_the_area_offset_test() ->
    %% The widget must confine itself to the rect it is given, wherever it sits.
    Buf = buf(20, 6),
    {Buf1, _S} = tuition_tree:render(
        #{nodes => tree()}, rect(4, 2, 10, 3), Buf, tuition_tree:new()
    ),
    ?assertEqual($a, char_at(Buf1, 6, 2)),
    %% Nothing drawn outside the rect.
    ?assertEqual($\s, char_at(Buf1, 0, 0)).
