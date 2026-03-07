#!/bin/bash
# Startup script for Moltbot in Cloudflare Sandbox
# This script:
# 1. Restores config from persistent backup directory (/data/moltbot) if available
#    (Worker cron is responsible for syncing that directory to/from R2)
# 2. Initializes moltbot config from template if missing
# 3. Updates config from environment variables
# 4. Starts the gateway

set -e

# Bail early if gateway already running
if pgrep -f "clawdbot gateway" > /dev/null 2>&1; then
    echo "Moltbot gateway is already running, exiting."
    exit 0
fi

# -----------------------------
# Canonical persistent paths
# -----------------------------
PERSIST_DIR="/data/moltbot"                 # Persistent state dir (synced to R2 by Worker cron)
WORKSPACE_DIR="/data/moltbot/workspace"     # Persistent clawdbot workspace (sessions/projects)
SKILLS_DIR="$WORKSPACE_DIR/skills"          # Skills must live under /data, not /root

# Clawdbot config locations (fine to keep under /root; config is small)
CONFIG_DIR="/root/.clawdbot"
CONFIG_FILE="$CONFIG_DIR/clawdbot.json"

TEMPLATE_DIR="/root/.clawdbot-templates"
TEMPLATE_FILE="$TEMPLATE_DIR/moltbot.json.template"

echo "Config directory:   $CONFIG_DIR"
echo "Persistent dir:     $PERSIST_DIR"
echo "Workspace directory:$WORKSPACE_DIR"
echo "Skills directory:   $SKILLS_DIR"

mkdir -p "$CONFIG_DIR"
mkdir -p "$PERSIST_DIR"
mkdir -p "$WORKSPACE_DIR"
mkdir -p "$SKILLS_DIR"

# -----------------------------
# One-time migration guard (if older images wrote to /root/clawd)
# -----------------------------
LEGACY_WORKDIR="/root/clawd"
if [ -d "$LEGACY_WORKDIR" ] && [ "$(ls -A "$LEGACY_WORKDIR" 2>/dev/null)" ] && [ ! "$(ls -A "$WORKSPACE_DIR" 2>/dev/null)" ]; then
    echo "Migrating legacy workspace from $LEGACY_WORKDIR -> $WORKSPACE_DIR (one-time)..."
    cp -a "$LEGACY_WORKDIR/." "$WORKSPACE_DIR/" || true
    echo "Legacy workspace migration complete."
fi

# ============================================================
# RESTORE CONFIG FROM PERSISTENT BACKUP AREA (synced from R2)
# ============================================================
# Expected backup structure:
#   $PERSIST_DIR/clawdbot/...
#   $PERSIST_DIR/skills/...
#   $PERSIST_DIR/.last-sync

should_restore_from_backup() {
    local BACKUP_SYNC_FILE="$PERSIST_DIR/.last-sync"
    local LOCAL_SYNC_FILE="$CONFIG_DIR/.last-sync"

    if [ ! -f "$BACKUP_SYNC_FILE" ]; then
        echo "No backup sync timestamp found, skipping restore"
        return 1
    fi

    if [ ! -f "$LOCAL_SYNC_FILE" ]; then
        echo "No local sync timestamp, will restore from backup"
        return 0
    fi

    BACKUP_TIME=$(cat "$BACKUP_SYNC_FILE" 2>/dev/null || echo "")
    LOCAL_TIME=$(cat "$LOCAL_SYNC_FILE" 2>/dev/null || echo "")

    echo "Backup last sync: $BACKUP_TIME"
    echo "Local last sync:  $LOCAL_TIME"

    BACKUP_EPOCH=$(date -d "$BACKUP_TIME" +%s 2>/dev/null || echo "0")
    LOCAL_EPOCH=$(date -d "$LOCAL_TIME" +%s 2>/dev/null || echo "0")

    if [ "$BACKUP_EPOCH" -gt "$LOCAL_EPOCH" ]; then
        echo "Backup is newer, will restore"
        return 0
    else
        echo "Local data is newer or same, skipping restore"
        return 1
    fi
}

if [ -f "$PERSIST_DIR/clawdbot/clawdbot.json" ]; then
    if should_restore_from_backup; then
        echo "Restoring config from $PERSIST_DIR/clawdbot -> $CONFIG_DIR ..."
        cp -a "$PERSIST_DIR/clawdbot/." "$CONFIG_DIR/"
        cp -f "$PERSIST_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
        echo "Restored config from backup."
    fi
