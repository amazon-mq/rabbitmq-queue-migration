package com.amazon.mq.rabbitmq.migration;

import com.amazon.mq.rabbitmq.ClusterTopology;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.rabbitmq.http.client.Client;
import com.rabbitmq.http.client.domain.UserPermissions;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Checks which users can call each queue migration HTTP endpoint. Reading migration status and
 * running the compatibility check need the monitoring tag; starting, interrupting and changing a
 * migration need the administrator tag.
 *
 * <p>Every refusal is checked against the 401 reason the management plugin sends, so a 503 (plugin
 * not ready) or a 400 (validation) cannot pass for one, and every refused route is shown to be
 * reachable by getting a response other than 401 as an administrator.
 */
public class AuthorizationTest {
  private static final Logger logger = LoggerFactory.getLogger(AuthorizationTest.class);

  private static final String MONITORING_USER = "rqm-auth-monitoring";
  private static final String MANAGEMENT_USER = "rqm-auth-management";
  private static final String NO_TAGS_USER = "rqm-auth-no-tags";
  private static final String PASSWORD = "rqm-auth-" + UUID.randomUUID();
  // A vhost with no queues: an administrator's start reaches validation and is refused with 400,
  // so the start route can be shown reachable without starting a migration.
  private static final String EMPTY_VHOST = "rqm-auth-empty";
  private static final String NOT_ADMIN = "Not administrator user";
  private static final String NOT_MONITOR = "Not monitor user";
  // A user with no tags is refused before any route-specific check.
  private static final String NOT_MANAGEMENT = "Not management user";

  private static final ObjectMapper mapper = new ObjectMapper();
  private static final List<String> failures = new ArrayList<>();

  private static HttpClient http;
  private static String apiBase;
  private static String adminUser;
  private static String adminPassword;

