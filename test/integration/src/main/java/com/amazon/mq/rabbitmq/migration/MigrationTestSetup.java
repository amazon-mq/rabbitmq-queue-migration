package com.amazon.mq.rabbitmq.migration;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import com.amazon.mq.rabbitmq.ClusterTopology;

import java.util.Arrays;
import java.util.List;
import java.util.Map;

/**
 * Main class for setting up RabbitMQ migration test environments.
 *
 * Usage: java -jar migration-test-setup.jar <instance-type> [options]
 *
 * Example: java -jar migration-test-setup.jar m5.xlarge
 */
public class MigrationTestSetup {

    private static final Logger logger = LoggerFactory.getLogger(MigrationTestSetup.class);

    public static void main(String[] args) {
        execute(args);
    }

    public static void execute(String[] args) {
        try {
            // Parse command line arguments
            TestConfiguration config = parseArguments(args);

            if (config.isSkipSetup()) {
                logger.info("Skipping migration test setup");
                return;
            } else {
                logger.info("Starting migration test setup");
            }

            logger.info("Queue Count: {}", config.getQueueCount());
            logger.info("Unsuitable Queue Count: {}", config.getUnsuitableQueueCount());
            logger.info("Total Messages: {}", config.getTotalMessages());
            logger.info("Target Message Count: {}", config.getTotalMessages());

            // Initialize RabbitMQ setup
            RabbitMQSetup setup = new RabbitMQSetup(config);

            try {
                // Run connection tests first
                logger.info("Running connection diagnostics...");
                if (!ConnectionTest.runConnectionTests(config)) {
                    logger.error("Connection tests failed. Please fix connection issues before proceeding.");
                    System.exit(1);
                }

                // Connect to RabbitMQ
                setup.initialize();

                // Set up test environment
                long startTime = System.currentTimeMillis();
                setup.setupTestEnvironment();
                long setupTime = System.currentTimeMillis() - startTime;

                // Print setup statistics
                Map<String, Object> stats = setup.getSetupStatistics();
                printSetupSummary(stats, setupTime, config);

                logger.info("Migration test setup completed successfully");

            } finally {
                setup.cleanup();
            }

        } catch (Exception e) {
            logger.error("Failed to set up migration test environment", e);
            System.exit(1);
        }
    }

