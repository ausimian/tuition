-module(tuition_input).
-moduledoc """
Turns a raw terminal byte stream into structured key events.

Feed it bytes as they arrive and it gives you `t:event/0`s. The local backend's
reader (`m:tuition_term_local`) forwards raw input bytes verbatim, one small
chunk at a time, in latin1, so escape sequences and UTF-8 arrive undecoded. This
module reassembles them using Erlang binary pattern matching.

## Incremental contract

Bytes may split a multi-byte sequence across reads, since the reader emits a
byte at a time. `parse/2` therefore decodes every *complete* sequence it can and
keeps any trailing partial (a lone `ESC`, a half-finished CSI, an incomplete
UTF-8 code point) in the returned `t:state/0`. A later `parse/2` completes it
from the bytes that follow.

## Lone-ESC disambiguation

A bare `ESC` (0x1B) is inherently ambiguous: on its own it is the Escape key,
but it is also the first byte of every CSI/SS3 sequence and of an Alt-modified
key. `parse/2` cannot tell which until it sees (or fails to see) the next byte,
so a trailing `ESC` stays buffered. The driver reads with a bounded timeout
(`tuition_term:read/2`). When that read times out with an `ESC` still buffered,
the driver calls `flush/1`, which resolves it to an Escape key. So `ESC [ A`
decodes to Up immediately, while a lone `ESC` resolves to Escape only once the
inter-byte timeout elapses.

## Alt-prefixed escape sequences (metaSendsEscape)

A terminal in `metaSendsEscape` mode encodes an Alt-modified escape-sequence key
(Alt+Up, Alt+F5,...) by prefixing an extra `ESC`, so Alt+Up arrives as
`ESC ESC [ A`. `parse/2` folds that leading `ESC` into an `alt` modifier on the
key the trailing sequence decodes to. Those bytes are identical to Escape
followed by that key, so timing tells the two apart, exactly as for a lone
`ESC`. A `metaSendsEscape` burst lands inside the driver's escape window and
decodes to the Alt chord, whereas a real Escape-then-key has an inter-key gap
and `flush/1` resolves the `ESC` to an Escape first. Only keys are prefixed this
way. An `ESC` before a non-key sequence — an SGR mouse report or a
bracketed-paste opener — stays a standalone Escape, followed by that sequence.
(The mainstream Alt encodings are unaffected too: printable Alt is a single
`ESC a`, and modern terminals send Alt+Up as the CSI modifier form
`ESC [ 1; 3 A`.)

## Mouse & bracketed paste

Two further input-adjacent sources are decoded here. Each is surfaced only once
capability probing (`m:tuition_caps`) has enabled the matching terminal mode:

- **SGR mouse** (`?1006`) — `ESC [ < Cb; Cx; Cy M|m` becomes a
  `t:mouse_event/0`. The final byte gives press (`M`) vs release (`m`), the
  `Cb` bitfield carries the button, held modifiers and a motion flag, and
  `Cx`/`Cy` are the 1-based column/row.
- **Bracketed paste** (`?2004`) — the bytes between `ESC [ 200 ~` and
  `ESC [ 201 ~` are *literal* pasted text. They are emitted as a single
  `{paste, binary()}` event, never re-decoded as keys. A paste can span reads,
  so the parser holds an "inside paste" buffer in its `t:state/0` until the
  closing bracket arrives.

This module is pure — no processes, no timers — so it is fully testable against
byte-sequence fixtures. The `receive... after` timing lives in the driver
(`m:tuition_input_driver`), which keeps decode logic separate from I/O.
""".

-export([new/0, parse/2, flush/1, pending/1, awaiting_escape/1]).

-type mod() :: shift | alt | ctrl | meta.
%% A decoded named key, as delivered by CSI/SS3 sequences and control bytes.
-type named() ::
    enter
    | tab
    | backspace
    | esc
    | up
    | down
    | left
    | right
    | home
    | 'end'
    | page_up
    | page_down
    | insert
    | delete
    | {f, 1..12}.
%% What a mouse report says happened: a button `press', its `release', or a
%% `drag' (motion with a button held, or a bare pointer move under all-motion
%% tracking). A wheel notch arrives as a `press' of a `wheel_*' button.
-type mouse_action() :: press | release | drag.
%% The button a mouse report names. `none' is the buttonless code (a plain move,
%% or the legacy release marker); `{button, N}' covers the extended buttons 8-11.
-type mouse_button() ::
    left
    | middle
    | right
    | wheel_up
    | wheel_down
    | wheel_left
    | wheel_right
    | {button, 8..11}
    | none.
