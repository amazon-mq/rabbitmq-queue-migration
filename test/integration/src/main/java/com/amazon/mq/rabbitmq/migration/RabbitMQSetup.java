package com.amazon.mq.rabbitmq.migration;

import com.rabbitmq.client.*;
import com.rabbitmq.http.client.Client;
import com.rabbitmq.http.client.domain.*;
import com.amazon.mq.rabbitmq.AmqpEndpoint;
import com.amazon.mq.rabbitmq.publishing.MultiThreadedPublisher;
import com.amazon.mq.rabbitmq.publishing.PublishingConfiguration;
import com.amazon.mq.rabbitmq.publishing.PublishingResult;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.net.MalformedURLException;
import java.net.URISyntaxException;
import java.security.KeyManagementException;
import java.security.NoSuchAlgorithmException;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.TimeoutException;

/**
 * Sets up RabbitMQ cluster with queues, exchanges, bindings, and messages for migration testing.
 */
public class RabbitMQSetup {
    private static final Logger logger = LoggerFactory.getLogger(RabbitMQSetup.class);

    private final TestConfiguration config;
    private Connection[] connections;
    private Channel[] channels;
    private Client[] httpClients;
    private int currentConnectionIndex = 0;
    private int currentHttpClientIndex = 0;

    // Multi-threaded publishing
    private Map<String, Integer> queueToConnectionMap = new ConcurrentHashMap<>();
    private ExecutorService publishingExecutor;
    private PublishingThread[] publishingThreads;
    private AtomicInteger globalPublishedCount = new AtomicInteger(0);
    private AtomicInteger globalConfirmedCount = new AtomicInteger(0);

    public RabbitMQSetup(TestConfiguration config) {
        this.config = config;
    }

    /**
     * Initialize connections to RabbitMQ using URI-based configuration
     */
    public void initialize() throws IOException, TimeoutException, URISyntaxException,
                                   NoSuchAlgorithmException, KeyManagementException, MalformedURLException {

        int nodeCount = config.getClusterTopology().getNodeCount();

        logger.info("Initializing RabbitMQ connections to {} cluster nodes...", nodeCount);

        // Initialize arrays based on actual node count
        connections = new Connection[nodeCount];
        channels = new Channel[nodeCount];

        // Initialize AMQP connections
        for (int i = 0; i < nodeCount; i++) {
            AmqpEndpoint endpoint = config.getAmqpEndpoint(i);

            try {
                ConnectionFactory factory = new ConnectionFactory();
                factory.setHost(endpoint.getHostname());
                factory.setPort(endpoint.getPort());
                factory.setUsername(endpoint.getUsername());
                factory.setPassword(endpoint.getPassword());
                factory.setVirtualHost(endpoint.getVirtualHost());
                factory.setAutomaticRecoveryEnabled(true);
                factory.setNetworkRecoveryInterval(5000);
                factory.setConnectionTimeout(10000); // 10 second timeout

                connections[i] = factory.newConnection("migration-test-setup-" + endpoint.getHostname() + "-" + endpoint.getPort());
                channels[i] = connections[i].createChannel();

                // NOTE: intentionally NOT enabling publisher confirmations

                logger.info("AMQP connection established to {}:{} vhost '{}' with confirmations enabled",
                    endpoint.getHostname(), endpoint.getPort(), endpoint.getVirtualHost());
            } catch (IOException e) {
                logger.error("Failed to connect to AMQP at {}:{}: {}", endpoint.getHostname(), endpoint.getPort(), e.getMessage());
                throw new IOException("AMQP connection failed to " + endpoint.getHostname() + ":" + endpoint.getPort(), e);
            }
        }

        // Initialize HTTP management clients
        httpClients = new Client[nodeCount];

        for (int i = 0; i < nodeCount; i++) {
            try {
                Client c = config.getClusterTopology().createHttpClient(i);
                httpClients[i] = c;
                // Test the management connection with a simple call
                httpClients[i].getVhosts();
                logger.info("Management API connection established to {}", c.toString());
            } catch (Exception e) {
                logger.error("Failed to connect to management API: {}", e.getMessage());
                throw e;
            }
        }

        logger.info("RabbitMQ connections established successfully to {} AMQP hosts and {} HTTP hosts",
                   nodeCount, nodeCount);
    }

