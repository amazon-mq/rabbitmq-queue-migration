# Future Work - RabbitMQ Queue Migration Plugin

**Last Updated:** January 9, 2026
**Status:** Planning for next development session

## 1.0.0 Readiness

Tasks required before releasing version 1.0.0 of the plugin:

### Log Message Review and Cleanup

**Status:** Not Started

**Problem:**
The plugin is currently overly verbose with log messages. Many informational details are logged at INFO level that should be DEBUG, making it difficult to identify truly important events in production logs.

**Tasks:**
1. **Audit all log messages** across all modules
2. **Reclassify log levels** according to these guidelines:
   - **DEBUG**: Internal state, detailed flow, progress updates for individual queues
   - **INFO**: Major milestones only (migration started, migration completed, phase transitions, final statistics)
   - **WARNING**: Unusual but handled conditions (retries, fallbacks, non-critical issues)
   - **ERROR**: Actual problems requiring attention (validation failures, queue migration failures)
   - **CRITICAL**: Major issues requiring immediate action (cluster-wide failures, data loss risks)

3. **Review each module systematically:**
   - `rqm.erl` - Core migration engine
   - `rqm_checks.erl` - Validation checks
   - `rqm_db.erl` - Database operations
   - `rqm_snapshot.erl` - Snapshot management
   - `rqm_util.erl` - Utilities
   - `rqm_mgmt.erl` - HTTP API
   - Other supporting modules

4. **Specific areas to review:**
   - Per-queue progress messages (likely should be DEBUG)
   - Shovel creation/cleanup messages (likely should be DEBUG)
   - Database update confirmations (likely should be DEBUG)
   - Validation check details (some should be DEBUG)
   - Keep only high-level progress at INFO

**Goal:**
Production logs should show clear, actionable information without overwhelming operators with implementation details.

### Testing and Validation

**Status:** In Progress

**Tasks:**
- [ ] Test skip unsuitable queues feature in production-like environment
- [ ] Verify all queue skip reasons work correctly
- [ ] Test with various unsuitable queue scenarios
- [ ] Validate Web UI displays skipped queues correctly
- [ ] Verify compatibility API with skip mode
- [ ] Test with large queue counts (1000+ queues)
- [ ] Verify message count tolerances work correctly
- [ ] Test rollback scenarios

### Documentation Completeness

**Status:** In Progress

**Tasks:**
- [ ] Update FUTURE.md to mark completed features
- [ ] Ensure all configuration parameters are documented
- [ ] Verify all HTTP API endpoints are documented correctly
- [ ] Add troubleshooting guide for common issues
- [ ] Document skip unsuitable queues feature thoroughly
- [ ] Add examples for all API parameters

### Performance and Scalability

**Status:** Not Started

**Tasks:**
- [ ] Benchmark with 5000+ queues
- [ ] Test with various message sizes and volumes
- [ ] Verify worker pool scaling on different instance sizes
- [ ] Test memory usage patterns under load
- [ ] Validate timeout configurations for large migrations

### Error Handling and Recovery

**Status:** Needs Review

**Tasks:**
- [ ] Review all exception handlers for completeness
- [ ] Verify rollback mechanisms work correctly
- [ ] Test failure scenarios (node failures, network issues, disk full)
- [ ] Ensure all error messages are actionable
- [ ] Verify cleanup happens in all error paths

### Code Quality and Consistency

**Status:** Needs Work

**Tasks:**
- [ ] Refactor `check_queue_message_count` to return unsuitable queue list
  - Currently returns `{error, queues_too_deep}` without queue details
  - Should return list of `unsuitable_queue` records like other checks
  - Would allow proper tracking of which queues are skipped due to message count
  - Currently skip mode just bypasses the check without recording specific queues

---

## Immediate Tasks

### 1. Per-Migration Tolerance Configuration

**Feature:** Allow users to specify message count tolerances when starting a migration

**API Design:**
```bash
PUT /api/queue-migration/start
Content-Type: application/json
{
  "over_tolerance": 10.0,
  "under_tolerance": 1.0
}
```

