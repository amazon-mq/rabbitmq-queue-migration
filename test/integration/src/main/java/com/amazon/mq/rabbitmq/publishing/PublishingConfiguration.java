package com.amazon.mq.rabbitmq.publishing;

import com.amazon.mq.rabbitmq.BrokerNode;
import com.amazon.mq.rabbitmq.ClusterTopology;
import com.rabbitmq.http.client.Client;
import java.util.Map;

/** Configuration for the multi-threaded publishing infrastructure. */
public class PublishingConfiguration {
  private final ClusterTopology clusterTopology;
  private final int confirmationWindow;

  public PublishingConfiguration(ClusterTopology clusterTopology) {
    this(clusterTopology, 100); // Default confirmation window
  }

  public PublishingConfiguration(ClusterTopology clusterTopology, int confirmationWindow) {
    this.clusterTopology = clusterTopology;
    this.confirmationWindow = confirmationWindow;
  }

  public ClusterTopology getClusterTopology() {
    return clusterTopology;
  }

  public int getConfirmationWindow() {
    return confirmationWindow;
  }

  public int getNodeCount() {
    return clusterTopology.getAllNodes().size();
  }

  public String getVirtualHost() {
    return clusterTopology.getAmqpEndpoint(0).getVirtualHost();
  }

  public String getUsername() {
    return clusterTopology.getUsername();
  }

  public String getPassword() {
    return clusterTopology.getPassword();
  }

  public Map<String, BrokerNode> getAllNodes() {
    return clusterTopology.getAllNodes();
  }

  public Client createHttpClient() {
    return clusterTopology.createHttpClient();
  }

  public boolean isLoadBalancerMode() {
    return clusterTopology.isLoadBalancerMode();
  }

  public javax.net.ssl.SSLContext getSslContext() {
    return clusterTopology.getSslContext();
  }
}