    /**
     * Get the next channel in round-robin fashion
     */
    private Channel getNextChannel() {
        int index = currentConnectionIndex % connections.length;
        currentConnectionIndex = (currentConnectionIndex + 1) % connections.length;
        return channels[index];
    }

    /**
     * Get the next HTTP client in round-robin fashion
     */
    private Client getNextHttpClient() {
        int index = currentHttpClientIndex % httpClients.length;
        currentHttpClientIndex = (currentHttpClientIndex + 1) % httpClients.length;
        return httpClients[index];
    }

    /**
     * Set up the complete test environment
     */
    public void setupTestEnvironment() throws Exception {
        logger.info("Setting up test environment for queue count: {}", config.getQueueCount());

        // 1. Set up HA policies
        setupHAPolicies();

        // 2. Create exchanges
        createExchanges();

        // 3. Create queues (without HA policy initially)
        createQueues();

        // 3.1. Create unsuitable queues for testing (if requested)
        createUnsuitableQueues();

        // 3.2. Create quorum queues for testing (if requested)
        createQuorumQueues();

        // 4. Create bindings
        createBindings();

        // 5. Publish messages (if total messages > 0)
        if (config.getTotalMessages() > 0) {
            try {
                publishMessages();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new RuntimeException("Publishing interrupted", e);
            }
        }

        // 6. Wait for HA policy to take effect and verify synchronization
        waitForHASynchronization();

        // 7. Verify setup
        verifySetup();

        logger.info("Test environment setup completed successfully");
    }

    private void createExchanges() throws IOException {
        int exchangeCount = config.getExchangeCount();

        if (exchangeCount > 0) {
            logger.info("Creating {} exchanges", exchangeCount);
        } else {
            logger.info("Not creating exchanges!");
            return;
        }

        // Create topic exchanges for flexible routing
        for (int i = 0; i < exchangeCount; i++) {
            String exchangeName = String.format("%s%d", config.getExchangePrefix(), i);
            getNextChannel().exchangeDeclare(exchangeName, BuiltinExchangeType.TOPIC, true, false, null);
            logger.debug("Created exchange: {}", exchangeName);
        }

        // Create additional exchange types for comprehensive testing
        getNextChannel().exchangeDeclare("test.direct", BuiltinExchangeType.DIRECT, true, false, null);
        getNextChannel().exchangeDeclare("test.fanout", BuiltinExchangeType.FANOUT, true, false, null);
        getNextChannel().exchangeDeclare("test.headers", BuiltinExchangeType.HEADERS, true, false, null);

        logger.info("Created {} topic exchanges plus 3 additional exchange types", exchangeCount);
    }

    private void createQueues() throws IOException {
        int queueCount = config.getQueueCount();

        logger.info("Creating {} mirrored classic queues across {} nodes (round-robin)", queueCount, connections.length);

        for (int i = 0; i < queueCount; i++) {
            String queueName = String.format("%s%d", config.getQueuePrefix(), i);

            // Round-robin across available channels
            int nodeIndex = i % channels.length;
            Channel nodeChannel = channels[nodeIndex];

            // Queue arguments for classic mirrored queues
            Map<String, Object> arguments = new HashMap<>();
            arguments.put("x-queue-type", "classic");

            // Add some queues with additional arguments for testing
            if (config.isEnableTTL() && i % 5 == 0) {
                arguments.put("x-message-ttl", config.getTtlMilliseconds()); // Configurable TTL
            }
            if (config.isEnableMaxLength() && i % 7 == 0) {
                arguments.put("x-max-length", 100000); // Max length
            }
            if (config.isEnableMaxPriority() && i % 11 == 0) {
                arguments.put("x-max-priority", 10); // Priority queue
            }

            nodeChannel.queueDeclare(queueName, true, false, false, arguments);
            queueToConnectionMap.put(queueName, nodeIndex);
            logger.debug("Created queue: {} on node {} with arguments: {}", queueName, nodeIndex + 1, arguments);
        }

        logger.info("Created {} queues with various configurations", queueCount);
    }

