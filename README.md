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

## Bring-up order

The order matters: the NFS export must exist, and `monitor-keys` must exist
inside it, before the Komodo stack is deployed.

```bash
# 1. NFS server (standalone compose, VPS only). Its init sidecar creates
#    /shared/monitor-keys and fixes ownership before the export goes live.
docker compose -f apps/nfs/compose.yml up -d
docker exec nfs-server ls -la /shared    # confirm monitor-keys is there

# 2. Filebrowser
docker stack deploy -c apps/filebrowser/compose.yml files
docker service logs files_filebrowser   # prints the generated admin password

# 3. Komodo
docker stack deploy -c apps/monitor/compose.yml monitor
```

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

Filebrowser writes as UID 1000; containers mounting the share connect as root
(UID 0). Left alone that produces `permission denied` and phantom
`no such file or directory` errors. The export uses
`all_squash,anonuid=1000,anongid=1000`, mapping every remote read/write onto
UID 1000 — no manual `chmod` passes required.

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

This is `NFS4ERR_NOENT` from the server, not a client-side problem — the
client reached port 2049 and the server replied that the path does not
resolve. A server that is down gives `connection refused`, and an export that
rejects the client gives `access denied by server`, so this error means
`/shared/monitor-keys` is missing from the export:

```bash
docker exec nfs-server ls -la /shared
docker exec nfs-server mkdir -p /shared/monitor-keys
docker exec nfs-server chown 1000:1000 /shared/monitor-keys
```

Swarm does not retry the mount once it has cached the failed volume, so purge
it (below) and redeploy afterwards.

### Purge cached NFS volumes across the cluster

After any change to the `keys` volume definition:

```bash
# 1. On the manager
docker stack rm monitor

# 2. On EVERY node (VPS, gaming PC, mini PC)
docker volume rm monitor_keys
```

Then redeploy. Skipping a node leaves that node mounting the old stub.
