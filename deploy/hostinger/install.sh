#!/bin/sh
# OpenMausBot on a Hostinger KVM VPS: size the server, install Docker and
# OpenMausBot with HTTPS on your domain, then set engine keys and make one bot
# per engine that is ready.
#
#   curl -fsSL https://raw.githubusercontent.com/DansiDanutz/MausBot-ro/main/deploy/hostinger/install.sh | sudo sh -s -- --domain maus.example.com
#   ... --check --domain maus.example.com    only check the server; changes nothing
#   ... --bots-only                          engine keys and bots on an existing install
#
# It calls the project's own deploy/install.sh for the server (checks, Docker,
# compose, Caddy, sandbox, first admin link) and adds what a Hostinger box needs
# around it: an early size check with the plan to pick, Docker install by
# default, the host firewall, engine keys, and the bots.
set -eu

RAW_BASE="${OMB_HOSTINGER_RAW_BASE:-https://raw.githubusercontent.com/DansiDanutz/MausBot-ro/main}"
INSTALL_DIR="${OMB_INSTALL_DIR:-/opt/openmausbot}"
KEYS_FILE="${OMB_HOSTINGER_KEYS:-/etc/mausbot/hostinger.env}"
PAIR_FILE="${OMB_HOSTINGER_PAIR_FILE:-/root/mausbot-pairing.txt}"

MODE=install
DOMAIN=""
EMAIL=""
BOTS=yes
INSTALL_DOCKER=yes
UPSTREAM_ARGS=""

say() { printf '%s\n' "$*"; }
ok() { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*"; }
fail() { printf '\n%s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: install.sh --domain HOST [options]

  --domain HOST        the name people open, with an A record already pointing here
  --email ADDRESS      the first admin's email, to sign in with an emailed code
  --keys-file FILE     engine keys to apply (default /etc/mausbot/hostinger.env)
  --no-bots            install the server and keys, but make no bots
  --no-sandbox         skip the bots' sandbox (only on a server you alone use)
  --no-install-docker  never install Docker; fail if it is missing
  --check              check the server only; changes nothing
  --bots-only          skip the server install; apply keys and make bots
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --domain=*) DOMAIN="${1#--domain=}"; shift ;;
    --email) EMAIL="${2:-}"; shift 2 ;;
    --email=*) EMAIL="${1#--email=}"; shift ;;
    --keys-file) KEYS_FILE="${2:-}"; shift 2 ;;
    --keys-file=*) KEYS_FILE="${1#--keys-file=}"; shift ;;
    --no-bots) BOTS=no; shift ;;
    --no-sandbox) UPSTREAM_ARGS="$UPSTREAM_ARGS --no-sandbox"; shift ;;
    --no-install-docker) INSTALL_DOCKER=no; shift ;;
    --check) MODE=check; shift ;;
    --bots-only) MODE=bots; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1. Run with --help." ;;
  esac
done

[ "$(id -u)" = 0 ] || fail "Run this as root: prefix it with sudo."

here=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)

free_gb() {
  path=$1
  while [ ! -d "$path" ]; do path=$(dirname "$path"); done
  df -Pk "$path" | awk 'NR == 2 { print int($4 / 1048576) }'
}

