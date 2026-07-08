%%%-------------------------------------------------------------------
%%% @doc The widget seam — ratatui's third layer, above render and layout.
%%%
%%% Sonde already has ratatui's first two layers: the cell {@type
%%% sonde_render:buffer()} with diff-based repaint ({@link sonde_render}) and the
%%% constraint/split {@type sonde_layout:rect()} engine ({@link sonde_layout}).
%%% This module is the third — a widget behaviour — and the small drawing
%%% vocabulary widgets share (PRD §6/§8). Nothing above this seam touches raw
%%% cells: a pane is composed from widgets, each drawing itself into a rect.
%%%
%%% == The seam ==
%%% A widget is a module implementing the {@link render/3} callback:
%%% ```
%%%   render(Config, Area :: #rect{}, Buf :: buffer()) -> buffer()
%%% '''
%%% `Config' is the widget's content and styling (the "self" a ratatui widget
%%% carries), `Area' is the {@link sonde_layout} rect it must confine itself to,
%%% and it returns the buffer with its cells drawn in — composing with the diff
%%% renderer exactly as a bare {@link sonde_render:put_text/5} would. {@link
%%% render/4} dispatches through the behaviour so a caller can render any widget
%%% uniformly by module. {@link sonde_block}, {@link sonde_paragraph}, {@link
%%% sonde_gauge}, {@link sonde_sparkline} and {@link sonde_chart} implement this
%%% callback.
%%%
%%% == Stateful widgets ==
%%% A selection index or scroll offset cannot live inside the widget: the
%%% immediate-mode renderer rebuilds every frame from scratch and discards the
%%% buffer, so nothing a stateless `render/3' stored would survive. A stateful
%%% widget ({@link sonde_list}, and the process table to come) instead takes that
%%% state as an explicit argument and returns the updated value:
%%% ```
%%%   render(Config, Area, Buf, State) -> {buffer(), State}
%%% '''
%%% The state (see `include/sonde_widget.hrl') lives in the application/UI state
%%% and is threaded by the caller across frames. This is ratatui's `StatefulWidget'
%%% split, made explicit because Erlang has no `&mut'.
%%%
%%% == Clipping is the widget's job ==
%%% {@link sonde_render:put_text/5} clips a run at the *buffer's* right edge, not
%%% at an arbitrary rect's. A widget confined to `Area' must not spill past
%%% `Area's right edge onto a neighbouring pane, so the shared {@link put_line/6}
%%% truncates text to the columns `Area' actually offers before drawing —
%%% measuring each grapheme cluster the way {@link sonde_render} will render it
%%% (so a control byte counts as the blank it becomes and a wide glyph as two
%%% columns), so the widget's clip and the renderer's never disagree.
%%%
%%% HARD CONSTRAINT (PRD §12): depends only on `kernel'/`stdlib'/`erts' plus the
%%% sibling render/layout/width modules. No third-party code.
%%% @end
%%%-------------------------------------------------------------------
-module(sonde_widget).

-include("sonde_layout.hrl").

-export([render/4, fill/3, put_line/6, truncate/2, split/2, align_offset/3, display_width/1]).

