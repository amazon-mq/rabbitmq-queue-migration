%% Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
%% SPDX-License-Identifier: Apache-2.0
%% vim:ft=erlang:
%% -*- mode: erlang; -*-

-module(rqm_compat_checker_mgmt).

-behaviour(rabbit_mgmt_extension).

-export([dispatcher/0, web_ui/0, accept_content/2]).
-export([
    init/2,
    content_types_accepted/2,
    content_types_provided/2,
    allowed_methods/2,
    resource_exists/2,
    is_authorized/2
]).

-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbitmq_management_agent/include/rabbit_mgmt_records.hrl").

dispatcher() -> [{"/queue-compatibility/check/:vhost", ?MODULE, []}].

web_ui() -> [{javascript, <<"queue-compatibility.js">>}].

%%--------------------------------------------------------------------

init(Req, _State) ->
    {cowboy_rest, rabbit_mgmt_headers:set_common_permission_headers(Req, ?MODULE), #context{}}.

content_types_accepted(ReqData, Context) ->
    {[{'*', accept_content}], ReqData, Context}.

content_types_provided(ReqData, Context) ->
    {[{<<"application/json">>, to_json}], ReqData, Context}.

allowed_methods(ReqData, Context) ->
    {[<<"POST">>, <<"HEAD">>, <<"OPTIONS">>], ReqData, Context}.

resource_exists(ReqData, Context) ->
    {true, ReqData, Context}.

is_authorized(ReqData, Context) ->
    rabbit_mgmt_util:is_authorized_monitor(ReqData, Context).

accept_content(ReqData, Context) ->
    VHost =
        case cowboy_req:binding(vhost, ReqData) of
            <<"all">> -> all_vhosts;
            undefined -> <<"/">>;
            _VHostName -> rabbit_mgmt_util:id(vhost, ReqData)
        end,

    % Parse options from request body
    OptsMap = parse_compatibility_options(ReqData),

    case VHost of
        all_vhosts ->
            % Handle all vhosts case - run migration readiness for each
            AllVhosts = [VH || VH <- rabbit_vhost:list()],
            Results = lists:map(
                fun(VH) ->
                    RawResult = rqm_compat_checker:check_migration_readiness(VH, OptsMap),
                    format_migration_readiness_response(RawResult)
                end,
                AllVhosts
            ),

            Json = rabbit_json:encode(#{
                vhost => <<"all">>,
                vhost_results => Results
            }),
            {true, cowboy_req:set_resp_body(Json, ReqData), Context};
        _ ->
            % Single vhost - run complete migration readiness check
            Result = rqm_compat_checker:check_migration_readiness(VHost, OptsMap),

            % Format for JSON response
            FormattedResult = format_migration_readiness_response(Result),
            Json = rabbit_json:encode(FormattedResult),
            {true, cowboy_req:set_resp_body(Json, ReqData), Context}
    end.

%% Helper functions

sort_queue_results(Results) ->
    lists:sort(
        fun({QueueResourceA, _}, {QueueResourceB, _}) ->
            NameA = QueueResourceA#resource.name,
            NameB = QueueResourceB#resource.name,
            VHostA = QueueResourceA#resource.virtual_host,
            VHostB = QueueResourceB#resource.virtual_host,
            % Sort by vhost first, then by queue name
            case VHostA =:= VHostB of
                true -> NameA =< NameB;
                false -> VHostA =< VHostB
            end
        end,
        Results
    ).

format_queue_result(QueueResource, {compatible, _}) ->
    #{
        name => QueueResource#resource.name,
        vhost => QueueResource#resource.virtual_host,
        compatible => true,
        issues => []
    };
format_queue_result(QueueResource, {incompatible, Issues}) ->
    #{
        name => QueueResource#resource.name,
        vhost => QueueResource#resource.virtual_host,
        compatible => false,
        issues => format_issues(Issues)
    }.

format_issues(Issues) ->
    [format_issue(Issue) || Issue <- Issues].

format_issue({exclusive, Reason}) ->
    #{
        type => <<"exclusive">>,
        reason => list_to_binary(Reason)
    };
format_issue({unsupported_argument, ArgName, Reason}) ->
    #{
        type => <<"unsupported_argument">>,
        argument => ArgName,
        reason => list_to_binary(Reason)
    };
format_issue({max_priority, Reason}) ->
    #{
        type => <<"max_priority">>,
        reason => list_to_binary(Reason)
    };
format_issue({lazy_mode, Reason}) ->
    #{
        type => <<"lazy_mode">>,
        reason => list_to_binary(Reason)
    };
format_issue({overflow_behavior, Reason}) ->
    #{
        type => <<"overflow_behavior">>,
        reason => list_to_binary(Reason)
    };
format_issue({message_count_limit, Reason}) ->
    #{
        type => <<"message_count_limit">>,
        reason => list_to_binary(Reason)
    };
format_issue({data_size_limit, Reason}) ->
    #{
        type => <<"data_size_limit">>,
        reason => list_to_binary(Reason)
    };
format_issue({too_many_queues, Reason}) ->
    #{
        type => <<"too_many_queues">>,
        reason => list_to_binary(Reason)
    };
format_issue({incompatible_overflow, Reason}) ->
    #{
        type => <<"incompatible_overflow">>,
        reason => list_to_binary(Reason)
    };
format_issue({Type, Reason}) ->
    #{
        type => atom_to_binary(Type, utf8),
        reason => list_to_binary(Reason)
    }.

format_migration_readiness_response(#{
    vhost := VHost,
    overall_ready := OverallReady,
    skip_unsuitable_queues := SkipUnsuitableQueues,
    system_checks := SystemChecks,
    queue_checks := QueueChecks
}) ->
    #{
        vhost => VHost,
        overall_ready => OverallReady,
        skip_unsuitable_queues => SkipUnsuitableQueues,
        system_checks => format_system_checks_for_ui(SystemChecks),
        queue_checks => format_queue_checks_for_ui(QueueChecks)
    }.

format_system_checks_for_ui(#{all_passed := AllPassed, checks := Checks}) ->
    #{
        all_passed => AllPassed,
        checks => [format_system_check(Check) || Check <- Checks]
    }.

format_system_check(#{check_type := CheckType, status := Status, message := Message}) ->
    #{
        check_type => CheckType,
        status => Status,
        message => Message
    }.

format_queue_checks_for_ui(#{summary := Summary, results := Results}) ->
    case Results of
        [] ->
            % No incompatible queues - return empty results
            #{
                summary => Summary,
                results => []
            };
        _ ->
            % Sort results before formatting
            SortedResults = sort_queue_results(Results),
            % Convert results to JSON format
            FormattedResults = [
                format_queue_result(QueueResource, Result)
             || {QueueResource, Result} <- SortedResults
            ],
            #{
                summary => Summary,
                results => FormattedResults
            }
    end.

parse_compatibility_options(ReqData) ->
    case cowboy_req:has_body(ReqData) of
        true ->
            {ok, Body, _} = cowboy_req:read_body(ReqData),
            case Body of
                <<>> ->
                    #{};
                _ ->
                    case rabbit_json:try_decode(Body) of
                        {ok, Json} when is_map(Json) ->
                            case maps:get(<<"skip_unsuitable_queues">>, Json, false) of
                                true -> #{skip_unsuitable_queues => true};
                                false -> #{skip_unsuitable_queues => false};
                                _ -> #{}
                            end;
                        _ ->
                            #{}
                    end
            end;
        false ->
            #{}
    end.
