-module(tuition_width_tests).

-include_lib("eunit/include/eunit.hrl").

%%% -- width/1: single grapheme clusters -------------------------------

ascii_test() ->
    ?assertEqual(1, tuition_width:width($a)),
    ?assertEqual(1, tuition_width:width($Z)),
    ?assertEqual(1, tuition_width:width("~")),
    %% A space still occupies a column.
    ?assertEqual(1, tuition_width:width($\s)),
    ?assertEqual(1, tuition_width:width(<<" ">>)).

wide_test() ->
    %% CJK ideograph 日 U+65E5 and fullwidth Latin Ａ U+FF21 are double-width.
    ?assertEqual(2, tuition_width:width(16#65E5)),
    ?assertEqual(2, tuition_width:width(<<"日"/utf8>>)),
    ?assertEqual(2, tuition_width:width(16#FF21)),
    %% Hangul syllable 가 U+AC00 and Hiragana あ U+3042.
    ?assertEqual(2, tuition_width:width(16#AC00)),
    ?assertEqual(2, tuition_width:width(16#3042)).

zero_width_test() ->
    %% Combining acute accent (Mn), ZWSP (Cf) and a C0 control (Cc).
    ?assertEqual(0, tuition_width:width(16#0301)),
    ?assertEqual(0, tuition_width:width(16#200B)),
    ?assertEqual(0, tuition_width:width(16#0001)),
    %% DEL and a lone ZWJ / variation selector are also zero on their own.
    ?assertEqual(0, tuition_width:width(16#007F)),
    ?assertEqual(0, tuition_width:width(16#200D)),
    ?assertEqual(0, tuition_width:width(16#FE0F)).

combining_cluster_test() ->
    %% "é" spelled as e + combining acute is one cluster, width 1.
    ?assertEqual(1, tuition_width:width([$e, 16#0301])),
    ?assertEqual(1, tuition_width:width(<<$e, "́"/utf8>>)).

emoji_presentation_test() ->
    %% A default-text codepoint promoted to emoji by VS16 becomes width 2:
    %% ❤ U+2764 is width 1, but ❤️ (U+2764 U+FE0F) is width 2.
    ?assertEqual(1, tuition_width:width(16#2764)),
    ?assertEqual(2, tuition_width:width([16#2764, 16#FE0F])),
    %% Keycap sequence "1️⃣" = '1' + VS16 + U+20E3 renders double-width.
    ?assertEqual(2, tuition_width:width([$1, 16#FE0F, 16#20E3])),
    %% Unqualified keycap (no VS16): '1' + U+20E3 still renders as a 2-col
    %% keycap emoji, and "1⃣x" is 2 + 1 = 3 columns.
    ?assertEqual(2, tuition_width:width([$1, 16#20E3])),
    ?assertEqual(3, tuition_width:swidth([$1, 16#20E3, $x])).

zwj_sequence_test() ->
    %% Family 👨‍👩‍👧 = MAN ZWJ WOMAN ZWJ GIRL is a single cluster, width 2.
    Family = [16#1F468, 16#200D, 16#1F469, 16#200D, 16#1F467],
    ?assertEqual(2, tuition_width:width(Family)),
    ?assertEqual(2, tuition_width:width(<<"👨‍👩‍👧"/utf8>>)).

flag_emoji_test() ->
    %% A regional-indicator pair 🇺🇸 (U+1F1FA U+1F1F8) is one cluster that
    %% renders as a two-column flag emoji. The per-codepoint oracle can't see
    %% this, so the cluster rule must: a missed flag under-counts (the #1 risk).
    US = [16#1F1FA, 16#1F1F8],
    ?assertEqual(2, tuition_width:width(US)),
    ?assertEqual(2, tuition_width:width(<<"🇺🇸"/utf8>>)),
    %% A lone regional indicator also renders wide.
    ?assertEqual(2, tuition_width:width(16#1F1FA)).

emoji_modifier_test() ->
    %% ☝ U+261D is a text-default emoji, width 1 on its own; with a skin-tone
    %% modifier U+1F3FD it is one cluster rendering as a two-column emoji.
    ?assertEqual(1, tuition_width:width(16#261D)),
    ?assertEqual(2, tuition_width:width([16#261D, 16#1F3FD])),
    ?assertEqual(2, tuition_width:width(<<"☝🏽"/utf8>>)),
    %% A skin-tone modifier after a NON-emoji base is malformed input; it must
    %% not collapse to 2 (an under-count). Sum instead: 'a' (1) + modifier (2).
    ?assertEqual(3, tuition_width:width([$a, 16#1F3FD])),
    ?assertEqual(3, tuition_width:swidth([$a, 16#1F3FD])).

indic_zwj_test() ->
    %% A ZWJ used for text shaping (not emoji) must NOT promote a cluster to
    %% width 2. Devanagari KA + VIRAMA + ZWJ is one cluster of width 1
    %% (KA=1, VIRAMA=0, ZWJ=0) — the ZWJ is a conjunct joiner, not emoji
    %% presentation. The blanket-ZWJ rule used to make this 2.
    ?assertEqual(1, tuition_width:width([16#0915, 16#094D, 16#200D])),
    %% The full conjunct क्‍ष is KA(1) + VIRAMA(0) + ZWJ(0) + SSA(1) = 2 columns
    %% — the two spacing consonants summed, not the 3 the blanket-ZWJ rule gave,
    %% and not an under-count from collapsing to a single base.
    ?assertEqual(2, tuition_width:swidth([16#0915, 16#094D, 16#200D, 16#0937])).

malformed_emoji_base_test() ->
    %% Emoji presentation is gated on the base being Extended_Pictographic, so a
    %% selector/modifier after a NON-emoji base is not treated as emoji.
    %% VS16 after 'a' is inert: width 1, not a phantom 2.
    ?assertEqual(1, tuition_width:width([$a, 16#FE0F])),
    ?assertEqual(1, tuition_width:swidth([$a, 16#FE0F])),
    %% A skin-tone modifier after wide CJK 日 (wide but NOT emoji) is malformed:
    %% sum the two wide code points (2 + 2 = 4) rather than collapse to 2.
    ?assertEqual(4, tuition_width:width([16#65E5, 16#1F3FD])),
    ?assertEqual(4, tuition_width:swidth([16#65E5, 16#1F3FD])).

empty_test() ->
    ?assertEqual(0, tuition_width:width(<<>>)),
    ?assertEqual(0, tuition_width:width("")).

%%% -- swidth/1: whole strings -----------------------------------------

swidth_ascii_test() ->
    ?assertEqual(0, tuition_width:swidth("")),
    ?assertEqual(5, tuition_width:swidth("hello")),
    ?assertEqual(11, tuition_width:swidth(<<"hello world">>)).

swidth_mixed_test() ->
    %% "aあb" = 1 + 2 + 1 = 4, via both a binary and a codepoint list.
    ?assertEqual(4, tuition_width:swidth(<<"aあb"/utf8>>)),
    ?assertEqual(4, tuition_width:swidth([$a, 16#3042, $b])).

swidth_combining_test() ->
    %% Combining marks add no columns: "e" + acute + "x" is 2 columns.
    ?assertEqual(2, tuition_width:swidth([$e, 16#0301, $x])),
    %% A ZWJ family emoji contributes a single double-width cluster.
    ?assertEqual(2, tuition_width:swidth(<<"👨‍👩‍👧"/utf8>>)),
    ?assertEqual(6, tuition_width:swidth(<<"[👨‍👩‍👧]!!"/utf8>>)).

swidth_bad_utf8_test() ->
    %% Best-effort: a stray, undecodable byte counts as one column; no crash.
    %% "a","b",<0xFF>,"c","d" => 1+1+1+1+1 = 5.
    ?assertEqual(5, tuition_width:swidth(<<"ab", 16#FF, "cd">>)),
    %% Same, but the bad byte is inside an iolist chunk rather than a flat
    %% binary: the following text must not be dropped (still 5, not 2).
    ?assertEqual(5, tuition_width:swidth([<<"ab">>, <<16#FF>>, <<"cd">>])).

swidth_split_utf8_test() ->
    %% A UTF-8 sequence split across adjacent binaries in an iolist must be
    %% joined before grapheme splitting: あ (E3 81 82) is width 2, not
    %% mis-decoded across the boundary.
    ?assertEqual(2, tuition_width:swidth([<<16#E3>>, <<16#81, 16#82>>])),
    ?assertEqual(2, tuition_width:swidth([<<16#E3, 16#81>>, <<16#82>>])),
    %% Boundary between two characters: "aあ" split as "a"+<<E3 81>> | <<82>>.
    ?assertEqual(3, tuition_width:swidth([<<$a, 16#E3, 16#81>>, <<16#82>>])).

%%% -- cross-check against the prim_tty oracle -------------------------
%%%
%%% prim_tty:npwcwidth/1 (kernel, internal) is the per-codepoint width the
%%% BEAM's own line editor uses. We sweep a broad sample and log how our tables
%%% compare, as a diagnostic and a crash guard.
%%%
%%% This is NOT asserted, because npwcwidth/1 delegates to the platform's libc
%%% wcwidth for parts of its range and so is not portable: e.g. glibc reports
%%% U+3248 as 2 and U+00AD / U+0600..U+0605 as 1, where macOS (and our
%%% EastAsianWidth-derived tables) say otherwise. Our tables follow the
%%% authoritative Unicode 16.0 EastAsianWidth; the explicit width/1 assertions
%%% above are the portable correctness gate.
%%%
%%% (prim_tty:wcswidth/1, the string oracle named in the issue, is a libc NIF
%%% that depends on the process locale and returns {ok,0} for plain ASCII in a
%%% non-interactive eunit run, so npwcwidth/1 is the usable per-codepoint form.)
oracle_cross_check_test_() ->
    {timeout, 120, fun run_cross_check/0}.

run_cross_check() ->
    %% Cover the whole BMP plus the emoji / CJK-extension planes and the
    %% plane-14 variation-selector & tag block.
    Sample = lists:seq(0, 16#3FFFF) ++ lists:seq(16#E0000, 16#E01EF),
    {Dangerous, Over} =
        lists:foldl(
            fun(Cp, {Dang, Ovr}) ->
                case oracle(Cp) of
                    skip ->
                        {Dang, Ovr};
                    OW ->
                        MyW = tuition_width:width(Cp),
                        if
                            MyW < OW -> {[{Cp, MyW, OW} | Dang], Ovr};
                            MyW > OW -> {Dang, Ovr + 1};
                            true -> {Dang, Ovr}
                        end
                end
            end,
            {[], 0},
            Sample
        ),
    ?debugFmt(
        "oracle cross-check vs prim_tty:npwcwidth (platform-dependent): "
        "~p codepoints, ~p over-count diffs, ~p under-count diffs",
        [length(Sample), Over, length(Dangerous)]
    ),
    %% Diagnostic only — see the note above on why this is not asserted.
    ok.

%% Wrap the oracle; surrogates are not scalar values, so skip them.
oracle(Cp) when Cp >= 16#D800, Cp =< 16#DFFF ->
    skip;
oracle(Cp) ->
    try
        prim_tty:npwcwidth(Cp)
    catch
        _:_ -> skip
    end.

%% Spot-check the documented "we say more than the oracle" cases so their
%% direction stays pinned even if the oracle's table shifts:
%%   * U+4DC0 (Yijing hexagram) and U+1D300 (Tai Xuan Jing) are East Asian
%%     Wide in current Unicode (our answer, 2) but width 1 in glibc's older
%%     wcwidth (the oracle). We follow Unicode EastAsianWidth.
%%   * Unassigned and Mc spacing-combining codepoints: the oracle reports 0,
%%     we reserve 1 (a safe over-estimate).
oracle_disagreement_direction_test() ->
    ?assertEqual(2, tuition_width:width(16#4DC0)),
    ?assertEqual(2, tuition_width:width(16#1D300)),
    %% U+0903 DEVANAGARI SIGN VISARGA is a spacing (Mc) mark: width 1 here.
    ?assertEqual(1, tuition_width:width(16#0903)),
    %% U+0378 is unassigned: we reserve a single column.
    ?assertEqual(1, tuition_width:width(16#0378)).
