-module(hb_test).
-export([simple_stack_test/0, full_push_test/0, simple_load_test/0]).
-export([init/0, generate_test_data/1, run/2]).
-hb_debug(print).

-include("include/hb.hrl").
-include_lib("eunit/include/eunit.hrl").

init() ->
    application:ensure_all_started(hb),
    ok.

run(Proc, Msg) ->
    run(Proc, Msg, #{}).
run(Proc, Msg, _Opts) ->
    hb_cache:write(hb:get(store), Msg),
    hb_cache:write(hb:get(store), Proc),
    Scheduler = dev_scheduler_registry:find(hb_message:id(Proc, signed), true),
    Assignment = dev_scheduler_server:schedule(Scheduler, Msg),
    hb_process:result(
        hb_message:id(Proc, signed),
        hb_message:id(Assignment, unsigned),
        hb:get(store),
        hb:wallet()
    ).

%%% TESTS

simple_stack_test() ->
    init(),
    {Proc, Msg} = generate_test_data(<<"return 42">>),
    {ok, Result} = run(Proc, Msg, #{ on_idle => terminate }),
    #tx { data = <<"42">> } = maps:get(<<"/Data">>, Result),
    ok.

full_push_test_() ->
    {timeout, 150, ?_assert(full_push_test())}.

full_push_test() ->
    init(),
    ?event(full_push_test_started),
    {_, Msg} = generate_test_data(ping_ping_script()),
    hb_cache:write(hb:get(store), Msg),
    hb_client:push(Msg, #{ tracing => none }),
    ok.

simple_load_test() ->
    init(),
    ?event(scheduling_many_items),
    Messages = 30,
    Msg = generate_test_data(ping_ping_script()),
    hb_cache:write(hb:get(store), Msg),
    Start = hb:now(),
    Assignments = lists:map(
        fun(_) -> hb_client:schedule(Msg) end,
        lists:seq(1, Messages)
    ),
    Scheduled = hb:now(),
    {ok, LastAssignment} = lists:last(Assignments),
    ?event({scheduling_many_items_done_s, ((Scheduled - Start) / Messages) / 1000}),
    hb_client:compute(LastAssignment, Msg),
    Computed = hb:now(),
    ?event({compute_time_s, ((Computed - Scheduled) / Messages) / 1000}),
    ?event({total_time_s, ((Computed - Start) / Messages) / 1000}),
    ?event({processed_messages, Messages}).

default_test_img(Wallet) ->
    Store = hb:get(store),
    {ok, Module} = file:read_file("test/aos-2-pure-xs.wasm"),
    hb_cache:write(
        Store,
        Img = ar_bundles:sign_item(
            #tx {
                tags = [
                    {<<"Protocol">>, <<"ao">>},
                    {<<"Variant">>, <<"ao.tn.2">>},
                    {<<"Type">>, <<"Image">>}
                ],
                data = Module
            },
            Wallet
        )
    ),
    Img.


default_test_devices(Wallet, Opts) ->
    ID = ar_wallet:to_address(Wallet),
    Img = maps:get(image, Opts),
    Quorum = maps:get(quorum, Opts, 2),
    LocalAddress = hb:address(),
    [
        {<<"Protocol">>, <<"ao">>},
        {<<"Variant">>, <<"ao.tn.2">>},
        {<<"Type">>, <<"Process">>},
        {<<"Device">>, <<"Stack">>},
        {<<"Device">>, <<"Scheduler">>},
        {<<"Location">>, hb_message:id(ID)},
        {<<"Device">>, <<"PODA">>},
        {<<"Quorum">>, integer_to_binary(Quorum)}
    ] ++
    [
        {<<"Authority">>, Addr} ||
            Addr <- maps:keys(maps:get(compute, hb:get(nodes))),
            Addr =/= '_'
    ] ++
    [
        {<<"Device">>, <<"JSON-Interface">>},
        {<<"Device">>, <<"VFS">>},
        {<<"Device">>, <<"WASM64-pure">>},
        {<<"Module">>, <<"aos-2-pure">>},
        {<<"Image">>, hb_message:id(Img)},
        {<<"Device">>, <<"Cron">>},
        {<<"Time">>, <<"100-Milliseconds">>},
        {<<"Device">>, <<"Multipass">>},
        {<<"Passes">>, <<"3">>}
    ].

ping_ping_script() ->
    <<
        "\n"
        "Handlers.add(\"Ping\", function(m) Send({ Target = ao.id, Action = \"Ping\" }); print(\"Sent Ping\"); end)\n"
        "Send({ Target = ao.id, Action = \"Ping\" })\n"
    >>.

generate_test_data(Script) ->
    generate_test_data(Script, hb:wallet()).
generate_test_data(Script, Wallet) ->
    Img = default_test_img(Wallet),
    generate_test_data(Script, Wallet, #{image => Img}).
generate_test_data(Script, Wallet, Opts) ->
    Devs = default_test_devices(Wallet, Opts),
    generate_test_data(Script, Wallet, Opts, Devs).
generate_test_data(Script, Wallet, _Opts, Devs) ->
    Store = hb:get(store),
    hb_cache:write(
        Store,
        SignedProcess = ar_bundles:sign_item(
            #tx{ tags = Devs },
            Wallet
        )
    ),
    Msg = ar_bundles:sign_item(
        #tx{
            target = ar_bundles:id(SignedProcess, signed),
            tags = [
                {<<"Protocol">>, <<"ao">>},
                {<<"Variant">>, <<"ao.tn.2">>},
                {<<"Type">>, <<"Message">>},
                {<<"Action">>, <<"Eval">>}
            ],
            data = Script
        },
        Wallet
    ),
    hb_cache:write(Store, Msg),
    ?event({test_data_written, {proc, hb_message:id(SignedProcess, signed)}, {msg, hb_message:id(Msg, unsigned)}}),
    {SignedProcess, Msg}.
