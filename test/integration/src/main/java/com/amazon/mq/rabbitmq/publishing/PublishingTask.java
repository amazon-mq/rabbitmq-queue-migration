package com.amazon.mq.rabbitmq.publishing;

/**
 * Represents a single message publishing task.
 * Contains the target queue name and message body to be published.
 */
public class PublishingTask {
    private final String queueName;
    private final byte[] messageBody;

    public PublishingTask(String queueName, byte[] messageBody) {
        this.queueName = queueName;
        this.messageBody = messageBody;
    }

    public String getQueueName() {
        return queueName;
    }

    public byte[] getMessageBody() {
        return messageBody;
    }

    @Override
    public String toString() {
        return String.format("PublishingTask{queueName='%s', messageSize=%d}",
            queueName, messageBody != null ? messageBody.length : 0);
    }
}
