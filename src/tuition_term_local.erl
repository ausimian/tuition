%%%-------------------------------------------------------------------
%%% @doc Local tty terminal backend (OTP 28 raw mode).
%%%
%%% Drives the current terminal via the OTP 28 `io' system. This is the Mode 1-3
%%% backend: the UI process runs locally and renders to the local tty. It has two
%%% submodes, chosen automatically at {@link open/1} time by how the shell
%%% responds to `shell:start_interactive({noshell, raw})':
%%%
%%% == Noshell submode (escript / `erl -noshell') ==
%%% `shell:start_interactive({noshell, raw})' returns `ok', putting the tty in
%%% raw input mode (keys delivered as typed, no echo) *and* raw output mode
%%% (bytes written verbatim, no ONLCR). Reads/writes/geometry all target the
%%% `user' device. This is the standalone tool / release path.
%%%
%%% == Cooperative submode (launched from a live `iex'/`erl', PRD §7 Mode 1) ==
%%% When a shell already owns the tty, `shell:start_interactive({noshell, raw})'
%%% returns `{error, already_started}'. Rather than refusing, the backend reads
%%% *cooperatively* through the current shell group: the OS tty is already in raw
%%% *input* mode (`edlin' does line editing in software), so turning `edlin' echo
%%% off with `io:setopts([{echo, false}])' and reading one byte at a time delivers
%%% each keystroke immediately, without Enter. Two facts (both validated live on
%%% OTP 28.3, see `docs/design/raw-mode-from-live-shell.md') shape this submode:
%%%
%%% <ul>
%%%   <li>Reads MUST target `group_leader()' (the current shell group), NOT
%%%       `user': `user' is not the current group in a live shell, so
%%%       `io:get_chars(user, …)' returns `{error, enotsup}'. Geometry, writes
%%%       and the opt restore all go to the group leader too.</li>
%%%   <li>Output stays ONLCR-cooked — `io:setopts([{onlcr, false}])' returns
%%%       `{error, enotsup}' on a shell group and there is no public way to flip
%%%       the tty's *output* submode. The renderer addresses the cursor
%%%       absolutely and never emits a bare `\n' (control codepoints are
%%%       sanitised out of cells), so ONLCR is harmless. This path does NOT emit
%%%       raw output.</li>
%%% </ul>
%%%
%%% Ctrl-C/Ctrl-G cannot be bound in cooperative mode: `user_drv' intercepts them
%%% ahead of the current group (Ctrl-C does `exit(current_group, interrupt)',
%%% i.e. a hard panic-detach the crash guard restores from). Quit is a normal key
%%% (`q'), handled by the render loop.
%%%
%%% == read/2 timeout contract ==
%%% `io:get_chars/3' is blocking, but {@link tuition_term} requires a bounded
%%% `read/2'. A dedicated linked reader process performs the blocking reads and
%%% forwards bytes to the owner as messages, so `read/2' is a plain
%%% `receive ... after Timeout'.
%%%
%%% == Crash-safe restoration (PRD §8/§10) ==
%%% Alternate-screen, cursor visibility and (cooperative submode) `edlin' echo are
%%% toggled by us, so restoring them is our responsibility. {@link close/1}
%%% restores them on the clean path; a linked guard process restores them if the
%%% owner dies abnormally, so a host VM that keeps running after the TUI (an
%%% embedded release, or a live shell) is left with a pristine prompt. In the
%%% noshell submode the raw termios state is owned by `prim_tty' and additionally
%%% restored by the runtime on VM exit.
%%% @end
%%%-------------------------------------------------------------------
-module(tuition_term_local).
-behaviour(tuition_term).

-export([open/1, write/2, read/2, size/1, close/1]).
%% Internal functions: spawned (reader_loop/2, guard_loop/5) or unit-tested
%% headlessly against a fake io server (saved_opts/2, do_restore/4).
-export([reader_loop/2, guard_loop/5, saved_opts/2, do_restore/4]).

%% shell:start_interactive/1 is spec'd `ok | {error, already_started}' upstream,
%% but at runtime it also returns `{error, enotsup}' on a host with no
%% controlling tty (headless CI, `erl -noshell' with redirected stdio) — see the
%% `{error, _}' clause and the enotsup path in tuition_demo_tests. dialyzer trusts
%% OTP's narrower spec and flags that clause as unreachable, so silence just this
%% false positive (no_match), not all of open/1.
-dialyzer({no_match, open/1}).

%% Enter alternate screen (?1049h) and hide the cursor (?25l).
-define(ENTER_SEQ, <<"\e[?1049h\e[?25l">>).
%% Reset SGR (0m), show the cursor (?25h), leave the alternate screen (?1049l).
-define(RESTORE_SEQ, <<"\e[0m\e[?25h\e[?1049l">>).
%% Cooperative-submode restore: the same ANSI plus a trailing CRLF so the shell
%% reprints its next prompt on a fresh line. `\r\n' (not a bare `\n') because
%% output is ONLCR-cooked here; the leading `\r' is idempotent under ONLCR.
-define(RESTORE_SEQ_COOP, <<?RESTORE_SEQ/binary, "\r\n">>).

%% The io opts open/1 overrides. latin1 makes the reader deliver raw *input*
%% bytes (any byte 0..255, so escape sequences and UTF-8 arrive intact for the
%% parser) and write/2 emit output verbatim; a single encoding governs both
%% directions. UTF-8 encoding and display width stay in the renderer (issue #5).
%% The cooperative submode additionally turns edlin echo off; the noshell submode
%% leaves echo to raw mode (do not touch it — keeps that path byte-identical).
-define(SETOPTS_NOSHELL, [binary, {encoding, latin1}]).
-define(SETOPTS_COOP, [{echo, false}, binary, {encoding, latin1}]).

-record(st, {
    owner :: pid(),
    reader :: pid(),
    guard :: pid(),
    %% Device every read/write/geometry/restore targets: `user' in the noshell
    %% submode, the group leader (a pid) in the cooperative submode.
    device :: io:device(),
    prev_opts :: [{atom(), term()}],
    %% ANSI restore payload (differs per submode: the cooperative one adds CRLF).
    restore_seq :: binary(),
    %% Whether close/1 and the guard must release global raw mode with
    %% `shell:start_interactive({noshell, cooked})'. True only in the noshell
    %% submode; in the cooperative submode the live shell still owns the tty, so
    %% we must NOT run that teardown.
    release_raw :: boolean()
}).
-opaque state() :: #st{}.
-export_type([state/0]).

%%% -- tuition_term callbacks --------------------------------------------

-spec open(map()) -> {ok, state()} | {error, term()}.
open(_Opts) ->
    case shell:start_interactive({noshell, raw}) of
        ok ->
            %% Noshell submode. `{noshell, raw}' can return `ok' even when io:user
            %% is not a tty (e.g. `erl -noshell' with stdin/stdout redirected),
            %% where the raw submode has no effect. Probe with io:columns/1 (which
            %% errors on a non-tty) and refuse rather than entering the alt-screen
            %% and spewing escape sequences into a pipe/log.
            case io:columns(user) of
                {ok, _} ->
                    enter(user, ?SETOPTS_NOSHELL, ?RESTORE_SEQ, true);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, already_started} ->
            %% Cooperative submode: a live shell owns the tty (launched from
            %% iex/erl). Borrow the current shell group (the group leader) as a
            %% raw byte pump. Reads/writes/geometry/restore all target it, NOT
            %% `user' (which is not the current group here → get_chars enotsup).
            GL = group_leader(),
            case io:columns(GL) of
                {ok, _} ->
                    enter(GL, ?SETOPTS_COOP, ?RESTORE_SEQ_COOP, false);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, _} = Error ->
            Error
    end.

-spec write(state(), iodata()) -> ok | {error, term()}.
write(#st{device = Device}, Data) ->
    %% Emit the already-rendered payload as raw bytes. The device is a latin1
    %% device (open/1), and latin1 tags a *binary* argument to put_chars as
    %% unicode — which transcodes/refuses code points > 255. Handing put_chars a
    %% *byte list* instead sidesteps that entirely: every byte (0..255) is latin1-
    %% representable and written verbatim, so the renderer's pre-encoded UTF-8
    %% passes through unaltered. iolist_to_binary/1 flattens and validates first;
    %% a stray code point > 255 is not byte iodata and is rejected as
    %% {error, non_byte_payload} rather than corrupting output. (In the
    %% cooperative submode output is ONLCR-cooked, but the renderer never emits a
    %% bare `\n', so nothing is translated.)
    try io:put_chars(Device, binary_to_list(iolist_to_binary(Data))) of
        ok -> ok
    catch
        error:badarg -> {error, non_byte_payload}
    end.

-spec read(state(), timeout()) -> {ok, binary()} | timeout | {error, term()}.
read(#st{reader = Reader}, Timeout) ->
    receive
        {?MODULE, Reader, {data, Bytes}} -> {ok, Bytes};
        {?MODULE, Reader, eof} -> {error, eof};
        {?MODULE, Reader, {error, Reason}} -> {error, Reason}
    after Timeout ->
        timeout
    end.

-spec size(state()) -> {ok, tuition_term:size()} | {error, term()}.
size(#st{device = Device}) ->
    case {io:columns(Device), io:rows(Device)} of
        {{ok, Cols}, {ok, Rows}} -> {ok, {Cols, Rows}};
        {{error, Reason}, _} -> {error, Reason};
        {_, {error, Reason}} -> {error, Reason}
    end.

-spec close(state()) -> ok.
close(#st{
    reader = Reader,
    guard = Guard,
    device = Device,
    prev_opts = Prev,
    restore_seq = RestoreSeq,
    release_raw = ReleaseRaw
}) ->
    %% Stop the reader, then restore while the guard is STILL live so that an
    %% owner kill mid-restore is still covered. Only once the terminal is fully
    %% restored do we silence the guard (a plain message, not an exit signal, so
    %% it is never mistaken for an owner exit).
    _ = stop_reader(Reader),
    do_restore(Device, RestoreSeq, Prev, ReleaseRaw),
    _ = silence_guard(Guard),
    ok.

%%% -- submode entry ---------------------------------------------------

%% Shared setup for both submodes: save the opts we override (so close/1 and the
%% guard can restore them), apply the raw io opts, start the linked reader and
%% guard against `Device', and enter the alternate screen.
-spec enter(io:device(), [term()], binary(), boolean()) -> {ok, state()}.
enter(Device, SetOpts, RestoreSeq, ReleaseRaw) ->
    Prev = saved_opts(Device, SetOpts),
    ok = io:setopts(Device, SetOpts),
    Owner = self(),
    Guard = spawn_link(?MODULE, guard_loop, [Owner, Device, RestoreSeq, Prev, ReleaseRaw]),
    Reader = spawn_link(?MODULE, reader_loop, [Owner, Device]),
    ok = io:put_chars(Device, ?ENTER_SEQ),
    {ok, #st{
        owner = Owner,
        reader = Reader,
        guard = Guard,
        device = Device,
        prev_opts = Prev,
        restore_seq = RestoreSeq,
        release_raw = ReleaseRaw
    }}.

%%% -- reader process --------------------------------------------------
%%
%% Blocks on a latin1 get_chars request against `Device' and forwards each chunk
%% to the owner. Reading a single byte at a time keeps latency low; the input
%% parser (issue #3) reassembles multi-byte escape sequences. In the cooperative
%% submode one byte per read is also *required*: the shell group is not in raw
%% terminal_mode, so a multi-char request would block for N chars.

-spec reader_loop(pid(), io:device()) -> ok.
reader_loop(Owner, Device) ->
    %% Use an explicit latin1 get_chars request, NOT io:get_chars/3: the latter
    %% returns UTF-8 regardless of device encoding, mangling raw high bytes
    %% (0xE9 -> <<0xC3,0xA9>>). The latin1 request returns each byte verbatim
    %% (0xE9 -> <<0xE9>>), so the parser sees the raw stream — meta keys, 8-bit
    %% input and arbitrary pasted bytes included.
    case io:request(Device, {get_chars, latin1, "", 1}) of
        eof ->
            Owner ! {?MODULE, self(), eof},
            ok;
        {error, Reason} ->
            Owner ! {?MODULE, self(), {error, Reason}},
            ok;
        Data ->
            Owner ! {?MODULE, self(), {data, iolist_to_binary(Data)}},
            reader_loop(Owner, Device)
    end.

%%% -- guard process ---------------------------------------------------
%%
%% Linked to the owner and trapping exits. If the owner goes away without
%% calling close/1 — a crash, a supervised `shutdown', a plain exit, or a
%% cooperative-mode Ctrl-C that interrupts the evaluated caller — the guard runs
%% the full restore so nothing ever strands the terminal in the alternate screen
%% / raw mode / echo-off. Only the explicit `stop' from close/1 (which has
%% already restored) is treated as clean.

-spec guard_loop(pid(), io:device(), binary(), [{atom(), term()}], boolean()) -> ok.
guard_loop(Owner, Device, RestoreSeq, PrevOpts, ReleaseRaw) ->
    process_flag(trap_exit, true),
    receive
        stop ->
            ok;
        {'EXIT', Owner, _Reason} ->
            %% Any reason (normal | shutdown | crash | interrupt): close/1 did not
            %% run, so in a host VM that keeps running nothing else restores the
            %% terminal — VM-exit termios restore never fires (and never applies to
            %% the cooperative submode, where we never took raw output over).
            do_restore(Device, RestoreSeq, PrevOpts, ReleaseRaw)
    end.

%%% -- helpers ---------------------------------------------------------

%% Emit the ANSI restore (SGR reset, show cursor, leave alt-screen; plus CRLF in
%% the cooperative submode) while the device is still in our binary/latin1 mode
%% (RestoreSeq is ASCII, safe as a binary), then — only in the noshell submode —
%% undo the global raw mode, and finally put the caller's original opts back
%% (re-enabling edlin echo in the cooperative submode). Best-effort: the
%% noshell/-noshell path also gets a full termios restore on VM exit.
-spec do_restore(io:device(), binary(), [{atom(), term()}], boolean()) -> ok.
do_restore(Device, RestoreSeq, PrevOpts, ReleaseRaw) ->
    _ = io:put_chars(Device, RestoreSeq),
    _ = maybe_release_raw(ReleaseRaw),
    _ = io:setopts(Device, PrevOpts),
    ok.

%% Release global raw mode — only the noshell submode took it. The cooperative
%% submode never called start_interactive to enter raw mode (the live shell
%% already owns the tty), so it must not call the cooked teardown either, or it
%% would fight the shell for the tty.
-spec maybe_release_raw(boolean()) -> ok | {error, term()}.
maybe_release_raw(true) -> shell:start_interactive({noshell, cooked});
maybe_release_raw(false) -> ok.

%% Snapshot the current value of exactly the opts open/1 is about to override —
%% the keys in `SetOpts' — so close/1 and the guard restore precisely those and
%% nothing else. Deriving the saved keys FROM `SetOpts' keeps the two in
%% lockstep: the noshell submode overrides only binary/encoding, so it never
%% saves nor restores `echo', leaving that path's echo entirely to raw mode and
%% the `{noshell, cooked}' teardown — byte-identical to before cooperative mode
%% (which is important: `saved_opts' runs *after* raw mode is entered, so a saved
%% raw-mode echo re-applied after the cooked teardown could undo it). Only the
%% cooperative submode overrides `echo' — where the live shell was never in raw
%% mode, so the saved value is the shell's real edlin echo — and so only it saves
%% and restores echo. Restoring just these keys also avoids the whole
%% io:getopts/1 list, which fails atomically on keys like `onlcr' that setopts
%% rejects with enotsup (verified) and would strand echo off.
-spec saved_opts(io:device(), [term()]) -> [{atom(), term()}].
saved_opts(Device, SetOpts) ->
    Current = io:getopts(Device),
    [{Key, opt_value(Key, Current)} || Key <- [opt_key(Opt) || Opt <- SetOpts]].

%% The key of an io opt in either form: a bare atom (`binary' == `{binary, true}')
%% or a `{Key, Value}' tuple (`{encoding, latin1}', `{echo, false}').
-spec opt_key(atom() | {atom(), term()}) -> atom().
opt_key(Key) when is_atom(Key) -> Key;
opt_key({Key, _}) -> Key.

%% The device's current value for an opt key, with a conservative default for a
%% minimal device that does not report it (so restore never fabricates a bad opt).
-spec opt_value(atom(), [{atom(), term()}]) -> term().
opt_value(Key, Current) -> proplists:get_value(Key, Current, opt_default(Key)).

-spec opt_default(atom()) -> term().
opt_default(echo) -> false;
opt_default(binary) -> false;
opt_default(encoding) -> unicode;
opt_default(_) -> undefined.

%% Tell the guard to exit without restoring (close/1 does the restore). A message
%% rather than an exit signal, so it is never confused with an owner `shutdown'.
-spec silence_guard(pid()) -> ok.
silence_guard(Guard) ->
    unlink(Guard),
    Guard ! stop,
    ok.

%% The reader blocks in io:get_chars/3 and won't see a message, so terminate it
%% with an exit signal (it does not trap exits).
-spec stop_reader(pid()) -> ok.
stop_reader(Reader) ->
    unlink(Reader),
    exit(Reader, shutdown),
    ok.
