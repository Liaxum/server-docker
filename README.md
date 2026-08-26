# server-docker

Multi-node Docker Swarm cluster interconnected over a Tailscale mesh, with
centralized NFS persistent storage and a Traefik reverse proxy.

- **Manager node:** `liaxum-vps` — Tailscale IP `100.64.0.1`. Everything that
  holds state is pinned to it via `node.hostname == liaxum-vps`.
- **Worker nodes:** remote physical hardware (gaming PC, mini PC) joined to
  both the Swarm and the Tailscale mesh.
- **Reverse proxy:** Traefik on the manager, terminating TLS on the `web-net`
  overlay network.

| Path | Deployed as | Purpose |
| --- | --- | --- |
| `traefik/compose.yml` | stack `traefik` | TLS termination, routing |
| `apps/nfs/compose.yml` | **standalone compose** on the VPS | exports `/shared` over Tailscale |
| `apps/filebrowser/compose.yml` | stack `files` | web UI on the shared volume |
| `apps/monitor/compose.yml` | stack `monitor` | Komodo core, Mongo, global agents, MCP |

## Host prerequisites

### NFS client utilities (every node)

The Docker `local` volume driver hands NFS mounts to the kernel, so the client
tools must be present on the host — not just in the container.

```bash
# Debian / Ubuntu
sudo apt update && sudo apt install -y nfs-common

# Arch Linux
sudo pacman -S nfs-utils
```

### VPS firewall (UFW on `liaxum-vps`)

Allow NFS strictly over the Tailscale interface:

```bash
sudo ufw allow in on tailscale0 to any port 2049 proto tcp
sudo ufw reload
```

### Shared overlay network

```bash
docker network create --driver overlay --attachable web-net
```

## Bootstrap

`scripts/bootstrap.sh` brings the manager node up in dependency order and is
safe to re-run — every stage checks before it acts.

```bash
./scripts/bootstrap.sh                    # deploy; host must already be ready
./scripts/bootstrap.sh --with-host-setup  # also prepare the host (needs sudo)
./scripts/bootstrap.sh --from nfs         # resume from a stage
./scripts/bootstrap.sh --dry-run          # print what would run
./scripts/bootstrap.sh --ssh user@host    # repo here, cluster there
```

Each host prerequisite offers to fix itself when it is missing:

```
    NFS client utilities are missing on root@liaxum.fr. Install them? [y/N]:
```

These default to yes, since preparing the host is what the script is for —
Enter accepts, `n` declines. `--with-host-setup` answers them all up front.
Declining stops with the command that fixes it, and a run with no terminal to
answer on does the same rather than changing a host unasked or hanging.

Removal is the exception: `--uninstall` asks for the manager hostname typed
back, with no default.

### Startup mode

Only five paths are needed to boot the cluster: `scripts`, `traefik`,
`apps/vpn`, `apps/nfs`, `apps/monitor`. Everything else is deployed by Komodo
once it is running, so a machine whose only job is bringing the cluster up
does not need it.

On a fresh machine, clone narrow to begin with:

```bash
git clone --filter=blob:none --sparse <url> server-docker
cd server-docker
git sparse-checkout set scripts traefik apps/vpn apps/nfs apps/monitor
```

On a clone you already have:

```bash
./scripts/startup-mode.sh          # narrow to the startup paths
./scripts/startup-mode.sh --full   # widen back
./scripts/startup-mode.sh --list   # print the paths
```

This is `git sparse-checkout`, so nothing leaves history and widening needs no
network. Cone mode always keeps root files, so `README.md` and `.gitignore`
come along — which is why the fresh-clone commands above are reachable from a
narrow clone. `scripts/startup-mode.sh` is not: a `--sparse` clone starts with
root files only, so the first narrowing has to be the plain git command.

`bootstrap.sh` skips any stage whose compose file is absent rather than
failing, so the same script works in both modes.

### Driving it from another machine

`docker stack deploy -c file` reads the compose file **client-side** and sends
the resulting spec to the daemon, as do `docker compose -f`, `docker secret
create` and `docker config create`. So with a remote context —

```bash
docker context create vps --docker host=ssh://liaxum-vps
docker context use vps
```

— the repo has to be on the machine running the CLI, not on the server. Every
docker-facing stage then works: bind mounts like `/opt/vpn/data` and the
`nfs_data` volume resolve on the daemon's host.

Two stages do not, because they inspect or modify the host rather than Docker:
`--with-host-setup` installs packages and edits ufw, and `mesh` checks which
addresses this machine holds. Both refuse to run against a remote daemon
rather than acting on the wrong machine.

