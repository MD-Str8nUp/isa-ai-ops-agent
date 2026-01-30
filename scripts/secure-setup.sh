#!/bin/bash
# ISA AI Ops Agent — Secure Setup Script
# Deploys a security-hardened AI Ops Agent instance
# Usage: curl -fsSL https://raw.githubusercontent.com/MD-Str8nUp/isa-ai-ops-agent/main/scripts/secure-setup.sh | bash

set -euo pipefail

echo "╔══════════════════════════════════════════╗"
echo "║   ISA AI Ops Agent — Secure Setup        ║"
echo "║   Security-hardened deployment            ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[ISA]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ═══════════════════════════════════════════
# 1. SYSTEM CHECKS
# ═══════════════════════════════════════════

log "Checking system requirements..."

# Check OS
if [ ! -f /etc/os-release ]; then
    error "Unsupported OS. Requires Ubuntu 22.04+ or Debian 12+"
fi

# Check root
if [ "$EUID" -ne 0 ]; then
    error "Must run as root. Use: sudo bash setup.sh"
fi

# Check Node.js
if ! command -v node &> /dev/null; then
    log "Installing Node.js 22..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
fi

NODE_VERSION=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
if [ "$NODE_VERSION" -lt 20 ]; then
    error "Node.js 20+ required. Found: $(node -v)"
fi

log "✅ System checks passed"

# ═══════════════════════════════════════════
# 2. GENERATE SECURE CREDENTIALS
# ═══════════════════════════════════════════

log "Generating secure credentials..."

# Random port (40000-60000)
AGENT_PORT=$(shuf -i 40000-60000 -n 1)

# Strong password (32 chars)
AGENT_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)

# Auth token (48 chars hex)
AGENT_TOKEN=$(openssl rand -hex 24)

# Gateway secret
GATEWAY_SECRET=$(openssl rand -hex 16)

log "✅ Credentials generated"
log "   Port: $AGENT_PORT"
log "   Password: $AGENT_PASSWORD"

# ═══════════════════════════════════════════
# 3. INSTALL & CONFIGURE
# ═══════════════════════════════════════════

log "Installing ISA AI Ops Agent..."

# Install globally
npm install -g clawdbot@latest 2>/dev/null || npm install -g openclaw@latest 2>/dev/null

# Create workspace
WORKSPACE="/root/workspace"
mkdir -p "$WORKSPACE"

# Create secure config
CONFIG_DIR="/root/.clawdbot"
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

cat > "$CONFIG_DIR/clawdbot.json" << EOF
{
  "agents": {
    "defaults": {
      "workspace": "$WORKSPACE",
      "compaction": {
        "mode": "safeguard"
      },
      "maxConcurrent": 4,
      "subagents": {
        "maxConcurrent": 8
      }
    },
    "list": [
      {
        "id": "main",
        "default": true,
        "workspace": "$WORKSPACE",
        "heartbeat": {
          "every": "30m"
        },
        "identity": {
          "name": "AI Ops Agent"
        }
      }
    ]
  },
  "gateway": {
    "port": $AGENT_PORT,
    "mode": "local",
    "bind": "lan",
    "controlUi": {
      "enabled": true,
      "allowInsecureAuth": false
    },
    "auth": {
      "mode": "token",
      "token": "$AGENT_TOKEN",
      "password": "$AGENT_PASSWORD"
    },
    "trustedProxies": ["127.0.0.1"]
  },
  "messages": {
    "ackReactionScope": "group-mentions"
  },
  "commands": {
    "native": "auto",
    "nativeSkills": "auto"
  }
}
EOF

chmod 600 "$CONFIG_DIR/clawdbot.json"

log "✅ Agent installed and configured"

# ═══════════════════════════════════════════
# 4. FIREWALL SETUP
# ═══════════════════════════════════════════

log "Configuring firewall..."

if command -v ufw &> /dev/null; then
    ufw --force enable
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh
    ufw allow 80/tcp
    ufw allow 443/tcp
    # Agent port only accessible via reverse proxy (localhost)
    # ufw allow $AGENT_PORT/tcp  # Intentionally NOT opened
    log "✅ Firewall configured (80/443 only)"
else
    warn "ufw not found. Install with: apt-get install ufw"
fi

# ═══════════════════════════════════════════
# 5. CADDY REVERSE PROXY (if domain provided)
# ═══════════════════════════════════════════

read -p "Enter domain (or press Enter to skip SSL): " DOMAIN

if [ -n "$DOMAIN" ]; then
    log "Setting up Caddy reverse proxy..."
    
    if ! command -v caddy &> /dev/null; then
        apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
        apt-get update
        apt-get install -y caddy
    fi
    
    cat > /etc/caddy/Caddyfile << EOF
$DOMAIN {
    reverse_proxy localhost:$AGENT_PORT
    
    # Rate limiting
    @ratelimit {
        path /api/*
    }
    
    # Security headers
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Referrer-Policy "strict-origin-when-cross-origin"
    }
    
    # Logging
    log {
        output file /var/log/caddy/access.log
    }
}
EOF
    
    systemctl restart caddy
    log "✅ Caddy configured with SSL for $DOMAIN"
fi

# ═══════════════════════════════════════════
# 6. SYSTEMD SERVICE
# ═══════════════════════════════════════════

log "Creating systemd service..."

cat > /etc/systemd/system/isa-agent.service << EOF
[Unit]
Description=ISA AI Ops Agent
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$WORKSPACE
ExecStart=$(which clawdbot || which openclaw) gateway start --foreground
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

# Security hardening
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=$WORKSPACE $CONFIG_DIR /tmp
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable isa-agent
systemctl start isa-agent

log "✅ Service created and started"

# ═══════════════════════════════════════════
# 7. SAVE CREDENTIALS
# ═══════════════════════════════════════════

CREDS_FILE="$CONFIG_DIR/credentials.txt"
cat > "$CREDS_FILE" << EOF
═══════════════════════════════════════════
ISA AI Ops Agent — Deployment Credentials
Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
═══════════════════════════════════════════

Port:     $AGENT_PORT
Password: $AGENT_PASSWORD
Token:    $AGENT_TOKEN
Domain:   ${DOMAIN:-"(none — use IP:$AGENT_PORT)"}

Control Panel: ${DOMAIN:+https://$DOMAIN}${DOMAIN:-http://$(hostname -I | awk '{print $1}'):$AGENT_PORT}

KEEP THIS FILE SECURE. Delete after saving credentials.
═══════════════════════════════════════════
EOF

chmod 600 "$CREDS_FILE"

# ═══════════════════════════════════════════
# DONE
# ═══════════════════════════════════════════

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   ✅ ISA AI Ops Agent Deployed!          ║"
echo "╠══════════════════════════════════════════╣"
echo "║                                          ║"
echo "║   Port:     $AGENT_PORT                      ║"
echo "║   Password: (see credentials.txt)        ║"
echo "║                                          ║"
if [ -n "$DOMAIN" ]; then
echo "║   URL: https://$DOMAIN                   ║"
fi
echo "║                                          ║"
echo "║   Credentials: $CREDS_FILE               ║"
echo "║                                          ║"
echo "║   Next: Run 'clawdbot onboard' to        ║"
echo "║   configure channels and AI provider.     ║"
echo "║                                          ║"
echo "╚══════════════════════════════════════════╝"
