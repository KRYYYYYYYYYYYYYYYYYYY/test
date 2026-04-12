// =============================================================================
// Cloudflare Worker — Reverse Proxy for Xray/VLESS
// Hides the real VPS IP behind Cloudflare infrastructure.
// TSPU sees traffic to Cloudflare, not to your server.
//
// Deployment:
//   1. Go to https://dash.cloudflare.com → Workers & Pages → Create
//   2. Paste this script
//   3. Set environment variable: BACKEND_HOST = your-server-domain.com
//   4. (Optional) Add a custom domain in Worker settings
//   5. Update your Xray client config to point to the Worker domain
// =============================================================================

export default {
  async fetch(request, env) {
    // Backend server — set via Cloudflare Worker environment variable
    // In Cloudflare dashboard: Settings → Variables → BACKEND_HOST
    const BACKEND = env.BACKEND_HOST;

    if (!BACKEND) {
      return new Response(
        "Worker misconfigured: BACKEND_HOST environment variable is not set.",
        { status: 500 }
      );
    }

    const url = new URL(request.url);

    // Rewrite the request to point to the real backend
    url.hostname = BACKEND;
    url.port = "443";
    url.protocol = "https:";

    // Build a new request with the original headers
    const modifiedRequest = new Request(url.toString(), {
      method: request.method,
      headers: request.headers,
      body: request.body,
      redirect: "follow",
    });

    // Forward the Host header as the backend domain
    // This is critical for TLS SNI and virtual hosting
    modifiedRequest.headers.set("Host", BACKEND);

    try {
      const response = await fetch(modifiedRequest);

      // Return the response with original headers
      const modifiedResponse = new Response(response.body, {
        status: response.status,
        statusText: response.statusText,
        headers: response.headers,
      });

      return modifiedResponse;
    } catch (err) {
      return new Response(`Proxy error: ${err.message}`, { status: 502 });
    }
  },
};