`--ssh` covers that gap, and is the simpler way to work from a laptop:

```bash
./scripts/bootstrap.sh --ssh liaxum-vps --with-host-setup
```

It points Docker at that host *and* runs the host-local stages there over ssh,
so one flag makes every stage work with the repo on this machine. It also
defaults `MANAGER_HOSTNAME` to the target rather than your laptop — otherwise
the `node.hostname ==` constraint would name a machine that is not in the
swarm, and every pinned service would sit unschedulable.

The connection is checked once up front, so an unreachable host fails as a
connection error instead of surfacing as a missing package or an absent
directory in every later check. `sudo` gets a terminal, so it can prompt.

### Starting over, and removing it

```bash
./scripts/bootstrap.sh --reset-config              # forget the answers
./scripts/bootstrap.sh --uninstall                 # remove the stacks and objects
./scripts/bootstrap.sh --uninstall --with-data     # and the volumes
```

`--reset-config` deletes `bootstrap.env` and the rendered vpn configs and
touches nothing else, so the next run asks afresh and redeploys over whatever
is running.

`--uninstall` removes the four stacks, the standalone NFS compose project,
`web-net`, the TLS secrets, the config objects, and finally `bootstrap.env`
and the rendered vpn configs — last, because everything before it needs those
settings to know what to remove. It prints what it found
before doing anything and asks you to type the manager hostname; without a
terminal to ask on, it refuses. Volumes are kept unless `--with-data` is
given, which destroys the Komodo database, the keys and the shared files.

`--with-host` also reverses the host changes: it purges packages it installed,
leaves the swarm it initialised, removes Tailscale it installed, and restores
the hostname it changed.

It can do this safely because each of those is **recorded when it is made**, in
`/var/lib/server-docker-bootstrap.state` on the target:

```
hostname_was ubuntu
installed_package apt-get nfs-common
swarm_init
created_dir /opt/vpn/data
installed_tailscale
```

Only recorded changes are undone. A package that was already installed, a
swarm that already existed, a hostname nobody changed — none of it is
recorded, so none of it is touched. The record is printed before the reversal
runs, so you can see exactly what is about to be undone. `/opt/vpn/data` is
kept unless `--with-data` is given, since it holds headscale's database.

Volumes on worker nodes remain out of reach — remove `<monitor stack>_keys`
on each.

### Settings

The first run asks for the values that differ per install and stores them in
`bootstrap.env`, which is gitignored because it holds credentials. Later runs
reuse the answers; `--reconfigure` asks again, and exporting a variable
beforehand overrides the stored value.

| | |
|---|---|
| `DOMAIN` | serves `vpn.`, `files.`, `monitor.`, `mcp.` |
| `MANAGER_HOSTNAME` | the `node.hostname ==` constraint; the host stage offers to rename the target to match |
| `MESH_ADDR` | this node's mesh address; the NFS server binds it |
| `MESH_CIDR` | range headscale hands out **and** the NFS export admits |
| `*_STACK` | stack names: `TRAEFIK_`, `VPN_`, `FILES_`, `MONITOR_` |
| `*_SUBDOMAIN` | subdomains: `VPN_`, `FILES_`, `MONITOR_`, `MCP_` |
| `CRT_FILE` / `KEY_FILE` | TLS material; detected in `traefik/secret/` by content |
| `MESH_USER` | headscale user that nodes enrol under |
| `HEADPLANE_API_KEY` | minted in headplane, so blank on a first run |
| `HEADPLANE_COOKIE_SECRET` | generated if you accept the default |

Service names are deliberately absent. They are YAML keys, and Compose does
not interpolate keys — parameterising them would mean generating every compose
file, which costs more than it buys. Every stack here calls its main service
`core` by repo convention, so a renamed stack still resolves as
`<stack>_core`; headplane's reference to headscale is rendered that way.

`MESH_CIDR` lands in two places that have to agree: headscale's
`prefixes.v4`, which decides what addresses exist, and the NFS export's client
spec, which decides who may mount. Set them apart and worker nodes get
addresses the export silently refuses. The config stage also rejects a
`MESH_ADDR` outside `MESH_CIDR`, since headscale would never hand it out.

These reach the stacks two different ways. Compose files use `${DOMAIN:-…}`
interpolation, so a manual `docker stack deploy` still works and falls back to
the committed defaults. Headscale's `config.yaml` and `headplane_config.yaml`
are mounted as Docker configs, and Compose never interpolates *file contents* —
so those are tracked as `.template` files and rendered by the `vpn` stage. The
rendered files are gitignored; edit the template, not the output.

