%% Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
%% SPDX-License-Identifier: Apache-2.0
%% vim:ft=erlang:
%% -*- mode: erlang; -*-

-module(rqm_checks).

-export([
    check_shovel_plugin/0,
    check_khepri_disabled/0,
    check_relaxed_checks_setting/0,
    check_leader_balance/1,
    check_leader_balance/2,
    check_queue_synchronization/1,
    check_queue_message_count/1,
    check_queue_suitability/1,
    check_disk_space/1,
    check_disk_space/2,
    check_system_migration_readiness/1,
    check_snapshot_not_in_progress/0,
    check_cluster_partitions/0,
    check_active_alarms/0,
    check_memory_usage/0
]).

%% Exported for testing
-ifdef(TEST).
-export([
    check_balance/3,
    determine_insufficient_space_reason/4
]).
-endif.

-include("rqm.hrl").

-include_lib("kernel/include/logger.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").

%%----------------------------------------------------------------------------
%% API
%%----------------------------------------------------------------------------

%% @doc Check if rabbitmq_shovel plugin is enabled.
%% This plugin is required for queue migration to work properly.
-spec check_shovel_plugin() -> ok | {error, shovel_plugin_not_enabled}.
check_shovel_plugin() ->
    ActivePlugins = rabbit_plugins:active(),
    case lists:member(rabbitmq_shovel, ActivePlugins) of
        true -> ok;
        false -> {error, shovel_plugin_not_enabled}
    end.

%% @doc Check if khepri_db is disabled.
%% Khepri must be disabled for queue migration to work properly.
-spec check_khepri_disabled() -> ok | {error, khepri_enabled}.
check_khepri_disabled() ->
    case rabbit_khepri:is_enabled() of
        false -> ok;
        true -> {error, khepri_enabled}
    end.

%% @doc Check if quorum_relaxed_checks_on_redeclaration is enabled.
%% This setting is required for queue migration to work properly as it allows
%% applications to continue declaring queues as classic after migration to quorum.
-spec check_relaxed_checks_setting() -> {ok, enabled} | {error, disabled}.
check_relaxed_checks_setting() ->
    case rabbit_misc:get_env(rabbit, quorum_relaxed_checks_on_redeclaration, false) of
        true -> {ok, enabled};
        false -> {error, disabled}
    end.

%% @doc Check if mirrored classic queue leaders are relatively well balanced
%% across cluster nodes for the default virtual host.
%% Returns {ok, balanced} if leaders are well distributed,
%% {error, {imbalanced, Details}} if not balanced enough for migration.
-spec check_leader_balance(rabbit_types:vhost()) ->
    {ok, balanced} | {error, {imbalanced, map()}}.
check_leader_balance(VHost) ->
    check_leader_balance(VHost, rqm_config:max_imbalance_ratio()).

%% @doc Check leader balance with custom imbalance ratio threshold.
-spec check_leader_balance(rabbit_types:vhost(), float()) ->
    {ok, balanced} | {error, {imbalanced, map()}}.
check_leader_balance(VHost, MaxImbalanceRatio) ->
    ClassicQueues = get_mirrored_classic_queues(VHost),
    QueueCount = length(ClassicQueues),
    case QueueCount < rqm_config:min_queues_for_balance_check() of
        true ->
            ?LOG_INFO(
                "rqm: leader balance check: only ~tp queues found, "
                "skipping balance check",
                [QueueCount]
            ),
            {ok, balanced};
        false ->
            Distribution = analyze_leader_distribution(ClassicQueues),
            check_balance(Distribution, MaxImbalanceRatio, QueueCount)
    end.

