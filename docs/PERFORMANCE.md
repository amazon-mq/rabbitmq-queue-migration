# Migration Performance Reference

**Last Updated:** March 27, 2026

Real-world migration timing data from Amazon MQ for RabbitMQ environments.
Use these figures as a rough guide when estimating migration windows.

---

## Important Caveats

Migration duration depends on many factors:

- Instance type (CPU, memory, network, disk I/O)
- Number of queues and total message count
- Message size
- Disk space available relative to data size
- Cluster network conditions at migration time

The figures below are from specific test runs and should be treated as
reference points, not guarantees.

---

## mq.m7g.large — Migration at Disk Capacity Limit

### Environment

| Property | Value |
|----------|-------|
| Instance type | mq.m7g.large (cluster deployment, 3 nodes) |
| vCPU per node | 2 |
| Memory per node | 8 GiB |
| Storage | EBS |
| Disk per node | 15 GB |
| Network baseline / burst | 0.937 / 12.5 Gbps |

See [Amazon MQ RabbitMQ broker instance types](https://docs.aws.amazon.com/amazon-mq/latest/developer-guide/rmq-broker-instance-types.html)
for full instance specifications.

### Migration Parameters

| Property | Value |
|----------|-------|
| Queues migrated | 50 |
| Messages per queue | 4,100 |
| Message size | 16 KiB |
| Total data | ~3.1 GiB |

### Result

| Property | Value |
|----------|-------|
| Duration | 2 minutes 4 seconds |
| Outcome | All 50 queues completed successfully |

### Notes

This migration was deliberately configured to approach the disk capacity
limit of the mq.m7g.large instance type. With 15 GB of disk per node and
~3.1 GiB of queue data, the plugin's disk space check requires approximately
6.7 GB free (3.1 GiB × 2.0 multiplier + 500 MB buffer), leaving very little
headroom on a 15 GB volume.

**If you are running mq.m7g.large**, this result represents approximately the
maximum data volume you can migrate in a single run. Exceeding this will cause
the pre-migration disk space check to fail. Use `batch_size` to migrate in
smaller increments if your total queue data exceeds this threshold.

---

## mq.m7g.4xlarge — Migration at Disk Capacity Limit

### Environment

| Property | Value |
|----------|-------|
| Instance type | mq.m7g.4xlarge (cluster deployment, 3 nodes) |
| vCPU per node | 16 |
| Memory per node | 64 GiB |
| Storage | EBS |
| Disk per node | 90 GB |
| Network baseline / burst | 7.5 / 15.0 Gbps |

See [Amazon MQ RabbitMQ broker instance types](https://docs.aws.amazon.com/amazon-mq/latest/developer-guide/rmq-broker-instance-types.html)
for full instance specifications.

### Migration Parameters

| Property | Value |
|----------|-------|
| Queues migrated | 250 |
| Messages per queue | 5,000 |
| Message size | 16 KiB |
| Total data | ~19.1 GiB |

### Result

| Property | Value |
|----------|-------|
| Duration | 11 minutes 35 seconds |
| Outcome | All 250 queues completed successfully |

### Notes

This migration was configured to approach the disk capacity limit of the
mq.m7g.4xlarge instance type. With 90 GB of disk per node and ~19.1 GiB
of queue data, the plugin requires approximately 38.7 GB free
(19.1 GiB × 2.0 multiplier + 500 MB buffer).

---

## Related Documentation

- **Configuration Reference:** [CONFIGURATION](CONFIGURATION.md)
- **Troubleshooting:** [TROUBLESHOOTING](TROUBLESHOOTING.md)
- **Amazon MQ instance types:** [rmq-broker-instance-types](https://docs.aws.amazon.com/amazon-mq/latest/developer-guide/rmq-broker-instance-types.html)
