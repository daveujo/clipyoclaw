FROM node:lts-trixie-slim

WORKDIR /build

RUN apt-get update && apt-get install -y \
    curl \
    postgresql-client \
    postgresql \
    postgresql-contrib \
    python3 \
    python3-pip \
    git \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/run/postgresql && chown postgres:postgres /var/run/postgresql

RUN npm init -y && npm install express@4 cors morgan

# Install OpenCode globally for NVIDIA/OpenCode support only.
RUN npm install -g opencode-ai

WORKDIR /app

# Clone the app repository and install dependencies.
RUN git clone --depth=1 https://github.com/paperclipai/paperclip.git .
RUN corepack enable
RUN pnpm install --ignore-scripts
RUN pnpm --filter @paperclipai/plugin-sdk build
RUN pnpm --filter @paperclipai/server build
RUN pnpm --filter @paperclipai/ui build

WORKDIR /build

# Install runtime helpers and keep only what the app actually uses.
RUN pip install --no-cache-dir --break-system-packages huggingface_hub PyYAML

COPY start.sh /app/
COPY health-server.js /app/
COPY paperclip-sync.py /app/
COPY cloudflare-proxy.js /app/
COPY cloudflare-proxy-setup.py /app/
COPY cloudflare-keepalive-setup.py /app/

RUN chmod +x /app/start.sh /app/cloudflare-keepalive-setup.py

RUN useradd -m -u 1001 -s /bin/bash paperclip && \
    mkdir -p /paperclip /var/lib/postgresql/data && \
    chown -R postgres:postgres /var/lib/postgresql/data && \
    chown paperclip:paperclip /paperclip