    public static TestConfiguration parseArguments(String[] args) {
        String hostname = "localhost";
        int port = 15672;

        // Check for help first, then get hostname and port
        for (String arg : args) {
            if (arg.equals("--help") || arg.equals("-h")) {
                printUsage();
                System.exit(0);
            }
        }

        // Parse hostname/port from args to update config
        for (String testArg : args) {
            if (testArg.startsWith("--hostname=")) {
                hostname = testArg.substring(11);
            } else if (testArg.startsWith("--port=")) {
                try {
                    port = Integer.parseInt(testArg.substring(7));
                } catch (NumberFormatException e) {
                    // Use default port
                }
            }
        }

        // Initialize config with defaults
        ClusterTopology topology = new ClusterTopology(hostname, port);
        TestConfiguration config = new TestConfiguration(topology);

        // Check for test-connection next
        for (String arg : args) {
            if (arg.equals("--test-connection")) {
                boolean success = ConnectionTest.runConnectionTests(config);
                System.exit(success ? 0 : 1);
            }
        }

        // Parse all arguments
        for (String arg : args) {
            if (arg.startsWith("--queue-count=")) {
                try {
                    int queueCount = Integer.parseInt(arg.substring(14));
                    config.setQueueCount(queueCount);
                } catch (NumberFormatException e) {
                    logger.error("Invalid queue count: {}", arg);
                    printUsage();
                    System.exit(1);
                }
            } else if (arg.startsWith("--total-messages=")) {
                try {
                    int totalMessages = Integer.parseInt(arg.substring(17));
                    config.setTotalMessages(totalMessages);
                } catch (NumberFormatException e) {
                    logger.error("Invalid total messages: {}", arg);
                    printUsage();
                    System.exit(1);
                }
            } else if (arg.startsWith("--exchange-count=")) {
                try {
                    int exchangeCount = Integer.parseInt(arg.substring(17));
                    config.setExchangeCount(exchangeCount);
                } catch (NumberFormatException e) {
                    logger.error("Invalid exchange count: {}", arg);
                    printUsage();
                    System.exit(1);
                }
            } else if (arg.startsWith("--bindings-per-queue=")) {
                try {
                    int bindingsPerQueue = Integer.parseInt(arg.substring(21));
                    config.setBindingsPerQueue(bindingsPerQueue);
                } catch (NumberFormatException e) {
                    logger.error("Invalid bindings per queue: {}", arg);
                    printUsage();
                    System.exit(1);
                }
            } else if (arg.startsWith("--confirmation-window=")) {
                try {
                    int confirmationWindow = Integer.parseInt(arg.substring(22));
                    config.setConfirmationWindow(confirmationWindow);
                } catch (NumberFormatException e) {
                    logger.error("Invalid confirmation window: {}", arg);
                    printUsage();
                    System.exit(1);
                }
            } else if (arg.startsWith("--migration-timeout=")) {
                try {
                    int migrationTimeout = Integer.parseInt(arg.substring(20));
                    config.setMigrationTimeout(migrationTimeout);
                } catch (NumberFormatException e) {
                    logger.error("Invalid migration timeout: {}", arg);
                    printUsage();
                    System.exit(1);
                }
            } else if (arg.startsWith("--unsuitable-queue-count=")) {
                try {
                    int unsuitableQueueCount = Integer.parseInt(arg.substring(27));
                    config.setUnsuitableQueueCount(unsuitableQueueCount);
                } catch (NumberFormatException e) {
                    logger.error("Invalid unsuitable queue count: {}", arg);
                    printUsage();
                    System.exit(1);
                }
            } else if (arg.startsWith("--message-distribution=")) {
                try {
                    String distribution = arg.substring(23);
                    config.setMessageDistribution(distribution);
                } catch (Exception e) {
                    logger.error("Invalid message distribution: {}", e.getMessage());
                    printUsage();
                    System.exit(1);
                }
            } else if (arg.startsWith("--message-sizes=")) {
                try {
                    String sizes = arg.substring(16);
                    config.setMessageSizes(sizes);
                } catch (Exception e) {
                    logger.error("Invalid message sizes: {}", e.getMessage());
                    printUsage();
                    System.exit(1);
                }
            } else if (arg.startsWith("--hostname=")) {
                hostname = arg.substring(11);
            } else if (arg.startsWith("--port=")) {
                try {
                    port = Integer.parseInt(arg.substring(7));
                } catch (NumberFormatException e) {
                    logger.error("Invalid port: {}", arg);
                    printUsage();
                    System.exit(1);
                }
            } else if (arg.equals("--no-ha")) {
                config.setEnableHA(false);
            } else if (arg.equals("--skip-cleanup")) {
                config.setSkipCleanup(true);
            } else if (arg.equals("--skip-setup")) {
                config.setSkipSetup(true);
            } else if (arg.equals("--enable-ttl")) {
                config.setEnableTTL(true);
            } else if (arg.equals("--enable-max-length")) {
                config.setEnableMaxLength(true);
            } else if (arg.equals("--enable-max-priority")) {
                config.setEnableMaxPriority(true);
            } else if (arg.startsWith("--ttl-hours=")) {
                try {
                    int hours = Integer.parseInt(arg.substring("--ttl-hours=".length()));
                    config.setTtlMilliseconds(hours * 3600000L); // Convert hours to milliseconds
                    config.setEnableTTL(true); // Automatically enable TTL when setting duration
                } catch (NumberFormatException e) {
                    logger.error("Invalid TTL hours value: {}", arg);
                    printUsage();
                    System.exit(1);
                }
            } else if (arg.equals("--help") || arg.equals("-h")) {
                printUsage();
                System.exit(0);
            } else if (!arg.equals("--test-connection")) {
                logger.warn("Unknown argument: {}", arg);
            }
        }

        return config;
    }

