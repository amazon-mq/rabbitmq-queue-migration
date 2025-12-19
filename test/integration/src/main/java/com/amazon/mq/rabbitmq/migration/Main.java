package com.amazon.mq.rabbitmq.migration;

import java.util.Arrays;

/**
 * Main entry point for RabbitMQ Migration Test Setup.
 * Handles mode detection and delegates to appropriate classes.
 */
public class Main {

    public static void main(String[] args) {
        if (args.length > 0 && args[0].equals("end-to-end")) {
            // Remove "end-to-end" from args and pass the rest
            String[] testArgs = Arrays.copyOfRange(args, 1, args.length);
            EndToEndMigrationTest.main(testArgs);
        } else if (args.length > 0 && args[0].equals("setup-env")) {
            // Remove "setup-env" from args and pass the rest
            String[] setupArgs = Arrays.copyOfRange(args, 1, args.length);
            MigrationTestSetup.main(setupArgs);
        } else if (args.length > 0 && args[0].equals("cleanup-env")) {
            // Remove "cleanup-env" from args and pass the rest
            String[] cleanupArgs = Arrays.copyOfRange(args, 1, args.length);
            CleanupEnvironment.main(cleanupArgs);
        } else {
            // Default behavior - setup-env (backward compatibility)
            MigrationTestSetup.main(args);
        }
    }
}
