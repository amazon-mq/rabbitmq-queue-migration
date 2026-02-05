package com.amazon.mq.rabbitmq.migration;

import com.amazon.mq.rabbitmq.AmqpEndpoint;
import com.amazon.mq.rabbitmq.ClusterTopology;
import com.rabbitmq.http.client.Client;

/** Configuration class for migration test setup parameters. */
public class TestConfiguration {

  // Cluster topology for RabbitMQ connections
  private final ClusterTopology clusterTopology;

  // Test configuration parameters (replacing instance type)
  private int queueCount = 10;
  private int totalMessages = 5500;
  private int exchangeCount = 5;
  private int bindingsPerQueue = 6;
  private int confirmationWindow = 4;
  private int migrationTimeout = 300; // 5 minutes default
  private boolean skipCleanup = false; // Skip cleanup in end-to-end mode
  private boolean skipSetup = false; // Skip setup in end-to-end mode
  private int unsuitableQueueCount = 0; // Number of unsuitable queues to create for testing

  private String virtualHost = getDefaultVirtualHost();
  private String queuePrefix = "test.queue.ha-all.";
  private String unsuitableQueuePrefix = "test.unsuitable.queue.ha-all.";
  private String exchangePrefix = "test.exchange.";
  private boolean skipUnsuitableQueues = false;
  private Integer batchSize = null; // null means "all"
  private String batchOrder = "smallest_first";

  // Per-message TTL configuration
  private int perMessageTtlPercent = 0; // Percentage of messages with per-message TTL
  private int perMessageTtlSeconds = 300; // 5 minutes default

  /**
   * Get the default virtual host used when no specific vhost is configured.
   *
   * @return the default virtual host "/"
   */
  public static String getDefaultVirtualHost() {
    return "/";
  }

  public static boolean isDefaultVirtualHost(String vhost) {
    return getDefaultVirtualHost().equals(vhost);
  }

  // Message size configuration (in bytes)
  private int smallMessageSize = 1024; // 1KiB
  private int mediumMessageSize = 102400; // 100KiB
  private int largeMessageSize = 1048576; // 1MiB

  // Message distribution percentages (as integers that sum to 100)
  private int smallMessagePercent = 70; // 70%
  private int mediumMessagePercent = 20; // 20%
  private int largeMessagePercent = 10; // 10%

  // Queue configuration
  private boolean enableHA = true; // Create mirrored classic queues
  private String haPolicy = "all"; // Mirror to all nodes
  private boolean enableTTL =
      false; // Enable TTL on queues (disabled by default to prevent migration issues)
  private boolean enableMaxLength =
      false; // Enable max length on queues (disabled by default to prevent migration issues)
  private boolean enableMaxPriority =
      false; // Enable priority on queues (disabled by default to prevent migration issues)
  private long ttlMilliseconds = 3600000; // 1 hour TTL when enabled

  /** Initialize with cluster topology */
  public TestConfiguration(ClusterTopology clusterTopology) {
    this.clusterTopology = clusterTopology;
  }

  public ClusterTopology getClusterTopology() {
    return clusterTopology;
  }

  public Client createHttpClient() {
    return clusterTopology.createHttpClient();
  }

  public AmqpEndpoint getAmqpEndpoint(int index) {
    return clusterTopology.getAmqpEndpoint(index);
  }

  public String getHttpHost() {
    return clusterTopology.getHttpHost();
  }

  public int getHttpPort() {
    return clusterTopology.getHttpPort();
  }

  public int getNodeCount() {
    return clusterTopology.getNodeCount();
  }

  public Client createHttpClient(int idx) {
    return clusterTopology.createHttpClient(idx);
  }

  public boolean isLoadBalancerMode() {
    return clusterTopology.isLoadBalancerMode();
  }

  public javax.net.ssl.SSLContext getSslContext() {
    return clusterTopology.getSslContext();
  }

  /**
   * Create a QueueMigrationClient configured for this topology.
   */
  public QueueMigrationClient createMigrationClient() {
    return new QueueMigrationClient(
        getHttpHost(),
        getHttpPort(),
        clusterTopology.getUsername(),
        clusterTopology.getPassword(),
        virtualHost,
        getSslContext());
  }

