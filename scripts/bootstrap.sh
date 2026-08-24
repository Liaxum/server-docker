#!/usr/bin/env bash
#
# Bring the manager node up from nothing, in dependency order.
#
# The order is not arbitrary. Headscale hands out the 100.64.0.1 address that
# the NFS server binds to, and the Komodo keys volume mounts that export, so
# the mesh has to exist before storage, which has to exist before monitoring.
#
#   ./scripts/bootstrap.sh                      # deploy, host must be ready
#   ./scripts/bootstrap.sh --with-host-setup    # also prepare the host (sudo)
#   ./scripts/bootstrap.sh --reconfigure        # re-ask the settings
#   ./scripts/bootstrap.sh --ssh user@host      # repo here, cluster there
#   ./scripts/bootstrap.sh --reset-config       # forget the answers, start over
#   ./scripts/bootstrap.sh --uninstall          # remove what this script created
#   ./scripts/bootstrap.sh --from nfs           # resume from a stage
#   ./scripts/bootstrap.sh --only monitor       # run a single stage
#   ./scripts/bootstrap.sh --dry-run            # print what would run
#
# Settings that differ per install -- domain, manager hostname, mesh address,
# headplane's credentials -- are asked once and kept in bootstrap.env, which is
# gitignored. Answers are reused on later runs unless --reconfigure is passed;
# exporting a variable beforehand overrides the stored value.
#
# --ssh keeps the repo on this machine and puts the cluster on another: docker
# commands go to that host's daemon, and the stages that inspect or change the
# host itself run there over ssh rather than here.
#
# Every stage is idempotent: re-running is always safe.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

STAGES=(config host swarm traefik vpn mesh nfs filebrowser monitor verify)

# Answers live here. It holds headplane's API key, so keep it out of git.
ENV_FILE="${ENV_FILE:-bootstrap.env}"

# What this script changed on the target host, so --uninstall --with-host can
# reverse exactly that and nothing else. Anything that was already there when
# we arrived is never recorded, and so is never removed.
STATE_FILE="${STATE_FILE:-/var/lib/server-docker-bootstrap.state}"

WITH_HOST_SETUP=0
RECONFIGURE=0
SSH_TARGET=""
RESET_CONFIG=0
UNINSTALL=0
WITH_DATA=0
WITH_HOST=0
DRY_RUN=0
FROM_STAGE=""
ONLY_STAGE=""

# Where to look for Traefik's certificate material. Not in the repo --
# .gitignore excludes it. Extensions vary by CA (.crt, .cer, .pem), so the
# files are identified by content rather than by name.
CERT_DIR="${CERT_DIR:-traefik/secret}"

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
    --reset-config)    RESET_CONFIG=1 ;;
    --uninstall)       UNINSTALL=1 ;;
    --with-data)       WITH_DATA=1 ;;
    --with-host)       WITH_HOST=1 ;;
    --ssh)             SSH_TARGET="${2:?--ssh needs user@host}"; shift ;;
    --dry-run)         DRY_RUN=1 ;;
    --from)            FROM_STAGE="${2:?--from needs a stage}"; shift ;;
    --only)            ONLY_STAGE="${2:?--only needs a stage}"; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

# Fail on the connection itself rather than letting every later check come
# back false and get reported as a missing package or an absent directory.
if [[ -n "$SSH_TARGET" ]]; then
  have ssh || die "--ssh needs an ssh client on this machine"
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_TARGET" true 2>/dev/null \
    || die "cannot reach $SSH_TARGET over ssh without a password. Check the host, and that your key is loaded."
fi

# Point the docker CLI at the target's daemon. Compose files are still read
# here -- only the resulting spec crosses the wire.
[[ -n "$SSH_TARGET" ]] && export DOCKER_HOST="ssh://$SSH_TARGET"

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

# Read-only check on the target host. Always executes, including under
# --dry-run: stage logic depends on the answer.
host_eval() {
  if [[ -n "$SSH_TARGET" ]]; then ssh -o BatchMode=yes "$SSH_TARGET" "$1"; else eval "$1"; fi
}

# Mutating command on the target host. Honours --dry-run, and asks for a
# terminal when remote so sudo can prompt.
host_run() {
  if (( DRY_RUN )); then
    printf '    would run%s: %s\n' "${SSH_TARGET:+ on $SSH_TARGET}" "$1"
    return
  fi
  if [[ -n "$SSH_TARGET" ]]; then ssh -t "$SSH_TARGET" "$1"; else eval "$1"; fi
}

# True when the docker CLI is pointed at a daemon on another machine, e.g.
# via `docker context use`. Deploys work fine that way -- compose files are
# read client-side and the spec is sent over -- but anything that inspects or
# modifies the host would act on the wrong machine.
docker_is_remote() {
  # --ssh points the daemon and the host commands at the same machine, so a
  # remote daemon is expected and not a mistake.
  [[ -n "$SSH_TARGET" ]] && return 1
  local daemon
  daemon="$(docker info --format '{{.Name}}' 2>/dev/null)" || return 1
  [[ -n "$daemon" ]] || return 1
  [[ "${daemon%%.*}" != "$(hostname -s 2>/dev/null || hostname)" ]]
}

