%%%-------------------------------------------------------------------
%%% @doc Terminal backend behaviour — the mandatory pluggable seam.
%%%
%%% This is the seam PRD §6/§11 require "from day one": it separates the
%%% renderer/layout/widgets (which sit above it) from the transport that
%%% actually carries keystrokes and rendered frames (which sits below it).
%%% A local raw-mode tty ({@link tuition_term_local}, Modes 1-3), an SSH channel
%%% pty ({@link tuition_ssh_cli} / {@link tuition_term_ssh}, Mode 4), and the
%%% scripted test backend ({@link tuition_loop_term}) are interchangeable
%%% implementations. Nothing above this seam may branch on which backend is in
%%% use.
%%%
%%% A backend is addressed through an opaque {Backend, State} handle; the
%%% dispatch helpers below hide that from callers.
%%% @end
%%%-------------------------------------------------------------------
-module(tuition_term).

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