The certificate and key are found by asking openssl what each file in
`traefik/secret/` actually is, rather than by extension — CAs hand out `.crt`,
`.cer` and `.pem` for the same thing, and a `.pem` may be either half. `.pem`
wins when several parse, matching this repo's convert-before-use convention.
DER input is converted rather than rejected: a `.cer` or `.key` the CA issued
in DER is written beside the original as `*_converted.pem` and used from then
on, since Traefik reads the secret verbatim and needs PEM.

Before the secrets are created the pair is checked: both parseable, and the
certificate's public key equal to the one the private key derives. A
mismatched pair otherwise deploys cleanly and fails TLS at runtime. A leaf
with no intermediates is flagged — browsers cope, Go clients such as Tailscale
do not — and the script offers to build the chain by fetching the issuer the
certificate itself names.

The `mesh` stage joins the node for you: it offers to install Tailscale, mints
a headscale pre-auth key through the running `<vpn stack>_core` container, and
runs `tailscale up`. Each step asks first, and if any of it fails
the stage prints the commands and **waits** rather than exiting — finish the
join in another terminal, press Enter, and the run continues from there. headscale allocates addresses in order rather than
letting you pick, so if it hands out something other than `MESH_ADDR` the stage
stops and tells you what to set — the NFS server binds that address and every
client mounts it.

Two things it will not do. Certificates: `liaxum_crt` and `liaxum_key` are
created from `traefik/secret/` (override with `CRT_FILE`/`KEY_FILE`), and
because Docker secrets are immutable, rotating one means removing the secret
and redeploying Traefik by hand. and rotating one means removing the secret and redeploying Traefik by hand.

The stages are `host swarm traefik vpn mesh nfs filebrowser monitor verify`.

## Bring-up order

The script above runs these for you; they are here for when you want to do it
by hand or check what a stage actually does.

The order matters: the NFS export must exist, and `monitor-keys` must exist
inside it, before the Komodo stack is deployed.

```bash
# 1. NFS server (standalone compose, VPS only). Its init sidecar creates
#    /shared/monitor-keys and fixes ownership before the export goes live.
docker compose -f apps/nfs/compose.yml up -d
docker exec nfs-server ls -la /shared    # confirm monitor-keys is there

# 2. Filebrowser
docker stack deploy -c apps/filebrowser/compose.yml files
docker service logs files_core   # prints the generated admin password

# 3. Komodo
docker stack deploy -c apps/monitor/compose.yml monitor
```

## Adding a service that needs shared storage

Two edits, no host access.

1. Add the directory to `SHARED_DIRS` in `apps/nfs/compose.yml`, space
   separated, and apply it:

   ```bash
   docker compose -f apps/nfs/compose.yml up -d
   ```

   The init sidecar creates anything listed and is idempotent, so existing
   directories are untouched.

2. Declare the volume in the new stack. The path is relative to the NFSv4
   root, which `fsid=0` pins to `/shared` — so a directory named `foo-data`
   is `:/foo-data`, not `:/shared/foo-data`:

   ```yaml
   volumes:
     data:
       driver: local
       driver_opts:
         type: "nfs"
         o: "addr=100.64.0.1,rw,nfsvers=4,nolock,soft"
         device: ":/foo-data"
   ```

The export itself needs no change — it covers the whole tree, and `all_squash`
maps every client onto UID 1000 regardless of what UID the service runs as
inside its container, so there is no per-service ownership setup.

If you later change a volume's `device` or `o` options, remember Docker pins
`driver_opts` at volume creation: the volume must be removed on every node
before the new options take effect.

Docker config and secret objects are immutable in the same way — redeploying
with changed content fails with `only updates to Labels are allowed`. The vpn
stack therefore names its configs after a hash of their contents, so a change
creates a new object rather than trying to rewrite one. Superseded objects are
left behind; `docker config ls` shows them and unreferenced ones can be
removed. Secrets have no such escape here, so rotating a certificate still
means removing the secret and redeploying Traefik.

## Design decisions

### Hybrid local + NFS volume model

`agent` runs in `mode: global`, so periphery instances land on machines that
have no access to the `core.pub` that `core` writes on the VPS. Rather than
copying keys around:

- on the VPS, the standalone NFS container mounts the local volume `nfs_data`
  at `/shared` and exports it over Tailscale;
- swarm services mount `keys` through the `local` driver with `type: "nfs"`
  pointed at `100.64.0.1:/shared/monitor-keys`;
- Filebrowser, being pinned to the VPS, binds `nfs_data` directly and skips
  the network round-trip entirely.