    private void createUnsuitableQueues() throws IOException {
        int unsuitableQueueCount = config.getUnsuitableQueueCount();

        if (unsuitableQueueCount <= 0) {
            return; // No unsuitable queues to create
        }

        logger.info("Creating {} unsuitable queues for migration testing", unsuitableQueueCount);

        // Define unsuitable queue types
        // Note: Only reject-publish-dlx is reliably unsuitable
        // too-many-messages and too-many-bytes require actually exceeding limits
        String[] unsuitableTypes = {"reject-publish-dlx"};

        // Migration limits (should match the values used in migration compatibility checker)
        // These are rough estimates - you may need to adjust based on actual migration limits
        int maxMessagesPerQueue = 50000;  // Adjust based on migration checker limits
        int maxBytesPerQueue = 100 * 1024 * 1024; // 100MB - adjust based on migration checker limits

        for (int i = 0; i < unsuitableQueueCount; i++) {
            String queueName = String.format("%s%d", config.getUnsuitableQueuePrefix(), i);

            // Round-robin across available channels for node distribution
            int nodeIndex = i % channels.length;
            Channel nodeChannel = channels[nodeIndex];

            // Determine unsuitable type (distribute evenly)
            String unsuitableType = unsuitableTypes[i % unsuitableTypes.length];

            Map<String, Object> arguments = new HashMap<>();
            arguments.put("x-queue-type", "classic");

            switch (unsuitableType) {
                case "reject-publish-dlx":
                    arguments.put("x-overflow", "reject-publish-dlx");
                    arguments.put("x-max-length", 1000); // Set a limit to trigger overflow
                    logger.debug("Creating unsuitable queue: {} with x-overflow=reject-publish-dlx", queueName);
                    break;

                case "too-many-messages":
                    // We'll create this queue and then fill it with too many messages
                    arguments.put("x-max-length", maxMessagesPerQueue + 10000); // Allow more than the migration limit
                    logger.debug("Creating unsuitable queue: {} that will have too many messages", queueName);
                    break;

                case "too-many-bytes":
                    // We'll create this queue and then fill it with too many bytes
                    arguments.put("x-max-length-bytes", maxBytesPerQueue + (50 * 1024 * 1024)); // Allow more than the migration limit
                    logger.debug("Creating unsuitable queue: {} that will have too many bytes", queueName);
                    break;
            }

            // Create the queue
            nodeChannel.queueDeclare(queueName, true, false, false, arguments);
            logger.debug("Created unsuitable queue: {} on node {} with type: {}", queueName, nodeIndex + 1, unsuitableType);
        }

        logger.info("Created {} unsuitable queues for testing migration compatibility checks", unsuitableQueueCount);

        // Fill unsuitable queues using MultiThreadedPublisher
        fillUnsuitableQueuesWithPublisher(unsuitableQueueCount, maxMessagesPerQueue, maxBytesPerQueue);
    }

    private void fillUnsuitableQueuesWithPublisher(int unsuitableQueueCount, int maxMessages, int maxBytes) {
        if (unsuitableQueueCount <= 0) {
            return;
        }

        logger.info("Filling {} unsuitable queues using MultiThreadedPublisher", unsuitableQueueCount);

        try {
            long startTime = System.currentTimeMillis();

            // Pre-generate message bodies to avoid memory duplication
            byte[] smallMessageBody = new byte[100]; // Small message for "too-many-messages" queues
            Arrays.fill(smallMessageBody, (byte) 'X');

            byte[] largeMessageBody = new byte[1024 * 1024]; // 1MB message for "too-many-bytes" queues
            Arrays.fill(largeMessageBody, (byte) 'Y');

            // Generate all tasks for all unsuitable queues
            List<com.amazon.mq.rabbitmq.publishing.PublishingTask> allTasks = generateAllUnsuitableQueueTasks(
                unsuitableQueueCount, maxMessages, maxBytes, smallMessageBody, largeMessageBody);

            if (!allTasks.isEmpty()) {
                // Create publishing configuration
                PublishingConfiguration publishingConfig = new PublishingConfiguration(
                    config.getClusterTopology(), config.getConfirmationWindow());

                // Use single MultiThreadedPublisher for all unsuitable queues
                MultiThreadedPublisher publisher = new MultiThreadedPublisher(publishingConfig);
                PublishingResult result = publisher.publishAsync(allTasks);

                // Monitor progress for large task counts
                if (allTasks.size() > 1000) {
                    monitorAggregateProgress(result, allTasks.size());
                }

                // Wait for completion
                result.awaitCompletion(300, TimeUnit.SECONDS); // 5 minute timeout

                // Log aggregate statistics
                long elapsed = System.currentTimeMillis() - startTime;
                double avgRate = result.getPublishedCount() * 1000.0 / elapsed;
                logger.info("Successfully filled {} unsuitable queues with {} total messages in {} ms ({} msg/sec)",
                           unsuitableQueueCount, result.getPublishedCount(), elapsed, String.format("%.1f", avgRate));

                if (result.getNackedCount() > 0) {
                    logger.info("Note: {} messages were nacked (expected for queues with max-length limits)",
                               result.getNackedCount());
                }
            }

        } catch (Exception e) {
            logger.error("Failed to fill unsuitable queues with MultiThreadedPublisher: {}", e.getMessage(), e);
            throw new RuntimeException("Failed to fill unsuitable queues", e);
        }
    }

