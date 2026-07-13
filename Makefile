PROJECT = rabbitmq_queue_migration
PROJECT_DESCRIPTION = RabbitMQ Queue Migration
PROJECT_MOD = rqm_app
PROJECT_VERSION = 1.2.0

define PROJECT_APP_EXTRA_KEYS
	{broker_version_requirements, []}
endef

DEPS = rabbit_common rabbit rabbitmq_management rabbitmq_aws
TEST_DEPS = rabbitmq_ct_helpers rabbitmq_ct_client_helpers

PLT_APPS += mnesia rabbitmq_shovel

DEP_EARLY_PLUGINS = rabbit_common/mk/rabbitmq-early-plugin.mk
DEP_PLUGINS = rabbit_common/mk/rabbitmq-plugin.mk

include ../../rabbitmq-components.mk
include ../../erlang.mk
