#!/usr/bin/env bash
#
# Bring the liaxum-vps manager node up from nothing, in dependency order.
#
# The order is not arbitrary. Headscale hands out the 100.64.0.1 address that
# the NFS server binds to, and the Komodo keys volume mounts that export, so
# the mesh has to exist before storage, which has to exist before monitoring.
#
#   ./scripts/bootstrap.sh                      # deploy, host must be ready
#   ./scripts/bootstrap.sh --with-host-setup    # also prepare the host (sudo)
#   ./scripts/bootstrap.sh --reconfigure        # re-ask the settings
#   ./scripts/bootstrap.sh --from nfs           # resume from a stage
#   ./scripts/bootstrap.sh --only monitor       # run a single stage
#   ./scripts/bootstrap.sh --dry-run            # print what would run
#
# Settings that differ per install -- domain, manager hostname, mesh address,
# headplane's credentials -- are asked once and kept in bootstrap.env, which is
# gitignored. Answers are reused on later runs unless --reconfigure is passed;
# exporting a variable beforehand overrides the stored value.
#
# Every stage is idempotent: re-running is always safe.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

STAGES=(config host swarm traefik vpn mesh nfs filebrowser monitor verify)

# Answers live here. It holds headplane's API key, so keep it out of git.
ENV_FILE="${ENV_FILE:-bootstrap.env}"

WITH_HOST_SETUP=0
RECONFIGURE=0
DRY_RUN=0
FROM_STAGE=""
ONLY_STAGE=""

# Certificate material for Traefik. Not in the repo -- .gitignore excludes it.
CRT_FILE="${CRT_FILE:-traefik/secret/liaxum.crt}"
KEY_FILE="${KEY_FILE:-traefik/secret/liaxum.key}"

# Docker needs this when the host has several addresses and cannot choose.
SWARM_ADVERTISE_ADDR="${SWARM_ADVERTISE_ADDR:-}"

RED=$'\033[31m'; YELLOW=$'\033[33m'; GREEN=$'\033[32m'; BOLD=$'\033[1m'; OFF=$'\033[0m'
[[ -t 1 ]] || { RED=""; YELLOW=""; GREEN=""; BOLD=""; OFF=""; }

info()  { printf '%s==>%s %s\n' "$BOLD" "$OFF" "$*"; }
ok()    { printf '%s  ok%s %s\n' "$GREEN" "$OFF" "$*"; }
skip()  { printf '    -- %s\n' "$*"; }
warn()  { printf '%swarn%s %s\n' "$YELLOW" "$OFF" "$*" >&2; }
die()   { printf '%sfail%s %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"; }

# Run a command, or print it under --dry-run.
run() {
  if (( DRY_RUN )); then
    printf '    would run: %s\n' "$*"
  else
    "$@"
  fi
}

# Query docker without side effects. Under --dry-run these still run, since
# they only read state and the stage logic depends on their answers.
have()        { command -v "$1" >/dev/null 2>&1; }
swarm_active(){ [[ "$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" == active ]]; }
net_exists()  { docker network inspect "$1" >/dev/null 2>&1; }
secret_exists(){ docker secret inspect "$1" >/dev/null 2>&1; }
config_exists(){ docker config inspect "$1" >/dev/null 2>&1; }

while (( $# )); do
  case "$1" in
    --with-host-setup) WITH_HOST_SETUP=1 ;;
    --reconfigure)     RECONFIGURE=1 ;;
    --dry-run)         DRY_RUN=1 ;;
    --from)            FROM_STAGE="${2:?--from needs a stage}"; shift ;;
    --only)            ONLY_STAGE="${2:?--only needs a stage}"; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

for s in ${FROM_STAGE:-} ${ONLY_STAGE:-}; do
  [[ " ${STAGES[*]} " == *" $s "* ]] || die "unknown stage: $s (have: ${STAGES[*]})"
done

# ---------------------------------------------------------------- stages ---

# Ask for one setting, or reuse what is already known. Precedence: an exported
# variable, then bootstrap.env, then the default shown in the prompt.
ask() {
  local var="$1" prompt="$2" default="${3:-}" hidden="${4:-}" optional="${5:-}"
  local current="${!var:-}" reply

  if [[ -n "$current" ]] && (( ! RECONFIGURE )); then
    export "$var=$current"
    return
  fi

  local suggestion="${current:-$default}"

  # Non-interactive: fall back to the suggestion, or fail if there is none.
  if [[ ! -t 0 ]]; then
    [[ -n "$suggestion" || -n "$optional" ]] || die "$var is unset and there is no terminal to ask on. Set it in $ENV_FILE or export it."
    export "$var=$suggestion"
    return
  fi

  if [[ -n "$hidden" ]]; then
    read -rsp "    $prompt: " reply; printf '\n'
  elif [[ -n "$suggestion" ]]; then
    read -rp "    $prompt [$suggestion]: " reply
  else
    read -rp "    $prompt: " reply
  fi

  reply="${reply:-$suggestion}"
  [[ -n "$reply" || -n "$optional" ]] || die "$var cannot be empty"
  export "$var=$reply"
}

