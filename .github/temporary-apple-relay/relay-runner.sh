#!/usr/bin/env bash
# Runner-side helper only. No key generation occurs here.
set -euo pipefail
relay_dir="$RUNNER_TEMP/motolink-apple-relay"
source_dir="$GITHUB_WORKSPACE/.github/temporary-apple-relay"

stop_relay() {
  for name in tunnel relay; do
    if [[ -f "$relay_dir/$name.pid" ]]; then
      pid="$(cat "$relay_dir/$name.pid")"
      if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
        kill -TERM "$pid" 2>/dev/null || true
      fi
    fi
  done
}

case "$1" in
  prepare)
    mkdir -p "$relay_dir"
    [[ "$(uname -m)" == x86_64 ]]
    # Validate a PUBLIC Ed25519 key before any dependency network requests.
    node - "$source_dir/public.pem" "$source_dir/relay-server.cjs" <<'NODE'
const fs = require('node:fs');
const crypto = require('node:crypto');
if (Number(process.versions.node.split('.')[0]) < 20) throw Error('Node 20+ required');
const pem = fs.readFileSync(process.argv[2], 'utf8').trim();
if (!/^-----BEGIN PUBLIC KEY-----\r?\n[A-Za-z0-9+/=\r\n]+\r?\n-----END PUBLIC KEY-----$/.test(pem))
  throw Error('Expected public PEM only; do not upload a private key');
if (crypto.createPublicKey(pem).asymmetricKeyType !== 'ed25519')
  throw Error('Expected an Ed25519 public key');
const source = fs.readFileSync(process.argv[3], 'utf8').replace(/\r\n/g, '\n');
const digest = crypto.createHash('sha256').update(source).digest('hex');
if (digest !== 'fb1ec112aca49098d41c43ddcb26d7ceb2353f47cda353ec193d7cc032024374') throw Error('Relay source differs from reviewed Apple allowlist');
console.log('Public Ed25519 key and unchanged relay source validated');
NODE
    npm install --prefix "$relay_dir" --no-save --ignore-scripts --no-audit --no-fund ws@8.22.0
    curl --fail --silent --show-error --location --retry 2 --max-time 90 \
      https://github.com/cloudflare/cloudflared/releases/download/2026.9.3/cloudflared-linux-amd64 \
      --output "$relay_dir/cloudflared"
    printf '%s  %s\n' \
      '77e26d8d900e0b8469f416239d14b5f296525fdf79fee6f511ef55609e3fbac2' \
      "$relay_dir/cloudflared" | sha256sum --check --status
    chmod 700 "$relay_dir/cloudflared"
    cp "$source_dir/relay-server.cjs" "$relay_dir/relay-server.cjs"
    node --check "$relay_dir/relay-server.cjs"
    ;;
  start)
    # Preserve original 20-minute server expiry; outer 18-minute limit leaves
    # room for setup/artifact upload/cleanup within the 20-minute job budget.
    trap stop_relay ERR
    timeout --signal=TERM --kill-after=5s 1080s \
      node "$relay_dir/relay-server.cjs" "$source_dir/public.pem" \
      >"$relay_dir/relay.log" 2>&1 &
    printf '%s\n' "$!" >"$relay_dir/relay.pid"
    date +%s >"$relay_dir/started-at.txt"
    ready=0
    for attempt in {1..20}; do
      kill -0 "$(cat "$relay_dir/relay.pid")"
      if [[ "$(curl --silent --max-time 1 --output /dev/null --write-out '%{http_code}' http://127.0.0.1:18742/ || true)" == 404 ]]; then
        ready=1
        break
      fi
      sleep 1
    done
    [[ "$ready" == 1 ]]
    timeout --signal=TERM --kill-after=5s 1080s \
      "$relay_dir/cloudflared" tunnel --no-autoupdate --url http://127.0.0.1:18742 \
      >"$relay_dir/tunnel.log" 2>&1 &
    printf '%s\n' "$!" >"$relay_dir/tunnel.pid"
    url=''
    for attempt in {1..45}; do
      kill -0 "$(cat "$relay_dir/relay.pid")"
      kill -0 "$(cat "$relay_dir/tunnel.pid")"
      url="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$relay_dir/tunnel.log" | head -n 1 || true)"
      [[ -n "$url" ]] && break
      sleep 2
    done
    [[ "$url" =~ ^https://[a-z0-9-]+\.trycloudflare\.com$ ]]
    printf '%s\n' "$url" >"$relay_dir/endpoint.txt"
    printf 'Public relay URL (requires local private key): %s\n' "$url"
    printf 'Temporary Apple relay: %s\n\nJob limit: 20 minutes; transport: at most 18 minutes.\n' \
      "$url" >>"$GITHUB_STEP_SUMMARY"
    ;;
  hold)
    end="$(( $(cat "$relay_dir/started-at.txt") + 1070 ))"
    while (( $(date +%s) < end )); do
      kill -0 "$(cat "$relay_dir/relay.pid")"
      kill -0 "$(cat "$relay_dir/tunnel.pid")"
      sleep 5
    done
    ;;
  stop)
    stop_relay
    ;;
  *)
    printf 'Usage: relay-runner.sh prepare|start|hold|stop\n' >&2
    exit 2
    ;;
esac
