%% Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
%% SPDX-License-Identifier: Apache-2.0
%% vim:ft=erlang:
%% -*- mode: erlang; -*-

-module(rqm).

-include("rqm.hrl").

-include_lib("kernel/include/logger.hrl").
-include_lib("rabbit/include/amqqueue.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").

%% Shovel completion stability check iterations
-define(SHOVEL_STABILITY_ITERATIONS, 15).

-export([
    start/1,
    validate_migration/1,
    status/0,
    get_migration_status/0,
    get_queue_migration_status/1,
    get_rollback_pending_migration_json/0,
    start_migration_preparation_on_node/2,
    start_post_migration_restore_on_node/3,
    start_migration_on_node/4
]).

%% Public API

start(OptsMap) when is_map(OptsMap) ->
    try
        Opts = build_migration_opts(migration, OptsMap),
        pre_migration_validation(shovel_plugin, Opts)
    catch
        Class:Reason:Stack ->
            ?LOG_ERROR("rqm: exception in ~tp", [?MODULE]),
            ?LOG_ERROR(" - class ~tp", [Class]),
            ?LOG_ERROR(" - rsn ~tp", [Reason]),
            ?LOG_ERROR("~tp", [Stack]),
            {error, {exception, Class, Reason}}
    end.

%% @doc Validate migration prerequisites without starting the migration
%% This function runs all validation checks synchronously and returns
%% ok if validation passes, or {error, Reason} if validation fails.
validate_migration(OptsMap) when is_map(OptsMap) ->
    Opts = build_migration_opts(validation_only, OptsMap),
    pre_migration_validation(shovel_plugin, Opts).

status() ->
    Id = {?MODULE, self()},
    Nodes = [node() | nodes()],
    try
        case global:set_lock(Id, Nodes, 0) of
            true ->
                {ok, not_running};
            false ->
                {ok, in_progress}
        end
    after
        global:del_lock(Id)
    end.

%% Private API

build_migration_opts(Mode, OptsMap) ->
    VHost = maps:get(vhost, OptsMap, <<"/">>),
    SkipUnsuitableQueues = maps:get(skip_unsuitable_queues, OptsMap, false),
    BatchSize = maps:get(batch_size, OptsMap, all),
    BatchOrder = maps:get(batch_order, OptsMap, smallest_first),
    QueueNames = maps:get(queue_names, OptsMap, undefined),
    MigrationId = maps:get(migration_id, OptsMap, undefined),
    Tolerance = maps:get(tolerance, OptsMap, undefined),
    #migration_opts{
        vhost = VHost,
        mode = Mode,
        skip_unsuitable_queues = SkipUnsuitableQueues,
        batch_size = BatchSize,
        batch_order = BatchOrder,
        queue_names = QueueNames,
        migration_id = MigrationId,
        tolerance = Tolerance
    }.

pre_migration_validation(shovel_plugin, Opts) ->
    handle_check_shovel_plugin(rqm_checks:check_shovel_plugin(), Opts);
pre_migration_validation(khepri_disabled, Opts) ->
    handle_check_khepri_disabled(rqm_checks:check_khepri_disabled(), Opts);
pre_migration_validation(relaxed_checks_setting, Opts) ->
    handle_check_relaxed_checks_setting(rqm_checks:check_relaxed_checks_setting(), Opts);
