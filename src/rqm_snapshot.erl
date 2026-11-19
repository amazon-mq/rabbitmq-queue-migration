%% Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
%% SPDX-License-Identifier: Apache-2.0
%% vim:ft=erlang:
%% -*- mode: erlang; -*-

-module(rqm_snapshot).

-include("rqm.hrl").

-include_lib("kernel/include/logger.hrl").
-include_lib("kernel/include/file.hrl").

-export([
    create_snapshot/1,
    cleanup_snapshot/1,
    check_no_snapshots_in_progress/0,
    check_snapshot_permitted/0
]).

-ifdef(TEST).
-export([snapshot_tags/1]).
-endif.

-define(PURPOSE_TAG_KEY, "rabbitmq-queue-migration:purpose").
-define(PURPOSE_TAG_VALUE, "pre-migration").
%% EC2 rejects a request that would give a resource more than 50 tags.
-define(MAX_SNAPSHOT_TAGS, 50).

%% @doc Create a snapshot using the configured snapshot mode
-spec create_snapshot(rabbit_types:vhost()) -> {ok, snapshot_state()} | {error, term()}.
create_snapshot(VHost) ->
    SnapshotMode = rqm_config:snapshot_mode(),
    create_snapshot(SnapshotMode, VHost).

%% @doc Create a tar-based fake snapshot
-spec create_snapshot(tar | ebs | none, rabbit_types:vhost()) ->
    {ok, snapshot_state()} | {error, term()}.
