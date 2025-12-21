package com.amazon.mq.rabbitmq;

public class AmqpEndpoint {
    private final String hostname;
    private int port;
    private String username;
    private String password;

    public AmqpEndpoint(String hostname, int port, String username, String password) {
        this.hostname = hostname;
        this.port = port;
        this.username = username;
        this.password = password;
    }

    public String getHostname() {
        return this.hostname;
    }

    public int getPort() {
        return this.port;
    }

    public String getUsername() {
        return this.username;
    }

    public String getPassword() {
        return this.password;
    }

    public String getVirtualHost() {
        return "/"; // TODO constants?
    }
}