pre_migration_validation(balanced_queue_leaders, #migration_opts{vhost = VHost} = Opts) ->
    handle_check_leader_balance(rqm_checks:check_leader_balance(VHost), Opts);
pre_migration_validation(queue_synchronization, #migration_opts{vhost = VHost} = Opts) ->
    handle_check_queue_synchronization(
        rqm_checks:check_queue_synchronization(VHost), Opts
    );
pre_migration_validation(queue_suitability, #migration_opts{vhost = VHost} = Opts) ->
    handle_check_queue_suitability(rqm_checks:check_queue_suitability(VHost), Opts);
pre_migration_validation(
    disk_space, #migration_opts{vhost = VHost, unsuitable_queues = UnsuitableQueues} = Opts
) ->
    handle_check_disk_space(rqm_checks:check_disk_space(VHost, UnsuitableQueues), Opts);
pre_migration_validation(active_alarms, Opts) ->
    handle_check_active_alarms(rqm_checks:check_active_alarms(), Opts);
pre_migration_validation(memory_usage, Opts) ->
    handle_check_memory_usage(rqm_checks:check_memory_usage(), Opts);
pre_migration_validation(snapshot_not_in_progress, Opts) ->
    handle_check_snapshot_not_in_progress(rqm_checks:check_snapshot_not_in_progress(), Opts);
pre_migration_validation(cluster_partitions, Opts) ->
    handle_check_cluster_partitions(rqm_checks:check_cluster_partitions(), Opts).

handle_check_shovel_plugin(ok, Opts) ->
    pre_migration_validation(khepri_disabled, Opts);
handle_check_shovel_plugin({error, shovel_plugin_not_enabled}, _Opts) ->
    ?LOG_ERROR(
        "rqm: rabbitmq_shovel plugin must be enabled for migration. "
        "Enable the plugin with: rabbitmq-plugins enable rabbitmq_shovel"
    ),
    {error, shovel_plugin_not_enabled}.

handle_check_khepri_disabled(ok, Opts) ->
    pre_migration_validation(relaxed_checks_setting, Opts);
handle_check_khepri_disabled({error, khepri_enabled}, _Opts) ->
    ?LOG_ERROR(
        "rqm: khepri_db must be disabled for migration. "
        "Khepri is not compatible with classic queue migration."
    ),
    {error, khepri_enabled}.

handle_check_relaxed_checks_setting({ok, enabled}, Opts) ->
    pre_migration_validation(balanced_queue_leaders, Opts);
handle_check_relaxed_checks_setting({error, disabled}, _Opts) ->
    ?LOG_ERROR(
        "rqm: quorum_relaxed_checks_on_redeclaration must be set to true for migration to work properly. "
        "This setting allows applications to continue declaring queues as classic after migration to quorum."
    ),
    {error, relaxed_checks_disabled}.

handle_check_leader_balance({ok, balanced}, Opts) ->
    pre_migration_validation(queue_synchronization, Opts);
handle_check_leader_balance({error, {imbalanced, _}}, _Opts) ->
    ?LOG_ERROR(
        "rqm: stopping migration due to imbalanced queue leaders. "
        "Re-balance queue leaders before migration."
    ),
    {error, queue_leaders_imbalanced}.

handle_check_queue_synchronization(ok, Opts) ->
    pre_migration_validation(queue_suitability, Opts);
handle_check_queue_synchronization(
    {error, {unsynchronized_queues, UnsuitableQueues}},
    #migration_opts{skip_unsuitable_queues = true} = Opts
) ->
    ?LOG_INFO(
        "rqm: found ~p unsynchronized queue(s), will skip during migration",
        [length(UnsuitableQueues)]
    ),
    UpdatedOpts = opts_add_unsuitable_queues(UnsuitableQueues, Opts),
    pre_migration_validation(queue_suitability, UpdatedOpts);
handle_check_queue_synchronization({error, {unsynchronized_queues, UnsuitableQueues}}, _Opts) ->
    QueueNameBinaries = [
        rabbit_misc:rs(R#unsuitable_queue.resource)
     || R <- UnsuitableQueues
    ],
    ?LOG_ERROR(
        "rqm: stopping migration due to unsynchronized queues: ~p. "
        "Wait for all mirrors to synchronize before migration.",
        [QueueNameBinaries]
    ),
    {error, {unsynchronized_queues, QueueNameBinaries}}.

handle_check_queue_suitability(ok, Opts) ->
    pre_migration_validation(disk_space, Opts);
handle_check_queue_suitability(
    {error, {unsuitable_queues, Details}},
    #migration_opts{skip_unsuitable_queues = true} = Opts
) ->
    ProblematicQueues = maps:get(problematic_queues, Details, []),
    ?LOG_INFO(
        "rqm: found ~p unsuitable queue(s), will skip during migration",
        [length(ProblematicQueues)]
    ),
    UpdatedOpts = opts_add_unsuitable_queues(ProblematicQueues, Opts),
    pre_migration_validation(disk_space, UpdatedOpts);
handle_check_queue_suitability({error, {unsuitable_queues, Details}}, _Opts) ->
    ProblematicQueues = maps:get(problematic_queues, Details, []),
    ?LOG_ERROR(
        "rqm: stopping migration due to unsuitable queues. "
        "Found ~p queue(s) with issues (too many messages, too many bytes, or unsuitable arguments).",
        [length(ProblematicQueues)]
    ),
    {error, {unsuitable_queues, Details}};
handle_check_queue_suitability({error, _} = Error, _Opts) ->
    Error.

handle_check_disk_space({ok, sufficient}, Opts) ->
    pre_migration_validation(active_alarms, Opts);
handle_check_disk_space({error, {insufficient_disk_space, Details}}, _Opts) ->
    RequiredMB = maps:get(required_free_mb, Details, 0),
    AvailableMB = maps:get(available_for_migration_mb, Details, 0),
    ?LOG_ERROR(
        "rqm: stopping migration due to insufficient disk space. "
        "Required: ~pMB, Available: ~pMB. Free up disk space before migration.",
        [RequiredMB, AvailableMB]
    ),
    {error, {insufficient_disk_space, Details}};
handle_check_disk_space({error, _} = Error, _Opts) ->
    Error.

handle_check_active_alarms(ok, Opts) ->
    pre_migration_validation(memory_usage, Opts);
handle_check_active_alarms({error, alarms_active}, _Opts) ->
    ?LOG_ERROR("rqm: active alarms detected. Clear all alarms before migration."),
    {error, alarms_active}.

handle_check_memory_usage({ok, sufficient}, Opts) ->
    pre_migration_validation(snapshot_not_in_progress, Opts);
handle_check_memory_usage({error, {memory_usage_too_high, Details}}, _Opts) ->
    MaxPercent = maps:get(max_allowed_percent, Details),
    ProblematicNodes = maps:get(problematic_nodes, Details),
    NodeCount = length(ProblematicNodes),
    ?LOG_ERROR(
        "rqm: ~p nodes have memory usage above ~p% threshold. "
        "Reduce memory usage before migration.",
        [NodeCount, MaxPercent]
    ),
    {error, {memory_usage_too_high, Details}}.

handle_check_snapshot_not_in_progress(ok, Opts) ->
    pre_migration_validation(cluster_partitions, Opts);
handle_check_snapshot_not_in_progress({error, {snapshot_in_progress, Details}}, _Opts) ->
    VolumeId = maps:get(volume_id, Details, "unknown"),
    SnapshotId = maps:get(snapshot_id, Details, "unknown"),
    ?LOG_ERROR(
        "rqm: snapshot ~s is already in progress for volume ~s. "
        "Wait for the snapshot to complete before starting a new migration.",
        [SnapshotId, VolumeId]
    ),
    {error, {snapshot_in_progress, Details}}.

handle_check_cluster_partitions({ok, Nodes}, Opts) ->
    handle_check_eligible_queue_count(rqm_checks:check_eligible_queue_count(Opts), Nodes);
handle_check_cluster_partitions({error, nodes_down}, _Opts) ->
    ?LOG_ERROR("rqm: nodes are down. Ensure all cluster nodes are up before migration."),
    {error, nodes_down};
handle_check_cluster_partitions({error, nodes_not_booted}, _Opts) ->
    ?LOG_ERROR(
        "rqm: some cluster nodes are not fully booted. Wait for all nodes to complete startup before migration."
    ),
    {error, nodes_not_booted};
handle_check_cluster_partitions({error, partitions_detected}, _Opts) ->
    ?LOG_ERROR("rqm: cluster partitions detected. Resolve partitions before migration."),
    {error, partitions_detected}.

handle_check_eligible_queue_count({ok, #migration_opts{mode = validation_only}}, _Nodes) ->
    ok;
handle_check_eligible_queue_count({ok, #migration_opts{vhost = VHost} = Opts}, Nodes) ->
    MigrationResult = start_migration(Nodes, Opts),
    handle_migration_result(MigrationResult, VHost);
handle_check_eligible_queue_count({error, _} = Error, _Nodes) ->
    Error.

handle_migration_result(ok, VHost) ->
    ?LOG_INFO("rqm: completed successfully for vhost ~ts", [VHost]);
handle_migration_result({error, MigrationError}, _VHost) ->
    ?LOG_ERROR("rqm: migration failed: ~p", [MigrationError]),
    ?LOG_WARNING("rqm: EBS snapshot can be used for rollback if needed"),
    % Do not attempt to restore normal operations as cluster state may be inconsistent
    {error, {migration_failed, MigrationError}}.

start_migration(Nodes, #migration_opts{migration_id = undefined} = Opts0) ->
    MigrationId = rqm_util:generate_migration_id(),
    Opts1 = Opts0#migration_opts{migration_id = MigrationId},
    start_migration(Nodes, Opts1);
start_migration(Nodes, Opts) ->
    maybe_start_with_lock(get_queue_migrate_lock(Nodes), Nodes, Opts).

maybe_start_with_lock({true, GlobalLockId}, Nodes, Opts) ->
    start_with_lock(GlobalLockId, Nodes, Opts);
maybe_start_with_lock(false, _Nodes, _Opts) ->
    ?LOG_WARNING("rqm: already in progress."),
    {error, in_progress}.

start_with_lock(
    GlobalLockId,
    Nodes,
    #migration_opts{
        vhost = VHost,
        skip_unsuitable_queues = SkipUnsuitableQueues,
        unsuitable_queues = UnsuitableQueues,
        migration_id = MigrationId,
        tolerance = Tolerance
    } = Opts
) ->
    %% Create migration record FIRST so failures are always tracked
    SkippedCount = length(UnsuitableQueues),
    {ok, _} = rqm_db:create_migration(
        MigrationId,
        VHost,
        os:timestamp(),
        SkipUnsuitableQueues,
        SkippedCount,
        Tolerance
    ),
    try
        {ok, PreparationState} = pre_migration_preparation(Nodes, VHost),

        {ok, MigrationDuration, CompletionStatus} = mcq_qq_migration(
            PreparationState, Nodes, Opts
        ),

        ok = post_migration_restore(Nodes, PreparationState, VHost),

        ok = post_migration_stats(Nodes, MigrationId, MigrationDuration, CompletionStatus),
        ok
    catch
        Class:Reason:Stack ->
            ok = handle_migration_exception_on_nodes(Nodes, Class, Reason),
            ok = handle_migration_exception(Class, Reason, Stack, MigrationId),
            {error, {Class, Reason}}
    after
        global:del_lock(GlobalLockId)
    end.

-spec handle_migration_exception_on_nodes([node()], atom(), term()) -> ok.
handle_migration_exception_on_nodes(Nodes, Class, Reason) ->
    ?LOG_DEBUG("rqm: restoring listeners on ~w nodes after exception ~tp:~tp", [
        length(Nodes), Class, Reason
    ]),
    {Results, BadNodes} = rpc:multicall(Nodes, rqm_util, resume_all_non_http_listeners, []),
    BadNodes =/= [] andalso
        ?LOG_WARNING("rqm: failed to restore listeners on nodes: ~tp", [BadNodes]),
    [
        ?LOG_WARNING("rqm: listener restoration returned error: ~tp", [Error])
     || {error, Error} <- Results
    ],
    ok.

handle_migration_exception(Class, Ex, Stack, MigrationId) ->
    ?LOG_ERROR(
        "rqm: CRITICAL EXCEPTION in migration ~s: ~tp",
        [format_migration_id(MigrationId), Class]
    ),
    ?LOG_ERROR("~tp", [Stack]),

    case Ex of
        {badmatch, _} ->
            ?LOG_ERROR("rqm: badmatch error in migration ~s", [format_migration_id(MigrationId)]);
        {migration_failed_rollback_pending, {errors, Errors}} ->
            {ErrorCount, AbortedCount} = count_errors_and_aborted(Errors),
            ?LOG_WARNING(
                "rqm: migration ~s failed, rollback is pending! ~p error(s), ~p aborted",
                [format_migration_id(MigrationId), ErrorCount, AbortedCount]
            );
        {migration_failed_no_rollback, {errors, Errors}} ->
            {ErrorCount, AbortedCount} = count_errors_and_aborted(Errors),
            ?LOG_WARNING(
                "rqm: migration ~s failed but no rollback is needed! ~p error(s), ~p aborted",
                [format_migration_id(MigrationId), ErrorCount, AbortedCount]
            );
        _ ->
            ?LOG_ERROR("rqm: unexpected error in migration ~s: ~tp", [
                format_migration_id(MigrationId), Ex
            ])
    end,

    ErrorReason = format_migration_error(Class, Ex),
    case rqm_db:update_migration_failed(MigrationId, ErrorReason) of
        {ok, _} ->
            ok;
        {error, not_found} ->
            ?LOG_DEBUG("rqm: migration ~s not found in database (failed before creation)", [
                format_migration_id(MigrationId)
            ]),
            ok
    end.

post_migration_stats(Nodes, MigrationId, MigrationDuration, CompletionStatus) ->
    ?LOG_INFO("rqm: retrieving final statistics for migration ~s", [
        format_migration_id(MigrationId)
    ]),
    {ok, Migration} = rqm_db:get_migration(MigrationId),
    TotalQueues = Migration#queue_migration.total_queues,
    CompletedQueues = Migration#queue_migration.completed_queues,

    ?LOG_INFO(
        "rqm: marking migration ~s as ~tp (~w of ~w queues completed)",
        [format_migration_id(MigrationId), CompletionStatus, CompletedQueues, TotalQueues]
    ),
    {ok, _} = rqm_db:update_migration_completed(MigrationId, CompletionStatus),

    ?LOG_INFO("rqm: SUMMARY for migration ~s:", [format_migration_id(MigrationId)]),
    ?LOG_INFO("rqm:   Duration: ~w seconds", [MigrationDuration]),
    ?LOG_INFO("rqm:   Total queues processed: ~w", [TotalQueues]),
    ?LOG_INFO("rqm:   Nodes involved: ~w", [length(Nodes)]),
    ok.

pre_migration_preparation(Nodes, VHost) ->
    ?LOG_DEBUG(
        "rqm: starting pre-migration preparation for vhost ~tp on nodes ~tp",
        [VHost, Nodes]
    ),
    PrepStart = erlang:system_time(second),

    ?LOG_DEBUG("rqm: starting preparation rqm_gatherer"),
    {ok, PrepGatherer} = rqm_gatherer:start_link(),

    ?LOG_DEBUG("rqm: dispatching work to ~w nodes for migration preparation", [length(Nodes)]),
    ok = start_migration_preparation_on_each_node(Nodes, PrepGatherer, VHost),
    ?LOG_DEBUG("rqm: waiting for all workers to complete for migration preparation"),

    {ok, PreparationState} = collect_rqm_gatherer_results(
        PrepGatherer, migration_preparation, length(Nodes)
    ),
    ?LOG_DEBUG("rqm: PreparationState ~tp", [PreparationState]),

    PrepEnd = erlang:system_time(second),
    PrepDuration = PrepEnd - PrepStart,
    ?LOG_DEBUG("rqm: migration preparation duration ~w seconds", [PrepDuration]),

    {ok, PreparationState}.

start_migration_preparation_on_each_node(Nodes, PrepGatherer, VHost) ->
    {ok, PidsAndRefs} = start_migration_preparation_on_each_node(Nodes, PrepGatherer, VHost, []),
    ok = wait_for_monitored_processes(PidsAndRefs).

start_migration_preparation_on_each_node([], _PrepGatherer, _VHost, Acc) ->
    {ok, Acc};
start_migration_preparation_on_each_node([Node | Rest], PrepGatherer, VHost, Acc0) ->
    Args = [PrepGatherer, VHost],
    % elp:ignore W0014
    PidAndRef = spawn_monitor(Node, ?MODULE, start_migration_preparation_on_node, Args),
    Acc1 = [PidAndRef | Acc0],
    start_migration_preparation_on_each_node(Rest, PrepGatherer, VHost, Acc1).

start_migration_preparation_on_node(PrepGatherer, VHost) ->
    %% Migration preparation -
    %% 1 - stop connections
    %% 2 - quiesce node
    %% 3 - EBS snapshot
    ?LOG_DEBUG("rqm: preparation: node ~tp starting for vhost ~tp", [node(), VHost]),
    ok = rqm_gatherer:fork(PrepGatherer),
    PreparationFun = fun() ->
        try
            Result =
                try
                    do_migration_preparation(VHost)
                catch
                    Class:Reason:Stack ->
                        ?LOG_ERROR("rqm: preparation: exception: ~tp:~tp", [Class, Reason]),
                        ?LOG_ERROR("~tp", [Stack]),
                        {error, {migration_preparation, {Class, Reason}}}
                end,
            ok = rqm_gatherer:in(PrepGatherer, Result)
        after
            ?LOG_DEBUG("rqm: node ~tp finished migration preparation for vhost ~tp", [node(), VHost]),
            ok = rqm_gatherer:finish(PrepGatherer)
        end
    end,
    ok = submit_to_worker_pool(PreparationFun).

do_migration_preparation(VHost) ->
    {ok, ConnectionPreparationState} = prepare_node_connections(VHost),
    try
        {ok, _EbsPreparationState} = quiesce_and_flush_node(VHost),
        case rqm_snapshot:create_snapshot(VHost) of
            {ok, EbsSnapshotState} ->
                MigrationPreparationState = #{
                    vhost => VHost,
                    connection_preparation_state => ConnectionPreparationState,
                    ebs_snapshot_state => EbsSnapshotState,
                    preparation_timestamp => erlang:system_time(millisecond)
                },
                {ok, #{node() => MigrationPreparationState}};
            {error, _} = Error ->
                catch restore_connection_listeners(ConnectionPreparationState),
                Error
        end
    catch
        Class:Reason:Stack ->
            case catch restore_connection_listeners(ConnectionPreparationState) of
                {ok, _} ->
                    ok;
                Error0 ->
                    ?LOG_ERROR("rqm: normal operations NOT restored for vhost ~ts, ~tp", [
                        VHost, Error0
                    ])
            end,
            erlang:raise(Class, Reason, Stack)
    end.

post_migration_restore(Nodes, PreparationState, VHost) when is_map(PreparationState) ->
    ?LOG_DEBUG(
        "rqm: starting post-migration restore for vhost ~tp on nodes ~tp",
        [VHost, Nodes]
    ),
    RestoreStart = erlang:system_time(second),

    ?LOG_DEBUG("rqm: starting post-migration restore rqm_gatherer"),
    {ok, RestoreGatherer} = rqm_gatherer:start_link(),

    ?LOG_DEBUG("rqm: dispatching work to ~w nodes for post-migration restore", [length(Nodes)]),
    ok = start_post_migration_restore_on_each_node(Nodes, RestoreGatherer, PreparationState, VHost),
    ?LOG_DEBUG("rqm: waiting for all workers to complete for post-migration restore"),

    {ok, RestoreStates} = collect_rqm_gatherer_results(
        RestoreGatherer, post_migration_restore, length(Nodes)
    ),
    ?LOG_DEBUG("rqm: RestoreStates ~tp", [RestoreStates]),

    % Always set default queue type to quorum after successful migration
    ok = set_default_queue_type_to_quorum(VHost),

    RestoreEnd = erlang:system_time(second),
    RestoreDuration = RestoreEnd - RestoreStart,
    ?LOG_DEBUG("rqm: post-migration restore duration ~w seconds", [RestoreDuration]),
    ok.

start_post_migration_restore_on_each_node(Nodes, RestoreGatherer, PreparationState, VHost) ->
    {ok, PidsAndRefs} = start_post_migration_restore_on_each_node(
        Nodes, RestoreGatherer, PreparationState, VHost, []
    ),
    ok = wait_for_monitored_processes(PidsAndRefs).

start_post_migration_restore_on_each_node([], _RestoreGatherer, _PreparationState, _VHost, Acc) ->
    {ok, Acc};
start_post_migration_restore_on_each_node(
    [Node | Rest], RestoreGatherer, PreparationState, VHost, Acc0
) when
    is_map(PreparationState)
->
    NodePreparationState = maps:get(Node, PreparationState),
    Args = [RestoreGatherer, NodePreparationState, VHost],
    % elp:ignore W0014
    PidAndRef = spawn_monitor(Node, ?MODULE, start_post_migration_restore_on_node, Args),
    Acc1 = [PidAndRef | Acc0],
    start_post_migration_restore_on_each_node(Rest, RestoreGatherer, PreparationState, VHost, Acc1).

start_post_migration_restore_on_node(RestoreGatherer, NodePreparationState, VHost) when
    is_map(NodePreparationState)
->
    %% Migration restore -
    %% 1 - restore connection listeners
    %% 2 - cleanup snapshots (if enabled)
    ?LOG_DEBUG("rqm: post-migration restore: node ~tp starting for vhost ~tp", [node(), VHost]),
    ok = rqm_gatherer:fork(RestoreGatherer),
    RestoreFun = fun() ->
        try
            ConnectionPreparationState = maps:get(
                connection_preparation_state, NodePreparationState
            ),
            {ok, ConnectionRestorationState} = restore_connection_listeners(
                ConnectionPreparationState
            ),

            ok = cleanup_node_snapshots(NodePreparationState),

            Result = {ok, #{node() => ConnectionRestorationState}},
            ok = rqm_gatherer:in(RestoreGatherer, Result)
        catch
            Class:Reason:Stack ->
                ?LOG_ERROR("rqm: post-migration restore: exception: ~tp:~tp", [Class, Reason]),
                ?LOG_ERROR("~tp", [Stack]),
                ok = rqm_gatherer:in(RestoreGatherer, {Class, {Reason, Stack}})
        after
            ?LOG_DEBUG("rqm: node ~tp finished post-migration restore for vhost ~tp", [
                node(), VHost
            ]),
            ok = rqm_gatherer:finish(RestoreGatherer)
        end
    end,
    ok = submit_to_worker_pool(RestoreFun).

-spec cleanup_node_snapshots(map()) -> ok.
cleanup_node_snapshots(NodePreparationState) ->
    case rqm_config:cleanup_snapshots_on_success() of
        false ->
            ?LOG_DEBUG("rqm: snapshot cleanup disabled, skipping cleanup"),
            ok;
        true ->
            case maps:get(ebs_snapshot_state, NodePreparationState, undefined) of
                undefined ->
                    ?LOG_DEBUG("rqm: no snapshots to clean up for node ~tp", [node()]),
                    ok;
                SnapshotState when is_binary(SnapshotState) ->
                    cleanup_single_snapshot(SnapshotState);
                {SnapshotId, _VolumeId} when is_binary(SnapshotId) ->
                    cleanup_single_snapshot(SnapshotId)
            end
    end.

-spec cleanup_single_snapshot(binary()) -> ok.
cleanup_single_snapshot(SnapshotId) ->
    case rqm_snapshot:cleanup_snapshot(SnapshotId) of
        ok ->
            ?LOG_DEBUG("rqm: successfully cleaned up snapshot: ~p", [SnapshotId]);
        {error, Reason} ->
            ?LOG_WARNING("rqm: failed to clean up snapshot ~p: ~p", [SnapshotId, Reason])
    end,
    ok.

mcq_qq_migration(
    PreparationState,
    Nodes,
    #migration_opts{
        migration_id = MigrationId,
        vhost = VHost,
        unsuitable_queues = UnsuitableQueues,
        batch_size = BatchSize
    } = Opts
) ->
    ?LOG_INFO(
        "rqm: starting migration ~s for vhost ~tp on nodes ~tp",
        [format_migration_id(MigrationId), VHost, Nodes]
    ),
    Start = erlang:system_time(second),

    ok = store_snapshot_information(MigrationId, PreparationState),

    ok = create_skipped_queue_records(MigrationId, UnsuitableQueues),

    ?LOG_DEBUG("rqm: starting rqm_gatherer for migration ~s", [format_migration_id(MigrationId)]),
    {ok, Gatherer} = rqm_gatherer:start_link(),
    {ok, QueueCountGatherer} = rqm_gatherer:start_link(),

    ?LOG_DEBUG(
        "rqm: dispatching work to ~w nodes for migration ~s",
        [length(Nodes), format_migration_id(MigrationId)]
    ),

    NodeAllocations = compute_node_allocations(Nodes, BatchSize),
    {ok, PidsAndRefs} = start_migration_on_each_node(
        NodeAllocations, QueueCountGatherer, Gatherer, Opts, []
    ),
    {ok, TotalQueueCount} = wait_for_total_queue_count(QueueCountGatherer, length(Nodes)),

    ?LOG_DEBUG(
        "rqm: waiting for all workers to complete migrating ~tp queues (migration ~s)",
        [TotalQueueCount, format_migration_id(MigrationId)]
    ),

    ok = wait_for_monitored_processes(PidsAndRefs, rqm_config:max_migration_duration_ms()),
    Result = wait_for_per_queue_migration_results(Gatherer, TotalQueueCount),
    handle_migration_result(Result, MigrationId, Start).

handle_migration_result({ok, _Results}, MigrationId, Start) ->
    ?LOG_INFO("rqm: migration ~s completed", [format_migration_id(MigrationId)]),
    End = erlang:system_time(second),
    Duration = End - Start,
    {ok, Duration, completed};
handle_migration_result({interrupted, Results}, MigrationId, Start) ->
    ?LOG_INFO("rqm: migration ~s interrupted", [format_migration_id(MigrationId)]),
    InterruptedQueues = [Resource || {aborted, Resource, interrupted} <- Results],
    [
        rqm_db:create_skipped_queue_status(Resource, MigrationId, interrupted)
     || Resource <- InterruptedQueues
    ],
    {ok, _} = rqm_db:update_migration_skipped_count(MigrationId),
    {ok, _} = rqm_db:update_migration_status(MigrationId, interrupted),
    End = erlang:system_time(second),
    Duration = End - Start,
    {ok, Duration, interrupted};
handle_migration_result({error, Errors}, MigrationId, _Start) ->
    ?LOG_WARNING(
        "rqm: checking rollback status for migration ~s",
        [format_migration_id(MigrationId)]
    ),
    {ok, MigrationRecord} = rqm_db:get_migration(MigrationId),
    case MigrationRecord#queue_migration.status of
        rollback_pending ->
            ?LOG_CRITICAL(
                "rqm: rollback_pending | migration_id ~s",
                [format_migration_id(MigrationId)]
            ),
            error({migration_failed_rollback_pending, {errors, Errors}});
        OtherStatus ->
            ?LOG_WARNING(
                "rqm: migration ~s failed but no rollback needed (status: ~tp)",
                [format_migration_id(MigrationId), OtherStatus]
            ),
            error({migration_failed_no_rollback, {errors, Errors}})
    end.

wait_for_total_queue_count(Gatherer, NodeCount) ->
    wait_for_total_queue_count(Gatherer, NodeCount, []).

wait_for_total_queue_count(Gatherer, 0, Acc) ->
    ok = rqm_gatherer:stop(Gatherer),
    {ok, lists:sum(Acc)};
wait_for_total_queue_count(Gatherer, NodeCount, Acc0) ->
    case rqm_gatherer:out(Gatherer) of
        {value, {ok, {node_queue_count, QueueCount}}} ->
            Acc1 = [QueueCount | Acc0],
            wait_for_total_queue_count(Gatherer, NodeCount - 1, Acc1);
        Unexpected ->
            error({unexpected_value, Unexpected})
    end.

wait_for_per_queue_migration_results(Gatherer, TotalQueueCount) ->
    wait_for_per_queue_migration_results(Gatherer, TotalQueueCount, false, false, []).

wait_for_per_queue_migration_results(Gatherer, 0, true = _IsError, _IsInterrupted, Acc) ->
    ok = rqm_gatherer:stop(Gatherer),
    {error, Acc};
wait_for_per_queue_migration_results(Gatherer, 0, false = _IsError, true = _IsInterrupted, Acc) ->
    ok = rqm_gatherer:stop(Gatherer),
    {interrupted, Acc};
wait_for_per_queue_migration_results(Gatherer, 0, false = _IsError, false = _IsInterrupted, Acc) ->
    ok = rqm_gatherer:stop(Gatherer),
    {ok, Acc};
wait_for_per_queue_migration_results(Gatherer, TotalQueueCount, IsError, IsInterrupted, Acc0) ->
    case rqm_gatherer:out(Gatherer) of
        empty ->
            Acc1 = [ok | Acc0],
            wait_for_per_queue_migration_results(
                Gatherer, TotalQueueCount - 1, IsError, IsInterrupted, Acc1
            );
        {value, ok} ->
            Acc1 = [ok | Acc0],
            wait_for_per_queue_migration_results(
                Gatherer, TotalQueueCount - 1, IsError, IsInterrupted, Acc1
            );
        {value, {ok, _, _} = Val} ->
            Acc1 = [Val | Acc0],
            wait_for_per_queue_migration_results(
                Gatherer, TotalQueueCount - 1, IsError, IsInterrupted, Acc1
            );
        {value, {aborted, _, interrupted} = Val} ->
            Acc1 = [Val | Acc0],
            wait_for_per_queue_migration_results(
                Gatherer, TotalQueueCount - 1, IsError, true, Acc1
            );
        Error ->
            Acc1 = [Error | Acc0],
            wait_for_per_queue_migration_results(
                Gatherer, TotalQueueCount - 1, true, IsInterrupted, Acc1
            )
    end.

start_migration_on_each_node(
    [], _QueueCountGatherer, _Gatherer, _Opts, Acc
) ->
    {ok, Acc};
start_migration_on_each_node(
    [{Node, NodeBatchSize} | Rest],
    QueueCountGatherer,
    Gatherer,
    #migration_opts{} = Opts,
    Acc0
) ->
    ok = rqm_gatherer:fork(QueueCountGatherer),
    Args = [
        QueueCountGatherer, Gatherer, NodeBatchSize, Opts
    ],
    % elp:ignore W0014
    PidAndRef = spawn_monitor(Node, ?MODULE, start_migration_on_node, Args),
    Acc1 = [PidAndRef | Acc0],
    start_migration_on_each_node(
        Rest, QueueCountGatherer, Gatherer, Opts, Acc1
    ).

start_migration_on_node(
    QueueCountGatherer,
    Gatherer,
    NodeBatchSize,
    #migration_opts{
        vhost = VHost,
        migration_id = MigrationId,
        batch_order = BatchOrder,
        queue_names = QueueNames
    } = Opts
) ->
    ?LOG_DEBUG(
        "rqm: node ~tp starting migration ~s for vhost ~tp (batch: ~p, order: ~p)",
        [node(), format_migration_id(MigrationId), VHost, NodeBatchSize, BatchOrder]
    ),

    % TODO all of this getting/filtering of queues needs to be in its own function
    %
    % Get all classic queues for this vhost on this node
    AllQueues = rabbit_db_queue:get_all_by_type_and_node(VHost, rabbit_classic_queue, node()),

    % Filter eligible queues
    EligibleQueues0 = [Q || Q <- AllQueues, is_queue_to_migrate(Q)],

    % Filter by queue_names if specified
    EligibleQueues1 = rqm_util:filter_by_queue_names(EligibleQueues0, QueueNames),

    % Filter out queues that already have status records for this migration (e.g., skipped queues)
    EligibleQueues2 = lists:filter(
        fun(Q) ->
            Resource = amqqueue:get_name(Q),
            case rqm_db:get_queue_status(Resource, MigrationId) of
                {ok, _Status} -> false;
                {error, not_found} -> true
            end
        end,
        EligibleQueues1
    ),

    % Sort and limit queues based on batch settings (ignored if queue_names specified)
    EligibleQueues3 = sort_and_limit_queues(EligibleQueues2, NodeBatchSize, BatchOrder, QueueNames),

    QueueCount = length(EligibleQueues3),
    SkippedByStatus = length(EligibleQueues0) - length(EligibleQueues1),
    SkippedByBatch = length(EligibleQueues2) - QueueCount,

    ?LOG_INFO(
        "rqm: node ~tp queue summary for migration ~s: ~w total classic, ~w eligible, ~w skipped (status), ~w excluded (batch), ~w to migrate",
        [
            node(),
            format_migration_id(MigrationId),
            length(AllQueues),
            length(EligibleQueues0),
            SkippedByStatus,
            SkippedByBatch,
            QueueCount
        ]
    ),

    % Update the migration record with the number of queues in a transaction
    GathererInData =
        case QueueCount > 0 of
            true ->
                % Update total queue count in the migration record and create queue status records
                case rqm_db:update_migration_with_queues(MigrationId, EligibleQueues3, VHost) of
                    {atomic, {ok, UpdatedQueueCount}} ->
                        ?LOG_DEBUG("rqm: updated migration record with ~w queues", [
                            UpdatedQueueCount
                        ]);
                    Other ->
                        ?LOG_WARNING("rqm: unexpected result when updating migration record: ~tp", [
                            Other
                        ])
                end,
                % Process the eligible queues
                process_queues_for_migration(EligibleQueues3, Gatherer, Opts),
                {ok, {node_queue_count, QueueCount}};
            false ->
                {ok, {node_queue_count, 0}}
        end,
    %% NB: *must* do this after calling process_queues_for_migration,
    %% to ensure rqm_gatherer:fork(Gatherer) is called before finishing the
    %% QueueCountGatherer
    ok = rqm_gatherer:in(QueueCountGatherer, GathererInData),
    ok = rqm_gatherer:finish(QueueCountGatherer).

process_queues_for_migration([], _Gatherer, _Opts) ->
    ok;
process_queues_for_migration([ClassicQ | Rest], Gatherer, #migration_opts{} = Opts) ->
    MigrationFun = fun() ->
        do_migration(ClassicQ, Gatherer, Opts)
    end,
    ok = rqm_gatherer:fork(Gatherer),
    ok = submit_to_worker_pool(MigrationFun),
    process_queues_for_migration(Rest, Gatherer, Opts).

do_migration(ClassicQ, Gatherer, #migration_opts{migration_id = MigrationId} = Opts) ->
    Resource = amqqueue:get_name(ClassicQ),

    % TODO could this be a function?
    % CRITICAL: Check migration status before starting any work
    case rqm_db:is_current_status(MigrationId, in_progress) of
        false ->
            % Check if migration was interrupted or rollback is pending
            case rqm_db:get_migration_status_value(MigrationId) of
                interrupted ->
                    ?LOG_INFO("rqm: skipping migration for ~ts - migration interrupted", [
                        rabbit_misc:rs(Resource)
                    ]),
                    ok = rqm_gatherer:in(Gatherer, {aborted, Resource, interrupted}),
                    ok = rqm_gatherer:finish(Gatherer),
                    {aborted, interrupted};
                rollback_pending ->
                    ?LOG_ERROR("rqm: aborting migration for ~ts - rollback pending", [
                        rabbit_misc:rs(Resource)
                    ]),
                    ok = rqm_gatherer:in(Gatherer, {aborted, Resource, rollback_pending}),
                    ok = rqm_gatherer:finish(Gatherer),
                    {aborted, rollback_pending};
                _ ->
                    ?LOG_ERROR(
                        "rqm: aborting migration for ~ts - overall migration no longer in progress",
                        [rabbit_misc:rs(Resource)]
                    ),
                    ok = rqm_gatherer:in(Gatherer, {aborted, Resource, migration_stopped}),
                    ok = rqm_gatherer:finish(Gatherer),
                    {aborted, migration_stopped}
            end;
        true ->
            % Proceed with normal migration
            do_migration_work(ClassicQ, Gatherer, Resource, Opts)
    end.

do_migration_work(ClassicQ, Gatherer, Resource, #migration_opts{migration_id = MigrationId} = Opts) ->
    ?LOG_DEBUG(
        "rqm: starting work on ~ts (migration ~s, node ~tp)",
        [rabbit_misc:rs(Resource), format_migration_id(MigrationId), node()]
    ),
    Ref = make_ref(),
    PPid = self(),

    % Store original queue metadata for potential rollback
    ?LOG_DEBUG("rqm: storing original metadata for ~ts", [rabbit_misc:rs(Resource)]),
    OriginalArgs = amqqueue:get_arguments(ClassicQ),
    OriginalBindings = rabbit_binding:list_for_destination(Resource),
    {ok, _} = rqm_db:store_original_queue_metadata(
        Resource, MigrationId, OriginalArgs, OriginalBindings
    ),
    ?LOG_DEBUG(
        "rqm: stored ~w bindings for ~ts",
        [length(OriginalBindings), rabbit_misc:rs(Resource)]
    ),

    ?LOG_DEBUG("rqm: marking ~ts as in_progress", [rabbit_misc:rs(Resource)]),
    {ok, TotalMessageCount} = rqm_db:get_message_count(Resource),
    ?LOG_DEBUG(
        "rqm: ~ts has ~w messages to migrate",
        [rabbit_misc:rs(Resource), TotalMessageCount]
    ),
    {ok, Status} = rqm_db:update_queue_status_started(Resource, MigrationId, TotalMessageCount),

    Fun = fun() ->
        % Note:
        % In testing, it has been observed that some shovels exit with the following reason
        % when they are stopping:
        %
        % exit:{{{badmatch,[]},[{mirrored_supervisor,child,2,...
        %
        % This is caught in the "catch" clause of this function.
        ?LOG_DEBUG(
            "rqm: worker starting for ~ts (migration ~s)",
            [rabbit_misc:rs(Resource), format_migration_id(MigrationId)]
        ),
        % Double-check migration status inside the worker process
        _ =
            % TODO duplicated check, it seems
            case rqm_db:is_current_status(MigrationId, in_progress) of
                false ->
                    % Check if migration was interrupted or rollback is pending
                    case rqm_db:get_migration_status_value(MigrationId) of
                        interrupted ->
                            ?LOG_INFO(
                                "rqm: skipping migration work for ~ts - migration interrupted",
                                [rabbit_misc:rs(Resource)]
                            ),
                            PPid ! {self(), Ref, {aborted, Resource, interrupted}};
                        rollback_pending ->
                            ?LOG_WARNING(
                                "rqm: aborting migration work for ~ts - rollback pending",
                                [rabbit_misc:rs(Resource)]
                            ),
                            PPid ! {self(), Ref, {aborted, Resource, rollback_pending}};
                        _ ->
                            ?LOG_WARNING(
                                "rqm: aborting migration work for ~ts - status changed during startup",
                                [rabbit_misc:rs(Resource)]
                            ),
                            PPid ! {self(), Ref, {aborted, Resource, migration_stopped}}
                    end;
                true ->
                    try
                        % Check for zero-message optimization
                        {ok, QuorumQ} =
                            case TotalMessageCount of
                                0 ->
                                    ?LOG_DEBUG(
                                        "rqm: ~ts has zero messages, using fast-path migration",
                                        [rabbit_misc:rs(Resource)]
                                    ),
                                    migrate_empty_queue_fast_path(
                                        ClassicQ, Resource, Status, Opts
                                    );
                                _ ->
                                    % Existing two-phase migration process
                                    migrate_with_messages(ClassicQ, Resource, Status, Opts)
                            end,
                        PPid ! {self(), Ref, {ok, Resource, qstr(QuorumQ)}}
                    catch
                        Class:Reason:Stack ->
                            ?LOG_ERROR(
                                "rqm: exception in ~ts (migration ~s): ~tp:~tp",
                                [
                                    rabbit_misc:rs(Resource),
                                    format_migration_id(MigrationId),
                                    Class,
                                    Reason
                                ]
                            ),
                            ?LOG_ERROR("~tp", [Stack]),

                            case Reason of
                                {queue_not_found, _} ->
                                    ?LOG_WARNING("rqm: ~ts was deleted during migration", [
                                        rabbit_misc:rs(Resource)
                                    ]);
                                {timeout, _} ->
                                    ?LOG_WARNING("rqm: timeout occurred for ~ts", [
                                        rabbit_misc:rs(Resource)
                                    ]);
                                _ ->
                                    ?LOG_ERROR("rqm: unexpected error for ~ts: ~tp", [
                                        rabbit_misc:rs(Resource), Reason
                                    ])
                            end,

                            ?LOG_DEBUG("rqm: marking ~ts as failed", [rabbit_misc:rs(Resource)]),
                            {ok, _} = rqm_db:update_queue_status_failed(
                                Resource,
                                MigrationId,
                                Status#queue_migration_status.started_at,
                                Status#queue_migration_status.total_messages,
                                Status#queue_migration_status.migrated_messages,
                                {Class, Reason, Stack}
                            ),

                            % CRITICAL: Set migration status to rollback_pending on first failure
                            ?LOG_CRITICAL(
                                "rqm: CRITICAL - failure detected for ~ts, setting migration status to rollback_pending",
                                [rabbit_misc:rs(Resource)]
                            ),
                            {ok, _} = rqm_db:update_migration_status(MigrationId, rollback_pending),
                            ?LOG_DEBUG("rqm: migration ~tp status updated to rollback_pending", [
                                MigrationId
                            ]),

                            PPid ! {self(), Ref, {error, Resource, {Class, Reason, Stack}}}
                    end
            end,
        unlink(PPid)
    end,

    ?LOG_DEBUG("rqm: spawning worker process for ~ts", [rabbit_misc:rs(Resource)]),
    % Note: must be in its own process to handle ra event messages
    CPid = spawn_link(Fun),
    ?LOG_DEBUG(
        "rqm: waiting for worker completion for ~ts (timeout: ~w retries)",
        [rabbit_misc:rs(Resource), rqm_config:queue_migration_timeout_retries()]
    ),
    Result = wait_for_migration(CPid, Ref, rqm_config:queue_migration_timeout_retries()),

    % Handle result - all cases must call rqm_gatherer:in and rqm_gatherer:finish
    case Result of
        {ok, QueueResource, QueueName} ->
            ?LOG_DEBUG("rqm: migrated queue ~tp", [QueueName]),
            ok = rqm_gatherer:in(Gatherer, {ok, QueueResource, QueueName}),
            ok = rqm_gatherer:finish(Gatherer);
        {error, QueueResource, ErrorDetails} ->
            ?LOG_ERROR("rqm: failed for ~ts: ~tp", [rabbit_misc:rs(QueueResource), ErrorDetails]),
            ok = rqm_gatherer:in(Gatherer, {error, QueueResource, ErrorDetails}),
            ok = rqm_gatherer:finish(Gatherer);
        {aborted, QueueResource, Reason} ->
            ?LOG_ERROR("rqm: aborted for ~ts: ~tp", [rabbit_misc:rs(QueueResource), Reason]),
            ok = rqm_gatherer:in(Gatherer, {aborted, QueueResource, Reason}),
            ok = rqm_gatherer:finish(Gatherer)
    end,
    Result.

wait_for_migration(_CPid, _Ref, 0) ->
    ?LOG_ERROR("rqm: final do_migration timeout!"),
    {error, timeout};
wait_for_migration(CPid, Ref, Retries0) ->
    receive
        {CPid, Ref, {ok, QueueResource, QName}} ->
            ?LOG_DEBUG("rqm: migrated queue ~tp", [QName]),
            {ok, QueueResource, QName};
        {CPid, Ref, {error, QueueResource, ErrorDetails}} ->
            ?LOG_ERROR("rqm: failed for ~ts: ~tp", [rabbit_misc:rs(QueueResource), ErrorDetails]),
            {error, QueueResource, ErrorDetails};
        {CPid, Ref, {aborted, QueueResource, Reason}} ->
            ?LOG_ERROR("rqm: aborted for ~ts: ~tp", [rabbit_misc:rs(QueueResource), Reason]),
            {aborted, QueueResource, Reason};
        Other ->
            ?LOG_DEBUG("rqm: handled other message: ~tp", [Other]),
            wait_for_migration(CPid, Ref, Retries0)
    after rqm_config:queue_migration_timeout_ms() ->
        Retries1 = Retries0 - 1,
        ?LOG_ERROR("rqm: do_migration timeout, retrying. Retries remaining: ~B", [Retries1]),
        wait_for_migration(CPid, Ref, Retries1)
    end.

migrate_to_tmp_qq(FinalResource, Q, #migration_opts{} = Opts) ->
    AddTmpPrefixFun = fun rqm_queue_naming:add_temp_prefix/2,
    migrate(FinalResource, Q, AddTmpPrefixFun, phase_one, Opts).

tmp_qq_to_qq(FinalResource, Q, #migration_opts{} = Opts) ->
    RemoveTmpPrefixFun = fun rqm_queue_naming:remove_temp_prefix/2,
    migrate(FinalResource, Q, RemoveTmpPrefixFun, phase_two, Opts).

migrate_empty_queue_fast_path(ClassicQ, Resource, Status, #migration_opts{
    migration_id = MigrationId
}) ->
    ?LOG_DEBUG("rqm: fast-path migration for empty ~ts", [rabbit_misc:rs(Resource)]),

    % Create final quorum queue directly (skip temporary queue)

    % Same name as original
    FinalResource = Resource,
    NewArgs = convert_args(amqqueue:get_arguments(ClassicQ)),

    % Copy bindings from classic to quorum queue
    Bindings = rabbit_binding:list_for_destination(Resource),
    ?LOG_DEBUG("rqm: copying ~w bindings for ~ts", [length(Bindings), rabbit_misc:rs(Resource)]),

    % Delete the source classic queue first (safe because AMQP is blocked)
    ?LOG_DEBUG("rqm: deleting empty source ~ts", [rabbit_misc:rs(Resource)]),
    try
        case rabbit_amqqueue:delete(ClassicQ, false, false, <<"migration_user">>) of
            {ok, _} ->
                ?LOG_DEBUG("rqm: successfully deleted empty source ~ts", [rabbit_misc:rs(Resource)]);
            Error ->
                ?LOG_ERROR("rqm: failed to delete empty source ~ts: ~tp", [
                    rabbit_misc:rs(Resource), Error
                ]),
                error({failed_to_delete_source_queue, Resource, Error})
        end
    catch
        exit:{{shutdown, delete}, Stack} ->
            ?LOG_WARNING("rqm: unexpected exit when deleting empty queue: ~tp", [Stack])
    end,

    % Create the final quorum queue (no name conflict now)
    NewQ =
        case
            rabbit_amqqueue:declare(FinalResource, true, false, NewArgs, none, <<"internal_user">>)
        of
            {new, Queue} ->
                ?LOG_DEBUG("rqm: created final quorum ~ts", [rabbit_misc:rs(FinalResource)]),
                Queue;
            {existing, Queue} ->
                ?LOG_DEBUG("rqm: using existing quorum ~ts", [rabbit_misc:rs(FinalResource)]),
                Queue
        end,

    % Add bindings to the new quorum queue
    QueueName = Resource#resource.name,
    FilteredBindings = filter_default_bindings(Bindings, QueueName),
    ?LOG_DEBUG(
        "rqm: filtered ~w default bindings, ~w remaining for ~ts",
        [
            length(Bindings) - length(FilteredBindings),
            length(FilteredBindings),
            rabbit_misc:rs(Resource)
        ]
    ),
    _ = [
        rabbit_binding:add(B#binding{destination = FinalResource}, <<"internaluser">>)
     || B <- FilteredBindings
    ],

    % Update queue status to completed
    ?LOG_DEBUG("rqm: marking empty ~ts as completed", [rabbit_misc:rs(Resource)]),
    {ok, _} = rqm_db:update_queue_status_completed(
        Resource,
        MigrationId,
        Status#queue_migration_status.started_at,
        % total_messages
        0,
        % migrated_messages
        0
    ),

    {ok, _} = rqm_db:update_migration_completed_count(Status#queue_migration_status.migration_id),

    ?LOG_DEBUG("rqm: fast-path migration completed for ~ts", [rabbit_misc:rs(Resource)]),
    {ok, NewQ}.

migrate_with_messages(ClassicQ, Resource, Status, #migration_opts{} = Opts) ->
    ?LOG_DEBUG(
        "rqm: ~ts entering phase 1 - creating temporary quorum queue",
        [rabbit_misc:rs(Resource)]
    ),
    StartTime = erlang:system_time(millisecond),
    {ok, QuorumQ0} = migrate_to_tmp_qq(Resource, ClassicQ, Opts),
    Phase1Time = erlang:system_time(millisecond) - StartTime,
    ?LOG_DEBUG(
        "rqm: ~ts phase 1 completed in ~wms",
        [rabbit_misc:rs(Resource), Phase1Time]
    ),

    ?LOG_DEBUG(
        "rqm: ~ts entering phase 2 - migrating to final quorum queue",
        [rabbit_misc:rs(Resource)]
    ),
    Phase2Start = erlang:system_time(millisecond),
    {ok, QuorumQ1} = tmp_qq_to_qq(Resource, QuorumQ0, Opts),
    Phase2Time = erlang:system_time(millisecond) - Phase2Start,
    ?LOG_DEBUG(
        "rqm: ~ts phase 2 completed in ~wms",
        [rabbit_misc:rs(Resource), Phase2Time]
    ),

    ?LOG_DEBUG("rqm: marking ~ts as completed", [rabbit_misc:rs(Resource)]),
    {ok, _} = rqm_db:update_queue_status_completed(
        Resource,
        Status#queue_migration_status.migration_id,
        Status#queue_migration_status.started_at,
        Status#queue_migration_status.total_messages,
        Status#queue_migration_status.total_messages
    ),

    {ok, _} = rqm_db:update_migration_completed_count(Status#queue_migration_status.migration_id),

    {ok, QuorumQ1}.

migrate(FinalResource, Q, NameFun, Phase, #migration_opts{migration_id = MigrationId} = Opts) ->
    Resource = amqqueue:get_name(Q),
    QName = Resource#resource.name,
    NewQName = NameFun(QName, MigrationId),

    ?LOG_DEBUG("rqm: migrating ~tp to ~tp", [QName, NewQName]),

    NewResource = Resource#resource{name = NewQName},

    NewArgs = convert_args(amqqueue:get_arguments(Q)),

    NewQ =
        case
            rabbit_amqqueue:declare(NewResource, true, false, NewArgs, none, <<"internal_user">>)
        of
            {new, Queue} ->
                ?LOG_DEBUG("rqm: created new queue ~ts", [rabbit_misc:rs(NewResource)]),
                Queue;
            {existing, Queue} ->
                ?LOG_WARNING("rqm: using existing queue ~ts", [rabbit_misc:rs(NewResource)]),
                Queue
        end,

    Bindings = rabbit_binding:list_for_destination(Resource),

    %% Filter out default exchange bindings to avoid duplicates
    QueueName = Resource#resource.name,
    FilteredBindings = filter_default_bindings(Bindings, QueueName),
    ?LOG_DEBUG(
        "rqm: filtered ~w default bindings, ~w remaining for ~ts",
        [
            length(Bindings) - length(FilteredBindings),
            length(FilteredBindings),
            rabbit_misc:rs(Resource)
        ]
    ),

    BindingResults = [
        rabbit_binding:add(B#binding{destination = NewResource}, <<"internaluser">>)
     || B <- FilteredBindings
    ],

    FailedBindings = [R || R <- BindingResults, R =/= ok],

    case FailedBindings of
        [] ->
            ?LOG_DEBUG("rqm: successfully created ~p bindings for ~ts", [
                length(FilteredBindings), rabbit_misc:rs(Resource)
            ]);
        _ ->
            ?LOG_ERROR("rqm: ~p binding(s) failed for ~ts: ~tp", [
                length(FailedBindings), rabbit_misc:rs(Resource), FailedBindings
            ])
    end,

    ok = migrate_queue_messages(FinalResource, Q, NewQ, Phase, Opts),

    %% Delete the source queue after successful message migration
    try
        case rabbit_amqqueue:delete(Q, false, false, <<"migration_user">>) of
            {ok, _} ->
                ?LOG_DEBUG("rqm: deleted source queue ~ts", [rabbit_misc:rs(Resource)]);
            Error ->
                ?LOG_ERROR("rqm: failed to delete source queue ~ts: ~tp", [
                    rabbit_misc:rs(Resource), Error
                ]),
                error({failed_to_delete_source_queue, Resource, Error})
        end
        %% LRB this really shouldn't be necessary
        %% See mqtt_node.erl line 167
    catch
        exit:{{shutdown, delete}, Stack} ->
            ?LOG_WARNING("rqm: unexpected exit when deleting QQ ~tp", [Stack])
    end,

    {ok, NewQ}.

migrate_queue_messages(FinalResource, OldQ, NewQ, Phase, #migration_opts{} = Opts) ->
    ok = migrate_queue_messages_with_shovel(FinalResource, OldQ, NewQ, Phase, Opts).

migrate_queue_messages_with_shovel(FinalResource, OldQ, NewQ, Phase, #migration_opts{} = Opts) ->
    OldQName = get_queue_name(OldQ),
    NewQName = get_queue_name(NewQ),
    VHost = get_vhost_from_resource(FinalResource),
    ShovelName = create_migration_shovel_name(FinalResource, Phase),

    {ok, MessagesToMigrate} = rqm_db:get_message_count(OldQ),
    {ok, DestInitialCount} = rqm_db:get_message_count(NewQ),

    ?LOG_DEBUG(
        "rqm: starting shovel-based migration from ~ts (~tp messages) to ~ts (~tp messages) (shovel: ~ts)",
        [OldQName, MessagesToMigrate, NewQName, DestInitialCount, ShovelName]
    ),

    case DestInitialCount of
        0 ->
            ok;
        Val when is_integer(Val) ->
            ?LOG_ERROR("rqm: expected 0 messages in queue ~tp, got ~tp", [NewQName, Val])
    end,

    %% Store pre-migration counts for verification
    PreMigrationCounts = #{
        source => MessagesToMigrate,
        destination => DestInitialCount,
        expected_total => MessagesToMigrate + DestInitialCount
    },

    ShovelDef = rqm_shovel:build_definition(OldQName, NewQName, MessagesToMigrate, VHost),

    try
        ?LOG_DEBUG("rqm: creating and verifying shovel ~ts", [ShovelName]),
        ok = rqm_shovel:create_and_verify(VHost, ShovelName, ShovelDef),

        ok = wait_for_shovel_completion(
            ShovelName, VHost, FinalResource, OldQ, NewQ, PreMigrationCounts, Opts
        )
    catch
        Class:Reason:Stack ->
            ?LOG_ERROR("rqm: shovel ~ts failed: ~tp:~tp", [ShovelName, Class, Reason]),
            ?LOG_ERROR("~tp", [Stack]),
            erlang:raise(Class, Reason, Stack)
    after
        rqm_shovel:cleanup(ShovelName, VHost)
    end.

%% NB:
%% deps/rabbit/src/rabbit_amqqueue.erl
%%
%% perform_limited_equivalence_checks_on_qq_redeclaration(Q, NewArgs) ->
%%     QName = amqqueue:get_name(Q),
%%     ExistingArgs = amqqueue:get_arguments(Q),
%%     CheckTypeArgs = [<<"x-dead-letter-exchange">>,
%%                      <<"x-dead-letter-routing-key">>,
%%                      <<"x-expires">>,
%%                      <<"x-max-length">>,
%%                      <<"x-max-length-bytes">>,
%%                      <<"x-single-active-consumer">>,
%%                      <<"x-message-ttl">>],
%%     ok = rabbit_misc:assert_args_equivalence(ExistingArgs, NewArgs, QName, CheckTypeArgs).
convert_args(Args) ->
    QQType = {<<"x-queue-type">>, longstr, <<"quorum">>},
    NewArgs =
        lists:filtermap(
            fun
                %% reject-publish-dlx is not supported by quorum queues and reject-publish
                %% does not work the same way (no dead lettering). This should be caught
                %% by the compatibility checker and prevent migration.
                %% https://www.rabbitmq.com/docs/quorum-queues#dead-lettering
                ({<<"x-overflow">>, longstr, <<"reject-publish-dlx">>}) ->
                    ?LOG_WARNING(
                        "rqm: UNEXPECTED reject-publish-dlx found in convert_args/1. "
                        "This should have been caught by compatibility checking. "
                        "Converting to reject-publish (NOTE: dead lettering behavior will be lost)."
                    ),
                    {true, {<<"x-overflow">>, longstr, <<"reject-publish">>}};
                % Remove classic queue specific arguments that don't apply to quorum queues
                ({<<"x-max-priority">>, _, _}) ->
                    % Priority queues work differently in quorum queues
                    false;
                ({<<"x-queue-mode">>, _, _}) ->
                    % Lazy mode doesn't apply to quorum queues
                    false;
                ({<<"x-queue-type">>, _, _}) ->
                    % Will be replaced with quorum type
                    false;
                ({<<"x-queue-master-locator">>, _, _}) ->
                    % Master locator is classic queue specific
                    false;
                ({<<"x-queue-version">>, _, _}) ->
                    % Queue version is classic queue specific
                    false;
                % Keep all other arguments (including critical ones that will be checked)
                (Arg) ->
                    {true, Arg}
            end,
            Args
        ),
    [QQType | NewArgs].

create_migration_shovel_name(Resource, Phase) ->
    QueueName = Resource#resource.name,
    PhaseStr =
        case Phase of
            phase_one -> <<"_p1">>;
            phase_two -> <<"_p2">>
        end,
    <<"migration_", QueueName/binary, PhaseStr/binary>>.

get_queue_name(Q) ->
    Resource = amqqueue:get_name(Q),
    Resource#resource.name.

get_vhost_from_resource(Resource) ->
    Resource#resource.virtual_host.

%% Filter out default exchange bindings to avoid duplicates
%% Default exchange bindings are automatically created for new queues
filter_default_bindings(Bindings, QueueName) ->
    lists:filter(
        fun(#binding{source = Source, key = Key}) ->
            not (Source#resource.name =:= <<"">> andalso Key =:= QueueName)
        end,
        Bindings
    ).

%% Wait for shovel to complete migration using message count-based detection
wait_for_shovel_completion(
    ShovelName,
    VHost,
    FinalResource,
    SrcQueue,
    DestQueue,
    PreMigrationCounts,
    #migration_opts{} = Opts
) when ?is_amqqueue(SrcQueue), ?is_amqqueue(DestQueue) ->
    % MaxRetries = 900, with 1-second sleep per retry = 15 minutes maximum wait
    wait_for_shovel_completion_stable(
        ShovelName,
        VHost,
        FinalResource,
        SrcQueue,
        DestQueue,
        PreMigrationCounts,
        900,
        [],
        Opts
    ).

wait_for_shovel_completion_stable(
    ShovelName,
    VHost,
    FinalResource,
    SrcQueue,
    DestQueue,
    PreMigrationCounts,
    MaxRetries,
    DestCountHistory,
    #migration_opts{} = Opts
) ->
    case MaxRetries of
        0 ->
            ?LOG_ERROR("rqm: timeout waiting for message transfer completion"),
            {ok, SrcCount} = rqm_db:get_message_count(SrcQueue),
            {ok, DestCount} = rqm_db:get_message_count(DestQueue),
            CurrentCounts = #{
                src_count => SrcCount, dest_count => DestCount, total_count => SrcCount + DestCount
            },
            error({shovel_timeout, unknown, CurrentCounts});
        _ ->
            {ok, SrcCount} = rqm_db:get_message_count(SrcQueue),
            {ok, DestCount} = rqm_db:get_message_count(DestQueue),

            % Keep last N destination counts for stability check
            NewHistory = [
                DestCount | lists:sublist(DestCountHistory, ?SHOVEL_STABILITY_ITERATIONS - 1)
            ],

            ExpectedTotal = maps:get(expected_total, PreMigrationCounts),

            case
                check_shovel_completion_by_stability(ExpectedTotal, SrcCount, DestCount, NewHistory)
            of
                {completed, Reason} ->
                    ?LOG_DEBUG(
                        "rqm: shovel completed (~p) after ~w stability iterations - src: ~w, dest: ~w",
                        [Reason, length(NewHistory), SrcCount, DestCount]
                    ),
                    {ok, _} = verify_and_update_progress(
                        ExpectedTotal, FinalResource, SrcQueue, DestQueue, Opts
                    ),
                    ok;
                in_progress ->
                    SrcQueueName = amqqueue:get_name(SrcQueue),
                    DestQueueName = amqqueue:get_name(DestQueue),
                    ?LOG_DEBUG(
                        "rqm: shovel in progress - src: ~ts (~w), dest: ~ts (~w)",
                        [
                            rabbit_misc:rs(SrcQueueName),
                            SrcCount,
                            rabbit_misc:rs(DestQueueName),
                            DestCount
                        ]
                    ),
                    update_queue_status_progress(FinalResource, DestQueue, Opts),

                    timer:sleep(1000),

                    wait_for_shovel_completion_stable(
                        ShovelName,
                        VHost,
                        FinalResource,
                        SrcQueue,
                        DestQueue,
                        PreMigrationCounts,
                        MaxRetries - 1,
                        NewHistory,
                        Opts
                    )
            end
    end.

% This is the case where the destination count is exactly the expected total,
% with source count being 0. We're definitely done at this point!
check_shovel_completion_by_stability(ExpectedTotal, 0, ExpectedTotal, _DestCountHistory) ->
    {completed, source_empty_and_destination_exact_count};
check_shovel_completion_by_stability(_ExpectedTotal, 0, DestCount, DestCountHistory) ->
    % Even when source is empty, wait for destination count stability
    % to handle race conditions with quorum queue count updates
    case length(DestCountHistory) of
        N when N >= ?SHOVEL_STABILITY_ITERATIONS ->
            % Check if destination count has been stable for N iterations
            case lists:all(fun(Count) -> Count =:= DestCount end, DestCountHistory) of
                true ->
                    % Source empty AND destination stable - transfer complete
                    {completed, source_empty_and_destination_stable};
                false ->
                    % Source empty but destination still changing - wait for stability
                    in_progress
            end;
        _ ->
            % Source empty but not enough destination history yet
            in_progress
    end;
check_shovel_completion_by_stability(_ExpectedTotal, SrcCount, _DestCount, _DestCountHistory) when
    is_integer(SrcCount) andalso SrcCount > 0
->
    % Source still has messages - shovel must be in progress.
    in_progress.

update_queue_status_progress(#resource{} = FinalResource, DestQueue, #migration_opts{
    migration_id = MigrationId
}) when
    ?is_amqqueue(DestQueue)
->
    DestQueueResource = amqqueue:get_name(DestQueue),
    try
        {ok, TotalMessageCount} = rqm_db:get_message_count(DestQueueResource),
        case rqm_db:update_queue_status_progress(FinalResource, MigrationId, TotalMessageCount) of
            {ok, _} ->
                ok;
            {error, Reason0} ->
                ?LOG_WARNING(
                    "rqm: failed to update queue progress for ~ts: ~tp",
                    [rabbit_misc:rs(FinalResource), Reason0]
                ),
                ok
        end
    catch
        Class:Reason1:Stack ->
            ?LOG_ERROR(
                "rqm: unexpected error (~ts): ~tp:~tp",
                [rabbit_misc:rs(DestQueueResource), Class, Reason1]
            ),
            ?LOG_DEBUG("~tp", [Stack])
    end.

%% Verify message counts and update progress with actual counts
verify_and_update_progress(
    ExpectedTotal, FinalResource, SrcQueue, DestQueue, #migration_opts{} = Opts
) ->
    {ok, SrcFinalCount} = rqm_db:get_message_count(SrcQueue),
    {ok, DestFinalCount} = rqm_db:get_message_count(DestQueue),
    ActualTotal = SrcFinalCount + DestFinalCount,
    verify_message_counts(ExpectedTotal, ActualTotal, FinalResource, DestFinalCount, Opts).

verify_message_counts(Expected, Expected, FinalResource, DestFinalCount, #migration_opts{
    migration_id = MigrationId
}) ->
    rqm_db:update_queue_status_progress(FinalResource, MigrationId, DestFinalCount);
verify_message_counts(
    ExpectedTotal, ActualTotal, FinalResource, DestFinalCount, #migration_opts{} = Opts
) ->
    LostMessages = ExpectedTotal - ActualTotal,
    check_message_count_tolerance(
        LostMessages, ExpectedTotal, ActualTotal, FinalResource, DestFinalCount, Opts
    ).

check_message_count_tolerance(
    LostMessages,
    ExpectedTotal,
    ActualTotal,
    FinalResource,
    DestFinalCount,
    #migration_opts{tolerance = Tolerance} = Opts
) when
    LostMessages < 0
->
    % Over-delivery: ActualTotal > ExpectedTotal
    Diff = abs(LostMessages),
    TolerancePercent = get_tolerance_percent(Tolerance, over),
    ToleranceValue = round(ExpectedTotal * TolerancePercent / 100.0),
    check_within_tolerance(
        Diff =< ToleranceValue,
        over,
        TolerancePercent,
        ExpectedTotal,
        ActualTotal,
        LostMessages,
        FinalResource,
        DestFinalCount,
        Opts
    );
check_message_count_tolerance(
    LostMessages,
    ExpectedTotal,
    ActualTotal,
    FinalResource,
    DestFinalCount,
    #migration_opts{tolerance = Tolerance} = Opts
) when
    LostMessages > 0
->
    % Under-delivery: ActualTotal < ExpectedTotal
    Diff = abs(LostMessages),
    TolerancePercent = get_tolerance_percent(Tolerance, under),
    ToleranceValue = round(ExpectedTotal * TolerancePercent / 100.0),
    check_within_tolerance(
        Diff =< ToleranceValue,
        under,
        TolerancePercent,
        ExpectedTotal,
        ActualTotal,
        LostMessages,
        FinalResource,
        DestFinalCount,
        Opts
    ).

get_tolerance_percent(undefined, over) ->
    rqm_config:message_count_over_tolerance_percent();
get_tolerance_percent(undefined, under) ->
    rqm_config:message_count_under_tolerance_percent();
get_tolerance_percent(Tolerance, _Direction) when is_float(Tolerance) ->
    Tolerance.

check_within_tolerance(
    true,
    Direction,
    TolerancePercent,
    ExpectedTotal,
    ActualTotal,
    LostMessages,
    FinalResource,
    DestFinalCount,
    #migration_opts{migration_id = MigrationId}
) ->
    ?LOG_WARNING(
        "rqm: message count ~p-delivery within tolerance (~tp%) - Expected: ~tp, Actual: ~tp, Diff: ~tp",
        [Direction, TolerancePercent, ExpectedTotal, ActualTotal, LostMessages]
    ),
    rqm_db:update_queue_status_progress(FinalResource, MigrationId, DestFinalCount);
check_within_tolerance(
    false,
    Direction,
    TolerancePercent,
    ExpectedTotal,
    ActualTotal,
    LostMessages,
    _FinalResource,
    _DestFinalCount,
    _Opts
) ->
    ?LOG_ERROR(
        "rqm: message count ~p-delivery exceeds tolerance (~tp%) - Expected: ~tp, Actual: ~tp, Diff: ~tp",
        [Direction, TolerancePercent, ExpectedTotal, ActualTotal, LostMessages]
    ),
    error({message_count_mismatch, ExpectedTotal, ActualTotal, LostMessages}).
is_queue_to_migrate(Q) ->
    is_queue_to_migrate(check_local_node, Q).

is_queue_to_migrate(check_local_node, Q) when ?amqqueue_pid_runs_on_local_node(Q) ->
    is_queue_to_migrate(check_is_classic, Q);
is_queue_to_migrate(check_local_node, Q) ->
    ?LOG_WARNING("rqm: skipping ~tp, not local to node ~tp", [qstr(Q), node()]),
    false;
is_queue_to_migrate(check_is_classic, Q) when
    ?amqqueue_pid_runs_on_local_node(Q) andalso ?amqqueue_is_classic(Q)
->
    is_queue_to_migrate(check_exclusive_and_policy, Q);
is_queue_to_migrate(check_is_classic, Q) ->
    ?LOG_WARNING("rqm: skipping ~tp, not a classic queue", [qstr(Q), node()]),
    false;
is_queue_to_migrate(check_exclusive_and_policy, Q) when
    ?amqqueue_pid_runs_on_local_node(Q) andalso
        ?amqqueue_is_classic(Q) andalso
        ?amqqueue_exclusive_owner_is(Q, none)
->
    case rqm_util:has_ha_policy(Q) of
        true ->
            true;
        _ ->
            ?LOG_WARNING("rqm: skipping ~tp, no HA policy", [qstr(Q)]),
            false
    end;
is_queue_to_migrate(check_exclusive_and_policy, Q) ->
    ?LOG_WARNING("rqm: skipping exclusive queue ~tp", [qstr(Q)]),
    false.

qstr(Q) when ?is_amqqueue(Q) ->
    Res = amqqueue:get_name(Q),
    rabbit_misc:rs(Res).

-spec get_queue_migrate_lock(list(node())) ->
    {true, {?MODULE, pid()}} | false.
get_queue_migrate_lock(Nodes) when is_list(Nodes) ->
    Id = {?MODULE, self()},
    case global:set_lock(Id, Nodes, 0) of
        true ->
            {true, Id};
        false ->
            false
    end.

-spec ensure_no_local_connections() -> boolean().
ensure_no_local_connections() ->
    case rabbit_networking:local_connections() of
        [] ->
            true;
        [_ | _] ->
            false;
        _ ->
            true
    end.

get_migration_status() ->
    rqm_db:get_migration_status().

get_queue_migration_status(MigrationId) ->
    rqm_db:get_queue_migration_status(MigrationId).

%% @doc Get rollback pending migration as JSON string for HOTW workflow
%% Returns {ok, JsonBinary} if rollback_pending migration exists, {error, not_found} otherwise
-spec get_rollback_pending_migration_json() -> {ok, binary()} | {error, not_found}.
get_rollback_pending_migration_json() ->
    case rqm_db:get_rollback_pending_migration() of
        {ok, Migration} ->
            rabbit_json:encode(rqm_mgmt:migration_to_json_detail(Migration));
        {error, not_found} ->
            {error, not_found}
    end.

%% Helper function to format migration ID for logging
%% Extracts timestamp from {Timestamp, Node} tuple and formats as string
format_migration_id({Timestamp, _Node}) ->
    integer_to_list(Timestamp).

%% Format error for storage in migration record
format_migration_error(_Class, {migration_failed_rollback_pending, {errors, Errors}}) ->
    {ErrorCount, AbortedCount} = count_errors_and_aborted(Errors),
    iolist_to_binary(
        io_lib:format("Migration failed: ~p error(s), ~p aborted. Rollback pending.", [
            ErrorCount, AbortedCount
        ])
    );
format_migration_error(_Class, {migration_failed_no_rollback, {errors, Errors}}) ->
    {ErrorCount, AbortedCount} = count_errors_and_aborted(Errors),
    iolist_to_binary(
        io_lib:format("Migration failed: ~p error(s), ~p aborted. No rollback needed.", [
            ErrorCount, AbortedCount
        ])
    );
format_migration_error(_Class, {preparation_failed, Reason}) when is_binary(Reason) ->
    <<"Preparation failed: ", Reason/binary>>;
format_migration_error(_Class, {preparation_failed, Reason}) ->
    iolist_to_binary(io_lib:format("Preparation failed: ~tp", [Reason]));
format_migration_error(
    _Class,
    {error,
        {migration_preparation, {snapshot_failed, _Volume, {snapshot_creation_failed, Details}}}}
) ->
    case extract_aws_error_message(Details) of
        {ok, Code, Message} ->
            iolist_to_binary(io_lib:format("Snapshot creation failed: ~s - ~s", [Code, Message]));
        error ->
            <<"Snapshot creation failed">>
    end;
format_migration_error(Class, Ex) ->
    iolist_to_binary(io_lib:format("~tp: ~tp", [Class, Ex])).

extract_aws_error_message(Details) when is_list(Details) ->
    try
        Errors = proplists:get_value("Errors", Details),
        [ErrorMap] = proplists:get_value("Error", Errors),
        Code = proplists:get_value("Code", ErrorMap),
        Message = proplists:get_value("Message", ErrorMap),
        {ok, Code, Message}
    catch
        _:_ -> error
    end;
extract_aws_error_message(_) ->
    error.

%% Helper function to compute per-node batch allocations
%% Returns list of {Node, AllocationCount} tuples
compute_node_allocations(Nodes, all) ->
    [{Node, all} || Node <- Nodes];
compute_node_allocations(Nodes, BatchSize) when is_integer(BatchSize), BatchSize > 0 ->
    NodeCount = length(Nodes),
    Base = BatchSize div NodeCount,
    Remainder = BatchSize rem NodeCount,
    {Allocations, _} = lists:mapfoldl(
        fun(Node, Rem) ->
            Extra =
                case Rem > 0 of
                    true -> 1;
                    false -> 0
                end,
            {{Node, Base + Extra}, Rem - Extra}
        end,
        Remainder,
        Nodes
    ),
    Allocations;
compute_node_allocations(Nodes, 0) ->
    [{Node, all} || Node <- Nodes].

%% Helper function to sort queues by size and limit to batch count
sort_and_limit_queues(Queues, _Limit, _BatchOrder, QueueNames) when is_list(QueueNames) ->
    Queues;
sort_and_limit_queues(Queues, all, _BatchOrder, _QueueNames) ->
    Queues;
sort_and_limit_queues(Queues, Limit, BatchOrder, _QueueNames) when is_integer(Limit) ->
    SortedQueues = sort_queues_by_size(Queues, BatchOrder),
    lists:sublist(SortedQueues, Limit).

sort_queues_by_size(Queues, BatchOrder) ->
    QueuesWithSize = lists:map(
        fun(Q) ->
            Info = rabbit_amqqueue:info(Q, [message_bytes]),
            Size = proplists:get_value(message_bytes, Info, 0),
            {Size, Q}
        end,
        Queues
    ),
    Sorted =
        case BatchOrder of
            smallest_first -> lists:keysort(1, QueuesWithSize);
            largest_first -> lists:reverse(lists:keysort(1, QueuesWithSize))
        end,
    [Q || {_Size, Q} <- Sorted].

%% Helper function to count errors and aborted results
count_errors_and_aborted(Errors) ->
    ErrorCount = length([E || E <- Errors, element(1, E) =:= error]),
    AbortedCount = length([A || A <- Errors, element(1, A) =:= aborted]),
    {ErrorCount, AbortedCount}.

%% @doc Prepare the RabbitMQ node connections for migration
%% 1. Suspend non-HTTP listeners (blocks AMQP connections, keeps HTTP API available)
%% 2. Close existing AMQP connections (stub - to be implemented)
%% Returns {ok, ConnectionPreparationState} on success for use in restoration
-type connection_preparation_state() :: #{
    node := node(),
    vhost := rabbit_types:vhost(),
    closed_connections := integer(),
    preparation_timestamp := integer(),
    suspended_listeners := list(rabbit_types:listener())
}.

-spec prepare_node_connections(rabbit_types:vhost()) ->
    {ok, connection_preparation_state()}.

prepare_node_connections(VHost) ->
    ?LOG_DEBUG("rqm: connection preparation: starting for vhost ~ts", [VHost]),

    % Step 1: Suspend non-HTTP listeners to block new AMQP connections
    % Keep HTTP API available for monitoring and control
    ?LOG_DEBUG("rqm: connection preparation: suspending non-HTTP listeners"),
    {ok, SuspendedListeners} = rqm_util:suspend_non_http_listeners(),

    % Step 2: Close existing AMQP connections
    {ok, NConnections} = rqm_util:close_all_client_connections(),

    % Step 3: Ensure no connections
    case ensure_no_local_connections() of
        true ->
            ?LOG_DEBUG("rqm: connection preparation: verified no local connections");
        _ ->
            ?LOG_ERROR("rqm: connection preparation: local connections still exist!")
    end,

    ConnectionPreparationState = #{
        node => node(),
        vhost => VHost,
        closed_connections => NConnections,
        suspended_listeners => SuspendedListeners,
        preparation_timestamp => erlang:system_time(millisecond)
    },

    ?LOG_DEBUG("rqm: connection preparation: completed successfully for vhost ~ts", [VHost]),
    {ok, ConnectionPreparationState}.

%% @doc Restore node connection listeners after successful migration
%% This function reverses the preparation steps:
%% 1. Resume suspended listeners
%% 2. Allow new connections
-type restoration_state() :: #{
    restoration_timestamp := integer(),
    restored_listeners := list(any()),
    vhost := rabbit_types:vhost()
}.

-spec restore_connection_listeners(connection_preparation_state()) ->
    {ok, restoration_state()}.

restore_connection_listeners(#{
    node := Node,
    vhost := VHost,
    suspended_listeners := SuspendedListeners
}) when Node =:= node() ->
    ?LOG_DEBUG("rqm: restoring normal operations for vhost ~ts", [VHost]),

    % Step 1: Resume suspended listeners to allow new AMQP connections
    ?LOG_DEBUG("rqm: resuming suspended listeners"),
    {ok, _ResumedListeners} = rqm_util:resume_non_http_listeners(SuspendedListeners),

    RestorationState = #{
        vhost => VHost,
        restored_listeners => SuspendedListeners,
        restoration_timestamp => erlang:system_time(millisecond)
    },

    ?LOG_DEBUG("rqm: normal operations restored for vhost ~ts", [VHost]),
    {ok, RestorationState};
restore_connection_listeners(#{
    node := WrongNode,
    vhost := VHost,
    suspended_listeners := SuspendedListeners
}) ->
    ?LOG_ERROR(
        "rqm: unexpected node ~tp when restoring normal operations for vhost ~ts",
        [WrongNode, VHost]
    ),
    RestorationState = #{
        vhost => VHost,
        restored_listeners => SuspendedListeners,
        restoration_timestamp => erlang:system_time(millisecond)
    },
    {ok, RestorationState}.

%% @doc Prepare the RabbitMQ cluster for EBS snapshot creation
%% This function implements the pre-snapshot quiescing workflow:
%% 1. Quiesce cluster state (stub - to be implemented)
%% 2. Flush disk operations (stub - to be implemented)
%% Returns {ok, EbsPreparationState} on success for use in restoration
-type ebs_preparation_state() :: #{
    vhost := rabbit_types:vhost(),
    preparation_timestamp := integer()
}.

-spec quiesce_and_flush_node(rabbit_types:vhost()) ->
    {ok, ebs_preparation_state()}.

quiesce_and_flush_node(VHost) ->
    ?LOG_DEBUG("rqm: quiescing and flushing node ~tp for vhost ~ts", [node(), VHost]),

    % Sync filesystem to ensure all data is written to disk
    % This is the most critical step for EBS snapshot consistency
    ?LOG_DEBUG("rqm: syncing filesystem"),
    case os:type() of
        {unix, _} ->
            os:cmd("sync"),
            ok;
        _ ->
            % On non-Unix systems, we can't easily force a sync
            ?LOG_DEBUG("rqm: filesystem sync not available on this platform"),
            ok
    end,

    EbsPreparationState = #{
        vhost => VHost,
        preparation_timestamp => erlang:system_time(millisecond)
    },

    ?LOG_DEBUG("rqm: node ~tp successfully quiesced and flushed for vhost ~ts", [node(), VHost]),
    {ok, EbsPreparationState}.

%% @doc Set default queue type to quorum for the migrated vhost
%% This is always done after successful migration to ensure new queues are quorum by default
-spec set_default_queue_type_to_quorum(rabbit_types:vhost()) -> ok.
set_default_queue_type_to_quorum(VHost) ->
    ?LOG_DEBUG("rqm: setting default queue type to quorum for vhost ~ts", [VHost]),
    case
        rabbit_vhost:update_metadata(
            VHost, #{default_queue_type => <<"quorum">>}, <<"internal_user">>
        )
    of
        ok ->
            ?LOG_DEBUG("rqm: successfully set default queue type to quorum for vhost ~ts", [VHost]);
        {error, Reason} ->
            ?LOG_ERROR("rqm: failed to set default queue type for vhost ~ts: ~p", [VHost, Reason])
    end,
    ok.

submit_to_worker_pool(Fun) ->
    ok = worker_pool:submit_async(rqm_config:worker_pool_name(), Fun).

%% @doc Extract and store snapshot information from preparation state
-spec store_snapshot_information(term(), map()) -> ok.
store_snapshot_information(MigrationId, PreparationState) ->
    Snapshots = extract_snapshots_from_preparation_state(PreparationState),
    case Snapshots of
        [] ->
            ?LOG_DEBUG("rqm: no snapshots to store for migration ~s", [
                format_migration_id(MigrationId)
            ]);
        _ ->
            ?LOG_DEBUG("rqm: storing ~p snapshots for migration ~s", [
                length(Snapshots), format_migration_id(MigrationId)
            ]),
            {ok, _} = rqm_db:update_migration_snapshots(MigrationId, Snapshots)
    end,
    ok.

%% @doc Create skipped queue status records for unsuitable queues
-spec create_skipped_queue_records(term(), list()) -> ok.
create_skipped_queue_records(_MigrationId, []) ->
    ok;
create_skipped_queue_records(MigrationId, [
    #unsuitable_queue{resource = Resource, reason = Reason} | Rest
]) ->
    {ok, _} = rqm_db:create_skipped_queue_status(Resource, MigrationId, Reason),
    create_skipped_queue_records(MigrationId, Rest).

%% @doc Extract snapshot information from preparation state
-spec extract_snapshots_from_preparation_state(map()) -> [{atom(), binary(), string()}].
extract_snapshots_from_preparation_state(PreparationState) ->
    maps:fold(fun extract_node_snapshots/3, [], PreparationState).

%% @doc Extract snapshots from a single node's preparation state
extract_node_snapshots(Node, NodeState, Acc) ->
    case maps:get(ebs_snapshot_state, NodeState, undefined) of
        undefined ->
            Acc;
        SnapshotState when is_binary(SnapshotState) ->
            % For tar mode, store as single entry with path as "volume"
            [{Node, SnapshotState, rqm_util:to_unicode(SnapshotState)} | Acc];
        {SnapshotId, VolumeId} when is_binary(SnapshotId) andalso is_binary(VolumeId) ->
            % For EBS mode, single snapshot-volume pair
            [{Node, SnapshotId, VolumeId} | Acc];
        Other ->
            ?LOG_WARNING("rqm: unexpected snapshot state format: ~p", [Other]),
            Acc
    end.

collect_rqm_gatherer_results(Gatherer, GathererDescription, Count) ->
    collect_rqm_gatherer_results(Gatherer, GathererDescription, Count, #{}).

collect_rqm_gatherer_results(Gatherer, GathererDescription, 0, Acc) ->
    ok = rqm_gatherer:stop(Gatherer),
    ?LOG_DEBUG("rqm: all workers completed successfully for ~tp", [GathererDescription]),
    {ok, Acc};
collect_rqm_gatherer_results(Gatherer, GathererDescription, Count, Acc) ->
    case rqm_gatherer:out(Gatherer) of
        empty ->
            ?LOG_DEBUG("rqm: all workers completed successfully for ~tp", [GathererDescription]),
            {ok, Acc};
        %% NB: Result is a map with a node name as the key,
        %% whose value is the actual result
        {value, {ok, Result}} when is_map(Result) ->
            Acc1 = maps:merge(Acc, Result),
            collect_rqm_gatherer_results(Gatherer, GathererDescription, Count - 1, Acc1);
        {value, {error, Error}} ->
            throw({error, {GathererDescription, Error}})
    end.

wait_for_monitored_processes(PidsAndRefs) ->
    wait_for_monitored_processes(PidsAndRefs, ?THIRTY_SECONDS_MS).

wait_for_monitored_processes(PidsAndRefs, TimeoutMs) when
    is_integer(TimeoutMs) andalso TimeoutMs > 0
->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    % Map Ref -> Pid for quick membership & sanity-check
    % elp:ignore W0036
    RefsMap = maps:from_list([{Ref, Pid} || {Pid, Ref} <- PidsAndRefs]),
    wait_for_monitored_processes_loop(RefsMap, Deadline).

wait_for_monitored_processes_loop(RefsMap, _Deadline) when map_size(RefsMap) =:= 0 ->
    ok;
wait_for_monitored_processes_loop(RefsMap0, Deadline) ->
    Now = erlang:monotonic_time(millisecond),
    Rem = Deadline - Now,
    if
        Rem =< 0 ->
            error(wait_for_processes_timeout);
        true ->
            receive
                {'DOWN', Ref, process, Pid, normal} when is_map_key(Ref, RefsMap0) ->
                    {Pid, RefsMap1} = maps:take(Ref, RefsMap0),
                    wait_for_monitored_processes_loop(RefsMap1, Deadline);
                {'DOWN', Ref, process, Pid, Unexpected} when is_map_key(Ref, RefsMap0) ->
                    {Pid, RefsMap1} = maps:take(Ref, RefsMap0),
                    ?LOG_ERROR("rqm: unexpected monitor result: ~tp", [Unexpected]),
                    wait_for_monitored_processes_loop(RefsMap1, Deadline)
            after Rem ->
                error(wait_for_processes_timeout)
            end
    end.

opts_add_unsuitable_queues([], #migration_opts{unsuitable_queues = Existing} = Opts) ->
    Opts#migration_opts{unsuitable_queues = lists:reverse(Existing)};
opts_add_unsuitable_queues([Q | Rest], #migration_opts{unsuitable_queues = Existing} = Opts0) ->
    Opts1 = Opts0#migration_opts{unsuitable_queues = [Q | Existing]},
    opts_add_unsuitable_queues(Rest, Opts1).
