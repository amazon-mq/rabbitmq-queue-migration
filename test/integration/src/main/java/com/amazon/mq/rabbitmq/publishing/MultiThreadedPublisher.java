package com.amazon.mq.rabbitmq.publishing;

import com.amazon.mq.rabbitmq.BrokerNode;
import com.amazon.mq.rabbitmq.ClusterInfo;
import com.rabbitmq.client.*;
import com.rabbitmq.http.client.Client;
import com.rabbitmq.http.client.domain.QueueInfo;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.stream.Collectors;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Multi-threaded publisher for RabbitMQ messages with automatic queue leader discovery and
 * publisher confirmation tracking.
 */
public class MultiThreadedPublisher {
  private static final Logger logger = LoggerFactory.getLogger(MultiThreadedPublisher.class);

  private final PublishingConfiguration config;
  private ClusterInfo clusterInfo;
  private final Map<String, Connection> nodeConnections = new ConcurrentHashMap<>();
  private final Map<String, Channel> nodeChannels = new ConcurrentHashMap<>();
  private final AtomicInteger globalPublishedCount = new AtomicInteger(0);
  private final AtomicInteger globalConfirmedCount = new AtomicInteger(0);
  private final AtomicInteger globalNackedCount = new AtomicInteger(0);

  private ExecutorService publishingExecutor;
  private boolean initialized = false;
  private boolean disposed = false;

  public MultiThreadedPublisher(PublishingConfiguration config) {
    this.config = config;
  }

  /** Initialize the publisher by discovering queue leaders and establishing connections. */
  private void initialize(List<PublishingTask> tasks) throws PublishingException {
    if (initialized) {
      throw new IllegalStateException("Publisher already initialized");
    }
    if (disposed) {
      throw new IllegalStateException("Publisher has been disposed");
    }

    try {
      logger.debug("Initializing multi-threaded publisher for {} nodes", config.getNodeCount());

      // Get cluster information for required queues
      List<String> queueNames =
          tasks.stream().map(PublishingTask::getQueueName).distinct().collect(Collectors.toList());

      clusterInfo = discoverQueueLeaders(queueNames);

      // Establish connections to required nodes
      establishConnections();

      initialized = true;
      logger.debug("Publisher initialized successfully");

    } catch (Exception e) {
      cleanup();
      if (e instanceof PublishingException) {
        throw e;
      }
      throw new PublishingException.ConnectionFailedException("Failed to initialize publisher", e);
    }
  }

  /** Publish messages asynchronously. */
  public PublishingResult publishAsync(List<PublishingTask> tasks) throws PublishingException {
    if (disposed) {
      throw new IllegalStateException("Publisher has been disposed");
    }

    if (tasks == null || tasks.isEmpty()) {
      // Handle empty task list - return completed result immediately
      CompletableFuture<Void> completedFuture = CompletableFuture.completedFuture(null);
      AtomicInteger publishedCount = new AtomicInteger(0);
      AtomicInteger confirmedCount = new AtomicInteger(0);
      AtomicInteger nackedCount = new AtomicInteger(0);
      return new PublishingResult(completedFuture, publishedCount, confirmedCount, nackedCount, 0);
    }

    initialize(tasks);

    logger.debug("Starting async publishing of {} tasks", tasks.size());

    // Calculate thread pool size
    int threadPoolSize = calculateThreadPoolSize(tasks.size());
    publishingExecutor = Executors.newFixedThreadPool(threadPoolSize);

    // Group tasks by target node
    Map<String, List<PublishingTask>> tasksByNode = groupTasksByNode(tasks);

    // Create completion future
    CompletableFuture<Void> completionFuture = new CompletableFuture<>();

    // Create result object
    PublishingResult result =
        new PublishingResult(
            completionFuture,
            globalPublishedCount,
            globalConfirmedCount,
            globalNackedCount,
            tasks.size());

    // Start publishing threads
    List<CompletableFuture<Void>> threadFutures = new ArrayList<>();
    for (Map.Entry<String, List<PublishingTask>> entry : tasksByNode.entrySet()) {
      String nodeHost = entry.getKey();
      List<PublishingTask> nodeTasks = entry.getValue();

      CompletableFuture<Void> threadFuture =
          CompletableFuture.runAsync(new PublishingWorker(nodeHost, nodeTasks), publishingExecutor);
      threadFutures.add(threadFuture);
    }

    // Complete when all threads finish
    CompletableFuture.allOf(threadFutures.toArray(new CompletableFuture[0]))
        .whenComplete(
            (unused, throwable) -> {
              if (throwable != null) {
                logger.error("Publishing failed", throwable);
                cleanup();
                completionFuture.completeExceptionally(throwable);
              } else {
                logger.debug("All publishing threads completed successfully");
                cleanup();
                completionFuture.complete(null);
              }
            });

    return result;
  }

