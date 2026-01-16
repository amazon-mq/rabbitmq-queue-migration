%% Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
%% SPDX-License-Identifier: Apache-2.0
%% vim:ft=erlang:
%% -*- mode: erlang; -*-

-module(rqm_db).

-include("rqm.hrl").

-include_lib("kernel/include/logger.hrl").
-include_lib("rabbit/include/amqqueue.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").

%% General queue operations
-export([get_message_count/1]).

%% Migration record operations
-export([
    create_migration/5,
    update_migration_status/2,
    update_migration_failed/2,
    update_migration_completed/2,
    update_migration_completed_count/1,
    update_migration_snapshots/2,
    get_migration/1,
    get_all_migrations/0,
    is_current_status/2,
    get_migration_status_value/1
]).

%% Queue status record operations
-export([
    create_queue_status/2,
    create_skipped_queue_status/3,
    update_queue_status_started/3,
    update_queue_status_progress/3,
    update_queue_status_completed/5,
    update_queue_status_failed/6,
    get_queue_status/2,
    get_queue_statuses_for_migration/1,
    store_original_queue_metadata/4
]).

%% Transaction operations
-export([update_migration_with_queues/3]).

%% API for retrieving migration status
-export([
    get_migration_status/0,
    get_queue_migration_status/1,
    get_rollback_pending_migration/0
]).

%% General queue operations