%% @doc Check if all mirrored classic queues are fully synchronized
%% Returns ok if all queues have all mirrors synchronized,
%% {error, {unsynchronized_queues, QueueNames}} if any queues are not fully synchronized.
-spec check_queue_synchronization(rabbit_types:vhost()) ->
    ok | {error, {unsynchronized_queues, [#unsuitable_queue{}]}}.
check_queue_synchronization(VHost) ->
    MigratableQueues = get_mirrored_classic_queues(VHost),
    UnsynchronizedQueues = lists:filter(
        fun(Queue) ->
            not rqm_util:has_all_mirrors_synchronized(Queue)
        end,
        MigratableQueues
    ),
    case UnsynchronizedQueues of
        [] ->
            ?LOG_INFO(
                "rqm: synchronization check: all ~tp mirratable queues are fully synchronized",
                [length(MigratableQueues)]
            ),
            ok;
        _ ->
            UnsuitableRecords = [
                #unsuitable_queue{
                    resource = amqqueue:get_name(Q),
                    reason = unsynchronized,
                    details = #{}
                }
             || Q <- UnsynchronizedQueues
            ],
            QueueNameBinaries = [
                rabbit_misc:rs(R#unsuitable_queue.resource)
             || R <- UnsuitableRecords
            ],
            ?LOG_ERROR(
                "rqm: synchronization check: ~tp queues are not fully synchronized: ~tp",
                [length(UnsynchronizedQueues), QueueNameBinaries]
            ),
            {error, {unsynchronized_queues, UnsuitableRecords}}
    end.

%% @doc Check if mirrored classic queues have more messages than is allowed.
%% Returns ok if no queue has too many messages.
%% {error, Details} if one or more queues have too many messages.
-spec check_queue_message_count(rabbit_types:vhost()) ->
    ok | {error, queues_too_deep}.
check_queue_message_count(VHost) ->
    MaxMessages = rqm_config:max_messages_in_queue(),
    Filter = fun
        ([{name, _Resource}, {messages, Count}]) when is_integer(Count), Count > MaxMessages ->
            true;
        (_) ->
            false
    end,
    QueuesTooDeep = lists:filter(Filter, rabbit_amqqueue:info_all(VHost, [name, messages])),
    case length(QueuesTooDeep) of
        0 ->
            ok;
        Num when Num > 0 ->
            ok = lists:foreach(
                fun([{name, Res}, {messages, Count}]) ->
                    QStr = rabbit_misc:rs(Res),
                    ?LOG_ERROR("rqm: ~ts too many messages: ~b", [QStr, Count])
                end,
                QueuesTooDeep
            ),
            {error, queues_too_deep}
    end.

%%----------------------------------------------------------------------------
%% Internal functions
%%----------------------------------------------------------------------------

%% @doc Get all mirrored classic queues in the specified virtual host
-spec get_mirrored_classic_queues(rabbit_types:vhost()) -> [rabbit_types:amqqueue()].
get_mirrored_classic_queues(VHost) ->
    AllQueues = rqm_db_queue:get_all_by_vhost_and_type(VHost, rabbit_classic_queue),
    lists:filter(fun rqm_util:has_ha_policy/1, AllQueues).

%% @doc Analyze the distribution of queue leaders across cluster nodes
-spec analyze_leader_distribution([rabbit_types:amqqueue()]) -> #{node() => non_neg_integer()}.
analyze_leader_distribution(Queues) ->
    % Get all cluster nodes first to ensure we account for nodes with zero queues
    ClusterNodes = rabbit_nodes:list_running(),
    % Initialize distribution map with all nodes set to 0
    InitialDistribution = maps:from_list([{Node, 0} || Node <- ClusterNodes]),
    % Count queues per leader node
    Distribution = lists:foldl(
        fun(Queue, Acc) ->
            LeaderNode = amqqueue:qnode(Queue),
            case LeaderNode of
                undefined ->
                    % Skip queues without clear leader
                    Acc;
                Node ->
                    maps:update_with(Node, fun(Count) -> Count + 1 end, 1, Acc)
            end
        end,
        InitialDistribution,
        Queues
    ),
    % Log current distribution
    ?LOG_INFO("rqm: leader balance check: current distribution:"),
    maps:fold(
        fun(Node, Count, _) ->
            ?LOG_INFO("  ~tp: ~tp queues", [Node, Count])
        end,
        ok,
        Distribution
    ),
    Distribution.

%% @doc Check if the leader distribution is balanced enough for migration
-spec check_balance(#{node() => non_neg_integer()}, float(), non_neg_integer()) ->
    {ok, balanced} | {error, {imbalanced, map()}}.
check_balance(Distribution, MaxImbalanceRatio, TotalQueues) ->
    Counts = maps:values(Distribution),
    NonZeroCounts = [Count || Count <- Counts, Count > 0],
    case length(NonZeroCounts) < 2 of
        true ->
            % Single node with queues - considered balanced
            ?LOG_INFO(
                "rqm: leader balance check: single node cluster or "
                "all queues on one node"
            ),
            {ok, balanced};
        false ->
            MinCount = lists:min(NonZeroCounts),
            MaxCount = lists:max(NonZeroCounts),
            % Calculate imbalance ratio, avoiding division by zero
            ImbalanceRatio =
                case MinCount of
                    0 -> infinity;
                    _ -> MaxCount / MinCount
                end,
            Balanced = ImbalanceRatio =< MaxImbalanceRatio,
            Details = #{
                total_queues => TotalQueues,
                node_count => maps:size(Distribution),
                min_queues_per_node => MinCount,
                max_queues_per_node => MaxCount,
                imbalance_ratio => ImbalanceRatio,
                max_allowed_ratio => MaxImbalanceRatio,
                distribution => Distribution
            },
            ?LOG_INFO(
                "rqm: leader balance check: analysis: "
                "min=~tp, max=~tp, ratio=~.2f, threshold=~.2f, balanced=~tp",
                [MinCount, MaxCount, ImbalanceRatio, MaxImbalanceRatio, Balanced]
            ),
            case Balanced of
                true ->
                    {ok, balanced};
                false ->
                    ?LOG_WARNING(
                        "rqm: queue leaders are not well balanced for migration. "
                        "Consider rebalancing before starting migration. "
                        "Imbalance ratio: ~.2f (threshold: ~.2f)",
                        [ImbalanceRatio, MaxImbalanceRatio]
                    ),
                    {error, {imbalanced, Details}}
            end
    end.

%%----------------------------------------------------------------------------
%% Disk Space Validation
%%----------------------------------------------------------------------------

%% @doc Check if there is sufficient free disk space for queue migration
%% for the default virtual host.
%% Returns {ok, sufficient} if there is enough disk space,
%% {error, {insufficient_disk_space, Details}} if not enough space available.
-spec check_disk_space(rabbit_types:vhost()) ->
    {ok, sufficient} | {error, {insufficient_disk_space, map()}}.
check_disk_space(VHost) ->
    check_disk_space(VHost, rqm_config:disk_space_safety_multiplier()).

%% @doc Check disk space availability with custom safety multiplier.
%% The safety multiplier accounts for:
%% - Temporary queues created during migration (1x current usage)
%% - Message duplication during transfer (1x current usage)
%% - Safety buffer for other operations (0.5x current usage)
%% Default multiplier of 2.5 provides reasonable safety margin.
-spec check_disk_space(rabbit_types:vhost(), float()) ->
    {ok, sufficient} | {error, {insufficient_disk_space, map()}}.
check_disk_space(VHost, SafetyMultiplier) ->
    % Get current disk space information
    CurrentFree = rabbit_disk_monitor:get_disk_free(),
    DiskFreeLimit = rabbit_disk_monitor:get_disk_free_limit(),

    case CurrentFree of
        'NaN' ->
            ?LOG_WARNING("rqm: disk: unable to determine current free disk space"),
            {error,
                {insufficient_disk_space, #{
                    reason => disk_space_unknown,
                    message => "Unable to determine current free disk space"
                }}};
        _ when is_integer(CurrentFree) ->
            % Estimate disk space needed for migration
            EstimatedUsage = estimate_migration_disk_usage(VHost, SafetyMultiplier),
            RequiredFree = EstimatedUsage + rqm_config:min_disk_space_buffer(),

            % Check if we have sufficient space
            check_disk_space_sufficiency(
                CurrentFree,
                DiskFreeLimit,
                RequiredFree,
                EstimatedUsage,
                VHost,
                SafetyMultiplier
            )
    end.

%%----------------------------------------------------------------------------
%% Internal disk space functions
%%----------------------------------------------------------------------------

%% @doc Estimate the disk space required for migration
-spec estimate_migration_disk_usage(rabbit_types:vhost(), float()) -> non_neg_integer().
estimate_migration_disk_usage(VHost, SafetyMultiplier) ->
    MigratableQueues = get_mirrored_classic_queues(VHost),
    QueueCount = length(MigratableQueues),

    case QueueCount of
        0 ->
            ?LOG_INFO("rqm: disk: no migratable queues found in vhost ~ts", [VHost]),
            0;
        _ ->
            % Calculate total disk usage for all queues
            TotalUsage = lists:foldl(
                fun(Queue, Acc) ->
                    QueueUsage = get_queue_disk_usage(Queue),
                    Acc + QueueUsage
                end,
                0,
                MigratableQueues
            ),

            % Apply safety multiplier
            RequiredSpace = round(TotalUsage * SafetyMultiplier),

            ?LOG_INFO(
                "rqm: disk: ~tp bytes needed for ~tp queues "
                "(~tp bytes base usage × ~.1f safety multiplier)",
                [RequiredSpace, QueueCount, TotalUsage, SafetyMultiplier]
            ),

            RequiredSpace
    end.

%% @doc Get disk usage for a single queue
-spec get_queue_disk_usage(rabbit_types:amqqueue()) -> non_neg_integer().
get_queue_disk_usage(Queue) ->
    QueueName = amqqueue:get_name(Queue),
    % Get queue information including message count and message bytes usage
    QueueInfo = rabbit_amqqueue:info(Queue, [messages, message_bytes]),
    Messages = proplists:get_value(messages, QueueInfo, 0),
    MessageBytes = proplists:get_value(message_bytes, QueueInfo, 0),
    ?LOG_DEBUG(
        "rqm: disk: queue ~tp usage ~tp bytes (~tp messages)",
        [QueueName, MessageBytes, Messages]
    ),
    MessageBytes.

%% @doc Check if current disk space is sufficient for migration
-spec check_disk_space_sufficiency(
    non_neg_integer(),
    non_neg_integer(),
    non_neg_integer(),
    non_neg_integer(),
    rabbit_types:vhost(),
    float()
) ->
    {ok, sufficient} | {error, {insufficient_disk_space, map()}}.
check_disk_space_sufficiency(
    CurrentFree,
    DiskFreeLimit,
    RequiredFree,
    EstimatedUsage,
    VHost,
    SafetyMultiplier
) ->
    % Check against both current free space and disk free limit
    AvailableForMigration = CurrentFree - DiskFreeLimit,
    SpaceAfterMigration = CurrentFree - RequiredFree,

    Details = #{
        vhost => VHost,
        current_free_bytes => CurrentFree,
        disk_free_limit_bytes => DiskFreeLimit,
        available_for_migration_bytes => max(0, AvailableForMigration),
        estimated_migration_usage_bytes => EstimatedUsage,
        required_free_bytes => RequiredFree,
        space_after_migration_bytes => SpaceAfterMigration,
        safety_multiplier => SafetyMultiplier,
        buffer_bytes => rqm_config:min_disk_space_buffer(),

        % Human-readable sizes
        current_free_mb => CurrentFree div (1024 * 1024),
        disk_free_limit_mb => DiskFreeLimit div (1024 * 1024),
        available_for_migration_mb => max(0, AvailableForMigration) div (1024 * 1024),
        estimated_migration_usage_mb => EstimatedUsage div (1024 * 1024),
        required_free_mb => RequiredFree div (1024 * 1024)
    },

    ?LOG_INFO(
        "rqm: disk: current=~tpMB, limit=~tpMB, available=~tpMB, "
        "required=~tpMB, after_migration=~tpMB",
        [
            maps:get(current_free_mb, Details),
            maps:get(disk_free_limit_mb, Details),
            maps:get(available_for_migration_mb, Details),
            maps:get(required_free_mb, Details),
            SpaceAfterMigration div (1024 * 1024)
        ]
    ),

    % Check multiple conditions for sufficient space
    Sufficient =
        (AvailableForMigration >= RequiredFree) andalso
            (SpaceAfterMigration >= DiskFreeLimit),

    case Sufficient of
        true ->
            ?LOG_INFO("rqm: disk: sufficient space available for migration"),
            {ok, sufficient};
        false ->
            Reason = determine_insufficient_space_reason(
                CurrentFree,
                DiskFreeLimit,
                RequiredFree,
                AvailableForMigration
            ),
            ReasonMessage =
                case Reason of
                    already_below_limit ->
                        "Current free space is already below disk free limit";
                    insufficient_available_space ->
                        "Not enough space available for migration";
                    would_exceed_limit_after_migration ->
                        "Migration would push free space below disk free limit";
                    _ ->
                        "Unknown reason for insufficient disk space"
                end,
            ?LOG_WARNING(
                "rqm: disk: insufficient space for migration. ~s",
                [ReasonMessage]
            ),
            {error, {insufficient_disk_space, Details#{reason => Reason}}}
    end.

%% @doc Check if there are any in-progress EBS snapshots for RabbitMQ volumes
%% Returns ok if no snapshots in progress, {error, snapshot_in_progress} otherwise
-spec check_snapshot_not_in_progress() -> ok | {error, {snapshot_in_progress, term()}}.
check_snapshot_not_in_progress() ->
    rqm_snapshot:check_no_snapshots_in_progress().

%% @doc Check if cluster has any partitions and all nodes are up.
%% Returns ok if no partitions detected, {error, nodes_down| or {error, partitions_detected} otherwise
-spec check_cluster_partitions() -> ok | {error, nodes_down} | {error, partitions_detected}.
check_cluster_partitions() ->
    M = sets:from_list(rabbit_nodes:list_members(), [{version, 2}]),
    R = sets:from_list(rabbit_nodes:list_running(), [{version, 2}]),
    NodesHealthy = sets:is_subset(M, R) andalso sets:is_subset(R, M),
    case {NodesHealthy, rabbit_node_monitor:partitions()} of
        {true, []} ->
            {ok, sets:to_list(sets:union(M, R))};
        {false, _} ->
            {error, nodes_down};
        {_, _Partitions} ->
            {error, partitions_detected}
    end.

%% @doc Check if any RabbitMQ alarms are active
%% Returns ok if no alarms active, {error, alarms_active} otherwise
-spec check_active_alarms() -> ok | {error, alarms_active}.
check_active_alarms() ->
    case rabbit_alarm:get_alarms() of
        [] -> ok;
        _Alarms -> {error, alarms_active}
    end.

%% @doc Check memory usage across all cluster nodes
%% Returns {ok, sufficient} if all nodes are under the memory threshold,
%% {error, {memory_usage_too_high, Details}} otherwise
-spec check_memory_usage() -> {ok, sufficient} | {error, {memory_usage_too_high, map()}}.
check_memory_usage() ->
    MaxPercent = rqm_config:max_memory_usage_percent(),
    RunningNodes = rabbit_nodes:list_running(),

    % Check memory usage on all running nodes
    Results = lists:map(
        fun(Node) ->
            case erpc:call(Node, vm_memory_monitor, get_rss_memory, []) of
                {badrpc, Reason} ->
                    {Node, {error, Reason}};
                RssMemory ->
                    case erpc:call(Node, vm_memory_monitor, get_total_memory, []) of
                        {badrpc, Reason} ->
                            {Node, {error, Reason}};
                        TotalMemory ->
                            UsagePercent = round((RssMemory / TotalMemory) * 100),
                            {Node, {ok, UsagePercent, RssMemory, TotalMemory}}
                    end
            end
        end,
        RunningNodes
    ),

    % Check if any node exceeds the threshold
    case
        lists:filter(
            fun({_Node, Result}) ->
                case Result of
                    {ok, UsagePercent, _Rss, _Total} -> UsagePercent > MaxPercent;
                    {error, _} -> true
                end
            end,
            Results
        )
    of
        [] ->
            {ok, sufficient};
        ProblematicNodes ->
            Details = #{
                max_allowed_percent => MaxPercent,
                problematic_nodes => ProblematicNodes,
                all_results => Results
            },
            {error, {memory_usage_too_high, Details}}
    end.

%% @doc Determine the specific reason for insufficient disk space
-spec determine_insufficient_space_reason(
    non_neg_integer(),
    non_neg_integer(),
    non_neg_integer(),
    integer()
) -> atom().
determine_insufficient_space_reason(
    CurrentFree, DiskFreeLimit, RequiredFree, AvailableForMigration
) ->
    if
        CurrentFree < DiskFreeLimit ->
            already_below_limit;
        AvailableForMigration < RequiredFree ->
            insufficient_available_space;
        (CurrentFree - RequiredFree) < DiskFreeLimit ->
            would_exceed_limit_after_migration;
        true ->
            unknown_reason
    end.

%% @doc Check if queues are suitable for migration based on count, message count, and size
%% Returns ok if all queues are suitable for migration.
%% {error, Details} if one or more queues are not suitable.
-spec check_queue_suitability(rabbit_types:vhost()) ->
    ok | {error, map()}.
check_queue_suitability(VHost) ->
    % Get ALL classic queues in the vhost (not just mirrored ones)
    % because any classic queue could have incompatible arguments
    AllClassicQueues = rqm_db_queue:get_all_by_vhost_and_type(VHost, rabbit_classic_queue),
    QueueCount = length(AllClassicQueues),

    % Handle empty cluster case
    case QueueCount of
        0 ->
            ?LOG_INFO(
                "rqm: no classic queues found in vhost ~ts, all queues suitable for migration", [
                    VHost
                ]
            ),
            ok;
        _ ->
            % Collect ALL issues instead of stopping at the first one
            AllIssues = collect_all_suitability_issues(AllClassicQueues, VHost),
            case AllIssues of
                [] -> ok;
                _ -> {error, {unsuitable_queues, #{problematic_queues => AllIssues}}}
            end
    end.

%% @doc Collect all suitability issues from all queues
-spec collect_all_suitability_issues([rabbit_types:amqqueue()], rabbit_types:vhost()) -> list().
collect_all_suitability_issues(AllClassicQueues, _VHost) ->
    % Check for reject-publish-dlx issues
    RejectPublishDlxIssues = collect_reject_publish_dlx_issues(AllClassicQueues),

    % For remaining checks, only consider mirrored classic queues
    MirroredClassicQueues = lists:filter(fun rqm_util:has_ha_policy/1, AllClassicQueues),
    MirroredQueueCount = length(MirroredClassicQueues),

    % Check if there are too many mirrored queues
    TooManyQueuesIssues =
        case MirroredQueueCount > rqm_config:max_queues_for_migration() of
            true ->
                % Mark all mirrored queues as having too_many_queues issue
                [
                    #unsuitable_queue{
                        resource = amqqueue:get_name(Q),
                        reason = too_many_queues,
                        details = #{
                            queue_count => MirroredQueueCount,
                            max_queues => rqm_config:max_queues_for_migration()
                        }
                    }
                 || Q <- MirroredClassicQueues
                ];
            false ->
                []
        end,

    % Check message and byte limits for mirrored queues
    MessageAndByteIssues =
        case {MirroredQueueCount, TooManyQueuesIssues} of
            {0, _} ->
                [];
            % Skip if already too many queues
            {_, [_ | _]} ->
                [];
            _ ->
                MaxMessagesPerQueue = rqm_config:calculate_max_messages_per_queue(
                    MirroredQueueCount
                ),
                MaxBytesPerQueue = rqm_config:calculate_max_message_bytes_per_queue(
                    MirroredQueueCount
                ),
                collect_message_and_byte_issues(
                    MirroredClassicQueues, MaxMessagesPerQueue, MaxBytesPerQueue
                )
        end,

    % Combine all issues
    RejectPublishDlxIssues ++ TooManyQueuesIssues ++ MessageAndByteIssues.

%% @doc Collect reject-publish-dlx issues from queues
-spec collect_reject_publish_dlx_issues([rabbit_types:amqqueue()]) -> list().
collect_reject_publish_dlx_issues(Queues) ->
    lists:filtermap(
        fun(Queue) ->
            Args = amqqueue:get_arguments(Queue),
            case rabbit_misc:table_lookup(Args, <<"x-overflow">>) of
                {_, <<"reject-publish-dlx">>} ->
                    {true, #unsuitable_queue{
                        resource = amqqueue:get_name(Queue),
                        reason = incompatible_overflow,
                        details = #{overflow => <<"reject-publish-dlx">>}
                    }};
                _ ->
                    false
            end
        end,
        Queues
    ).

%% @doc Collect message count and byte limit issues from mirrored queues
-spec collect_message_and_byte_issues(
    [rabbit_types:amqqueue()], non_neg_integer(), non_neg_integer()
) -> list().
collect_message_and_byte_issues(Queues, MaxMessagesPerQueue, MaxBytesPerQueue) ->
    lists:filtermap(
        fun(Queue) ->
            Info = rabbit_amqqueue:info(Queue, [name, messages, message_bytes]),
            Name = proplists:get_value(name, Info),
            Messages = proplists:get_value(messages, Info, 0),
            MessageBytes = proplists:get_value(message_bytes, Info, 0),

            case {Messages > MaxMessagesPerQueue, MessageBytes > MaxBytesPerQueue} of
                {true, _} ->
                    {true, #unsuitable_queue{
                        resource = Name,
                        reason = too_many_messages,
                        details = #{messages => Messages, max_messages => MaxMessagesPerQueue}
                    }};
                {_, true} ->
                    {true, #unsuitable_queue{
                        resource = Name,
                        reason = too_many_bytes,
                        details = #{message_bytes => MessageBytes, max_bytes => MaxBytesPerQueue}
                    }};
                _ ->
                    false
            end
        end,
        Queues
    ).

