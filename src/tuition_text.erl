%%%-------------------------------------------------------------------
%%% @doc Rich styled text — a `line' of styled `span's, ratatui's `Text' model.
%%%
%%% The styling model below this module is whole-widget: a {@link tuition_paragraph}
%%% carries one `style' for its whole block, a {@link tuition_list} row or {@link
%%% tuition_table} cell is plain chardata drawn in one style. This module adds the
%%% missing granularity — mixed styles *within* a single line — so an observer can
%%% colour a status word red, dim a timestamp prefix, or bold a matched substring
%%% without splitting the text across widgets.
%%%
%%% == The model ==
%%% Three layers, smallest first (ratatui's `Span'/`Line'/`Text'):
%%% ```
%%%   span() :: {Text :: chardata(), style()}   %% a styled run, one style
%%%   line() :: [span()]                        %% styled runs, left-to-right
%%%   text() :: [line()]                         %% lines, top-to-bottom
%%% '''
%%% `style()' is the same `#{fg,bg,bold,underline}' overlay {@link tuition_render}
%%% already understands. A span's style is drawn *over* the widget's base style
%%% (see {@link put_line/6}), so a span that sets only `#{bold => true}' bolds the
%%% text while keeping the paragraph/row/cell colour underneath.
%%%
%%% == Backward compatible ==
%%% Everywhere a widget accepts styled text it also still accepts plain chardata:
%%% a bare binary or iolist is exactly one span in the default style. The
%%% normalisers ({@link line/1}, {@link lines/1}) accept the flexible input a widget
%%% receives — plain chardata, a lone span, a single line, or a list of lines — and
%%% return the canonical shape (`[span()]' / `[line()]', span text as a UTF-8
%%% binary), so a widget written against the canonical form never sees the sugar.
%%%
%%% A <em>span</em> is recognised structurally: a `{Text, Style}' pair whose second
%%% element is a map, or a `#{text := Text}' map. Neither shape is valid chardata
%%% (chardata is integers, binaries and lists — never a tuple or a bare map), so
%%% the presence of a span is what tells styled input apart from plain chardata,
%%% with no ambiguity. To keep the plain path unchanged, <b>multi-line</b> plain
%%% text is still expressed with embedded `\n' (as {@link tuition_paragraph} always
%%% has); a list of bare binaries is chardata (concatenated), not a list of lines.
%%% Multiple lines come from `\n' or from a list whose elements are themselves
%%% span-carrying lines.
%%%
%%% == Rendering ==
%%% {@link put_line/6} draws a line span by span, measuring each in display columns
%%% with the same sanitise-aware {@link tuition_widget:display_width/1} /
%%% {@link tuition_widget:truncate/2} the plain widgets use, and clips the line at
%%% the area's right edge — so a styled line can no more spill onto a neighbour than
%%% a plain one can. {@link line_width/1} and {@link truncate_line/2} are the
%%% measure/clip helpers a widget aligns and wraps styled lines with.
%%%
%%% HARD CONSTRAINT (PRD §12): depends only on `kernel'/`stdlib'/`erts' plus the
%%% sibling render/widget modules. No third-party code.
%%% @end
%%%-------------------------------------------------------------------
-module(tuition_text).

-include("tuition_layout.hrl").

-export([span/1, span/2, line/1, lines/1, regroup/1, line_width/1, truncate_line/2, put_line/6]).

-type style() :: tuition_render:style().
%% A styled run: text plus the style overlaid on it. Its canonical form carries the
%% text as a UTF-8 binary, but a constructor accepts any chardata.
-type span() :: {unicode:chardata(), style()}.
%% A line: styled runs drawn left-to-right, sharing one row.
-type line() :: [span()].
%% Multiple lines, drawn top-to-bottom.
-type text() :: [line()].

%% The flexible input a widget accepts wherever it takes a single line: plain
%% chardata (one default-styled span), one span (tuple or map form), or a list
%% mixing bare chardata (default style) and spans.
-type line_input() ::
    unicode:chardata()
    | span_input()
    | [unicode:chardata() | span_input()].
