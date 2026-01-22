package com.amazon.mq.rabbitmq.publishing;

import com.amazon.mq.rabbitmq.ClusterTopology;
import com.rabbitmq.http.client.Client;
import com.rabbitmq.http.client.domain.QueueInfo;
import java.util.ArrayList;
import java.util.List;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Example usage of the multi-threaded publishing infrastructure. Demonstrates basic publishing,
 * progress monitoring, and error handling.
 */
public class PublishingExample {
  private static final Logger logger = LoggerFactory.getLogger(PublishingExample.class);

  public static void main(String[] args) throws Exception {
    basicPublishingExample();
    publishingWithProgressMonitoring();
    // errorHandlingExample(); // Uncomment to test error scenarios
  }

  /** Basic publishing example - publish and wait for completion. */
  public static void basicPublishingExample() throws Exception {
    logger.info("=== Basic Publishing Example ===");

    // 1. Create test queues
    createTestQueues();

    // 2. Create cluster topology and configuration
    ClusterTopology clusterTopology = new ClusterTopology("localhost", 15672);
    PublishingConfiguration config = new PublishingConfiguration(clusterTopology);

    // 3. Create publishing tasks
    List<PublishingTask> tasks = new ArrayList<>();
    for (int i = 0; i < 50; i++) {
      String queueName = "test.queue." + (i % 3);
      String message = "Hello from basic example " + i;
      tasks.add(new PublishingTask(queueName, message.getBytes()));
    }

    // 4. Publish and wait for completion
    MultiThreadedPublisher publisher = new MultiThreadedPublisher(config);
    PublishingResult result = publisher.publishAsync(tasks);

    long startTime = System.currentTimeMillis();
    result.awaitCompletion();
    long duration = System.currentTimeMillis() - startTime;

    double messagesPerSecond = (double) result.getPublishedCount() / (duration / 1000.0);
    System.out.printf(
        "Published %d/%d messages in %d ms (%.1f msg/sec)%n",
        result.getPublishedCount(), tasks.size(), duration, messagesPerSecond);

    logger.info("Basic publishing completed successfully!");
  }

  /** Publishing with progress monitoring - monitor progress while publishing continues. */
  public static void publishingWithProgressMonitoring() throws Exception {
    logger.info("=== Publishing with Progress Monitoring ===");

    // 1. Create test queues
    createTestQueues();

    // 2. Create cluster topology and configuration with larger confirmation window
    ClusterTopology clusterTopology = new ClusterTopology("localhost", 15672);
    PublishingConfiguration config = new PublishingConfiguration(clusterTopology, 8);

    // 3. Create more tasks for longer-running example
    List<PublishingTask> tasks = new ArrayList<>();
    for (int i = 0; i < 200; i++) {
      String queueName = "test.queue." + (i % 3);
      String message = "Hello from progress monitoring example " + i + " - " + "x".repeat(100);
      tasks.add(new PublishingTask(queueName, message.getBytes()));
    }

    // 4. Start publishing asynchronously
    MultiThreadedPublisher publisher = new MultiThreadedPublisher(config);
    PublishingResult result = publisher.publishAsync(tasks);

    // 5. Monitor progress
    logger.info("Monitoring publishing progress...");
    long startTime = System.currentTimeMillis();

    while (!result.isComplete()) {
      long elapsed = System.currentTimeMillis() - startTime;
      double messagesPerSecond =
          elapsed > 0 ? (double) result.getPublishedCount() / (elapsed / 1000.0) : 0.0;

      int progressPercent = (int) ((double) result.getConfirmedCount() / tasks.size() * 100);
      System.out.printf(
          "Progress: %d%% (%d/%d published, %d confirmed, %.1f msg/sec)%n",
          progressPercent,
          result.getPublishedCount(),
          tasks.size(),
          result.getConfirmedCount(),
          messagesPerSecond);

      Thread.sleep(500); // Check progress every 500ms
    }

    // 6. Final results
    long totalDuration = System.currentTimeMillis() - startTime;
    System.out.printf(
        "Final: Published %d messages, confirmed %d, took %d ms%n",
        result.getPublishedCount(), result.getConfirmedCount(), totalDuration);

    logger.info("Progress monitoring example completed!");
  }

  /** Error handling example - demonstrates exception handling. */
  public static void errorHandlingExample() throws Exception {
    logger.info("=== Error Handling Example ===");

    try {
      ClusterTopology clusterTopology = new ClusterTopology("localhost", 15672);
      PublishingConfiguration config = new PublishingConfiguration(clusterTopology);

      // Create task for non-existent queue to trigger error
      List<PublishingTask> tasks =
          List.of(new PublishingTask("non.existent.queue", "This will fail".getBytes()));

      MultiThreadedPublisher publisher = new MultiThreadedPublisher(config);
      publisher.publishAsync(tasks);

    } catch (Exception e) {
      logger.error("Expected error occurred: {}", e.getMessage());
      logger.info("Error handling example completed!");
    }
  }

  /** Create test queues for examples. */
  private static void createTestQueues() throws Exception {
    ClusterTopology clusterTopology = new ClusterTopology("localhost", 15672);
    Client httpClient = clusterTopology.createHttpClient();

    for (int i = 0; i < 3; i++) {
      String queueName = "test.queue." + i;
      try {
        QueueInfo queueInfo = new QueueInfo();
        queueInfo.setName(queueName);
        queueInfo.setDurable(true);
        httpClient.declareQueue("/", queueName, queueInfo);
      } catch (Exception e) {
        logger.debug("Queue {} already exists or creation failed: {}", queueName, e.getMessage());
      }
    }
  }
}
