package com.amazon.mq.rabbitmq.migration;

import com.amazon.mq.rabbitmq.AmqpEndpoint;
import com.rabbitmq.http.client.Client;
import com.rabbitmq.http.client.domain.BindingInfo;
import com.rabbitmq.http.client.domain.Definitions;
import com.rabbitmq.http.client.domain.ExchangeInfo;
import com.rabbitmq.http.client.domain.QueueInfo;
import java.util.List;
import java.util.Map;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Complete end-to-end migration test that sets up RabbitMQ environment and performs classic queue
 * to quorum queue migration testing.
 */
public class EndToEndMigrationTest {

  private static final Logger logger = LoggerFactory.getLogger(EndToEndMigrationTest.class);
  private static final int MONITORING_INTERVAL_SECONDS = 5;

  public static void main(String[] args) {
    execute(args);
  }

  public static void execute(String[] args) {
    try {
      logger.info("Starting complete end-to-end migration test");

      // Parse configuration for all phases
      TestConfiguration config = MigrationTestSetup.parseArguments(args);

      // Phase 0: Cleanup previous test artifacts (unless skipped)
      if (!config.isSkipCleanup()) {
        logger.info("=== Phase 0: Cleaning up previous test artifacts ===");
        CleanupEnvironment.performCleanup(config);
      } else {
        logger.info("=== Phase 0: Skipping cleanup (--skip-cleanup specified) ===");
      }

      // Phase 1: Setup test environment (unless skipped)
      if (!config.isSkipSetup()) {
        logger.info("=== Phase 1: Setting up test environment ===");
        MigrationTestSetup.execute(args);
      } else {
        logger.info(
            "=== Phase 1: Skipping setup of up test environment (--skip-setup specified) ===");
      }

      // Phase 2: Collect pre-migration statistics
      logger.info("=== Phase 2: Collecting pre-migration statistics ===");
      Client httpClient = config.createHttpClient();
      Definitions preMigrationDefs = httpClient.getDefinitions();
      logger.info(
          "Captured pre-migration definitions: {} queues, {} exchanges, {} bindings",
          preMigrationDefs.getQueues().size(),
          preMigrationDefs.getExchanges().size(),
          preMigrationDefs.getBindings().size());
      PreMigrationStats preMigrationStats = collectPreMigrationStats(config);

      // Phase 3: Trigger migration
      logger.info("=== Phase 3: Triggering queue migration ===");
      QueueMigrationClient migrationClient = createMigrationClient(config);
      QueueMigrationClient.MigrationResponse migrationResponse =
          migrationClient.startMigration(
              config.isSkipUnsuitableQueues(), config.getBatchSize(), config.getBatchOrder());
      logger.info("Migration start response: {}", migrationResponse);

      // Phase 4: Wait for migration to start, then monitor progress
      logger.info("=== Phase 4: Monitoring migration progress ===");
      long migrationStartTime = System.currentTimeMillis();

      // Wait for migration to actually start before monitoring
      if (!waitForMigrationToStart(migrationClient, 120)) {
        logger.error("❌ Migration did not start within 120 seconds");
        System.exit(1);
      }

      boolean migrationSuccess =
          monitorMigrationProgress(migrationClient, config.getMigrationTimeout(), config);

      // Phase 5: Validate migration results
      logger.info("=== Phase 5: Validating migration results ===");
      if (migrationSuccess) {
        validateMigrationResults(config, preMigrationStats, preMigrationDefs, migrationStartTime);
        logger.info("✅ Complete end-to-end migration test finished successfully!");
      } else {
        logger.error("❌ Migration test failed - migration did not complete successfully");
        System.exit(1);
      }

    } catch (Exception e) {
      logger.error("End-to-end migration test failed", e);
      System.exit(1);
    }
  }

  private static QueueMigrationClient createMigrationClient(TestConfiguration config) {
    // Use first node for migration client
    return new QueueMigrationClient(
        config.getHttpHost(), config.getHttpPort(), "guest", "guest", config.getVirtualHost());
  }

