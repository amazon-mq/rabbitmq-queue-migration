package com.amazon.mq.rabbitmq.migration;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Base64;
import java.util.HashMap;
import java.util.Map;

/**
 * Client for RabbitMQ Queue Migration API endpoints.
 * Handles /api/queue-migration REST calls using plain Java HTTP client.
 */
public class QueueMigrationClient {

    private static final Logger logger = LoggerFactory.getLogger(QueueMigrationClient.class);

    private final String baseUrl;
    private final String authHeader;
    private final String vhost;
    private final HttpClient httpClient;
    private final ObjectMapper objectMapper;

    public QueueMigrationClient(String host, int port, String username, String password) {
        this(host, port, username, password, TestConfiguration.getDefaultVirtualHost());
    }

    public QueueMigrationClient(String host, int port, String username, String password, String vhost) {
        this.baseUrl = String.format("http://%s:%d/api", host, port);
        this.authHeader = "Basic " + Base64.getEncoder().encodeToString((username + ":" + password).getBytes());
        this.vhost = vhost;
        this.httpClient = HttpClient.newBuilder()
            .version(HttpClient.Version.HTTP_1_1)
            .connectTimeout(Duration.ofSeconds(10))
            .build();
        this.objectMapper = new ObjectMapper();

        logger.info("Queue Migration Client initialized for {}:{}", host, port);
    }

    /**
     * Start queue migration for the default virtual host
     */
    public MigrationResponse startMigration() throws IOException, InterruptedException {
        return startMigration(false, null, null);
    }

    /**
     * Start queue migration with skip unsuitable queues option
     */
    public MigrationResponse startMigration(boolean skipUnsuitableQueues) throws IOException, InterruptedException {
        return startMigration(skipUnsuitableQueues, null, null);
    }

    /**
     * Start queue migration with batch options
     */
    public MigrationResponse startMigration(Integer batchSize, String batchOrder) throws IOException, InterruptedException {
        return startMigration(false, batchSize, batchOrder);
    }

    /**
     * Start queue migration with all options
     */
    public MigrationResponse startMigration(boolean skipUnsuitableQueues, Integer batchSize, String batchOrder) throws IOException, InterruptedException {
        Map<String, Object> options = new HashMap<>();

        if (skipUnsuitableQueues) {
            options.put("skip_unsuitable_queues", true);
        }

        if (batchSize != null) {
            options.put("batch_size", batchSize);
        }

        if (batchOrder != null) {
            options.put("batch_order", batchOrder);
        }

        String requestBody = objectMapper.writeValueAsString(options);

        logger.info("Starting queue migration for vhost '{}' with options: {}", vhost, requestBody);

        String encodedVhost = URLEncoder.encode(vhost, StandardCharsets.UTF_8);
        String endpoint = baseUrl + "/queue-migration/start/" + encodedVhost;

        logger.info("Building HTTP request to: {}", endpoint);
        HttpRequest request = HttpRequest.newBuilder()
            .uri(URI.create(endpoint))
            .header("Authorization", authHeader)
            .header("Content-Type", "application/json")
            .POST(HttpRequest.BodyPublishers.ofString(requestBody))
            .timeout(Duration.ofSeconds(30))
            .build();

        logger.info("Sending HTTP POST request...");
        HttpResponse<String> response;
        try {
            response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
            logger.info("Received HTTP response: status={}", response.statusCode());
        } catch (IOException e) {
            logger.error("IOException during HTTP request: {}", e.getMessage());
            // Java HTTP client sometimes throws EOF on error responses
            // Treat as a failed request
            String msg = e.getMessage();
            if (msg != null && msg.contains("EOF")) {
                throw new IOException("Migration start failed (likely unsuitable queues or validation error)", e);
            }
            throw new IOException("Failed to send migration start request: " + msg, e);
        }

        int statusCode = response.statusCode();
        String responseBody = response.body();

        logger.info("Response body: {}", responseBody);

        if (statusCode != 200 && statusCode != 202 && statusCode != 204) {
            throw new IOException("Failed to start migration. Status: " + statusCode + ", Body: " + responseBody);
        }

        return parseResponse(responseBody);
    }

    /**
     * Interrupt an in-progress migration
     */
    public void interruptMigration(String migrationId) throws IOException, InterruptedException {
        logger.info("Interrupting migration: {}", migrationId);

        HttpRequest request = HttpRequest.newBuilder()
            .uri(URI.create(baseUrl + "/queue-migration/interrupt/" + migrationId))
            .header("Authorization", authHeader)
            .header("Content-Type", "application/json")
            .POST(HttpRequest.BodyPublishers.noBody())
            .timeout(Duration.ofSeconds(30))
            .build();

        HttpResponse<String> response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());