    private static void printUsage() {
        System.out.println("RabbitMQ Migration Test Setup");
        System.out.println();
        System.out.println("Usage: java -jar migration-test-setup.jar [options]");
        System.out.println();
        System.out.println("Configuration Options:");
        System.out.println("  --queue-count=N            Number of queues to create (min: 10, max: 65536, default: 10)");
        System.out.println("  --total-messages=N         Total messages across all queues (default: 5500)");
        System.out.println("  --exchange-count=N         Number of exchanges to create (default: 5)");
        System.out.println("  --bindings-per-queue=N     Number of bindings per queue (default: 6)");
        System.out.println("  --confirmation-window=N    Confirmations per publishing thread (min: 4, max: 256, default: 4)");
        System.out.println("  --migration-timeout=N      Migration timeout in seconds (default: 300, for end-to-end mode)");
        System.out.println("  --unsuitable-queue-count=N  Number of unsuitable queues to create for testing (default: 0)");
        System.out.println("                                Creates queues with reject-publish-dlx, too many messages, etc.");
        System.out.println();
        System.out.println("Message Configuration:");
        System.out.println("  --message-distribution=X,Y,Z   Message size distribution percentages (must sum to 100)");
        System.out.println("                                 Example: --message-distribution=70,20,10");
        System.out.println("  --message-sizes=S,M,L          Message sizes in bytes (min: 8, max: 4MiB)");
        System.out.println("                                 Example: --message-sizes=1024,102400,1048576");
        System.out.println();
        System.out.println("Connection Options:");
        System.out.println("  --hostname=HOST            RabbitMQ management API hostname (default: localhost)");
        System.out.println("  --port=PORT                RabbitMQ management API port (default: 15672)");
        System.out.println("                             ClusterTopology will automatically discover all cluster nodes");
        System.out.println();
        System.out.println("Test Options:");
        System.out.println("  --no-ha                    Disable HA/mirroring");
        System.out.println("  --skip-cleanup             Skip cleanup phase in end-to-end mode");
        System.out.println("  --skip-setup               Skip setup phase in end-to-end mode");
        System.out.println("  --enable-ttl               Enable TTL on queues (disabled by default)");
        System.out.println("  --ttl-hours=HOURS          Set TTL duration in hours (default: 1, enables TTL)");
        System.out.println("  --enable-max-length        Enable max-length on queues (disabled by default)");
        System.out.println("  --enable-max-priority      Enable priority on queues (disabled by default)");
        System.out.println();
        System.out.println("Other Options:");
        System.out.println("  --test-connection          Test connections and exit");
        System.out.println("  --help, -h                 Show this help message");
        System.out.println();
        System.out.println("Examples:");
        System.out.println("  # Basic usage with defaults");
        System.out.println("  java -jar migration-test-setup.jar");
        System.out.println();
        System.out.println("  # Setup environment only");
        System.out.println("  java -jar migration-test-setup.jar setup-env --queue-count=20 --total-messages=10000");
        System.out.println();
        System.out.println("  # Cleanup environment only");
        System.out.println("  java -jar migration-test-setup.jar cleanup-env");
        System.out.println();
        System.out.println("  # Complete end-to-end migration test");
        System.out.println("  java -jar migration-test-setup.jar end-to-end --queue-count=10 --migration-timeout=600");
        System.out.println();
        System.out.println("  # End-to-end test without cleanup or setup");
        System.out.println("  java -jar migration-test-setup.jar end-to-end --queue-count=10 --skip-cleanup --skip-setup");
        System.out.println();
    }

    private static void printSetupSummary(Map<String, Object> stats, long setupTimeMs, TestConfiguration config) {
        System.out.println();
        System.out.println("=== MIGRATION TEST SETUP SUMMARY ===");
        System.out.println("Queue Count:       " + config.getQueueCount());
        System.out.println("Unsuitable Queue Count: " + config.getUnsuitableQueueCount());
        System.out.println("Setup Time:        " + setupTimeMs + " ms");
        System.out.println();
        System.out.println("Resources Created:");
        System.out.println("  Queues:          " + stats.get("queues"));
        System.out.println("  Exchanges:       " + stats.get("exchanges"));
        System.out.println("  Bindings:        " + stats.get("bindings"));
        System.out.println("  Total Messages:  " + stats.get("totalMessages"));
        System.out.println("  HA Enabled:      " + stats.get("haEnabled"));
        System.out.println("  TTL Enabled:     " + config.isEnableTTL() +
                          (config.isEnableTTL() ? " (" + (config.getTtlMilliseconds() / 3600000) + "h)" : ""));
        System.out.println();

        System.out.println("=== Setup Complete - Ready for Migration Testing ===");
        System.out.println();
    }
}
