package com.amazon.mq.rabbitmq.migration;

public class MessageBodyCache {
  private final byte[] smallMessage;
  private final byte[] mediumMessage;
  private final byte[] largeMessage;

  public MessageBodyCache(TestConfiguration config) {
    // Generate one message body per size
    smallMessage = MessageGenerator.generatePayload(config.getSmallMessageSize());
    mediumMessage = MessageGenerator.generatePayload(config.getMediumMessageSize());
    largeMessage = MessageGenerator.generatePayload(config.getLargeMessageSize());
  }

  byte[] getMessageBody(MessageSize size) {
    switch (size) {
      case SMALL:
        return smallMessage;
      case MEDIUM:
        return mediumMessage;
      case LARGE:
        return largeMessage;
      default:
        throw new IllegalArgumentException("Unknown message size: " + size);
    }
  }
}
