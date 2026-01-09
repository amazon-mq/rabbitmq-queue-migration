%% Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
%% SPDX-License-Identifier: Apache-2.0
%% vim:ft=erlang:
%% -*- mode: erlang; -*-

%% Worker pool configuration
-define(QUEUE_MIGRATION_WORKER_POOL, rqm_worker_pool).
-define(DEFAULT_WORKER_POOL_MAX, 32).

%% Message count verification configuration
-define(DEFAULT_MESSAGE_COUNT_OVER_TOLERANCE_PERCENT, 5.0).
-define(DEFAULT_MESSAGE_COUNT_UNDER_TOLERANCE_PERCENT, 2.0).

%% Shovel configuration
-define(DEFAULT_SHOVEL_PREFETCH_COUNT, 1024).

%% Timeout configuration

% 15 retries of 2 minutes each, 30 minutes total to migrate queue
-define(QUEUE_MIGRATION_TIMEOUT_RETRIES, 15).
% 2 minutes
-define(QUEUE_MIGRATION_TIMEOUT_MS, 120000).

%% Progress update configuration
-define(DEFAULT_PROGRESS_UPDATE_FREQUENCY, 10).

%% Rollback configuration
-define(DEFAULT_ROLLBACK_ON_ERROR, true).

%% Snapshot cleanup configuration
-define(DEFAULT_CLEANUP_SNAPSHOTS_ON_SUCCESS, true).

%% Queue leader balance configuration
-define(MAX_IMBALANCE_RATIO, 1.6).
-define(MIN_QUEUES_FOR_BALANCE_CHECK, 10).

%% Queue message count configuration
-define(MAX_MESSAGES_IN_QUEUE, 15000).

%% Disk space configuration
-define(DISK_SPACE_SAFETY_MULTIPLIER, 2.5).
% 500MB
-define(MIN_DISK_SPACE_BUFFER, 500000000).

%% Memory usage configuration
-define(MAX_MEMORY_USAGE_PERCENT, 40).

%% Queue count and size configuration
-define(MAX_QUEUES_FOR_MIGRATION, 500).
-define(BASE_MAX_MESSAGES_IN_QUEUE, 20000).
% 512MiB
-define(BASE_MAX_MESSAGE_BYTES_IN_QUEUE, 536870912).

% 45 minutes
-define(MAX_MIGRATION_DURATION_MS, 2700000).

-define(THIRTY_SECONDS_MS, 30000).

-define(DEFAULT_EBS_VOLUME_DEVICE, "/dev/sdh").

%% Records for tracking migration progress

%% Record to track unsuitable queues during validation
-record(unsuitable_queue, {
    resource,
    reason :: atom(),
    details :: term()
}).

%% Record to track the overall migration status
-record(queue_migration, {
    % Unique migration ID (timestamp + node)
    id,
    % Virtual host being migrated
    vhost,
    % Timestamp when migration started
    started_at,
    % Timestamp when migration completed (null if in progress)
    completed_at,
    % Total number of queues to migrate
    total_queues,
    % Number of queues completed
    completed_queues,
    % Number of queues skipped
    skipped_queues = 0,
    % Status: 'in_progress', 'completed', 'failed', 'rollback_pending', 'rollback_completed'
    status :: migration_status(),
    % Timestamp when rollback started
    rollback_started_at,
    % Timestamp when rollback completed
    rollback_completed_at,
    % List of rollback errors per queue
    rollback_errors,
    % List of snapshot info: [{Node, SnapshotId, VolumeId}, ...]
    snapshots,
    % Whether to skip unsuitable queues instead of blocking migration
    skip_unsuitable_queues = false :: boolean()
}).

%% Record to track individual queue migration status
-record(queue_migration_status, {
    % Composite primary key: {QueueResource, MigrationId}
    key,
    % Queue resource record
    queue_resource,
    % Reference to parent migration
    migration_id,
    % Store original classic queue arguments for rollback
    original_queue_args,
    % Store original binding details for rollback
    original_bindings,
    % When this queue's migration started
    started_at,
    % When this queue's migration completed (null if in progress)
    completed_at,
    % Total messages in queue at start
    total_messages,
    % Number of messages migrated so far
    migrated_messages,
    % Status: 'pending', 'in_progress', 'completed', 'failed', 'rollback_pending', 'rollback_completed'
    status :: migration_status(),
    % Error details if failed (null otherwise)
    error,
    % When rollback started for this queue
    rollback_started_at,
    % When rollback completed for this queue
    rollback_completed_at,
    % Specific rollback error if any
    rollback_error
}).

%% Type definitions
-type snapshot_id() :: binary().

-type migration_status() ::
    'pending'
    | 'in_progress'
    | 'completed'
    | 'failed'
    | 'skipped'
    | 'rollback_pending'
    | 'rollback_completed'.
