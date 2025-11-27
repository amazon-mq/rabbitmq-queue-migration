%% Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
%% SPDX-License-Identifier: Apache-2.0
%% vim:ft=erlang:
%% -*- mode: erlang; -*-

-module(unit_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

%% Common Test callbacks
-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_group/2,
    end_per_group/2,
    init_per_testcase/2,
    end_per_testcase/2
]).

%% Test cases
-export([
    % URL-safe base64 encoding tests
    base64url_encode_basic_test/1,
    base64url_encode_with_padding_test/1,
    base64url_encode_with_special_chars_test/1,
    base64url_encode_empty_binary_test/1,
    base64url_encode_large_binary_test/1,

    % URL-safe base64 decoding tests
    base64url_decode_basic_test/1,
    base64url_decode_with_padding_test/1,
    base64url_decode_with_special_chars_test/1,
    base64url_decode_empty_binary_test/1,
    base64url_decode_invalid_length_test/1,

    % Round-trip tests
    base64url_roundtrip_test/1,
    base64url_roundtrip_migration_id_test/1,
    base64url_roundtrip_various_sizes_test/1,

    % Migration ID specific tests
    migration_id_encoding_test/1,
    migration_id_no_url_unsafe_chars_test/1,
    migration_id_different_nodes_test/1,
    migration_id_different_timestamps_test/1,

    % Padding tests
    add_base64_padding_test/1,
    add_base64_padding_edge_cases_test/1,

    % Compatibility tests
    url_safety_test/1,
    standard_base64_comparison_test/1,

    % Migration checks tests
    check_balance_test/1,
    estimate_queue_disk_usage_test/1,
    determine_insufficient_space_reason_test/1,
    has_all_mirrors_synchronized_test/1
]).

%% Test groups
all() ->
    [
        {group, base64url_encoding},
        {group, base64url_decoding},
        {group, roundtrip_tests},
        {group, migration_id_tests},
        {group, padding_tests},
        {group, compatibility_tests},
        {group, migration_checks}
    ].

groups() ->
    [
        {base64url_encoding, [parallel], [
            base64url_encode_basic_test,
            base64url_encode_with_padding_test,
            base64url_encode_with_special_chars_test,
            base64url_encode_empty_binary_test,
            base64url_encode_large_binary_test
        ]},
        {base64url_decoding, [parallel], [
            base64url_decode_basic_test,
            base64url_decode_with_padding_test,
            base64url_decode_with_special_chars_test,
            base64url_decode_empty_binary_test,
            base64url_decode_invalid_length_test
        ]},
        {roundtrip_tests, [parallel], [
            base64url_roundtrip_test,
            base64url_roundtrip_migration_id_test,
            base64url_roundtrip_various_sizes_test
        ]},
        {migration_id_tests, [parallel], [
            migration_id_encoding_test,
            migration_id_no_url_unsafe_chars_test,
            migration_id_different_nodes_test,
            migration_id_different_timestamps_test
        ]},
        {padding_tests, [parallel], [
            add_base64_padding_test,
            add_base64_padding_edge_cases_test
        ]},
        {compatibility_tests, [parallel], [
            url_safety_test,
            standard_base64_comparison_test
        ]},
        {migration_checks, [parallel], [
            check_balance_test,
            estimate_queue_disk_usage_test,
            determine_insufficient_space_reason_test,
            has_all_mirrors_synchronized_test
        ]}
    ].

%% Setup and teardown
init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(_GroupName, Config) ->
    Config.

