%% Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
%% SPDX-License-Identifier: Apache-2.0
%% vim:ft=erlang:
%% -*- mode: erlang; -*-

-module(rqm_util).

-include_lib("kernel/include/logger.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").

%% Public API
-export([
    has_ha_policy/1,
    has_all_mirrors_synchronized/1,
    filter_by_queue_names/2,
    base64url_encode/1,
    base64url_decode/1,
    add_base64_padding/1,
    generate_migration_id/0,
    format_migration_id/1,
    parse_migration_id/1,
    to_unicode/1,
    unicode_format/2,
    suspend_non_http_listeners/0,
    close_all_client_connections/0,
    resume_non_http_listeners/1,
    resume_all_non_http_listeners/0,
    format_iso8601_utc/0
]).

has_ha_policy(Q) ->
    case rabbit_policy:effective_definition(Q) of
        EffectivePolicies when is_list(EffectivePolicies) ->
            proplists:lookup(<<"ha-mode">>, EffectivePolicies) =/= none;
        _ ->
            false
    end.

%% @doc Check if all mirrors of a mirrored classic queue are synchronized
%% Returns true if all mirror nodes have synchronized replicas, false otherwise
-spec has_all_mirrors_synchronized(rabbit_types:amqqueue()) -> boolean().
has_all_mirrors_synchronized(Q) ->
    case amqqueue:get_type(Q) of
        rabbit_classic_queue ->
            % Get all mirror pids (synchronized mirrors)
            SyncMirrorPids = amqqueue:get_sync_slave_pids(Q),
            % Get all mirror nodes where the queue should be running
            AllMirrorPids = amqqueue:get_slave_pids(Q),
            % All mirrors are synchronized if sync count equals total count
            length(SyncMirrorPids) =:= length(AllMirrorPids);
        _ ->
            % Non-classic queues are considered synchronized by default
            true
    end.

%% =============================================================================
%% URL-safe base64 encoding functions
%% =============================================================================
%% These functions implement RFC 4648 Section 5 - Base 64 Encoding with URL and Filename Safe Alphabet

%% @doc Encode binary data using URL-safe base64 encoding
%% Replaces '+' with '-', '/' with '_', and removes padding '='
-spec base64url_encode(binary()) -> binary().
base64url_encode(Data) ->
    % Standard base64 encode, then replace characters and remove padding
    Encoded = base64:encode(Data),
    % Replace + with -, / with _, and remove padding =
    NoPadding = binary:replace(Encoded, <<"=">>, <<>>, [global]),
    Step1 = binary:replace(NoPadding, <<"+">>, <<"-">>, [global]),
    binary:replace(Step1, <<"/">>, <<"_">>, [global]).

%% @doc Decode URL-safe base64 encoded data
%% Reverses the URL-safe encoding: '-' to '+', '_' to '/', and adds padding if needed
-spec base64url_decode(binary()) -> binary().
base64url_decode(Data) ->
    % Reverse character replacements and add padding if needed
    Step1 = binary:replace(Data, <<"-">>, <<"+">>, [global]),
    Step2 = binary:replace(Step1, <<"_">>, <<"/">>, [global]),
    PaddedData = add_base64_padding(Step2),
    base64:decode(PaddedData).

%% @doc Add appropriate padding to base64 data
%% Base64 requires padding to make the length a multiple of 4
-spec add_base64_padding(binary()) -> binary().
add_base64_padding(Data) ->
    case byte_size(Data) rem 4 of
        % No padding needed
        0 -> Data;
        % Invalid base64 length
        1 -> error(invalid_base64_length);
        % Add 2 padding characters
        2 -> <<Data/binary, "==">>;
        % Add 1 padding character
        3 -> <<Data/binary, "=">>
    end.

%% @doc Format migration ID using URL-safe base64 encoding
-spec format_migration_id({integer(), atom()}) -> binary().
format_migration_id({Timestamp, Node}) ->
    MigrationId = {Timestamp, Node},
    base64url_encode(term_to_binary(MigrationId)).

-spec generate_migration_id() -> {integer(), atom()}.
generate_migration_id() ->
    {erlang:system_time(millisecond), node()}.

%% @doc Parse a URL-encoded migration ID string back to the original tuple
%% Returns {ok, MigrationId} or error if the input is invalid
-spec parse_migration_id(binary()) -> {ok, {integer(), atom()}} | error.
parse_migration_id(UrlEncoded) ->
    try
        Decoded = uri_string:percent_decode(UrlEncoded),
        Bin = base64url_decode(Decoded),
        {ok, binary_to_term(Bin)}
    catch
        _:_ -> error
    end.

