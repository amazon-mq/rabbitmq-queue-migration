package com.amazon.mq.rabbitmq.migration;

import com.amazon.mq.rabbitmq.ClusterTopology;
import com.rabbitmq.http.client.Client;
import com.rabbitmq.http.client.domain.QueueInfo;
import java.util.List;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Tests migration behavior when some queues are already quorum type. Validates idempotency -
 * already-converted queues should be skipped.
 */
public class AlreadyQuorumTest {

  private static final Logger logger = LoggerFactory.getLogger(AlreadyQuorumTest.class);

  private static final int CLASSIC_QUEUE_COUNT = 15;
  private static final int QUORUM_QUEUE_COUNT = 10;
  private static final int TOTAL_MESSAGES = 3000;

  public static void main(String[] args) {
    try {
      logger.info("Starting already-quorum queue migration test");

      // Parse hostname and port from args
      String hostname = "localhost";
      int port = 15672;
      boolean portSpecified = false;
      boolean loadBalancer = false;
      for (String arg : args) {
        if (arg.startsWith("--hostname=")) {
          hostname = arg.substring(11);
        } else if (arg.startsWith("--port=")) {
          port = Integer.parseInt(arg.substring(7));
          portSpecified = true;
        } else if (arg.equals("--load-balancer")) {
          loadBalancer = true;
        }
      }

      if (loadBalancer && portSpecified && port != 443) {
        logger.error("When --load-balancer is specified, --port must be 443 (got {})", port);
        System.exit(1);
      }

      // Create configuration directly
      ClusterTopology topology =
          new ClusterTopology(hostname, port, "guest", "guest", "/", loadBalancer);
      TestConfiguration config = new TestConfiguration(topology);
      config.setQueueCount(CLASSIC_QUEUE_COUNT);
      config.setQuorumQueueCount(QUORUM_QUEUE_COUNT);
      config.setTotalMessages(TOTAL_MESSAGES);

      // Phase 0: Cleanup
      logger.info("=== Phase 0: Cleanup ===");
      CleanupEnvironment.performCleanup(config);

      // Phase 1: Setup
      logger.info(
          "=== Phase 1: Setup ({} classic + {} quorum queues, {} messages) ===",
          CLASSIC_QUEUE_COUNT,
          QUORUM_QUEUE_COUNT,
          TOTAL_MESSAGES);
      MigrationTestSetup.execute(config);

      QueueMigrationClient client = config.createMigrationClient();

      // Phase 2: Verify initial state
      logger.info("=== Phase 2: Verifying initial state ===");
      verifyInitialState(config);

      // Phase 3: Start migration
      logger.info("=== Phase 3: Starting migration ===");
      QueueMigrationClient.MigrationResponse response = client.startMigration(false, null, null);
      String migrationId = response.getMigrationId();
      if (migrationId == null) {
        throw new RuntimeException("Failed to get migration ID from start response");
      }
      logger.info("Migration started with ID: {}", migrationId);

      // Phase 4: Wait for completion
      logger.info("=== Phase 4: Waiting for completion ===");
      waitForMigrationComplete(client, migrationId);

      // Phase 5: Validate results
      logger.info("=== Phase 5: Validating results ===");
      validateResults(client, migrationId, config);

      logger.info("✅ Already-quorum queue test passed!");
    } catch (Exception e) {
      logger.error("❌ Already-quorum queue test failed", e);
      System.exit(1);
    }
  }

  private static void verifyInitialState(TestConfiguration config) throws Exception {
    Client httpClient = config.createHttpClient();

    List<QueueInfo> queues = httpClient.getQueues("/");

    int classicCount = 0;
    int quorumCount = 0;

    for (QueueInfo queue : queues) {
      String queueName = queue.getName();
      if (!queueName.startsWith("test.")) {
        continue;
      }

      if ("classic".equals(queue.getType())) {
        classicCount++;
      } else if ("quorum".equals(queue.getType())) {
        quorumCount++;
      }
    }

    logger.info("Initial state: {} classic, {} quorum queues", classicCount, quorumCount);

    if (classicCount != CLASSIC_QUEUE_COUNT) {
      throw new RuntimeException(
          String.format(
              "Expected %d classic queues, found: %d", CLASSIC_QUEUE_COUNT, classicCount));
    }

    if (quorumCount != QUORUM_QUEUE_COUNT) {
      throw new RuntimeException(
          String.format("Expected %d quorum queues, found: %d", QUORUM_QUEUE_COUNT, quorumCount));
    }
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

      String status = details.getStatus();
      logger.info(
          "Migration status: {}, completed: {}/{}",
          status,
          details.getCompletedQueues(),
          details.getTotalQueues());

      if ("completed".equals(status) || "failed".equals(status)) {
        return;
      }

      Thread.sleep(2000);
    }

    throw new RuntimeException("Migration did not complete within timeout");
  }

  private static void validateResults(
      QueueMigrationClient client, String migrationId, TestConfiguration config) throws Exception {
    QueueMigrationClient.MigrationDetailResponse details = client.getMigrationDetails(migrationId);

    logger.info("Migration status: {}", details.getStatus());
    logger.info("Completed queues: {}", details.getCompletedQueues());
    logger.info("Total queues: {}", details.getTotalQueues());

    if (!"completed".equals(details.getStatus())) {
      throw new RuntimeException("Expected status 'completed', got: " + details.getStatus());
    }

    // Should only migrate the classic queues
    if (details.getCompletedQueues() != CLASSIC_QUEUE_COUNT) {
      throw new RuntimeException(
          String.format(
              "Expected %d completed queues, got: %d",
              CLASSIC_QUEUE_COUNT, details.getCompletedQueues()));
    }

    // Total should be classic queues only (quorum queues should be filtered out)
    if (details.getTotalQueues() != CLASSIC_QUEUE_COUNT) {
      throw new RuntimeException(
          String.format(
              "Expected %d total queues, got: %d", CLASSIC_QUEUE_COUNT, details.getTotalQueues()));
    }

    // Verify final queue types
    Client httpClient = config.createHttpClient();

    List<QueueInfo> queues = httpClient.getQueues("/");

    int classicCount = 0;
    int quorumCount = 0;

    for (QueueInfo queue : queues) {
      String queueName = queue.getName();
      if (!queueName.startsWith("test.")) {
        continue;
      }

      if ("classic".equals(queue.getType())) {
        classicCount++;
      } else if ("quorum".equals(queue.getType())) {
        quorumCount++;
      }
    }

    logger.info("Final state: {} classic, {} quorum queues", classicCount, quorumCount);

    // All queues should now be quorum
    int expectedQuorum = CLASSIC_QUEUE_COUNT + QUORUM_QUEUE_COUNT;
    if (quorumCount != expectedQuorum) {
      throw new RuntimeException(
          String.format("Expected %d quorum queues, got: %d", expectedQuorum, quorumCount));
    }

    if (classicCount != 0) {
      throw new RuntimeException(String.format("Expected 0 classic queues, got: %d", classicCount));
    }
  }
}
