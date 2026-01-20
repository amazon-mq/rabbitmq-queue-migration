package com.amazon.mq.rabbitmq.migration;

import com.amazon.mq.rabbitmq.ClusterTopology;
import com.rabbitmq.http.client.Client;
import com.rabbitmq.http.client.domain.QueueInfo;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.stream.Collectors;

/**
 * Tests batch migration functionality.
 * Creates queues with varying sizes, then migrates in batches with different ordering.
 */
public class BatchMigrationTest {

    private static final Logger logger = LoggerFactory.getLogger(BatchMigrationTest.class);

    private static final int TOTAL_QUEUE_COUNT = 50;
    private static final int MESSAGES_PER_QUEUE = 200;
    private static final int TOTAL_MESSAGES = TOTAL_QUEUE_COUNT * MESSAGES_PER_QUEUE;
    private static final int BATCH_SIZE = 10;

    public static void main(String[] args) {
        try {
            logger.info("Starting batch migration test");

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
            config.setQueueCount(TOTAL_QUEUE_COUNT);
            config.setTotalMessages(TOTAL_MESSAGES);

            // Phase 0: Cleanup
            logger.info("=== Phase 0: Cleanup ===");
            CleanupEnvironment.performCleanup(config);

            // Phase 1: Setup
            logger.info("=== Phase 1: Setup ({} queues, {} messages) ===", TOTAL_QUEUE_COUNT, TOTAL_MESSAGES);
            MigrationTestSetup.execute(config);

            QueueMigrationClient client = new QueueMigrationClient(
                config.getHttpHost(), config.getHttpPort(), "guest", "guest");

            // Phase 2: First batch - 10 smallest queues
            logger.info("=== Phase 2: First batch migration (10 smallest queues) ===");
            String migrationId1 = runBatchMigration(client, BATCH_SIZE, "smallest_first");
            if (!validateBatchResult(config, migrationId1, 10, 40)) {
                logger.error("❌ First batch migration validation failed");
                System.exit(1);
            }

            // Phase 3: Second batch - 10 smallest from remaining
            logger.info("=== Phase 3: Second batch migration (10 smallest from remaining) ===");
            String migrationId2 = runBatchMigration(client, BATCH_SIZE, "smallest_first");
            if (!validateBatchResult(config, migrationId2, 20, 30)) {
                logger.error("❌ Second batch migration validation failed");
                System.exit(1);
            }

            // Phase 4: Third batch - 10 largest from remaining
            logger.info("=== Phase 4: Third batch migration (10 largest from remaining) ===");
            String migrationId3 = runBatchMigration(client, BATCH_SIZE, "largest_first");
            if (!validateBatchResult(config, migrationId3, 30, 20)) {
                logger.error("❌ Third batch migration validation failed");
                System.exit(1);
            }

            logger.info("✅ Batch migration test passed!");

        } catch (Exception e) {
            logger.error("Batch migration test failed with exception", e);
            System.exit(1);
        }
    }

    private static String runBatchMigration(QueueMigrationClient client, int batchSize, String batchOrder) throws Exception {
        logger.info("Starting migration with batch_size={}, batch_order={}", batchSize, batchOrder);

        QueueMigrationClient.MigrationResponse response = client.startMigration(batchSize, batchOrder);
        String migrationId = response.getMigrationId();
        if (migrationId == null) {
            throw new RuntimeException("Failed to get migration ID from start response");
        }
        logger.info("Migration started with ID: {}", migrationId);

        // Wait for completion
        waitForMigrationComplete(client, migrationId);

        return migrationId;
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

            logger.info("Migration status: {}, completed: {}/{} queues",
                details.getStatus(), details.getCompletedQueues(), details.getTotalQueues());

            if (details.isFailed()) {
                throw new RuntimeException("Migration failed: " + details.getStatus());
            }

            if (details.isCompleted()) {
                logger.info("Migration completed successfully");
                return;
            }

            Thread.sleep(2000);
        }

        throw new RuntimeException("Timeout waiting for migration to complete");
    }

    private static boolean validateBatchResult(TestConfiguration config, String migrationId,
                                               int expectedQuorum, int expectedClassic) throws Exception {
        boolean valid = true;

        QueueMigrationClient client = new QueueMigrationClient(
            config.getHttpHost(), config.getHttpPort(), "guest", "guest");

        QueueMigrationClient.MigrationDetailResponse details = client.getMigrationDetails(migrationId);
        if (details == null) {
            logger.error("❌ Migration not found");
            return false;
        }

        // Validate status is completed
        if (!details.isCompleted()) {
            logger.error("❌ Expected status 'completed', got '{}'", details.getStatus());
            valid = false;
        } else {
            logger.info("✅ Migration status is 'completed'");
        }

        // Validate batch size
        if (details.getCompletedQueues() != BATCH_SIZE) {
            logger.error("❌ Expected {} queues migrated, got {}", BATCH_SIZE, details.getCompletedQueues());
            valid = false;
        } else {
            logger.info("✅ Correct batch size migrated");
        }

        // Validate total queue types
        Client httpClient = config.createHttpClient();
        List<QueueInfo> queues = httpClient.getQueues("/");

        int quorumCount = 0;
        int classicCount = 0;

        for (QueueInfo queue : queues) {
            if (queue.getName().startsWith("test.queue.")) {
                if ("quorum".equals(queue.getType())) {
                    quorumCount++;
                } else if ("classic".equals(queue.getType())) {
                    classicCount++;
                }
            }
        }

        logger.info("Queue types: {} quorum, {} classic", quorumCount, classicCount);

        if (quorumCount != expectedQuorum) {
            logger.error("❌ Expected {} quorum queues, got {}", expectedQuorum, quorumCount);
            valid = false;
        } else {
            logger.info("✅ Correct number of quorum queues");
        }

        if (classicCount != expectedClassic) {
            logger.error("❌ Expected {} classic queues, got {}", expectedClassic, classicCount);
            valid = false;
        } else {
            logger.info("✅ Correct number of classic queues");
        }

        return valid;
    }
}
