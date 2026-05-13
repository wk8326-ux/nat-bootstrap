#!/usr/bin/env python3
import os
import re
import signal
import subprocess
import sys
from dataclasses import dataclass
from typing import List, Tuple

SAFE_SIGNALS = {"15": signal.SIGTERM, "9": signal.SIGKILL}
SYSTEM_PROCESS_PATTERNS = [
    r"^\[.*\]$",
    r"^systemd",
    r"^init$",
    r"^openrc-init$",
    r"^agetty$",
    r"^dbus-daemon$",
    r"^rsyslogd$",
    r"^cron$",
    r"^crond$",
    r"^systemd-journal",
    r"^systemd-logind$",
    r"^systemd-network",
    r"^systemd-resolve",
    r"^systemd-timesyn",
    r"^systemd-udevd$",
    r"^sshd$",
]

FOCUS_RULES = [
    (r"^xray$", "关键", "代理核心，负责 VLESS/WS/Reality 等流量转发；杀掉后节点通常立刻失效。"),
    (r"^sing-box$", "关键", "代理核心，负责 sing-box 协议与路由；杀掉后代理失效。"),
    (r"^hysteria$", "关键", "Hysteria/HY2 核心进程；杀掉后该协议不可用。"),
    (r"^tuic-server$", "关键", "TUIC 服务端；杀掉后 TUIC 不可用。"),
    (r"^cloudflared$", "关键", "Cloudflare Tunnel 进程；若节点靠 CF Tunnel 出口，这个不能动。"),
    (r"^nezha-agent$", "关键", "哪吒探针；杀掉后面板离线，但一般不影响代理转发。"),
    (r"^nodeget-agent$", "关键", "NodeGet 探针/客户端；杀掉后面板或任务上报中断。"),
    (r"^sockd$", "关键", "SOCKS 代理服务；若你在用 SOCKS 入口，这个不能动。"),
    (r"^frpc$", "关键", "frp 客户端；用于穿透或中转，杀掉后通道断。"),
    (r"^frps$", "关键", "frp 服务端；承接下游 frp，杀掉后穿透断。"),
    (r"^nginx$", "关键", "反向代理/站点服务；如入口靠它暴露，则不能动。"),
    (r"^caddy$", "关键", "反向代理/站点服务；如入口靠它暴露，则不能动。"),
    (r"^haproxy$", "关键", "负载均衡/反代服务；入口依赖时不能动。"),
    (r"^python3?$", "确认", "Python 进程；可能是脚本、bot、面板或残留任务，需要看命令行判断。"),
    (r"^bash$", "确认", "Shell 进程；常见于登录会话或脚本包装层，先确认是不是你当前在跑的任务。"),
    (r"^sh$", "确认", "Shell 进程；常见于脚本或会话包装层，先确认。"),
]

TEMP_HINTS = [
    ("curl ", "下载任务，常见于安装脚本或调试残留。"),
    ("wget ", "下载任务，常见于安装脚本或调试残留。"),
    ("scp ", "文件传输任务，通常是临时进程。"),
    ("rsync ", "文件同步/传输任务，通常是临时进程。"),
    ("tar ", "解压/打包任务，通常是临时进程。"),
    ("unzip", "解压任务，通常是临时进程。"),
    ("sleep ", "等待任务，若长期挂着通常可疑。"),
    ("tail ", "看日志任务，通常只是会话残留。"),
]

@dataclass
class Proc:
    pid: int
    ppid: int
    user: str
    comm: str
    pcpu: float
    pmem: float
    rss_kb: int
    etime: str
    args: str
    level: str
    note: str


def sh(cmd: List[str]) -> str:
    return subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)


def is_system_noise(comm: str, args: str) -> bool:
    merged = f"{comm} {args}".strip()
    return any(re.search(p, comm) for p in SYSTEM_PROCESS_PATTERNS) or merged.startswith("[")


def classify(comm: str, args: str) -> Tuple[str, str]:
    for pattern, level, note in FOCUS_RULES:
        if re.search(pattern, comm):
            if comm in ("python", "python3"):
                low = args.lower()
                if "nezha" in low:
                    return "关键", "Python 进程，但命令行里带哪吒内容，优先视为监控/探针相关。"
                if "nanobot" in low or "bot" in low:
                    return "确认", "Python 进程，看起来像 bot/自动脚本；若不是你现在需要的服务，可手动处理。"
            return level, note

    low = args.lower()
    for token, note in TEMP_HINTS:
        if token in low:
            return "临时", note

    return "可疑", "不是系统噪音，也没命中常见必备服务；若占用高且你不认识，通常值得手工清理。"


def list_procs() -> List[Proc]:
    out = sh(["ps", "-eo", "pid=,ppid=,user=,comm=,%cpu=,%mem=,rss=,etime=,args="])
    rows: List[Proc] = []
    me = os.getpid()
    parent = os.getppid()
    for raw in out.splitlines():
        raw = raw.rstrip()
        if not raw:
            continue
        parts = raw.split(None, 8)
        if len(parts) < 9:
            continue
        pid, ppid, user, comm, pcpu, pmem, rss, etime, args = parts
        pid_i = int(pid)
        ppid_i = int(ppid)
        if pid_i in (me, parent):
            continue
        if is_system_noise(comm, args):
            continue
        level, note = classify(comm, args)
        rows.append(Proc(pid_i, ppid_i, user, comm, float(pcpu), float(pmem), int(rss), etime, args, level, note))
    rows.sort(key=lambda p: (-p.pmem, -p.pcpu, -p.rss_kb, p.pid))
    return rows