  private static boolean waitForMigrationToStart(
      QueueMigrationClient migrationClient, int timeoutSeconds) throws Exception {
    logger.info("Waiting for migration to start (timeout: {}s)...", timeoutSeconds);

    long startTime = System.currentTimeMillis();

    while (true) {
      long elapsed = (System.currentTimeMillis() - startTime) / 1000;

      QueueMigrationClient.MigrationStatusResponse statusResponse =
          migrationClient.getMigrationStatus();

      if (statusResponse.hasMigration()) {
        QueueMigrationClient.MigrationInfo migration = statusResponse.getMigrationInfo();

        // Check if this is a migration that's actually running
        if (migration.isInProgress()) {
          logger.info("✅ Migration started and is in progress: {}", migration.getDisplayId());
          return true;
        }

        // If we find a completed migration, it might be stale from a previous run
        if (migration.isCompleted()) {
          logger.debug("Found completed migration (possibly stale): {}", migration.getDisplayId());
          // Continue waiting for a new migration to start
        }

        // If we find a failed migration, it might be stale from a previous run
        if (migration.isFailed()) {
          logger.debug("Found failed migration (possibly stale): {}", migration.getDisplayId());
          // Continue waiting for a new migration to start
        }
      } else {
        logger.debug("No migration found yet, elapsed: {}s", elapsed);
      }

      // Check timeout
      if (elapsed >= timeoutSeconds) {
        logger.error("Migration did not start within {}s timeout", timeoutSeconds);
        return false;
      }

      Thread.sleep(1000); // Check every second
    }
  }

  private static PreMigrationStats collectPreMigrationStats(TestConfiguration config)
      throws Exception {
    logger.info("Collecting pre-migration queue statistics...");

    // Wait for stats to stabilize and get queue information using utility
    Client httpClient = config.createHttpClient();
    RabbitMQStatsUtils.waitForTestQueueStatsToStabilize(
        httpClient, config.getVirtualHost(), config.getQueuePrefix(), "pre-migration");
    List<QueueInfo> queues = httpClient.getQueues(config.getVirtualHost());

    // Filter test queues and collect stats
    int testQueueCount = 0;
    long totalMessages = 0;
    int classicQueueCount = 0;
    int quorumQueueCount = 0;

    for (QueueInfo queue : queues) {
      if (queue.getName().startsWith(config.getQueuePrefix())) {
        testQueueCount++;
        totalMessages += queue.getMessagesReady();

        String queueType = queue.getType();
        if ("classic".equals(queueType)) {
          classicQueueCount++;
        } else if ("quorum".equals(queueType)) {
          quorumQueueCount++;
        }
      }
    }

    PreMigrationStats stats =
        new PreMigrationStats(testQueueCount, totalMessages, classicQueueCount, quorumQueueCount);
    logger.info("Pre-migration stats: {}", stats);
    return stats;
  }

