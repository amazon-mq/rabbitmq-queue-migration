FROM rabbitmq:3.13.7-management

COPY --chown=rabbitmq:rabbitmq --chmod=0400 erlang.cookie /var/lib/rabbitmq/.erlang.cookie
COPY --chown=rabbitmq:rabbitmq enabled_plugins /etc/rabbitmq/enabled_plugins
COPY --chown=rabbitmq:rabbitmq rabbitmq.conf /etc/rabbitmq/rabbitmq.conf

COPY rabbitmq_queue_migration.ez /opt/rabbitmq/plugins/

RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install --yes --no-install-recommends unzip; \
    unzip -d /opt/rabbitmq/plugins /opt/rabbitmq/plugins/rabbitmq_queue_migration.ez

EXPOSE 4369 5673 15673 15692 25672 35672-35682