check_plan() {
  say "Hostinger server"
  [ -r /etc/os-release ] || fail "This is not Linux. Use a Hostinger KVM VPS with the Ubuntu 24.04 template."
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    ubuntu:22.04|ubuntu:24.04) ok "Ubuntu ${VERSION_ID}" ;;
    *) fail "Use a Hostinger KVM VPS with Ubuntu 22.04 or 24.04 (this is ${PRETTY_NAME:-unknown}). Reinstall the OS from hPanel → VPS → OS & Panel." ;;
  esac
  case "$(uname -m)" in
    x86_64) ok "x86-64" ;;
    *) fail "OpenMausBot's server image is x86-64 only (this is $(uname -m)). Pick an x86-64 KVM plan in hPanel." ;;
  esac
  cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 0)
  if [ "$cpus" -lt 2 ]; then
    fail "This VPS has $cpus CPU. Hostinger KVM 1 is below OpenMausBot's minimum: upgrade to KVM 2 (2 vCPU, 8 GB) or larger in hPanel → VPS → Upgrade."
  fi
  ok "$cpus CPUs"
  mem_mb=$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)
  mem_mb=${mem_mb:-0}
  if [ "$mem_mb" -lt 3500 ]; then
    fail "This VPS has ${mem_mb} MB of memory; OpenMausBot needs 4 GB. Use Hostinger KVM 2 or larger."
  fi
  ok "${mem_mb} MB memory"
  disk_gb=$(free_gb "$INSTALL_DIR")
  disk_gb=${disk_gb:-0}
  if [ "$disk_gb" -lt 20 ]; then
    fail "Only ${disk_gb} GB free where OpenMausBot installs. Free 20 GB, or move to a plan with more disk."
  fi
  ok "${disk_gb} GB free disk"
  virt=$(systemd-detect-virt 2>/dev/null || echo unknown)
  case "$virt" in
    kvm|none) ok "virtualization: $virt" ;;
    *) warn "virtualization: $virt (Hostinger KVM reports kvm)" ;;
  esac
}

docker_ready() {
  docker version >/dev/null 2>&1 && docker compose version >/dev/null 2>&1
}

check_docker() {
  if docker_ready; then
    ok "Docker $(docker version --format '{{.Server.Version}}') with Compose"
    return 0
  fi
  warn "Docker with the Compose plugin is not available"
  return 1
}

open_firewall() {
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | head -1 | grep -q "Status: active" || return 0
  for port in 22 80 443; do ufw allow "$port"/tcp >/dev/null 2>&1 || true; done
  ok "ufw allows 22, 80 and 443"
}

upstream_script() {
  if [ -f "$here/../install.sh" ]; then
    printf '%s\n' "$here/../install.sh"
    return 0
  fi
  target=$(mktemp)
  curl -fsSL --max-time 120 "$RAW_BASE/deploy/install.sh" -o "$target" ||
    fail "Could not download the OpenMausBot installer from $RAW_BASE."
  printf '%s\n' "$target"
}

run_upstream() {
  script=$1
  shift
  # --install-docker is the one Hostinger default worth setting: a fresh VPS
  # template has no Docker, and the installer otherwise stops to ask.
  if [ "$INSTALL_DOCKER" = yes ]; then
    set -- "$@" --install-docker
  fi
  sh "$script" "$@"
}

engine_for_key() {
  case "$1" in
    ANTHROPIC_API_KEY) echo claude ;;
    OPENAI_API_KEY) echo openai ;;
    XAI_API_KEY) echo xai ;;
    OPENROUTER_API_KEY) echo openrouter ;;
    GROQ_API_KEY) echo groq ;;
    MISTRAL_API_KEY) echo mistral ;;
    CEREBRAS_API_KEY) echo cerebras ;;
    GREENFERENCE_API_KEY) echo greenference ;;
    MODELGO_API_KEY) echo modelgo ;;
    *) echo "" ;;
  esac
}

compose() {
  ( cd "$INSTALL_DIR" && docker compose "$@" )
}