  private static boolean monitorMigrationProgress(
      QueueMigrationClient migrationClient, int timeoutSeconds, TestConfiguration config)
      throws Exception {
    logger.info("Monitoring migration progress (timeout: {}s)...", timeoutSeconds);

    long startTime = System.currentTimeMillis();
    String lastStatus = "";
    int lastProgress = -1;
    int checkCount = 0;
    boolean migrationFound = false;
    int interruptedStableCount = 0;
    int lastCompletedQueues = -1;

    while (true) {
      checkCount++;
      long currentTime = System.currentTimeMillis();
      ;
      long elapsed = (currentTime - startTime) / 1000;

      QueueMigrationClient.MigrationStatusResponse statusResponse =
          migrationClient.getMigrationStatus();

      if (statusResponse.hasMigration()) {
        migrationFound = true;
        QueueMigrationClient.MigrationInfo migration = statusResponse.getMigrationInfo();

        // Log progress when status or progress changes, or every 20 checks
        if (!migration.getStatus().equals(lastStatus)
            || migration.getProgressPercentage() != lastProgress
            || (checkCount % 20) == 0) {

          logger.info(
              "Migration: {} | Progress: {}% | Queues: {}/{} | Elapsed: {}s | ID: {}",
              migration.getStatus(),
              migration.getProgressPercentage(),
              migration.getCompletedQueues(),
              migration.getTotalQueues(),
              elapsed,
              migration.getDisplayId());

          lastStatus = migration.getStatus();
          lastProgress = migration.getProgressPercentage();
        }

        // Perform listener verification during active migration (only once)
        if (migration.isInProgress() && checkCount == 1) {
          verifyListenerStateDuringMigration(config);
        }

        // Check if migration is complete
        if (migration.isCompleted()) {
          logger.info("✅ Migration completed successfully!");
          logger.info(
              "Started: {} | Completed: {}", migration.getStartedAt(), migration.getCompletedAt());
          logger.info(
              "Final result: {}/{} queues migrated ({}%)",
              migration.getCompletedQueues(),
              migration.getTotalQueues(),
              migration.getProgressPercentage());

          verifyListenersRestored(config);
          return true;
        } else if (migration.isFailed()) {
          logger.error("❌ Migration failed!");
          logger.error("Migration info: {}", migration);
          verifyListenersRestored(config);
          return false;
        } else if (migration.isInterrupted()) {
          // Wait for in-flight queues to finish (completedQueues stops changing)
          int currentCompleted = migration.getCompletedQueues();
          if (currentCompleted == lastCompletedQueues) {
            interruptedStableCount++;
            if (interruptedStableCount >= 3) {
              logger.info("✅ Migration interrupted, in-flight queues finished");
              logger.info(
                  "Final result: {}/{} queues migrated before interrupt",
                  migration.getCompletedQueues(),
                  migration.getTotalQueues());
              verifyListenersRestored(config);
              return true;
            }
          } else {
            interruptedStableCount = 0;
            lastCompletedQueues = currentCompleted;
          }
        }
      } else {
        if ((checkCount % 20) == 0) {
          logger.info(
              "Overall status: {} | Elapsed: {}s | Waiting for migration to appear...",
              statusResponse.getOverallStatus(),
              elapsed);
        }
      }

      // Check timeout
      if (elapsed > timeoutSeconds) {
        logger.warn("⚠️ Migration monitoring timeout reached ({}s)", timeoutSeconds);
        if (migrationFound) {
          logger.warn("Migration was found but did not complete within timeout");
        } else {
          logger.error("No migration was detected within timeout period");
        }
        return false;
      }

      Thread.sleep(MONITORING_INTERVAL_SECONDS * 1000);
    }
  }

  private static void verifyListenerStateDuringMigration(TestConfiguration config) {
    // Skip verification for t3.micro equivalent (too fast)
    if (!shouldVerifyListeners()) {
      logger.info("Skipping listener verification for small configuration (migration too fast)");
      return;
    }

    logger.info("Performing listener state verification during migration...");

    boolean httpAvailable = checkHttpApiAvailable(config);
    boolean amqpSuspended = checkAmqpListenersSuspended(config);

    // Report results
    if (httpAvailable && amqpSuspended) {
      logger.info("✅ Listener state verification passed: HTTP available, AMQP suspended");
    } else if (httpAvailable && !amqpSuspended) {
      logger.warn(
          "⚠️ Partial verification: HTTP available, but AMQP not suspended (migration may be too"
              + " fast)");
    } else {
      logger.error("❌ Listener state verification failed");
    }
  }

  private static void verifyListenersRestored(TestConfiguration config) {
    if (!shouldVerifyListeners()) {
      return;
    }

    logger.info("Verifying that listeners are restored after migration...");

    try {
      // Wait for HTTP API to be restored (with timeout)
      if (!waitForHttpApiRestoration(config, 30)) {
        logger.error("❌ HTTP API did not restore within 30 seconds after migration");
        return;
      }

      // Wait for AMQP listeners to be restored (with timeout)
      if (!waitForAmqpListenersRestoration(config, 30)) {
        logger.error("❌ AMQP listeners did not restore within 30 seconds after migration");
        return;
      }

    } catch (Exception e) {
      logger.warn("Listener restoration verification failed: {}", e.getMessage());
    }
  }

