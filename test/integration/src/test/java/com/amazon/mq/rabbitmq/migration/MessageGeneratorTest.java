package com.amazon.mq.rabbitmq.migration;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

import java.util.Map;
import com.amazon.mq.rabbitmq.ClusterTopology;

class MessageGeneratorTest {

    @Test
    void testGeneratePayload() {
        // Test different sizes
        byte[] small = MessageGenerator.generatePayload(1024);
        assertEquals(1024, small.length);

        byte[] large = MessageGenerator.generatePayload(1048576);
        assertEquals(1048576, large.length);

        // Test empty payload
        byte[] empty = MessageGenerator.generatePayload(0);
        assertEquals(0, empty.length);
    }

    @Test
    void testGenerateHeaders() {
        Map<String, Object> headers = MessageGenerator.generateHeaders(123, "TEST");

        assertNotNull(headers);
        assertEquals(123, headers.get("messageNumber"));
        assertEquals("TEST", headers.get("messageType"));
        assertEquals(0, headers.get("priority"));
        assertEquals(3, headers.size()); // messageNumber, messageType, and priority
    }

    @Test
    void testGenerateRoutingKey() {
        String key1 = MessageGenerator.generateRoutingKey(0, 10);
        String key2 = MessageGenerator.generateRoutingKey(1, 10);

        assertNotNull(key1);
        assertNotNull(key2);
        assertNotEquals(key1, key2);

        // Should contain expected patterns
        assertTrue(key1.contains("."));
    }

    @Test
    void testSelectMessageSize() {
        ClusterTopology topology = new ClusterTopology("localhost", 15672);
        TestConfiguration config = new TestConfiguration(topology);
        // Use default configuration values

        // Test that it returns one of the configured sizes
        for (int i = 0; i < 100; i++) {
            int size = MessageGenerator.selectMessageSize(config, i);
            assertTrue(size == config.getSmallMessageSize() ||
                      size == config.getMediumMessageSize() ||
                      size == config.getLargeMessageSize());
        }
    }

    @Test
    void testTestMessage() {
        byte[] payload = "test message".getBytes();
        Map<String, Object> headers = MessageGenerator.generateHeaders(1, "TEST");
        String routingKey = "test.key";

        MessageGenerator.TestMessage message = new MessageGenerator.TestMessage(payload, headers, routingKey);

        assertArrayEquals(payload, message.getPayload());
        assertEquals(headers, message.getHeaders());
        assertEquals(routingKey, message.getRoutingKey());
        assertTrue(message.validateChecksum());
    }
}
