package com.amazon.mq.rabbitmq.migration;

public class PublishingTask {
  final String queueName;
  final MessageSize messageSize;
  final int messageNumber;
  final Long expirationMs;

  public PublishingTask(String queueName, MessageSize messageSize, int messageNumber) {
    this(queueName, messageSize, messageNumber, null);
  }

  public PublishingTask(
      String queueName, MessageSize messageSize, int messageNumber, Long expirationMs) {
    this.queueName = queueName;
    this.messageSize = messageSize;
    this.messageNumber = messageNumber;
    this.expirationMs = expirationMs;
  }
}
