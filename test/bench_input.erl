%%%-------------------------------------------------------------------
%%% @doc Microbenchmark for {@link sonde_input:parse/2}.
%%%
%%% Every keystroke and paste passes through the input parser, so decoding raw
%%% bytes into events is a hot path for interactive latency (PRD §8). The input
%%% is a byte stream that stresses the interesting branches together: CSI arrow
%%% and edit keys, a modified CSI, an SS3 function key, control bytes, and
%%% multi-byte UTF-8 (CJK and a 4-byte emoji) interleaved with plain ASCII —
%%% repeated into a paste-sized chunk parsed in a single call.
%%%
%%% Legacy `rebar3_bench' callbacks: `parse/1' prepares the (cached) input and
%%% `bench_parse/2' is the timed body. Run with `rebar3 as bench bench'.
%%% @end
%%%-------------------------------------------------------------------
-module(bench_input).

-export([parse/1, bench_parse/2]).

%% Prepare the benchmark input once: a mixed byte stream + a fresh parser state.
parse({input, _}) ->
    Seq = [
        %% ASCII printable run
        <<"hello ">>,
        %% Up arrow (CSI)
        <<16#1B, $[, $A>>,
        %% Ctrl+Right (CSI with modifier)
        <<16#1B, $[, $1, $;, $5, $C>>,
        %% F1 (SS3)
        <<16#1B, $O, $P>>,
        %% Delete (CSI tilde)
        <<16#1B, $[, $3, $~>>,
        %% wide CJK, 3-byte UTF-8
        <<"日"/utf8>>,
        %% grinning face, 4-byte UTF-8
        <<16#1F600/utf8>>,
        %% Tab
        <<$\t>>,
        %% Ctrl-A control byte
        <<1>>
    ],
    Bytes = iolist_to_binary(lists:duplicate(16, Seq)),
    {Bytes, sonde_input:new()}.

%% Timed body: decode the whole stream from a fresh parser state.
bench_parse({Bytes, State}, _) ->
    sonde_input:parse(Bytes, State).
