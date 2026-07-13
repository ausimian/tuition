%%% A single rendered terminal cell, shared by the diff renderer and the
%%% terminal backends. Kept intentionally small for Phase 0; styling
%%% (SGR attributes, truecolor) expands as capability probing lands.
-ifndef(TUITION_TERM_HRL).
-define(TUITION_TERM_HRL, true).

-record(cell, {
    %% The visible glyph: a single codepoint, or a grapheme cluster (base plus
    %% combining marks / an emoji ZWJ sequence) as a codepoint list. One cell
    %% carries one user-perceived character; its column span (1 or 2) is decided
    %% by tuition_width, not by the number of codepoints here.
    char = $\s :: char() | [char()],
    fg = default :: default | 0..255 | {rgb, byte(), byte(), byte()},
    bg = default :: default | 0..255 | {rgb, byte(), byte(), byte()},
    bold = false :: boolean(),
    underline = false :: boolean(),
    %% Cached display width of `char' in terminal columns (1 or 2), so the diff
    %% renderer can advance the cursor without re-measuring every changed cell
    %% each frame. Filled in from tuition_width by the renderer when the cell is
    %% stored in a buffer; a blank/default cell is one column. Only meaningful
    %% for stored cells — a hand-built cell keeps the default until placed.
    cols = 1 :: 1 | 2
}).

-endif.