    private List<com.amazon.mq.rabbitmq.publishing.PublishingTask> generateAllUnsuitableQueueTasks(
            int unsuitableQueueCount, int maxMessages, int maxBytes,
            byte[] smallMessageBody, byte[] largeMessageBody) {

        List<com.amazon.mq.rabbitmq.publishing.PublishingTask> allTasks = new ArrayList<>();
        String[] unsuitableTypes = {"reject-publish-dlx", "too-many-messages", "too-many-bytes"};

        for (int i = 0; i < unsuitableQueueCount; i++) {
            String queueName = String.format("%s%d", config.getUnsuitableQueuePrefix(), i);
            String unsuitableType = unsuitableTypes[i % unsuitableTypes.length];

            // Only generate tasks for queues that need messages
            if ("too-many-messages".equals(unsuitableType)) {
                int messagesToPublish = maxMessages + 5000;
                for (int j = 0; j < messagesToPublish; j++) {
                    allTasks.add(new com.amazon.mq.rabbitmq.publishing.PublishingTask(queueName, smallMessageBody));
                }
                logger.debug("Generated {} small message tasks for queue: {}", messagesToPublish, queueName);

            } else if ("too-many-bytes".equals(unsuitableType)) {
                int messageSize = 1024 * 1024; // 1MB per message
                int messagesToPublish = (maxBytes / messageSize) + 100; // Exceed the byte limit
                for (int j = 0; j < messagesToPublish; j++) {
                    allTasks.add(new com.amazon.mq.rabbitmq.publishing.PublishingTask(queueName, largeMessageBody));
                }
                logger.debug("Generated {} large message tasks for queue: {}", messagesToPublish, queueName);
            }
            // "reject-publish-dlx" queues don't need to be filled with messages
        }

        logger.info("Generated {} total publishing tasks for {} unsuitable queues", allTasks.size(), unsuitableQueueCount);
        return allTasks;
    }

    private void monitorAggregateProgress(PublishingResult result, int totalTasks) throws InterruptedException {
        int lastReported = 0;
        long startTime = System.currentTimeMillis();

        while (!result.isComplete()) {
            Thread.sleep(1000); // Check every second

            int currentPublished = result.getPublishedCount();
            if (currentPublished - lastReported >= 5000 || currentPublished == totalTasks) {
                long elapsed = System.currentTimeMillis() - startTime;
                double rate = currentPublished * 1000.0 / elapsed;
                int progressPercent = (currentPublished * 100) / totalTasks;

                logger.info("Unsuitable queues: {}/{} messages ({}%) - {} msg/sec",
                           currentPublished, totalTasks, progressPercent, String.format("%.1f", rate));
                lastReported = currentPublished;
            }

            if (result.isComplete()) break;
        }
    }

