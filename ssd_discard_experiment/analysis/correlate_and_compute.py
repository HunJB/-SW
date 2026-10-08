#!/usr/bin/env python3
"""
correlate_and_compute.py — 실행 하나(run_dir)의 결과를 summary.json 으로 정리한다.

입력 (run_dir 안, 있는 것만 사용)
  manifest.json          실행 설정
  host_events.csv        파일 생성·삭제·TRIM 시각, 파일이 차지한 장치 범위
  expstat_summary.json   Cosmos+ 계측 펌웨어 카운터의 구간 차이 (EXPSTAT=1 로 실행했을 때)
  fio_probe.json, probe_lat.1.log   배경 읽기 probe 지연
  ftl_gc_log.csv         FEMU가 남긴 이벤트 로그 (tick_ns,type,lba,length_bytes,src_ppa,dst_ppa)

출력
  GC 복사량, WAF, DSM 통계        카운터가 있으면 카운터에서, 없으면 FEMU 로그에서
  읽기 지연 p50/p95/p99           측정 구간 전체, TRIM 구간, 그 밖
  삭제된 데이터의 복사량          FEMU 이벤트 로그가 있을 때만 (보드는 합계 카운터만 남긴다)

사용법
  python3 correlate_and_compute.py <run_dir> [--out summary.json] [--ftl-lba-bytes 512]

삭제된 데이터의 복사량을 세는 기준
  삭제된 범위는 unlink 시각부터 그 범위에 대한 discard가 도착하거나 다른 파일이 그 자리를
  다시 차지할 때까지 '삭제됐지만 SSD는 모르는' 상태다. 이 구간에 GC가 그 범위를 옮기면 센다.
  호스트 시각과 FEMU 시각을 비교하므로 두 시계가 맞아 있어야 한다(femu_patch/README_PATCH.md).
"""

import argparse
import bisect
import csv
import json
import sys
from pathlib import Path

FS_BLOCK = 4096


# ---------- 호스트 이벤트 ----------

def load_host_events(path: Path):
    ev = {"deleted": [], "created": [], "trim": [], "measure": [None, None], "host_write_bytes": 0}
    pending = {}
    trim_start = None
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            t = int(row["event_time_ns"]) if row["event_time_ns"] else None
            kind, p = row["event_type"], row["path"]
            if kind == "measure_start":
                ev["measure"][0] = t
            elif kind == "measure_end":
                ev["measure"][1] = t
            elif kind == "file_create":
                # 측정 구간 안에서 쓴 양만 더한다 (사전 쓰기 제외)
                if ev["measure"][0] is not None:
                    ev["host_write_bytes"] += parse_bytes(row["length_bytes"])
            elif kind == "create_extent":
                ev["created"].append((int(row["start_lba"]) * FS_BLOCK, int(row["length_bytes"]), t))
            elif kind == "pre_delete_extent":
                pending.setdefault(p, []).append((int(row["start_lba"]) * FS_BLOCK, int(row["length_bytes"])))
            elif kind == "unlink":
                for start, length in pending.pop(p, []):
                    ev["deleted"].append((start, length, t))
            elif kind == "fstrim_start":
                trim_start = t
            elif kind == "fstrim_end" and trim_start is not None:
                ev["trim"].append((trim_start, t))
                trim_start = None
    return ev


def parse_bytes(s):
    s = (s or "").strip()
    if not s:
        return 0
    if s.endswith("MiB"):          # 예전 형식
        return int(float(s[:-3]) * 1024 * 1024)
    return int(s)


# ---------- 읽기 지연 ----------

def percentile(sorted_vals, q):
    if not sorted_vals:
        return None
    i = min(len(sorted_vals) - 1, max(0, int(round(q * len(sorted_vals) + 0.5)) - 1))
    return sorted_vals[i]


def summarize_lat(vals):
    vals = sorted(vals)
    return {"n": len(vals), "p50_ns": percentile(vals, 0.50), "p95_ns": percentile(vals, 0.95),
            "p99_ns": percentile(vals, 0.99)}


