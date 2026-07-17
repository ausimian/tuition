-module(tuition_width).
-moduledoc """
Unicode display width — terminal columns per grapheme cluster.

The renderer must advance the cursor by the number of columns a run of
text actually occupies, not by the number of codepoints it contains.
Getting this wrong corrupts every subsequent cell on the row — the #1
correctness risk here. Two facts drive the whole module:

  * A user-perceived character is a *grapheme cluster* — possibly several
    codepoints (a base plus combining marks, or an emoji ZWJ sequence) —
    that occupies a single run of columns. We split text into clusters
    with `string:next_grapheme/1` (stdlib yields clusters, never
    columns) and take the width of each cluster as a whole.
  * A cluster's column count is governed by its base codepoint: combining
    marks (Unicode Mn/Me), format/zero-width characters (Cf: ZWSP, ZWNJ,
    ZWJ,...), C0/C1 controls (Cc) and variation selectors take 0 columns;
    East Asian Wide/Fullwidth codepoints take 2; everything else takes 1.
    An emoji-presentation selector (VS16), a skin-tone modifier, or an
    emoji ZWJ sequence promotes an otherwise-narrow base to width 2, and a
    regional-indicator base (a flag) is width 2.

The width data below is three self-contained sorted interval
tables — the *wide* set (East Asian Wide + Fullwidth, plus the emoji
blocks that render double-width), the *zero* set (Mn/Me/Cf/Cc + variation
selectors), and the *Extended_Pictographic* set (genuine emoji bases) —
derived offline from the Unicode 16.0 character database. Nothing here
calls into `prim_tty` or `unicode_util` at runtime; both `prim_tty` and
`unicode_util` are used only to generate/validate the tables offline.
""".

-export([width/1, swidth/1]).

-type grapheme() :: char() | unicode:chardata().
%% A single grapheme cluster: one codepoint, a binary, or a list of codepoints.

-export_type([grapheme/0]).

%% Selectors that promote an otherwise-narrow base codepoint to width 2.

