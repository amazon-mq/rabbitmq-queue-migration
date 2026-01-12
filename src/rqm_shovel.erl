%% Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
%% SPDX-License-Identifier: Apache-2.0
%% vim:ft=erlang:
%% -*- mode: erlang; -*-

-module(rqm_shovel).

-include("rqm.hrl").

-include_lib("kernel/include/logger.hrl").
-include_lib("rabbit/include/amqqueue.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").

-export([
    create_with_retry/4,
    verify_started/2,
    build_definition/3,
    cleanup/2
]).

%% @doc Create a shovel with retry logic for transient failures
-spec create_with_retry(binary(), binary(), list(), non_neg_integer()) -> ok.
create_with_retry(_VHost, ShovelName, _ShovelDef, 0) ->
    ?LOG_ERROR("rqm: failed to create shovel ~ts after all retries", [ShovelName]),
    error({shovel_creation_failed, ShovelName});
create_with_retry(VHost, ShovelName, ShovelDef, Retries) ->
    case catch rabbit_runtime_parameters:set(VHost, <<"shovel">>, ShovelName, ShovelDef, none) of
        ok ->
            ok;
        {'EXIT', Reason} ->
            ?LOG_WARNING(
                "rqm: exception creating shovel ~ts: ~tp, retrying (~p attempts left)",
                [ShovelName, Reason, Retries - 1]
            ),
            timer:sleep(1000),
            create_with_retry(VHost, ShovelName, ShovelDef, Retries - 1);
        Other ->
            ?LOG_WARNING(
                "rqm: unexpected result creating shovel ~ts: ~tp, retrying (~p attempts left)",
                [ShovelName, Other, Retries - 1]
            ),
            timer:sleep(1000),
            create_with_retry(VHost, ShovelName, ShovelDef, Retries - 1)
    end.

%% @doc Build shovel definition for message migration
-spec build_definition(binary(), binary(), non_neg_integer()) -> list().
build_definition(SourceQueueName, DestQueueName, MessageCount) ->
    Prefetch = calculate_prefetch(MessageCount),
    [
        {<<"src-uri">>, <<"amqp://">>},
        {<<"dest-uri">>, <<"amqp://">>},
        {<<"src-queue">>, SourceQueueName},
        {<<"dest-queue">>, DestQueueName},
        {<<"ack-mode">>, <<"on-confirm">>},
        {<<"src-delete-after">>, <<"never">>},
        {<<"prefetch-count">>, Prefetch}
    ].

%% @doc Calculate prefetch count based on message count
-spec calculate_prefetch(non_neg_integer()) -> pos_integer().
calculate_prefetch(MessageCount) ->
    MaxPrefetch = rqm_config:shovel_prefetch_count(),
    if
        MessageCount =< 128 ->
            max(1, MessageCount div 4);
        MessageCount =< 500 ->
            MaxPrefetch div 2;
        true ->
            MaxPrefetch
    end.

%% @doc Verify that a shovel actually started and is running
-spec verify_started(binary(), binary()) -> ok.
verify_started(VHost, ShovelName) ->
    verify_shovel_started(VHost, ShovelName, 10).

-spec verify_shovel_started(binary(), binary(), non_neg_integer()) -> ok.
verify_shovel_started(_VHost, ShovelName, 0) ->
    ?LOG_ERROR("rqm: shovel ~ts never started after all attempts", [ShovelName]),
    error({shovel_not_started, ShovelName});
verify_shovel_started(VHost, ShovelName, Attempts) ->
    ShovelFullName = {VHost, ShovelName},
    case rabbit_shovel_status:lookup(ShovelFullName) of
        not_found ->
            ?LOG_DEBUG("rqm: shovel ~ts not found in status, retrying (~p attempts left)", [
                ShovelName, Attempts - 1
            ]),
            timer:sleep(500),
            verify_shovel_started(VHost, ShovelName, Attempts - 1);
        StatusProplist ->
            Info = proplists:get_value(info, StatusProplist),
            case Info of
                {State, _Opts} when State =:= starting; State =:= running ->
                    ?LOG_DEBUG("rqm: shovel ~ts verified in state ~p", [ShovelName, State]),
                    ok;
                {State, _Opts} ->
                    ?LOG_ERROR("rqm: shovel ~ts in unexpected state ~p", [ShovelName, State]),
                    error({shovel_bad_state, ShovelName, State});
                _ ->
                    ?LOG_DEBUG(
                        "rqm: shovel ~ts status format unexpected, retrying (~p attempts left)", [
                            ShovelName, Attempts - 1
                        ]
                    ),
                    timer:sleep(500),
                    verify_shovel_started(VHost, ShovelName, Attempts - 1)
            end
    end.

%% @doc Clean up a migration shovel
-spec cleanup(binary(), binary()) -> ok.
cleanup(ShovelName, VHost) ->
    case rabbit_runtime_parameters:lookup(VHost, <<"shovel">>, ShovelName) of
        not_found ->
            %% With "never" mode, not_found is an error condition
            ?LOG_ERROR(
                "rqm: shovel ~ts not found during cleanup - this indicates a problem",
                [ShovelName]
            ),
            ok;
        _Value ->
            case catch rabbit_runtime_parameters:clear(VHost, <<"shovel">>, ShovelName, none) of
                ok ->
                    ?LOG_DEBUG("rqm: cleaned up shovel ~ts", [ShovelName]),
                    ok;
                {'EXIT', {noproc, _}} ->
                    ?LOG_DEBUG("rqm: shovel ~ts already cleaned up (noproc)", [ShovelName]),
                    ok;
                {'EXIT', Reason} ->
                    ?LOG_WARNING("rqm: exception cleaning up shovel ~ts: ~tp", [
                        ShovelName, Reason
                    ]),
                    ok;
                Other ->
                    ?LOG_WARNING("rqm: unexpected result cleaning up shovel ~ts: ~tp", [
                        ShovelName, Other
                    ]),
                    ok
            end
    end.
