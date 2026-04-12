// =============================================================================
// Cloudflare Worker — Streaming Reverse Proxy for Xray/VLESS (xHTTP transport)
// Hides the real VPS IP behind Cloudflare infrastructure.
// TSPU sees traffic to Cloudflare, not to your server.
//
// Uses TCP connect() API to reach raw IP backends directly,
// bypassing Cloudflare's CDN proxy (avoids Error 1003).
// Streams the response body instead of buffering (supports xHTTP).
// Uses HTTP/1.1 with an inline chunked-encoding decoder so that
// binary VLESS protocol data is never corrupted by chunk markers.
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

    // --- Diagnostic endpoint: /__health ---
    if (url.pathname === "/__health") {
      const start = Date.now();
      try {
        const socket = connect({ hostname: BACKEND, port: PORT });
        const writer = socket.writable.getWriter();
        // Send a minimal HTTP request to test the connection
        const testReq = `GET / HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n`;
        await writer.write(new TextEncoder().encode(testReq));
        writer.releaseLock();

        // Try to read with a timeout using AbortSignal
        const reader = socket.readable.getReader();
        const readResult = await Promise.race([
          reader.read(),
          new Promise(resolve =>
            setTimeout(() => resolve({ done: true, value: null, timeout: true }), 3000)
          ),
        ]);
        reader.releaseLock();
        try { socket.close(); } catch {}

        const elapsed = Date.now() - start;
        const gotData = readResult.value && readResult.value.length > 0;
        const timedOut = readResult.timeout || false;

        return new Response(JSON.stringify({
          status: "ok",
          backend: `${BACKEND}:${PORT}`,
          tcp_connect: "success",
          elapsed_ms: elapsed,
          got_response_data: gotData,
          read_timed_out: timedOut,
          data_preview: gotData
            ? new TextDecoder().decode(readResult.value.slice(0, 200))
            : null,
        }, null, 2), {
          headers: { "Content-Type": "application/json" },
        });
      } catch (err) {
        const elapsed = Date.now() - start;
        return new Response(JSON.stringify({
          status: "error",
          backend: `${BACKEND}:${PORT}`,
          tcp_connect: "failed",
          elapsed_ms: elapsed,
          error: err.message,
        }, null, 2), {
          status: 502,
          headers: { "Content-Type": "application/json" },
        });
      }
    }

    // Build the HTTP request line and headers to send over raw TCP
    const path = url.pathname + url.search;
    const method = request.method;

    const headerLines = [];
    // Use HTTP/1.1 so Go's net/http supports streaming responses
    // (required for xHTTP download channel). Go will use chunked
    // Transfer-Encoding for streaming bodies, but we decode it below
    // before forwarding to the client.
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

    // Tell backend to close the connection when done (no keep-alive)
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
      let isChunked = false;
      const parsedHeaderLines = rawHeaders.split("\r\n").slice(1);
      for (const line of parsedHeaderLines) {
        const colonIdx = line.indexOf(":");
        if (colonIdx > 0) {
          const hName = line.substring(0, colonIdx).trim();
          const hValue = line.substring(colonIdx + 1).trim();
          const lName = hName.toLowerCase();
          // Detect chunked encoding — Go's net/http uses this for
          // streaming HTTP/1.1 responses. We must decode it so raw
          // binary VLESS data passes through without chunk markers.
          if (lName === "transfer-encoding" && hValue.toLowerCase().includes("chunked")) {
            isChunked = true;
            continue;
          }
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

      // --- Chunked decoding helper ---
      // Go's net/http uses Transfer-Encoding: chunked for streaming
      // HTTP/1.1 responses. Decode chunk framing so raw binary VLESS
      // data passes through without hex size markers corrupting it.
      const pumpChunked = async (initialData) => {
        let buf = initialData;
        const readMore = async () => {
          const { done, value } = await reader.read();
          if (done) return false;
          const merged = new Uint8Array(buf.length + value.length);
          merged.set(buf);
          merged.set(value, buf.length);
          buf = merged;
          return true;
        };
        while (true) {
          // Find chunk size line (hex digits followed by \r\n)
          let crlfIdx = -1;
          while (crlfIdx === -1) {
            for (let i = 0; i < buf.length - 1; i++) {
              if (buf[i] === 13 && buf[i + 1] === 10) { crlfIdx = i; break; }
            }
            if (crlfIdx === -1) {
              if (!(await readMore())) return;
            }
          }
          const sizeLine = new TextDecoder().decode(buf.slice(0, crlfIdx)).trim();
          const chunkSize = parseInt(sizeLine, 16);
          if (isNaN(chunkSize) || chunkSize === 0) return; // end of chunks
          buf = buf.slice(crlfIdx + 2);
          // Read chunk data
          while (buf.length < chunkSize + 2) { // +2 for trailing \r\n
            if (!(await readMore())) {
              if (buf.length > 0) await bodyWriter.write(buf);
              return;
            }
          }
          await bodyWriter.write(buf.slice(0, chunkSize));
          buf = buf.slice(chunkSize + 2); // skip trailing \r\n
        }
      };

      // Pump data from TCP socket to response stream in background
      const pump = async () => {
        try {
          if (isChunked) {
            // Decode chunked transfer encoding
            await pumpChunked(leftover);
          } else {
            // Raw streaming (expected path with HTTP/1.0)
            if (leftover.length > 0) {
              await bodyWriter.write(leftover);
            }
            while (true) {
              const { done, value } = await reader.read();
              if (done) break;
              await bodyWriter.write(value);
            }
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
