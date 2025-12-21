package com.amazon.mq.rabbitmq.publishing;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class PublishingExceptionTest {

    @Test
    void testBasePublishingException() {
        String message = "Test error";
        PublishingException exception = new PublishingException(message);

        assertEquals(message, exception.getMessage());
        assertNull(exception.getCause());
    }

    @Test
    void testPublishingExceptionWithCause() {
        String message = "Test error";
        RuntimeException cause = new RuntimeException("Root cause");
        PublishingException exception = new PublishingException(message, cause);

        assertEquals(message, exception.getMessage());
        assertEquals(cause, exception.getCause());
    }

    @Test
    void testConnectionFailedException() {
        String message = "Connection failed";
        RuntimeException cause = new RuntimeException("Network error");

        PublishingException.ConnectionFailedException exception =
            new PublishingException.ConnectionFailedException(message, cause);

        assertEquals(message, exception.getMessage());
        assertEquals(cause, exception.getCause());
        assertTrue(exception instanceof PublishingException);
    }

    @Test
    void testQueueNotFoundException() {
        String queueName = "test.queue.1";

        PublishingException.QueueNotFoundException exception =
            new PublishingException.QueueNotFoundException(queueName);

        assertEquals(queueName, exception.getQueueName());
        assertTrue(exception.getMessage().contains(queueName));
        assertTrue(exception instanceof PublishingException);
    }

    @Test
    void testConfirmationTimeoutException() {
        int pendingConfirmations = 42;

        PublishingException.ConfirmationTimeoutException exception =
            new PublishingException.ConfirmationTimeoutException(pendingConfirmations);

        assertEquals(pendingConfirmations, exception.getPendingConfirmations());
        assertTrue(exception.getMessage().contains(String.valueOf(pendingConfirmations)));
        assertTrue(exception instanceof PublishingException);
    }

    @Test
    void testLeaderDiscoveryException() {
        String message = "Leader discovery failed";
        RuntimeException cause = new RuntimeException("HTTP error");

        PublishingException.LeaderDiscoveryException exception =
            new PublishingException.LeaderDiscoveryException(message, cause);

        assertEquals(message, exception.getMessage());
        assertEquals(cause, exception.getCause());
        assertTrue(exception instanceof PublishingException);
    }
}
