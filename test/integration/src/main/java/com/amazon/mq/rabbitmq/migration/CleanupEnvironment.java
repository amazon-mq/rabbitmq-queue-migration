package com.amazon.mq.rabbitmq.migration;

import com.rabbitmq.http.client.Client;
import com.rabbitmq.http.client.domain.ConnectionInfo;
import com.rabbitmq.http.client.domain.QueueInfo;
import com.rabbitmq.http.client.domain.VhostInfo;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.List;

/**
 * Aggressive cleanup of RabbitMQ test environment.
 * Matches the behavior of cleanup_previous_test_artifacts() in the shell script.
 */
public class CleanupEnvironment {

    private static final Logger logger = LoggerFactory.getLogger(CleanupEnvironment.class);

    public static void main(String[] args) {
        execute(args);
    }

    public static void execute(String[] args) {
        try {
            // Parse configuration for connection details
            TestConfiguration config = MigrationTestSetup.parseArguments(args);

            if (config.isSkipCleanup()) {
                logger.info("Skipping RabbitMQ environment cleanup");
                return;
            } else {
                logger.info("Starting RabbitMQ environment cleanup");
            }

            // Run connection tests first
            logger.info("Running connection diagnostics...");
            if (!ConnectionTest.runConnectionTests(config)) {
                logger.error("Connection tests failed. Please fix connection issues before proceeding.");
                System.exit(1);
            }

            // Perform cleanup operations
            performCleanup(config);

            logger.info("✅ RabbitMQ environment cleanup completed successfully");

        } catch (Exception e) {
            logger.error("Failed to clean up RabbitMQ environment", e);
            System.exit(1);
        }
    }

    public static void performCleanup(TestConfiguration config) throws Exception {
        logger.info("=== Phase 0: Cleaning up previous test artifacts ===");

        // Create HTTP client for management operations
        Client httpClient = config.getClusterTopology().createHttpClient();

        // Create migration client for migration records
        QueueMigrationClient migrationClient = new QueueMigrationClient(
            config.getClusterTopology().getHttpHost(),
            config.getClusterTopology().getHttpPort(),
            "guest",
            "guest",
            config.getVirtualHost()
        );

        // Step 1: Delete all non-default virtual hosts
        deleteNonDefaultVirtualHosts(httpClient);

        // Step 2: Delete all queues from the default virtual host
        deleteAllQueuesFromDefaultVhost(httpClient);

        // Step 3: Close all remaining connections
        closeAllConnections(httpClient);

        // Step 4: Check migration records (can't delete, but log them)
        checkMigrationRecords(migrationClient);

        // Step 5: Wait for cleanup to stabilize
        logger.info("Waiting for cleanup to stabilize...");
        Thread.sleep(6000);

        // Step 6: Verify clean state
        verifyCleanState(httpClient, config);

        logger.info("✅ Previous test artifacts cleanup completed");
    }

    private static void deleteNonDefaultVirtualHosts(Client httpClient) {
        logger.info("Deleting all non-default virtual hosts...");

        try {
            List<VhostInfo> vhosts = httpClient.getVhosts();
            boolean foundNonDefault = false;

            for (VhostInfo vhost : vhosts) {
                if (!TestConfiguration.isDefaultVirtualHost(vhost.getName())) {
                    foundNonDefault = true;
                    try {
                        logger.info("Deleting vhost: {}", vhost.getName());
                        httpClient.deleteVhost(vhost.getName());
                    } catch (Exception e) {
                        logger.error("Failed to delete vhost '{}': {}", vhost.getName(), e.getMessage());
                        // Continue with next vhost
                    }
                }
            }

            if (foundNonDefault) {
                logger.info("✅ Deleted non-default virtual hosts");
            } else {
                logger.info("No non-default virtual hosts to delete");
            }

        } catch (Exception e) {
            logger.error("Failed to list virtual hosts: {}", e.getMessage());
        }
    }

