%% Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
%% SPDX-License-Identifier: Apache-2.0
%% vim:ft=erlang:
%% -*- mode: erlang; -*-

-module(rqm_mgmt).

-behaviour(rabbit_mgmt_extension).

-export([dispatcher/0, web_ui/0, to_json/2]).
-export([
    init/2,
    content_types_accepted/2,
    content_types_provided/2,
    allowed_methods/2,
    resource_exists/2,
    is_authorized/2,
    accept_content/2
]).

-import(rabbit_misc, [pget/2]).

-include("rqm.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbitmq_management_agent/include/rabbit_mgmt_records.hrl").

dispatcher() ->
    [
        {"/queue-migration/start", ?MODULE, []},
        {"/queue-migration/start/:vhost", ?MODULE, []},
        {"/queue-migration/status", ?MODULE, []},
        {"/queue-migration/status/:migration_id", ?MODULE, []}
    ].

web_ui() -> [{javascript, <<"queue-migration.js">>}].

%%--------------------------------------------------------------------

init(Req, _State) ->
    {cowboy_rest, rabbit_mgmt_headers:set_common_permission_headers(Req, ?MODULE), #context{}}.

content_types_accepted(ReqData, Context) ->
    {[{'*', accept_content}], ReqData, Context}.

content_types_provided(ReqData, Context) ->
    {[{<<"application/json">>, to_json}], ReqData, Context}.

allowed_methods(ReqData, Context) ->
    {[<<"GET">>, <<"HEAD">>, <<"PUT">>, <<"OPTIONS">>], ReqData, Context}.

resource_exists(ReqData, Context) ->
    {true, ReqData, Context}.

to_json(ReqData, Context) ->
    case cowboy_req:binding(migration_id, ReqData) of
        undefined ->
            % Return overall migration status
            {ok, Status} = rqm:status(),

            % Get migration status data
            Migrations = rqm:get_migration_status(),
            MigrationData = [migration_to_json(M) || M <- Migrations],

            Json = rabbit_json:encode(#{
                status => Status,
                migrations => MigrationData
            }),
            {Json, ReqData, Context};
        MigrationIdUrlEncoded ->
            MigrationIdUrlDecoded = uri_string:percent_decode(MigrationIdUrlEncoded),
            MigrationIdBin = rqm_util:base64url_decode(MigrationIdUrlDecoded),
            MigrationId = binary_to_term(MigrationIdBin),
            % Return details for a specific migration
            case rqm:get_queue_migration_status(MigrationId) of
                {ok, {Migration, QueueDetails}} ->
                    Json = rabbit_json:encode(#{
                        migration => migration_to_json_detail(Migration),
                        queues => [queue_status_to_json(Q) || Q <- QueueDetails]
                    }),
                    {Json, ReqData, Context};
                {error, _} ->
                    Json = rabbit_json:encode(#{
                        error => <<"Migration not found">>
                    }),
                    {Json, ReqData, Context}
            end
    end.

is_authorized(ReqData, Context) ->
    rabbit_mgmt_util:is_authorized_monitor(ReqData, Context).

bad_request(ErrorJson, ReqData, Context) ->
    ReqData2 = cowboy_req:set_resp_body(ErrorJson, ReqData),
    ReqData3 = cowboy_req:reply(400, #{<<"content-type">> => <<"application/json">>}, ReqData2),
    {stop, ReqData3, Context}.

accept_content(ReqData, Context) ->
    VHost =
        case cowboy_req:binding(vhost, ReqData) of
            undefined -> <<"/">>;
            _VHostName -> rabbit_mgmt_util:id(vhost, ReqData)
        end,
    % First, run validation synchronously to catch errors before spawning
    case rqm:validate_migration(VHost) of
        ok ->
            % Validation passed, spawn the actual migration asynchronously
            spawn(rqm, start, [VHost]),
            {true, ReqData, Context};
        {error, {too_many_queues, Details}} ->
            QueueCount = maps:get(queue_count, Details),
            MaxQueues = maps:get(max_queues, Details),
            Message = rqm_util:unicode_format(
                "Too many queues (~p) for migration. Maximum allowed: ~p", [QueueCount, MaxQueues]
            ),
            ErrorJson = rabbit_json:encode(#{
                error => bad_request,
                reason => Message,
                queue_count => QueueCount,
                max_queues => MaxQueues
            }),
            bad_request(ErrorJson, ReqData, Context);
        {error, {unsuitable_queues, Details}} ->
            QueueCount = maps:get(queue_count, Details),
            Message = rqm_util:unicode_format(
                "Some queues have too many messages or bytes for the current queue count (~p)", [
                    QueueCount
                ]
            ),
            ErrorJson = rabbit_json:encode(#{
                error => bad_request,
                reason => Message,
                queue_count => QueueCount
            }),
            bad_request(ErrorJson, ReqData, Context);
        {error, queue_leaders_imbalanced} ->
            Message =
                <<"Queue leaders are imbalanced. Re-balance queue leaders before migration.">>,
            ErrorJson = rabbit_json:encode(#{
                error => bad_request,
                reason => Message
            }),
            bad_request(ErrorJson, ReqData, Context);
        {error, queues_too_deep} ->
            Message = <<"Some queues have too many messages for migration.">>,
            ErrorJson = rabbit_json:encode(#{
                error => bad_request,
                reason => Message
            }),
            bad_request(ErrorJson, ReqData, Context);
        {error, {insufficient_disk_space, Details}} ->
            RequiredMB = maps:get(required_free_mb, Details, 0),
            AvailableMB = maps:get(available_for_migration_mb, Details, 0),
            Message = rqm_util:unicode_format(
                "Insufficient disk space for migration. Required: ~pMB, Available: ~pMB", [
                    RequiredMB, AvailableMB
                ]
            ),
            ErrorJson = rabbit_json:encode(#{
                error => bad_request,
                reason => Message,
                required_free_mb => RequiredMB,
                available_for_migration_mb => AvailableMB
            }),
            bad_request(ErrorJson, ReqData, Context);
        {error, {incompatible_overflow_behavior, Details}} ->
            QueueName = maps:get(queue_name, Details),
            OverflowBehavior = maps:get(overflow_behavior, Details),
            QueueNameStr = rabbit_misc:rs(QueueName),
            Message = rqm_util:unicode_format(
                "Cannot migrate: Queue '~s' uses overflow behavior '~s' which is incompatible with quorum queues. "
                "Please change the queue's overflow behavior to 'drop-head' or 'reject-publish' before migration.",
                [QueueNameStr, OverflowBehavior]
            ),
            ErrorJson = rabbit_json:encode(#{
                error => bad_request,
                reason => Message,
                queue_name => QueueNameStr,
                incompatible_setting => <<"x-overflow">>,
                current_value => OverflowBehavior,
                suggested_values => [<<"drop-head">>, <<"reject-publish">>]
            }),
            bad_request(ErrorJson, ReqData, Context);
        {error, Other} ->
            Message = rqm_util:unicode_format("Migration validation failed: ~p", [Other]),
            ErrorJson = rabbit_json:encode(#{
                error => bad_request,
                reason => Message
            }),
            bad_request(ErrorJson, ReqData, Context)
    end.

