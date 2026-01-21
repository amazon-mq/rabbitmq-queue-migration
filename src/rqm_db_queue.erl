%% Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
%% SPDX-License-Identifier: Apache-2.0
%% vim:ft=erlang:
%% -*- mode: erlang; -*-

-module(rqm_db_queue).

-include("rabbitmq.hrl").
-include_lib("stdlib/include/qlc.hrl").

-export([get_all_by_vhost_and_type/2, get_all_by_type_and_node/2]).

-define(MNESIA_TABLE, rabbit_queue).
-define(MNESIA_DURABLE_TABLE, rabbit_durable_queue).
-define(KHEPRI_WILDCARD_STAR_STAR, #if_path_matches{regex = any}).

-spec get_all_by_vhost_and_type(VHostName, Type) -> [Queue] when
    VHostName :: vhost:name(),
    Type :: atom(),
    Queue :: amqqueue:amqqueue().
get_all_by_vhost_and_type(VHostName, Type) ->
    Pattern = pattern_match_on_name_and_type(rabbit_misc:r(VHostName, queue), Type),
    rabbit_khepri:handle_fallback(
        #{
            mnesia => fun() -> get_all_by_pattern_in_mnesia(Pattern) end,
            khepri => fun() -> get_all_by_pattern_in_khepri(Pattern) end
        }
    ).

get_all_by_pattern_in_mnesia(Pattern) ->
    rabbit_db:list_in_mnesia(?MNESIA_TABLE, Pattern).

get_all_by_pattern_in_khepri(Pattern) ->
    rabbit_db:list_in_khepri(
        khepri_queues_path() ++
            [
                rabbit_khepri:if_has_data([
                    ?KHEPRI_WILDCARD_STAR_STAR, #if_data_matches{pattern = Pattern}
                ])
            ]
    ).

-spec get_all_by_type_and_node(Type, Node) -> [Queue] when
    Type :: atom(),
    Node :: 'none' | atom(),
    Queue :: amqqueue:amqqueue().
get_all_by_type_and_node(Type, Node) ->
    rabbit_khepri:handle_fallback(
        #{
            mnesia => fun() -> get_all_by_type_and_node_in_mnesia(Type, Node) end,
            khepri => fun() -> get_all_by_type_and_node_in_khepri(Type, Node) end
        }
    ).

get_all_by_type_and_node_in_mnesia(Type, Node) ->
    mnesia:async_dirty(
        fun() ->
            qlc:e(
                qlc:q([
                    Q
                 || Q <- mnesia:table(?MNESIA_DURABLE_TABLE),
                    amqqueue:get_type(Q) =:= Type,
                    amqqueue:qnode(Q) == Node
                ])
            )
        end
    ).

get_all_by_type_and_node_in_khepri(Type, Node) ->
    Pattern = amqqueue:pattern_match_on_type(Type),
    Qs = rabbit_db:list_in_khepri(
        khepri_queues_path() ++
            [
                rabbit_khepri:if_has_data([
                    ?KHEPRI_WILDCARD_STAR_STAR, #if_data_matches{pattern = Pattern}
                ])
            ]
    ),
    [Q || Q <- Qs, amqqueue:qnode(Q) == Node].

-spec pattern_match_on_name_and_type(Name, Type) -> Pattern when
    Name :: rabbit_amqqueue:name() | ets:match_pattern(),
    Type :: atom(),
    Pattern :: amqqueue_pattern().
pattern_match_on_name_and_type(Name, Type) ->
    #amqqueue{name = Name, type = Type, _ = '_'}.

khepri_queues_path() ->
    [?MODULE, queues].
