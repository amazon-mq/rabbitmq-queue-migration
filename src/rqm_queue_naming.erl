%% Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
%% SPDX-License-Identifier: Apache-2.0
%% vim:ft=erlang:
%% -*- mode: erlang; -*-

-module(rqm_queue_naming).

-export([
    add_temp_prefix/2,
    remove_temp_prefix/2
]).

%% @doc Add temporary prefix to queue name using migration ID timestamp
%% Creates name in format: tmp_<timestamp>_<original_name>
%% This ensures uniqueness even if original name starts with tmp_
-spec add_temp_prefix(binary(), {integer(), atom()}) -> binary().
add_temp_prefix(OriginalName, {Timestamp, _Node}) when is_binary(OriginalName), is_integer(Timestamp) ->
    TimestampBin = integer_to_binary(Timestamp),
    <<"tmp_", TimestampBin/binary, "_", OriginalName/binary>>.

%% @doc Remove temporary prefix from queue name using migration ID timestamp
%% Extracts original name by matching the exact timestamp prefix
%% This ensures we only remove the prefix we added, even if original name contains tmp_
-spec remove_temp_prefix(binary(), {integer(), atom()}) -> binary().
remove_temp_prefix(TempName, {Timestamp, _Node}) when is_binary(TempName), is_integer(Timestamp) ->
    TimestampBin = integer_to_binary(Timestamp),
    PrefixLen = byte_size(<<"tmp_">>) + byte_size(TimestampBin) + byte_size(<<"_">>),
    <<_Prefix:PrefixLen/binary, OriginalName/binary>> = TempName,
    OriginalName.
