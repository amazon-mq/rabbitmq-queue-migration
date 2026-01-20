package com.amazon.mq.rabbitmq.migration;

import com.rabbitmq.http.client.Client;
import com.rabbitmq.http.client.domain.QueueInfo;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Tests migration interruption functionality.
 * Starts a migration, interrupts after a threshold of completed queues,
 * and validates the interrupted state.
 */
public class InterruptionTest {

    private static final Logger logger = LoggerFactory.getLogger(InterruptionTest.class);

    private static final int QUEUE_COUNT = 30;
    private static final int TOTAL_MESSAGES = 6000;
    private static final int INTERRUPT_AFTER_QUEUES = 10;
    private static final int SMALL_SIZE = 4096;    // 4K
    private static final int MEDIUM_SIZE = 8192;   // 8K
    private static final int LARGE_SIZE = 16384;   // 16K

    public static void main(String[] args) {
        try {
            logger.info("Starting migration interruption test");

            // Build args with test-specific configuration
            String[] testArgs = buildTestArgs(args);
            TestConfiguration config = MigrationTestSetup.parseArguments(testArgs);

            // Phase 0: Cleanup
            logger.info("=== Phase 0: Cleanup ===");
            CleanupEnvironment.performCleanup(config);

            // Phase 1: Setup
            logger.info("=== Phase 1: Setup ({} queues, {} messages) ===", QUEUE_COUNT, TOTAL_MESSAGES);
            MigrationTestSetup.execute(testArgs);

            // Phase 2: Collect pre-migration stats
            logger.info("=== Phase 2: Pre-migration statistics ===");
            Map<String, Long> preMigrationCounts = collectMessageCounts(config);
            logger.info("Pre-migration: {} queues", preMigrationCounts.size());

            // Phase 3: Start migration and interrupt
            logger.info("=== Phase 3: Start migration and interrupt after {} queues ===", INTERRUPT_AFTER_QUEUES);
            QueueMigrationClient client = new QueueMigrationClient(
                config.getHttpHost(), config.getHttpPort(), "guest", "guest");

            QueueMigrationClient.MigrationResponse startResponse = client.startMigration();
            String migrationId = startResponse.getMigrationId();
            if (migrationId == null) {
                logger.error("❌ Failed to get migration ID from start response");
                System.exit(1);
            }
            logger.info("Migration started with ID: {}", migrationId);

            if (!waitAndInterrupt(client, migrationId, INTERRUPT_AFTER_QUEUES)) {
                logger.error("❌ Failed to interrupt migration");
                System.exit(1);
            }

            // Phase 4: Wait for migration to finish after interrupt
            logger.info("=== Phase 4: Wait for migration to complete ===");
            waitForMigrationComplete(client, migrationId);

            // Phase 5: Validate results
            logger.info("=== Phase 5: Validate interruption results ===");
            boolean valid = validateInterruption(client, config, migrationId, preMigrationCounts);

            if (valid) {
                logger.info("✅ Interruption test passed!");
            } else {
                logger.error("❌ Interruption test failed");
                System.exit(1);
            }

        } catch (Exception e) {
            logger.error("Interruption test failed with exception", e);
            System.exit(1);
        }
    }

    private static String[] buildTestArgs(String[] originalArgs) {
        // Test-specific defaults
        String[] defaults = new String[] {
            "--queue-count=" + QUEUE_COUNT,
            "--total-messages=" + TOTAL_MESSAGES,
            "--message-sizes=" + SMALL_SIZE + "," + MEDIUM_SIZE + "," + LARGE_SIZE,
            "--message-distribution=90,5,5",
            "--migration-timeout=600"
        };

        // Merge: defaults first, then originalArgs (which can override or add --hostname, --port, etc.)
        String[] merged = new String[defaults.length + originalArgs.length];
        System.arraycopy(defaults, 0, merged, 0, defaults.length);
        System.arraycopy(originalArgs, 0, merged, defaults.length, originalArgs.length);
        return merged;
    }

    private static Map<String, Long> collectMessageCounts(TestConfiguration config) throws Exception {
        Client httpClient = config.createHttpClient();
        List<QueueInfo> queues = httpClient.getQueues("/");

        Map<String, Long> counts = new HashMap<>();
        for (QueueInfo queue : queues) {
            if (queue.getName().startsWith("test.queue.")) {
                counts.put(queue.getName(), queue.getMessagesReady());
            }
        }
        return counts;
    }