%% The flexible input a widget accepts wherever it takes a block of text: plain
%% chardata (split on `\n'), a single {@type line_input()}, or a list of lines.
-type text_input() :: unicode:chardata() | line_input() | [line_input()].
%% Either span shape a caller may write: the `{Text, Style}' pair or the
%% `#{text := Text, style => Style}' map (style optional, default unstyled).
-type span_input() ::
    {unicode:chardata(), style()}
    | #{text := unicode:chardata(), style => style()}.

-export_type([style/0, span/0, line/0, text/0, line_input/0, text_input/0, span_input/0]).

%%% -- constructors ----------------------------------------------------

%% @doc A span in the default (unstyled) style — the styled equivalent of a bare
%% binary. Text is normalised to a UTF-8 binary.
-spec span(unicode:chardata()) -> span().
span(Text) -> span(Text, #{}).

%% @doc A span carrying `Style'. Text is normalised to a UTF-8 binary; the style is
%% overlaid on the widget's base style at draw time, so setting only some keys
%% leaves the rest to the base.
-spec span(unicode:chardata(), style()) -> span().
span(Text, Style) -> {to_bin(Text), Style}.

%%% -- normalisation ---------------------------------------------------

%% @doc Normalise one {@type line_input()} to the canonical `[span()]': plain
%% chardata becomes a single default-styled span, a lone span (either shape) a
%% one-span line, and a list mixing bare chardata and spans a line of the
%% corresponding runs. Empty-text spans are dropped, so a normalised line has no
%% zero-width runs to draw. This is what {@link tuition_list} normalises an item and
%% {@link tuition_table} a cell through, so both accept a styled line or the plain
%% chardata they took before.
-spec line(line_input()) -> line().
line(Input) -> drop_empty(to_spans(Input)).

%% @doc Normalise one {@type text_input()} to the canonical `[line()]', splitting on
%% `\n' (tolerating `\r\n'). Plain chardata splits into lines exactly as {@link
%% tuition_paragraph} always split it; a `\n' embedded in a span's text likewise
%% breaks the line, carrying the span's style onto both sides. A wholly empty line
%% is preserved as `[]' (an empty span list) so a blank line still occupies a row.
%% This is what {@link tuition_paragraph} normalises its `text' through.
-spec lines(text_input()) -> text().
lines(Input) ->
    lists:flatmap(fun split_line_nl/1, classify_text(Input)).

%%% -- measurement / clipping ------------------------------------------

%% @doc The display width of a whole line in terminal columns: the sum of its
%% runs' widths, each measured with the sanitise-aware {@link
%% tuition_widget:display_width/1} so the total agrees with what {@link put_line/6}
%% draws (a control byte counts as the one-column blank it becomes, a wide glyph as
%% two). The line is {@link regroup/1}ed first, so a grapheme cluster split across a
%% style boundary is measured as the one glyph it renders as rather than double-
%% counted from each half — keeping the width a widget aligns by in step with what
%% is drawn. Widgets use it to align a styled line the way they align a plain one.
-spec line_width(line()) -> non_neg_integer().
line_width(Line) ->
    lists:sum([tuition_widget:display_width(Text) || {Text, _Style} <- regroup(Line)]).

%% @doc The longest prefix of `Line' whose display width is at most `MaxCols'
%% columns, as a line — the line is {@link regroup/1}ed (so a cluster split across a
%% style boundary stays whole and is never torn at the clip), then clipped run by
%% run with {@link tuition_widget:truncate/2}, stopping at the first cluster that
%% would overflow (including a wide glyph with only one column left, dropped whole
%% as {@link tuition_render} would drop it). The width/truncate helper for styled
%% lines, and the clip {@link put_line/6} applies before drawing.
-spec truncate_line(line(), integer()) -> line().
truncate_line(_Line, MaxCols) when MaxCols =< 0 ->
    [];
truncate_line(Line, MaxCols) ->
    trunc_spans(regroup(Line), MaxCols, []).

-spec trunc_spans(line(), integer(), [span()]) -> line().
trunc_spans([], _Rem, Acc) ->
    lists:reverse(Acc);
trunc_spans(_Spans, Rem, Acc) when Rem =< 0 ->
    lists:reverse(Acc);
trunc_spans([{Text, Style} | Rest], Rem, Acc) ->
    Clipped = tuition_widget:truncate(Text, Rem),
    case {Clipped, to_bin(Text)} of
        %% An empty (or all-control-stripped-to-nothing) span contributes nothing:
        %% skip it and keep the budget for the runs that follow.
        {<<>>, <<>>} ->
            trunc_spans(Rest, Rem, Acc);
        %% Non-empty source but nothing fit — the next cluster overflows the budget
        %% (e.g. a wide glyph against one remaining column). Drawing would stop
        %% here, so the clip does too: no later span can start further right.
        {<<>>, _} ->
            lists:reverse(Acc);
        _ ->
            Used = tuition_widget:display_width(Clipped),
            trunc_spans(Rest, Rem - Used, [{Clipped, Style} | Acc])
    end.

%%% -- drawing ---------------------------------------------------------

