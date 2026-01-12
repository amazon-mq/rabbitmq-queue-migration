# Message Transfer Approaches: Internal Queue API vs Shovels

**Date:** January 12, 2026  
**Context:** Research for improving RabbitMQ queue migration reliability and performance

## Overview

The queue migration plugin has used two different approaches for transferring messages from classic queues to quorum queues:

1. **Direct Internal Queue API** (original implementation)
2. **Shovel-based Transfer** (current implementation)

This document analyzes both approaches and explores a hybrid async windowed approach.

---

## Approach 1: Direct Internal Queue API (Synchronous)

### Implementation

Uses RabbitMQ's internal `rabbit_queue_type` API to directly dequeue from source and deliver to destination:

```erlang
dequeue_and_deliver(FinalResource, OldQ, NewQueue, OldQState, NewQueueState, Counter, Phase) ->
    case rabbit_queue_type:dequeue(OldQ, false, self(), 0, OldQState) of
        {empty, DelState} ->
            % Source empty, migration complete
            ok;
        {ok, _Count, {Name, _, MsgId, _, Msg}, QueueState} ->
            % 1. Deliver message to destination
            DeliverState = deliver(NewQueue, Msg, NewQueueState),
            % 2. Settle (ack) message on source
            settle(OldQ, Name, MsgId, QueueState),
            % 3. Continue with next message
            dequeue_and_deliver(FinalResource, OldQ, NewQueue, QueueState, DeliverState, Counter + 1, Phase)
    end.

deliver(Q, Msg, State) ->
    QRef = amqqueue:get_name(Q),
    {ok, NewState, _} = rabbit_queue_type:deliver([Q], Msg, #{correlation => 1}, State),
    receive
        {'$gen_cast', {queue_event, QRef, {_, {applied, [{_, ok}]}} = Evt}} ->
            {ok, LState, _} = rabbit_queue_type:handle_event(QRef, Evt, NewState),
            LState
    after 30000 ->
        ?LOG_WARNING("deliver timeout")
    end.

settle(OldQ, Name, MsgId, QueueState) ->
    {ok, NewState, _} = rabbit_queue_type:settle(Name, complete, 0, [MsgId], QueueState),
    % Wait for settlement RA event...
```

### Characteristics

**Advantages:**
- ✅ **Reliable**: Can't lose messages - each confirmed before proceeding
- ✅ **Visible**: Full control and visibility into every operation
- ✅ **Simple**: No external dependencies (no shovel plugin required)
- ✅ **Safe**: If process crashes, messages remain in source queue
- ✅ **Direct**: No AMQP protocol overhead, uses internal APIs
- ✅ **Deterministic**: Predictable behavior, easy to debug

**Disadvantages:**
- ❌ **Slow**: One message at a time with synchronous waits
- ❌ **Network round-trips**: Each message requires multiple RA consensus rounds
- ❌ **No batching**: Can't leverage quorum queue batch operations
- ❌ **Blocking**: Worker blocked waiting for each message confirmation

**Performance:**
- Approximately 10-50 messages/second per queue
- Acceptable for small queues (< 1000 messages)
- Prohibitively slow for large queues (10,000+ messages)

---

## Approach 2: Shovel-based Transfer (Current)

### Implementation

Uses RabbitMQ's shovel plugin to transfer messages via AMQP:

```erlang
migrate_queue_messages_with_shovel(FinalResource, MigrationId, OldQ, NewQ, Phase) ->
    % Build shovel definition
    ShovelDef = rqm_shovel:build_definition(OldQName, NewQName, MessageCount),
    
    % Create and verify shovel
    ok = rqm_shovel:create_with_retry(VHost, ShovelName, ShovelDef, 10),
    ok = rqm_shovel:verify_started(VHost, ShovelName),
    
    % Wait for completion by monitoring message counts
    ok = wait_for_shovel_completion(
        ShovelName, VHost, FinalResource, MigrationId, OldQ, NewQ, PreMigrationCounts
    ),
    
    % Cleanup
    rqm_shovel:cleanup(ShovelName, VHost).
```

### Characteristics

**Advantages:**
- ✅ **Fast**: Parallel message transfer with configurable prefetch
- ✅ **Proven**: Shovels are battle-tested in production
- ✅ **Efficient**: Leverages AMQP consumer/publisher optimizations
- ✅ **Scalable**: Can handle large queues efficiently
- ✅ **Configurable**: Prefetch tuning for different workloads

**Disadvantages:**
- ❌ **Opaque**: Limited visibility into shovel internals
- ❌ **External dependency**: Requires rabbitmq_shovel plugin
- ❌ **Indirect monitoring**: Must poll message counts to detect completion
- ❌ **Silent failures**: Shovel can fail to start without clear indication
- ❌ **Message loss risk**: Observed cases where messages disappeared
- ❌ **AMQP overhead**: Protocol layer even for local queues
- ❌ **Complex debugging**: Shovel issues are hard to diagnose

