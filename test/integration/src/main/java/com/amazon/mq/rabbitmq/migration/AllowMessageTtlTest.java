package com.amazon.mq.rabbitmq.migration;

import com.amazon.mq.rabbitmq.ClusterTopology;
import com.rabbitmq.http.client.Client;
import com.rabbitmq.http.client.domain.QueueInfo;
import java.util.List;
import java.util.Map;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Tests the {@code allow_message_ttl} migration option.
 *
 * <p>Creates a set of mirrored classic queues where a subset carries a queue-level message TTL
 * ({@code x-message-ttl}), and validates the deterministic behavior of the option:
 *
 * <ol>
 *   <li>Without the flag, migration fails because the TTL queues are unsuitable ({@code
 *       message_ttl}).
 *   <li>With {@code allow_message_ttl=true}, migration succeeds and every queue becomes quorum.
 *   <li>The migrated quorum queues retain their {@code x-message-ttl} argument.
 * </ol>
 *
 * <p>This test deliberately uses a long TTL so that no messages expire during the migration window:
 * it covers the deterministic behaviors only. The lossy path - where messages actually expire
 * mid-migration and the forced 100% tolerance accepts the resulting count difference - is
 * timing-dependent and is therefore verified manually rather than asserted here. See the
 * "Reproducing message expiry during migration (manual)" section in docs/SKIP_UNSUITABLE_QUEUES.md
 * for the reproduction recipe.
 */
public class AllowMessageTtlTest {

  private static final Logger logger = LoggerFactory.getLogger(AllowMessageTtlTest.class);

  private static final int QUEUE_COUNT = 10;
  private static final int MESSAGES_PER_QUEUE = 200;
  private static final int TOTAL_MESSAGES = QUEUE_COUNT * MESSAGES_PER_QUEUE;
  // RabbitMQSetup applies x-message-ttl to every 5th queue when TTL is enabled.
  private static final int EXPECTED_TTL_QUEUE_COUNT = QUEUE_COUNT / 5;
  // Long TTL so nothing expires during migration (keeps this test deterministic).
  private static final long TTL_MILLISECONDS = 3_600_000L; // 1 hour

  public static void main(String[] args) {
    try {
      logger.info("Starting allow_message_ttl test");

      // Build the cluster topology from shared connection args (supports
      // --load-balancer, --username, --password, --vhost).
      ClusterTopology topology = MigrationTestSetup.topologyFromArgs(args);
      TestConfiguration config = new TestConfiguration(topology);
      config.setQueueCount(QUEUE_COUNT);
      config.setTotalMessages(TOTAL_MESSAGES);
      config.setEnableTTL(true);
      config.setTtlMilliseconds(TTL_MILLISECONDS);

      // Phase 0: Cleanup
      logger.info("=== Phase 0: Cleanup ===");
      CleanupEnvironment.performCleanup(config);

      // Phase 1: Setup (a subset of queues will carry x-message-ttl)
      logger.info(
          "=== Phase 1: Setup ({} queues, ~{} with message TTL) ===",
          QUEUE_COUNT,
          EXPECTED_TTL_QUEUE_COUNT);
      MigrationTestSetup.execute(config);

      QueueMigrationClient client = config.createMigrationClient();

      // Phase 2: Attempt migration without the flag (should fail on message_ttl)
      logger.info("=== Phase 2: Attempt migration without allow_message_ttl ===");
      if (!attemptMigrationWithoutFlag(client)) {
        logger.error("❌ Migration should have failed without allow_message_ttl");
        System.exit(1);
      }

      // Phase 3: Migrate with the flag (should succeed)
      logger.info("=== Phase 3: Migrate with allow_message_ttl=true ===");
      String migrationId = startMigrationWithFlag(client);
      if (migrationId == null) {
        logger.error("❌ Failed to start migration with allow_message_ttl");
        System.exit(1);
      }

      // Phase 4: Wait for completion
      logger.info("=== Phase 4: Wait for migration to complete ===");
      waitForMigrationComplete(client, migrationId);

      // Phase 5: Validate results
      logger.info("=== Phase 5: Validate results ===");
      if (validateResults(config)) {
        logger.info("✅ allow_message_ttl test passed!");
      } else {
        logger.error("❌ allow_message_ttl test failed");
        System.exit(1);
      }

    } catch (Exception e) {
      logger.error("allow_message_ttl test failed with exception", e);
      System.exit(1);
    }
  }