  public static void main(String[] args) {
    Client admin = null;
    boolean passed = false;
    try {
      ClusterTopology topology = MigrationTestSetup.topologyFromArgs(args);
      TestConfiguration config = new TestConfiguration(topology);
      config.setQueueCount(2);
      config.setTotalMessages(0);

      String scheme = topology.isLoadBalancerMode() ? "https" : "http";
      apiBase = scheme + "://" + config.getHttpHost() + ":" + config.getHttpPort() + "/api";
      adminUser = topology.getUsername();
      adminPassword = topology.getPassword();
      HttpClient.Builder builder =
          HttpClient.newBuilder()
              .version(HttpClient.Version.HTTP_1_1)
              .connectTimeout(Duration.ofSeconds(10));
      if (topology.getSslContext() != null) {
        builder.sslContext(topology.getSslContext());
      }
      http = builder.build();

      logger.info("=== Phase 0: Cleanup ===");
      CleanupEnvironment.performCleanup(config);

      logger.info("=== Phase 1: Setup (2 empty queues, test users) ===");
      MigrationTestSetup.execute(config);
      admin = config.createHttpClient();
      String vhost = config.getVirtualHost();
      createUser(admin, vhost, MONITORING_USER, List.of("monitoring"));
      createUser(admin, vhost, MANAGEMENT_USER, List.of("management"));
      createUser(admin, vhost, NO_TAGS_USER, List.of());
      admin.createVhost(EMPTY_VHOST);

      logger.info("=== Phase 2: A refused start changes nothing ===");
      int migrationsBefore = migrationCount();
      String startPath = "/queue-migration/start/" + enc(vhost);
      expectRefused(MONITORING_USER, "POST", startPath, "{}", NOT_ADMIN);
      // A start that got through would create its record and suspend listeners asynchronously.
      Thread.sleep(3000);
      check(migrationCount() == migrationsBefore, "a refused start created a migration record");
      check(
          ConnectionTest.runConnectionTests(config),
          "AMQP connections failed after a refused start, so listeners were suspended");

      logger.info("=== Phase 3: Start a migration as administrator ===");
      Response started = send(adminUser, adminPassword, "POST", startPath, "{}");
      check(started.status == 200, "administrator start returned " + started);
      String migrationId = mapper.readTree(started.body).path("migration_id").asText();
      waitForStatus(migrationId, "completed");

      logger.info("=== Phase 4: Who can call each endpoint ===");
      String statusPath = "/queue-migration/status/" + migrationId;
      String checkPath = "/queue-migration/check/" + enc(vhost);
      String emptyStartPath = "/queue-migration/start/" + enc(EMPTY_VHOST);
      // The default vhost's queues are quorum queues after Phase 3, so an administrator's start
      // there is refused by validation rather than starting another migration.
      String defaultStartPath = "/queue-migration/start";
      String interruptPath = "/queue-migration/interrupt/" + migrationId;
      String badStatus = "{\"status\":\"foo_bar\"}";

      // A monitoring user is refused only on the admin routes, with the admin reason. A
      // management user fails the monitoring check; a user with no tags is refused before it.
      expectAllowed(MONITORING_USER, "GET", "/queue-migration/status", null, 200);
      expectAllowed(MONITORING_USER, "GET", statusPath, null, 200);
      expectAllowed(MONITORING_USER, "POST", checkPath, "{}", 200);
      expectRefused(MONITORING_USER, "POST", emptyStartPath, "{}", NOT_ADMIN);
      expectRefused(MONITORING_USER, "POST", defaultStartPath, "{}", NOT_ADMIN);
      expectRefused(MONITORING_USER, "POST", interruptPath, null, NOT_ADMIN);
      expectRefused(MONITORING_USER, "POST", statusPath, badStatus, NOT_ADMIN);
      for (String user : List.of(MANAGEMENT_USER, NO_TAGS_USER)) {
        String reason = MANAGEMENT_USER.equals(user) ? NOT_MONITOR : NOT_MANAGEMENT;
        expectRefused(user, "GET", "/queue-migration/status", null, reason);
        expectRefused(user, "GET", statusPath, null, reason);
        expectRefused(user, "POST", checkPath, "{}", reason);
        expectRefused(user, "POST", emptyStartPath, "{}", null);
        expectRefused(user, "POST", defaultStartPath, "{}", null);
        expectRefused(user, "POST", interruptPath, null, null);
        expectRefused(user, "POST", statusPath, badStatus, null);
      }
      // Reachability as administrator: each admin route answers with something other than 401.
      expectAllowed(adminUser, "GET", "/queue-migration/status", null, 200);
      expectAllowed(adminUser, "POST", checkPath, "{}", 200);
      expectAllowed(adminUser, "POST", emptyStartPath, "{}", 400);
      expectAllowed(adminUser, "POST", defaultStartPath, "{}", 400);
      expectAllowed(adminUser, "POST", "/queue-migration/interrupt/not-a-migration", null, 404);
      // GET on a POST-only route is refused by method, before authorization.
      expectAllowed(MONITORING_USER, "GET", emptyStartPath, null, 405);
      expectAllowed(adminUser, "GET", interruptPath, null, 405);
      expectAllowed(adminUser, "GET", defaultStartPath, null, 405);
      expectAllowed(MONITORING_USER, "HEAD", checkPath, null, 405);

      logger.info("=== Phase 5: Refused interrupt and status update change nothing ===");
      check("completed".equals(storedStatus(migrationId)), "refused requests changed the status");

      logger.info("=== Phase 6: Status updates accept only rollback_completed ===");
      expectAllowed(adminUser, "POST", statusPath, badStatus, 400);
      expectAllowed(
          adminUser,
          "POST",
          statusPath,
          "{\"status\":\"not_an_existing_atom_"
              + UUID.randomUUID().toString().replace("-", "")
              + "\"}",
          400);
      check("completed".equals(storedStatus(migrationId)), "a refused status value was stored");
      expectAllowed(adminUser, "POST", statusPath, "{\"status\":\"rollback_completed\"}", 200);
      check(
          "rollback_completed".equals(storedStatus(migrationId)),
          "rollback_completed was accepted but not stored");

      if (!failures.isEmpty()) {
        throw new RuntimeException(failures.size() + " authorization check(s) failed");
      }
      passed = true;
      logger.info("✅ Authorization test passed!");
    } catch (Exception e) {
      // Report the checks that failed before the exception: they usually explain it.
      failures.forEach(f -> logger.error("❌ {}", f));
      logger.error("❌ Authorization test failed", e);
    } finally {
      if (admin != null) {
        for (String user : List.of(MONITORING_USER, MANAGEMENT_USER, NO_TAGS_USER)) {
          try {
            admin.deleteUser(user);
          } catch (Exception ignored) {
            // Best effort: the user may not have been created.
          }
        }
        try {
          admin.deleteVhost(EMPTY_VHOST);
        } catch (Exception ignored) {
          // Best effort: the vhost may not have been created.
        }
      }
    }
    if (!passed) {
      System.exit(1);
    }
  }