**Performance:**
- 1000-5000+ messages/second per queue (depends on message size and prefetch)
- Excellent for large queues
- Overkill for small queues (< 100 messages)

**Known Issues:**
- Shovel worker may fail to start even when parameter is set
- Message count mismatches observed (messages disappearing)
- Timeout detection is slow (30 minutes with retries)

---

## Approach 3: Direct Internal Queue API (Async Windowed)

### Proposed Implementation

Combines the reliability of direct API with performance of batching:

```erlang
async_migrate(FinalResource, OldQ, NewQ, WindowSize) ->
    async_migrate(FinalResource, OldQ, NewQ, WindowSize, #{}, 0).

async_migrate(FinalResource, OldQ, NewQ, WindowSize, InFlight, Counter) ->
    % 1. Dequeue messages up to window size
    {Messages, OldQState} = dequeue_batch(OldQ, WindowSize - map_size(InFlight)),
    
    % 2. Deliver all messages with unique correlation IDs (async)
    InFlight1 = deliver_batch(NewQ, Messages, InFlight),
    
    % 3. Collect delivery confirmations (with timeout)
    {Delivered, InFlight2} = collect_delivery_events(NewQ, InFlight1, Timeout),
    
    % 4. Settle delivered messages (async)
    InFlight3 = settle_batch(OldQ, Delivered, InFlight2),
    
    % 5. Collect settlement confirmations (with timeout)
    {Settled, InFlight4} = collect_settlement_events(OldQ, InFlight3, Timeout),
    
    % 6. Update progress and continue
    NewCounter = Counter + length(Settled),
    update_progress(FinalResource, NewCounter),
    
    case {Messages, map_size(InFlight4)} of
        {[], 0} -> ok;
        _ -> async_migrate(...)
    end.
```

### Key Mechanisms

**Correlation ID Tracking:**
```erlang
% Assign unique correlation ID to each message
CorrelationId = Counter + 1,
{ok, NewState, _} = rabbit_queue_type:deliver([Q], Msg, #{correlation => CorrelationId}, State)

% Match in RA event
receive
    {'$gen_cast', {queue_event, QRef, {_, {applied, [{CorrelationId, ok}]}}}} ->
        % This message was confirmed
end
```

**Window Management:**
- Window size controls max outstanding messages
- Smaller window (10-50): More reliable, easier to track
- Larger window (100-500): Better performance, more complex
- Dynamic window: Adjust based on success rate

**Event Collection:**
```erlang
collect_delivery_events(QRef, InFlight, Timeout) ->
    collect_delivery_events(QRef, InFlight, Timeout, erlang:monotonic_time(millisecond)).

collect_delivery_events(QRef, InFlight, Timeout, StartTime) ->
    Elapsed = erlang:monotonic_time(millisecond) - StartTime,
    Remaining = max(0, Timeout - Elapsed),
    
    receive
        {'$gen_cast', {queue_event, QRef, {_, {applied, Results}}}} ->
            % Mark messages as delivered based on correlation IDs in Results
            InFlight1 = mark_delivered(Results, InFlight),
            % Continue collecting if more expected
            case all_delivered(InFlight1) of
                true -> {ok, InFlight1};
                false -> collect_delivery_events(QRef, InFlight1, Timeout, StartTime)
            end
    after Remaining ->
        {timeout, InFlight}
    end.
```

### Characteristics

**Advantages:**
- ✅ **Reliable**: Full control over every message
- ✅ **Fast**: Batched operations with configurable window
- ✅ **Visible**: Complete visibility into message state
- ✅ **No external dependencies**: Uses only internal APIs
- ✅ **Deterministic**: Predictable behavior
- ✅ **Debuggable**: Can log every step
- ✅ **Recoverable**: Know exactly which messages succeeded/failed

**Disadvantages:**
- ❌ **Complex**: Significant implementation complexity
- ❌ **State management**: Must track multiple in-flight messages
- ❌ **Event handling**: Complex receive loops with timeouts
- ❌ **Testing**: More code paths to test
- ❌ **Maintenance**: More code to maintain

**Performance Estimate:**
- With window size 50: ~500-1000 messages/second
- With window size 100: ~1000-2000 messages/second
- Better than sync, not quite as fast as shovels
- More predictable than shovels

---

## Comparison Matrix

| Aspect | Sync Direct API | Shovels | Async Windowed API |
|--------|----------------|---------|-------------------|
| **Reliability** | Excellent | Good (with issues) | Excellent |
| **Performance** | Poor | Excellent | Good |
| **Visibility** | Excellent | Poor | Excellent |
| **Complexity** | Low | Low (for us) | High |
| **Dependencies** | None | Shovel plugin | None |
| **Debugging** | Easy | Hard | Medium |
| **Message Loss Risk** | None | Observed | None |
| **Suitable For** | Small queues | Large queues | All sizes |

---

## Recommendations

### Short Term (Current State)