%% @doc Run all system-level migration readiness checks
%% Returns list of all check results (both passed and failed)
-spec check_system_migration_readiness(rabbit_types:vhost()) -> [map()].
check_system_migration_readiness(VHost) ->
    % Run all checks independently and collect results
    RelaxedChecksResult = check_relaxed_checks_result(),
    LeaderBalanceResult = check_leader_balance_result(VHost),
    QueueSynchronizationResult = check_queue_synchronization_result(VHost),
    QueueSuitabilityResult = check_queue_suitability_result(VHost),
    MessageCountResult = check_message_count_result(VHost),
    DiskSpaceResult = check_disk_space_result(VHost),

    [
        RelaxedChecksResult,
        LeaderBalanceResult,
        QueueSynchronizationResult,
        QueueSuitabilityResult,
        MessageCountResult,
        DiskSpaceResult
    ].

%% Helper functions to convert check results to standardized format
check_relaxed_checks_result() ->
    case check_relaxed_checks_setting() of
        {ok, enabled} ->
            #{
                check_type => relaxed_checks_setting,
                status => passed,
                message => <<"Relaxed checks setting is enabled">>
            };
        {error, disabled} ->
            #{
                check_type => relaxed_checks_setting,
                status => failed,
                message =>
                    <<"Migration requires quorum_relaxed_checks_on_redeclaration to be set to true. This setting allows applications to continue declaring queues as classic after migration to quorum.">>
            }
    end.

