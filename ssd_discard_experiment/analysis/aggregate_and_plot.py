#!/usr/bin/env python3
"""
aggregate_and_plot.py — runs/ 아래 여러 실행의 summary.json 을 모아 정책별로 비교한다.

  - 같은 (워크로드, 정책, Split 조각 수) 끼리 묶어 평균과 표준편차를 낸다.
  - verdict 가 INVALID 인 실행은 뺀다(--keep-invalid 로 포함).
  - GC 복사량은 같은 워크로드의 nodiscard 평균 대비 감소율도 함께 낸다.

사용법
    python3 aggregate_and_plot.py <runs_root_dir> [--out-dir ./report]

출력: policy_comparison.csv, gc_copy_by_policy.png, waf_by_policy.png, p99_by_policy.png
"""

import argparse
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

    summaries = [json.load(open(p)) for p in sorted(args.runs_root.glob("*/summary.json"))]
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

    baseline = {}   # 워크로드별 nodiscard 평균 GC 복사량
    for (w, p, _), rows in groups.items():
        if p == "nodiscard":
            baseline[w] = mean_sd([r.get("gc_copy_bytes") for r in rows])[0]

    args.out_dir.mkdir(parents=True, exist_ok=True)
    table = []
    for key in keys:
        w, p, k = key
        rows = groups[key]
        gc_m, gc_sd, n = mean_sd([r.get("gc_copy_bytes") for r in rows])
        waf_m, waf_sd, _ = mean_sd([r.get("waf") for r in rows])
        p99_m, p99_sd, _ = mean_sd([lat(r, "measure") or lat(r, "whole_run") for r in rows])
        p99t_m, _, _ = mean_sd([lat(r, "during_trim") for r in rows])
        dsm_m, _, _ = mean_sd([r.get("dsm_ms_total") for r in rows])
        ign_m, _, _ = mean_sd([r.get("dsm_ignored_bytes") for r in rows])
        gcb_m, _, _ = mean_sd([r.get("dsm_gc_busy_cmds") for r in rows])
        base = baseline.get(w)
        red = (1 - gc_m / base) * 100 if (gc_m is not None and base) else None
        table.append({"workload": w, "policy": label(p, k), "n_runs": len(rows),
                      "gc_copy_bytes_mean": gc_m, "gc_copy_bytes_sd": gc_sd,
                      "gc_copy_reduction_vs_nodiscard_pct": red,
                      "waf_mean": waf_m, "waf_sd": waf_sd,
                      "read_p99_ns_mean": p99_m, "read_p99_ns_sd": p99_sd,
                      "read_p99_ns_during_trim_mean": p99t_m, "dsm_ms_total_mean": dsm_m,
                      "dsm_ignored_bytes_mean": ign_m, "dsm_gc_busy_cmds_mean": gcb_m})

    cols = list(table[0].keys())
    with open(args.out_dir / "policy_comparison.csv", "w") as f:
        f.write(",".join(cols) + "\n")
        for r in table:
            f.write(",".join("" if r[c] is None else str(r[c]) for c in cols) + "\n")
    print(f"[OK] 표 저장: {args.out_dir / 'policy_comparison.csv'}")
    for r in table:
        if r["n_runs"] < 3:
            print(f"[NOTE] {r['workload']} / {r['policy']}: 실행 {r['n_runs']}회. 평균 비교는 탐색 수준으로만 볼 것")

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
    bar("read_p99_ns_mean", "read_p99_ns_sd", "p99 read latency (ms)", "Read p99 by discard policy",
        "p99_by_policy.png", 1e-6)
    print(f"[OK] 그래프 저장: {args.out_dir}")


if __name__ == "__main__":
    main()
