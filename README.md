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

## Requirements

Prepare first:

- a working domain hostname
- a Cloudflare Tunnel
- the Tunnel Token
- hostname routing in Cloudflare pointing to this node service
