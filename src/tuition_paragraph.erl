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
%%%   <li>`text'   — the content as chardata; embedded `\n' (or `\r\n') split it
%%%       into lines. Default `<<>>' (an empty paragraph draws nothing).</li>
%%%   <li>`wrap'   — `none' (default; long lines are clipped at the right edge) or
%%%       `word' (greedy word wrap to the rect width, hard-splitting a single word
%%%       longer than the width).</li>
%%%   <li>`align'  — `left' (default), `center' or `right', applied per line.</li>
%%%   <li>`scroll' — the number of rendered lines to skip from the top (default
%%%       `0'); the vertical scroll offset. Held in the app state by the caller,
%%%       like any other widget scroll position.</li>
%%%   <li>`style'  — a style overlaid on every drawn cell (default: unstyled).</li>
%%% </ul>
%%%
%%% == Wrapping and width ==
%%% Wrapping and alignment measure text in terminal *columns* ({@link
%%% tuition_width}), not codepoints, so a line of CJK or emoji wraps and centres by
%%% the space it actually occupies. Word wrap collapses runs of spaces (ratatui's
%%% trimming wrap): each rendered line is packed greedily and its own leading/
%%% trailing padding comes from alignment, not the source spacing. Whatever the
%%% wrap decision, every rendered line is finally drawn through {@link
%%% tuition_widget:put_line/6}, which truncates it to the rect — so nothing ever
%%% spills past the paragraph's region onto a neighbour.
%%%
%%% HARD CONSTRAINT (PRD §12): depends only on `kernel'/`stdlib'/`erts' plus the
%%% sibling render/layout/width/widget modules. No third-party code.
%%% @end
%%%-------------------------------------------------------------------
-module(tuition_paragraph).
-behaviour(tuition_widget).

-include("tuition_layout.hrl").

-export([render/3]).

-type wrap() :: none | word.
-type paragraph() :: #{
    text => unicode:chardata(),
    wrap => wrap(),
    align => left | center | right,
    scroll => non_neg_integer(),
    style => tuition_render:style()
}.

-export_type([paragraph/0, wrap/0]).

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
    Source = split_lines(maps:get(text, Para, <<>>)),
    Rendered = lists:flatmap(fun(Line) -> wrap_line(Wrap, Line, W) end, Source),
    Visible = drop(Scroll, Rendered),
    draw_lines(Visible, Area, Align, Style, 0, Buf).

%% Draw rendered lines top to bottom, one per row, stopping at the rect's height
%% (a line scrolled past the bottom is never drawn) or when the lines run out.
-spec draw_lines(
    [binary()],
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
    %% Measure with the widget layer's sanitise-aware width, not tuition_width:swidth/1:
    %% a control byte in untrusted text renders as a one-column blank (put_line
    %% clips it as one), so the alignment offset must count it as one too or a
    %% centred/right-aligned line would be misplaced and its tail clipped.
    Width = min(tuition_widget:display_width(Line), W),
    Col = tuition_widget:align_offset(Align, W, Width),
    Buf1 = tuition_widget:put_line(Buf, Area, Col, Row, Line, Style),
    draw_lines(Rest, Area, Align, Style, Row + 1, Buf1).

%%% -- line splitting --------------------------------------------------

%% Split text into source lines on `\n', tolerating `\r\n' by stripping a
%% trailing carriage return from each. Chardata is normalised to a binary first,
%% so a deep iolist splits the same as a flat binary.
-spec split_lines(unicode:chardata()) -> [binary()].
split_lines(Text) ->
    [strip_cr(Line) || Line <- binary:split(to_bin(Text), <<"\n">>, [global])].

-spec strip_cr(binary()) -> binary().
strip_cr(Line) ->
    Size = byte_size(Line),
    case Size > 0 andalso binary:at(Line, Size - 1) =:= $\r of
        true -> binary:part(Line, 0, Size - 1);
        false -> Line
    end.

%%% -- word wrap -------------------------------------------------------

%% `none' keeps the source line whole (put_line clips it at the right edge);
%% `word' greedily packs words onto lines no wider than W columns.
-spec wrap_line(wrap(), binary(), non_neg_integer()) -> [binary()].
wrap_line(none, Line, _W) ->
    [Line];
