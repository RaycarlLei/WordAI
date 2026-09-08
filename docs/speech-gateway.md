# Optional speech gateway

No server is bundled or configured. An operator may implement `POST /tts` relative to the configured HTTPS base path.

- Request: UTF-8 text, `Content-Type: text/plain; charset=utf-8`.
- Response: status 200 and valid MP3 bytes, at most 900,000 bytes. Redirects are rejected.
- One ten-second deadline covers connection, response headers and the complete
  body. Receiving more chunks does not extend it. Timeout aborts the request,
  cancels body reading and closes the client dedicated to that request.
- Failed/invalid responses fall back to system speech where available. Successful audio is cached locally.
- The client sends no provider credentials. Keep provider keys on the server, outside source control.
- Operators must add input limits, rate limits, abuse prevention and appropriate access control; this minimal client does not implement user authentication. Do not expose an unrestricted paid provider proxy.
- Configure only infrastructure you control. Use of the gateway sends the requested speech text to that operator.
