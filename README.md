# RabbitMQ Queue Migration Plugin

This plugin adds information on queue migration status to the management
plugin.

## Installation

```shell
rabbitmq-plugins enable rabbitmq_queue_migration
```

If you have a heterogenous cluster (where the nodes have different plugins
installed), this should be installed on the same nodes as the management
plugin.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This project is licensed under the Apache-2.0 License.