  /**
   * Determine if we should perform listener verification based on configuration size. Skip
   * verification for small configurations (like t3.micro) where migration is too fast.
   */
  private static boolean shouldVerifyListeners() {
    // For now, we'll skip verification for configurations with <= 10 queues and <= 5500 messages
    // This matches the t3.micro behavior from the shell script
    // In the future, this could be made configurable
    return true; // Enable verification for all configurations for now
  }

  private static boolean waitForHttpApiRestoration(TestConfiguration config, int timeoutSeconds)
      throws Exception {
    logger.info("Waiting for HTTP API to restore (timeout: {}s)...", timeoutSeconds);

    long startTime = System.currentTimeMillis();

    while (true) {
      long elapsed = (System.currentTimeMillis() - startTime) / 1000;

      if (checkHttpApiAvailable(config)) {
        logger.info("✅ HTTP API is restored and available");
        return true;
      }

      // Check timeout
      if (elapsed >= timeoutSeconds) {
        logger.error("HTTP API did not restore within {}s timeout", timeoutSeconds);
        return false;
      }

      Thread.sleep(1000); // Check every second
    }
  }

  private static boolean waitForAmqpListenersRestoration(
      TestConfiguration config, int timeoutSeconds) throws Exception {
    logger.info("Waiting for AMQP listeners to restore (timeout: {}s)...", timeoutSeconds);

    long startTime = System.currentTimeMillis();

    while (true) {
      long elapsed = (System.currentTimeMillis() - startTime) / 1000;

      if (checkAmqpListenersRestored(config)) {
        logger.info("✅ AMQP listeners are restored and accepting connections");
        return true;
      }

      // Check timeout
      if (elapsed >= timeoutSeconds) {
        logger.error("AMQP listeners did not restore within {}s timeout", timeoutSeconds);
        return false;
      }

      Thread.sleep(1000); // Check every second
    }
  }

  /** Check if HTTP API is available during migration */
  private static boolean checkHttpApiAvailable(TestConfiguration config) {
    logger.info("Checking if HTTP API remains available...");

    try {
      Client httpClient = config.createHttpClient();
      // Do a simple aliveness test
      return httpClient.alivenessTest(config.getVirtualHost());
    } catch (Exception e) {
      logger.warn("❌ HTTP API check error: {}", e.getMessage());
      return false;
    }
  }

  /** Check if AMQP listeners are suspended (not accepting connections) */
  private static boolean checkAmqpListenersSuspended(TestConfiguration config) {
    logger.info("Checking if AMQP listeners are suspended across all nodes...");

    int nodeCount = config.getClusterTopology().getNodeCount();
    boolean allSuspended = true;

    for (int i = 0; i < nodeCount; i++) {
      AmqpEndpoint endpoint = config.getAmqpEndpoint(i);
      logger.debug(
          "Checking AMQP listener suspension on {}:{}", endpoint.getHostname(), endpoint.getPort());

      boolean nodeSuspended = false;

      // Retry up to 3 times to detect non-listening port
      for (int attempt = 1; attempt <= 3; attempt++) {
        try {
          // Try to connect to AMQP port - this should fail if listeners are suspended
          java.net.Socket socket = new java.net.Socket();
          socket.connect(
              new java.net.InetSocketAddress(endpoint.getHostname(), endpoint.getPort()), 1000);
          socket.close();

          logger.debug(
              "Attempt {}/3: AMQP listener on {}:{} is accepting connections",
              attempt,
              endpoint.getHostname(),
              endpoint.getPort());

          if (attempt < 3) {
            // Sleep before retry
            Thread.sleep(1000);
          }

        } catch (Exception e) {
          logger.debug(
              "Attempt {}/3: AMQP listener on {}:{} is not accepting connections: {}",
              attempt,
              endpoint.getHostname(),
              endpoint.getPort(),
              e.getMessage());
          nodeSuspended = true;
          break; // Connection failed, listener is suspended
        }
      }

      if (nodeSuspended) {
        logger.info(
            "✅ AMQP listener on {}:{} is properly suspended",
            endpoint.getHostname(),
            endpoint.getPort());
      } else {
        logger.warn(
            "⚠️ AMQP listener on {}:{} is still accepting connections after 3 attempts",
            endpoint.getHostname(),
            endpoint.getPort());
        allSuspended = false;
      }
    }

    if (allSuspended) {
      logger.info("✅ All AMQP listeners are properly suspended across {} nodes", nodeCount);
    } else {
      logger.warn("⚠️ Not all AMQP listeners are suspended");
    }

    return allSuspended;
  }

