#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="1.0.0"
DEFAULT_NODE_NAME="NAT_CFWS"
DEFAULT_WS_HOST="127.0.0.1"
DEFAULT_WS_PORT="8080"
DEFAULT_WS_PATH="/"
DEFAULT_XRAY_DIR="/usr/local/xray"
DEFAULT_XRAY_BIN="/usr/local/xray/xray"
DEFAULT_XRAY_CONFIG="/usr/local/etc/xray/config.json"
DEFAULT_CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
DEFAULT_CLOUDFLARED_ENV="/etc/default/cloudflared-nat-cfws"
DEFAULT_LOG_DIR="/var/log/nat-cfws"
XRAY_SERVICE_NAME="xray"
CF_SERVICE_NAME="cloudflared-nat-cfws"

NODE_NAME="${NODE_NAME:-$DEFAULT_NODE_NAME}"
CF_HOST="${CF_HOST:-}"
CF_TUNNEL_TOKEN="${CF_TUNNEL_TOKEN:-}"
VLESS_UUID="${VLESS_UUID:-}"
WS_HOST="${WS_HOST:-$DEFAULT_WS_HOST}"
WS_PORT="${WS_PORT:-$DEFAULT_WS_PORT}"
WS_PATH="${WS_PATH:-$DEFAULT_WS_PATH}"
NON_INTERACTIVE="0"
FORCE_REINSTALL="0"
SKIP_CLOUDFLARE_CHECK="0"

OS_ID=""
OS_VERSION_ID=""
ARCH_RAW=""
ARCH=""
INIT_SYSTEM=""
PKG_UPDATE=""
PKG_INSTALL=""
NEED_SUDO="0"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
section() { printf '\n==== %s ====\n' "$*"; }
fail() { red "[FAIL] $*"; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }
warn() { yellow "[WARN] $*"; }
ok() { green "[OK] $*"; }

run_root() {
  if [ "$NEED_SUDO" = "1" ]; then
    sudo "$@"
  else
    "$@"
  fi
}

usage() {
  cat <<EOF
用法:
  bash cf_vless_ws_install.sh [选项]

最少交互项:
  - 节点名
  - 域名
  - Cloudflare Tunnel Token

可选参数:
  --node-name NAME           节点名称
  --host DOMAIN              Cloudflare Tunnel 绑定域名
  --token TOKEN              Cloudflare Tunnel Token
  --uuid UUID                指定 UUID；默认自动生成
  --non-interactive          非交互模式；缺少参数则报错
  --force-reinstall          强制重新下载 xray / cloudflared
  --skip-cloudflare-check    跳过域名 DNS 粗检查
  -h, --help                 查看帮助

示例:
  bash cf_vless_ws_install.sh
  bash cf_vless_ws_install.sh --node-name NAT_HKCF --host hkcf.holdzywoo.top --token 'xxxxx' --non-interactive
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --node-name)
        NODE_NAME="${2:-}"
        shift 2
        ;;
      --host)
        CF_HOST="${2:-}"
        shift 2
        ;;
      --token)
        CF_TUNNEL_TOKEN="${2:-}"
        shift 2
        ;;
      --uuid)
        VLESS_UUID="${2:-}"
        shift 2
        ;;
      --non-interactive)
        NON_INTERACTIVE="1"
        shift
        ;;
      --force-reinstall)
        FORCE_REINSTALL="1"
        shift
        ;;
      --skip-cloudflare-check)
        SKIP_CLOUDFLARE_CHECK="1"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "未知参数: $1"
        ;;
    esac
  done
}

require_root_or_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    NEED_SUDO="0"
    return
  fi
  if command -v sudo >/dev/null 2>&1; then
    NEED_SUDO="1"
    sudo -n true >/dev/null 2>&1 || fail "需要 root 或可用 sudo（建议直接用 root 运行）"
    return
  fi
  fail "请用 root 运行脚本"
}

prompt_required() {
  local var_name="$1"
  local prompt_text="$2"
  local secret_mode="${3:-0}"
  local current_value="${!var_name:-}"

  if [ -n "$current_value" ]; then
    return
  fi

  if [ "$NON_INTERACTIVE" = "1" ]; then
    fail "缺少必要参数: ${var_name}"
  fi

  while true; do
    if [ "$secret_mode" = "1" ]; then
      printf '[INFO] Token 输入为隐藏模式；终端不会回显，这是正常的。支持直接粘贴后回车。\n'
      read -r -s -p "$prompt_text: " current_value
      printf '\n'
    else
      read -r -p "$prompt_text: " current_value
    fi
    current_value="$(printf '%s' "$current_value" | sed 's/^ *//;s/ *$//')"
    if [ -n "$current_value" ]; then
      printf -v "$var_name" '%s' "$current_value"
      return
    fi
    warn "这一项不能为空"
  done
}

