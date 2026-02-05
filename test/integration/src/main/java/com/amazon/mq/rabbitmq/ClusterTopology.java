package com.amazon.mq.rabbitmq;

import com.rabbitmq.http.client.Client;
import com.rabbitmq.http.client.ClientParameters;
import com.rabbitmq.http.client.JdkHttpClientHttpLayer;
import com.rabbitmq.http.client.domain.OverviewResponse;

import java.net.MalformedURLException;
import java.net.URISyntaxException;
import java.util.ArrayList;
import java.util.List;
import java.util.HashMap;
import java.util.Map;
import javax.net.ssl.SSLContext;

/**
 * Discovers and maintains RabbitMQ cluster topology information.
 * Eagerly discovers all broker nodes and their AMQP/HTTP ports upon initialization.
 *
 * Supports two modes:
 * - Direct mode: connects directly to cluster nodes using discovered hostnames
 * - Load balancer mode: all connections go through the load balancer endpoint
 */
public class ClusterTopology {
    private static final int LOAD_BALANCER_HTTPS_PORT = 443;
    private static final int LOAD_BALANCER_AMQPS_PORT = 5671;

    private final String hostname;
    private final int port;
    private final String username;
    private final String password;
    private final String virtualHost;
    private final boolean loadBalancerMode;
    private final SSLContext sslContext;
    private final Client httpClient;

    private List<AmqpEndpoint> amqpEndpoints = new ArrayList<>();
    private List<HttpEndpoint> httpEndpoints = new ArrayList<>();
    private Map<String, BrokerNode> brokerNodes;
    private boolean initialized = false;

    public ClusterTopology(String hostname, int port) {
        this(hostname, port, "guest", "guest", "/", false);
    }

    public ClusterTopology(String hostname, int port, String username, String password, String virtualHost) {
        this(hostname, port, username, password, virtualHost, false);
    }

    public ClusterTopology(String hostname, int port, String username, String password,
                           String virtualHost, boolean loadBalancerMode) {
        this.hostname = hostname;
        this.port = loadBalancerMode ? LOAD_BALANCER_HTTPS_PORT : port;
        this.username = username;
        this.password = password;
        this.virtualHost = virtualHost;
        this.loadBalancerMode = loadBalancerMode;
        this.sslContext = loadBalancerMode ? TlsUtils.createTrustAllSslContext() : null;

        try {
            String scheme = loadBalancerMode ? "https" : "http";
            String baseUrl = scheme + "://" + hostname + ":" + this.port;
            String apiUrl = baseUrl + "/api/";

            ClientParameters params = new ClientParameters()
                .url(apiUrl)
                .username(username)
                .password(password);

            if (loadBalancerMode) {
                params.httpLayerFactory(JdkHttpClientHttpLayer.configure()
                    .clientBuilderConsumer(builder -> builder.sslContext(sslContext))
                    .create());
            }

            this.httpClient = new Client(params);

            // Eagerly discover cluster topology
            discoverClusterTopology();
            this.initialized = true;

        } catch (MalformedURLException | URISyntaxException e) {
            throw new RuntimeException("Failed to initialize cluster topology discovery", e);
        }
    }

    private void discoverClusterTopology() {
        try {
            OverviewResponse overview = httpClient.getOverview();
            brokerNodes = new HashMap<>();

            // Discover all broker nodes with AMQP and HTTP ports
            Map<String, Integer> amqpPorts = new HashMap<>();
            Map<String, Integer> httpPorts = new HashMap<>();

            overview.getListeners().forEach(listener -> {
                String nodeName = listener.getNode();
                int listenerPort = listener.getPort();
                String protocol = listener.getProtocol();

                if ("amqp".equals(protocol) || "amqp/ssl".equals(protocol)) {
                    amqpPorts.put(nodeName, listenerPort);
                } else if ("http".equals(protocol) || "https".equals(protocol)) {
                    httpPorts.put(nodeName, listenerPort);
                }
            });

            // Create BrokerNode instances
            amqpPorts.forEach((nodeName, amqpPort) -> {
                String nodeHostname;
                int effectiveAmqpPort;
                int effectiveHttpPort;

                if (loadBalancerMode) {
                    // In load balancer mode, all connections go through the load balancer
                    nodeHostname = this.hostname;
                    effectiveAmqpPort = LOAD_BALANCER_AMQPS_PORT;
                    effectiveHttpPort = LOAD_BALANCER_HTTPS_PORT;
                } else {
                    // Direct mode: use discovered node hostnames
                    nodeHostname = nodeName.contains("@") ?
                        nodeName.substring(nodeName.indexOf("@") + 1) : nodeName;
                    effectiveAmqpPort = amqpPort;
                    effectiveHttpPort = httpPorts.getOrDefault(nodeName, 15672);
                }

                brokerNodes.put(nodeName, new BrokerNode(nodeName, nodeHostname, effectiveAmqpPort, effectiveHttpPort));
                amqpEndpoints.add(new AmqpEndpoint(nodeHostname, effectiveAmqpPort, this.username, this.password, this.virtualHost));
                httpEndpoints.add(new HttpEndpoint(nodeHostname, effectiveHttpPort, this.username, this.password));
            });

        } catch (Exception e) {
            throw new RuntimeException("Failed to discover cluster topology", e);
        }
    }

    /**
     * Get all broker nodes in the cluster.
     */
    public Map<String, BrokerNode> getAllNodes() {
        if (!initialized) {
            throw new IllegalStateException("ClusterTopology not initialized");
        }
        return new HashMap<>(brokerNodes);
    }

    public AmqpEndpoint getAmqpEndpoint(int idx) {
        return this.amqpEndpoints.get(idx);
    }

    public String getHttpHost() {
        return this.httpEndpoints.get(0).getHostname();
    }

    public int getHttpPort() {
        return this.httpEndpoints.get(0).getPort();
    }

    /**
     * Create a new HTTP client instance using a random discovered HTTP endpoint.
     * This ensures the URL properly ends with /api/ for RabbitMQ HTTP API compatibility.
     */
    public Client createHttpClient() {
        int randomIdx = (int)(Math.random() * brokerNodes.size());
        return createHttpClient(randomIdx);
    }

    public Client createHttpClient(int idx) {
        if (!initialized) {
            throw new IllegalStateException("ClusterTopology not initialized");
        }

        try {
            BrokerNode[] nodes = brokerNodes.values().toArray(new BrokerNode[0]);
            BrokerNode node = nodes[idx];

            String scheme = loadBalancerMode ? "https" : "http";
            String baseUrl = scheme + "://" + node.getHostname() + ":" + node.getHttpPort();
            String apiUrl = baseUrl + "/api/";

            ClientParameters params = new ClientParameters()
                .url(apiUrl)
                .username(username)
                .password(password);

            if (loadBalancerMode) {
                params.httpLayerFactory(JdkHttpClientHttpLayer.configure()
                    .clientBuilderConsumer(builder -> builder.sslContext(sslContext))
                    .create());
            }

            return new Client(params);

        } catch (MalformedURLException | URISyntaxException e) {
            throw new RuntimeException("Failed to create HTTP client", e);
        }
    }

    public String getHostname() {
        return hostname;
    }

    public int getPort() {
        return port;
    }

    public String getUsername() {
        return username;
    }

    public String getPassword() {
        return password;
    }

    public String getVirtualHost() {
        return virtualHost;
    }

    public int getNodeCount() {
        return amqpEndpoints.size();
    }

    public boolean isLoadBalancerMode() {
        return loadBalancerMode;
    }

    public SSLContext getSslContext() {
        return sslContext;
    }
}
