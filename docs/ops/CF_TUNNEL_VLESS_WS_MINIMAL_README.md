# nat-cfws-bootstrap

极简 NAT 代理节点引导脚本：在一台空白 NAT / VPS 上快速部署 `Cloudflare Tunnel + VLESS WS`。

特点：
- 只需要 3 个核心输入：节点名、域名、Tunnel Token
- 自动生成 UUID
- 默认固定 `127.0.0.1:8080`、`path=/`
- 不包含 SSH 自动化
- 不包含哪吒 agent
- 适合月抛 NAT、轻量机、临时中转节点

支持：
- Alpine
- Debian / Ubuntu
- amd64 / arm64 / armv7
- OpenRC / systemd

## 一条命令启动

交互模式：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wk8326-ux/nanobot-private/main/cf_vless_ws_install.sh)
```

非交互模式：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wk8326-ux/nanobot-private/main/cf_vless_ws_install.sh) --node-name NAT_HKCF --host hkcf.holdzywoo.top --token 'YOUR_CF_TUNNEL_TOKEN' --non-interactive
```

## 本地直接运行

```bash
bash cf_vless_ws_install.sh
```

## 参数

- `--node-name NAME`：节点名
- `--host DOMAIN`：Cloudflare Tunnel 绑定域名
- `--token TOKEN`：Cloudflare Tunnel Token
- `--uuid UUID`：手动指定 UUID；默认自动生成
- `--non-interactive`：非交互模式
- `--force-reinstall`：强制重装 xray / cloudflared
- `--skip-cloudflare-check`：跳过域名 DNS 粗检查

## 客户端配置要点

固定使用：
- type: `ws`
- security: `tls`
- host: `你的域名`
- sni: `你的域名`
- path: `/`

不要带：
- Reality 参数
- public key / short id
- `flow=xtls-rprx-vision`

## 说明

- 这是 `Cloudflare Tunnel` 主动外连模式，不依赖公网入站 `443`
- 普通浏览器直接访问域名时返回 `400` 或 `404` 也可能是正常现象
- 脚本会检查本地 `8080` 是否被占用

## 生成结果

脚本完成后会输出：
- 节点名
- 域名
- UUID
- 本地监听地址
- 配置文件路径
- 日志路径
- 最终可导入的 VLESS 链接
