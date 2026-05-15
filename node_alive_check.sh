#!/bin/sh
set -eu

SCRIPT_VERSION="0.1.0"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
CF_ENV="/etc/default/cloudflared-nat-cfws"
CF_SERVICE="cloudflared-nat-cfws"
XRAY_SERVICE="xray"

green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
ok() { green "[OK] $*"; }
warn() { yellow "[WARN] $*"; }
fail() { red "[FAIL] $*"; }
section() { printf '\n==== %s ====\n' "$*"; }

pick_ps_cmd() {
  if ps -eo pid=,comm=,args= >/dev/null 2>&1; then
    echo full
  elif ps w >/dev/null 2>&1; then
    echo busybox
  else
    echo none
  fi
}

PS_MODE="$(pick_ps_cmd)"

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

proc_match() {
  needle="$1"
  case "$PS_MODE" in
    full)
      ps -eo pid=,comm=,args= | awk -v n="$needle" '
        index($0, n) {
          pid=$1; comm=$2;
          args="";
          for (i=3;i<=NF;i++) args=args (i==3?"":" ") $i;
          printf "%s\t%s\t%s\n", pid, comm, args;
          found=1;
        }
        END { exit(found?0:1) }'
      ;;
    busybox)
      ps w | awk -v n="$needle" '
        $0 ~ n {
          pid=$1; comm=$5;
          args="";
          for (i=5;i<=NF;i++) args=args (i==5?"":" ") $i;
          printf "%s\t%s\t%s\n", pid, comm, args;
          found=1;
        }
        END { exit(found?0:1) }'
      ;;
    *)
      return 1
      ;;
  esac
}

port_listeners() {
  port="$1"
  if have_cmd ss; then
    ss -lntp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" || true
  elif have_cmd netstat; then
    netstat -lntp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" || true
  else
    true
  fi
}

service_state() {
  svc="$1"
  if have_cmd rc-service; then
    rc-service "$svc" status 2>&1 || true
  elif have_cmd systemctl; then
    systemctl is-active "$svc" 2>&1 || true
  else
    printf 'unknown\n'
  fi
}

detect_mode() {
  if [ -f "$CF_ENV" ] || proc_match "cloudflared tunnel run --token-file" >/dev/null 2>&1 || proc_match "$CF_SERVICE" >/dev/null 2>&1; then
    echo cfws
    return
  fi
  if [ -f "$XRAY_CONFIG" ] && grep -q 'realitySettings' "$XRAY_CONFIG" 2>/dev/null; then
    echo reality
    return
  fi
  if [ -f "$XRAY_CONFIG" ] && grep -q 'wsSettings' "$XRAY_CONFIG" 2>/dev/null; then
    echo cfws
    return
  fi
  echo unknown
}

show_proc_block() {
  title="$1"
  pattern="$2"
  section "$title"
  if out="$(proc_match "$pattern" 2>/dev/null)" && [ -n "$out" ]; then
    printf '%s\n' "$out" | while IFS='\t' read -r pid comm args; do
      printf 'PID=%s COMM=%s\nCMD=%s\n\n' "$pid" "$comm" "$args"
    done
    return 0
  fi
  warn "未发现匹配进程: $pattern"
  return 1
}

check_reality() {
  section "部署类型：GF VLESS + Reality"
  info "判断依据: xray 配置含 realitySettings"

  state="$(service_state "$XRAY_SERVICE")"
  info "xray 服务状态: $state"

  alive=0
  if show_proc_block "xray 进程" "$XRAY_SERVICE"; then
    alive=1
  fi

  listen_port="$(awk -F: '/"port"/ {gsub(/[^0-9]/, "", $2); if ($2 != "") {print $2; exit}}' "$XRAY_CONFIG" 2>/dev/null || true)"
  if [ -n "$listen_port" ]; then
    section "监听检查"
    info "检测到本地监听端口: $listen_port"
    listeners="$(port_listeners "$listen_port")"
    if [ -n "$listeners" ]; then
      printf '%s\n' "$listeners"
      ok "端口 ${listen_port} 有监听"
    else
      warn "端口 ${listen_port} 没查到监听"
      alive=0
    fi
  else
    warn "未能从配置中解析监听端口"
  fi

  if [ "$alive" -eq 1 ]; then
    ok "Reality 节点看起来存活"
  else
    fail "Reality 节点疑似未存活"
  fi
}

check_cfws() {
  section "部署类型：CF Tunnel + VLESS WS"
  info "判断依据: cloudflared 配置/进程，或 xray 配置含 wsSettings"

  xray_ok=0
  cf_ok=0

  info "xray 服务状态: $(service_state "$XRAY_SERVICE")"
  info "cloudflared 服务状态: $(service_state "$CF_SERVICE")"

  if show_proc_block "xray 进程" "$XRAY_SERVICE"; then
    xray_ok=1
  fi
  if show_proc_block "cloudflared 进程" "cloudflared tunnel run --token-file"; then
    cf_ok=1
  elif show_proc_block "cloudflared 进程（服务名回退）" "$CF_SERVICE"; then
    cf_ok=1
  fi

  ws_port="$(awk '
    /"wsSettings"/ {flag=1}
    flag && /"port"/ {gsub(/[^0-9]/, "", $2); if ($2 != "") {print $2; exit}}
  ' "$XRAY_CONFIG" 2>/dev/null || true)"
  [ -n "$ws_port" ] || ws_port="8080"

  section "监听检查"
  info "检测到/默认 WS 本地端口: $ws_port"
  listeners="$(port_listeners "$ws_port")"
  if [ -n "$listeners" ]; then
    printf '%s\n' "$listeners"
    ok "端口 ${ws_port} 有监听"
  else
    warn "端口 ${ws_port} 没查到监听"
    xray_ok=0
  fi

  if [ "$xray_ok" -eq 1 ] && [ "$cf_ok" -eq 1 ]; then
    ok "CFWS 节点看起来存活"
  else
    fail "CFWS 节点疑似未存活"
  fi
}

main() {
  section "NAT 节点存活检测 v${SCRIPT_VERSION}"
  mode="$(detect_mode)"
  info "识别结果: $mode"
  case "$mode" in
    reality) check_reality ;;
    cfws) check_cfws ;;
    *)
      fail "未识别部署类型。当前只支持: GF VLESS + Reality / CF Tunnel + VLESS WS"
      ;;
  esac
}

main "$@"
