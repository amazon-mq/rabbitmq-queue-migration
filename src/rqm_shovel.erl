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
    create_and_verify/3,
    verify_started/2,
    build_definition/4,
    cleanup/2
]).

%% @doc Create shovel and verify it starts, with retry logic
-spec create_and_verify(binary(), binary(), list()) -> ok.
create_and_verify(VHost, ShovelName, ShovelDef) ->
    ok = create_with_retry(VHost, ShovelName, ShovelDef, 10),
    verify_first_attempt(VHost, ShovelName, ShovelDef).

verify_first_attempt(VHost, ShovelName, ShovelDef) ->
    handle_verify_result(
        verify_started(VHost, ShovelName, 10, 500),
        VHost,
        ShovelName,
        ShovelDef,
        first_attempt
    ).

handle_verify_result(ok, _VHost, _ShovelName, _ShovelDef, _Attempt) ->
    ok;
handle_verify_result(
    {error, shovel_not_started}, VHost, ShovelName, ShovelDef, first_attempt
) ->
    ?LOG_WARNING("rqm: shovel ~ts failed to start, retrying with longer timeout", [ShovelName]),
    cleanup(ShovelName, VHost),
    ok = create_with_retry(VHost, ShovelName, ShovelDef, 10),
    handle_verify_result(
        verify_started(VHost, ShovelName, 20, 500),
        VHost,
        ShovelName,
        ShovelDef,
        second_attempt
    );
handle_verify_result({error, shovel_not_started}, _VHost, ShovelName, _ShovelDef, second_attempt) ->
    ?LOG_ERROR("rqm: shovel ~ts failed to start after retry", [ShovelName]),
    error({shovel_not_started, ShovelName}).

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
-spec build_definition(binary(), binary(), non_neg_integer(), binary()) -> list().
build_definition(SourceQueueName, DestQueueName, MessageCount, VHost) ->
    EncodedVHost = rqm_util:to_unicode(rabbit_http_util:quote_plus(VHost)),
    SrcDestUri = <<"amqp:///", EncodedVHost/binary>>,
    Prefetch = calculate_prefetch(MessageCount),
    [
        {<<"src-uri">>, SrcDestUri},
        {<<"dest-uri">>, SrcDestUri},
        {<<"src-queue">>, SourceQueueName},
        {<<"dest-queue">>, DestQueueName},
        {<<"ack-mode">>, <<"on-confirm">>},
        {<<"src-delete-after">>, <<"never">>},
        {<<"prefetch-count">>, Prefetch}
    ].

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
-spec verify_started(binary(), binary()) -> ok | {error, shovel_not_started}.
verify_started(VHost, ShovelName) ->
    verify_started(VHost, ShovelName, 10, 500).

-spec verify_started(binary(), binary(), non_neg_integer(), non_neg_integer()) ->
    ok | {error, shovel_not_started}.
verify_started(_VHost, ShovelName, 0, _Delay) ->
    ?LOG_ERROR("rqm: shovel ~ts never started after all attempts", [ShovelName]),
    {error, shovel_not_started};
verify_started(VHost, ShovelName, Attempts, Delay) ->
    ShovelFullName = {VHost, ShovelName},
    case rabbit_shovel_status:lookup(ShovelFullName) of
        not_found ->
            ?LOG_DEBUG("rqm: shovel ~ts not found in status, retrying (~p attempts left)", [
                ShovelName, Attempts - 1
            ]),
            timer:sleep(Delay),
            verify_started(VHost, ShovelName, Attempts - 1, Delay);
        StatusProplist ->
            Info = proplists:get_value(info, StatusProplist),
            case Info of
                {State, _Opts} when State =:= starting; State =:= running ->
                    ?LOG_DEBUG("rqm: shovel ~ts verified in state ~p", [ShovelName, State]),
                    ok;
                {State, _Opts} ->
                    ?LOG_ERROR("rqm: shovel ~ts in unexpected state ~p", [ShovelName, State]),
                    {error, shovel_not_started};
                _ ->
                    ?LOG_DEBUG(
                        "rqm: shovel ~ts status format unexpected, retrying (~p attempts left)", [
                            ShovelName, Attempts - 1
                        ]
                    ),
                    timer:sleep(Delay),
                    verify_started(VHost, ShovelName, Attempts - 1, Delay)
            end
    end.

%% @doc Clean up a migration shovel
-spec cleanup(binary(), binary()) -> ok.
cleanup(ShovelName, VHost) ->
    case rabbit_runtime_parameters:lookup(VHost, <<"shovel">>, ShovelName) of
        not_found ->
            ?LOG_ERROR(
                "rqm: shovel ~ts not found during cleanup - this indicates a problem",
                [ShovelName]
            ),
            ok;
        _Value ->
            case catch rabbit_runtime_parameters:clear(VHost, <<"shovel">>, ShovelName, <<"rmq-shovel">>) of
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
