package com.amazon.mq.rabbitmq.migration;

public class PublishingTask {
  final String queueName;
  final MessageSize messageSize;
  final int messageNumber;

  public PublishingTask(String queueName, MessageSize messageSize, int messageNumber) {
    this.queueName = queueName;
    this.messageSize = messageSize;
    this.messageNumber = messageNumber;
  }
}
