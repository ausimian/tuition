-module(tuition_scrollbar_tests).

-include_lib("eunit/include/eunit.hrl").
-include("tuition_layout.hrl").
-include("tuition_term.hrl").

%%% -- helpers ---------------------------------------------------------

%% Default glyphs, mirrored from tuition_scrollbar's private defines.
-define(V_TRACK, 16#2502).
-define(H_TRACK, 16#2500).
-define(THUMB, 16#2588).
%% Arrow caps used in the cap tests (▲ / ▼).
-define(UP, 16#25B2).
-define(DOWN, 16#25BC).

buf(W, H) -> tuition_render:new({W, H}).
cell(B, X, Y) -> tuition_render:cell_at(B, X, Y).
ch(B, X, Y) -> (cell(B, X, Y))#cell.char.
rect(X, Y, W, H) -> #rect{x = X, y = Y, w = W, h = H}.

%% Render a vertical bar into a 1-wide, H-tall rect.
vert(Cfg, H) ->
    tuition_scrollbar:render(Cfg, rect(0, 0, 1, H), buf(1, H)).

%% Render a horizontal bar into a W-wide, 1-tall rect.
horiz(Cfg, W) ->
    tuition_scrollbar:render(Cfg, rect(0, 0, W, 1), buf(W, 1)).

%%% -- thumb position --------------------------------------------------

thumb_sits_at_top_at_position_zero_test() ->
    %% content 20, viewport 10 over a 10-cell track -> a 5-cell thumb; at
    %% position 0 it fills rows 0..4 and the track shows below it.
    B = vert(#{content_length => 20, viewport_length => 10, position => 0}, 10),
    ?assertEqual(?THUMB, ch(B, 0, 0)),
    ?assertEqual(?THUMB, ch(B, 0, 4)),
    ?assertEqual(?V_TRACK, ch(B, 0, 5)),
    ?assertEqual(?V_TRACK, ch(B, 0, 9)).

thumb_sits_at_bottom_at_max_position_test() ->
    %% Scrolled to the end (position 10 = content - viewport) the 5-cell thumb
    %% sits flush at the bottom, rows 5..9.
    B = vert(#{content_length => 20, viewport_length => 10, position => 10}, 10),
    ?assertEqual(?V_TRACK, ch(B, 0, 0)),
    ?assertEqual(?V_TRACK, ch(B, 0, 4)),
    ?assertEqual(?THUMB, ch(B, 0, 5)),
    ?assertEqual(?THUMB, ch(B, 0, 9)).

position_past_the_end_is_clamped_test() ->
    %% A position beyond the scrollable range lands the thumb at the bottom, not
    %% off the end of the track.
    B = vert(#{content_length => 20, viewport_length => 10, position => 999}, 10),
    ?assertEqual(?THUMB, ch(B, 0, 9)),
    ?assertEqual(?THUMB, ch(B, 0, 5)),
    ?assertEqual(?V_TRACK, ch(B, 0, 4)).

thumb_travels_through_the_middle_test() ->
    %% Halfway through the scrollable range the thumb sits in the middle of the
    %% remaining track: position 5 of 10 -> start round(5 * 5/10) = 3, rows 3..7.
    B = vert(#{content_length => 20, viewport_length => 10, position => 5}, 10),
    ?assertEqual(?V_TRACK, ch(B, 0, 2)),
    ?assertEqual(?THUMB, ch(B, 0, 3)),
    ?assertEqual(?THUMB, ch(B, 0, 7)),
    ?assertEqual(?V_TRACK, ch(B, 0, 8)).

%%% -- thumb length ----------------------------------------------------

content_that_fits_fills_the_whole_track_test() ->
    %% Nothing to scroll (content <= viewport): the thumb is the whole track.
    B = vert(#{content_length => 5, viewport_length => 10, position => 0}, 10),
    ?assertEqual(?THUMB, ch(B, 0, 0)),
    ?assertEqual(?THUMB, ch(B, 0, 9)).

zero_content_fills_the_whole_track_test() ->
    B = vert(#{content_length => 0, position => 0}, 10),
    ?assertEqual(?THUMB, ch(B, 0, 0)),
    ?assertEqual(?THUMB, ch(B, 0, 9)).

huge_content_keeps_a_one_cell_thumb_test() ->
    %% A tiny viewport over huge content would round the thumb to zero cells; it
    %% is floored at one so the thumb never vanishes.
    B = vert(#{content_length => 1000, viewport_length => 1, position => 0}, 10),
    ?assertEqual(?THUMB, ch(B, 0, 0)),
    ?assertEqual(?V_TRACK, ch(B, 0, 1)),
    ?assertEqual(?V_TRACK, ch(B, 0, 9)).

viewport_length_defaults_to_the_track_length_test() ->
    %% Omitting viewport_length uses the track length (10 here), so content 20
    %% gives the same 5-cell thumb as passing viewport_length => 10.
    B = vert(#{content_length => 20, position => 0}, 10),
    ?assertEqual(?THUMB, ch(B, 0, 4)),
    ?assertEqual(?V_TRACK, ch(B, 0, 5)).

%%% -- orientation -----------------------------------------------------

horizontal_bar_runs_along_row_zero_test() ->
    B = horiz(
        #{orientation => horizontal, content_length => 20, viewport_length => 10, position => 0}, 10
    ),
    ?assertEqual(?THUMB, ch(B, 0, 0)),
    ?assertEqual(?THUMB, ch(B, 4, 0)),
    ?assertEqual(?H_TRACK, ch(B, 5, 0)),
    ?assertEqual(?H_TRACK, ch(B, 9, 0)).

%%% -- arrow caps ------------------------------------------------------

arrow_caps_bound_the_track_test() ->
    %% With caps the track is 8 cells (rows 1..8) between ▲ (row 0) and ▼ (row 9);
    %% content 20 over viewport 8 -> a 3-cell thumb, at the top rows 1..3.
    B = vert(
        #{
            content_length => 20,
            viewport_length => 8,
            position => 0,
            begin_symbol => <<?UP/utf8>>,
            end_symbol => <<?DOWN/utf8>>
        },
        10
    ),
    ?assertEqual(?UP, ch(B, 0, 0)),
    ?assertEqual(?DOWN, ch(B, 0, 9)),
    ?assertEqual(?THUMB, ch(B, 0, 1)),
    ?assertEqual(?THUMB, ch(B, 0, 3)),
    ?assertEqual(?V_TRACK, ch(B, 0, 4)).

arrow_caps_keep_the_thumb_off_the_end_cell_test() ->
    %% Scrolled to the end, the thumb stops above the ▼ cap, never over it.
    B = vert(
        #{
            content_length => 20,
            viewport_length => 8,
            position => 12,
            begin_symbol => <<?UP/utf8>>,
            end_symbol => <<?DOWN/utf8>>
        },
        10
    ),
    ?assertEqual(?DOWN, ch(B, 0, 9)),
    ?assertEqual(?THUMB, ch(B, 0, 8)),
    ?assertEqual(?THUMB, ch(B, 0, 6)),
    ?assertEqual(?V_TRACK, ch(B, 0, 5)).

%%% -- glyphs & styling ------------------------------------------------

custom_glyphs_override_the_defaults_test() ->
    B = vert(
        #{
            content_length => 20,
            viewport_length => 10,
            position => 0,
            track => <<"|">>,
            thumb => <<"#">>
        },
        10
    ),
    ?assertEqual($#, ch(B, 0, 0)),
    ?assertEqual($|, ch(B, 0, 9)).

thumb_style_colours_the_thumb_test() ->
    B = vert(
        #{content_length => 20, viewport_length => 10, position => 0, thumb_style => #{fg => 2}}, 10
    ),
    ?assertMatch(#cell{char = ?THUMB, fg = 2}, cell(B, 0, 0)).

track_style_colours_the_track_test() ->
    B = vert(
        #{content_length => 20, viewport_length => 10, position => 0, style => #{bg => 3}}, 10
    ),
    ?assertMatch(#cell{char = ?V_TRACK, bg = 3}, cell(B, 0, 9)).

%%% -- degenerate ------------------------------------------------------

degenerate_area_draws_nothing_test() ->
    B0 = buf(1, 10),
    ?assertEqual(B0, tuition_scrollbar:render(#{content_length => 20}, rect(0, 0, 0, 10), B0)),
    ?assertEqual(B0, tuition_scrollbar:render(#{content_length => 20}, rect(0, 0, 1, 0), B0)).
