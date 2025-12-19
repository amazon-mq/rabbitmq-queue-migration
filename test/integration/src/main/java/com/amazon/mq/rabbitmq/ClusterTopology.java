package com.amazon.mq.rabbitmq;

import com.rabbitmq.http.client.Client;
import com.rabbitmq.http.client.ClientParameters;
import com.rabbitmq.http.client.domain.OverviewResponse;

import java.net.MalformedURLException;
import java.net.URISyntaxException;
import java.util.ArrayList;
import java.util.List;
import java.util.HashMap;
import java.util.Map;

/**
 * Discovers and maintains RabbitMQ cluster topology information.
 * Eagerly discovers all broker nodes and their AMQP/HTTP ports upon initialization.
 */
public class ClusterTopology {
    private final String hostname;
    private final int port;
    private final String username;
    private final String password;
    private final Client httpClient;

    private List<AmqpEndpoint> amqpEndpoints = new ArrayList<>();
    private List<HttpEndpoint> httpEndpoints = new ArrayList<>();
    private Map<String, BrokerNode> brokerNodes;
    private boolean initialized = false;

    public ClusterTopology(String hostname, int port) {
        this(hostname, port, "guest", "guest");
    }

    public ClusterTopology(String hostname, int port, String username, String password) {
        this.hostname = hostname;
        this.port = port;
        this.username = username;
        this.password = password;

        try {
            // Add /api/ suffix for RabbitMQ HTTP API compatibility
            String baseUrl = "http://" + hostname + ":" + port;
            String apiUrl = baseUrl.endsWith("/") ? baseUrl + "api/" : baseUrl + "/api/";

            ClientParameters params = new ClientParameters()
                .url(apiUrl)
                .username(username)
                .password(password);
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

                if ("amqp".equals(listener.getProtocol())) {
                    amqpPorts.put(nodeName, listenerPort);
                } else if ("http".equals(listener.getProtocol())) {
                    httpPorts.put(nodeName, listenerPort);
                }
            });

            // Create BrokerNode instances
            amqpPorts.forEach((nodeName, amqpPort) -> {
                String nodeHostname = nodeName.contains("@") ?
                    nodeName.substring(nodeName.indexOf("@") + 1) : nodeName;
                int httpPort = httpPorts.getOrDefault(nodeName, 15672); // Default HTTP port

                brokerNodes.put(nodeName, new BrokerNode(nodeName, nodeHostname, amqpPort, httpPort));
                amqpEndpoints.add(new AmqpEndpoint(nodeHostname, amqpPort, this.username, this.password));
                httpEndpoints.add(new HttpEndpoint(nodeHostname, httpPort, this.username, this.password));
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

            // Build API URL with proper /api/ suffix
            String baseUrl = "http://" + node.getHostname() + ":" + node.getHttpPort();
            String apiUrl = baseUrl.endsWith("/") ? baseUrl + "api/" : baseUrl + "/api/";

            ClientParameters params = new ClientParameters()
                .url(apiUrl)
                .username(username)
                .password(password);

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

    public int getNodeCount() {
        return amqpEndpoints.size();
    }
}