  private void establishConnections() throws PublishingException {
    logger.debug("Establishing connections to required nodes");

    Set<BrokerNode> requiredNodes = clusterInfo.getRequiredNodes();

    // Get credentials from cluster topology
    String username = config.getClusterTopology().getUsername();
    String password = config.getClusterTopology().getPassword();

    for (BrokerNode brokerNode : requiredNodes) {
      try {
        ConnectionFactory factory = new ConnectionFactory();
        factory.setHost(brokerNode.getHostname());
        factory.setPort(brokerNode.getAmqpPort());
        factory.setUsername(username);
        factory.setPassword(password);
        factory.setVirtualHost(config.getVirtualHost());

        Connection connection = factory.newConnection();
        Channel channel = connection.createChannel();
        channel.confirmSelect(); // Enable publisher confirmations

        nodeConnections.put(brokerNode.getNodeName(), connection);
        nodeChannels.put(brokerNode.getNodeName(), channel);

        logger.debug(
            "Established connection to node: {} ({}:{})",
            brokerNode.getNodeName(),
            brokerNode.getHostname(),
            brokerNode.getAmqpPort());

      } catch (Exception e) {
        throw new PublishingException.ConnectionFailedException(
            "Failed to connect to node: " + brokerNode.getNodeName(), e);
      }
    }

    logger.debug("Established connections to {} nodes", nodeConnections.size());
  }

  private ClusterInfo discoverQueueLeaders(List<String> queueNames) throws PublishingException {
    logger.debug("Discovering queue leaders for {} unique queues", queueNames.size());

    try {
      // Get all broker nodes from cluster topology
      Map<String, BrokerNode> brokerNodes = config.getClusterTopology().getAllNodes();

      // Get queue information to discover leaders
      Client httpClient = config.getClusterTopology().createHttpClient();
      List<QueueInfo> queues = httpClient.getQueues(config.getVirtualHost());
      Map<String, String> queueLeaders = new HashMap<>();

      for (String queueName : queueNames) {
        QueueInfo queueInfo =
            queues.stream().filter(q -> queueName.equals(q.getName())).findFirst().orElse(null);

        if (queueInfo == null) {
          throw new PublishingException.QueueNotFoundException(queueName);
        }

        String leaderNodeName = queueInfo.getNode();
        if (leaderNodeName == null || !brokerNodes.containsKey(leaderNodeName)) {
          throw new PublishingException.LeaderDiscoveryException(
              "Queue " + queueName + " leader node " + leaderNodeName + " not found in cluster",
              null);
        }

        queueLeaders.put(queueName, leaderNodeName);
        logger.debug("Queue {} leader: {}", queueName, leaderNodeName);
      }

      logger.debug(
          "Discovered leaders for {} queues across {} broker nodes",
          queueLeaders.size(),
          brokerNodes.size());

      return new ClusterInfo(brokerNodes, queueLeaders);

    } catch (Exception e) {
      if (e instanceof PublishingException) {
        throw e;
      }
      throw new PublishingException.LeaderDiscoveryException("Failed to discover queue leaders", e);
    }
  }

  private int calculateThreadPoolSize(int taskCount) {
    int nodeCount = config.getNodeCount();
    int cpuCount = Runtime.getRuntime().availableProcessors();
    int maxThreads = nodeCount * cpuCount;
    return Math.min(maxThreads, taskCount);
  }

  private Map<String, List<PublishingTask>> groupTasksByNode(List<PublishingTask> tasks) {
    return tasks.stream()
        .collect(
            Collectors.groupingBy(task -> clusterInfo.getQueueLeaders().get(task.getQueueName())));
  }

  private void cleanup() {
    logger.debug("Cleaning up publisher resources");

    // Close channels
    for (Channel channel : nodeChannels.values()) {
      try {
        if (channel.isOpen()) {
          channel.close();
        }
      } catch (Exception e) {
        logger.warn("Error closing channel", e);
      }
    }
    nodeChannels.clear();

    // Close connections
    for (Connection connection : nodeConnections.values()) {
      try {
        if (connection.isOpen()) {
          connection.close();
        }
      } catch (Exception e) {
        logger.warn("Error closing connection", e);
      }
    }
    nodeConnections.clear();

    // Shutdown executor
    if (publishingExecutor != null) {
      publishingExecutor.shutdown();
      try {
        if (!publishingExecutor.awaitTermination(1, TimeUnit.SECONDS)) {
          publishingExecutor.shutdownNow();
        }
      } catch (InterruptedException e) {
        publishingExecutor.shutdownNow();
        Thread.currentThread().interrupt();
      }
    }

    disposed = true;
  }

