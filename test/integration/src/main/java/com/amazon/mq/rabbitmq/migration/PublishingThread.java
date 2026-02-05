package com.amazon.mq.rabbitmq.migration;

import com.amazon.mq.rabbitmq.AmqpEndpoint;
import com.rabbitmq.client.*;
import java.io.IOException;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public class PublishingThread implements Runnable {
  private static final Logger logger = LoggerFactory.getLogger(PublishingThread.class);

  private final TestConfiguration config;
  private final int connectionIndex;
  private final BlockingQueue<PublishingTask> taskQueue;
  private volatile int currentTaskIndex = 0;
  private volatile int failureCount = 0;
  private static final int MAX_FAILURES = 3;
  private Connection connection;
  private Channel channel;
  private final Map<Long, Long> threadPendingConfirmations = new ConcurrentHashMap<>();
  private final Object confirmationLock = new Object();
  private final MessageBodyCache messageBodyCache;
  private final AtomicInteger globalPublishedCount;
  private final AtomicInteger globalConfirmedCount;
  private final int windowSize;
  private volatile boolean completed = false;

  public PublishingThread(
      TestConfiguration config,
      int connectionIndex,
      BlockingQueue<PublishingTask> taskQueue,
      AtomicInteger globalPublishedCount,
      AtomicInteger globalConfirmedCount) {
    this.config = config;
    this.connectionIndex = connectionIndex;
    this.taskQueue = taskQueue;
    this.messageBodyCache = new MessageBodyCache(config);
    this.globalPublishedCount = globalPublishedCount;
    this.globalConfirmedCount = globalConfirmedCount;
    this.windowSize = config.getConfirmationWindow();
  }

  @Override
  public void run() {
    try {
      initializeConnection();
      processPublishingTasks();
      waitForFinalConfirmations();
      completed = true;
      logger.debug("Publishing thread {} completed successfully", connectionIndex);
    } catch (Exception e) {
      logger.error("Publishing thread {} failed: {}", connectionIndex, e.getMessage());
      if (failureCount < MAX_FAILURES) {
        failureCount++;
        logger.info(
            "Restarting publishing thread {} (attempt {}/{})",
            connectionIndex,
            failureCount,
            MAX_FAILURES);
        run(); // Restart
      } else {
        logger.error("Publishing thread {} exceeded maximum failures, exiting", connectionIndex);
        System.exit(1);
      }
    }
  }

  private void initializeConnection() throws IOException, java.util.concurrent.TimeoutException {
    AmqpEndpoint amqp = config.getAmqpEndpoint(connectionIndex);
    ConnectionFactory factory = new ConnectionFactory();
    factory.setHost(amqp.getHostname());
    factory.setPort(amqp.getPort());
    factory.setUsername(amqp.getUsername());
    factory.setPassword(amqp.getPassword());
    factory.setVirtualHost(amqp.getVirtualHost());
    factory.setConnectionTimeout(10000);

    if (config.isLoadBalancerMode()) {
      factory.useSslProtocol(config.getSslContext());
    }

    connection = factory.newConnection("publishing-thread-" + connectionIndex);
    channel = connection.createChannel();
    channel.confirmSelect();
    channel.addConfirmListener(
        new ConfirmListener() {
          @Override
          public void handleAck(long deliveryTag, boolean multiple) {
            handleConfirmation(deliveryTag, multiple, true);
          }

          @Override
          public void handleNack(long deliveryTag, boolean multiple) {
            handleConfirmation(deliveryTag, multiple, false);
          }
        });
  }

  private void processPublishingTasks() throws InterruptedException, IOException {
    PublishingTask task;
    while ((task = taskQueue.take()) != null) {
      if (task.queueName == null) break; // Poison pill to stop thread
      publishMessage(task);
      currentTaskIndex++;
    }
    logger.debug(
        "Publishing thread {} finished processing {} tasks", connectionIndex, currentTaskIndex);
  }

  private void publishMessage(PublishingTask task) throws IOException, InterruptedException {
    // Wait for confirmation window space
    waitForConfirmationWindow();
    // Get message body from cache
    byte[] payload = messageBodyCache.getMessageBody(task.messageSize);
    Map<String, Object> headers =
        MessageGenerator.generateHeaders(task.messageNumber, task.messageSize.toString());
    // Track message for confirmation
    long deliveryTag = channel.getNextPublishSeqNo();
    synchronized (confirmationLock) {
      threadPendingConfirmations.put(deliveryTag, System.currentTimeMillis());
    }
    // Publish message
    AMQP.BasicProperties.Builder builder =
        new AMQP.BasicProperties.Builder().headers(headers).deliveryMode(2);
    if (task.expirationMs != null) {
      builder.expiration(String.valueOf(task.expirationMs));
    }
    AMQP.BasicProperties properties = builder.build();
    channel.basicPublish("", task.queueName, properties, payload);
    globalPublishedCount.incrementAndGet();
  }

  private void waitForConfirmationWindow() throws InterruptedException {
    synchronized (confirmationLock) {
      while (threadPendingConfirmations.size() >= windowSize) {
        confirmationLock.wait(1000);
      }
      // Adaptive delay if window is 80%+ full
      int currentPending = threadPendingConfirmations.size();
      if (currentPending >= (windowSize * 0.8)) {
        int delayMs = Math.min(50, currentPending - (int) (windowSize * 0.8));
        if (delayMs > 0) {
          Thread.sleep(delayMs);
        }
      }
    }
  }

  private void handleConfirmation(long deliveryTag, boolean multiple, boolean ack) {
    synchronized (confirmationLock) {
      if (multiple) {
        threadPendingConfirmations.entrySet().removeIf(entry -> entry.getKey() <= deliveryTag);
      } else {
        threadPendingConfirmations.remove(deliveryTag);
      }
      if (!ack) {
        logger.warn(
            "Received NACK for delivery tag {} on connection {}", deliveryTag, connectionIndex);
      }
      globalConfirmedCount.incrementAndGet();
      confirmationLock.notifyAll();
    }
  }

  private void waitForFinalConfirmations() throws InterruptedException {
    logger.debug(
        "Publishing thread {} waiting for {} pending confirmations",
        connectionIndex,
        threadPendingConfirmations.size());
    long timeout = System.currentTimeMillis() + 30000;
    while (System.currentTimeMillis() < timeout) {
      synchronized (confirmationLock) {
        if (threadPendingConfirmations.isEmpty()) break;
      }
      Thread.sleep(100);
    }
    if (!threadPendingConfirmations.isEmpty()) {
      logger.warn(
          "Publishing thread {} timed out waiting for {} confirmations",
          connectionIndex,
          threadPendingConfirmations.size());
    }
  }

  boolean isCompleted() {
    return completed;
  }

  void shutdown() {
    try {
      if (channel != null && channel.isOpen()) channel.close();
      if (connection != null && connection.isOpen()) connection.close();
    } catch (Exception e) {
      logger.warn(
          "Error closing publishing thread {} resources: {}", connectionIndex, e.getMessage());
    }
  }
}
