package com.amazon.mq.rabbitmq.publishing;

import com.amazon.mq.rabbitmq.ClusterTopology;

/**
 * Configuration for the multi-threaded publishing infrastructure.
 */
public class PublishingConfiguration {
    private final ClusterTopology clusterTopology;
    private final int confirmationWindow;

    public PublishingConfiguration(ClusterTopology clusterTopology) {
        this(clusterTopology, 100); // Default confirmation window
    }

    public PublishingConfiguration(ClusterTopology clusterTopology, int confirmationWindow) {
        this.clusterTopology = clusterTopology;
        this.confirmationWindow = confirmationWindow;
    }

    public ClusterTopology getClusterTopology() {
        return clusterTopology;
    }

    public int getConfirmationWindow() {
        return confirmationWindow;
    }

    public int getNodeCount() {
        return clusterTopology.getAllNodes().size();
    }
}
