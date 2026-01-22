package com.amazon.mq.rabbitmq.migration;

import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.HashMap;
import java.util.Map;

/** Utility class for generating test messages of various sizes and types. */
public class MessageGenerator {

  private static final SecureRandom RANDOM = new SecureRandom();

  // Pre-generated message templates for performance
  private static final byte[] SMALL_MESSAGE_TEMPLATE = createMessageTemplate(1024);
  private static final byte[] MEDIUM_MESSAGE_TEMPLATE = createMessageTemplate(102400);
  private static final byte[] LARGE_MESSAGE_TEMPLATE = createMessageTemplate(1048576);

  /** Generate a message payload of the specified size using pre-generated templates */
  public static byte[] generatePayload(int sizeBytes) {
    if (sizeBytes <= 0) {
      return new byte[0];
    }

    // Use pre-generated templates for common sizes
    if (sizeBytes == 1024) {
      return SMALL_MESSAGE_TEMPLATE.clone();
    } else if (sizeBytes == 102400) {
      return MEDIUM_MESSAGE_TEMPLATE.clone();
    } else if (sizeBytes == 1048576) {
      return LARGE_MESSAGE_TEMPLATE.clone();
    }

    // Fallback for custom sizes
    return createMessageTemplate(sizeBytes);
  }

  /** Create a message template of the specified size */
  private static byte[] createMessageTemplate(int sizeBytes) {
    if (sizeBytes <= 0) {
      return new byte[0];
    }

    // Create simple structured message
    String header = "{\"type\":\"test\",\"size\":" + sizeBytes + ",\"data\":\"";
    String footer = "\"}";

    byte[] headerBytes = header.getBytes(StandardCharsets.UTF_8);
    byte[] footerBytes = footer.getBytes(StandardCharsets.UTF_8);

    int dataSize = Math.max(0, sizeBytes - headerBytes.length - footerBytes.length);

    byte[] result = new byte[sizeBytes];
    System.arraycopy(headerBytes, 0, result, 0, headerBytes.length);

    // Fill data section with 'X' characters
    for (int i = headerBytes.length; i < headerBytes.length + dataSize; i++) {
      result[i] = 'X';
    }

    System.arraycopy(footerBytes, 0, result, headerBytes.length + dataSize, footerBytes.length);

    return result;
  }

  /** Generate simplified message headers */
  public static Map<String, Object> generateHeaders(int messageNumber, String messageType) {
    Map<String, Object> headers = new HashMap<>();
    headers.put("messageNumber", messageNumber);
    headers.put("messageType", messageType);
    headers.put("priority", 0); // Default priority to avoid NullPointerException
    return headers;
  }

  /** Generate simplified routing key for message distribution */
  public static String generateRoutingKey(int messageNumber, int totalQueues) {
    String[] categories = {"order", "payment", "inventory", "user", "notification"};
    String[] actions = {"created", "updated", "deleted", "processed", "failed"};
    String[] regions = {"us-east", "us-west", "eu-west", "ap-south"};

    // Simple distribution based on message number
    String category = categories[messageNumber % categories.length];
    String action = actions[(messageNumber / categories.length) % actions.length];
    String region =
        regions[(messageNumber / (categories.length * actions.length)) % regions.length];

    return String.format("%s.%s.%s", category, action, region);
  }

  /** Determine message size category based on configuration */
  public static int selectMessageSize(TestConfiguration config, int messageNumber) {
    double rand = RANDOM.nextDouble();

    if (rand < config.getSmallMessagePercent()) {
      return config.getSmallMessageSize();
    } else if (rand < config.getSmallMessagePercent() + config.getMediumMessagePercent()) {
      return config.getMediumMessageSize();
    } else {
      return config.getLargeMessageSize();
    }
  }

  public static String getMessageTypeForSize(int sizeBytes) {
    if (sizeBytes <= 2048) {
      return "SMALL";
    } else if (sizeBytes <= 204800) {
      return "MEDIUM";
    } else {
      return "LARGE";
    }
  }

  /** Create a message with simplified checksum for integrity validation */
  public static class TestMessage {
    private final byte[] payload;
    private final Map<String, Object> headers;
    private final String routingKey;
    private final long checksum;

    public TestMessage(byte[] payload, Map<String, Object> headers, String routingKey) {
      this.payload = payload;
      this.headers = headers;
      this.routingKey = routingKey;
      this.checksum = calculateChecksum(payload);
    }

    public byte[] getPayload() {
      return payload;
    }

    public Map<String, Object> getHeaders() {
      return headers;
    }

    public String getRoutingKey() {
      return routingKey;
    }

    public long getChecksum() {
      return checksum;
    }

    private long calculateChecksum(byte[] data) {
      long checksum = 0;
      for (byte b : data) {
        checksum += b & 0xFF;
      }
      return checksum;
    }

    public boolean validateChecksum() {
      return checksum == calculateChecksum(payload);
    }
  }
}
