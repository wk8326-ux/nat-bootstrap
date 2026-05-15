# nat-bootstrap

Public bootstrap scripts for NAT and lightweight nodes.

## Scripts

### 1) Cloudflare Tunnel + VLESS WS

Interactive:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wk8326-ux/nat-bootstrap/main/cf_vless_ws_install.sh)
```

Non-interactive:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wk8326-ux/nat-bootstrap/main/cf_vless_ws_install.sh) \
  --node-name NAT_HKCF \
  --host hkcf.holdzywoo.top \
  --token 'YOUR_CF_TUNNEL_TOKEN' \
  --non-interactive
```

What it installs:

- xray
- cloudflared
- VLESS + WS
- Cloudflare Tunnel outbound connection

Prepare first:

- a working domain hostname
- a Cloudflare Tunnel
- the Tunnel Token
- hostname routing in Cloudflare pointing to this node service

Notes:

- This script targets the `CF Tunnel -> cloudflared -> local xray(ws)` path.
- The Tunnel Token file/content must be the raw `eyJ...` token only.
- Best suited for NAT/lightweight nodes that cannot expose standard public web ports directly.

### 2) VLESS + Reality

For lightweight NAT nodes that need direct `VLESS + Reality` on port `443`.

Recommended on Alpine / BusyBox style systems: install `bash` and `curl` first, then download and run the script.

Interactive:

```bash
curl -fsSL -o gf_vless_reality_install.sh https://raw.githubusercontent.com/wk8326-ux/nat-bootstrap/main/gf_vless_reality_install.sh
bash gf_vless_reality_install.sh
```

Non-interactive:

```bash
curl -fsSL -o gf_vless_reality_install.sh https://raw.githubusercontent.com/wk8326-ux/nat-bootstrap/main/gf_vless_reality_install.sh
bash gf_vless_reality_install.sh \
  --node-name GF_US01 \
  --public-host 1.2.3.4 \
  --public-port 45231 \
  --listen-port 443 \
  --dest www.cloudflare.com:443 \
  --server-name www.cloudflare.com \
  --non-interactive
```

What it installs:

- xray
- VLESS + Reality inbound
- auto-generated UUID / Reality key pair / shortId when not provided
- service autostart via systemd or OpenRC

Prepare first:

- a node with a reachable public IP or usable external port mapping
- a confirmed external entry address for client import (`--public-host`)
- if NAT mapping is used, the external mapped port for client import (`--public-port`)
- a free listening port on the node (default `443`)
- a valid Reality target pair: `--dest HOST:PORT` and matching `--server-name HOST`

Important notes:

- On `systemd` hosts, the script uses the upstream Xray installer.
- On `Alpine + OpenRC`, it automatically switches to a manual Xray install path instead of `install-release.sh`.
- `--public-host` and `--public-port` are only used to generate the final import link. They do not create DNS records or port forwarding for you.
- If the machine is NAT-based, the external mapped port must really reach the node's listening port. DNS alone cannot solve high-port NAT mapping.
- This script installs only the local `VLESS + Reality` service. It does not set up reverse proxy, CDN, Cloudflare Tunnel, panel registration, or extra routing.
- Port conflict handling is intentionally simple:
  - `--auto-disable-nginx`: stop + disable nginx if nginx is occupying the target port
  - `--force-stop-port-holder`: try stopping the service occupying the target port
- Recommended default test path is direct public-IP import first, then move on to your own domain/entry planning after the node is verified.
- This Reality path has not been broadly field-tested yet. Treat it as a convenience bootstrap script, verify carefully on each new node, and prefer small-step validation before wider reuse.

Typical use cases:

- a public VPS that can listen on `443` directly
- a NAT node whose provider gives a stable external port mapping and you plan to import the generated link manually or via `--public-port`
- quick personal deployment where you want a minimal local Reality service first and will handle the surrounding infra yourself

Not covered by this script:

- Cloudflare-related setup
- domain DNS management
- security group / firewall opening
- panel / probe / agent registration
- multi-node orchestration

## Other tools

### Node alive checker

Detects which of the two bootstrap deployment styles is present, then checks whether the expected processes really exist.

Supported modes:

- `GF VLESS + Reality`
- `CF Tunnel + VLESS WS`

Run directly:

```bash
curl -fsSL -o node_alive_check.sh https://raw.githubusercontent.com/wk8326-ux/nat-bootstrap/main/node_alive_check.sh
sh node_alive_check.sh
```

What it checks:

- deployment type detection first
- whether `xray` is really running
- for CFWS mode, whether `cloudflared` is really running too
- whether the expected local listening port still exists

Notes:

- This is a local process / listener health check, not an external reachability test.
- If a process is present but external access still fails, continue checking NAT mapping, tunnel state, firewall, and upstream entry path.

### Interactive process inspector / killer for NAT or lightweight VPS

Recommended lightweight shell version:

```bash
sh <(curl -fsSL https://raw.githubusercontent.com/wk8326-ux/nat-bootstrap/main/proc_guard.sh)
```

Or download then run:

```bash
curl -fsSL -o proc_guard.sh https://raw.githubusercontent.com/wk8326-ux/nat-bootstrap/main/proc_guard.sh
sh proc_guard.sh
```

Show more than the default top entries:

```bash
sh proc_guard.sh 20
```

Legacy Python version is still available if a machine already has Python 3, but NAT nodes should prefer the shell version.

Features:

- hide system noise by default
- focus on this node's non-system processes only
- sort by memory / CPU usage so leftovers float to the top
- explain common proxy / probe / script processes in plain Chinese
- choose indexes to send `SIGTERM` or `SIGKILL`
- suitable for spotting retry leftovers or useless resident tasks on tiny NAT nodes