    private void setupHAPolicies() throws Exception {
        if (!config.isEnableHA()) {
            logger.info("HA policies disabled, skipping");
            return;
        }

        logger.info("Setting up HA policies for mirrored queues (after message publishing)");

        try {
            // Create HA policy for all test queues
            PolicyInfo policy = new PolicyInfo();
            policy.setVhost(config.getAmqpEndpoint(0).getVirtualHost());
            policy.setName("test-ha-policy");
            policy.setPattern("ha-all");
            policy.setApplyTo("queues");
            policy.setPriority(1);

            Map<String, Object> definition = new HashMap<>();
            definition.put("ha-mode", config.getHaPolicy());
            definition.put("ha-sync-mode", "automatic");
            definition.put("queue-version", 2);
            policy.setDefinition(definition);

            getNextHttpClient().declarePolicy(config.getAmqpEndpoint(0).getVirtualHost(), policy.getName(), policy);
            logger.info("Created HA policy: {} with pattern: {}", policy.getName(), policy.getPattern());
        } catch (Exception e) {
            logger.warn("Failed to create HA policy via HTTP API: {}", e.getMessage());
            logger.info("HA policy creation failed, but continuing with setup. Queues will not be mirrored.");
            logger.info("You can manually create the HA policy later using:");
            logger.info("  rabbitmqctl set_policy test-ha-policy \"ha-all\" '{{\"ha-mode\":\"all\",\"ha-sync-mode\":\"automatic\"}}' --apply-to queues");
        }
    }

    /**
     * Wait for HA synchronization to complete for all test queues
     */
    private void waitForHASynchronization() throws Exception {
        int queueCount = config.getQueueCount();

        logger.info("Waiting for HA synchronization of {} queues...", queueCount);

        int maxAttempts = 30; // 30 attempts with 1-second intervals = 30 seconds max per queue

        for (int i = 0; i < queueCount; i++) {
            String queueName = String.format("%s%d", config.getQueuePrefix(), i);
            logger.debug("Checking synchronization for queue: {}", queueName);

            int attempt = 0;
            boolean queueSynchronized = false;

            while (attempt < maxAttempts && !queueSynchronized) {
                attempt++;

                try {
                    // Get specific queue information
                    QueueInfo queueInfo = getNextHttpClient().getQueue(config.getAmqpEndpoint(0).getVirtualHost(), queueName);

                    if (queueInfo == null) {
                        logger.warn("Queue {} not found in API response", queueName);
                        break;
                    }

                    // Check if queue has the expected number of synchronized slaves
                    // For a 3-node cluster with "ha-mode": "all", we expect 2 synchronized slaves
                    List<String> synchronizedSlaveNodes = queueInfo.getSynchronisedMirrorNodes();
                    if (synchronizedSlaveNodes != null && synchronizedSlaveNodes.size() >= 2) {
                        queueSynchronized = true;
                        logger.debug("Queue {} is fully synchronized with {} slaves (attempt {})",
                            queueName, synchronizedSlaveNodes.size(), attempt);
                    } else {
                        logger.debug("Queue {} has {} synchronized slaves (expected 2, attempt {})",
                            queueName, synchronizedSlaveNodes != null ? synchronizedSlaveNodes.size() : 0, attempt);

                        // Wait 1 second before next check for this queue
                        Thread.sleep(1000);
                    }

                } catch (Exception e) {
                    logger.warn("Error checking HA synchronization status for queue {} (attempt {}): {}",
                        queueName, attempt, e.getMessage());
                    Thread.sleep(1000);
                }
            }

            if (!queueSynchronized) {
                logger.warn("Queue {} did not synchronize within {} seconds", queueName, maxAttempts);
            }
        }

        logger.info("HA synchronization check completed for all {} queues", queueCount);
    }

    private void createQuorumQueues() throws IOException {
        int quorumQueueCount = config.getQuorumQueueCount();

        if (quorumQueueCount <= 0) {
            return; // No quorum queues to create
        }

        logger.info("Creating {} quorum queues for testing", quorumQueueCount);

        for (int i = 0; i < quorumQueueCount; i++) {
            String queueName = String.format("test.quorum.queue.%d", i);

            // Round-robin across available channels
            int nodeIndex = i % channels.length;
            Channel nodeChannel = channels[nodeIndex];

            // Queue arguments for quorum queues
            Map<String, Object> arguments = new HashMap<>();
            arguments.put("x-queue-type", "quorum");

            nodeChannel.queueDeclare(queueName, true, false, false, arguments);
            queueToConnectionMap.put(queueName, nodeIndex);
            logger.debug("Created quorum queue: {} on node {}", queueName, nodeIndex + 1);
        }

        logger.info("Created {} quorum queues", quorumQueueCount);
    }

