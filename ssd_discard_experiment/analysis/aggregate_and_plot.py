#!/usr/bin/env python3
"""
aggregate_and_plot.py

runs/ 아래 여러 조합의 summary.json(correlate_and_compute.py 출력물)을 모아
policy별로 WAF / 죽은 데이터 비율 / p99 지연을 비교하는 표와 막대그래프를 만든다.

사용법:
    python3 aggregate_and_plot.py <runs_root_dir> --out-dir ./report
"""

import argparse
import json
from pathlib import Path
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


def load_all_summaries(runs_root: Path):
    summaries = []
    for summary_path in runs_root.glob("*/summary.json"):
        with open(summary_path) as f:
            summaries.append(json.load(f))
    return summaries


def group_by_policy(summaries):
    grouped = defaultdict(list)
    for s in summaries:
        grouped[s.get("policy", "unknown")].append(s)
    return grouped


def avg(values):
    values = [v for v in values if v is not None]
    return sum(values) / len(values) if values else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("runs_root", type=Path)
    ap.add_argument("--out-dir", type=Path, default=Path("./report"))
    args = ap.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    summaries = load_all_summaries(args.runs_root)

    if not summaries:
        print(f"[WARN] {args.runs_root} 아래에서 summary.json을 찾지 못했습니다.")
        return

    grouped = group_by_policy(summaries)
    policies = sorted(grouped.keys())

    # ---- 표 (CSV) ----
    table_path = args.out_dir / "policy_comparison.csv"
    with open(table_path, "w") as f:
        f.write("policy,n_runs,avg_waf,avg_dead_copy_ratio,avg_p99_ns\n")
        for p in policies:
            rows = grouped[p]
            waf_avg = avg([r.get("waf") for r in rows])
            dead_ratio_avg = avg([r.get("dead_copy_ratio") for r in rows])
            p99_avg = avg([
                (r.get("latency_ns") or {}).get("p99_ns") for r in rows
            ])
            f.write(f"{p},{len(rows)},{waf_avg},{dead_ratio_avg},{p99_avg}\n")

    print(f"[OK] 표 저장: {table_path}")

    # ---- 그래프 1: policy별 평균 WAF ----
    waf_values = [avg([r.get("waf") for r in grouped[p]]) or 0 for p in policies]
    plt.figure()
    plt.bar(policies, waf_values)
    plt.ylabel("Average WAF")
    plt.title("Discard 방식별 평균 WAF")
    plt.savefig(args.out_dir / "waf_by_policy.png", bbox_inches="tight")
    plt.close()

    # ---- 그래프 2: policy별 평균 죽은 데이터 비율 ----
    dead_ratio_values = [
        avg([r.get("dead_copy_ratio") for r in grouped[p]]) or 0 for p in policies
    ]
    plt.figure()
    plt.bar(policies, dead_ratio_values)
    plt.ylabel("Dead Data Copy Ratio")
    plt.title("Discard 방식별 죽은 데이터 복사 비율")
    plt.savefig(args.out_dir / "dead_ratio_by_policy.png", bbox_inches="tight")
    plt.close()

    # ---- 그래프 3: policy별 평균 p99 지연 ----
    p99_values = [
        avg([(r.get("latency_ns") or {}).get("p99_ns") for r in grouped[p]]) or 0
        for p in policies
    ]
    plt.figure()
    plt.bar(policies, p99_values)
    plt.ylabel("p99 Read Latency (ns)")
    plt.title("Discard 방식별 p99 읽기 지연")
    plt.savefig(args.out_dir / "p99_by_policy.png", bbox_inches="tight")
    plt.close()

    print(f"[OK] 그래프 3개 저장됨: {args.out_dir}")


if __name__ == "__main__":
    main()
