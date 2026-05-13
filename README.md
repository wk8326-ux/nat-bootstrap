# nat-bootstrap

Public bootstrap scripts for NAT and lightweight nodes.

## One-line install

Interactive:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wk8326-ux/nat-bootstrap/main/cf_vless_ws_install.sh)
```

Non-interactive:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wk8326-ux/nat-bootstrap/main/cf_vless_ws_install.sh) --node-name NAT_HKCF --host hkcf.holdzywoo.top --token 'YOUR_CF_TUNNEL_TOKEN' --non-interactive
```

## What it installs

- xray
- cloudflared
- VLESS + WS
- Cloudflare Tunnel outbound connection

## Other tools

Interactive process inspector / killer for NAT or lightweight VPS:

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


Prepare first:

- a working domain hostname
- a Cloudflare Tunnel
- the Tunnel Token
- hostname routing in Cloudflare pointing to this node service