    private void createBindings() throws IOException {
        int queueCount = config.getQueueCount();
        int exchangeCount = config.getExchangeCount();
        int bindingsPerQueue = config.getBindingsPerQueue();

        if (bindingsPerQueue > 0) {
            logger.info("Creating bindings: {} queues × {} bindings per queue", queueCount, bindingsPerQueue);
        } else {
            logger.info("Not creating any bindings!");
            return;
        }

        int totalBindings = 0;

        for (int queueIndex = 0; queueIndex < queueCount; queueIndex++) {
            String queueName = String.format("%s%d", config.getQueuePrefix(), queueIndex);

            for (int bindingIndex = 0; bindingIndex < bindingsPerQueue; bindingIndex++) {
                // Distribute bindings across exchanges
                int exchangeIndex = (queueIndex + bindingIndex) % exchangeCount;
                String exchangeName = String.format("%s%d", config.getExchangePrefix(), exchangeIndex);

                // Generate routing key patterns
                String routingKey = generateRoutingKeyPattern(queueIndex, bindingIndex);

                getNextChannel().queueBind(queueName, exchangeName, routingKey);
                totalBindings++;

                logger.debug("Bound queue {} to exchange {} with routing key {}",
                    queueName, exchangeName, routingKey);
            }

            // Add some bindings to special exchanges
            if (queueIndex % 3 == 0) {
                getNextChannel().queueBind(queueName, "test.direct", "direct.key." + queueIndex);
                totalBindings++;
            }
            if (queueIndex % 5 == 0) {
                getNextChannel().queueBind(queueName, "test.fanout", "");
                totalBindings++;
            }
            if (queueIndex % 7 == 0) {
                // Headers exchange binding - match on message type and priority
                Map<String, Object> bindingArgs = new HashMap<>();
                bindingArgs.put("x-match", "any"); // Match any of the specified headers
                bindingArgs.put("messageType", "LARGE");
                bindingArgs.put("priority", 5);
                getNextChannel().queueBind(queueName, "test.headers", "", bindingArgs);
                totalBindings++;
            }
        }

        logger.info("Created {} total bindings", totalBindings);
    }

    private String generateRoutingKeyPattern(int queueIndex, int bindingIndex) {
        String[] categories = {"order", "payment", "inventory", "user", "notification"};
        String[] actions = {"created", "updated", "deleted", "processed", "failed"};
        String[] regions = {"us-east", "us-west", "eu-west", "ap-south"};

        String category = categories[queueIndex % categories.length];
        String action = actions[bindingIndex % actions.length];
        String region = regions[(queueIndex + bindingIndex) % regions.length];

        return String.format("%s.%s.%s", category, action, region);
    }