  /** Check if AMQP listeners are restored (accepting connections) */
  private static boolean checkAmqpListenersRestored(TestConfiguration config) {
    logger.info("Checking if AMQP listeners are restored across all nodes...");

    int nodeCount = config.getClusterTopology().getNodeCount();
    boolean allRestored = true;

    for (int i = 0; i < nodeCount; i++) {
      AmqpEndpoint endpoint = config.getAmqpEndpoint(i);
      try {
        // Try to connect to AMQP port - this should succeed if listeners are restored
        java.net.Socket socket = new java.net.Socket();
        socket.connect(
            new java.net.InetSocketAddress(endpoint.getHostname(), endpoint.getPort()), 1000);
        socket.close();

        logger.info(
            "✅ AMQP listener on {}:{} is restored and accepting connections",
            endpoint.getHostname(),
            endpoint.getPort());

      } catch (Exception e) {
        logger.warn(
            "❌ AMQP listener on {}:{} connection failed: {}",
            endpoint.getHostname(),
            endpoint.getPort(),
            e.getMessage());
        allRestored = false;
      }
    }

    if (allRestored) {
      logger.info("✅ All AMQP listeners are restored across {} nodes", nodeCount);
    } else {
      logger.warn("❌ Not all AMQP listeners are restored");
    }

    return allRestored;
  }

  private static void validateMigrationResults(
      TestConfiguration config,
      PreMigrationStats preMigrationStats,
      Definitions preMigrationDefs,
      long migrationStartTime)
      throws Exception {
    logger.info("Validating migration results...");

    // Wait for post-migration stats to stabilize
    Client httpClient = config.createHttpClient();
    RabbitMQStatsUtils.waitForTestQueueStatsToStabilize(
        httpClient, config.getVirtualHost(), config.getQueuePrefix(), "post-migration");

    // Capture post-migration definitions for topology validation
    Definitions postMigrationDefs = httpClient.getDefinitions();

    // Collect post-migration stats
    List<QueueInfo> queues = httpClient.getQueues(config.getVirtualHost());

    int testQueueCount = 0;
    long totalMessages = 0;
    int classicQueueCount = 0;
    int quorumQueueCount = 0;

    for (QueueInfo queue : queues) {
      if (queue.getName().startsWith(config.getQueuePrefix())) {
        testQueueCount++;
        totalMessages += queue.getMessagesReady();

        String queueType = queue.getType();
        if ("classic".equals(queueType)) {
          classicQueueCount++;
        } else if ("quorum".equals(queueType)) {
          quorumQueueCount++;
        }
      }
    }

    // Validation checks
    boolean validationPassed = true;

    // Check queue count
    if (testQueueCount != preMigrationStats.queueCount) {
      logger.error(
          "❌ Queue count mismatch: expected {}, found {}",
          preMigrationStats.queueCount,
          testQueueCount);
      validationPassed = false;
    } else {
      logger.info("✅ Queue count validation passed: {}", testQueueCount);
    }

    // Check message count
    if (totalMessages != preMigrationStats.totalMessages) {
      logger.error(
          "❌ Message count mismatch: expected {}, found {}",
          preMigrationStats.totalMessages,
          totalMessages);
      validationPassed = false;
    } else {
      logger.info("✅ Message count validation passed: {}", totalMessages);
    }

    // Calculate expected quorum count based on batch size and unsuitable queues
    int unsuitableCount = config.getUnsuitableQueueCount();
    int migratableQueueCount = testQueueCount - unsuitableCount;
    int expectedQuorumCount = migratableQueueCount;
    if (config.getBatchSize() != null && config.getBatchSize() < migratableQueueCount) {
      expectedQuorumCount = config.getBatchSize();
      logger.info(
          "Batch migration mode: expecting {} queues migrated (batch_size={})",
          expectedQuorumCount,
          config.getBatchSize());
    }
    if (unsuitableCount > 0) {
      logger.info(
          "Unsuitable queues configured: {} queues expected to remain classic", unsuitableCount);
    }

    // Check that expected number of queues are now quorum queues
    if (quorumQueueCount != expectedQuorumCount) {
      logger.error(
          "❌ Quorum queue count mismatch: expected {}, found {} quorum, {} classic, {} total",
          expectedQuorumCount,
          quorumQueueCount,
          classicQueueCount,
          testQueueCount);
      validationPassed = false;
    } else {
      logger.info("✅ Quorum queue count validation passed: {} quorum queues", quorumQueueCount);
    }

    // Check that remaining classic queues match expectation (unmigrated batch + unsuitable)
    int expectedClassicCount = testQueueCount - expectedQuorumCount;
    if (classicQueueCount != expectedClassicCount) {
      logger.error(
          "❌ Classic queue count mismatch: expected {}, found {}",
          expectedClassicCount,
          classicQueueCount);
      validationPassed = false;
    } else if (classicQueueCount > 0) {
      logger.info("✅ Classic queue count as expected: {} (batch migration)", classicQueueCount);
    } else {
      logger.info("✅ No classic queues remain");
    }

    // Validate topology (exchanges, bindings, queue properties)
    logger.info("Validating topology preservation...");
    validationPassed &=
        validateExchanges(preMigrationDefs, postMigrationDefs, config.getExchangePrefix());
    validationPassed &=
        validateBindings(
            preMigrationDefs,
            postMigrationDefs,
            config.getExchangePrefix(),
            config.getQueuePrefix());
    validationPassed &=
        validateQueueProperties(preMigrationDefs, postMigrationDefs, config.getQueuePrefix());

    // Calculate migration duration
    long migrationDurationSeconds = (System.currentTimeMillis() - migrationStartTime) / 1000;

    // Generate migration summary
    printMigrationSummary(
        preMigrationStats,
        testQueueCount,
        totalMessages,
        classicQueueCount,
        quorumQueueCount,
        migrationDurationSeconds,
        expectedQuorumCount);

    if (!validationPassed) {
      throw new RuntimeException("Migration validation failed");
    }

    logger.info("✅ Migration validation completed successfully");
  }

