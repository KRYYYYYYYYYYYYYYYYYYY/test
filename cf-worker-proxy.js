// =============================================================================
// Cloudflare Worker — Reverse Proxy for Xray/VLESS (xHTTP transport)
// Hides the real VPS IP behind Cloudflare infrastructure.
// TSPU sees traffic to Cloudflare, not to your server.
//
// Uses TCP connect() API to reach raw IP backends directly,
// bypassing Cloudflare's CDN proxy (avoids Error 1003).
//
// Environment variables:
//   BACKEND_HOST  — VPS IP or domain (e.g., 87.242.119.137)
//   BACKEND_PORT  — backend port (default: 8443)
// =============================================================================

import { connect } from "cloudflare:sockets";

export default {
  async fetch(request, env) {
    const BACKEND = env.BACKEND_HOST;
    if (!BACKEND) {
      return new Response(
        "Worker misconfigured: BACKEND_HOST environment variable is not set.",
        { status: 500 }
      );
    }

    const PORT = parseInt(env.BACKEND_PORT || "8443", 10);
    const url = new URL(request.url);

    // Build the HTTP request line and headers to send over raw TCP
    const path = url.pathname + url.search;
    const method = request.method;

    // Collect headers — use Worker hostname as Host (backend doesn't care)
    const headerLines = [];
    headerLines.push(`${method} ${path} HTTP/1.1`);
    headerLines.push(`Host: ${url.hostname}`);

    // Forward relevant headers from the original request
    for (const [key, value] of request.headers) {
      const lk = key.toLowerCase();
      // Skip hop-by-hop headers and host (already set)
      if (lk === "host" || lk === "connection" || lk === "keep-alive" ||
          lk === "transfer-encoding" || lk === "upgrade" ||
          lk === "proxy-connection") {
        continue;
      }
      headerLines.push(`${key}: ${value}`);
    }

    // Read body if present
    let bodyBytes = null;
    if (method !== "GET" && method !== "HEAD" && request.body) {
      bodyBytes = new Uint8Array(await request.arrayBuffer());
      headerLines.push(`Content-Length: ${bodyBytes.length}`);
    } else if (method === "POST" || method === "PUT" || method === "PATCH") {
      headerLines.push("Content-Length: 0");
    }

    headerLines.push("Connection: close");
    headerLines.push(""); // blank line ends headers
    headerLines.push("");

    const headerString = headerLines.join("\r\n");
    const encoder = new TextEncoder();

    try {
      // Open raw TCP connection to backend — bypasses CF CDN proxy
      const socket = connect({ hostname: BACKEND, port: PORT });
      const writer = socket.writable.getWriter();

      // Send HTTP request
      await writer.write(encoder.encode(headerString));
      if (bodyBytes && bodyBytes.length > 0) {
        await writer.write(bodyBytes);
      }
      writer.releaseLock();

      // Read the full HTTP response from the TCP stream
      const reader = socket.readable.getReader();
      const chunks = [];
      let totalLength = 0;

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        chunks.push(value);
        totalLength += value.length;
        if (totalLength > 50 * 1024 * 1024) break; // 50MB safety limit
      }

      if (totalLength === 0) {
        return new Response("Backend returned empty response", { status: 502 });
      }

      // Combine chunks into single buffer
      const fullResponse = new Uint8Array(totalLength);
      let offset = 0;
      for (const chunk of chunks) {
        fullResponse.set(chunk, offset);
        offset += chunk.length;
      }

      // Find header/body boundary (\r\n\r\n)
      let headerEnd = -1;
      for (let i = 0; i < totalLength - 3; i++) {
        if (fullResponse[i] === 13 && fullResponse[i+1] === 10 &&
            fullResponse[i+2] === 13 && fullResponse[i+3] === 10) {
          headerEnd = i;
          break;
        }
      }

      if (headerEnd === -1) {
        return new Response("Backend returned invalid HTTP response", { status: 502 });
      }

      // Parse status line and headers (text-safe, ASCII only)
      const decoder = new TextDecoder();
      const rawHeaders = decoder.decode(fullResponse.slice(0, headerEnd));
      const bodyStartIdx = headerEnd + 4;

      const statusLine = rawHeaders.split("\r\n")[0];
      const statusMatch = statusLine.match(/HTTP\/\d\.?\d?\s+(\d+)/);
      const statusCode = statusMatch ? parseInt(statusMatch[1], 10) : 200;

      const respHeaders = new Headers();
      const parsedHeaders = rawHeaders.split("\r\n").slice(1);
      for (const line of parsedHeaders) {
        const colonIdx = line.indexOf(":");
        if (colonIdx > 0) {
          const hName = line.substring(0, colonIdx).trim();
          const hValue = line.substring(colonIdx + 1).trim();
          const lName = hName.toLowerCase();
          if (lName === "transfer-encoding" || lName === "connection") continue;
          respHeaders.append(hName, hValue);
        }
      }

      // Return body as raw bytes (preserves binary data)
      const responseBody = fullResponse.slice(bodyStartIdx);

      return new Response(responseBody, {
        status: statusCode,
        headers: respHeaders,
      });
    } catch (err) {
      return new Response(`Proxy error: ${err.message}`, { status: 502 });
    }
  },
};
