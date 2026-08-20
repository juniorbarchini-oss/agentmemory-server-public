# 🧠 AgentMemory Server — Centralized AI Memory Hub in Docker

Official repository for deploying a centralized **`agentmemory`** Hub (v0.9.28 + Rust `iii` engine v0.11.2) using Docker Compose.

It enables a shared, persistent 24/7 memory hub for AI coding agents (such as Antigravity `agy`, Cursor, Claude Code, etc.) across multiple client machines connected via VPN (e.g. Tailscale) or local area networks, optionally accelerated by a central **Ollama** server.

---

## 🛠️ Prerequisites

- A Linux host with **Docker Engine** and **Docker Compose** installed (e.g. Ubuntu Server, Debian, or any homelab server OS).
- A running **Ollama** instance (local or remote).
- Network connectivity (VPN, local subnet, or Tailscale) between your client machines and the host server.

---

## 🏗️ Solution Architecture

The stack consists of 2 containerized services sharing the same internal network stack (`network_mode: "service:agentmemory"`):

1. **`agentmemory-server`**: Main Node.js daemon + Rust `iii-engine` (ports `3111` for REST API and `3112` for WebSockets).
2. **`agentmemory-nginx-viewer`**: An Nginx server (`nginx:alpine`) acting as a reverse proxy on port `3114` to expose the web visualization UI and WebSocket live streams securely.

```
                  ┌────────────────────────────────────────────────────────┐
                  │                 Central Memory Server                  │
                  │                                                        │
                  │   ┌────────────────────────────────────────────────┐   │
 Client Linux     │   │           Docker Stack (agentmemory)           │   │
(Antigravity) ───┼──>│  - REST API (Port 3111)                         │   │
   [VPN / LAN]    │   │  - Stream WS (Port 3112)                       │   │
                  │   │  - Web Viewer Nginx (Port 3114)                │   │
 Client macOS ────┼──>│  - Database: SQLite (./data/state_store.db)    │   │
(Antigravity)     │   └───────────────────────┬────────────────────────┘   │
                  │                           │                            │
                  │                           ▼                            │
                  │                     Ollama Server                      │
                  │              http://<ollama-server-ip>:11434           │
                  └────────────────────────────────────────────────────────┘
```

---

## 📄 Configuration Files

### 1. `docker-compose.yml`
```yaml
services:
  agentmemory:
    build: .
    container_name: agentmemory-server
    restart: always
    command: sh -c "node /usr/local/lib/node_modules/@agentmemory/agentmemory/dist/index.mjs & /root/.agentmemory/bin/iii --config /home/node/app/iii-config.yaml"
    environment:
      - OPENAI_API_KEY=ollama
      - OPENAI_BASE_URL=http://<ollama-server-ip>:11434/v1
      - OPENAI_MODEL=qwen2.5-coder:7b
      - AGENTMEMORY_AUTO_COMPRESS=true
      - GRAPH_EXTRACTION_ENABLED=true
      - CONSOLIDATION_ENABLED=true
      - AGENTMEMORY_INJECT_CONTEXT=true
      - AGENTMEMORY_URL=http://<server-ip>:3111
    volumes:
      - ./data:/home/node/data
      - ./agentmemory_cache:/root/.agentmemory
      - ./iii-config.yaml:/home/node/app/iii-config.yaml
    ports:
      - "3111:3111"
      - "3112:3112"
      - "3114:3114"

  nginx-viewer:
    image: nginx:alpine
    container_name: agentmemory-nginx-viewer
    restart: always
    network_mode: "service:agentmemory"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      - agentmemory
```

*(Note: Adjust `./data` and `./agentmemory_cache` paths to valid directories on your host server).*

### 2. `Dockerfile`
```dockerfile
FROM node:20-slim
RUN apt-get update && apt-get install -y curl tar ca-certificates procps && rm -rf /var/lib/apt/lists/*
RUN npm install -g @agentmemory/agentmemory@0.9.28
RUN mkdir -p /root/.agentmemory/bin && curl -fsSL "https://github.com/iii-hq/iii/releases/download/iii/v0.11.2/iii-x86_64-unknown-linux-gnu.tar.gz" | tar -xz -C /root/.agentmemory/bin && chmod +x /root/.agentmemory/bin/iii
WORKDIR /home/node
ENV HOME=/home/node
EXPOSE 3111 3112 3113
CMD ["/root/.agentmemory/bin/iii", "--config", "/home/node/app/iii-config.yaml"]
```

### 3. `iii-config.yaml`
```yaml
workers:
  - name: iii-http
    config:
      port: 3111
      host: 0.0.0.0
      default_timeout: 180000
      cors:
        allowed_origins: ["http://localhost:3111", "http://localhost:3113", "http://127.0.0.1:3111", "http://127.0.0.1:3113", "http://<server-ip>:3111", "http://<server-ip>:3113", "http://<server-ip>:3114"]
        allowed_methods: [GET, POST, PUT, DELETE, OPTIONS]
  - name: iii-state
    config:
      adapter:
        name: kv
        config:
          store_method: file_based
          file_path: /home/node/data/state_store.db
  - name: iii-queue
    config:
      adapter:
        name: builtin
  - name: iii-pubsub
    config:
      adapter:
        name: local
  - name: iii-cron
    config:
      adapter:
        name: kv
  - name: iii-stream
    config:
      port: 3112
      host: 0.0.0.0
      adapter:
        name: kv
        config:
          store_method: file_based
          file_path: /home/node/data/stream_store
  - name: iii-observability
    config:
      enabled: true
      service_name: agentmemory
      exporter: memory
      sampling_ratio: 0.1
      metrics_enabled: true
      logs_enabled: true
      logs_console_output: false
```