**Implementation:**
- Accept optional `over_tolerance` and `under_tolerance` in request body
- Validate range: 0.0-100.0 for both parameters
- Store in migration record for consistent use throughout migration
- Fall back to configured defaults if not specified
- Update Web UI to provide input fields for these parameters

**Benefits:**
- Per-migration control without changing global configuration
- Useful for testing different tolerance levels
- Allows stricter verification for critical migrations
- More lenient for development/testing migrations

### 2. Limit Number of Queues to Migrate

**Feature:** Allow users to specify maximum number of queues to migrate in a single migration run

**Current Behavior:**
- Migration processes ALL eligible queues in the vhost
- `max_queues_for_migration` (500) is a validation limit, not a migration limit
- No way to do incremental migrations

**API Design:**
```bash
PUT /api/queue-migration/start
Content-Type: application/json
{
  "max_queues": 50
}
```

**Implementation:**
- Accept optional `max_queues` parameter in request body
- Validate: must be positive integer, cannot exceed `max_queues_for_migration` config
- Limit queue selection to first N eligible queues
- Store in migration record for tracking
- Update Web UI to provide input field

**Benefits:**
- Incremental migrations for large deployments
- Test migrations with small batches
- Reduce resource pressure by migrating in waves
- Easier to pause/resume migration process
- Lower risk - migrate critical queues first, others later

**Use Cases:**
- "Migrate 10 queues to test the process"
- "Migrate 100 queues per day over a week"
- "Migrate high-priority queues first"

### 3. Skip Unsuitable Queues Instead of Blocking Migration

**Status:** ✅ IMPLEMENTED (January 9, 2026)

**Feature:** Allow migrations to proceed by skipping queues that fail validation

**Implementation Complete:**
- System-level checks still block (shovel plugin, Khepri, disk space, alarms, memory, snapshots, partitions, leader balance)
- Queue-level checks identify queues to skip (unsynchronized, too many messages/bytes, incompatible arguments)
- Migration proceeds with suitable queues, skips unsuitable ones
- Skipped queues tracked with `queue_migration_status` records with `status = skipped`
- Skip reasons stored in `error` field: `unsynchronized`, `too_many_messages`, `too_many_bytes`, `too_many_queues`, `incompatible_overflow`

**API Implementation:**
```bash
PUT /api/queue-migration/start
Content-Type: application/json
{
  "skip_unsuitable_queues": true
}

GET /api/queue-migration/compatibility?skip_unsuitable_queues=true
```

**Completed Implementation:**

1. ✅ **Data Model**: Added `unsuitable_queue` record and `skipped` status type
2. ✅ **Migration Record**: Added `skip_unsuitable_queues` and `skipped_queues` fields
3. ✅ **Validation Chain**: Handlers accumulate unsuitable queues when skip mode enabled
4. ✅ **Database Operations**: `create_skipped_queue_status/3` creates skipped queue records
5. ✅ **Migration Logic**: Nodes filter out queues with existing status records
6. ✅ **HTTP APIs**: Both migration and compatibility APIs accept `skip_unsuitable_queues` parameter
7. ✅ **Status Reporting**: JSON output includes `skipped_queues` count and individual queue skip reasons
8. ✅ **Web UI**: Checkboxes in both migration and compatibility forms, skipped status display

**Testing Status:**
- Awaiting production-like testing with various unsuitable queue scenarios

**Benefits Achieved:**
- Migrate what's possible without fixing every issue first
- Incremental approach - fix problematic queues and migrate them later
- Reduces migration friction for large deployments
- Better user experience - progress instead of all-or-nothing

**Considerations:**
- Need clear reporting of which queues were skipped and why
- Users must understand skipped queues still need attention
- May need separate API to "retry skipped queues"

### 4. Investigate Message Count Discrepancies

**Issue:** Post-migration verification occasionally shows message count mismatches (e.g., 306 actual vs 300 expected).

