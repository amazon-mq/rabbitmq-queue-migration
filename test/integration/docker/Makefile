.PHONY: start-cluster stop-cluster

DOCKER_FRESH ?= false

rabbitmq-queue-migration-plugin: $(CURDIR)/rabbitmq_queue_migration.ez
	cp -f rabbitmq_queue_migration.ez rmq0
	cp -f rabbitmq_queue_migration.ez rmq1
	cp -f rabbitmq_queue_migration.ez rmq2

start-cluster: rabbitmq-queue-migration-plugin
ifeq ($(DOCKER_FRESH),true)
	docker compose build --pull --no-cache
else
	docker compose build
endif
	$(CURDIR)/start-cluster.sh

stop-cluster:
	$(CURDIR)/stop-cluster.sh