**Continue with shovels** but improve reliability:
1. ✅ **Shovel startup verification** - Detect silent failures early (implemented)
2. ✅ **Dynamic prefetch** - Safer defaults for mixed message sizes (implemented)
3. 🔲 **Better error detection** - Detect stuck shovels faster
4. 🔲 **Message count validation** - Stricter tolerance checking
5. 🔲 **Investigate message loss** - Root cause analysis needed

### Medium Term

**Hybrid approach** - Use different methods based on queue size:
- Small queues (< 1000 messages): Direct sync API (reliable, fast enough)
- Large queues (≥ 1000 messages): Shovels (fast, acceptable risk)
- Configurable threshold

### Long Term

**Consider async windowed API** if:
- Shovel reliability issues persist
- Need better visibility for debugging
- Performance requirements can't be met with sync API
- Willing to invest in implementation and testing

**Implementation effort estimate:**
- Core async logic: 2-3 days
- Event handling and correlation: 2-3 days
- Error handling and recovery: 2-3 days
- Testing and debugging: 3-5 days
- **Total: 2-3 weeks**

---

## Technical Details

### Correlation ID Usage

The correlation ID is passed through the entire delivery pipeline:

```erlang
% Delivery
rabbit_queue_type:deliver([Q], Msg, #{correlation => CorrelationId}, State)
  ↓
rabbit_fifo_client:enqueue(QName, CorrelationId, Msg, QState)
  ↓
RA consensus
  ↓
RA event: {applied, [{CorrelationId, ok}]}
```

This allows matching async responses to specific messages.

### Window Size Considerations

**Factors affecting optimal window size:**
- Message size (larger messages = smaller window)
- Network latency (higher latency = larger window beneficial)
- Memory constraints (window * avg_message_size < memory_limit)
- Error rate (higher errors = smaller window for easier recovery)

**Recommended starting point:**
- Default: 50 messages
- Small messages (< 10KB): 100 messages
- Large messages (> 100KB): 25 messages
- Configurable per migration

### Error Handling Strategy

**Delivery failure:**
- Retry message with exponential backoff
- After N retries, fail the migration
- Messages remain in source queue (safe)

**Settlement failure:**
- Message delivered but not settled
- On retry, message would be duplicated
- Need idempotency or accept duplication
- Document this behavior clearly

**Timeout handling:**
- Per-message timeout: 30 seconds
- Per-batch timeout: 5 minutes
- Overall migration timeout: configurable

---

## Open Questions

1. **Can we batch dequeue?** Does `rabbit_queue_type:dequeue` support multiple messages?
2. **RA event batching:** Do RA events come individually or can they be batched?
3. **Ordering requirements:** Must messages be delivered in order?
4. **Memory limits:** What's a safe upper bound for in-flight messages?
5. **Crash recovery:** How to handle partial batches on process crash?

---

## Next Steps

### Investigation Needed

1. **Root cause shovel message loss**
   - Why did 500 messages disappear in test?
   - Is it a shovel bug or our usage?
   - Can it be prevented?

2. **Benchmark async windowed approach**
   - Prototype with small window (10 messages)
   - Measure performance vs shovels
   - Validate reliability

3. **Test shovel improvements**
   - Verify startup detection works at scale
   - Test dynamic prefetch with various message sizes
   - Monitor for message loss

### Decision Criteria

**Stick with shovels if:**
- Message loss issue can be resolved
- Performance is acceptable
- Startup verification prevents silent failures

**Switch to async windowed API if:**
- Shovel reliability issues persist
- Need better debugging visibility
- Performance requirements justify the complexity

---

## Code References

### Current Shovel Implementation
- `src/rqm_shovel.erl` - Shovel lifecycle management
- `src/rqm.erl:wait_for_shovel_completion_stable/9` - Completion monitoring
- `src/rqm.erl:migrate_queue_messages_with_shovel/5` - Main flow

### Old Direct API Implementation
- `/home/lrbakken/workplace/.../rabbit_queue_migration.erl:dequeue_and_deliver/7`
- `/home/lrbakken/workplace/.../rabbit_queue_migration.erl:deliver/3`
- `/home/lrbakken/workplace/.../rabbit_queue_migration.erl:settle/4`

### Relevant RabbitMQ APIs
- `rabbit_queue_type:dequeue/4` - Dequeue messages
- `rabbit_queue_type:deliver/3` - Deliver messages with correlation ID
- `rabbit_queue_type:settle/5` - Settle (ack) messages
- `rabbit_queue_type:handle_event/3` - Handle RA events
- `rabbit_fifo_client:enqueue/4` - Underlying quorum queue enqueue

---

## Conclusion

The async windowed approach offers a compelling middle ground between reliability and performance. However, it requires significant implementation effort. The current shovel-based approach with recent improvements (startup verification, dynamic prefetch) may be sufficient if the message loss issue can be resolved.

**Recommendation:** Continue with shovels while monitoring for issues. If message loss persists, prototype the async windowed approach with a small window size (10-25 messages) to validate the concept before full implementation.
