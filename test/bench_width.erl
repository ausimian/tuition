%%%-------------------------------------------------------------------
%%% @doc Microbenchmark for {@link sonde_width:swidth/1}.
%%%
%%% PRD §8 flags Unicode display-width as the #1 correctness/perf risk: every
%%% rendered cell run is measured with this, so it sits on the hot path. The
%%% input is a representative terminal line mixing the cases `swidth' has to
%%% get right — plain ASCII, wide CJK, a combining-mark cluster, a ZWJ emoji
%%% sequence, a regional-indicator flag, a skin-tone-modified emoji, and a
%%% VS16-promoted emoji — repeated to a realistic line length.
%%%
%%% Legacy `rebar3_bench' callbacks: `swidth/1' prepares the (cached) input and
%%% `bench_swidth/2' is the timed body. Run with `rebar3 as bench bench'.
%%% @end
%%%-------------------------------------------------------------------
-module(bench_width).

-export([swidth/1, bench_swidth/2]).

%% Prepare the benchmark input once: a mixed-script line copied several times.
swidth({input, _}) ->
    Segment = unicode:characters_to_binary([
        %% ASCII
        "The quick brown fox ",
        %% Wide CJK ideographs + kana
        "日本語のテキスト ",
        %% e + combining acute -> one width-1 cluster
        [$e, 16#0301],
        " ",
        %% ZWJ family sequence (man+ZWJ+woman+ZWJ+girl), one width-2 cluster
        [16#1F468, 16#200D, 16#1F469, 16#200D, 16#1F467],
        " ",
        %% Regional-indicator pair -> US flag, one width-2 cluster
        [16#1F1FA, 16#1F1F8],
        " ",
        %% Pointing hand + skin-tone modifier, one width-2 cluster
        [16#261D, 16#1F3FD],
        " ",
        %% Text-default heart promoted to emoji presentation by VS16
        [16#2764, 16#FE0F],
        "\n"
    ]),
    binary:copy(Segment, 8).

%% Timed body: measure the display width of the whole mixed line.
bench_swidth(Input, _) ->
    sonde_width:swidth(Input).
