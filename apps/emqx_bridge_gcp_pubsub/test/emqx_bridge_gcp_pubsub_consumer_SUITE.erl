%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_bridge_gcp_pubsub_consumer_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

-define(BRIDGE_TYPE, gcp_pubsub_consumer).
-define(BRIDGE_TYPE_BIN, <<"gcp_pubsub_consumer">>).
-define(REPUBLISH_TOPIC, <<"republish/t">>).

-import(emqx_common_test_helpers, [on_exit/1]).

%%------------------------------------------------------------------------------
%% CT boilerplate
%%------------------------------------------------------------------------------

all() ->
    emqx_common_test_helpers:all(?MODULE).

init_per_suite(Config) ->
    GCPEmulatorHost = os:getenv("GCP_EMULATOR_HOST", "toxiproxy"),
    GCPEmulatorPortStr = os:getenv("GCP_EMULATOR_PORT", "8085"),
    GCPEmulatorPort = list_to_integer(GCPEmulatorPortStr),
    ProxyHost = os:getenv("PROXY_HOST", "toxiproxy"),
    ProxyPort = list_to_integer(os:getenv("PROXY_PORT", "8474")),
    ProxyName = "gcp_emulator",
    emqx_common_test_helpers:reset_proxy(ProxyHost, ProxyPort),
    case emqx_common_test_helpers:is_tcp_server_available(GCPEmulatorHost, GCPEmulatorPort) of
        true ->
            ok = emqx_common_test_helpers:start_apps([emqx_conf]),
            ok = emqx_connector_test_helpers:start_apps([
                emqx_resource, emqx_bridge, emqx_rule_engine
            ]),
            {ok, _} = application:ensure_all_started(emqx_connector),
            emqx_mgmt_api_test_util:init_suite(),
            HostPort = GCPEmulatorHost ++ ":" ++ GCPEmulatorPortStr,
            true = os:putenv("PUBSUB_EMULATOR_HOST", HostPort),
            Client = start_control_client(),
            [
                {proxy_name, ProxyName},
                {proxy_host, ProxyHost},
                {proxy_port, ProxyPort},
                {gcp_emulator_host, GCPEmulatorHost},
                {gcp_emulator_port, GCPEmulatorPort},
                {client, Client}
                | Config
            ];
        false ->
            case os:getenv("IS_CI") of
                "yes" ->
                    throw(no_gcp_emulator);
                _ ->
                    {skip, no_gcp_emulator}
            end
    end.

end_per_suite(Config) ->
    Client = ?config(client, Config),
    stop_control_client(Client),
    emqx_mgmt_api_test_util:end_suite(),
    ok = emqx_common_test_helpers:stop_apps([emqx_conf]),
    ok = emqx_connector_test_helpers:stop_apps([emqx_bridge, emqx_resource, emqx_rule_engine]),
    _ = application:stop(emqx_connector),
    os:unsetenv("PUBSUB_EMULATOR_HOST"),
    ok.

init_per_testcase(TestCase, Config0) when
    TestCase =:= t_multiple_topic_mappings;
    TestCase =:= t_topic_deleted_while_consumer_is_running
->
    UniqueNum = integer_to_binary(erlang:unique_integer()),
    TopicMapping = [
        #{
            pubsub_topic => <<"pubsub-1-", UniqueNum/binary>>,
            mqtt_topic => <<"mqtt/topic/1/", UniqueNum/binary>>,
            qos => 2,
            payload_template => <<"${.}">>
        },
        #{
            pubsub_topic => <<"pubsub-2-", UniqueNum/binary>>,
            mqtt_topic => <<"mqtt/topic/2/", UniqueNum/binary>>,
            qos => 1,
            payload_template => to_payload_template(
                #{
                    <<"v">> => <<"${.value}">>,
                    <<"a">> => <<"${.attributes.key}">>
                }
            )
        }
    ],
    Config = [{topic_mapping, TopicMapping} | Config0],
    common_init_per_testcase(TestCase, Config);
init_per_testcase(TestCase, Config) ->
    common_init_per_testcase(TestCase, Config).

common_init_per_testcase(TestCase, Config0) ->
    ct:timetrap(timer:seconds(60)),
    emqx_bridge_testlib:delete_all_bridges(),
    emqx_config:delete_override_conf_files(),
    ConsumerTopic =
        <<
            (atom_to_binary(TestCase))/binary,
            (emqx_guid:to_hexstr(emqx_guid:gen()))/binary
        >>,
    UniqueNum = integer_to_binary(erlang:unique_integer()),
    MQTTTopic = proplists:get_value(mqtt_topic, Config0, <<"mqtt/topic/", UniqueNum/binary>>),
    MQTTQoS = proplists:get_value(mqtt_qos, Config0, 0),
    DefaultTopicMapping = [
        #{
            pubsub_topic => ConsumerTopic,
            mqtt_topic => MQTTTopic,
            qos => MQTTQoS,
            payload_template => <<"${.}">>
        }
    ],
    TopicMapping = proplists:get_value(topic_mapping, Config0, DefaultTopicMapping),
    ServiceAccountJSON =
        #{<<"project_id">> := ProjectId} =
        emqx_bridge_gcp_pubsub_utils:generate_service_account_json(),
    Config = [
        {consumer_topic, ConsumerTopic},
        {topic_mapping, TopicMapping},
        {service_account_json, ServiceAccountJSON},
        {project_id, ProjectId}
        | Config0
    ],
    {Name, ConfigString, ConsumerConfig} = consumer_config(TestCase, Config),
    ensure_topics(Config),
    ok = snabbkaffe:start_trace(),
    [
        {bridge_type, ?BRIDGE_TYPE},
        {bridge_name, Name},
        {bridge_config, ConsumerConfig},
        {consumer_name, Name},
        {consumer_config_string, ConfigString},
        {consumer_config, ConsumerConfig}
        | Config
    ].

end_per_testcase(_Testcase, Config) ->
    case proplists:get_bool(skip_does_not_apply, Config) of
        true ->
            ok;
        false ->
            ProxyHost = ?config(proxy_host, Config),
            ProxyPort = ?config(proxy_port, Config),
            emqx_common_test_helpers:reset_proxy(ProxyHost, ProxyPort),
            emqx_bridge_testlib:delete_all_bridges(),
            emqx_common_test_helpers:call_janitor(60_000),
            ok = snabbkaffe:stop(),
            ok
    end.

%%------------------------------------------------------------------------------
%% Helper fns
%%------------------------------------------------------------------------------

consumer_config(TestCase, Config) ->
    UniqueNum = integer_to_binary(erlang:unique_integer()),
    ConsumerTopic = ?config(consumer_topic, Config),
    ServiceAccountJSON = ?config(service_account_json, Config),
    Name = <<
        (atom_to_binary(TestCase))/binary, UniqueNum/binary
    >>,
    ServiceAccountJSONStr = emqx_utils_json:encode(ServiceAccountJSON),
    MQTTTopic = proplists:get_value(mqtt_topic, Config, <<"mqtt/topic/", UniqueNum/binary>>),
    MQTTQoS = proplists:get_value(mqtt_qos, Config, 0),
    DefaultTopicMapping = [
        #{
            pubsub_topic => ConsumerTopic,
            mqtt_topic => MQTTTopic,
            qos => MQTTQoS,
            payload_template => <<"${.}">>
        }
    ],
    TopicMapping0 = proplists:get_value(topic_mapping, Config, DefaultTopicMapping),
    TopicMappingStr = topic_mapping(TopicMapping0),
    ConfigString =
        io_lib:format(
            "bridges.gcp_pubsub_consumer.~s {\n"
            "  enable = true\n"
            %% gcp pubsub emulator doesn't do pipelining very well...
            "  pipelining = 1\n"
            "  connect_timeout = \"5s\"\n"
            "  service_account_json = ~s\n"
            "  consumer {\n"
            "    ack_deadline = \"60s\"\n"
            "    ack_retry_interval = \"1s\"\n"
            "    pull_max_messages = 10\n"
            "    consumer_workers_per_topic = 1\n"
            %% topic mapping
            "~s"
            "  }\n"
            "  max_retries = 2\n"
            "  pool_size = 8\n"
            "  resource_opts {\n"
            "    health_check_interval = \"1s\"\n"
            %% to fail and retry pulling faster
            "    request_ttl = \"5s\"\n"
            "  }\n"
            "}\n",
            [
                Name,
                ServiceAccountJSONStr,
                TopicMappingStr
            ]
        ),
    {Name, ConfigString, parse_and_check(ConfigString, Name)}.

