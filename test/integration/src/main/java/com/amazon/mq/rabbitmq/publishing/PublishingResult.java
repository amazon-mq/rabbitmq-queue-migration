package com.amazon.mq.rabbitmq.publishing;

import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Result object for asynchronous publishing operations.
 * Provides progress tracking and completion status.
 */
public class PublishingResult {
    private final CompletableFuture<Void> completionFuture;
    private final AtomicInteger publishedCount;
    private final AtomicInteger confirmedCount;
    private final AtomicInteger nackedCount;
    private final int totalTasks;
    private final long startTime;

    public PublishingResult(CompletableFuture<Void> completionFuture,
                           AtomicInteger publishedCount,
                           AtomicInteger confirmedCount,
                           AtomicInteger nackedCount,
                           int totalTasks) {
        this.completionFuture = completionFuture;
        this.publishedCount = publishedCount;
        this.confirmedCount = confirmedCount;
        this.nackedCount = nackedCount;
        this.totalTasks = totalTasks;
        this.startTime = System.currentTimeMillis();
    }

    /**
     * Check if all publishing tasks have completed.
     */
    public boolean isComplete() {
        return completionFuture.isDone();
    }

    /**
     * Get the current progress as a percentage (0-100).
     */
    public int getProgressPercentage() {
        if (totalTasks == 0) return 100;
        return (publishedCount.get() * 100) / totalTasks;
    }

    /**
     * Get the number of messages published so far.
     */
    public int getPublishedCount() {
        return publishedCount.get();
    }

    /**
     * Get the number of messages confirmed so far.
     */
    public int getConfirmedCount() {
        return confirmedCount.get();
    }

    /**
     * Get the number of messages nacked so far.
     */
    public int getNackedCount() {
        return nackedCount.get();
    }

    /**
     * Get the total number of tasks to be published.
     */
    public int getTotalTasks() {
        return totalTasks;
    }

    /**
     * Get the elapsed time since publishing started (in milliseconds).
     */
    public long getElapsedTimeMs() {
        return System.currentTimeMillis() - startTime;
    }

    /**
     * Get the current publishing rate (messages per second).
     */
    public double getCurrentRate() {
        long elapsed = getElapsedTimeMs();
        if (elapsed == 0) return 0.0;
        return publishedCount.get() * 1000.0 / elapsed;
    }

    /**
     * Wait for all publishing tasks to complete.
     *
     * @throws PublishingException if publishing fails
     * @throws InterruptedException if interrupted while waiting
     */
    public void awaitCompletion() throws PublishingException, InterruptedException {
        try {
            completionFuture.get();
        } catch (Exception e) {
            if (e.getCause() instanceof PublishingException) {
                throw (PublishingException) e.getCause();
            }
            throw new PublishingException("Publishing failed", e);
        }
    }

    /**
     * Wait for all publishing tasks to complete with a timeout.
     *
     * @param timeout the maximum time to wait
     * @param unit the time unit of the timeout argument
     * @return true if completed within timeout, false otherwise
     * @throws PublishingException if publishing fails
     * @throws InterruptedException if interrupted while waiting
     */
    public boolean awaitCompletion(long timeout, TimeUnit unit)
            throws PublishingException, InterruptedException {
        try {
            completionFuture.get(timeout, unit);
            return true;
        } catch (java.util.concurrent.TimeoutException e) {
            return false;
        } catch (Exception e) {
            if (e.getCause() instanceof PublishingException) {
                throw (PublishingException) e.getCause();
            }
            throw new PublishingException("Publishing failed", e);
        }
    }
}