%% @doc Draw a styled `Line' within `Area', at the `Area'-relative column `DCol'
%% and row `DRow', clipped to `Area' — the styled sibling of {@link
%% tuition_widget:put_line/6}. A row outside `[0, H)' or a column outside `[0, W)'
%% draws nothing, and the line is truncated to the columns remaining to `Area's
%% right edge (`W - DCol') so it can never spill onto a neighbour. Each span is
%% drawn with its own style overlaid on `Base' (the widget's base style), so a span
%% key overrides `Base' and the keys it omits fall through to `Base'.
%%
%% A grapheme cluster split across a span boundary (a base in one span, a combining
%% mark or ZWJ continuation in the next — as substring styling that is not
%% grapheme-aware can produce) is first stitched back whole, taking its base span's
%% style, so the trailing mark is never handed to {@link tuition_render} as a lone
%% zero-width cluster (which it would drop) and thereby lost.
-spec put_line(
    tuition_render:buffer(),
    #rect{},
    integer(),
    integer(),
    line(),
    style()
) -> tuition_render:buffer().
put_line(Buf, #rect{h = H}, _DCol, DRow, _Line, _Base) when DRow < 0; DRow >= H ->
    Buf;
put_line(Buf, #rect{w = W}, DCol, _DRow, _Line, _Base) when DCol < 0; DCol >= W ->
    Buf;
put_line(Buf, #rect{x = X, y = Y, w = W}, DCol, DRow, Line, Base) ->
    %% truncate_line/2 regroups the line, so the clipped runs handed to draw_spans
    %% are already grapheme-aligned — a split cluster is one run, never a lone mark.
    Clipped = truncate_line(Line, W - DCol),
    draw_spans(Buf, X + DCol, Y + DRow, Clipped, Base).

%% Draw each span at the running column, advancing by the span's own display width
%% so the next span starts exactly where this one ended. The line is already
%% clipped to the area, so put_text's own right-edge clip only ever backs it up.
-spec draw_spans(tuition_render:buffer(), integer(), integer(), line(), style()) ->
    tuition_render:buffer().
draw_spans(Buf, _X, _Y, [], _Base) ->
    Buf;
draw_spans(Buf, X, Y, [{Text, Style} | Rest], Base) ->
    Buf1 = tuition_render:put_text(Buf, X, Y, Text, maps:merge(Base, Style)),
    draw_spans(Buf1, X + tuition_widget:display_width(Text), Y, Rest, Base).

%%% -- grapheme regrouping ---------------------------------------------

%% @doc Re-segment a line's spans on grapheme-cluster boundaries computed across the
%% whole line, so a cluster split by a style change is stitched back into a single
%% run and never drawn — or measured, or wrapped — as its parts. Each cluster takes
%% the style of the span its base (first byte) came from — a cell renders one glyph
%% in one style, so the base's style is the only sensible choice — and runs of equal
%% style are coalesced back together. A line of zero or one span has no cross-span
%% boundary to heal and is returned untouched, which keeps the plain (single-span)
%% path allocation free. {@link line_width/1}, {@link truncate_line/2} and {@link
%% put_line/6} apply it themselves; it is exported so {@link tuition_paragraph} can
%% heal a word before hard-wrapping it, where a cluster torn across two output rows
%% could not be stitched back afterwards.
-spec regroup(line()) -> line().
regroup([]) ->
    [];
regroup([_] = Line) ->
    Line;
regroup(Line) ->
    Segments = [{byte_size(to_bin(Text)), Style} || {Text, Style} <- Line],
    AllBin = list_to_binary([to_bin(Text) || {Text, _Style} <- Line]),
    Total = byte_size(AllBin),
    Clusters = clusters(AllBin, Total, []),
    coalesce([{Cluster, style_at(Offset, Segments)} || {Cluster, Offset} <- Clusters]).

%% The grapheme clusters of `Bin', each paired with its byte offset into the whole
%% line (`Total - byte_size(remaining)'), so a later lookup can find the span it
%% began in. Returned in order.
-spec clusters(binary(), non_neg_integer(), [{binary(), non_neg_integer()}]) ->
    [{binary(), non_neg_integer()}].
clusters(Bin, Total, Acc) ->
    case string:next_grapheme(Bin) of
        [GC | Rest] when is_integer(GC); is_list(GC) ->
            Offset = Total - byte_size(Bin),
            clusters(as_bin(Rest), Total, [{grapheme_bin(GC), Offset} | Acc]);
        _ ->
            lists:reverse(Acc)
    end.

%% The style of the span covering byte `Offset': walk the `{ByteLen, Style}'
%% segments, spending the offset against each until it lands inside one. A trailing
%% offset past every segment (only reachable via a malformed decode) takes the
%% default style.
-spec style_at(non_neg_integer(), [{non_neg_integer(), style()}]) -> style().
style_at(_Offset, []) ->
    #{};
style_at(Offset, [{Len, Style} | Rest]) ->
    case Offset < Len of
        true -> Style;
        false -> style_at(Offset - Len, Rest)
    end.

%% Merge adjacent clusters that share a style into one run, so drawing emits one
%% put_text per styled run rather than one per cluster.
-spec coalesce([span()]) -> line().
coalesce([]) ->
    [];
coalesce([{Bin, Style} | Rest]) ->
    coalesce(Rest, Bin, Style, []).

-spec coalesce([span()], binary(), style(), [span()]) -> line().
coalesce([], CurBin, CurStyle, Acc) ->
    lists:reverse([{CurBin, CurStyle} | Acc]);
coalesce([{Bin, Style} | Rest], CurBin, CurStyle, Acc) when Style =:= CurStyle ->
    coalesce(Rest, <<CurBin/binary, Bin/binary>>, CurStyle, Acc);
coalesce([{Bin, Style} | Rest], CurBin, CurStyle, Acc) ->
    coalesce(Rest, Bin, Style, [{CurBin, CurStyle} | Acc]).

%% A grapheme cluster (a lone codepoint or a codepoint list) as a UTF-8 binary.
-spec grapheme_bin(char() | [char()]) -> binary().
grapheme_bin(GC) when is_integer(GC) -> <<GC/utf8>>;
grapheme_bin(GC) when is_list(GC) -> to_bin(GC).

%% The remainder from string:next_grapheme/1 as a binary (it hands back a binary
%% tail for binary input, but tolerate a chardata tail too).
-spec as_bin(unicode:chardata()) -> binary().
as_bin(Bin) when is_binary(Bin) -> Bin;
as_bin(Other) -> to_bin(Other).

%%% -- classification --------------------------------------------------

%% Split a flexible text input into its per-line pieces, before `\n' splitting: a
%% list whose elements are themselves span-carrying lines is already a list of
%% lines; anything else (plain chardata, a lone span, a single mixed line) is one
%% line.
-spec classify_text(text_input()) -> [line_input()].
classify_text(Bin) when is_binary(Bin) ->
    [Bin];
classify_text(List) when is_list(List) ->
    case has_line_element(List) of
        true -> List;
        false -> [List]
    end;
classify_text(Other) ->
    [Other].

%% Does a (possibly improper) list carry a nested line element? Walked directly,
%% not via `lists:any/2', so a plain improper iolist (`[<<"a">> | <<"b">>]', a
%% binary tail) is tolerated as "no line" rather than crashing the scan.
-spec has_line_element(nonempty_maybe_improper_list()) -> boolean().
has_line_element([H | T]) -> is_line_element(H) orelse has_line_element(T);
has_line_element(_Tail) -> false.

%% A list element that is itself a line — a list carrying at least one span. Only a
%% nested span-list marks the outer value as a list of lines; a bare binary or a
%% char list (plain chardata) never does, keeping the plain multi-line path on
%% `\n'.
-spec is_line_element(term()) -> boolean().
is_line_element(E) when is_list(E) -> has_span(E);
is_line_element(_) -> false.

%% Normalise one line input to canonical spans, keeping empty runs (the `\n'
%% splitter needs them; {@link line/1} drops them afterwards).
-spec to_spans(line_input()) -> [span()].
to_spans(Bin) when is_binary(Bin) ->
    [{Bin, #{}}];
to_spans(List) when is_list(List) ->
    case has_span(List) of
        true -> [elem_to_span(E) || E <- List];
        false -> [{to_bin(List), #{}}]
    end;
to_spans(Span) ->
    case is_span(Span) of
        true -> [norm_span(Span)];
        false -> [{to_bin(Span), #{}}]
    end.

%% Does a (possibly improper) list contain a span element? Walked directly rather
%% than via `lists:any/2' so an improper iolist tail — a plain-chardata binary tail
%% the old widgets accepted (`[<<"a">> | <<"b">>]') — is tolerated as "no span"
%% instead of crashing the scan; such input stays plain chardata, as it was.
-spec has_span(nonempty_maybe_improper_list()) -> boolean().
has_span([H | T]) -> is_span(H) orelse has_span(T);
has_span(_Tail) -> false.

%% A list element inside a line: a span in either shape, or bare chardata (a
%% default-styled run).
-spec elem_to_span(unicode:chardata() | span_input()) -> span().
elem_to_span(E) ->
    case is_span(E) of
        true -> norm_span(E);
        false -> {to_bin(E), #{}}
    end.

%% Is this value a span (either shape)? A `{_, Style}' pair with a map style, or a
%% `#{text := _}' map. Deliberately narrow so no chardata is ever mistaken for one.
-spec is_span(term()) -> boolean().
is_span({_Text, Style}) when is_map(Style) -> true;
is_span(Map) when is_map(Map) -> is_map_key(text, Map);
is_span(_) -> false.

%% Canonicalise a span to `{binary(), style()}'.
-spec norm_span(span_input()) -> span().
norm_span({Text, Style}) when is_map(Style) -> {to_bin(Text), Style};
norm_span(Map) when is_map(Map) -> {to_bin(maps:get(text, Map)), maps:get(style, Map, #{})}.

%%% -- newline splitting -----------------------------------------------

%% Normalise one line input to spans, then split it at every embedded `\n' into one
%% or more canonical lines (empty runs dropped per line).
-spec split_line_nl(line_input()) -> [line()].
split_line_nl(Input) ->
    split_spans_nl(to_spans(Input)).

%% Split a span list into lines at `\n' boundaries, carrying each span's style onto
%% every piece it is broken into. `\r\n' is tolerated by dropping the `\r' as each
%% line is closed (see {@link close_line/1}).
-spec split_spans_nl([span()]) -> [line()].
split_spans_nl(Spans) ->
    {LinesRev, CurRev} = lists:foldl(fun split_span/2, {[], []}, Spans),
    Lines = lists:reverse([close_line(CurRev) | LinesRev]),
    [drop_empty(Line) || Line <- Lines].

%% Fold one span into the {completed-lines, current-line} accumulator (both
%% reversed): its first piece continues the current line, and every `\n' after it
%% closes the current line and starts a fresh one with the following piece.
-spec split_span(span(), {[line()], [span()]}) -> {[line()], [span()]}.
split_span({Text, Style}, {LinesRev, CurRev}) ->
    [First | Rest] = binary:split(to_bin(Text), <<"\n">>, [global]),
    Cur1 = [{First, Style} | CurRev],
    lists:foldl(
        fun(Piece, {LR, CR}) -> {[close_line(CR) | LR], [{Piece, Style}]} end,
        {LinesRev, Cur1},
        Rest
    ).

%% Finalise a reversed line accumulator into an in-order line, dropping a single
%% trailing `\r' from its last non-empty span. That `\r' sits immediately before
%% the `\n' that ends the line (or before end-of-text), so it is the CR of a CRLF
%% break; a `\r' anywhere else — mid-line, including at a span boundary the line
%% continues past — stays and renders as a blank column, exactly as the same text
%% renders when it is not split into spans.
-spec close_line([span()]) -> line().
close_line(SpansRev) ->
    lists:reverse(strip_trailing_cr(SpansRev)).

%% Strip one trailing `\r' from the last non-empty span of a reversed line. Empty
%% spans at the head (in-order: the tail of the line) carry no `\r' and are passed
%% over — a following span that began with the line's terminating `\n' contributes
%% such an empty piece, and the CR to drop sits on the span before it, so the strip
%% must skip past the empty piece to reach it.
-spec strip_trailing_cr([span()]) -> [span()].
strip_trailing_cr([]) -> [];
strip_trailing_cr([{<<>>, _Style} = Empty | Rest]) -> [Empty | strip_trailing_cr(Rest)];
strip_trailing_cr([{Bin, Style} | Rest]) -> [{strip_cr(Bin), Style} | Rest].

%%% -- small utilities -------------------------------------------------

%% Drop empty-text spans, so a normalised line carries only runs that draw
%% something (an entirely empty line stays `[]', still occupying a row).
-spec drop_empty([span()]) -> line().
drop_empty(Spans) ->
    [Span || {Text, _Style} = Span <- Spans, Text =/= <<>>].

-spec strip_cr(binary()) -> binary().
strip_cr(Line) ->
    Size = byte_size(Line),
    case Size > 0 andalso binary:at(Line, Size - 1) =:= $\r of
        true -> binary:part(Line, 0, Size - 1);
        false -> Line
    end.

%% Best-effort chardata -> UTF-8 binary; a malformed tail contributes whatever
%% prefix decoded, so normalising never crashes on bad encodings (matching the
%% renderer's own tolerance for untrusted content).
-spec to_bin(unicode:chardata()) -> binary().
to_bin(Text) ->
    case unicode:characters_to_binary(Text) of
        Bin when is_binary(Bin) -> Bin;
        {error, Good, _Rest} -> Good;
        {incomplete, Good, _Rest} -> Good
    end.
