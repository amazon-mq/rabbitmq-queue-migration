# TODO

## QueueMigrationClient refactoring

`MigrationInfo` and `MigrationDetailResponse` have duplicate fields and status methods. Consolidate into a single class or use composition.

## InterruptionTest message count validation

Message count validation is currently disabled due to pre-migration counts showing 0 instead of expected values. The issue appears to be a timing problem where counts are collected before messages are fully published by the setup code. Need to investigate:

1. Whether setup publishes messages asynchronously
2. If there's a synchronization issue between queue creation and message publishing
3. Whether a delay or explicit wait is needed after setup before collecting counts

The validation should verify that completed queues retain their message counts after migration to quorum type.
