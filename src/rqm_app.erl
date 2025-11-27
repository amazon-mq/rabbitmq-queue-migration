%% Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
%% SPDX-License-Identifier: Apache-2.0
%% vim:ft=erlang:
%% -*- mode: erlang; -*-

-module(rqm_app).

-include("rqm.hrl").

-include_lib("kernel/include/logger.hrl").

-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) ->
    {ok, pid()} | {ok, pid(), State :: term()} | {error, Reason :: term()}.
start(_Type, _StartArgs) ->
    ok = setup_schema(),
    ok = setup_default_config(),
    WorkerPoolSize = rqm_config:calculate_worker_pool_size(),
    ?LOG_INFO("rqm: starting worker pool with size ~tp on node ~tp", [WorkerPoolSize, node()]),
    worker_pool_sup:start_link(WorkerPoolSize, rqm_config:worker_pool_name()).

-spec stop(Application) -> ok | {error, Reason} when Application :: atom(), Reason :: term().
stop(_State) ->
    ok.

%%----------------------------------------------------------------------------

setup_schema() ->
    ?LOG_INFO("rqm: setting up schema"),
    Tables =
        [
            {queue_migration, [
                {record_name, queue_migration},
                {attributes, record_info(fields, queue_migration)},
                {disc_copies, [node()]},
                {type, set}
            ]},
            {queue_migration_status, [
                {record_name, queue_migration_status},
                {attributes, record_info(fields, queue_migration_status)},
                {disc_copies, [node()]},
                {type, ordered_set}
            ]}
        ],
    lists:foreach(
        fun({Table, Def}) -> ok = rabbit_table:create(Table, Def) end,
        Tables
    ),
    TableNames = [queue_migration, queue_migration_status],
    ok = rabbit_table:wait(TableNames).

setup_default_config() ->
    rqm_config:setup_defaults().
