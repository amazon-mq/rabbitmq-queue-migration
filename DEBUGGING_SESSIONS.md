# RabbitMQ Queue Migration Plugin - Debugging Sessions

This document captures debugging sessions, lessons learned, and deep technical insights discovered while developing and testing the RabbitMQ Queue Migration plugin.

## Table of Contents

- [Session 1: Concurrent Snapshot Limit Error](#session-1-concurrent-snapshot-limit-error)
- [Session 2: Worker Pool Sizing and Performance](#session-2-worker-pool-sizing-and-performance)
- [Session 3: Bad Key Errors in Validation Handlers](#session-3-bad-key-errors-in-validation-handlers)
- [Session 4: Understanding Shovel Cleanup Exceptions](#session-4-understanding-shovel-cleanup-exceptions)
- [Erlang Deep Dives](#erlang-deep-dives)

---

## Session 1: Concurrent Snapshot Limit Error

**Date:** 2026-01-06

### Problem

When two migrations were run too closely together, AWS rejected the second snapshot request with `ConcurrentSnapshotLimitExceeded`:

```
{"Response",
  [{"Errors",
    [{"Error",
      [{"Code", "ConcurrentSnapshotLimitExceeded"},
       {"Message", "Maximum allowed in-progress snapshots for a single volume exceeded."}]}]}]}
```

This caused an unhandled case clause error in `rqm_ebs:create_volume_snapshot/2` at line 82.

### Root Cause

The error occurred during the pre-migration preparation phase when creating EBS snapshots. The code didn't handle the AWS error response format for concurrent snapshot limits.

### Solution

Added a pre-migration validation check to detect in-progress snapshots before migration starts:

1. **New validation check:** `check_snapshot_not_in_progress/0` in `rqm_checks.erl`
2. **Implementation in `rqm_snapshot.erl`:** 
   - `check_no_snapshots_in_progress/0` - Entry point that checks snapshot mode
   - `check_no_snapshots_in_progress/1` - Pattern matches on `tar` (skip) or `ebs` (check)
   - `check_ebs_snapshots_in_progress/0` - Sets AWS region and queries for snapshots
   - `check_volume_snapshots_in_progress/1` - Checks if any snapshots are in "pending" state
3. **Validation chain integration:** Added between `memory_usage` and `cluster_partitions` checks

### Key Lessons

1. **Validation chain pattern:** Each check follows the pattern:
   - `pre_migration_validation({V, check_name}, VHost)` - Calls the check
   - `handle_check_*` - Handles result, either continues chain or returns error
   - Terminal check (`cluster_partitions`) either returns `ok` or starts migration

2. **Module boundaries:** All snapshot-related logic belongs in `rqm_snapshot.erl`, not `rqm_checks.erl`

3. **AWS region setup:** Must call `rabbitmq_aws_config:region()` and `rabbitmq_aws:set_region(Region)` before any AWS API calls

4. **Graceful degradation:** Validation checks should allow migration to proceed if they can't verify (e.g., tar mode, AWS not configured)

### Commits

- `dfe8d96` - Add validation check for concurrent EBS snapshots
- `05e5435` - Fix function call in snapshot validation check
- `bebb33a` - Move snapshot check to `rqm_snapshot` and fix AWS region setup

---

## Session 2: Worker Pool Sizing and Performance

**Date:** 2026-01-06

### Problem

Initial worker pool sizing formula was `min(schedulers, worker_pool_max())`, which limited parallelism on systems with few CPU cores. Testing showed migration could benefit from more workers than available cores.

### Testing Data

**Environment:** m7g.large instances (2 vCPUs), 500 queues, 100 messages per queue

| Worker Count | Formula | Duration | Result |
|--------------|---------|----------|--------|
| 1 | Configured | 29 minutes | ✅ Success |
| 2 | `min(2, 4) = 2` | 14 minutes | ✅ Success (2x speedup) |
| 4 | `min(2*2, 32) = 4` | Failed | ❌ Timeouts, network saturation, partitions |

### Root Cause Analysis

Migration is **I/O-bound**, not CPU-bound. Workers spend time waiting on:
- Database operations (Mnesia reads/writes)
- Network I/O (message transfers)
- Disk I/O (queue persistence)

However, too many workers cause:
- Network bandwidth exhaustion
- Mnesia/database contention
- Cluster instability (partitions when nodes can't keep up with heartbeats)

### Solution Evolution

**Attempt 1:** Changed formula to `min(schedulers * 2, worker_pool_max())`
- Allowed 2x workers as CPU cores
- Increased `DEFAULT_WORKER_POOL_MAX` from 8 to 32
- **Result:** 4 workers on 2 vCPU system caused cluster failures

**Final Solution:** Reverted to `min(schedulers, worker_pool_max())`
- Kept `DEFAULT_WORKER_POOL_MAX` at 32 (for larger instances)
- Worker count capped at scheduler count prevents instability

### Key Lessons

1. **Optimal worker count = scheduler count:** Performance scales linearly up to scheduler count, but beyond causes instability

2. **I/O-bound doesn't mean unlimited parallelism:** Even I/O-bound workloads have optimal concurrency limits due to shared resource contention

3. **Data-driven decisions:** Testing revealed the sweet spot was exactly at scheduler count, not above or below

4. **Default ceiling matters:** `DEFAULT_WORKER_POOL_MAX = 32` allows larger instances (16+ vCPUs) to fully utilize their cores without affecting smaller instances

### Commits

- `3ff9fd8` - Increase worker pool size limits for better migration performance (later reverted)
- `[commit]` - Revert worker pool formula to cap at scheduler count

---

## Session 3: Bad Key Errors in Validation Handlers

**Date:** 2026-01-07

### Problem

Validation handlers attempted to access `queue_count` from error Details maps, but the maps only contained `problematic_queues`:

```
exception error: bad key: queue_count
  in function  map_get/2
     called as map_get(queue_count,
                       #{problematic_queues => [...]})
```

Occurred in:
- `rqm.erl` line 167 - `handle_check_queue_suitability` for `unsuitable_queues`
- `rqm_mgmt.erl` line 163 - HTTP API error handler for `unsuitable_queues`

### Root Cause

The `check_queue_suitability/1` function was refactored to collect all issues into a single `unsuitable_queues` error with only `problematic_queues` in the Details map. The error handlers still expected the old format with `queue_count` and `max_queues` fields.

### Solution

1. **Fixed active handlers:** Changed to extract `problematic_queues` and use `length(ProblematicQueues)` instead of accessing non-existent `queue_count`

2. **Removed dead code:** Deleted `too_many_queues` error handlers that were never called:
   - `rqm.erl` lines 154-162
   - `rqm_mgmt.erl` lines 149-161
   - `rqm_checks.erl` lines 862-868 (formatter)

### Key Lessons

1. **Map access safety:** Use `maps:get(Key, Map, Default)` when key might not exist, or verify map structure matches expectations

2. **Dead code identification:** Error handlers can become unreachable after refactoring - trace through actual error returns to verify handlers are still needed

3. **Consistent error formats:** When refactoring error returns, update all handlers that consume those errors

4. **Issue types vs error types:** In this codebase:
   - **Error type:** `unsuitable_queues` (what `check_queue_suitability` returns)
   - **Issue types:** `too_many_queues`, `too_many_messages`, `too_many_bytes` (embedded in problematic_queues list)

### Commits

- `[commit]` - Fix bad key error and remove dead `too_many_queues` handlers

---

## Session 4: Understanding Shovel Cleanup Exceptions

**Date:** 2026-01-08

### Problem

During testing, shovels occasionally raised exceptions when stopping:

```
exit:{{{badmatch,[]},[{mirrored_supervisor,child,2,...}]},
      {gen_server2,call,[<0.1346.0>,{delete_child,...},infinity]}}
```

Initial assumption was that this required trapping exits and handling EXIT messages in the worker process.

### Investigation

Traced the complete call chain from worker through shovel cleanup to understand how the exception propagates.

#### Call Chain

1. Worker calls `migrate_with_messages/3` (line 827)
2. → `migrate_to_tmp_qq/2` (line 1032)
3. → `migrate/4` (line 940)
4. → `migrate_queue_messages_with_shovel/4` (line 1134)
5. → `after` block calls `cleanup_migration_shovel/2` (line 1201)
6. → `rabbit_runtime_parameters:clear(...)` (line 1449)
7. → `rabbit_shovel_parameters:notify_clear(...)`
8. → `rabbit_shovel_dyn_worker_sup_sup:stop_child(...)`
9. → `mirrored_supervisor:delete_child(...)`
10. → `gen_server2:call(mirroring(Sup), {delete_child, Id}, infinity)`
11. → `mirrored_supervisor:handle_call({delete_child, Id}, ...)`
12. → `stop(Group, Delegate, Id)`
13. → `check_stop(Group, Delegate, Id)` (line 421)
14. → `child(Delegate, Id)` (line 226)

#### The Badmatch

**File:** `deps/rabbit/src/mirrored_supervisor.erl`, line 226

```erlang
child(Sup, Id) ->
    [Pid] = [Pid || {Id1, Pid, _, _} <- ?SUPERVISOR:which_children(Sup),
                    Id1 =:= Id],
    Pid.
```

**What happens:**
- List comprehension returns `[]` when child is already removed
- Pattern match `[Pid] = []` fails
- Raises `{badmatch, []}` exception

#### Exception Propagation

The exception propagates back through the call stack until it reaches `gen_server2:call`:

**File:** `deps/rabbit_common/src/gen_server2.erl`, lines 342-347

```erlang
call(Name, Request, Timeout) ->
    case catch gen:call(Name, '$gen_call', Request, Timeout) of
        {ok,Res} ->
            Res;
        {'EXIT',Reason} ->
            exit({Reason, {?MODULE, call, [Name, Request, Timeout]}})
    end.
```

**Key mechanism:**
1. `catch gen:call(...)` converts any exception into `{'EXIT', Reason}`
2. Case statement matches `{'EXIT', Reason}` clause
3. Calls `exit({Reason, {gen_server2, call, ...}})` to re-raise with context
4. This exit exception propagates to the worker's call stack
5. Worker's `catch` clause at line 832 catches it (Class = exit)

### Solution

**No code changes needed!** The worker's existing `try...catch` block already handles this:

```erlang
try
    {ok, QuorumQ} = migrate_with_messages(...)
    PPid ! {self(), Ref, {ok, ...}}
catch
    Class:Reason:Stack ->  % Catches the exit exception
        ?LOG_ERROR("rqm: exception in ~ts: ~tp:~tp", [...]),
        PPid ! {self(), Ref, {error, ...}}
end
```

The exception is caught, logged, and the queue is marked as failed. The migration continues with remaining queues.

### Key Lessons

1. **Exit vs EXIT message:**
   - `exit(Reason)` - Raises an **exception** with class `exit`
   - `{'EXIT', Pid, Reason}` - A **message** received when trapping exits from linked processes
   - These are completely different things!

2. **gen_server:call exception handling:**
   - When server process crashes or raises exception during `handle_call`
   - `gen:call` returns (via `catch`) as `{'EXIT', Reason}`
   - `gen_server:call` re-raises as `exit({Reason, {gen_server, call, [...]}})`
   - This adds call context to help debugging

3. **The `catch` keyword:**
   - `catch Expression` converts exceptions into returnable values
   - `throw(Term)` → returns `Term` (unwrapped)
   - `error(Reason)` → returns `{'EXIT', {Reason, Stacktrace}}`
   - `exit(Reason)` → returns `{'EXIT', Reason}`
   - Allows pattern matching on exception results in case statements

4. **Synchronous calls propagate exceptions:**
   - When making synchronous `gen_server:call`, exceptions in the server propagate to the caller
   - No linking or exit trapping needed - it's just normal exception propagation through the call stack
   - The caller's `try...catch` handles these exceptions

5. **Race condition in shovel cleanup:**
   - Shovel child may terminate and be removed from supervisor between `terminate_child` and `delete_child` calls
   - This causes `child(Delegate, Id)` to return `[]` instead of `[Pid]`
   - Results in badmatch exception during cleanup
   - This is a benign race condition - the shovel is already stopped, cleanup just fails to find it

### Documentation References

**Erlang gen_server documentation:**
- File: `/home/lrbakken/development/erlang/otp/lib/stdlib/doc/src/gen_server.xml`
- Section: `call/2,3` function description
- Relevant excerpt: "This call may exit the calling process with an exit term on the form `{Reason, Location}`"
- The `_OtherTerm` case documents: "The server process exited during the call, with reason Reason. Either by returning `{stop,Reason,_}` from one of its callbacks (without replying to this call), by raising an exception, or due to getting an exit signal it did not trap."

**Erlang gen_server source:**
- File: `/home/lrbakken/development/erlang/otp/lib/stdlib/src/gen_server.erl`
- Lines 418-419: Exception conversion mechanism

**RabbitMQ gen_server2 source:**
- File: `deps/rabbit_common/src/gen_server2.erl`
- Lines 346-347: Same exception conversion (gen_server2 is a copy with RabbitMQ additions)

---

## Erlang Deep Dives

### Exception Handling with `catch`

The `catch` keyword converts exceptions into values that can be pattern matched:

```erlang
% Normal return
case catch normal_function() of
    Result -> handle_result(Result)
end

% Exception converted to {'EXIT', Reason}
case catch function_that_crashes() of
    {'EXIT', Reason} -> handle_crash(Reason);
    Result -> handle_result(Result)
end

% Throw returns unwrapped value
case catch throw(my_value) of
    my_value -> handle_throw();  % No {'EXIT', ...} wrapper
    Result -> handle_result(Result)
end
```

**Conversion rules:**
- `throw(Term)` → `Term` (unwrapped)
- `error(Reason)` → `{'EXIT', {Reason, Stacktrace}}`
- `exit(Reason)` → `{'EXIT', Reason}`

### gen_server:call Exception Propagation

When a `gen_server:call` is made and the server process crashes or raises an exception:

1. **Server side:** Exception occurs in `handle_call` or related code
2. **gen:call:** Returns via `catch` as `{'EXIT', Reason}`
3. **gen_server:call:** Pattern matches and re-raises:
   ```erlang
   case catch gen:call(...) of
       {'EXIT', Reason} ->
           exit({Reason, {gen_server, call, [ServerRef, Request, Timeout]}})
   end
   ```
4. **Caller side:** Receives exit exception with added context

**Why add context?**
The original exception might be `{badmatch, []}`, but after going through `gen_server:call`, it becomes:
```erlang
exit:{{{badmatch, []}, Stacktrace}, 
      {gen_server2, call, [Pid, {delete_child, Id}, infinity]}}
```

This tells you:
- What the original error was: `{badmatch, []}`
- Where it happened: `Stacktrace`
- What call triggered it: `gen_server2:call` with specific arguments

### Supervisor Behavior

**Standard Erlang supervisors:**
- Trap exits: `process_flag(trap_exit, true)`
- Link to children when starting them
- Receive `{'EXIT', Pid, Reason}` messages when children terminate
- Handle these in `handle_info` to restart children per strategy

**Mirrored supervisor:**
- Also traps exits (line 251 in `mirrored_supervisor.erl`)
- Coordinates supervision across cluster nodes
- Uses standard supervisor as delegate

**Important distinction:**
- Supervisor trapping exits is for **handling child termination**
- This is separate from **exceptions in supervisor's own code**
- The badmatch in `child/2` is the supervisor's own exception, not a child EXIT

### Process Linking and Exit Trapping

**Without trap_exit:**
- Linked process dies → your process dies with same reason
- Exception propagates through links

**With trap_exit:**
- Linked process dies → you receive `{'EXIT', Pid, Reason}` message
- You handle it in `receive` block
- Your process continues running

**Key point:** `trap_exit` only affects **EXIT signals from linked processes**, not exceptions in your own code. Exceptions in your own code are handled by `try...catch`, not by trapping exits.

### Why the Initial Confusion

The error message showed:
```
exit:{{{badmatch,[]},[{mirrored_supervisor,child,2,...}]},
      {gen_server2,call,[...]}}
```

The word "exit" and the structure made it seem like an EXIT message, but it's actually an **exit exception** (class: exit) that propagates through the call stack. The confusion arose from:

1. Exception class is `exit` (not `error` or `throw`)
2. The term structure resembles EXIT message format
3. The comment mentioned "shovels exit" which suggested EXIT messages

**Reality:** It's a synchronous call that raises an exit exception, caught by the worker's `try...catch` block. No EXIT messages, no need for `trap_exit` in the worker.

---

## Best Practices Learned

### 1. Validation Chain Design

**Pattern:**
```erlang
pre_migration_validation({V, check_name}, VHost) ->
    handle_check_name(V, rqm_checks:check_name(VHost), VHost).

handle_check_name(V, ok, VHost) ->
    pre_migration_validation({V, next_check}, VHost);
handle_check_name(_V, {error, Reason}, _VHost) ->
    ?LOG_ERROR("rqm: check failed: ~p", [Reason]),
    {error, Reason}.
```

**Terminal check:**
```erlang
handle_check_cluster_partitions(validation_only, {ok, _Nodes}, _VHost) ->
    ok;  % Validation mode - stop here
handle_check_cluster_partitions(migration, {ok, Nodes}, VHost) ->
    start_with_new_migration_id(Nodes, VHost, generate_migration_id());  % Start migration
```

### 2. Module Boundaries

Keep related functionality together:
- All snapshot operations in `rqm_snapshot.erl`
- All validation checks in `rqm_checks.erl` (but delegate to appropriate modules)
- All AWS EBS operations in `rqm_ebs.erl`

### 3. Error Handling Patterns

**Graceful degradation:**
```erlang
check_something() ->
    case try_operation() of
        {ok, Result} -> validate(Result);
        {error, Reason} ->
            ?LOG_DEBUG("rqm: skipping check, operation failed: ~p", [Reason]),
            ok  % Allow migration to proceed
    end.
```

**Fail fast for critical checks:**
```erlang
check_critical() ->
    case try_operation() of
        {ok, Result} -> validate(Result);
        {error, Reason} ->
            ?LOG_ERROR("rqm: critical check failed: ~p", [Reason]),
            {error, Reason}  % Block migration
    end.
```

### 4. AWS Integration

**Always set region before API calls:**
```erlang
{ok, Region} = rabbitmq_aws_config:region(),
ok = rabbitmq_aws:set_region(Region),
case rqm_ebs:instance_volumes() of
    ...
end
```

**Handle missing configuration gracefully:**
```erlang
case rabbitmq_aws_config:region() of
    {ok, Region} ->
        ok = rabbitmq_aws:set_region(Region),
        do_aws_operation();
    {error, _} ->
        ?LOG_DEBUG("rqm: AWS not configured, skipping"),
        ok
end
```

### 5. Worker Pool Sizing

**Formula:** `min(erlang:system_info(schedulers), worker_pool_max())`

**Rationale:**
- Migration scales linearly with workers up to scheduler count
- Beyond scheduler count causes resource contention and instability
- Let users configure lower if needed, but cap at scheduler count

**Configuration:**
- `DEFAULT_WORKER_POOL_MAX = 32` - High ceiling for large instances
- Actual pool size capped by scheduler count
- 2 vCPU system: max 2 workers
- 16 vCPU system: max 16 workers

---

## Testing Insights

### Performance Characteristics

**Migration rates (m7g.large, 2 vCPUs):**
- 500 queues, 100 messages each
- 1 worker: 29 minutes
- 2 workers: 14 minutes (2x speedup)
- 4 workers: Failed (network saturation, partitions)

**Optimal configuration:**
- Worker count = scheduler count
- Provides best balance of throughput and stability

### Common Issues

1. **Concurrent snapshots:** Add validation check to detect in-progress snapshots
2. **Queue size limits:** Configure `base_max_message_bytes_in_queue` for large queues
3. **Worker pool sizing:** Don't exceed scheduler count
4. **Shovel cleanup races:** Benign badmatch exceptions are caught and handled

### Configuration for Large Migrations

Example `advanced.config` for 1000 queues with larger messages:

```erlang
[
  {rabbitmq_queue_migration, [
    {snapshot_mode, ebs},
    {ebs_volume_device, "/dev/sdh"},
    {cleanup_snapshots_on_success, true},
    {worker_pool_max, 8},  % Will be capped at scheduler count
    {max_queues_for_migration, 1000},
    {base_max_message_bytes_in_queue, 268435456}  % 256 MiB
  ]}
].
```

---

## Future Considerations

### Potential Improvements

1. **Shovel cleanup robustness:** Handle the badmatch race condition more gracefully in `mirrored_supervisor:child/2`

2. **Dynamic worker scaling:** Adjust worker count based on actual resource utilization during migration

3. **Better progress estimation:** Account for message size in progress calculations, not just count

4. **Snapshot state checking:** Poll snapshot status to determine when it's safe to start new migration

### Known Limitations

1. **Shovel cleanup race:** Benign badmatch can occur when shovel terminates between `terminate_child` and `delete_child`

2. **Worker pool ceiling:** Hard-capped at scheduler count based on testing data

3. **Snapshot concurrency:** Only one snapshot per volume at a time (AWS limitation)

---

## Debugging Tips

### Tracing Exception Flow

When debugging exceptions in distributed systems:

1. **Identify the exception class:** `error`, `exit`, or `throw`
2. **Find the origin:** Look at the stacktrace to see where it was raised
3. **Trace the call chain:** Follow synchronous calls to see how it propagates
4. **Check for conversion points:** Look for `gen_server:call`, `catch`, etc. that transform exceptions
5. **Verify handlers:** Ensure `try...catch` blocks are in the right places

### Understanding Error Messages

**Exit exception format:**
```erlang
exit:{OriginalReason, {Module, Function, Args}}
```

Example:
```erlang
exit:{{{badmatch, []}, Stacktrace}, 
      {gen_server2, call, [Pid, Request, infinity]}}
```

Tells you:
- Original error: `{badmatch, []}`
- Where in original code: `Stacktrace`
- What triggered it: `gen_server2:call(Pid, Request, infinity)`

### Common Pitfalls

1. **Confusing exit exceptions with EXIT messages**
   - Exit exception: `exit(Reason)` - propagates through call stack
   - EXIT message: `{'EXIT', Pid, Reason}` - received when trapping exits

2. **Assuming I/O-bound means unlimited parallelism**
   - Shared resources (network, disk, database) have contention limits
   - Too many workers can degrade performance

3. **Not checking map keys before access**
   - Use `maps:get(Key, Map, Default)` or verify structure
   - Error formats can change during refactoring

4. **Ignoring AWS rate limits and concurrency restrictions**
   - EBS snapshots: one per volume at a time
   - Add validation checks to fail fast with clear errors

---

## Appendix: Code References

### Validation Chain Entry Point

**File:** `deps/rabbitmq_queue_migration/src/rqm.erl`

```erlang
% Line 75 - Validation only (no migration)
pre_migration_validation_only(VHost) ->
    pre_migration_validation({validation_only, shovel_plugin}, VHost).

% Line 78 - Validation + migration
pre_migration_validation(VHost) ->
    pre_migration_validation({migration, shovel_plugin}, VHost).
```

### Worker Process Structure

**File:** `deps/rabbitmq_queue_migration/src/rqm.erl`, lines 779-890

```erlang
Fun = fun() ->
    ?LOG_INFO("rqm: worker starting for ~ts", [rabbit_misc:rs(Resource)]),
    try
        {ok, QuorumQ} = migrate_with_messages(ClassicQ, Resource, Status),
        PPid ! {self(), Ref, {ok, Resource, qstr(QuorumQ)}}
    catch
        Class:Reason:Stack ->
            ?LOG_ERROR("rqm: exception in ~ts: ~tp:~tp", [...]),
            PPid ! {self(), Ref, {error, Resource, {Class, Reason, Stack}}}
    end,
    unlink(PPid)
end,
CPid = spawn_link(Fun),
```

### Shovel Cleanup

**File:** `deps/rabbitmq_queue_migration/src/rqm.erl`, lines 1186-1201

```erlang
try
    ok = rabbit_runtime_parameters:set(VHost, <<"shovel">>, ShovelName, ShovelDef, none),
    ok = wait_for_shovel_completion(...),
    ?LOG_INFO("rqm: shovel ~ts completed successfully", [ShovelName])
catch
    Class:Reason:Stack ->
        ?LOG_ERROR("rqm: shovel ~ts failed: ~tp:~tp", [ShovelName, Class, Reason]),
        erlang:raise(Class, Reason, Stack)
after
    cleanup_migration_shovel(ShovelName, VHost)  % Always executes
end.
```

### Badmatch Location

**File:** `deps/rabbit/src/mirrored_supervisor.erl`, line 226

```erlang
child(Sup, Id) ->
    [Pid] = [Pid || {Id1, Pid, _, _} <- ?SUPERVISOR:which_children(Sup),
                    Id1 =:= Id],
    Pid.
```

When the list comprehension returns `[]`, the pattern match `[Pid] = []` raises `{badmatch, []}`.

---

## Glossary

**Terms used in this document:**

- **Exit exception:** An exception with class `exit`, raised by `exit(Reason)`, propagates through call stack
- **EXIT message:** A message `{'EXIT', Pid, Reason}` received when trapping exits from linked processes
- **Trap exits:** `process_flag(trap_exit, true)` - converts exit signals to messages
- **Scheduler:** Erlang VM thread that executes processes, typically one per CPU core
- **Worker pool:** Set of worker processes that execute tasks in parallel
- **Shovel:** RabbitMQ plugin that transfers messages between queues
- **Mirrored supervisor:** RabbitMQ's distributed supervisor that coordinates across cluster nodes
- **Gatherer pattern:** Coordination pattern for collecting results from distributed workers

---

## Contributing to This Document

When debugging new issues:

1. Add a new session section with date
2. Describe the problem with error messages
3. Explain root cause analysis
4. Document the solution
5. Extract key lessons learned
6. Reference relevant code locations

Keep entries focused and technical. Include actual error messages, stack traces, and code snippets to help future debugging efforts.
