#!/usr/bin/env bash
#
# Join a worker node to the cluster: mesh first, then the swarm.
#
# The order matters as much as it does on the manager. The swarm manager
# advertises its mesh address, so 100.64.0.1:2377 is unreachable until this
# node is on the tailnet -- and a worker that joins advertising its own LAN or
# public address puts the overlay back on the internet, which is the thing the
# mesh exists to avoid. So: tailscale, then swarm, both on mesh addresses.
#
#   ./scripts/join-worker.sh                        # run on the worker itself
#   ./scripts/join-worker.sh --ssh user@worker      # repo here, worker there
#   ./scripts/join-worker.sh --manager root@vps     # read the join token itself
#   ./scripts/join-worker.sh --from swarm           # resume from a stage
#   ./scripts/join-worker.sh --only verify          # run a single stage
#   ./scripts/join-worker.sh --dry-run              # print what would run
#   ./scripts/join-worker.sh --leave                # undo: swarm, then mesh
#
# Cluster-wide settings -- domain, the manager's mesh address, the headscale
# user -- are read from bootstrap.env when it is there, so the same repo that
# built the manager joins workers without being asked twice. This script never
# writes that file. Its own answers go to worker.env, or to
# worker-<target>.env when --ssh is given, so several workers can be driven
# from one checkout.
#
# --manager is optional. With it, the pre-auth key and the join token are read
# off the manager over ssh and nothing has to be copied by hand. Without it,
# the node asks headscale to register it and prints the key to paste into
# Headplane, then asks for the join token.
#
# Every stage is idempotent: re-running is always safe.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

STAGES=(config host mesh swarm verify)

# Cluster-wide answers, written by bootstrap.sh. Read only, never written.
ENV_FILE="${ENV_FILE:-bootstrap.env}"

# What this script changed on the worker, so --leave can reverse exactly that.
STATE_FILE="${STATE_FILE:-/var/lib/server-docker-worker.state}"

SSH_TARGET=""
MANAGER_SSH=""
WITH_HOST_SETUP=0
RECONFIGURE=0
DRY_RUN=0
LEAVE=0
FROM_STAGE=""
ONLY_STAGE=""

# Filled in by the mesh stage: the address headscale actually handed out.
WORKER_MESH_ADDR=""

RED=$'\033[31m'; YELLOW=$'\033[33m'; GREEN=$'\033[32m'; BOLD=$'\033[1m'; OFF=$'\033[0m'
[[ -t 1 ]] || { RED=""; YELLOW=""; GREEN=""; BOLD=""; OFF=""; }

info()  { printf '%s==>%s %s\n' "$BOLD" "$OFF" "$*"; }
ok()    { printf '%s  ok%s %s\n' "$GREEN" "$OFF" "$*"; }
skip()  { printf '    -- %s\n' "$*"; }
warn()  { printf '%swarn%s %s\n' "$YELLOW" "$OFF" "$*" >&2; }
die()   { printf '%sfail%s %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"; }

have() { command -v "$1" >/dev/null 2>&1; }

while (( $# )); do
  case "$1" in
    --ssh)             SSH_TARGET="${2:?--ssh needs user@host}"; shift ;;
    --manager)         MANAGER_SSH="${2:?--manager needs user@host}"; shift ;;
    --with-host-setup) WITH_HOST_SETUP=1 ;;
    --reconfigure)     RECONFIGURE=1 ;;
    --dry-run)         DRY_RUN=1 ;;
    --leave)           LEAVE=1 ;;
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