  private static void printMigrationSummary(
      PreMigrationStats preMigrationStats,
      int postQueueCount,
      long postTotalMessages,
      int postClassicCount,
      int postQuorumCount,
      long migrationDurationSeconds,
      int expectedQuorumCount) {

    System.out.println();
    System.out.println("=== MIGRATION TEST SUMMARY ===");
    System.out.println(
        "Migration Duration:    "
            + migrationDurationSeconds
            + "s ("
            + (migrationDurationSeconds / 60)
            + "m)");
    System.out.println();
    System.out.println("Migration Results:");
    System.out.println("  Classic queues before: " + preMigrationStats.classicQueueCount);
    System.out.println("  Quorum queues after:   " + postQuorumCount);
    System.out.println("  Remaining classic:     " + postClassicCount);
    System.out.println(
        "  Messages preserved:    " + postTotalMessages + "/" + preMigrationStats.totalMessages);

    // Calculate success rate based on expected migrations
    int successRate = expectedQuorumCount > 0 ? (postQuorumCount * 100 / expectedQuorumCount) : 100;
    System.out.println("  Migration success rate: " + successRate + "%");

    boolean allValidationsPassed =
        postQuorumCount == expectedQuorumCount
            && postTotalMessages == preMigrationStats.totalMessages;

    System.out.println();
    System.out.println(
        "=== MIGRATION COMPLETE - "
            + (allValidationsPassed ? "ALL VALIDATIONS PASSED" : "VALIDATION ISSUES DETECTED")
            + " ===");
    System.out.println();
  }

  /** Pre-migration statistics */
  private static class PreMigrationStats {
    final int queueCount;
    final long totalMessages;
    final int classicQueueCount;
    final int quorumQueueCount;

