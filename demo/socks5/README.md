# SOCKS5 Demo

This demo shows how to use the `SOCKS5ClientAdapter` with `HttpClient` to make HTTP requests through a SOCKS5 proxy server.

## Building

```bash
dub build
```

## Usage

```bash
# Using named options
./ae-demo-socks5 --proxy-host HOST --proxy-port PORT --url URL

# Using positional arguments
./ae-demo-socks5 [PROXY_HOST [PROXY_PORT [URL]]]
```

### Options

- `--proxy-host HOST` - SOCKS5 proxy hostname (default: localhost)
- `--proxy-port PORT` - SOCKS5 proxy port (default: 1080)
- `--url URL` - Full URL to fetch (default: http://example.com/)

Or pass them as positional arguments in the same order.

## Testing

### Using SSH as a SOCKS5 Proxy

The easiest way to test this demo is to use SSH's built-in SOCKS5 proxy:

```bash
# In one terminal, create a SOCKS5 proxy on port 1080
ssh -D 1080 -N user@some-server

# In another terminal, run the demo
./ae-demo-socks5 --proxy-host localhost --proxy-port 1080 --url http://example.com/
```

### Using a Standalone SOCKS5 Proxy

You can also use standalone SOCKS5 proxies like:

- **Dante** (https://www.inet.no/dante/)
- **Shadowsocks** (https://shadowsocks.org/)
- **Tor** (SOCKS5 proxy on port 9050 by default)

Example with Tor:
```bash
./ae-demo-socks5 --proxy-host localhost --proxy-port 9050 --url http://example.com/

# Or with positional arguments:
./ae-demo-socks5 localhost 9050 http://example.com/
```

### Using a Custom SOCKS5 Proxy

```bash
# HTTP request
./ae-demo-socks5 127.178.114.11 10052 http://cy.md/ip.php

# HTTPS request (uses nested adapters: SSL over SOCKS5)
./ae-demo-socks5 127.178.114.11 10052 https://cy.md/ip.php
```

The demo automatically detects `https://` URLs and creates an `HttpsClient` instead of `HttpClient`, demonstrating **adapter nesting**: `SSLAdapter` wraps `SOCKS5ClientAdapter` which wraps `TcpConnection`.

## Debug Output

To see detailed SOCKS5 protocol messages, compile with the SOCKS5 debug flag:

```bash
dub build --build=debug --debug=SOCKS5
```

## Example Output

```
[SOCKS5Demo] Connecting to SOCKS5 proxy at localhost:1080
[SOCKS5Demo] Fetching URL: http://example.com/
[SOCKS5Demo] Sending request: GET /
[SOCKS5Demo] Got response: HTTP 200 OK
[SOCKS5Demo] Response headers:
[SOCKS5Demo]   Content-Type: text/html; charset=UTF-8
[SOCKS5Demo]   Content-Length: 1256
...

Response body:
----------------------------------------
<!doctype html>
<html>
<head>
    <title>Example Domain</title>
...
```

## Implementation Architecture

This demo demonstrates two key components:

### SOCKS5ClientAdapter

A `ConnectionAdapter` that implements the SOCKS5 protocol (RFC 1928):

- **Authentication**: No-auth method (0x00) - extensible for other methods
- **Commands**: CONNECT only
- **Address Types**: IPv4, IPv6, and domain names
- **State Machine**: Greeting → Request → Connected → Transparent data flow

The adapter follows the standard `ConnectionAdapter` pattern used throughout `ae`, making it composable with other adapters.

**Direct Usage:**

```d
// Create TCP connection to SOCKS5 proxy
auto proxyConn = new TcpConnection();

// Wrap with SOCKS5 adapter
auto socks = new SOCKS5ClientAdapter(proxyConn);
socks.setTarget("example.com", 80);  // Set destination

// Set up handlers
socks.handleConnect = { /* connected */ };
socks.handleReadData = (Data data) { /* received data */ };

// Connect to proxy (triggers SOCKS5 handshake)
proxyConn.connect("proxy.example.com", 1080);
```

Alternatively, you can pass the target in the constructor:

```d
auto socks = new SOCKS5ClientAdapter(proxyConn, "example.com", 80);
proxyConn.connect("proxy.example.com", 1080);
```

### SOCKS5Connector

A `Connector` implementation for use with `HttpClient`:

```d
auto connector = new SOCKS5Connector("proxy.example.com", 1080);
auto client = new HttpClient(30.seconds, connector);
client.request(request);
```

The connector:
1. Creates a TCP connection to the SOCKS5 proxy
2. Wraps it with `SOCKS5ClientAdapter` targeting the final destination
3. Returns the wrapped connection to `HttpClient`

This design allows `HttpClient` to transparently use SOCKS5 proxies without any knowledge of the SOCKS5 protocol.

## Composability and Adapter Nesting

The SOCKS5 adapter demonstrates **perfect composability** with other adapters. The demo supports both HTTP and HTTPS through SOCKS5, showing adapter nesting in action.

### HTTPS Through SOCKS5 (Nested Adapters)

When you use an `https://` URL, the demo creates this adapter stack:

```
Application
    ↓
TimeoutAdapter          # Handles connection timeouts
    ↓
SSLAdapter              # TLS encryption
    ↓
SOCKS5ClientAdapter     # SOCKS5 protocol tunneling
    ↓
TcpConnection           # Raw TCP to SOCKS5 proxy
```

**Code:**
```d
auto connector = new SOCKS5Connector(proxyHost, proxyPort);
auto client = new HttpsClient(30.seconds, connector);
```

**What happens:**
1. `SOCKS5Connector` creates `TcpConnection` → wraps with `SOCKS5ClientAdapter`
2. `HttpsClient.adaptConnection()` wraps it → `SSLAdapter(SOCKS5ClientAdapter(...))`
3. `HttpClient` constructor wraps it → `TimeoutAdapter(SSLAdapter(...))`

Result: **Three-layer nesting** that works seamlessly!

### Low-Level Approach

You can also compose adapters manually:

```d
auto tcpConn = new TcpConnection();
auto socks = new SOCKS5ClientAdapter(tcpConn);
socks.setTarget("example.com", 443);
auto ssl = new OpenSSLAdapter(sslContext, socks);
auto timeout = new TimeoutAdapter(ssl);

// All handlers are set on the outermost adapter
timeout.handleConnect = { /* ... */ };
```

### Why This Works

The `Connector` API's two-phase design enables this nesting:

1. **Phase 1** (`getConnection()`): Returns unwrapped connection for adapter layering
2. **Phase 2** (`connect(host, port)`): Initiates the actual connection

This allows `HttpsClient` to inject `SSLAdapter` between the `SOCKS5ClientAdapter` and `TimeoutAdapter` without knowing anything about SOCKS5.
