package com.amazon.mq.rabbitmq.migration;

import com.rabbitmq.http.client.Client;
import com.rabbitmq.http.client.domain.QueueInfo;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.List;

/**
 * Utility class for RabbitMQ statistics operations.
 * Provides simple stats stabilization for migration validation.
 */
public class RabbitMQStatsUtils {

    private static final Logger logger = LoggerFactory.getLogger(RabbitMQStatsUtils.class);

    /**
     * Wait for test queue message counts to stabilize.
     * This method polls RabbitMQ queue statistics and waits until the message count
     * remains exactly the same between consecutive checks.
     *
     * @param httpClient The RabbitMQ HTTP client to use for API calls
     * @param vhost The virtual host to query queues from
     * @param context Description of the context for logging (e.g., "pre-migration", "post-migration")
     * @return The final stabilized message count
     * @throws Exception if there's an error communicating with RabbitMQ
     */
    public static long waitForTestQueueStatsToStabilize(Client httpClient, String vhost, String context) throws Exception {
        logger.info("Waiting for RabbitMQ stats to stabilize{}...",
            context != null && !context.isEmpty() ? " for " + context : "");

        int maxAttempts = 10;
        int sleepDurationSeconds = 6;
        int attempt = 1;
        long previousCount = 0;
        long currentCount = 0;

        while (attempt <= maxAttempts) {
            logger.info("Stats stability check attempt {}/{}...", attempt, maxAttempts);

            if (attempt > 1) {
                Thread.sleep(sleepDurationSeconds * 1000);
            }

            try {
                List<QueueInfo> queues = httpClient.getQueues(vhost);
                currentCount = queues.stream()
                    .filter(q -> q.getName().startsWith("test.queue."))
                    .mapToLong(QueueInfo::getMessagesReady)
                    .sum();

                logger.info("Message count: {} (previous: {})", currentCount, previousCount);

                if (currentCount == previousCount && attempt > 1) {
                    logger.info("✅ Stats have stabilized at {} messages after {} seconds",
                        currentCount, attempt * sleepDurationSeconds);
                    return currentCount;
                }

                previousCount = currentCount;
                attempt++;

            } catch (Exception e) {
                logger.warn("Error during stats stability check attempt {}: {}", attempt, e.getMessage());
                if (attempt == maxAttempts) {
                    throw e;
                }
                attempt++;
            }
        }

        logger.warn("Stats stability timeout reached after {} seconds", maxAttempts * sleepDurationSeconds);
        return currentCount;
    }
}