create_snapshot(tar, VHost) ->
    ?LOG_DEBUG("rqm: creating fake EBS snapshot (tar archive) for vhost ~ts on node ~tp", [
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
                    ?LOG_DEBUG("rqm: fake EBS snapshot created: ~ts (~w bytes)", [
                        ArchiveFile, ArchiveSize
                    ]),
                    {ok, {
                        rqm_util:to_unicode(ArchiveFile),
                        SnapshotDir,
                        rqm_util:to_unicode(rabbit_net:hostname())
                    }};
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
    ?LOG_DEBUG("rqm: creating real EBS snapshot for vhost ~ts on node ~tp", [VHost, node()]),
    case discover_data_volume() of
        {ok, InstanceId, Volume} ->
            create_ebs_snapshot(
                InstanceId,
                proplists:get_value(volume_id, Volume),
                proplists:get_value(tags, Volume, [])
            );
        {error, _} = Error ->
            Error
    end;
%% @doc Skip snapshot creation when mode is none
create_snapshot(none, _VHost) ->
    ?LOG_DEBUG("rqm: snapshot mode is none, skipping snapshot creation"),
    {ok, <<"none">>}.

%% @doc Check that this node's instance role may create its migration snapshot,
%% by sending the same CreateSnapshot request, tags included, with DryRun set.
%% Fails only when EC2 refuses the request with UnauthorizedOperation. Any other
%% outcome (throttling, a transport error, volume discovery) is logged and
%% passes: it says nothing about permissions, and the real snapshot reports it.
%% Always ok outside ebs mode.
-spec check_snapshot_permitted() -> ok | {error, {snapshot_not_permitted, string()}}.
check_snapshot_permitted() ->
    check_snapshot_permitted(rqm_config:snapshot_mode()).

check_snapshot_permitted(ebs) ->
    try dry_run_snapshot() of
        Result -> dry_run_result(Result)
    catch
        Class:Reason ->
            skip_permission_check({Class, Reason})
    end;
check_snapshot_permitted(_SnapshotMode) ->
    ok.

dry_run_snapshot() ->
    case discover_data_volume() of
        {ok, _InstanceId, Volume} ->
            VolumeId = proplists:get_value(volume_id, Volume),
            Options = snapshot_options(proplists:get_value(tags, Volume, [])),
            rqm_ebs:create_volume_snapshot(VolumeId, Options#{dry_run => true});
        {error, _} = Error ->
            Error
    end.

%% EC2 answers a DryRun it would have allowed with the DryRunOperation error.
dry_run_result({error, {snapshot_creation_failed, ErrorData}} = Result) ->
    case rqm_ebs:error_code(ErrorData) of
        {ok, "DryRunOperation"} ->
            ok;
        {ok, "UnauthorizedOperation" = Code} ->
            ?LOG_ERROR("rqm: snapshot dry run refused: ~p", [Result]),
            {error, {snapshot_not_permitted, Code}};
        _ ->
            skip_permission_check(Result)
    end;
dry_run_result(Result) ->
    skip_permission_check(Result).

skip_permission_check(Result) ->
    ?LOG_WARNING("rqm: snapshot permissions not checked, the dry run did not complete: ~p", [
        Result
    ]),
    ok.

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
check_no_snapshots_in_progress(none) ->
    ok;
check_no_snapshots_in_progress(ebs) ->
    check_ebs_snapshots_in_progress().

check_ebs_snapshots_in_progress() ->
    {ok, Region} = rabbitmq_aws_config:region(),
    ok = rabbitmq_aws:set_region(Region),
    case rqm_ebs:instance_volumes() of
        {ok, {_InstanceId, Volumes}} ->
            case find_rabbitmq_volume(Volumes) of
                {ok, Volume} ->
                    check_volume_snapshots_in_progress(proplists:get_value(volume_id, Volume));
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
                    {error,
                        {snapshot_in_progress, #{
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
    Path =
        "/?Action=DescribeSnapshots"
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

%% @doc Find this node's EBS instance ID and RabbitMQ data volume
-spec discover_data_volume() ->
    {ok, string(), proplists:proplist()} | {error, {volume_discovery_failed, term()}}.
discover_data_volume() ->
    {ok, Region} = rabbitmq_aws_config:region(),
    ok = rabbitmq_aws:set_region(Region),
    case rqm_ebs:instance_volumes() of
        {ok, {InstanceId, Volumes}} ->
            case find_rabbitmq_volume(Volumes) of
                {ok, Volume} ->
                    {ok, InstanceId, Volume};
                {error, Reason} ->
                    ?LOG_ERROR("rqm: failed to find EBS volume: ~p", [Reason]),
                    {error, {volume_discovery_failed, Reason}}
            end;
        {error, Reason} ->
            ?LOG_ERROR("rqm: failed to discover EBS volumes: ~p", [Reason]),
            {error, {volume_discovery_failed, Reason}}
    end.

%% @doc Find the RabbitMQ data volume among the attached EBS volumes (expect exactly one)
-spec find_rabbitmq_volume(list()) -> {ok, proplists:proplist()} | {error, term()}.
find_rabbitmq_volume([]) ->
    {error, no_volumes_found};
find_rabbitmq_volume(Volumes) ->
    case [V || V <- Volumes, is_rmq_data_volume(V)] of
        [] ->
            {error, no_rabbitmq_volumes_found};
        [Volume] ->
            {ok, Volume};
        Multiple ->
            MultipleIds = [proplists:get_value(volume_id, V) || V <- Multiple],
            ?LOG_ERROR(
                "rqm: found multiple RabbitMQ volumes: ~p. Expected exactly one volume on device ~s",
                [MultipleIds, rqm_config:ebs_volume_device()]
            ),
            {error, {multiple_rabbitmq_volumes_found, MultipleIds}}
    end.

%% @doc Create EBS snapshot for single volume ID
-spec create_ebs_snapshot(
    InstanceId :: string(), VolumeId :: string(), VolumeTags :: [{string(), string()}]
) ->
    {ok, snapshot_state()} | {error, term()}.
create_ebs_snapshot(InstanceId, VolumeId, VolumeTags) ->
    case rqm_ebs:create_volume_snapshot(VolumeId, snapshot_options(VolumeTags)) of
        {ok, SnapshotId, _Metadata} ->
            {ok, {
                rqm_util:to_unicode(SnapshotId),
                rqm_util:to_unicode(VolumeId),
                rqm_util:to_unicode(InstanceId)
            }};
        {error, Reason} ->
            ?LOG_ERROR("rqm: failed to create snapshot for volume ~s: ~p", [VolumeId, Reason]),
            {error, {snapshot_failed, VolumeId, Reason}}
    end.

%% @doc The CreateSnapshot options, shared by the real request and its dry run
snapshot_options(VolumeTags) ->
    Timestamp = rqm_util:format_iso8601_utc(),
    Description = rqm_util:unicode_format("RabbitMQ migration snapshot ~s on ~s", [
        Timestamp, node()
    ]),
    #{description => Description, tags => snapshot_tags(VolumeTags)}.

%% @doc Build the snapshot tags: the data volume's own tags plus the purpose marker
-spec snapshot_tags([{string(), string()}]) -> [{string(), string()}].
snapshot_tags(VolumeTags) ->
    % Keys starting with "aws:" are reserved for AWS and cannot be set by a request.
    Copied = [
        Tag
     || {Key, _} = Tag <- VolumeTags,
        not lists:prefix("aws:", Key),
        Key =/= ?PURPOSE_TAG_KEY
    ],
    Kept = keep_within_limit(Copied, ?MAX_SNAPSHOT_TAGS - 1),
    case length(Copied) - length(Kept) of
        0 ->
            ok;
        Dropped ->
            ?LOG_WARNING("rqm: not copying ~b volume tag(s) to the snapshot: EC2 allows ~b tags", [
                Dropped, ?MAX_SNAPSHOT_TAGS
            ])
    end,
    Kept ++ [{?PURPOSE_TAG_KEY, ?PURPOSE_TAG_VALUE}].

%% Keep `Name' when tags must be dropped: it is the tag an IAM policy is most
%% likely to scope a cluster's snapshots by.
keep_within_limit(Tags, Limit) when length(Tags) =< Limit ->
    Tags;
keep_within_limit(Tags, Limit) ->
    {Name, Others} = lists:partition(fun({Key, _}) -> Key =:= "Name" end, Tags),
    Name ++ lists:sublist(Others, Limit - length(Name)).

%% @doc Clean up a snapshot based on the configured snapshot mode
-spec cleanup_snapshot(snapshot_id()) -> ok | {error, term()}.
cleanup_snapshot(SnapshotId) ->
    SnapshotMode = rqm_config:snapshot_mode(),
    cleanup_snapshot(SnapshotMode, SnapshotId).

%% @doc Clean up a tar-based snapshot
-spec cleanup_snapshot(tar | ebs | none, snapshot_id()) -> ok | {error, term()}.
cleanup_snapshot(tar, SnapshotId) when is_binary(SnapshotId) ->
    SnapshotPath = binary_to_list(SnapshotId),
    ?LOG_DEBUG("rqm: cleaning up tar snapshot: ~s", [SnapshotPath]),
    case file:delete(SnapshotPath) of
        ok ->
            ?LOG_DEBUG("rqm: successfully deleted tar snapshot: ~s", [SnapshotPath]),
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
    ?LOG_DEBUG("rqm: cleaning up EBS snapshot: ~s", [SnapshotIdStr]),
    case rqm_ebs:delete_volume_snapshot(SnapshotIdStr) of
        {ok, _} ->
            ?LOG_DEBUG("rqm: successfully deleted EBS snapshot: ~s", [SnapshotIdStr]),
            ok;
        {error, {not_found, _}} ->
            ?LOG_WARNING("rqm: EBS snapshot not found (already deleted?): ~s", [SnapshotIdStr]),
            % Consider this success
            ok;
        {error, Reason} ->
            ?LOG_ERROR("rqm: failed to delete EBS snapshot ~s: ~p", [SnapshotIdStr, Reason]),
            {error, {ebs_delete_failed, Reason}}
    end;
%% @doc No cleanup needed when mode is none
cleanup_snapshot(none, _SnapshotId) ->
    ok;
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
