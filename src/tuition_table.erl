%%%-------------------------------------------------------------------
%%% @doc Table widget — columns, a header row, and stateful row selection.
%%%
%%% A table lays a fixed set of columns across its area, draws a header row at
%%% the top, and shows a scrollable, selectable column of data rows underneath —
%%% ratatui's `Table' + `TableState'. It is the widget the etop/observer-parity
%%% process view (PRD §9.1) is built from: many rows, a handful of columns, one
%%% highlighted selection, sortable by a column.
%%%
%%% == Layout ==
%%% Column widths are solved by the same {@link tuition_layout} constraint engine
%%% the panes are tiled with — each column carries a {@type
%%% tuition_layout:constraint()} (`{fixed, N}' / `{percent, P}' / `fill'), and the
%%% columns are apportioned across the area with a `column_spacing'-wide gap
%%% between them. A left gutter as wide as the `highlight_symbol' is reserved so
%%% the header and every row line up whether or not a row is selected. Every cell
%%% is clipped to its own column, so text can never spill into the next column
%%% (or past the table onto a neighbouring pane).
%%%
%%% == Stateful, like the list ==
%%% Row selection and the scroll offset live in a `#list_state{}' (see
%%% `include/tuition_widget.hrl') held by the *caller* — the renderer is
%%% immediate-mode and discards every frame, so state kept in the widget would
%%% not survive (see {@link tuition_widget}). The rows are exactly a {@link
%%% tuition_list} scrolled under the header, so {@link render/4} reuses {@link
%%% tuition_list:reconcile/3} to clamp the selection and slide the offset, and the
%%% navigation API ({@link next/2}, {@link prev/2}, {@link select/2}, {@link
%%% selected/1}) delegates to {@link tuition_list} — one source of truth for the
%%% `ListState' logic. Header rows are not part of the scroll: the offset and
%%% selection index count data rows only.
%%%
%%% == Sortable columns ==
%%% Sorting is the caller's — the caller holds the typed model and orders it, and
%%% the table only *reflects* the current sort. Pass `sort => {Col, asc | desc}'
%%% and the sorted column's header gains a ▲/▼ indicator. {@link toggle_sort/2}
%%% is the pure key-handler that cycles a column's direction (and switches
%%% columns), and {@link apply_sort/2} is a convenience that orders rows
%%% lexicographically by a column's text — enough for text columns; a caller with
%%% numeric/typed data sorts its own model and passes the ordered rows in.
%%%
%%% == Config ==
%%% A `#{}' map, every key optional:
%%% <ul>
%%%   <li>`columns' — the column specs (default `[]'; an empty table draws
%%%       nothing). Each is a `#{}' with optional `header' (a {@type
%%%       tuition_text:line_input()} label — plain chardata or a styled line —
%%%       default `<<>>'), `constraint' (a {@type tuition_layout:constraint()},
%%%       default `fill') and `align' (`left' (default) | `center' | `right',
%%%       applied to the header and every cell in the column).</li>
%%%   <li>`rows' — the data rows, each a list of cells, one per column; each cell a
%%%       {@type tuition_text:line_input()} (plain chardata as before, or a {@link
%%%       tuition_text} styled line carrying mixed per-span styles over the row's
%%%       base). A row with fewer cells than columns leaves the trailing columns
%%%       blank, extra cells are ignored (default `[]'). May instead be a <b>lazy</b>
%%%       `{Items, RowFun}' pair — an item list and a `fun((Item) -> row())' — in
%%%       which case `RowFun' is applied only to the items in the visible slice,
%%%       so a large table never pays to build the rows scrolled off screen. The
%%%       item count still fixes the scroll extent; only the row rendering is
%%%       deferred.</li>
%%%   <li>`header_style' — style for the header row, filled full width (default:
%%%       unstyled).</li>
%%%   <li>`row_style' — base style for every data row, filled full width (default:
%%%       unstyled — so an unstyled table shows whatever it is drawn over between
%%%       and beside its cells).</li>
%%%   <li>`highlight_style' — style overlaid on the selected row across its full
%%%       width (default: unstyled — set at least a colour to make the selection
%%%       visible).</li>
%%%   <li>`highlight_symbol' — a prefix drawn in the left gutter of the selected
%%%       row (e.g. `"> "'); its width is reserved on every row so the columns
%%%       stay aligned (default `<<>>' — no gutter).</li>
%%%   <li>`column_spacing' — blank columns between adjacent columns (default
%%%       `1').</li>
%%%   <li>`sort' — `none' (default) or `{Col, asc | desc}', which draws the
%%%       indicator on column `Col's header. It does not reorder `rows' — pass
%%%       them already ordered.</li>
%%% </ul>
%%%
%%% HARD CONSTRAINT (PRD §12): depends only on `kernel'/`stdlib'/`erts' plus the
%%% sibling render/layout/width/widget modules. No third-party code.
%%% @end
%%%-------------------------------------------------------------------
-module(tuition_table).

-include("tuition_layout.hrl").
-include("tuition_widget.hrl").

-export([new/0, render/4, next/2, prev/2, select/2, selected/1]).
-export([toggle_sort/2, apply_sort/2]).

-type column() :: #{
    header => tuition_text:line_input(),
    constraint => tuition_layout:constraint(),
    align => left | center | right
}.
-type row() :: [tuition_text:line_input()].
%% The row data: either the rows themselves, or a lazy `{Items, RowFun}' pair
%% whose `RowFun' is applied only to the items in the visible slice (see the
%% module doc). The lazy form is how a large table skips building off-screen rows.
-type rows() :: [row()] | {[term()], fun((term()) -> row())}.
-type sort() :: none | {non_neg_integer(), asc | desc}.
-type table_cfg() :: #{
    columns => [column()],
    rows => rows(),
    header_style => tuition_render:style(),
    row_style => tuition_render:style(),
    highlight_style => tuition_render:style(),
    highlight_symbol => unicode:chardata(),
    column_spacing => non_neg_integer(),
    sort => sort()
}.
-type state() :: #list_state{}.