def load_latency(run_dir: Path, ev):
    """probe_lat.1.log 가 있으면 구간별로, 없으면 fio 요약값만."""
    out = {}
    log = run_dir / "probe_lat.1.log"
    if log.exists() and ev["measure"][0] is not None:
        m0, m1 = ev["measure"][0], ev["measure"][1] or float("inf")
        trims = sorted(ev["trim"])
        starts = [a for a, _ in trims]
        allv, inv, outv = [], [], []
        with open(log) as f:
            for line in f:
                parts = line.split(",")
                if len(parts) < 2:
                    continue
                t = int(parts[0]) * 1_000_000      # log_unix_epoch: ms → ns
                if not (m0 <= t <= m1):
                    continue
                lat = int(parts[1])
                allv.append(lat)
                i = bisect.bisect_right(starts, t) - 1
                (inv if i >= 0 and t <= trims[i][1] else outv).append(lat)
        out["measure"] = summarize_lat(allv)
        out["during_trim"] = summarize_lat(inv)
        out["outside_trim"] = summarize_lat(outv)
        return out
    fj = run_dir / "fio_probe.json"
    if fj.exists():
        try:
            read = json.load(open(fj))["jobs"][0]["read"]
            pct = (read.get("clat_ns") or read.get("lat_ns") or {}).get("percentile", {})
            out["whole_run"] = {"n": read.get("total_ios"), "p50_ns": pct.get("50.000000"),
                                "p95_ns": pct.get("95.000000"), "p99_ns": pct.get("99.000000")}
        except (KeyError, IndexError, json.JSONDecodeError):
            pass
    return out


# ---------- FEMU 이벤트 로그 ----------

def load_ftl_log(path: Path, lba_bytes: int):
    gc, discards = [], []
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            rec = (int(row["lba"]) * lba_bytes, int(row["length_bytes"]), int(row["tick_ns"]))
            (gc if int(row["type"]) == 0 else discards).append(rec)
    return gc, discards


def overlaps(a_start, a_len, b_start, b_len):
    return max(a_start, b_start) < min(a_start + a_len, b_start + b_len)


def compute_dead_copy(ev, gc, discards, window):
    """삭제된 범위마다 '삭제됐지만 SSD는 모르는' 구간 [unlink, 끝)을 구하고 그 안의 GC 복사를 센다."""
    m0, m1 = window
    spans = []   # (start, length, t_from, t_to)
    for start, length, t_del in ev["deleted"]:
        ends = [t for (s, l, t) in discards if t >= t_del and overlaps(start, length, s, l)]
        ends += [t for (s, l, t) in ev["created"] if t > t_del and overlaps(start, length, s, l)]
        spans.append((start, length, t_del, min(ends) if ends else float("inf")))
    spans.sort()
    starts = [s[0] for s in spans]
    max_len = max((s[1] for s in spans), default=0)

    total = dead = dead_n = 0
    for g_start, g_len, g_t in gc:
        if not (m0 <= g_t <= m1):
            continue
        total += g_len
        lo = bisect.bisect_left(starts, g_start - max_len)
        hi = bisect.bisect_right(starts, g_start + g_len)
        for start, length, t_from, t_to in spans[lo:hi]:
            if t_from <= g_t < t_to and overlaps(g_start, g_len, start, length):
                dead += g_len
                dead_n += 1
                break
    return {"gc_copy_bytes": total, "dead_copy_bytes": dead, "dead_copy_count": dead_n,
            "dead_copy_ratio": (dead / total) if total else 0.0}


# ---------- 실행 유효성 ----------