parse_and_check(ConfigString, Name) ->
    {ok, RawConf} = hocon:binary(ConfigString, #{format => map}),
    TypeBin = ?BRIDGE_TYPE_BIN,
    hocon_tconf:check_plain(emqx_bridge_schema, RawConf, #{required => false, atom_key => false}),
    #{<<"bridges">> := #{TypeBin := #{Name := Config}}} = RawConf,
    ct:pal("config:\n  ~p", [Config]),
    Config.

topic_mapping(TopicMapping0) ->
    Template0 = <<
        "{pubsub_topic = \"{{ pubsub_topic }}\","
        " mqtt_topic = \"{{ mqtt_topic }}\","
        " qos = {{ qos }},"
        " payload_template = \"{{{ payload_template }}}\" }"
    >>,
    Template = bbmustache:parse_binary(Template0),
    Entries =
        lists:map(
            fun(Params) ->
                bbmustache:compile(Template, Params, [{key_type, atom}])
            end,
            TopicMapping0
        ),
    iolist_to_binary(
        [
            "  topic_mapping = [",
            lists:join(<<",\n">>, Entries),
            "]\n"
        ]
    ).

ensure_topics(Config) ->
    TopicMapping = ?config(topic_mapping, Config),
    lists:foreach(
        fun(#{pubsub_topic := T}) ->
            ensure_topic(Config, T)
        end,
        TopicMapping
    ).

ensure_topic(Config, Topic) ->
    ProjectId = ?config(project_id, Config),
    Client = ?config(client, Config),
    Method = put,
    Path = <<"/v1/projects/", ProjectId/binary, "/topics/", Topic/binary>>,
    Body = <<"{}">>,
    Res = emqx_bridge_gcp_pubsub_client:query_sync(
        {prepared_request, {Method, Path, Body}},
        Client
    ),
    case Res of
        {ok, _} ->
            ok;
        {error, #{status_code := 409}} ->
            %% already exists
            ok
    end,
    ok.

start_control_client() ->
    RawServiceAccount = emqx_bridge_gcp_pubsub_utils:generate_service_account_json(),
    ServiceAccount = emqx_utils_maps:unsafe_atom_key_map(RawServiceAccount),
    ConnectorConfig =
        #{
            connect_timeout => 5_000,
            max_retries => 0,
            pool_size => 1,
            resource_opts => #{request_ttl => 5_000},
            service_account_json => ServiceAccount
        },
    PoolName = <<"control_connector">>,
    {ok, Client} = emqx_bridge_gcp_pubsub_client:start(PoolName, ConnectorConfig),
    Client.

stop_control_client(Client) ->
    ok = emqx_bridge_gcp_pubsub_client:stop(Client),
    ok.

pubsub_publish(Config, Topic, Messages0) ->
    Client = ?config(client, Config),
    ProjectId = ?config(project_id, Config),
    Method = post,
    Path = <<"/v1/projects/", ProjectId/binary, "/topics/", Topic/binary, ":publish">>,
    Messages =
        lists:map(
            fun(Msg) ->
                emqx_utils_maps:update_if_present(
                    <<"data">>,
                    fun
                        (D) when is_binary(D) -> base64:encode(D);
                        (M) when is_map(M) -> base64:encode(emqx_utils_json:encode(M))
                    end,
                    Msg
                )
            end,
            Messages0
        ),
    Body = emqx_utils_json:encode(#{<<"messages">> => Messages}),
    {ok, _} = emqx_bridge_gcp_pubsub_client:query_sync(
        {prepared_request, {Method, Path, Body}},
        Client
    ),
    ok.

delete_topic(Config, Topic) ->
    Client = ?config(client, Config),
    ProjectId = ?config(project_id, Config),
    Method = delete,
    Path = <<"/v1/projects/", ProjectId/binary, "/topics/", Topic/binary>>,
    Body = <<>>,
    {ok, _} = emqx_bridge_gcp_pubsub_client:query_sync(
        {prepared_request, {Method, Path, Body}},
        Client
    ),
    ok.

delete_subscription(Config, SubscriptionId) ->
    Client = ?config(client, Config),
    ProjectId = ?config(project_id, Config),
    Method = delete,
    Path = <<"/v1/projects/", ProjectId/binary, "/subscriptions/", SubscriptionId/binary>>,
    Body = <<>>,
    {ok, _} = emqx_bridge_gcp_pubsub_client:query_sync(
        {prepared_request, {Method, Path, Body}},
        Client
    ),
    ok.

create_bridge(Config) ->
    create_bridge(Config, _Overrides = #{}).

create_bridge(Config, Overrides) ->
    Type = ?BRIDGE_TYPE_BIN,
    Name = ?config(consumer_name, Config),
    BridgeConfig0 = ?config(consumer_config, Config),
    BridgeConfig = emqx_utils_maps:deep_merge(BridgeConfig0, Overrides),
    emqx_bridge:create(Type, Name, BridgeConfig).

remove_bridge(Config) ->
    Type = ?BRIDGE_TYPE_BIN,
    Name = ?config(consumer_name, Config),
    emqx_bridge:remove(Type, Name).

create_bridge_api(Config) ->
    create_bridge_api(Config, _Overrides = #{}).

create_bridge_api(Config, Overrides) ->
    TypeBin = ?BRIDGE_TYPE_BIN,
    Name = ?config(consumer_name, Config),
    BridgeConfig0 = ?config(consumer_config, Config),
    BridgeConfig = emqx_utils_maps:deep_merge(BridgeConfig0, Overrides),
    Params = BridgeConfig#{<<"type">> => TypeBin, <<"name">> => Name},
    Path = emqx_mgmt_api_test_util:api_path(["bridges"]),
    AuthHeader = emqx_mgmt_api_test_util:auth_header_(),
    Opts = #{return_all => true},
    ct:pal("creating bridge (via http): ~p", [Params]),
    Res =
        case emqx_mgmt_api_test_util:request_api(post, Path, "", AuthHeader, Params, Opts) of
            {ok, {Status, Headers, Body0}} ->
                {ok, {Status, Headers, emqx_utils_json:decode(Body0, [return_maps])}};
            Error ->
                Error
        end,
    ct:pal("bridge create result: ~p", [Res]),
    Res.

probe_bridge_api(Config) ->
    TypeBin = ?BRIDGE_TYPE_BIN,
    Name = ?config(consumer_name, Config),
    ConsumerConfig = ?config(consumer_config, Config),
    Params = ConsumerConfig#{<<"type">> => TypeBin, <<"name">> => Name},
    Path = emqx_mgmt_api_test_util:api_path(["bridges_probe"]),
    AuthHeader = emqx_mgmt_api_test_util:auth_header_(),
    Opts = #{return_all => true},
    ct:pal("probing bridge (via http): ~p", [Params]),
    Res =
        case emqx_mgmt_api_test_util:request_api(post, Path, "", AuthHeader, Params, Opts) of
            {ok, {{_, 204, _}, _Headers, _Body0} = Res0} -> {ok, Res0};
            Error -> Error
        end,
    ct:pal("bridge probe result: ~p", [Res]),
    Res.

start_and_subscribe_mqtt(Config) ->
    TopicMapping = ?config(topic_mapping, Config),
    {ok, C} = emqtt:start_link([{proto_ver, v5}]),
    on_exit(fun() -> emqtt:stop(C) end),
    {ok, _} = emqtt:connect(C),
    lists:foreach(
        fun(#{mqtt_topic := MQTTTopic}) ->
            {ok, _, [2]} = emqtt:subscribe(C, MQTTTopic, _QoS = 2)
        end,
        TopicMapping
    ),
    ok.

resource_id(Config) ->
    Type = ?BRIDGE_TYPE_BIN,
    Name = ?config(consumer_name, Config),
    emqx_bridge_resource:resource_id(Type, Name).

bridge_id(Config) ->
    Type = ?BRIDGE_TYPE_BIN,
    Name = ?config(consumer_name, Config),
    emqx_bridge_resource:bridge_id(Type, Name).

receive_published() ->
    receive_published(#{}).

receive_published(Opts0) ->
    Default = #{n => 1, timeout => 20_000},
    Opts = maps:merge(Default, Opts0),
    receive_published(Opts, []).

receive_published(#{n := N, timeout := _Timeout}, Acc) when N =< 0 ->
    {ok, lists:reverse(Acc)};
receive_published(#{n := N, timeout := Timeout} = Opts, Acc) ->
    receive
        {publish, Msg0 = #{payload := Payload}} ->
            Msg =
                case emqx_utils_json:safe_decode(Payload, [return_maps]) of
                    {ok, Decoded} -> Msg0#{payload := Decoded};
                    {error, _} -> Msg0
                end,
            receive_published(Opts#{n := N - 1}, [Msg | Acc])
    after Timeout ->
        {timeout, #{
            msgs_so_far => Acc,
            mailbox => process_info(self(), messages),
            expected_remaining => N
        }}
    end.

create_rule_and_action_http(Config) ->
    ConsumerName = ?config(consumer_name, Config),
    BridgeId = emqx_bridge_resource:bridge_id(?BRIDGE_TYPE_BIN, ConsumerName),
    ActionFn = <<(atom_to_binary(?MODULE))/binary, ":action_response">>,
    Params = #{
        enable => true,
        sql => <<"SELECT * FROM \"$bridges/", BridgeId/binary, "\"">>,
        actions =>
            [
                #{
                    <<"function">> => <<"republish">>,
                    <<"args">> =>
                        #{
                            <<"topic">> => ?REPUBLISH_TOPIC,
                            <<"payload">> => <<>>,
                            <<"qos">> => 0,
                            <<"retain">> => false,
                            <<"user_properties">> => <<"${headers}">>
                        }
                },
                #{<<"function">> => ActionFn}
            ]
    },
    Path = emqx_mgmt_api_test_util:api_path(["rules"]),
    AuthHeader = emqx_mgmt_api_test_util:auth_header_(),
    ct:pal("rule action params: ~p", [Params]),
    case emqx_mgmt_api_test_util:request_api(post, Path, "", AuthHeader, Params) of
        {ok, Res = #{<<"id">> := RuleId}} ->
            on_exit(fun() -> ok = emqx_rule_engine:delete_rule(RuleId) end),
            {ok, emqx_utils_json:decode(Res, [return_maps])};
        Error ->
            Error
    end.

action_response(Selected, Envs, Args) ->
    ?tp(action_response, #{
        selected => Selected,
        envs => Envs,
        args => Args
    }),
    ok.

assert_non_received_metrics(BridgeName) ->
    Metrics = emqx_bridge:get_metrics(?BRIDGE_TYPE, BridgeName),
    #{counters := Counters0, gauges := Gauges} = Metrics,
    Counters = maps:remove(received, Counters0),
    ?assert(lists:all(fun(V) -> V == 0 end, maps:values(Counters)), #{metrics => Metrics}),
    ?assert(lists:all(fun(V) -> V == 0 end, maps:values(Gauges)), #{metrics => Metrics}),
    ok.

to_payload_template(Map) ->
    PayloadTemplate0 = emqx_utils_json:encode(Map),
    PayloadTemplate1 = io_lib:format("~p", [binary_to_list(PayloadTemplate0)]),
    string:strip(lists:flatten(PayloadTemplate1), both, $").

wait_acked(Opts) ->
    N = maps:get(n, Opts),
    Timeout = maps:get(timeout, Opts, 30_000),
    %% no need to check return value; we check the property in
    %% the check phase.  this is just to give it a chance to do
    %% so and avoid flakiness.  should be fast.
    snabbkaffe:block_until(
        ?match_n_events(N, #{?snk_kind := gcp_pubsub_consumer_worker_acknowledged}),
        Timeout
    ),
    ok.

wait_forgotten() ->
    wait_forgotten(_Opts = #{}).

wait_forgotten(Opts0) ->
    Timeout = maps:get(timeout, Opts0, 15_000),
    %% no need to check return value; we check the property in
    %% the check phase.  this is just to give it a chance to do
    %% so and avoid flakiness.
    ?block_until(
        #{?snk_kind := gcp_pubsub_consumer_worker_message_ids_forgotten},
        Timeout
    ),
    ok.

get_pull_worker_pids(Config) ->
    ResourceId = resource_id(Config),
    Pids =
        [
            PullWorkerPid
         || {_WorkerName, PoolWorkerPid} <- ecpool:workers(ResourceId),
            {ok, PullWorkerPid} <- [ecpool_worker:client(PoolWorkerPid)]
        ],
    %% assert
    [_ | _] = Pids,
    Pids.

get_async_worker_pids(Config) ->
    ResourceId = resource_id(Config),
    Pids =
        [
            AsyncWorkerPid
         || {_WorkerName, AsyncWorkerPid} <- gproc_pool:active_workers(ehttpc:name(ResourceId))
        ],
    %% assert
    [_ | _] = Pids,
    Pids.

projection_optional_span(Trace) ->
    [
        case maps:get(?snk_span, Evt, undefined) of
            undefined ->
                K;
            start ->
                {K, start};
            {complete, _} ->
                {K, complete}
        end
     || #{?snk_kind := K} = Evt <- Trace
    ].

cluster(Config) ->
    PrivDataDir = ?config(priv_dir, Config),
    Cluster = emqx_common_test_helpers:emqx_cluster(
        [core, core],
        [
            {apps, [emqx_conf, emqx_rule_engine, emqx_bridge]},
            {listener_ports, []},
            {peer_mod, slave},
            {priv_data_dir, PrivDataDir},
            {load_schema, true},
            {start_autocluster, true},
            {schema_mod, emqx_enterprise_schema},
            {env_handler, fun
                (emqx) ->
                    application:set_env(emqx, boot_modules, [broker, router]),
                    ok;
                (emqx_conf) ->
                    ok;
                (_) ->
                    ok
            end}
        ]
    ),
    ct:pal("cluster: ~p", [Cluster]),
    Cluster.

start_cluster(Cluster) ->
    Nodes = lists:map(
        fun({Name, Opts}) ->
            ct:pal("starting ~p", [Name]),
            emqx_common_test_helpers:start_slave(Name, Opts)
        end,
        Cluster
    ),
    on_exit(fun() ->
        emqx_utils:pmap(
            fun(N) ->
                ct:pal("stopping ~p", [N]),
                emqx_common_test_helpers:stop_slave(N)
            end,
            Nodes
        )
    end),
    Nodes.

wait_for_cluster_rpc(Node) ->
    %% need to wait until the config handler is ready after
    %% restarting during the cluster join.
    ?retry(
        _Sleep0 = 100,
        _Attempts0 = 50,
        true = is_pid(erpc:call(Node, erlang, whereis, [emqx_config_handler]))
    ).

setup_and_start_listeners(Node, NodeOpts) ->
    erpc:call(
        Node,
        fun() ->
            lists:foreach(
                fun(Type) ->
                    Port = emqx_common_test_helpers:listener_port(NodeOpts, Type),
                    ok = emqx_config:put(
                        [listeners, Type, default, bind],
                        {{127, 0, 0, 1}, Port}
                    ),
                    ok = emqx_config:put_raw(
                        [listeners, Type, default, bind],
                        iolist_to_binary([<<"127.0.0.1:">>, integer_to_binary(Port)])
                    ),
                    ok
                end,
                [tcp, ssl, ws, wss]
            ),
            ok = emqx_listeners:start(),
            ok
        end
    ).

%%------------------------------------------------------------------------------
%% Trace properties
%%------------------------------------------------------------------------------

prop_pulled_only_once() ->
    {"all pulled message ids are unique", fun ?MODULE:prop_pulled_only_once/1}.
prop_pulled_only_once(Trace) ->
    PulledIds =
        [
            MsgId
         || #{messages := Msgs} <- ?of_kind(gcp_pubsub_consumer_worker_decoded_messages, Trace),
            #{<<"message">> := #{<<"messageId">> := MsgId}} <- Msgs
        ],
    NumPulled = length(PulledIds),
    UniquePulledIds = sets:from_list(PulledIds, [{version, 2}]),
    UniqueNumPulled = sets:size(UniquePulledIds),
    ?assertEqual(UniqueNumPulled, NumPulled, #{pulled_ids => PulledIds}),
    ok.

prop_handled_only_once() ->
    {"all pulled message are processed only once", fun ?MODULE:prop_handled_only_once/1}.
prop_handled_only_once(Trace) ->
    HandledIds =
        [
            MsgId
         || #{?snk_span := start, message_id := MsgId} <-
                ?of_kind("gcp_pubsub_consumer_worker_handle_message", Trace)
        ],
    UniqueHandledIds = lists:usort(HandledIds),
    NumHandled = length(HandledIds),
    NumUniqueHandled = length(UniqueHandledIds),
    ?assertEqual(NumHandled, NumUniqueHandled, #{handled_ids => HandledIds}),
    ok.

prop_all_pulled_are_acked() ->
    {"all pulled msg ids are acked", fun ?MODULE:prop_all_pulled_are_acked/1}.
prop_all_pulled_are_acked(Trace) ->
    PulledMsgIds =
        [
            MsgId
         || #{messages := Msgs} <- ?of_kind(gcp_pubsub_consumer_worker_decoded_messages, Trace),
            #{<<"message">> := #{<<"messageId">> := MsgId}} <- Msgs
        ],
    AckedMsgIds0 = ?projection(acks, ?of_kind(gcp_pubsub_consumer_worker_acknowledged, Trace)),
    AckedMsgIds1 = [
        MsgId
     || PendingAcks <- AckedMsgIds0, {MsgId, _AckId} <- maps:to_list(PendingAcks)
    ],
    AckedMsgIds = sets:from_list(AckedMsgIds1, [{version, 2}]),
    ?assertEqual(
        sets:from_list(PulledMsgIds, [{version, 2}]),
        AckedMsgIds,
        #{
            decoded_msgs => ?of_kind(gcp_pubsub_consumer_worker_decoded_messages, Trace),
            acknlowledged => ?of_kind(gcp_pubsub_consumer_worker_acknowledged, Trace)
        }
    ),
    ok.

prop_client_stopped() ->
    {"client is stopped", fun ?MODULE:prop_client_stopped/1}.
prop_client_stopped(Trace) ->
    ?assert(
        ?strict_causality(
            #{?snk_kind := gcp_pubsub_ehttpc_pool_started, pool_name := _P1},
            #{?snk_kind := gcp_pubsub_stop, resource_id := _P2},
            _P1 =:= _P2,
            Trace
        )
    ),
    ok.

prop_workers_stopped(Topic) ->
    {"workers are stopped", fun(Trace) -> ?MODULE:prop_workers_stopped(Trace, Topic) end}.
prop_workers_stopped(Trace0, Topic) ->
    %% no assert because they might not start in the first place
    Trace = [Event || Event = #{topic := T} <- Trace0, T =:= Topic],
    ?strict_causality(
        #{?snk_kind := gcp_pubsub_consumer_worker_init, ?snk_meta := #{pid := _P1}},
        #{?snk_kind := gcp_pubsub_consumer_worker_terminate, ?snk_meta := #{pid := _P2}},
        _P1 =:= _P2,
        Trace
    ),
    ok.

prop_acked_ids_eventually_forgotten() ->
    {"all acked message ids are eventually forgotten",
        fun ?MODULE:prop_acked_ids_eventually_forgotten/1}.
prop_acked_ids_eventually_forgotten(Trace) ->
    AckedMsgIds0 =
        [
            MsgId
         || #{acks := PendingAcks} <- ?of_kind(gcp_pubsub_consumer_worker_acknowledged, Trace),
            {MsgId, _AckId} <- maps:to_list(PendingAcks)
        ],
    AckedMsgIds = sets:from_list(AckedMsgIds0, [{version, 2}]),
    ForgottenMsgIds = sets:union(
        ?projection(
            message_ids,
            ?of_kind(gcp_pubsub_consumer_worker_message_ids_forgotten, Trace)
        )
    ),
    EmptySet = sets:new([{version, 2}]),
    ?assertEqual(
        EmptySet,
        sets:subtract(AckedMsgIds, ForgottenMsgIds),
        #{
            forgotten => ForgottenMsgIds,
            acked => AckedMsgIds
        }
    ),
    ok.

%%------------------------------------------------------------------------------
%% Testcases
%%------------------------------------------------------------------------------

t_start_stop(Config) ->
    ResourceId = resource_id(Config),
    [#{pubsub_topic := PubSubTopic} | _] = ?config(topic_mapping, Config),
    ?check_trace(
        begin
            {ok, SRef0} =
                snabbkaffe:subscribe(
                    ?match_event(#{?snk_kind := "gcp_pubsub_consumer_worker_subscription_ready"}),
                    40_000
                ),
            ?assertMatch({ok, _}, create_bridge(Config)),
            {ok, _} = snabbkaffe:receive_events(SRef0),
            ?assertMatch({ok, connected}, emqx_resource_manager:health_check(ResourceId)),

            ?assertMatch({ok, _}, remove_bridge(Config)),
            ok
        end,
        [
            prop_client_stopped(),
            prop_workers_stopped(PubSubTopic),
            fun(Trace) ->
                ?assertMatch([_], ?of_kind(gcp_pubsub_consumer_unset_nonexistent_topic, Trace)),
                ok
            end
        ]
    ),
    ok.

t_consume_ok(Config) ->
    BridgeName = ?config(consumer_name, Config),
    TopicMapping = ?config(topic_mapping, Config),
    ResourceId = resource_id(Config),
    ?check_trace(
        begin
            start_and_subscribe_mqtt(Config),
            ?assertMatch(
                {{ok, _}, {ok, _}},
                ?wait_async_action(
                    create_bridge(Config),
                    #{?snk_kind := "gcp_pubsub_consumer_worker_subscription_ready"},
                    40_000
                )
            ),
            [
                #{
                    pubsub_topic := Topic,
                    mqtt_topic := MQTTTopic,
                    qos := QoS
                }
            ] = TopicMapping,
            Payload0 = emqx_guid:to_hexstr(emqx_guid:gen()),
            Messages0 = [
                #{
                    <<"data">> => Data0 = #{<<"value">> => Payload0},
                    <<"attributes">> => Attributes0 = #{<<"key">> => <<"value">>},
                    <<"orderingKey">> => <<"some_ordering_key">>
                }
            ],
            pubsub_publish(Config, Topic, Messages0),
            {ok, Published0} = receive_published(),
            EncodedData0 = emqx_utils_json:encode(Data0),
            ?assertMatch(
                [
                    #{
                        qos := QoS,
                        topic := MQTTTopic,
                        payload :=
                            #{
                                <<"attributes">> := Attributes0,
                                <<"message_id">> := MsgId,
                                <<"ordering_key">> := <<"some_ordering_key">>,
                                <<"publish_time">> := PubTime,
                                <<"topic">> := Topic,
                                <<"value">> := EncodedData0
                            }
                    }
                ] when is_binary(MsgId) andalso is_binary(PubTime),
                Published0
            ),
            wait_acked(#{n => 1}),
            ?retry(
                _Interval = 200,
                _NAttempts = 20,
                ?assertEqual(1, emqx_resource_metrics:received_get(ResourceId))
            ),

            %% Batch with only data and only attributes
            Payload1 = emqx_guid:to_hexstr(emqx_guid:gen()),
            Messages1 = [
                #{<<"data">> => Data1 = #{<<"val">> => Payload1}},
                #{<<"attributes">> => Attributes1 = #{<<"other_key">> => <<"other_value">>}}
            ],
            pubsub_publish(Config, Topic, Messages1),
            {ok, Published1} = receive_published(#{n => 2}),
            EncodedData1 = emqx_utils_json:encode(Data1),
            ?assertMatch(
                [
                    #{
                        qos := QoS,
                        topic := MQTTTopic,
                        payload :=
                            #{
                                <<"message_id">> := _,
                                <<"publish_time">> := _,
                                <<"topic">> := Topic,
                                <<"value">> := EncodedData1
                            }
                    },
                    #{
                        qos := QoS,
                        topic := MQTTTopic,
                        payload :=
                            #{
                                <<"attributes">> := Attributes1,
                                <<"message_id">> := _,
                                <<"publish_time">> := _,
                                <<"topic">> := Topic
                            }
                    }
                ],
                Published1
            ),
            ?assertNotMatch(
                [
                    #{payload := #{<<"attributes">> := _, <<"ordering_key">> := _}},
                    #{payload := #{<<"value">> := _, <<"ordering_key">> := _}}
                ],
                Published1
            ),
            %% no need to check return value; we check the property in
            %% the check phase.  this is just to give it a chance to do
            %% so and avoid flakiness.  should be fast.
            ?block_until(
                #{?snk_kind := gcp_pubsub_consumer_worker_acknowledged, acks := Acks} when
                    map_size(Acks) =:= 2,
                5_000
            ),
            ?retry(
                _Interval = 200,
                _NAttempts = 20,
                ?assertEqual(3, emqx_resource_metrics:received_get(ResourceId))
            ),

            %% FIXME: uncomment after API spec is un-hidden...
            %% %% Check that the bridge probe API doesn't leak atoms.
            %% ProbeRes0 = probe_bridge_api(Config),
            %% ?assertMatch({ok, {{_, 204, _}, _Headers, _Body}}, ProbeRes0),
            %% AtomsBefore = erlang:system_info(atom_count),
            %% %% Probe again; shouldn't have created more atoms.
            %% ProbeRes1 = probe_bridge_api(Config),
            %% ?assertMatch({ok, {{_, 204, _}, _Headers, _Body}}, ProbeRes1),
            %% AtomsAfter = erlang:system_info(atom_count),
            %% ?assertEqual(AtomsBefore, AtomsAfter),

            assert_non_received_metrics(BridgeName),
            ?block_until(
                #{?snk_kind := gcp_pubsub_consumer_worker_message_ids_forgotten, message_ids := Ids} when
                    map_size(Ids) =:= 2,
                30_000
            ),

            ok
        end,
        [
            prop_all_pulled_are_acked(),
            prop_pulled_only_once(),
            prop_handled_only_once(),
            prop_acked_ids_eventually_forgotten()
        ]
    ),
    ok.

t_bridge_rule_action_source(Config) ->
    BridgeName = ?config(consumer_name, Config),
    TopicMapping = ?config(topic_mapping, Config),
    ResourceId = resource_id(Config),
    ?check_trace(
        begin
            ?assertMatch(
                {{ok, _}, {ok, _}},
                ?wait_async_action(
                    create_bridge(Config),
                    #{?snk_kind := "gcp_pubsub_consumer_worker_subscription_ready"},
                    40_000
                )
            ),
            {ok, _} = create_rule_and_action_http(Config),

            [#{pubsub_topic := PubSubTopic}] = TopicMapping,
            {ok, C} = emqtt:start_link([{proto_ver, v5}]),
            on_exit(fun() -> emqtt:stop(C) end),
            {ok, _} = emqtt:connect(C),
            {ok, _, [0]} = emqtt:subscribe(C, ?REPUBLISH_TOPIC),

            Payload0 = emqx_guid:to_hexstr(emqx_guid:gen()),
            Messages0 = [
                #{
                    <<"data">> => Data0 = #{<<"payload">> => Payload0},
                    <<"attributes">> => Attributes0 = #{<<"key">> => <<"value">>}
                }
            ],
            {_, {ok, _}} =
                ?wait_async_action(
                    pubsub_publish(Config, PubSubTopic, Messages0),
                    #{?snk_kind := action_response},
                    5_000
                ),
            Published0 = receive_published(),
            EncodedData0 = emqx_utils_json:encode(Data0),
            ?assertMatch(
                {ok, [
                    #{
                        topic := ?REPUBLISH_TOPIC,
                        qos := 0,
                        payload := #{
                            <<"event">> := <<"$bridges/", _/binary>>,
                            <<"message_id">> := _,
                            <<"metadata">> := #{<<"rule_id">> := _},
                            <<"publish_time">> := _,
                            <<"topic">> := PubSubTopic,
                            <<"attributes">> := Attributes0,
                            <<"value">> := EncodedData0
                        }
                    }
                ]},
                Published0
            ),
            ?retry(
                _Interval = 200,
                _NAttempts = 20,
                ?assertEqual(1, emqx_resource_metrics:received_get(ResourceId))
            ),

            assert_non_received_metrics(BridgeName),

            #{payload => Payload0}
        end,
        [
            prop_pulled_only_once(),
            prop_handled_only_once()
        ]
    ),
    ok.

t_on_get_status(Config) ->
    emqx_bridge_testlib:t_on_get_status(Config, #{failure_status => connecting}),
    ok.

t_create_via_http_api(_Config) ->
    ct:comment("FIXME: implement after API specs are un-hidden in e5.2.0..."),
    ok.

t_multiple_topic_mappings(Config) ->
    BridgeName = ?config(consumer_name, Config),
    TopicMapping = ?config(topic_mapping, Config),
    ResourceId = resource_id(Config),
    ?check_trace(
        begin
            start_and_subscribe_mqtt(Config),
            ?assertMatch(
                {{ok, _}, {ok, _}},
                ?wait_async_action(
                    create_bridge(Config),
                    #{?snk_kind := "gcp_pubsub_consumer_worker_subscription_ready"},
                    40_000
                )
            ),
            [
                #{
                    pubsub_topic := Topic0,
                    mqtt_topic := MQTTTopic0,
                    qos := QoS0
                },
                #{
                    pubsub_topic := Topic1,
                    mqtt_topic := MQTTTopic1,
                    qos := QoS1
                }
            ] = TopicMapping,
            Payload = emqx_guid:to_hexstr(emqx_guid:gen()),
            Messages = [
                #{
                    <<"data">> => Payload,
                    <<"attributes">> => Attributes = #{<<"key">> => <<"value">>},
                    <<"orderingKey">> => <<"some_ordering_key">>
                }
            ],
            pubsub_publish(Config, Topic0, Messages),
            pubsub_publish(Config, Topic1, Messages),
            {ok, Published0} = receive_published(#{n => 2}),
            Published =
                lists:sort(
                    fun(#{topic := TA}, #{topic := TB}) ->
                        TA =< TB
                    end,
                    Published0
                ),
            ?assertMatch(
                [
                    #{
                        qos := QoS0,
                        topic := MQTTTopic0,
                        payload :=
                            #{
                                <<"attributes">> := Attributes,
                                <<"message_id">> := _,
                                <<"ordering_key">> := <<"some_ordering_key">>,
                                <<"publish_time">> := _,
                                <<"topic">> := _Topic,
                                <<"value">> := Payload
                            }
                    },
                    #{
                        qos := QoS1,
                        topic := MQTTTopic1,
                        payload := #{
                            <<"v">> := Payload,
                            <<"a">> := <<"value">>
                        }
                    }
                ],
                Published
            ),
            wait_acked(#{n => 2}),
            ?retry(
                _Interval = 200,
                _NAttempts = 20,
                ?assertEqual(2, emqx_resource_metrics:received_get(ResourceId))
            ),

            assert_non_received_metrics(BridgeName),

            ok
        end,
        [
            prop_all_pulled_are_acked(),
            prop_pulled_only_once(),
            prop_handled_only_once()
        ]
    ),
    ok.

%% 2+ pull workers do not duplicate delivered messages
t_multiple_pull_workers(Config) ->
    ct:timetrap({seconds, 120}),
    BridgeName = ?config(consumer_name, Config),
    TopicMapping = ?config(topic_mapping, Config),
    ResourceId = resource_id(Config),
    ?check_trace(
        begin
            NConsumers = 3,
            start_and_subscribe_mqtt(Config),
            {ok, SRef0} =
                snabbkaffe:subscribe(
                    ?match_event(#{?snk_kind := "gcp_pubsub_consumer_worker_subscription_ready"}),
                    NConsumers,
                    40_000
                ),
            {ok, _} = create_bridge(
                Config,
                #{
                    <<"consumer">> => #{
                        %% reduce flakiness
                        <<"ack_deadline">> => <<"10m">>,
                        <<"consumer_workers_per_topic">> => NConsumers
                    }
                }
            ),
            {ok, _} = snabbkaffe:receive_events(SRef0),
            [#{pubsub_topic := Topic}] = TopicMapping,
            Payload = emqx_guid:to_hexstr(emqx_guid:gen()),
            Messages = [#{<<"data">> => Payload}],
            pubsub_publish(Config, Topic, Messages),
            {ok, Published} = receive_published(),
            ?assertMatch(
                [#{payload := #{<<"value">> := Payload}}],
                Published
            ),
            ?retry(
                _Interval = 200,
                _NAttempts = 20,
                ?assertEqual(1, emqx_resource_metrics:received_get(ResourceId))
            ),

            assert_non_received_metrics(BridgeName),

            wait_acked(#{n => 1, timeout => 90_000}),

            ok
        end,
        [
            prop_all_pulled_are_acked(),
            prop_pulled_only_once(),
            prop_handled_only_once(),
            {"message is processed only once", fun(Trace) ->
                ?assertMatch({timeout, _}, receive_published(#{timeout => 5_000})),
                ?assertMatch(
                    [#{?snk_span := start}, #{?snk_span := {complete, _}}],
                    ?of_kind("gcp_pubsub_consumer_worker_handle_message", Trace)
                ),
                ok
            end}
        ]
    ),
    ok.

t_nonexistent_topic(Config) ->
    BridgeName = ?config(bridge_name, Config),
    [Mapping0] = ?config(topic_mapping, Config),
    ResourceId = resource_id(Config),
    PubSubTopic = <<"nonexistent-", (emqx_guid:to_hexstr(emqx_guid:gen()))/binary>>,
    TopicMapping0 = [Mapping0#{pubsub_topic := PubSubTopic}],
    TopicMapping = emqx_utils_maps:binary_key_map(TopicMapping0),
    ?check_trace(
        begin
            {ok, _} =
                create_bridge(
                    Config,
                    #{
                        <<"consumer">> =>
                            #{<<"topic_mapping">> => TopicMapping}
                    }
                ),
            ?assertMatch(
                {ok, disconnected},
                emqx_resource_manager:health_check(ResourceId)
            ),
            ?assertMatch(
                {ok, _Group, #{error := "GCP PubSub topics are invalid" ++ _}},
                emqx_resource_manager:lookup_cached(ResourceId)
            ),
            %% now create the topic and restart the bridge
            ensure_topic(Config, PubSubTopic),
            ?assertMatch(
                ok,
                emqx_bridge_resource:restart(?BRIDGE_TYPE, BridgeName)
            ),
            ?retry(
                _Interval0 = 200,
                _NAttempts0 = 20,
                ?assertMatch({ok, connected}, emqx_resource_manager:health_check(ResourceId))
            ),
            ?assertMatch(
                {ok, _Group, #{error := undefined}},
                emqx_resource_manager:lookup_cached(ResourceId)
            ),
            ok
        end,
        [
            fun(Trace) ->
                %% client is stopped after first failure
                ?assertMatch([_], ?of_kind(gcp_pubsub_stop, Trace)),
                ok
            end
        ]
    ),
    ok.

t_topic_deleted_while_consumer_is_running(Config) ->
    TopicMapping = [#{pubsub_topic := PubSubTopic} | _] = ?config(topic_mapping, Config),
    NTopics = length(TopicMapping),
    ResourceId = resource_id(Config),
    ?check_trace(
        begin
            {ok, SRef0} =
                snabbkaffe:subscribe(
                    ?match_event(#{?snk_kind := "gcp_pubsub_consumer_worker_subscription_ready"}),
                    NTopics,
                    40_000
                ),
            {ok, _} = create_bridge(Config),
            {ok, _} = snabbkaffe:receive_events(SRef0),

            ?assertMatch({ok, connected}, emqx_resource_manager:health_check(ResourceId)),

            %% curiously, gcp pubsub doesn't seem to return any errors from the
            %% subscription if the topic is deleted while the subscription still exists...
            {ok, SRef1} =
                snabbkaffe:subscribe(
                    ?match_event(#{
                        ?snk_kind := gcp_pubsub_consumer_worker_pull_async,
                        ?snk_span := start
                    }),
                    2,
                    40_000
                ),
            delete_topic(Config, PubSubTopic),
            {ok, _} = snabbkaffe:receive_events(SRef1),

            ok
        end,
        []
    ),
    ok.

t_connection_down_before_starting(Config) ->
    ProxyName = ?config(proxy_name, Config),
    ProxyHost = ?config(proxy_host, Config),
    ProxyPort = ?config(proxy_port, Config),
    ResourceId = resource_id(Config),
    ?check_trace(
        begin
            emqx_common_test_helpers:with_failure(down, ProxyName, ProxyHost, ProxyPort, fun() ->
                ?assertMatch(
                    {{ok, _}, {ok, _}},
                    ?wait_async_action(
                        create_bridge(Config),
                        #{?snk_kind := gcp_pubsub_consumer_worker_init},
                        10_000
                    )
                ),
                ?assertMatch({ok, connecting}, emqx_resource_manager:health_check(ResourceId)),
                ok
            end),
            ?retry(
                _Interval0 = 200,
                _NAttempts0 = 20,
                ?assertMatch({ok, connected}, emqx_resource_manager:health_check(ResourceId))
            ),
            ok
        end,
        []
    ),
    ok.

t_connection_timeout_before_starting(Config) ->
    ProxyName = ?config(proxy_name, Config),
    ProxyHost = ?config(proxy_host, Config),
    ProxyPort = ?config(proxy_port, Config),
    ResourceId = resource_id(Config),
    ?check_trace(
        begin
            emqx_common_test_helpers:with_failure(
                timeout, ProxyName, ProxyHost, ProxyPort, fun() ->
                    ?assertMatch(
                        {{ok, _}, {ok, _}},
                        ?wait_async_action(
                            create_bridge(Config),
                            #{?snk_kind := gcp_pubsub_consumer_worker_init},
                            10_000
                        )
                    ),
                    ?assertMatch({ok, connecting}, emqx_resource_manager:health_check(ResourceId)),
                    ok
                end
            ),
            ?retry(
                _Interval0 = 200,
                _NAttempts0 = 20,
                ?assertMatch({ok, connected}, emqx_resource_manager:health_check(ResourceId))
            ),
            ok
        end,
        []
    ),
    ok.

t_pull_worker_death(Config) ->
    ResourceId = resource_id(Config),
    ?check_trace(
        begin
            ?assertMatch(
                {{ok, _}, {ok, _}},
                ?wait_async_action(
                    create_bridge(Config),
                    #{?snk_kind := gcp_pubsub_consumer_worker_init},
                    10_000
                )
            ),

            [PullWorkerPid | _] = get_pull_worker_pids(Config),
            Ref = monitor(process, PullWorkerPid),
            sys:terminate(PullWorkerPid, die),
            receive
                {'DOWN', Ref, process, PullWorkerPid, _} ->
                    ok
            after 500 -> ct:fail("pull worker didn't die")
            end,
            ?assertMatch({ok, connecting}, emqx_resource_manager:health_check(ResourceId)),

            %% recovery
            ?retry(
                _Interval0 = 200,
                _NAttempts0 = 20,
                ?assertMatch({ok, connected}, emqx_resource_manager:health_check(ResourceId))
            ),

            ok
        end,
        []
    ),
    ok.

t_async_worker_death_mid_pull(Config) ->
    ct:timetrap({seconds, 120}),
    [#{pubsub_topic := PubSubTopic}] = ?config(topic_mapping, Config),
    Payload = emqx_guid:to_hexstr(emqx_guid:gen()),
    ?check_trace(
        begin
            start_and_subscribe_mqtt(Config),

            ?force_ordering(
                #{
                    ?snk_kind := gcp_pubsub_consumer_worker_pull_async,
                    ?snk_span := {complete, _}
                },
                #{?snk_kind := kill_async_worker, ?snk_span := start}
            ),
            ?force_ordering(
                #{?snk_kind := kill_async_worker, ?snk_span := {complete, _}},
                #{?snk_kind := gcp_pubsub_consumer_worker_reply_delegator}
            ),
            spawn_link(fun() ->
                ?tp_span(
                    kill_async_worker,
                    #{},
                    begin
                        %% produce a message while worker is being killed
                        Messages = [#{<<"data">> => Payload}],
                        pubsub_publish(Config, PubSubTopic, Messages),

                        AsyncWorkerPids = get_async_worker_pids(Config),
                        emqx_utils:pmap(
                            fun(AsyncWorkerPid) ->
                                Ref = monitor(process, AsyncWorkerPid),
                                sys:terminate(AsyncWorkerPid, die),
                                receive
                                    {'DOWN', Ref, process, AsyncWorkerPid, _} ->
                                        ok
                                after 500 -> ct:fail("async worker didn't die")
                                end,
                                ok
                            end,
                            AsyncWorkerPids
                        ),

                        ok
                    end
                )
            end),

            ?assertMatch(
                {{ok, _}, {ok, _}},
                ?wait_async_action(
                    create_bridge(
                        Config,
                        #{<<"pool_size">> => 1}
                    ),
                    #{?snk_kind := gcp_pubsub_consumer_worker_init},
                    10_000
                )
            ),

            {ok, _} =
                ?block_until(
                    #{?snk_kind := gcp_pubsub_consumer_worker_handled_async_worker_down},
                    30_000
                ),

            %% check that we eventually received the message.
            %% for some reason, this can take forever in ci...
            {ok, Published} = receive_published(#{timeout => 60_000}),
            ?assertMatch([#{payload := #{<<"value">> := Payload}}], Published),

            ok
        end,
        [
            prop_handled_only_once(),
            fun(Trace) ->
                %% expected order of events; reply delegator called only once
                SubTrace = ?of_kind(
                    [
                        gcp_pubsub_consumer_worker_handled_async_worker_down,
                        gcp_pubsub_consumer_worker_pull_response_received,
                        gcp_pubsub_consumer_worker_reply_delegator
                    ],
                    Trace
                ),
                ?assertMatch(
                    [
                        #{?snk_kind := gcp_pubsub_consumer_worker_handled_async_worker_down},
                        #{?snk_kind := gcp_pubsub_consumer_worker_reply_delegator}
                        | _
                    ],
                    SubTrace,
                    #{sub_trace => projection_optional_span(SubTrace)}
                ),
                ?assertMatch(
                    #{?snk_kind := gcp_pubsub_consumer_worker_pull_response_received},
                    lists:last(SubTrace)
                ),
                ok
            end
        ]
    ),
    ok.

t_connection_error_while_creating_subscription(Config) ->
    ProxyName = ?config(proxy_name, Config),
    ProxyHost = ?config(proxy_host, Config),
    ProxyPort = ?config(proxy_port, Config),
    ?check_trace(
        begin
            emqx_common_test_helpers:with_failure(down, ProxyName, ProxyHost, ProxyPort, fun() ->
                %% check retries
                {ok, SRef0} =
                    snabbkaffe:subscribe(
                        ?match_event(#{?snk_kind := "gcp_pubsub_consumer_worker_subscription_error"}),
                        _NEvents0 = 2,
                        10_000
                    ),
                {ok, _} = create_bridge(Config),
                {ok, _} = snabbkaffe:receive_events(SRef0),
                ok
            end),
            %% eventually succeeds
            {ok, _} =
                ?block_until(
                    #{?snk_kind := "gcp_pubsub_consumer_worker_subscription_created"},
                    10_000
                ),
            ok
        end,
        []
    ),
    ok.

t_subscription_already_exists(Config) ->
    BridgeName = ?config(bridge_name, Config),
    ?check_trace(
        begin
            {{ok, _}, {ok, _}} =
                ?wait_async_action(
                    create_bridge(Config),
                    #{?snk_kind := "gcp_pubsub_consumer_worker_subscription_created"},
                    10_000
                ),
            %% now restart the same bridge
            {ok, _} = emqx_bridge:disable_enable(disable, ?BRIDGE_TYPE, BridgeName),

            {{ok, _}, {ok, _}} =
                ?wait_async_action(
                    emqx_bridge:disable_enable(enable, ?BRIDGE_TYPE, BridgeName),
                    #{?snk_kind := "gcp_pubsub_consumer_worker_subscription_ready"},
                    10_000
                ),

            ok
        end,
        fun(Trace) ->
            ?assertMatch(
                [
                    "gcp_pubsub_consumer_worker_subscription_already_exists",
                    "gcp_pubsub_consumer_worker_subscription_patched"
                ],
                ?projection(
                    ?snk_kind,
                    ?of_kind(
                        [
                            "gcp_pubsub_consumer_worker_subscription_already_exists",
                            "gcp_pubsub_consumer_worker_subscription_patched"
                        ],
                        Trace
                    )
                )
            ),
            ok
        end
    ),
    ok.

t_subscription_patch_error(Config) ->
    BridgeName = ?config(bridge_name, Config),
    ProxyName = ?config(proxy_name, Config),
    ProxyHost = ?config(proxy_host, Config),
    ProxyPort = ?config(proxy_port, Config),
    ?check_trace(
        begin
            {{ok, _}, {ok, _}} =
                ?wait_async_action(
                    create_bridge(Config),
                    #{?snk_kind := "gcp_pubsub_consumer_worker_subscription_created"},
                    10_000
                ),
            %% now restart the same bridge
            {ok, _} = emqx_bridge:disable_enable(disable, ?BRIDGE_TYPE, BridgeName),

            ?force_ordering(
                #{?snk_kind := "gcp_pubsub_consumer_worker_subscription_already_exists"},
                #{?snk_kind := cut_connection, ?snk_span := start}
            ),
            ?force_ordering(
                #{?snk_kind := cut_connection, ?snk_span := {complete, _}},
                #{?snk_kind := gcp_pubsub_consumer_worker_patch_subscription_enter}
            ),
            spawn_link(fun() ->
                ?tp_span(
                    cut_connection,
                    #{},
                    emqx_common_test_helpers:enable_failure(down, ProxyName, ProxyHost, ProxyPort)
                )
            end),

            {{ok, _}, {ok, _}} =
                ?wait_async_action(
                    emqx_bridge:disable_enable(enable, ?BRIDGE_TYPE, BridgeName),
                    #{?snk_kind := "gcp_pubsub_consumer_worker_subscription_patch_error"},
                    10_000
                ),

            {{ok, _}, {ok, _}} =
                ?wait_async_action(
                    emqx_common_test_helpers:heal_failure(down, ProxyName, ProxyHost, ProxyPort),
                    #{?snk_kind := "gcp_pubsub_consumer_worker_subscription_ready"},
                    10_000
                ),

            ok
        end,
        []
    ),
    ok.

t_topic_deleted_while_creating_subscription(Config) ->
    [#{pubsub_topic := PubSubTopic}] = ?config(topic_mapping, Config),
    ResourceId = resource_id(Config),
    ?check_trace(
        begin
            ?force_ordering(
                #{?snk_kind := gcp_pubsub_consumer_worker_init},
                #{?snk_kind := delete_topic, ?snk_span := start}
            ),
            ?force_ordering(
                #{?snk_kind := delete_topic, ?snk_span := {complete, _}},
                #{?snk_kind := gcp_pubsub_consumer_worker_create_subscription_enter}
            ),
            spawn_link(fun() ->
                ?tp_span(
                    delete_topic,
                    #{},
                    delete_topic(Config, PubSubTopic)
                )
            end),
            {{ok, _}, {ok, _}} =
                ?wait_async_action(
                    create_bridge(Config),
                    #{?snk_kind := gcp_pubsub_consumer_worker_terminate},
                    10_000
                ),
            ?assertMatch({ok, disconnected}, emqx_resource_manager:health_check(ResourceId)),
            ok
        end,
        []
    ),
    ok.

t_topic_deleted_while_patching_subscription(Config) ->
    BridgeName = ?config(bridge_name, Config),
    [#{pubsub_topic := PubSubTopic}] = ?config(topic_mapping, Config),
    ResourceId = resource_id(Config),
    ?check_trace(
        begin
            {{ok, _}, {ok, _}} =
                ?wait_async_action(
                    create_bridge(Config),
                    #{?snk_kind := "gcp_pubsub_consumer_worker_subscription_created"},
                    10_000
                ),
            %% now restart the same bridge
            {ok, _} = emqx_bridge:disable_enable(disable, ?BRIDGE_TYPE, BridgeName),

            ?force_ordering(
                #{?snk_kind := "gcp_pubsub_consumer_worker_subscription_already_exists"},
                #{?snk_kind := delete_topic, ?snk_span := start}
            ),
            ?force_ordering(
                #{?snk_kind := delete_topic, ?snk_span := {complete, _}},
                #{?snk_kind := gcp_pubsub_consumer_worker_patch_subscription_enter}
            ),
            spawn_link(fun() ->
                ?tp_span(
                    delete_topic,
                    #{},
                    delete_topic(Config, PubSubTopic)
                )
            end),
            %% as with deleting the topic of an existing subscription, patching after the
            %% topic does not exist anymore doesn't return errors either...
            {{ok, _}, {ok, _}} =
                ?wait_async_action(
                    emqx_bridge:disable_enable(enable, ?BRIDGE_TYPE, BridgeName),
                    #{?snk_kind := "gcp_pubsub_consumer_worker_subscription_ready"},
                    10_000
                ),
            ?assertMatch({ok, connected}, emqx_resource_manager:health_check(ResourceId)),
            ok
        end,
        []
    ),
    ok.

t_subscription_deleted_while_consumer_is_running(Config) ->
    ResourceId = resource_id(Config),
    ?check_trace(
        begin
            {{ok, _}, {ok, #{subscription_id := SubscriptionId}}} =
                ?wait_async_action(
                    create_bridge(Config),
                    #{
                        ?snk_kind := gcp_pubsub_consumer_worker_pull_async,
                        ?snk_span := {complete, _}
                    },
                    10_000
                ),
            {ok, SRef0} =
                snabbkaffe:subscribe(
                    ?match_event(
                        #{?snk_kind := "gcp_pubsub_consumer_worker_pull_error"}
                    ),
                    30_000
                ),
            {ok, SRef1} =
                snabbkaffe:subscribe(
                    ?match_event(
                        #{?snk_kind := "gcp_pubsub_consumer_worker_subscription_ready"}
                    ),
                    30_000
                ),
            delete_subscription(Config, SubscriptionId),
            {ok, _} = snabbkaffe:receive_events(SRef0),
            {ok, _} = snabbkaffe:receive_events(SRef1),

            ?assertMatch({ok, connected}, emqx_resource_manager:health_check(ResourceId)),
            ok
        end,
        fun(Trace0) ->
            SubTrace0 = ?of_kind(
                [
                    "gcp_pubsub_consumer_worker_pull_error",
                    "gcp_pubsub_consumer_worker_subscription_ready",
                    gcp_pubsub_consumer_worker_create_subscription_enter
                ],
                Trace0
            ),
            SubTrace = projection_optional_span(SubTrace0),
            ?assertMatch(
                [
                    gcp_pubsub_consumer_worker_create_subscription_enter,
                    "gcp_pubsub_consumer_worker_subscription_ready",
                    "gcp_pubsub_consumer_worker_pull_error",
                    gcp_pubsub_consumer_worker_create_subscription_enter
                    | _
                ],
                SubTrace
            ),
            ?assertEqual(
                "gcp_pubsub_consumer_worker_subscription_ready",
                lists:last(SubTrace),
                #{sub_trace => SubTrace}
            ),
            ok
        end
    ),
    ok.

t_subscription_and_topic_deleted_while_consumer_is_running(Config) ->
    ct:timetrap({seconds, 90}),
    [#{pubsub_topic := PubSubTopic}] = ?config(topic_mapping, Config),
    ResourceId = resource_id(Config),
    ?check_trace(
        begin
            {{ok, _}, {ok, #{subscription_id := SubscriptionId}}} =
                ?wait_async_action(
                    create_bridge(Config),
                    #{
                        ?snk_kind := gcp_pubsub_consumer_worker_pull_async,
                        ?snk_span := {complete, _}
                    },
                    10_000
                ),
            delete_topic(Config, PubSubTopic),
            delete_subscription(Config, SubscriptionId),
            {ok, _} = ?block_until(#{?snk_kind := gcp_pubsub_consumer_worker_terminate}, 60_000),

            ?assertMatch({ok, disconnected}, emqx_resource_manager:health_check(ResourceId)),
            ok
        end,
        []
    ),
    ok.

t_connection_down_during_ack(Config) ->
    ProxyName = ?config(proxy_name, Config),
    ProxyHost = ?config(proxy_host, Config),
    ProxyPort = ?config(proxy_port, Config),
    [#{pubsub_topic := PubSubTopic}] = ?config(topic_mapping, Config),
    ?check_trace(
        begin
            start_and_subscribe_mqtt(Config),

            {{ok, _}, {ok, _}} =
                ?wait_async_action(
                    create_bridge(Config),
                    #{?snk_kind := "gcp_pubsub_consumer_worker_subscription_ready"},
                    10_000
                ),

            ?force_ordering(
                #{
                    ?snk_kind := "gcp_pubsub_consumer_worker_handle_message",
                    ?snk_span := {complete, _}
                },
                #{?snk_kind := cut_connection, ?snk_span := start}
            ),
            ?force_ordering(
                #{?snk_kind := cut_connection, ?snk_span := {complete, _}},
                #{?snk_kind := gcp_pubsub_consumer_worker_acknowledge_enter}
            ),
            spawn_link(fun() ->
                ?tp_span(
                    cut_connection,
                    #{},
                    emqx_common_test_helpers:enable_failure(down, ProxyName, ProxyHost, ProxyPort)
                )
            end),

            Payload = emqx_guid:to_hexstr(emqx_guid:gen()),
            Messages = [#{<<"data">> => Payload}],
            pubsub_publish(Config, PubSubTopic, Messages),
            {ok, _} = ?block_until(#{?snk_kind := "gcp_pubsub_consumer_worker_ack_error"}, 10_000),

            {{ok, _}, {ok, _}} =
                ?wait_async_action(
                    emqx_common_test_helpers:heal_failure(down, ProxyName, ProxyHost, ProxyPort),
                    #{?snk_kind := gcp_pubsub_consumer_worker_acknowledged},
                    30_000
                ),

            {ok, _Published} = receive_published(),

            ok
        end,
        [
            prop_all_pulled_are_acked(),
            prop_pulled_only_once(),
            prop_handled_only_once(),
            {"message is processed only once", fun(Trace) ->
                ?assertMatch({timeout, _}, receive_published(#{timeout => 5_000})),
                ?assertMatch(
                    [#{?snk_span := start}, #{?snk_span := {complete, _}}],
                    ?of_kind("gcp_pubsub_consumer_worker_handle_message", Trace)
                ),
                ok
            end}
        ]
    ),
    ok.

t_connection_down_during_ack_redeliver(Config) ->
    ct:timetrap({seconds, 120}),
    [#{pubsub_topic := PubSubTopic}] = ?config(topic_mapping, Config),
    ?check_trace(
        begin
            start_and_subscribe_mqtt(Config),

            {{ok, _}, {ok, _}} =
                ?wait_async_action(
                    create_bridge(
                        Config,
                        #{<<"consumer">> => #{<<"ack_deadline">> => <<"10s">>}}
                    ),
                    #{?snk_kind := "gcp_pubsub_consumer_worker_subscription_ready"},
                    10_000
                ),

            emqx_common_test_helpers:with_mock(
                emqx_bridge_gcp_pubsub_client,
                query_sync,
                fun(PreparedRequest = {prepared_request, {_Method, Path, _Body}}, Client) ->
                    case re:run(Path, <<":acknowledge$">>) of
                        {match, _} ->
                            ct:sleep(800),
                            {error, timeout};
                        nomatch ->
                            meck:passthrough([PreparedRequest, Client])
                    end
                end,
                fun() ->
                    Payload = emqx_guid:to_hexstr(emqx_guid:gen()),
                    Messages = [#{<<"data">> => Payload}],
                    pubsub_publish(Config, PubSubTopic, Messages),
                    {ok, _} = snabbkaffe:block_until(
                        ?match_n_events(2, #{?snk_kind := "gcp_pubsub_consumer_worker_ack_error"}),
                        20_000
                    ),
                    %% The minimum deadline pubsub does is 10 s.
                    {ok, _} = ?block_until(#{?snk_kind := message_redelivered}, 30_000),
                    ok
                end
            ),

            {ok, Published} = receive_published(),
            ct:pal("received: ~p", [Published]),

            wait_forgotten(#{timeout => 60_000}),

            %% should be processed only once
            Res = receive_published(#{timeout => 5_000}),

            Res
        end,
        [
            prop_acked_ids_eventually_forgotten(),
            prop_all_pulled_are_acked(),
            prop_handled_only_once(),
            {"message is processed only once", fun(Res, Trace) ->
                ?assertMatch({timeout, _}, Res),
                ?assertMatch(
                    [#{?snk_span := start}, #{?snk_span := {complete, _}}],
                    ?of_kind("gcp_pubsub_consumer_worker_handle_message", Trace)
                ),
                ok
            end}
        ]
    ),
    ok.

t_connection_down_during_pull(Config) ->
    ct:timetrap({seconds, 90}),
    ProxyName = ?config(proxy_name, Config),
    ProxyHost = ?config(proxy_host, Config),
    ProxyPort = ?config(proxy_port, Config),
    [#{pubsub_topic := PubSubTopic}] = ?config(topic_mapping, Config),
    FailureType = timeout,
    ?check_trace(
        begin
            start_and_subscribe_mqtt(Config),

            {{ok, _}, {ok, _}} =
                ?wait_async_action(
                    create_bridge(Config),
                    #{?snk_kind := "gcp_pubsub_consumer_worker_subscription_ready"},
                    10_000
                ),

            ?force_ordering(
                #{
                    ?snk_kind := gcp_pubsub_consumer_worker_pull_async,
                    ?snk_span := start
                },
                #{?snk_kind := cut_connection, ?snk_span := start}
            ),
            ?force_ordering(
                #{?snk_kind := cut_connection, ?snk_span := {complete, _}},
                #{
                    ?snk_kind := gcp_pubsub_consumer_worker_pull_async,
                    ?snk_span := {complete, _}
                }
            ),
            spawn_link(fun() ->
                ?tp_span(
                    cut_connection,
                    #{},
                    begin
                        Payload = emqx_guid:to_hexstr(emqx_guid:gen()),
                        Messages = [#{<<"data">> => Payload}],
                        pubsub_publish(Config, PubSubTopic, Messages),
                        emqx_common_test_helpers:enable_failure(
                            FailureType, ProxyName, ProxyHost, ProxyPort
                        ),
                        ok
                    end
                )
            end),

            ?block_until("gcp_pubsub_consumer_worker_pull_error", 10_000),
            emqx_common_test_helpers:heal_failure(FailureType, ProxyName, ProxyHost, ProxyPort),

            {ok, _Published} = receive_published(),

            Res = receive_published(#{timeout => 5_000}),

            wait_forgotten(#{timeout => 60_000}),

            Res
        end,
        [
            prop_acked_ids_eventually_forgotten(),
            prop_all_pulled_are_acked(),
            prop_handled_only_once(),
            {"message is processed only once", fun(Res, Trace) ->
                ?assertMatch({timeout, _}, Res),
                ?assertMatch(
                    [#{?snk_span := start}, #{?snk_span := {complete, _}}],
                    ?of_kind("gcp_pubsub_consumer_worker_handle_message", Trace)
                ),
                ok
            end}
        ]
    ),
    ok.

%% debugging api
t_get_subscription(Config) ->
    ?check_trace(
        begin
            ?assertMatch(
                {{ok, _}, {ok, _}},
                ?wait_async_action(
                    create_bridge(Config),
                    #{?snk_kind := "gcp_pubsub_consumer_worker_subscription_ready"},
                    10_000
                )
            ),

            [PullWorkerPid | _] = get_pull_worker_pids(Config),
            ?retry(
                _Interval0 = 200,
                _NAttempts0 = 20,
                ?assertMatch(
                    {ok, #{}},
                    emqx_bridge_gcp_pubsub_consumer_worker:get_subscription(PullWorkerPid)
                )
            ),

            ok
        end,
        []
    ),
    ok.

t_cluster_subscription(Config) ->
    [
        #{
            mqtt_topic := MQTTTopic,
            pubsub_topic := PubSubTopic
        }
    ] = ?config(topic_mapping, Config),
    BridgeId = bridge_id(Config),
    Cluster = [{_N1, Opts1} | _] = cluster(Config),
    ?check_trace(
        begin
            Nodes = [N1, N2] = start_cluster(Cluster),
            NumNodes = length(Nodes),
            lists:foreach(fun wait_for_cluster_rpc/1, Nodes),
            erpc:call(N2, fun() -> {ok, _} = create_bridge(Config) end),
            lists:foreach(
                fun(N) ->
                    ?assertMatch(
                        {ok, _},
                        erpc:call(N, emqx_bridge, lookup, [BridgeId]),
                        #{node => N}
                    )
                end,
                Nodes
            ),
            {ok, _} = snabbkaffe:block_until(
                ?match_n_events(
                    NumNodes,
                    #{?snk_kind := "gcp_pubsub_consumer_worker_subscription_ready"}
                ),
                10_000
            ),

            setup_and_start_listeners(N1, Opts1),
            TCPPort1 = emqx_common_test_helpers:listener_port(Opts1, tcp),
            {ok, C1} = emqtt:start_link([{port, TCPPort1}, {proto_ver, v5}]),
            on_exit(fun() -> catch emqtt:stop(C1) end),
            {ok, _} = emqtt:connect(C1),
            {ok, _, [2]} = emqtt:subscribe(C1, MQTTTopic, 2),

            Payload = emqx_guid:to_hexstr(emqx_guid:gen()),
            Messages = [#{<<"data">> => Payload}],
            pubsub_publish(Config, PubSubTopic, Messages),

            ?assertMatch({ok, _Published}, receive_published()),

            ok
        end,
        [prop_handled_only_once()]
    ),
    ok.