check_leader_balance_result(VHost) ->
    case check_leader_balance(VHost) of
        {ok, balanced} ->
            #{
                check_type => leader_balance,
                status => passed,
                message => <<"Queue leaders are balanced across cluster nodes">>
            };
        {error, ImbalanceDetails} ->
            #{
                check_type => leader_balance,
                status => failed,
                message => format_leader_balance_error(ImbalanceDetails)
            }
    end.

check_queue_synchronization_result(VHost) ->
    case check_queue_synchronization(VHost) of
        ok ->
            #{
                check_type => queue_synchronization,
                status => passed,
                message => <<"All mirrored classic queues are fully synchronized">>
            };
        {error, {unsynchronized_queues, QueueNames}} ->
            QueueNamesStr = lists:join(<<", ">>, QueueNames),
            Message = iolist_to_binary([
                <<"Unsynchronized queues: ">>,
                QueueNamesStr,
                <<". Wait for all mirrors to synchronize before migration.">>
            ]),
            #{
                check_type => queue_synchronization,
                status => failed,
                message => Message
            }
    end.

check_queue_suitability_result(VHost) ->
    case check_queue_suitability(VHost) of
        ok ->
            #{
                check_type => queue_suitability,
                status => passed,
                message => <<"All queues are suitable for migration">>
            };
        {error, ErrorDetails} ->
            #{
                check_type => queue_suitability,
                status => failed,
                message => format_queue_suitability_error(ErrorDetails)
            }
    end.

