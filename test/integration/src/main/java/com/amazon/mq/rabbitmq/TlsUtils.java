package com.amazon.mq.rabbitmq;

import java.security.KeyManagementException;
import java.security.NoSuchAlgorithmException;
import java.security.cert.X509Certificate;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

/**
 * TLS utilities for connections that skip certificate and hostname verification.
 * Used when connecting through a load balancer where the certificate CN won't match.
 */
public final class TlsUtils {

    private TlsUtils() {}

    /**
     * Creates an SSLContext that trusts all certificates and skips hostname verification.
     */
    public static SSLContext createTrustAllSslContext() {
        try {
            SSLContext sslContext = SSLContext.getInstance("TLSv1.2");
            sslContext.init(null, new TrustManager[] { new TrustAllTrustManager() }, null);
            return sslContext;
        } catch (NoSuchAlgorithmException | KeyManagementException e) {
            throw new RuntimeException("Failed to create trust-all SSLContext", e);
        }
    }

    /**
     * A TrustManager that accepts all certificates without validation.
     * WARNING: This disables certificate verification and should only be used
     * for testing or when connecting through a trusted load balancer.
     */
    static class TrustAllTrustManager implements X509TrustManager {
        @Override
        public void checkClientTrusted(X509Certificate[] chain, String authType) {}

        @Override
        public void checkServerTrusted(X509Certificate[] chain, String authType) {}

        @Override
        public X509Certificate[] getAcceptedIssuers() {
            return new X509Certificate[0];
        }
    }
}