% VARIATION SELECTOR-16 (forces emoji presentation)
-define(VS16, 16#FE0F).
% ZERO WIDTH JOINER (binds an emoji ZWJ sequence)
-define(ZWJ, 16#200D).

%%% -- public API ------------------------------------------------------

-doc """
Display width, in terminal columns, of a single grapheme cluster.

Accepts a bare codepoint, a binary or a list of codepoints. For a well-formed
cluster the result is 0, 1 or 2 — the base codepoint's width (0 for
combining/zero-width, 2 for East Asian Wide/Fullwidth, 1 otherwise), or 2 for
an emoji cluster (VS16, a flag, or a ZWJ/skin-tone modifier on an emoji base).
Malformed input (a stray non-zero-width code point trailing the base) is
summed rather than under-counted, so it may exceed 2. An empty cluster is 0.
""".
-spec width(grapheme()) -> non_neg_integer().
width(Grapheme) ->
    case to_codepoints(Grapheme) of
        [] -> 0;
        [Base | Rest] -> cluster_width(Base, Rest)
    end.

-doc """
Total display width, in terminal columns, of a run of text.

Grapheme-cluster aware: the text is split with `string:next_grapheme/1` and each cluster contributes its `width/1`.
Malformed input is counted best-effort (one column per stray byte) so the
renderer never crashes on bad encodings.
""".
-spec swidth(unicode:chardata()) -> non_neg_integer().
swidth(Text) ->
    swidth_cd(Text, 0).

%% Normalise chardata to a flat UTF-8 binary before grapheme splitting, so a
%% multi-byte sequence split across adjacent binaries in an iolist is joined —
%% string:next_grapheme/1 would otherwise mis-decode the boundary. An
%% undecodable byte is charged one replacement column and the scan resyncs; a
%% truncated trailing sequence is charged one column per leftover byte.
-spec swidth_cd(unicode:chardata(), non_neg_integer()) -> non_neg_integer().
swidth_cd(Text, Acc) ->
    case unicode:characters_to_binary(Text) of
        Bin when is_binary(Bin) ->
            swidth_loop(string:next_grapheme(Bin), Acc);
        {error, Good, Rest} ->
            Acc1 = swidth_loop(string:next_grapheme(Good), Acc),
            case drop_byte(Rest) of
                eof -> Acc1 + 1;
                Rest1 -> swidth_cd(Rest1, Acc1 + 1)
            end;
        {incomplete, Good, Rest} ->
            swidth_loop(string:next_grapheme(Good), Acc) + iolist_size(Rest)
    end.

swidth_loop([], Acc) ->
    Acc;
swidth_loop([GC | Rest], Acc) ->
    swidth_loop(string:next_grapheme(Rest), Acc + grapheme_width(GC));
swidth_loop({error, Rest}, Acc) ->
    %% Stray, undecodable byte: count it as one replacement column and resync on
    %% the remainder. string:next_grapheme/1 reports the tail as a flat binary
    %% for a binary input but as an *iolist* for chardata, so drop the leading
    %% byte from either shape rather than dropping the rest of the text.
    case drop_byte(Rest) of
        eof -> Acc;
        Rest1 -> swidth_loop(string:next_grapheme(Rest1), Acc + 1)
    end.

%% Drop one leading byte from a chardata remainder, returning chardata to resync
%% on (or `eof' when nothing is left). Handles a flat binary tail and an iolist
%% tail (a list of binary chunks / code points / nested chardata) alike.
-spec drop_byte(unicode:chardata()) -> unicode:chardata() | eof.
drop_byte(<<_, More/binary>>) ->
    More;
drop_byte(<<>>) ->
    eof;
drop_byte([]) ->
    eof;
drop_byte([<<_, More/binary>> | T]) ->
    [More | T];
drop_byte([<<>> | T]) ->
    drop_byte(T);
drop_byte([H | T]) when is_integer(H) -> T;
drop_byte([H | T]) ->
    case drop_byte(H) of
        eof -> drop_byte(T);
        More -> [More | T]
    end.

%%% -- cluster / codepoint width ---------------------------------------

%% Width of one grapheme cluster as produced by string:next_grapheme/1: a
%% bare codepoint, or a [Base | CombiningMarks] list.
-spec grapheme_width(char() | [char()]) -> non_neg_integer().
grapheme_width(Cp) when is_integer(Cp) ->
    cluster_width(Cp, []);
grapheme_width([Base | Rest]) ->
    cluster_width(Base, Rest).

%% Width of one grapheme cluster (Base plus its trailing code points). A
%% regional-indicator base is a flag (or lone RI), always two columns. An emoji
%% cluster is two columns: a keycap, or a genuine emoji base carrying emoji
%% presentation (VS16, a skin-tone modifier, or a ZWJ join). Everything else is
%% the base plus any non-zero-width trailing code points — for well-formed text
%% that is just the base (0/1/2), while malformed input (a modifier or VS16
%% after a NON-emoji base, an Indic ZWJ conjunct, ...) is summed rather than
%% under-counted or wrongly promoted. Emoji presentation is gated on the base
%% actually being Extended_Pictographic, so wide non-emoji (CJK) and a
%% non-emoji base + VS16 are handled correctly.
-spec cluster_width(char(), [char()]) -> non_neg_integer().
cluster_width(Base, []) when Base >= 16#20, Base =< 16#7E ->
    %% Hot path: a bare printable-ASCII grapheme is always one column.
    1;
cluster_width(Base, Rest) ->
    case regional_indicator(Base) of
        true ->
            2;
        false ->
            EmojiCluster =
                keycap(Base, Rest) orelse
                    (is_emoji(Base) andalso emoji_presentation(Rest)),
            case EmojiCluster of
                true ->
                    2;
                false ->
                    lists:foldl(
                        fun(Cp, Acc) -> Acc + cp_width(Cp) end,
                        cp_width(Base),
                        Rest
                    )
            end
    end.

%% Trailing code points that request emoji presentation for an emoji base: an
%% emoji variation selector (VS16), a ZWJ join, or a skin-tone modifier.
-spec emoji_presentation([char()]) -> boolean().
emoji_presentation(Rest) ->
    lists:member(?VS16, Rest) orelse
        lists:member(?ZWJ, Rest) orelse
        lists:any(fun emoji_modifier/1, Rest).

%% Whether a base is a genuine emoji (Extended_Pictographic) and so can carry
%% emoji presentation via VS16, a skin-tone modifier, or a ZWJ join. Uses the
%% Extended_Pictographic table rather than merely East Asian width, so wide
%% non-emoji such as CJK ideographs are correctly NOT treated as emoji bases.
-spec is_emoji(char()) -> boolean().
is_emoji(Cp) ->
    in_table(Cp, extended_pictographic_ranges()).

%% An enclosing-keycap sequence: a keycap base (0-9, # or *) followed by the
%% combining enclosing keycap U+20E3, with or without the VS16 qualifier. It
%% renders as a two-column keycap emoji either way.
-spec keycap(char(), [char()]) -> boolean().
keycap(Base, Rest) ->
    keycap_base(Base) andalso lists:member(16#20E3, Rest).

-spec keycap_base(char()) -> boolean().
keycap_base(Cp) ->
    (Cp >= $0 andalso Cp =< $9) orelse Cp =:= $# orelse Cp =:= $*.

%% Regional Indicator Symbols A..Z (U+1F1E6..U+1F1FF); a pair forms a flag.
-spec regional_indicator(char()) -> boolean().
regional_indicator(Cp) ->
    Cp >= 16#1F1E6 andalso Cp =< 16#1F1FF.

%% Emoji skin-tone modifiers (Fitzpatrick, U+1F3FB..U+1F3FF). A modifier after
%% an emoji base forms a single two-column glyph even when the base is a
%% text-default (narrow) emoji such as ☝ U+261D.
-spec emoji_modifier(char()) -> boolean().
emoji_modifier(Cp) ->
    Cp >= 16#1F3FB andalso Cp =< 16#1F3FF.

%% Width of a lone codepoint: zero set wins over wide set (a combining mark is
%% always zero, even in the rare case a range would otherwise claim it).
-spec cp_width(char()) -> 0 | 1 | 2.
cp_width(Cp) when Cp >= 16#20, Cp =< 16#7E ->
    %% Printable ASCII fast path — no table lookups.
    1;
cp_width(Cp) ->
    case in_table(Cp, zero_ranges()) of
        true ->
            0;
        false ->
            case in_table(Cp, wide_ranges()) of
                true -> 2;
                false -> 1
            end
    end.

%%% -- normalisation ---------------------------------------------------

%% Reduce any accepted grapheme representation to a flat list of codepoints.
%% Best-effort on malformed encodings: use whatever prefix decoded cleanly.
-spec to_codepoints(grapheme()) -> [char()].
to_codepoints(Cp) when is_integer(Cp) ->
    [Cp];
to_codepoints(Chardata) ->
    case unicode:characters_to_list(Chardata) of
        L when is_list(L) -> L;
        {error, Good, _Rest} -> Good;
        {incomplete, Good, _Rest} -> Good
    end.

%%% -- interval-table lookup -------------------------------------------

%% Binary search over a tuple of sorted, non-overlapping {Lo, Hi} ranges.
-spec in_table(char(), tuple()) -> boolean().
in_table(Cp, Ranges) ->
    in_table(Cp, Ranges, 1, tuple_size(Ranges)).

in_table(_Cp, _Ranges, Lo, Hi) when Lo > Hi ->
    false;
in_table(Cp, Ranges, Lo, Hi) ->
    Mid = (Lo + Hi) div 2,
    case element(Mid, Ranges) of
        {L, _} when Cp < L -> in_table(Cp, Ranges, Lo, Mid - 1);
        {_, H} when Cp > H -> in_table(Cp, Ranges, Mid + 1, Hi);
        _ -> true
    end.

%%% -- width data (Unicode 16.0) ---------------------------------------
%%%
%%% Both tables are compile-time literal constants (Erlang stores them once in
%%% the module's literal pool; they are not rebuilt per call). Ranges are
%%% sorted ascending and non-overlapping so in_table/2 can binary-search them.

%% East Asian Wide (W) + Fullwidth (F) codepoints, plus the emoji blocks that
%% render double-width: CJK ideographs + extensions, Hiragana/Katakana, Hangul
%% syllables & Jamo, CJK symbols/punctuation, fullwidth forms, Yijing/Tai Xuan
%% Jing symbols, and the emoji ranges (Misc Symbols & Pictographs, Emoticons,
%% Transport, Supplemental Symbols, Symbols & Pictographs Extended-A).
-spec wide_ranges() -> tuple().
wide_ranges() ->
    {
        {16#1100, 16#115F},
        {16#231A, 16#231B},
        {16#2329, 16#232A},
        {16#23E9, 16#23EC},
        {16#23F0, 16#23F0},
        {16#23F3, 16#23F3},
        {16#25FD, 16#25FE},
        {16#2614, 16#2615},
        {16#2630, 16#2637},
        {16#2648, 16#2653},
        {16#267F, 16#267F},
        {16#268A, 16#268F},
        {16#2693, 16#2693},
        {16#26A1, 16#26A1},
        {16#26AA, 16#26AB},
        {16#26BD, 16#26BE},
        {16#26C4, 16#26C5},
        {16#26CE, 16#26CE},
        {16#26D4, 16#26D4},
        {16#26EA, 16#26EA},
        {16#26F2, 16#26F3},
        {16#26F5, 16#26F5},
        {16#26FA, 16#26FA},
        {16#26FD, 16#26FD},
        {16#2705, 16#2705},
        {16#270A, 16#270B},
        {16#2728, 16#2728},
        {16#274C, 16#274C},
        {16#274E, 16#274E},
        {16#2753, 16#2755},
        {16#2757, 16#2757},
        {16#2795, 16#2797},
        {16#27B0, 16#27B0},
        {16#27BF, 16#27BF},
        {16#2B1B, 16#2B1C},
        {16#2B50, 16#2B50},
        {16#2B55, 16#2B55},
        {16#2E80, 16#2E99},
        {16#2E9B, 16#2EF3},
        {16#2F00, 16#2FD5},
        {16#2FF0, 16#303E},
        {16#3041, 16#3096},
        {16#3099, 16#30FF},
        {16#3105, 16#312F},
        {16#3131, 16#318E},
        {16#3190, 16#31E5},
        {16#31EF, 16#321E},
        {16#3220, 16#3247},
        {16#3250, 16#A48C},
        {16#A490, 16#A4C6},
        {16#A960, 16#A97C},
        {16#AC00, 16#D7A3},
        {16#F900, 16#FAFF},
        {16#FE10, 16#FE19},
        {16#FE30, 16#FE52},
        {16#FE54, 16#FE66},
        {16#FE68, 16#FE6B},
        {16#FF01, 16#FF60},
        {16#FFE0, 16#FFE6},
        {16#16FE0, 16#16FE4},
        {16#16FF0, 16#16FF1},
        {16#17000, 16#187F7},
        {16#18800, 16#18CD5},
        {16#18CFF, 16#18D08},
        {16#1AFF0, 16#1AFF3},
        {16#1AFF5, 16#1AFFB},
        {16#1AFFD, 16#1AFFE},
        {16#1B000, 16#1B122},
        {16#1B132, 16#1B132},
        {16#1B150, 16#1B152},
        {16#1B155, 16#1B155},
        {16#1B164, 16#1B167},
        {16#1B170, 16#1B2FB},
        {16#1D300, 16#1D356},
        {16#1D360, 16#1D376},
        {16#1F004, 16#1F004},
        {16#1F0CF, 16#1F0CF},
        {16#1F18E, 16#1F18E},
        {16#1F191, 16#1F19A},
        {16#1F200, 16#1F202},
        {16#1F210, 16#1F23B},
        {16#1F240, 16#1F248},
        {16#1F250, 16#1F251},
        {16#1F260, 16#1F265},
        {16#1F300, 16#1F320},
        {16#1F32D, 16#1F335},
        {16#1F337, 16#1F37C},
        {16#1F37E, 16#1F393},
        {16#1F3A0, 16#1F3CA},
        {16#1F3CF, 16#1F3D3},
        {16#1F3E0, 16#1F3F0},
        {16#1F3F4, 16#1F3F4},
        {16#1F3F8, 16#1F43E},
        {16#1F440, 16#1F440},
        {16#1F442, 16#1F4FC},
        {16#1F4FF, 16#1F53D},
        {16#1F54B, 16#1F54E},
        {16#1F550, 16#1F567},
        {16#1F57A, 16#1F57A},
        {16#1F595, 16#1F596},
        {16#1F5A4, 16#1F5A4},
        {16#1F5FB, 16#1F64F},
        {16#1F680, 16#1F6C5},
        {16#1F6CC, 16#1F6CC},
        {16#1F6D0, 16#1F6D2},
        {16#1F6D5, 16#1F6D7},
        {16#1F6DC, 16#1F6DF},
        {16#1F6EB, 16#1F6EC},
        {16#1F6F4, 16#1F6FC},
        {16#1F7E0, 16#1F7EB},
        {16#1F7F0, 16#1F7F0},
        {16#1F90C, 16#1F93A},
        {16#1F93C, 16#1F945},
        {16#1F947, 16#1F9FF},
        {16#1FA70, 16#1FA7C},
        {16#1FA80, 16#1FA89},
        {16#1FA8F, 16#1FAC6},
        {16#1FACE, 16#1FADC},
        {16#1FADF, 16#1FAE9},
        {16#1FAF0, 16#1FAF8},
        {16#20000, 16#2FFFD},
        {16#30000, 16#3FFFD}
    }.

%% Zero-width codepoints: Unicode general categories Mn (non-spacing mark),
%% Me (enclosing mark), Cf (format: ZWSP U+200B, ZWNJ/ZWJ, BOM, ...) and Cc
%% (C0/C1 controls incl. DEL), plus the variation selectors (U+FE00-FE0F and
%% the U+E0100-E01EF supplement) and tag characters. Spacing combining marks
%% (Mc) are treated as width 1 — see the correctness note in the tests.
-spec zero_ranges() -> tuple().
zero_ranges() ->
    {
        {16#0, 16#1F},
        {16#7F, 16#9F},
        {16#AD, 16#AD},
        {16#300, 16#36F},
        {16#483, 16#489},
        {16#591, 16#5BD},
        {16#5BF, 16#5BF},
        {16#5C1, 16#5C2},
        {16#5C4, 16#5C5},
        {16#5C7, 16#5C7},
        {16#600, 16#605},
        {16#610, 16#61A},
        {16#61C, 16#61C},
        {16#64B, 16#65F},
        {16#670, 16#670},
        {16#6D6, 16#6DD},
        {16#6DF, 16#6E4},
        {16#6E7, 16#6E8},
        {16#6EA, 16#6ED},
        {16#70F, 16#70F},
        {16#711, 16#711},
        {16#730, 16#74A},
        {16#7A6, 16#7B0},
        {16#7EB, 16#7F3},
        {16#7FD, 16#7FD},
        {16#816, 16#819},
        {16#81B, 16#823},
        {16#825, 16#827},
        {16#829, 16#82D},
        {16#859, 16#85B},
        {16#890, 16#891},
        {16#897, 16#89F},
        {16#8CA, 16#902},
        {16#93A, 16#93A},
        {16#93C, 16#93C},
        {16#941, 16#948},
        {16#94D, 16#94D},
        {16#951, 16#957},
        {16#962, 16#963},
        {16#981, 16#981},
        {16#9BC, 16#9BC},
        {16#9C1, 16#9C4},
        {16#9CD, 16#9CD},
        {16#9E2, 16#9E3},
        {16#9FE, 16#9FE},
        {16#A01, 16#A02},
        {16#A3C, 16#A3C},
        {16#A41, 16#A42},
        {16#A47, 16#A48},
        {16#A4B, 16#A4D},
        {16#A51, 16#A51},
        {16#A70, 16#A71},
        {16#A75, 16#A75},
        {16#A81, 16#A82},
        {16#ABC, 16#ABC},
        {16#AC1, 16#AC5},
        {16#AC7, 16#AC8},
        {16#ACD, 16#ACD},
        {16#AE2, 16#AE3},
        {16#AFA, 16#AFF},
        {16#B01, 16#B01},
        {16#B3C, 16#B3C},
        {16#B3F, 16#B3F},
        {16#B41, 16#B44},
        {16#B4D, 16#B4D},
        {16#B55, 16#B56},
        {16#B62, 16#B63},
        {16#B82, 16#B82},
        {16#BC0, 16#BC0},
        {16#BCD, 16#BCD},
        {16#C00, 16#C00},
        {16#C04, 16#C04},
        {16#C3C, 16#C3C},
        {16#C3E, 16#C40},
        {16#C46, 16#C48},
        {16#C4A, 16#C4D},
        {16#C55, 16#C56},
        {16#C62, 16#C63},
        {16#C81, 16#C81},
        {16#CBC, 16#CBC},
        {16#CBF, 16#CBF},
        {16#CC6, 16#CC6},
        {16#CCC, 16#CCD},
        {16#CE2, 16#CE3},
        {16#D00, 16#D01},
        {16#D3B, 16#D3C},
        {16#D41, 16#D44},
        {16#D4D, 16#D4D},
        {16#D62, 16#D63},
        {16#D81, 16#D81},
        {16#DCA, 16#DCA},
        {16#DD2, 16#DD4},
        {16#DD6, 16#DD6},
        {16#E31, 16#E31},
        {16#E34, 16#E3A},
        {16#E47, 16#E4E},
        {16#EB1, 16#EB1},
        {16#EB4, 16#EBC},
        {16#EC8, 16#ECE},
        {16#F18, 16#F19},
        {16#F35, 16#F35},
        {16#F37, 16#F37},
        {16#F39, 16#F39},
        {16#F71, 16#F7E},
        {16#F80, 16#F84},
        {16#F86, 16#F87},
        {16#F8D, 16#F97},
        {16#F99, 16#FBC},
        {16#FC6, 16#FC6},
        {16#102D, 16#1030},
        {16#1032, 16#1037},
        {16#1039, 16#103A},
        {16#103D, 16#103E},
        {16#1058, 16#1059},
        {16#105E, 16#1060},
        {16#1071, 16#1074},
        {16#1082, 16#1082},
        {16#1085, 16#1086},
        {16#108D, 16#108D},
        {16#109D, 16#109D},
        {16#135D, 16#135F},
        {16#1712, 16#1714},
        {16#1732, 16#1733},
        {16#1752, 16#1753},
        {16#1772, 16#1773},
        {16#17B4, 16#17B5},
        {16#17B7, 16#17BD},
        {16#17C6, 16#17C6},
        {16#17C9, 16#17D3},
        {16#17DD, 16#17DD},
        {16#180B, 16#180F},
        {16#1885, 16#1886},
        {16#18A9, 16#18A9},
        {16#1920, 16#1922},
        {16#1927, 16#1928},
        {16#1932, 16#1932},
        {16#1939, 16#193B},
        {16#1A17, 16#1A18},
        {16#1A1B, 16#1A1B},
        {16#1A56, 16#1A56},
        {16#1A58, 16#1A5E},
        {16#1A60, 16#1A60},
        {16#1A62, 16#1A62},
        {16#1A65, 16#1A6C},
        {16#1A73, 16#1A7C},
        {16#1A7F, 16#1A7F},
        {16#1AB0, 16#1ACE},
        {16#1B00, 16#1B03},
        {16#1B34, 16#1B34},
        {16#1B36, 16#1B3A},
        {16#1B3C, 16#1B3C},
        {16#1B42, 16#1B42},
        {16#1B6B, 16#1B73},
        {16#1B80, 16#1B81},
        {16#1BA2, 16#1BA5},
        {16#1BA8, 16#1BA9},
        {16#1BAB, 16#1BAD},
        {16#1BE6, 16#1BE6},
        {16#1BE8, 16#1BE9},
        {16#1BED, 16#1BED},
        {16#1BEF, 16#1BF1},
        {16#1C2C, 16#1C33},
        {16#1C36, 16#1C37},
        {16#1CD0, 16#1CD2},
        {16#1CD4, 16#1CE0},
        {16#1CE2, 16#1CE8},
        {16#1CED, 16#1CED},
        {16#1CF4, 16#1CF4},
        {16#1CF8, 16#1CF9},
        {16#1DC0, 16#1DFF},
        {16#200B, 16#200F},
        {16#202A, 16#202E},
        {16#2060, 16#2064},
        {16#2066, 16#206F},
        {16#20D0, 16#20F0},
        {16#2CEF, 16#2CF1},
        {16#2D7F, 16#2D7F},
        {16#2DE0, 16#2DFF},
        {16#302A, 16#302D},
        {16#3099, 16#309A},
        {16#A66F, 16#A672},
        {16#A674, 16#A67D},
        {16#A69E, 16#A69F},
        {16#A6F0, 16#A6F1},
        {16#A802, 16#A802},
        {16#A806, 16#A806},
        {16#A80B, 16#A80B},
        {16#A825, 16#A826},
        {16#A82C, 16#A82C},
        {16#A8C4, 16#A8C5},
        {16#A8E0, 16#A8F1},
        {16#A8FF, 16#A8FF},
        {16#A926, 16#A92D},
        {16#A947, 16#A951},
        {16#A980, 16#A982},
        {16#A9B3, 16#A9B3},
        {16#A9B6, 16#A9B9},
        {16#A9BC, 16#A9BD},
        {16#A9E5, 16#A9E5},
        {16#AA29, 16#AA2E},
        {16#AA31, 16#AA32},
        {16#AA35, 16#AA36},
        {16#AA43, 16#AA43},
        {16#AA4C, 16#AA4C},
        {16#AA7C, 16#AA7C},
        {16#AAB0, 16#AAB0},
        {16#AAB2, 16#AAB4},
        {16#AAB7, 16#AAB8},
        {16#AABE, 16#AABF},
        {16#AAC1, 16#AAC1},
        {16#AAEC, 16#AAED},
        {16#AAF6, 16#AAF6},
        {16#ABE5, 16#ABE5},
        {16#ABE8, 16#ABE8},
        {16#ABED, 16#ABED},
        {16#FB1E, 16#FB1E},
        {16#FE00, 16#FE0F},
        {16#FE20, 16#FE2F},
        {16#FEFF, 16#FEFF},
        {16#FFF9, 16#FFFB},
        {16#101FD, 16#101FD},
        {16#102E0, 16#102E0},
        {16#10376, 16#1037A},
        {16#10A01, 16#10A03},
        {16#10A05, 16#10A06},
        {16#10A0C, 16#10A0F},
        {16#10A38, 16#10A3A},
        {16#10A3F, 16#10A3F},
        {16#10AE5, 16#10AE6},
        {16#10D24, 16#10D27},
        {16#10D69, 16#10D6D},
        {16#10EAB, 16#10EAC},
        {16#10EFC, 16#10EFF},
        {16#10F46, 16#10F50},
        {16#10F82, 16#10F85},
        {16#11001, 16#11001},
        {16#11038, 16#11046},
        {16#11070, 16#11070},
        {16#11073, 16#11074},
        {16#1107F, 16#11081},
        {16#110B3, 16#110B6},
        {16#110B9, 16#110BA},
        {16#110BD, 16#110BD},
        {16#110C2, 16#110C2},
        {16#110CD, 16#110CD},
        {16#11100, 16#11102},
        {16#11127, 16#1112B},
        {16#1112D, 16#11134},
        {16#11173, 16#11173},
        {16#11180, 16#11181},
        {16#111B6, 16#111BE},
        {16#111C9, 16#111CC},
        {16#111CF, 16#111CF},
        {16#1122F, 16#11231},
        {16#11234, 16#11234},
        {16#11236, 16#11237},
        {16#1123E, 16#1123E},
        {16#11241, 16#11241},
        {16#112DF, 16#112DF},
        {16#112E3, 16#112EA},
        {16#11300, 16#11301},
        {16#1133B, 16#1133C},
        {16#11340, 16#11340},
        {16#11366, 16#1136C},
        {16#11370, 16#11374},
        {16#113BB, 16#113C0},
        {16#113CE, 16#113CE},
        {16#113D0, 16#113D0},
        {16#113D2, 16#113D2},
        {16#113E1, 16#113E2},
        {16#11438, 16#1143F},
        {16#11442, 16#11444},
        {16#11446, 16#11446},
        {16#1145E, 16#1145E},
        {16#114B3, 16#114B8},
        {16#114BA, 16#114BA},
        {16#114BF, 16#114C0},
        {16#114C2, 16#114C3},
        {16#115B2, 16#115B5},
        {16#115BC, 16#115BD},
        {16#115BF, 16#115C0},
        {16#115DC, 16#115DD},
        {16#11633, 16#1163A},
        {16#1163D, 16#1163D},
        {16#1163F, 16#11640},
        {16#116AB, 16#116AB},
        {16#116AD, 16#116AD},
        {16#116B0, 16#116B5},
        {16#116B7, 16#116B7},
        {16#1171D, 16#1171D},
        {16#1171F, 16#1171F},
        {16#11722, 16#11725},
        {16#11727, 16#1172B},
        {16#1182F, 16#11837},
        {16#11839, 16#1183A},
        {16#1193B, 16#1193C},
        {16#1193E, 16#1193E},
        {16#11943, 16#11943},
        {16#119D4, 16#119D7},
        {16#119DA, 16#119DB},
        {16#119E0, 16#119E0},
        {16#11A01, 16#11A0A},
        {16#11A33, 16#11A38},
        {16#11A3B, 16#11A3E},
        {16#11A47, 16#11A47},
        {16#11A51, 16#11A56},
        {16#11A59, 16#11A5B},
        {16#11A8A, 16#11A96},
        {16#11A98, 16#11A99},
        {16#11C30, 16#11C36},
        {16#11C38, 16#11C3D},
        {16#11C3F, 16#11C3F},
        {16#11C92, 16#11CA7},
        {16#11CAA, 16#11CB0},
        {16#11CB2, 16#11CB3},
        {16#11CB5, 16#11CB6},
        {16#11D31, 16#11D36},
        {16#11D3A, 16#11D3A},
        {16#11D3C, 16#11D3D},
        {16#11D3F, 16#11D45},
        {16#11D47, 16#11D47},
        {16#11D90, 16#11D91},
        {16#11D95, 16#11D95},
        {16#11D97, 16#11D97},
        {16#11EF3, 16#11EF4},
        {16#11F00, 16#11F01},
        {16#11F36, 16#11F3A},
        {16#11F40, 16#11F40},
        {16#11F42, 16#11F42},
        {16#11F5A, 16#11F5A},
        {16#13430, 16#13440},
        {16#13447, 16#13455},
        {16#1611E, 16#16129},
        {16#1612D, 16#1612F},
        {16#16AF0, 16#16AF4},
        {16#16B30, 16#16B36},
        {16#16F4F, 16#16F4F},
        {16#16F8F, 16#16F92},
        {16#16FE4, 16#16FE4},
        {16#1BC9D, 16#1BC9E},
        {16#1BCA0, 16#1BCA3},
        {16#1CF00, 16#1CF2D},
        {16#1CF30, 16#1CF46},
        {16#1D167, 16#1D169},
        {16#1D173, 16#1D182},
        {16#1D185, 16#1D18B},
        {16#1D1AA, 16#1D1AD},
        {16#1D242, 16#1D244},
        {16#1DA00, 16#1DA36},
        {16#1DA3B, 16#1DA6C},
        {16#1DA75, 16#1DA75},
        {16#1DA84, 16#1DA84},
        {16#1DA9B, 16#1DA9F},
        {16#1DAA1, 16#1DAAF},
        {16#1E000, 16#1E006},
        {16#1E008, 16#1E018},
        {16#1E01B, 16#1E021},
        {16#1E023, 16#1E024},
        {16#1E026, 16#1E02A},
        {16#1E08F, 16#1E08F},
        {16#1E130, 16#1E136},
        {16#1E2AE, 16#1E2AE},
        {16#1E2EC, 16#1E2EF},
        {16#1E4EC, 16#1E4EF},
        {16#1E5EE, 16#1E5EF},
        {16#1E8D0, 16#1E8D6},
        {16#1E944, 16#1E94A},
        {16#E0001, 16#E0001},
        {16#E0020, 16#E007F},
        {16#E0100, 16#E01EF}
    }.

%% Extended_Pictographic code points (Unicode 16.0), derived by probing
%% the unicode_util grapheme-break rules; regenerable via
%% priv/gen_extpict.escript. Gates emoji presentation on genuine emoji
%% bases so wide non-emoji (CJK) and a non-emoji base + VS16 are not
%% treated as emoji. 78 ranges.
-spec extended_pictographic_ranges() -> tuple().
extended_pictographic_ranges() ->
    {
        {16#00A9, 16#00A9},
        {16#00AE, 16#00AE},
        {16#203C, 16#203C},
        {16#2049, 16#2049},
        {16#2122, 16#2122},
        {16#2139, 16#2139},
        {16#2194, 16#2199},
        {16#21A9, 16#21AA},
        {16#231A, 16#231B},
        {16#2328, 16#2328},
        {16#2388, 16#2388},
        {16#23CF, 16#23CF},
        {16#23E9, 16#23F3},
        {16#23F8, 16#23FA},
        {16#24C2, 16#24C2},
        {16#25AA, 16#25AB},
        {16#25B6, 16#25B6},
        {16#25C0, 16#25C0},
        {16#25FB, 16#25FE},
        {16#2600, 16#2605},
        {16#2607, 16#2612},
        {16#2614, 16#2685},
        {16#2690, 16#2705},
        {16#2708, 16#2712},
        {16#2714, 16#2714},
        {16#2716, 16#2716},
        {16#271D, 16#271D},
        {16#2721, 16#2721},
        {16#2728, 16#2728},
        {16#2733, 16#2734},
        {16#2744, 16#2744},
        {16#2747, 16#2747},
        {16#274C, 16#274C},
        {16#274E, 16#274E},
        {16#2753, 16#2755},
        {16#2757, 16#2757},
        {16#2763, 16#2767},
        {16#2795, 16#2797},
        {16#27A1, 16#27A1},
        {16#27B0, 16#27B0},
        {16#27BF, 16#27BF},
        {16#2934, 16#2935},
        {16#2B05, 16#2B07},
        {16#2B1B, 16#2B1C},
        {16#2B50, 16#2B50},
        {16#2B55, 16#2B55},
        {16#3030, 16#3030},
        {16#303D, 16#303D},
        {16#3297, 16#3297},
        {16#3299, 16#3299},
        {16#1F000, 16#1F0FF},
        {16#1F10D, 16#1F10F},
        {16#1F12F, 16#1F12F},
        {16#1F16C, 16#1F171},
        {16#1F17E, 16#1F17F},
        {16#1F18E, 16#1F18E},
        {16#1F191, 16#1F19A},
        {16#1F1AD, 16#1F1E5},
        {16#1F201, 16#1F20F},
        {16#1F21A, 16#1F21A},
        {16#1F22F, 16#1F22F},
        {16#1F232, 16#1F23A},
        {16#1F23C, 16#1F23F},
        {16#1F249, 16#1F3FA},
        {16#1F400, 16#1F53D},
        {16#1F546, 16#1F64F},
        {16#1F680, 16#1F6FF},
        {16#1F774, 16#1F77F},
        {16#1F7D5, 16#1F7FF},
        {16#1F80C, 16#1F80F},
        {16#1F848, 16#1F84F},
        {16#1F85A, 16#1F85F},
        {16#1F888, 16#1F88F},
        {16#1F8AE, 16#1F8FF},
        {16#1F90C, 16#1F93A},
        {16#1F93C, 16#1F945},
        {16#1F947, 16#1FAFF},
        {16#1FC00, 16#1FFFD}
    }.