wrap_line(word, Line, W) ->
    case wrap_words(binary:split(Line, <<" ">>, [global]), W, none, []) of
        %% A wholly empty (or all-whitespace) source line still occupies one row,
        %% so a blank line in the text renders as a blank row rather than vanishing.
        [] -> [<<>>];
        Lines -> Lines
    end.

%% Greedy word wrap. `Cur' is the line being built (`none' before the first word
%% lands on it); `Acc' holds the finished lines in reverse. Empty tokens (from
%% collapsed runs of spaces) are skipped.
-spec wrap_words([binary()], non_neg_integer(), none | binary(), [binary()]) -> [binary()].
wrap_words([], _W, Cur, Acc) ->
    lists:reverse(flush(Cur, Acc));
wrap_words([<<>> | Rest], W, Cur, Acc) ->
    wrap_words(Rest, W, Cur, Acc);
wrap_words([Word | Rest], W, Cur, Acc) ->
    {Cur1, Acc1} = place(Word, W, Cur, Acc),
    wrap_words(Rest, W, Cur1, Acc1).

%% Push the current line (if any) onto the finished list.
-spec flush(none | binary(), [binary()]) -> [binary()].
flush(none, Acc) -> Acc;
flush(Cur, Acc) -> [Cur | Acc].

%% Place one word: on its own it either extends the current line (with a joining
%% space) when it still fits, or starts a fresh line; a word wider than the whole
%% line is hard-split into column-sized chunks.
-spec place(binary(), non_neg_integer(), none | binary(), [binary()]) ->
    {binary(), [binary()]}.
place(Word, W, Cur, Acc) ->
    case tuition_widget:display_width(Word) =< W of
        true -> place_fitting(Word, W, Cur, Acc);
        false -> place_long(Word, W, Cur, Acc)
    end.

-spec place_fitting(binary(), non_neg_integer(), none | binary(), [binary()]) ->
    {binary(), [binary()]}.
place_fitting(Word, _W, none, Acc) ->
    {Word, Acc};
place_fitting(Word, W, Cur, Acc) ->
    case tuition_widget:display_width(Cur) + 1 + tuition_widget:display_width(Word) =< W of
        true -> {<<Cur/binary, " ", Word/binary>>, Acc};
        false -> {Word, [Cur | Acc]}
    end.

%% A word wider than the whole line: flush the current line, hard-split the word
%% into W-column chunks, and keep the final chunk as the new current line so a
%% following short word can still share its row.
-spec place_long(binary(), non_neg_integer(), none | binary(), [binary()]) ->
    {binary(), [binary()]}.
place_long(Word, W, Cur, Acc0) ->
    {Chunks, Last} = hard_split(Word, W),
    {Last, lists:reverse(Chunks, flush(Cur, Acc0))}.

%% Split a word into full W-column chunks plus a final (possibly shorter) chunk.
-spec hard_split(binary(), non_neg_integer()) -> {[binary()], binary()}.
hard_split(Word, W) ->
    hard_split(Word, W, []).

-spec hard_split(binary(), non_neg_integer(), [binary()]) -> {[binary()], binary()}.
hard_split(Word, W, Acc) ->
    {Head, Rest} = tuition_widget:split(Word, W),
    case Rest of
        <<>> -> {lists:reverse(Acc), Head};
        _ -> hard_split(Rest, W, [Head | Acc])
    end.

%%% -- small utilities -------------------------------------------------

%% Drop the first N elements, tolerating N greater than the list length (a scroll
%% offset past the end yields an empty list rather than crashing).
-spec drop(non_neg_integer(), [T]) -> [T].
drop(0, List) -> List;
drop(_N, []) -> [];
drop(N, [_ | T]) when N > 0 -> drop(N - 1, T).

%% Best-effort chardata -> UTF-8 binary; a malformed tail contributes whatever
%% prefix decoded, so rendering never crashes on bad encodings.
-spec to_bin(unicode:chardata()) -> binary().
to_bin(Text) ->
    case unicode:characters_to_binary(Text) of
        Bin when is_binary(Bin) -> Bin;
        {error, Good, _Rest} -> Good;
        {incomplete, Good, _Rest} -> Good
    end.