    PreMigrationStats(
        int queueCount, long totalMessages, int classicQueueCount, int quorumQueueCount) {
      this.queueCount = queueCount;
      this.totalMessages = totalMessages;
      this.classicQueueCount = classicQueueCount;
      this.quorumQueueCount = quorumQueueCount;
    }

    @Override
    public String toString() {
      return String.format(
          "PreMigrationStats{queues=%d, messages=%d, classic=%d, quorum=%d}",
          queueCount, totalMessages, classicQueueCount, quorumQueueCount);
    }
  }

  /** Validate that all test exchanges are preserved post-migration */
  private static boolean validateExchanges(
      Definitions preMigrationDefs, Definitions postMigrationDefs, String exchangePrefix) {
    logger.info("Validating exchanges...");

    List<ExchangeInfo> preExchanges =
        preMigrationDefs.getExchanges().stream()
            .filter(e -> e.getName().startsWith(exchangePrefix))
            .toList();

    List<ExchangeInfo> postExchanges =
        postMigrationDefs.getExchanges().stream()
            .filter(e -> e.getName().startsWith(exchangePrefix))
            .toList();

    boolean passed = true;

    if (preExchanges.size() != postExchanges.size()) {
      logger.error(
          "❌ Exchange count mismatch: expected {}, found {}",
          preExchanges.size(),
          postExchanges.size());
      passed = false;
    }

    for (ExchangeInfo preExchange : preExchanges) {
      ExchangeInfo postExchange =
          postExchanges.stream()
              .filter(e -> e.getName().equals(preExchange.getName()))
              .findFirst()
              .orElse(null);

      if (postExchange == null) {
        logger.error("❌ Exchange missing: {}", preExchange.getName());
        passed = false;
        continue;
      }

      if (!preExchange.getType().equals(postExchange.getType())) {
        logger.error(
            "❌ Exchange {} type mismatch: expected {}, found {}",
            preExchange.getName(),
            preExchange.getType(),
            postExchange.getType());
        passed = false;
      }

      if (preExchange.isDurable() != postExchange.isDurable()) {
        logger.error(
            "❌ Exchange {} durable flag mismatch: expected {}, found {}",
            preExchange.getName(),
            preExchange.isDurable(),
            postExchange.isDurable());
        passed = false;
      }

      if (preExchange.isAutoDelete() != postExchange.isAutoDelete()) {
        logger.error(
            "❌ Exchange {} auto-delete flag mismatch: expected {}, found {}",
            preExchange.getName(),
            preExchange.isAutoDelete(),
            postExchange.isAutoDelete());
        passed = false;
      }
    }

    if (passed) {
      logger.info("✅ Exchange validation passed: {} exchanges verified", preExchanges.size());
    }

    return passed;
  }

  /** Validate that all test bindings are preserved post-migration */
  private static boolean validateBindings(
      Definitions preMigrationDefs,
      Definitions postMigrationDefs,
      String exchangePrefix,
      String queuePrefix) {
    logger.info("Validating bindings...");

    List<BindingInfo> preBindings =
        preMigrationDefs.getBindings().stream()
            .filter(
                b ->
                    b.getSource().startsWith(exchangePrefix)
                        || b.getDestination().startsWith(queuePrefix))
            .toList();

    List<BindingInfo> postBindings =
        postMigrationDefs.getBindings().stream()
            .filter(
                b ->
                    b.getSource().startsWith(exchangePrefix)
                        || b.getDestination().startsWith(queuePrefix))
            .toList();

    boolean passed = true;

    if (preBindings.size() != postBindings.size()) {
      logger.error(
          "❌ Binding count mismatch: expected {}, found {}",
          preBindings.size(),
          postBindings.size());
      passed = false;
    }

    for (BindingInfo preBinding : preBindings) {
      BindingInfo postBinding =
          postBindings.stream()
              .filter(
                  b ->
                      b.getSource().equals(preBinding.getSource())
                          && b.getDestination().equals(preBinding.getDestination())
                          && b.getRoutingKey().equals(preBinding.getRoutingKey()))
              .findFirst()
              .orElse(null);

      if (postBinding == null) {
        logger.error(
            "❌ Binding missing: {} -> {} (key: {})",
            preBinding.getSource(),
            preBinding.getDestination(),
            preBinding.getRoutingKey());
        passed = false;
        continue;
      }

      Map<String, Object> preArgs = preBinding.getArguments();
      Map<String, Object> postArgs = postBinding.getArguments();

      if ((preArgs == null || preArgs.isEmpty()) && (postArgs == null || postArgs.isEmpty())) {
        continue;
      }

      if ((preArgs == null || preArgs.isEmpty()) != (postArgs == null || postArgs.isEmpty())) {
        logger.error(
            "❌ Binding {} -> {} arguments mismatch: one has arguments, other doesn't",
            preBinding.getSource(),
            preBinding.getDestination());
        passed = false;
        continue;
      }

      if (!preArgs.equals(postArgs)) {
        logger.error(
            "❌ Binding {} -> {} arguments differ: expected {}, found {}",
            preBinding.getSource(),
            preBinding.getDestination(),
            preArgs,
            postArgs);
        passed = false;
      }
    }

    if (passed) {
      logger.info("✅ Binding validation passed: {} bindings verified", preBindings.size());
    }

    return passed;
  }