# Fail on the connection itself rather than letting every later check come back
# false and get reported as a missing package or an absent interface.
ssh_targets=()
[[ -n "$SSH_TARGET"  ]] && ssh_targets+=("$SSH_TARGET")
[[ -n "$MANAGER_SSH" ]] && ssh_targets+=("$MANAGER_SSH")
# Guarded: bash 3.2, which is what macOS ships, errors on an empty array
# expansion under set -u.
if (( ${#ssh_targets[@]} > 0 )); then
  have ssh || die "--ssh/--manager need an ssh client on this machine"
  for target in "${ssh_targets[@]}"; do
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" true 2>/dev/null \
      || die "cannot reach $target over ssh without a password. Check the host, and that your key is loaded."
  done
fi

# One answers file per worker, so driving several from one checkout does not
# have them overwrite each other.
if [[ -n "$SSH_TARGET" ]]; then
  WORKER_ENV_FILE="${WORKER_ENV_FILE:-worker-$(printf '%s' "$SSH_TARGET" | tr -c 'A-Za-z0-9._-' '-').env}"
else
  WORKER_ENV_FILE="${WORKER_ENV_FILE:-worker.env}"
fi

WHERE="${SSH_TARGET:-this machine}"

# --------------------------------------------------------------- helpers ---

# Read-only check on the worker. Always executes, including under --dry-run:
# stage logic depends on the answer.
host_eval() {
  if [[ -n "$SSH_TARGET" ]]; then ssh -o BatchMode=yes "$SSH_TARGET" "$1"; else eval "$1"; fi
}

# Mutating command on the worker. Honours --dry-run, and asks for a terminal
# when remote so sudo can prompt.
host_run() {
  if (( DRY_RUN )); then
    printf '    would run%s: %s\n' "${SSH_TARGET:+ on $SSH_TARGET}" "$1"
    return
  fi
  if [[ -n "$SSH_TARGET" ]]; then ssh -t "$SSH_TARGET" "$1"; else eval "$1"; fi
}

# Read-only check on the manager. Fails when --manager was not given, which is
# how every caller decides whether to fall back to asking the operator.
mgr_eval() {
  [[ -n "$MANAGER_SSH" ]] || return 1
  ssh -o BatchMode=yes "$MANAGER_SSH" "$1"
}

manager_reachable() { [[ -n "$MANAGER_SSH" ]]; }

# A precondition this run cannot meet. Fatal normally; under --dry-run it is
# information, because seeing the whole plan is more useful than stopping at
# the first thing that is not ready yet.
blocker() {
  (( DRY_RUN )) && { warn "$*"; return 0; }
  die "$*"
}

confirm() {
  local reply def="${2:-no}" hint="[y/N]"
  [[ "$def" == yes ]] && hint="[Y/n]"
  [[ -t 0 ]] || return 1
  read -rp "    $1 $hint: " reply
  reply="${reply:-$def}"
  [[ "$reply" =~ ^[Yy] ]]
}

# May this run change the worker? True with --with-host-setup, or when the
# operator says yes to the specific change being proposed. Defaults to yes:
# preparing the node is what this script is for, and declining is one key.
may_fix() {
  (( DRY_RUN )) && { printf '    would ask: %s\n' "$1"; return 0; }
  (( WITH_HOST_SETUP )) || confirm "$1" yes
}

# Note a change we made on the worker, so --leave can undo exactly that.
# Anything that was already there when we arrived is never recorded, and so is
# never removed.
record() {
  (( DRY_RUN )) && return 0
  host_run "printf '%s\n' '$1' | sudo tee -a $STATE_FILE >/dev/null" || true
}

recorded() { host_eval "sudo grep -qxF '$1' $STATE_FILE 2>/dev/null"; }

recorded_value() {
  host_eval "sudo grep -m1 '^$1 ' $STATE_FILE 2>/dev/null" | cut -d' ' -f2-
}

# Ask for one setting, or reuse what is already known. Precedence: an exported
# variable, then the env files, then the default shown in the prompt.
ask() {
  local var="$1" prompt="$2" default="${3:-}" optional="${4:-}"
  local current="${!var:-}" reply

  if [[ -n "$current" ]] && (( ! RECONFIGURE )); then
    export "$var=$current"
    return
  fi

  local suggestion="${current:-$default}"

  if [[ ! -t 0 ]]; then
    [[ -n "$suggestion" || -n "$optional" ]] || die "$var is unset and there is no terminal to ask on. Set it in $WORKER_ENV_FILE or export it."
    export "$var=$suggestion"
    return
  fi

  if [[ -n "$suggestion" ]]; then
    read -rp "    $prompt [$suggestion]: " reply
  else
    read -rp "    $prompt: " reply
  fi

  reply="${reply:-$suggestion}"
  [[ -n "$reply" || -n "$optional" ]] || die "$var cannot be empty"
  export "$var=$reply"
}

# Parsed rather than sourced: a value already exported must win over the stored
# one, and nothing in these files should be able to execute.
load_env_file() {
  [[ -f "$1" ]] || return 0
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    key="${line%%=*}"; val="${line#*=}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    [[ -n "${!key:-}" ]] || export "$key=$val"
  done < "$1"
}

write_worker_env() {
  (( DRY_RUN )) && return 0
  umask 077
  cat > "$WORKER_ENV_FILE" <<EOF
# Written by scripts/join-worker.sh for ${SSH_TARGET:-this machine}. Gitignored.
# The join token is deliberately not here: it rotates, and a stale one fails
# in a way that reads like a network problem.
DOMAIN=$DOMAIN
VPN_SUBDOMAIN=$VPN_SUBDOMAIN
MESH_ADDR=$MESH_ADDR
MESH_USER=$MESH_USER
MONITOR_STACK=$MONITOR_STACK
WORKER_HOSTNAME=$WORKER_HOSTNAME
EOF
  ok "saved $WORKER_ENV_FILE"
}

# The first tailscale address the worker holds, empty when it is not on the
# mesh. Trust tailscale over `ip addr`: the interface can lag the assignment.
worker_mesh_addr() {
  host_eval 'tailscale ip -4 2>/dev/null | head -1' 2>/dev/null | tr -d '[:space:]' || true
}

swarm_state() {
  host_eval "docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null" | tr -d '[:space:]' || true
}

# ---------------------------------------------------------------- stages ---

# Stages after config read these. --from and --only skip config, so without
# this a missing answer surfaces as "unbound variable" from somewhere deep
# rather than as the one line that says which setting is missing.
require_settings() {
  local v
  for v in DOMAIN VPN_SUBDOMAIN MESH_ADDR MESH_USER MONITOR_STACK WORKER_HOSTNAME; do
    [[ -n "${!v:-}" ]] || die "$v is not set. Run '$0 --only config' first, or export it."
  done
  export VPN_STACK="${VPN_STACK:-vpn}"
}


stage_config() {
  info "settings"
  [[ -f "$ENV_FILE" ]] && skip "read cluster settings from $ENV_FILE"
  [[ -f "$WORKER_ENV_FILE" ]] && skip "loaded $WORKER_ENV_FILE"

  ask DOMAIN         "Domain serving the stacks"          "liaxum.fr"
  ask VPN_SUBDOMAIN  "Subdomain headscale answers on"     "vpn"
  ask MESH_ADDR      "The manager's address on the mesh"  "100.64.0.1"
  ask MESH_USER      "Headscale user to enrol this node as" "admin"
  ask MONITOR_STACK  "Name of the monitoring stack"       "monitor"

  local current
  current="$(host_eval 'hostname -s' 2>/dev/null)" || current=""
  ask WORKER_HOSTNAME "Hostname this node joins the swarm as" "${current:-worker}"
  [[ "$WORKER_HOSTNAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || die "WORKER_HOSTNAME '$WORKER_HOSTNAME' is not a valid hostname"

  write_worker_env
}

# The swarm records a node's hostname when it joins and never revisits it, so
# this has to be settled before the swarm stage rather than after.
ensure_hostname() {
  local current
  current="$(host_eval 'hostname -s' 2>/dev/null)" || current=""
  [[ -n "$current" ]] || { warn "could not read the worker's hostname"; return; }
  [[ "$current" == "$WORKER_HOSTNAME" ]] && { skip "hostname is already $WORKER_HOSTNAME"; return; }

  if [[ "$(swarm_state)" == active ]]; then
    warn "$WHERE is called $current, but WORKER_HOSTNAME is $WORKER_HOSTNAME. It already belongs to a swarm, which recorded $current at join time -- renaming now would not change 'docker node ls'. Set WORKER_HOSTNAME to $current instead, or run --leave first."
    return
  fi

  may_fix "$WHERE is called $current but WORKER_HOSTNAME is $WORKER_HOSTNAME. Rename the host?" \
    || { blocker "$WHERE is called $current but WORKER_HOSTNAME is $WORKER_HOSTNAME."; return; }

  if host_eval 'command -v hostnamectl >/dev/null 2>&1'; then
    host_run "sudo hostnamectl set-hostname $WORKER_HOSTNAME"
  else
    host_run "printf '%s\\n' $WORKER_HOSTNAME | sudo tee /etc/hostname >/dev/null && sudo hostname $WORKER_HOSTNAME"
  fi
  record "hostname_was $current"
  # Without this, every later sudo prints "unable to resolve host".
  host_run "grep -qw $WORKER_HOSTNAME /etc/hosts || printf '127.0.1.1 %s\\n' $WORKER_HOSTNAME | sudo tee -a /etc/hosts >/dev/null"
}

ensure_docker() {
  host_eval 'command -v docker >/dev/null 2>&1' && { skip "docker present"; return; }

  may_fix "docker is not installed on $WHERE. Install it (runs Docker's installer: curl -fsSL https://get.docker.com | sh)?" \
    || { blocker "docker is not installed on $WHERE. Install it, or re-run with --with-host-setup."; return; }

  host_run 'curl -fsSL https://get.docker.com | sh'
  host_run 'sudo systemctl enable --now docker' || true
  record "installed_docker"
}

# The keys volume is an NFS mount, so a worker without a client cannot start
# the Komodo agent -- it fails at mount time, which reads as a scheduling
# problem rather than a missing package.
ensure_nfs_client() {
  host_eval 'command -v mount.nfs4 >/dev/null 2>&1' && { skip "NFS client utilities present"; return; }

  may_fix "NFS client utilities are missing on $WHERE. Install them?" \
    || { blocker "NFS client utilities missing on $WHERE. Install nfs-common (Debian/Ubuntu) or nfs-utils (Arch), or re-run with --with-host-setup."; return; }

  if host_eval 'command -v apt-get >/dev/null 2>&1'; then
    host_run 'sudo apt-get update && sudo apt-get install -y nfs-common'
    record "installed_package apt-get nfs-common"
  elif host_eval 'command -v pacman >/dev/null 2>&1'; then
    host_run 'sudo pacman -S --needed --noconfirm nfs-utils'
    record "installed_package pacman nfs-utils"
  elif host_eval 'command -v dnf >/dev/null 2>&1'; then
    host_run 'sudo dnf install -y nfs-utils'
    record "installed_package dnf nfs-utils"
  else
    die "cannot install NFS client utilities on $WHERE: no apt-get, pacman or dnf found"
  fi
}

# Only the client module here: nfsd is the server's, and it runs on the
# manager. A worker that loads nfsd gains nothing and exports nothing.
ensure_nfs_module() {
  host_eval 'lsmod 2>/dev/null | grep -q "^nfs "' && { skip "nfs module loaded"; return; }

  may_fix "the nfs client module is not loaded on $WHERE. Load it?" \
    || { warn "nfs is not loaded on $WHERE. Load it with: sudo modprobe nfs"; return; }

  host_run 'sudo modprobe nfs'
  # Survive a reboot, or the node comes back unable to mount the keys volume.
  host_run "printf 'nfs\\n' | sudo tee /etc/modules-load.d/nfs-client.conf >/dev/null"
  record "loaded_nfs_module"
}

stage_host() {
  info "host prerequisites on $WHERE"
  ensure_hostname
  ensure_docker
  ensure_nfs_client
  ensure_nfs_module
  ok "$WHERE ready"
}

ensure_tailscale() {
  host_eval 'command -v tailscale >/dev/null 2>&1' && { skip "tailscale present"; return 0; }

  may_fix "tailscale is not installed on $WHERE. Install it (runs Tailscale's installer: curl -fsSL https://tailscale.com/install.sh | sh)?" \
    || return 1

  host_run 'curl -fsSL https://tailscale.com/install.sh | sh'
  record "installed_tailscale"
}

# tailscaled verifies the control server against the system trust store, the
# same one curl uses. If curl cannot verify it, neither can tailscale, and the
# join sits until it times out with nothing useful to say. Ask first.
check_control_reachable() {
  local url="https://$VPN_SUBDOMAIN.$DOMAIN/health"
  host_eval "curl -sS -o /dev/null --max-time 10 $url >/dev/null 2>&1" && return 0

  local why
  why="$(host_eval "curl -sS -o /dev/null --max-time 10 $url 2>&1 | head -3")" || true
  warn "$WHERE cannot reach $url, and tailscale uses the same trust store:"
  printf '%s\n' "${why:-(no output)}" | sed 's/^/      /' >&2
  if printf '%s' "$why" | grep -qi 'certificate\|SSL'; then
    warn "that is a certificate problem on the manager, not on this node. A leaf without its intermediates fails here even though browsers accept it -- see 'Certificates' in the README."
  fi
  return 1
}

# headscale's user id, resolved off the manager. Lifted from bootstrap.sh,
# where it was debugged against a live instance: the output shape has changed
# across releases, so try json, then the table, then a single unambiguous row.
#
# Every pipeline is guarded with "|| true": a grep that matches nothing exits
# non-zero, and under set -e with pipefail that aborts the function before the
# next parser runs -- on bash 3.2, which macOS ships, though not on bash 5.
headscale_user_id() {
  local container="$1" name="$2" out id

  out="$(mgr_eval "docker exec $container headscale users list --output json 2>/dev/null")" || out=""
  id="$(printf '%s' "$out" | tr '{' '\n' | grep "\"name\":\"$name\"" \
        | grep -o '"id":"\?[0-9]\+' | grep -o '[0-9]\+' | head -1)" || true
  [[ -n "$id" ]] && { printf '%s' "$id"; return 0; }

  # Every build prints a table: "1 | admin | 2026-08-24". Take the leading id
  # from the row whose name column matches.
  out="$(mgr_eval "docker exec $container headscale users list 2>/dev/null")" || out=""
  id="$(printf '%s' "$out" | awk -v n="$name" -F'[|[:space:]]+' \
        '{ for (i = 1; i <= NF; i++) if ($i == n && $1 ~ /^[0-9]+$/) { print $1; exit } }' | head -1)" || true
  [[ -n "$id" ]] && { printf '%s' "$id"; return 0; }

  # Neither shape matched. A fresh install has exactly one user, so a single
  # unambiguous id is safe to take -- and stays right if that user is not
  # number one. Two or more and we would be guessing, so we do not.
  local ids count
  ids="$(printf '%s' "$out" | grep -oE '^[[:space:]]*[0-9]+[[:space:]]*\|' | tr -cd '0-9\n')" || true
  count="$(printf '%s\n' "$ids" | grep -c '[0-9]' || true)"
  if [[ "$count" == "1" ]]; then
    printf '%s' "$(printf '%s' "$ids" | tr -d '[:space:]')"
    return 0
  fi
  return 0
}

# Ask the manager for a pre-auth key. Best effort: without --manager, or when
# headscale's CLI has moved again, the caller falls back to registering the
# node through Headplane instead.
mint_preauth_key() {
  manager_reachable || return 1

  local container
  container="$(mgr_eval "docker ps -qf name=${VPN_STACK:-vpn}_core | head -1")" || container=""
  container="$(printf '%s' "$container" | tr -d '[:space:]')"
  [[ -n "$container" ]] || { warn "no headscale container running on $MANAGER_SSH; will register through Headplane instead"; return 1; }

  # 0.24 and later want a numeric id, older builds want the name, so resolve
  # one and keep the other as a fallback rather than picking a version.
  local ref out key
  local -a candidates
  ref="$(headscale_user_id "$container" "$MESH_USER")" || ref=""
  if [[ -n "$ref" ]]; then
    candidates=("$ref")
  else
    # A fresh install numbers the first user 1; try that, then the name.
    candidates=(1 "$MESH_USER")
  fi

  for ref in "${candidates[@]}"; do
    out="$(mgr_eval "docker exec $container headscale preauthkeys create --user $ref --reusable --expiration 1h --output json 2>&1")" || true
    key="$(printf '%s' "$out" | grep -o '"key":"[^"]*"' | head -1 | cut -d'"' -f4)" || true
    if [[ -z "$key" ]]; then
      out="$(mgr_eval "docker exec $container headscale preauthkeys create --user $ref --reusable --expiration 1h 2>&1")" || true
      key="$(printf '%s' "$out" | tail -1 | tr -d '[:space:]')" || true
      # A key is one long unbroken token. Hyphens and underscores are part of
      # it -- hskey-auth-... -- so only whitespace and length tell a key from
      # an error message.
      [[ "$key" =~ ^[A-Za-z0-9._-]{20,}$ ]] || key=""
    fi
    [[ -n "$key" ]] && { printf '%s' "$key"; return 0; }
  done

  warn "could not mint a pre-auth key on $MANAGER_SSH; will register through Headplane instead"
  return 1
}

# No key: bring tailscale up detached, fish the registration key out of its
# output, and let the operator approve it in Headplane. Headplane has no
# pre-auth key dialog, but its Machines page takes exactly this key.
register_via_headplane() {
  local log=/tmp/join-worker-tailscale.log

  # Detached on purpose: without a key, `tailscale up` blocks printing the
  # registration URL, and the URL is the thing we are here to read. setsid is
  # not on every image, so fall back to nohup.
  local detach='setsid'
  host_eval 'command -v setsid >/dev/null 2>&1' || detach='nohup'
  host_run "sudo rm -f $log && sudo sh -c '$detach tailscale up --login-server https://$VPN_SUBDOMAIN.$DOMAIN > $log 2>&1 < /dev/null &'"

  local i line url=""
  printf '    waiting for a registration key' >&2
  for i in $(seq 1 20); do
    # The log can hold more than one URL -- the control server is named in
    # other messages too -- so take the registration one, and only fall back
    # to "first https" when nothing matches.
    line="$(host_eval "sudo cat $log 2>/dev/null" \
            | grep -oE 'https://[^[:space:]]*(register|nodekey|hskey)[^[:space:]]*' | head -1)" || true
    [[ -n "$line" ]] || line="$(host_eval "sudo cat $log 2>/dev/null" \
            | grep -oE 'https://[^[:space:]]+' | head -1)" || true
    [[ -n "$line" ]] && { url="$line"; break; }
    printf '.' >&2
    sleep 3
  done
  printf '\n' >&2

  if [[ -z "$url" ]]; then
    warn "tailscale printed no registration URL. What it did say:"
    host_eval "sudo cat $log 2>/dev/null" | tail -5 | sed 's/^/      /' >&2
    return 1
  fi

  cat >&2 <<EOF

Register this node in Headplane:

  1. open https://$VPN_SUBDOMAIN.$DOMAIN/admin -> Machines -> Register Machine Key
  2. paste this, and pick the owner '$MESH_USER':

     $url

EOF
  return 0
}

# Wait for headscale to hand this node an address, however it was registered.
# A pre-auth join and an approved registration both end here.
wait_for_address() {
  local i got
  printf '    waiting for an address' >&2
  for i in $(seq 1 "${MESH_WAIT_TRIES:-40}"); do
    got="$(worker_mesh_addr)"
    if [[ -n "$got" ]]; then
      printf '\n' >&2
      WORKER_MESH_ADDR="$got"
      return 0
    fi
    printf '.' >&2
    sleep 3
  done
  printf '\n' >&2
  return 1
}

stage_mesh() {
  info "mesh"

  if (( DRY_RUN )); then
    skip "would install tailscale on $WHERE and join https://$VPN_SUBDOMAIN.$DOMAIN as '$MESH_USER'"
    return
  fi

  local existing
  existing="$(worker_mesh_addr)"
  if [[ -n "$existing" ]]; then
    WORKER_MESH_ADDR="$existing"
    ok "$WHERE is on the mesh as $WORKER_MESH_ADDR"
    return
  fi

  ensure_tailscale || { blocker "tailscale is not installed on $WHERE"; return; }
  check_control_reachable || { blocker "$WHERE cannot reach the control server (see above)"; return; }

  local key=""
  key="$(mint_preauth_key)" || key=""

  if [[ -n "$key" ]]; then
    # --timeout stops an unreachable control server being retried forever. But
    # it waits for the backend to reach Running -- DERP setup and all -- not
    # just for the handshake, and a first join routinely takes longer, so treat
    # a timeout as "not yet": the backend carries on after up returns.
    host_run "sudo tailscale up --timeout 120s --login-server https://$VPN_SUBDOMAIN.$DOMAIN --authkey $key >/dev/null" || true
  else
    register_via_headplane || { blocker "could not start a registration on $WHERE"; return; }
  fi

  if wait_for_address; then
    ok "joined the mesh as $WORKER_MESH_ADDR"
    return
  fi

  # Not a failure yet when a human still has to click approve in Headplane.
  if [[ -t 0 ]]; then
    while true; do
      printf '    Press Enter once the node is registered, or Ctrl-C to stop: ' >&2
      read -r _ || break
      WORKER_MESH_ADDR="$(worker_mesh_addr)"
      [[ -n "$WORKER_MESH_ADDR" ]] && { ok "joined the mesh as $WORKER_MESH_ADDR"; return; }
      warn "$WHERE still has no mesh address"
    done
  fi
  blocker "$WHERE did not get a mesh address"
}

# The token the manager prints, or the one the operator pastes. Never stored:
# it rotates, and a stale one fails in a way that reads like a network problem.
worker_join_token() {
  local token=""
  if manager_reachable; then
    token="$(mgr_eval 'docker swarm join-token -q worker 2>/dev/null' | tr -d '[:space:]')" || token=""
    [[ "$token" == SWMTKN-* ]] && { printf '%s' "$token"; return 0; }
    warn "could not read a worker token from $MANAGER_SSH"
  fi

  [[ -t 0 ]] || return 1
  cat >&2 <<EOF

Run this on the manager, and paste what it prints:

  docker swarm join-token -q worker

EOF
  read -rp "    Worker join token: " token
  token="$(printf '%s' "$token" | tr -d '[:space:]')"
  [[ "$token" == SWMTKN-* ]] || return 1
  printf '%s' "$token"
}

# What the manager tells this node its managers are, read from the worker
# itself. This is the advertised address, which is the one that matters: the
# manager's daemon listens on every interface, so joining over
# 100.64.0.1:2377 succeeds even when it advertises a public address -- and
# then hands this node that public address for overlay traffic. So a
# successful join proves nothing, and --manager is not needed to catch it.
check_remote_managers() {
  local addrs
  addrs="$(host_eval "docker info --format '{{range .Swarm.RemoteManagers}}{{.Addr}} {{end}}' 2>/dev/null")" || addrs=""
  addrs="$(printf '%s' "$addrs" | tr -s '[:space:]' ' ')"
  [[ -n "${addrs// /}" ]] || return 0        # older daemons omit the field

  case " $addrs " in
    *" $MESH_ADDR:"*) ok "the manager advertises $MESH_ADDR"; return 0 ;;
  esac

  warn "the swarm's manager is ${addrs% }, not $MESH_ADDR. That is the address it advertises, so this node's overlay traffic goes there rather than over the mesh -- the join succeeded because the manager listens on every interface, not because it is on the mesh."
  warn "fix it on the manager, then re-run --leave and this script:"
  warn "  ./scripts/bootstrap.sh --ssh <manager> --from mesh"
  return 1
}

# Refuse to join over anything but the mesh. Joining a manager that advertises
# its public address is what puts the overlay back on the internet, and it is
# fixed at init on the manager -- so it has to be caught here, not after.
check_manager_advertise() {
  manager_reachable || return 0
  local have
  have="$(mgr_eval "docker info --format '{{.Swarm.NodeAddr}}' 2>/dev/null" | tr -d '[:space:]')" || have=""
  [[ -n "$have" ]] || return 0
  [[ "$have" == "$MESH_ADDR" ]] && return 0

  warn "the manager advertises $have, not $MESH_ADDR. Workers join over that address and the overlay carries their traffic there, so this node would not use the mesh."
  warn "fix it on the manager first: ./scripts/bootstrap.sh --ssh $MANAGER_SSH --from mesh"
  return 1
}

stage_swarm() {
  info "swarm"

  if (( DRY_RUN )); then
    skip "would join $MESH_ADDR:2377 advertising this node's mesh address"
    return
  fi

  [[ -n "$WORKER_MESH_ADDR" ]] || WORKER_MESH_ADDR="$(worker_mesh_addr)"
  [[ -n "$WORKER_MESH_ADDR" ]] || { blocker "$WHERE has no mesh address, so it cannot reach $MESH_ADDR:2377. Run the mesh stage first."; return; }

  local state
  state="$(swarm_state)"
  if [[ "$state" == active ]]; then
    local addr
    addr="$(host_eval "docker info --format '{{.Swarm.NodeAddr}}' 2>/dev/null" | tr -d '[:space:]')" || addr=""
    if [[ -n "$addr" && "$addr" != "$WORKER_MESH_ADDR" ]]; then
      warn "$WHERE is in a swarm advertising $addr rather than its mesh address $WORKER_MESH_ADDR, so its overlay traffic does not use the mesh. Run --leave, then this script again."
    else
      skip "already in a swarm${addr:+, advertising $addr}"
    fi
    check_remote_managers || true
    return
  fi

  check_manager_advertise || { blocker "the manager does not advertise $MESH_ADDR"; return; }

  # 2377 is the control plane; without it the join hangs rather than failing.
  if ! host_eval "timeout 5 bash -c '</dev/tcp/$MESH_ADDR/2377' 2>/dev/null"; then
    blocker "$WHERE cannot reach $MESH_ADDR:2377 over the mesh. Check 'tailscale status' on both ends, and any firewall on the manager."
    return
  fi

  local token
  token="$(worker_join_token)" || { blocker "no worker join token"; return; }

  # --advertise-addr is the whole point: without it docker picks whatever
  # interface it likes, usually the LAN or public one, and the overlay leaves
  # the mesh even though the join itself went over it.
  host_run "docker swarm join --token $token --advertise-addr $WORKER_MESH_ADDR $MESH_ADDR:2377"
  record "swarm_joined"
  ok "joined the swarm as $WORKER_HOSTNAME, advertising $WORKER_MESH_ADDR"
  check_remote_managers || true
}

# The one thing nothing else proves: that this node can actually mount the
# manager's export over the mesh. Docker reports a failed volume mount as a
# scheduling problem, so testing it directly is the difference between a
# five-minute fix and an afternoon.
verify_nfs() {
  local mnt=/tmp/join-worker-nfs-probe

  if ! host_eval "timeout 5 bash -c '</dev/tcp/$MESH_ADDR/2049' 2>/dev/null"; then
    warn "$MESH_ADDR:2049 is not reachable from $WHERE. On the manager, the export is bound to the mesh address and ufw must allow it: sudo ufw allow in on tailscale0 to any port 2049 proto tcp"
    return 1
  fi

  local out
  out="$(host_run "sudo mkdir -p $mnt && sudo mount -t nfs4 -o nfsvers=4,nolock,soft,nosuid,nodev $MESH_ADDR:/monitor-keys $mnt 2>&1" 2>&1)" || {
    warn "mounting $MESH_ADDR:/monitor-keys failed:"
    printf '%s\n' "${out:-(no output)}" | tail -3 | sed 's/^/      /' >&2
    warn "the path is relative to the NFSv4 root, which the export pins to /shared with fsid=0. If this says 'no such file or directory', check that /shared/monitor-keys exists on the manager and that the export admits this node's address."
    return 1
  }

  local wrote=0
  host_run "sudo touch $mnt/.probe-$WORKER_HOSTNAME && sudo rm -f $mnt/.probe-$WORKER_HOSTNAME" && wrote=1
  host_run "sudo umount $mnt && sudo rmdir $mnt" || true

  (( wrote )) || { warn "mounted $MESH_ADDR:/monitor-keys but could not write to it"; return 1; }
  ok "mounted and wrote to $MESH_ADDR:/monitor-keys over the mesh"
}

stage_verify() {
  info "verifying"

  if (( DRY_RUN )); then
    skip "would check the mesh address, the swarm membership and a real NFS mount"
    return
  fi

  local failed=0

  WORKER_MESH_ADDR="$(worker_mesh_addr)"
  if [[ -n "$WORKER_MESH_ADDR" ]]; then
    ok "mesh address: $WORKER_MESH_ADDR"
  else
    warn "no mesh address"
    failed=1
  fi

  local state
  state="$(swarm_state)"
  if [[ "$state" == active ]]; then
    ok "swarm: $state"
  else
    warn "swarm: ${state:-unknown}"
    failed=1
  fi

  check_remote_managers || failed=1
  verify_nfs || failed=1

  if manager_reachable; then
    local row
    row="$(mgr_eval "docker node ls --format '{{.Hostname}} {{.Status}} {{.Availability}}' 2>/dev/null" | grep -w "$WORKER_HOSTNAME" | head -1)" || row=""
    if [[ -n "$row" ]]; then
      ok "docker node ls: $row"
    else
      warn "$WORKER_HOSTNAME does not appear in 'docker node ls' on the manager"
      failed=1
    fi

    # Global service: the swarm schedules it here the moment the node is
    # ready, so it is the first real test of the mount under docker.
    local agent
    agent="$(mgr_eval "docker service ps ${MONITOR_STACK}_agent --filter desired-state=running --format '{{.Node}} {{.CurrentState}}' 2>/dev/null" | grep -w "$WORKER_HOSTNAME" | head -1)" || agent=""
    if [[ -n "$agent" ]]; then
      ok "${MONITOR_STACK}_agent on this node: ${agent#* }"
    else
      warn "${MONITOR_STACK}_agent is not running on $WORKER_HOSTNAME yet. It is a global service, so give it a moment, then: docker service ps --no-trunc ${MONITOR_STACK}_agent"
    fi
  else
    skip "no --manager, so 'docker node ls' was not checked. Run it on the manager to confirm $WORKER_HOSTNAME is there."
  fi

  (( failed )) && die "the node is not fully joined (see above)"

  cat <<EOF

  $WORKER_HOSTNAME is on the mesh at $WORKER_MESH_ADDR and in the swarm.

  Komodo picks the node up through the agent, which is global and mounts the
  shared keys over NFS -- the mount is verified above. Nothing else has to be
  deployed here: swarm schedules onto it.

EOF
  ok "worker ready"
}

# ---------------------------------------------------------------- leave ---

# Undo, in the reverse order of the join: swarm first, because leaving the mesh
# first would strand the node with no route to the manager.
do_leave() {
  info "removing $WHERE from the cluster"

  if [[ "$(swarm_state)" == active ]]; then
    if confirm "Leave the swarm?" yes; then
      host_run 'docker swarm leave --force' || true
      ok "left the swarm"
      if manager_reachable && [[ -n "${WORKER_HOSTNAME:-}" ]]; then
        # A node that left stays in `docker node ls` as Down until it is
        # removed, and the placement constraints still see it.
        if mgr_eval "docker node rm --force $WORKER_HOSTNAME" >/dev/null 2>&1; then
          ok "removed $WORKER_HOSTNAME from the manager's node list"
        else
          warn "could not remove $WORKER_HOSTNAME on the manager; do it there with: docker node rm --force $WORKER_HOSTNAME"
        fi
      else
        warn "run this on the manager to drop the stale node: docker node rm --force ${WORKER_HOSTNAME:-<hostname>}"
      fi
    fi
  else
    skip "not in a swarm"
  fi

  if host_eval 'command -v tailscale >/dev/null 2>&1'; then
    if confirm "Log out of the mesh?" yes; then
      host_run 'sudo tailscale logout' || true
      host_run 'sudo tailscale down' || true
      ok "left the mesh"
      warn "the node is still registered in headscale. Remove it in Headplane -> Machines, or: headscale nodes delete -i <id>"
    fi
  fi

  # Only what this script installed, and only when it recorded doing so.
  if recorded "installed_tailscale" && confirm "Uninstall tailscale, which this script installed?" no; then
    host_run 'sudo apt-get remove -y tailscale || sudo pacman -Rns --noconfirm tailscale || sudo dnf remove -y tailscale' || true
  fi
  if recorded "installed_docker" && confirm "Uninstall docker, which this script installed?" no; then
    host_run 'sudo apt-get remove -y docker-ce docker-ce-cli containerd.io || true' || true
  fi

  local was
  was="$(recorded_value hostname_was)" || was=""
  if [[ -n "$was" ]] && confirm "Restore the hostname to $was?" no; then
    host_run "sudo hostnamectl set-hostname $was" || true
  fi

  host_run "sudo rm -f $STATE_FILE" || true
  [[ -f "$WORKER_ENV_FILE" ]] && confirm "Delete $WORKER_ENV_FILE?" yes && rm -f "$WORKER_ENV_FILE"
  ok "done"
}

# ------------------------------------------------------------------ run ---

# Cluster settings first so the worker's own file can override them, then the
# worker's, then whatever the operator exported -- load_env_file never
# overwrites something already set.
load_env_file "$WORKER_ENV_FILE"
load_env_file "$ENV_FILE"

if (( LEAVE )); then
  do_leave
  exit 0
fi

started=0
for stage in "${STAGES[@]}"; do
  if [[ -n "$ONLY_STAGE" ]]; then
    [[ "$stage" == "$ONLY_STAGE" ]] || continue
  elif [[ -n "$FROM_STAGE" ]] && (( ! started )); then
    [[ "$stage" == "$FROM_STAGE" ]] || continue
    started=1
  fi
  [[ "$stage" == config ]] || require_settings
  "stage_$stage"
done