### UID squashing

Two paths reach this storage and they have to agree on ownership:

- **over NFS** (`core`, `agent`) — `all_squash` rewrites every client to
  `anonuid` regardless of what UID the process runs as in its container, so
  these services need no configuration at all;
- **directly** (`filebrowser`) — pinned to the VPS and binding `nfs_data` as a
  local volume, it never goes through NFS and never gets squashed, so it
  writes as whatever UID it actually runs as.

Filebrowser is therefore the only writer the export cannot control, and the
squash target has to match it. Both are set to root: containers default to
root, so the two agree without depending on any image's choice of runtime UID
— a `:latest` pull changing that default would otherwise break permissions
with nothing in this repo having changed. Filebrowser states `user: "0:0"`
explicitly so the pairing is visible rather than inherited.

The tradeoff is that a client could plant setuid-root files on the share, so
clients mount `nosuid,nodev`. Note this is not the security boundary: any host
matching the export's client specs already has full access to every file on
it, whatever the anon UID. The boundary is the ACL and the Tailscale-bound
listener.

### Swarm caches broken volumes

If a service mounts an NFS path that does not exist, Docker caches a broken
stub volume **on every node that ran the task**. Fixing the server side is not
enough; either remove the stale volume on each host, or bump the volume key in
the stack file (`keys` → `keys_v2`) so a fresh one is created.

## Runbook

### Inspect the shared volume

```bash
# On the VPS host
ls -la /var/lib/docker/volumes/nfs_data/_data/monitor-keys

# Through the NFS container
docker exec -it nfs-server ls -la /shared/monitor-keys

# From an agent on a worker node — proves the NFS mount actually resolved
docker exec -it $(docker ps -qf name=monitor_agent) ls -la /config/keys
```

### `failed to mount local volume: ... no such file or directory`

```
starting container failed: error while mounting volume '/var/lib/docker/volumes/monitor_keys/_data':
failed to mount local volume: mount :/shared/monitor-keys:..., data: addr=100.64.0.1,...:
no such file or directory
```

This is `NFS4ERR_NOENT` from the server: the client reached port 2049 and the
server refused to resolve the path. It has **two** causes that look identical,
because NFSv4 hides an export from a client that does not match its ACL rather
than reporting a permission error — the lookup just returns ENOENT.

1. The directory really is missing from the export:

   ```bash
   docker exec nfs-server ls -la /shared
   ```

   The init sidecar in `apps/nfs/compose.yml` creates it, so this should only
   happen on a volume predating that service.

2. The server has no NFSv4 root, so *every* lookup fails. `/shared` is a
   bind-mounted Docker volume living in the NFS container's mount namespace,
   and nfsd cannot build a pseudo-filesystem that reaches it. `exportfs -v`
   still lists the export quite happily, which makes this look like a path
   problem. The export therefore carries `fsid=0`, pinning `/shared` as the
   v4 root — which is why clients mount `:/monitor-keys` and not
   `:/shared/monitor-keys`.

3. The client's source address matches no client spec on the export. NFSv4
   hides an unmatched export rather than refusing it. The VPS mounts its own
   export through the published port, where the source is NAT'd to the Docker
   bridge gateway, hence the `172.16.0.0/12` spec beside the Tailscale range.

To tell these apart, mount at three depths from a throwaway container — no
host access needed. `--network host` puts the mount in the same namespace
dockerd uses for real volume mounts:

```bash
docker run --rm --privileged --network host alpine sh -c '
apk add --no-cache nfs-utils >/dev/null 2>&1; mkdir -p /mnt/t
for p in /monitor-keys /; do
  echo "=== mounting 100.64.0.1:$p"
  mount -t nfs4 -o nolock,soft 100.64.0.1:$p /mnt/t 2>&1 && { ls -la /mnt/t; umount /mnt/t; }
done'
```

`/` failing too means there is no v4 root (cause 2). `/` working while a
subpath fails means the directory or the ACL (causes 1 and 3).

Swarm re-attempts the mount every time it restarts the task, so once the
export is right the service recovers on its own; force it with
`docker service update --force monitor_core` if you would rather not wait.

Changing the volume's `device` or `o` options is different: Docker stores
those on the volume at creation and ignores the updated stack file, so the
volume has to be removed on every node first (see below).

### Purge cached NFS volumes across the cluster

After any change to the `keys` volume definition:

```bash
# 1. On the manager
docker stack rm monitor

# 2. On EVERY node (VPS, gaming PC, mini PC)
docker volume rm monitor_keys
```

Then redeploy. Skipping a node leaves that node mounting the old stub.
