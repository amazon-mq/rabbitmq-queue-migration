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
        {"/queue-migration/check/:vhost", ?MODULE, [check]},
        {"/queue-migration/start", ?MODULE, [start]},
        {"/queue-migration/start/:vhost", ?MODULE, [start_vhost]},
        {"/queue-migration/status", ?MODULE, [status_list]},
        {"/queue-migration/status/:migration_id", ?MODULE, [status_detail]},
        {"/queue-migration/interrupt/:migration_id", ?MODULE, [interrupt]},
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

allowed_methods(ReqData, {check, Context}) ->
    {[<<"POST">>, <<"HEAD">>, <<"OPTIONS">>], ReqData, {check, Context}};
allowed_methods(ReqData, {EndpointType, Context}) ->
    {[<<"GET">>, <<"HEAD">>, <<"POST">>, <<"OPTIONS">>], ReqData, {EndpointType, Context}}.

resource_exists(ReqData, {status_detail, Context}) ->
    MigrationIdUrlEncoded = cowboy_req:binding(migration_id, ReqData),
    case rqm_util:parse_migration_id(MigrationIdUrlEncoded) of
        {ok, MigrationId} ->
            case rqm:get_queue_migration_status(MigrationId) of
                {ok, _} ->
                    State = {migration_id, MigrationId},
                    {true, ReqData, {status_detail, Context#context{impl = State}}};
                {error, _} ->
                    {false, ReqData, {status_detail, Context}}
            end;
        error ->
            {false, ReqData, {status_detail, Context}}
    end;
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
to_json(ReqData, {status_detail, #context{impl = {migration_id, MigrationId}}} = Context) ->
    {ok, {Migration, QueueDetails}} = rqm:get_queue_migration_status(MigrationId),
    Json = rabbit_json:encode(#{
        migration => migration_to_json_detail(Migration),
        queues => [queue_status_to_json(Q) || Q <- QueueDetails]
    }),
    {Json, ReqData, {status_detail, Context}};
to_json(ReqData, {interrupt, Context}) ->
    {halt, ReqData, {interrupt, Context}}.

is_authorized(ReqData, {EndpointType, Context}) ->
    {Res, RD, C} = rabbit_mgmt_util:is_authorized_monitor(ReqData, Context),
    {Res, RD, {EndpointType, C}}.

bad_request(ErrorJson, ReqData, {EndpointType, Context}) ->
    ReqData2 = cowboy_req:set_resp_body(ErrorJson, ReqData),
    ReqData3 = cowboy_req:reply(400, #{<<"content-type">> => <<"application/json">>}, ReqData2),
    {stop, ReqData3, {EndpointType, Context}}.

accept_content(ReqData, {check, Context}) ->
    accept_compatibility_check(ReqData, {check, Context});
accept_content(ReqData, {start, Context}) ->
    accept_migration_start(ReqData, {start, Context});
accept_content(ReqData, {start_vhost, Context}) ->
    accept_migration_start(ReqData, {start_vhost, Context});
accept_content(ReqData, {status_detail, Context}) ->
    MigrationIdUrlEncoded = cowboy_req:binding(migration_id, ReqData),
    accept_status_update(MigrationIdUrlEncoded, ReqData, {status_detail, Context});
accept_content(ReqData, {interrupt, Context}) ->
    MigrationIdUrlEncoded = cowboy_req:binding(migration_id, ReqData),
    accept_interrupt(MigrationIdUrlEncoded, ReqData, {interrupt, Context}).

accept_migration_start(ReqData, {EndpointType, Context}) ->
    VHost =
        case cowboy_req:binding(vhost, ReqData) of
            undefined -> <<"/">>;
            _VHostName -> rabbit_mgmt_util:id(vhost, ReqData)
        end,
    % Parse request body for options
    Opts0 = parse_migration_options(VHost, ReqData),
    % First, run validation synchronously to catch errors before spawning
    case rqm:validate_migration(Opts0) of
        ok ->
            MigrationId = rqm_util:generate_migration_id(),
            Opts1 = Opts0#{migration_id => MigrationId},
            spawn(rqm, start, [Opts1]),
            Json = rabbit_json:encode(#{
                migration_id => rqm_util:format_migration_id(MigrationId),
                status => <<"started">>
            }),
            ReqData2 = cowboy_req:set_resp_body(Json, ReqData),
            {true, ReqData2, {EndpointType, Context}};
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
                "Found ~p queue(s) with issues (too many messages, too many bytes, or unsuitable arguments)",
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
        {error, {unsuitable_overflow_behavior, Details}} ->
            QueueName = maps:get(queue_name, Details),
            OverflowBehavior = maps:get(overflow_behavior, Details),
            QueueNameStr = rabbit_misc:rs(QueueName),
            Message = rqm_util:unicode_format(
                "Cannot migrate: Queue '~s' uses overflow behavior '~s' which is unsuitable with quorum queues. "
                "Please change the queue's overflow behavior to 'drop-head' or 'reject-publish' before migration.",
                [QueueNameStr, OverflowBehavior]
            ),
            ErrorJson = rabbit_json:encode(#{
                error => bad_request,
                reason => Message,
                queue_name => QueueNameStr,
                unsuitable_setting => <<"x-overflow">>,
                current_value => OverflowBehavior,
                suggested_values => [<<"drop-head">>, <<"reject-publish">>]
            }),
            bad_request(ErrorJson, ReqData, {EndpointType, Context});
        {error, {no_eligible_queues, Details}} ->
            TotalQueues = maps:get(total, Details, 0),
            UnsuitableQueues = maps:get(unsuitable, Details, 0),
            Message =
                case TotalQueues of
                    0 ->
                        <<"No mirrored classic queues found in this vhost. Only classic queues with an HA policy can be migrated.">>;
                    _ ->
                        <<"All mirrored classic queues in this vhost are unsuitable for migration.">>
                end,
            ErrorJson = rabbit_json:encode(#{
                error => bad_request,
                reason => Message,
                total_queues => TotalQueues,
                unsuitable_queues => UnsuitableQueues
            }),
            bad_request(ErrorJson, ReqData, {EndpointType, Context});
        {error, nodes_down} ->
            Message =
                <<"Some cluster nodes are down. Ensure all cluster nodes are running before migration.">>,
            ErrorJson = rabbit_json:encode(#{
                error => bad_request,
                reason => Message
            }),
            bad_request(ErrorJson, ReqData, {EndpointType, Context});
        {error, nodes_not_booted} ->
            Message =
                <<"Some cluster nodes are not fully booted. Wait for all nodes to complete startup before migration.">>,
            ErrorJson = rabbit_json:encode(#{
                error => bad_request,
                reason => Message
            }),
            bad_request(ErrorJson, ReqData, {EndpointType, Context});
        {error, partitions_detected} ->
            Message =
                <<"Cluster partitions detected. Resolve network partitions before migration.">>,
            ErrorJson = rabbit_json:encode(#{
                error => bad_request,
                reason => Message
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
    case rqm_util:parse_migration_id(MigrationIdUrlEncoded) of
        {ok, MigrationId} ->
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
                            not_found_reply(ReqData2, {EndpointType, Context})
                    end;
                {error, _} ->
                    ErrorJson = rabbit_json:encode(#{error => <<"Invalid JSON">>}),
                    bad_request(ErrorJson, ReqData2, {EndpointType, Context});
                {ok, _} ->
                    ErrorJson = rabbit_json:encode(#{error => <<"Missing 'status' field">>}),
                    bad_request(ErrorJson, ReqData2, {EndpointType, Context})
            end;
        error ->
            not_found_reply(ReqData, {EndpointType, Context})
    end.

accept_interrupt(MigrationIdUrlEncoded, ReqData, {EndpointType, Context}) ->
    case rqm_util:parse_migration_id(MigrationIdUrlEncoded) of
        {ok, MigrationId} ->
            case rqm_db:update_migration_status(MigrationId, interrupted) of
                {ok, _Migration} ->
                    Json = rabbit_json:encode(#{
                        interrupted => true,
                        migration_id => MigrationIdUrlEncoded
                    }),
                    ReqData2 = cowboy_req:set_resp_body(Json, ReqData),
                    {true, ReqData2, {EndpointType, Context}};
                {error, not_found} ->
                    not_found_reply(ReqData, {EndpointType, Context})
            end;
        error ->
            not_found_reply(ReqData, {EndpointType, Context})
    end.

migration_to_json(
    {Id, VHost, StartedAt, CompletedAt, TotalQueues, CompletedQueues, SkippedQueues, Status,
        SkipUnsuitableQueues, Tolerance, Error}
) ->
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
        skip_unsuitable_queues => SkipUnsuitableQueues,
        tolerance => Tolerance,
        error => format_error(Error)
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
    skip_unsuitable_queues = SkipUnsuitableQueues,
    tolerance = Tolerance,
    error = Error
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
        skip_unsuitable_queues => SkipUnsuitableQueues,
        tolerance => Tolerance,
        error => format_error(Error)
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
        error => format_error(Error)
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

format_error(undefined) ->
    null;
format_error(Error) ->
    Error.

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

parse_migration_options(VHost, ReqData) ->
    Opts = #{vhost => VHost},
    maybe_parse_json_body(Opts, read_body(ReqData)).

read_body(ReqData) ->
    HasBody = cowboy_req:has_body(ReqData),
    read_body(HasBody, ReqData).

read_body(false, _ReqData) ->
    empty;
read_body(true, ReqData) ->
    {ok, Body, _} = cowboy_req:read_body(ReqData),
    decode_body(Body).

decode_body(<<>>) ->
    empty;
decode_body(Body) ->
    try_decode_json(rabbit_json:try_decode(Body)).

try_decode_json({ok, Json}) when is_map(Json) ->
    {ok, Json};
try_decode_json(_) ->
    empty.

maybe_parse_json_body(Opts, {ok, Json}) ->
    parse_all_options(Opts, Json);
maybe_parse_json_body(Opts, empty) ->
    Opts.

parse_all_options(Opts0, Json) ->
    Opts1 = parse_skip_unsuitable_queues(Json, Opts0),
    Opts2 = parse_batch_size(Json, Opts1),
    Opts3 = parse_batch_order(Json, Opts2),
    Opts4 = parse_queue_names(Json, Opts3),
    parse_tolerance(Json, Opts4).

parse_skip_unsuitable_queues(Json, Opts) ->
    case maps:get(<<"skip_unsuitable_queues">>, Json, false) of
        true -> Opts#{skip_unsuitable_queues => true};
        false -> Opts#{skip_unsuitable_queues => false};
        _ -> Opts
    end.

parse_batch_size(Json, Opts) ->
    case maps:get(<<"batch_size">>, Json, undefined) of
        undefined -> Opts;
        <<"all">> -> Opts#{batch_size => all};
        0 -> Opts#{batch_size => all};
        N when is_integer(N), N > 0 -> Opts#{batch_size => N};
        _ -> Opts
    end.

parse_batch_order(Json, Opts) ->
    case maps:get(<<"batch_order">>, Json, undefined) of
        <<"smallest_first">> -> Opts#{batch_order => smallest_first};
        <<"largest_first">> -> Opts#{batch_order => largest_first};
        _ -> Opts
    end.

parse_queue_names(Json, Opts) ->
    case maps:get(<<"queue_names">>, Json, undefined) of
        undefined ->
            Opts;
        Names when is_list(Names) ->
            QueueNames = [rqm_util:to_unicode(N) || N <- Names],
            Opts#{queue_names => QueueNames};
        _ ->
            Opts
    end.

parse_tolerance(Json, Opts) ->
    case maps:get(<<"tolerance">>, Json, undefined) of
        V when is_number(V), V >= 0.0, V =< 100.0 ->
            Opts#{tolerance => float(V)};
        _ ->
            Opts
    end.

not_found_reply(ReqData, State) ->
    ErrorJson = rabbit_json:encode(#{error => <<"Migration not found">>}),
    ReqData2 = cowboy_req:set_resp_body(ErrorJson, ReqData),
    ReqData3 = cowboy_req:reply(404, #{<<"content-type">> => <<"application/json">>}, ReqData2),
    {stop, ReqData3, State}.

%%--------------------------------------------------------------------
%% Compatibility check handlers
%%--------------------------------------------------------------------

accept_compatibility_check(ReqData, {EndpointType, Context}) ->
    VHost =
        case cowboy_req:binding(vhost, ReqData) of
            <<"all">> -> all_vhosts;
            undefined -> <<"/">>;
            _VHostName -> rabbit_mgmt_util:id(vhost, ReqData)
        end,
    OptsMap = parse_skip_unsuitable_queues_from_body(ReqData),
    case VHost of
        all_vhosts ->
            AllVhosts = rabbit_vhost:list(),
            Results = [
                format_readiness(rqm_compat_checker:check_migration_readiness(VH, OptsMap))
             || VH <- AllVhosts
            ],
            Json = rabbit_json:encode(#{vhost => <<"all">>, vhost_results => Results}),
            {true, cowboy_req:set_resp_body(Json, ReqData), {EndpointType, Context}};
        _ ->
            Result = rqm_compat_checker:check_migration_readiness(VHost, OptsMap),
            Json = rabbit_json:encode(format_readiness(Result)),
            {true, cowboy_req:set_resp_body(Json, ReqData), {EndpointType, Context}}
    end.

parse_skip_unsuitable_queues_from_body(ReqData) ->
    case cowboy_req:has_body(ReqData) of
        true ->
            {ok, Body, _} = cowboy_req:read_body(ReqData),
            case Body of
                <<>> ->
                    #{};
                _ ->
                    case rabbit_json:try_decode(Body) of
                        {ok, #{<<"skip_unsuitable_queues">> := true}} ->
                            #{skip_unsuitable_queues => true};
                        {ok, _} ->
                            #{skip_unsuitable_queues => false};
                        _ ->
                            #{}
                    end
            end;
        false ->
            #{}
    end.

format_readiness(#{
    vhost := VHost,
    overall_ready := Ready,
    skip_unsuitable_queues := Skip,
    system_checks := SysChecks,
    queue_checks := QueueChecks
}) ->
    #{
        vhost => VHost,
        overall_ready => Ready,
        skip_unsuitable_queues => Skip,
        system_checks => format_system_checks(SysChecks),
        queue_checks => format_queue_checks(QueueChecks)
    }.

format_system_checks(#{all_passed := AllPassed, checks := Checks}) ->
    #{all_passed => AllPassed, checks => Checks}.

format_queue_checks(#{summary := Summary, results := []}) ->
    #{summary => Summary, results => []};
format_queue_checks(#{summary := Summary, results := Results}) ->
    Sorted = lists:sort(fun({A, _}, {B, _}) -> queue_sort_key(A) =< queue_sort_key(B) end, Results),
    #{summary => Summary, results => [format_queue_result(R) || R <- Sorted]}.

queue_sort_key(#resource{virtual_host = VHost, name = Name}) -> {VHost, Name}.

format_queue_result({#resource{name = Name, virtual_host = VHost}, {compatible, _}}) ->
    #{name => Name, vhost => VHost, compatible => true, issues => []};
format_queue_result({#resource{name = Name, virtual_host = VHost}, {unsuitable, Issues}}) ->
    #{
        name => Name,
        vhost => VHost,
        compatible => false,
        issues => [format_issue(I) || I <- Issues]
    }.

format_issue({exclusive, Reason}) ->
    #{type => <<"exclusive">>, reason => list_to_binary(Reason)};
format_issue({Type, Reason}) when is_atom(Type), is_list(Reason) ->
    #{type => atom_to_binary(Type, utf8), reason => list_to_binary(Reason)};
format_issue({unsupported_argument, ArgName, Reason}) ->
    #{type => <<"unsupported_argument">>, argument => ArgName, reason => list_to_binary(Reason)}.