elif [ -f "$PERSIST_DIR/clawdbot.json" ]; then
    # Legacy flat backup format
    if should_restore_from_backup; then
        echo "Restoring legacy config from $PERSIST_DIR -> $CONFIG_DIR ..."
        cp -a "$PERSIST_DIR/." "$CONFIG_DIR/"
        cp -f "$PERSIST_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
        echo "Restored legacy config from backup."
    fi
else
    echo "No persisted config backup found under $PERSIST_DIR (starting with local/template config)."
fi

# Restore skills from backup into persistent workspace skills directory
if [ -d "$PERSIST_DIR/skills" ] && [ "$(ls -A "$PERSIST_DIR/skills" 2>/dev/null)" ]; then
    if should_restore_from_backup; then
        echo "Restoring skills from $PERSIST_DIR/skills -> $SKILLS_DIR ..."
        mkdir -p "$SKILLS_DIR"
        cp -a "$PERSIST_DIR/skills/." "$SKILLS_DIR/"
        echo "Restored skills from backup."
    fi
fi

# If config still doesn't exist, initialize from template
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No existing config found, initializing from template..."
    if [ -f "$TEMPLATE_FILE" ]; then
        cp "$TEMPLATE_FILE" "$CONFIG_FILE"
    else
        # Minimal fallback config (IMPORTANT: workspace under /data)
        cat > "$CONFIG_FILE" << 'EOFCONFIG'
{
  "agents": {
    "defaults": {
      "workspace": "/data/moltbot/workspace"
    }
  },
  "gateway": {
    "port": 18789,
    "mode": "local"
  }
}
EOFCONFIG
    fi
else
    echo "Using existing config"
fi

# ============================================================
# UPDATE CONFIG FROM ENVIRONMENT VARIABLES
# ============================================================
node << EOFNODE
const fs = require('fs');

const configPath = '/root/.clawdbot/clawdbot.json';
const workspacePath = '/data/moltbot/workspace';

console.log('Updating config at:', configPath);
let config = {};

try {
  config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
  console.log('Starting with empty config');
}

// Ensure nested objects exist
config.agents = config.agents || {};
config.agents.defaults = config.agents.defaults || {};
config.agents.defaults.model = config.agents.defaults.model || {};
config.gateway = config.gateway || {};
config.channels = config.channels || {};

// FORCE workspace to persistent path (prevents regressions)
config.agents.defaults.workspace = workspacePath;

// Clean up any broken anthropic provider config from previous runs
if (config.models?.providers?.anthropic?.models) {
  const hasInvalidModels = config.models.providers.anthropic.models.some(m => !m.name);
  if (hasInvalidModels) {
    console.log('Removing broken anthropic provider config (missing model names)');
    delete config.models.providers.anthropic;
  }
}

// Gateway configuration
config.gateway.port = 18789;
config.gateway.mode = 'local';
config.gateway.trustedProxies = ['10.1.0.0'];

// Set gateway token if provided
if (process.env.CLAWDBOT_GATEWAY_TOKEN) {
  config.gateway.auth = config.gateway.auth || {};
  config.gateway.auth.token = process.env.CLAWDBOT_GATEWAY_TOKEN;
}

// Allow insecure auth for dev mode
if (process.env.CLAWDBOT_DEV_MODE === 'true') {
  config.gateway.controlUi = config.gateway.controlUi || {};
  config.gateway.controlUi.allowInsecureAuth = true;
}

// Telegram configuration
if (process.env.TELEGRAM_BOT_TOKEN) {
  config.channels.telegram = config.channels.telegram || {};
  config.channels.telegram.botToken = process.env.TELEGRAM_BOT_TOKEN;
  config.channels.telegram.enabled = true;
  config.channels.telegram.dm = config.channels.telegram.dm || {};
  config.channels.telegram.dmPolicy = process.env.TELEGRAM_DM_POLICY || 'pairing';
}

// Discord configuration
if (process.env.DISCORD_BOT_TOKEN) {
  config.channels.discord = config.channels.discord || {};
  config.channels.discord.token = process.env.DISCORD_BOT_TOKEN;
  config.channels.discord.enabled = true;
  config.channels.discord.dm = config.channels.discord.dm || {};
  config.channels.discord.dm.policy = process.env.DISCORD_DM_POLICY || 'pairing';
}

