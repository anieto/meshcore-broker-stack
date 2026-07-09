# meshcore-broker-stack

Self-hosted regional MeshCore infrastructure: an MQTT broker paired with a
[CoreScope](https://github.com/Kpa-clawbot/CoreScope) analyzer, deployed
together behind a Cloudflare Tunnel with no open ports on the VPS. This is
the deployment guide — how it's put together, and how to stand up your own
copy for any region, not just Texas.

This exact setup runs live as MeshTexas, at
[meshtexas.net](https://meshtexas.net) / [analyzer.meshtexas.net](https://analyzer.meshtexas.net) —
an example of the end result. Everywhere below,
`yourdomain.net` is a placeholder for whatever domain you're deploying to.

- **MQTT broker** ([`michaelhart/meshcore-mqtt-broker`](https://github.com/michaelhart/meshcore-mqtt-broker))
  — accepts publish connections from any MeshCore operator's device in your
  region using JWT auth (same model as MeshMapper/Waev/Meshomatic)
- **CoreScope** ([`Kpa-clawbot/CoreScope`](https://github.com/Kpa-clawbot/CoreScope))
  — live packet analyzer web UI, subscribes to the broker

## Architecture

```
Other operators' devices ──WSS──┐
Your observer device(s) ────────┤──> Cloudflare (mqtt.yourdomain.net)
                                       │ Cloudflare Tunnel (no ports open)
                                   VPS: broker:8883
                                       │ localhost (internal only)
                                   VPS: corescope:3000
                                       │ Cloudflare Tunnel
Browser users ──HTTPS──> Cloudflare (analyzer.yourdomain.net)
```

**Why Cloudflare for both services:**
- No TLS cert management on the VPS
- VPS has zero open ports (Cloudflare Tunnel creates outbound-only connections)
- Both subdomains get HTTPS automatically
- One `cloudflared` daemon handles all routes

## Prerequisites

- [ ] A domain you control — add it to Cloudflare as the DNS provider
- [ ] A Cloudflare account (free tier works)
- [ ] A VPS: Ubuntu 22.04 LTS, 2GB RAM, 1 vCPU (~$12/mo on DigitalOcean/Vultr/Linode)
- [ ] SSH access to the VPS

Suggested subdomains:
- `mqtt.yourdomain.net` — the public MQTT broker
- `analyzer.yourdomain.net` — the CoreScope web UI

## Step 1 — VPS initial setup

SSH into the VPS, then:

```bash
apt update && apt upgrade -y

# Docker
curl -fsSL https://get.docker.com | sh
systemctl enable docker

# Git
apt install -y git

# Create a working directory — name it whatever you like
mkdir -p /opt/meshcore
cd /opt/meshcore
```

## Step 2 — Copy project files to the VPS

From your local machine, copy this repo to the VPS:

```bash
scp -r /path/to/this/repo/ root@<vps-ip>:/opt/meshcore/
```

Or clone it directly from GitHub on the VPS instead.

## Step 3 — Create the broker .env

On the VPS:

```bash
cd /opt/meshcore
cp broker/.env.example broker/.env
nano broker/.env
```

Fill in these values (everything else can stay as-is for now):

```
AUTH_EXPECTED_AUDIENCE=mqtt.yourdomain.net   ← your actual subdomain
SUBSCRIBER_1=corescope:STRONG_PASSWORD_HERE:2
SUBSCRIBER_2=admin:DIFFERENT_STRONG_PASSWORD:1
ALLOWED_REGIONS=SAT,AUS,HOU                  ← your region codes (see below)
```

`ALLOWED_REGIONS` is what keeps this a *regional* broker instead of an open
relay — only devices tagged with one of these codes can publish. Use
whatever short codes make sense for your area (MeshTexas uses IATA airport
codes, e.g. `SAT` for San Antonio); leave it unset to accept any region.

Pick strong random passwords. The `corescope` password must also go into
`corescope/config.json` — this file ships with MeshTexas's own live values
as a working example, not a blank template, so update it for your own
deployment before starting:

```bash
nano corescope/config.json
# change "CHANGE_ME_STRONG_PASSWORD" to match SUBSCRIBER_1's password
# change "broker" to your actual wss://mqtt.yourdomain.net URL
# update "regions", "defaultRegion", "iataFilter", and "mapDefaults.center"
# to your own area — these currently reflect MeshTexas's Texas deployment
# update "branding" (siteName, tagline, logoUrl) to your own project's identity
```

**Deployment risk, not just first-time setup**: since this repo is public, the
tracked copy of `corescope/config.json` must keep the `CHANGE_ME_STRONG_PASSWORD`
placeholder — it can never hold your real password. That means every time you
edit this file later (e.g. adding a region) and copy it back to the VPS, you
will silently overwrite the live, working password with the placeholder unless
you re-apply it by hand afterward. Symptom if this happens: every device still
publishes fine, but CoreScope's own subscriber connection fails auth and the
map goes stale — check `docker compose logs broker` for `Invalid password`
tied to the `corescope` username to confirm. Always diff the live `password`
field on the VPS before and after deploying a new `config.json`.

## Step 4 — Build and start services

```bash
cd /opt/meshcore
docker compose build      # builds the broker image (~2 min first time)
docker compose up -d
docker compose logs -f    # watch for startup errors, Ctrl-C when clean
```

Verify both are running:

```bash
docker compose ps
# broker     running
# corescope  running
```

At this point both services are up but only accessible from localhost —
the VPS has no open ports yet. Cloudflare Tunnel handles public access.

## Step 5 — Install Cloudflare Tunnel

On the VPS:

```bash
# Install cloudflared
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
dpkg -i cloudflared.deb
```

Authenticate (this opens a browser link — paste into your local machine's browser):

```bash
cloudflared tunnel login
```

Create the tunnel (name it whatever you like — `meshcore` here):

```bash
cloudflared tunnel create meshcore
```

This outputs a tunnel ID (UUID). Note it — you'll use it in the config.

Create the tunnel config at `/etc/cloudflared/config.yml`:

```yaml
tunnel: <YOUR_TUNNEL_UUID>
credentials-file: /root/.cloudflared/<YOUR_TUNNEL_UUID>.json

ingress:
  - hostname: mqtt.yourdomain.net
    service: http://localhost:8883

  - hostname: analyzer.yourdomain.net
    service: http://localhost:3000

  - service: http_status:404
```

Route DNS to the tunnel (run once per hostname — creates the CNAME automatically):

```bash
cloudflared tunnel route dns meshcore mqtt.yourdomain.net
cloudflared tunnel route dns meshcore analyzer.yourdomain.net
```

Note: if you rename a subdomain later, run the `route dns` command for the new hostname, then delete the old CNAME manually in the Cloudflare DNS dashboard. Local DNS caches (and any local resolver like AdGuard) may need flushing before the new hostname resolves on your own machine.

Install cloudflared as a system service:

```bash
cloudflared service install
systemctl enable cloudflared
systemctl start cloudflared
systemctl status cloudflared   # should show Active: running
```

## Step 6 — Cloudflare dashboard: cache rule for CoreScope

CoreScope's API must never be cached or the dashboard shows stale data.

In the Cloudflare dashboard → your zone → **Caching → Cache Rules → Create rule**:
- When: `URI Path` `starts with` `/api/`
- Then: Cache eligibility → **Bypass cache**

Save and deploy.

## Step 7 — Verify end-to-end

```bash
# Broker reachable externally (should get an MQTT WebSocket upgrade response)
curl -v wss://mqtt.yourdomain.net

# CoreScope web UI reachable
curl -s https://analyzer.yourdomain.net/api/stats | python3 -m json.tool

# CoreScope is receiving packets (will be 0 until devices connect)
curl -s https://analyzer.yourdomain.net/api/stats | grep totalPackets
```

Open `https://analyzer.yourdomain.net` in a browser — you should see the CoreScope
dashboard (empty for now, data arrives in Step 8).

## Step 8 — Point your devices at the new broker

### Example: MeshCore firmware (agessaman fork, custom preset slot)

Connect via USB serial (115200 baud), then — replace `mqtt4` with any free
custom preset slot, and the values below with your own domain:

```
set mqtt4.preset custom
set mqtt4.server mqtt.yourdomain.net
set mqtt4.port 443
set mqtt4.audience mqtt.yourdomain.net
save
reboot
```

Note: for `custom` preset slots, only `preset`, `server`, `port`, and `audience` are valid CLI fields — `transport`, `tls`, and `auth` return "unknown config" and are implied by the preset type (custom always uses WSS+JWT).

Verify: `get mqtt.status` → the slot you configured should show `connected`.

### Example: RAK4631 via meshcoretomqtt

Create a TOML file (e.g. `30-myregion.toml`) in your `meshcoretomqtt` config
directory (typically `/etc/mctomqtt/config.d/` on Linux) — replace `myregion`
and the server/audience values with your own:

```toml
[[broker]]
name = "myregion"
enabled = true
server = "mqtt.yourdomain.net"
port = 443
transport = "websockets"
keepalive = 60
qos = 0
retain = true

[broker.tls]
enabled = true
verify = true

[broker.auth]
method = "token"
audience = "mqtt.yourdomain.net"
```

Restart the meshcoretomqtt service, then check its logs for the new broker connecting.

## Step 9 — Invite other operators in your region

Once your own devices are publishing, share with other operators in your area:
- Broker URL: `wss://mqtt.yourdomain.net` (port 443, WSS, JWT auth)
- Auth: same JWT model as MeshMapper/Waev — no credentials needed from you,
  each device mints its own token from its own keypair
- They just add a custom slot (same commands as Step 8 above, or a new
  TOML file for meshcoretomqtt users)
- CoreScope can scope which regions show up on the map via `iataFilter` in
  `corescope/config.json` — MeshTexas tags regions with IATA airport codes
  (e.g. `SAT`, `AUS`, `HOU`) as a readable convention; use whatever regional
  tags make sense for your area

## Ongoing maintenance

`scripts/backup-and-update.sh` backs up CoreScope's database, the broker's
abuse-detection database, and `corescope/config.json`, prunes backups older
than 7 days, then updates and restarts both services — waiting for each to
report healthy before moving on.

```bash
./scripts/backup-and-update.sh                # backup, then update both services
./scripts/backup-and-update.sh --backup-only  # just the backup step
./scripts/backup-and-update.sh --update-only  # skip backup, just update
```

Override `BACKUP_DIR` (default `/opt/backups`) or `RETENTION_DAYS` (default
`7`) as environment variables if you want them elsewhere.

For daily automated backups via cron, without touching the running services:
```bash
0 3 * * * /opt/meshcore/scripts/backup-and-update.sh --backup-only >> /var/log/meshcore-backup.log 2>&1
```

For fully automated weekly updates (backs up first, updates both services,
waits for healthy, notifies via ntfy on success/failure — see below), stagger
it at least an hour from the nightly backup job so they never run
concurrently:
```bash
0 4 * * 0 /opt/meshcore/scripts/backup-and-update.sh >> /var/log/meshcore-update.log 2>&1
```

**View logs:**
```bash
docker compose logs -f broker      # broker connections/auth
docker compose logs -f corescope   # packet ingest + web UI
```

## Push notifications (optional)

`scripts/backup-and-update.sh` can push a notification via
[ntfy](https://ntfy.sh) on backup failures, and on update success/failure —
so a failed 3am backup doesn't just sit silently in a log file. It's opt-in
and no-ops until configured:

```bash
cp scripts/.env.example scripts/.env
nano scripts/.env   # set NTFY_URL, NTFY_TOPIC, and NTFY_TOKEN
```

`NTFY_URL` can point at the public `https://ntfy.sh` or a self-hosted ntfy
server. Either way, create a topic and a token scoped to publish-only access
to it (see [ntfy's access control docs](https://docs.ntfy.sh/config/#access-control)
if self-hosting), then subscribe to that topic in the
[ntfy app](https://ntfy.sh/app) to receive the alerts.

## Notes

- The broker port (8883) is bound to `127.0.0.1` only in docker-compose.yml —
  it is not directly accessible from the internet. All external traffic goes
  through the Cloudflare Tunnel.
- CoreScope disables its built-in Mosquitto (`DISABLE_MOSQUITTO=true`) and
  its built-in Caddy (`DISABLE_CADDY=true`) — both are handled externally.
- CoreScope connects to the broker as the `corescope` subscriber (Role 2:
  full SNR/RSSI data, no PII internal topics).
- The broker validates that each publisher's `origin_id` in the JSON payload
  matches their authenticated public key — spam/spoofing prevention is built in.
- If abuse detection needs tightening later, set `ABUSE_ENFORCEMENT_ENABLED=true`
  in `broker/.env` and restart the broker.
- `ALLOWED_REGIONS` in `broker/.env` (see Step 3) is what scopes the broker
  to your region — restart the broker after changing it for it to take effect.
- Both services bind-mount the VPS's `/etc/localtime` (read-only) into the
  container, so log timestamps match the VPS's own clock. Make sure the
  VPS's system timezone is actually set to your region
  (`timedatectl set-timezone <region>`) — otherwise cron schedules fire at
  the wrong wall-clock time relative to what you expect. Don't add a `TZ=`
  environment variable alongside this on Alpine-based images (both services
  here are Alpine) — without the full `tzdata` package installed, an
  unresolvable named `TZ` value silently overrides the correctly-mounted
  `/etc/localtime` and falls back to UTC.

## License

This repo's own files (Dockerfile, docker-compose.yml, config, scripts, docs)
are licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE) —
free to use, modify, and self-host for any noncommercial purpose.

This project builds on two separate open-source projects, each under their
own license:
- [`michaelhart/meshcore-mqtt-broker`](https://github.com/michaelhart/meshcore-mqtt-broker) — MIT License
- [`Kpa-clawbot/CoreScope`](https://github.com/Kpa-clawbot/CoreScope) — GNU GPL v3.0

Neither of those licenses is inherited by this repo: the broker image is
built fresh from their own upstream source at build time (never vendored
into this repo), and CoreScope runs as an unmodified prebuilt image
configured entirely through this repo's own `config.json` — so all credit
for those two projects goes to their respective authors.