  /** Validate that queue properties are preserved post-migration */
  private static boolean validateQueueProperties(
      Definitions preMigrationDefs, Definitions postMigrationDefs, String queuePrefix) {
    logger.info("Validating queue properties...");

    List<QueueInfo> preQueues =
        preMigrationDefs.getQueues().stream()
            .filter(q -> q.getName().startsWith(queuePrefix))
            .toList();

    List<QueueInfo> postQueues =
        postMigrationDefs.getQueues().stream()
            .filter(q -> q.getName().startsWith(queuePrefix))
            .toList();

    boolean passed = true;

    List<String> sharedArguments =
        List.of(
            "x-message-ttl",
            "x-max-length",
            "x-max-length-bytes",
            "x-expires",
            "x-dead-letter-exchange",
            "x-dead-letter-routing-key",
            "x-overflow");

    for (QueueInfo preQueue : preQueues) {
      QueueInfo postQueue =
          postQueues.stream()
              .filter(q -> q.getName().equals(preQueue.getName()))
              .findFirst()
              .orElse(null);

      if (postQueue == null) {
        logger.error("❌ Queue missing in post-migration: {}", preQueue.getName());
        passed = false;
        continue;
      }

      Map<String, Object> preArgs = preQueue.getArguments();
      Map<String, Object> postArgs = postQueue.getArguments();

      if (preArgs != null && preArgs.containsKey("x-max-priority")) {
        if (postArgs == null || !postArgs.containsKey("x-max-priority")) {
          logger.warn(
              "⚠️ Queue {} lost x-max-priority during migration (expected for quorum queues)",
              preQueue.getName());
        }
      }

      for (String argName : sharedArguments) {
        Object preValue = preArgs != null ? preArgs.get(argName) : null;
        Object postValue = postArgs != null ? postArgs.get(argName) : null;

        if (preValue == null && postValue == null) {
          continue;
        }

        if (preValue == null || postValue == null) {
          logger.error(
              "❌ Queue {} argument {} mismatch: pre={}, post={}",
              preQueue.getName(),
              argName,
              preValue,
              postValue);
          passed = false;
          continue;
        }

        if (!argumentValuesEqual(preValue, postValue)) {
          logger.error(
              "❌ Queue {} argument {} mismatch: pre={}, post={}",
              preQueue.getName(),
              argName,
              preValue,
              postValue);
          passed = false;
        }
      }
    }

    if (passed) {
      logger.info("✅ Queue properties validation passed: {} queues verified", preQueues.size());
    }

    return passed;
  }

  /** Compare argument values, handling numeric type differences */
  private static boolean argumentValuesEqual(Object value1, Object value2) {
    if (value1.equals(value2)) {
      return true;
    }

    if (value1 instanceof Number && value2 instanceof Number) {
      return ((Number) value1).longValue() == ((Number) value2).longValue();
    }

    return false;
  }
}