%% Draw the widget described by `Config' into `Area', returning the buffer with
%% its cells composited in. Called once per frame — the widget owns nothing
%% between frames (see the module doc on stateful widgets).
-callback render(Config :: term(), Area :: #rect{}, Buf :: sonde_render:buffer()) ->
    sonde_render:buffer().

%%% -- seam dispatch ---------------------------------------------------

%% @doc Render a stateless widget `Mod' through the behaviour: `Mod:render(Config,
%% Area, Buf)'. Lets a caller composite any widget uniformly by module, which is
%% the point of the seam. Stateful widgets are rendered through their own
%% `render/4' ({@link sonde_list:render/4}) instead — they return updated state.
-spec render(module(), term(), #rect{}, sonde_render:buffer()) -> sonde_render:buffer().
render(Mod, Config, Area, Buf) ->
    Mod:render(Config, Area, Buf).

%%% -- shared drawing helpers ------------------------------------------

%% @doc Fill every cell of `Area' with a space in `Style' — the styled background
%% a {@link sonde_block} paints behind its content, or the highlight bar a {@link
%% sonde_list} lays under its selected row. A degenerate rect (no columns or rows)
%% draws nothing. An empty style paints no background: the region is left
%% untouched so whatever it composites over — a parent block's background — shows
%% through, rather than being overwritten with default-blank cells. (Painting a
%% *styled* space is not a blank, so a non-empty style does overwrite, which is
%% what makes a configured background actually cover the parent.)
-spec fill(sonde_render:buffer(), #rect{}, sonde_render:style()) -> sonde_render:buffer().
fill(Buf, _Area, Style) when map_size(Style) =:= 0 ->
    Buf;
fill(Buf, #rect{w = W, h = H}, _Style) when W =< 0; H =< 0 ->
    Buf;
fill(Buf, #rect{x = X, y = Y, w = W, h = H}, Style) ->
    Spaces = binary:copy(<<" ">>, W),
    lists:foldl(
        fun(Row, B) -> sonde_render:put_text(B, X, Y + Row, Spaces, Style) end,
        Buf,
        lists:seq(0, H - 1)
    ).

%% @doc Draw one line of `Text' within `Area', at the `Area'-relative column
%% `DCol' and row `DRow', clipped to `Area': a row outside `[0, H)' or a column
%% outside `[0, W)' draws nothing, and the text is truncated to the columns
%% remaining to `Area's right edge (`W - DCol') so it can never spill past the
%% widget's region onto a neighbour. `Style' is overlaid on every cell drawn.
-spec put_line(
    sonde_render:buffer(),
    #rect{},
    integer(),
    integer(),
    unicode:chardata(),
    sonde_render:style()
) -> sonde_render:buffer().
put_line(Buf, #rect{h = H}, _DCol, DRow, _Text, _Style) when DRow < 0; DRow >= H ->
    Buf;
put_line(Buf, #rect{w = W}, DCol, _DRow, _Text, _Style) when DCol < 0; DCol >= W ->
    Buf;
put_line(Buf, #rect{x = X, y = Y, w = W}, DCol, DRow, Text, Style) ->
    Clipped = truncate(Text, W - DCol),
    sonde_render:put_text(Buf, X + DCol, Y + DRow, Clipped, Style).

%% @doc The left offset, in columns, that places `Width' columns of content within
%% an `Avail'-wide span under `Align'. Never negative — content already as wide as
%% (or wider than) the span sits flush left. Shared by every widget that aligns
%% text within a rect (a block title, a paragraph line).
-spec align_offset(left | center | right, non_neg_integer(), non_neg_integer()) ->
    non_neg_integer().
align_offset(left, _Avail, _Width) -> 0;
align_offset(center, Avail, Width) -> max(0, (Avail - Width) div 2);
align_offset(right, Avail, Width) -> max(0, Avail - Width).

%% @doc Display width of a whole string in terminal columns, measured the way the
%% widget layer actually renders it — each grapheme cluster via the same
%% sanitise-aware accounting {@link truncate/2} uses (a C0/C1 control counts as
%% the one-column blank it becomes, a malformed over-wide cluster as one, a wide
%% glyph as two). Use this, not {@link sonde_width:swidth/1}, whenever the width
%% must agree with {@link put_line/6}'s clip and {@link sonde_render}'s cursor
%% advance — e.g. to align text that may carry control bytes from untrusted
%% content, where the raw width would under-count the controls and misplace the
%% run.
-spec display_width(unicode:chardata()) -> non_neg_integer().
display_width(Text) ->
    sum_cols(string:next_grapheme(to_bin(Text)), 0).

-spec sum_cols(term(), non_neg_integer()) -> non_neg_integer().
sum_cols([GC | Rest], Acc) when is_integer(GC); is_list(GC) ->
    sum_cols(string:next_grapheme(Rest), Acc + disp_cols(GC));
sum_cols(_Done, Acc) ->
    Acc.

%% @doc The longest grapheme-cluster prefix of `Text' whose display width is at
%% most `MaxCols' columns. Stops before the first cluster that would overflow —
%% including a wide (two-column) cluster with only one column left — mirroring how
%% {@link sonde_render} clips a run at the buffer's right edge, so a widget's own
%% clip and the renderer's advance agree cell for cell.
%%
%% Width is measured the way {@link sonde_render} will actually render each
%% cluster, not by the raw {@link sonde_width:width/1}: a C0/C1 control base
%% becomes a one-column blank and a malformed over-wide cluster a one-column
%% replacement char, so a control or garbage byte in untrusted content is
%% budgeted for the column it will occupy rather than the zero {@link sonde_width}
%% assigns it — otherwise the clip could trail the emitted bytes and let the tail
%% spill one cell past `Area'.
-spec truncate(unicode:chardata(), integer()) -> binary().
truncate(_Text, MaxCols) when MaxCols =< 0 ->
    <<>>;
truncate(Text, MaxCols) ->
    take(string:next_grapheme(to_bin(Text)), MaxCols, 0, []).

%% Fold clusters until the next would exceed the budget, accumulating the taken
%% clusters (reversed) to reassemble. A zero-width cluster never overflows (its
%% base already fit), so a trailing combining mark rides along with its base.
-spec take(term(), non_neg_integer(), non_neg_integer(), [char() | [char()]]) -> binary().
take([GC | Rest], MaxCols, Used, Acc) when is_integer(GC); is_list(GC) ->
    case Used + disp_cols(GC) of
        Wide when Wide > MaxCols -> finish(Acc);
        Next -> take(string:next_grapheme(Rest), MaxCols, Next, [GC | Acc])
    end;
take(_Done, _MaxCols, _Used, Acc) ->
    %% End of text, or an undecodable tail from string:next_grapheme/1.
    finish(Acc).

-spec finish([char() | [char()]]) -> binary().
finish(Acc) ->
    case unicode:characters_to_binary(lists:reverse(Acc)) of
        Bin when is_binary(Bin) -> Bin;
        _ -> <<>>
    end.

%% @doc Split `Text' into a head of at most `MaxCols' columns and the remaining
%% bytes, measured the way {@link truncate/2} does — a control counts as the
%% one-column blank it renders as, a wide glyph as two. Unlike {@link truncate/2}
%% it always takes at least one grapheme cluster when `Text' is non-empty, so a
%% caller hard-splitting an over-wide run (a single wide glyph against a one-column
%% budget) still makes progress instead of looping; {@link put_line/6}'s own clip
%% drops the one-column overflow at draw time. Returns `{Head, Rest}' as UTF-8
%% binaries. This is the width-safe word-wrap primitive {@link sonde_paragraph}
%% hard-splits with, so its wrap decisions match what the renderer draws.
-spec split(unicode:chardata(), non_neg_integer()) -> {binary(), binary()}.
split(Text, MaxCols) ->
    split_walk(to_bin(Text), MaxCols, 0, []).

-spec split_walk(binary(), non_neg_integer(), non_neg_integer(), [char() | [char()]]) ->
    {binary(), binary()}.
split_walk(Bin, MaxCols, Used, Acc) ->
    case string:next_grapheme(Bin) of
        [GC | Rest] when is_integer(GC); is_list(GC) ->
            Cw = disp_cols(GC),
            case Acc =:= [] orelse Used + Cw =< MaxCols of
                %% `Bin' still begins with GC here, so at the break it is exactly
                %% the untaken remainder — return it verbatim.
                true -> split_walk(as_bin(Rest), MaxCols, Used + Cw, [GC | Acc]);
                false -> {finish(Acc), Bin}
            end;
        _ ->
            {finish(Acc), <<>>}
    end.

-spec as_bin(unicode:chardata()) -> binary().
as_bin(Bin) when is_binary(Bin) -> Bin;
as_bin(Other) -> to_bin(Other).

%% Columns a cluster will occupy once {@link sonde_render} has sanitised it: a
%% control base renders as a one-column blank, a malformed >2-column cluster as a
%% one-column replacement char, a legitimate zero-width mark stays 0, wide stays
%% 2. This mirrors sonde_render's "sanitise, then measure the sanitised glyph"
%% rule so the budget here matches the cursor advance there.
-spec disp_cols(char() | [char()]) -> 0 | 1 | 2.
disp_cols(GC) ->
    case is_control(base(GC)) of
        true ->
            1;
        false ->
            case sonde_width:width(GC) of
                0 -> 0;
                2 -> 2;
                _ -> 1
            end
    end.

%% The base codepoint of a cluster: the cluster itself when it is a lone
%% codepoint, else the first codepoint of the list.
-spec base(char() | [char()]) -> char().
base(C) when is_integer(C) -> C;
base([Base | _]) -> Base;
base([]) -> $\s.

%% C0 controls and DEL/C1 controls — the codepoints sonde_render replaces with a
%% blank rather than emitting raw.
-spec is_control(char()) -> boolean().
is_control(C) -> C < 16#20 orelse (C >= 16#7F andalso C =< 16#9F).

%% Best-effort chardata -> UTF-8 binary; a malformed tail contributes whatever
%% prefix decoded, so truncation never crashes on bad encodings (matching
%% sonde_render's own tolerance for untrusted content).
-spec to_bin(unicode:chardata()) -> binary().
to_bin(Text) ->
    case unicode:characters_to_binary(Text) of
        Bin when is_binary(Bin) -> Bin;
        {error, Good, _Rest} -> Good;
        {incomplete, Good, _Rest} -> Good
    end.