apply_keys() {
  [ -f "$KEYS_FILE" ] || return 0
  [ -s "$KEYS_FILE" ] || return 0
  say ""
  say "Engine keys from $KEYS_FILE"
  applied=0
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s' "$line" | tr -d '\r')
    case "$line" in ''|'#'*) continue ;; esac
    name=${line%%=*}
    value=${line#*=}
    name=$(printf '%s' "$name" | tr -d ' ')
    name=${name#export }
    value=$(printf '%s' "$value" | sed -e 's/^["'\'']//' -e 's/["'\'']$//')
    [ -n "$value" ] || continue
    engine=$(engine_for_key "$name")
    [ -n "$engine" ] || continue
    export "$name=$value"
    if compose exec -T -e "$name" omb openmausbot engine set "$engine" --key-env "$name" --install >/dev/null 2>&1; then
      ok "$engine engine ready"
      applied=$((applied + 1))
    else
      warn "$engine engine was not set from $name (the key may be wrong or rejected)"
    fi
  done < "$KEYS_FILE"
  [ "$applied" -gt 0 ] || warn "No usable key in $KEYS_FILE"
}

make_bots() {
  [ "$BOTS" = yes ] || return 0
  source_file="$here/setup-bots.mjs"
  if [ ! -f "$source_file" ]; then
    source_file=$(mktemp)
    curl -fsSL --max-time 60 "$RAW_BASE/deploy/hostinger/setup-bots.mjs" -o "$source_file" ||
      fail "Could not download setup-bots.mjs from $RAW_BASE."
  fi
  say ""
  say "Bots"
  compose cp "$source_file" omb:/tmp/setup-bots.mjs >/dev/null 2>&1 ||
    fail "Could not copy setup-bots.mjs into the server container."
  if compose exec -T omb node /tmp/setup-bots.mjs; then
    :
  else
    warn "Bots were not all created. Run this again with --bots-only once an engine is signed in."
  fi
}

pair_link() {
  [ "$MODE" = check ] && return 0
  template=$(compose exec -T omb openmausbot pair --label "Hostinger admin" 2>/dev/null) || return 0
  case "$template" in *"Link "*"https://"*) ;; *) return 0 ;; esac
  printf '%s\n' "$template" | grep -E '^(Pairing code|Link) ' > "$PAIR_FILE" 2>/dev/null || return 0
  chmod 600 "$PAIR_FILE"
  say ""
  say "First admin sign-in (single use; make another with: cd $INSTALL_DIR && docker compose exec omb openmausbot pair)"
  if [ -t 1 ]; then
    sed 's/^/  /' "$PAIR_FILE"
  else
    say "  saved to $PAIR_FILE (read it from a terminal; it signs in as the admin once)"
  fi
}

print_summary() {
  say ""
  say "MausBot: https://$DOMAIN"
  say "Folder:   $INSTALL_DIR"
  say "Logs:     cd $INSTALL_DIR && docker compose logs -f omb"
  say "Bots:     cd $INSTALL_DIR && docker compose exec omb openmausbot bots"
  say "Update:   sudo $INSTALL_DIR/update.sh"
  say ""
  say "Engine CLIs sign in once, interactively:"
  say "  cd $INSTALL_DIR && docker compose exec omb claude"
  say "  cd $INSTALL_DIR && docker compose exec omb codex login"
  say "  cd $INSTALL_DIR && docker compose exec omb grok"
}

# ---- main ------------------------------------------------------------------

case "$MODE" in
  check)
    check_plan
    say ""
    if check_docker; then :; else warn "The installer can add Docker (get.docker.com) when you run without --check."; fi
    say ""
    script=$(upstream_script)
    run_upstream "$script" --check ${DOMAIN:+--domain "$DOMAIN"}
    ;;
  install)
    check_plan
    check_docker || true
    open_firewall
    [ -n "$DOMAIN" ] || fail "Say which name people will open: --domain maus.example.com"
    script=$(upstream_script)
    say ""
    say "Installing OpenMausBot at https://$DOMAIN"
    # shellcheck disable=SC2086  # a flag list, deliberately split into words
    if [ -n "$EMAIL" ]; then
      run_upstream "$script" --domain "$DOMAIN" --email "$EMAIL" $UPSTREAM_ARGS
    else
      run_upstream "$script" --domain "$DOMAIN" $UPSTREAM_ARGS
    fi
    apply_keys
    make_bots
    pair_link
    print_summary
    ;;
  bots)
    [ -f "$INSTALL_DIR/compose.yaml" ] || fail "No OpenMausBot install in $INSTALL_DIR. Run without --bots-only first."
    DOMAIN=$(awk -F= '/^DOMAIN=/ { print $2; exit }' "$INSTALL_DIR/.env" 2>/dev/null || true)
    apply_keys
    make_bots
    pair_link
    ;;
esac
