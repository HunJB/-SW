#!/usr/bin/env python3
"""
aggregate_and_plot.py — runs/ 아래 여러 실행의 summary.json 을 모아 정책별로 비교한다.

  - 같은 (워크로드, 정책, Split 조각 수) 끼리 묶어 평균과 표준편차를 낸다.
  - verdict 가 INVALID 인 실행은 뺀다(--keep-invalid 로 포함).
  - GC 복사량은 같은 워크로드의 nodiscard 평균 대비 감소율도 함께 낸다.

사용법
    python3 aggregate_and_plot.py <runs_root_dir> [--out-dir ./report]

출력
  policy_comparison.csv     정책별 평균·표준편차·최소·최대, nodiscard 대비 감소율
  runs_detail.csv           실행 하나당 한 줄 (반복별 값을 그대로 보여 줄 때)
  cycle_gc_copy.csv         cycle별 GC 복사량의 정책별 평균 (시간에 따른 변화)
  gc_copy_by_policy.png, waf_by_policy.png, p99_by_policy.png,
  victim_ratio_by_policy.png, cycle_gc_copy.png
"""

import argparse
import csv
import json
import statistics
from collections import defaultdict
from pathlib import Path

ORDER = {"nodiscard": 0, "immediate": 1, "batch": 2, "split": 3}


def mean_sd(values):
    values = [v for v in values if v is not None]
    if not values:
        return None, None, 0
    return statistics.mean(values), (statistics.stdev(values) if len(values) > 1 else 0.0), len(values)


def min_max(values):
    values = [v for v in values if v is not None]
    return (min(values), max(values)) if values else (None, None)


# 실행별로 모으는 값: (표 이름, summary 에서 꺼내는 함수)
DETAIL = [
    ("gc_copy_bytes", lambda s: s.get("gc_copy_bytes")),
    ("steady_gc_copy_bytes", lambda s: s.get("steady_gc_copy_bytes")),
    ("steady_gc_copy_ratio", lambda s: s.get("steady_gc_copy_ratio")),
    ("waf", lambda s: s.get("waf")),
    ("gc_count", lambda s: s.get("gc_count")),
    ("full_invalid_victim_ratio", lambda s: s.get("full_invalid_victim_ratio")),
    ("gc_copy_bytes_per_victim", lambda s: s.get("gc_copy_bytes_per_victim")),
    ("first_gc_cycle", lambda s: s.get("first_gc_cycle")),
    ("host_write_bytes", lambda s: s.get("host_write_bytes")),
    ("dsm_cmd", lambda s: s.get("dsm_cmd")),
    ("dsm_req_bytes", lambda s: s.get("dsm_req_bytes")),
    ("dsm_invalid_bytes", lambda s: s.get("dsm_invalid_bytes")),
    ("dsm_ignored_bytes", lambda s: s.get("dsm_ignored_bytes")),
    ("dsm_ms_total", lambda s: s.get("dsm_ms_total")),
    ("trim_seconds", lambda s: s.get("trim_seconds")),
    ("read_p99_ns", lambda s: lat(s, "measure") or lat(s, "whole_run")),
    ("read_p999_ns", lambda s: lat(s, "measure", "p999_ns")),
    ("read_p99_ns_without_uart_stall", lambda s: lat(s, "without_uart_stall")),
    ("read_p999_ns_without_uart_stall", lambda s: lat(s, "without_uart_stall", "p999_ns")),
    ("read_p99_ns_during_trim", lambda s: lat(s, "during_trim")),
    ("read_p99_ns_outside_trim", lambda s: lat(s, "outside_trim")),
]


def load_cycles(run_dir):
    """cycles.csv 에서 측정 cycle(c1..cN)만 순서대로."""
    path = run_dir / "cycles.csv"
    if not path.exists():
        return []
    out = []
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            to = r.get("to", "")
            if to.startswith("c") and to[1:].isdigit():
                out.append((int(to[1:]), int(r["gc_copy_B"] or 0), int(r["host_wr_B"] or 0)))
    return sorted(out)


