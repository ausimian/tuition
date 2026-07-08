%%%-------------------------------------------------------------------
%%% @doc Microbenchmark for {@link sonde_render:diff/2}.
%%%
%%% Rendering is the render hot path (PRD §8): the renderer is immediate-mode
%%% (the ratatui model), so `diff/2' walks *every* cell of the frame each time
%%% it repaints — the per-cell scan is an unavoidable O(cells) floor — and then
%%% emits ANSI only for the cells that changed. This suite separates that scan
%%% floor from the emission cost by covering four representative frames at one
%%% realistic terminal size (120x40 = 4800 cells):
%%%
%%%   * `full_paint'  — `diff(blank, populated)': every cell changes, so the
%%%     result is dominated by cursor moves, SGR changes and glyph bytes.
%%%   * `noop'        — `diff(frame, frame)': emits nothing, isolating the pure
%%%     O(cells) scan floor (issue #19: a throwaway measurement put this at
%%%     ~285 us of a ~0.3-0.5 ms full diff).
%%%   * `single_cell' — one differing cell in an otherwise-identical frame: the
%%%     common interactive case (a cursor blink, a counter tick) — the full scan
%%%     plus one cursor move and one glyph.
%%%   * `wide'        — `diff(blank, cjk_frame)': a frame of two-column CJK/emoji
%%%     glyphs, exercising the {@link //sonde_tui/sonde_width} column-advance on
%%%     the render path (issue #5) far harder than the ASCII dashboard.
%%%
%%% Legacy `rebar3_bench' callbacks: each `NAME/1' prepares the (cached) input
%%% pair and `bench_NAME/2' is the timed body — a single `diff/2' call. Run with
%%% `rebar3 as bench bench'.
%%%
%%% Frames are built entirely through the public `sonde_render' drawing API
%%% ({@link sonde_render:new/1}, {@link sonde_render:put_text/5}), so this module
%%% needs no access to the `#cell{}' record header.
%%% @end
%%%-------------------------------------------------------------------
-module(bench_render).

-export([
    full_paint/1,
    bench_full_paint/2,
    noop/1,
    bench_noop/2,
    single_cell/1,
    bench_single_cell/2,
    wide/1,
    bench_wide/2
]).

%% A realistic split-pane terminal size (PRD §8), common to all four cases so
%% the O(cells) diff scan floor is measured against the same 4800-cell grid.
-define(COLS, 120).
-define(ROWS, 40).

%%% -- full paint ------------------------------------------------------

%% Prepare the input once: a blank buffer and a fully populated frame.
full_paint({input, _}) ->
    Size = {?COLS, ?ROWS},
    {sonde_render:new(Size), dashboard(Size)}.

%% Timed body: repaint the whole screen from blank.
bench_full_paint({Prev, Next}, _) ->
    sonde_render:diff(Prev, Next).

%%% -- no-op (scan floor) ----------------------------------------------

%% Prepare the input once: the same populated frame on both sides.
noop({input, _}) ->
    Frame = dashboard({?COLS, ?ROWS}),
    {Frame, Frame}.

%% Timed body: diff a frame against itself — walks all cells, emits nothing.
bench_noop({Prev, Next}, _) ->
    sonde_render:diff(Prev, Next).

%%% -- single-cell change ----------------------------------------------

%% Prepare the input once: two copies of a populated frame differing at exactly
%% one cell. Overwriting the same ASCII cell with two different glyphs keeps the
%% difference to a single cell regardless of what the dashboard drew there.
single_cell({input, _}) ->
    Base = dashboard({?COLS, ?ROWS}),
    Prev = sonde_render:put_text(Base, 60, 20, "0"),
    Next = sonde_render:put_text(Base, 60, 20, "1"),
    {Prev, Next}.

%% Timed body: full scan plus a lone cursor move and one glyph.
bench_single_cell({Prev, Next}, _) ->
    sonde_render:diff(Prev, Next).

%%% -- wide-glyph-heavy paint ------------------------------------------

%% Prepare the input once: a blank buffer and a frame of two-column glyphs.
wide({input, _}) ->
    Size = {?COLS, ?ROWS},
    {sonde_render:new(Size), cjk_frame(Size)}.

%% Timed body: repaint a wide-glyph screen from blank.
bench_wide({Prev, Next}, _) ->
    sonde_render:diff(Prev, Next).

%%% -- frame builders --------------------------------------------------

%% A populated ASCII frame roughly the shape of a Sonde dashboard: a styled
%% title bar over process/metric rows. Body rows overflow the width and clip,
%% so the frame is densely filled — a genuine full repaint. Per-row styling
%% exercises the SGR transitions in diff/2, not just glyph emission.
dashboard(Size) ->
    Title = "Sonde   nodes: 4   procs: 128934   reductions/s: 4.21M   mem: 1.8G",
    Buf0 = sonde_render:new(Size),
    Buf1 = sonde_render:put_text(Buf0, 0, 0, pad(Title), #{bold => true, fg => 15, bg => 4}),
    lists:foldl(fun(Y, B) -> put_row(B, Y) end, Buf1, lists:seq(1, ?ROWS - 1)).

%% One process-listing style row, drawn with the row's style.
put_row(Buf, Y) ->
    sonde_render:put_text(Buf, 0, Y, pad(row_text(Y)), row_style(Y)).

%% A ~full-width process-listing line, varied per row so the frame is not a
%% single repeated string. Returned as an iolist (valid chardata for put_text).
row_text(Y) ->
    [
        "<0.",
        integer_to_list(100 + Y),
        ".0>   gen_server   running",
        "   reds=",
        integer_to_list(Y * 971 rem 100000),
        "   mq=",
        integer_to_list(Y rem 8),
        "   heap=",
        integer_to_list(610 + Y * 13),
        "   name=sonde_worker_",
        integer_to_list(Y),
        "   ",
        lists:duplicate(40, $-)
    ].

%% Vary styling across rows so adjacent changed runs force SGR changes.
row_style(Y) when Y rem 8 =:= 0 -> #{fg => 3};
row_style(Y) when Y rem 3 =:= 0 -> #{fg => 8};
row_style(_Y) -> #{}.

%% A frame of two-column glyphs, one tiled line per row, diffed against blank in
%% the `wide' case. Each glyph advances the write column by two via sonde_width.
cjk_frame(Size) ->
    Line = wide_line(),
    lists:foldl(
        fun(Y, B) -> sonde_render:put_text(B, 0, Y, Line) end,
        sonde_render:new(Size),
        lists:seq(0, ?ROWS - 1)
    ).

%% Exactly ?COLS columns of wide glyphs: a CJK/kana run plus an emoji is 12
%% two-column clusters (24 columns); five copies fill a 120-column row.
wide_line() ->
    Seg = [
        %% 日本語のテ
        16#65E5,
        16#672C,
        16#8A9E,
        16#306E,
        16#30C6,
        %% キストを表
        16#30AD,
        16#30B9,
        16#30C8,
        16#3092,
        16#8868,
        %% 示 + grinning face
        16#793A,
        16#1F600
    ],
    lists:append(lists:duplicate(5, Seg)).

%% Pad an ASCII line with spaces to the full terminal width. Over-width lines
%% are returned unchanged — put_text clips them at the right edge.
pad(Line) ->
    Bin = unicode:characters_to_binary(Line),
    case ?COLS - byte_size(Bin) of
        Fill when Fill > 0 -> <<Bin/binary, (binary:copy(<<" ">>, Fill))/binary>>;
        _ -> Bin
    end.