%% @doc Format string using io_lib:format and convert to Unicode binary
%% This function combines io_lib:format/2 with unicode:characters_to_binary/1
%% to ensure proper Unicode handling and consistent binary output
-spec to_unicode(string()) -> binary().
to_unicode(Arg) ->
    unicode:characters_to_binary(Arg).

%% @doc Format string using io_lib:format and convert to Unicode binary
%% This function combines io_lib:format/2 with unicode:characters_to_binary/1
%% to ensure proper Unicode handling and consistent binary output
-spec unicode_format(string(), [term()]) -> binary().
unicode_format(Format, Args) ->
    unicode:characters_to_binary(io_lib:format(Format, Args)).

%% =============================================================================
%% Listener management functions for EBS snapshot preparation
%% =============================================================================

%% @doc Suspend all listeners except HTTP and HTTPS protocols
%% This function is designed for EBS snapshot preparation where we need to:
%% - Block AMQP connections to ensure data consistency
%% - Keep HTTP API available for monitoring and control
%% Returns {ok, SuspendedListeners} on success, {error, Reason} on failure
-spec suspend_non_http_listeners() -> {ok, [rabbit_types:listener()]} | {error, term()}.
suspend_non_http_listeners() ->
    AllListeners = rabbit_networking:node_client_listeners(node()),
    NonHttpListeners = lists:filter(fun is_non_http_listener/1, AllListeners),

    ?LOG_DEBUG(
        "rqm: suspending ~b non-HTTP listeners for EBS snapshot preparation. "
        "HTTP API will remain available for monitoring.",
        [length(NonHttpListeners)]
    ),

    Results = lists:foldl(fun suspend_listener_with_logging/2, [], NonHttpListeners),
    case lists:foldl(fun ok_or_first_error/2, ok, Results) of
        ok ->
            ?LOG_DEBUG("rqm: successfully suspended ~b non-HTTP listeners", [
                length(NonHttpListeners)
            ]),
            {ok, NonHttpListeners};
        Error ->
            ?LOG_ERROR("rqm: failed to suspend some non-HTTP listeners: ~p", [Error]),
            {error, Error}
    end.

%% @doc Close all client connections
%% This function is designed for EBS snapshot preparation where we need to:
%% - Block AMQP connections to ensure data consistency
%% - Keep HTTP API available for monitoring and control
%% Returns {ok, ConnectionCount} on success
-spec close_all_client_connections() -> {'ok', non_neg_integer()}.
close_all_client_connections() ->
    Pids = rabbit_networking:local_connections(),
    ok = rabbit_networking:close_connections(Pids, "rqm: preparation"),
    {ok, length(Pids)}.

%% @doc Resume previously suspended non-HTTP listeners
%% This function resumes listeners that were suspended by suspend_non_http_listeners/0
%% Takes a list of listeners returned by the suspend function
%% Returns {ok, ResumedListeners} on success, {error, Reason} on failure
-spec resume_non_http_listeners([rabbit_types:listener()]) ->
    {ok, [rabbit_types:listener()]} | {error, term()}.
resume_non_http_listeners(SuspendedListeners) ->
    ?LOG_DEBUG("rqm: resuming ~b previously suspended non-HTTP listeners", [
        length(SuspendedListeners)
    ]),

    Results = lists:foldl(fun resume_listener_with_logging/2, [], SuspendedListeners),
    case lists:foldl(fun ok_or_first_error/2, ok, Results) of
        ok ->
            ?LOG_DEBUG("rqm: successfully resumed ~b non-HTTP listeners", [
                length(SuspendedListeners)
            ]),
            {ok, SuspendedListeners};
        Error ->
            ?LOG_ERROR("rqm: failed to resume some non-HTTP listeners: ~p", [Error]),
            {error, Error}
    end.

%% @doc Resume all non-HTTP listeners on the current node
%% This is a convenience function that doesn't require the original suspended listener list
%% It finds all non-HTTP listeners and attempts to resume them
%% Returns {ok, ResumedListeners} on success, {error, Reason} on failure
-spec resume_all_non_http_listeners() -> {ok, [rabbit_types:listener()]} | {error, term()}.
resume_all_non_http_listeners() ->
    AllListeners = rabbit_networking:node_listeners(node()),
    NonHttpListeners = lists:filter(fun is_non_http_listener/1, AllListeners),
    resume_non_http_listeners(NonHttpListeners).

