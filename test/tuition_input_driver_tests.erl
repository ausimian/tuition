-module(tuition_input_driver_tests).

-include_lib("eunit/include/eunit.hrl").

%% A complete sequence in one read decodes directly.
poll_decodes_bytes_test() ->
    Handle = handle([{ok, <<"\e[A">>}]),
    {ok, Events, _St} = tuition_input_driver:poll(Handle, tuition_input:new(), 1000),
    ?assertEqual([{key, up, []}], Events).

%% The end-to-end lone-ESC path: a read delivers a bare ESC (no event yet),
%% then the next read times out and the driver flushes it to Escape.
poll_lone_esc_flushes_on_timeout_test() ->
    Handle = handle([{ok, <<"\e">>}, timeout]),
    St0 = tuition_input:new(),
    {ok, E1, St1} = tuition_input_driver:poll(Handle, St0, 1000),
    ?assertEqual([], E1),
    ?assert(tuition_input:pending(St1)),
    {ok, E2, St2} = tuition_input_driver:poll(Handle, St1, 1000),
    ?assertEqual([{key, esc, []}], E2),
    ?assertNot(tuition_input:pending(St2)).

%% ESC then a real escape sequence across two reads yields the sequence, not
%% Escape — the buffered ESC is completed, never flushed.
poll_esc_sequence_not_flushed_test() ->
    Handle = handle([{ok, <<"\e">>}, {ok, <<"[A">>}]),
    St0 = tuition_input:new(),
    {ok, E1, St1} = tuition_input_driver:poll(Handle, St0, 1000),
    ?assertEqual([], E1),
    {ok, E2, _St2} = tuition_input_driver:poll(Handle, St1, 1000),
    ?assertEqual([{key, up, []}], E2).

%% A split multi-byte UTF-8 char must survive an idle timeout between its bytes:
%% the timeout must NOT flush it to a replacement character. Bytes: C3, timeout,
%% A9 -> one "é", not two U+FFFD.
poll_utf8_partial_not_flushed_on_timeout_test() ->
    Handle = handle([{ok, <<16#C3>>}, timeout, {ok, <<16#A9>>}]),
    St0 = tuition_input:new(),
    {ok, E1, St1} = tuition_input_driver:poll(Handle, St0, 1000),
    ?assertEqual([], E1),
    ?assert(tuition_input:pending(St1)),
    ?assertNot(tuition_input:awaiting_escape(St1)),
    {ok, E2, St2} = tuition_input_driver:poll(Handle, St1, 1000),
    ?assertEqual([], E2),
    ?assert(tuition_input:pending(St2)),
    {ok, E3, _St3} = tuition_input_driver:poll(Handle, St2, 1000),
    ?assertEqual([{key, {char, 16#E9}, []}], E3).

%% Alt+multibyte delivered byte-by-byte with a timeout between the UTF-8 lead
%% and its continuation must still decode as one Alt-modified char — the timeout
%% must NOT flush `<<ESC, C3>>` to a bare Escape. Bytes: ESC, C3, timeout, A9.
poll_alt_utf8_not_flushed_to_escape_test() ->
    Handle = handle([{ok, <<"\e">>}, {ok, <<16#C3>>}, timeout, {ok, <<16#A9>>}]),
    St0 = tuition_input:new(),
    {ok, E1, St1} = tuition_input_driver:poll(Handle, St0, 1000),
    {ok, E2, St2} = tuition_input_driver:poll(Handle, St1, 1000),
    %% After ESC then the UTF-8 lead, no longer escape-ambiguous.
    ?assertNot(tuition_input:awaiting_escape(St2)),
    {ok, E3, St3} = tuition_input_driver:poll(Handle, St2, 1000),
    {ok, E4, _St4} = tuition_input_driver:poll(Handle, St3, 1000),
    ?assertEqual([], E1 ++ E2 ++ E3),
    ?assertEqual([{key, {char, 16#E9}, [alt]}], E4).

%% metaSendsEscape Alt+Up = ESC ESC [ A. Delivered byte-by-byte, the driver holds
%% the short escape timeout across the nested-ESC partials (never flushing the
%% pair to Escapes) and decodes one Alt+Up once the sequence completes.
poll_metasendsescape_alt_arrow_decodes_test() ->
    Handle = handle([{ok, <<"\e">>}, {ok, <<"\e">>}, {ok, <<"[">>}, {ok, <<"A">>}]),
    St0 = tuition_input:new(),
    {ok, E1, St1} = tuition_input_driver:poll(Handle, St0, 1000),
    {ok, E2, St2} = tuition_input_driver:poll(Handle, St1, 1000),
    {ok, E3, St3} = tuition_input_driver:poll(Handle, St2, 1000),
    ?assert(tuition_input:awaiting_escape(St1)),
    ?assert(tuition_input:awaiting_escape(St2)),
    ?assert(tuition_input:awaiting_escape(St3)),
    {ok, E4, _St4} = tuition_input_driver:poll(Handle, St3, 1000),
    ?assertEqual([], E1 ++ E2 ++ E3),
    ?assertEqual([{key, up, [alt]}], E4).

%% ESC ESC with nothing following: the read times out while the pair is buffered
%% and the driver flushes it to two Escapes in one call.
poll_double_escape_flushes_on_timeout_test() ->
    Handle = handle([{ok, <<"\e">>}, {ok, <<"\e">>}, timeout]),
    St0 = tuition_input:new(),
    {ok, E1, St1} = tuition_input_driver:poll(Handle, St0, 1000),
    {ok, E2, St2} = tuition_input_driver:poll(Handle, St1, 1000),
    ?assertEqual([], E1 ++ E2),
    ?assert(tuition_input:awaiting_escape(St2)),
    {ok, E3, St3} = tuition_input_driver:poll(Handle, St2, 1000),
    ?assertEqual([{key, esc, []}, {key, esc, []}], E3),
    ?assertNot(tuition_input:pending(St3)).

%% Regression: after an ESC-timeout flush of `ESC [ <utf8-lead>`, the split UTF-8
%% tail must survive to complete on a later read rather than being flushed to a
%% replacement char. Bytes: ESC [ C3, timeout (flush -> Escape + `[`, C3 kept),
%% then A9 completes é.
poll_flush_keeps_utf8_tail_then_completes_test() ->
    Handle = handle([{ok, <<"\e[", 16#C3>>}, timeout, {ok, <<16#A9>>}]),
    St0 = tuition_input:new(),
    {ok, E1, St1} = tuition_input_driver:poll(Handle, St0, 1000),
    ?assertEqual([], E1),
    ?assert(tuition_input:awaiting_escape(St1)),
    {ok, E2, St2} = tuition_input_driver:poll(Handle, St1, 1000),
    ?assertEqual([{key, esc, []}, {key, {char, $[}, []}], E2),
    ?assertNot(tuition_input:awaiting_escape(St2)),
    {ok, E3, _St3} = tuition_input_driver:poll(Handle, St2, 1000),
    ?assertEqual([{key, {char, 16#E9}, []}], E3).

%% A timeout with nothing buffered simply produces no events.
poll_idle_timeout_is_empty_test() ->
    Handle = handle([timeout]),
    {ok, Events, _St} = tuition_input_driver:poll(Handle, tuition_input:new(), 1000),
    ?assertEqual([], Events).

%% Read errors propagate unchanged.
poll_error_propagates_test() ->
    Handle = handle([{error, eof}]),
    ?assertEqual(
        {error, eof},
        tuition_input_driver:poll(Handle, tuition_input:new(), 1000)
    ).

handle(Script) ->
    {tuition_fake_term, tuition_fake_term:start(Script)}.