  /** Worker thread for publishing messages to a specific node. */
  private class PublishingWorker implements Runnable {
    private final String nodeHost;
    private final List<PublishingTask> tasks;
    private final Map<Long, Long> pendingConfirmations = new ConcurrentHashMap<>();
    private final Object confirmationLock = new Object();

    public PublishingWorker(String nodeHost, List<PublishingTask> tasks) {
      this.nodeHost = nodeHost;
      this.tasks = tasks;
    }

    @Override
    public void run() {
      try {
        Channel channel = nodeChannels.get(nodeHost);
        if (channel == null) {
          throw new PublishingException.ConnectionFailedException(
              "No channel available for node: " + nodeHost, null);
        }

        // Set up confirmation listener
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

        logger.debug("Publishing {} tasks on node: {}", tasks.size(), nodeHost);

        // Publish messages with confirmation window
        int windowSize = config.getConfirmationWindow();
        for (int i = 0; i < tasks.size(); i++) {
          PublishingTask task = tasks.get(i);

          long deliveryTag = channel.getNextPublishSeqNo();
          pendingConfirmations.put(deliveryTag, System.currentTimeMillis());

          // Publish to default exchange with queue name as routing key
          channel.basicPublish("", task.getQueueName(), null, task.getMessageBody());
          globalPublishedCount.incrementAndGet();

          // Wait for confirmation window space (like original code)
          synchronized (confirmationLock) {
            while (pendingConfirmations.size() >= windowSize) {
              try {
                confirmationLock.wait(1000);
              } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new PublishingException(
                    "Interrupted while waiting for confirmation window", e);
              }
            }
          }
        }

        // Wait for all remaining confirmations
        waitForAllConfirmations();

        logger.debug("Completed publishing {} tasks on node: {}", tasks.size(), nodeHost);

      } catch (Exception e) {
        logger.error("Publishing worker failed on node: " + nodeHost, e);
        throw new RuntimeException(e);
      }
    }

    private void handleConfirmation(long deliveryTag, boolean multiple, boolean ack) {
      synchronized (confirmationLock) {
        int confirmedCount = 0;
        if (multiple) {
          // Count how many confirmations we're removing
          confirmedCount =
              (int)
                  pendingConfirmations.entrySet().stream()
                      .mapToLong(entry -> entry.getKey())
                      .filter(tag -> tag <= deliveryTag)
                      .count();
          // Remove all confirmations up to and including this delivery tag
          pendingConfirmations.entrySet().removeIf(entry -> entry.getKey() <= deliveryTag);
        } else {
          if (pendingConfirmations.remove(deliveryTag) != null) {
            confirmedCount = 1;
          }
        }

        if (ack) {
          globalConfirmedCount.addAndGet(confirmedCount);
        } else {
          globalNackedCount.addAndGet(confirmedCount);
        }

        confirmationLock.notifyAll(); // Wake up waiting threads
      }
    }

    private void waitForConfirmations(int targetRemaining) throws PublishingException {
      long timeout = System.currentTimeMillis() + 30000; // 30 second timeout

      while (System.currentTimeMillis() < timeout) {
        synchronized (confirmationLock) {
          if (pendingConfirmations.size() <= targetRemaining) {
            return; // Success
          }
          try {
            confirmationLock.wait(100); // Wait for notifications
          } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new PublishingException("Interrupted while waiting for confirmations", e);
          }
        }
      }

      // Timeout occurred
      synchronized (confirmationLock) {
        if (pendingConfirmations.size() > targetRemaining) {
          logger.warn(
              "Confirmation timeout: {} confirmations still pending", pendingConfirmations.size());
          throw new PublishingException.ConfirmationTimeoutException(pendingConfirmations.size());
        }
      }
    }

    private void waitForAllConfirmations() throws PublishingException {
      logger.debug("Waiting for all confirmations. Pending: {}", pendingConfirmations.size());
      waitForConfirmations(0);
      logger.debug("All confirmations received. Pending: {}", pendingConfirmations.size());
    }
  }
}
