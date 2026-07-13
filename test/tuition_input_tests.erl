-module(tuition_input_tests).

-include_lib("eunit/include/eunit.hrl").

%%% -- printable & control bytes ---------------------------------------

printable_ascii_test() ->
    ?assertEqual([{key, {char, $a}, []}], decode(<<"a">>)),
    ?assertEqual(
        [{key, {char, $h}, []}, {key, {char, $i}, []}],
        decode(<<"hi">>)
    ),
    ?assertEqual([{key, {char, $~}, []}], decode(<<"~">>)).

named_control_keys_test() ->
    ?assertEqual([{key, tab, []}], decode(<<$\t>>)),
    ?assertEqual([{key, enter, []}], decode(<<$\r>>)),
    ?assertEqual([{key, enter, []}], decode(<<$\n>>)),
    ?assertEqual([{key, backspace, []}], decode(<<16#7F>>)),
    ?assertEqual([{key, backspace, []}], decode(<<16#08>>)).

ctrl_chords_test() ->
    ?assertEqual([{key, {ctrl, $a}, [ctrl]}], decode(<<16#01>>)),
    ?assertEqual([{key, {ctrl, $z}, [ctrl]}], decode(<<16#1A>>)),
    ?assertEqual([{key, {ctrl, $@}, [ctrl]}], decode(<<16#00>>)),
    ?assertEqual([{key, {ctrl, $\\}, [ctrl]}], decode(<<16#1C>>)),
    ?assertEqual([{key, {ctrl, $_}, [ctrl]}], decode(<<16#1F>>)).

%%% -- CSI / SS3 escape sequences --------------------------------------

csi_arrows_test() ->
    ?assertEqual([{key, up, []}], decode(<<"\e[A">>)),
    ?assertEqual([{key, down, []}], decode(<<"\e[B">>)),
    ?assertEqual([{key, right, []}], decode(<<"\e[C">>)),
    ?assertEqual([{key, left, []}], decode(<<"\e[D">>)),
    ?assertEqual([{key, home, []}], decode(<<"\e[H">>)),
    ?assertEqual([{key, 'end', []}], decode(<<"\e[F">>)).

ss3_arrows_and_fkeys_test() ->
    ?assertEqual([{key, up, []}], decode(<<"\eOA">>)),
    ?assertEqual([{key, left, []}], decode(<<"\eOD">>)),
    ?assertEqual([{key, home, []}], decode(<<"\eOH">>)),
    ?assertEqual([{key, {f, 1}, []}], decode(<<"\eOP">>)),
    ?assertEqual([{key, {f, 4}, []}], decode(<<"\eOS">>)).

shift_tab_test() ->
    %% Back-tab (kcbt) is CSI Z.
    ?assertEqual([{key, tab, [shift]}], decode(<<"\e[Z">>)).

keypad_enter_test() ->
    %% Application-keypad Enter (kent) is SS3 M — same event as regular Enter.
    ?assertEqual([{key, enter, []}], decode(<<"\eOM">>)).

csi_tilde_navigation_test() ->
    ?assertEqual([{key, home, []}], decode(<<"\e[1~">>)),
    ?assertEqual([{key, insert, []}], decode(<<"\e[2~">>)),
    ?assertEqual([{key, delete, []}], decode(<<"\e[3~">>)),
    ?assertEqual([{key, 'end', []}], decode(<<"\e[4~">>)),
    ?assertEqual([{key, page_up, []}], decode(<<"\e[5~">>)),
    ?assertEqual([{key, page_down, []}], decode(<<"\e[6~">>)).

csi_tilde_fkeys_test() ->
    ?assertEqual([{key, {f, 5}, []}], decode(<<"\e[15~">>)),
    ?assertEqual([{key, {f, 6}, []}], decode(<<"\e[17~">>)),
    ?assertEqual([{key, {f, 12}, []}], decode(<<"\e[24~">>)).

modified_arrows_test() ->
    ?assertEqual([{key, up, [shift]}], decode(<<"\e[1;2A">>)),
    ?assertEqual([{key, right, [ctrl]}], decode(<<"\e[1;5C">>)),
    %% 1 + (shift|alt|ctrl bits) = 1 + 7 = 8
    ?assertEqual([{key, left, [shift, alt, ctrl]}], decode(<<"\e[1;8D">>)).

modified_tilde_test() ->
    ?assertEqual([{key, delete, [ctrl]}], decode(<<"\e[3;5~">>)),
    ?assertEqual([{key, page_up, [shift]}], decode(<<"\e[5;2~">>)).

unknown_sequences_are_ignored_test() ->
    %% A recognised-but-unmapped CSI (`ESC [ > 1 ; 2 c', a secondary-DA reply) —
    %% consumed, no event, no stall.
    ?assertEqual([], decode(<<"\e[>1;2c">>)),
    %% A printable after an ignored sequence still decodes.
    ?assertEqual([{key, {char, $x}, []}], decode(<<"\e[>0c", "x">>)).

cursor_position_report_is_ignored_test() ->
    %% CPR (the reply to DSR ESC[6n) is CSI `row;col R'; with a row parameter it
    %% is not the `1;M' function-key form, so it must not surface as an F3 key or
    %% steal the probe's reply. It is consumed silently, and a real key right
    %% after it still decodes.
    ?assertEqual([], decode(<<"\e[24;80R">>)),
    ?assertEqual([{key, {char, $a}, []}], decode(<<"\e[10;5R", "a">>)),
    %% A bare CSI P/Q/R/S (no `1;M' params) is not a key either — unmodified
    %% F1-F4 arrive as SS3.
    ?assertEqual([], decode(<<"\e[P">>)).

modified_csi_fkeys_test() ->
    %% Modified F1-F4 arrive as CSI `ESC [ 1 ; M P/Q/R/S'.
    ?assertEqual([{key, {f, 1}, [shift]}], decode(<<"\e[1;2P">>)),
    ?assertEqual([{key, {f, 2}, [alt]}], decode(<<"\e[1;3Q">>)),
    ?assertEqual([{key, {f, 3}, [ctrl]}], decode(<<"\e[1;5R">>)),
    ?assertEqual([{key, {f, 4}, [shift]}], decode(<<"\e[1;2S">>)).

%%% -- SGR mouse (?1006) -----------------------------------------------

sgr_mouse_press_and_release_test() ->
    %% `ESC [ < Cb ; Cx ; Cy M|m' — M is a press, m a release. Cx/Cy are 1-based
    %% and carried through verbatim (no legacy +32 offset).
    ?assertEqual([{mouse, press, left, {10, 20}, []}], decode(<<"\e[<0;10;20M">>)),
    ?assertEqual([{mouse, release, left, {10, 20}, []}], decode(<<"\e[<0;10;20m">>)).

sgr_mouse_buttons_test() ->
    ?assertEqual([{mouse, press, left, {1, 1}, []}], decode(<<"\e[<0;1;1M">>)),
    ?assertEqual([{mouse, press, middle, {1, 1}, []}], decode(<<"\e[<1;1;1M">>)),
    ?assertEqual([{mouse, press, right, {1, 1}, []}], decode(<<"\e[<2;1;1M">>)),
    %% Extended buttons 8-11 set bit 7 (128): 128 -> button 8, 131 -> button 11.
    ?assertEqual([{mouse, press, {button, 8}, {1, 1}, []}], decode(<<"\e[<128;1;1M">>)),
    ?assertEqual([{mouse, press, {button, 11}, {1, 1}, []}], decode(<<"\e[<131;1;1M">>)).

sgr_mouse_wheel_test() ->
    %% Wheel notches set bit 6 (64): 64 up, 65 down, 66/67 the horizontal wheel.
    ?assertEqual([{mouse, press, wheel_up, {5, 6}, []}], decode(<<"\e[<64;5;6M">>)),
    ?assertEqual([{mouse, press, wheel_down, {5, 6}, []}], decode(<<"\e[<65;5;6M">>)),
    ?assertEqual([{mouse, press, wheel_left, {5, 6}, []}], decode(<<"\e[<66;5;6M">>)),
    ?assertEqual([{mouse, press, wheel_right, {5, 6}, []}], decode(<<"\e[<67;5;6M">>)).

sgr_mouse_drag_test() ->
    %% Motion flag (bit 5, value 32) with a button held -> a drag. 32 = motion +
    %% button 0 (left); 34 = motion + button 2 (right).
    ?assertEqual([{mouse, drag, left, {3, 4}, []}], decode(<<"\e[<32;3;4M">>)),
    ?assertEqual([{mouse, drag, right, {3, 4}, []}], decode(<<"\e[<34;3;4M">>)),
    %% A buttonless move (all-motion tracking): motion + button code 3 -> `none'.
    ?assertEqual([{mouse, drag, none, {3, 4}, []}], decode(<<"\e[<35;3;4M">>)).

sgr_mouse_modifiers_test() ->
    %% Shift = 4, Meta = 8, Ctrl = 16, OR'd into Cb alongside the button.
    ?assertEqual([{mouse, press, left, {1, 1}, [shift]}], decode(<<"\e[<4;1;1M">>)),
    ?assertEqual([{mouse, press, left, {1, 1}, [meta]}], decode(<<"\e[<8;1;1M">>)),
    ?assertEqual([{mouse, press, left, {1, 1}, [ctrl]}], decode(<<"\e[<16;1;1M">>)),
    %% 4 + 16 = shift+ctrl on the left button; order is shift, meta, ctrl.
    ?assertEqual([{mouse, press, left, {1, 1}, [shift, ctrl]}], decode(<<"\e[<20;1;1M">>)).

sgr_mouse_split_across_reads_test() ->
    %% The report is buffered until its final byte arrives, like any CSI.
    St0 = tuition_input:new(),
    {E1, St1} = tuition_input:parse(<<"\e[<0;10">>, St0),
    {E2, _St2} = tuition_input:parse(<<";20M">>, St1),
    ?assertEqual([], E1),
    ?assert(tuition_input:pending(St1)),
    ?assertEqual([{mouse, press, left, {10, 20}, []}], E2).

sgr_mouse_then_key_test() ->
    %% A printable right after a mouse report still decodes.
    ?assertEqual(
        [{mouse, press, left, {1, 1}, []}, {key, {char, $x}, []}],
        decode(<<"\e[<0;1;1M", "x">>)
    ),
    %% A malformed `<'-report (too few params) is consumed, not misread as a key.
    ?assertEqual([{key, {char, $y}, []}], decode(<<"\e[<0;1M", "y">>)).

sgr_mouse_rejects_malformed_params_test() ->
    %% Coordinates are 1-based, so an omitted field or a coordinate below 1 is a
    %% malformed report: it is dropped (no event) rather than emitting a spurious
    %% click at a bogus cell.
    %% Omitted button field (empty first parameter).
    ?assertEqual([], decode(<<"\e[<;10;20M">>)),
    %% Zero column, then zero row.
    ?assertEqual([], decode(<<"\e[<0;0;20M">>)),
    ?assertEqual([], decode(<<"\e[<0;10;0M">>)),
    %% Empty column / empty row field.
    ?assertEqual([], decode(<<"\e[<0;;20M">>)),
    ?assertEqual([], decode(<<"\e[<0;10;M">>)),
    %% A stray CSI intermediate byte in a field (`-' is 0x2D, `.' is 0x2E). These
    %% are validated from the RAW sequence, so they are rejected rather than being
    %% silently stripped to a passing value (without this, `-1' would drop to `1'
    %% and slip past the `>= 1' coordinate guard).
    ?assertEqual([], decode(<<"\e[<0;-1;20M">>)),
    ?assertEqual([], decode(<<"\e[<-1;10;20M">>)),
    ?assertEqual([], decode(<<"\e[<0;1.5;20M">>)),
    %% Button 0 is a legitimate code (left button), so a well-formed 1-based
    %% report still decodes to the correct event.
    ?assertEqual([{mouse, press, left, {10, 20}, []}], decode(<<"\e[<0;10;20M">>)).

%%% -- bracketed paste (?2004) -----------------------------------------

bracketed_paste_basic_test() ->
    %% The bytes between `ESC [ 200 ~' and `ESC [ 201 ~' are one paste event.
    ?assertEqual([{paste, <<"hello">>}], decode(<<"\e[200~hello\e[201~">>)),
    %% An empty paste is still a single (empty) event.
    ?assertEqual([{paste, <<>>}], decode(<<"\e[200~\e[201~">>)).

bracketed_paste_keeps_escape_bytes_literal_test() ->
    %% Bytes inside a paste that look like escape/control sequences stay LITERAL —
    %% the `ESC [ A' is pasted text, not an Up key; the `\r' is not an Enter.
    ?assertEqual(
        [{paste, <<"a\e[Ab\rc">>}],
        decode(<<"\e[200~a\e[Ab\rc\e[201~">>)
    ).

bracketed_paste_then_key_test() ->
    %% Real keys before and after the paste decode normally around it.
    ?assertEqual(
        [{key, {char, $a}, []}, {paste, <<"xy">>}, {key, up, []}],
        decode(<<"a\e[200~xy\e[201~\e[A">>)
    ).

bracketed_paste_split_across_reads_test() ->
    %% Content split across three reads; the paste is emitted only when the
    %% closing bracket lands, carrying the whole text.
    St0 = tuition_input:new(),
    {E1, St1} = tuition_input:parse(<<"\e[200~he">>, St0),
    {E2, St2} = tuition_input:parse(<<"llo">>, St1),
    {E3, St3} = tuition_input:parse(<<"\e[201~">>, St2),
    ?assertEqual([], E1),
    ?assertEqual([], E2),
    ?assert(tuition_input:pending(St1)),
    ?assert(tuition_input:pending(St2)),
    %% A paste in progress must not force the short ESC timeout (it would truncate
    %% a slow paste), even though bytes are buffered.
    ?assertNot(tuition_input:awaiting_escape(St2)),
    ?assertEqual([{paste, <<"hello">>}], E3),
    ?assertNot(tuition_input:pending(St3)).

bracketed_paste_terminator_split_across_reads_test() ->
    %% The closing bracket itself is split across reads; a buffer tail that is a
    %% prefix of the terminator must not be mistaken for content.
    St0 = tuition_input:new(),
    {E1, St1} = tuition_input:parse(<<"\e[200~hi\e[20">>, St0),
    {E2, _St2} = tuition_input:parse(<<"1~">>, St1),
    ?assertEqual([], E1),
    ?assertEqual([{paste, <<"hi">>}], E2).

bracketed_paste_flush_emits_partial_test() ->
    %% The driver never flushes a paste, but flush stays total: a paste whose
    %% terminator never arrived surfaces its collected bytes best-effort.
    {[], St} = tuition_input:parse(<<"\e[200~ab">>, tuition_input:new()),
    ?assert(tuition_input:pending(St)),
    ?assertEqual([{paste, <<"ab">>}], flush_events(St)).

stray_paste_end_is_ignored_test() ->
    %% A close bracket with no paste in progress is not a key and not a paste.
    ?assertEqual([{key, {char, $z}, []}], decode(<<"\e[201~z">>)).

%%% -- Alt / Meta ------------------------------------------------------

alt_modified_key_test() ->
    ?assertEqual([{key, {char, $a}, [alt]}], decode(<<"\ea">>)),
    ?assertEqual([{key, {char, $b}, [alt]}], decode(<<"\eb">>)).

alt_multibyte_key_test() ->
    %% Alt+"é": ESC then the two UTF-8 bytes of U+00E9 — one Alt-modified char,
    %% not a crash (regression guard for the single-byte Alt-decode assumption).
    ?assertEqual(
        [{key, {char, 16#E9}, [alt]}],
        decode(<<"\e", 16#C3, 16#A9>>)
    ).

alt_multibyte_split_across_reads_test() ->
    %% ESC, then the UTF-8 lead, then the continuation — buffered until complete.
    St0 = tuition_input:new(),
    {E1, St1} = tuition_input:parse(<<"\e">>, St0),
    {E2, St2} = tuition_input:parse(<<16#C3>>, St1),
    {E3, _St3} = tuition_input:parse(<<16#A9>>, St2),
    ?assertEqual([], E1),
    ?assertEqual([], E2),
    ?assert(tuition_input:pending(St2)),
    ?assertEqual([{key, {char, 16#E9}, [alt]}], E3).

double_escape_buffers_then_flushes_to_two_escapes_test() ->
    %% Two ESCs in one buffer are ambiguous under metaSendsEscape: they may still
    %% grow into an Alt+<escape-seq-key> chord if a CSI/SS3 follows, so neither is
    %% emitted yet. With nothing following, flush resolves them to two Escapes (in
    %% one call — the residue is drained, not stranded for a further timeout).
    {Events, St} = tuition_input:parse(<<"\e\e">>, tuition_input:new()),
    ?assertEqual([], Events),
    ?assert(tuition_input:pending(St)),
    ?assert(tuition_input:awaiting_escape(St)),
    ?assertEqual([{key, esc, []}, {key, esc, []}], flush_events(St)).

%%% -- Alt-prefixed escape sequences (metaSendsEscape) -----------------

alt_prefixed_arrows_test() ->
    %% ESC ESC <CSI arrow> is the metaSendsEscape encoding of Alt+arrow.
    ?assertEqual([{key, up, [alt]}], decode(<<"\e\e[A">>)),
    ?assertEqual([{key, down, [alt]}], decode(<<"\e\e[B">>)),
    ?assertEqual([{key, right, [alt]}], decode(<<"\e\e[C">>)),
    ?assertEqual([{key, left, [alt]}], decode(<<"\e\e[D">>)),
    ?assertEqual([{key, home, [alt]}], decode(<<"\e\e[H">>)),
    ?assertEqual([{key, 'end', [alt]}], decode(<<"\e\e[F">>)).

alt_prefixed_ss3_test() ->
    %% ESC ESC <SS3> — Alt on the SS3 arrows and F1-F4.
    ?assertEqual([{key, up, [alt]}], decode(<<"\e\eOA">>)),
    ?assertEqual([{key, {f, 1}, [alt]}], decode(<<"\e\eOP">>)),
    ?assertEqual([{key, {f, 4}, [alt]}], decode(<<"\e\eOS">>)).

alt_prefixed_tilde_test() ->
    %% ESC ESC [ N ~ — Alt on the navigation/function tilde keys.
    ?assertEqual([{key, delete, [alt]}], decode(<<"\e\e[3~">>)),
    ?assertEqual([{key, page_up, [alt]}], decode(<<"\e\e[5~">>)),
    ?assertEqual([{key, {f, 5}, [alt]}], decode(<<"\e\e[15~">>)).

alt_prefixed_shift_tab_test() ->
    %% ESC ESC [ Z — Alt+Shift+Tab; the alt folds in alongside the shift (sorted).
    ?assertEqual([{key, tab, [alt, shift]}], decode(<<"\e\e[Z">>)).

alt_prefixed_already_modified_test() ->
    %% A modifier already on the inner sequence combines with the alt (deduped and
    %% ordered). ESC ESC [ 1 ; 5 A = Alt+Ctrl+Up; a redundant ESC ESC [ 1 ; 3 A
    %% (inner already alt) stays a single alt.
    ?assertEqual([{key, up, [alt, ctrl]}], decode(<<"\e\e[1;5A">>)),
    ?assertEqual([{key, up, [alt]}], decode(<<"\e\e[1;3A">>)).

alt_prefixed_escape_then_alt_printable_test() ->
    %% ESC ESC <printable> is NOT Alt-doubled: printable Alt is already the single
    %% `ESC a', so the extra leading ESC is a separate Escape key -> Escape, Alt+a.
    ?assertEqual(
        [{key, esc, []}, {key, {char, $a}, [alt]}],
        decode(<<"\e\ea">>)
    ).

alt_prefixed_unknown_csi_preserves_escape_test() ->
    %% An unknown CSI is not a key, so metaSendsEscape would not have prefixed it:
    %% the leading ESC is a real Escape, then the CSI is consumed (no event). A
    %% printable right after still decodes.
    ?assertEqual(
        [{key, esc, []}, {key, {char, $x}, []}],
        decode(<<"\e\e[>1;2c", "x">>)
    ).

alt_prefixed_paste_preserves_escape_test() ->
    %% `ESC ESC [ 200 ~ ...' is a real Escape typed just before a bracketed paste,
    %% NOT an alt-prefixed key: metaSendsEscape only prefixes keys, so the Escape
    %% must survive and the paste decode normally after it.
    ?assertEqual(
        [{key, esc, []}, {paste, <<"hi">>}],
        decode(<<"\e\e[200~hi\e[201~">>)
    ).

alt_prefixed_mouse_preserves_escape_test() ->
    %% Likewise an SGR mouse report is not a key: `ESC ESC [ < ... M' is Escape
    %% followed by the mouse report, with the Escape preserved and no phantom alt.
    ?assertEqual(
        [{key, esc, []}, {mouse, press, left, {1, 1}, []}],
        decode(<<"\e\e[<0;1;1M">>)
    ).

alt_prefixed_split_across_reads_test() ->
    %% ESC, ESC, '[', 'A' in four reads -> one Alt+Up. Each partial stays
    %% escape-ambiguous so the driver holds the short timeout throughout.
    St0 = tuition_input:new(),
    {E1, St1} = tuition_input:parse(<<"\e">>, St0),
    {E2, St2} = tuition_input:parse(<<"\e">>, St1),
    {E3, St3} = tuition_input:parse(<<"[">>, St2),
    {E4, St4} = tuition_input:parse(<<"A">>, St3),
    ?assertEqual([], E1 ++ E2 ++ E3),
    ?assert(tuition_input:awaiting_escape(St1)),
    ?assert(tuition_input:awaiting_escape(St2)),
    ?assert(tuition_input:awaiting_escape(St3)),
    ?assertEqual([{key, up, [alt]}], E4),
    ?assertNot(tuition_input:pending(St4)).

alt_prefixed_incomplete_flushes_to_escapes_test() ->
    %% ESC ESC [ with no final byte: the sequence never completed. Flush treats
    %% each leading ESC as Escape and re-decodes the trailing bytes ('[' -> a
    %% printable), draining the whole nested partial without stranding it.
    {[], St} = tuition_input:parse(<<"\e\e[">>, tuition_input:new()),
    ?assert(tuition_input:awaiting_escape(St)),
    ?assertEqual(
        [{key, esc, []}, {key, esc, []}, {key, {char, $[}, []}],
        flush_events(St)
    ).

triple_escape_flushes_to_three_escapes_test() ->
    %% ESC ESC ESC: the first ESC is a definite Escape (a third ESC follows the
    %% pair), emitted immediately; the trailing `ESC ESC' buffers and flushes to
    %% two more Escapes.
    {Events, St} = tuition_input:parse(<<"\e\e\e">>, tuition_input:new()),
    ?assertEqual([{key, esc, []}], Events),
    ?assert(tuition_input:awaiting_escape(St)),
    ?assertEqual([{key, esc, []}, {key, esc, []}], flush_events(St)).

flush_keeps_trailing_utf8_partial_buffered_test() ->
    %% Regression: flushing an ESC-led buffer drains only the escape-ambiguous
    %% residue — a split UTF-8 character in the tail must stay buffered, not be
    %% forced onto the escape timeout (which would lose its continuation to a
    %% replacement char). Here `ESC [ C3' (an incomplete CSI whose tail is the lead
    %% byte of é): flush yields Escape + `[' and leaves the C3 pending...
    {[], St0} = tuition_input:parse(<<"\e[", 16#C3>>, tuition_input:new()),
    ?assert(tuition_input:awaiting_escape(St0)),
    {Flushed, St1} = tuition_input:flush(St0),
    ?assertEqual([{key, esc, []}, {key, {char, $[}, []}], Flushed),
    ?assert(tuition_input:pending(St1)),
    ?assertNot(tuition_input:awaiting_escape(St1)),
    %% ...so the continuation byte still completes é (U+00E9), not a replacement.
    {Events, _St2} = tuition_input:parse(<<16#A9>>, St1),
    ?assertEqual([{key, {char, 16#E9}, []}], Events).

%%% -- UTF-8 printables ------------------------------------------------

utf8_two_byte_test() ->
    %% "é" = U+00E9 = C3 A9
    ?assertEqual([{key, {char, 16#E9}, []}], decode(<<16#C3, 16#A9>>)).

utf8_four_byte_test() ->
    %% "😀" = U+1F600 = F0 9F 98 80
    ?assertEqual([{key, {char, 16#1F600}, []}], decode(<<16#F0, 16#9F, 16#98, 16#80>>)).

invalid_utf8_yields_replacement_test() ->
    %% C3 followed by a non-continuation byte is invalid; resync past the lead.
    ?assertEqual(
        [{key, {char, 16#FFFD}, []}, {key, {char, $a}, []}],
        decode(<<16#C3, $a>>)
    ).

bad_continuation_does_not_swallow_next_key_test() ->
    %% A 3-byte lead (needs 2 continuations) followed by a non-continuation byte
    %% is already known-bad; it must NOT buffer waiting for a third byte, or the
    %% following `a' would be stranded (the driver never flushes a non-ESC
    %% partial). One replacement, then the `a' decodes immediately.
    ?assertEqual(
        [{key, {char, 16#FFFD}, []}, {key, {char, $a}, []}],
        decode(<<16#E0, $a>>)
    ),
    %% A valid partial prefix (lead + a genuine continuation, still short) does
    %% keep waiting — it isn't spuriously flushed.
    {[], St} = tuition_input:parse(<<16#E0, 16#A0>>, tuition_input:new()),
    ?assert(tuition_input:pending(St)),
    ?assertNot(tuition_input:awaiting_escape(St)),
    %% ...and completes when the final byte arrives (U+0800).
    {Events, _} = tuition_input:parse(<<16#80>>, St),
    ?assertEqual([{key, {char, 16#800}, []}], Events).

%%% -- incremental reassembly across reads -----------------------------

csi_split_across_reads_test() ->
    %% ESC, then '[', then 'A' arrive in three separate reads -> one Up.
    St0 = tuition_input:new(),
    {E1, St1} = tuition_input:parse(<<"\e">>, St0),
    {E2, St2} = tuition_input:parse(<<"[">>, St1),
    {E3, St3} = tuition_input:parse(<<"A">>, St2),
    ?assertEqual([], E1),
    ?assertEqual([], E2),
    ?assertEqual([{key, up, []}], E3),
    ?assertNot(tuition_input:pending(St3)).

utf8_split_across_reads_test() ->
    St0 = tuition_input:new(),
    {E1, St1} = tuition_input:parse(<<16#C3>>, St0),
    ?assertEqual([], E1),
    ?assert(tuition_input:pending(St1)),
    {E2, _St2} = tuition_input:parse(<<16#A9>>, St1),
    ?assertEqual([{key, {char, 16#E9}, []}], E2).

esc_then_printable_is_alt_across_reads_test() ->
    %% Lone ESC buffered, then a printable arrives before any timeout -> Alt.
    St0 = tuition_input:new(),
    {E1, St1} = tuition_input:parse(<<"\e">>, St0),
    ?assertEqual([], E1),
    ?assert(tuition_input:pending(St1)),
    {E2, _St2} = tuition_input:parse(<<"a">>, St1),
    ?assertEqual([{key, {char, $a}, [alt]}], E2).

%%% -- lone-ESC disambiguation via flush -------------------------------

lone_esc_buffers_then_flushes_to_escape_test() ->
    {Events, St} = tuition_input:parse(<<"\e">>, tuition_input:new()),
    ?assertEqual([], Events),
    ?assert(tuition_input:pending(St)),
    {Flushed, St2} = tuition_input:flush(St),
    ?assertEqual([{key, esc, []}], Flushed),
    ?assertNot(tuition_input:pending(St2)).

flush_on_empty_is_noop_test() ->
    ?assertEqual([], flush_events(tuition_input:new())).

awaiting_escape_distinguishes_esc_from_utf8_partial_test() ->
    ?assertNot(tuition_input:awaiting_escape(tuition_input:new())),
    %% Lone ESC and partial escape sequences are ESC-ambiguous.
    {[], EscSt} = tuition_input:parse(<<"\e">>, tuition_input:new()),
    ?assert(tuition_input:awaiting_escape(EscSt)),
    {[], CsiSt} = tuition_input:parse(<<"\e[">>, tuition_input:new()),
    ?assert(tuition_input:awaiting_escape(CsiSt)),
    %% A split UTF-8 lead byte is pending but NOT ESC-ambiguous.
    {[], Utf8St} = tuition_input:parse(<<16#C3>>, tuition_input:new()),
    ?assert(tuition_input:pending(Utf8St)),
    ?assertNot(tuition_input:awaiting_escape(Utf8St)),
    %% ESC followed by a UTF-8 lead byte is Alt committed to an incomplete char
    %% (Alt+é), no longer escape-ambiguous — must wait, not time out to Escape.
    {[], AltUtf8St} = tuition_input:parse(<<"\e", 16#C3>>, tuition_input:new()),
    ?assert(tuition_input:pending(AltUtf8St)),
    ?assertNot(tuition_input:awaiting_escape(AltUtf8St)).

flush_truncated_utf8_yields_replacement_test() ->
    {[], St} = tuition_input:parse(<<16#C3>>, tuition_input:new()),
    ?assertEqual([{key, {char, 16#FFFD}, []}], flush_events(St)).

flush_incomplete_csi_falls_back_to_escape_test() ->
    %% An escape sequence that never completed: flush treats the leading ESC as
    %% Escape and re-decodes the trailing bytes ('[' -> a printable).
    {[], St} = tuition_input:parse(<<"\e[">>, tuition_input:new()),
    ?assertEqual(
        [{key, esc, []}, {key, {char, $[}, []}],
        flush_events(St)
    ).

%%% -- mixed stream ----------------------------------------------------

mixed_stream_test() ->
    ?assertEqual(
        [
            {key, {char, $h}, []},
            {key, {char, $i}, []},
            {key, enter, []},
            {key, up, []},
            {key, {ctrl, $c}, [ctrl]}
        ],
        decode(<<"hi\r\e[A", 16#03>>)
    ).

%%% -- helpers ---------------------------------------------------------

%% Decode a complete buffer against a fresh parser and return just the events.
decode(Bytes) ->
    {Events, _St} = tuition_input:parse(Bytes, tuition_input:new()),
    Events.

flush_events(St) ->
    {Events, _St} = tuition_input:flush(St),
    Events.
