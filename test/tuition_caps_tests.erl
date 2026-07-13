-module(tuition_caps_tests).

-include_lib("eunit/include/eunit.hrl").
-include("tuition_caps.hrl").

%%% -- fixtures --------------------------------------------------------

%% A DECRQSS SGR read-back echoing the probe's RGB(1,2,3) — xterm's colon form
%% with an empty colour-space id, the awkward real-world shape.
-define(TRUECOLOR_COLON, <<"\eP1$r0;38:2::1:2:3m\e\\">>).
%% The semicolon form some terminals reply with instead.
-define(TRUECOLOR_SEMI, <<"\eP1$r0;38;2;1;2;3m\e\\">>).
%% DECRQM reports: mode recognised (value 2 = reset-but-supported / 1 = set).
-define(SYNC_OK, <<"\e[?2026;2$y">>).
-define(PASTE_OK, <<"\e[?2004;1$y">>).
-define(MOUSE_OK, <<"\e[?1006;1$y">>).
%% kitty keyboard flags reply.
-define(KITTY_OK, <<"\e[?1u">>).
%% The DA1 (Primary Device Attributes) reply that ends every probe — a realistic
%% xterm answer. DA1, not a DSR/CPR, so the sentinel cannot collide with a
%% modified F3 keypress (`ESC [ 1 ; 2 R').
-define(DA, <<"\e[?62;1;6c">>).

%%% -- baseline --------------------------------------------------------

baseline_all_off_test() ->
    Caps = tuition_caps:baseline(),
    ?assertEqual(#caps{}, Caps),
    ?assertNot(Caps#caps.truecolor),
    ?assertNot(Caps#caps.sync_output),
    ?assertNot(Caps#caps.bracketed_paste),
    ?assertNot(Caps#caps.sgr_mouse),
    ?assertNot(Caps#caps.kitty_keyboard).

%%% -- pure reply decoding ---------------------------------------------

parse_full_reply_enables_all_test() ->
    Buf = <<
        (?TRUECOLOR_COLON)/binary,
        (?SYNC_OK)/binary,
        (?PASTE_OK)/binary,
        (?MOUSE_OK)/binary,
        (?KITTY_OK)/binary,
        (?DA)/binary
    >>,
    ?assertEqual(
        #caps{
            truecolor = true,
            sync_output = true,
            bracketed_paste = true,
            sgr_mouse = true,
            kitty_keyboard = true
        },
        tuition_caps:parse_replies(Buf)
    ).

parse_truecolor_semicolon_form_test() ->
    Caps = tuition_caps:parse_replies(<<(?TRUECOLOR_SEMI)/binary, (?DA)/binary>>),
    ?assert(Caps#caps.truecolor).

%% A 256-colour-only terminal replies to DECRQSS but does NOT echo the RGB
%% triple, so truecolor must stay off.
parse_non_truecolor_sgr_readback_test() ->
    Caps = tuition_caps:parse_replies(<<"\eP1$r0;38;5;9m\e\\", (?DA)/binary>>),
    ?assertNot(Caps#caps.truecolor).

%% An invalid DECRQSS reply (`0 $ r') means the query was not understood.
parse_invalid_decrqss_is_off_test() ->
    Caps = tuition_caps:parse_replies(<<"\eP0$r\e\\", (?DA)/binary>>),
    ?assertNot(Caps#caps.truecolor).

%% A terminal without truecolor may misparse the probe `38;2;1;2;3' as separate
%% SGR attributes (bold;faint;italic) and echo the bare `1;2;3' tail with no
%% `38;2' introducer. That must NOT be read as a stored RGB foreground.
parse_misparsed_sgr_tail_is_not_truecolor_test() ->
    Caps = tuition_caps:parse_replies(<<"\eP1$r0;1;2;3m\e\\", (?DA)/binary>>),
    ?assertNot(Caps#caps.truecolor).

%% Only synchronized output answered: that one capability is on, the rest degrade
%% to off. This is the per-capability graceful-degradation case.
parse_partial_reply_leaves_rest_off_test() ->
    Caps = tuition_caps:parse_replies(<<(?SYNC_OK)/binary, (?DA)/binary>>),
    ?assertEqual(#caps{sync_output = true}, Caps).

%% A DECRQM value of 0 means "mode not recognised" — the capability is off even
%% though a reply was sent.
parse_decrqm_zero_is_unsupported_test() ->
    Caps = tuition_caps:parse_replies(<<"\e[?2026;0$y", (?DA)/binary>>),
    ?assertNot(Caps#caps.sync_output).

%% A DECRQM value of 4 means "permanently reset" — recognised but impossible to
%% enable, so the capability must stay off (it is not a usable feature).
parse_decrqm_permanently_reset_is_unsupported_test() ->
    Caps = tuition_caps:parse_replies(<<"\e[?2026;4$y", (?DA)/binary>>),
    ?assertNot(Caps#caps.sync_output).

%% A DECRQM value of 3 means "permanently set" — recognised and always on, so the
%% capability is available.
parse_decrqm_permanently_set_is_supported_test() ->
    Caps = tuition_caps:parse_replies(<<"\e[?2026;3$y", (?DA)/binary>>),
    ?assert(Caps#caps.sync_output).

%% The DA1 sentinel and any stray leading bytes must not crash or spuriously set
%% a capability.
parse_ignores_sentinel_and_noise_test() ->
    ?assertEqual(#caps{}, tuition_caps:parse_replies(?DA)),
    ?assertEqual(#caps{}, tuition_caps:parse_replies(<<"garbage", (?DA)/binary>>)),
    ?assertEqual(#caps{}, tuition_caps:parse_replies(<<>>)).

%% A truncated control string at the tail is dropped cleanly, not looped on.
parse_truncated_dcs_is_dropped_test() ->
    ?assertEqual(#caps{}, tuition_caps:parse_replies(<<"\eP1$r0;38;2;1;2;3">>)).

%%% -- residue (input preserved across the probe) ----------------------

%% Pure replies terminated by the DA1 sentinel are all consumed, so nothing is
%% left over for the input parser.
decode_replies_pure_replies_leave_no_residue_test() ->
    {Caps, Residue} = tuition_caps:decode_replies(<<(?SYNC_OK)/binary, (?DA)/binary>>),
    ?assertEqual(#caps{sync_output = true}, Caps),
    ?assertEqual(<<>>, Residue).

%% A plain key typed during the probe window trails the replies as an
%% unrecognised byte: it is returned as residue so the loop can replay it.
decode_replies_trailing_key_is_residue_test() ->
    {Caps, Residue} = tuition_caps:decode_replies(<<"\e[?62;c", "q">>),
    ?assertEqual(#caps{}, Caps),
    ?assertEqual(<<"q">>, Residue).

%% A partial escape at the tail (a truncated sequence, or the head of a key the
%% terminal has not finished delivering) is preserved whole as residue.
decode_replies_trailing_incomplete_escape_is_residue_test() ->
    {Caps, Residue} = tuition_caps:decode_replies(<<"\e[?62;c", "\e[">>),
    ?assertEqual(#caps{}, Caps),
    ?assertEqual(<<"\e[">>, Residue).

%%% -- probe over the terminal seam ------------------------------------

probe_writes_queries_and_decodes_test() ->
    Buf = <<
        (?TRUECOLOR_SEMI)/binary,
        (?SYNC_OK)/binary,
        (?PASTE_OK)/binary,
        (?MOUSE_OK)/binary,
        (?KITTY_OK)/binary,
        (?DA)/binary
    >>,
    Pid = tuition_probe_term:start([{ok, Buf}]),
    {Caps, _Residue} = tuition_caps:probe({tuition_probe_term, Pid}, 100),
    ?assertEqual(
        #caps{
            truecolor = true,
            sync_output = true,
            bracketed_paste = true,
            sgr_mouse = true,
            kitty_keyboard = true
        },
        Caps
    ),
    %% The probe must have emitted the truecolor set + DECRQSS read-back, the
    %% DECRQM queries, and the DA1 sentinel.
    Sent = tuition_probe_term:sent(Pid),
    [
        ?assertMatch({_, _}, binary:match(Sent, Q))
     || Q <- [<<"\e[38;2;1;2;3m">>, <<"\eP$qm\e\\">>, <<"\e[?2026$p">>, <<"\e[c">>]
    ].

%% Replies split arbitrarily across reads must reassemble before decoding.
probe_accumulates_split_reads_test() ->
    Full = <<(?TRUECOLOR_SEMI)/binary, (?SYNC_OK)/binary, (?DA)/binary>>,
    Mid = byte_size(Full) div 2,
    <<A:Mid/binary, B/binary>> = Full,
    Pid = tuition_probe_term:start([{ok, A}, {ok, B}]),
    {Caps, _Residue} = tuition_caps:probe({tuition_probe_term, Pid}, 100),
    ?assert(Caps#caps.truecolor),
    ?assert(Caps#caps.sync_output).

%% A terminal that answers only the DA1 sentinel (supports none of the
%% enrichments) yields the baseline, promptly (the DA1 reply ends the read).
probe_only_sentinel_is_baseline_test() ->
    Pid = tuition_probe_term:start([{ok, ?DA}]),
    %% The DA1 sentinel is a complete reply, so it is consumed: no residue.
    ?assertEqual({#caps{}, <<>>}, tuition_caps:probe({tuition_probe_term, Pid}, 100)).

%% A terminal that answers nothing at all degrades to the baseline on the read
%% timeout, without hanging.
probe_silent_terminal_times_out_to_baseline_test() ->
    Pid = tuition_probe_term:start([]),
    ?assertEqual({#caps{}, <<>>}, tuition_caps:probe({tuition_probe_term, Pid}, 50)).

%% A write failure short-circuits to the baseline (no reads attempted).
probe_write_error_is_baseline_test() ->
    Pid = tuition_probe_term:start([{ok, ?DA}], {error, closed}),
    ?assertEqual({#caps{}, <<>>}, tuition_caps:probe({tuition_probe_term, Pid}, 100)).

%% A modified F3 keypress (`ESC [ 1 ; 2 R') is byte-identical in shape to a DSR's
%% CPR reply. Arriving mid-probe it must NOT be mistaken for the sentinel: the
%% DA1-based read must skip past it and still consume the real capability replies
%% that follow. If the old CPR sentinel logic were in play the probe would stop
%% on the F3 and degrade every capability to off.
probe_modified_f3_does_not_end_probe_test() ->
    Replies = <<
        (?TRUECOLOR_SEMI)/binary,
        (?SYNC_OK)/binary,
        (?PASTE_OK)/binary,
        (?MOUSE_OK)/binary,
        (?KITTY_OK)/binary,
        (?DA)/binary
    >>,
    Pid = tuition_probe_term:start([{ok, <<"\e[1;2R">>}, {ok, Replies}]),
    {Caps, _Residue} = tuition_caps:probe({tuition_probe_term, Pid}, 100),
    ?assertEqual(
        #caps{
            truecolor = true,
            sync_output = true,
            bracketed_paste = true,
            sgr_mouse = true,
            kitty_keyboard = true
        },
        Caps
    ).

%%% -- COLORTERM fallback ----------------------------------------------

%% COLORTERM=truecolor|24bit advertises 24-bit colour for terminals that don't
%% answer the DECRQSS probe, so it enables truecolor on top of the probe result.
apply_colorterm_enables_truecolor_test() ->
    ?assert((tuition_caps:apply_colorterm("truecolor", #caps{}))#caps.truecolor),
    ?assert((tuition_caps:apply_colorterm("24bit", #caps{}))#caps.truecolor).

%% An unset variable (`false') or any other value leaves the set untouched, and
%% the fallback only ever adds truecolor — it never clears a probe-detected one.
apply_colorterm_other_values_are_noops_test() ->
    ?assertEqual(#caps{}, tuition_caps:apply_colorterm(false, #caps{})),
    ?assertEqual(#caps{}, tuition_caps:apply_colorterm("256color", #caps{})),
    ?assert((tuition_caps:apply_colorterm(false, #caps{truecolor = true}))#caps.truecolor).

%% It touches only truecolor, never the other capabilities.
apply_colorterm_preserves_other_caps_test() ->
    Caps = #caps{sync_output = true, sgr_mouse = true},
    ?assertEqual(
        Caps#caps{truecolor = true},
        tuition_caps:apply_colorterm("truecolor", Caps)
    ).