check_message_count_result(VHost) ->
    case check_queue_message_count(VHost) of
        ok ->
            #{
                check_type => message_count,
                status => passed,
                message => <<"Message counts are within migration limits">>
            };
        {error, queues_too_deep} ->
            % Get the specific details for a better error message
            MaxMessages = rqm_config:max_messages_in_queue(),
            Filter = fun
                ([{name, _Resource}, {messages, Count}]) when
                    is_integer(Count), Count > MaxMessages
                ->
                    true;
                (_) ->
                    false
            end,
            QueuesTooDeep = lists:filter(Filter, rabbit_amqqueue:info_all(VHost, [name, messages])),
            QueueCount = length(QueuesTooDeep),

            #{
                check_type => message_count,
                status => failed,
                message => rqm_util:unicode_format(
                    "~tp queues have too many messages (> ~tp) for safe migration. Reduce message counts or drain queues before migration.",
                    [QueueCount, MaxMessages]
                )
            }
    end.

check_disk_space_result(VHost) ->
    case check_disk_space(VHost) of
        {ok, sufficient} ->
            #{
                check_type => disk_space,
                status => passed,
                message => <<"Sufficient disk space available for migration">>
            };
        {error, DiskSpaceError} ->
            #{
                check_type => disk_space,
                status => failed,
                message => format_disk_space_error(DiskSpaceError)
            }
    end.

