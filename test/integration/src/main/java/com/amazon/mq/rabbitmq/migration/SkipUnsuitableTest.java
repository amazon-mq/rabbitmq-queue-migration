package com.amazon.mq.rabbitmq.migration;

import com.rabbitmq.http.client.Client;
import com.rabbitmq.http.client.domain.QueueInfo;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.List;

/**
 * Tests skip unsuitable queues functionality.
 * Creates mix of suitable and unsuitable queues, validates that:
 * 1. Migration fails without skip flag
 * 2. Migration succeeds with skip flag
 * 3. Unsuitable queues are skipped with correct reasons
 */
public class SkipUnsuitableTest {

    private static final Logger logger = LoggerFactory.getLogger(SkipUnsuitableTest.class);

    private static final int SUITABLE_QUEUE_COUNT = 20;
    private static final int UNSUITABLE_QUEUE_COUNT = 5;
    private static final int TOTAL_QUEUE_COUNT = SUITABLE_QUEUE_COUNT + UNSUITABLE_QUEUE_COUNT;
    private static final int MESSAGES_PER_QUEUE = 200;
    private static final int TOTAL_MESSAGES = TOTAL_QUEUE_COUNT * MESSAGES_PER_QUEUE;

    public static void main(String[] args) {
        try {
            logger.info("Starting skip unsuitable queues test");

            String[] testArgs = buildTestArgs(args);
            TestConfiguration config = MigrationTestSetup.parseArguments(testArgs);

            // Phase 0: Cleanup
            logger.info("=== Phase 0: Cleanup ===");
            CleanupEnvironment.performCleanup(config);

            // Phase 1: Setup with unsuitable queues
            logger.info("=== Phase 1: Setup ({} suitable, {} unsuitable queues) ===",
                SUITABLE_QUEUE_COUNT, UNSUITABLE_QUEUE_COUNT);
            MigrationTestSetup.execute(testArgs);

            QueueMigrationClient client = new QueueMigrationClient(
                config.getHttpHost(), config.getHttpPort(), "guest", "guest");

            // Phase 2: Attempt migration without skip flag (should fail)
            logger.info("=== Phase 2: Attempt migration without skip flag ===");
            boolean failedAsExpected = attemptMigrationWithoutSkip(client);
            if (!failedAsExpected) {
                logger.error("❌ Migration should have failed without skip flag");
                System.exit(1);
            }

            // Phase 3: Attempt migration with skip flag (should succeed)
            logger.info("=== Phase 3: Attempt migration with skip flag ===");
            String migrationId = startMigrationWithSkip(client);
            if (migrationId == null) {
                logger.error("❌ Failed to start migration with skip flag");
                System.exit(1);
            }

            // Phase 4: Wait for completion
            logger.info("=== Phase 4: Wait for migration to complete ===");
            waitForMigrationComplete(client, migrationId);

            // Phase 5: Validate results
            logger.info("=== Phase 5: Validate results ===");
            boolean valid = validateResults(client, config, migrationId);

            if (valid) {
                logger.info("✅ Skip unsuitable queues test passed!");
            } else {
                logger.error("❌ Skip unsuitable queues test failed");
                System.exit(1);
            }

        } catch (Exception e) {
            logger.error("Skip unsuitable queues test failed with exception", e);
            System.exit(1);
        }
    }

    private static String[] buildTestArgs(String[] originalArgs) {
        String[] defaults = new String[]{
            "--queue-count", String.valueOf(TOTAL_QUEUE_COUNT),
            "--total-messages", String.valueOf(TOTAL_MESSAGES),
            "--unsuitable-queue-count", String.valueOf(UNSUITABLE_QUEUE_COUNT)
        };

        String[] merged = new String[defaults.length + originalArgs.length];
        System.arraycopy(defaults, 0, merged, 0, defaults.length);
        System.arraycopy(originalArgs, 0, merged, defaults.length, originalArgs.length);
        return merged;
    }

    private static boolean attemptMigrationWithoutSkip(QueueMigrationClient client) {
        try {
            client.startMigration(false);
            logger.error("Migration started without skip flag - this should have failed");
            return false;
        } catch (Exception e) {
            String errorMsg = e.getMessage();
            if (errorMsg != null && errorMsg.contains("unsuitable")) {
                logger.info("✅ Migration correctly failed with unsuitable queues error");
                return true;
            } else {
                logger.error("Migration failed but with unexpected error: {}", errorMsg);
                return false;
            }
        }
    }

    private static String startMigrationWithSkip(QueueMigrationClient client) throws Exception {
        QueueMigrationClient.MigrationResponse response = client.startMigration(true);
        String migrationId = response.getMigrationId();
        if (migrationId != null) {
            logger.info("Migration started with ID: {}", migrationId);
        }
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
                logger.error("Migration failed: {}", details.getStatus());
                throw new RuntimeException("Migration failed");
            }

            if (details.isCompleted()) {
                logger.info("Migration completed successfully");
                return;
            }

            Thread.sleep(2000);
        }

        throw new RuntimeException("Timeout waiting for migration to complete");
    }

    private static boolean validateResults(QueueMigrationClient client, TestConfiguration config,
                                          String migrationId) throws Exception {
        boolean valid = true;

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

        // Count completed and skipped queues
        int completedCount = 0;
        int skippedCount = 0;
        int skippedWithUnsuitableReason = 0;

        for (QueueMigrationClient.QueueMigrationStatus qs : details.getQueueStatuses()) {
            if (qs.isCompleted()) {
                completedCount++;
            } else if (qs.isSkipped()) {
                skippedCount++;
                String reason = qs.getReason();
                if ("unsuitable_overflow".equals(reason)) {
                    skippedWithUnsuitableReason++;
                }
            }
        }

        logger.info("Queue status breakdown: {} completed, {} skipped", completedCount, skippedCount);

        // Validate counts
        if (completedCount != SUITABLE_QUEUE_COUNT) {
            logger.error("❌ Expected {} completed queues, got {}", SUITABLE_QUEUE_COUNT, completedCount);
            valid = false;
        } else {
            logger.info("✅ Correct number of queues completed");
        }

        if (skippedCount != UNSUITABLE_QUEUE_COUNT) {
            logger.error("❌ Expected {} skipped queues, got {}", UNSUITABLE_QUEUE_COUNT, skippedCount);
            valid = false;
        } else {
            logger.info("✅ Correct number of queues skipped");
        }

        if (skippedWithUnsuitableReason != UNSUITABLE_QUEUE_COUNT) {
            logger.error("❌ Expected all {} skipped queues to have 'unsuitable_overflow' reason, got {}",
                UNSUITABLE_QUEUE_COUNT, skippedWithUnsuitableReason);
            valid = false;
        } else {
            logger.info("✅ All skipped queues have correct reason");
        }

        // Validate queue types
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

        if (quorumCount != SUITABLE_QUEUE_COUNT) {
            logger.error("❌ Expected {} quorum queues, got {}", SUITABLE_QUEUE_COUNT, quorumCount);
            valid = false;
        } else {
            logger.info("✅ Correct number of quorum queues");
        }

        if (classicCount != UNSUITABLE_QUEUE_COUNT) {
            logger.error("❌ Expected {} classic queues remaining, got {}", UNSUITABLE_QUEUE_COUNT, classicCount);
            valid = false;
        } else {
            logger.info("✅ Correct number of classic queues remaining");
        }

        return valid;
    }
}
