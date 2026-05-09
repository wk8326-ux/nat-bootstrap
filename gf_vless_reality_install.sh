#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="1.0.0"
DEFAULT_NODE_NAME="GF_VLESS_REALITY"
DEFAULT_LISTEN_HOST="0.0.0.0"
DEFAULT_LISTEN_PORT="443"
DEFAULT_DEST="www.cloudflare.com:443"
DEFAULT_SERVER_NAME="www.cloudflare.com"
DEFAULT_XRAY_CONFIG="/usr/local/etc/xray/config.json"
DEFAULT_LINK_TAG="GF_VLESS_REALITY"
XRAY_SERVICE_NAME="xray"

NODE_NAME="${NODE_NAME:-$DEFAULT_NODE_NAME}"
LISTEN_HOST="${LISTEN_HOST:-$DEFAULT_LISTEN_HOST}"
LISTEN_PORT="${LISTEN_PORT:-$DEFAULT_LISTEN_PORT}"
REALITY_DEST="${REALITY_DEST:-$DEFAULT_DEST}"
REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-$DEFAULT_SERVER_NAME}"
VLESS_UUID="${VLESS_UUID:-}"
REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY:-}"
REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY:-}"
REALITY_SHORT_ID="${REALITY_SHORT_ID:-}"
NON_INTERACTIVE="0"
FORCE_STOP_PORT_HOLDER="0"
AUTO_DISABLE_NGINX="0"
PUBLIC_HOST="${PUBLIC_HOST:-}"

OS_ID=""
OS_VERSION_ID=""
ARCH_RAW=""
ARCH=""
INIT_SYSTEM=""
NEED_SUDO="0"
PKG_UPDATE=""
PKG_INSTALL=""
PORT_HOLDER_PIDS=""
PORT_HOLDER_NAMES=""

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
  bash gf_vless_reality_install.sh [参数]

参数:
  --node-name NAME              节点名，默认 ${DEFAULT_NODE_NAME}
  --public-host HOST            对外连接地址（公网 IP 或域名）；仅用于生成最终链接
  --listen-port PORT            本地监听端口，默认 ${DEFAULT_LISTEN_PORT}
  --dest HOST:PORT              Reality dest，默认 ${DEFAULT_DEST}
  --server-name HOST            Reality serverNames/SNI，默认 ${DEFAULT_SERVER_NAME}
  --uuid UUID                   手动指定 UUID
  --private-key KEY             手动指定 Reality PrivateKey
  --public-key KEY              手动指定 Reality PublicKey
  --short-id SID                手动指定 shortId
  --non-interactive             缺参数时直接报错，不交互询问
  --force-stop-port-holder      若监听端口被占用，尝试停止占用服务
  --auto-disable-nginx          若占用者包含 nginx，自动 stop + disable nginx
  -h, --help                    显示帮助
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --node-name) NODE_NAME="${2:-}"; shift 2 ;;
      --public-host) PUBLIC_HOST="${2:-}"; shift 2 ;;
      --listen-port) LISTEN_PORT="${2:-}"; shift 2 ;;
      --dest) REALITY_DEST="${2:-}"; shift 2 ;;
      --server-name) REALITY_SERVER_NAME="${2:-}"; shift 2 ;;
      --uuid) VLESS_UUID="${2:-}"; shift 2 ;;
      --private-key) REALITY_PRIVATE_KEY="${2:-}"; shift 2 ;;
      --public-key) REALITY_PUBLIC_KEY="${2:-}"; shift 2 ;;
      --short-id) REALITY_SHORT_ID="${2:-}"; shift 2 ;;
      --non-interactive) NON_INTERACTIVE="1"; shift ;;
      --force-stop-port-holder) FORCE_STOP_PORT_HOLDER="1"; shift ;;
      --auto-disable-nginx) AUTO_DISABLE_NGINX="1"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) fail "未知参数: $1" ;;
    esac
  done
}