  private static void createUser(Client admin, String vhost, String user, List<String> tags) {
    admin.createUser(user, PASSWORD.toCharArray(), tags);
    admin.updatePermissions(vhost, user, new UserPermissions(".*", ".*", ".*"));
  }

  /** The request must get through authorization and return the expected status. */
  private static void expectAllowed(
      String user, String method, String path, String body, int expectedStatus) throws Exception {
    Response r = sendAs(user, method, path, body);
    check(
        r.status == expectedStatus,
        user + " " + method + " " + path + ": expected " + expectedStatus + ", got " + r);
  }

  /**
   * The request must be refused by authorization: a 401 whose reason, when given, is the expected
   * one. A null reason accepts any 401 from the management plugin.
   */
  private static void expectRefused(
      String user, String method, String path, String body, String reason) throws Exception {
    Response r = sendAs(user, method, path, body);
    boolean ok = r.status == 401;
    if (ok && reason != null) {
      ok = reason.equals(mapper.readTree(r.body).path("reason").asText());
    }
    check(ok, user + " " + method + " " + path + ": expected 401 " + reason + ", got " + r);
  }

  private static Response sendAs(String user, String method, String path, String body)
      throws Exception {
    String password = adminUser.equals(user) ? adminPassword : PASSWORD;
    return send(user, password, method, path, body);
  }

  private static Response send(
      String user, String password, String method, String path, String body) throws Exception {
    String auth =
        Base64.getEncoder()
            .encodeToString((user + ":" + password).getBytes(StandardCharsets.UTF_8));
    HttpRequest.Builder b =
        HttpRequest.newBuilder()
            .uri(URI.create(apiBase + path))
            .header("Authorization", "Basic " + auth)
            .header("Content-Type", "application/json")
            .timeout(Duration.ofSeconds(60));
    HttpRequest.BodyPublisher publisher =
        body == null
            ? HttpRequest.BodyPublishers.noBody()
            : HttpRequest.BodyPublishers.ofString(body);
    HttpResponse<String> resp =
        http.send(b.method(method, publisher).build(), HttpResponse.BodyHandlers.ofString());
    return new Response(resp.statusCode(), resp.body());
  }

  private static int migrationCount() throws Exception {
    Response r = send(adminUser, adminPassword, "GET", "/queue-migration/status", null);
    return mapper.readTree(r.body).path("migrations").size();
  }

  private static String storedStatus(String migrationId) throws Exception {
    Response r =
        send(adminUser, adminPassword, "GET", "/queue-migration/status/" + migrationId, null);
    JsonNode migration = mapper.readTree(r.body).path("migration");
    return migration.path("status").asText();
  }

  private static void waitForStatus(String migrationId, String expected) throws Exception {
    List<String> terminal = List.of("completed", "failed", "interrupted", "rollback_pending");
    long deadline = System.currentTimeMillis() + 120_000;
    String status = null;
    while (System.currentTimeMillis() < deadline) {
      status = storedStatus(migrationId);
      if (expected.equals(status)) {
        return;
      }
      if (terminal.contains(status)) {
        break;
      }
      Thread.sleep(2000);
    }
    throw new RuntimeException("migration " + migrationId + " ended in " + status);
  }

  private static void check(boolean condition, String failure) {
    if (!condition) {
      failures.add(failure);
    }
  }

  private static String enc(String vhost) {
    return URLEncoder.encode(vhost, StandardCharsets.UTF_8).replace("+", "%20");
  }

  private static final class Response {
    final int status;
    final String body;

    Response(int status, String body) {
      this.status = status;
      this.body = body;
    }

    @Override
    public String toString() {
      return status + " " + (body == null ? "" : body.replaceAll("\\s+", " "));
    }
  }
}