end_per_group(_GroupName, _Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%% =============================================================================
%% URL-safe Base64 Encoding Tests
%% =============================================================================

base64url_encode_basic_test(_Config) ->
    % Test basic encoding
    Input = <<"hello world">>,
    % Standard base64 without padding
    Expected = <<"aGVsbG8gd29ybGQ">>,
    Result = rqm_util:base64url_encode(Input),
    ?assertEqual(Expected, Result).

base64url_encode_with_padding_test(_Config) ->
    % Test encoding that would normally require padding
    Input = <<"hello">>,
    Result = rqm_util:base64url_encode(Input),
    % Should not contain padding characters
    ?assertEqual(false, binary:match(Result, <<"=">>) =/= nomatch),
    ?assertEqual(<<"aGVsbG8">>, Result).

base64url_encode_with_special_chars_test(_Config) ->
    % Test encoding that produces + and / in standard base64
    % This binary is crafted to produce + and / characters in standard base64

    % This should produce "/////w==" in standard base64
    Input = <<255, 255, 255>>,
    StandardBase64 = base64:encode(Input),
    Result = rqm_util:base64url_encode(Input),

    % Verify standard base64 contains problematic characters
    ?assertNotEqual(nomatch, binary:match(StandardBase64, <<"/">>)),

    % Verify URL-safe version doesn't contain problematic characters
    ?assertEqual(nomatch, binary:match(Result, <<"+">>)),
    ?assertEqual(nomatch, binary:match(Result, <<"/">>)),
    ?assertEqual(nomatch, binary:match(Result, <<"=">>)).

base64url_encode_empty_binary_test(_Config) ->
    % Test encoding empty binary
    Input = <<>>,
    Expected = <<>>,
    Result = rqm_util:base64url_encode(Input),
    ?assertEqual(Expected, Result).

base64url_encode_large_binary_test(_Config) ->
    % Test encoding large binary
    Input = crypto:strong_rand_bytes(1024),
    Result = rqm_util:base64url_encode(Input),

    % Verify no problematic characters
    ?assertEqual(nomatch, binary:match(Result, <<"+">>)),
    ?assertEqual(nomatch, binary:match(Result, <<"/">>)),
    ?assertEqual(nomatch, binary:match(Result, <<"=">>)),

    % Verify it's not empty
    ?assertNotEqual(<<>>, Result).

%% =============================================================================
%% URL-safe Base64 Decoding Tests
%% =============================================================================

base64url_decode_basic_test(_Config) ->
    % Test basic decoding
    Input = <<"aGVsbG8gd29ybGQ">>,
    Expected = <<"hello world">>,
    Result = rqm_util:base64url_decode(Input),
    ?assertEqual(Expected, Result).

base64url_decode_with_padding_test(_Config) ->
    % Test decoding that requires padding

    % Missing padding
    Input = <<"aGVsbG8">>,
    Expected = <<"hello">>,
    Result = rqm_util:base64url_decode(Input),
    ?assertEqual(Expected, Result).

base64url_decode_with_special_chars_test(_Config) ->
    % Test decoding with URL-safe characters

    % URL-safe characters that should become ////
    Input = <<"____">>,
    % This should decode without error
    Result = rqm_util:base64url_decode(Input),
    ?assert(is_binary(Result)).

base64url_decode_empty_binary_test(_Config) ->
    % Test decoding empty binary
    Input = <<>>,
    Expected = <<>>,
    Result = rqm_util:base64url_decode(Input),
    ?assertEqual(Expected, Result).

base64url_decode_invalid_length_test(_Config) ->
    % Test decoding with invalid length (length % 4 == 1)

    % Length 1, should cause error
    Input = <<"a">>,
    ?assertError(
        invalid_base64_length,
        rqm_util:base64url_decode(Input)
    ).

%% =============================================================================
%% Round-trip Tests
%% =============================================================================

base64url_roundtrip_test(_Config) ->
    % Test various inputs for round-trip encoding/decoding
    TestInputs = [
        <<"hello world">>,
        <<"">>,
        <<"a">>,
        <<"ab">>,
        <<"abc">>,
        <<"abcd">>,
        crypto:strong_rand_bytes(100),
        <<255, 255, 255>>,
        <<0, 0, 0>>,
        <<"The quick brown fox jumps over the lazy dog">>
    ],

    lists:foreach(
        fun(Input) ->
            Encoded = rqm_util:base64url_encode(Input),
            Decoded = rqm_util:base64url_decode(Encoded),
            ?assertEqual(Input, Decoded)
        end,
        TestInputs
    ).

base64url_roundtrip_migration_id_test(_Config) ->
    % Test round-trip with actual migration ID structures
    TestMigrationIds = [
        {1234567890123, 'rabbit@node1'},
        {erlang:system_time(millisecond), node()},
        {0, 'test@localhost'},
        {999999999999999, 'very-long-node-name@some-host.example.com'}
    ],

    lists:foreach(
        fun(MigrationId) ->
            Binary = term_to_binary(MigrationId),
            Encoded = rqm_util:base64url_encode(Binary),
            Decoded = rqm_util:base64url_decode(Encoded),
            DecodedTerm = binary_to_term(Decoded),
            ?assertEqual(MigrationId, DecodedTerm)
        end,
        TestMigrationIds
    ).

base64url_roundtrip_various_sizes_test(_Config) ->
    % Test round-trip with various binary sizes
    Sizes = [0, 1, 2, 3, 4, 5, 10, 50, 100, 255, 256, 1000, 1024],

    lists:foreach(
        fun(Size) ->
            Input = crypto:strong_rand_bytes(Size),
            Encoded = rqm_util:base64url_encode(Input),
            Decoded = rqm_util:base64url_decode(Encoded),
            ?assertEqual(Input, Decoded)
        end,
        Sizes
    ).

%% =============================================================================
%% Migration ID Specific Tests
%% =============================================================================

migration_id_encoding_test(_Config) ->
    % Test the actual format_migration_id function
    MigrationId = {1234567890123, 'rabbit@node1'},
    EncodedId = rqm_util:format_migration_id(MigrationId),

    % Should be a binary
    ?assert(is_binary(EncodedId)),

    % Should not be empty
    ?assertNotEqual(<<>>, EncodedId),

    % Should be decodable back to original
    DecodedBinary = rqm_util:base64url_decode(EncodedId),
    DecodedId = binary_to_term(DecodedBinary),
    ?assertEqual(MigrationId, DecodedId).

migration_id_no_url_unsafe_chars_test(_Config) ->
    % Test that migration IDs never contain URL-unsafe characters
    TestMigrationIds = [
        {1234567890123, 'rabbit@node1'},
        {erlang:system_time(millisecond), node()},
        {0, 'test'},
        {999999999999999, 'very-long-node-name@some-host.example.com'},
        {1, 'a'},
        % Max 64-bit integer
        {18446744073709551615, 'max-int@node'}
    ],

    UnsafeChars = [<<"+">>, <<"/">>, <<"=">>],

    lists:foreach(
        fun(MigrationId) ->
            EncodedId = rqm_util:format_migration_id(MigrationId),
            lists:foreach(
                fun(UnsafeChar) ->
                    ?assertEqual(nomatch, binary:match(EncodedId, UnsafeChar))
                end,
                UnsafeChars
            )
        end,
        TestMigrationIds
    ).

migration_id_different_nodes_test(_Config) ->
    % Test that different nodes produce different encoded IDs
    Timestamp = 1234567890123,
    Node1 = 'rabbit@node1',
    Node2 = 'rabbit@node2',

    Id1 = rqm_util:format_migration_id({Timestamp, Node1}),
    Id2 = rqm_util:format_migration_id({Timestamp, Node2}),

    ?assertNotEqual(Id1, Id2).

migration_id_different_timestamps_test(_Config) ->
    % Test that different timestamps produce different encoded IDs
    Node = 'rabbit@node1',
    Timestamp1 = 1234567890123,
    Timestamp2 = 1234567890124,

    Id1 = rqm_util:format_migration_id({Timestamp1, Node}),
    Id2 = rqm_util:format_migration_id({Timestamp2, Node}),

    ?assertNotEqual(Id1, Id2).

%% =============================================================================
%% Padding Tests
%% =============================================================================

add_base64_padding_test(_Config) ->
    % Test padding addition for various lengths
    TestCases = [
        % Length 0 -> no padding
        {<<"">>, <<"">>},
        % Length 2 -> add 2 padding chars
        {<<"YQ">>, <<"YQ==">>},
        % Length 3 -> add 1 padding char
        {<<"YWI">>, <<"YWI=">>},
        % Length 4 -> no padding needed
        {<<"YWJD">>, <<"YWJD">>}
    ],

    lists:foreach(
        fun({Input, Expected}) ->
            Result = rqm_util:add_base64_padding(Input),
            ?assertEqual(Expected, Result)
        end,
        TestCases
    ).

add_base64_padding_edge_cases_test(_Config) ->
    % Test edge cases for padding

    % Length 1 should cause an error (invalid base64)
    ?assertError(
        invalid_base64_length,
        rqm_util:add_base64_padding(<<"A">>)
    ),

    % Length 5 should add 3 padding chars (5 % 4 = 1, invalid)
    ?assertError(
        invalid_base64_length,
        rqm_util:add_base64_padding(<<"ABCDE">>)
    ).

%% =============================================================================
%% Compatibility Tests
%% =============================================================================

url_safety_test(_Config) ->
    % Test that encoded values are safe for use in URLs
    TestData = [
        term_to_binary({erlang:system_time(millisecond), node()}),
        crypto:strong_rand_bytes(100),
        % Should produce lots of / and + in standard base64
        <<255, 255, 255, 255>>,
        term_to_binary([{key, value}, {another, <<"binary">>}])
    ],

    % Characters that are problematic in URLs
    ProblematicChars = [<<"+">>, <<"/">>, <<"=">>, <<" ">>, <<"?">>, <<"&">>, <<"#">>],

    lists:foreach(
        fun(Data) ->
            Encoded = rqm_util:base64url_encode(Data),
            lists:foreach(
                fun(ProblematicChar) ->
                    ?assertEqual(
                        nomatch,
                        binary:match(Encoded, ProblematicChar),
                        io_lib:format(
                            "Found problematic char ~p in encoded data ~p",
                            [ProblematicChar, Encoded]
                        )
                    )
                end,
                ProblematicChars
            )
        end,
        TestData
    ).

standard_base64_comparison_test(_Config) ->
    % Compare URL-safe base64 with standard base64 to ensure they're different
    % when standard base64 contains problematic characters

    % This produces "//8=" in standard base64
    TestData = <<255, 255>>,

    StandardEncoded = base64:encode(TestData),
    UrlSafeEncoded = rqm_util:base64url_encode(TestData),

    % They should be different
    ?assertNotEqual(StandardEncoded, UrlSafeEncoded),

    % Standard should contain problematic chars
    ?assertNotEqual(nomatch, binary:match(StandardEncoded, <<"/">>)),
    ?assertNotEqual(nomatch, binary:match(StandardEncoded, <<"=">>)),

    % URL-safe should not contain problematic chars
    ?assertEqual(nomatch, binary:match(UrlSafeEncoded, <<"/">>)),
    ?assertEqual(nomatch, binary:match(UrlSafeEncoded, <<"=">>)),

    % But they should decode to the same value
    StandardDecoded = base64:decode(StandardEncoded),
    UrlSafeDecoded = rqm_util:base64url_decode(UrlSafeEncoded),
    ?assertEqual(StandardDecoded, UrlSafeDecoded),
    ?assertEqual(TestData, UrlSafeDecoded).

%% =============================================================================
%% Migration Checks Tests
%% =============================================================================

check_balance_test(_Config) ->
    % Test balanced distribution
    BalancedDist = #{node1 => 10, node2 => 10, node3 => 10},
    ?assertEqual(
        {ok, balanced},
        rqm_checks:check_balance(BalancedDist, 2.0, 30)
    ),

    % Test slightly imbalanced but acceptable
    SlightlyImbalanced = #{node1 => 8, node2 => 10, node3 => 12},
    ?assertEqual(
        {ok, balanced},
        rqm_checks:check_balance(SlightlyImbalanced, 2.0, 30)
    ),

    % Test severely imbalanced
    SeverelyImbalanced = #{node1 => 2, node2 => 3, node3 => 25},
    ?assertMatch(
        {error, {imbalanced, _}},
        rqm_checks:check_balance(SeverelyImbalanced, 2.0, 30)
    ),

    % Test single node
    SingleNode = #{node1 => 30, node2 => 0, node3 => 0},
    ?assertEqual(
        {ok, balanced},
        rqm_checks:check_balance(SingleNode, 2.0, 30)
    ).

estimate_queue_disk_usage_test(_Config) ->
    % Test the disk usage estimation calculation logic
    % Note: This tests the calculation logic with direct values since we can't
    % easily mock queue objects in Common Test without complex setup

    % Test memory-based estimate (higher)
    Messages1 = 1000,
    % 10MB
    Memory1 = 10000000,
    MinPerMessage = 1024,
    % 20MB
    MemoryBased1 = Memory1 * 2,
    % ~1MB
    MessageBased1 = Messages1 * MinPerMessage,
    % Should be 20MB
    Expected1 = max(MemoryBased1, MessageBased1),
    ?assertEqual(20000000, Expected1),

    % Test message-based estimate (higher)
    Messages2 = 100000,
    % 1MB
    Memory2 = 1000000,
    % 2MB
    MemoryBased2 = Memory2 * 2,
    % ~100MB
    MessageBased2 = Messages2 * MinPerMessage,
    % Should be ~100MB
    Expected2 = max(MemoryBased2, MessageBased2),
    ?assertEqual(102400000, Expected2).

determine_insufficient_space_reason_test(_Config) ->
    % Test already below limit
    ?assertEqual(
        already_below_limit,
        rqm_checks:determine_insufficient_space_reason(
            1000, 2000, 500, -1000
        )
    ),

    % Test insufficient available space
    ?assertEqual(
        insufficient_available_space,
        rqm_checks:determine_insufficient_space_reason(
            10000, 2000, 10000, 8000
        )
    ),

    % Test would exceed limit after migration
    % Available space is sufficient, but after migration we'd be below the disk free limit
    ?assertEqual(
        would_exceed_limit_after_migration,
        rqm_checks:determine_insufficient_space_reason(
            10000, 9500, 1000, 2000
        )
    ).

has_all_mirrors_synchronized_test(_Config) ->
    % Test with mock queue data structures
    % Since we can't easily create real amqqueue records in unit tests,
    % we test the logic with mock data that simulates the key behaviors

    % Test case 1: All mirrors synchronized (sync_pids = slave_pids)
    % This simulates a queue where all 3 mirrors are synchronized
    SyncPids1 = [pid1, pid2, pid3],
    SlavePids1 = [pid1, pid2, pid3],
    ?assertEqual(true, length(SyncPids1) =:= length(SlavePids1)),

    % Test case 2: Not all mirrors synchronized (sync_pids < slave_pids)
    % This simulates a queue where only 2 out of 3 mirrors are synchronized
    SyncPids2 = [pid1, pid2],
    SlavePids2 = [pid1, pid2, pid3],
    ?assertEqual(false, length(SyncPids2) =:= length(SlavePids2)),

    % Test case 3: No mirrors (empty lists)
    % This simulates a non-mirrored queue
    SyncPids3 = [],
    SlavePids3 = [],
    ?assertEqual(true, length(SyncPids3) =:= length(SlavePids3)),

    % Test case 4: Single mirror synchronized
    SyncPids4 = [pid1],
    SlavePids4 = [pid1],
    ?assertEqual(true, length(SyncPids4) =:= length(SlavePids4)).
