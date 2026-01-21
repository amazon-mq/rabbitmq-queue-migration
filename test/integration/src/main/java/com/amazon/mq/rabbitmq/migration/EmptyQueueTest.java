package com.amazon.mq.rabbitmq.migration;

import com.amazon.mq.rabbitmq.ClusterTopology;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public class EmptyQueueTest {
    private static final Logger logger = LoggerFactory.getLogger(EmptyQueueTest.class);
    private static final int QUEUE_COUNT = 20;

    public static void main(String[] args) {
        try {
            logger.info("Starting empty queue migration test with {} queues", QUEUE_COUNT);

            // Parse hostname and port from args
            String hostname = "localhost";
            int port = 15672;
            for (String arg : args) {
                if (arg.startsWith("--hostname=")) {
                    hostname = arg.substring(11);
                } else if (arg.startsWith("--port=")) {
                    port = Integer.parseInt(arg.substring(7));
                }
            }

            // Create configuration directly
            ClusterTopology topology = new ClusterTopology(hostname, port);
            TestConfiguration config = new TestConfiguration(topology);
            config.setQueueCount(QUEUE_COUNT);
            config.setTotalMessages(0);  // No messages

            // Phase 0: Cleanup
            logger.info("=== Phase 0: Cleanup ===");
            CleanupEnvironment.performCleanup(config);

            // Phase 1: Setup
            logger.info("=== Phase 1: Setup ({} empty queues) ===", QUEUE_COUNT);
            MigrationTestSetup.execute(config);

            QueueMigrationClient client = new QueueMigrationClient(
                config.getHttpHost(), config.getHttpPort(), "guest", "guest");

            // Phase 2: Start migration
            logger.info("=== Phase 2: Starting migration ===");
            QueueMigrationClient.MigrationResponse response = client.startMigration(false, null, null);
            String migrationId = response.getMigrationId();
            if (migrationId == null) {
                throw new RuntimeException("Failed to get migration ID from start response");
            }
            logger.info("Migration started with ID: {}", migrationId);

            // Phase 3: Wait for completion
            logger.info("=== Phase 3: Waiting for completion ===");
            waitForMigrationComplete(client, migrationId);

            // Phase 4: Validate results
            logger.info("=== Phase 4: Validating results ===");
            validateResults(client, migrationId);

            logger.info("✅ Empty queue test passed!");
        } catch (Exception e) {
            logger.error("❌ Empty queue test failed", e);
            System.exit(1);
        }
    }

    private static void waitForMigrationComplete(QueueMigrationClient client, String migrationId) throws Exception {
        logger.info("Waiting for migration to complete...");

        long startTime = System.currentTimeMillis();
        long timeout = 120_000; // 2 minutes

        while (System.currentTimeMillis() - startTime < timeout) {
            QueueMigrationClient.MigrationDetailResponse details = client.getMigrationDetails(migrationId);

            if (details == null) {
                Thread.sleep(2000);
                continue;
            }

            String status = details.getStatus();
            logger.info("Migration status: {}, completed: {}/{}", status,
                details.getCompletedQueues(), details.getTotalQueues());

            if ("completed".equals(status) || "failed".equals(status)) {
                return;
            }

            Thread.sleep(2000);
        }

        throw new RuntimeException("Migration did not complete within timeout");
    }

    private static void validateResults(QueueMigrationClient client, String migrationId) throws Exception {
        QueueMigrationClient.MigrationDetailResponse details = client.getMigrationDetails(migrationId);

        logger.info("Migration status: {}", details.getStatus());
        logger.info("Completed queues: {}", details.getCompletedQueues());
        logger.info("Total queues: {}", details.getTotalQueues());

        if (!"completed".equals(details.getStatus())) {
            throw new RuntimeException("Expected status 'completed', got: " + details.getStatus());
        }

        if (details.getCompletedQueues() != QUEUE_COUNT) {
            throw new RuntimeException(
                String.format("Expected %d completed queues, got: %d",
                    QUEUE_COUNT, details.getCompletedQueues())
            );
        }

        if (details.getTotalQueues() != QUEUE_COUNT) {
            throw new RuntimeException(
                String.format("Expected %d total queues, got: %d",
                    QUEUE_COUNT, details.getTotalQueues())
            );
        }

        // Verify no queues were skipped
        long skippedCount = details.getQueueStatuses().stream()
            .filter(QueueMigrationClient.QueueMigrationStatus::isSkipped)
            .count();

        if (skippedCount != 0) {
            throw new RuntimeException(
                String.format("Expected 0 skipped queues, got: %d", skippedCount)
            );
        }
    }
}
