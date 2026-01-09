%% Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
%% SPDX-License-Identifier: Apache-2.0
%% vim:ft=erlang:
%% -*- mode: erlang; -*-

-module(rqm_mgmt).

-behaviour(rabbit_mgmt_extension).

-export([dispatcher/0, web_ui/0, to_json/2, migration_to_json_detail/1]).
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
        {"/queue-migration/start", ?MODULE, [start]},
        {"/queue-migration/start/:vhost", ?MODULE, [start_vhost]},
        {"/queue-migration/status", ?MODULE, [status_list]},
        {"/queue-migration/status/:migration_id", ?MODULE, [status_detail]},
        {"/queue-migration/rollback-pending", ?MODULE, [rollback_pending]}
    ].

web_ui() -> [{javascript, <<"queue-migration.js">>}].

%%--------------------------------------------------------------------

init(Req, [EndpointType]) ->
    {cowboy_rest, rabbit_mgmt_headers:set_common_permission_headers(Req, ?MODULE),
        {EndpointType, #context{}}}.

content_types_accepted(ReqData, {EndpointType, Context}) ->
    {[{'*', accept_content}], ReqData, {EndpointType, Context}}.

content_types_provided(ReqData, {EndpointType, Context}) ->
    {[{<<"application/json">>, to_json}], ReqData, {EndpointType, Context}}.

allowed_methods(ReqData, {EndpointType, Context}) ->
    {[<<"GET">>, <<"HEAD">>, <<"PUT">>, <<"OPTIONS">>], ReqData, {EndpointType, Context}}.

resource_exists(ReqData, {EndpointType, Context}) ->
    {true, ReqData, {EndpointType, Context}}.

to_json(ReqData, {rollback_pending, Context}) ->
    case rqm_db:get_rollback_pending_migration() of
        {ok, Migration} ->
            Json = rabbit_json:encode(migration_to_json_detail(Migration)),
            {Json, ReqData, {rollback_pending, Context}};
        {error, not_found} ->
            ReqData2 = cowboy_req:reply(
                404,
                #{<<"content-type">> => <<"application/json">>},
                rabbit_json:encode(#{error => <<"No rollback pending migration found">>}),
                ReqData
            ),
            {stop, ReqData2, {rollback_pending, Context}}
    end;
to_json(ReqData, {status_list, Context}) ->
    {ok, Status} = rqm:status(),
    Migrations = rqm:get_migration_status(),
    MigrationData = [migration_to_json(M) || M <- Migrations],
    Json = rabbit_json:encode(#{
        status => Status,
        migrations => MigrationData
    }),
    {Json, ReqData, {status_list, Context}};
to_json(ReqData, {status_detail, Context}) ->
    MigrationIdUrlEncoded = cowboy_req:binding(migration_id, ReqData),
    MigrationIdUrlDecoded = uri_string:percent_decode(MigrationIdUrlEncoded),
    MigrationIdBin = rqm_util:base64url_decode(MigrationIdUrlDecoded),
    MigrationId = binary_to_term(MigrationIdBin),
    case rqm:get_queue_migration_status(MigrationId) of
        {ok, {Migration, QueueDetails}} ->
            Json = rabbit_json:encode(#{
                migration => migration_to_json_detail(Migration),
                queues => [queue_status_to_json(Q) || Q <- QueueDetails]
            }),
            {Json, ReqData, {status_detail, Context}};
        {error, _} ->
            Json = rabbit_json:encode(#{
                error => <<"Migration not found">>
            }),
            {Json, ReqData, {status_detail, Context}}
    end.

is_authorized(ReqData, {EndpointType, Context}) ->
    {Res, RD, C} = rabbit_mgmt_util:is_authorized_monitor(ReqData, Context),
    {Res, RD, {EndpointType, C}}.