def fmt_mem(kb: int) -> str:
    if kb >= 1024 * 1024:
        return f"{kb / 1024 / 1024:.2f}G"
    if kb >= 1024:
        return f"{kb / 1024:.1f}M"
    return f"{kb}K"


def clip(text: str, width: int) -> str:
    if len(text) <= width:
        return text.ljust(width)
    return text[: width - 1] + "…"


def print_view(rows: List[Proc], limit: int) -> None:
    print("\n仅显示本机非系统噪音进程（按内存/CPU占用排序）\n")
    if not rows:
        print("没有发现额外常驻进程；当前可见的基本都是系统必需进程。\n")
        return

    header = f"{'序号':<4} {'PID':<6} {'标签':<4} {'CPU%':>6} {'MEM%':>6} {'RSS':>8} {'进程名':<14} {'命令摘要':<44}"
    print(header)
    print("-" * len(header))
    for idx, p in enumerate(rows[:limit], start=1):
        print(f"{idx:<4} {p.pid:<6} {p.level:<4} {p.pcpu:>6.1f} {p.pmem:>6.1f} {fmt_mem(p.rss_kb):>8} {clip(p.comm, 14)} {clip(p.args, 44)}")
    print()
    print("说明：输入序号后，会再显示该进程的完整命令与解释，再由你确认是否 kill。\n")


def show_details(selected: List[Proc]) -> None:
    print("\n已选进程详情：\n")
    for p in selected:
        print(f"PID : {p.pid}")
        print(f"TAG : {p.level}")
        print(f"CPU : {p.pcpu:.1f}%")
        print(f"MEM : {p.pmem:.1f}%")
        print(f"RSS : {fmt_mem(p.rss_kb)}")
        print(f"COMM: {p.comm}")
        print(f"CMD : {p.args}")
        print(f"NOTE: {p.note}")
        print()


def choose_indices(max_n: int) -> List[int]:
    text = input("输入要 kill 的序号（如 2 4 7-9，直接回车取消）: ").strip()
    if not text:
        return []
    picked = set()
    for token in text.split():
        if "-" in token:
            a, b = token.split("-", 1)
            if a.isdigit() and b.isdigit():
                aa, bb = int(a), int(b)
                if aa > bb:
                    aa, bb = bb, aa
                for i in range(aa, bb + 1):
                    if 1 <= i <= max_n:
                        picked.add(i)
        elif token.isdigit():
            i = int(token)
            if 1 <= i <= max_n:
                picked.add(i)
    return sorted(picked)


def do_kill(chosen: List[Proc]) -> None:
    if not chosen:
        print("未选择任何进程。")
        return
    show_details(chosen)
    sig = input("选择信号：15=优雅终止，9=强制杀死（默认 15）: ").strip() or "15"
    if sig not in SAFE_SIGNALS:
        print("不支持的信号。")
        return
    confirm = input("确认执行？输入 yes 继续: ").strip().lower()
    if confirm != "yes":
        print("已取消。")
        return
    for p in chosen:
        try:
            os.kill(p.pid, SAFE_SIGNALS[sig])
            print(f"[OK] 已发送 SIG{sig} -> PID {p.pid} ({p.comm})")
        except ProcessLookupError:
            print(f"[SKIP] PID {p.pid} 已不存在")
        except PermissionError:
            print(f"[FAIL] 无权限处理 PID {p.pid}")
        except Exception as e:
            print(f"[FAIL] PID {p.pid}: {e}")


def main() -> int:
    if os.geteuid() != 0:
        print("建议用 root 运行，否则可能无法 kill 目标进程。", file=sys.stderr)
    limit = 12
    if len(sys.argv) > 1 and sys.argv[1].isdigit():
        limit = max(1, int(sys.argv[1]))

    print("说明：这是 Python 脚本，正确运行方式是 `python3 proc_guard.py`，不要用 bash 直接执行。")
    print("说明：本脚本只列本机进程，不会扫描宿主机其它租户。它基于当前 NAT/VPS 容器/虚机内可见的 ps 结果工作。")
    print("说明：默认隐藏系统噪音，只关注你后装服务、残留脚本、代理/探针相关进程。")

    while True:
        rows = list_procs()
        shown = rows[:limit]
        print_view(rows, limit)
        print("操作：")
        print("  k  选择序号并 kill")
        print("  a  显示更多（+10）")
        print("  r  刷新")
        print("  q  退出")
        action = input("请选择操作 [k/a/r/q]: ").strip().lower() or "r"
        if action == "q":
            return 0
        if action == "a":
            limit += 10
            continue
        if action == "k":
            idxs = choose_indices(len(shown))
            chosen = [shown[i - 1] for i in idxs]
            do_kill(chosen)
            input("\n回车继续... ")
            continue


if __name__ == "__main__":
    raise SystemExit(main())