require_root_or_sudo() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    NEED_SUDO="0"
    return
  fi
  if command -v sudo >/dev/null 2>&1; then
    NEED_SUDO="1"
    sudo -n true >/dev/null 2>&1 || fail "需要 root 或可用 sudo（建议先 sudo -i）"
    return
  fi
  fail "请用 root 运行脚本"
}

detect_os() {
  [ -r /etc/os-release ] || fail "缺少 /etc/os-release，无法识别系统"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_VERSION_ID="${VERSION_ID:-}"
  ARCH_RAW="$(uname -m)"
  case "$ARCH_RAW" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l|armv7) ARCH="armv7" ;;
    *) fail "暂不支持的架构: $ARCH_RAW" ;;
  esac
  if command -v systemctl >/dev/null 2>&1; then
    INIT_SYSTEM="systemd"
  elif command -v rc-service >/dev/null 2>&1; then
    INIT_SYSTEM="openrc"
  else
    fail "未识别到 systemd / openrc"
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

prompt_required() {
  local var_name="$1"
  local prompt_text="$2"
  local current_value="${!var_name:-}"
  if [ -n "$current_value" ]; then
    return
  fi
  if [ "$NON_INTERACTIVE" = "1" ]; then
    fail "缺少必要参数: ${var_name}"
  fi
  while true; do
    read -r -p "$prompt_text: " current_value
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
  PUBLIC_HOST="$(printf '%s' "$PUBLIC_HOST" | sed 's/^ *//;s/ *$//')"
  REALITY_SERVER_NAME="$(printf '%s' "$REALITY_SERVER_NAME" | sed 's/^ *//;s/ *$//')"
  REALITY_DEST="$(printf '%s' "$REALITY_DEST" | sed 's/^ *//;s/ *$//')"
  LISTEN_PORT="$(printf '%s' "$LISTEN_PORT" | sed 's/^ *//;s/ *$//')"
  printf '%s' "$LISTEN_PORT" | grep -Eq '^[0-9]+$' || fail "listen-port 必须是数字"
}

check_system() {
  section "检查系统与环境"
  info "系统: ${OS_ID} ${OS_VERSION_ID:-unknown}"
  info "架构: ${ARCH_RAW} -> ${ARCH}"
  info "init: ${INIT_SYSTEM}"
  curl -I --max-time 10 https://www.cloudflare.com >/dev/null 2>&1 || fail "出网异常：无法访问 Cloudflare"
  ok "环境检查通过"
}

stop_service_if_exists() {
  local svc="$1"
  if [ "$INIT_SYSTEM" = "systemd" ]; then
    run_root systemctl stop "$svc" >/dev/null 2>&1 || true
    run_root systemctl disable "$svc" >/dev/null 2>&1 || true
  else
    run_root rc-service "$svc" stop >/dev/null 2>&1 || true
    run_root rc-update del "$svc" default >/dev/null 2>&1 || true
  fi
}

