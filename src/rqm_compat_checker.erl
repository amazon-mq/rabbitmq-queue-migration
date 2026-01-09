%% Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
%% SPDX-License-Identifier: Apache-2.0
%% vim:ft=erlang:
%% -*- mode: erlang; -*-

-module(rqm_compat_checker).

-include("rqm.hrl").

-include_lib("rabbit_common/include/rabbit.hrl").

%% Public API
-export([
    check_all_vhosts/0, check_all_vhosts/1,
    check_vhost/1, check_vhost/2,
    check_queue/1,
    check_migration_readiness/1,
    check_migration_readiness/2
]).

%% Check all queues in all vhosts
check_all_vhosts() ->
    check_all_vhosts(all).

check_all_vhosts(FilterMode) ->
    % Get all classic queues directly using rabbit_db_queue:get_all_by_type/1
    ClassicQueues = rabbit_db_queue:get_all_by_type(rabbit_classic_queue),

    % Group queues by vhost
    QueuesByVHost = group_by_vhost(ClassicQueues),

    % Check each vhost's queues
    [
        {VHost, Results, Summary}
     || {VHost, Results, Summary} <- [
            check_vhost_internal(VHost, Queues, FilterMode)
         || {VHost, Queues} <- QueuesByVHost
        ]
    ].

%% Check all queues in a specific vhost
check_vhost(VHost) ->
    check_vhost(VHost, all).

check_vhost(VHost, FilterMode) when is_binary(VHost) ->
    % Get all classic queues directly using rqm_db_queue:get_all_by_vhost_and_type/2
    VHostClassicQueues = rqm_db_queue:get_all_by_vhost_and_type(VHost, rabbit_classic_queue),

    % Check queues with the specified filter mode
    check_vhost_internal(VHost, VHostClassicQueues, FilterMode).

%% Check a specific queue for compatibility with quorum queues
check_queue(Queue) ->
    VHost = vhost_from_queue(Queue),
    SuitabilityResult = rqm_checks:check_queue_suitability(VHost),
    check_queue_internal(Queue, SuitabilityResult).

%% Private functions

%% Helper function to check all queues in a vhost and return summary statistics
check_vhost_internal(VHost, Queues, FilterMode) ->
    % FIRST: Check overall queue suitability (operational constraints)
    SuitabilityResult = rqm_checks:check_queue_suitability(VHost),

    % THEN: Check all queues with both technical and operational criteria
    AllResults = [
        {amqqueue:get_name(Q), check_queue_internal(Q, SuitabilityResult)}
     || Q <- Queues
    ],

    % Calculate summary statistics
    {Compatible, Incompatible} = count_compatible_queues(AllResults),

    % Filter results if needed
    FilteredResults =
        case FilterMode of
            all ->
                AllResults;
            incompatible_only ->
                lists:filter(
                    fun({_, {Status, _}}) -> Status =:= incompatible end,
                    AllResults
                )
        end,

    % Return vhost, filtered results, and summary statistics
    TotalQueues = length(AllResults),
    CompatibilityPercentage =
        case TotalQueues of
            % No queues means 100% compatible
            0 -> 100;
            _ -> trunc((Compatible / TotalQueues) * 100)
        end,

    {VHost, FilteredResults, #{
        total_queues => TotalQueues,
        compatible_queues => Compatible,
        incompatible_queues => Incompatible,
        compatibility_percentage => CompatibilityPercentage
    }}.

%% Helper function to count compatible and incompatible queues
count_compatible_queues(Results) ->
    lists:foldl(
        fun
            ({_, {compatible, _}}, {C, I}) -> {C + 1, I};
            ({_, {incompatible, _}}, {C, I}) -> {C, I + 1}
        end,
        {0, 0},
        Results
    ).

%% Internal function to check a queue's compatibility, considering suitability results
check_queue_internal(Queue, SuitabilityResult) ->
    % Standard per-queue compatibility issues
    StandardIssues = lists:flatten([
        check_exclusive(Queue),
        check_critical_arguments(Queue)
    ]),

    % Add suitability issues if they apply to this queue
    SuitabilityIssues = extract_queue_suitability_issues(Queue, SuitabilityResult),

    % Combine and deduplicate issues by type
    AllIssues = deduplicate_issues(StandardIssues ++ SuitabilityIssues),

    case AllIssues of
        [] -> {compatible, []};
        _ -> {incompatible, AllIssues}
    end.

