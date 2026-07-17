-module(tuition_term).
-moduledoc """
The behaviour every terminal backend implements.

This is the seam between the renderer, layout and widgets that sit above it and
the transport that carries keystrokes and rendered frames below it. A local
raw-mode tty (`m:tuition_term_local`), an SSH channel pty (`m:tuition_ssh_cli` /
`m:tuition_term_ssh`) and the scripted test backend (`m:tuition_loop_term`) are
interchangeable implementations. Nothing above this seam may branch on which
backend is in use.

Callers address a backend through an opaque `{Backend, State}` handle. The
dispatch helpers below hide it from them.
""".

-export([open/2, write/2, read/2, size/1, close/1]).

-type backend() :: module().
-type state() :: term().
-type handle() :: {backend(), state()}.
-type size() :: {Cols :: pos_integer(), Rows :: pos_integer()}.

-export_type([backend/0, handle/0, size/0]).

%% Enter raw mode / take ownership of the transport.
-callback open(Opts :: map()) -> {ok, state()} | {error, term()}.
%% Emit an already-rendered byte payload (ANSI/ECMA-48) to the terminal.
-callback write(state(), iodata()) -> ok | {error, term()}.
%% Read available input bytes, waiting at most Timeout ms.
-callback read(state(), Timeout :: timeout()) ->
    {ok, binary()} | timeout | {error, term()}.
%% Current terminal size in character cells.
-callback size(state()) -> {ok, size()} | {error, term()}.
%% Restore cooked mode / release the transport. Must be crash-safe.
-callback close(state()) -> ok.

%%% -- dispatch helpers over a {Backend, State} handle -----------------

-spec open(backend(), map()) -> {ok, handle()} | {error, term()}.
open(Backend, Opts) ->
    case Backend:open(Opts) of
        {ok, State} -> {ok, {Backend, State}};
        {error, _} = Error -> Error
    end.

-spec write(handle(), iodata()) -> ok | {error, term()}.
write({Backend, State}, Data) -> Backend:write(State, Data).

-spec read(handle(), timeout()) -> {ok, binary()} | timeout | {error, term()}.
read({Backend, State}, Timeout) -> Backend:read(State, Timeout).

-spec size(handle()) -> {ok, size()} | {error, term()}.
size({Backend, State}) -> Backend:size(State).

-spec close(handle()) -> ok.
close({Backend, State}) -> Backend:close(State).