check_port_conflict() {
  section "检查监听端口"
  local ss_output
  ss_output="$(ss -lntp 2>/dev/null | awk -v p=":${LISTEN_PORT}" '$4 ~ p {print}')"
  if [ -z "$ss_output" ]; then
    ok "端口 ${LISTEN_PORT} 空闲"
    return
  fi

  printf '%s\n' "$ss_output"
  PORT_HOLDER_PIDS="$(printf '%s\n' "$ss_output" | grep -o 'pid=[0-9]\+' | cut -d= -f2 | sort -u | tr '\n' ' ')"
  PORT_HOLDER_NAMES="$(printf '%s\n' "$ss_output" | grep -o '"[^"]\+"' | tr -d '"' | sort -u | tr '\n' ' ')"
  warn "端口 ${LISTEN_PORT} 已被占用，进程: ${PORT_HOLDER_NAMES:-unknown}"

  if [ "$AUTO_DISABLE_NGINX" = "1" ] && printf '%s' "$PORT_HOLDER_NAMES" | grep -qw nginx; then
    warn "检测到 nginx 占用端口，自动停止并禁用 nginx"
    stop_service_if_exists nginx
    ss -lntp 2>/dev/null | awk -v p=":${LISTEN_PORT}" '$4 ~ p {print}' | grep -q . && fail "nginx 已处理，但端口 ${LISTEN_PORT} 仍被占用"
    ok "nginx 已释放端口 ${LISTEN_PORT}"
    return
  fi

  if [ "$FORCE_STOP_PORT_HOLDER" = "1" ]; then
    for name in $PORT_HOLDER_NAMES; do
      stop_service_if_exists "$name"
    done
    if ss -lntp 2>/dev/null | awk -v p=":${LISTEN_PORT}" '$4 ~ p {print}' | grep -q .; then
      fail "已尝试释放端口 ${LISTEN_PORT}，但仍被占用"
    fi
    ok "端口 ${LISTEN_PORT} 已释放"
    return
  fi

  fail "端口 ${LISTEN_PORT} 被占用；可先手动处理，或加 --auto-disable-nginx / --force-stop-port-holder"
}

install_xray() {
  section "安装 Xray"
  local need_install="1"
  local xray_bin="/usr/local/bin/xray"
  if command -v xray >/dev/null 2>&1; then
    need_install="0"
    xray_bin="$(command -v xray)"
  fi
  if [ "$need_install" = "1" ]; then
    local tmp_script
    tmp_script="/tmp/install-release.sh"
    curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o "$tmp_script"
    run_root bash "$tmp_script" install
  fi
  command -v xray >/dev/null 2>&1 || fail "Xray 安装后不可用"
  ok "Xray 就绪：$(xray version | head -n1)"
}

generate_identity_if_needed() {
  section "生成 Reality 参数"
  if [ -z "$VLESS_UUID" ]; then
    VLESS_UUID="$(xray uuid 2>/dev/null || true)"
  fi
  [ -n "$VLESS_UUID" ] || fail "生成 UUID 失败"

  if [ -z "$REALITY_PRIVATE_KEY" ] || [ -z "$REALITY_PUBLIC_KEY" ]; then
    local pair_output
    pair_output="$(xray x25519 2>/dev/null || true)"
    [ -n "$pair_output" ] || fail "生成 Reality 密钥对失败"
    [ -n "$REALITY_PRIVATE_KEY" ] || REALITY_PRIVATE_KEY="$(printf '%s\n' "$pair_output" | sed -n 's/^PrivateKey: *//p' | head -n1)"
    [ -n "$REALITY_PUBLIC_KEY" ] || REALITY_PUBLIC_KEY="$(printf '%s\n' "$pair_output" | sed -n 's/^PublicKey: *//p' | head -n1)"
    if [ -z "$REALITY_PUBLIC_KEY" ]; then
      REALITY_PUBLIC_KEY="$(printf '%s\n' "$pair_output" | sed -n 's/^Password (PublicKey): *//p' | head -n1)"
    fi
  fi
  [ -n "$REALITY_PRIVATE_KEY" ] || fail "Reality PrivateKey 为空"
  [ -n "$REALITY_PUBLIC_KEY" ] || fail "Reality PublicKey 为空"

  if [ -z "$REALITY_SHORT_ID" ]; then
    REALITY_SHORT_ID="$(openssl rand -hex 8 2>/dev/null || true)"
  fi
  [ -n "$REALITY_SHORT_ID" ] || fail "生成 shortId 失败"
  ok "Reality 参数已准备完成"
}

write_xray_config() {
  section "写入 Xray 配置"
  run_root mkdir -p /usr/local/etc/xray
  run_root tee "$DEFAULT_XRAY_CONFIG" >/dev/null <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "${LISTEN_HOST}",
      "port": ${LISTEN_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${VLESS_UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": [
            "${REALITY_SERVER_NAME}"
          ],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": [
            "${REALITY_SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
  xray run -test -config "$DEFAULT_XRAY_CONFIG" >/dev/null
  ok "Xray 配置校验通过"
}

restart_and_enable_xray() {
  section "启动并设置自启"
  if [ "$INIT_SYSTEM" = "systemd" ]; then
    run_root systemctl restart "$XRAY_SERVICE_NAME"
    run_root systemctl enable "$XRAY_SERVICE_NAME" >/dev/null 2>&1 || true
  else
    run_root rc-service "$XRAY_SERVICE_NAME" restart
    run_root rc-update add "$XRAY_SERVICE_NAME" default >/dev/null 2>&1 || true
  fi
  ok "Xray 已重启并写入自启"
}

verify_xray() {
  section "验证服务状态"
  sleep 2
  if [ "$INIT_SYSTEM" = "systemd" ]; then
    run_root systemctl is-active --quiet "$XRAY_SERVICE_NAME" || {
      run_root systemctl status "$XRAY_SERVICE_NAME" --no-pager || true
      run_root journalctl -u "$XRAY_SERVICE_NAME" -n 50 --no-pager || true
      fail "Xray 服务未正常运行"
    }
  else
    run_root rc-service "$XRAY_SERVICE_NAME" status >/dev/null 2>&1 || {
      run_root rc-service "$XRAY_SERVICE_NAME" status || true
      fail "Xray 服务未正常运行"
    }
  fi
  ss -lntp 2>/dev/null | awk -v p=":${LISTEN_PORT}" '$4 ~ p {print}' | grep -q xray || fail "未检测到 xray 监听 ${LISTEN_PORT}"
  ok "Xray 正在监听 ${LISTEN_HOST}:${LISTEN_PORT}"
}

maybe_fill_public_host() {
  if [ -n "$PUBLIC_HOST" ]; then
    return
  fi
  PUBLIC_HOST="$(curl -4fsSL --max-time 8 ifconfig.me 2>/dev/null || true)"
  [ -n "$PUBLIC_HOST" ] || PUBLIC_HOST="YOUR_PUBLIC_IP_OR_DOMAIN"
}

print_summary() {
  section "交付结果"
  maybe_fill_public_host
  local link
  link="vless://${VLESS_UUID}@${PUBLIC_HOST}:${LISTEN_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER_NAME}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&headerType=none#${NODE_NAME}"
  cat <<EOF
节点名: ${NODE_NAME}
对外地址: ${PUBLIC_HOST}
监听端口: ${LISTEN_PORT}
UUID: ${VLESS_UUID}
Reality PrivateKey: ${REALITY_PRIVATE_KEY}
Reality PublicKey: ${REALITY_PUBLIC_KEY}
Short ID: ${REALITY_SHORT_ID}
Server Name: ${REALITY_SERVER_NAME}
Dest: ${REALITY_DEST}
配置文件: ${DEFAULT_XRAY_CONFIG}

VLESS 链接:
${link}

常用检查命令:
- 查看服务状态:
  $( [ "$INIT_SYSTEM" = "systemd" ] && printf 'systemctl status xray --no-pager' || printf 'rc-service xray status' )
- 查看 443 监听:
  ss -lntp | grep ':${LISTEN_PORT}'
- 查看日志:
  $( [ "$INIT_SYSTEM" = "systemd" ] && printf 'journalctl -u xray -n 50 --no-pager' || printf 'tail -n 50 /var/log/xray/error.log' )
EOF
}

main() {
  parse_args "$@"
  section "GF VLESS + Reality 极简安装脚本 v${SCRIPT_VERSION}"
  require_root_or_sudo
  detect_os
  install_base_packages
  check_system
  prompt_required NODE_NAME "节点名称（如 GF_US01）"
  prompt_required PUBLIC_HOST "对外连接地址（公网 IP 或域名，用于生成链接）"
  normalize_inputs
  check_port_conflict
  install_xray
  generate_identity_if_needed
  write_xray_config
  restart_and_enable_xray
  verify_xray
  print_summary
}

main "$@"
