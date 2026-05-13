#!/usr/bin/env python3
import os
import re
import shlex
import signal
import subprocess
import sys
from dataclasses import dataclass
from typing import List, Dict, Tuple

KEEP_RULES = [
    (r"^xray$", "代理核心，负责 VLESS/VMess/Trojan 等入站或出站转发。杀掉后代理通常立刻失效。"),
    (r"^sing-box$", "代理核心，负责代理协议与路由。杀掉后代理通常立刻失效。"),
    (r"^hysteria$", "Hysteria/HY2 代理核心。杀掉后该节点协议会失效。"),
    (r"^tuic-server$", "TUIC 服务端进程。杀掉后 TUIC 节点失效。"),
    (r"^cloudflared$", "Cloudflare Tunnel 进程。若节点依赖 CF Tunnel/Argo，这个不能随便杀。"),
    (r"^nezha-agent$", "哪吒探针。杀掉后面板监控会离线，但通常不影响代理转发本身。"),
    (r"^nodeget-agent$", "NodeGet 探针/客户端。杀掉后对应面板或任务上报会中断。"),
    (r"^sockd$", "Dante/sockd SOCKS 代理服务。若你在用 SOCKS 入口，就不能杀。"),
    (r"^frpc$", "frp 客户端。用于内网穿透/反向代理。杀掉后穿透会断。"),
    (r"^frps$", "frp 服务端。用于承接 frp 客户端连接。杀掉后下游穿透会断。"),
    (r"^nginx$", "Nginx 反向代理/静态服务。若站点或面板靠它暴露，则不能杀。"),
    (r"^caddy$", "Caddy 反向代理/站点服务。若站点靠它暴露，则不能杀。"),
    (r"^haproxy$", "负载均衡/反代服务。杀掉后入口可能中断。"),
    (r"^python3?$", "通用 Python 进程。可能是脚本、bot、面板或临时任务，需要看命令行再判断。"),
    (r"^bash$", "Shell 进程，常见于登录会话、脚本执行或守护包装层。通常先别动。"),
    (r"^sh$", "Shell 进程，常见于启动脚本或会话。通常先别动。"),
    (r"^sshd$", "SSH 服务端。杀掉可能导致无法再登录机器。"),
    (r"^crond$", "定时任务守护进程。杀掉后 cron 任务不会继续执行。"),
    (r"^cron$", "定时任务守护进程。杀掉后 cron 任务不会继续执行。"),
    (r"^systemd$", "系统初始化/服务管理进程。不要动。"),
    (r"^init$", "系统初始化进程。不要动。"),
    (r"^openrc-init$", "OpenRC 初始化进程。不要动。"),
]

SAFE_SIGNALS = {
    "15": signal.SIGTERM,
    "9": signal.SIGKILL,
}

@dataclass
class Proc:
    pid: int
    ppid: int
    comm: str
    user: str
    etime: str
    args: str
    note: str
    category: str


def run(cmd: List[str]) -> str:
    return subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)


def classify(comm: str, args: str) -> Tuple[str, str]:
    text = f"{comm} {args}".strip()
    for pattern, note in KEEP_RULES:
        if re.search(pattern, comm):
            if comm == "python" or comm == "python3":
                if "nezha" in args:
                    return "keep", "Python 进程，但命令行里带哪吒相关内容，优先视为监控/运维脚本。"
                if "nanobot" in args or "bot" in args:
                    return "check", "Python 进程，像机器人/脚本服务，先确认是否在跑自动任务。"
            return "keep", note

    low = text.lower()
    if any(k in low for k in ["apt", "apk", "dnf", "yum", "opkg"]):
        return "temp", "包管理相关临时进程，常见于安装/更新期间，平时一般不会常驻。"
    if any(k in low for k in ["curl ", "wget ", "tar ", "unzip", "gzip", "scp ", "rsync "]):
        return "temp", "下载/解压/传输类进程，通常是临时任务，可按当前是否仍在执行判断。"
    if any(k in low for k in ["sleep ", "tail ", "less", "vi ", "vim ", "nano "]):
        return "temp", "交互/观察类进程，多半只是终端操作残留。"
    return "unknown", "未命中常见关键进程规则。NAT/轻量机上若不是你认识的服务，通常值得进一步检查。"