%% A decoded SGR mouse report: what happened, to which button, at a 1-based
%% column/row, with any modifiers the terminal folded into the `Cb' bitfield.
-type mouse_event() ::
    {mouse, mouse_action(), mouse_button(), {Col :: pos_integer(), Row :: pos_integer()}, [mod()]}.
%% A single decoded input event. `char' carries a printable Unicode code point;
%% `ctrl' carries the base letter of a control-key chord (e.g. `$a' for Ctrl-A);
%% a mouse report is a {@type mouse_event()}; a bracketed paste is the literal
%% pasted bytes, delivered whole in one `{paste, _}'.
-type event() ::
    {key, {char, char()}, [mod()]}
    | {key, {ctrl, char()}, [mod()]}
    | {key, named(), [mod()]}
    | mouse_event()
    | {paste, binary()}.

%% Opaque parser state: `{input, Buf}' holds any trailing partial (a lone `ESC',
%% a half CSI, an incomplete UTF-8 run) between reads; `{paste, Buf}' means we are
%% inside a bracketed paste, accumulating literal bytes until the `ESC [ 201 ~'
%% terminator arrives (possibly across several reads).
-opaque state() :: {input, binary()} | {paste, binary()}.

-export_type([event/0, named/0, mod/0, mouse_action/0, mouse_button/0, mouse_event/0, state/0]).

%% Unicode replacement character, emitted for malformed UTF-8.
-define(REPLACEMENT, 16#FFFD).

%% Bracketed-paste brackets: the CSI tilde numbers that open (`ESC [ 200 ~') and
%% close (`ESC [ 201 ~') a paste, and the full closing byte sequence scanned for
%% inside a paste.
-define(PASTE_START_NUM, 200).
-define(PASTE_END_NUM, 201).
-define(PASTE_END, <<16#1B, $[, "201~">>).

%%% -- API -------------------------------------------------------------

-spec new() -> state().
new() -> {input, <<>>}.

-doc """
Whether any incomplete sequence is buffered awaiting more bytes. Inside a
bracketed paste this is always true: the paste is unfinished until its closing
bracket arrives, even with no content buffered yet.
""".
-spec pending(state()) -> boolean().
pending({input, <<>>}) -> false;
pending({input, _}) -> true;
pending({paste, _}) -> true.

-doc """
Whether the buffered partial is genuinely ESC-ambiguous and so needs the
driver's short inter-byte (escape) timeout to resolve. It is true for three
things: a lone `ESC`, which must become Escape promptly if nothing follows; an
incomplete CSI/SS3 introducer (`ESC [`/`ESC O`), which the timeout resolves to
Escape plus the trailing bytes; and their `metaSendsEscape` nested-ESC
counterparts — a bare `ESC ESC` (still able to grow into an Alt+<escape-seq-key>
chord) and an incomplete `ESC ESC [`/`ESC ESC O` — which the timeout resolves to
two Escapes, or to the Alt chord if the sequence completes before it fires.

Crucially it is FALSE once `ESC` is followed by anything else. In practice that
means a partial Alt-prefixed multi-byte character (`<<ESC, 16#C3>>` for Alt+é).
There the ESC is already committed to an Alt chord and only the UTF-8
continuation is outstanding. That is not an escape ambiguity, so it must wait
under the normal read policy. Forcing it onto the short timeout would flush it
to a bare `Escape` plus an unmodified character, dropping the Alt. (The same
goes for a plain split UTF-8 character, which never starts with `ESC`.)
""".
-spec awaiting_escape(state()) -> boolean().
awaiting_escape({input, <<16#1B>>}) -> true;
awaiting_escape({input, <<16#1B, $[, _/binary>>}) -> true;
awaiting_escape({input, <<16#1B, $O, _/binary>>}) -> true;
%% metaSendsEscape nested-ESC partials: a buffered `ESC ESC' (which may still grow
%% into Alt+<escape-seq-key>) and an incomplete `ESC ESC ['/`ESC ESC O' introducer
%% are ESC-ambiguous too, so the short escape timeout must resolve them rather than
%% stalling on the idle timeout.
awaiting_escape({input, <<16#1B, 16#1B>>}) -> true;
awaiting_escape({input, <<16#1B, 16#1B, $[, _/binary>>}) -> true;
awaiting_escape({input, <<16#1B, 16#1B, $O, _/binary>>}) -> true;
awaiting_escape({input, _}) -> false;
%% Inside a paste, a buffered trailing `ESC' (or `ESC [') is literal pasted text
%% or part of the closing bracket — never an escape awaiting disambiguation — so
%% the short ESC timeout must not apply, or a slow paste would be truncated.
awaiting_escape({paste, _}) -> false.

-doc """
Decode `Bytes` (appended to any buffered partial) into complete events,
returning them in arrival order plus the state holding any trailing partial.
""".
-spec parse(binary(), state()) -> {[event()], state()}.
parse(Bytes, {input, Buf}) ->
    {RevEvents, St} = decode(<<Buf/binary, Bytes/binary>>, []),
    {lists:reverse(RevEvents), St};
parse(Bytes, {paste, Buf}) ->
    {RevEvents, St} = collect_paste(<<Buf/binary, Bytes/binary>>, []),
    {lists:reverse(RevEvents), St}.

-doc """
Resolve a buffered partial when no more bytes are coming (the driver's
inter-byte read timed out). A leading `ESC` becomes an Escape key and any bytes
that trailed it are re-decoded. A truncated multi-byte UTF-8 code point is
emitted as the Unicode replacement character. Idempotent on an empty buffer.
""".
-spec flush(state()) -> {[event()], state()}.
flush({input, <<>>}) ->
    {[], {input, <<>>}};
flush({input, <<16#1B, Rest/binary>>}) ->
    %% A bare ESC (or the head of an escape sequence the terminal never
    %% finished): resolve to the Escape key, then decode whatever trailed it.
    %% Under metaSendsEscape the residue can itself be a buffered ESC partial (a
    %% double-Escape `ESC ESC', or an `ESC ESC <seq>' the terminal never finished),
    %% so drain it too — a fully-buffered `ESC ESC' thus resolves to two Escapes in
    %% one flush. But only while the residue stays escape-ambiguous: a non-ESC
    %% residue (a split UTF-8 character, e.g. the `<utf8-lead>' left by `ESC [
    %% <utf8-lead>' whose continuation is still in flight) must stay buffered, never
    %% forced onto the escape timeout, or its tail bytes would be lost to
    %% replacement characters (the documented split-UTF-8 rule, see awaiting_escape/1).
    {Events, St} = parse(Rest, new()),
    {More, St2} =
        case awaiting_escape(St) of
            true -> flush(St);
            false -> {[], St}
        end,
    {[{key, esc, []} | Events ++ More], St2};
flush({input, <<_Byte, Rest/binary>>}) ->
    %% Truncated multi-byte UTF-8 (or a stray continuation byte) at flush time:
    %% surface one replacement character and continue with the remainder.
    {Events, St} = parse(Rest, new()),
    {[{key, {char, ?REPLACEMENT}, []} | Events], St};
%% A paste whose closing bracket never arrived (the terminal fell silent
%% mid-paste): the driver does not flush a paste — {@link awaiting_escape/1} is
%% false for it, so an idle read just keeps buffering — but flush stays total, so
%% surface whatever was collected best-effort rather than stranding it. An empty
%% paste buffer resolves to nothing.
flush({paste, <<>>}) ->
    {[], new()};
flush({paste, Buf}) ->
    {[{paste, Buf}], new()}.

%%% -- decode loop -----------------------------------------------------
%%
%% decode/2 walks the buffer one event at a time (decode_step/1), prepending
%% complete events to an accumulator (reversed, un-reversed by parse/2). It stops
%% at the first byte boundary that could still grow into a longer sequence,
%% handing the whole unconsumed `Bin' back to be buffered.

-spec decode(binary(), [event()]) -> {[event()], state()}.
decode(Bin, Acc) ->
    case decode_step(Bin) of
        done -> {Acc, {input, <<>>}};
        incomplete -> {Acc, {input, Bin}};
        {emit, Event, Rest} -> decode(Rest, [Event | Acc]);
        {skip, Rest} -> decode(Rest, Acc);
        %% ESC [ 200 ~ opened a bracketed paste: everything up to the closing
        %% ESC [ 201 ~ is literal text, so switch to paste collection.
        {paste_start, Rest} -> collect_paste(Rest, Acc)
    end.

%% Accumulate the literal bytes of a bracketed paste until the `ESC [ 201 ~'
%% terminator appears anywhere in the buffer, then emit them as one `{paste, _}'
%% event and resume normal decoding of whatever trailed the terminator. Until the
%% terminator lands the whole run stays buffered as `{paste, _}' state — never
%% emitted piecemeal and never re-decoded as keys — so a paste split across reads,
%% or one carrying escape/control bytes, is delivered verbatim and whole.
-spec collect_paste(binary(), [event()]) -> {[event()], state()}.
collect_paste(Bin, Acc) ->
    case binary:match(Bin, ?PASTE_END) of
        {Start, Len} ->
            <<Content:Start/binary, _Term:Len/binary, Rest/binary>> = Bin,
            decode(Rest, [{paste, Content} | Acc]);
        nomatch ->
            {Acc, {paste, Bin}}
    end.

%% Decode exactly one event from the front of the buffer. `incomplete' means the
%% buffer is a genuine prefix of a longer sequence (lone ESC, half CSI, partial
%% UTF-8) and the caller should buffer it whole; `skip' consumed bytes without
%% producing an event (a recognised-but-ignored sequence); `paste_start' consumed
%% an `ESC [ 200 ~' and hands the rest to paste collection.
-type step() ::
    done
    | incomplete
    | {emit, event(), binary()}
    | {skip, binary()}
    | {paste_start, binary()}.

-spec decode_step(binary()) -> step().
decode_step(<<>>) ->
    done;
%% --- ESC-introduced sequences ---
%% Trailing lone ESC: cannot yet tell Escape / CSI / SS3 / Alt apart. Buffer it.
decode_step(<<16#1B>>) ->
    incomplete;
decode_step(<<16#1B, $[, Rest/binary>>) ->
    csi_step(Rest);
decode_step(<<16#1B, $O, Rest/binary>>) ->
    ss3_step(Rest);
%% --- ESC ESC: metaSendsEscape Alt-modified escape-sequence keys ---
%% A `metaSendsEscape' terminal prefixes an extra ESC to encode an Alt-modified
%% escape-sequence KEY, so Alt+Up is `ESC ESC [ A' (vs the mainstream CSI modifier
%% form `ESC [ 1 ; 3 A', matched above). Fold the leading ESC into an `alt' on the
%% key the inner CSI/SS3 decodes to. By bytes alone this is indistinguishable from
%% Escape then Up; timing tells them apart (see the module doc): the driver's
%% escape window covers a metaSendsEscape burst, but a real Escape-then-Up flushes
%% the first ESC to an Escape key before the arrow arrives. Crucially metaSendsEscape
%% only prefixes KEYS: if the inner sequence is a mouse report, a bracketed-paste
%% opener, or an ignored CSI, the leading ESC is instead a genuine Escape typed just
%% before it — meta_esc/2 emits that Escape and decodes the sequence unmodified.
decode_step(<<16#1B, 16#1B>>) ->
    %% Bare `ESC ESC': cannot yet tell Alt+<escape-seq-key> (if a CSI/SS3 follows)
    %% from a double-Escape (if nothing does). Buffer and let timing decide — on
    %% flush it resolves to two Escapes, on `[ A' it becomes Alt+Up.
    incomplete;
decode_step(<<16#1B, 16#1B, $[, Rest/binary>>) ->
    meta_esc(csi_step(Rest), <<16#1B, $[, Rest/binary>>);
decode_step(<<16#1B, 16#1B, $O, Rest/binary>>) ->
    meta_esc(ss3_step(Rest), <<16#1B, $O, Rest/binary>>);
decode_step(<<16#1B, 16#1B, Rest/binary>>) ->
    %% `ESC ESC' followed by a non-introducer (another ESC, or a printable/control
    %% byte): the first ESC is a complete Escape. Emit it and keep the rest, which
    %% begins with the second ESC — a triple-Escape tail (`ESC ESC ESC' -> Escape
    %% then a buffered `ESC ESC') or an ESC-prefixed Alt+printable (`ESC ESC a' ->
    %% Escape then Alt+a, since printable Alt is already the single `ESC a' and the
    %% extra leading ESC is a separate Escape key).
    {emit, {key, esc, []}, <<16#1B, Rest/binary>>};
decode_step(<<16#1B, Rest/binary>>) ->
    %% ESC + a non-introducer byte: Alt-modified key. Decode that following key
    %% (which may itself be multi-byte UTF-8) and fold `alt' into its modifiers.
    alt_step(Rest);
%% --- control bytes ---
decode_step(<<$\r, Rest/binary>>) ->
    {emit, {key, enter, []}, Rest};
decode_step(<<$\n, Rest/binary>>) ->
    {emit, {key, enter, []}, Rest};
decode_step(<<$\t, Rest/binary>>) ->
    {emit, {key, tab, []}, Rest};
decode_step(<<16#7F, Rest/binary>>) ->
    {emit, {key, backspace, []}, Rest};
decode_step(<<16#08, Rest/binary>>) ->
    {emit, {key, backspace, []}, Rest};
decode_step(<<16#00, Rest/binary>>) ->
    {emit, {key, {ctrl, $@}, [ctrl]}, Rest};
decode_step(<<Byte, Rest/binary>>) when Byte >= 16#01, Byte =< 16#1A ->
    %% C0 control chord: 0x01->Ctrl-A .. 0x1A->Ctrl-Z (Tab/CR/LF handled above).
    {emit, {key, {ctrl, Byte - 1 + $a}, [ctrl]}, Rest};
decode_step(<<Byte, Rest/binary>>) when Byte >= 16#1C, Byte =< 16#1F ->
    %% 0x1C->Ctrl-\ 0x1D->Ctrl-] 0x1E->Ctrl-^ 0x1F->Ctrl-_
    {emit, {key, {ctrl, Byte - 16#1C + $\\}, [ctrl]}, Rest};
%% --- printable ASCII ---
decode_step(<<Byte, Rest/binary>>) when Byte >= 16#20, Byte =< 16#7E ->
    {emit, {key, {char, Byte}, []}, Rest};
%% --- UTF-8 multi-byte ---
decode_step(<<Byte, _/binary>> = All) when Byte >= 16#C2, Byte =< 16#F4 ->
    utf8_step(All);
%% --- stray UTF-8 continuation / overlong lead: emit replacement, resync ---
decode_step(<<_Byte, Rest/binary>>) ->
    {emit, {key, {char, ?REPLACEMENT}, []}, Rest}.

%% Decode the key following an ESC prefix and add `alt'. If that key is not yet
%% complete (partial UTF-8), the whole `ESC ...' stays buffered for the next read.
-spec alt_step(binary()) -> step().
alt_step(Rest) ->
    case decode_step(Rest) of
        {emit, Event, Rest1} -> {emit, add_mod(alt, Event), Rest1};
        {skip, Rest1} -> {skip, Rest1};
        _ -> incomplete
    end.

%% Resolve a metaSendsEscape `ESC ESC <seq>' from the inner CSI/SS3 decode. Only a
%% KEY carries the synthetic Alt — metaSendsEscape prefixes escape-sequence keys,
%% not mouse reports, pastes or unknown CSIs — so:
%%   - a decoded KEY takes `alt' and both escapes are consumed (Alt+Up, Alt+F5, ...);
%%   - an incomplete inner sequence keeps the whole `ESC ESC <seq>' buffered, since
%%     it may still complete into a key;
%%   - any NON-key outcome (a mouse report, a bracketed-paste opener, an ignored
%%     CSI) means the leading ESC is a standalone Escape key typed just before that
%%     sequence: emit the Escape and re-decode from the second ESC (`KeepFromEsc2'),
%%     so `ESC ESC [ 200 ~ ...' is Escape + paste, not a swallowed Escape. This
%%     keeps the pre-metaSendsEscape behaviour for those non-key paths.
-spec meta_esc(step(), binary()) -> step().
meta_esc({emit, {key, _, _} = Event, Rest}, _KeepFromEsc2) ->
    {emit, add_mod(alt, Event), Rest};
meta_esc(incomplete, _KeepFromEsc2) ->
    incomplete;
meta_esc(_NonKey, KeepFromEsc2) ->
    {emit, {key, esc, []}, KeepFromEsc2}.

%%% -- CSI: ESC [ params intermediates final -------------------------------
%%
%% `Bin' is everything after the `ESC ['; if the final byte has not arrived we
%% report `incomplete' so decode/2 buffers the whole sequence.

-spec csi_step(binary()) -> step().
%% SGR mouse (`?1006') is validated from its RAW bytes (see sgr_mouse_step/1),
%% before split_csi/2 could strip an intermediate byte (0x20-0x2F) out of a
%% malformed field. The leading `<' private marker is unique to this encoding, so
%% any `<'-introduced CSI is routed here rather than through the key clauses.
csi_step(<<$<, Rest/binary>>) ->
    sgr_mouse_step(Rest);
csi_step(Bin) ->
    case split_csi(Bin, <<>>) of
        incomplete ->
            incomplete;
        {Params, Final, Rest} ->
            case csi_event(Params, Final) of
                ignore -> {skip, Rest};
                paste_start -> {paste_start, Rest};
                Event -> {emit, Event, Rest}
            end
    end.

%% Accumulate parameter (0x30-0x3F) and intermediate (0x20-0x2F) bytes up to the
%% final byte (0x40-0x7E). Parameters are kept; intermediates are dropped (none
%% are meaningful for the key set).
-spec split_csi(binary(), binary()) ->
    incomplete | {binary(), byte(), binary()}.
split_csi(<<C, Rest/binary>>, Params) when C >= 16#30, C =< 16#3F ->
    split_csi(Rest, <<Params/binary, C>>);
split_csi(<<C, Rest/binary>>, Params) when C >= 16#20, C =< 16#2F ->
    split_csi(Rest, Params);
split_csi(<<Final, Rest/binary>>, Params) when Final >= 16#40, Final =< 16#7E ->
    {Params, Final, Rest};
split_csi(_, _) ->
    incomplete.

%% Decode an SGR mouse report from the bytes after `ESC [ <'. The parameters are
%% collected VERBATIM up to the final byte (scan_to_final/2, which unlike
%% split_csi/2 keeps intermediates), so a stray intermediate in a field — e.g. the
%% `-' in `ESC[<0;-1;20M', which split_csi/2 would silently drop to leave a
%% passing `1' — is seen and rejected. A `M'/`m' final gives press vs release; any
%% other final, or params that are not exactly three digit fields with 1-based
%% coordinates, is consumed and dropped.
-spec sgr_mouse_step(binary()) -> step().
sgr_mouse_step(Bin) ->
    case scan_to_final(Bin, <<>>) of
        incomplete ->
            incomplete;
        {Raw, Final, Rest} when Final =:= $M; Final =:= $m ->
            case sgr_mouse_params(Raw) of
                {ok, Cb, Cx, Cy} -> {emit, mouse_event(Cb, {Cx, Cy}, Final), Rest};
                error -> {skip, Rest}
            end;
        {_Raw, _Final, Rest} ->
            {skip, Rest}
    end.

%% Collect the raw parameter/intermediate bytes (the whole 0x20-0x3F range) of a
%% CSI up to its final byte (0x40-0x7E), keeping every byte verbatim so a strict
%% validator can inspect them. Mirrors split_csi/2's byte-class boundaries — a
%% byte outside those ranges (a control byte, a truncated read) is `incomplete' —
%% differing only in that it does not discard intermediates.
-spec scan_to_final(binary(), binary()) -> incomplete | {binary(), byte(), binary()}.
scan_to_final(<<Final, Rest/binary>>, Acc) when Final >= 16#40, Final =< 16#7E ->
    {Acc, Final, Rest};
scan_to_final(<<C, Rest/binary>>, Acc) when C >= 16#20, C =< 16#3F ->
    scan_to_final(Rest, <<Acc/binary, C>>);
scan_to_final(_, _) ->
    incomplete.

%% Map a decoded CSI (parameter bytes + final byte) to an event. `paste_start'
%% signals an opening bracketed-paste marker (handled specially by the caller);
%% unknown sequences resolve to `ignore' and are consumed without emitting.
%% (SGR mouse reports — the `<'-introduced CSIs — never reach here: csi_step/1
%% routes them to sgr_mouse_step/1 for raw-byte validation before split_csi/2.)
-spec csi_event(binary(), byte()) -> event() | ignore | paste_start.
csi_event(Params, Final) when Final >= $A, Final =< $D; Final =:= $H; Final =:= $F ->
    {key, arrow_or_edge(Final), csi_mods(Params)};
%% Modified F1-F4 arrive as CSI `ESC [ 1 ; M P/Q/R/S' (e.g. Shift-F1 = ESC[1;2P);
%% unmodified F1-F4 come as SS3 (ss3_key/1). Only the key-number/modifier form is
%% a key, so require a leading `1' parameter. This excludes the Cursor Position
%% Report (`ESC [ row ; col R', the DSR reply capability probing reads, e.g.
%% ESC[24;80R) whose first parameter is the row — so a CPR is never a keypress.
%% (An unsolicited CPR with row 1 would be byte-identical to a modified F3, but
%% CPR only arrives in reply to a DSR the probe issues out-of-band, not through
%% this key path.)
csi_event(Params, Final) when Final =:= $P; Final =:= $Q; Final =:= $R; Final =:= $S ->
    case csi_numbers(Params) of
        [1, M | _] -> {key, csi_fkey(Final), decode_mods(M)};
        _ -> ignore
    end;
%% Back-tab (Shift-Tab): `ESC [ Z' (terminfo kcbt), emitted by xterm/screen/tmux
%% for reverse focus navigation.
csi_event(_Params, $Z) ->
    {key, tab, [shift]};
csi_event(Params, $~) ->
    case csi_numbers(Params) of
        [] ->
            ignore;
        %% Bracketed paste (`?2004') open marker; the matching `ESC [ 201 ~' close
        %% is handled inside paste collection, so a stray close here (no paste in
        %% progress) is simply ignored.
        [?PASTE_START_NUM] ->
            paste_start;
        [?PASTE_END_NUM] ->
            ignore;
        [Num | Tail] ->
            case tilde_key(Num) of
                ignore -> ignore;
                Named -> {key, Named, mods_from(Tail)}
            end
    end;
csi_event(_Params, _Final) ->
    ignore.

%% Final byte of a modified CSI F1-F4 sequence (`ESC [ 1 ; M P/Q/R/S').
-spec csi_fkey(byte()) -> named().
csi_fkey($P) -> {f, 1};
csi_fkey($Q) -> {f, 2};
csi_fkey($R) -> {f, 3};
csi_fkey($S) -> {f, 4}.

-spec arrow_or_edge(byte()) -> named().
arrow_or_edge($A) -> up;
arrow_or_edge($B) -> down;
arrow_or_edge($C) -> right;
arrow_or_edge($D) -> left;
arrow_or_edge($H) -> home;
arrow_or_edge($F) -> 'end'.

%%% -- SGR mouse (?1006) ---------------------------------------------------
%%
%% Build a mouse event from the decoded `Cb' bitfield, the 1-based `{Col, Row}'
%% and the final byte. `Cb' packs three things: the low bits select the button
%% (with high bits switching to the wheel or the extended 8-11 range), bit 5 is a
%% motion flag, and bits 2-4 are the shift/meta/ctrl modifiers.

-spec mouse_event(integer(), {pos_integer(), pos_integer()}, byte()) -> mouse_event().
mouse_event(Cb, Pos, Final) ->
    {mouse, mouse_action(Cb, Final), mouse_button(Cb), Pos, mouse_mods(Cb)}.

%% Press (`M') vs release (`m'); a press with the motion bit (32) set is a drag —
%% a button held while the pointer moves, or (under all-motion tracking) a plain
%% buttonless move.
-spec mouse_action(integer(), byte()) -> mouse_action().
mouse_action(_Cb, $m) -> release;
mouse_action(Cb, $M) when Cb band 32 =/= 0 -> drag;
mouse_action(_Cb, $M) -> press.

%% The button `Cb' names. Bit 6 (64) switches the low two bits to the wheel;
%% bit 7 (128) switches them to the extended buttons 8-11; otherwise the low two
%% bits are the primary buttons, with code 3 the buttonless/legacy-release marker.
-spec mouse_button(integer()) -> mouse_button().
mouse_button(Cb) when Cb band 64 =/= 0 -> wheel_button(Cb band 3);
mouse_button(Cb) when Cb band 128 =/= 0 -> {button, 8 + (Cb band 3)};
mouse_button(Cb) -> low_button(Cb band 3).

-spec wheel_button(0..3) -> mouse_button().
wheel_button(0) -> wheel_up;
wheel_button(1) -> wheel_down;
wheel_button(2) -> wheel_left;
wheel_button(3) -> wheel_right.

-spec low_button(0..3) -> mouse_button().
low_button(0) -> left;
low_button(1) -> middle;
low_button(2) -> right;
low_button(3) -> none.

%% The held modifiers `Cb' carries: Shift (4), Meta (8) and Ctrl (16). xterm names
%% bit 8 "Meta"; it maps to `meta' here, matching how {@link decode_mods/1} treats
%% the same bit on the key path.
-spec mouse_mods(integer()) -> [mod()].
mouse_mods(Cb) ->
    [shift || Cb band 4 =/= 0] ++
        [meta || Cb band 8 =/= 0] ++
        [ctrl || Cb band 16 =/= 0].

%% Parse the three SGR mouse parameters strictly from the RAW `Cb ; Cx ; Cy'
%% bytes (sgr_mouse_step/1 passes them verbatim, intermediates included). All
%% three fields must be present digit runs, and the coordinates are 1-based, so an
%% omitted/non-numeric field or a coordinate below 1 is a malformed report and
%% rejected — it must not surface a spurious event at a bogus cell. Button 0 is a
%% legitimate code (the left button), so only the coordinates are range-checked.
-spec sgr_mouse_params(binary()) ->
    {ok, non_neg_integer(), pos_integer(), pos_integer()} | error.
sgr_mouse_params(Params) ->
    case binary:split(Params, <<";">>, [global]) of
        [CbBin, CxBin, CyBin] ->
            case {field_int(CbBin), field_int(CxBin), field_int(CyBin)} of
                {{ok, Cb}, {ok, Cx}, {ok, Cy}} when Cx >= 1, Cy >= 1 ->
                    {ok, Cb, Cx, Cy};
                _ ->
                    error
            end;
        _ ->
            error
    end.

%% One CSI parameter field parsed strictly into a non-negative integer: it must
%% be a non-empty run of ASCII digits. Anything else is an error — an empty field
%% (unlike the 0 {@link to_int/1} coerces to), but also a sign or a stray CSI
%% intermediate byte (`-'/`.'/space), which `binary_to_integer/1' alone might
%% accept or which split_csi/2 would have silently stripped. So a malformed mouse
%% field is rejected rather than coerced to a passing value.
-spec field_int(binary()) -> {ok, non_neg_integer()} | error.
field_int(<<>>) ->
    error;
field_int(Bin) ->
    case all_digits(Bin) of
        true -> {ok, binary_to_integer(Bin)};
        false -> error
    end.

%% Whether every byte of `Bin' is an ASCII digit (0x30-0x39). Empty is vacuously
%% true; field_int/1 rules the empty field out before calling this.
-spec all_digits(binary()) -> boolean().
all_digits(<<>>) -> true;
all_digits(<<D, Rest/binary>>) when D >= $0, D =< $9 -> all_digits(Rest);
all_digits(<<_, _/binary>>) -> false.

%% `ESC [ N ~' navigation / function keys (xterm & rxvt numbering).
-spec tilde_key(integer()) -> named() | ignore.
tilde_key(1) -> home;
tilde_key(2) -> insert;
tilde_key(3) -> delete;
tilde_key(4) -> 'end';
tilde_key(5) -> page_up;
tilde_key(6) -> page_down;
tilde_key(7) -> home;
tilde_key(8) -> 'end';
tilde_key(11) -> {f, 1};
tilde_key(12) -> {f, 2};
tilde_key(13) -> {f, 3};
tilde_key(14) -> {f, 4};
tilde_key(15) -> {f, 5};
tilde_key(17) -> {f, 6};
tilde_key(18) -> {f, 7};
tilde_key(19) -> {f, 8};
tilde_key(20) -> {f, 9};
tilde_key(21) -> {f, 10};
tilde_key(23) -> {f, 11};
tilde_key(24) -> {f, 12};
tilde_key(_) -> ignore.

%%% -- SS3: ESC O final ----------------------------------------------------

-spec ss3_step(binary()) -> step().
ss3_step(<<>>) ->
    incomplete;
ss3_step(<<Final, Rest/binary>>) ->
    case ss3_key(Final) of
        ignore -> {skip, Rest};
        Named -> {emit, {key, Named, []}, Rest}
    end.

-spec ss3_key(byte()) -> named() | ignore.
ss3_key($A) -> up;
ss3_key($B) -> down;
ss3_key($C) -> right;
ss3_key($D) -> left;
ss3_key($H) -> home;
ss3_key($F) -> 'end';
ss3_key($P) -> {f, 1};
ss3_key($Q) -> {f, 2};
ss3_key($R) -> {f, 3};
ss3_key($S) -> {f, 4};
%% Keypad Enter in application-keypad mode: `ESC O M' (terminfo kent). Same event
%% as the main Enter key so both keyboard sources behave alike.
ss3_key($M) -> enter;
ss3_key(_) -> ignore.

%%% -- UTF-8 ---------------------------------------------------------------
%%
%% Decode one code point. A lead byte with too few continuation bytes present is
%% treated as incomplete and the whole run is buffered for the next read; an
%% invalid encoding surfaces a replacement character and consumes the lead byte.

-spec utf8_step(binary()) -> step().
utf8_step(All) ->
    Need = utf8_len(binary:first(All)),
    <<_Lead, AfterLead/binary>> = All,
    case All of
        <<CP/utf8, Rest/binary>> when byte_size(All) - byte_size(Rest) =:= Need ->
            {emit, {key, {char, CP}, []}, Rest};
        _ when byte_size(All) < Need ->
            case continuations_ok(AfterLead) of
                true ->
                    %% Every byte after the lead is a valid continuation so far —
                    %% a genuine prefix of a longer character. Wait for the rest.
                    incomplete;
                false ->
                    %% A non-continuation byte is already present, so this can
                    %% never become valid however many bytes follow. Don't buffer
                    %% (the driver won't flush a non-ESC partial, which would
                    %% strand the following bytes): emit one replacement and
                    %% resync at the next byte immediately.
                    {emit, {key, {char, ?REPLACEMENT}, []}, AfterLead}
            end;
        _ ->
            %% Enough bytes but not valid UTF-8: resync past the lead byte.
            {emit, {key, {char, ?REPLACEMENT}, []}, AfterLead}
    end.

%% Whether every byte present is a UTF-8 continuation byte (0x80..0xBF), i.e. the
%% run could still grow into a valid multi-byte character.
-spec continuations_ok(binary()) -> boolean().
continuations_ok(<<>>) ->
    true;
continuations_ok(<<B, Rest/binary>>) when B >= 16#80, B =< 16#BF ->
    continuations_ok(Rest);
continuations_ok(_) ->
    false.

-spec utf8_len(byte()) -> 2..4.
utf8_len(B) when B >= 16#F0 -> 4;
utf8_len(B) when B >= 16#E0 -> 3;
utf8_len(_) -> 2.

%%% -- modifiers -----------------------------------------------------------

%% Arrows/edges carry modifiers as `1 ; M' (the leading `1' is the key number).
-spec csi_mods(binary()) -> [mod()].
csi_mods(Params) ->
    case csi_numbers(Params) of
        [_Key, M | _] -> decode_mods(M);
        _ -> []
    end.

%% Tilde sequences carry modifiers as the parameters after the key number.
-spec mods_from([integer()]) -> [mod()].
mods_from([M | _]) -> decode_mods(M);
mods_from([]) -> [].

%% The xterm modifier parameter is 1 + a bitmask (1 = none, 2 = Shift,
%% 3 = Alt, 5 = Ctrl, ...). Decode the bitmask into an ordered atom list.
-spec decode_mods(integer()) -> [mod()].
decode_mods(M) when M >= 1 ->
    Bits = M - 1,
    [shift || Bits band 1 =/= 0] ++
        [alt || Bits band 2 =/= 0] ++
        [ctrl || Bits band 4 =/= 0] ++
        [meta || Bits band 8 =/= 0];
decode_mods(_) ->
    [].

-spec add_mod(mod(), event()) -> event().
add_mod(Mod, {key, Key, Mods}) ->
    {key, Key, lists:usort([Mod | Mods])}.

%% Parse `;'-separated CSI parameters into integers; an empty field defaults
%% to 0 (xterm's convention for an omitted parameter).
-spec csi_numbers(binary()) -> [integer()].
csi_numbers(<<>>) ->
    [];
csi_numbers(Params) ->
    [to_int(Field) || Field <- binary:split(Params, <<";">>, [global])].

-spec to_int(binary()) -> integer().
to_int(<<>>) ->
    0;
to_int(Bin) ->
    try
        binary_to_integer(Bin)
    catch
        error:badarg -> 0
    end.