%% Deduplicate issues by keeping only the first occurrence of each type
deduplicate_issues(Issues) ->
    deduplicate_issues(Issues, sets:new(), []).

deduplicate_issues([], _Seen, Acc) ->
    lists:reverse(Acc);
deduplicate_issues([{Type, _Reason} = Issue | Rest], Seen, Acc) ->
    case sets:is_element(Type, Seen) of
        true ->
            deduplicate_issues(Rest, Seen, Acc);
        false ->
            deduplicate_issues(Rest, sets:add_element(Type, Seen), [Issue | Acc])
    end.

%% Extract suitability issues that apply to a specific queue
extract_queue_suitability_issues(Queue, SuitabilityResult) ->
    case SuitabilityResult of
        ok ->
            [];
        {error, {unsuitable_queues, Details}} ->
            % Check if this specific queue is in the problematic queues list
            ProblematicQueues = maps:get(problematic_queues, Details, []),
            QueueResource = amqqueue:get_name(Queue),
            lists:filtermap(
                fun
                    (
                        #unsuitable_queue{
                            resource = QueueName,
                            reason = IssueType,
                            details = IssueDetails
                        }
                    ) when QueueName =:= QueueResource ->
                        case IssueType of
                            too_many_messages ->
                                Messages = maps:get(messages, IssueDetails),
                                MaxMessages = maps:get(max_messages, IssueDetails),
                                {true,
                                    {message_count_limit,
                                        io_lib:format(
                                            "Queue has ~p messages, exceeds limit of ~p",
                                            [Messages, MaxMessages]
                                        )}};
                            too_many_bytes ->
                                MessageBytes = maps:get(message_bytes, IssueDetails),
                                MaxBytes = maps:get(max_bytes, IssueDetails),
                                {true,
                                    {data_size_limit,
                                        io_lib:format(
                                            "Queue has ~p bytes, exceeds limit of ~p",
                                            [MessageBytes, MaxBytes]
                                        )}};
                            too_many_queues ->
                                QueueCount = maps:get(queue_count, IssueDetails),
                                MaxQueues = maps:get(max_queues, IssueDetails),
                                {true,
                                    {too_many_queues,
                                        io_lib:format(
                                            "Too many queues for migration (~p found, max ~p)",
                                            [QueueCount, MaxQueues]
                                        )}};
                            incompatible_overflow ->
                                {true,
                                    {incompatible_overflow,
                                        "reject-publish-dlx overflow behavior not supported in quorum queues"}};
                            _ ->
                                false
                        end;
                    (_) ->
                        false
                end,
                ProblematicQueues
            );
        _ ->
            []
    end.

%% Helper function to extract vhost from queue
vhost_from_queue(Queue) ->
    Resource = amqqueue:get_name(Queue),
    Resource#resource.virtual_host.

%% Helper function to group queues by vhost
group_by_vhost(Queues) ->
    lists:foldl(
        fun(Queue, Acc) ->
            VHost = vhost_from_queue(Queue),
            case lists:keyfind(VHost, 1, Acc) of
                {VHost, QList} ->
                    lists:keyreplace(VHost, 1, Acc, {VHost, [Queue | QList]});
                false ->
                    [{VHost, [Queue]} | Acc]
            end
        end,
        [],
        Queues
    ).

%% Check if queue is exclusive (not supported in quorum queues)
check_exclusive(Queue) ->
    case amqqueue:is_exclusive(Queue) of
        true -> [{exclusive, "Exclusive queues are not supported by quorum queues"}];
        false -> []
    end.

