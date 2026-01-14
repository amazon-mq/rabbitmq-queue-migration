%% Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
%% SPDX-License-Identifier: Apache-2.0
%% vim:ft=erlang:
%% -*- mode: erlang; -*-

-module(rqm_config).

-include("rqm.hrl").

-include_lib("kernel/include/logger.hrl").

-export([
    % Configuration setup
    setup_defaults/0,

    % Queue leader balance configuration
    max_imbalance_ratio/0,
    min_queues_for_balance_check/0,

    % Disk space configuration
    min_disk_space_buffer/0,

    % Memory usage configuration
    max_memory_usage_percent/0,

    % Queue count configuration
    max_queues_for_migration/0,
    max_migration_duration_ms/0,

    % Worker pool configuration
    worker_pool_name/0,
    worker_pool_max/0,
    calculate_worker_pool_size/0,

    % Timeout configuration
    queue_migration_timeout_retries/0,
    queue_migration_timeout_ms/0,

    % Progress update configuration
    progress_update_frequency/0,

    % Message count verification configuration
    message_count_over_tolerance_percent/0,
    message_count_under_tolerance_percent/0,

    % Shovel configuration
    shovel_prefetch_count/0,

    % Snapshot configuration
    snapshot_mode/0,
    cleanup_snapshots_on_success/0,

    % RabbitMQ EBS data volume device
    ebs_volume_device/0
]).

%%----------------------------------------------------------------------------
%% Queue leader balance configuration
%%----------------------------------------------------------------------------

%% @doc Get the maximum allowed imbalance ratio for queue leaders
-spec max_imbalance_ratio() -> float().
max_imbalance_ratio() ->
    ?MAX_IMBALANCE_RATIO.

%% @doc Get the minimum number of queues required for balance check
-spec min_queues_for_balance_check() -> non_neg_integer().
min_queues_for_balance_check() ->
    ?MIN_QUEUES_FOR_BALANCE_CHECK.

%%----------------------------------------------------------------------------
%% Queue message count configuration
%%----------------------------------------------------------------------------

%%----------------------------------------------------------------------------
%% Disk space configuration
%%----------------------------------------------------------------------------

%% @doc Get the minimum free disk space buffer in bytes
-spec min_disk_space_buffer() -> non_neg_integer().
min_disk_space_buffer() ->
    case application:get_env(rabbitmq_queue_migration, min_disk_space_buffer) of
        {ok, Value} when is_integer(Value), Value > 0 ->
            Value;
        _ ->
            ?MIN_DISK_SPACE_BUFFER
    end.

%%----------------------------------------------------------------------------
%% Memory usage configuration
%%----------------------------------------------------------------------------

%% @doc Get the maximum memory usage percentage allowed for migration
-spec max_memory_usage_percent() -> non_neg_integer().
max_memory_usage_percent() ->
    case application:get_env(rabbitmq_queue_migration, max_memory_usage_percent) of
        {ok, Value} when is_integer(Value), Value > 0, Value =< 100 ->
            Value;
        _ ->
            ?MAX_MEMORY_USAGE_PERCENT
    end.

%%----------------------------------------------------------------------------
%% Worker pool configuration
%%----------------------------------------------------------------------------

%% @doc Get the worker pool name
-spec worker_pool_name() -> atom().
worker_pool_name() ->
    ?QUEUE_MIGRATION_WORKER_POOL.

%% @doc Get the maximum worker pool size
-spec worker_pool_max() -> pos_integer().
worker_pool_max() ->
    case application:get_env(rabbitmq_queue_migration, worker_pool_max) of
        {ok, Value} when is_integer(Value), Value >= 1, Value =< ?DEFAULT_WORKER_POOL_MAX ->
            Value;
        _ ->
            ?DEFAULT_WORKER_POOL_MAX
    end.

%% @doc Calculate the worker pool size based on available schedulers
-spec calculate_worker_pool_size() -> pos_integer().
calculate_worker_pool_size() ->
    S = erlang:system_info(schedulers),
    min(S, worker_pool_max()).

%%----------------------------------------------------------------------------
%% Timeout configuration
%%----------------------------------------------------------------------------

%% @doc Get the number of retries for migration timeout
-spec queue_migration_timeout_retries() -> pos_integer().
queue_migration_timeout_retries() ->
    ?QUEUE_MIGRATION_TIMEOUT_RETRIES.

%% @doc Get the timeout in milliseconds for each retry
-spec queue_migration_timeout_ms() -> pos_integer().
queue_migration_timeout_ms() ->
    ?QUEUE_MIGRATION_TIMEOUT_MS.

%%----------------------------------------------------------------------------
%% Progress update configuration
%%----------------------------------------------------------------------------

%% @doc Get the progress update frequency
-spec progress_update_frequency() -> pos_integer().
progress_update_frequency() ->
    case application:get_env(rabbitmq_queue_migration, progress_update_frequency) of
        {ok, Value} when is_integer(Value), Value >= 1, Value =< 4096 ->
            Value;
        _ ->
            ?DEFAULT_PROGRESS_UPDATE_FREQUENCY
    end.

%%----------------------------------------------------------------------------
%% Message count verification configuration
%%----------------------------------------------------------------------------

%% @doc Get the message count over-delivery tolerance percentage
-spec message_count_over_tolerance_percent() -> float().
message_count_over_tolerance_percent() ->
    case application:get_env(rabbitmq_queue_migration, message_count_over_tolerance_percent) of
        {ok, Value} when is_number(Value), Value >= 0.0, Value =< 100.0 ->
            float(Value);
        _ ->
            ?DEFAULT_MESSAGE_COUNT_OVER_TOLERANCE_PERCENT
    end.