# Is an IPv4 address inside a CIDR? Returns 2 when the inputs are not plain
# IPv4, so callers can skip the check rather than reject an IPv6 setup.
cidr_contains() {
  local cidr="$1" addr="$2" base bits mask
  base="${cidr%/*}"; bits="${cidr#*/}"
  [[ "$base" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 2
  [[ "$bits" =~ ^[0-9]+$ ]] && (( bits <= 32 )) || return 2
  local -a b a
  IFS=. read -r -a b <<< "$base"
  IFS=. read -r -a a <<< "$addr"
  mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  (( ((b[0]<<24|b[1]<<16|b[2]<<8|b[3]) & mask) == ((a[0]<<24|a[1]<<16|a[2]<<8|a[3]) & mask) ))
}

# Short content hash, used to name docker config objects. sha256sum is
# coreutils, shasum comes with macOS -- this runs wherever the CLI does.
file_hash() {
  if have sha256sum;  then sha256sum "$1" | cut -c1-12
  elif have shasum;   then shasum -a 256 "$1" | cut -c1-12
  else openssl dgst -sha256 "$1" | awk '{print substr($NF, 1, 12)}'
  fi
}

# Substitute the settings into a *.template file. Deliberately not envsubst:
# gettext is not installed everywhere, and the placeholder set is fixed.
render() {
  local template="$1" out="${1%.template}"
  (( DRY_RUN )) && { printf '    would render: %s -> %s\n' "$template" "$out"; return; }
  sed -e "s|\${DOMAIN}|$DOMAIN|g" \
      -e "s|\${MANAGER_HOSTNAME}|$MANAGER_HOSTNAME|g" \
      -e "s|\${MESH_ADDR}|$MESH_ADDR|g" \
      -e "s|\${MESH_CIDR}|$MESH_CIDR|g" \
      -e "s|\${VPN_STACK}|$VPN_STACK|g" \
      -e "s|\${VPN_SUBDOMAIN}|$VPN_SUBDOMAIN|g" \
      -e "s|\${HEADPLANE_API_KEY}|$HEADPLANE_API_KEY|g" \
      -e "s|\${HEADPLANE_COOKIE_SECRET}|$HEADPLANE_COOKIE_SECRET|g" \
      "$template" > "$out"
  ok "rendered $out"
}

# Pull in stored answers. Runs before any stage, so --only/--from still see
# the settings without re-running the config stage.
load_env() {
  [[ -f "$ENV_FILE" ]] || return 0
  local line key val
  # Parsed rather than sourced: a value already exported must win over the
  # stored one, and nothing in this file should be able to execute.
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    key="${line%%=*}"; val="${line#*=}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    [[ -n "${!key:-}" ]] || export "$key=$val"
  done < "$ENV_FILE"
}

# Stages that interpolate settings into compose files or rendered configs need
# real values; without them Compose would quietly fall back to its defaults and
# deploy someone else's domain.
require_settings() {
  local v
  for v in DOMAIN MANAGER_HOSTNAME MESH_ADDR MESH_CIDR \
           TRAEFIK_STACK VPN_STACK VPN_SUBDOMAIN FILES_STACK FILES_SUBDOMAIN \
           MONITOR_STACK MONITOR_SUBDOMAIN MCP_SUBDOMAIN CRT_FILE KEY_FILE MESH_USER; do
    [[ -n "${!v:-}" ]] || die "$v is not set. Run '$0 --only config' first, or export it."
    export "$v=${!v}"
  done
  export HEADPLANE_API_KEY="${HEADPLANE_API_KEY:-}"
  export HEADPLANE_COOKIE_SECRET="${HEADPLANE_COOKIE_SECRET:-}"
}

write_env() {
  umask 077
  cat > "$ENV_FILE" <<EOF
# Written by scripts/bootstrap.sh. Gitignored: contains credentials.
DOMAIN=$DOMAIN
MANAGER_HOSTNAME=$MANAGER_HOSTNAME
MESH_ADDR=$MESH_ADDR
MESH_CIDR=$MESH_CIDR
TRAEFIK_STACK=$TRAEFIK_STACK
VPN_STACK=$VPN_STACK
VPN_SUBDOMAIN=$VPN_SUBDOMAIN
FILES_STACK=$FILES_STACK
FILES_SUBDOMAIN=$FILES_SUBDOMAIN
MONITOR_STACK=$MONITOR_STACK
MONITOR_SUBDOMAIN=$MONITOR_SUBDOMAIN
MCP_SUBDOMAIN=$MCP_SUBDOMAIN
MESH_USER=$MESH_USER
CRT_FILE=$CRT_FILE
KEY_FILE=$KEY_FILE
HEADPLANE_API_KEY=$HEADPLANE_API_KEY
HEADPLANE_COOKIE_SECRET=$HEADPLANE_COOKIE_SECRET
EOF
  ok "saved $ENV_FILE"
}

stage_config() {
  info "settings"
  [[ -f "$ENV_FILE" ]] && skip "loaded $ENV_FILE"

  ask DOMAIN           "Domain serving the stacks"       "liaxum.fr"
  ask MANAGER_HOSTNAME "Hostname of the manager node"    "$(host_eval 'hostname -s' 2>/dev/null || hostname)"
  [[ "$MANAGER_HOSTNAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || die "MANAGER_HOSTNAME '$MANAGER_HOSTNAME' is not a valid hostname"
  ask MESH_ADDR        "This node's address on the mesh" "100.64.0.1"
  # Headscale hands out addresses from this range and the NFS export admits
  # that same range, so the two have to be set together.
  ask MESH_CIDR        "Address range headscale hands out" "100.64.0.0/10"

  if ! cidr_contains "$MESH_CIDR" "$MESH_ADDR"; then
    (( $? == 2 )) || die "MESH_ADDR $MESH_ADDR is outside MESH_CIDR $MESH_CIDR: headscale would never hand out that address, and the NFS export would refuse it."
  fi

  # Minted in headplane; see its docs. Left empty until headscale exists, so a
  # first run can get as far as deploying headscale and come back to it.
  # Stack names are docker stack deploy arguments, so they are free to change.
  # Service names are not: they are YAML keys, and Compose does not interpolate
  # keys -- every stack here calls its main service "core" by repo convention.
  ask TRAEFIK_STACK      "Stack name for traefik"      "traefik"
  ask VPN_STACK          "Stack name for headscale"    "vpn"
  ask VPN_SUBDOMAIN      "Subdomain for headscale"     "vpn"
  ask FILES_STACK        "Stack name for filebrowser"  "files"
  ask FILES_SUBDOMAIN    "Subdomain for filebrowser"   "files"
  ask MONITOR_STACK      "Stack name for komodo"       "monitor"
  ask MONITOR_SUBDOMAIN  "Subdomain for komodo"        "monitor"
  ask MCP_SUBDOMAIN      "Subdomain for the komodo MCP server" "mcp"

  ask CRT_FILE "TLS certificate file" "$(detect_pem cert || echo "$CERT_DIR/certificate.pem")"
  ask KEY_FILE "TLS private key file" "$(detect_pem key  || echo "$CERT_DIR/private.key")"

  ask MESH_USER "Headscale user to enrol nodes under" "admin"
  [[ "$MESH_USER" =~ ^[A-Za-z0-9._-]+$ ]] || die "MESH_USER '$MESH_USER' is not a valid name"

  ask HEADPLANE_API_KEY       "Headplane API key (blank to fill in later)" "" "" optional
  ask HEADPLANE_COOKIE_SECRET "Headplane cookie secret" "$(openssl rand -hex 16 2>/dev/null || head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"

  if (( DRY_RUN )); then
    skip "would write $ENV_FILE"
  else
    write_env
  fi

  printf '    %s, manager %s, mesh %s in %s\n' "*.$DOMAIN" "$MANAGER_HOSTNAME" "$MESH_ADDR" "$MESH_CIDR"
  printf '    stacks: %s %s %s %s\n' "$TRAEFIK_STACK" "$VPN_STACK" "$FILES_STACK" "$MONITOR_STACK"
}

# First file in CERT_DIR that parses as a certificate ("cert") or a private
# key ("key"). Naming is inconsistent across CAs and a .pem may be either, so
# ask openssl rather than trusting the extension.
detect_pem() {
  local kind="$1" f
  local -a candidates
  have openssl || return 1
  # Preference matters when several files parse. Name hints come first, then
  # .pem -- this repo converts the CA's .cer/.key into .pem before use. A hint
  # only reorders the search; openssl still decides what each file is, so a
  # "certificate-key.pem" caught by *cert* is rejected and the scan continues.
  case "$kind" in
    cert) candidates=("$CERT_DIR"/*cert* "$CERT_DIR"/*fullchain* "$CERT_DIR"/*.pem \
                      "$CERT_DIR"/*.crt "$CERT_DIR"/*.cer "$CERT_DIR"/*) ;;
    key)  candidates=("$CERT_DIR"/*private* "$CERT_DIR"/*.key "$CERT_DIR"/*.pem "$CERT_DIR"/*) ;;
  esac
  for f in "${candidates[@]}"; do
    [[ -f "$f" ]] || continue
    case "$kind" in
      cert) openssl x509 -in "$f" -noout >/dev/null 2>&1 && { printf '%s' "$f"; return 0; } ;;
      key)  openssl pkey -in "$f" -noout >/dev/null 2>&1 && { printf '%s' "$f"; return 0; } ;;
    esac
  done
  return 1
}

# A mismatched pair deploys happily and then fails TLS at runtime, so compare
# the public key the certificate carries against the one the key derives.
check_cert_pair() {
  have openssl || { skip "openssl absent; not checking the certificate"; return 0; }

  # Traefik reads the secret verbatim and needs PEM. openssl 3 auto-detects
  # DER, so parsing successfully is not evidence of the right encoding --
  # check the armour.
  local head
  head="$(head -c 11 "$CRT_FILE" 2>/dev/null)"
  [[ "$head" == "-----BEGIN " ]] \
    || die "$CRT_FILE is not PEM (Traefik needs PEM). If your CA gave you DER: openssl x509 -inform DER -in $CRT_FILE -out ${CRT_FILE%.*}.pem"
  head="$(head -c 11 "$KEY_FILE" 2>/dev/null)"
  [[ "$head" == "-----BEGIN " ]] \
    || die "$KEY_FILE is not PEM (Traefik needs PEM). If your CA gave you DER: openssl pkey -inform DER -in $KEY_FILE -out ${KEY_FILE%.*}.pem"

  openssl x509 -in "$CRT_FILE" -noout >/dev/null 2>&1 \
    || die "$CRT_FILE does not parse as a certificate"
  openssl pkey -in "$KEY_FILE" -noout >/dev/null 2>&1 \
    || die "$KEY_FILE does not parse as a private key"

  local a b
  a="$(openssl x509 -in "$CRT_FILE" -noout -pubkey 2>/dev/null)"
  b="$(openssl pkey -in "$KEY_FILE" -pubout 2>/dev/null)"
  [[ "$a" == "$b" ]] || die "$CRT_FILE and $KEY_FILE are not a pair: the certificate's public key does not match the private key"

  # A leaf without its intermediates verifies in browsers, which fetch or cache
  # them, and fails in Go -- so tailscale cannot reach headscale and retries
  # forever, which reads as the command hanging.
  local certs
  certs="$(grep -c -- '-----BEGIN CERTIFICATE-----' "$CRT_FILE" 2>/dev/null || echo 0)"
  if [[ "$certs" -le 1 ]]; then
    warn "$CRT_FILE holds a single certificate, so the intermediate chain is missing. Browsers usually cope; Go clients (tailscale, and anything else dialling these hosts) do not. Concatenate the CA's intermediates after the leaf: cat leaf.cer intermediate.cer > fullchain.pem"
  fi

  local expiry
  expiry="$(openssl x509 -in "$CRT_FILE" -noout -enddate 2>/dev/null)" || true
  ok "certificate ok, $certs in chain (${expiry#notAfter=})"
}

# A precondition this run cannot meet. Fatal normally; under --dry-run it is
# information, because seeing the whole plan is more useful than stopping at
# the first thing that is not ready yet.
blocker() {
  (( DRY_RUN )) && { warn "$*"; return 0; }
  die "$*"
}

# Note a host change we made, so it can be undone later.
record() {
  (( DRY_RUN )) && return 0
  host_run "printf '%s\n' '$1' | sudo tee -a $STATE_FILE >/dev/null" || true
}

recorded() { host_eval "sudo grep -qxF '$1' $STATE_FILE 2>/dev/null"; }

# The value recorded after a key, e.g. "hostname_was ubuntu" -> ubuntu.
recorded_value() {
  host_eval "sudo grep -m1 '^$1 ' $STATE_FILE 2>/dev/null" | cut -d' ' -f2-
}

# Ask a yes/no question. Returns false when there is no terminal, so
# non-interactive runs fall through to the explicit failure instead of
# hanging or silently changing a host.
confirm() {
  local reply
  [[ -t 0 ]] || return 1
  read -rp "    $1 [y/N]: " reply
  [[ "$reply" =~ ^[Yy] ]]
}

# May this run change the target host? True with --with-host-setup, or when
# the operator says yes to the specific change being proposed.
may_fix() {
  # Never prompt during a dry run: report the offer and carry on planning.
  (( DRY_RUN )) && { printf '    would ask: %s\n' "$1"; return 0; }
  (( WITH_HOST_SETUP )) || confirm "$1"
}

# The swarm records a node's hostname when it joins, and the placement
# constraints match on it -- so this has to be settled before ensure_swarm.
ensure_hostname() {
  local current
  current="$(host_eval 'hostname -s' 2>/dev/null)" || current=""
  [[ -n "$current" ]] || { warn "could not read the target's hostname"; return; }
  [[ "$current" == "$MANAGER_HOSTNAME" ]] && { skip "hostname is already $MANAGER_HOSTNAME"; return; }

  if swarm_active; then
    warn "target is called $current, but MANAGER_HOSTNAME is $MANAGER_HOSTNAME. It already belongs to a swarm, which recorded $current at join time -- renaming now would not change 'docker node ls', and the placement constraints would match no node. Set MANAGER_HOSTNAME to $current instead."
    return
  fi

  may_fix "Target is called $current but MANAGER_HOSTNAME is $MANAGER_HOSTNAME. Rename the host?" \
    || { blocker "target is called $current but MANAGER_HOSTNAME is $MANAGER_HOSTNAME; placement constraints would match no node."; return; }

  if host_eval 'command -v hostnamectl >/dev/null 2>&1'; then
    host_run "sudo hostnamectl set-hostname $MANAGER_HOSTNAME"
  else
    host_run "printf '%s\\n' $MANAGER_HOSTNAME | sudo tee /etc/hostname >/dev/null && sudo hostname $MANAGER_HOSTNAME"
  fi
  # Without this, every later sudo prints "unable to resolve host".
  record "hostname_was $current"
  host_run "grep -qw $MANAGER_HOSTNAME /etc/hosts || printf '127.0.1.1 %s\\n' $MANAGER_HOSTNAME | sudo tee -a /etc/hosts >/dev/null"
}

ensure_nfs_client() {
  local where="${SSH_TARGET:-this machine}"
  host_eval 'command -v mount.nfs4 >/dev/null 2>&1' && { skip "NFS client utilities present"; return; }

  may_fix "NFS client utilities are missing on $where. Install them?" \
    || { blocker "NFS client utilities missing on $where. Install nfs-common (Debian/Ubuntu) or nfs-utils (Arch), or re-run with --with-host-setup."; return; }

  if host_eval 'command -v apt-get >/dev/null 2>&1'; then
    host_run 'sudo apt-get update && sudo apt-get install -y nfs-common'
    record "installed_package apt-get nfs-common"
  elif host_eval 'command -v pacman >/dev/null 2>&1'; then
    host_run 'sudo pacman -S --needed --noconfirm nfs-utils'
    record "installed_package pacman nfs-utils"
  else
    die "cannot install NFS client utilities on $where: neither apt-get nor pacman found"
  fi
}

ensure_swarm() {
  swarm_active && { skip "swarm already initialised"; return; }

  may_fix "The target is not in a swarm. Initialise one?" \
    || { blocker "the target is not in a swarm. Run 'docker swarm init' on it, or re-run with --with-host-setup."; return; }

  if [[ -n "$SWARM_ADVERTISE_ADDR" ]]; then
    host_run "docker swarm init --advertise-addr $SWARM_ADVERTISE_ADDR"
  else
    host_run 'docker swarm init'
  fi
  record "swarm_init"
}

ensure_vpn_dir() {
  local where="${SSH_TARGET:-this machine}"
  host_eval 'test -d /opt/vpn/data' && { skip "/opt/vpn/data exists"; return; }

  may_fix "/opt/vpn/data does not exist on $where (headscale's state). Create it?" \
    || { blocker "/opt/vpn/data does not exist on $where. Create it, or re-run with --with-host-setup."; return; }

  host_run 'sudo mkdir -p /opt/vpn/data'
  record "created_dir /opt/vpn/data"
}

ensure_ufw_rule() {
  host_eval 'command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"' \
    || { skip "ufw inactive or absent; nothing to open"; return; }
  host_eval 'ufw status | grep -q "2049.*tailscale0"' && { skip "ufw allows 2049 on tailscale0"; return; }

  # Not fatal: local mounts work without it, only worker nodes need it.
  if may_fix "ufw does not allow 2049 on tailscale0, so worker nodes cannot mount the export. Add the rule?"; then
    host_run 'sudo ufw allow in on tailscale0 to any port 2049 proto tcp && sudo ufw reload'
  else
    warn "no ufw rule allowing 2049 on tailscale0. Local mounts work without it, but worker nodes will not be able to mount the export."
  fi
}

stage_host() {
  local where="${SSH_TARGET:-this machine}"
  info "host prerequisites on $where"

  # Without --ssh a remote daemon means the checks would inspect this machine
  # while the cluster lives elsewhere, and any fix would land here too.
  if docker_is_remote; then
    die "docker is pointed at a remote daemon ($(docker info --format '{{.Name}}')), so host checks would run against the wrong machine. Use --ssh <user@host> to target it, or run this on the manager itself."
  fi

  ensure_hostname
  ensure_nfs_client
  ensure_swarm
  ensure_vpn_dir
  ensure_ufw_rule

  ok "$where ready"
}

stage_swarm() {
  info "swarm resources"
  if ! swarm_active; then
    # Say which daemon was asked and what it answered: the usual cause is
    # docker pointing somewhere other than the operator assumes.
    local endpoint state
    endpoint="${DOCKER_HOST:-$(docker context show 2>/dev/null || echo default)}"
    # || true: pipefail would otherwise abort the function before die runs
    state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>&1 | tail -1)" || true
    blocker "the daemon at $endpoint reports swarm state '${state:-unreachable}'. Run the host stage, which offers to initialise a swarm, or check that --ssh/DOCKER_HOST points where you think."
    return
  fi

  if net_exists web-net; then
    skip "network web-net exists"
  else
    run docker network create --driver overlay --attachable web-net
  fi

  if ! secret_exists liaxum_crt || ! secret_exists liaxum_key; then
    [[ -f "$CRT_FILE" && -f "$KEY_FILE" ]] && check_cert_pair
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
      blocker "secret $name is missing and $file does not exist. Put the certificate there, or set CRT_FILE/KEY_FILE."
    fi
  done

  if config_exists traefik_dynamic; then
    skip "config traefik_dynamic exists"
  else
    run docker config create traefik_dynamic traefik/dynamic.yml
  fi

  ok "swarm resources ready"
}

# Deploy a stack, unless its compose file is absent -- a startup-mode sparse
# checkout carries only the stacks needed to boot the cluster.
deploy() {
  local file="$1" stack="$2"
  if [[ ! -f "$file" ]]; then
    skip "$file not in this checkout; skipping"
    return
  fi
  run docker stack deploy -c "$file" "$stack"
}

stage_traefik()     { info "traefik";     deploy traefik/compose.yml "$TRAEFIK_STACK"; }
stage_filebrowser() { info "filebrowser"; deploy apps/filebrowser/compose.yml "$FILES_STACK"; }
stage_monitor()     { info "komodo";      deploy apps/monitor/compose.yml "$MONITOR_STACK"; }

# Headplane authenticates to headscale with an API key. Leaving it blank
# renders a config whose UI cannot read anything, so mint one and keep it.
# A headscale API key is <prefix>.<secret>, and apikeys list shows prefixes.
# That is enough to tell a live key from one left over after the database was
# replaced -- which otherwise sits in bootstrap.env looking perfectly valid.
headplane_key_live() {
  local container="$1" key="$2" prefix
  prefix="${key%%.*}"
  [[ -n "$prefix" && "$prefix" != "$key" ]] || return 1
  host_eval "docker exec $container headscale apikeys list 2>/dev/null" | grep -qF "$prefix"
}

ensure_headplane_key() {
  local container out key
  (( DRY_RUN )) && { skip "would check headplane's API key, and mint one if needed"; return 1; }

  container="$(host_eval "docker ps -qf name=${VPN_STACK}_core | head -1")" || container=""
  [[ -n "$container" ]] || return 1

  if [[ -n "${HEADPLANE_API_KEY:-}" ]]; then
    if headplane_key_live "$container" "$HEADPLANE_API_KEY"; then
      skip "headplane's API key is still valid"
      return 1
    fi
    warn "the stored headplane API key is not known to this headscale (its database was probably replaced); minting a new one"
  fi

  may_fix "Headplane needs an API key to read headscale. Mint one?" || return 1

  out="$(host_eval "docker exec $container headscale apikeys create --expiration 90d 2>&1")" || true
  # The key is printed alone on a line; take the longest token that carries the
  # prefix.secret shape rather than anything long-ish in a log line.
  key="$(printf '%s' "$out" | tr -d '\r' | grep -Eo '[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{20,}' | tail -1)"
  [[ -n "$key" ]] || key="$(printf '%s' "$out" | tr -d '\r' | grep -Eo '^[A-Za-z0-9_.-]{30,}$' | tail -1)"
  if [[ -z "$key" ]]; then
    warn "could not mint a headplane API key. headscale said:"
    printf '%s\n' "$out" | tail -5 | sed 's/^/      /' >&2
    return 1
  fi

  HEADPLANE_API_KEY="$key"
  write_env
  ok "minted a headplane API key (90d) and saved it to $ENV_FILE"
  return 0
}

vpn_config_hashes() {
  (( DRY_RUN )) && return 0
  [[ -f apps/vpn/config.yaml ]] && export HEADSCALE_CONFIG_HASH="$(file_hash apps/vpn/config.yaml)"
  [[ -f apps/vpn/headplane_config.yaml ]] && export HEADPLANE_CONFIG_HASH="$(file_hash apps/vpn/headplane_config.yaml)"
  return 0
}

stage_vpn() {
  info "headscale"
  # compose reads these as files, so they are rendered rather than interpolated
  [[ -f apps/vpn/config.yaml.template ]] && render apps/vpn/config.yaml.template
  [[ -f apps/vpn/headplane_config.yaml.template ]] && render apps/vpn/headplane_config.yaml.template
  vpn_config_hashes
  deploy apps/vpn/compose.yml "$VPN_STACK"

  # The key can only be minted once headscale is running, so re-render and
  # redeploy when we get one.
  if ensure_headplane_key; then
    render apps/vpn/headplane_config.yaml.template
    vpn_config_hashes
    deploy apps/vpn/compose.yml "$VPN_STACK"
  fi
}

# headscale >= 0.24 wants a numeric id for --user and rejects the name:
#   invalid argument "admin" for "-u, --user" flag: strconv.ParseUint
# Older builds take the name. Resolve to an id, and let the caller fall back.
headscale_user_id() {
  local container="$1" name="$2"
  host_eval "docker exec $container headscale users list --output json 2>/dev/null" \
    | tr '{' '\n' \
    | grep "\"name\":\"$name\"" \
    | grep -o '"id":"\?[0-9]\+' \
    | grep -o '[0-9]\+' \
    | head -1
}

mesh_addr_held() {
  host_eval "ip -4 -oneline addr show 2>/dev/null | grep -qw $MESH_ADDR"
}

# Install tailscale, mint a headscale pre-auth key, and join. Each step asks
# first, so a plain run still lets the operator do it by hand.
join_mesh() {
  local where="${SSH_TARGET:-this host}" container key out

  if ! host_eval 'command -v tailscale >/dev/null 2>&1'; then
    may_fix "tailscale is not installed on $where. Install it (runs Tailscale's installer: curl -fsSL https://tailscale.com/install.sh | sh)?" \
      || return 1
    host_run 'curl -fsSL https://tailscale.com/install.sh | sh'
    record "installed_tailscale"
  fi

  container="$(host_eval "docker ps -qf name=${VPN_STACK}_core | head -1")" || container=""
  [[ -n "$container" ]] || { warn "no ${VPN_STACK}_core container is running, so no pre-auth key can be minted"; return 1; }

  may_fix "Enrol $where in headscale as user '$MESH_USER'?" || return 1

  # Already-exists is the normal case on a re-run, so its failure is not fatal.
  host_eval "docker exec $container headscale users create $MESH_USER" >/dev/null 2>&1 || true

  local ref
  ref="$(headscale_user_id "$container" "$MESH_USER")"
  [[ -n "$ref" ]] || ref="$MESH_USER"   # older headscale takes the name

  # Keep stderr: when this fails it is the only thing that explains why, and
  # headscale's CLI has changed shape across releases.
  out="$(host_eval "docker exec $container headscale preauthkeys create --user $ref --reusable --expiration 1h --output json 2>&1")" || true
  key="$(printf '%s' "$out" | grep -o '"key":"[^"]*"' | head -1 | cut -d'"' -f4)"
  if [[ -z "$key" ]]; then
    out="$(host_eval "docker exec $container headscale preauthkeys create --user $ref --reusable --expiration 1h 2>&1")" || true
    key="$(printf '%s' "$out" | tail -1 | tr -d '[:space:]')"
    # A usable key is a long opaque token; anything else is an error message.
    [[ "$key" =~ ^[A-Za-z0-9]{20,}$ ]] || key=""
  fi

  if [[ -z "$key" ]]; then
    warn "could not mint a pre-auth key from $container. headscale said:"
    printf '%s\n' "$out" | tail -5 | sed 's/^/      /' >&2
    return 1
  fi

  # Without a timeout this retries an unreachable control server forever,
  # which looks like the command doing nothing at all.
  host_run "sudo tailscale up --timeout 45s --login-server https://$VPN_SUBDOMAIN.$DOMAIN --authkey $key >/dev/null" \
    || { warn "tailscale up did not complete. Check that https://$VPN_SUBDOMAIN.$DOMAIN resolves to this host and serves a valid certificate: curl -sS -o /dev/null -w '%{http_code}\\n' https://$VPN_SUBDOMAIN.$DOMAIN/health"; return 1; }
  return 0
}

# Show what to run, then wait rather than exiting: the operator finishes the
# join in another terminal and the run carries on from where it paused.
wait_for_mesh() {
  cat >&2 <<EOF

${SSH_TARGET:-This host} does not hold $MESH_ADDR yet, so the NFS server cannot bind it.
Run this on ${SSH_TARGET:-this host}, then come back:

  C=\$(docker ps -qf name=${VPN_STACK}_core)
  docker exec \$C headscale users list          # note the id of $MESH_USER
  docker exec \$C headscale preauthkeys create --user <id> --reusable --expiration 1h
  sudo tailscale up --timeout 45s --login-server https://$VPN_SUBDOMAIN.$DOMAIN --authkey <key>

EOF
  [[ -t 0 ]] || return 1

  while true; do
    printf '    Press Enter once joined, or Ctrl-C to stop: ' >&2
    read -r _ || return 1
    mesh_addr_held && return 0
    warn "${SSH_TARGET:-this host} still does not hold $MESH_ADDR"
  done
}

# headscale allocates in order, so the address is not ours to choose.
check_mesh_addr() {
  local got
  got="$(host_eval 'tailscale ip -4 2>/dev/null | head -1' | tr -d '[:space:]')" || got=""
  [[ -z "$got" || "$got" == "$MESH_ADDR" ]] && return 0
  die "joined the mesh, but headscale assigned $got rather than $MESH_ADDR. Set MESH_ADDR to $got (re-run with --reconfigure): the NFS server binds it, and the clients mount it."
}

stage_mesh() {
  info "mesh address"

  if (( DRY_RUN )); then
    skip "would check that $MESH_ADDR is assigned to ${SSH_TARGET:-this host}, and offer to join if not"
    return
  fi

  if docker_is_remote; then
    skip "docker is remote and --ssh was not given; cannot check for $MESH_ADDR -- verify on the manager node"
    return
  fi

  if mesh_addr_held; then
    ok "$MESH_ADDR is assigned to ${SSH_TARGET:-this host}"
    return
  fi

  if join_mesh && mesh_addr_held; then
    ok "joined the mesh as $MESH_ADDR"
    return
  fi
  check_mesh_addr

  if wait_for_mesh; then
    ok "$MESH_ADDR is assigned to ${SSH_TARGET:-this host}"
    return
  fi
  blocker "not joined to the mesh"
}

stage_nfs() {
  info "nfs server"
  [[ -f apps/nfs/compose.yml ]] || { skip "apps/nfs/compose.yml not in this checkout; skipping"; return; }
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
  for svc in "${TRAEFIK_STACK}_core" "${VPN_STACK}_core" "${VPN_STACK}_web" \
             "${FILES_STACK}_core" "${MONITOR_STACK}_db" "${MONITOR_STACK}_core" \
             "${MONITOR_STACK}_agent" "${MONITOR_STACK}_mcp"; do
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

  headscale   https://$VPN_SUBDOMAIN.$DOMAIN     admin at /admin
  filebrowser https://$FILES_SUBDOMAIN.$DOMAIN     password: docker service logs ${FILES_STACK}_core
  komodo      https://$MONITOR_SUBDOMAIN.$DOMAIN

EOF
}

# ------------------------------------------------------------------ main ---

# --- modes that replace the stage run --------------------------------------

# Forget the answers. Deliberately does not touch the cluster: the next run
# asks again and redeploys over whatever is there.
do_reset_config() {
  info "resetting configuration"
  local f removed=0
  for f in "$ENV_FILE" apps/vpn/config.yaml apps/vpn/headplane_config.yaml; do
    if [[ -f "$f" ]]; then
      run rm -f "$f"
      (( DRY_RUN )) || ok "removed $f"
      removed=1
    else
      skip "$f is not there"
    fi
  done
  (( removed )) && printf '    Run the script again to answer afresh.\n'
  return 0
}

# Undo the host changes this script recorded making, newest concern first.
# Nothing that was already present when we arrived was recorded, so nothing
# that predates the bootstrap is touched.
undo_host() {
  local state pm pkg was
  state="$(host_eval "sudo cat $STATE_FILE 2>/dev/null")" || state=""
  if [[ -z "$state" ]]; then
    skip "no record of host changes; nothing to undo"
    return 0
  fi

  printf '    this script recorded making these changes:\n'
  printf '%s\n' "$state" | sed 's/^/      /'

  if grep -qx 'installed_tailscale' <<< "$state"; then
    host_run 'sudo tailscale down 2>/dev/null; sudo tailscale logout 2>/dev/null' || true
    host_run 'sudo apt-get purge -y tailscale tailscale-archive-keyring 2>/dev/null || sudo pacman -Rns --noconfirm tailscale 2>/dev/null' || true
    host_run 'sudo rm -f /etc/apt/sources.list.d/tailscale.list /usr/share/keyrings/tailscale-archive-keyring.gpg' || true
  fi

  # After the stacks are gone, so nothing is scheduled onto a dying swarm.
  if grep -qx 'swarm_init' <<< "$state"; then
    host_run 'docker swarm leave --force' || true
  fi

  while read -r _ pm pkg; do
    [[ -n "${pkg:-}" ]] || continue
    case "$pm" in
      apt-get) host_run "sudo apt-get purge -y $pkg && sudo apt-get autoremove -y" || true ;;
      pacman)  host_run "sudo pacman -Rns --noconfirm $pkg" || true ;;
    esac
  done < <(grep '^installed_package ' <<< "$state" || true)

  if grep -qx 'created_dir /opt/vpn/data' <<< "$state"; then
    if (( WITH_DATA )); then
      host_run 'sudo rm -rf /opt/vpn/data'
    else
      skip "/opt/vpn/data kept (holds headscale's database; --with-data removes it)"
    fi
  fi

  was="$(printf '%s\n' "$state" | grep -m1 '^hostname_was ' | cut -d' ' -f2-)"
  if [[ -n "$was" ]]; then
    if host_eval 'command -v hostnamectl >/dev/null 2>&1'; then
      host_run "sudo hostnamectl set-hostname $was"
    else
      host_run "printf '%s\n' $was | sudo tee /etc/hostname >/dev/null && sudo hostname $was"
    fi
  fi

  host_run "sudo rm -f $STATE_FILE"
  ok "host changes undone"
}

# Remove what this script created. Host changes -- packages, the hostname,
# tailscale, the swarm itself -- are left alone: they are not ours to undo.
do_uninstall() {
  info "uninstalling from ${SSH_TARGET:-this machine}"

  local stacks=("$MONITOR_STACK" "$FILES_STACK" "$VPN_STACK" "$TRAEFIK_STACK")
  local present=() volumes=() st
  for st in "${stacks[@]}"; do
    docker stack ls --format '{{.Name}}' 2>/dev/null | grep -qx "$st" && present+=("$st")
  done

  volumes=("${MONITOR_STACK}_mongo-data" "${MONITOR_STACK}_mongo-config" \
           "${MONITOR_STACK}_keys" "${FILES_STACK}_config" nfs_data)

  printf '    stacks:  %s\n' "${present[*]:-none}"
  printf '    network: web-net\n'
  printf '    secrets: liaxum_crt liaxum_key\n'
  printf '    configs: traefik_dynamic, and the vpn config objects\n'
  printf '    local:   %s and the rendered vpn configs\n' "$ENV_FILE"
  if (( WITH_HOST )); then
    printf '    %shost:    packages, swarm membership, tailscale and the hostname this script changed%s\n' "$RED" "$OFF"
  else
    printf '    host:    untouched (pass --with-host to undo what this script changed)\n'
  fi
  if (( WITH_DATA )); then
    printf '    %svolumes: %s%s\n' "$RED" "${volumes[*]}" "$OFF"
    printf '    %sthis destroys the komodo database, the keys and the shared files%s\n' "$RED" "$OFF"
  else
    printf '    volumes: kept (pass --with-data to remove them too)\n'
  fi

  if (( ! DRY_RUN )); then
    if [[ -t 0 ]]; then
      local reply
      read -rp "    Type the manager hostname ($MANAGER_HOSTNAME) to confirm: " reply
      [[ "$reply" == "$MANAGER_HOSTNAME" ]] || die "not confirmed; nothing was removed"
    else
      die "uninstall needs a terminal to confirm on"
    fi
  fi

  # Guarded: bash 3.2, which macOS still ships, treats "${empty[@]}" as an
  # unbound variable under set -u.
  if (( ${#present[@]} > 0 )); then
    for st in "${present[@]}"; do run docker stack rm "$st"; done
  fi

  # Networks and volumes stay busy until the tasks actually stop.
  if (( ! DRY_RUN )) && (( ${#present[@]} > 0 )); then
    printf '    waiting for tasks to stop' >&2
    local i
    for i in $(seq 1 30); do
      docker service ls --format '{{.Name}}' 2>/dev/null | grep -qE "^($(IFS='|'; echo "${present[*]}"))_" || break
      printf '.' >&2; sleep 2
    done
    printf '\n' >&2
  fi

  [[ -f apps/nfs/compose.yml ]] && run docker compose -f apps/nfs/compose.yml down

  local obj
  for obj in liaxum_crt liaxum_key; do
    secret_exists "$obj" && run docker secret rm "$obj"
  done
  for obj in $(docker config ls --format '{{.Name}}' 2>/dev/null | grep -E '^(traefik_dynamic|headscale_config_|headplane_config_)' || true); do
    run docker config rm "$obj"
  done
  net_exists web-net && run docker network rm web-net

  if (( WITH_DATA )); then
    local v
    for v in "${volumes[@]}"; do
      docker volume inspect "$v" >/dev/null 2>&1 && run docker volume rm "$v"
    done
    warn "volumes on other nodes are not reachable from here; remove ${MONITOR_STACK}_keys on each worker"
  fi

  (( WITH_HOST )) && undo_host

  # Last, because everything above needs the settings to know what to remove.
  do_reset_config

  ok "uninstalled"
  return 0
}

load_env

if (( RESET_CONFIG )); then do_reset_config; exit 0; fi
if (( UNINSTALL )); then
  [[ -n "${MANAGER_HOSTNAME:-}" ]] || die "no settings found, so there is nothing to identify. Uninstall needs $ENV_FILE."
  require_settings
  do_uninstall
  exit 0
fi

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