  private static boolean attemptMigrationWithoutFlag(QueueMigrationClient client) {
    try {
      client.startMigration(false);
      logger.error("Migration started without allow_message_ttl - this should have failed");
      return false;
    } catch (Exception e) {
      String errorMsg = e.getMessage();
      if (errorMsg != null
          && (errorMsg.contains("unsuitable") || errorMsg.contains("validation error"))) {
        logger.info("✅ Migration correctly failed without the flag: {}", errorMsg);
        return true;
      }
      logger.error("Migration failed but with unexpected error: {}", errorMsg);
      return false;
    }
  }

  private static String startMigrationWithFlag(QueueMigrationClient client) throws Exception {
    // skipUnsuitableQueues=false, no batching, allowMessageTtl=true
    QueueMigrationClient.MigrationResponse response =
        client.startMigration(false, null, null, true);
    String migrationId = response.getMigrationId();
    if (migrationId != null) {
      logger.info("Migration started with ID: {}", migrationId);
    }
    return migrationId;
  }

  private static void waitForMigrationComplete(QueueMigrationClient client, String migrationId)
      throws Exception {
    logger.info("Waiting for migration to complete...");

    long startTime = System.currentTimeMillis();
    long timeout = 120_000; // 2 minutes

    while (System.currentTimeMillis() - startTime < timeout) {
      QueueMigrationClient.MigrationDetailResponse details =
          client.getMigrationDetails(migrationId);

      if (details == null) {
        Thread.sleep(2000);
        continue;
      }

      logger.info(
          "Migration status: {}, completed: {}/{} queues",
          details.getStatus(),
          details.getCompletedQueues(),
          details.getTotalQueues());

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

  private static boolean validateResults(TestConfiguration config) throws Exception {
    boolean valid = true;

    Client httpClient = config.createHttpClient();
    List<QueueInfo> queues = httpClient.getQueues("/");
    String queuePrefix = config.getQueuePrefix();

    int quorumCount = 0;
    int classicCount = 0;
    int ttlRetainedCount = 0;

    for (QueueInfo queue : queues) {
      if (!queue.getName().startsWith(queuePrefix)) {
        continue;
      }
      if ("quorum".equals(queue.getType())) {
        quorumCount++;
      } else if ("classic".equals(queue.getType())) {
        classicCount++;
      }

      Map<String, Object> arguments = queue.getArguments();
      if (arguments != null && arguments.containsKey("x-message-ttl")) {
        ttlRetainedCount++;
      }
    }

    logger.info(
        "Queue types: {} quorum, {} classic; {} retain x-message-ttl",
        quorumCount,
        classicCount,
        ttlRetainedCount);

    // All test queues should now be quorum (none blocked, none left classic).
    if (quorumCount != QUEUE_COUNT) {
      logger.error("❌ Expected {} quorum queues, got {}", QUEUE_COUNT, quorumCount);
      valid = false;
    } else {
      logger.info("✅ All {} queues migrated to quorum", QUEUE_COUNT);
    }

    if (classicCount != 0) {
      logger.error("❌ Expected 0 classic queues remaining, got {}", classicCount);
      valid = false;
    } else {
      logger.info("✅ No classic queues remain");
    }

    // The TTL-carrying queues should still have x-message-ttl after migration.
    if (ttlRetainedCount != EXPECTED_TTL_QUEUE_COUNT) {
      logger.error(
          "❌ Expected {} migrated queues to retain x-message-ttl, got {}",
          EXPECTED_TTL_QUEUE_COUNT,
          ttlRetainedCount);
      valid = false;
    } else {
      logger.info("✅ Migrated queues retained x-message-ttl ({} queues)", ttlRetainedCount);
    }

    return valid;
  }
}
