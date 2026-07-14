%%%-------------------------------------------------------------------
%%% @doc Text input field — a single-line, editable value with a caret and
%%% horizontal scroll (stateful).
%%%
%%% Where {@link tuition_input} / {@link tuition_input_driver} turn a byte stream
%%% into structured key events, this is the on-screen counterpart: a rendered,
%%% editable field that shows typed text, a caret, and a scrolling view of a value
%%% longer than the field is wide. It is the affordance a filter/search box or a
%%% command line is built from (PRD §9). It is ratatui-land's `tui-input'.
%%%
%%% == Stateful, by necessity ==
%%% The value, the caret position and the scroll offset live in an `#input_state{}'
%%% (see `include/tuition_widget.hrl') held by the *caller*, not in this module —
%%% the renderer is immediate-mode and discards every frame, so state kept inside
%%% the widget would not survive (see {@link tuition_widget}). Editing is a pure
%%% state transition the caller applies to each decoded event, and {@link render/4}
%%% takes the state and returns it with the scroll offset reconciled to keep the
%%% caret in view:
%%% ```
%%%   {State1, _Changed} = tuition_input_field:handle(Event, State0),
%%%   {Buf1, State2}     = tuition_input_field:render(Cfg, Area, Buf0, State1).
%%% '''
%%% This is ratatui's `StatefulWidget' split, made explicit because Erlang has no
%%% `&mut'.
%%%
%%% == Editing ({@link handle/2}) ==
%%% {@link handle/2} folds one decoded {@link tuition_input:event()} into the state
%%% and reports whether the *value* changed (so a caller can re-run its filter only
%%% when it must — a bare caret move returns `false'):
%%% <ul>
%%%   <li>a printable `char' (no `ctrl'/`alt'/`meta') is inserted at the caret;</li>
%%%   <li>`backspace' deletes the cluster before the caret, `delete' the one
%%%       after;</li>
%%%   <li>`left'/`right' move the caret one grapheme cluster; with `ctrl' or `alt'
%%%       held they move by a word;</li>
%%%   <li>`home'/`end' jump to the start/end;</li>
%%%   <li>a `{paste, _}' inserts its text at the caret, with control bytes (a
%%%       newline included, since the field is single-line) stripped;</li>
%%%   <li>anything else (`enter', `tab', arrows the field does not use, a `ctrl'
%%%       chord, a mouse report) is left for the caller to act on and returns the
%%%       state unchanged.</li>
%%% </ul>
%%% Caret movement and word boundaries are grapheme-cluster aware — a wide glyph or
%%% a base-plus-combining-mark cluster is one step — measured with the same {@link
%%% tuition_widget:display_width/1} the renderer clips by, so the caret column the
%%% field scrolls to and the column the glyph actually lands on never disagree. A
%%% word is a maximal run of non-space clusters; a word move skips any spaces then
%%% the run beside them.
%%%
%%% == Horizontal scroll ==
%%% When the value is wider than the field, {@link render/4} slides `offset' (the
%%% index of the leftmost visible cluster) just far enough to keep the caret in
%%% view: leftward when the caret sits left of the window, rightward when it runs
%%% off the right — reserving one column for the caret so a caret at the very end
%%% of a full field is still shown — and it pulls back left to avoid a needless
%%% blank tail after the value shrinks. Scrolling is by whole clusters, so a wide
%%% glyph is never split across the left edge. The reconciled offset is returned
%%% and kept for the next frame, the horizontal analogue of {@link tuition_list}'s
%%% vertical `offset'.
%%%
%%% == The caret is a styled cell ==
%%% The application owns (and hides) the hardware cursor, so the field draws its own
%%% caret as a styled cell over the glyph beneath it — `cursor_style' overlaid on
%%% that glyph (default: `underline', the one always-available attribute that shows
%%% over a blank; a `reverse' block cursor awaits the richer style model of #8). An
%%% empty `cursor_style' draws no visible caret, which is how a caller marks the
%%% field unfocused.
%%%
%%% == Config ==
%%% A `#{}' map, every key optional:
%%% <ul>
%%%   <li>`placeholder'       — chardata shown when the value is empty (default
%%%       none).</li>
%%%   <li>`style'             — base style for the field, filling its full width
%%%       (default: unstyled, so a parent background shows through).</li>
%%%   <li>`cursor_style'      — style overlaid on the caret cell (default
%%%       `#{underline => true}'; `#{}' to hide the caret).</li>
%%%   <li>`placeholder_style' — style for the placeholder text (default
%%%       `#{fg => 8}', a dim grey).</li>
%%%   <li>`mask'              — a single codepoint to display in place of every
%%%       value cluster, for a password-style field (default: show the value).</li>
%%% </ul>
%%% The field draws on the top row of `Area' and confines itself to it; give it a
%%% one-row rect via {@link tuition_layout}.
%%%
%%% HARD CONSTRAINT (PRD §12): depends only on `kernel'/`stdlib'/`erts' plus the
%%% sibling render/layout/width/widget modules. No third-party code.
%%% @end
%%%-------------------------------------------------------------------
-module(tuition_input_field).

-include("tuition_layout.hrl").
-include("tuition_widget.hrl").

-export([new/0, render/4, handle/2, value/1, set_value/2, cursor/1]).

-type input_cfg() :: #{
    placeholder => unicode:chardata(),
    style => tuition_render:style(),
    cursor_style => tuition_render:style(),
    placeholder_style => tuition_render:style(),
    mask => char()
}.
-type state() :: #input_state{}.

