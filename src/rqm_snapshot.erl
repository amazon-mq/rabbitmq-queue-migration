%% Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
%% SPDX-License-Identifier: Apache-2.0
%% vim:ft=erlang:
%% -*- mode: erlang; -*-

-module(rqm_snapshot).

-include("rqm.hrl").

-include_lib("kernel/include/logger.hrl").
-include_lib("kernel/include/file.hrl").

-export([create_snapshot/1, cleanup_snapshot/1, check_no_snapshots_in_progress/0]).

%% @doc Create a snapshot using the configured snapshot mode
-spec create_snapshot(rabbit_types:vhost()) -> {ok, snapshot_id()} | {error, term()}.
create_snapshot(VHost) ->
    SnapshotMode = rqm_config:snapshot_mode(),
    create_snapshot(SnapshotMode, VHost).

%% @doc Create a tar-based fake snapshot
-spec create_snapshot(tar, rabbit_types:vhost()) -> {ok, snapshot_id()} | {error, term()}.
create_snapshot(tar, VHost) ->
    ?LOG_INFO("rqm: creating fake EBS snapshot (tar archive) for vhost ~ts on node ~tp", [
        VHost, node()
    ]),

    Timestamp = rqm_util:format_iso8601_utc(),
    SnapshotDir = rqm_util:unicode_format("/tmp/rabbitmq_migration_snapshots/~s/", [Timestamp]),
    ok = filelib:ensure_dir(SnapshotDir),

    % Create tar archive filename
    SnapshotFile = rqm_util:unicode_format("~s.tar.gz", [node()]),
    ArchiveFile = filename:join(SnapshotDir, SnapshotFile),

    % Get RabbitMQ data directory
    DataDir = rabbit:data_dir(),
    ?LOG_DEBUG("rqm: RabbitMQ data directory: ~ts", [DataDir]),

    % Create tar command
    TarCommand = io_lib:format("tar -czf ~s -C ~s . && echo -n 'SUCCESS'", [ArchiveFile, DataDir]),
    ?LOG_DEBUG("rqm: creating tar archive with command: ~s", [TarCommand]),
    case os:cmd(TarCommand) of
        "SUCCESS" ->
            % Check if archive was actually created
            case filelib:is_file(ArchiveFile) of
                true ->
                    {ok, FileInfo} = file:read_file_info(ArchiveFile),
                    ArchiveSize = FileInfo#file_info.size,
                    ?LOG_INFO("rqm: fake EBS snapshot created: ~ts (~w bytes)", [
                        ArchiveFile, ArchiveSize
                    ]),
                    {ok, rqm_util:to_unicode(ArchiveFile)};
                false ->
                    ?LOG_ERROR("rqm: tar archive was not created: ~s", [ArchiveFile]),
                    {error, archive_not_created}
            end;
        ErrorOutput ->
            ?LOG_ERROR("rqm: tar command failed: ~s", [ErrorOutput]),
            {error, {tar_command_failed, ErrorOutput}}
    end;
%% @doc Create a real EBS snapshot
create_snapshot(ebs, VHost) ->
    ?LOG_INFO("rqm: creating real EBS snapshot for vhost ~ts on node ~tp", [VHost, node()]),
    {ok, Region} = rabbitmq_aws_config:region(),
    ok = rabbitmq_aws:set_region(Region),
    case rqm_ebs:instance_volumes() of
        {ok, Volumes} ->
            case find_rabbitmq_volume(Volumes) of
                {ok, VolumeId} ->
                    create_ebs_snapshot(VolumeId);
                {error, Reason} ->
                    ?LOG_ERROR("rqm: failed to find EBS volume: ~p", [Reason]),
                    {error, {volume_discovery_failed, Reason}}
            end;
        {error, Reason} ->
            ?LOG_ERROR("rqm: failed to discover EBS volumes: ~p", [Reason]),
            {error, {volume_discovery_failed, Reason}}
    end;
%% @doc Fallback for invalid snapshot modes - defaults to tar
create_snapshot(InvalidMode, VHost) ->
    ?LOG_WARNING("rqm: invalid snapshot mode ~p, defaulting to tar", [InvalidMode]),
    create_snapshot(tar, VHost).

%% @doc Check if there are any in-progress EBS snapshots for RabbitMQ volumes
%% Returns ok if no snapshots in progress, {error, {snapshot_in_progress, Details}} otherwise
-spec check_no_snapshots_in_progress() -> ok | {error, {snapshot_in_progress, term()}}.
check_no_snapshots_in_progress() ->
    SnapshotMode = rqm_config:snapshot_mode(),
    check_no_snapshots_in_progress(SnapshotMode).

