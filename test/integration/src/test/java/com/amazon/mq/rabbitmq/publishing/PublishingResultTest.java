package com.amazon.mq.rabbitmq.publishing;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

class PublishingResultTest {

    @Test
    void testInitialState() {
        CompletableFuture<Void> future = new CompletableFuture<>();
        AtomicInteger published = new AtomicInteger(0);
        AtomicInteger confirmed = new AtomicInteger(0);
        int totalTasks = 100;

        PublishingResult result = new PublishingResult(future, published, confirmed, totalTasks);

        assertFalse(result.isComplete());
        assertEquals(0, result.getProgressPercentage());
        assertEquals(0, result.getPublishedCount());
        assertEquals(0, result.getConfirmedCount());
        assertEquals(100, result.getTotalTasks());
        assertTrue(result.getElapsedTimeMs() >= 0);
        assertEquals(0.0, result.getCurrentRate());
    }

    @Test
    void testProgressTracking() throws InterruptedException {
        CompletableFuture<Void> future = new CompletableFuture<>();
        AtomicInteger published = new AtomicInteger(0);
        AtomicInteger confirmed = new AtomicInteger(0);
        int totalTasks = 100;

        PublishingResult result = new PublishingResult(future, published, confirmed, totalTasks);

        // Simulate progress
        published.set(25);
        assertEquals(25, result.getProgressPercentage());
        assertEquals(25, result.getPublishedCount());

        published.set(50);
        confirmed.set(40);
        assertEquals(50, result.getProgressPercentage());
        assertEquals(50, result.getPublishedCount());
        assertEquals(40, result.getConfirmedCount());

        // Wait a bit to test rate calculation
        Thread.sleep(10);
        assertTrue(result.getCurrentRate() > 0);
    }

    @Test
    void testCompletion() throws Exception {
        CompletableFuture<Void> future = new CompletableFuture<>();
        AtomicInteger published = new AtomicInteger(100);
        AtomicInteger confirmed = new AtomicInteger(100);
        int totalTasks = 100;

        PublishingResult result = new PublishingResult(future, published, confirmed, totalTasks);

        assertFalse(result.isComplete());

        // Complete the future
        future.complete(null);

        assertTrue(result.isComplete());
        assertEquals(100, result.getProgressPercentage());

        // Should complete immediately
        result.awaitCompletion();
        assertTrue(result.awaitCompletion(1, TimeUnit.MILLISECONDS));
    }

    @Test
    void testCompletionWithException() {
        CompletableFuture<Void> future = new CompletableFuture<>();
        AtomicInteger published = new AtomicInteger(0);
        AtomicInteger confirmed = new AtomicInteger(0);
        int totalTasks = 100;

        PublishingResult result = new PublishingResult(future, published, confirmed, totalTasks);

        // Complete with exception
        PublishingException testException = new PublishingException("Test error");
        future.completeExceptionally(testException);

        assertTrue(result.isComplete());

        assertThrows(PublishingException.class, result::awaitCompletion);
    }

    @Test
    void testZeroTotalTasks() {
        CompletableFuture<Void> future = new CompletableFuture<>();
        AtomicInteger published = new AtomicInteger(0);
        AtomicInteger confirmed = new AtomicInteger(0);
        int totalTasks = 0;

        PublishingResult result = new PublishingResult(future, published, confirmed, totalTasks);

        assertEquals(100, result.getProgressPercentage()); // Should be 100% when no tasks
        assertEquals(0, result.getTotalTasks());
    }

    @Test
    void testTimeout() throws Exception {
        CompletableFuture<Void> future = new CompletableFuture<>();
        AtomicInteger published = new AtomicInteger(0);
        AtomicInteger confirmed = new AtomicInteger(0);
        int totalTasks = 100;

        PublishingResult result = new PublishingResult(future, published, confirmed, totalTasks);

        // Should timeout
        assertFalse(result.awaitCompletion(10, TimeUnit.MILLISECONDS));
        assertFalse(result.isComplete());
    }
}
