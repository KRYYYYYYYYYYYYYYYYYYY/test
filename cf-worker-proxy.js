// =============================================================================
// Cloudflare Worker — Streaming Reverse Proxy for Xray/VLESS (xHTTP transport)
// Hides the real VPS IP behind Cloudflare infrastructure.
// TSPU sees traffic to Cloudflare, not to your server.
//
// Uses TCP connect() API to reach raw IP backends directly,
// bypassing Cloudflare's CDN proxy (avoids Error 1003).
// Streams the response body instead of buffering (supports xHTTP).
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

    const headerLines = [];
    headerLines.push(`${method} ${path} HTTP/1.1`);
    headerLines.push(`Host: ${url.hostname}`);

    // Forward relevant headers from the original request
    for (const [key, value] of request.headers) {
      const lk = key.toLowerCase();
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

      // --- Streaming response: parse headers, then stream body ---
      const reader = socket.readable.getReader();
      const decoder = new TextDecoder();

      // Accumulate data until we find the header/body boundary (\r\n\r\n)
      let headerBuf = new Uint8Array(0);
      let headerEndIdx = -1;

      while (headerEndIdx === -1) {
        const { done, value } = await reader.read();
        if (done) {
          return new Response("Backend closed connection before headers", { status: 502 });
        }

        // Append new data to header buffer
        const merged = new Uint8Array(headerBuf.length + value.length);
        merged.set(headerBuf);
        merged.set(value, headerBuf.length);
        headerBuf = merged;

        // Search for \r\n\r\n in the accumulated buffer
        for (let i = Math.max(0, headerBuf.length - value.length - 3);
             i < headerBuf.length - 3; i++) {
          if (headerBuf[i] === 13 && headerBuf[i+1] === 10 &&
              headerBuf[i+2] === 13 && headerBuf[i+3] === 10) {
            headerEndIdx = i;
            break;
          }
        }
      }

      // Parse HTTP status and headers
      const rawHeaders = decoder.decode(headerBuf.slice(0, headerEndIdx));
      const bodyStart = headerEndIdx + 4;

      const statusLine = rawHeaders.split("\r\n")[0];
      const statusMatch = statusLine.match(/HTTP\/\d\.?\d?\s+(\d+)/);
      const statusCode = statusMatch ? parseInt(statusMatch[1], 10) : 200;

      const respHeaders = new Headers();
      const parsedHeaderLines = rawHeaders.split("\r\n").slice(1);
      for (const line of parsedHeaderLines) {
        const colonIdx = line.indexOf(":");
        if (colonIdx > 0) {
          const hName = line.substring(0, colonIdx).trim();
          const hValue = line.substring(colonIdx + 1).trim();
          const lName = hName.toLowerCase();
          // Skip hop-by-hop headers
          if (lName === "transfer-encoding" || lName === "connection") continue;
          respHeaders.append(hName, hValue);
        }
      }

      // If no body expected, return immediately
      if (method === "HEAD" || statusCode === 204 || statusCode === 304) {
        reader.releaseLock();
        return new Response(null, { status: statusCode, headers: respHeaders });
      }

      // Leftover body data from the header read
      const leftover = headerBuf.slice(bodyStart);

      // Create a streaming response body using TransformStream
      const { readable, writable } = new TransformStream();
      const bodyWriter = writable.getWriter();

      // Pump data from TCP socket to response stream in background
      const pump = async () => {
        try {
          // Write leftover bytes first
          if (leftover.length > 0) {
            await bodyWriter.write(leftover);
          }
          // Stream remaining data from TCP socket
          while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            await bodyWriter.write(value);
          }
        } catch (e) {
          // Connection closed or errored — just finish
        } finally {
          try { await bodyWriter.close(); } catch {}
          try { reader.releaseLock(); } catch {}
        }
      };

      // Start pumping without awaiting (runs in background)
      pump();

      // Return streaming response immediately
      return new Response(readable, {
        status: statusCode,
        headers: respHeaders,
      });
    } catch (err) {
      return new Response(`Proxy error: ${err.message}`, { status: 502 });
    }
  },
};