### 4. `nginx.conf`
```nginx
server {
    listen 3114;
    server_name <server-ip> localhost;

    location = / {
        return 302 /viewer?wsPort=3114;
    }

    location = /viewer {
        if ($arg_wsPort = "") {
            return 302 /viewer?wsPort=3114;
        }
        proxy_pass http://127.0.0.1:3113;
        proxy_set_header Host localhost:3113;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    location /stream/ {
        proxy_pass http://127.0.0.1:3112/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    location / {
        proxy_pass http://127.0.0.1:3113;
        proxy_set_header Host localhost:3113;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

---

## 🚀 Deployment Guide (Step-by-Step)

1. **Create the stack folder on your host server:**
   ```bash
   mkdir -p /opt/agentmemory-server
   cd /opt/agentmemory-server
   ```

2. **Save the configuration files (`docker-compose.yml`, `Dockerfile`, `iii-config.yaml`, `nginx.conf`) in that folder.**
   *(Make sure to replace `<server-ip>` and `<ollama-server-ip>` with your actual network settings).*

3. **Deploy with Docker Compose:**
   ```bash
   docker compose build --no-cache
   docker compose up -d
   ```

4. **Verify the server is running:**
   Check the REST API endpoint from your web browser or command line:
   ```bash
   curl http://<server-ip>:3111/agentmemory/health
   ```

---

## 💻 Client Agent Configurations

To connect your coding agents to the centralized server, configure their MCP or CLI configurations using the following structures.

### Client 1: Linux Client
In `~/.gemini/antigravity-cli/mcp_config.json` (or `~/.config/Cursor/mcpServer.json` depending on your agent):
```json
"mcpServers": {
  "agentmemory": {
    "command": "npx",
    "args": ["-y", "@agentmemory/mcp"],
    "env": {
      "AGENTMEMORY_URL": "http://<server-ip>:3111",
      "AGENTMEMORY_TOOLS": "all",
      "AGENTMEMORY_FORCE_PROXY": "1"
    }
  }
}
```

### Client 2: macOS Client
In `/Users/<your-mac-username>/.gemini/antigravity-cli/mcp_config.json` (or standard MCP configurations):
```json
"mcpServers": {
  "agentmemory": {
    "command": "<absolute-path-to-npx>",
    "args": ["-y", "@agentmemory/mcp"],
    "env": {
      "PATH": "<path-to-node-bin-directory>:/usr/local/bin:/usr/bin:/bin",
      "AGENTMEMORY_URL": "http://<server-ip>:3111",
      "AGENTMEMORY_TOOLS": "all",
      "AGENTMEMORY_FORCE_PROXY": "1"
    }
  }
}
```

---

## ⚠️ Troubleshooting (Common Error Log)

1. **Alpine Glibc Library Issue:**
   - *Error:* `not found` when executing `iii` in a `node:20-alpine` base image.
   - *Solution:* Use the Debian-based `node:20-slim` image instead.

2. **Loopback & Nginx DNS Gateway 502:**
   - *Error:* Nginx failing to resolve the internal port `3113` because it is exposed on loopback in a separate container.
   - *Solution:* Shared the network namespace using `network_mode: "service:agentmemory"`.

3. **WebSockets Stuck on "Connecting":**
   - *Error:* Nginx proxying `/stream/mem-live/viewer` requests to a path that isn't handled correctly.
   - *Solution:* Set `proxy_pass http://127.0.0.1:3112/;` with a trailing slash `/` to correctly route to the root of the WebSocket server.

4. **Homebrew Node Not Found on macOS (`env: node: No such file or directory`):**
   - *Error:* `npx` called by the parent app fails because the GUI environment doesn't load the Node path.
   - *Solution:* Add the absolute path to your Node/npm binary folder (e.g. `/opt/homebrew/bin` or standard Node installation folder) in the `PATH` variable inside the MCP configuration.

5. **Client Agents Disconnecting or Isolating Memory Context:**
   - *Error:* A client agent saves memory logs locally instead of writing to the central server, leading to fractured context.
   - *Solution:* Ensure that in the client's MCP configuration (`mcp_config.json`), `"AGENTMEMORY_URL"` points explicitly to the Tailscale/LAN IP of the central host (`http://<server-ip>:3111`) instead of `localhost`, and that `"AGENTMEMORY_FORCE_PROXY": "1"` is active.

---

## ⚖️ Credits & License

* **Original Creator:** This project is a specialized server-client deployment wrapper of the excellent [agentmemory](https://github.com/rohitg00/agentmemory) library developed by [Rohit Gupta (rohitg00)](https://github.com/rohitg00). We are extremely grateful for his work in creating a persistent memory layer for AI agents.
* **Server Adaptation & Docker Stack:** Packaged and adapted for multi-client centralized server architectures by the [juniorbarchini-oss](https://github.com/juniorbarchini-oss) organization.
* **License:** Distributed under the **MIT License**. See the [LICENSE](LICENSE) file for details.

---

## 🌟 Support & Donations

If you find this deployment stack useful, you can support the project in two ways:

1. **Star the Repository:** Click the ⭐ button at the top right of this page.
2. **Support on Ko-fi:** Buy me a coffee to support my work and maintenance of my open-source tools:

[![Support me on Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/hbarchini)
