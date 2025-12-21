.PHONY: rabbitmq-queue-migration-plugin integration-test

# NOTE:
# If plugins/rabbitmq_queue_migration-*.ez does not yet exist, run:
#
# make DIST_AS_EZS=true dist
#
$(CURDIR)/test/integration/docker/rabbitmq_queue_migration.ez:
	cp -f $(CURDIR)/plugins/rabbitmq_queue_migration-*.ez $(CURDIR)/test/integration/docker/rabbitmq_queue_migration.ez

rabbitmq-queue-migration-plugin: $(CURDIR)/test/integration/docker/rabbitmq_queue_migration.ez

.PHONY: integration-test stop-cluster
integration-test: rabbitmq-queue-migration-plugin
	$(MAKE) -C $(CURDIR)/test/integration integration-test
