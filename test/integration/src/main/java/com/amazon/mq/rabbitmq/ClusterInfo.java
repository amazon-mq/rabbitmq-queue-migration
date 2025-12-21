package com.amazon.mq.rabbitmq;

import java.util.Map;
import java.util.Set;

/**
 * Contains complete RabbitMQ cluster information including broker nodes and queue leaders.
 */
public class ClusterInfo {
    private final Map<String, BrokerNode> nodes; // nodeName -> BrokerNode
    private final Map<String, String> queueLeaders; // queueName -> nodeName

    public ClusterInfo(Map<String, BrokerNode> nodes, Map<String, String> queueLeaders) {
        this.nodes = nodes;
        this.queueLeaders = queueLeaders;
    }

    public Map<String, BrokerNode> getNodes() {
        return nodes;
    }

    public Map<String, String> getQueueLeaders() {
        return queueLeaders;
    }

    /**
     * Get the broker node that leads the specified queue.
     */
    public BrokerNode getQueueLeaderNode(String queueName) {
        String leaderNodeName = queueLeaders.get(queueName);
        if (leaderNodeName == null) {
            return null;
        }
        return nodes.get(leaderNodeName);
    }

    /**
     * Get all unique broker nodes that lead at least one queue.
     */
    public Set<BrokerNode> getRequiredNodes() {
        return queueLeaders.values().stream()
                .map(nodes::get)
                .collect(java.util.stream.Collectors.toSet());
    }

    @Override
    public String toString() {
        return String.format("ClusterInfo{nodes=%d, queueLeaders=%d}",
                nodes.size(), queueLeaders.size());
    }
}