%% @doc Get the message count under-delivery tolerance percentage
-spec message_count_under_tolerance_percent() -> float().
message_count_under_tolerance_percent() ->
    case application:get_env(rabbitmq_queue_migration, message_count_under_tolerance_percent) of
        {ok, Value} when is_number(Value), Value >= 0.0, Value =< 100.0 ->
            float(Value);
        _ ->
            ?DEFAULT_MESSAGE_COUNT_UNDER_TOLERANCE_PERCENT
    end.

%%----------------------------------------------------------------------------
%% Shovel configuration
%%----------------------------------------------------------------------------

%% @doc Get the shovel prefetch count
-spec shovel_prefetch_count() -> pos_integer().
shovel_prefetch_count() ->
    case application:get_env(rabbitmq_queue_migration, shovel_prefetch_count) of
        {ok, Value} when is_integer(Value), Value > 0 ->
            Value;
        _ ->
            ?DEFAULT_SHOVEL_PREFETCH_COUNT
    end.

%%----------------------------------------------------------------------------
%% Queue count and size configuration
%%----------------------------------------------------------------------------

%% @doc Get the maximum number of queues allowed for migration
-spec max_queues_for_migration() -> non_neg_integer().
max_queues_for_migration() ->
    case application:get_env(rabbitmq_queue_migration, max_queues_for_migration) of
        {ok, Value} when is_integer(Value), Value > 0 ->
            Value;
        _ ->
            ?MAX_QUEUES_FOR_MIGRATION
    end.

%% @doc Get the maximum migration duration in minutes
-spec max_migration_duration_ms() -> non_neg_integer().
max_migration_duration_ms() ->
    case application:get_env(rabbitmq_queue_migration, max_migration_duration_ms) of
        {ok, Value} when is_integer(Value), Value > 0 ->
            Value;
        _ ->
            ?MAX_MIGRATION_DURATION_MS
    end.

%%----------------------------------------------------------------------------
%% Configuration Setup
%%----------------------------------------------------------------------------

%% @doc Setup default configuration values for all migration parameters
%% This function validates and sets default values for all configurable parameters
-spec setup_defaults() -> ok.
setup_defaults() ->
    ok = setup_progress_update_frequency(),
    ok = setup_worker_pool_max(),
    ok.

%% @doc Setup and validate progress_update_frequency configuration
-spec setup_progress_update_frequency() -> ok.
setup_progress_update_frequency() ->
    case application:get_env(rabbitmq_queue_migration, progress_update_frequency) of
        undefined ->
            ok = application:set_env(
                rabbitmq_queue_migration,
                progress_update_frequency,
                ?DEFAULT_PROGRESS_UPDATE_FREQUENCY
            );
        {ok, Value} when is_integer(Value), Value >= 1, Value =< 4096 ->
            ok;
        {ok, _} ->
            ?LOG_WARNING(
                "rqm: invalid progress_update_frequency value, using default ~p",
                [?DEFAULT_PROGRESS_UPDATE_FREQUENCY]
            ),
            ok = application:set_env(
                rabbitmq_queue_migration,
                progress_update_frequency,
                ?DEFAULT_PROGRESS_UPDATE_FREQUENCY
            )
    end.

%% @doc Setup and validate worker_pool_max configuration
-spec setup_worker_pool_max() -> ok.
setup_worker_pool_max() ->
    case application:get_env(rabbitmq_queue_migration, worker_pool_max) of
        undefined ->
            ok = application:set_env(
                rabbitmq_queue_migration,
                worker_pool_max,
                ?DEFAULT_WORKER_POOL_MAX
            );
        {ok, Value} when is_integer(Value), Value >= 1, Value =< ?DEFAULT_WORKER_POOL_MAX ->
            ok;
        {ok, _} ->
            ?LOG_WARNING(
                "rqm: invalid worker_pool_max value, using default ~p",
                [?DEFAULT_WORKER_POOL_MAX]
            ),
            ok = application:set_env(
                rabbitmq_queue_migration,
                worker_pool_max,
                ?DEFAULT_WORKER_POOL_MAX
            )
    end.

%% @doc Get snapshot mode configuration (tar or ebs)
-spec snapshot_mode() -> tar | ebs.
snapshot_mode() ->
    case application:get_env(rabbitmq_queue_migration, snapshot_mode, tar) of
        tar -> tar;
        ebs -> ebs;
        % Default to tar for invalid values
        _ -> tar
    end.

%% @doc Get RabbitMQ EBS data volume device
-spec ebs_volume_device() -> string().
ebs_volume_device() ->
    case
        application:get_env(
            rabbitmq_queue_migration,
            ebs_volume_device,
            ?DEFAULT_EBS_VOLUME_DEVICE
        )
    of
        Value when is_list(Value) ->
            Value;
        _ ->
            % Default to /dev/sdh
            ?DEFAULT_EBS_VOLUME_DEVICE
    end.

%% @doc Get snapshot cleanup configuration
-spec cleanup_snapshots_on_success() -> boolean().
cleanup_snapshots_on_success() ->
    case
        application:get_env(
            rabbitmq_queue_migration,
            cleanup_snapshots_on_success,
            ?DEFAULT_CLEANUP_SNAPSHOTS_ON_SUCCESS
        )
    of
        true ->
            true;
        false ->
            false;
        _ ->
            % Default to true for invalid values
            ?DEFAULT_CLEANUP_SNAPSHOTS_ON_SUCCESS
    end.
