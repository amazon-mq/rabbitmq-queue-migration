%% Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
%% SPDX-License-Identifier: Apache-2.0
%% vim:ft=erlang:
%% -*- mode: erlang; -*-

%% @doc AWS EBS module
%% This module provides higher-level AWS operations like EBS snapshots.
%% @end

-module(rqm_ebs).

-export([
    instance_volumes/0,
    create_volume_snapshot/1,
    create_volume_snapshot/2,
    delete_volume_snapshot/1,
    delete_volume_snapshot/2
]).

-type attachment_info() :: [{device, string()} | {state, string()}].
-type volume_info() :: [
    {volume_id, string()}
    | {size, string()}
    | {volume_type, string()}
    | {state, string()}
    | {attachment, attachment_info()}
].
-type volumes_list() :: [volume_info()].

-type snapshot_options() :: #{
    description => string(),
    tags => [{string(), string()}],
    dry_run => boolean()
}.

-type delete_options() :: #{
    dry_run => boolean()
}.

-type snapshot_metadata() :: #{
    snapshot_id => string(),
    volume_id => string(),
    state => string(),
    start_time => string(),
    progress => string(),
    description => string()
}.

-spec instance_volumes() -> {'ok', volumes_list()} | {'error', 'undefined'}.
%% @doc Return the EBS volumes attached to the current instance from the EC2 API.
%% @end
instance_volumes() ->
    case rabbitmq_aws_config:instance_id() of
        {ok, InstanceId} ->
            Path =
                "/?Action=DescribeVolumes&Filter.1.Name=attachment.instance-id&Filter.1.Value.1=" ++
                    InstanceId ++ "&Version=2016-11-15",
            case rabbitmq_aws:api_get_request("ec2", Path) of
                {ok, Response} -> parse_volumes_response(Response);
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec create_volume_snapshot(string()) -> {ok, string(), snapshot_metadata()} | {error, term()}.
%% @doc Create a snapshot of the specified EBS volume with default options.
%% @end
create_volume_snapshot(VolumeId) ->
    create_volume_snapshot(VolumeId, #{}).

-spec create_volume_snapshot(string(), snapshot_options()) ->
    {ok, string(), snapshot_metadata()} | {error, term()}.
%% @doc Create a snapshot of the specified EBS volume with custom options.
%% @end
create_volume_snapshot(VolumeId, Options) ->
    Description = maps:get(description, Options, "RabbitMQ automated snapshot"),
    DryRun = maps:get(dry_run, Options, false),

    Body = build_snapshot_body(VolumeId, Description, DryRun),
    Headers = [{"content-type", "application/x-www-form-urlencoded"}],
    case rabbitmq_aws:post("ec2", "/", Body, Headers) of
        {ok, {_Headers, Response}} -> parse_snapshot_response(Response);
        {error, _Message, {_Headers, Response}} -> parse_snapshot_response(Response);
        {error, Reason} -> categorize_error(VolumeId, Reason)
    end.

-spec delete_volume_snapshot(string()) -> {ok, string()} | {error, term()}.
%% @doc Delete the specified EBS snapshot with default options.
%% @end
delete_volume_snapshot(SnapshotId) ->
    delete_volume_snapshot(SnapshotId, #{}).

-spec delete_volume_snapshot(string(), delete_options()) -> {ok, string()} | {error, term()}.
%% @doc Delete the specified EBS snapshot with custom options.
%% @end
delete_volume_snapshot(SnapshotId, Options) ->
    DryRun = maps:get(dry_run, Options, false),

    Body = build_delete_body(SnapshotId, DryRun),
    Headers = [{"content-type", "application/x-www-form-urlencoded"}],
    case rabbitmq_aws:post("ec2", "/", Body, Headers) of
        {ok, {_Headers, Response}} -> parse_delete_response(Response, SnapshotId);
        {error, _Message, {_Headers, Response}} -> parse_delete_response(Response, SnapshotId);
        {error, Reason} -> categorize_delete_error(SnapshotId, Reason)
    end.

%%----------------------------------------------------------------------------------------------------
%% private functions
%%----------------------------------------------------------------------------------------------------

-spec parse_volumes_response(term()) -> {'ok', volumes_list()} | {'error', 'parse_error'}.
%% @doc Parse the DescribeVolumes XML response into a list of volume information.
%% @end
parse_volumes_response([{"DescribeVolumesResponse", VolumeData}]) ->
    case proplists:get_value("volumeSet", VolumeData, []) of
        [] ->
            {ok, []};
        VolumeSet when is_list(VolumeSet) ->
            Volumes = lists:map(fun parse_volume/1, VolumeSet),
            {ok, Volumes};
        _ ->
            {error, parse_error}
    end;
parse_volumes_response(_) ->
    {error, parse_error}.

-spec parse_volume(term()) -> volume_info().
%% @doc Parse individual volume data from XML response.
%% @end
parse_volume({"item", VolumeProps}) ->
    VolumeId = proplists:get_value("volumeId", VolumeProps, ""),
    Size = proplists:get_value("size", VolumeProps, ""),
    VolumeType = proplists:get_value("volumeType", VolumeProps, ""),
    State = proplists:get_value("status", VolumeProps, ""),

    % Parse attachment info
    AttachmentSet = proplists:get_value("attachmentSet", VolumeProps, []),
    Attachment =
        case AttachmentSet of
            [{"item", AttachProps}] ->
                [
                    {device, proplists:get_value("device", AttachProps, "")},
                    {state, proplists:get_value("status", AttachProps, "")}
                ];
            _ ->
                []
        end,

    [
        {volume_id, VolumeId},
        {size, Size},
        {volume_type, VolumeType},
        {state, State},
        {attachment, Attachment}
    ];
parse_volume(_) ->
    [].

-spec build_snapshot_body(string(), string() | binary(), boolean()) -> string().
build_snapshot_body(VolumeId, Description, DryRun) ->
    DescStr = unicode:characters_to_list(Description),
    BaseBody =
        "Action=CreateSnapshot&VolumeId=" ++ VolumeId ++
            "&Description=" ++ uri_string:quote(DescStr) ++
            "&Version=2016-11-15",
    case DryRun of
        true -> BaseBody ++ "&DryRun=true";
        false -> BaseBody
    end.

-spec build_delete_body(string(), boolean()) -> string().
build_delete_body(SnapshotId, DryRun) ->
    BaseBody =
        "Action=DeleteSnapshot&SnapshotId=" ++ SnapshotId ++
            "&Version=2016-11-15",
    case DryRun of
        true -> BaseBody ++ "&DryRun=true";
        false -> BaseBody
    end.

-spec parse_snapshot_response(term()) -> {ok, string(), snapshot_metadata()} | {error, term()}.
parse_snapshot_response([{"CreateSnapshotResponse", SnapshotData}]) ->
    SnapshotId = proplists:get_value("snapshotId", SnapshotData, ""),
    Metadata = #{
        snapshot_id => SnapshotId,
        volume_id => proplists:get_value("volumeId", SnapshotData, ""),
        state => proplists:get_value("status", SnapshotData, ""),
        start_time => proplists:get_value("startTime", SnapshotData, ""),
        progress => proplists:get_value("progress", SnapshotData, ""),
        description => proplists:get_value("description", SnapshotData, "")
    },
    {ok, SnapshotId, Metadata};
parse_snapshot_response({error, ErrorType, ErrorDetails}) ->
    {error, {snapshot_creation_failed, ErrorType, ErrorDetails}}.

-spec parse_delete_response(term(), string()) -> {ok, string()}.
parse_delete_response([{"DeleteSnapshotResponse", _ResponseData}], SnapshotId) ->
    {ok, SnapshotId}.

-spec categorize_error(string(), term()) -> {error, term()}.
categorize_error(VolumeId, Reason) ->
    case Reason of
        "InvalidVolume.NotFound" ->
            Msg = io_lib:format("Volume '~tp' not found", [VolumeId]),
            {error, {not_found, Msg}};
        _ ->
            {error, Reason}
    end.

-spec categorize_delete_error(string(), term()) -> {error, term()}.
categorize_delete_error(SnapshotId, Reason) ->
    case Reason of
        "InvalidSnapshot.NotFound" ->
            Msg = io_lib:format("Snapshot '~tp' not found", [SnapshotId]),
            {error, {not_found, Msg}};
        "InvalidSnapshot.InUse" ->
            Msg = io_lib:format("Snapshot '~tp' is currently in use", [SnapshotId]),
            {error, {in_use, Msg}};
        _ ->
            {error, Reason}
    end.
