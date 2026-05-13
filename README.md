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

```bash
python3 proc_guard.py
```

Show more than the default top entries:

```bash
python3 proc_guard.py 20
```

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
