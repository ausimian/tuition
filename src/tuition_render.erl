-module(tuition_render).
-moduledoc """
Double-buffered cell grid with diff-based minimal repaint.

The renderer is immediate-mode, the ratatui model:
every frame is rebuilt from scratch into a fresh `t:buffer/0` of
`t:tuition_term:size/0` cells, then `diff/2` compares it
against the buffer currently on screen and emits ANSI for *only* the cells
that changed. The caller keeps the last buffer as the next frame's baseline:

```
Prev0 = tuition_render:new(Size), %% blank screen
Next = build_frame(State), %% put_text/put_cell...
ok = tuition_term:write(Handle, tuition_render:diff(Prev0, Next)),
loop(Handle, Next). %% Next becomes the baseline
```

## Minimal output

Emission walks the grid in row-major order and, for each changed cell,
writes a cursor-position (`ESC [ row; col H`) only when the cursor is not
already there, then baseline SGR only when the style differs from what is
already active, then the glyph bytes. Contiguous changed cells in a row thus
share a single cursor move and a single SGR. Re-rendering an unchanged frame
emits nothing; changing one cell emits a lone cursor move plus that cell's
bytes.

The buffer is stored row-major (see the `#buf{}` record): each row is a
separate term, so before scanning a row's cells `diff/2` first compares the
two rows with `=:=` and skips the whole row when they are equal. The per-cell
scan floor is therefore paid only on rows that actually changed, not on every
cell of the frame — the common interactive case (a few changed cells on an
otherwise-static screen) touches only its handful of dirty rows, which is
what keeps repaint cheap on large terminals.

## SGR boundary invariant

A diff assumes the terminal is at default SGR when it starts and restores
default SGR before it returns (a trailing `ESC [ 0 m` iff it left a styled
run active). Successive diffs therefore compose without the style of one
frame bleeding into the next. Cursor visibility and the alternate screen are
the backend's responsibility (`m:tuition_term_local`), not
the renderer's.

## Column width

Column advance uses `tuition_width:width/1`, never the
codepoint count: a wide (East-Asian / emoji) glyph occupies two columns. Its
left cell holds the glyph and the cell to its right is a `wide_cont`
placeholder that is never emitted on its own — it is painted by the two-wide
glyph to its left. Overwriting either half of a wide glyph dissolves the
orphaned half back to blank so the grid stays consistent. A wide glyph with
no room for its right half in the final column is dropped, never stored. A
lone zero-width cluster (a stray combining mark or ZWSP) is likewise dropped:
it advances no column on the terminal, so storing it as a cell would leave
the model's cursor a column ahead of the terminal's and desync the run. A
malformed cluster wider than two columns is replaced with a single
replacement character, so the column advance can never trail the emitted
bytes for untrusted text.

## Content safety

A cell never stores a C0/C1 control codepoint (`0x00`–`0x1F`, `0x7F`–`0x9F`):
drawing replaces it with a blank. Rendered content is routinely untrusted — a
process name, a message, a stacktrace from an observed node — so a stray
`ESC` or newline must never reach the terminal as a cursor move or the start
of an escape sequence, which would desync the model or inject arbitrary
terminal control.
""".

-include("tuition_term.hrl").
-include("tuition_layout.hrl").

-export([new/1, size/1, clear/1, cell_at/3, put_cell/4, put_text/4, put_text/5, diff/2]).
-export([cell/1, cell/2, char/1, fg/1, bg/1, bold/1, underline/1]).