normalize_inputs() {
  NODE_NAME="$(printf '%s' "$NODE_NAME" | sed 's/^ *//;s/ *$//')"
  CF_HOST="$(printf '%s' "$CF_HOST" | sed 's/^ *//;s/ *$//')"
  case "$WS_PATH" in
    "") WS_PATH='/' ;;
    /*) ;;
    *) WS_PATH="/$WS_PATH" ;;
  esac
}

ensure_uuid() {
  if [ -n "$VLESS_UUID" ]; then
    return
  fi
  if command -v xray >/dev/null 2>&1; then
    VLESS_UUID="$(xray uuid 2>/dev/null || true)"
  fi
  if [ -z "$VLESS_UUID" ] && [ -x "$DEFAULT_XRAY_BIN" ]; then
    VLESS_UUID="$($DEFAULT_XRAY_BIN uuid 2>/dev/null || true)"
  fi
  if [ -z "$VLESS_UUID" ] && [ -r /proc/sys/kernel/random/uuid ]; then
    VLESS_UUID="$(cat /proc/sys/kernel/random/uuid)"
  fi
  if [ -z "$VLESS_UUID" ] && command -v uuidgen >/dev/null 2>&1; then
    VLESS_UUID="$(uuidgen | tr 'A-Z' 'a-z')"
  fi
  [ -n "$VLESS_UUID" ] || fail "无法自动生成 UUID"
}

detect_os() {
  [ -r /etc/os-release ] || fail "/etc/os-release 不存在，无法识别系统"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_VERSION_ID="${VERSION_ID:-}"
  ARCH_RAW="$(uname -m)"

  case "$ARCH_RAW" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l) ARCH="armv7" ;;
    *) fail "暂不支持的架构: $ARCH_RAW" ;;
  esac

  if command -v rc-service >/dev/null 2>&1; then
    INIT_SYSTEM="openrc"
  elif command -v systemctl >/dev/null 2>&1; then
    INIT_SYSTEM="systemd"
  else
    fail "未识别到 systemd 或 OpenRC"
  fi

  case "$OS_ID" in
    alpine)
      PKG_UPDATE="apk update"
      PKG_INSTALL="apk add --no-cache"
      ;;
    ubuntu|debian)
      PKG_UPDATE="apt-get update -y"
      PKG_INSTALL="apt-get install -y"
      ;;
    *)
      fail "暂不支持的系统: $OS_ID"
      ;;
  esac
}

pkg_update() { run_root sh -lc "$PKG_UPDATE"; }
pkg_install() { run_root sh -lc "$PKG_INSTALL $*"; }

install_base_packages() {
  section "安装基础依赖"
  pkg_update
  case "$OS_ID" in
    alpine)
      pkg_install bash curl wget tar gzip unzip openssl ca-certificates tzdata iproute2 bind-tools
      ;;
    ubuntu|debian)
      export DEBIAN_FRONTEND=noninteractive
      pkg_install bash curl wget tar gzip unzip openssl ca-certificates tzdata iproute2 dnsutils
      ;;
  esac
  ok "基础依赖已安装"
}

check_system() {
  section "检查系统与环境"
  info "系统: ${OS_ID} ${OS_VERSION_ID:-unknown}"
  info "架构: ${ARCH_RAW} -> ${ARCH}"
  info "init: ${INIT_SYSTEM}"

  date >/dev/null 2>&1 || fail "系统时间命令不可用"
  ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 || warn "ICMP 到 1.1.1.1 不通，继续检查 HTTPS"
  curl -I --max-time 10 https://www.cloudflare.com >/dev/null 2>&1 || fail "出网异常：无法访问 Cloudflare"

  if command -v getent >/dev/null 2>&1; then
    getent hosts github.com >/dev/null 2>&1 || warn "DNS 解析检查不理想"
  elif command -v nslookup >/dev/null 2>&1; then
    nslookup github.com >/dev/null 2>&1 || warn "DNS 解析检查不理想"
  fi

  if ss -lntp 2>/dev/null | grep -q ":${WS_PORT}\\b"; then
    ss -lntp 2>/dev/null | grep ":${WS_PORT}\\b" || true
    fail "本地端口 ${WS_PORT} 已被占用"
  fi

  ok "环境检查通过"
}

check_host_dns_hint() {
  section "检查域名提示"
  if [ "$SKIP_CLOUDFLARE_CHECK" = "1" ]; then
    warn "已跳过域名 DNS 粗检查"
    return
  fi

  local resolved=""
  if command -v getent >/dev/null 2>&1; then
    resolved="$(getent ahosts "$CF_HOST" 2>/dev/null | awk 'NR==1{print $1}')"
  elif command -v nslookup >/dev/null 2>&1; then
    resolved="$(nslookup "$CF_HOST" 2>/dev/null | awk '/^Address: /{print $2}' | tail -n1)"
  fi

  if [ -z "$resolved" ]; then
    warn "暂时无法解析 ${CF_HOST}，如果你还没把域名接到 tunnel，这里可以先忽略"
    return
  fi

  info "${CF_HOST} 当前解析示例: ${resolved}"
}

install_xray() {
  section "安装 Xray"
  local need_install="1"
  if [ "$FORCE_REINSTALL" = "0" ]; then
    if [ -x "$DEFAULT_XRAY_BIN" ]; then
      need_install="0"
    elif command -v xray >/dev/null 2>&1; then
      need_install="0"
      DEFAULT_XRAY_BIN="$(command -v xray)"
    fi
  fi

  if [ "$need_install" = "1" ]; then
    local ver arch_tag pkg_name url tmp_pkg
    ver="$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep '"tag_name"' | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')"
    [ -n "$ver" ] || fail "无法获取 Xray 最新版本号"

    case "$ARCH" in
      amd64) arch_tag="64" ;;
      arm64) arch_tag="arm64-v8a" ;;
      armv7) arch_tag="arm32-v7a" ;;
      *) fail "Xray 未映射架构: $ARCH" ;;
    esac

    pkg_name="Xray-linux-${arch_tag}.zip"
    url="https://github.com/XTLS/Xray-core/releases/download/${ver}/${pkg_name}"
    tmp_pkg="/tmp/${pkg_name}"
    curl -fL "$url" -o "$tmp_pkg"
    run_root mkdir -p "$DEFAULT_XRAY_DIR"
    run_root unzip -oq "$tmp_pkg" -d "$DEFAULT_XRAY_DIR"
    run_root chmod +x "$DEFAULT_XRAY_BIN"
    run_root mkdir -p /usr/local/bin
    run_root ln -sf "$DEFAULT_XRAY_BIN" /usr/local/bin/xray
  fi

  "$DEFAULT_XRAY_BIN" version >/dev/null 2>&1 || fail "Xray 安装后无法执行"
  ok "Xray 就绪：$($DEFAULT_XRAY_BIN version | head -n1)"
}

write_xray_config() {
  section "写入 Xray 配置"
  run_root mkdir -p "$(dirname "$DEFAULT_XRAY_CONFIG")"
  run_root tee "$DEFAULT_XRAY_CONFIG" >/dev/null <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-ws",
      "listen": "${WS_HOST}",
      "port": ${WS_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${VLESS_UUID}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "${WS_PATH}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ]
}
EOF
  run_root "$DEFAULT_XRAY_BIN" run -test -config "$DEFAULT_XRAY_CONFIG"
  ok "Xray 配置校验通过"
}

write_xray_service() {
  section "配置 Xray 服务"
  run_root mkdir -p "$DEFAULT_LOG_DIR"

  if [ "$INIT_SYSTEM" = "systemd" ]; then
    run_root tee /etc/systemd/system/xray.service >/dev/null <<EOF
[Unit]
Description=Xray Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${DEFAULT_XRAY_BIN} run -config ${DEFAULT_XRAY_CONFIG}
Restart=always
RestartSec=3
LimitNOFILE=1048576
StandardOutput=append:${DEFAULT_LOG_DIR}/xray.log
StandardError=append:${DEFAULT_LOG_DIR}/xray.err

[Install]
WantedBy=multi-user.target
EOF
    run_root systemctl daemon-reload
    run_root systemctl enable --now "$XRAY_SERVICE_NAME"
  else
    run_root tee /etc/init.d/xray >/dev/null <<EOF
#!/sbin/openrc-run
name="xray"
description="Xray Service"
command="${DEFAULT_XRAY_BIN}"
command_args="run -config ${DEFAULT_XRAY_CONFIG}"
command_background="true"
pidfile="/run/xray.pid"
output_log="${DEFAULT_LOG_DIR}/xray.log"
error_log="${DEFAULT_LOG_DIR}/xray.err"
depend() {
  need net
}
EOF
    run_root chmod +x /etc/init.d/xray
    run_root rc-update add xray default >/dev/null 2>&1 || true
    run_root rc-service xray restart
  fi

  ok "Xray 服务已启动"
}

verify_xray() {
  section "验证 Xray"
  sleep 2
  if [ "$INIT_SYSTEM" = "systemd" ]; then
    run_root systemctl is-active --quiet "$XRAY_SERVICE_NAME" || {
      run_root systemctl status "$XRAY_SERVICE_NAME" --no-pager || true
      fail "Xray 服务未正常运行"
    }
  else
    run_root rc-service xray status >/dev/null 2>&1 || {
      run_root rc-service xray status || true
      fail "Xray 服务未正常运行"
    }
  fi

  ss -lntp 2>/dev/null | grep -q "${WS_HOST}:${WS_PORT}\\b\|:${WS_PORT}\\b" || fail "未检测到 Xray 监听 ${WS_HOST}:${WS_PORT}"
  ok "Xray 正在监听 ${WS_HOST}:${WS_PORT}"
}

install_cloudflared() {
  section "安装 cloudflared"
  local need_install="1"
  if [ "$FORCE_REINSTALL" = "0" ]; then
    if [ -x "$DEFAULT_CLOUDFLARED_BIN" ]; then
      need_install="0"
    elif command -v cloudflared >/dev/null 2>&1; then
      need_install="0"
      DEFAULT_CLOUDFLARED_BIN="$(command -v cloudflared)"
    fi
  fi

  if [ "$need_install" = "1" ]; then
    local url tmp_pkg
    case "$ARCH" in
      amd64) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
      arm64) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
      armv7) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm" ;;
      *) fail "cloudflared 未映射架构: $ARCH" ;;
    esac
    tmp_pkg="/tmp/cloudflared"
    curl -fL "$url" -o "$tmp_pkg"
    run_root install -m 0755 "$tmp_pkg" "$DEFAULT_CLOUDFLARED_BIN"
  fi

  "$DEFAULT_CLOUDFLARED_BIN" --version >/dev/null 2>&1 || fail "cloudflared 安装后无法执行"
  ok "cloudflared 就绪：$($DEFAULT_CLOUDFLARED_BIN --version | head -n1)"
}

write_cloudflared_service() {
  section "配置 Cloudflare Tunnel"
  run_root mkdir -p /etc/default /etc/cloudflared "$DEFAULT_LOG_DIR"
  run_root tee "$DEFAULT_CLOUDFLARED_ENV" >/dev/null <<EOF
TUNNEL_TOKEN='${CF_TUNNEL_TOKEN}'
EOF
  run_root chmod 600 "$DEFAULT_CLOUDFLARED_ENV"

  if [ "$INIT_SYSTEM" = "systemd" ]; then
    run_root tee "/etc/systemd/system/${CF_SERVICE_NAME}.service" >/dev/null <<EOF
[Unit]
Description=Cloudflare Tunnel for NAT CFWS
After=network-online.target xray.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/sh -lc '. ${DEFAULT_CLOUDFLARED_ENV}; exec ${DEFAULT_CLOUDFLARED_BIN} tunnel run --token "$TUNNEL_TOKEN"'
Restart=always
RestartSec=5
StandardOutput=append:${DEFAULT_LOG_DIR}/cloudflared.log
StandardError=append:${DEFAULT_LOG_DIR}/cloudflared.err

[Install]
WantedBy=multi-user.target
EOF
    run_root systemctl daemon-reload
    run_root systemctl enable --now "$CF_SERVICE_NAME"
  else
    run_root tee "/etc/init.d/${CF_SERVICE_NAME}" >/dev/null <<EOF
#!/sbin/openrc-run
name="${CF_SERVICE_NAME}"
description="Cloudflare Tunnel for NAT CFWS"
command="${DEFAULT_CLOUDFLARED_BIN}"
command_args="tunnel run --token-file ${DEFAULT_CLOUDFLARED_ENV}"
command_background="true"
pidfile="/run/${CF_SERVICE_NAME}.pid"
output_log="${DEFAULT_LOG_DIR}/cloudflared.log"
error_log="${DEFAULT_LOG_DIR}/cloudflared.err"
depend() {
  need net
  after xray
}
EOF
    run_root chmod +x "/etc/init.d/${CF_SERVICE_NAME}"
    run_root rc-update add "$CF_SERVICE_NAME" default >/dev/null 2>&1 || true
    run_root rc-service "$CF_SERVICE_NAME" restart
  fi

  ok "Cloudflare Tunnel 服务已启动"
}

verify_cloudflared() {
  section "验证 Cloudflare Tunnel"
  sleep 4
  if [ "$INIT_SYSTEM" = "systemd" ]; then
    run_root systemctl is-active --quiet "$CF_SERVICE_NAME" || {
      run_root systemctl status "$CF_SERVICE_NAME" --no-pager || true
      [ -f "${DEFAULT_LOG_DIR}/cloudflared.log" ] && tail -n 50 "${DEFAULT_LOG_DIR}/cloudflared.log" || true
      [ -f "${DEFAULT_LOG_DIR}/cloudflared.err" ] && tail -n 50 "${DEFAULT_LOG_DIR}/cloudflared.err" || true
      fail "cloudflared 服务未正常运行"
    }
  else
    run_root rc-service "$CF_SERVICE_NAME" status >/dev/null 2>&1 || {
      run_root rc-service "$CF_SERVICE_NAME" status || true
      [ -f "${DEFAULT_LOG_DIR}/cloudflared.log" ] && tail -n 50 "${DEFAULT_LOG_DIR}/cloudflared.log" || true
      [ -f "${DEFAULT_LOG_DIR}/cloudflared.err" ] && tail -n 50 "${DEFAULT_LOG_DIR}/cloudflared.err" || true
      fail "cloudflared 服务未正常运行"
    }
  fi

  if [ -f "${DEFAULT_LOG_DIR}/cloudflared.log" ]; then
    tail -n 20 "${DEFAULT_LOG_DIR}/cloudflared.log" || true
  fi

  ok "cloudflared 进程已运行"
}

print_summary() {
  section "交付结果"
  local link
  link="vless://${VLESS_UUID}@${CF_HOST}:443?encryption=none&security=tls&type=ws&host=${CF_HOST}&path=${WS_PATH}&sni=${CF_HOST}#${NODE_NAME}"

  cat <<EOF
节点名: ${NODE_NAME}
域名: ${CF_HOST}
UUID: ${VLESS_UUID}
本地 WS: ${WS_HOST}:${WS_PORT}
WS Path: ${WS_PATH}
Xray 配置: ${DEFAULT_XRAY_CONFIG}
Tunnel Token 文件: ${DEFAULT_CLOUDFLARED_ENV}
日志目录: ${DEFAULT_LOG_DIR}

VLESS 链接:
${link}

说明:
- 这套是 Cloudflare Tunnel 主动外连，不依赖公网入站 443
- 外部普通访问域名返回 400/404 也可能是正常现象
- 客户端应保持: ws + tls + host=${CF_HOST} + sni=${CF_HOST} + path=${WS_PATH}
- 不要带 Reality 参数，不要带 vision flow

常用命令:
- 查看 Xray:
  $( [ "$INIT_SYSTEM" = "systemd" ] && printf 'systemctl status xray --no-pager' || printf 'rc-service xray status' )
- 查看 Tunnel:
  $( [ "$INIT_SYSTEM" = "systemd" ] && printf 'systemctl status %s --no-pager' "$CF_SERVICE_NAME" || printf 'rc-service %s status' "$CF_SERVICE_NAME" )
- 查看日志:
  tail -f ${DEFAULT_LOG_DIR}/xray.log ${DEFAULT_LOG_DIR}/xray.err ${DEFAULT_LOG_DIR}/cloudflared.log ${DEFAULT_LOG_DIR}/cloudflared.err
EOF
}

main() {
  parse_args "$@"
  section "NAT CF Tunnel + VLESS WS 极简安装脚本 v${SCRIPT_VERSION}"
  require_root_or_sudo
  detect_os
  install_base_packages
  check_system
  prompt_required NODE_NAME "节点名称（如 NAT_HKCF）"
  prompt_required CF_HOST "CF Tunnel 绑定域名（如 hkcf.holdzywoo.top）"
  prompt_required CF_TUNNEL_TOKEN "CF Tunnel Token" 1
  normalize_inputs
  check_host_dns_hint
  install_xray
  ensure_uuid
  write_xray_config
  write_xray_service
  verify_xray
  install_cloudflared
  write_cloudflared_service
  verify_cloudflared
  print_summary
}

main "$@"