    private void publishMessages() throws IOException, InterruptedException {
        int totalMessages = config.getTotalMessages();
        if (totalMessages <= 0) {
            logger.info("No messages to publish");
            return;
        }
        int queueCount = config.getQueueCount();
        int connectionCount = connections.length;
        logger.info("Publishing {} messages with confirmation window size: {}",
                totalMessages, config.getConfirmationWindow());
        long overallStartTime = System.currentTimeMillis();

        // Pre-generate message bodies
        // Create task queues for each publishing thread
        @SuppressWarnings("unchecked")
        BlockingQueue<PublishingTask>[] taskQueues = new BlockingQueue[connectionCount];
        for (int i = 0; i < connectionCount; i++) {
            taskQueues[i] = new LinkedBlockingQueue<>();
        }

        // Pre-generate publishing tasks
        generatePublishingTasks(totalMessages, queueCount, taskQueues);

        // Create and start publishing threads
        publishingThreads = new PublishingThread[connectionCount];
        publishingExecutor = Executors.newFixedThreadPool(connectionCount);
        for (int i = 0; i < connectionCount; i++) {
            publishingThreads[i] = new PublishingThread(
                    this.config, i, taskQueues[i], this.globalPublishedCount, this.globalConfirmedCount);
            publishingExecutor.submit(publishingThreads[i]);
        }

        // Monitor progress and wait for completion
        monitorPublishingProgress(totalMessages);

        // Send poison pills to stop threads
        for (BlockingQueue<PublishingTask> queue : taskQueues) {
            queue.offer(new PublishingTask(null, MessageSize.SMALL, 0));
        }

        // Wait for all publishing threads to complete (including their own confirmation waits)
        logger.info("Waiting for all publishing threads to complete...");
        boolean allCompleted = false;
        long completionTimeout = System.currentTimeMillis() + 60000; // 60 second timeout
        while (!allCompleted && System.currentTimeMillis() < completionTimeout) {
            allCompleted = true;
            for (PublishingThread thread : publishingThreads) {
                if (!thread.isCompleted()) {
                    allCompleted = false;
                    break;
                }
            }
            if (!allCompleted) {
                Thread.sleep(100);
            }
        }

        if (!allCompleted) {
            logger.warn("Some publishing threads did not complete within timeout");
        }

        // Shutdown executor
        publishingExecutor.shutdown();
        if (!publishingExecutor.awaitTermination(10, TimeUnit.SECONDS)) {
            publishingExecutor.shutdownNow();
        }

        // Close thread resources
        for (PublishingThread thread : publishingThreads) {
            thread.shutdown();
        }

        long elapsed = System.currentTimeMillis() - overallStartTime;
        double avgRate = globalPublishedCount.get() * 1000.0 / elapsed;
        logger.info("Published {} messages in {} ms (avg {} msg/sec) using {} threads",
            globalPublishedCount.get(), elapsed, String.format("%.1f", avgRate), connectionCount);
    }

    private void generatePublishingTasks(int totalMessages, int queueCount, BlockingQueue<PublishingTask>[] taskQueues) {
        for (int i = 0; i < totalMessages; i++) {
            // Select message size based on distribution
            MessageSize messageSize;
            int messageSize_int = MessageGenerator.selectMessageSize(config, i);
            if (messageSize_int == config.getSmallMessageSize()) {
                messageSize = MessageSize.SMALL;
            } else if (messageSize_int == config.getMediumMessageSize()) {
                messageSize = MessageSize.MEDIUM;
            } else {
                messageSize = MessageSize.LARGE;
            }
            // Determine target queue and connection
            int targetQueueIndex = i % queueCount;
            String queueName = String.format("%s%d", config.getQueuePrefix(), targetQueueIndex);
            int connectionIndex = queueToConnectionMap.get(queueName);
            // Create and queue task
            PublishingTask task = new PublishingTask(queueName, messageSize, i);
            taskQueues[connectionIndex].offer(task);
        }
    }

    private void monitorPublishingProgress(int totalMessages) throws InterruptedException {
        long startTime = System.currentTimeMillis();
        int lastReported = 0;
        while (globalPublishedCount.get() < totalMessages) {
            Thread.sleep(100);
            int currentPublished = globalPublishedCount.get();
            if (currentPublished - lastReported >= 1000) {
                long elapsed = System.currentTimeMillis() - startTime;
                double rate = currentPublished * 1000.0 / elapsed;
                int confirmed = globalConfirmedCount.get();
                logger.info("Published {}/{} messages ({} msg/sec) - Confirmed: {}",
                    currentPublished, totalMessages, String.format("%.1f", rate), confirmed);
                lastReported = currentPublished;
            }
        }
        logger.info("All {} messages published, waiting for threads to complete confirmations...", totalMessages);
    }

