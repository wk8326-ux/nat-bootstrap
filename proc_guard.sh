#!/bin/sh
set -eu

LIMIT="${1:-12}"
case "$LIMIT" in
  ''|*[!0-9]*) LIMIT=12 ;;
esac
[ "$LIMIT" -ge 1 ] 2>/dev/null || LIMIT=12

PS_CMD="ps -eo pid=,ppid=,user=,comm=,%cpu=,%mem=,rss=,etime=,args="
if ! ps -eo pid= >/dev/null 2>&1; then
  PS_CMD="ps w"
fi

TMP_BASE="${TMPDIR:-/tmp}/proc_guard.$$"
RAW="$TMP_BASE.raw"
ROWS="$TMP_BASE.rows"
MAP="$TMP_BASE.map"
trap 'rm -f "$RAW" "$ROWS" "$MAP"' EXIT INT TERM

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

fmt_mem() {
  kb="$1"
  if [ "$kb" -ge 1048576 ] 2>/dev/null; then
    awk -v v="$kb" 'BEGIN{printf "%.2fG", v/1024/1024}'
  elif [ "$kb" -ge 1024 ] 2>/dev/null; then
    awk -v v="$kb" 'BEGIN{printf "%.1fM", v/1024}'
  else
    printf '%sK' "$kb"
  fi
}

clip() {
  text="$1"
  width="$2"
  printf '%s' "$text" | awk -v w="$width" '
    {
      if (length($0) <= w) { printf "%s", $0; next }
      printf "%s…", substr($0,1,w-1)
    }'
}

build_rows() {
  eval "$PS_CMD" > "$RAW"
  awk -v me="$$" '
    function is_noise(comm, args, merged) {
      merged = comm " " args
      if (comm ~ /^\[.*\]$/) return 1
      if (comm ~ /^(systemd|init|openrc-init|agetty|dbus-daemon|rsyslogd|cron|crond|sshd)$/) return 1
      if (comm ~ /^systemd-(journal|logind|network|resolve|timesyn|udevd)/) return 1
      if (comm ~ /^(login|getty)$/) return 1
      if (comm ~ /^(ksoftirqd|rcu_|migration|kworker|watchdog|oom_reaper|mm_percpu_wq|kthreadd|idle_inject|cpuhp|kdevtmpfs|jbd2|kauditd|khungtaskd|kcompactd|ksmd|khugepaged|kintegrityd|kblockd|blkcg_punt_bio|ata_sff|md|edac-poller|devfreq_wq|kswapd|ecryptfs-kthread|kthrotld|acpi_thermal_pm|scsi_eh_|scsi_tmf_|ipv6_addrconf|kstrp|zswap-shrink|charger_manager|mld|kpsmoused|ttm_swap|oom_reaper|writeback|kdmflush|kcryptd|dmcrypt_write|kaluad|nfit|crypto|kintegrityd|uas|nvme|loop|card|cfg80211|bluetooth|mld|iprt-|psimon)/) return 1
      if (comm ~ /^(ps|awk|sort|head|sed|grep|cut|tr|printf|sleep|sh)$/ && args ~ /proc_guard/) return 1
      if (comm ~ /^(fwupd|udisksd|upowerd|polkitd|rpcbind|fail2ban-server|zerotier-one|syncthing|unattended-upgr)$/) return 1
      return 0
    }
    function classify(comm, args, low, level, note) {
      low = tolower(args)
      level = "可疑"
      note = "不是系统噪音；若你不认识且长期常驻，可考虑清理。"
      if (comm ~ /^(xray|sing-box|hysteria|tuic-server|cloudflared|nezha-agent|nodeget-agent|sockd|frpc|frps|nginx|caddy|haproxy)$/) {
        level = "关键"
        note = "关键服务，误杀可能导致代理、探针或入口失效。"
      } else if (comm ~ /^(python|python3|bash|ash)$/) {
        level = "确认"
        note = "脚本/解释器类进程，先看完整命令再决定。"
      } else if (low ~ /(curl |wget |scp |rsync |tar |unzip|tail |sleep )/) {
        level = "临时"
        note = "看起来像下载、解压、传输或调试残留。"
      }
      return level "|" note
    }
    NF >= 9 {
      pid=$1; ppid=$2; user=$3; comm=$4; pcpu=$5; pmem=$6; rss=$7; etime=$8
      args=""
      for (i=9;i<=NF;i++) args = args (i==9?"":" ") $i
      if (pid == me) next
      if (is_noise(comm, args)) next
      info = classify(comm, args)
      split(info, arr, "|")
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", pid, ppid, user, comm, pcpu, pmem, rss, etime, args, arr[1] "\t" arr[2]
    }
  ' "$RAW" | sort -t ' ' -k6,6nr -k5,5nr > "$ROWS"
}

