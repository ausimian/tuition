-module(tuition_widget_host_tests).

-include_lib("eunit/include/eunit.hrl").
-include("tuition_widget.hrl").

%%% -- event helpers ---------------------------------------------------

key(Named) -> {key, Named, []}.
char(C) -> {key, {char, C}, []}.

%% Render a host full-screen at `Size' and return the bytes the diff would emit,
%% so a test can assert on what the widget actually drew.
paint(Size, State) ->
    {Buf, _State} = tuition_widget_host:build_frame(Size, State),
    iolist_to_binary(tuition_render:diff(tuition_render:new(Size), Buf)).

%%% -- specs -----------------------------------------------------------

%% A stateless widget: a gauge, whose default label is the rounded percentage.
gauge_spec() ->
    #{widget => tuition_gauge, config => #{ratio => 0.63}}.

%% A stateful widget: a list, seeded on the first item, navigated by the caller's
%% own fold. The item count the widget needs to clamp at the ends is the caller's
%% to supply — the host never inspects the config.
list_items() -> [<<"alpha">>, <<"beta">>, <<"gamma">>].

list_spec() ->
    #{
        widget => tuition_list,
        %% A highlight_style is what makes the selected row survive the render diff:
        %% an all-default run has its interior spaces diffed away against the blank
        %% baseline, so "> alpha" would reach the assertion with its space missing.
        config => #{
            items => list_items(),
            highlight_symbol => <<"> ">>,
            highlight_style => #{fg => 0, bg => 6}
        },
        state => tuition_list:select(tuition_list:new(), 0),
        input => fun list_input/2
    }.

list_input({key, down, _Mods}, #{state := S} = Model) ->
    Model#{state := tuition_list:next(S, length(list_items()))};
list_input({key, up, _Mods}, #{state := S} = Model) ->
    Model#{state := tuition_list:prev(S, length(list_items()))};
list_input(_Event, Model) ->
    Model.

%%% -- stateless hosting -----------------------------------------------

stateless_widget_draws_itself_into_the_area_test() ->
    B = paint({20, 1}, tuition_widget_host:new(gauge_spec())),
    ?assertMatch({_, _}, binary:match(B, <<"63%">>)).

stateless_host_leaves_its_state_untouched_across_a_frame_test() ->
    %% A stateless widget owns nothing between frames, so the host must hand its
    %% state back unchanged rather than inventing one.
    S0 = tuition_widget_host:new(gauge_spec()),
    {_Buf, S1} = tuition_widget_host:build_frame({20, 1}, S0),
    ?assertEqual(S0, S1).

a_stateless_spec_carries_no_widget_state_test() ->
    ?assertEqual(
        #{config => #{ratio => 0.63}},
        tuition_widget_host:model(tuition_widget_host:new(gauge_spec()))
    ).

%%% -- default input ---------------------------------------------------

without_an_input_fun_q_quits_test() ->
    ?assertEqual(
        quit, tuition_widget_host:apply_events([char($q)], tuition_widget_host:new(gauge_spec()))
    ).

without_an_input_fun_every_other_key_is_ignored_test() ->
    S0 = tuition_widget_host:new(gauge_spec()),
    ?assertEqual({ok, S0}, tuition_widget_host:apply_events([key(down), char($x)], S0)).

default_quit_short_circuits_remaining_events_test() ->
    S0 = tuition_widget_host:new(gauge_spec()),
    ?assertEqual(quit, tuition_widget_host:apply_events([char($q), key(down)], S0)).

%%% -- caller-supplied input -------------------------------------------

the_input_fun_folds_into_the_widget_state_test() ->
    {ok, S1} = tuition_widget_host:apply_events(
        [key(down), key(down)], tuition_widget_host:new(list_spec())
    ),
    #{state := Sel} = tuition_widget_host:model(S1),
    ?assertEqual(2, tuition_list:selected(Sel)).

the_input_fun_can_fold_into_the_config_test() ->
    %% Interactivity for a *stateless* widget means recomputing its config, so the
    %% fold has to reach the config, not just the widget state.
    Spec = #{
        widget => tuition_gauge,
        config => #{ratio => 0.1},
        input => fun
            ({key, up, _Mods}, #{config := C} = Model) -> Model#{config := C#{ratio := 0.9}};
            (_Event, Model) -> Model
        end
    },
    {ok, S1} = tuition_widget_host:apply_events([key(up)], tuition_widget_host:new(Spec)),
    ?assertMatch({_, _}, binary:match(paint({20, 1}, S1), <<"90%">>)).

an_input_fun_returning_quit_short_circuits_test() ->
    Spec = maps:put(
        input,
        fun
            ({key, esc, _Mods}, _Model) -> quit;
            (Event, Model) -> list_input(Event, Model)
        end,
        list_spec()
    ),
    ?assertEqual(
        quit, tuition_widget_host:apply_events([key(esc), key(down)], tuition_widget_host:new(Spec))
    ).

an_input_fun_owns_q_rather_than_the_default_test() ->
    %% A host with its own fold decides everything, so a text-entry widget can take
    %% `q' as a keystroke instead of losing it to the default quit. (Ctrl-C still
    %% quits — the shell peels that off before a pane ever sees it.)
    Spec = #{
        widget => tuition_input_field,
        config => #{},
        state => tuition_input_field:new(),
        input => fun(Event, #{state := S} = Model) ->
            %% handle/2 also reports whether the *value* changed; the showcase
            %% doesn't gate anything on that, so it drops it.
            {S1, _Changed} = tuition_input_field:handle(Event, S),
            Model#{state := S1}
        end
    },
    {ok, S1} = tuition_widget_host:apply_events(
        [char($q)], tuition_widget_host:new(Spec)
    ),
    #{state := Field} = tuition_widget_host:model(S1),
    ?assertEqual(<<"q">>, tuition_input_field:value(Field)).

%%% -- stateful rendering ----------------------------------------------

stateful_widget_draws_itself_and_its_selection_test() ->
    B = paint({20, 4}, tuition_widget_host:new(list_spec())),
    ?assertMatch({_, _}, binary:match(B, <<"> alpha">>)),
    ?assertMatch({_, _}, binary:match(B, <<"gamma">>)).

render_persists_the_widgets_reconciled_state_test() ->
    %% A stateful widget may adjust its scroll offset to keep the selection in
    %% view, and that adjustment has to survive to the next frame — the whole
    %% reason the pane contract returns state from `render/3'.
    Spec = maps:merge(list_spec(), #{
        config => #{items => [integer_to_binary(N) || N <- lists:seq(1, 50)]},
        state => tuition_list:select(tuition_list:new(), 40)
    }),
    S0 = tuition_widget_host:new(Spec),
    {_Buf, S1} = tuition_widget_host:build_frame({20, 4}, S0),
    #{state := After} = tuition_widget_host:model(S1),
    %% Selection 40 in a 4-row viewport: the offset had to move off 0 to show it.
    ?assertEqual(37, After#list_state.offset).

%%% -- pane contract ---------------------------------------------------

sample_is_a_no_op_test() ->
    %% A widget showcase has no live node data; `sample/1' exists only to satisfy
    %% the contract the shell drives every pane through on the idle tick.
    S0 = tuition_widget_host:new(gauge_spec()),
    ?assertEqual(S0, tuition_widget_host:sample(S0)).