def list_processes() -> List[Proc]:
    out = run(["ps", "-eo", "pid=,ppid=,user=,comm=,etime=,args="])
    procs: List[Proc] = []
    for raw in out.splitlines():
        raw = raw.rstrip()
        if not raw:
            continue
        parts = raw.split(None, 5)
        if len(parts) < 6:
            continue
        pid, ppid, user, comm, etime, args = parts
        if int(pid) == os.getpid():
            continue
        category, note = classify(comm, args)
        procs.append(Proc(int(pid), int(ppid), comm, user, etime, args, note, category))
    procs.sort(key=lambda p: (p.category != "keep", p.comm, p.pid))
    return procs


def print_table(procs: List[Proc]) -> None:
    print("\n当前进程列表：\n")
    for idx, p in enumerate(procs, start=1):
        tag = {"keep": "保留", "check": "确认", "temp": "临时", "unknown": "未知"}.get(p.category, p.category)
        print(f"[{idx:02d}] PID={p.pid:<6} USER={p.user:<8} COMM={p.comm:<14} TAG={tag:<4} ETIME={p.etime}")
        print(f"     CMD : {p.args}")
        print(f"     NOTE: {p.note}")
        print()


def choose_indices(max_n: int) -> List[int]:
    text = input("输入要处理的序号（如 3 5 8-10，直接回车返回）: ").strip()
    if not text:
        return []
    result = []
    for token in text.split():
        if "-" in token:
            a, b = token.split("-", 1)
            if a.isdigit() and b.isdigit():
                aa, bb = int(a), int(b)
                if aa > bb:
                    aa, bb = bb, aa
                result.extend(range(aa, bb + 1))
        elif token.isdigit():
            result.append(int(token))
    return sorted({x for x in result if 1 <= x <= max_n})


def confirm_and_kill(selected: List[Proc]) -> None:
    if not selected:
        print("未选择任何进程。")
        return

    print("\n将处理这些进程：\n")
    for p in selected:
        print(f"- PID={p.pid} COMM={p.comm} TAG={p.category} CMD={p.args}")

    sig = input("选择信号：15=优雅终止，9=强制杀死（默认 15）: ").strip() or "15"
    if sig not in SAFE_SIGNALS:
        print("不支持的信号。")
        return

    ans = input("确认执行？输入 yes 继续: ").strip().lower()
    if ans != "yes":
        print("已取消。")
        return

    for p in selected:
        try:
            os.kill(p.pid, SAFE_SIGNALS[sig])
            print(f"[OK] 已发送 SIG{sig} -> PID {p.pid} ({p.comm})")
        except ProcessLookupError:
            print(f"[SKIP] PID {p.pid} 已不存在")
        except PermissionError:
            print(f"[FAIL] 无权限杀死 PID {p.pid}")
        except Exception as e:
            print(f"[FAIL] PID {p.pid}: {e}")


def main() -> int:
    if os.geteuid() != 0:
        print("建议用 root 运行，否则可能无法杀掉目标进程。", file=sys.stderr)

    while True:
        procs = list_processes()
        print_table(procs)
        print("操作：")
        print("  k  选择序号并 kill")
        print("  r  刷新列表")
        print("  q  退出")
        action = input("请选择操作 [k/r/q]: ").strip().lower() or "r"
        if action == "q":
            return 0
        if action == "r":
            continue
        if action == "k":
            indices = choose_indices(len(procs))
            selected = [procs[i - 1] for i in indices]
            confirm_and_kill(selected)
            input("\n回车继续... ")
            continue
        print("未知操作，已刷新。")


if __name__ == "__main__":
    raise SystemExit(main())