print_table() {
  count=0
  : > "$MAP"
  printf '\n仅显示本机非系统噪音进程（偏 NAT 常见服务/残留）\n\n'
  if [ ! -s "$ROWS" ]; then
    printf '没有发现额外常驻进程。\n\n'
    return
  fi
  printf '%-4s %-6s %-4s %6s %6s %8s %-14s %-44s\n' '序号' 'PID' '标签' 'CPU%' 'MEM%' 'RSS' '进程名' '命令摘要'
  printf '%s\n' '---------------------------------------------------------------------------------------------------'
  while IFS='	' read -r pid ppid user comm pcpu pmem rss etime args level note; do
    count=$((count + 1))
    [ "$count" -le "$LIMIT" ] || break
    rss_h="$(fmt_mem "$rss")"
    args_short="$(clip "$args" 44)"
    comm_short="$(clip "$comm" 14)"
    printf '%-4s %-6s %-4s %6s %6s %8s %-14s %-44s\n' "$count" "$pid" "$level" "$pcpu" "$pmem" "$rss_h" "$comm_short" "$args_short"
    printf '%s	%s	%s	%s	%s	%s	%s	%s	%s	%s	%s\n' "$count" "$pid" "$ppid" "$user" "$comm" "$pcpu" "$pmem" "$rss" "$etime" "$args" "$level|$note" >> "$MAP"
  done < "$ROWS"
  printf '\n说明：输入序号后，会先显示完整命令与解释，再由你确认是否 kill。\n\n'
}

show_details() {
  for n in "$@"; do
    line="$(awk -F '\t' -v idx="$n" '$1==idx {print; exit}' "$MAP")"
    [ -n "$line" ] || continue
    pid="$(printf '%s' "$line" | cut -f2)"
    comm="$(printf '%s' "$line" | cut -f5)"
    pcpu="$(printf '%s' "$line" | cut -f6)"
    pmem="$(printf '%s' "$line" | cut -f7)"
    rss="$(printf '%s' "$line" | cut -f8)"
    args="$(printf '%s' "$line" | cut -f10)"
    extra="$(printf '%s' "$line" | cut -f11)"
    level="${extra%%|*}"
    note="${extra#*|}"
    printf '\nPID : %s\n' "$pid"
    printf 'TAG : %s\n' "$level"
    printf 'CPU : %s%%\n' "$pcpu"
    printf 'MEM : %s%%\n' "$pmem"
    printf 'RSS : %s\n' "$(fmt_mem "$rss")"
    printf 'COMM: %s\n' "$comm"
    printf 'CMD : %s\n' "$args"
    printf 'NOTE: %s\n' "$note"
  done
  printf '\n'
}

parse_selection() {
  max="$1"
  shift
  result=""
  for token in "$@"; do
    case "$token" in
      *-*)
        a="${token%-*}"
        b="${token#*-}"
        case "$a$b" in
          ''|*[!0-9]*) continue ;;
        esac
        [ "$a" -le "$b" ] || { t="$a"; a="$b"; b="$t"; }
        i="$a"
        while [ "$i" -le "$b" ]; do
          if [ "$i" -ge 1 ] && [ "$i" -le "$max" ]; then
            case " $result " in *" $i "*) ;; *) result="$result $i" ;; esac
          fi
          i=$((i + 1))
        done
        ;;
      *)
        case "$token" in ''|*[!0-9]*) continue ;; esac
        if [ "$token" -ge 1 ] && [ "$token" -le "$max" ]; then
          case " $result " in *" $token "*) ;; *) result="$result $token" ;; esac
        fi
        ;;
    esac
  done
  printf '%s\n' "$result" | xargs 2>/dev/null || true
}

kill_selected() {
  max_shown="$(wc -l < "$MAP" | tr -d ' ')"
  [ "$max_shown" -ge 1 ] 2>/dev/null || { printf '当前没有可选进程。\n'; return; }
  printf '输入要 kill 的序号（如 2 4 7-9，直接回车取消）: '
  IFS= read -r raw || raw=""
  [ -n "$raw" ] || { printf '已取消。\n'; return; }
  selected="$(parse_selection "$max_shown" $raw)"
  [ -n "$selected" ] || { printf '没有识别到有效序号。\n'; return; }
  show_details $selected
  printf '选择信号：15=优雅终止，9=强制杀死（默认 15）: '
  IFS= read -r sig || sig="15"
  [ -n "$sig" ] || sig="15"
  case "$sig" in 15|9) ;; *) printf '不支持的信号。\n'; return ;; esac
  printf '确认执行？输入 yes 继续: '
  IFS= read -r confirm || confirm=""
  [ "$confirm" = "yes" ] || { printf '已取消。\n'; return; }
  for n in $selected; do
    pid="$(awk -F '\t' -v idx="$n" '$1==idx {print $2; exit}' "$MAP")"
    comm="$(awk -F '\t' -v idx="$n" '$1==idx {print $5; exit}' "$MAP")"
    [ -n "$pid" ] || continue
    if kill "-$sig" "$pid" 2>/dev/null; then
      printf '[OK] 已发送 SIG%s -> PID %s (%s)\n' "$sig" "$pid" "$comm"
    else
      printf '[FAIL] PID %s 处理失败\n' "$pid"
    fi
  done
}

printf '说明：这是轻量 shell 版，适合 NAT/小鸡，尽量避免 Python 依赖。\n'
printf '说明：本脚本只列当前机器内可见进程，不会扫描宿主机其它租户。\n'
printf '说明：默认隐藏大部分系统噪音，重点看代理、探针、脚本残留。\n'

while :; do
  build_rows
  print_table
  printf '操作：\n'
  printf '  k  选择序号并 kill\n'
  printf '  a  显示更多（+10）\n'
  printf '  r  刷新\n'
  printf '  q  退出\n'
  printf '请选择操作 [k/a/r/q]: '
  IFS= read -r action || action="q"
  action="${action:-r}"
  case "$action" in
    q|Q) exit 0 ;;
    a|A) LIMIT=$((LIMIT + 10)) ;;
    k|K) kill_selected; printf '\n回车继续... '; IFS= read -r _ || true ;;
    *) : ;;
  esac
done