migration_to_json({Id, VHost, StartedAt, CompletedAt, TotalQueues, CompletedQueues, Status}) ->
    #{
        id => rqm_util:format_migration_id(Id),
        display_id => format_display_id(Id, VHost, StartedAt),
        vhost => VHost,
        started_at => format_timestamp(StartedAt),
        completed_at => format_timestamp(CompletedAt),
        total_queues => TotalQueues,
        completed_queues => CompletedQueues,
        progress_percentage => calculate_progress_percentage(CompletedQueues, TotalQueues),
        status => Status
    }.

migration_to_json_detail(#queue_migration{
    id = Id,
    vhost = VHost,
    started_at = StartedAt,
    completed_at = CompletedAt,
    total_queues = TotalQueues,
    completed_queues = CompletedQueues,
    status = Status,
    snapshots = Snapshots
}) ->
    #{
        id => rqm_util:format_migration_id(Id),
        display_id => format_display_id(Id, VHost, StartedAt),
        vhost => VHost,
        started_at => format_timestamp(StartedAt),
        completed_at => format_timestamp(CompletedAt),
        total_queues => TotalQueues,
        completed_queues => CompletedQueues,
        progress_percentage => calculate_progress_percentage(CompletedQueues, TotalQueues),
        status => Status,
        snapshots => format_snapshots(Snapshots)
    }.

queue_status_to_json({Resource, StartedAt, CompletedAt, TotalMsgs, MigratedMsgs, Status, Error}) ->
    #{
        resource => format_resource(Resource),
        started_at => format_timestamp(StartedAt),
        completed_at => format_timestamp(CompletedAt),
        total_messages => TotalMsgs,
        migrated_messages => MigratedMsgs,
        progress_percentage => calculate_progress_percentage(MigratedMsgs, TotalMsgs),
        status => Status,
        error => Error
    }.

format_display_id({Timestamp, Node}, VHost, _StartedAt) ->
    {{Year, Month, Day}, {Hour, Minute, Second}} =
        calendar:system_time_to_universal_time(Timestamp, millisecond),
    NodeStr = atom_to_list(Node),
    list_to_binary(
        io_lib:format(
            "~s (~4..0w-~2..0w-~2..0w ~2..0w:~2..0w:~2..0w) on ~s",
            [VHost, Year, Month, Day, Hour, Minute, Second, NodeStr]
        )
    ).

format_resource(#resource{virtual_host = VHost, name = Name}) ->
    #{
        vhost => VHost,
        name => Name
    }.

format_timestamp(undefined) ->
    null;
format_timestamp(Timestamp) ->
    {{Year, Month, Day}, {Hour, Minute, Second}} = calendar:now_to_datetime(Timestamp),
    list_to_binary(
        io_lib:format(
            "~4..0w-~2..0w-~2..0w ~2..0w:~2..0w:~2..0w",
            [Year, Month, Day, Hour, Minute, Second]
        )
    ).

calculate_progress_percentage(_, 0) ->
    0;
calculate_progress_percentage(Completed, Total) ->
    trunc((Completed / Total) * 100).

format_snapshots(undefined) ->
    [];
format_snapshots([]) ->
    [];
format_snapshots(Snapshots) ->
    [format_snapshot(Snapshot) || Snapshot <- Snapshots].

format_snapshot({Node, SnapshotId, VolumeId}) ->
    #{
        node => Node,
        snapshot_id => SnapshotId,
        volume_id => VolumeId
    }.