bad_request(ErrorJson, ReqData, {EndpointType, Context}) ->
    ReqData2 = cowboy_req:set_resp_body(ErrorJson, ReqData),
    ReqData3 = cowboy_req:reply(400, #{<<"content-type">> => <<"application/json">>}, ReqData2),
    {stop, ReqData3, {EndpointType, Context}}.

accept_content(ReqData, {start, Context}) ->
    accept_migration_start(ReqData, {start, Context});
accept_content(ReqData, {start_vhost, Context}) ->
    accept_migration_start(ReqData, {start_vhost, Context});
accept_content(ReqData, {status_detail, Context}) ->
    MigrationIdUrlEncoded = cowboy_req:binding(migration_id, ReqData),
    accept_status_update(MigrationIdUrlEncoded, ReqData, {status_detail, Context}).

accept_migration_start(ReqData, {EndpointType, Context}) ->
    VHost =
        case cowboy_req:binding(vhost, ReqData) of
            undefined -> <<"/">>;
            _VHostName -> rabbit_mgmt_util:id(vhost, ReqData)
        end,
    % Parse request body for options
    OptsMap = parse_migration_options(ReqData),
    % First, run validation synchronously to catch errors before spawning
    case rqm:validate_migration(VHost, OptsMap) of
        ok ->
            % Validation passed, spawn the actual migration asynchronously
            spawn(rqm, start, [VHost, OptsMap]),
            {true, ReqData, {EndpointType, Context}};
        {error, shovel_plugin_not_enabled} ->
            Message =
                <<
                    "rabbitmq_shovel plugin must be enabled for migration. "
                    "Enable the plugin with: rabbitmq-plugins enable rabbitmq_shovel"
                >>,
            ErrorJson = rabbit_json:encode(#{
                error => bad_request,
                reason => Message
            }),
            bad_request(ErrorJson, ReqData, {EndpointType, Context});
        {error, khepri_enabled} ->
            Message =
                <<
                    "khepri_db must be disabled for migration. "
                    "Khepri is not compatible with classic queue migration."
                >>,
            ErrorJson = rabbit_json:encode(#{
                error => bad_request,
                reason => Message
            }),
            bad_request(ErrorJson, ReqData, {EndpointType, Context});
        {error, {unsuitable_queues, Details}} ->
            ProblematicQueues = maps:get(problematic_queues, Details, []),
            Message = rqm_util:unicode_format(
                "Found ~p queue(s) with issues (too many messages, too many bytes, or incompatible arguments)",
                [length(ProblematicQueues)]
            ),
            ErrorJson = rabbit_json:encode(#{
                error => bad_request,
                reason => Message,
                problematic_queue_count => length(ProblematicQueues)
            }),
            bad_request(ErrorJson, ReqData, {EndpointType, Context});
        {error, queue_leaders_imbalanced} ->
            Message =
                <<"Queue leaders are imbalanced. Re-balance queue leaders before migration.">>,
            ErrorJson = rabbit_json:encode(#{
                error => bad_request,
                reason => Message
            }),
            bad_request(ErrorJson, ReqData, {EndpointType, Context});
        {error, queues_too_deep} ->
            Message = <<"Some queues have too many messages for migration.">>,
            ErrorJson = rabbit_json:encode(#{
                error => bad_request,
                reason => Message
            }),
            bad_request(ErrorJson, ReqData, {EndpointType, Context});
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
            bad_request(ErrorJson, ReqData, {EndpointType, Context});
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
            bad_request(ErrorJson, ReqData, {EndpointType, Context});
        {error, Other} ->
            Message = rqm_util:unicode_format("Migration validation failed: ~p", [Other]),
            ErrorJson = rabbit_json:encode(#{
                error => bad_request,
                reason => Message
            }),
            bad_request(ErrorJson, ReqData, {EndpointType, Context})
    end.

accept_status_update(MigrationIdUrlEncoded, ReqData, {EndpointType, Context}) ->
    MigrationIdUrlDecoded = uri_string:percent_decode(MigrationIdUrlEncoded),
    MigrationIdBin = rqm_util:base64url_decode(MigrationIdUrlDecoded),
    MigrationId = binary_to_term(MigrationIdBin),
    {ok, Body, ReqData2} = cowboy_req:read_body(ReqData),
    case rabbit_json:try_decode(Body) of
        {ok, #{<<"status">> := StatusBin}} ->
            Status = binary_to_existing_atom(StatusBin, utf8),
            case rqm_db:update_migration_status(MigrationId, Status) of
                {ok, _Migration} ->
                    Json = rabbit_json:encode(#{
                        updated => true,
                        migration_id => MigrationIdUrlEncoded,
                        status => StatusBin
                    }),
                    ReqData3 = cowboy_req:set_resp_body(Json, ReqData2),
                    {true, ReqData3, {EndpointType, Context}};
                {error, not_found} ->
                    ErrorJson = rabbit_json:encode(#{error => <<"Migration not found">>}),
                    ReqData3 = cowboy_req:set_resp_body(ErrorJson, ReqData2),
                    ReqData4 = cowboy_req:reply(
                        404, #{<<"content-type">> => <<"application/json">>}, ReqData3
                    ),
                    {stop, ReqData4, {EndpointType, Context}}
            end;
        {error, _} ->
            ErrorJson = rabbit_json:encode(#{error => <<"Invalid JSON">>}),
            bad_request(ErrorJson, ReqData2, {EndpointType, Context});
        {ok, _} ->
            ErrorJson = rabbit_json:encode(#{error => <<"Missing 'status' field">>}),
            bad_request(ErrorJson, ReqData2, {EndpointType, Context})
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
    skipped_queues = SkippedQueues,
    status = Status,
    snapshots = Snapshots,
    skip_unsuitable_queues = SkipUnsuitableQueues
}) ->
    #{
        id => rqm_util:format_migration_id(Id),
        display_id => format_display_id(Id, VHost, StartedAt),
        vhost => VHost,
        started_at => format_timestamp(StartedAt),
        completed_at => format_timestamp(CompletedAt),
        total_queues => TotalQueues,
        completed_queues => CompletedQueues,
        skipped_queues => SkippedQueues,
        progress_percentage => calculate_progress_percentage(CompletedQueues, TotalQueues),
        status => Status,
        snapshots => format_snapshots(Snapshots),
        skip_unsuitable_queues => SkipUnsuitableQueues
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

parse_migration_options(ReqData) ->
    case cowboy_req:has_body(ReqData) of
        true ->
            {ok, Body, _} = cowboy_req:read_body(ReqData),
            case Body of
                <<>> ->
                    #{};
                _ ->
                    case rabbit_json:try_decode(Body) of
                        {ok, Json} when is_map(Json) ->
                            parse_skip_unsuitable_queues(Json);
                        _ ->
                            #{}
                    end
            end;
        false ->
            #{}
    end.

parse_skip_unsuitable_queues(Json) ->
    case maps:get(<<"skip_unsuitable_queues">>, Json, false) of
        true -> #{skip_unsuitable_queues => true};
        false -> #{skip_unsuitable_queues => false};
        _ -> #{}
    end.
