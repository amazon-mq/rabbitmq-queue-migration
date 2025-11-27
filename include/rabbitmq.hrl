%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2025 Broadcom. All Rights Reserved. The term “Broadcom” refers to Broadcom Inc. and/or its subsidiaries. All rights reserved.
%%

-record(if_data_matches, {
    pattern = '_' :: ets:match_pattern() | term(),
    conditions = [] :: [any()],
    compiled = undefined :: ets:comp_match_spec() | undefined
}).

-record(if_path_matches, {
    regex = any :: any | iodata() | unicode:charlist(),
    compiled = undefined ::
        khepri_condition:re_compile_ret()
        | undefined
}).

-record(amqqueue, {
    %% immutable
    name :: rabbit_amqqueue:name() | ets:match_pattern(),
    %% immutable
    durable :: boolean() | ets:match_pattern(),
    %% immutable
    auto_delete :: boolean() | ets:match_pattern(),
    %% immutable
    exclusive_owner = none :: pid() | none | ets:match_pattern(),
    %% immutable
    arguments = [] :: rabbit_framing:amqp_table() | ets:match_pattern(),
    %% durable (just so we know home node)
    pid :: pid() | ra_server_id() | none | ets:match_pattern(),
    %% transient
    slave_pids = [] :: [pid()] | none | ets:match_pattern(),
    %% transient
    sync_slave_pids = [] :: [pid()] | none | ets:match_pattern(),
    %% durable
    recoverable_slaves = [] :: [atom()] | none | ets:match_pattern(),
    %% durable, implicit update as above
    policy :: proplists:proplist() | none | undefined | ets:match_pattern(),
    %% durable, implicit update as above
    operator_policy :: proplists:proplist() | none | undefined | ets:match_pattern(),
    %% transient
    gm_pids = [] :: [{pid(), pid()}] | none | ets:match_pattern(),
    %% transient, recalculated as above
    decorators :: [atom()] | none | undefined | ets:match_pattern(),
    %% durable (have we crashed?)
    state = live :: atom() | none | ets:match_pattern(),
    policy_version = 0 :: non_neg_integer() | ets:match_pattern(),
    slave_pids_pending_shutdown = [] :: [pid()] | ets:match_pattern(),
    %% secondary index
    vhost :: rabbit_types:vhost() | undefined | ets:match_pattern(),
    options = #{} :: map() | ets:match_pattern(),
    type = rabbit_classic_queue :: module() | ets:match_pattern(),
    type_state = #{} :: map() | ets:match_pattern()
}).

-type ra_server_id() :: {Name :: atom(), Node :: node()}.

-type amqqueue_pattern() :: amqqueue_v2_pattern().
-type amqqueue_v2_pattern() :: #amqqueue{
    name :: rabbit_amqqueue:name() | ets:match_pattern(),
    durable :: ets:match_pattern(),
    auto_delete :: ets:match_pattern(),
    exclusive_owner :: ets:match_pattern(),
    arguments :: ets:match_pattern(),
    pid :: ets:match_pattern(),
    slave_pids :: ets:match_pattern(),
    sync_slave_pids :: ets:match_pattern(),
    recoverable_slaves :: ets:match_pattern(),
    policy :: ets:match_pattern(),
    operator_policy :: ets:match_pattern(),
    gm_pids :: ets:match_pattern(),
    decorators :: ets:match_pattern(),
    state :: ets:match_pattern(),
    policy_version :: ets:match_pattern(),
    slave_pids_pending_shutdown :: ets:match_pattern(),
    vhost :: ets:match_pattern(),
    options :: ets:match_pattern(),
    type :: atom() | ets:match_pattern(),
    type_state :: ets:match_pattern()
}.