// Slack configuration
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
  config.channels.slack = config.channels.slack || {};
  config.channels.slack.botToken = process.env.SLACK_BOT_TOKEN;
  config.channels.slack.appToken = process.env.SLACK_APP_TOKEN;
  config.channels.slack.enabled = true;
}

// Base URL override (Cloudflare AI Gateway etc.)
const baseUrl = (process.env.AI_GATEWAY_BASE_URL || process.env.ANTHROPIC_BASE_URL || '').replace(/\/+$/, '');
const isOpenAI = baseUrl.endsWith('/openai');

if (isOpenAI) {
  console.log('Configuring OpenAI provider with base URL:', baseUrl);
  config.models = config.models || {};
  config.models.providers = config.models.providers || {};
  config.models.providers.openai = {
    baseUrl: baseUrl,
    api: 'openai-responses',
    models: [
      { id: 'gpt-5.2', name: 'GPT-5.2', contextWindow: 200000 },
      { id: 'gpt-5', name: 'GPT-5', contextWindow: 200000 },
      { id: 'gpt-4.5-preview', name: 'GPT-4.5 Preview', contextWindow: 128000 }
    ]
  };
  config.agents.defaults.models = config.agents.defaults.models || {};
  config.agents.defaults.models['openai/gpt-5.2'] = { alias: 'GPT-5.2' };
  config.agents.defaults.models['openai/gpt-5'] = { alias: 'GPT-5' };
  config.agents.defaults.models['openai/gpt-4.5-preview'] = { alias: 'GPT-4.5' };
  config.agents.defaults.model.primary = 'openai/gpt-5.2';
} else if (baseUrl) {
  console.log('Configuring Anthropic provider with base URL:', baseUrl);
  config.models = config.models || {};
  config.models.providers = config.models.providers || {};
  const providerConfig = {
    baseUrl: baseUrl,
    api: 'anthropic-messages',
    models: [
      { id: 'claude-opus-4-5-20251101', name: 'Claude Opus 4.5', contextWindow: 200000 },
      { id: 'claude-sonnet-4-5-20250929', name: 'Claude Sonnet 4.5', contextWindow: 200000 },
      { id: 'claude-haiku-4-5-20251001', name: 'Claude Haiku 4.5', contextWindow: 200000 }
    ]
  };
  if (process.env.ANTHROPIC_API_KEY) providerConfig.apiKey = process.env.ANTHROPIC_API_KEY;
  config.models.providers.anthropic = providerConfig;
  config.agents.defaults.models = config.agents.defaults.models || {};
  config.agents.defaults.models['anthropic/claude-opus-4-5-20251101'] = { alias: 'Opus 4.5' };
  config.agents.defaults.models['anthropic/claude-sonnet-4-5-20250929'] = { alias: 'Sonnet 4.5' };
  config.agents.defaults.models['anthropic/claude-haiku-4-5-20251001'] = { alias: 'Haiku 4.5' };
  config.agents.defaults.model.primary = 'anthropic/claude-opus-4-5-20251101';
} else {
  config.agents.defaults.model.primary = 'anthropic/claude-opus-4-5';
}
// DISABLE Cloudflare browser integration (temporary for stability)
delete config.browser;



// Remove any keys that are literally undefined (JSON.parse won't create undefined,
// but your code or other versions might attach it before writing)
for (const k of Object.keys(cfProfile)) {
  if (cfProfile[k] === undefined) delete cfProfile[k];
}

fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Configuration updated successfully');
console.log('Workspace forced to:', workspacePath);
EOFNODE

# ============================================================
# START GATEWAY
# ============================================================
echo "Starting Moltbot Gateway..."
echo "Gateway will be available on port 18789"

rm -f /tmp/clawdbot-gateway.lock 2>/dev/null || true
rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true

BIND_MODE="lan"
echo "Dev mode: ${CLAWDBOT_DEV_MODE:-false}, Bind mode: $BIND_MODE"

if [ -n "$CLAWDBOT_GATEWAY_TOKEN" ]; then
    echo "Starting gateway with token auth..."
    exec clawdbot gateway --port 18789 --verbose --allow-unconfigured --bind "$BIND_MODE" --token "$CLAWDBOT_GATEWAY_TOKEN"
else
    echo "Starting gateway with device pairing (no token)..."
    exec clawdbot gateway --port 18789 --verbose --allow-unconfigured --bind "$BIND_MODE"
fi
