-module(dev_scheduler).
-export([init/3, end_of_schedule/1, uses/0]).

-include("include/ao.hrl").

%%% A simple scheduler scheme for AO.

init(State, [{<<"Location">>, Location} | _], _) ->
    case State of
        #{schedule := []} -> {ok, update_schedule(State#{su_location => Location})};
        _ -> {ok, State}
    end;
init(State, _, _) ->
    {ok, State}.

end_of_schedule(State) -> {ok, update_schedule(State)}.

update_schedule(State = #{process := Proc, schedule := []}) ->
    CurrentSlot = maps:get(slot, State, 0),
    ToSlot = maps:get(to_slot, State),
    % TODO: Get from slot via checkpoint
    Assignments = ao_client:get_assignments(Proc#tx.id, CurrentSlot, ToSlot),
    ?c(assignments_recvd),
    %ar_bundles:print(Assignments),
    State#{schedule => Assignments}.

uses() -> all.
