%% Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
%% SPDX-License-Identifier: Apache-2.0
%% vim:ft=erlang:
%% -*- mode: erlang; -*-

%% @doc Top-level supervisor for the rabbitmq_queue_migration plugin.
%%
%% Supervises:
%%   * rqm_init_state: gen_server that drives async Mnesia table setup
%%     and exposes the plugin's init status to callers (HTTP layer).
%%   * worker_pool_sup: existing rabbit_common worker pool, used by the
%%     migration runtime for parallel per-queue work.
%%
%% Children are started in the order listed: rqm_init_state first (so its
%% status is reachable as soon as possible), worker_pool_sup second. Both
%% are transient: a normal termination is not restarted, but a crash is.

-module(rqm_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) ->
    {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 3600
    },
    InitState = #{
        id => rqm_init_state,
        start => {rqm_init_state, start_link, []},
        restart => transient,
        shutdown => 5000,
        type => worker,
        modules => [rqm_init_state]
    },
    WorkerPool = #{
        id => worker_pool_sup,
        start =>
            {worker_pool_sup, start_link, [
                rqm_config:calculate_worker_pool_size(),
                rqm_config:worker_pool_name()
            ]},
        restart => transient,
        shutdown => infinity,
        type => supervisor,
        modules => [worker_pool_sup]
    },
    {ok, {SupFlags, [InitState, WorkerPool]}}.