-export_type([column/0, row/0, rows/0, sort/0, table_cfg/0, state/0]).

%% Sort-indicator glyphs, drawn on the sorted column's header. Both are one
%% column wide in {@link tuition_width}, so {@link tuition_widget:display_width/1} and
%% the renderer agree on the header's width.
-define(ASC, 16#25B2).
-define(DESC, 16#25BC).

%%% -- state (delegated to the list) -----------------------------------

%% @doc A fresh table state: no row selected, unscrolled. Row selection is a
%% `#list_state{}', so the navigation below is {@link tuition_list}'s.
-spec new() -> state().
new() -> tuition_list:new().

%% @doc Move the row selection to the next row, clamped to the last. `Len' is the
%% row count. Delegates to {@link tuition_list:next/2}.
-spec next(state(), non_neg_integer()) -> state().
next(State, Len) -> tuition_list:next(State, Len).

%% @doc Move the row selection to the previous row, clamped to the first.
%% Delegates to {@link tuition_list:prev/2}.
-spec prev(state(), non_neg_integer()) -> state().
prev(State, Len) -> tuition_list:prev(State, Len).

%% @doc Set the row selection to a specific index (or `none'); clamped to the row
%% count at the next {@link render/4}. Delegates to {@link tuition_list:select/2}.
-spec select(state(), none | non_neg_integer()) -> state().
select(State, Selected) -> tuition_list:select(State, Selected).

%% @doc The selected row index, or `none'. Delegates to {@link
%% tuition_list:selected/1}.
-spec selected(state()) -> none | non_neg_integer().
selected(State) -> tuition_list:selected(State).

%%% -- sorting (pure helpers) ------------------------------------------

%% @doc Cycle the sort for a column, the pure transition a "sort by this column"
%% key applies: selecting a new column sorts it ascending; selecting the column
%% already sorted flips its direction. Never clears — a caller wanting an
%% unsorted state manages that itself. Feed the result back as the `sort' config
%% (and reorder the rows with {@link apply_sort/2} or your own model).
-spec toggle_sort(sort(), non_neg_integer()) -> {non_neg_integer(), asc | desc}.
toggle_sort({Col, asc}, Col) -> {Col, desc};
toggle_sort({Col, desc}, Col) -> {Col, asc};
toggle_sort(_Sort, Col) -> {Col, asc}.

%% @doc Order `Rows' by the text of column `Col', a convenience for text columns.
%% The key is the column's cell as a UTF-8 binary (a missing cell sorts as empty),
%% compared in Erlang term order — lexicographic by byte, i.e. codepoint order for
%% well-formed UTF-8. `lists:sort/2' is stable, so rows equal on the key keep their
%% prior order. A caller with numeric or otherwise typed columns should sort its
%% own model instead and pass the ordered rows in. `none' returns `Rows'
%% unchanged.
%%
%% The key is extracted once per row (decorate–sort–undecorate) rather than in the
%% comparator: the process view (PRD §9.1) sorts many rows, so pulling the O(N)
%% cell extraction + UTF-8 conversion out of `lists:sort/2's O(N log N) comparisons
%% keeps a large table's re-sort cheap. Sorting the `{Key, Row}' pairs keeps the
%% sort stable on the key alone (the row is never compared).
-spec apply_sort([row()], sort()) -> [row()].
apply_sort(Rows, none) ->
    Rows;
apply_sort(Rows, {Col, Dir}) ->
    Keyed = [{cell_bin(Row, Col), Row} || Row <- Rows],
    Sorted = lists:sort(fun({Ka, _}, {Kb, _}) -> ordered(Ka, Kb, Dir) end, Keyed),
    [Row || {_Key, Row} <- Sorted].

-spec ordered(binary(), binary(), asc | desc) -> boolean().
ordered(Ka, Kb, asc) -> Ka =< Kb;
ordered(Ka, Kb, desc) -> Ka >= Kb.

%%% -- render ----------------------------------------------------------

%% @doc Draw the header and the visible slice of rows into `Area', highlighting
%% the selected row, and return the buffer together with the reconciled state
%% (selection clamped to the row count, offset slid to keep the selection within
%% the rows viewport — the area height less the header row). A degenerate area, or
%% a table with no columns, draws nothing but still reconciles the state, so a
%% resize down to nothing and back leaves a valid selection/offset behind.
-spec render(table_cfg(), #rect{}, tuition_render:buffer(), state()) ->
    {tuition_render:buffer(), state()}.
render(Cfg, #rect{w = W, h = H} = Area, Buf, State0) ->
    Columns = maps:get(columns, Cfg, []),
    Rows = maps:get(rows, Cfg, []),
    Len = rows_len(Rows),
    HeaderRows = header_rows(Columns, H),
    Visible = max(0, H - HeaderRows),
    State1 = tuition_list:reconcile(State0, Len, Visible),
    Buf1 =
        case W =:= 0 orelse H =:= 0 orelse Columns =:= [] of
            true -> Buf;
            false -> draw(Cfg, Columns, Rows, Area, HeaderRows, Visible, State1, Buf)
        end,
    {Buf1, State1}.

%% A header row is drawn whenever the table has columns and at least one row of
%% height to put it on; it is not part of the scrollable rows.
-spec header_rows([column()], non_neg_integer()) -> 0 | 1.
header_rows([], _H) -> 0;
header_rows(_Columns, H) when H >= 1 -> 1;
header_rows(_Columns, _H) -> 0.

%% Solve the column geometry once, then draw the header and the row slice over it.
-spec draw(
    table_cfg(),
    [column()],
    rows(),
    #rect{},
    0 | 1,
    non_neg_integer(),
    state(),
    tuition_render:buffer()
) -> tuition_render:buffer().
draw(Cfg, Columns, Rows, #rect{x = X, y = Y, w = W} = Area, HeaderRows, Visible, State, Buf) ->
    Spacing = maps:get(column_spacing, Cfg, 1),
    Symbol = maps:get(highlight_symbol, Cfg, <<>>),
    Gutter = tuition_widget:display_width(Symbol),
    %% Columns start after the selection gutter; the gutter itself is filled by
    %% the row/header background and carries the highlight symbol on the selected
    %% row, so header and rows stay column-aligned regardless of selection.
    ColsArea = #rect{x = X + Gutter, y = Y, w = max(0, W - Gutter), h = 1},
    Geom = column_geometry(Columns, Spacing, ColsArea),
    Buf1 = draw_header(Buf, Geom, Area, HeaderRows, Cfg),
    RowsArea = #rect{x = X, y = Y + HeaderRows, w = W, h = Visible},
    draw_rows(Buf1, Geom, Rows, RowsArea, State, Symbol, Cfg).

%%% -- column geometry -------------------------------------------------

%% The `{Cx, Cw, Column}' geometry of each column: the column constraints solved
%% across the columns area by the layout engine, with a fixed spacer between
%% adjacent columns. Interleaving spacers into the constraint list lets the same
%% largest-remainder solver apportion the gaps, so the columns and spacing sum to
%% the area exactly (no drift) and `fill' columns share only the width the fixed
%% columns and gaps leave.
-spec column_geometry([column()], non_neg_integer(), #rect{}) ->
    [{non_neg_integer(), non_neg_integer(), column()}].
column_geometry(Columns, Spacing, ColsArea) ->
    Constraints = interleave([maps:get(constraint, C, fill) || C <- Columns], Spacing),
    Rects = tuition_layout:split(horizontal, Constraints, ColsArea),
    ColRects = drop_spacers(Rects),
    lists:zipwith(
        fun(#rect{x = Cx, w = Cw}, Col) -> {Cx, Cw, Col} end, ColRects, Columns
    ).

%% Put a fixed `Spacing'-wide spacer between every pair of adjacent columns.
-spec interleave([tuition_layout:constraint()], non_neg_integer()) ->
    [tuition_layout:constraint()].
interleave([], _Spacing) -> [];
interleave([C], _Spacing) -> [C];
interleave([C | Rest], Spacing) -> [C, {fixed, Spacing} | interleave(Rest, Spacing)].

%% Keep the column rects, dropping the interleaved spacer rects (every second
%% element after the first).
-spec drop_spacers([#rect{}]) -> [#rect{}].
drop_spacers([]) -> [];
drop_spacers([Col]) -> [Col];
drop_spacers([Col, _Spacer | Rest]) -> [Col | drop_spacers(Rest)].

%%% -- header ----------------------------------------------------------

%% Draw the header row: a full-width bar in the header style, then each column's
%% label (with a sort indicator appended on the sorted column) aligned and clipped
%% within its column. Nothing to draw if the area has no room for a header.
-spec draw_header(
    tuition_render:buffer(),
    [{non_neg_integer(), non_neg_integer(), column()}],
    #rect{},
    0 | 1,
    table_cfg()
) -> tuition_render:buffer().
draw_header(Buf, _Geom, _Area, 0, _Cfg) ->
    Buf;
draw_header(Buf, Geom, #rect{x = X, y = Y, w = W}, 1, Cfg) ->
    Style = maps:get(header_style, Cfg, #{}),
    Sort = maps:get(sort, Cfg, none),
    Buf1 = tuition_widget:fill(Buf, #rect{x = X, y = Y, w = W, h = 1}, Style),
    {BufN, _Idx} = lists:foldl(
        fun({Cx, Cw, Col}, {B, Idx}) ->
            Text = header_text(Col, Idx, Sort),
            {draw_cell(B, Cx, Cw, Y, Text, align(Col), Style), Idx + 1}
        end,
        {Buf1, 0},
        Geom
    ),
    BufN.

%% The header text for a column: its label, with a space and a ▲/▼ indicator
%% appended when this is the sorted column. The indicator is subject to the same
%% per-column truncation as any header, so a column too narrow for both simply
%% loses the tail.
-spec header_text(column(), non_neg_integer(), sort()) -> tuition_text:line().
header_text(Col, Idx, {Idx, Dir}) ->
    tuition_text:line(maps:get(header, Col, <<>>)) ++
        [{<<" ">>, #{}}, {<<(arrow(Dir))/utf8>>, #{}}];
header_text(Col, _Idx, _Sort) ->
    tuition_text:line(maps:get(header, Col, <<>>)).

-spec arrow(asc | desc) -> char().
arrow(asc) -> ?ASC;
arrow(desc) -> ?DESC.

%%% -- rows ------------------------------------------------------------

%% Draw the visible slice of data rows, top to bottom, one per row of `RowsArea'.
%% The offset has been clamped into `[0, rows_len(Rows)]' by reconcile, so
%% {@link rows_window/3} is safe; materializing only the visible slice keeps a
%% deep-scrolled table as cheap to draw as the rows on screen — and, for the lazy
%% row form, as cheap to *build* (see {@link tuition_list}).
-spec draw_rows(
    tuition_render:buffer(),
    [{non_neg_integer(), non_neg_integer(), column()}],
    rows(),
    #rect{},
    state(),
    unicode:chardata(),
    table_cfg()
) -> tuition_render:buffer().
draw_rows(Buf, Geom, Rows, #rect{y = Y, h = H} = RowsArea, State, Symbol, Cfg) ->
    #list_state{selected = Selected, offset = Offset} = State,
    Base = maps:get(row_style, Cfg, #{}),
    Highlight = maps:get(highlight_style, Cfg, #{}),
    Slice = rows_window(Rows, Offset, H),
    {BufN, _Row} = lists:foldl(
        fun(Row, {B, VRow}) ->
            Index = Offset + VRow,
            RowY = Y + VRow,
            B1 = draw_row(
                B, Geom, Row, RowsArea, RowY, Index =:= Selected, Base, Highlight, Symbol
            ),
            {B1, VRow + 1}
        end,
        {Buf, 0},
        Slice
    ),
    BufN.

%% Draw one data row: fill it full width with its style (the highlight overlaid on
%% the base for the selected row, the base alone otherwise), draw the highlight
%% symbol in the gutter of the selected row only — an unselected row leaves the
%% gutter to the fill, so an unstyled row never overwrites a parent background
%% there — then draw each cell clipped to its column.
-spec draw_row(
    tuition_render:buffer(),
    [{non_neg_integer(), non_neg_integer(), column()}],
    row(),
    #rect{},
    non_neg_integer(),
    boolean(),
    tuition_render:style(),
    tuition_render:style(),
    unicode:chardata()
) -> tuition_render:buffer().
draw_row(Buf, Geom, Row, #rect{x = X, w = W}, RowY, Selected, Base, Highlight, Symbol) ->
    Style =
        case Selected of
            true -> maps:merge(Base, Highlight);
            false -> Base
        end,
    RowRect = #rect{x = X, y = RowY, w = W, h = 1},
    Buf1 = tuition_widget:fill(Buf, RowRect, Style),
    Buf2 =
        case Selected of
            true -> tuition_widget:put_line(Buf1, RowRect, 0, 0, Symbol, Style);
            false -> Buf1
        end,
    {BufN, _Idx} = lists:foldl(
        fun({Cx, Cw, Col}, {B, Idx}) ->
            {draw_cell(B, Cx, Cw, RowY, cell(Row, Idx), align(Col), Style), Idx + 1}
        end,
        {Buf2, 0},
        Geom
    ),
    BufN.

%%% -- cells -----------------------------------------------------------

%% Draw one cell's text within its column at screen row `Y', aligned in the
%% column and clipped to it (via {@link tuition_widget:put_line/6}, so it can never
%% spill into the next column). A zero-width column draws nothing.
-spec draw_cell(
    tuition_render:buffer(),
    non_neg_integer(),
    non_neg_integer(),
    non_neg_integer(),
    tuition_text:line_input(),
    left | center | right,
    tuition_render:style()
) -> tuition_render:buffer().
draw_cell(Buf, _Cx, Cw, _Y, _Cell, _Align, _Style) when Cw =< 0 ->
    Buf;
draw_cell(Buf, Cx, Cw, Y, Cell, Align, Style) ->
    CellRect = #rect{x = Cx, y = Y, w = Cw, h = 1},
    Line = tuition_text:line(Cell),
    Width = min(tuition_text:line_width(Line), Cw),
    DCol = tuition_widget:align_offset(Align, Cw, Width),
    tuition_text:put_line(Buf, CellRect, DCol, 0, Line, Style).

%%% -- rows: eager list or lazy {Items, RowFun} -----------------------

%% The row count, which fixes the scroll extent regardless of how the rows are
%% rendered. Cheap for both forms — a list length, or the item-list length.
-spec rows_len(rows()) -> non_neg_integer().
rows_len(Rows) when is_list(Rows) -> length(Rows);
rows_len({Items, _RowFun}) -> length(Items).

%% The `Count' rows starting at `Offset', materialized as `[row()]'. For an eager
%% list this is a plain slice; for the lazy form only the items in the window are
%% passed through `RowFun', so the rows scrolled off screen are never built.
%% `Offset' has been clamped to `[0, rows_len(Rows)]' by reconcile, so the
%% `nthtail/2' is safe.
-spec rows_window(rows(), non_neg_integer(), non_neg_integer()) -> [row()].
rows_window(Rows, Offset, Count) when is_list(Rows) ->
    lists:sublist(lists:nthtail(Offset, Rows), Count);
rows_window({Items, RowFun}, Offset, Count) ->
    [RowFun(Item) || Item <- lists:sublist(lists:nthtail(Offset, Items), Count)].

%%% -- helpers ---------------------------------------------------------

-spec align(column()) -> left | center | right.
align(Col) -> maps:get(align, Col, left).

%% The `Idx'-th cell (0-based) of a row, or `<<>>' when the row is shorter than
%% the column count.
-spec cell(row(), non_neg_integer()) -> tuition_text:line_input().
cell(Row, Idx) ->
    case Idx < length(Row) of
        true -> lists:nth(Idx + 1, Row);
        false -> <<>>
    end.

%% A cell's plain text as a UTF-8 binary sort key: the concatenation of its span
%% texts, so a styled cell sorts by the text it shows; a missing cell sorts as the
%% empty string. Normalising through {@link tuition_text:line/1} tolerates a bad
%% encoding the same way a draw does, so a malformed cell never crashes a sort.
-spec cell_bin(row(), non_neg_integer()) -> binary().
cell_bin(Row, Col) -> line_text(tuition_text:line(cell(Row, Col))).

%% The plain text of a normalised line: its span texts joined. Span texts are
%% already UTF-8 binaries (normalised by {@link tuition_text:line/1}), so this
%% never re-decodes.
-spec line_text(tuition_text:line()) -> binary().
line_text(Line) -> iolist_to_binary([Text || {Text, _Style} <- Line]).
