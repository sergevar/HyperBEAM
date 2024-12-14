-module(hb_persistent).
-export([start/1, start/2, resolve/2]).
-export([run/1, run/2, run/3]).
-include("include/hb.hrl").
-hb_debug(print).

%%% @moduledoc This module implements an Erlang process structure for
%%% long-lived executions (like AO processes) in Hyperbeam. It persists
%%% messages between executions, keeping a message in memory, or caching to
%%% disk as needed.

%%% The default frequency for checkpointing is 2 slots.
-define(DEFAULT_FREQ, 10).

%% @doc Resolve a message to a new state, awaiting if needed.
resolve(Path, Opts) ->
    Store = hb_opts:get(store, no_viable_store, Opts),
    % If the node operator has defined a proxy resolver that will complete
    % computations for us, we find it here.
    LookupStore =
        case hb_opts:get(proxy_store, no_proxy_store, Opts) of
            no_proxy_store ->
                % No proxy is set; return the local store.
                hb_store:scope(Store, local);
            ProxyStore -> ProxyStore
        end,
    % Check if the resolution is already in the cache.
    case hb_cache:read(Path, Opts#{ store => LookupStore }) of
        not_found ->
            {Msg1ID, RestOfPath} = hb_path:pop_request(Path, Opts),
            case pg:get_local_members({compute, Msg1ID}) of
                [] ->
                    ?event({no_worker_for_path, Path}),
                    {ok, Msg1} = hb_cache:read(Msg1ID, Opts),
                    await_resolution(
                        run(
                            Msg1,
                            #{
                                to => RestOfPath,
                                store => Store,
                                wallet => hb:wallet(),
                                on_idle => wait
                            },
                            create_monitor(RestOfPath, Opts)
                        )
                    );
                [Pid|_] ->
                    ?event({found_worker_for_path, Path}),
                    ?no_prod("The CU process IPC API is poorly named."),
                    Pid !
                        {
                            on_idle,
                            run,
                            add_monitor,
                            [create_monitor(RestOfPath, Opts)]
                        },
                    Pid ! {on_idle, add_message, Msg1ID},
                    ?event({added_listener_and_message, Pid, Msg1ID}),
                    await_resolution(Pid)
            end;
        {ok, Result} -> {ok, Result}
    end.

%% @doc Wait for an execution to complete and return a result.
await_resolution(Pid) ->
    receive
        {result, Pid, _Msg, State} ->
            {ok, maps:get(results, State)}
    end.

%% @doc Run a new execution synchronously.
run(Process) -> run(Process, #{ error_strategy => throw }).
run(Process, Opts) ->
    run(Process, Opts, create_persistent_monitor(Opts)).
run(Process, Opts, Monitor) when not is_list(Monitor) ->
    run(Process, Opts, [Monitor]);
run(Process, RawOpts, Monitors) ->
    Opts = RawOpts#{
        post => maps:get(post, RawOpts, []) ++ [{dev_monitor, Monitors}]
    },
    element(1, spawn_monitor(fun() -> boot(Process, Opts) end, Opts)).

