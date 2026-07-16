-module(tuition_render_tests).

-include_lib("eunit/include/eunit.hrl").
-include("tuition_term.hrl").
-include("tuition_layout.hrl").

%% Render a diff to a flat binary for byte-exact assertions.
bin(IoData) -> iolist_to_binary(IoData).

%%% -- construction ----------------------------------------------------

new_size_test() ->
    ?assertEqual({10, 4}, tuition_render:size(tuition_render:new({10, 4}))).

new_from_rect_ignores_origin_test() ->
    %% A buffer always spans the whole terminal; a rect contributes only its size.
    ?assertEqual(
        {8, 6}, tuition_render:size(tuition_render:new(#rect{x = 3, y = 4, w = 8, h = 6}))
    ).

clear_keeps_size_blank_test() ->
    B = tuition_render:put_text(tuition_render:new({6, 3}), 0, 0, <<"hi">>),
    Cleared = tuition_render:clear(B),
    ?assertEqual({6, 3}, tuition_render:size(Cleared)),
    ?assertEqual(<<>>, bin(tuition_render:diff(tuition_render:new({6, 3}), Cleared))).

%%% -- acceptance: unchanged frame emits nothing -----------------------

unchanged_frame_emits_nothing_test() ->
    B = tuition_render:put_text(tuition_render:new({20, 5}), 3, 2, <<"hello">>),
    ?assertEqual(<<>>, bin(tuition_render:diff(B, B))).

blank_over_blank_emits_nothing_test() ->
    %% Drawing spaces (the blank glyph) must not register as a change: a space
    %% cell is structurally the default, so the buffer stays empty.
    B = tuition_render:put_text(tuition_render:new({10, 2}), 0, 0, <<"   ">>),
    ?assertEqual(<<>>, bin(tuition_render:diff(tuition_render:new({10, 2}), B))).

%%% -- acceptance: one cell change => cursor move + that cell's bytes ---

single_cell_change_test() ->
    A = tuition_render:put_text(tuition_render:new({10, 3}), 2, 1, <<"a">>),
    B = tuition_render:put_text(tuition_render:new({10, 3}), 2, 1, <<"b">>),
    %% CUP to row 2, col 3 (1-based) then the single glyph — nothing more.
    ?assertEqual(<<"\e[2;3Hb">>, bin(tuition_render:diff(A, B))).

%%% -- minimal emission ------------------------------------------------

contiguous_run_shares_one_cursor_move_test() ->
    B = tuition_render:put_text(tuition_render:new({10, 2}), 0, 0, <<"hi">>),
    ?assertEqual(<<"\e[1;1Hhi">>, bin(tuition_render:diff(tuition_render:new({10, 2}), B))).

gap_reemits_cursor_test() ->
    B0 = tuition_render:new({10, 2}),
    B1 = tuition_render:put_text(tuition_render:put_text(B0, 0, 0, <<"A">>), 5, 0, <<"B">>),
    ?assertEqual(<<"\e[1;1HA\e[1;6HB">>, bin(tuition_render:diff(B0, B1))).

%%% -- SGR -------------------------------------------------------------

styled_run_emits_baseline_sgr_and_resets_test() ->
    B = tuition_render:put_text(tuition_render:new({10, 2}), 0, 0, <<"X">>, #{bold => true}),
    ?assertEqual(
        <<"\e[1;1H\e[0;1mX\e[0m">>,
        bin(tuition_render:diff(tuition_render:new({10, 2}), B))
    ).

sgr_emitted_only_on_style_change_test() ->
    B0 = tuition_render:new({10, 2}),
    B1 = tuition_render:put_text(
        tuition_render:put_text(B0, 0, 0, <<"A">>, #{bold => true}),
        5,
        0,
        <<"B">>
    ),
    %% Bold A, then a plain B five cells over: SGR set once for the bold run,
    %% reset once when the style drops back to default. No trailing reset (the
    %% last run is already default).
    ?assertEqual(
        <<"\e[1;1H\e[0;1mA\e[1;6H\e[0mB">>,
        bin(tuition_render:diff(B0, B1))
    ).

sgr_256_color_test() ->
    B = tuition_render:put_text(tuition_render:new({4, 1}), 0, 0, <<"A">>, #{fg => 1, bg => 2}),
    ?assertEqual(
        <<"\e[1;1H\e[0;38;5;1;48;5;2mA\e[0m">>,
        bin(tuition_render:diff(tuition_render:new({4, 1}), B))
    ).

sgr_truecolor_test() ->
    B = tuition_render:put_text(
        tuition_render:new({4, 1}), 0, 0, <<"A">>, #{fg => {rgb, 10, 20, 30}}
    ),
    ?assertEqual(
        <<"\e[1;1H\e[0;38;2;10;20;30mA\e[0m">>,
        bin(tuition_render:diff(tuition_render:new({4, 1}), B))
    ).

%%% -- Unicode width ---------------------------------------------------

wide_glyph_occupies_two_cells_test() ->
    B = tuition_render:put_text(tuition_render:new({10, 2}), 0, 0, <<"中"/utf8>>),
    ?assertMatch(#cell{char = 16#4E2D}, tuition_render:cell_at(B, 0, 0)),
    ?assertEqual(wide_cont, tuition_render:cell_at(B, 1, 0)),
    ?assertEqual(#cell{}, tuition_render:cell_at(B, 2, 0)).

wide_glyph_advances_column_by_width_test() ->
    %% The glyph after a wide char lands contiguously (no fresh cursor move) only
    %% if column advance used width 2, not one codepoint.
    B = tuition_render:put_text(tuition_render:new({10, 2}), 0, 0, <<"中Z"/utf8>>),
    ?assertEqual(
        <<"\e[1;1H", "中"/utf8, "Z">>,
        bin(tuition_render:diff(tuition_render:new({10, 2}), B))
    ).

wide_cont_is_not_emitted_on_its_own_test() ->
    %% A wide glyph diffed against blank emits the glyph once and nothing for its
    %% covered right half.
    B = tuition_render:put_text(tuition_render:new({6, 1}), 0, 0, <<"中"/utf8>>),
    ?assertEqual(<<"\e[1;1H", "中"/utf8>>, bin(tuition_render:diff(tuition_render:new({6, 1}), B))).

%%% -- clipping --------------------------------------------------------

clip_run_at_right_edge_test() ->
    B = tuition_render:put_text(tuition_render:new({3, 2}), 0, 0, <<"abcdef">>),
    ?assertEqual(<<"\e[1;1Habc">>, bin(tuition_render:diff(tuition_render:new({3, 2}), B))),
    ?assertEqual(#cell{}, tuition_render:cell_at(B, 3, 0)).

wide_glyph_not_placed_when_it_would_overflow_test() ->
    %% Width-3 buffer, wide glyph aimed at the final column: no room for its right
    %% half, so it is dropped rather than overrunning the edge.
    B = tuition_render:put_text(tuition_render:new({3, 2}), 2, 0, <<"中"/utf8>>),
    ?assertEqual(#cell{}, tuition_render:cell_at(B, 2, 0)),
    ?assertEqual(<<>>, bin(tuition_render:diff(tuition_render:new({3, 2}), B))).

negative_x_clips_run_and_draws_onscreen_tail_test() ->
    %% A run starting left of column 0: the off-screen leading glyphs are dropped
    %% and the tail that reaches column 0 still draws. "cd" of "abcd" from X=-2.
    B = tuition_render:put_text(tuition_render:new({10, 2}), -2, 0, <<"abcd">>),
    ?assertMatch(#cell{char = $c}, tuition_render:cell_at(B, 0, 0)),
    ?assertMatch(#cell{char = $d}, tuition_render:cell_at(B, 1, 0)),
    ?assertEqual(<<"\e[1;1Hcd">>, bin(tuition_render:diff(tuition_render:new({10, 2}), B))).

negative_x_wide_glyph_straddling_left_edge_is_dropped_test() ->
    %% A wide glyph straddling column 0 (its left half at column -1) must be
    %% dropped whole, never stored as a `wide_cont' at column 0 with its left half
    %% off-screen: diff/2 never emits a lone `wide_cont', so such a strand would
    %% leave column 0 stale over the previous frame. The on-screen tail (Z) still
    %% lands, and the diff from the prior frame touches only the cell Z overwrote.
    B0 = tuition_render:put_text(tuition_render:new({10, 2}), 0, 0, <<"abc">>),
    B1 = tuition_render:put_text(B0, -1, 0, <<"中Z"/utf8>>),
    ?assertMatch(#cell{char = $a}, tuition_render:cell_at(B1, 0, 0)),
    ?assertMatch(#cell{char = $Z}, tuition_render:cell_at(B1, 1, 0)),
    ?assertMatch(#cell{char = $c}, tuition_render:cell_at(B1, 2, 0)),
    ?assertEqual(<<"\e[1;2HZ">>, bin(tuition_render:diff(B0, B1))).

%%% -- wide-glyph orphan dissolution -----------------------------------

overwriting_right_half_blanks_the_wide_glyph_test() ->
    B0 = tuition_render:put_text(tuition_render:new({10, 2}), 0, 0, <<"中"/utf8>>),
    B1 = tuition_render:put_cell(B0, 1, 0, #cell{char = $a}),
    ?assertEqual(#cell{}, tuition_render:cell_at(B1, 0, 0)),
    ?assertMatch(#cell{char = $a}, tuition_render:cell_at(B1, 1, 0)).

overwriting_left_half_blanks_the_continuation_test() ->
    B0 = tuition_render:put_text(tuition_render:new({10, 2}), 0, 0, <<"中"/utf8>>),
    B1 = tuition_render:put_cell(B0, 0, 0, #cell{char = $b}),
    ?assertMatch(#cell{char = $b}, tuition_render:cell_at(B1, 0, 0)),
    ?assertEqual(#cell{}, tuition_render:cell_at(B1, 1, 0)).

replacing_narrow_with_wide_clears_next_cell_owner_test() ->
    %% "ab": narrow a,b. Overwrite (0,0) with a wide glyph — its right half must
    %% claim (1,0), evicting b, and the grid must round-trip through a diff.
    B0 = tuition_render:put_text(tuition_render:new({10, 2}), 0, 0, <<"ab">>),
    B1 = tuition_render:put_cell(B0, 0, 0, #cell{char = 16#4E2D}),
    ?assertMatch(#cell{char = 16#4E2D}, tuition_render:cell_at(B1, 0, 0)),
    ?assertEqual(wide_cont, tuition_render:cell_at(B1, 1, 0)),
    ?assertEqual(
        <<"\e[1;1H", "中"/utf8>>,
        bin(tuition_render:diff(tuition_render:new({10, 2}), B1))
    ).

%%% -- content safety: control-character sanitisation ------------------

put_text_sanitises_newline_test() ->
    %% "A\nB" must not emit a raw newline (which would move the terminal cursor):
    %% the control becomes a blank cell, so B lands one column further along.
    B = tuition_render:put_text(tuition_render:new({10, 2}), 0, 0, <<"A\nB">>),
    ?assertEqual(#cell{}, tuition_render:cell_at(B, 1, 0)),
    ?assertEqual(<<"\e[1;1HA\e[1;3HB">>, bin(tuition_render:diff(tuition_render:new({10, 2}), B))).

put_text_sanitises_escape_test() ->
    %% A stray ESC in rendered content must never reach the terminal as the start
    %% of an escape sequence. The only ESC bytes in the output are the cursor
    %% moves the renderer itself emits.
    B = tuition_render:put_text(tuition_render:new({10, 2}), 0, 0, <<"x", 16#1B, "y">>),
    ?assertEqual(<<"\e[1;1Hx\e[1;3Hy">>, bin(tuition_render:diff(tuition_render:new({10, 2}), B))).

put_cell_sanitises_control_test() ->
    B = tuition_render:put_cell(tuition_render:new({5, 2}), 0, 0, #cell{char = 16#1B}),
    ?assertEqual(#cell{}, tuition_render:cell_at(B, 0, 0)),
    ?assertEqual(<<>>, bin(tuition_render:diff(tuition_render:new({5, 2}), B))).

put_text_drops_zero_width_cluster_test() ->
    %% A lone ZWSP (U+200B, width 0) before 'b' must not claim a cell: 'b' lands
    %% in column 0, not shifted right, and the run stays in sync with the cursor.
    B = tuition_render:put_text(tuition_render:new({10, 2}), 0, 0, [16#200B, $b]),
    ?assertMatch(#cell{char = $b}, tuition_render:cell_at(B, 0, 0)),
    ?assertEqual(#cell{}, tuition_render:cell_at(B, 1, 0)),
    ?assertEqual(<<"\e[1;1Hb">>, bin(tuition_render:diff(tuition_render:new({10, 2}), B))).

put_text_zero_width_between_glyphs_stays_in_sync_test() ->
    %% "a" ZWSP "b": the zero-width cluster between them advances no column, so the
    %% two visible glyphs stay adjacent and the emitted run has no stray cursor
    %% move — exactly matching what the terminal renders.
    B = tuition_render:put_text(tuition_render:new({10, 2}), 0, 0, [$a, 16#200B, $b]),
    ?assertEqual(<<"\e[1;1Hab">>, bin(tuition_render:diff(tuition_render:new({10, 2}), B))).

put_cell_drops_zero_width_glyph_test() ->
    B = tuition_render:put_cell(tuition_render:new({5, 2}), 2, 0, #cell{char = 16#0301}),
    ?assertEqual(#cell{}, tuition_render:cell_at(B, 2, 0)),
    ?assertEqual(<<>>, bin(tuition_render:diff(tuition_render:new({5, 2}), B))).

put_text_replaces_overwide_cluster_test() ->
    %% "a" + a skin-tone modifier clusters as one grapheme that tuition_width sums to
    %% three columns (a malformed sequence). It must collapse to a single U+FFFD so
    %% the buffer advance (1) matches what the terminal actually renders, instead
    %% of emitting three columns' worth of bytes while advancing one.
    B = tuition_render:put_text(tuition_render:new({10, 2}), 0, 0, [$a, 16#1F3FD]),
    ?assertEqual(#cell{char = 16#FFFD}, tuition_render:cell_at(B, 0, 0)),
    ?assertEqual(#cell{}, tuition_render:cell_at(B, 1, 0)),
    ?assertEqual(
        <<"\e[1;1H", 16#FFFD/utf8>>, bin(tuition_render:diff(tuition_render:new({10, 2}), B))
    ).

put_cell_replaces_overwide_cluster_test() ->
    B = tuition_render:put_cell(tuition_render:new({10, 2}), 0, 0, #cell{char = [$a, 16#1F3FD]}),
    ?assertEqual(#cell{char = 16#FFFD}, tuition_render:cell_at(B, 0, 0)),
    ?assertEqual(#cell{}, tuition_render:cell_at(B, 1, 0)).

%%% -- put_cell wide-glyph edge (parity with put_text) -----------------

put_cell_drops_wide_glyph_at_last_column_test() ->
    %% Width-3 buffer, wide glyph placed directly at the final column: no room for
    %% its continuation half, so nothing is stored and nothing is emitted.
    B = tuition_render:put_cell(tuition_render:new({3, 2}), 2, 0, #cell{char = 16#4E2D}),
    ?assertEqual(#cell{}, tuition_render:cell_at(B, 2, 0)),
    ?assertEqual(<<>>, bin(tuition_render:diff(tuition_render:new({3, 2}), B))).

put_cell_places_wide_glyph_when_it_fits_test() ->
    B = tuition_render:put_cell(tuition_render:new({3, 2}), 1, 0, #cell{char = 16#4E2D}),
    ?assertMatch(#cell{char = 16#4E2D}, tuition_render:cell_at(B, 1, 0)),
    ?assertEqual(wide_cont, tuition_render:cell_at(B, 2, 0)).

%%% -- multi-line ------------------------------------------------------

per_row_cursor_moves_test() ->
    B0 = tuition_render:new({10, 3}),
    B1 = tuition_render:put_text(tuition_render:put_text(B0, 0, 0, <<"A">>), 0, 2, <<"B">>),
    ?assertEqual(<<"\e[1;1HA\e[3;1HB">>, bin(tuition_render:diff(B0, B1))).

out_of_bounds_row_draws_nothing_test() ->
    B = tuition_render:put_text(tuition_render:new({10, 2}), 0, 5, <<"nope">>),
    ?assertEqual(<<>>, bin(tuition_render:diff(tuition_render:new({10, 2}), B))).

%%% -- cell builder / accessors (issue #45) ----------------------------

%% cell/1 builds an unstyled cell — the glyph set, everything else default.
cell_unstyled_test() ->
    C = tuition_render:cell($A),
    ?assertEqual(#cell{char = $A}, C),
    ?assertEqual($A, tuition_render:char(C)),
    ?assertEqual(default, tuition_render:fg(C)),
    ?assertEqual(default, tuition_render:bg(C)),
    ?assertNot(tuition_render:bold(C)),
    ?assertNot(tuition_render:underline(C)).

%% cell/2 applies the same style map put_text/5 takes; omitted keys stay default.
cell_styled_test() ->
    C = tuition_render:cell($X, #{fg => {rgb, 1, 2, 3}, bold => true}),
    ?assertEqual($X, tuition_render:char(C)),
    ?assertEqual({rgb, 1, 2, 3}, tuition_render:fg(C)),
    ?assertEqual(default, tuition_render:bg(C)),
    ?assert(tuition_render:bold(C)),
    ?assertNot(tuition_render:underline(C)).

%% A built cell round-trips through put_cell/4 and reads back via the accessors.
cell_round_trips_through_put_cell_test() ->
    C = tuition_render:cell($Z, #{bg => 42, underline => true}),
    B = tuition_render:put_cell(tuition_render:new({3, 1}), 0, 0, C),
    Read = tuition_render:cell_at(B, 0, 0),
    ?assertEqual($Z, tuition_render:char(Read)),
    ?assertEqual(42, tuition_render:bg(Read)),
    ?assert(tuition_render:underline(Read)).

%% The accessors read a grapheme-cluster glyph as-is (a codepoint list).
cell_cluster_char_test() ->
    C = tuition_render:cell([$e, 16#0301]),
    ?assertEqual([$e, 16#0301], tuition_render:char(C)).