%% @doc Check if a listener is NOT an HTTP/HTTPS protocol listener
%% Returns true for listeners that should be suspended (non-HTTP protocols)
%% Excludes HTTP, HTTPS, and clustering protocols
-spec is_non_http_listener(rabbit_types:listener()) -> boolean().
is_non_http_listener(#listener{protocol = http}) -> false;
is_non_http_listener(#listener{protocol = https}) -> false;
is_non_http_listener(#listener{protocol = clustering}) -> false;
is_non_http_listener(_) -> true.

%% @doc Suspend a single listener on the current node with detailed logging
%% Returns ok on success, {error, Reason} on failure
-spec suspend_listener_with_logging(rabbit_types:listener(), [term()]) -> [term()].
suspend_listener_with_logging(
    #listener{
        node = Node,
        protocol = Protocol,
        host = Host,
        port = Port,
        ip_address = Addr
    },
    Acc
) when Node =:= node() ->
    RanchRef = rabbit_networking:ranch_ref(Addr, Port),
    case ranch:suspend_listener(RanchRef) of
        ok ->
            ?LOG_DEBUG("rqm: suspended ~p listener on ~s:~p", [Protocol, Host, Port]),
            [ok | Acc];
        Error ->
            ?LOG_WARNING(
                "rqm: failed to suspend ~p listener on ~s:~p: ~p",
                [Protocol, Host, Port, Error]
            ),
            [Error | Acc]
    end;
suspend_listener_with_logging(#listener{node = _OtherNode}, Acc) ->
    Acc.

%% @doc Resume a single listener on the current node with detailed logging
%% Returns ok on success, {error, Reason} on failure
-spec resume_listener_with_logging(rabbit_types:listener(), [term()]) -> [term()].
resume_listener_with_logging(
    #listener{
        node = Node,
        protocol = Protocol,
        host = Host,
        port = Port,
        ip_address = Addr
    },
    Acc
) when Node =:= node() ->
    RanchRef = rabbit_networking:ranch_ref(Addr, Port),
    case ranch:resume_listener(RanchRef) of
        ok ->
            ?LOG_DEBUG("rqm: resumed ~p listener on ~s:~p", [Protocol, Host, Port]),
            [ok | Acc];
        Error ->
            ?LOG_WARNING(
                "queue_migration: failed to resume ~p listener on ~s:~p: ~p",
                [Protocol, Host, Port, Error]
            ),
            [Error | Acc]
    end;
resume_listener_with_logging(#listener{node = _OtherNode}, Acc) ->
    Acc.

%% @doc Helper function to accumulate errors, returning the first error encountered
%% Returns ok if all operations succeeded, or the first error
-spec ok_or_first_error(term(), ok | {error, term()}) -> ok | {error, term()}.
ok_or_first_error(ok, Acc) ->
    Acc;
ok_or_first_error(Error, ok) ->
    Error;
ok_or_first_error(_Error, FirstError) ->
    FirstError.

-spec format_iso8601_utc() -> io_lib:chars().
format_iso8601_utc() ->
    {{Year, Month, Day}, {Hour, Min, Sec}} = calendar:universal_time(),
    % For fractional seconds, you would also need to get milliseconds/microseconds
    % and format them accordingly, e.g., ".sss"
    io_lib:format(
        "~.4.0w-~.2.0w-~.2.0wT~.2.0w-~.2.0w-~.2.0wZ",
        [Year, Month, Day, Hour, Min, Sec]
    ).

-spec filter_by_queue_names([rabbit_types:amqqueue()], undefined | [binary()]) ->
    [rabbit_types:amqqueue()].
filter_by_queue_names(Queues, undefined) ->
    Queues;
filter_by_queue_names(Queues, QueueNames) when is_list(QueueNames) ->
    FilteredQueues = [
        Q
     || Q <- Queues,
        begin
            #resource{name = QName} = amqqueue:get_name(Q),
            lists:member(QName, QueueNames)
        end
    ],
    SpecifiedButNotFound =
        QueueNames --
            [
                begin
                    #resource{name = QName} = amqqueue:get_name(Q),
                    QName
                end
             || Q <- FilteredQueues
            ],
    [
        ?LOG_WARNING("rqm: specified queue '~ts' not found or not eligible for migration", [QName])
     || QName <- SpecifiedButNotFound
    ],
    FilteredQueues.