%% @doc Get message count for a queue
-spec get_message_count(#resource{} | amqqueue:amqqueue()) -> {ok, non_neg_integer()}.
get_message_count(Queue) when ?is_amqqueue(Queue) ->
    case rabbit_amqqueue:info(Queue, [messages]) of
        [{messages, Count}] ->
            {ok, Count};
        Unexpected ->
            ?LOG_DEBUG("rqm: ~tp Unexpected ~tp", [?FUNCTION_NAME, Unexpected]),
            {ok, 0}
    end;
get_message_count(Resource) when is_record(Resource, resource) ->
    case rabbit_amqqueue:lookup(Resource) of
        {ok, Q} ->
            case rabbit_amqqueue:info(Q, [messages]) of
                [{messages, Count}] ->
                    {ok, Count};
                Unexpected ->
                    ?LOG_DEBUG("rqm: ~tp Unexpected ~tp", [?FUNCTION_NAME, Unexpected]),
                    {ok, 0}
            end;
        {error, not_found} ->
            ?LOG_DEBUG("rqm: ~tp NOT FOUND", [?FUNCTION_NAME]),
            %% Queue doesn't exist, consider it empty
            {ok, 0}
    end.

%% Migration record operations

%% @doc Create a new migration record
-spec create_migration(term(), binary(), erlang:timestamp(), boolean(), non_neg_integer()) ->
    {ok, #queue_migration{}}.
create_migration(MigrationId, VHost, StartTime, SkipUnsuitableQueues, SkippedCount) ->
    MigrationRecord = #queue_migration{
        id = MigrationId,
        vhost = VHost,
        started_at = StartTime,
        completed_at = undefined,
        total_queues = 0,
        completed_queues = 0,
        skipped_queues = SkippedCount,
        status = in_progress,
        snapshots = [],
        skip_unsuitable_queues = SkipUnsuitableQueues
    },
    mnesia:dirty_write(MigrationRecord),
    {ok, MigrationRecord}.

%% @doc Update migration status
-spec update_migration_status(term(), migration_status()) ->
    {ok, #queue_migration{}} | {error, not_found}.
update_migration_status(MigrationId, rollback_completed) ->
    F = fun(M) ->
        M#queue_migration{status = rollback_completed, rollback_completed_at = os:timestamp()}
    end,
    update_migration(MigrationId, F);
update_migration_status(MigrationId, Status) ->
    F = fun(M) ->
        M#queue_migration{status = Status}
    end,
    update_migration(MigrationId, F).

%% @doc Update migration as failed with error reason
-spec update_migration_failed(term(), term()) -> {ok, #queue_migration{}} | {error, not_found}.
update_migration_failed(MigrationId, Error) ->
    F = fun(M) ->
        M#queue_migration{status = failed, error = Error, completed_at = os:timestamp()}
    end,
    update_migration(MigrationId, F).

%% @doc Update migration as completed
-spec update_migration_completed(term(), non_neg_integer()) ->
    {ok, #queue_migration{}} | {error, not_found}.
update_migration_completed(MigrationId, TotalQueues) ->
    F = fun(M) ->
        M#queue_migration{
            status = completed,
            completed_at = os:timestamp(),
            completed_queues = TotalQueues
        }
    end,
    update_migration(MigrationId, F).

%% @doc Update migration completed count based on completed queue statuses
-spec update_migration_completed_count(term()) -> {ok, non_neg_integer()} | {error, not_found}.
update_migration_completed_count(MigrationId) ->
    case mnesia:dirty_read(queue_migration, MigrationId) of
        [] ->
            {error, not_found};
        [Migration] ->
            % Count completed queues
            CompletedCount = length(
                mnesia:dirty_match_object(
                    queue_migration_status,
                    #queue_migration_status{migration_id = MigrationId, status = completed, _ = '_'}
                )
            ),

            % Update migration record
            mnesia:dirty_write(Migration#queue_migration{
                completed_queues = CompletedCount
            }),
            {ok, CompletedCount}
    end.

%% @doc Update migration snapshots
-spec update_migration_snapshots(term(), list()) -> {ok, #queue_migration{}} | {error, not_found}.
update_migration_snapshots(MigrationId, Snapshots) ->
    case mnesia:dirty_read(queue_migration, MigrationId) of
        [] ->
            {error, not_found};
        [Migration] ->
            UpdatedMigration = Migration#queue_migration{snapshots = Snapshots},
            mnesia:dirty_write(UpdatedMigration),
            {ok, UpdatedMigration}
    end.

%% @doc Get migration by ID
-spec get_migration(term()) -> {ok, #queue_migration{}} | {error, not_found}.
get_migration(MigrationId) ->
    case mnesia:dirty_read(queue_migration, MigrationId) of
        [] -> {error, not_found};
        [Migration] -> {ok, Migration}
    end.

%% @doc Get all migrations
-spec get_all_migrations() -> [#queue_migration{}].
get_all_migrations() ->
    Migrations = mnesia:dirty_match_object(queue_migration, #queue_migration{_ = '_'}),
    % Sort by started_at descending (most recent first)
    lists:sort(
        fun(#queue_migration{started_at = A}, #queue_migration{started_at = B}) ->
            A >= B
        end,
        Migrations
    ).

%% Queue status record operations

%% @doc Create a queue status record
-spec create_queue_status(#resource{}, term()) -> {ok, #queue_migration_status{}}.
create_queue_status(Resource, MigrationId) ->
    QueueStatus = #queue_migration_status{
        key = {Resource, MigrationId},
        queue_resource = Resource,
        migration_id = MigrationId,
        started_at = undefined,
        completed_at = undefined,
        total_messages = 0,
        migrated_messages = 0,
        status = pending,
        error = undefined
    },
    mnesia:dirty_write(QueueStatus),
    {ok, QueueStatus}.

%% @doc Create a skipped queue status record
-spec create_skipped_queue_status(#resource{}, term(), term()) -> {ok, #queue_migration_status{}}.
create_skipped_queue_status(Resource, MigrationId, SkipReason) ->
    QueueStatus = #queue_migration_status{
        key = {Resource, MigrationId},
        queue_resource = Resource,
        migration_id = MigrationId,
        started_at = os:timestamp(),
        completed_at = os:timestamp(),
        total_messages = 0,
        migrated_messages = 0,
        status = skipped,
        error = SkipReason
    },
    mnesia:dirty_write(QueueStatus),
    {ok, QueueStatus}.

%% @doc Update queue status to in_progress with message count
-spec update_queue_status_started(#resource{}, term(), non_neg_integer()) ->
    {ok, #queue_migration_status{}} | {error, not_found}.
update_queue_status_started(Resource, MigrationId, TotalMessageCount) ->
    Key = {Resource, MigrationId},
    case mnesia:dirty_read(queue_migration_status, Key) of
        [] ->
            % Create record if it doesn't exist
            QueueStatus = #queue_migration_status{
                key = Key,
                queue_resource = Resource,
                migration_id = MigrationId,
                started_at = os:timestamp(),
                completed_at = undefined,
                total_messages = TotalMessageCount,
                migrated_messages = 0,
                status = in_progress,
                error = undefined
            },
            mnesia:dirty_write(QueueStatus),
            {ok, QueueStatus};
        [Status] ->
            % Update status to in_progress with message count
            UpdatedStatus = Status#queue_migration_status{
                started_at = os:timestamp(),
                total_messages = TotalMessageCount,
                status = in_progress
            },
            mnesia:dirty_write(UpdatedStatus),
            {ok, UpdatedStatus}
    end.

%% @doc Update queue migration progress
-spec update_queue_status_progress(#resource{}, term(), non_neg_integer()) ->
    {ok, #queue_migration_status{}} | {error, not_found}.
update_queue_status_progress(Resource, MigrationId, CurrentMigratedMessageCount) ->
    Key = {Resource, MigrationId},
    case mnesia:dirty_read(queue_migration_status, Key) of
        [] ->
            {error, not_found};
        [Status] ->
            UpdatedStatus = Status#queue_migration_status{
                migrated_messages = CurrentMigratedMessageCount
            },
            ok = mnesia:dirty_write(UpdatedStatus),
            {ok, UpdatedStatus}
    end.

%% @doc Update queue status to completed
-spec update_queue_status_completed(
    #resource{}, term(), erlang:timestamp() | undefined, non_neg_integer(), non_neg_integer()
) ->
    {ok, #queue_migration_status{}} | {error, not_found}.
update_queue_status_completed(Resource, MigrationId, StartedAt, TotalMessages, MigratedMessages) ->
    QueueStatus = #queue_migration_status{
        key = {Resource, MigrationId},
        queue_resource = Resource,
        migration_id = MigrationId,
        started_at = StartedAt,
        completed_at = os:timestamp(),
        total_messages = TotalMessages,
        migrated_messages = MigratedMessages,
        status = completed,
        error = undefined
    },
    mnesia:dirty_write(QueueStatus),
    {ok, QueueStatus}.

%% @doc Update queue status to failed with specific error details
-spec update_queue_status_failed(
    #resource{},
    term(),
    erlang:timestamp() | undefined,
    non_neg_integer(),
    non_neg_integer(),
    term()
) ->
    {ok, #queue_migration_status{}} | {error, not_found}.
update_queue_status_failed(
    Resource, MigrationId, StartedAt, TotalMessages, MigratedMessages, ErrorDetails
) ->
    ErrorMsg =
        case ErrorDetails of
            {shovel_timeout, ExpectedCount, CurrentCounts} ->
                SrcCount = maps:get(src_count, CurrentCounts, 0),
                DestCount = maps:get(dest_count, CurrentCounts, 0),
                rqm_util:unicode_format(
                    "Shovel timeout: expected ~w messages, found ~w in source + ~w in destination",
                    [ExpectedCount, SrcCount, DestCount]
                );
            {Class, Reason, _Stack} ->
                rqm_util:unicode_format("~s: ~p", [Class, Reason]);
            {timeout, Details} ->
                rqm_util:unicode_format("Timeout: ~p", [Details]);
            {queue_not_found, Details} ->
                rqm_util:unicode_format("Queue not found: ~p", [Details]);
            shovel_timeout ->
                <<"Shovel operation timed out">>;
            Other ->
                rqm_util:unicode_format("Migration failed: ~p", [Other])
        end,
    QueueStatus = #queue_migration_status{
        key = {Resource, MigrationId},
        queue_resource = Resource,
        migration_id = MigrationId,
        started_at = StartedAt,
        completed_at = os:timestamp(),
        total_messages = TotalMessages,
        migrated_messages = MigratedMessages,
        status = failed,
        error = ErrorMsg
    },
    mnesia:dirty_write(QueueStatus),
    {ok, QueueStatus}.

%% @doc Get queue status by resource and migration ID
-spec get_queue_status(#resource{}, term()) -> {ok, #queue_migration_status{}} | {error, not_found}.
get_queue_status(Resource, MigrationId) ->
    Key = {Resource, MigrationId},
    case mnesia:dirty_read(queue_migration_status, Key) of
        [] -> {error, not_found};
        [Status] -> {ok, Status}
    end.

%% @doc Get all queue statuses for a migration
-spec get_queue_statuses_for_migration(term()) -> [#queue_migration_status{}].
get_queue_statuses_for_migration(MigrationId) ->
    mnesia:dirty_match_object(
        queue_migration_status,
        #queue_migration_status{migration_id = MigrationId, _ = '_'}
    ).

%% Transaction operations

%% @doc Update migration record and create queue status records in a transaction
-spec update_migration_with_queues(term(), [amqqueue:amqqueue()], binary()) ->
    {atomic, {ok, non_neg_integer()}} | {aborted, term()}.
update_migration_with_queues(MigrationId, Queues, _VHost) ->
    F = fun() ->
        [Migration] = mnesia:read(queue_migration, MigrationId),
        QueueCount = length(Queues),
        NewTotalQueues = Migration#queue_migration.total_queues + QueueCount,

        % Update migration record
        mnesia:write(Migration#queue_migration{
            total_queues = NewTotalQueues
        }),

        % Create queue status records
        [
            mnesia:write(#queue_migration_status{
                key = {amqqueue:get_name(Q), MigrationId},
                queue_resource = amqqueue:get_name(Q),
                migration_id = MigrationId,
                started_at = undefined,
                completed_at = undefined,
                total_messages = 0,
                migrated_messages = 0,
                status = pending,
                error = undefined
            })
         || Q <- Queues
        ],

        {ok, NewTotalQueues}
    end,
    mnesia:transaction(F).

%% API for retrieving migration status

%% @doc Get status of all migrations
-spec get_migration_status() ->
    [
        {
            term(),
            binary(),
            erlang:timestamp(),
            erlang:timestamp() | undefined,
            non_neg_integer(),
            non_neg_integer(),
            non_neg_integer(),
            atom(),
            boolean(),
            binary() | undefined
        }
    ].
get_migration_status() ->
    Migrations = get_all_migrations(),
    [
        {Id, VHost, StartedAt, CompletedAt, TotalQueues, CompletedQueues, SkippedQueues, Status,
            SkipUnsuitableQueues,
            Error}
     || #queue_migration{
            id = Id,
            vhost = VHost,
            started_at = StartedAt,
            completed_at = CompletedAt,
            total_queues = TotalQueues,
            completed_queues = CompletedQueues,
            skipped_queues = SkippedQueues,
            status = Status,
            skip_unsuitable_queues = SkipUnsuitableQueues,
            error = Error
        } <- Migrations
    ].

%% @doc Get detailed status of a specific migration
-spec get_queue_migration_status(term()) ->
    {ok,
        {#queue_migration{}, [
            {
                #resource{},
                erlang:timestamp() | undefined,
                erlang:timestamp() | undefined,
                non_neg_integer(),
                non_neg_integer(),
                atom(),
                term()
            }
        ]}}
    | {error, migration_not_found}.
get_queue_migration_status(MigrationId) ->
    case get_migration(MigrationId) of
        {error, not_found} ->
            {error, migration_not_found};
        {ok, Migration} ->
            QueueStatuses = get_queue_statuses_for_migration(MigrationId),

            QueueDetails = [
                {Resource, StartedAt, CompletedAt, TotalMsgs, MigratedMsgs, Status, Error}
             || #queue_migration_status{
                    queue_resource = Resource,
                    started_at = StartedAt,
                    completed_at = CompletedAt,
                    total_messages = TotalMsgs,
                    migrated_messages = MigratedMsgs,
                    status = Status,
                    error = Error
                } <- QueueStatuses
            ],

            {ok, {Migration, QueueDetails}}
    end.

%% Check if migration has a specific status
-spec is_current_status(term(), atom()) -> boolean().
is_current_status(MigrationId, ExpectedStatus) ->
    case get_migration(MigrationId) of
        {ok, Migration} ->
            Migration#queue_migration.status =:= ExpectedStatus;
        {error, _} ->
            % Migration record not found
            false
    end.

-spec get_migration_status_value(term()) -> migration_status() | undefined.
get_migration_status_value(MigrationId) ->
    case get_migration(MigrationId) of
        {ok, Migration} ->
            Migration#queue_migration.status;
        {error, _} ->
            undefined
    end.

%% @doc Get the most recent migration with rollback_pending status
-spec get_rollback_pending_migration() -> {ok, #queue_migration{}} | {error, not_found}.
get_rollback_pending_migration() ->
    Pattern = #queue_migration{status = rollback_pending, _ = '_'},
    case mnesia:dirty_match_object(queue_migration, Pattern) of
        [] ->
            {error, not_found};
        Migrations ->
            [MostRecent | _] = lists:sort(
                fun(A, B) -> A#queue_migration.started_at >= B#queue_migration.started_at end,
                Migrations
            ),
            {ok, MostRecent}
    end.

%% Store original queue metadata for rollback
-spec store_original_queue_metadata(#resource{}, term(), term(), term()) ->
    {ok, term()} | {error, term()}.
store_original_queue_metadata(Resource, MigrationId, OriginalArgs, OriginalBindings) ->
    Key = {Resource, MigrationId},
    Fun = fun() ->
        case mnesia:read(queue_migration_status, Key, write) of
            [Status] ->
                UpdatedStatus = Status#queue_migration_status{
                    original_queue_args = OriginalArgs,
                    original_bindings = OriginalBindings
                },
                mnesia:write(UpdatedStatus),
                {ok, UpdatedStatus};
            [] ->
                {error, not_found}
        end
    end,
    case mnesia:transaction(Fun) of
        {atomic, Result} -> Result;
        {aborted, Reason} -> {error, Reason}
    end.

update_migration(MigrationId, UpdateFun) ->
    case mnesia:dirty_read(queue_migration, MigrationId) of
        [] ->
            {error, not_found};
        [Migration0] ->
            Migration1 = UpdateFun(Migration0),
            ok = mnesia:dirty_write(Migration1),
            {ok, Migration1}
    end.
