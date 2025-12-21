package com.amazon.mq.rabbitmq.publishing;

import com.amazon.mq.rabbitmq.ClusterTopology;
import com.rabbitmq.http.client.Client;
import com.rabbitmq.http.client.domain.QueueInfo;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Integration tests for MultiThreadedPublisher.
 * These tests require a running RabbitMQ cluster.
 */
class MultiThreadedPublisherIntegrationTest {

    private ClusterTopology clusterTopology;

    @BeforeEach
    void setUp() {
        // Create cluster topology for localhost testing
        clusterTopology = new ClusterTopology("localhost", 15672);

        // Create test queues
        createTestQueues();
    }

    @Test
    void testBasicPublishing() throws Exception {
        PublishingConfiguration config = new PublishingConfiguration(clusterTopology, 4);

        // Create publishing tasks
        List<PublishingTask> tasks = new ArrayList<>();
        for (int i = 0; i < 100; i++) {
            String queueName = "test.queue." + (i % 3);
            String message = "Test message " + i;
            tasks.add(new PublishingTask(queueName, message.getBytes()));
        }

        // Publish messages
        MultiThreadedPublisher publisher = new MultiThreadedPublisher(config);
        PublishingResult result = publisher.publishAsync(tasks);

        // Wait for completion and verify results
        result.awaitCompletion();

        assertTrue(result.isComplete());
        assertEquals(100, result.getPublishedCount());
        assertEquals(100, result.getConfirmedCount());
    }

    @Test
    void testQueueNotFound() throws Exception {
        PublishingConfiguration config = new PublishingConfiguration(clusterTopology);

        // Create task for non-existent queue
        List<PublishingTask> tasks = List.of(
            new PublishingTask("non.existent.queue", "This should fail".getBytes())
        );

        MultiThreadedPublisher publisher = new MultiThreadedPublisher(config);

        assertThrows(PublishingException.QueueNotFoundException.class, () -> {
            publisher.publishAsync(tasks);
        });
    }

    @Test
    void testEmptyTaskList() throws Exception {
        PublishingConfiguration config = new PublishingConfiguration(clusterTopology);

        List<PublishingTask> tasks = new ArrayList<>();

        MultiThreadedPublisher publisher = new MultiThreadedPublisher(config);
        PublishingResult result = publisher.publishAsync(tasks);

        result.awaitCompletion();

        assertTrue(result.isComplete());
        assertEquals(0, result.getPublishedCount());
        assertEquals(0, result.getConfirmedCount());
    }

    @Test
    void testLargeMessageBatch() throws Exception {
        PublishingConfiguration config = new PublishingConfiguration(clusterTopology, 16);

        // Create 1000 tasks with varying message sizes
        List<PublishingTask> tasks = new ArrayList<>();
        for (int i = 0; i < 1000; i++) {
            String queueName = "test.queue." + (i % 3);
            String message = "Large message " + i + " - " + "x".repeat(i % 100);
            tasks.add(new PublishingTask(queueName, message.getBytes()));
        }

        long startTime = System.currentTimeMillis();

        MultiThreadedPublisher publisher = new MultiThreadedPublisher(config);
        PublishingResult result = publisher.publishAsync(tasks);

        result.awaitCompletion();
        long duration = System.currentTimeMillis() - startTime;

        assertTrue(result.isComplete());
        assertEquals(1000, result.getPublishedCount());
        assertEquals(1000, result.getConfirmedCount());

        double messagesPerSecond = (double) result.getPublishedCount() / (duration / 1000.0);
        System.out.printf("Published %d messages in %d ms (%.1f msg/sec)%n",
                result.getPublishedCount(), duration, messagesPerSecond);

        // Performance assertion - should be reasonably fast
        assertTrue(messagesPerSecond > 100, "Publishing rate too slow: " + messagesPerSecond + " msg/sec");
    }

    private void createTestQueues() {
        try {
            Client httpClient = clusterTopology.createHttpClient();

            for (int i = 0; i < 3; i++) {
                String queueName = "test.queue." + i;
                try {
                    QueueInfo queueInfo = new QueueInfo();
                    queueInfo.setName(queueName);
                    queueInfo.setDurable(true);
                    httpClient.declareQueue("/", queueName, queueInfo);
                } catch (Exception e) {
                    // Queue might already exist, ignore
                }
            }
        } catch (Exception e) {
            throw new RuntimeException("Failed to create test queues", e);
        }
    }
}
