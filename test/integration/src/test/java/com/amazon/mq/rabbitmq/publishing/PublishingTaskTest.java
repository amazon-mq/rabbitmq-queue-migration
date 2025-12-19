package com.amazon.mq.rabbitmq.publishing;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class PublishingTaskTest {

    @Test
    void testConstructorAndGetters() {
        String queueName = "test.queue.1";
        byte[] messageBody = "test message".getBytes();

        PublishingTask task = new PublishingTask(queueName, messageBody);

        assertEquals(queueName, task.getQueueName());
        assertArrayEquals(messageBody, task.getMessageBody());
    }

    @Test
    void testToString() {
        String queueName = "test.queue.1";
        byte[] messageBody = "test message".getBytes();

        PublishingTask task = new PublishingTask(queueName, messageBody);
        String result = task.toString();

        assertTrue(result.contains(queueName));
        assertTrue(result.contains(String.valueOf(messageBody.length)));
    }

    @Test
    void testWithNullMessageBody() {
        String queueName = "test.queue.1";

        PublishingTask task = new PublishingTask(queueName, null);

        assertEquals(queueName, task.getQueueName());
        assertNull(task.getMessageBody());

        String result = task.toString();
        assertTrue(result.contains("messageSize=0"));
    }

    @Test
    void testWithEmptyMessageBody() {
        String queueName = "test.queue.1";
        byte[] emptyBody = new byte[0];

        PublishingTask task = new PublishingTask(queueName, emptyBody);

        assertEquals(queueName, task.getQueueName());
        assertArrayEquals(emptyBody, task.getMessageBody());
        assertEquals(0, task.getMessageBody().length);
    }
}
