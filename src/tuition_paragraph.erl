%%%-------------------------------------------------------------------
%%% @doc Paragraph widget — styled, wrapped, aligned, scrollable text.
%%%
%%% A paragraph renders a block of text into a rect: it splits the text into
%%% lines on `\n', optionally word-wraps each source line to the rect width,
%%% aligns every rendered line left/centre/right, and draws the slice of lines a
%%% vertical scroll offset selects. It is the ratatui `Paragraph' — the widget the
%%% detail/help panes and the system-dashboard text tiles (PRD §9.1) are built
%%% from.
%%%
%%% == Config ==
%%% A `#{}' map, every key optional:
%%% <ul>
%%%   <li>`text'   — the content. Plain chardata (embedded `\n' / `\r\n' split it
%%%       into lines) as before, or the {@link tuition_text} styled model — a
%%%       {@type tuition_text:text_input()} — so a single line can carry mixed
%%%       per-span styles. Default `<<>>' (an empty paragraph draws nothing).</li>
%%%   <li>`wrap'   — `none' (default; long lines are clipped at the right edge) or
%%%       `word' (greedy word wrap to the rect width, hard-splitting a single word
%%%       longer than the width). Word wrap works across spans, carrying each
%%%       run's style with it.</li>
%%%   <li>`align'  — `left' (default), `center' or `right', applied per line.</li>
%%%   <li>`scroll' — the number of rendered lines to skip from the top (default
%%%       `0'); the vertical scroll offset. Held in the app state by the caller,
%%%       like any other widget scroll position.</li>
%%%   <li>`style'  — a base style overlaid on every drawn cell (default: unstyled).
%%%       A span's own style is layered over this base, so an unstyled span shows
%%%       the paragraph style and a span key overrides it.</li>
%%% </ul>
%%%
%%% == Wrapping and width ==
%%% Wrapping and alignment measure text in terminal *columns* ({@link
%%% tuition_width}), not codepoints, so a line of CJK or emoji wraps and centres by
%%% the space it actually occupies. Word wrap collapses runs of spaces (ratatui's
%%% trimming wrap): each rendered line is packed greedily and its own leading/
%%% trailing padding comes from alignment, not the source spacing. A word that
%%% straddles a style boundary keeps each run's style through the wrap. Whatever the
%%% wrap decision, every rendered line is finally drawn through {@link
%%% tuition_text:put_line/6}, which truncates it to the rect — so nothing ever
%%% spills past the paragraph's region onto a neighbour.
%%%
%%% HARD CONSTRAINT (PRD §12): depends only on `kernel'/`stdlib'/`erts' plus the
%%% sibling render/layout/width/widget/text modules. No third-party code.
%%% @end
%%%-------------------------------------------------------------------
-module(tuition_paragraph).
-behaviour(tuition_widget).

-include("tuition_layout.hrl").

-export([render/3]).

-type wrap() :: none | word.
-type paragraph() :: #{
    text => tuition_text:text_input(),
    wrap => wrap(),
    align => left | center | right,
    scroll => non_neg_integer(),
    style => tuition_render:style()
}.

-export_type([paragraph/0, wrap/0]).

%% A word being wrapped: styled runs with no spaces, possibly straddling a style
%% boundary (so it carries more than one span). Its width is the sum of its runs'.
-type word() :: [tuition_text:span()].
%% A word paired with the style of the space that separated it from the next word
%% (the first space of a collapsed run). When two words land on one wrapped line,
%% the joining space is re-inserted in this style, so a space that is part of a
%% styled span keeps that span's background rather than reverting to the base.
-type wsep() :: {word(), tuition_text:style()}.

%%% -- render ----------------------------------------------------------

%% @doc Draw the paragraph into `Area'. A degenerate area (no columns or rows)
%% draws nothing. See the module doc for the config map.
-spec render(paragraph(), #rect{}, tuition_render:buffer()) -> tuition_render:buffer().
render(_Para, #rect{w = W, h = H}, Buf) when W =< 0; H =< 0 ->
    Buf;
render(Para, #rect{w = W} = Area, Buf) ->
    Wrap = maps:get(wrap, Para, none),
    Align = maps:get(align, Para, left),
    Style = maps:get(style, Para, #{}),
    Scroll = maps:get(scroll, Para, 0),
    Source = tuition_text:lines(maps:get(text, Para, <<>>)),
    Rendered = lists:flatmap(fun(Line) -> wrap_line(Wrap, Line, W) end, Source),
    Visible = drop(Scroll, Rendered),
    draw_lines(Visible, Area, Align, Style, 0, Buf).

%% Draw rendered lines top to bottom, one per row, stopping at the rect's height
%% (a line scrolled past the bottom is never drawn) or when the lines run out.
-spec draw_lines(
    [tuition_text:line()],
    #rect{},
    left | center | right,
    tuition_render:style(),
    non_neg_integer(),
    tuition_render:buffer()
) -> tuition_render:buffer().
draw_lines(_Lines, #rect{h = H}, _Align, _Style, Row, Buf) when Row >= H ->
    Buf;
draw_lines([], _Area, _Align, _Style, _Row, Buf) ->
    Buf;
draw_lines([Line | Rest], #rect{w = W} = Area, Align, Style, Row, Buf) ->
    %% Measure with the styled-line width, which sums each span the sanitise-aware
    %% way tuition_text:put_line/6 will draw it (a control byte counts as the
    %% one-column blank it becomes), so a centred/right-aligned line is placed by
    %% the columns it truly occupies and its tail is never clipped.
    Width = min(tuition_text:line_width(Line), W),
    Col = tuition_widget:align_offset(Align, W, Width),
    Buf1 = tuition_text:put_line(Buf, Area, Col, Row, Line, Style),
    draw_lines(Rest, Area, Align, Style, Row + 1, Buf1).

%%% -- word wrap -------------------------------------------------------

%% `none' keeps the source line whole ({@link tuition_text:put_line/6} clips it at
%% the right edge); `word' greedily packs words onto lines no wider than W columns.
-spec wrap_line(wrap(), tuition_text:line(), non_neg_integer()) -> [tuition_text:line()].
wrap_line(none, Line, _W) ->
    [Line];
wrap_line(word, Line, W) ->
    case wrap_words(tokenize(Line), W, none, #{}, []) of
        %% A wholly empty (or all-whitespace) source line still occupies one row,
        %% so a blank line in the text renders as a blank row rather than vanishing.
        [] -> [[]];
        Lines -> Lines
    end.

%% Split a styled line into words at every space, collapsing runs of spaces and
%% carrying each run's style. A word that straddles a style boundary keeps both
%% runs: two adjacent spans with no space between them join into one word whose
%% halves keep their own styles. Each word is paired with the style of the space
%% that follows it, so a joining space re-inserted at pack time keeps that style.
-spec tokenize(tuition_text:line()) -> [wsep()].
tokenize(Line) ->
    Acc = lists:foldl(fun tokenize_span/2, {[], []}, Line),
    %% The final word has no following space; its separator style is unused.
    {WordsRev, _} = close_word(#{}, Acc),
    lists:reverse(WordsRev).

%% Fold one span into {finished-words, current-word} (both reversed): its first
%% piece continues the current word, and every space after it closes the current
%% word and starts a fresh one. The closing space belongs to this span, so its
%% style is recorded as the closed word's separator.
-spec tokenize_span(tuition_text:span(), {[wsep()], word()}) -> {[wsep()], word()}.
tokenize_span({Bin, Style}, Acc0) ->
    [First | Rest] = binary:split(Bin, <<" ">>, [global]),
    Acc1 = add_frag(First, Style, Acc0),
    lists:foldl(
        fun(Piece, Acc) -> add_frag(Piece, Style, close_word(Style, Acc)) end,
        Acc1,
        Rest
    ).

%% Append a non-empty fragment to the current word; an empty piece (from a
%% collapsed run of spaces or a span edge on a space) adds nothing.
-spec add_frag(binary(), tuition_text:style(), {[wsep()], word()}) -> {[wsep()], word()}.
add_frag(<<>>, _Style, Acc) -> Acc;
add_frag(Bin, Style, {WordsRev, CurRev}) -> {WordsRev, [{Bin, Style} | CurRev]}.

%% Close the current word onto the finished list, tagging it with `SepStyle' (the
%% style of the space that ended it). A no-op when the current word is empty, so a
%% collapsed run of spaces never emits an empty word and the first space of the run
%% is the one whose style is kept.
-spec close_word(tuition_text:style(), {[wsep()], word()}) -> {[wsep()], word()}.
close_word(_SepStyle, {WordsRev, []}) -> {WordsRev, []};
close_word(SepStyle, {WordsRev, CurRev}) -> {[{lists:reverse(CurRev), SepStyle} | WordsRev], []}.

%% Greedy word wrap. `Cur' is the line being built (`none' before the first word
%% lands on it), `PrevSep' the separator style of the last word placed on it (the
%% style a joining space takes), and `Acc' holds the finished lines in reverse.
-spec wrap_words(
    [wsep()],
    non_neg_integer(),
    none | tuition_text:line(),
    tuition_text:style(),
    [tuition_text:line()]
) -> [tuition_text:line()].
wrap_words([], _W, Cur, _PrevSep, Acc) ->
    lists:reverse(flush(Cur, Acc));
wrap_words([{Word, Sep} | Rest], W, Cur, PrevSep, Acc) ->
    {Cur1, Acc1} = place(Word, W, Cur, PrevSep, Acc),
    wrap_words(Rest, W, Cur1, Sep, Acc1).

%% Push the current line (if any) onto the finished list.
-spec flush(none | tuition_text:line(), [tuition_text:line()]) -> [tuition_text:line()].
flush(none, Acc) -> Acc;
flush(Cur, Acc) -> [Cur | Acc].

%% Place one word: on its own it either extends the current line (with a joining
%% space in `PrevSep's style) when it still fits, or starts a fresh line; a word
%% wider than the whole line is hard-split into column-sized chunks.
%%
%% The word is regrouped on grapheme boundaries first, so a cluster split across a
%% style boundary (a base fragment and a combining/ZWJ continuation fragment with no
%% space between them) is one run before it is measured or hard-split: measuring the
%% healed run gives the true width, and hard-splitting it never tears the cluster
%% across two rows — which {@link tuition_text:put_line/6}, regrouping only within a
%% single output line, could not undo.
-spec place(
    word(),
    non_neg_integer(),
    none | tuition_text:line(),
    tuition_text:style(),
    [tuition_text:line()]
) -> {tuition_text:line(), [tuition_text:line()]}.
place(Word0, W, Cur, PrevSep, Acc) ->
    Word = tuition_text:regroup(Word0),
    case word_width(Word) =< W of
        true -> place_fitting(Word, W, Cur, PrevSep, Acc);
        false -> place_long(Word, W, Cur, Acc)
    end.

-spec place_fitting(
    word(),
    non_neg_integer(),
    none | tuition_text:line(),
    tuition_text:style(),
    [tuition_text:line()]
) -> {tuition_text:line(), [tuition_text:line()]}.
place_fitting(Word, _W, none, _PrevSep, Acc) ->
    {Word, Acc};
place_fitting(Word, W, Cur, PrevSep, Acc) ->
    case tuition_text:line_width(Cur) + 1 + word_width(Word) =< W of
        true -> {Cur ++ [{<<" ">>, PrevSep} | Word], Acc};
        false -> {Word, [Cur | Acc]}
    end.

%% A word wider than the whole line: flush the current line, hard-split the word
%% into W-column chunks, and keep the final chunk as the new current line so a
%% following short word can still share its row.
-spec place_long(word(), non_neg_integer(), none | tuition_text:line(), [tuition_text:line()]) ->
    {tuition_text:line(), [tuition_text:line()]}.
place_long(Word, W, Cur, Acc0) ->
    {Chunks, Last} = hard_split(Word, W),
    {Last, lists:reverse(Chunks, flush(Cur, Acc0))}.

%% Split a word into full W-column chunks plus a final (possibly shorter) chunk,
%% keeping each run's style across the splits.
-spec hard_split(word(), non_neg_integer()) -> {[tuition_text:line()], tuition_text:line()}.
hard_split(Word, W) ->
    hard_split(Word, W, []).

-spec hard_split(word(), non_neg_integer(), [tuition_text:line()]) ->
    {[tuition_text:line()], tuition_text:line()}.
hard_split(Word, W, Acc) ->
    {Head, Rest} = peel(Word, W),
    case Rest of
        [] -> {lists:reverse(Acc), Head};
        _ -> hard_split(Rest, W, [Head | Acc])
    end.

%% Peel a chunk of at most W columns off the front of `Word', spanning as many of
%% its runs as fit and keeping each run's style. Always takes at least one grapheme
%% cluster (via {@link tuition_widget:split/2}) so an over-wide word still makes
%% progress; the run that overflows the budget is left for the next chunk.
-spec peel(word(), non_neg_integer()) -> {tuition_text:line(), word()}.
peel(Word, W) ->
    peel(Word, W, 0, []).

-spec peel(word(), non_neg_integer(), non_neg_integer(), tuition_text:line()) ->
    {tuition_text:line(), word()}.
peel([], _W, _Used, Acc) ->
    {lists:reverse(Acc), []};
peel([{Bin, Style} | Rest], W, Used, Acc) ->
    Rem = W - Used,
    {Head, Tail} = tuition_widget:split(Bin, Rem),
    Hw = tuition_widget:display_width(Head),
    case Acc =/= [] andalso Hw > Rem of
        %% This run's first cluster overflows the remaining budget and the chunk
        %% already has content: close the chunk here without consuming the run.
        true ->
            {lists:reverse(Acc), [{Bin, Style} | Rest]};
        false ->
            Acc1 = [{Head, Style} | Acc],
            Used1 = Used + Hw,
            case Tail of
                %% Run fully consumed with room left: pull in the next run.
                <<>> when Used1 < W -> peel(Rest, W, Used1, Acc1);
                %% Run consumed but the chunk is now full.
                <<>> -> {lists:reverse(Acc1), Rest};
                %% Run split at the budget: its tail starts the next chunk.
                _ -> {lists:reverse(Acc1), [{Tail, Style} | Rest]}
            end
    end.

-spec word_width(word()) -> non_neg_integer().
word_width(Word) ->
    lists:sum([tuition_widget:display_width(Bin) || {Bin, _Style} <- Word]).

%%% -- small utilities -------------------------------------------------

%% Drop the first N elements, tolerating N greater than the list length (a scroll
%% offset past the end yields an empty list rather than crashing).
-spec drop(non_neg_integer(), [T]) -> [T].
drop(0, List) -> List;
drop(_N, []) -> [];
drop(N, [_ | T]) when N > 0 -> drop(N - 1, T).
