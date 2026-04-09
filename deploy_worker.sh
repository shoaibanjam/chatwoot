#!/bin/bash
# Real deploy steps — run AFTER repo is updated (git pull/reset). Do not `git pull`
# from this file: replacing deploy.sh while `bash deploy.sh` runs leaves bash executing
# the old script from memory, so rbenv/PATH never apply.

set -e
export RACK_TIMEOUT_SERVICE_TIMEOUT=120

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# Non-interactive SSH: mimic login PATH (rbenv, nvm, etc.)
if [[ -f "$HOME/.bash_profile" ]]; then
  # shellcheck source=/dev/null
  source "$HOME/.bash_profile"
elif [[ -f "$HOME/.profile" ]]; then
  # shellcheck source=/dev/null
  source "$HOME/.profile"
fi

if [[ -x "$HOME/.rbenv/bin/rbenv" ]]; then
  export PATH="$HOME/.rbenv/bin:$PATH"
  eval "$(rbenv init - bash)"
elif command -v rbenv >/dev/null 2>&1; then
  eval "$(rbenv init - bash)"
fi

export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if [[ -s "$NVM_DIR/nvm.sh" ]]; then
  # shellcheck source=/dev/null
  source "$NVM_DIR/nvm.sh"
fi

if [[ -f "$HOME/.asdf/asdf.sh" ]]; then
  # shellcheck source=/dev/null
  source "$HOME/.asdf/asdf.sh"
fi

if [[ -s "$HOME/.rvm/scripts/rvm" ]]; then
  # shellcheck source=/dev/null
  source "$HOME/.rvm/scripts/rvm"
fi

if ! command -v bundle >/dev/null 2>&1; then
  echo "ERROR: bundle not found after loading shell env. PATH=$PATH" >&2
  exit 127
fi

if ! command -v pnpm >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
  echo "ERROR: pnpm or node not found after loading shell env. PATH=$PATH" >&2
  exit 127
fi

echo "📦 Installing dependencies..."
bundle install
pnpm install

echo "🔨 Precompiling assets..."
bundle exec rake assets:precompile

# Match exact app name only: `grep chatwoot` wrongly matched chatwoot-backend /
# chatwoot-frontend / chatwoot-worker, then `pm2 stop chatwoot` failed (no such app)
# and set -e aborted the deploy before `pm2 start`.
echo "🧹 Stopping legacy PM2 apps from ecosystem.config.js if present..."
for app in chatwoot-backend chatwoot-frontend chatwoot-worker; do
  if pm2 describe "$app" >/dev/null 2>&1; then
    echo "   Stopping $app"
    pm2 stop "$app"
    pm2 delete "$app"
  fi
done

if pm2 describe chatwoot >/dev/null 2>&1; then
  echo "🛑 Stopping existing PM2 process chatwoot..."
  pm2 stop chatwoot
  pm2 delete chatwoot
else
  echo "ℹ️  No existing PM2 app named chatwoot, skipping stop/delete..."
fi

echo "▶️  Starting server with PM2..."
# pnpm is a Node script; --interpreter bash made bash execute it as shell →
# "syntax error near unexpected token" in chatwoot-error.log and errored restarts.
PNPM_BIN="$(command -v pnpm)"
NODE_BIN="$(command -v node)"
pm2 start "$PNPM_BIN" --name chatwoot --cwd "$REPO_ROOT" --interpreter "$NODE_BIN" -- start:production

echo "💾 Saving PM2 configuration..."
pm2 save

echo "✅ Deployment complete!"
echo "📊 Check status with: pm2 status"
echo "📝 View logs with: pm2 logs chatwoot"