%% @doc Check if there are any in-progress EBS snapshots for RabbitMQ volumes
%% Returns ok if no snapshots in progress, {error, {snapshot_in_progress, Details}} otherwise
-spec check_no_snapshots_in_progress(atom()) -> ok | {error, {snapshot_in_progress, term()}}.
check_no_snapshots_in_progress(tar) ->
    ?LOG_DEBUG("rqm: skipping snapshot check in tar mode"),
    ok;
check_no_snapshots_in_progress(ebs) ->
    check_ebs_snapshots_in_progress();
check_no_snapshots_in_progress(InvalidMode) ->
    ?LOG_WARNING("rqm: invalid snapshot mode ~p", [InvalidMode]),
    ok.

check_ebs_snapshots_in_progress() ->
    {ok, Region} = rabbitmq_aws_config:region(),
    ok = rabbitmq_aws:set_region(Region),
    case rqm_ebs:instance_volumes() of
        {ok, Volumes} ->
            case find_rabbitmq_volume(Volumes) of
                {ok, VolumeId} ->
                    check_volume_snapshots_in_progress(VolumeId);
                {error, _} = Error ->
                    ?LOG_DEBUG("rqm: skipping snapshot check, volume not found: ~p", [Error]),
                    ok
            end;
        {error, _} = Error ->
            ?LOG_DEBUG("rqm: skipping snapshot check, cannot get volumes: ~p", [Error]),
            ok
    end.

check_volume_snapshots_in_progress(VolumeId) ->
    case describe_snapshots(VolumeId) of
        {ok, Snapshots} ->
            InProgress = lists:filter(fun is_snapshot_in_progress/1, Snapshots),
            case InProgress of
                [] ->
                    ok;
                [Snapshot | _] ->
                    SnapshotId = proplists:get_value(snapshot_id, Snapshot, "unknown"),
                    State = proplists:get_value(state, Snapshot, "unknown"),
                    {error, {snapshot_in_progress, #{
                        volume_id => VolumeId,
                        snapshot_id => SnapshotId,
                        state => State
                    }}}
            end;
        {error, Reason} ->
            ?LOG_WARNING("rqm: failed to check snapshots for volume ~s: ~p", [VolumeId, Reason]),
            ok
    end.

describe_snapshots(VolumeId) ->
    Path = "/?Action=DescribeSnapshots"
           "&Filter.1.Name=volume-id&Filter.1.Value.1=" ++ VolumeId ++
           "&Version=2016-11-15",
    case rabbitmq_aws:api_get_request("ec2", Path) of
        {ok, Response} -> parse_snapshots_response(Response);
        {error, Reason} -> {error, Reason}
    end.

parse_snapshots_response([{"DescribeSnapshotsResponse", Data}]) ->
    case proplists:get_value("snapshotSet", Data, []) of
        [] ->
            {ok, []};
        SnapshotSet when is_list(SnapshotSet) ->
            Snapshots = lists:map(fun parse_snapshot/1, SnapshotSet),
            {ok, Snapshots};
        _ ->
            {error, parse_error}
    end;
parse_snapshots_response(_) ->
    {error, parse_error}.

parse_snapshot({"item", Props}) ->
    [
        {snapshot_id, proplists:get_value("snapshotId", Props, "")},
        {volume_id, proplists:get_value("volumeId", Props, "")},
        {state, proplists:get_value("status", Props, "")},
        {progress, proplists:get_value("progress", Props, "")}
    ];
parse_snapshot(_) ->
    [].

is_snapshot_in_progress(Snapshot) ->
    State = proplists:get_value(state, Snapshot, ""),
    State =:= "pending".

%%----------------------------------------------------------------------------
%% Internal functions
%%----------------------------------------------------------------------------

%% @doc Extract volume ID from all attached EBS volumes (expect exactly one)
-spec find_rabbitmq_volume(list()) -> {ok, string()} | {error, term()}.
find_rabbitmq_volume([]) ->
    {error, no_volumes_found};
find_rabbitmq_volume(Volumes) ->
    VolumeIds = extract_volume_ids(Volumes),
    case VolumeIds of
        [] ->
            {error, no_rabbitmq_volumes_found};
        [VolumeId] ->
            {ok, VolumeId};
        MultipleIds ->
            ?LOG_ERROR(
                "rqm: found multiple RabbitMQ volumes: ~p. Expected exactly one volume on device ~s",
                [MultipleIds, rqm_config:ebs_volume_device()]
            ),
            {error, {multiple_rabbitmq_volumes_found, MultipleIds}}
    end.

%% @doc Extract volume IDs from volume list
-spec extract_volume_ids(list()) -> [string()].
extract_volume_ids(Volumes) ->
    lists:foldl(fun extract_volume_id/2, [], Volumes).