create_monitor(MsgID, _Opts) ->
    Listener = self(),
    fun(S, {add_message, Inbound}) ->
        % Gather messages
        Assignment = maps:get(<<"Assignment">>, Inbound#tx.data),
        Msg = maps:get(<<"Message">>, Inbound#tx.data),
        % Gather IDs
        AssignmentID = hb_util:id(Assignment, signed),
        AssignmentUnsignedID = hb_util:id(Assignment, unsigned),
        ScheduledMsgID = hb_util:id(Msg, signed),
        ScheduledMsgUnsignedID = hb_util:id(Msg, unsigned),
        % Gather slot
        Slot =
            case lists:keyfind(<<"Slot">>, 1, Assignment#tx.tags) of
                {<<"Slot">>, RawSlot} ->
                    list_to_integer(binary_to_list(RawSlot));
                false -> no_slot
            end,
        % Check if the message is relevant
        IsRelevant =
            (Slot == MsgID) or
            (ScheduledMsgID == MsgID) or
            (AssignmentID == MsgID) or
            (ScheduledMsgUnsignedID == MsgID) or
            (AssignmentUnsignedID == MsgID),
        % Send the result if the message is relevant.
        % Continue waiting otherwise.
        case IsRelevant of
            true ->
                Listener ! {result, self(), Inbound, S}, done;
            false ->
                ?event({monitor_got_message_for_wrong_slot, Slot, MsgID}),
                %ar_bundles:print(Inbound),
                ignored
        end;
        (S, end_of_schedule) ->
            ?event(
                {monitor_got_eos,
                    {waiting_for_slot, maps:get(slot, S, no_slot)},
                    {to, maps:get(to, S, no_to)}
                }
            ),
            ignored;
        (_, Signal) ->
            ?event({monitor_got_unknown_signal, Signal}),
            ignored
    end.

create_persistent_monitor(_Opts) ->
    Listener = self(),
    fun(S, {add_message, Msg}) ->
        Listener ! {result, self(), Msg, S};
        (_, _) -> ok
    end.

%% Process execution flow =>
%% Boot:    Check which devices need checkpoints and which they require
%%          Read the checkpoint data from the cache if available
%%          Build init state, mixing checkpoint data with baseline state
%%          Run init() on all devices
%% Execute: Run execute_schedule for the slot.
%%          Run execute_message for each device.
%%          Run checkpoint on all devices if the current slot is a checkpoint
%%          slot. Cache the result of the computation if the caller requested
%%          it. Repeat for the next slot.
%% EOS:     Check if we are in aggressive/lazy execution mode.
%%          Run end_of_schedule() on all devices to see if there is more work
%%          in aggressive mode, or move to await_command() in lazy mode.
%% Waiting: Either wait for a new message to arrive, or exit as requested.
boot(Process, Opts) ->
    % Register the process so that it can be found by its ID.
    ?event(
        {booting_process,
            {signed, hb_util:id(Process, signed)},
            {unsigned, hb_util:id(Process, unsigned)}
        }
    ),
    pg:join({cu, hb_util:id(Process, signed)}, self()),
    % Build the device stack.
    ?event({registered_process, hb_util:id(Process, signed)}),
    {ok, Dev} = hb_converge:load_device(Process, Opts),
    ?event({booting_device, Dev}),
    {ok, BootState = #{ devices := Devs }}
        = hb_converge:resolve(Dev, boot, [Process, Opts], Opts),
    ?event(booted_device),
    % Get the store we are using for this execution.
    Store = maps:get(store, Opts, hb_opts:get(store)),
    % Get checkpoint key names from all devices.
    % TODO: Assumes that the device is a stack or another device that uses maps
    % for state.
    {ok, #{keys := [Key|_]}} =
        hb_converge:resolve(Dev, checkpoint_uses, [BootState], Opts),
    % We don't support partial checkpoints (perhaps we never will?), so just
    % take one key and use that to find the latest full checkpoint.
    CheckpointOption =
        hb_cache:latest(
            Store,
            ar_bundles:id(Process, signed),
            maps:get(to, Opts, inf),
            [Key]
        ),
    {Slot, Checkpoint} =
        case CheckpointOption of
            not_found ->
                ?event({wasm_no_checkpoint, maps:get(to, Opts, inf)}),
                {-1, #{}};
            {LatestSlot, State} ->
                ?event(wasm_checkpoint),
                {LatestSlot, State#tx.data}
    end,
    InitState =
        (Checkpoint)#{
            process => Process,
            slot => Slot + 1,
            to => maps:get(to, Opts, inf),
            wallet => maps:get(wallet, Opts, hb:wallet()),
            store => maps:get(store, Opts, hb_opts:get(store)),
            schedule => maps:get(schedule, Opts, []),
            devices => Devs
        },
    ?event(
        {running_init_on_slot,
            Slot + 1,
            maps:get(to, Opts, inf),
            maps:keys(Checkpoint)
        }
    ),
    RuntimeOpts =
        Opts#{
            proc_dev => Dev,
            return => all,
            % If no compute mode is already set, use the global default.
            compute_mode => maps:get(compute_mode, Opts, hb_opts:get(compute_mode))
        },
    case hb_converge:resolve(Dev, init, [InitState, RuntimeOpts]) of
        {ok, StateAfterInit} ->
            execute_schedule(StateAfterInit, RuntimeOpts);
        {error, N, DevMod, Info} ->
            throw({error, boot, N, DevMod, Info})
    end.

execute_schedule(State, Opts) ->
    ?event(
        {
            process_executing_slot,
            maps:get(slot, State),
            {proc_id, hb_util:id(maps:get(process, State))},
            {to, maps:get(to, State)}
        }
    ),
    case State of
        #{schedule := []} ->
            ?event(
                {process_finished_schedule,
                    {final_slot, maps:get(slot, State)}
                }
            ),
            case maps:get(compute_mode, Opts) of
                aggressive ->
                    case execute_eos(State, Opts) of
                        {ok, #{schedule := []}} ->
                            ?event(eos_did_not_yield_more_work),
                            await_command(State, Opts);
                        {ok, NS} ->
                            execute_schedule(NS, Opts);
                        {error, DevNum, DevMod, Info} ->
                            ?event({error, {DevNum, DevMod, Info}}),
                            execute_terminate(
                                State#{
                                    errors :=
                                        maps:get(errors, State, [])
                                        ++ [{DevNum, DevMod, Info}]
                                },
                                Opts
                            )
                    end;
                lazy ->
                    ?event({lazy_compute_mode, moving_to_await_state}),
                    await_command(State, Opts)
            end;
        #{schedule := [Msg | NextSched]} ->
            case execute_message(Msg, State, Opts) of
                {ok, NewState = #{schedule := [Msg | NextSched]}} ->
                    post_execute(
                        Msg,
                        NewState#{schedule := NextSched},
                        Opts
                    );
                {ok, NewState} ->
                    ?event({schedule_updated, not_popping}),
                    post_execute(
                        Msg,
                        NewState#{schedule := NextSched},
                        Opts
                    );
                {error, DevNum, DevMod, Info} ->
                    ?event({error, {DevNum, DevMod, Info}}),
                    execute_terminate(
                        State#{
                            errors :=
                                maps:get(errors, State, [])
                                ++ [{DevNum, DevMod, Info}]
                        },
                        Opts
                    )
            end
    end.

post_execute(
    _Msg,
    State =
        #{
            store := Store,
            results := Results,
            process := Process,
            slot := Slot,
            wallet := Wallet
        },
    Opts = #{ proc_dev := Dev }
) ->
    ?event({handling_post_execute_for_slot, Slot}),
    case is_checkpoint_slot(State, Opts) of
        true ->
            % Run checkpoint on the device stack, but we do not propagate the
            % result.
            ?event({checkpointing_for_slot, Slot}),
            {ok, CheckpointState} =
                hb_converge:resolve(
                    Dev,
                    checkpoint,
                    [State#{ save_keys => [], message => undefined }],
                    Opts#{ message => undefined }
                ),
            Checkpoint =
                ar_bundles:normalize(
                    #tx {
                        data =
                            maps:merge(
                                Results,
                                maps:from_list(lists:map(
                                    fun(Key) ->
                                        Item = maps:get(Key, CheckpointState),
                                        case is_record(Item, tx) of
                                            true -> {Key, Item};
                                            false -> 
                                                throw({error, checkpoint_result_not_tx, Key})
                                        end
                                    end,
                                    maps:get(save_keys, CheckpointState, [])
                                ))
                            )
                    }
                ),
            ?event({checkpoint_normalized_for_slot, Slot}),
            hb_cache:write_result(
                Store,
                hb_util:id(Process, signed),
                Slot,
                ar_bundles:sign_item(Checkpoint, Wallet)
            ),
            ?event({checkpoint_written_for_slot, Slot});
        false ->
            NormalizedResult =
                ar_bundles:deserialize(ar_bundles:serialize(Results)),
            hb_cache:write_result(
                Store,
                hb_util:id(Process, signed),
                Slot,
                NormalizedResult
            ),
            ?event({result_written_for_slot, Slot})
    end,
    execute_schedule(initialize_slot(State), Opts).

initialize_slot(State = #{slot := Slot}) ->
    ?event({preparing_for_next_slot, Slot + 1}),
    State#{
        slot := Slot + 1,
        pass := 0,
        results := undefined,
        message => undefined
    }.

execute_message(M2, M1, Opts) ->
    hb_converge:resolve(M1, M2, Opts).

execute_terminate(M1, Opts) ->
    hb_converge:resolve(M1, terminate, Opts).

execute_eos(M1, Opts) ->
    hb_converge:resolve(M1, end_of_schedule, Opts).

is_checkpoint_slot(State, Opts) ->
    (maps:get(is_checkpoint, Opts, fun(_) -> false end))(State)
        orelse maps:get(slot, State) rem maps:get(freq, Opts, ?DEFAULT_FREQ) == 0.

%% After execution of the current schedule has finished the Erlang process
%% should enter a hibernation state, waiting for either more work or
%% termination.
await_command(State, Opts = #{ on_idle := terminate }) ->
    execute_terminate(State, Opts);
await_command(State, Opts = #{ on_idle := wait, proc_dev := Dev }) ->
    receive
        {on_idle, run, Function, Args} ->
            ?event({running_command, Function, Args}),
            {ok, NewState} = hb_converge:resolve(
                Dev,
                Function,
                [State#{ message => hd(Args) }, Opts],
                Opts
            ),
            await_command(NewState, Opts);
        {on_idle, add_message, MsgRef} ->
            ?event({received_message, MsgRef}),
            % TODO: As with starting from a message, we should avoid the
            % unnecessary SU call if possible here.
            {ok, NewState} = execute_eos(State#{ to => MsgRef }, Opts),
            execute_schedule(NewState, Opts);
        {on_idle, stop} ->
            ?event({received_stop_command}),
            execute_terminate(State, Opts);
        Other ->
            ?event({received_unknown_message, Other}),
            await_command(State, Opts)
    end.