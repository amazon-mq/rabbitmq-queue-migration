package com.amazon.mq.rabbitmq.migration;

import java.util.Arrays;

/**
 * Main entry point for RabbitMQ Migration Test Setup.
 * Handles mode detection and delegates to appropriate classes.
 */
public class Main {

    public static void main(String[] args) {
        if (args.length > 0 && args[0].equals("end-to-end")) {
            String[] testArgs = Arrays.copyOfRange(args, 1, args.length);
            EndToEndMigrationTest.main(testArgs);
        } else if (args.length > 0 && args[0].equals("interrupt-test")) {
            String[] testArgs = Arrays.copyOfRange(args, 1, args.length);
            InterruptionTest.main(testArgs);
        } else if (args.length > 0 && args[0].equals("skip-unsuitable-test")) {
            String[] testArgs = Arrays.copyOfRange(args, 1, args.length);
            SkipUnsuitableTest.main(testArgs);
        } else if (args.length > 0 && args[0].equals("setup-env")) {
            String[] setupArgs = Arrays.copyOfRange(args, 1, args.length);
            MigrationTestSetup.main(setupArgs);
        } else if (args.length > 0 && args[0].equals("cleanup-env")) {
            String[] cleanupArgs = Arrays.copyOfRange(args, 1, args.length);
            CleanupEnvironment.main(cleanupArgs);
        } else {
            // Default behavior - setup-env (backward compatibility)
            MigrationTestSetup.main(args);
        }
    }
}