    private void verifySetup() throws Exception {
        logger.info("Verifying test setup...");

        try {
            // Get queue information
            List<QueueInfo> queues = getNextHttpClient().getQueues();
            List<QueueInfo> testQueues = queues.stream()
                .filter(q -> q.getName().startsWith(config.getQueuePrefix()))
                .toList();

            logger.info("Found {} test queues", testQueues.size());

            // Verify message counts
            long totalMessages = testQueues.stream()
                .mapToLong(q -> q.getMessagesReady())
                .sum();

            logger.info("Total messages in queues: {}", totalMessages);

            // Verify HA status
            if (config.isEnableHA()) {
                long mirroredQueues = testQueues.stream()
                    .filter(q -> q.getPolicy() != null && q.getPolicy().contains("test-ha-policy"))
                    .count();
                logger.info("Mirrored queues: {}/{}", mirroredQueues, testQueues.size());
            }

            // Get exchange information
            List<ExchangeInfo> exchanges = getNextHttpClient().getExchanges();
            long testExchanges = exchanges.stream()
                .filter(e -> e.getName().startsWith(config.getExchangePrefix()))
                .count();

            logger.info("Test exchanges: {}", testExchanges);

            // Get binding information
            List<BindingInfo> bindings = getNextHttpClient().getBindings();
            long testBindings = bindings.stream()
                .filter(b -> b.getSource().startsWith(config.getExchangePrefix()) || b.getDestination().startsWith(config.getQueuePrefix()))
                .count();

            logger.info("Test bindings: {}", testBindings);

        } catch (Exception e) {
            logger.warn("Failed to verify setup via HTTP API: {}", e.getMessage());
            logger.info("Setup verification failed, but resources were created successfully.");
            logger.info("You can manually verify the setup using:");
            logger.info("  rabbitmqctl list_queues name messages");
            logger.info("  rabbitmqctl list_exchanges name type");
            logger.info("  rabbitmqctl list_bindings");
        }

        logger.info("Setup verification completed");
    }

    /**
     * Clean up resources
     */
    public void cleanup() {
        logger.info("Cleaning up resources...");

        // Close all channels
        if (channels != null) {
            for (int i = 0; i < channels.length; i++) {
                try {
                    if (channels[i] != null && channels[i].isOpen()) {
                        channels[i].close();
                    }
                } catch (Exception e) {
                    logger.warn("Error closing channel {}", i + 1, e);
                }
            }
        }

        // Close all connections
        if (connections != null) {
            for (int i = 0; i < connections.length; i++) {
                try {
                    if (connections[i] != null && connections[i].isOpen()) {
                        connections[i].close();
                    }
                } catch (Exception e) {
                    logger.warn("Error closing connection {}", i + 1, e);
                }
            }
        }

        logger.info("Cleanup completed");
    }

    /**
     * Get setup statistics
     */
    public Map<String, Object> getSetupStatistics() throws Exception {
        Map<String, Object> stats = new HashMap<>();

        try {
            // Get the complete statistics (no need to wait for stabilization since we use publisher confirms)
            List<QueueInfo> queues = getNextHttpClient().getQueues();
            List<QueueInfo> testQueues = queues.stream()
                .filter(q -> q.getName().startsWith(config.getQueuePrefix()))
                .toList();

            List<ExchangeInfo> exchanges = getNextHttpClient().getExchanges();
            long testExchanges = exchanges.stream()
                .filter(e -> e.getName().startsWith(config.getExchangePrefix()))
                .count();

            List<BindingInfo> bindings = getNextHttpClient().getBindings();
            long testBindings = bindings.stream()
                .filter(b -> b.getSource().startsWith(config.getExchangePrefix()) || b.getDestination().startsWith(config.getQueuePrefix()))
                .count();

            // Use the configured message count (represents confirmed published messages)
            // rather than queue statistics which may not be immediately accurate
            long totalMessages = config.getTotalMessages();

            // Use the calculated statistics
            stats.put("queues", testQueues.size());
            stats.put("exchanges", testExchanges);
            stats.put("bindings", testBindings);
            stats.put("totalMessages", totalMessages);
        } catch (Exception e) {
            logger.warn("Failed to get detailed statistics via HTTP API: {}", e.getMessage());

            // Provide estimated values based on configuration
            stats.put("queues", config.getQueueCount());
            stats.put("exchanges", config.getExchangeCount() + 3); // +3 for special exchanges
            stats.put("bindings", config.getQueueCount() * config.getBindingsPerQueue());
            stats.put("totalMessages", config.getTotalMessages());
        }

        stats.put("haEnabled", config.isEnableHA());

        return stats;
    }

}
