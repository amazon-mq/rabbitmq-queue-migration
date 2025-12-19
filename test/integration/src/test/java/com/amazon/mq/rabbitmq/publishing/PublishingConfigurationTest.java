package com.amazon.mq.rabbitmq.publishing;

import com.amazon.mq.rabbitmq.ClusterTopology;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Unit tests for PublishingConfiguration.
 */
class PublishingConfigurationTest {

    @Test
    void testBasicConfiguration() {
        ClusterTopology clusterTopology = new ClusterTopology("localhost", 15672);
        PublishingConfiguration config = new PublishingConfiguration(clusterTopology);

        assertNotNull(config.getClusterTopology());
        assertEquals(100, config.getConfirmationWindow()); // Default value
        assertTrue(config.getNodeCount() > 0);
    }

    @Test
    void testConfigurationWithCustomWindow() {
        ClusterTopology clusterTopology = new ClusterTopology("localhost", 15672);
        PublishingConfiguration config = new PublishingConfiguration(clusterTopology, 50);

        assertNotNull(config.getClusterTopology());
        assertEquals(50, config.getConfirmationWindow());
        assertTrue(config.getNodeCount() > 0);
    }

    @Test
    void testClusterTopologyAccess() {
        ClusterTopology clusterTopology = new ClusterTopology("localhost", 15672);
        PublishingConfiguration config = new PublishingConfiguration(clusterTopology);

        assertSame(clusterTopology, config.getClusterTopology());
        assertEquals("localhost", config.getClusterTopology().getHostname());
        assertEquals(15672, config.getClusterTopology().getPort());
    }

    @Test
    void testNodeCountReflectsClusterSize() {
        ClusterTopology clusterTopology = new ClusterTopology("localhost", 15672);
        PublishingConfiguration config = new PublishingConfiguration(clusterTopology);

        // Node count should reflect the actual cluster size discovered by ClusterTopology
        assertTrue(config.getNodeCount() > 0);
        assertEquals(clusterTopology.getAllNodes().size(), config.getNodeCount());
    }
}