-export_type([input_cfg/0, state/0]).

%% A caret drawn over a blank needs an attribute that shows without a glyph;
%% underline is the one always available today (bold on a space is invisible, and
%% there is no `reverse' yet — see #8). A dim grey placeholder is the convention
%% for "no value here". Both are overridable via config.
-define(DEFAULT_CURSOR_STYLE, #{underline => true}).
-define(DEFAULT_PLACEHOLDER_STYLE, #{fg => 8}).

%%% -- state -----------------------------------------------------------

%% @doc A fresh, empty field: no text, caret at the start, unscrolled. A caller
%% that does not want to include `tuition_widget.hrl' can start here and drive the
%% field through the API ({@link handle/2}, {@link set_value/2}, {@link value/1},
%% {@link cursor/1}).
-spec new() -> state().
new() -> #input_state{}.

%% @doc The field's current value, as a UTF-8 binary.
-spec value(state()) -> binary().
value(#input_state{value = Value}) -> Value.

%% @doc The caret position, as a 0-based grapheme-cluster index into the value
%% (`0' before the first cluster, the cluster count after the last).
-spec cursor(state()) -> non_neg_integer().
cursor(#input_state{cursor = Cursor}) -> Cursor.

%% @doc Replace the value wholesale and place the caret at its end. Control bytes
%% (newlines included — the field is single-line) are stripped, so a value pasted
%% in programmatically renders as one clean line. The scroll offset is reset and
%% reconciled at the next {@link render/4}.
-spec set_value(state(), unicode:chardata()) -> state().
set_value(State, Chardata) ->
    Value = sanitize(to_bin(Chardata)),
    State#input_state{value = Value, cursor = count_clusters(Value), offset = 0}.

%%% -- editing ---------------------------------------------------------

%% @doc Fold one decoded {@link tuition_input:event()} into the field, returning
%% the updated state and whether the *value* changed. A bare caret move (`left',
%% `home', ...) returns `false' though the state's caret moved, so a caller can
%% gate an expensive re-filter on real edits; an event the field ignores returns
%% the state unchanged and `false'. See the module doc for the key bindings.
-spec handle(tuition_input:event(), state()) -> {state(), Changed :: boolean()}.
handle(Event, #input_state{value = Before} = State0) ->
    State1 = apply_event(Event, State0),
    {State1, State1#input_state.value =/= Before}.

-spec apply_event(tuition_input:event(), state()) -> state().
apply_event({key, {char, CP}, Mods}, State) ->
    case is_text_input(Mods) of
        true -> insert(State, <<CP/utf8>>);
        false -> State
    end;
apply_event({key, backspace, _Mods}, State) ->
    backspace(State);
apply_event({key, delete, _Mods}, State) ->
    delete(State);
apply_event({key, left, Mods}, State) ->
    move_left(State, word_mod(Mods));
apply_event({key, right, Mods}, State) ->
    move_right(State, word_mod(Mods));
apply_event({key, home, _Mods}, State) ->
    State#input_state{cursor = 0};
apply_event({key, 'end', _Mods}, #input_state{value = Value} = State) ->
    State#input_state{cursor = count_clusters(Value)};
apply_event({paste, Bin}, State) ->
    insert(State, Bin);
apply_event(_Other, State) ->
    %% enter, tab, arrows the field does not use, ctrl chords, mouse — the
    %% caller's to act on. Leave the field untouched.
    State.

%% Insert `Text' (sanitised of control bytes) at the caret, advancing the caret
%% past it. Editing works on the list of grapheme clusters so a wide glyph or a
%% base-plus-combining-mark cluster is inserted and stepped over as one unit.
-spec insert(state(), unicode:chardata()) -> state().
insert(#input_state{value = Value, cursor = Cursor} = State, Text) ->
    case sanitize(to_bin(Text)) of
        <<>> ->
            State;
        Clean ->
            Clusters = clusters(Value),
            At = min(Cursor, length(Clusters)),
            Inserted = clusters(Clean),
            New = lists:sublist(Clusters, At) ++ Inserted ++ lists:nthtail(At, Clusters),
            State#input_state{value = join(New), cursor = At + length(Inserted)}
    end.

%% Delete the cluster before the caret and step back over the gap; a no-op at the
%% start of the value.
-spec backspace(state()) -> state().
backspace(#input_state{value = Value, cursor = Cursor} = State) ->
    Clusters = clusters(Value),
    case min(Cursor, length(Clusters)) of
        0 ->
            State;
        At ->
            New = lists:sublist(Clusters, At - 1) ++ lists:nthtail(At, Clusters),
            State#input_state{value = join(New), cursor = At - 1}
    end.

%% Delete the cluster after the caret, leaving the caret put; a no-op at the end of
%% the value.
-spec delete(state()) -> state().
delete(#input_state{value = Value, cursor = Cursor} = State) ->
    Clusters = clusters(Value),
    At = min(Cursor, length(Clusters)),
    case At < length(Clusters) of
        false ->
            State;
        true ->
            New = lists:sublist(Clusters, At) ++ lists:nthtail(At + 1, Clusters),
            State#input_state{value = join(New), cursor = At}
    end.

%% Move the caret left one cluster, or (Word) to the start of the word to its left.
-spec move_left(state(), boolean()) -> state().
move_left(#input_state{value = Value, cursor = Cursor} = State, Word) ->
    Clusters = clusters(Value),
    At = min(Cursor, length(Clusters)),
    New =
        case Word of
            true -> word_left(Clusters, At);
            false -> max(0, At - 1)
        end,
    State#input_state{cursor = New}.

%% Move the caret right one cluster, or (Word) past the word to its right.
-spec move_right(state(), boolean()) -> state().
move_right(#input_state{value = Value, cursor = Cursor} = State, Word) ->
    Clusters = clusters(Value),
    N = length(Clusters),
    At = min(Cursor, N),
    New =
        case Word of
            true -> word_right(Clusters, At);
            false -> min(N, At + 1)
        end,
    State#input_state{cursor = New}.

%% Skip any spaces to the left of `At', then the run of non-spaces beside them —
%% landing at the start of the word the caret was in or just past.
-spec word_left([binary()], non_neg_integer()) -> non_neg_integer().
word_left(Clusters, At) ->
    OverSpaces = skip_left(Clusters, At, true),
    skip_left(Clusters, OverSpaces, false).

%% Skip any spaces to the right of `At', then the run of non-spaces beside them —
%% landing just past the next word.
-spec word_right([binary()], non_neg_integer()) -> non_neg_integer().
word_right(Clusters, At) ->
    OverSpaces = skip_right(Clusters, At, length(Clusters), true),
    skip_right(Clusters, OverSpaces, length(Clusters), false).

%% Step left from `At' while the cluster immediately to the left is (or is not,
%% when `WantSpace' is `false') a space. `At' counts clusters to the caret's left,
%% so the cluster just left of it is the `At'th (1-based) — `lists:nth(At, _)'.
-spec skip_left([binary()], non_neg_integer(), boolean()) -> non_neg_integer().
skip_left(_Clusters, 0, _WantSpace) ->
    0;
skip_left(Clusters, At, WantSpace) ->
    case is_space(lists:nth(At, Clusters)) =:= WantSpace of
        true -> skip_left(Clusters, At - 1, WantSpace);
        false -> At
    end.

%% Step right from `At' while the cluster at the caret (the `At'th, 0-based —
%% `lists:nth(At + 1, _)') is (or is not) a space, stopping at the end `N'.
-spec skip_right([binary()], non_neg_integer(), non_neg_integer(), boolean()) ->
    non_neg_integer().
skip_right(_Clusters, N, N, _WantSpace) ->
    N;
skip_right(Clusters, At, N, WantSpace) ->
    case is_space(lists:nth(At + 1, Clusters)) =:= WantSpace of
        true -> skip_right(Clusters, At + 1, N, WantSpace);
        false -> At
    end.

%% Whether a cluster is a word separator. A word boundary is an ASCII space: it is
%% the separator a filter/command box types, and control bytes (tabs included) are
%% stripped before they reach the value, so no other whitespace occurs here.
-spec is_space(binary()) -> boolean().
is_space(<<$\s, _/binary>>) -> true;
is_space(_Cluster) -> false.

%% Whether a `char' event is plain typed text rather than a shortcut: no `ctrl',
%% `alt' or `meta' held (a bare `shift', already folded into the codepoint, is
%% fine).
-spec is_text_input([tuition_input:mod()]) -> boolean().
is_text_input(Mods) ->
    not lists:any(fun(M) -> lists:member(M, [ctrl, alt, meta]) end, Mods).

%% Whether a modifier set asks for a word-wise caret move (`ctrl' or `alt' held on
%% an arrow key), the two conventional word-move chords.
-spec word_mod([tuition_input:mod()]) -> boolean().
word_mod(Mods) ->
    lists:member(ctrl, Mods) orelse lists:member(alt, Mods).

%%% -- render ----------------------------------------------------------

%% @doc Draw the field into the top row of `Area' — the visible slice of the value
%% (or the placeholder when empty) with the caret over it — and return the buffer
%% together with the reconciled state (caret clamped into range, scroll offset slid
%% to keep the caret in view). A degenerate area draws nothing but still reconciles
%% the state, so a resize to nothing and back leaves a valid caret/offset behind.
-spec render(input_cfg(), #rect{}, tuition_render:buffer(), state()) ->
    {tuition_render:buffer(), state()}.
render(Cfg, #rect{w = W, h = H} = Area, Buf, State0) ->
    Display = display_clusters(Cfg, State0),
    State1 = reconcile(State0, Display, W),
    Buf1 =
        case W =< 0 orelse H =< 0 of
            true -> Buf;
            false -> draw(Cfg, Area, Buf, State1, Display)
        end,
    {Buf1, State1}.

%% The value as a list of `{Glyph, Width}' pairs: the glyph to draw for each
%% cluster (the cluster itself, or the `mask' codepoint for a password field) and
%% its display width, measured the way {@link tuition_widget:display_width/1} — and
%% so the renderer — will account for it.
-spec display_clusters(input_cfg(), state()) -> [{binary(), non_neg_integer()}].
display_clusters(Cfg, #input_state{value = Value}) ->
    Mask = maps:get(mask, Cfg, none),
    [display_one(GC, Mask) || GC <- clusters(Value)].

-spec display_one(binary(), char() | none) -> {binary(), non_neg_integer()}.
display_one(_GC, Mask) when is_integer(Mask) ->
    Glyph = <<Mask/utf8>>,
    {Glyph, tuition_widget:display_width(Glyph)};
display_one(GC, _Mask) ->
    {GC, tuition_widget:display_width(GC)}.

%% @doc Reconcile an `#input_state{}' against the current value and field width:
%% clamp the caret into `[0, N]' (the cluster count) and slide the scroll offset so
%% the caret falls within the visible window. Pure: the returned state is what
%% survives to the next frame.
-spec reconcile(state(), [{binary(), non_neg_integer()}], integer()) -> state().
reconcile(#input_state{value = Value, cursor = Cursor0, offset = Offset0}, Display, W) ->
    N = length(Display),
    Cursor = clamp(Cursor0, 0, N),
    Offset = adjust_offset(Offset0, Cursor, Display, W),
    #input_state{value = Value, cursor = Cursor, offset = Offset}.

%% Slide the scroll offset (a cluster index) to keep the caret in view within a
%% `W'-column field. The offset can never sit right of the caret; it is then pushed
%% right until the columns before the caret fit in `W - 1' (reserving the last
%% column for the caret itself), and finally pulled back left so the value's tail
%% does not leave a needless blank gap after an edit shortened it.
-spec adjust_offset(
    non_neg_integer(), non_neg_integer(), [{binary(), non_neg_integer()}], integer()
) ->
    non_neg_integer().
adjust_offset(_Offset, _Cursor, _Display, W) when W =< 0 ->
    0;
adjust_offset(Offset0, Cursor, Display, W) ->
    Widths = [Width || {_Glyph, Width} <- Display],
    N = length(Widths),
    Capped = min(max(Offset0, 0), Cursor),
    Pushed = push_right(Capped, Cursor, Widths, W),
    pull_left(Pushed, Cursor, N, Widths, W).

%% Push the offset right until the caret's column (the width of the clusters
%% between the offset and the caret) leaves room for the caret cell in `W'. Stops
%% at the caret at the latest, where that width is zero.
-spec push_right(non_neg_integer(), non_neg_integer(), [non_neg_integer()], pos_integer()) ->
    non_neg_integer().
push_right(Offset, Cursor, Widths, W) ->
    case Offset < Cursor andalso width_between(Widths, Offset, Cursor) > W - 1 of
        true -> push_right(Offset + 1, Cursor, Widths, W);
        false -> Offset
    end.

%% Pull the offset back left while the visible tail (the value from one cluster
%% earlier to the end, plus the caret's own column when it sits at the very end)
%% would still fit in `W' — so a value that shrank does not leave leading text
%% hidden behind a blank right margin.
-spec pull_left(
    non_neg_integer(), non_neg_integer(), non_neg_integer(), [non_neg_integer()], pos_integer()
) -> non_neg_integer().
pull_left(0, _Cursor, _N, _Widths, _W) ->
    0;
pull_left(Offset, Cursor, N, Widths, W) ->
    CaretExtra = caret_extra(Cursor, N),
    case width_between(Widths, Offset - 1, N) + CaretExtra =< W of
        true -> pull_left(Offset - 1, Cursor, N, Widths, W);
        false -> Offset
    end.

%%% -- drawing ---------------------------------------------------------

%% Fill the field's row with the base style, draw the value's visible slice (or the
%% placeholder when empty), then lay the caret over the glyph beneath it.
-spec draw(input_cfg(), #rect{}, tuition_render:buffer(), state(), [{binary(), non_neg_integer()}]) ->
    tuition_render:buffer().
draw(Cfg, #rect{w = W} = Area, Buf, #input_state{cursor = Cursor, offset = Offset}, Display) ->
    Base = maps:get(style, Cfg, #{}),
    Buf1 = tuition_widget:fill(Buf, top_row(Area), Base),
    Buf2 =
        case Display of
            [] -> draw_placeholder(Cfg, Area, Buf1, Base);
            _ -> draw_value(Area, Buf1, Base, Display, Offset)
        end,
    draw_caret(Cfg, Area, Buf2, Base, Display, Offset, Cursor, W).

%% Draw the visible clusters, from the offset onward, as one run at column 0;
%% {@link tuition_widget:put_line/6} truncates it to the field width, dropping a
%% wide glyph with only one column left at the right edge exactly as the renderer
%% would.
-spec draw_value(
    #rect{},
    tuition_render:buffer(),
    tuition_render:style(),
    [{binary(), non_neg_integer()}],
    non_neg_integer()
) ->
    tuition_render:buffer().
draw_value(Area, Buf, Base, Display, Offset) ->
    Glyphs = [Glyph || {Glyph, _Width} <- lists:nthtail(Offset, Display)],
    tuition_widget:put_line(Buf, Area, 0, 0, Glyphs, Base).

%% Draw the placeholder (shown only while the value is empty) at column 0 in the
%% placeholder style, over the base style so a configured field background shows
%% through; nothing when no placeholder is configured.
-spec draw_placeholder(input_cfg(), #rect{}, tuition_render:buffer(), tuition_render:style()) ->
    tuition_render:buffer().
draw_placeholder(Cfg, Area, Buf, Base) ->
    case to_bin(maps:get(placeholder, Cfg, <<>>)) of
        <<>> ->
            Buf;
        Placeholder ->
            tuition_widget:put_line(Buf, Area, 0, 0, Placeholder, placeholder_style(Cfg, Base))
    end.

%% Overlay the caret: the glyph beneath it re-drawn with `cursor_style' merged onto
%% the style already there. When the caret would fall off the right edge (it should
%% not after reconciliation, but guard anyway) nothing is drawn; when a wide glyph
%% under the caret has only one column left, a space stands in so the caret still
%% shows rather than being clipped to nothing.
-spec draw_caret(
    input_cfg(),
    #rect{},
    tuition_render:buffer(),
    tuition_render:style(),
    [{binary(), non_neg_integer()}],
    non_neg_integer(),
    non_neg_integer(),
    integer()
) -> tuition_render:buffer().
draw_caret(Cfg, Area, Buf, Base, Display, Offset, Cursor, W) ->
    CaretCol = width_between([Width || {_G, Width} <- Display], Offset, Cursor),
    case CaretCol < W of
        false ->
            Buf;
        true ->
            {Glyph0, Under} = caret_glyph(Cfg, Display, Cursor, Base),
            Glyph =
                case CaretCol + tuition_widget:display_width(Glyph0) > W of
                    true -> <<" ">>;
                    false -> Glyph0
                end,
            Cursor0 = maps:get(cursor_style, Cfg, ?DEFAULT_CURSOR_STYLE),
            tuition_widget:put_line(Buf, Area, CaretCol, 0, Glyph, maps:merge(Under, Cursor0))
    end.

%% The glyph the caret sits on and the style already under it: the value cluster at
%% the caret; a space (in the base style) when the caret is past the last cluster;
%% and, in the empty-value case, the placeholder's first cluster (in the
%% placeholder style) so the caret rests on the hint rather than blanking it.
-spec caret_glyph(
    input_cfg(), [{binary(), non_neg_integer()}], non_neg_integer(), tuition_render:style()
) ->
    {binary(), tuition_render:style()}.
caret_glyph(Cfg, Display, Cursor, Base) ->
    case Cursor < length(Display) of
        true ->
            {Glyph, _Width} = lists:nth(Cursor + 1, Display),
            {Glyph, Base};
        false ->
            caret_on_blank(Cfg, Display, Base)
    end.

-spec caret_on_blank(input_cfg(), [{binary(), non_neg_integer()}], tuition_render:style()) ->
    {binary(), tuition_render:style()}.
caret_on_blank(Cfg, [], Base) ->
    case to_bin(maps:get(placeholder, Cfg, <<>>)) of
        <<>> ->
            {<<" ">>, Base};
        Placeholder ->
            {first_cluster(Placeholder), placeholder_style(Cfg, Base)}
    end;
caret_on_blank(_Cfg, _Display, Base) ->
    {<<" ">>, Base}.

%% The placeholder text style, with the field's base style merged underneath so a
%% configured field background (or other base attribute) shows through the
%% placeholder cells: {@link tuition_widget:put_line/6} writes fresh cells rather
%% than merging onto the base-filled row, so the base must be carried explicitly
%% here — the way {@link tuition_list} draws its rows in the base style, and the
%% caret merges onto the style beneath it. An explicit `placeholder_style' key wins
%% over the base, so a caller can still override the background.
-spec placeholder_style(input_cfg(), tuition_render:style()) -> tuition_render:style().
placeholder_style(Cfg, Base) ->
    maps:merge(Base, maps:get(placeholder_style, Cfg, ?DEFAULT_PLACEHOLDER_STYLE)).

%%% -- helpers ---------------------------------------------------------

%% The field's top row as a one-row rect — the single line it draws on.
-spec top_row(#rect{}) -> #rect{}.
top_row(#rect{x = X, y = Y, w = W}) -> #rect{x = X, y = Y, w = W, h = 1}.

%% Columns spanned by the clusters in `[From, To)' — the width the caret sits at
%% relative to the offset, and the visible tail width for scroll reconciliation.
-spec width_between([non_neg_integer()], non_neg_integer(), non_neg_integer()) -> non_neg_integer().
width_between(Widths, From, To) when To > From ->
    lists:sum(lists:sublist(Widths, From + 1, To - From));
width_between(_Widths, _From, _To) ->
    0.

%% One extra column for the caret when it sits past the last cluster (at the end of
%% the value), so scroll reconciliation reserves room for it; zero otherwise.
-spec caret_extra(non_neg_integer(), non_neg_integer()) -> 0 | 1.
caret_extra(N, N) -> 1;
caret_extra(_Cursor, _N) -> 0.

%% Clamp `V' into `[Lo, Hi]'.
-spec clamp(integer(), integer(), integer()) -> integer().
clamp(V, Lo, Hi) -> min(max(V, Lo), Hi).

%% Split a UTF-8 binary into its grapheme clusters, each as a binary — the unit
%% caret movement and editing step over, so a wide glyph or a base-plus-combining
%% cluster counts as one.
-spec clusters(binary()) -> [binary()].
clusters(Bin) -> clusters(string:next_grapheme(Bin), []).

-spec clusters(term(), [binary()]) -> [binary()].
clusters([GC | Rest], Acc) when is_integer(GC); is_list(GC) ->
    clusters(string:next_grapheme(Rest), [grapheme_bin(GC) | Acc]);
clusters(_Done, Acc) ->
    lists:reverse(Acc).

%% One grapheme cluster (a codepoint or a codepoint list) as a UTF-8 binary; an
%% undecodable cluster degrades to empty rather than crashing.
-spec grapheme_bin(char() | [char()]) -> binary().
grapheme_bin(GC) ->
    case unicode:characters_to_binary([GC]) of
        Bin when is_binary(Bin) -> Bin;
        _ -> <<>>
    end.

%% The first grapheme cluster of a non-empty binary (used to rest the caret on a
%% placeholder's opening glyph).
-spec first_cluster(binary()) -> binary().
first_cluster(Bin) ->
    case clusters(Bin) of
        [First | _] -> First;
        [] -> <<" ">>
    end.

-spec count_clusters(binary()) -> non_neg_integer().
count_clusters(Bin) -> length(clusters(Bin)).

%% Join grapheme-cluster binaries back into one value binary.
-spec join([binary()]) -> binary().
join(Clusters) -> iolist_to_binary(Clusters).

%% Drop C0/C1 control codepoints so a single-line field never stores a newline,
%% tab or escape — whether typed, pasted, or set programmatically — that the
%% renderer would blank anyway and that would muddle caret/word logic.
-spec sanitize(binary()) -> binary().
sanitize(Bin) ->
    <<<<CP/utf8>> || <<CP/utf8>> <= Bin, not is_control(CP)>>.

%% C0 controls and DEL/C1 controls — the codepoints {@link tuition_render} replaces
%% with a blank rather than emitting raw.
-spec is_control(char()) -> boolean().
is_control(CP) -> CP < 16#20 orelse (CP >= 16#7F andalso CP =< 16#9F).

%% Best-effort chardata -> UTF-8 binary; a malformed tail contributes whatever
%% prefix decoded, matching the tolerance the rest of the widget layer keeps for
%% untrusted content.
-spec to_bin(unicode:chardata()) -> binary().
to_bin(Text) ->
    case unicode:characters_to_binary(Text) of
        Bin when is_binary(Bin) -> Bin;
        {error, Good, _Rest} -> Good;
        {incomplete, Good, _Rest} -> Good
    end.