    private static void deleteAllQueuesFromDefaultVhost(Client httpClient) {
        // Note: there's no need to delete queues from non-default virtual hosts
        // since those are deleted by deleteNonDefaultVirtualHosts.
        final String vhost = TestConfiguration.getDefaultVirtualHost();

        logger.info("Deleting all queues from the default ({}) virtual host...", vhost);

        try {
            List<QueueInfo> queues = httpClient.getQueues(vhost);

            if (queues == null || queues.isEmpty()) {
                logger.info("No queues to delete from virtual host");
                return;
            }

            for (QueueInfo queue : queues) {
                try {
                    logger.info("Deleting queue: {}", queue.getName());
                    httpClient.deleteQueue(vhost, queue.getName());
                } catch (Exception e) {
                    logger.error("Failed to delete queue '{}': {}", queue.getName(), e.getMessage());
                    // Continue with next queue
                }
            }

            logger.info("✅ Deleted all queues from default virtual host");

        } catch (Exception e) {
            logger.error("Failed to list queues: {}", e.getMessage());
        }
    }

    private static void closeAllConnections(Client httpClient) {
        logger.info("Cleaning up any remaining connections...");

        try {
            List<ConnectionInfo> connections = httpClient.getConnections();

            if (connections.isEmpty()) {
                logger.info("No connections to close");
                return;
            }

            for (ConnectionInfo connection : connections) {
                try {
                    logger.info("Closing connection: {}", connection.getName());
                    httpClient.closeConnection(connection.getName());
                } catch (Exception e) {
                    logger.error("Failed to close connection '{}': {}", connection.getName(), e.getMessage());
                    // Continue with next connection
                }
            }

            logger.info("✅ Closed remaining connections");

        } catch (Exception e) {
            logger.error("Failed to list connections: {}", e.getMessage());
        }
    }

    private static void checkMigrationRecords(QueueMigrationClient migrationClient) {
        logger.info("Cleaning up old migration records...");

        try {
            QueueMigrationClient.MigrationStatusResponse statusResponse = migrationClient.getMigrationStatus();

            if (statusResponse.hasMigration()) {
                // Note: There's no API to delete old migration records, but we can log them
                QueueMigrationClient.MigrationInfo migration = statusResponse.getMigrationInfo();
                logger.info("Found existing migration record:");
                logger.info("  - {}: {} (started: {})",
                    migration.getDisplayId(), migration.getStatus(), migration.getStartedAt());
                logger.info("Note: Old migration records will remain but won't affect new migrations");
            } else {
                logger.info("No existing migration records found");
            }

        } catch (Exception e) {
            logger.info("Could not check migration records (migration plugin may not be available): {}",
                e.getMessage());
        }
    }

    private static void verifyCleanState(Client httpClient, TestConfiguration config) {
        logger.info("Clean state verification:");

        try {
            // Count virtual hosts
            List<VhostInfo> vhosts = httpClient.getVhosts();
            logger.info("  Virtual hosts: {} (should be 1 - default only)", vhosts.size());

            // Count queues in configured vhost
            List<QueueInfo> queues = httpClient.getQueues(config.getVirtualHost());
            int queueCount = (queues != null) ? queues.size() : 0;
            logger.info("  Queues in {}: {} (should be 0)", config.getVirtualHost(), queueCount);

            // Count active connections
            List<ConnectionInfo> connections = httpClient.getConnections();
            logger.info("  Active connections: {} (should be 0)", connections.size());

            // Verify we have exactly the expected clean state
            if (vhosts.size() == 1 && queues.size() == 0 && connections.size() == 0) {
                logger.info("✅ Clean state verification passed");
            } else {
                logger.warn("⚠️ Clean state verification shows unexpected resources remaining");
            }

        } catch (Exception e) {
            logger.error("Failed to verify clean state: {}", e.getMessage());
        }
    }
}