%% User-friendly error message formatters with specific details
format_leader_balance_error({imbalanced, Details}) ->
    % Extract specific imbalance details
    case Details of
        #{
            min_queues_per_node := MinQueues,
            max_queues_per_node := MaxQueues,
            imbalance_ratio := ImbalanceRatio,
            max_allowed_ratio := MaxAllowedRatio,
            node_count := NodeCount
        } ->
            rqm_util:unicode_format(
                "Queue leaders are not balanced across ~tp cluster nodes (min: ~tp queues, max: ~tp queues per node, ratio: ~.2f, threshold: ~.2f). Rebalance queue leaders before migration to ensure optimal performance.",
                [NodeCount, MinQueues, MaxQueues, ImbalanceRatio, MaxAllowedRatio]
            );
        _ ->
            rqm_util:unicode_format(
                "Queue leaders are not balanced across cluster nodes. Rebalance queue leaders before migration to ensure optimal performance.",
                []
            )
    end.

format_disk_space_error({insufficient_disk_space, Details}) ->
    % Extract specific disk space details from the error map
    case Details of
        #{reason := disk_space_unknown} ->
            rqm_util:unicode_format(
                "Unable to determine current free disk space. Ensure disk monitoring is working properly before migration.",
                []
            );
        #{required_space := RequiredBytes, current_free := CurrentFree, node := Node} ->
            RequiredMiB = RequiredBytes div (1024 * 1024),
            AvailableMiB = CurrentFree div (1024 * 1024),
            rqm_util:unicode_format(
                "Insufficient disk space for migration on node ~ts - at least ~tpMiB is required, but only ~tpMiB is available. Free up disk space before migration.",
                [Node, RequiredMiB, AvailableMiB]
            );
        #{required_space := RequiredBytes} ->
            RequiredMiB = RequiredBytes div (1024 * 1024),
            rqm_util:unicode_format(
                "Insufficient disk space for migration - at least ~tpMiB is required on all cluster nodes. Free up disk space before migration.",
                [RequiredMiB]
            );
        _ ->
            rqm_util:unicode_format(
                "Insufficient disk space for migration. Ensure adequate free disk space on all cluster nodes before migration.",
                []
            )
    end.