def lat(summary, phase, key="p99_ns"):
    return ((summary.get("latency_ns") or {}).get(phase) or {}).get(key)


def label(policy, k):
    return f"split K={k}" if policy == "split" and k is not None else str(policy)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("runs_root", type=Path)
    ap.add_argument("--out-dir", type=Path, default=Path("./report"))
    ap.add_argument("--keep-invalid", action="store_true")
    args = ap.parse_args()

    summaries = []
    for p in sorted(args.runs_root.glob("*/summary.json")):
        s = json.load(open(p))
        s["_dir"] = p.parent
        summaries.append(s)
    if not summaries:
        print(f"[WARN] {args.runs_root} 아래에서 summary.json 을 찾지 못했습니다.")
        return
    dropped = [s for s in summaries if str(s.get("verdict", "")).startswith("INVALID")]
    if dropped and not args.keep_invalid:
        for s in dropped:
            print(f"[SKIP] {s.get('run_id')}: {s.get('verdict')}")
        summaries = [s for s in summaries if s not in dropped]

    groups = defaultdict(list)
    for s in summaries:
        groups[(s.get("workload"), s.get("policy"), s.get("split_k"))].append(s)
    keys = sorted(groups, key=lambda k: (str(k[0]), ORDER.get(k[1], 9), k[2] or 0))

    baseline = {}   # (워크로드, 지표)별 nodiscard 평균
    for (w, p, _), rows in groups.items():
        if p == "nodiscard":
            for name in ("gc_copy_bytes", "steady_gc_copy_bytes"):
                baseline[(w, name)] = mean_sd([r.get(name) for r in rows])[0]

    args.out_dir.mkdir(parents=True, exist_ok=True)

    # 실행 하나당 한 줄
    with open(args.out_dir / "runs_detail.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["run_id", "workload", "policy", "rep", "verdict"] + [n for n, _ in DETAIL])
        for key in keys:
            for r in sorted(groups[key], key=lambda r: r.get("rep") or 0):
                w.writerow([r.get("run_id"), r.get("workload"), label(r.get("policy"), r.get("split_k")),
                            r.get("rep"), r.get("verdict")] + [get(r) for _, get in DETAIL])

    table = []
    for key in keys:
        w, p, k = key
        rows = groups[key]
        row = {"workload": w, "policy": label(p, k), "n_runs": len(rows)}
        for name, get in DETAIL:
            vals = [get(r) for r in rows]
            m, sd, _ = mean_sd(vals)
            lo, hi = min_max(vals)
            row[f"{name}_mean"], row[f"{name}_sd"], row[f"{name}_min"], row[f"{name}_max"] = m, sd, lo, hi
        for name in ("gc_copy_bytes", "steady_gc_copy_bytes"):
            base = baseline.get((w, name))
            m = row[f"{name}_mean"]
            row[f"{name}_reduction_vs_nodiscard_pct"] = (1 - m / base) * 100 if (m is not None and base) else None
        table.append(row)

    cols = list(table[0].keys())
    with open(args.out_dir / "policy_comparison.csv", "w", newline="") as f:
        wr = csv.DictWriter(f, fieldnames=cols)
        wr.writeheader()
        wr.writerows(table)
    print(f"[OK] 표 저장: {args.out_dir / 'policy_comparison.csv'}, runs_detail.csv")
    for r in table:
        if r["n_runs"] < 3:
            print(f"[NOTE] {r['workload']} / {r['policy']}: 실행 {r['n_runs']}회. 평균 비교는 탐색 수준으로만 볼 것")

    # 화면 요약: 논문 표에 바로 옮길 수 있는 값
    print("\n정책별 요약 (평균 ± 표준편차, 괄호는 nodiscard 대비 GC 복사량 감소율)")
    for r in table:
        def g(n, scale=1.0, fmt="{:.2f}"):
            m, sd = r[f"{n}_mean"], r[f"{n}_sd"]
            return "-" if m is None else (fmt.format(m * scale) + " ± " + fmt.format((sd or 0) * scale))
        red = r["gc_copy_bytes_reduction_vs_nodiscard_pct"]
        print(f"  {r['workload']:3s} {r['policy']:12s} n={r['n_runs']}  "
              f"GC copy {g('gc_copy_bytes', 1 / 2**30)} GiB"
              f"{'' if red is None or r['policy'] == 'nodiscard' else f' (감소 {red:.1f}%)'}  "
              f"WAF {g('waf', fmt='{:.3f}')}  "
              f"full-invalid victim {g('full_invalid_victim_ratio', 100, '{:.1f}')}%  "
              f"p99 {g('read_p99_ns_without_uart_stall', 1e-6)} ms")

    # cycle별 GC 복사량: 정책별로 반복 평균
    per_cycle = defaultdict(lambda: defaultdict(list))
    for key in keys:
        for r in groups[key]:
            run_dir = r["_dir"]
            for c, gc, _ in load_cycles(run_dir):
                per_cycle[(key[0], label(key[1], key[2]))][c].append(gc)
    if per_cycle:
        with open(args.out_dir / "cycle_gc_copy.csv", "w", newline="") as f:
            wr = csv.writer(f)
            wr.writerow(["workload", "policy", "cycle", "n_runs", "gc_copy_bytes_mean", "gc_copy_bytes_sd"])
            for (w, p), cyc in per_cycle.items():
                for c in sorted(cyc):
                    m, sd, n = mean_sd(cyc[c])
                    wr.writerow([w, p, c, n, m, sd])

    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("[NOTE] matplotlib 이 없어 그래프는 건너뜁니다 (pip install matplotlib)")
        return

    # 그래프 글자는 영어로 둔다. 한글 글꼴이 없는 환경에서 글자가 깨지기 때문이다.
    def bar(metric, sd, ylabel, title, fname, scale=1.0):
        rows = [r for r in table if r[metric] is not None]
        if not rows:
            return
        names = [f"{r['workload']}\n{r['policy']}" for r in rows]
        plt.figure(figsize=(max(5, 1.2 * len(rows)), 4))
        plt.bar(names, [r[metric] * scale for r in rows],
                yerr=[(r[sd] or 0) * scale for r in rows] if sd else None, capsize=4)
        plt.ylabel(ylabel)
        plt.title(title)
        plt.savefig(args.out_dir / fname, bbox_inches="tight", dpi=150)
        plt.close()

    bar("gc_copy_bytes_mean", "gc_copy_bytes_sd", "GC copy (GiB)", "GC copy by discard policy",
        "gc_copy_by_policy.png", 1 / 2**30)
    bar("waf_mean", "waf_sd", "WAF", "WAF by discard policy", "waf_by_policy.png")
    bar("read_p99_ns_without_uart_stall_mean", "read_p99_ns_without_uart_stall_sd", "p99 read latency (ms)",
        "Read p99 by discard policy (UART stalls excluded)", "p99_by_policy.png", 1e-6)
    bar("full_invalid_victim_ratio_mean", "full_invalid_victim_ratio_sd", "Fully invalid victims (%)",
        "GC victims with no valid data", "victim_ratio_by_policy.png", 100)

    if per_cycle:
        plt.figure(figsize=(7, 4))
        for (w, p), cyc in sorted(per_cycle.items(), key=lambda kv: (kv[0][0], ORDER.get(kv[0][1].split()[0], 9))):
            xs = sorted(cyc)
            plt.plot(xs, [statistics.mean(cyc[c]) / 2**20 for c in xs], marker="o", ms=3, label=f"{w} {p}")
        plt.gca().xaxis.get_major_locator().set_params(integer=True)
        plt.xlabel("cycle")
        plt.ylabel("GC copy per cycle (MiB)")
        plt.title("GC copy per cycle (mean over runs)")
        plt.legend()
        plt.savefig(args.out_dir / "cycle_gc_copy.png", bbox_inches="tight", dpi=150)
        plt.close()
    print(f"[OK] 그래프 저장: {args.out_dir}")


if __name__ == "__main__":
    main()