# Substitute the settings into a *.template file. Deliberately not envsubst:
# gettext is not installed everywhere, and the placeholder set is fixed.
render() {
  local template="$1" out="${1%.template}"
  (( DRY_RUN )) && { printf '    would render: %s -> %s\n' "$template" "$out"; return; }
  sed -e "s|\${DOMAIN}|$DOMAIN|g" \
      -e "s|\${MANAGER_HOSTNAME}|$MANAGER_HOSTNAME|g" \
      -e "s|\${MESH_ADDR}|$MESH_ADDR|g" \
      -e "s|\${HEADPLANE_API_KEY}|$HEADPLANE_API_KEY|g" \
      -e "s|\${HEADPLANE_COOKIE_SECRET}|$HEADPLANE_COOKIE_SECRET|g" \
      "$template" > "$out"
  ok "rendered $out"
}

# Pull in stored answers. Runs before any stage, so --only/--from still see
# the settings without re-running the config stage.
load_env() {
  # shellcheck source=/dev/null
  [[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }
  return 0
}

# Stages that interpolate settings into compose files or rendered configs need
# real values; without them Compose would quietly fall back to its defaults and
# deploy someone else's domain.
require_settings() {
  local v
  for v in DOMAIN MANAGER_HOSTNAME MESH_ADDR; do
    [[ -n "${!v:-}" ]] || die "$v is not set. Run '$0 --only config' first, or export it."
    export "$v=${!v}"
  done
  export HEADPLANE_API_KEY="${HEADPLANE_API_KEY:-}"
  export HEADPLANE_COOKIE_SECRET="${HEADPLANE_COOKIE_SECRET:-}"
}

stage_config() {
  info "settings"
  [[ -f "$ENV_FILE" ]] && skip "loaded $ENV_FILE"

  ask DOMAIN           "Domain serving the stacks"       "liaxum.fr"
  ask MANAGER_HOSTNAME "Hostname of the manager node"    "$(hostname)"
  ask MESH_ADDR        "This node's address on the mesh" "100.64.0.1"

  # Minted in headplane; see its docs. Left empty until headscale exists, so a
  # first run can get as far as deploying headscale and come back to it.
  ask HEADPLANE_API_KEY       "Headplane API key (blank to fill in later)" "" "" optional
  ask HEADPLANE_COOKIE_SECRET "Headplane cookie secret" "$(openssl rand -hex 16 2>/dev/null || head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"

  if (( DRY_RUN )); then
    skip "would write $ENV_FILE"
  else
    umask 077
    cat > "$ENV_FILE" <<EOF
# Written by scripts/bootstrap.sh. Gitignored: contains credentials.
DOMAIN=$DOMAIN
MANAGER_HOSTNAME=$MANAGER_HOSTNAME
MESH_ADDR=$MESH_ADDR
HEADPLANE_API_KEY=$HEADPLANE_API_KEY
HEADPLANE_COOKIE_SECRET=$HEADPLANE_COOKIE_SECRET
EOF
    ok "saved $ENV_FILE"
  fi

  printf '    %s -> %s, manager %s, mesh %s\n' "stacks" "*.$DOMAIN" "$MANAGER_HOSTNAME" "$MESH_ADDR"
}

stage_host() {
  if (( ! WITH_HOST_SETUP )); then
    skip "host setup not requested; checking prerequisites instead"

    have mount.nfs4 || die "NFS client utilities missing. Install nfs-common (Debian/Ubuntu) or nfs-utils (Arch), or re-run with --with-host-setup."
    swarm_active   || die "this node is not in a swarm. Run 'docker swarm init', or re-run with --with-host-setup."
    [[ -d /opt/vpn/data ]] || die "/opt/vpn/data does not exist (headscale's state directory). Create it, or re-run with --with-host-setup."

    if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
      ufw status | grep -q '2049.*tailscale0' \
        || warn "no ufw rule allowing 2049 on tailscale0. Local mounts work without it, but worker nodes will not be able to mount the export."
    fi
    ok "host prerequisites present"
    return
  fi

  info "preparing the host (requires sudo)"

  if have mount.nfs4; then
    skip "NFS client utilities already installed"
  elif have apt-get; then
    run sudo apt-get update
    run sudo apt-get install -y nfs-common
  elif have pacman; then
    run sudo pacman -S --needed --noconfirm nfs-utils
  else
    die "cannot install NFS client utilities: neither apt-get nor pacman found"
  fi

  if swarm_active; then
    skip "swarm already initialised"
  elif [[ -n "$SWARM_ADVERTISE_ADDR" ]]; then
    run docker swarm init --advertise-addr "$SWARM_ADVERTISE_ADDR"
  else
    run docker swarm init
  fi

  if [[ -d /opt/vpn/data ]]; then
    skip "/opt/vpn/data exists"
  else
    run sudo mkdir -p /opt/vpn/data
  fi

  if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    if ufw status | grep -q '2049.*tailscale0'; then
      skip "ufw already allows 2049 on tailscale0"
    else
      run sudo ufw allow in on tailscale0 to any port 2049 proto tcp
      run sudo ufw reload
    fi
  else
    skip "ufw inactive or absent; nothing to open"
  fi

  ok "host ready"
}

stage_swarm() {
  info "swarm resources"
  swarm_active || die "this node is not in a swarm (run with --with-host-setup)"

  if net_exists web-net; then
    skip "network web-net exists"
  else
    run docker network create --driver overlay --attachable web-net
  fi

  # Docker secrets are immutable: to rotate a certificate you remove the
  # secret and redeploy Traefik, which is deliberately not automated here.
  local pair
  for pair in "liaxum_crt:$CRT_FILE" "liaxum_key:$KEY_FILE"; do
    local name="${pair%%:*}" file="${pair#*:}"
    if secret_exists "$name"; then
      skip "secret $name exists"
    elif [[ -f "$file" ]]; then
      run docker secret create "$name" "$file"
    else
      die "secret $name is missing and $file does not exist. Put the certificate there, or set CRT_FILE/KEY_FILE."
    fi
  done

  if config_exists traefik_dynamic; then
    skip "config traefik_dynamic exists"
  else
    run docker config create traefik_dynamic traefik/dynamic.yml
  fi

  ok "swarm resources ready"
}

stage_traefik()     { info "traefik";     run docker stack deploy -c traefik/compose.yml traefik; }
stage_filebrowser() { info "filebrowser"; run docker stack deploy -c apps/filebrowser/compose.yml files; }
stage_monitor()     { info "komodo";      run docker stack deploy -c apps/monitor/compose.yml monitor; }

stage_vpn() {
  info "headscale"
  # compose reads these as files, so they are rendered rather than interpolated
  render apps/vpn/config.yaml.template
  render apps/vpn/headplane_config.yaml.template
  run docker stack deploy -c apps/vpn/compose.yml vpn
}

stage_mesh() {
  info "mesh address"

  if (( DRY_RUN )); then
    skip "would check that $MESH_ADDR is assigned to this host"
    return
  fi

  if ip -4 -oneline addr show 2>/dev/null | grep -qw "$MESH_ADDR"; then
    ok "$MESH_ADDR is assigned to this host"
    return
  fi

  # Joining is interactive, or needs a pre-auth key minted inside headscale.
  # Automating it would mean generating keys on every run, so stop instead.
  cat >&2 <<EOF

This host does not hold $MESH_ADDR yet, so the NFS server cannot bind it.
Join the mesh, then re-run with: $0 --from nfs

  docker exec headscale headscale users create \$USER
  docker exec headscale headscale preauthkeys create --user \$USER --reusable --expiration 1h
  sudo tailscale up --login-server https://vpn.$DOMAIN --authkey <key>

EOF
  die "not joined to the mesh"
}

stage_nfs() {
  info "nfs server"
  # Standalone compose, not a stack: the kernel NFS server needs privileges
  # and an AppArmor bypass that swarm services cannot be granted.
  # --remove-orphans clears containers left by earlier service names.
  run docker compose -f apps/nfs/compose.yml up -d --remove-orphans
}

stage_verify() {
  info "verifying"

  if (( DRY_RUN )); then
    skip "would check every service has its replicas running"
    return
  fi

  local failed=0 svc replicas
  for svc in traefik_core vpn_core vpn_web files_core monitor_db monitor_core monitor_agent monitor_mcp; do
    replicas="$(docker service ls --filter "name=$svc" --format '{{.Replicas}}' 2>/dev/null | head -1)"
    if [[ -z "$replicas" ]]; then
      warn "$svc: not deployed"
      failed=1
    elif [[ "${replicas%%/*}" == "${replicas##*/}" && "${replicas%%/*}" != 0 ]]; then
      ok "$svc: $replicas"
    else
      warn "$svc: $replicas -- inspect with: docker service ps --no-trunc $svc"
      failed=1
    fi
  done

  if docker exec nfs-server test -d /shared 2>/dev/null; then
    ok "nfs-server: exporting /shared"
  else
    warn "nfs-server: not running"
    failed=1
  fi

  (( failed )) && die "some services are not healthy (see above)"

  cat <<EOF

$(printf '%s' "$GREEN")All services are up.$(printf '%s' "$OFF")

  headscale   https://vpn.$DOMAIN          admin at /admin
  filebrowser https://files.$DOMAIN        password: docker service logs files_core
  komodo      https://monitor.$DOMAIN

EOF
}

# ------------------------------------------------------------------ main ---

load_env

started=0
for stage in "${STAGES[@]}"; do
  if [[ -n "$ONLY_STAGE" ]]; then
    [[ "$stage" == "$ONLY_STAGE" ]] || continue
  elif [[ -n "$FROM_STAGE" && $started -eq 0 ]]; then
    [[ "$stage" == "$FROM_STAGE" ]] || continue
    started=1
  fi
  case "$stage" in
    config|host) ;;
    *)           require_settings ;;
  esac
  "stage_$stage"
done
