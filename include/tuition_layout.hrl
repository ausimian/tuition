%%% Geometry shared by the layout engine and the renderer.
%%%
%%% A `rect' is an axis-aligned rectangle of terminal cells. It carries a
%%% zero-based, top-left origin `{X, Y}' and a size `W'x`H' in columns x rows.
%%% The layout engine ({@link tuition_layout}) tiles a parent rect into child
%%% rects the renderer then draws into; children inherit the parent's origin,
%%% so nested layouts compose by splitting a child again.
-ifndef(SONDE_LAYOUT_HRL).
-define(SONDE_LAYOUT_HRL, true).

-record(rect, {
    x = 0 :: non_neg_integer(),
    y = 0 :: non_neg_integer(),
    w = 0 :: non_neg_integer(),
    h = 0 :: non_neg_integer()
}).

-endif.
