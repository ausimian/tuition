%%%-------------------------------------------------------------------
%%% @doc Terminal capability probing (PRD §8).
%%%
%%% Sonde assumes a hardcoded modern xterm/ECMA-48 baseline — cursor
%%% addressing, SGR, the alternate screen, screen clear — unconditionally.
%%% On top of that baseline it probes, at startup, for a handful of *optional*
%%% enrichments by writing query sequences to the terminal and reading the
%%% replies back off the input stream (clean to do now that raw mode delivers
%%% input verbatim). A terminal that does not support a feature simply stays
%%% silent for that query, so a missing reply degrades the capability to off.
%%%
%%% == Mechanism ==
%%% {@link probe/2} writes every query in one burst, then a Primary Device
%%% Attributes request (`ESC [ c'). Terminals answer queries in order, so the DA1
%%% reply — `ESC [ ? ... c' — acts as a sentinel: once it arrives, every
%%% supported query has already answered and every unsupported one has stayed
%%% silent. The read loop therefore stops at the DA1 reply (or a read timeout,
%%% whichever comes first) rather than waiting the full timeout per capability.
%%%
%%% DA1 is used as the sentinel rather than a Device Status Report because a
%%% DSR's Cursor Position Report (`ESC [ row ; col R') is byte-identical to a
%%% modified F3 keypress (`ESC [ 1 ; 2 R'): a CPR sentinel could be ended early
%%% by such a keystroke arriving mid-probe, leaving the real capability replies
%%% queued for the input parser to misread. A DA1 reply (`ESC [ ? ... c') cannot
%%% collide with any key sequence.
%%%
%%% The queries used:
%%% <ul>
%%%   <li><b>truecolor</b> — set an RGB foreground (`ESC [ 38 ; 2 ; 1 ; 2 ; 3 m')
%%%       then read the active SGR back with DECRQSS (`DCS $ q m ST'). A terminal
%%%       that really stored the 24-bit colour echoes the RGB triple; a
%%%       256-colour-only terminal does not.</li>
%%%   <li><b>synchronized output</b> (`?2026'), <b>bracketed paste</b> (`?2004')
%%%       and <b>SGR mouse</b> (`?1006') — DECRQM (`ESC [ ? mode $ p'), whose
%%%       reply (`ESC [ ? mode ; value $ y') reports the mode as recognised with
%%%       any non-zero value.</li>
%%%   <li><b>kitty keyboard</b> — the progressive-enhancement flags query
%%%       (`ESC [ ? u'); a supporting terminal replies `ESC [ ? flags u'.</li>
%%% </ul>
%%%
%%% == Purity ==
%%% Reply decoding ({@link parse_replies/1}) is a pure function of the reply
%%% bytes, independent of any process or timer, so it is exhaustively testable
%%% against fixtures. Only {@link probe/2} touches the terminal seam.
%%%
%%% HARD CONSTRAINT (PRD §12): depends only on `kernel'/`stdlib'/`erts' (plus the
%%% sibling {@link tuition_term} seam). No third-party code.
%%% @end
%%%-------------------------------------------------------------------
-module(tuition_caps).

-include("tuition_caps.hrl").

-export([
    baseline/0, probe/1, probe/2, resolve/2, parse_replies/1, decode_replies/1, apply_colorterm/2
]).

-type caps() :: #caps{}.
-export_type([caps/0]).

%% Default inter-read window for the probe. The DA1 sentinel normally ends the
%% read promptly; this bounds the wait when a terminal answers nothing at all.
-define(DEFAULT_TIMEOUT, 100).

%% All query sequences plus the DA1 sentinel, written in one burst. The truecolor
%% probe resets SGR (`ESC [ 0 m') both before the set — so no pre-existing
%% attribute can leak into the DECRQSS read-back — and after reading it back, so
%% no colour leaks into the first frame.
-define(QUERIES, <<
    %% truecolor: reset SGR, set RGB(1,2,3), read the active SGR back, reset again.
    "\e[0m",
    "\e[38;2;1;2;3m",
    "\eP$qm\e\\",
    "\e[0m",
    %% DECRQM for the DEC private modes.
    "\e[?2026$p",
    "\e[?2004$p",
    "\e[?1006$p",
    %% kitty keyboard progressive-enhancement flags.
    "\e[?u",
    %% sentinel: DA1 (`ESC [ c') -> `ESC [ ? ... c' marks the end of the replies.
    %% DA1 rather than DSR because a DSR's CPR reply is byte-identical to a
    %% modified F3 keypress and could end the read early.
    "\e[c"
>>).

%%% -- API -------------------------------------------------------------

%% @doc The always-assumed baseline: every optional enrichment off. This is what
%% a probe degrades to when the terminal answers nothing, and the safe default
%% for a backend that has no probing channel.
-spec baseline() -> caps().
baseline() -> #caps{}.

%% @doc As {@link probe/2} with the default read timeout.
-spec probe(tuition_term:handle()) -> {caps(), binary()}.
probe(Handle) -> probe(Handle, ?DEFAULT_TIMEOUT).

%% @doc Probe `Handle' for the optional capabilities and return `{Caps, Residue}':
%% the capability set, plus any non-reply bytes read during the probe window — a
%% key the user pressed before the terminal answered, or a truncated escape tail.
%% Writes the queries, reads replies until the DA1 sentinel or a read timeout,
%% then decodes them ({@link decode_replies/1}). A write failure, or a terminal
%% that answers nothing, yields the {@link baseline/0} set — never an error. The
%% residue is handed back so the host can replay it into the input stream instead
%% of swallowing the keystroke; see {@link decode_replies/1} for which bytes survive.
-spec probe(tuition_term:handle(), timeout()) -> {caps(), binary()}.
probe(Handle, Timeout) ->
    case tuition_term:write(Handle, ?QUERIES) of
        ok -> decode_replies(read_until_sentinel(Handle, Timeout, <<>>));
        {error, _} -> {baseline(), <<>>}
    end.

%% @doc Resolve a capability set for a host from its option map, probing the
%% terminal only when neither an explicit profile nor an opt-out is given. This is
%% the hook a host threads through so a backend that cannot answer the interactive
%% probe can skip it: on an asynchronous or high-latency transport the query
%% round-trip overruns the read window ({@link probe/2}'s), so the probe both fails
%% <em>and</em> corrupts input — late replies arrive after the loop starts and, in
%% the case of the DECRQSS truecolor read-back (a DCS, byte-identical to an
%% `Alt'+`Shift'+`P' keystroke), decode as a burst of fake keys. Returns
%% `{Caps, Residue}' in the same shape as {@link probe/2}:
%%
%% <ul>
%%   <li>`#{caps := Caps}' — use that profile verbatim; no queries are written and
%%       the residue is empty.</li>
%%   <li>`#{probe := false}' — skip the probe and use {@link baseline/0}; again no
%%       queries and an empty residue.</li>
%%   <li>otherwise — {@link probe/1} the terminal (the default). An explicit `caps'
%%       wins over `probe', which wins over the probe default.</li>
%% </ul>
%%
%% When probing is skipped <em>no</em> terminal queries are emitted, so no stray
%% reply can be injected as input. The `COLORTERM' env fold stays the host's job
%% (see {@link apply_colorterm/2}), layered on top of a probed or baseline result
%% but not a caller-supplied one — the host's environment describes the host, not
%% the (possibly remote) terminal the caps were handed for.
-spec resolve(tuition_term:handle(), map()) -> {caps(), binary()}.
resolve(_Handle, #{caps := Caps}) ->
    {Caps, <<>>};
resolve(_Handle, #{probe := false}) ->
    {baseline(), <<>>};
resolve(Handle, _Opts) ->
    probe(Handle).

%% @doc Fold a `COLORTERM' environment value into a capability set. Some terminals
%% advertise 24-bit colour via `COLORTERM=truecolor'|`24bit' yet do not answer the
%% DECRQSS truecolor probe, so that env hint is taken as truecolor support. `false'
%% (the variable is unset) or any other value leaves the set unchanged, and it only
%% ever adds truecolor, never clears it. Kept here (beside the reply decoding) but
%% applied by the host, which owns the environment, on top of {@link probe/2} — so
%% `probe/2' itself stays a pure function of the terminal's replies.
-spec apply_colorterm(string() | false, caps()) -> caps().
apply_colorterm(Value, Caps) when Value =:= "truecolor"; Value =:= "24bit" ->
    Caps#caps{truecolor = true};
apply_colorterm(_Value, Caps) ->
    Caps.

%%% -- read loop -------------------------------------------------------

%% Accumulate reply bytes until the DA1 sentinel appears, or a read stops
%% delivering (timeout/error). The buffer gathered so far is always returned, so
%% partial replies still decode as far as they got.
-spec read_until_sentinel(tuition_term:handle(), timeout(), binary()) -> binary().
read_until_sentinel(Handle, Timeout, Acc) ->
    case tuition_term:read(Handle, Timeout) of
        {ok, Bytes} ->
            Acc1 = <<Acc/binary, Bytes/binary>>,
            case has_da_reply(Acc1) of
                true -> Acc1;
                false -> read_until_sentinel(Handle, Timeout, Acc1)
            end;
        timeout ->
            Acc;
        {error, _} ->
            Acc
    end.

%% Whether a Primary Device Attributes reply (`ESC [ ? digits/`;' c') appears
%% anywhere in the buffer. Unlike a DSR's Cursor Position Report — which is
%% byte-identical to a modified F3 keypress (`ESC [ 1 ; 2 R') — the DA1 reply's
%% leading `?' and `c' final cannot collide with any key sequence, so it stays an
%% unambiguous end-of-replies marker even if a keystroke arrives mid-probe.
-spec has_da_reply(binary()) -> boolean().
has_da_reply(<<16#1B, $[, $?, Rest/binary>>) ->
    da_tail(Rest) orelse has_da_reply(Rest);
has_da_reply(<<_, Rest/binary>>) ->
    has_da_reply(Rest);
has_da_reply(<<>>) ->
    false.

-spec da_tail(binary()) -> boolean().
da_tail(<<C, Rest/binary>>) when C >= $0, C =< $9 -> da_tail(Rest);
da_tail(<<$;, Rest/binary>>) -> da_tail(Rest);
da_tail(<<$c, _/binary>>) -> true;
da_tail(_) -> false.

%%% -- reply decoding --------------------------------------------------

%% @doc Decode a buffer of terminal replies into `{Caps, Residue}': the
%% capability set, plus the bytes that were <em>not</em> part of a terminal
%% reply. Recognised (and ignored-but-complete) CSI and DCS responses — the
%% DECRQM/DECRQSS/kitty replies and the DA1 sentinel — set their capability and
%% are consumed. Two kinds of byte survive as residue instead: a stray byte that
%% does not begin a response we recognise (a plain key the user pressed during
%% the probe window), and a trailing <em>incomplete</em> DCS/CSI (a partial escape
%% at the tail). A <em>complete</em> CSI/DCS is always consumed as a reply, even
%% when its final is one we ignore: a real arrow-key pressed mid-probe is
%% byte-for-byte a CSI and cannot be told apart from a genuine reply, and
%% mis-feeding a real reply back to the input parser would be worse than dropping
%% the rare mid-probe arrow-key. Pure — the whole point is testability without a
%% terminal.
-spec decode_replies(binary()) -> {caps(), binary()}.
decode_replies(Bin) -> parse(Bin, #caps{}, <<>>).

%% @doc Decode replies into just the capability set, discarding the residue. The
%% reply-only view; {@link decode_replies/1} additionally surfaces the residue.
-spec parse_replies(binary()) -> caps().
parse_replies(Bin) -> element(1, decode_replies(Bin)).

-spec parse(binary(), caps(), binary()) -> {caps(), binary()}.
parse(<<>>, Caps, Res) ->
    {Caps, Res};
parse(<<16#1B, $P, Rest/binary>>, Caps, Res) ->
    %% DCS ... ST — the DECRQSS SGR read-back (truecolor).
    case take_string(Rest) of
        {Payload, Rest1} -> parse(Rest1, apply_dcs(Payload, Caps), Res);
        %% Truncated tail: keep the whole partial escape as residue and stop.
        incomplete -> {Caps, <<Res/binary, 16#1B, $P, Rest/binary>>}
    end;
parse(<<16#1B, $[, Rest/binary>>, Caps, Res) ->
    %% CSI — DECRQM replies, the kitty reply, or the DA1 sentinel.
    case take_csi(Rest) of
        {Prefix, Final, Rest1} -> parse(Rest1, apply_csi(Prefix, Final, Caps), Res);
        %% Truncated tail: keep the whole partial escape as residue and stop.
        incomplete -> {Caps, <<Res/binary, 16#1B, $[, Rest/binary>>}
    end;
parse(<<C, Rest/binary>>, Caps, Res) ->
    %% Not the start of a response we recognise — a stray/user byte. Keep it as
    %% residue and resync at the next byte.
    parse(Rest, Caps, <<Res/binary, C>>).

%% Consume a control-string body up to its terminator: ST (`ESC \') or, for
%% terminals that use it, BEL. Returns the body and the remainder, or
%% `incomplete' if the string was truncated.
-spec take_string(binary()) -> {binary(), binary()} | incomplete.
take_string(Bin) -> take_string(Bin, <<>>).

take_string(<<16#1B, $\\, Rest/binary>>, Acc) -> {Acc, Rest};
take_string(<<16#07, Rest/binary>>, Acc) -> {Acc, Rest};
take_string(<<C, Rest/binary>>, Acc) -> take_string(Rest, <<Acc/binary, C>>);
take_string(<<>>, _Acc) -> incomplete.

%% Split a CSI body into its parameter+intermediate prefix (bytes 0x20-0x3F, so
%% `?', digits, `;' and `$' are all kept) and its final byte (0x40-0x7E).
-spec take_csi(binary()) -> {binary(), byte(), binary()} | incomplete.
take_csi(Bin) -> take_csi(Bin, <<>>).

take_csi(<<C, Rest/binary>>, Acc) when C >= 16#20, C =< 16#3F ->
    take_csi(Rest, <<Acc/binary, C>>);
take_csi(<<Final, Rest/binary>>, Acc) when Final >= 16#40, Final =< 16#7E ->
    {Acc, Final, Rest};
take_csi(_, _) ->
    incomplete.

%% A DCS payload sets truecolor only when it is a *valid* DECRQSS reply (`1 $ r'
%% prefix) that echoed back the RGB triple we set. Anything else (an invalid
%% `0 $ r', or an unrelated DCS) leaves caps untouched.
-spec apply_dcs(binary(), caps()) -> caps().
apply_dcs(<<"1$r", Sgr/binary>>, Caps) ->
    case is_truecolor_sgr(Sgr) of
        true -> Caps#caps{truecolor = true};
        false -> Caps
    end;
apply_dcs(_Payload, Caps) ->
    Caps.

%% Did the read-back SGR contain the full RGB foreground the truecolor probe set?
%% Require the complete colour introducer — `38;2' / `38:2', including xterm's
%% empty colour-space form `38:2::…' — not just the bare `1;2;3' tail. A terminal
%% that does not support 24-bit colour may misparse the probe `38;2;1;2;3' as
%% separate SGR attributes (bold;faint;italic) and echo that tail on its own; the
%% introducer is what distinguishes a genuinely stored RGB foreground from that
%% false positive.
-spec is_truecolor_sgr(binary()) -> boolean().
is_truecolor_sgr(Sgr) ->
    binary:match(Sgr, [<<"38;2;1;2;3">>, <<"38:2:1:2:3">>, <<"38:2::1:2:3">>]) =/= nomatch.

%% A CSI reply. `$ y' is a DECRQM report (`? mode ; value $'). Only a value that
%% the terminal can actually present enables the mode: 1 (set), 2 (reset) and 3
%% (permanently set) all mean the feature is usable, whereas 0 (not recognised)
%% and 4 (permanently reset — recognised but can never be enabled) leave it off.
%% `? ... u' is the kitty keyboard reply; everything else (the CPR, unknown
%% finals) is ignored.
-spec apply_csi(binary(), byte(), caps()) -> caps().
apply_csi(Prefix, $y, Caps) ->
    case decrqm(Prefix) of
        {Mode, Value} when Value >= 1, Value =< 3 -> set_mode(Mode, Caps);
        _ -> Caps
    end;
apply_csi(<<$?, _/binary>>, $u, Caps) ->
    Caps#caps{kitty_keyboard = true};
apply_csi(_Prefix, _Final, Caps) ->
    Caps.

%% Parse a DECRQM prefix `? mode ; value $' into {Mode, Value}, dropping the
%% leading private marker and trailing intermediate. `error' when it is not that
%% shape.
-spec decrqm(binary()) -> {integer(), integer()} | error.
decrqm(<<$?, Body0/binary>>) ->
    Body = strip_trailing_intermediates(Body0),
    case binary:split(Body, <<";">>) of
        [Mode, Value] ->
            case {to_int(Mode), to_int(Value)} of
                {{ok, M}, {ok, V}} -> {M, V};
                _ -> error
            end;
        _ ->
            error
    end;
decrqm(_Prefix) ->
    error.

-spec set_mode(integer(), caps()) -> caps().
set_mode(2026, Caps) -> Caps#caps{sync_output = true};
set_mode(2004, Caps) -> Caps#caps{bracketed_paste = true};
set_mode(1006, Caps) -> Caps#caps{sgr_mouse = true};
set_mode(_Mode, Caps) -> Caps.

%% Drop trailing CSI intermediate bytes (0x20-0x2F, e.g. the `$' of `$ y') so the
%% value field is left as bare digits.
-spec strip_trailing_intermediates(binary()) -> binary().
strip_trailing_intermediates(<<>>) ->
    <<>>;
strip_trailing_intermediates(Bin) ->
    Size = byte_size(Bin) - 1,
    case Bin of
        <<Head:Size/binary, C>> when C >= 16#20, C =< 16#2F ->
            strip_trailing_intermediates(Head);
        _ ->
            Bin
    end.

-spec to_int(binary()) -> {ok, integer()} | error.
to_int(Bin) ->
    try
        {ok, binary_to_integer(Bin)}
    catch
        error:badarg -> error
    end.