  public int getSmallMessageSize() {
    return smallMessageSize;
  }

  public void setSmallMessageSize(int smallMessageSize) {
    this.smallMessageSize = smallMessageSize;
  }

  public int getMediumMessageSize() {
    return mediumMessageSize;
  }

  public void setMediumMessageSize(int mediumMessageSize) {
    this.mediumMessageSize = mediumMessageSize;
  }

  public int getLargeMessageSize() {
    return largeMessageSize;
  }

  public void setLargeMessageSize(int largeMessageSize) {
    this.largeMessageSize = largeMessageSize;
  }

  public double getSmallMessagePercent() {
    return smallMessagePercent / 100.0;
  }

  public void setSmallMessagePercent(int smallMessagePercent) {
    this.smallMessagePercent = smallMessagePercent;
  }

  public double getMediumMessagePercent() {
    return mediumMessagePercent / 100.0;
  }

  public void setMediumMessagePercent(int mediumMessagePercent) {
    this.mediumMessagePercent = mediumMessagePercent;
  }

  public double getLargeMessagePercent() {
    return largeMessagePercent / 100.0;
  }

  public void setLargeMessagePercent(int largeMessagePercent) {
    this.largeMessagePercent = largeMessagePercent;
  }

  /** Set message distribution from comma-separated percentages */
  public void setMessageDistribution(String distribution) {
    String[] parts = distribution.split(",");
    if (parts.length != 3) {
      throw new IllegalArgumentException("Message distribution must have exactly 3 values");
    }

    int small = Integer.parseInt(parts[0].trim());
    int medium = Integer.parseInt(parts[1].trim());
    int large = Integer.parseInt(parts[2].trim());

    if (small + medium + large != 100) {
      throw new IllegalArgumentException("Message distribution percentages must sum to 100");
    }

    this.smallMessagePercent = small;
    this.mediumMessagePercent = medium;
    this.largeMessagePercent = large;
  }

  /** Set message sizes from comma-separated byte values */
  public void setMessageSizes(String sizes) {
    String[] parts = sizes.split(",");
    if (parts.length != 3) {
      throw new IllegalArgumentException("Message sizes must have exactly 3 values");
    }

    int small = Integer.parseInt(parts[0].trim());
    int medium = Integer.parseInt(parts[1].trim());
    int large = Integer.parseInt(parts[2].trim());

    // Validate size limits (8 bytes to 4MiB)
    int maxSize = 4 * 1024 * 1024; // 4MiB in bytes
    if (small < 8
        || small > maxSize
        || medium < 8
        || medium > maxSize
        || large < 8
        || large > maxSize) {
      throw new IllegalArgumentException("Message sizes must be between 8 bytes and 4MiB");
    }

    this.smallMessageSize = small;
    this.mediumMessageSize = medium;
    this.largeMessageSize = large;
  }

  public boolean isEnableHA() {
    return enableHA;
  }

  public void setEnableHA(boolean enableHA) {
    this.enableHA = enableHA;
  }

  public String getHaPolicy() {
    return haPolicy;
  }

  public void setHaPolicy(String haPolicy) {
    this.haPolicy = haPolicy;
  }

  public boolean isEnableTTL() {
    return enableTTL;
  }

  public void setEnableTTL(boolean enableTTL) {
    this.enableTTL = enableTTL;
  }

  public boolean isEnableMaxLength() {
    return enableMaxLength;
  }

  public void setEnableMaxLength(boolean enableMaxLength) {
    this.enableMaxLength = enableMaxLength;
  }

  public boolean isEnableMaxPriority() {
    return enableMaxPriority;
  }

  public void setEnableMaxPriority(boolean enableMaxPriority) {
    this.enableMaxPriority = enableMaxPriority;
  }

  public long getTtlMilliseconds() {
    return ttlMilliseconds;
  }

  public void setTtlMilliseconds(long ttlMilliseconds) {
    this.ttlMilliseconds = ttlMilliseconds;
  }

