FROM node:20-slim
RUN apt-get update && apt-get install -y curl tar ca-certificates procps && rm -rf /var/lib/apt/lists/*
RUN npm install -g @agentmemory/agentmemory@0.9.28
RUN mkdir -p /root/.agentmemory/bin && curl -fsSL "https://github.com/iii-hq/iii/releases/download/iii/v0.11.2/iii-x86_64-unknown-linux-gnu.tar.gz" | tar -xz -C /root/.agentmemory/bin && chmod +x /root/.agentmemory/bin/iii
WORKDIR /home/node
ENV HOME=/home/node
EXPOSE 3111 3112 3113
CMD ["/root/.agentmemory/bin/iii", "--config", "/home/node/iii-config.yaml"]