def verdict(policy, dsm_cmd, rebooted):
    if rebooted:
        return "INVALID: 측정 중 보드가 재부팅됨"
    if dsm_cmd is None:
        return "unchecked"
    if policy == "nodiscard" and dsm_cmd != 0:
        return f"INVALID: No Discard인데 discard 명령 {dsm_cmd}개가 도달함"
    if policy != "nodiscard" and dsm_cmd == 0:
        return "INVALID: discard 명령이 한 번도 도달하지 않음"
    return "valid"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_dir", type=Path)
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--ftl-lba-bytes", type=int, default=512,
                    help="FEMU 로그의 lba 한 단위의 바이트 수 (기본 512)")
    args = ap.parse_args()

    run_dir = args.run_dir
    events_csv = run_dir / "host_events.csv"
    if not events_csv.exists():
        sys.exit(f"[ERROR] {events_csv} 없음")
    manifest = json.load(open(run_dir / "manifest.json")) if (run_dir / "manifest.json").exists() else {}
    policy = {"none": "nodiscard", "fstrim": "batch"}.get(manifest.get("policy"), manifest.get("policy"))

    ev = load_host_events(events_csv)
    summary = {
        "run_id": manifest.get("run_id", run_dir.name),
        "workload": manifest.get("workload"),
        "policy": policy,
        "rep": manifest.get("rep"),
        "split_k": manifest.get("split_k") if policy == "split" else None,
        "trim_every": manifest.get("trim_every"),
        "host_write_bytes": ev["host_write_bytes"],
        "trim_count": len(ev["trim"]),
        "trim_seconds": sum(b - a for a, b in ev["trim"]) / 1e9,
        "source": "host-only",
        "gc_copy_bytes": None, "waf": None, "verdict": "unchecked",
    }

    expstat = run_dir / "expstat_summary.json"
    ftl_log = run_dir / "ftl_gc_log.csv"
    if expstat.exists():
        x = json.load(open(expstat))
        summary.update({
            "source": "cosmos-expstat",
            "host_write_bytes": x.get("host_wr_B"),       # 장치가 받은 쓰기(파일시스템 메타데이터 포함)
            "host_file_bytes": ev["host_write_bytes"],
            "gc_copy_bytes": x.get("gc_copy_B"),
            "gc_count": x.get("gc_scheduled"),
            "erase_count": x.get("erase_issued"),
            "waf": x.get("device_waf"),
            "dsm_cmd": x.get("dsm_cmd"), "dsm_range": x.get("dsm_range"),
            "dsm_req_bytes": x.get("dsm_req_B"), "dsm_invalid_bytes": x.get("dsm_inval_B"),
            "dsm_busy_bytes": x.get("dsm_busy_B"), "dsm_ignored_bytes": x.get("dsm_ignored_B"),
            "dsm_gc_busy_cmds": x.get("dsm_gc_busy_cmds"), "dsm_errors": x.get("dsm_errors"),
            "dsm_already_free_bytes": x.get("dsm_already_free_B"),
            "dsm_ms_total": x.get("dsm_ms_total"), "dsm_ms_mean": x.get("dsm_ms_mean"),
            "dsm_ms_p99_upper": x.get("dsm_ms_p99_upper"),
            "verdict": verdict(policy, x.get("dsm_cmd"), x.get("rebooted")),
        })
    elif ftl_log.exists():
        gc, discards = load_ftl_log(ftl_log, args.ftl_lba_bytes)
        window = (ev["measure"][0] or 0, ev["measure"][1] or float("inf"))
        summary.update(compute_dead_copy(ev, gc, discards, window))
        n_disc = sum(1 for d in discards if window[0] <= d[2] <= window[1])
        host = ev["host_write_bytes"]
        summary.update({
            "source": "femu-log",
            "waf": ((host + summary["gc_copy_bytes"]) / host) if host else None,
            "dsm_range": n_disc,
            "dsm_req_bytes": sum(d[1] for d in discards if window[0] <= d[2] <= window[1]),
            "verdict": verdict(policy, n_disc, False),
        })
    else:
        print("[WARN] expstat_summary.json 도 ftl_gc_log.csv 도 없어 GC 지표는 비워 둡니다.", file=sys.stderr)

    summary["latency_ns"] = load_latency(run_dir, ev)

    out_path = args.out or (run_dir / "summary.json")
    with open(out_path, "w") as f:
        json.dump(summary, f, indent=2, ensure_ascii=False)
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    print(f"\n[OK] {out_path} 에 저장됨")


if __name__ == "__main__":
    main()