        if (response.statusCode() != 200 && response.statusCode() != 202 && response.statusCode() != 204) {
            throw new IOException("Failed to interrupt migration. Status: " + response.statusCode() + ", Body: " + response.body());
        }

        logger.info("Migration interrupt request completed with status: {}", response.statusCode());
    }

    /**
     * Get detailed migration status including per-queue information
     */
    public MigrationDetailResponse getMigrationDetails(String migrationId) throws IOException, InterruptedException {
        HttpRequest request = HttpRequest.newBuilder()
            .uri(URI.create(baseUrl + "/queue-migration/status/" + migrationId))
            .header("Authorization", authHeader)
            .GET()
            .timeout(Duration.ofSeconds(10))
            .build();

        HttpResponse<String> response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());

        if (response.statusCode() == 404) {
            return null;
        }

        if (response.statusCode() != 200) {
            throw new IOException("Failed to get migration details. Status: " + response.statusCode() + ", Body: " + response.body());
        }

        return parseMigrationDetails(response.body());
    }

    private MigrationDetailResponse parseMigrationDetails(String responseBody) throws IOException {
        JsonNode root = objectMapper.readTree(responseBody);
        JsonNode migration = root.get("migration");

        String status = migration.get("status").asText();
        String displayId = migration.get("display_id").asText();
        int completedQueues = migration.get("completed_queues").asInt();
        int totalQueues = migration.get("total_queues").asInt();

        java.util.List<QueueMigrationStatus> queueStatuses = new java.util.ArrayList<>();
        JsonNode queues = root.get("queues");
        if (queues != null && queues.isArray()) {
            for (JsonNode queueNode : queues) {
                String queueName = queueNode.get("resource").get("name").asText();
                String queueStatus = queueNode.get("status").asText();
                String error = null;
                JsonNode errorNode = queueNode.get("error");
                if (errorNode != null && !errorNode.isNull()) {
                    error = errorNode.asText();
                }
                queueStatuses.add(new QueueMigrationStatus(queueName, queueStatus, error));
            }
        }

        return new MigrationDetailResponse(displayId, status, completedQueues, totalQueues, queueStatuses);
    }

    /**
     * Get current migration status
     */
    public MigrationStatusResponse getMigrationStatus() throws IOException, InterruptedException {
        HttpRequest request = HttpRequest.newBuilder()
            .uri(URI.create(baseUrl + "/queue-migration/status"))
            .header("Authorization", authHeader)
            .GET()
            .timeout(Duration.ofSeconds(10))
            .build();

        HttpResponse<String> response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());

        if (response.statusCode() != 200) {
            throw new IOException("Failed to get migration status. Status: " + response.statusCode() + ", Body: " + response.body());
        }

        return parseMigrationStatus(response.body());
    }

    private MigrationResponse parseResponse(String responseBody) throws IOException {
        if (responseBody == null || responseBody.trim().isEmpty()) {
            return new MigrationResponse("started", null);
        }

        try {
            JsonNode node = objectMapper.readTree(responseBody);
            String status = node.has("status") ? node.get("status").asText() : "started";
            String migrationId = node.has("migration_id") ? node.get("migration_id").asText() : null;
            return new MigrationResponse(status, migrationId);
        } catch (Exception e) {
            logger.warn("Failed to parse migration response, using defaults: {}", e.getMessage());
            return new MigrationResponse("started", null);
        }
    }

    private MigrationStatusResponse parseMigrationStatus(String responseBody) throws IOException {
        JsonNode rootNode = objectMapper.readTree(responseBody);

        String overallStatus = rootNode.has("status") ? rootNode.get("status").asText() : "unknown";

        if (!rootNode.has("migrations") || !rootNode.get("migrations").isArray()) {
            return new MigrationStatusResponse(overallStatus, null);
        }

        JsonNode migrationsArray = rootNode.get("migrations");
        if (migrationsArray.size() == 0) {
            return new MigrationStatusResponse(overallStatus, null);
        }

        // Find the most recent migration (last in array, or by started_at timestamp)
        JsonNode latestMigration = null;
        String latestStartTime = "";

        for (JsonNode migration : migrationsArray) {
            String startedAt = migration.has("started_at") ? migration.get("started_at").asText() : "";
            if (latestMigration == null || startedAt.compareTo(latestStartTime) > 0) {
                latestMigration = migration;
                latestStartTime = startedAt;
            }
        }

        if (latestMigration == null) {
            return new MigrationStatusResponse(overallStatus, null);
        }

        MigrationInfo migrationInfo = new MigrationInfo(
            latestMigration.has("display_id") ? latestMigration.get("display_id").asText() : "unknown",
            latestMigration.has("status") ? latestMigration.get("status").asText() : "unknown",
            latestMigration.has("progress_percentage") ? latestMigration.get("progress_percentage").asInt() : 0,
            latestMigration.has("completed_queues") ? latestMigration.get("completed_queues").asInt() : 0,
            latestMigration.has("total_queues") ? latestMigration.get("total_queues").asInt() : 0,
            latestMigration.has("started_at") ? latestMigration.get("started_at").asText() : "unknown",
            latestMigration.has("completed_at") ? latestMigration.get("completed_at").asText() : null
        );

        return new MigrationStatusResponse(overallStatus, migrationInfo);
    }

    /**
     * Response from migration start request
     */
    public static class MigrationResponse {
        private final String status;
        private final String migrationId;

        public MigrationResponse(String status, String migrationId) {
            this.status = status;
            this.migrationId = migrationId;
        }

        public String getStatus() { return status; }
        public String getMigrationId() { return migrationId; }

        @Override
        public String toString() {
            return String.format("MigrationResponse{status='%s', migrationId='%s'}", status, migrationId);
        }
    }

    /**
     * Response from migration status request
     */
    public static class MigrationStatusResponse {
        private final String overallStatus;
        private final MigrationInfo migrationInfo;

        public MigrationStatusResponse(String overallStatus, MigrationInfo migrationInfo) {
            this.overallStatus = overallStatus;
            this.migrationInfo = migrationInfo;
        }

        public String getOverallStatus() { return overallStatus; }
        public MigrationInfo getMigrationInfo() { return migrationInfo; }
        public boolean hasMigration() { return migrationInfo != null; }

        @Override
        public String toString() {
            return String.format("MigrationStatusResponse{overallStatus='%s', migrationInfo=%s}",
                overallStatus, migrationInfo);
        }
    }

    /**
     * Information about a specific migration
     */
    public static class MigrationInfo {
        private final String displayId;
        private final String status;
        private final int progressPercentage;
        private final int completedQueues;
        private final int totalQueues;
        private final String startedAt;
        private final String completedAt;

        public MigrationInfo(String displayId, String status, int progressPercentage,
                           int completedQueues, int totalQueues, String startedAt, String completedAt) {
            this.displayId = displayId;
            this.status = status;
            this.progressPercentage = progressPercentage;
            this.completedQueues = completedQueues;
            this.totalQueues = totalQueues;
            this.startedAt = startedAt;
            this.completedAt = completedAt;
        }

        public String getDisplayId() { return displayId; }
        public String getStatus() { return status; }
        public int getProgressPercentage() { return progressPercentage; }
        public int getCompletedQueues() { return completedQueues; }
        public int getTotalQueues() { return totalQueues; }
        public String getStartedAt() { return startedAt; }
        public String getCompletedAt() { return completedAt; }

        public boolean isCompleted() { return "completed".equals(status); }
        public boolean isFailed() { return "failed".equals(status); }
        public boolean isInProgress() { return "in_progress".equals(status); }
        public boolean isInterrupted() { return "interrupted".equals(status); }

        @Override
        public String toString() {
            return String.format("MigrationInfo{id='%s', status='%s', progress=%d%%, queues=%d/%d, started='%s'}",
                displayId, status, progressPercentage, completedQueues, totalQueues, startedAt);
        }
    }

    /**
     * Detailed migration response with per-queue status
     */
    public static class MigrationDetailResponse {
        private final String displayId;
        private final String status;
        private final int completedQueues;
        private final int totalQueues;
        private final java.util.List<QueueMigrationStatus> queueStatuses;

        public MigrationDetailResponse(String displayId, String status, int completedQueues,
                                       int totalQueues, java.util.List<QueueMigrationStatus> queueStatuses) {
            this.displayId = displayId;
            this.status = status;
            this.completedQueues = completedQueues;
            this.totalQueues = totalQueues;
            this.queueStatuses = queueStatuses;
        }

        public String getDisplayId() { return displayId; }
        public String getStatus() { return status; }
        public int getCompletedQueues() { return completedQueues; }
        public int getTotalQueues() { return totalQueues; }
        public java.util.List<QueueMigrationStatus> getQueueStatuses() { return queueStatuses; }

        public boolean isInterrupted() { return "interrupted".equals(status); }
        public boolean isCompleted() { return "completed".equals(status); }
        public boolean isInProgress() { return "in_progress".equals(status); }
        public boolean isFailed() { return "failed".equals(status); }
    }

    /**
     * Status of a single queue in a migration
     */
    public static class QueueMigrationStatus {
        private final String queueName;
        private final String status;
        private final String reason;

        public QueueMigrationStatus(String queueName, String status, String reason) {
            this.queueName = queueName;
            this.status = status;
            this.reason = reason;
        }

        public String getQueueName() { return queueName; }
        public String getStatus() { return status; }
        public String getReason() { return reason; }

        public boolean isCompleted() { return "completed".equals(status); }
        public boolean isSkipped() { return "skipped".equals(status); }
    }
}