  // Getters and setters for new configuration parameters
  public int getQueueCount() {
    return queueCount;
  }

  public void setQueueCount(int queueCount) {
    this.queueCount = Math.max(10, Math.min(65536, queueCount));
  }

  public int getTotalMessages() {
    return totalMessages;
  }

  public void setTotalMessages(int totalMessages) {
    this.totalMessages = totalMessages;
  }

  public int getExchangeCount() {
    return exchangeCount;
  }

  public void setExchangeCount(int exchangeCount) {
    this.exchangeCount = exchangeCount;
  }

  public int getBindingsPerQueue() {
    return bindingsPerQueue;
  }

  public void setBindingsPerQueue(int bindingsPerQueue) {
    this.bindingsPerQueue = bindingsPerQueue;
  }

  public int getConfirmationWindow() {
    return confirmationWindow;
  }

  public void setConfirmationWindow(int confirmationWindow) {
    this.confirmationWindow = Math.max(4, Math.min(256, confirmationWindow));
  }

  public int getMigrationTimeout() {
    return migrationTimeout;
  }

  public void setMigrationTimeout(int migrationTimeout) {
    this.migrationTimeout = migrationTimeout;
  }

  public boolean isSkipCleanup() {
    return skipCleanup;
  }

  public void setSkipCleanup(boolean skipCleanup) {
    this.skipCleanup = skipCleanup;
  }

  public boolean isSkipSetup() {
    return skipSetup;
  }

  public void setSkipSetup(boolean skipSetup) {
    this.skipSetup = skipSetup;
  }

  public int getUnsuitableQueueCount() {
    return unsuitableQueueCount;
  }

  public void setUnsuitableQueueCount(int unsuitableQueueCount) {
    this.unsuitableQueueCount = Math.max(0, unsuitableQueueCount);
  }

  private int quorumQueueCount = 0; // Number of quorum queues to create for testing

  public int getQuorumQueueCount() {
    return quorumQueueCount;
  }

  public void setQuorumQueueCount(int quorumQueueCount) {
    this.quorumQueueCount = Math.max(0, quorumQueueCount);
  }

  public String getVirtualHost() {
    return virtualHost;
  }

  public void setVirtualHost(String virtualHost) {
    this.virtualHost = virtualHost;
  }

  public String getQueuePrefix() {
    return queuePrefix;
  }

  public void setQueuePrefix(String queuePrefix) {
    this.queuePrefix = queuePrefix;
  }

  public String getUnsuitableQueuePrefix() {
    return unsuitableQueuePrefix;
  }

  public void setUnsuitableQueuePrefix(String unsuitableQueuePrefix) {
    this.unsuitableQueuePrefix = unsuitableQueuePrefix;
  }

  public String getExchangePrefix() {
    return exchangePrefix;
  }

  public void setExchangePrefix(String exchangePrefix) {
    this.exchangePrefix = exchangePrefix;
  }

  public boolean isSkipUnsuitableQueues() {
    return skipUnsuitableQueues;
  }

  public void setSkipUnsuitableQueues(boolean skipUnsuitableQueues) {
    this.skipUnsuitableQueues = skipUnsuitableQueues;
  }

  public Integer getBatchSize() {
    return batchSize;
  }

  public void setBatchSize(Integer batchSize) {
    this.batchSize = batchSize;
  }

  public String getBatchOrder() {
    return batchOrder;
  }

  public void setBatchOrder(String batchOrder) {
    this.batchOrder = batchOrder;
  }

  public int getPerMessageTtlPercent() {
    return perMessageTtlPercent;
  }

  public void setPerMessageTtlPercent(int perMessageTtlPercent) {
    this.perMessageTtlPercent = Math.max(0, Math.min(100, perMessageTtlPercent));
  }

  public int getPerMessageTtlSeconds() {
    return perMessageTtlSeconds;
  }

  public void setPerMessageTtlSeconds(int perMessageTtlSeconds) {
    this.perMessageTtlSeconds = perMessageTtlSeconds;
  }
}
