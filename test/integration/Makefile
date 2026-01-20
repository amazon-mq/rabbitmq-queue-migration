.DEFAULT_GOAL := package
.PHONY: clean compile debug run run-example

SRC_DIRS := $(CURDIR)/src/main/java/com/amazon/mq/rabbitmq
SRCS := $(wildcard $(SRC_DIRS)/**/*.java)
JAR := $(CURDIR)/target/migration-test-setup-1.0.0.jar

clean:
	$(CURDIR)/mvnw clean

compile:
	$(CURDIR)/mvnw compile

debug:
	@echo $(SRCS)

$(JAR): $(SRCS)
	$(CURDIR)/mvnw package -B -q -DskipTests=true

package: $(JAR)

run: package
	java -jar $(JAR) $(ARGS)

run-example: compile
	$(CURDIR)/mvnw exec:java -Dexec.mainClass="com.amazon.mq.rabbitmq.publishing.PublishingExample"

# integration-test

.PHONY: integration-test start-cluster stop-cluster integration-end-to-end integration-interrupt

rabbitmq-queue-migration-plugin: $(CURDIR)/docker/rabbitmq_queue_migration.ez

start-cluster: rabbitmq-queue-migration-plugin
	$(MAKE) -C $(CURDIR)/docker start-cluster

stop-cluster:
	$(MAKE) -C $(CURDIR)/docker stop-cluster

integration-test: rabbitmq-queue-migration-plugin start-cluster integration-end-to-end integration-interrupt integration-skip-unsuitable integration-batch

integration-end-to-end: package
	java -jar $(JAR) end-to-end \
		--queue-count=10 \
		--total-messages=1000 \
		--migration-timeout=300 \
		--hostname=localhost \
		--port=15672

integration-interrupt: package
	java -jar $(JAR) interrupt-test \
		--hostname=localhost \
		--port=15672

integration-skip-unsuitable: package
	java -jar $(JAR) skip-unsuitable-test \
		--hostname=localhost \
		--port=15672

integration-batch: package
	java -jar $(JAR) batch-test \
		--hostname=localhost \
		--port=15672
