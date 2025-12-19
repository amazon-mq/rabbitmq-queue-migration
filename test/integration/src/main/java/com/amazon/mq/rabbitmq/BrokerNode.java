package com.amazon.mq.rabbitmq;

/**
 * Represents a single RabbitMQ broker node with connection information.
 */
public class BrokerNode {
    private final String nodeName;
    private final String hostname;
    private final int amqpPort;
    private final int httpPort;

    public BrokerNode(String nodeName, String hostname, int amqpPort, int httpPort) {
        this.nodeName = nodeName;
        this.hostname = hostname;
        this.amqpPort = amqpPort;
        this.httpPort = httpPort;
    }

    public String getNodeName() {
        return nodeName;
    }

    public String getHostname() {
        return hostname;
    }

    public int getAmqpPort() {
        return amqpPort;
    }

    public int getHttpPort() {
        return httpPort;
    }

    @Override
    public String toString() {
        return String.format("BrokerNode{nodeName='%s', hostname='%s', amqp=%d, http=%d}",
                nodeName, hostname, amqpPort, httpPort);
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (o == null || getClass() != o.getClass()) return false;
        BrokerNode that = (BrokerNode) o;
        return amqpPort == that.amqpPort &&
                httpPort == that.httpPort &&
                nodeName.equals(that.nodeName) &&
                hostname.equals(that.hostname);
    }

    @Override
    public int hashCode() {
        return nodeName.hashCode();
    }
}
