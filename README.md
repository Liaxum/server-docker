# server-docker

Multi-node Docker Swarm cluster interconnected over a Tailscale mesh, with
centralized NFS persistent storage and a Traefik reverse proxy.

- **Manager node:** `liaxum-vps` — Tailscale IP `100.64.0.1`. Everything that
  holds state is pinned to it via `node.hostname == liaxum-vps`.
- **Worker nodes:** remote physical hardware (gaming PC, mini PC) joined to
  both the Swarm and the Tailscale mesh — see
  [Joining a worker node](#joining-a-worker-node).
- **Reverse proxy:** Traefik on the manager, terminating TLS on the `web-net`
  overlay network.

| Path | Deployed as | Purpose |
| --- | --- | --- |
| `traefik/compose.yml` | stack `traefik` | TLS termination, routing |
| `apps/nfs/compose.yml` | **standalone compose** on the VPS | exports `/shared` over Tailscale |
| `apps/filebrowser/compose.yml` | stack `files` | web UI on the shared volume |
| `apps/monitor/compose.yml` | stack `monitor` | Komodo core, Mongo, global agents, MCP |
| `scripts/bootstrap.sh` | — | brings the manager up from nothing |
| `scripts/join-worker.sh` | — | adds a worker to the mesh, then the swarm |

## Host prerequisites

### NFS client utilities (every node)

The Docker `local` volume driver hands NFS mounts to the kernel, so the client
tools must be present on the host — not just in the container. Both scripts
install these, so this is what they do rather than something to run by hand:
`bootstrap.sh` on the manager, `join-worker.sh` on every worker.

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

### Moving the swarm onto the mesh

Docker fixes a manager's advertise address at `docker swarm init` and there is
no way to change it afterwards. The bootstrap order makes that awkward: the
swarm has to exist before Traefik, which has to exist before headscale, which
is what hands out the mesh address — so on a first run the node does not hold
`MESH_ADDR` yet and Docker advertises whatever interface it picks, usually the
public one.

The consequence is not cosmetic. `docker swarm join-token worker` then prints
a public address, workers join over it, and the overlay carries their traffic
over the internet rather than the mesh.

`SWARM_ADVERTISE_ADDR` is asked for in the config stage and defaults to
`MESH_ADDR`. The `host` stage uses it when the node holds that address, and
when the node is already in a swarm advertising something else, it offers to
move it:

```
The swarm advertises 203.0.113.10. Workers join over that address and the
overlay carries their traffic there, so it will not use the mesh.
...
    Re-initialise the swarm to advertise 100.64.0.1? [y/N]:
```

Saying yes runs `docker swarm leave --force` and re-initialises on the address
you chose; the stages after it rebuild the services, secrets and config
objects. Volumes are untouched, so the Komodo database, the keys and the
shared files survive. Any worker already joined has to re-join with the new
token. This one prompt defaults to **no**, unlike the other host prompts,
because it throws away the running cluster to rebuild it.

A first run cannot advertise the mesh address at all: the swarm has to exist
before Traefik, which comes before headscale, which is what hands the address
out. So the `host` stage lets Docker choose, and says so.

The `mesh` stage then closes the loop. The moment after the node joins is the
first time it holds the address, so the stage moves the swarm onto it and
rebuilds what that destroys — swarm resources, Traefik and headscale, in that
order. A plain run therefore ends with the swarm on the mesh without anyone
having to notice:

```
  ok joined the mesh as 100.64.0.1
==> moving the swarm onto 100.64.0.1
    Re-initialise the swarm to advertise 100.64.0.1? [Y/n]:
  ok swarm re-initialised, advertising 100.64.0.1
==> swarm resources
==> traefik
==> headscale
```

Volumes and `/opt/vpn/data` are untouched, so headscale keeps its database and
this node stays registered. Any worker already joined has to re-join with the
new token.

### Starting over, and removing it

```bash
./scripts/bootstrap.sh --reset-config               # forget the answers
./scripts/bootstrap.sh --uninstall                  # stacks, objects, images
./scripts/bootstrap.sh --uninstall --with-data      # and the volumes
./scripts/bootstrap.sh --uninstall --with-host      # and the host changes
./scripts/bootstrap.sh --uninstall --keep-images    # leave the images alone
```

`--reset-config` deletes `bootstrap.env` and the rendered vpn configs and
touches nothing else, so the next run asks afresh and redeploys over whatever
is running.

`--uninstall` removes the four stacks, the standalone NFS compose project,
`web-net`, the TLS secrets, the config objects, the images these stacks name,
and finally `bootstrap.env` and the rendered vpn configs — last, because everything before it needs those
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

Volumes on worker nodes remain out of reach from the manager — run
`join-worker.sh --leave` against each worker, which removes them there.

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
| `KOMODO_ONBOARDING_KEY` | created in Komodo once core runs; the monitor stage asks |
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

The `monitor` stage has the same shape of problem as `mesh`: the agent
registers with core using an onboarding key, and that key can only be created
once core is running. So the stage deploys, waits for core, asks for the key,
saves it and redeploys. Leaving it blank is fine — everything else comes up,
and `--only monitor` picks up where you left off.

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

The stages are `config host swarm traefik vpn mesh nfs filebrowser monitor
verify`.

`verify` waits up to `VERIFY_WAIT` seconds (180 by default) for services to
converge before reporting anything unhealthy — pulling images on a cold host
is the slow part, and a service still starting is not a broken one.

## Joining a worker node

`bootstrap.sh` builds the manager. `join-worker.sh` adds everything else:

```bash
./scripts/join-worker.sh                                   # on the worker itself
./scripts/join-worker.sh --ssh user@gamingpc               # repo here, worker there
./scripts/join-worker.sh --ssh user@gamingpc --manager root@vps   # nothing to copy by hand
./scripts/join-worker.sh --only verify                     # just check
./scripts/join-worker.sh --leave                           # leave, stay ready
./scripts/join-worker.sh --uninstall                       # and the images
./scripts/join-worker.sh --uninstall --with-host           # and the host changes
```

The stages are `config host mesh swarm verify`, and the order is the point.
The manager advertises its mesh address, so `100.64.0.1:2377` does not resolve
to anything reachable until the node is on the tailnet — Tailscale has to come
first. And a worker that joins without `--advertise-addr` lets Docker pick an
interface, usually the LAN or public one, which puts the overlay back on the
internet even though the join itself went over the mesh. The script always
passes the address headscale handed out.

`host` installs Docker, the NFS *client* utilities and the `nfs` kernel module
— not `nfsd`, which is the server's and runs only on the manager — and sets
the hostname before the swarm records it. Each change is offered individually
and defaults to yes; `--with-host-setup` accepts them all.

### With and without `--manager`

`--manager` is ssh access to the manager, and it is optional.

**With it**, the pre-auth key and the join token are read off the manager
directly and the run is unattended, and `verify` can check `docker node ls` and
where the Komodo agent landed. `--leave` can also drop the stale `Down` node.

**Without it**, none of that is lost, only done by hand — and the one check
that actually matters happens either way, see below.

For enrolment, the node asks headscale to register it and prints the key for
Headplane:

```
Register this node in Headplane:

  1. open https://vpn.liaxum.fr/admin -> Machines -> Register Machine Key
  2. paste this, and pick the owner 'admin':

     https://vpn.liaxum.fr/register/nodekey:...
```

Headplane has no pre-auth key dialog — key creation is CLI-only — but its
Machines page takes exactly this registration key, so the whole enrolment can
happen in the browser. The script waits, then continues once the address
arrives. It then asks for the output of `docker swarm join-token -q worker`.

The join token is deliberately never stored: it rotates, and a stale one fails
in a way that reads like a network problem.

### Why a successful join proves nothing

The manager's daemon listens on every interface, so
`docker swarm join ... 100.64.0.1:2377` succeeds **even when the manager
advertises its public address** — and then hands this node that public address
for overlay traffic. The join going over the mesh does not mean the cluster
does.

So after joining, the worker reads back what the manager told it:

```bash
docker info --format '{{range .Swarm.RemoteManagers}}{{.Addr}} {{end}}'
```

That is the advertised address, and the script checks it on every run of the
`swarm` and `verify` stages. It needs no ssh to the manager, which is why
`--manager` stays a convenience rather than a requirement:

```
warn the swarm's manager is 203.0.113.10:2377, not 100.64.0.1. That is the
     address it advertises, so this node's overlay traffic goes there rather
     than over the mesh -- the join succeeded because the manager listens on
     every interface, not because it is on the mesh.
```

The fix is on the manager (`bootstrap.sh --from mesh`, see
[Moving the swarm onto the mesh](#moving-the-swarm-onto-the-mesh)), then
`--leave` and re-join. Daemons too old to report the field are left alone
rather than warned about.

### What `verify` actually proves

Membership in `docker node ls` does not mean the node can do its job. The
Komodo agent mounts the shared keys over NFS, and Docker reports a failed
volume mount as a scheduling problem, so neither tells you much on its own.

`verify` checks both, in this order:

```
  ok mesh address: 100.64.0.4
  ok swarm: active
  ok the manager advertises 100.64.0.1
  ok docker node ls: liaxum-mini Ready Active
  ok monitor_agent on this node: Running 5 minutes ago -- it mounts the keys over NFS, so the mount works
  ok mounted and wrote to 100.64.0.1:/monitor-keys over the mesh
```

The agent line comes before the probe deliberately. Docker mounts an NFS
volume *before* starting the container, so a task that reached `Running`
**is** the mount succeeding — stronger evidence than the probe, which only
shows this script can mount it too. So when the probe cannot run (see below)
but the agent is Running, the node is reported ready rather than failed.

The probe itself mounts `100.64.0.1:/monitor-keys`, writes a file, removes it
and unmounts. If port 2049 is unreachable it names the rule to add on the
manager (`ufw allow in on tailscale0 to any port 2049 proto tcp`); if the
mount is refused it points at the `fsid=0` root rather than leaving you to
guess.

The `docker node ls` and agent lines need `--manager`; without it they are
skipped with a note, and a probe that cannot run then has nothing to fall back
on and does fail.

### sudo and the probe

Mounting needs root, so on a worker whose ssh user is not root and whose sudo
wants a password, the probe prompts:

```
[sudo: authenticate] Password:
```

Answer it and the probe runs. Decline and, with the agent Running, you still
get `worker ready` — the probe reports that it could not run and says plainly
that this is not evidence about the mount either way.

The prompt has to reach your terminal, which means the probe runs in one ssh
connection with nothing captured, and reports through its exit code alone.
That is not incidental: capturing the command swallows the prompt and hangs,
redirecting around sudo puts the prompt in the log instead, pre-creating that
log fails because root cannot `O_CREAT` a file the ssh user owns in a sticky
`/tmp` under `fs.protected_regular`, and authenticating in one connection then
probing in another fails because sudo's credential cache is per-tty. Passwordless
sudo, or an ssh user that is already root, avoids the prompt entirely.

### Settings

Cluster-wide answers come from `bootstrap.env` when the checkout has one, so
the repo that built the manager joins workers without asking twice. This
script never writes that file. Its own answers go to `worker.env`, or
`worker-<target>.env` when `--ssh` is given, so several workers can be driven
from one checkout.

### Removing a worker

```bash
./scripts/join-worker.sh --ssh user@gamingpc --leave              # leave, stay ready
./scripts/join-worker.sh --ssh user@gamingpc --uninstall          # and the images
./scripts/join-worker.sh --ssh user@gamingpc --uninstall --with-host
```

Both print what they found and ask you to type the node's hostname before
touching anything; without a terminal to ask on, they refuse.

The order is the reverse of the join, and for the same reason: the swarm goes
first so nothing is scheduled onto a node whose volumes are about to vanish,
the manager's `docker node rm` happens while the mesh is still up in case ssh
to it runs over the mesh, and Tailscale comes down last.

**The cached NFS volumes are removed either way**, and this is the part worth
knowing about. Swarm caches a broken NFS volume on every node it ever tried to
schedule onto, so a stale one survives a redeploy and keeps failing — see
[Swarm caches broken volumes](#swarm-caches-broken-volumes). They are local
handles, not data: the files stay on the manager. They are found by driver
option rather than by name, so a worker's own unrelated local volumes are
never touched:

```
    volumes: monitor_keys
```

`--uninstall` also removes the cluster's images, but only the ones this node
actually pulled — a worker never runs Traefik, so listing it would be noise.
`--keep-images` skips that.

`--with-host` reverses **only** what the host stage recorded doing in
`/var/lib/server-docker-worker.state`: packages it installed, the
`nfs-client.conf` module config it wrote, Tailscale and Docker if it installed
them, and the hostname if it changed it. A package that was already there, a
hostname nobody changed — none of it is recorded, so none of it is touched.
Docker is removed last, since undoing it earlier would take the daemon out from
under every step above.

The node stays registered in headscale either way — delete it in Headplane →
Machines, or `headscale nodes delete -i <id>` on the manager.

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
# the filebrowser stage prints its generated admin password

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

## Pi-hole and port 53

`apps/pihole/compose.yml` is a swarm stack, and swarm's port syntax has **no
`host_ip` field** — it is documented as unsupported there. So publishing 53
binds `0.0.0.0:53` on the manager: the mesh address, yes, and the public one
too. There is no way to narrow it from the compose file.

That matters more than it sounds. An open DNS resolver on a public IP is found
by scanners within hours and used for amplification attacks — traffic leaves
your server, aimed at someone else — and providers null-route or suspend
servers for it.

`apps/nfs/compose.yml` avoids this by not being a swarm stack: standalone
compose can bind `${MESH_ADDR}:2049` and genuinely cannot be reached from
outside. Pi-hole cannot take that route, because Traefik runs with
`--providers.swarm` only and would not discover a standalone container's web
UI.

So the firewall is the control, and it is load-bearing rather than optional.

### Stack environment

Komodo lets you attach an environment to a stack, and the compose file reads
its values. Everything has a default matching this cluster except the password,
which is required:

| Variable | Default | |
| --- | --- | --- |
| `PIHOLE_PASSWORD` | — | **required**; the deploy fails without it |
| `DOMAIN` | `liaxum.fr` | |
| `PIHOLE_SUBDOMAIN` | `pihole` | |
| `MANAGER_HOSTNAME` | `liaxum-vps` | must match `docker node ls` |
| `PIHOLE_UPSTREAMS` | `1.1.1.1;8.8.8.8` | v6 syntax, semicolon separated |
| `TZ` | `Europe/Paris` | |

The password is the reason to bother. It is written `${PIHOLE_PASSWORD:?...}`
rather than `${PIHOLE_PASSWORD}` because an unset plain `${VAR}` interpolates
to an empty string **silently** — and an empty Pi-hole API password means the
admin UI stops asking for one. `:?` fails the deploy instead:

```
required variable PIHOLE_PASSWORD is missing a value: set PIHOLE_PASSWORD in
the stack environment
```

Everything else uses `${VAR:-default}` for the same reason from the other
direction. An unset `${MANAGER_HOSTNAME}` would leave `node.hostname == ` — a
constraint that matches no node, so the service sits at 0/1 forever with
nothing to explain it.

That care is warranted because **the two deploy paths do not read the same
sources**:

| | `docker compose` | `docker stack deploy` |
| --- | --- | --- |
| reads `.env` in the directory | yes | **no** |
| reads exported environment variables | yes | yes |

So a `.env` file that works perfectly under `docker compose` is ignored
entirely by `docker stack deploy`, which interpolates every `${VAR}` to an
empty string without complaint. If your Komodo stack uses swarm, confirm it
exports the environment rather than only writing a `.env` beside the file. The
password guard doubles as the test: if the deploy fails complaining about
`PIHOLE_PASSWORD` when you have set it, the environment is not reaching
interpolation.

### `ufw` will not do it

Docker publishes a port by inserting DNAT rules into `nat/PREROUTING`. The
packet is then **forwarded** to the container, so it never traverses the
`INPUT` chain where ufw's rules live. `ufw deny 53` looks like it worked and
blocks nothing.

Docker jumps to the `DOCKER-USER` chain before its own filter rules, and that
chain is in `FORWARD`, so this is where the rule belongs:

```bash
# on the manager -- replace eth0 with its public interface (ip route get 1.1.1.1)
sudo iptables -I DOCKER-USER -i eth0 -p udp --dport 53 -j DROP
sudo iptables -I DOCKER-USER -i eth0 -p tcp --dport 53 -j DROP

# survive a reboot
sudo apt install -y iptables-persistent && sudo netfilter-persistent save
```

Queries arriving on `tailscale0` are untouched, so mesh clients still resolve.

### Check it from outside

From anywhere that is not on the mesh, against the manager's public address:

```bash
dig @<public-ip> +short +time=3 example.com
```

It must time out. An answer means the resolver is open and the rules are not
in place.

### If the task will not start

`systemd-resolved` binds `127.0.0.53:53`, which is inside `0.0.0.0:53`, so the
bind fails and the task restarts. `restart_policy` stops after three attempts
so the failure is visible rather than buried under new task IDs:

```bash
docker service ps --no-trunc pihole_core
ss -lnup 'sport = :53'; ss -lntp 'sport = :53'
```

The fix is on the host — leave `systemd-resolved` running for the host's own
resolution but stop it listening:

```bash
sudo mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNSStubListener=no\n' | sudo tee /etc/systemd/resolved.conf.d/no-stub.conf
sudo systemctl restart systemd-resolved
```

`/etc/resolv.conf` must then point somewhere real rather than at `127.0.0.53`,
or the host loses DNS the moment Pi-hole is down — which takes Tailscale and
the image pulls with it.

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
