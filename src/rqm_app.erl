%% Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
%% SPDX-License-Identifier: Apache-2.0
%% vim:ft=erlang:
%% -*- mode: erlang; -*-

%% @doc Plugin application callback module.
%%
%% start/2 is intentionally kept thin: it calls rqm_config:setup_defaults/0
%% (idempotent application:set_env calls) and starts rqm_sup. All Mnesia
%% table setup is handled asynchronously by rqm_init_state under rqm_sup,
%% so this module never blocks on broker boot.
%%
%% Any failure in start/2 is logged and converted to `ignore`, which is a
%% documented application:start/2 return that means "started ok, no top
%% supervisor". The application controller does not treat `ignore` as an
%% error, so the broker continues to boot. This is the belt-and-braces
%% guarantee that a plugin start failure NEVER aborts broker boot.

-module(rqm_app).

-include_lib("kernel/include/logger.hrl").

-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) ->
    {ok, pid()} | ignore.
start(_Type, _StartArgs) ->
    try
        ok = rqm_config:setup_defaults(),
        case rqm_sup:start_link() of
            {ok, Pid} ->
                {ok, Pid};
            ignore ->
                ?LOG_ERROR("rqm: rqm_sup:start_link/0 returned `ignore`"),
                ignore;
            {error, Reason} ->
                ?LOG_ERROR(
                    "rqm: rqm_sup:start_link/0 returned {error, ~tp}",
                    [Reason]
                ),
                ignore
        end
    catch
        Class:CaughtReason:Stack ->
            ?LOG_ERROR(
                "rqm: application start raised ~tp:~tp~n~tp",
                [Class, CaughtReason, Stack]
            ),
            ignore
    end.

-spec stop(term()) -> ok.
stop(_State) ->
    ok.
