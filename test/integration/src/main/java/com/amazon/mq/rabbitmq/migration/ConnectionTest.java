package com.amazon.mq.rabbitmq.migration;

import com.amazon.mq.rabbitmq.AmqpEndpoint;
import com.rabbitmq.client.Connection;
import com.rabbitmq.client.ConnectionFactory;
import com.rabbitmq.http.client.Client;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/** Utility class to test RabbitMQ connections and diagnose issues. */
public class ConnectionTest {

  private static final Logger logger = LoggerFactory.getLogger(ConnectionTest.class);

  /** Test AMQP connections to all configured URIs */
  public static boolean testAmqpConnection(TestConfiguration config) {
    boolean allSuccessful = true;

    for (int i = 0; i < config.getNodeCount(); i++) {
      AmqpEndpoint endpoint = config.getAmqpEndpoint(i);
      logger.info(
          "Testing AMQP connection to {}:{} vhost '{}'",
          endpoint.getHostname(),
          endpoint.getPort(),
          endpoint.getVirtualHost());

      ConnectionFactory factory = new ConnectionFactory();
      factory.setHost(endpoint.getHostname());
      factory.setPort(endpoint.getPort());
      factory.setUsername(endpoint.getUsername());
      factory.setPassword(endpoint.getPassword());
      factory.setVirtualHost(endpoint.getVirtualHost());
      factory.setConnectionTimeout(5000);

      try (Connection connection = factory.newConnection("connection-test")) {
        logger.info(
            "✅ AMQP connection successful to {}:{}", endpoint.getHostname(), endpoint.getPort());
      } catch (Exception e) {
        logger.error(
            "❌ AMQP connection failed to {}:{}: {}",
            endpoint.getHostname(),
            endpoint.getPort(),
            e.getMessage());
        allSuccessful = false;

        if (e.getCause() instanceof com.rabbitmq.client.ShutdownSignalException) {
          com.rabbitmq.client.ShutdownSignalException sse =
              (com.rabbitmq.client.ShutdownSignalException) e.getCause();
          String reason = sse.getReason().toString();

          if (reason.contains("vhost") && reason.contains("not found")) {
            logger.error("Virtual host '{}' does not exist", endpoint.getVirtualHost());
            logger.info("Create it with: rabbitmqctl add_vhost {}", endpoint.getVirtualHost());
            logger.info(
                "Grant permissions with: rabbitmqctl set_permissions -p {} {} \".*\" \".*\" \".*\"",
                endpoint.getVirtualHost(),
                endpoint.getUsername());
          } else if (reason.contains("ACCESS_REFUSED")) {
            logger.error("Authentication failed for user '{}'", endpoint.getUsername());
            logger.info(
                "Check username/password or create user with: rabbitmqctl add_user {} <password>",
                endpoint.getUsername());
            logger.info(
                "Set admin tag with: rabbitmqctl set_user_tags {} administrator",
                endpoint.getUsername());
          }
        }
      }
    }

    return allSuccessful;
  }

  /** Test HTTP management API connections to all configured URIs */
  public static boolean testManagementConnection(TestConfiguration config) {
    boolean allSuccessful = true;

    for (int i = 0; i < config.getNodeCount(); i++) {
      Client client = config.createHttpClient(i);
      logger.info("Testing Management API connection to {}", client.toString());

      boolean thisUriSuccess = false;
      try {
        // Test with a simple API call that should work
        client.getVhosts();
        logger.info("✅ Management API connection successful to {}", client.toString());
        thisUriSuccess = true;
      } catch (Exception e) {
        logger.error(
            "❌ Management API connection failed to {}: {}", client.toString(), e.getMessage());

        String errorMsg = e.getMessage().toLowerCase();
        if (errorMsg.contains("401") || errorMsg.contains("unauthorized")) {
          logger.error("Authentication failed for management API");
          logger.info(
              "Ensure user 'guest' has administrator tag: rabbitmqctl set_user_tags guest"
                  + " administrator");
        } else if (errorMsg.contains("connection refused")) {
          logger.error("Management plugin may not be enabled");
          logger.info("Enable it with: rabbitmq-plugins enable rabbitmq_management");
        } else if (errorMsg.contains("404")) {
          logger.error("Management API endpoint not found - check the port and URL");
        } else if (errorMsg.contains("406")) {
          logger.error("Content negotiation issue - this may be a version compatibility problem");
        }
      }

      if (!thisUriSuccess) {
        allSuccessful = false;
      }
    }

    return allSuccessful;
  }

  /** Run comprehensive connection tests */
  public static boolean runConnectionTests(TestConfiguration config) {
    logger.info("Running connection diagnostics...");

    boolean amqpOk = testAmqpConnection(config);
    boolean mgmtOk = testManagementConnection(config);

    if (amqpOk && mgmtOk) {
      logger.info("✅ All connection tests passed");
      return true;
    } else {
      logger.error("❌ Connection tests failed");
      return false;
    }
  }
}