**Observations:**
- Occurs with no active connections during migration
- Extra messages appear in destination queue
- Current workaround: Configurable tolerance (5% over, 2% under)

**Investigation needed:**
- Trace shovel message delivery to understand duplication
- Check if messages are counted during in-flight state
- Verify shovel `ack-mode: on-confirm` behavior
- Determine if this is timing, prefetch, or actual duplication

**Questions:**
- Could prefetch cause double-counting?
- Are messages acknowledged before being counted as delivered?
- Does shovel retry logic cause duplicates?

### 2. Optimize Shovel Prefetch for Different Workloads

**Current:** Default 1024, now configurable

**Testing needed:**
- Small messages (< 1KB): Test higher prefetch (2048, 4096)
- Large messages (> 100KB): Test lower prefetch (256, 512)
- Measure impact on migration speed and memory usage

### 3. Document Shovel Exception Patterns

**Observed exceptions:**
- `noproc` during shovel creation (handled with retry)
- `badmatch` during shovel cleanup (handled with case catch)

**Documentation needed:**
- Add to DEBUGGING_SESSIONS.md
- Explain when each occurs
- Document retry/handling strategies

## Testing Priorities

### 1. Large-Scale Testing

**Scenarios:**
- 5000+ queues
- Mixed message sizes (1KB to 1MB)
- High message volumes (100K+ per queue)
- Multi-region clusters

### 2. Failure Scenario Testing

**Cases:**
- Node failures during migration
- Network partitions mid-migration
- Disk space exhaustion
- Memory pressure conditions
- Concurrent migrations (should be prevented)

### 3. Performance Benchmarking

**Metrics:**
- Migration rate vs queue count
- Impact of message size on throughput
- Worker pool scaling efficiency
- Memory usage patterns

## Known Issues

### 1. Message Count Mismatches

**Status:** Mitigated with configurable tolerance

**Root cause:** Under investigation

**Workaround:** Set appropriate tolerance percentages

### 2. Shovel Supervisor Availability

**Status:** Mitigated with retry logic

**Symptom:** `noproc` errors during shovel creation

**Solution:** 10 retries with 1-second delays

### 3. Shovel Cleanup Race Condition

**Status:** Handled gracefully

**Symptom:** Badmatch in `mirrored_supervisor:child/2`

**Solution:** `case catch` in cleanup code

**Upstream:** PR submitted to RabbitMQ main branch to fix `mirrored_supervisor:child/2`

## Configuration Tuning Guide

### For Small Messages (< 1KB)

```erlang
{shovel_prefetch_count, 2048},  % Higher prefetch for throughput
{worker_pool_max, 16}            % More workers if you have cores
```

### For Large Messages (> 100KB)

```erlang
{shovel_prefetch_count, 256},              % Lower prefetch to reduce memory
{base_max_message_bytes_in_queue, 1073741824}  % 1 GiB limit
```

### For Strict Data Integrity

```erlang
{message_count_over_tolerance_percent, 0.0},   % No extra messages allowed
{message_count_under_tolerance_percent, 0.0}   % No missing messages allowed
```

### For Lenient Migration (Development)

```erlang
{message_count_over_tolerance_percent, 10.0},  % Allow 10% extra
{message_count_under_tolerance_percent, 5.0}   % Allow 5% missing
```

## Questions for Next Session

1. **Message count discrepancies** - What causes the extra messages?
2. **Shovel lifecycle** - When exactly does the badmatch race occur?
3. **Performance optimization** - Can we improve migration speed further?
4. **Rollback testing** - How to test rollback scenarios safely?

## Reference Documents

- **AGENTS.md** - Complete technical architecture and implementation details
- **DEBUGGING_SESSIONS.md** - Detailed debugging sessions and Erlang deep dives
- **HTTP_API.md** - Complete HTTP API reference
- **INTEGRATION_TESTING.md** - Integration testing guide
- **EC2_SETUP.md** - AWS EC2 and IAM configuration guide