-record(buf, {
    w = 0 :: non_neg_integer(),
    h = 0 :: non_neg_integer(),
    %% Row-major and sparse: `rows' maps a row index Y to that row's cells, and
    %% each row maps a column X to a stored cell. An absent Y is a fully blank
    %% row; within a row an absent X is a blank cell, and a wide glyph's right
    %% half is `wide_cont'. Only cells (and rows) that differ from blank are
    %% stored, so a blank cell and an untouched row have a canonical empty
    %% representation. Keeping each row a separate term is what lets {@link
    %% diff/2} skip an unchanged row with a single `=:=' (see the module doc).
    rows = #{} :: #{non_neg_integer() => row()}
}).

-type row() :: #{non_neg_integer() => #cell{} | wide_cont}.
%% One row of the grid: a sparse column-index-to-cell map.

-opaque buffer() :: #buf{}.
%% A style overlay for {@link put_text/5}; omitted keys take the cell defaults
%% (default colours, no bold, no underline).
-type style() :: #{
    fg => default | 0..255 | {rgb, byte(), byte(), byte()},
    bg => default | 0..255 | {rgb, byte(), byte(), byte()},
    bold => boolean(),
    underline => boolean()
}.
%% The active-SGR tuple threaded through emission: {Fg, Bg, Bold, Underline}.
-type sgr() :: {term(), term(), boolean(), boolean()}.

-export_type([buffer/0, style/0]).

%% Unicode replacement character, substituted for a malformed over-wide cluster.
-define(REPLACEMENT, 16#FFFD).

%%% -- construction ----------------------------------------------------

-doc """
A blank buffer covering a terminal size or a `t:tuition_layout:rect/0`.

Every cell starts as the default blank (`m:tuition_term` `#cell{}`:
a space with default colours). A rect's origin is ignored — a buffer always
spans the whole terminal in absolute coordinates; draw into a sub-rect by
passing its absolute origin to `put_text/4`.
""".
-spec new(tuition_term:size() | #rect{}) -> buffer().
new({Cols, Rows}) when is_integer(Cols), is_integer(Rows) ->
    #buf{w = max(0, Cols), h = max(0, Rows)};
new(#rect{w = W, h = H}) ->
    #buf{w = W, h = H}.

-doc """
The buffer's size in cells, as a `t:tuition_term:size/0` pair.
""".
-spec size(buffer()) -> {non_neg_integer(), non_neg_integer()}.
size(#buf{w = W, h = H}) -> {W, H}.

-doc """
A blank buffer of the same size — the starting point for the next frame.
""".
-spec clear(buffer()) -> buffer().
clear(#buf{w = W, h = H}) -> #buf{w = W, h = H}.

-doc """
The effective cell at `{X, Y}`: a `#cell{}` (the blank default when
nothing was drawn there) or the `wide_cont` placeholder standing for the right
half of a two-column glyph. For tests and introspection.
""".
-spec cell_at(buffer(), non_neg_integer(), non_neg_integer()) -> #cell{} | wide_cont.
cell_at(Buf, X, Y) -> get_cell(Buf, X, Y).

%%% -- cells -----------------------------------------------------------

%% The power-user custom-render path ({@link put_cell/4} / {@link cell_at/3}) is
%% the only place a `#cell{}' leaks to consumers — the common {@link put_text/5}
%% path takes a style map instead. These record-free helpers cover that path so a
%% caller never has to reach into the `#cell{}' tuple: build one to place, read
%% the fields of one fetched. The internal `cols' cache (a stored cell's display
%% width) is not exposed — it is filled in on placement and is not a caller
%% concern.

-doc """
Build an unstyled `#cell{}` for `Char` — default colours, no bold, no
underline. See `cell/2` to style it. `Char` is a single codepoint or a
grapheme-cluster codepoint list; it is sanitised (a control codepoint becomes
a blank) only when the cell is placed by `put_cell/4`, not here.
""".
-spec cell(char() | [char()]) -> #cell{}.
cell(Char) -> cell(Char, #{}).

-doc """
Build a `#cell{}` for `Char` with the given `t:style/0` overlay —
the same style map `put_text/5` takes, so a colour/attribute set carries
across both paths. Omitted style keys take the cell defaults.
""".
-spec cell(char() | [char()], style()) -> #cell{}.
cell(Char, Style) -> (style_cell(Style))#cell{char = Char}.

-doc """
The cell's glyph: a single codepoint or a grapheme-cluster codepoint list.
""".
-spec char(#cell{}) -> char() | [char()].
char(#cell{char = Ch}) -> Ch.

-doc """
The cell's foreground colour.
""".
-spec fg(#cell{}) -> default | 0..255 | {rgb, byte(), byte(), byte()}.
fg(#cell{fg = Fg}) -> Fg.

-doc """
The cell's background colour.
""".
-spec bg(#cell{}) -> default | 0..255 | {rgb, byte(), byte(), byte()}.
bg(#cell{bg = Bg}) -> Bg.

-doc """
Whether the cell is bold.
""".
-spec bold(#cell{}) -> boolean().
bold(#cell{bold = Bold}) -> Bold.

-doc """
Whether the cell is underlined.
""".
-spec underline(#cell{}) -> boolean().
underline(#cell{underline = Under}) -> Under.

%%% -- drawing ---------------------------------------------------------

-doc """
Place one `#cell{}` at `{X, Y}`, spanning one or two columns per its
glyph's display width. A two-column glyph also marks `{X + 1, Y}` as
`wide_cont`. Overwriting either half of an existing wide glyph blanks its
orphaned half first, keeping the grid consistent. Out-of-bounds writes are
ignored, a control codepoint is sanitised to a blank, and a wide glyph with no
room for its right half in the final column is dropped rather than stored.
""".
-spec put_cell(buffer(), integer(), integer(), #cell{}) -> buffer().
put_cell(#buf{w = W, h = H} = Buf, X, Y, _Cell) when X < 0; Y < 0; X >= W; Y >= H ->
    Buf;
put_cell(#buf{w = W} = Buf, X, Y, #cell{char = Ch} = Cell0) ->
    %% Sanitise before anything else, so no code path can store a control/
    %% non-printing codepoint that diff/2 would later emit as a cursor move or
    %% escape sequence carried in rendered content (terminal-escape injection).
    Cell = Cell0#cell{char = sanitize_glyph(Ch)},
    put_row(Buf, Y, row_put_cell(get_row(Buf, Y), W, X, Cell)).

-doc """
Draw `Text` from `{X, Y}` with default styling. See `put_text/5`.
""".
-spec put_text(buffer(), integer(), integer(), unicode:chardata()) -> buffer().
put_text(Buf, X, Y, Text) -> put_text(Buf, X, Y, Text, #{}).

-doc """
Draw `Text` left-to-right from `{X, Y}`, advancing the write column by
each grapheme cluster's display width (so a wide glyph consumes two columns).
Text is clipped at the right edge — a run that would overflow, or a wide glyph
with only one column of room, stops the draw — and a row outside the buffer
draws nothing. `Style` overlays colours/attributes onto every cell drawn.
""".
-spec put_text(buffer(), integer(), integer(), unicode:chardata(), style()) -> buffer().
put_text(#buf{h = H} = Buf, _X, Y, _Text, _Style) when Y < 0; Y >= H ->
    Buf;
put_text(#buf{w = W} = Buf, X, Y, Text, Style) ->
    %% The whole run lands on row Y (put_text never wraps), so fetch that row
    %% once, fold the clusters into it, and store it back once — rather than
    %% touching the outer row map per cell.
    Base = style_cell(Style),
    Row0 = get_row(Buf, Y),
    Row1 = draw_clusters(string:next_grapheme(to_bin(Text)), W, X, Row0, Base),
    put_row(Buf, Y, Row1).

%% Fold grapheme clusters into one row, one cell each, stopping at the right
%% edge. `Base' carries the run's style; each cluster fills in its `char'.
-spec draw_clusters(term(), non_neg_integer(), integer(), row(), #cell{}) -> row().
draw_clusters([], _W, _X, Row, _Base) ->
    Row;
draw_clusters({error, _Rest}, _W, _X, Row, _Base) ->
    %% Undecodable tail from string:next_grapheme/1 — stop cleanly.
    Row;
draw_clusters([GC | Rest], W, X, Row, Base) when X < W ->
    %% Sanitise first, then measure the *sanitised* glyph, so the column advance
    %% always matches what is actually stored and later emitted.
    Glyph = sanitize_glyph(GC),
    Next = string:next_grapheme(Rest),
    case cluster_cols(Glyph) of
        0 ->
            %% Zero-width cluster (a stray combining mark or ZWSP with no base):
            %% it advances no column on the terminal, so storing it as a cell
            %% would desync the cursor. Drop it and keep the column.
            draw_clusters(Next, W, X, Row, Base);
        2 when X + 1 >= W ->
            %% A wide glyph will not fit in the final column: stop here.
            Row;
        Cw ->
            Row1 = row_put_cell(Row, W, X, Base#cell{char = Glyph}),
            draw_clusters(Next, W, X + Cw, Row1, Base)
    end;
draw_clusters(_GCs, _W, _X, Row, _Base) ->
    %% Past the right edge.
    Row.

%%% -- diff / emit -----------------------------------------------------

-doc """
ANSI to turn a terminal displaying `Prev` into one displaying `Next`.

Both buffers are assumed to share the same geometry (on resize the caller
starts from a fresh blank buffer). The result is `iodata()` ready for
`tuition_term:write/2`: empty when the frames are identical,
otherwise the minimal cursor moves, SGR changes and glyph bytes for the
changed cells, ending at default SGR.
""".
-spec diff(buffer(), buffer()) -> iodata().
diff(Prev, #buf{w = W, h = H} = Next) ->
    {Style, Rev} = diff_rows(0, H, W, Prev, Next, none, default_sgr(), []),
    %% Restore the default-SGR boundary invariant if a styled run was left active.
    Rev1 =
        case Style =:= default_sgr() of
            true -> Rev;
            false -> [<<"\e[0m">> | Rev]
        end,
    lists:reverse(Rev1).

%% Walk rows top to bottom. Two equal rows (the common case for a static region)
%% settle with one `=:=' and contribute nothing; only a row whose cells actually
%% differ is scanned column by column. `Cursor' and the active SGR thread across
%% rows unchanged, so a run's cursor move and SGR are emitted exactly as the flat
%% grid walk would have emitted them.
-spec diff_rows(
    non_neg_integer(),
    non_neg_integer(),
    non_neg_integer(),
    buffer(),
    buffer(),
    none | {integer(), integer()},
    sgr(),
    [iodata()]
) ->
    {sgr(), [iodata()]}.
diff_rows(Y, H, _W, _Prev, _Next, _Cursor, Style, Acc) when Y >= H ->
    {Style, Acc};
diff_rows(Y, H, W, Prev, Next, Cursor, Style, Acc) ->
    PrevRow = get_row(Prev, Y),
    NextRow = get_row(Next, Y),
    case NextRow =:= PrevRow of
        true ->
            diff_rows(Y + 1, H, W, Prev, Next, Cursor, Style, Acc);
        false ->
            {Cursor1, Style1, Acc1} = diff_cols(0, W, Y, PrevRow, NextRow, Cursor, Style, Acc),
            diff_rows(Y + 1, H, W, Prev, Next, Cursor1, Style1, Acc1)
    end.

%% Emit (or not) for each column of one changed row, threading
%% {Cursor, ActiveSgr, RevAcc}. The two row maps are already in hand from
%% diff_rows, so each cell is a direct row lookup — no outer-map indirection.
-spec diff_cols(
    non_neg_integer(),
    non_neg_integer(),
    non_neg_integer(),
    row(),
    row(),
    none | {integer(), integer()},
    sgr(),
    [iodata()]
) ->
    {none | {integer(), integer()}, sgr(), [iodata()]}.
diff_cols(X, W, _Y, _PrevRow, _NextRow, Cursor, Style, Acc) when X >= W ->
    {Cursor, Style, Acc};
diff_cols(X, W, Y, PrevRow, NextRow, Cursor, Style, Acc) ->
    NextVal = row_get(NextRow, X),
    case NextVal =:= row_get(PrevRow, X) of
        true ->
            diff_cols(X + 1, W, Y, PrevRow, NextRow, Cursor, Style, Acc);
        false ->
            case NextVal of
                wide_cont ->
                    %% The right half of a wide glyph is painted by the glyph to
                    %% its left (always itself a change), never on its own.
                    diff_cols(X + 1, W, Y, PrevRow, NextRow, Cursor, Style, Acc);
                #cell{cols = Cols} = Cell ->
                    %% maybe_cursor leaves the cursor at {X, Y}; emitting the
                    %% glyph below advances it by the glyph's width — read from the
                    %% cell's cached `cols' (set when it was drawn), never
                    %% re-measured here — so the intermediate position is not kept.
                    {_AtCell, Acc1} = maybe_cursor(Cursor, X, Y, Acc),
                    {Style1, Acc2} = maybe_sgr(Style, sgr_of(Cell), Acc1),
                    Acc3 = [glyph_bytes(Cell) | Acc2],
                    Cursor1 = {X + Cols, Y},
                    diff_cols(X + 1, W, Y, PrevRow, NextRow, Cursor1, Style1, Acc3)
            end
    end.

%% Emit a cursor-position sequence only when the cursor is not already at {X, Y}.
-spec maybe_cursor(
    none | {integer(), integer()},
    non_neg_integer(),
    non_neg_integer(),
    [iodata()]
) ->
    {{non_neg_integer(), non_neg_integer()}, [iodata()]}.
maybe_cursor({X, Y}, X, Y, Acc) -> {{X, Y}, Acc};
maybe_cursor(_Cursor, X, Y, Acc) -> {{X, Y}, [cursor_to(X, Y) | Acc]}.

%% Emit baseline SGR only when the required style differs from what is active.
-spec maybe_sgr(sgr(), sgr(), [iodata()]) -> {sgr(), [iodata()]}.
maybe_sgr(Style, Style, Acc) -> {Style, Acc};
maybe_sgr(_Old, New, Acc) -> {New, [sgr(New) | Acc]}.

%%% -- ANSI encoding ---------------------------------------------------

%% CUP: ESC [ row ; col H, with the 1-based coordinates ECMA-48 uses.
-spec cursor_to(non_neg_integer(), non_neg_integer()) -> binary().
cursor_to(X, Y) ->
    <<"\e[", (int(Y + 1))/binary, ";", (int(X + 1))/binary, "H">>.

%% Baseline SGR for a style: a reset (`0') followed by the set attributes, so the
%% sequence is self-contained regardless of the previously active style. A change
%% back to the default style is just the reset.
-spec sgr(sgr()) -> binary().
sgr(Sgr) ->
    <<"\e[", (join_semis([<<"0">> | attr_codes(Sgr)]))/binary, "m">>.

-spec attr_codes(sgr()) -> [binary()].
attr_codes({Fg, Bg, Bold, Under}) ->
    bool_code(Bold, <<"1">>) ++
        bool_code(Under, <<"4">>) ++
        color_code(38, 39, Fg) ++
        color_code(48, 49, Bg).

-spec bool_code(boolean(), binary()) -> [binary()].
bool_code(true, Code) -> [Code];
bool_code(false, _Code) -> [].

%% A colour code for the given SGR selector base (38/48 = fg/bg). `default' needs
%% no code (the leading reset already restored it); 256-colour and truecolor use
%% the standard `Base ; 5 ; N' and `Base ; 2 ; R ; G ; B' forms.
-spec color_code(38 | 48, 39 | 49, term()) -> [binary()].
color_code(_Base, _Default, default) ->
    [];
color_code(Base, _Default, N) when is_integer(N) ->
    [<<(int(Base))/binary, ";5;", (int(N))/binary>>];
color_code(Base, _Default, {rgb, R, G, B}) ->
    [<<(int(Base))/binary, ";2;", (int(R))/binary, ";", (int(G))/binary, ";", (int(B))/binary>>].

-spec glyph_bytes(#cell{}) -> binary().
glyph_bytes(#cell{char = Ch}) ->
    case unicode:characters_to_binary(chars(Ch)) of
        Bin when is_binary(Bin) -> Bin;
        _ -> <<" ">>
    end.

%%% -- cell / buffer helpers -------------------------------------------

%% Effective value at a position: the stored cell / `wide_cont', or the blank
%% default when nothing is stored there (including out-of-range lookups).
-spec get_cell(buffer(), integer(), integer()) -> #cell{} | wide_cont.
get_cell(Buf, X, Y) ->
    row_get(get_row(Buf, Y), X).

%% Row Y's cell map, or an empty map for an untouched (fully blank) row —
%% including out-of-range rows.
-spec get_row(buffer(), integer()) -> row().
get_row(#buf{rows = Rows}, Y) ->
    maps:get(Y, Rows, #{}).

%% Store row Y, keeping the outer map sparse: an emptied row drops its key so a
%% drawn-then-cleared row is `=:=' to one never touched (canonical blank row).
-spec put_row(buffer(), integer(), row()) -> buffer().
put_row(#buf{rows = Rows} = Buf, Y, Row) ->
    Rows1 =
        case map_size(Row) =:= 0 of
            true -> maps:remove(Y, Rows);
            false -> maps:put(Y, Row, Rows)
        end,
    Buf#buf{rows = Rows1}.

%%% -- row-local cell helpers ------------------------------------------
%%% Operate on a single row's cell map. put_cell/4 and draw_clusters both fold a
%%% run into one row before storing it back, so every write on the hot draw path
%%% stays within these map operations — no outer-map churn per cell.

%% Effective value at column X of a row: the stored cell / `wide_cont', or the
%% blank default when the column is untouched.
-spec row_get(row(), integer()) -> #cell{} | wide_cont.
row_get(Row, X) ->
    maps:get(X, Row, #cell{}).

%% Store a value at column X, keeping the row sparse: writing the blank default
%% removes the key so equality against an untouched cell (and row) holds.
-spec row_set(row(), integer(), #cell{} | wide_cont) -> row().
row_set(Row, X, Val) ->
    case Val =:= #cell{} of
        true -> maps:remove(X, Row);
        false -> maps:put(X, Val, Row)
    end.

%% Place one sanitised `#cell{}' at column X of a row, spanning one or two
%% columns per its glyph's width — the row-local core shared by put_cell/4 and
%% the drawing loop. A cell left of column 0 (a run drawn from a negative X), a
%% zero-width glyph, or a wide glyph with no room for its right half in the final
%% column, is dropped (the row is returned unchanged); otherwise any orphaned
%% half at the target columns is dissolved first.
-spec row_put_cell(row(), non_neg_integer(), integer(), #cell{}) -> row().
row_put_cell(Row, _W, X, _Cell) when X < 0 ->
    %% Off the left edge: put_text may start at a negative X and walk rightwards
    %% into view. Drop the off-screen cell whole — mirroring put_cell/4's bounds
    %% guard — so a wide glyph straddling column 0 never strands a `wide_cont' at
    %% column 0 with its left half off-screen. diff/2 never emits a `wide_cont'
    %% on its own, so such a strand would leave that column stale over a
    %% non-blank prior frame.
    Row;
row_put_cell(Row, W, X, Cell) ->
    %% Measure the glyph once here, at store time, and cache it in the cell's
    %% `cols' field so diff/2 never re-measures it on the repaint hot path.
    case char_cols(Cell) of
        0 ->
            %% Zero-width glyph: it claims no column, and storing it would leave
            %% the cursor a column ahead of the terminal on emit — drop it.
            Row;
        2 when X + 1 >= W ->
            %% A wide glyph cannot render wholly in the final column — it would
            %% wrap onto the next row and desync the model — so drop it.
            Row;
        2 ->
            R1 = row_dissolve(Row, X),
            R2 = row_dissolve(R1, X + 1),
            R3 = row_set(R2, X, Cell#cell{cols = 2}),
            row_set(R3, X + 1, wide_cont);
        1 ->
            row_set(row_dissolve(Row, X), X, Cell#cell{cols = 1})
    end.

%% Blank column X and, if it is one half of a wide glyph, its partner half too,
%% so a subsequent write never strands an orphaned half on the row.
-spec row_dissolve(row(), integer()) -> row().
row_dissolve(Row, X) ->
    case row_get(Row, X) of
        wide_cont ->
            row_set(row_set(Row, X - 1, #cell{}), X, #cell{});
        #cell{cols = 2} ->
            %% A stored wide glyph's left half: blank its `wide_cont' partner too.
            %% Its width is read from the cached `cols', not re-measured.
            row_set(row_set(Row, X + 1, #cell{}), X, #cell{});
        _NarrowOrBlank ->
            Row
    end.

%% Column span of a cell's glyph, measured from its `char' (a `wide_cont' never
%% reaches here). A stored cell is always 1 or 2 columns — zero-width clusters
%% are dropped before storage — but the 0 case is typed for the drawing-side
%% callers that decide on it. This is the store-time measurement whose result is
%% cached in `#cell.cols'; readers of a stored cell use that field instead.
-spec char_cols(#cell{}) -> 0 | 1 | 2.
char_cols(#cell{char = Ch}) -> cluster_cols(Ch).

%% Column span of a grapheme cluster on a terminal: 2 for wide (East-Asian /
%% emoji), 0 for a zero-width cluster (a combining mark or ZWSP), 1 otherwise.
-spec cluster_cols(char() | [char()]) -> 0 | 1 | 2.
cluster_cols(GC) ->
    case tuition_width:width(GC) of
        2 -> 2;
        0 -> 0;
        _ -> 1
    end.

-spec style_cell(style()) -> #cell{}.
style_cell(Style) ->
    #cell{
        fg = maps:get(fg, Style, default),
        bg = maps:get(bg, Style, default),
        bold = maps:get(bold, Style, false),
        underline = maps:get(underline, Style, false)
    }.

-spec sgr_of(#cell{}) -> sgr().
sgr_of(#cell{fg = Fg, bg = Bg, bold = Bold, underline = Under}) -> {Fg, Bg, Bold, Under}.

-spec default_sgr() -> sgr().
default_sgr() -> {default, default, false, false}.

%%% -- small utilities -------------------------------------------------

-spec chars(char() | [char()]) -> [char()].
chars(C) when is_integer(C) -> [C];
chars(L) when is_list(L) -> L.

%% Make a grapheme cluster safe to store and emit, and guaranteed to span 0, 1 or
%% 2 columns:
%%   * a cluster whose base is a C0/C1 control (or DEL) becomes a blank space, and
%%     any stray control codepoint trailing the base is dropped — so no glyph ever
%%     carries a cursor move or the start of an escape sequence;
%%   * a malformed cluster wider than two columns (tuition_width deliberately sums
%%     these — e.g. a base plus a spurious wide modifier — rather than under-count)
%%     collapses to a single replacement character, so the model's column advance
%%     can never trail the bytes actually emitted.
%% Well-formed content — legitimate zero-width combining marks, two-column
%% emoji/CJK — is returned unchanged.
-spec sanitize_glyph(char() | [char()]) -> char() | [char()].
sanitize_glyph(GC) ->
    Safe = strip_controls(GC),
    case tuition_width:width(Safe) > 2 of
        true -> ?REPLACEMENT;
        false -> Safe
    end.

%% Replace a control base with a blank and drop any control codepoint trailing the
%% base, leaving the printable remainder of the cluster.
-spec strip_controls(char() | [char()]) -> char() | [char()].
strip_controls(C) when is_integer(C) ->
    case is_control(C) of
        true -> $\s;
        false -> C
    end;
strip_controls([Base | Rest]) ->
    case is_control(Base) of
        true -> $\s;
        false -> [Base | [C || C <- Rest, not is_control(C)]]
    end;
strip_controls([]) ->
    $\s.

%% C0 controls and DEL/C1 controls — codepoints that, emitted raw, move the
%% cursor or begin an escape sequence rather than painting a cell.
-spec is_control(char()) -> boolean().
is_control(C) -> C < 16#20 orelse (C >= 16#7F andalso C =< 16#9F).

-spec int(integer()) -> binary().
int(N) -> integer_to_binary(N).

-spec join_semis([binary()]) -> binary().
join_semis([H | T]) ->
    lists:foldl(fun(Part, Acc) -> <<Acc/binary, ";", Part/binary>> end, H, T).

%% Best-effort chardata -> UTF-8 binary; a malformed tail contributes whatever
%% prefix decoded, so drawing never crashes on bad encodings.
-spec to_bin(unicode:chardata()) -> binary().
to_bin(Text) ->
    case unicode:characters_to_binary(Text) of
        Bin when is_binary(Bin) -> Bin;
        {error, Good, _Rest} -> Good;
        {incomplete, Good, _Rest} -> Good
    end.
