%% Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
%% SPDX-License-Identifier: Apache-2.0
%% vim:ft=erlang:
%% -*- mode: erlang; -*-

%% @doc Plugin initialisation state machine.
%%
%% Holds the plugin's init status across boot and exposes it via gen_server
%% calls for use by the HTTP layer (rqm_mgmt:service_available/2). The
%% state machine is:
%%
%%     initializing --(schema setup ok)--> ready
%%     initializing --(attempts exhausted)--> failed
%%
%% While `initializing` or `failed`, callers see `service_available/2`
%% return false and the plugin's HTTP routes return 503 with a JSON body
%% built from `status_detail/0`.
%%
%% Schema setup (rabbit_table:create + rabbit_table:wait) runs in
%% handle_info/2 so that init/1 returns immediately and never blocks the
%% supervisor. Each failed attempt schedules the next via send_after/3
%% (NOT the gen_server timeout mechanism, which is cancelled by any
%% incoming message and is therefore unreliable in the presence of
%% management-UI polling for status).
%%
%% Recovery from `failed` is by `rabbitmq-plugins disable
%% rabbitmq_queue_migration` followed by `rabbitmq-plugins enable
%% rabbitmq_queue_migration`. There is no in-process retry endpoint.

-module(rqm_init_state).

-behaviour(gen_server).

-include("rqm.hrl").
-include_lib("kernel/include/logger.hrl").

%% Public API
-export([
    start_link/0,
    status/0,
    status_detail/0
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {
    status :: initializing | ready | failed,
    attempts = 0 :: non_neg_integer(),
    started_at :: integer(),
    failed_at :: undefined | integer(),
    last_error :: undefined | term()
}).

-define(ATTEMPT_MSG, attempt).

%%----------------------------------------------------------------------------
%% Public API
%%----------------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Returns the current init state.
-spec status() -> initializing | ready | failed.
status() ->
    gen_server:call(?MODULE, status).

%% @doc Returns a JSON-shaped map describing the init state, suitable for
%% use as the body of a 503 response. When the status is `ready`, returns
%% the atom `ready` so callers can short-circuit.
-spec status_detail() -> ready | map().
status_detail() ->
    gen_server:call(?MODULE, status_detail).

%%----------------------------------------------------------------------------
%% gen_server callbacks
%%----------------------------------------------------------------------------

init([]) ->
    State = #state{
        status = initializing,
        attempts = 0,
        started_at = erlang:system_time(millisecond)
    },
    %% Kick off the first attempt asynchronously so init/1 returns
    %% immediately. The message is in our own mailbox before the
    %% gen_server starts processing, so it will be the first message
    %% handled.
    self() ! ?ATTEMPT_MSG,
    {ok, State}.

handle_call(status, _From, State = #state{status = S}) ->
    {reply, S, State};
handle_call(status_detail, _From, State = #state{status = ready}) ->
    {reply, ready, State};
handle_call(status_detail, _From, State) ->
    {reply, build_status_detail(State), State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(?ATTEMPT_MSG, State = #state{status = initializing, attempts = N}) when
    N < ?INIT_RETRY_ATTEMPTS
->
    case try_setup_schema() of
        ok ->
            ?LOG_INFO(
                "rqm: tables ready (attempt ~tp/~tp)",
                [N + 1, ?INIT_RETRY_ATTEMPTS]
            ),
            {noreply, State#state{status = ready}};
        {error, Reason} ->
            ?LOG_WARNING(
                "rqm: schema setup attempt ~tp/~tp failed: ~tp",
                [N + 1, ?INIT_RETRY_ATTEMPTS, Reason]
            ),
            schedule_next_attempt(),
            {noreply, State#state{
                attempts = N + 1,
                last_error = Reason
            }}
    end;
handle_info(?ATTEMPT_MSG, State = #state{status = initializing}) ->
    %% Attempts exhausted. Move to terminal `failed` state. Recovery
    %% requires plugin disable/enable.
    ?LOG_ERROR(
        "rqm: schema setup failed after ~tp attempts; plugin entering "
        "`failed` state. Last error: ~tp. To retry, run "
        "`rabbitmq-plugins disable rabbitmq_queue_migration` then "
        "`rabbitmq-plugins enable rabbitmq_queue_migration`.",
        [?INIT_RETRY_ATTEMPTS, State#state.last_error]
    ),
    {noreply, State#state{
        status = failed,
        failed_at = erlang:system_time(millisecond)
    }};
handle_info(?ATTEMPT_MSG, State) ->
    %% Stray attempt message after we have already reached a terminal
    %% state. Ignore.
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%----------------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------------

schedule_next_attempt() ->
    erlang:send_after(?INIT_RETRY_INTERVAL_MS, self(), ?ATTEMPT_MSG),
    ok.

try_setup_schema() ->
    try
        ?LOG_DEBUG("rqm: setting up schema"),
        Tables = [
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
        ok = rabbit_table:wait(TableNames)
    catch
        _:Reason ->
            {error, Reason}
    end.

build_status_detail(#state{
    status = S,
    attempts = A,
    started_at = Started,
    failed_at = Failed,
    last_error = Err
}) ->
    Base = #{
        status => atom_to_binary(S),
        attempts => A,
        max_attempts => ?INIT_RETRY_ATTEMPTS,
        started_at => format_ts(Started)
    },
    Base1 =
        case Failed of
            undefined -> Base;
            _ -> Base#{failed_at => format_ts(Failed)}
        end,
    case S =:= failed andalso Err =/= undefined of
        true -> Base1#{error => format_error(Err)};
        false -> Base1
    end.

format_ts(Millis) when is_integer(Millis) ->
    rqm_util:to_unicode(
        calendar:system_time_to_rfc3339(
            Millis,
            [{unit, millisecond}, {offset, "Z"}]
        )
    ).

format_error(Reason) ->
    rqm_util:unicode_format("~tp", [Reason]).
