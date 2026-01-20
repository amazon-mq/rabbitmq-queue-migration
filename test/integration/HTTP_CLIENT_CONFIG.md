# Java HTTP Client Configuration

## CRITICAL: Always Use HTTP/1.1

**Rule:** When creating Java `HttpClient` instances in test/integration code, ALWAYS force HTTP/1.1:

```java
HttpClient httpClient = HttpClient.newBuilder()
    .version(HttpClient.Version.HTTP_1_1)  // REQUIRED
    .connectTimeout(Duration.ofSeconds(10))
    .build();
```

**Why:** RabbitMQ Management API uses HTTP/1.1. The Java HTTP client defaults to HTTP/2, which causes EOF exceptions when the server closes the HTTP/2 connection attempt.

**Symptom:** `java.io.EOFException: EOF reached while reading` in `Http2Connection` stack traces.

**DO NOT:**
- Omit `.version(HttpClient.Version.HTTP_1_1)`
- Assume HTTP/2 will work
- Try to "fix" this by switching HTTP clients

**This mistake has been made multiple times. Never make it again.**