    private static boolean waitAndInterrupt(QueueMigrationClient client, String migrationId, int threshold) throws Exception {
        logger.info("Waiting for {} queues to complete before interrupting...", threshold);

        long startTime = System.currentTimeMillis();
        long timeout = 300_000; // 5 minutes

        while (System.currentTimeMillis() - startTime < timeout) {
            QueueMigrationClient.MigrationDetailResponse details = client.getMigrationDetails(migrationId);

            // Migration record may not exist yet (async creation), retry
            if (details == null) {
                logger.debug("Migration not found yet, waiting...");
                Thread.sleep(1000);
                continue;
            }

            if (details.isCompleted() || details.isInterrupted()) {
                logger.error("Migration finished before we could interrupt (completed {} queues)",
                    details.getCompletedQueues());
                return false;
            }

            if (details.getCompletedQueues() >= threshold) {
                logger.info("Threshold reached: {} queues completed, interrupting...", details.getCompletedQueues());
                client.interruptMigration(migrationId);
                return true;
            }

            logger.debug("Progress: {}/{} queues", details.getCompletedQueues(), details.getTotalQueues());
            Thread.sleep(500);
        }

        logger.error("Timeout waiting for migration to reach threshold");
        return false;
    }

    private static void waitForMigrationComplete(QueueMigrationClient client, String migrationId) throws Exception {
        logger.info("Waiting for migration to finish after interrupt...");

        long startTime = System.currentTimeMillis();
        long timeout = 120_000; // 2 minutes

        while (System.currentTimeMillis() - startTime < timeout) {
            QueueMigrationClient.MigrationDetailResponse details = client.getMigrationDetails(migrationId);

            if (details == null) {
                Thread.sleep(1000);
                continue;
            }

            if (!details.isInProgress()) {
                logger.info("Migration finished with status: {}", details.getStatus());
                return;
            }

            Thread.sleep(1000);
        }

        logger.warn("Timeout waiting for migration to complete after interrupt");
    }

    private static boolean validateInterruption(QueueMigrationClient client, TestConfiguration config,
                                                String migrationId, Map<String, Long> preMigrationCounts) throws Exception {
        boolean valid = true;

        // Get detailed migration status
        QueueMigrationClient.MigrationDetailResponse details = client.getMigrationDetails(migrationId);

        if (details == null) {
            logger.error("❌ Migration {} not found", migrationId);
            return false;
        }

        // Validate overall status is interrupted
        if (!details.isInterrupted()) {
            logger.error("❌ Expected status 'interrupted', got '{}'", details.getStatus());
            valid = false;
        } else {
            logger.info("✅ Migration status is 'interrupted'");
        }

        // Count completed and skipped queues
        int completedCount = 0;
        int skippedCount = 0;
        int skippedWithInterruptReason = 0;

        for (QueueMigrationClient.QueueMigrationStatus qs : details.getQueueStatuses()) {
            if (qs.isCompleted()) {
                completedCount++;
            } else if (qs.isSkipped()) {
                skippedCount++;
                if ("interrupted".equals(qs.getReason())) {
                    skippedWithInterruptReason++;
                }
            }
        }

        logger.info("Queue status breakdown: {} completed, {} skipped", completedCount, skippedCount);

        // Validate we have both completed and skipped queues
        if (completedCount < INTERRUPT_AFTER_QUEUES) {
            logger.error("❌ Expected at least {} completed queues, got {}", INTERRUPT_AFTER_QUEUES, completedCount);
            valid = false;
        } else {
            logger.info("✅ At least {} queues completed", INTERRUPT_AFTER_QUEUES);
        }

        if (skippedCount == 0) {
            logger.error("❌ Expected some skipped queues, got none");
            valid = false;
        } else {
            logger.info("✅ {} queues were skipped", skippedCount);
        }

        // Validate skipped queues have reason "interrupted"
        if (skippedWithInterruptReason != skippedCount) {
            logger.error("❌ Expected all skipped queues to have reason 'interrupted', got {}/{}",
                skippedWithInterruptReason, skippedCount);
            valid = false;
        } else {
            logger.info("✅ All skipped queues have reason 'interrupted'");
        }

        // Validate queue types in RabbitMQ
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

        if (quorumCount != completedCount) {
            logger.error("❌ Quorum queue count ({}) doesn't match completed count ({})", quorumCount, completedCount);
            valid = false;
        } else {
            logger.info("✅ Quorum queue count matches completed migrations");
        }

        if (classicCount != skippedCount) {
            logger.error("❌ Classic queue count ({}) doesn't match skipped count ({})", classicCount, skippedCount);
            valid = false;
        } else {
            logger.info("✅ Classic queue count matches skipped migrations");
        }

        // Validate message counts for completed queues
        Map<String, Long> postMigrationCounts = collectMessageCounts(config);
        boolean messageCountsValid = true;

        for (QueueMigrationClient.QueueMigrationStatus qs : details.getQueueStatuses()) {
            if (qs.isCompleted()) {
                Long preMigration = preMigrationCounts.get(qs.getQueueName());
                Long postMigration = postMigrationCounts.get(qs.getQueueName());

                if (preMigration != null && postMigration != null && !preMigration.equals(postMigration)) {
                    logger.error("❌ Message count mismatch for {}: {} -> {}",
                        qs.getQueueName(), preMigration, postMigration);
                    messageCountsValid = false;
                }
            }
        }

        if (messageCountsValid) {
            logger.info("✅ Message counts preserved for completed queues");
        } else {
            valid = false;
        }

        return valid;
    }
}