%% Enhanced queue suitability error formatting
format_queue_suitability_error({incompatible_overflow_behavior, _Details}) ->
    rqm_util:unicode_format(
        "✗ Some queues are incompatible, see below",
        []
    );
format_queue_suitability_error({unsuitable_queues, Details}) ->
    ProblematicQueues = maps:get(problematic_queues, Details),
    QueueCount = length(ProblematicQueues),

    % Count different types of problems and extract limits from the actual issues
    {MessageProblems, ByteProblems, MaxMessagesPerQueue, MaxBytesPerQueue} =
        lists:foldl(
            fun
                (
                    #unsuitable_queue{reason = too_many_messages, details = IssueDetails},
                    {M, B, MaxMsg, MaxBytes}
                ) ->
                    Max = maps:get(max_messages, IssueDetails),
                    {M + 1, B, max(MaxMsg, Max), MaxBytes};
                (
                    #unsuitable_queue{reason = too_many_bytes, details = IssueDetails},
                    {M, B, MaxMsg, MaxBytes}
                ) ->
                    Max = maps:get(max_bytes, IssueDetails),
                    {M, B + 1, MaxMsg, max(MaxBytes, Max)};
                (#unsuitable_queue{reason = incompatible_overflow}, {M, B, MaxMsg, MaxBytes}) ->
                    {M, B, MaxMsg, MaxBytes};
                (_, {M, B, MaxMsg, MaxBytes}) ->
                    {M, B, MaxMsg, MaxBytes}
            end,
            {0, 0, 0, 0},
            ProblematicQueues
        ),

    case {MessageProblems, ByteProblems} of
        {M, 0} when M > 0 ->
            rqm_util:unicode_format(
                "~tp queues have too many messages (> ~tp per queue) for migration. Reduce message counts before migration.",
                [M, MaxMessagesPerQueue]
            );
        {0, B} when B > 0 ->
            MaxBytesMiB = MaxBytesPerQueue div (1024 * 1024),
            rqm_util:unicode_format(
                "~tp queues have too many message bytes (> ~tpMiB per queue) for migration. Reduce message sizes before migration.",
                [B, MaxBytesMiB]
            );
        {M, B} when M > 0, B > 0 ->
            MaxBytesMiB = MaxBytesPerQueue div (1024 * 1024),
            rqm_util:unicode_format(
                "~tp queues exceed migration limits (~tp with too many messages > ~tp, ~tp with too many bytes > ~tpMiB). Reduce message counts and sizes before migration.",
                [QueueCount, M, MaxMessagesPerQueue, B, MaxBytesMiB]
            );
        _ ->
            % Handle incompatible overflow or other issues
            rqm_util:unicode_format(
                "✗ Some queues are incompatible, see below",
                []
            )
    end.
