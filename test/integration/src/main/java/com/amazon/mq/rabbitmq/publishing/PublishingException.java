package com.amazon.mq.rabbitmq.publishing;

/** Base exception for publishing infrastructure failures. */
public class PublishingException extends Exception {
  public PublishingException(String message) {
    super(message);
  }

  public PublishingException(String message, Throwable cause) {
    super(message, cause);
  }

  /** Exception thrown when connection to RabbitMQ fails. */
  public static class ConnectionFailedException extends PublishingException {
    public ConnectionFailedException(String message, Throwable cause) {
      super(message, cause);
    }
  }

  /** Exception thrown when a target queue is not found. */
  public static class QueueNotFoundException extends PublishingException {
    private final String queueName;

    public QueueNotFoundException(String queueName) {
      super("Queue not found: " + queueName);
      this.queueName = queueName;
    }

    public String getQueueName() {
      return queueName;
    }
  }

  /** Exception thrown when publisher confirmations timeout. */
  public static class ConfirmationTimeoutException extends PublishingException {
    private final int pendingConfirmations;

    public ConfirmationTimeoutException(int pendingConfirmations) {
      super(
          "Publisher confirmation timeout with " + pendingConfirmations + " pending confirmations");
      this.pendingConfirmations = pendingConfirmations;
    }

    public int getPendingConfirmations() {
      return pendingConfirmations;
    }
  }

  /** Exception thrown when queue leader discovery fails. */
  public static class LeaderDiscoveryException extends PublishingException {
    public LeaderDiscoveryException(String message, Throwable cause) {
      super(message, cause);
    }
  }
}