%% Check critical arguments that will be validated even with relaxed checks
%% These are the arguments checked in perform_limited_equivalence_checks_on_qq_redeclaration
check_critical_arguments(Queue) ->
    Args = amqqueue:get_arguments(Queue),
    CriticalArgChecks = [
        check_critical_overflow_behavior(Args),
        check_critical_dead_letter_args(Args),
        check_critical_expires(Args),
        check_critical_max_length_args(Args),
        check_critical_single_active_consumer(Args),
        check_critical_message_ttl(Args)
    ],
    lists:flatten(CriticalArgChecks).

%% Check overflow behavior - reject-publish-dlx is incompatible with quorum queues
check_critical_overflow_behavior(Args) ->
    case rabbit_misc:table_lookup(Args, <<"x-overflow">>) of
        {_, <<"reject-publish-dlx">>} ->
            [
                {incompatible_overflow,
                    "x-overflow=reject-publish-dlx is not supported in quorum queues. Quorum queues support drop-head and reject-publish, but reject-publish does not provide dead lettering like reject-publish-dlx does in classic queues."}
            ];
        _ ->
            []
    end.

%% Check dead letter arguments for quorum queue compatibility
check_critical_dead_letter_args(_Args) ->
    Issues = [],
    % x-dead-letter-exchange and x-dead-letter-routing-key are supported in quorum queues
    % No specific compatibility issues to check
    Issues.

%% Check expires argument
check_critical_expires(Args) ->
    case rabbit_misc:table_lookup(Args, <<"x-expires">>) of
        undefined -> [];
        % x-expires is supported in quorum queues
        {_, _} -> []
    end.

%% Check max length arguments
check_critical_max_length_args(_Args) ->
    Issues = [],
    % x-max-length and x-max-length-bytes are supported in quorum queues
    % No specific compatibility issues to check
    Issues.

%% Check single active consumer
check_critical_single_active_consumer(Args) ->
    case rabbit_misc:table_lookup(Args, <<"x-single-active-consumer">>) of
        undefined -> [];
        % x-single-active-consumer is supported in quorum queues
        {_, _} -> []
    end.

%% Check message TTL
check_critical_message_ttl(Args) ->
    case rabbit_misc:table_lookup(Args, <<"x-message-ttl">>) of
        undefined -> [];
        % x-message-ttl is supported in quorum queues
        {_, _} -> []
    end.

%% @doc Run complete migration readiness check (system + queues)
-spec check_migration_readiness(rabbit_types:vhost()) -> map().
check_migration_readiness(VHost) ->
    check_migration_readiness(VHost, #{}).

-spec check_migration_readiness(rabbit_types:vhost(), map()) -> map().
check_migration_readiness(VHost, OptsMap) ->
    SkipUnsuitableQueues = maps:get(skip_unsuitable_queues, OptsMap, false),

    % Run all system checks (never stops early)
    AllChecks = rqm_checks:check_system_migration_readiness(VHost),

    % Separate true system checks from queue-level checks
    QueueLevelCheckTypes = [queue_synchronization, queue_suitability, message_count],
    {SystemChecks, QueueLevelChecks} = lists:partition(
        fun(#{check_type := CheckType}) ->
            not lists:member(CheckType, QueueLevelCheckTypes)
        end,
        AllChecks
    ),

    % Run queue compatibility checks
    {VHost, QueueResults, QueueSummary} = check_vhost(VHost, incompatible_only),

    % Determine overall readiness
    TrueSystemReady = lists:all(fun(#{status := Status}) -> Status =:= passed end, SystemChecks),
    QueueChecksReady = lists:all(
        fun(#{status := Status}) -> Status =:= passed end, QueueLevelChecks
    ),
    QueueReady = maps:get(incompatible_queues, QueueSummary) =:= 0,
    OverallReady =
        case SkipUnsuitableQueues of
            true -> TrueSystemReady;
            false -> TrueSystemReady andalso QueueChecksReady andalso QueueReady
        end,

    % Format combined results (include all checks for display)
    #{
        vhost => VHost,
        overall_ready => OverallReady,
        skip_unsuitable_queues => SkipUnsuitableQueues,
        system_checks => #{
            all_passed => lists:all(fun(#{status := Status}) -> Status =:= passed end, AllChecks),
            checks => AllChecks
        },
        queue_checks => #{
            summary => QueueSummary,
            results => QueueResults
        }
    }.
