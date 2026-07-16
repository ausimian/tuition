%%%-------------------------------------------------------------------
%%% @doc Thin driver wiring the terminal seam to the input parser.
%%%
%%% {@link tuition_input} is a pure, timerless decoder; this module supplies the
%%% one piece of timing it deliberately leaves out — the bounded read whose
%%% `timeout' triggers lone-ESC resolution (PRD §8). The `receive ... after'
%%% itself lives in {@link tuition_term:read/2}; {@link poll/3} connects a read
%%% `timeout' to {@link tuition_input:flush/1}.
%%%
%%% It is intentionally minimal: it advances the parser by exactly one bounded
%%% read and returns the events produced. The full event loop (issues #6/#8)
%%% owns dispatch, batching and lifecycle; this just proves the timeout path
%%% end-to-end and gives that loop a single primitive to build on.
%%%
%%% Typical use — call {@link poll/3} in a loop, threading the parser state:
%%% <pre>
%%%   loop(Handle, St0) ->
%%%       case tuition_input_driver:poll(Handle, St0, 1000) of
%%%           {ok, Events, St1} ->
%%%               lists:foreach(fun handle_event/1, Events),
%%%               loop(Handle, St1);
%%%           {error, Reason} ->
%%%               {stopped, Reason}
%%%       end.
%%% </pre>
%%% @end
%%%-------------------------------------------------------------------
-module(tuition_input_driver).

-export([poll/3]).

%% Inter-byte window for disambiguating a lone ESC from an escape sequence.
%% Once a partial is buffered, a read that stays quiet this long means "no more
%% bytes are coming", so the partial (a bare ESC) is flushed to an Escape key.
-define(ESC_TIMEOUT, 50).

%% @doc Advance the parser by one bounded read.
%%
%% The short {@link ESC_TIMEOUT} applies only when an ESC-initiated sequence is
%% buffered ({@link tuition_input:awaiting_escape/1}) so a lone `ESC' resolves to
%% Escape promptly; otherwise the read uses `IdleTimeout' (the caller's choice of
%% how long to wait for fresh input). This matters because the reader is
%% byte-at-a-time: a split multi-byte UTF-8 character must NOT be forced onto the
%% 50ms window, or inter-byte jitter (SSH, a loaded system) would time out
%% between its bytes and `flush/1' would corrupt it into replacement characters.
%%
%% Incoming bytes are decoded via {@link tuition_input:parse/2}. A read `timeout'
%% flushes the buffered partial via {@link tuition_input:flush/1} ONLY when it is
%% an ESC awaiting disambiguation; a non-ESC partial (incomplete UTF-8) is left
%% buffered for the next read rather than flushed. Either way the produced events
%% (possibly empty) and the advanced state are returned.
-spec poll(tuition_term:handle(), tuition_input:state(), timeout()) ->
    {ok, [tuition_input:event()], tuition_input:state()} | {error, term()}.
poll(Handle, St, IdleTimeout) ->
    AwaitingEsc = tuition_input:awaiting_escape(St),
    Timeout =
        case AwaitingEsc of
            true -> ?ESC_TIMEOUT;
            false -> IdleTimeout
        end,
    case tuition_term:read(Handle, Timeout) of
        {ok, Bytes} ->
            {Events, St1} = tuition_input:parse(Bytes, St),
            {ok, Events, St1};
        timeout when AwaitingEsc ->
            {Events, St1} = tuition_input:flush(St),
            {ok, Events, St1};
        timeout ->
            %% Idle read with no ESC pending: keep any (UTF-8) partial buffered.
            {ok, [], St};
        {error, Reason} ->
            {error, Reason}
    end.
