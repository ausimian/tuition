%%% Terminal capability set, produced by {@link tuition_caps:probe/2} and read by
%%% the renderer, input setup and (later) widgets to decide which optional
%%% terminal features to use.
%%%
%%% A modern xterm/ECMA-48 baseline — cursor addressing, SGR, the alternate
%%% screen and screen clear — is assumed unconditionally and never probed, so it
%%% has no field here. Every field below is an *optional enrichment* the runtime
%%% probe turns on only when the terminal answers its query; an absent or
%%% negative reply leaves it at its safe-off default (graceful degradation).
-ifndef(SONDE_CAPS_HRL).
-define(SONDE_CAPS_HRL, true).

-record(caps, {
    %% 24-bit RGB SGR, discriminated with a DECRQSS read-back (a 256-colour-only
    %% terminal does not echo the RGB triple it was handed).
    truecolor = false :: boolean(),
    %% DEC private mode ?2026 — batches a frame so a repaint is presented
    %% atomically (no tearing).
    sync_output = false :: boolean(),
    %% DEC private mode ?2004 — pasted text is bracketed so it is never mistaken
    %% for typed keys.
    bracketed_paste = false :: boolean(),
    %% DEC private mode ?1006 — SGR mouse encoding (unbounded coordinates).
    sgr_mouse = false :: boolean(),
    %% The kitty keyboard protocol — unambiguous key/modifier reporting.
    kitty_keyboard = false :: boolean()
}).

-endif.