%% rqm_snapshot:extract_volume_id([{volume_id,"vol-07746e989a46b742f"},
%%  {size,"8"},
%%  {volume_type,"gp3"},
%%  {state,"in-use"},
%%  {attachment,[{device,"/dev/xvda"},{state,"attached"}]}], [])
%% @doc Extract volume ID from a single volume record
extract_volume_id(VolumeInfo, Acc) when is_list(VolumeInfo) ->
    case {proplists:get_value(volume_id, VolumeInfo), is_rmq_data_volume(VolumeInfo)} of
        {undefined, _} ->
            Acc;
        {_, false} ->
            Acc;
        {VolumeId, true} ->
            [VolumeId | Acc]
    end;
extract_volume_id(_, Acc) ->
    Acc.

%% @doc Create EBS snapshot for single volume ID
-spec create_ebs_snapshot(string()) -> {ok, {string(), string()}} | {error, term()}.
create_ebs_snapshot(VolumeId) ->
    Timestamp = rqm_util:format_iso8601_utc(),
    Description = rqm_util:unicode_format("RabbitMQ migration snapshot ~s on ~s", [
        Timestamp, node()
    ]),

    case rqm_ebs:create_volume_snapshot(VolumeId, #{description => Description}) of
        {ok, SnapshotId, _Metadata} ->
            ?LOG_INFO("rqm: created snapshot ~s for volume ~s", [SnapshotId, VolumeId]),
            {ok, {rqm_util:to_unicode(SnapshotId), rqm_util:to_unicode(VolumeId)}};
        {error, Reason} ->
            ?LOG_ERROR("rqm: failed to create snapshot for volume ~s: ~p", [VolumeId, Reason]),
            {error, {snapshot_failed, VolumeId, Reason}}
    end.

%% @doc Clean up a snapshot based on the configured snapshot mode
-spec cleanup_snapshot(snapshot_id()) -> ok | {error, term()}.
cleanup_snapshot(SnapshotId) ->
    SnapshotMode = rqm_config:snapshot_mode(),
    cleanup_snapshot(SnapshotMode, SnapshotId).

%% @doc Clean up a tar-based snapshot
-spec cleanup_snapshot(tar, snapshot_id()) -> ok | {error, term()}.
cleanup_snapshot(tar, SnapshotId) when is_binary(SnapshotId) ->
    SnapshotPath = binary_to_list(SnapshotId),
    ?LOG_INFO("rqm: cleaning up tar snapshot: ~s", [SnapshotPath]),
    case file:delete(SnapshotPath) of
        ok ->
            ?LOG_INFO("rqm: successfully deleted tar snapshot: ~s", [SnapshotPath]),
            ok;
        {error, enoent} ->
            ?LOG_WARNING("rqm: tar snapshot file not found (already deleted?): ~s", [SnapshotPath]),
            % Consider this success
            ok;
        {error, Reason} ->
            ?LOG_ERROR("rqm: failed to delete tar snapshot ~s: ~p", [SnapshotPath, Reason]),
            {error, {file_delete_failed, Reason}}
    end;
%% @doc Clean up an EBS snapshot
cleanup_snapshot(ebs, SnapshotId) when is_binary(SnapshotId) ->
    SnapshotIdStr = binary_to_list(SnapshotId),
    ?LOG_INFO("rqm: cleaning up EBS snapshot: ~s", [SnapshotIdStr]),
    case rqm_ebs:delete_volume_snapshot(SnapshotIdStr) of
        {ok, _} ->
            ?LOG_INFO("rqm: successfully deleted EBS snapshot: ~s", [SnapshotIdStr]),
            ok;
        {error, {not_found, _}} ->
            ?LOG_WARNING("rqm: EBS snapshot not found (already deleted?): ~s", [SnapshotIdStr]),
            % Consider this success
            ok;
        {error, Reason} ->
            ?LOG_ERROR("rqm: failed to delete EBS snapshot ~s: ~p", [SnapshotIdStr, Reason]),
            {error, {ebs_delete_failed, Reason}}
    end;
%% @doc Fallback for invalid snapshot modes
cleanup_snapshot(InvalidMode, SnapshotId) ->
    ?LOG_WARNING("rqm: invalid snapshot mode ~p for cleanup, skipping snapshot ~p", [
        InvalidMode, SnapshotId
    ]),
    ok.

%% Helper function to check if volume is mounted to /dev/sdh
is_rmq_data_volume(VolumeInfo) ->
    Device = rqm_config:ebs_volume_device(),
    case proplists:get_value(attachment, VolumeInfo) of
        AttachmentInfo when is_list(AttachmentInfo) ->
            proplists:get_value(device, AttachmentInfo) =:= Device;
        _ ->
            false
    end.
