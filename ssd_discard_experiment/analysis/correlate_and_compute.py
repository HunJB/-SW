#!/usr/bin/env python3
"""
correlate_and_compute.py

하나의 run_dir(예: runs/w1_fstrim_fstrim5_rep1_20261006_120000/) 안의
  - host_events.csv   (파일 생성/삭제 시각, filefrag LBA, fstrim 시각)
  - ftl_gc_log.csv     (GC 복사 이벤트: tick_ns,type,lba,length_bytes,src_ppa,dst_ppa)
  - fio_probe.json      (배경 읽기 probe의 지연 분포)
를 읽어서 다음을 계산한다:
  - 죽은 데이터 복사량 (삭제 시각 이후, discard 도착 이전에 GC가 옮긴 페이지 수)
  - WAF = (host_write_bytes + gc_copy_bytes) / host_write_bytes
  - 죽은 데이터 비율 = 죽은 데이터 복사량 / 전체 GC 복사량
  - 읽기 p50/p95/p99 지연 (fio_probe.json에서 추출)

사용법:
    python3 correlate_and_compute.py <run_dir> [--out summary.json]

ftl_gc_log.csv의 type 컬럼: 0=GC_COPY, 1=DISCARD_ARRIVE
  (femu_patch/ftl_instrumentation.c 의 io_log_event_type_t 와 동일한 규칙)

주의: Cosmos+ 보드에서 받은 teammate의 dsm_deallocate.c는 현재 '합계 카운터'
(dsmStats)만 남기고, 개별 slice의 무효화 시각을 로그로 남기지 않는다.
이 스크립트의 죽은 데이터 복사량 계산은 "슬라이스 단위 discard 도착 시각"이
필요하므로, Cosmos+ 경로로 돌릴 거라면 DsmInvalidateSlice()가
(lsa, timestamp)를 ftl_gc_log.csv와 같은 포맷으로 남기도록 팀원과 상의해서
보강이 필요하다. FEMU 경로(ftl_instrumentation.c)는 이미 이 포맷을 남기도록
되어 있으므로 바로 사용 가능하다.
"""

import argparse
import csv
import json
import sys
from pathlib import Path
from dataclasses import dataclass, field


@dataclass
class DeleteEvent:
    path: str
    delete_time_ns: int
    extents: list = field(default_factory=list)  # [(start_lba, length_bytes), ...]


@dataclass
class DiscardArrival:
    lba: int
    length_bytes: int
    time_ns: int


def load_host_events(path: Path):
    """host_events.csv를 읽어 파일별 unlink 시각 + 그 직전 extent 목록을 묶는다."""
    deletes_by_path = {}
    pending_extents = {}

    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            etype = row["event_type"]
            p = row["path"]
            t = int(row["event_time_ns"]) if row["event_time_ns"] else None

            if etype == "pre_delete_extent":
                pending_extents.setdefault(p, []).append(
                    (int(row["start_lba"]), int(row["length_bytes"] or 0))
                )
            elif etype == "unlink":
                ev = DeleteEvent(
                    path=p,
                    delete_time_ns=t,
                    extents=pending_extents.pop(p, []),
                )
                deletes_by_path.setdefault(p, []).append(ev)

    return deletes_by_path


def load_ftl_log(path: Path):
    gc_events = []       # (time_ns, lba, length_bytes)
    discard_events = []  # DiscardArrival

    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            t = int(row["tick_ns"])
            lba = int(row["lba"])
            length = int(row["length_bytes"])
            etype = int(row["type"])
            if etype == 0:  # GC_COPY
                gc_events.append((t, lba, length))
            elif etype == 1:  # DISCARD_ARRIVE
                discard_events.append(DiscardArrival(lba, length, t))

    return gc_events, discard_events


def ranges_overlap(a_start, a_len, b_start, b_len):
    a_end = a_start + a_len
    b_end = b_start + b_len
    return max(a_start, b_start) < min(a_end, b_end)


def find_discard_time_for_lba(lba, length, discard_events):
    """해당 LBA 범위를 덮는 discard 이벤트 중 가장 이른 시각을 반환. 없으면 None."""
    candidates = [
        d.time_ns for d in discard_events
        if ranges_overlap(lba, length, d.lba, d.length_bytes)
    ]
    return min(candidates) if candidates else None


def compute_dead_copy(deletes_by_path, gc_events, discard_events):
    """
    각 GC 복사 이벤트(lba, time)가:
      - 어떤 파일의 삭제된 extent와 겹치고
      - 그 삭제 시각 이후, discard 도착 이전에 일어났다면
    '죽은 데이터 복사'로 센다.
    """
    # 삭제된 모든 extent를 하나의 리스트로 펼침: (start_lba, length, delete_time_ns)
    deleted_extents = []
    for evs in deletes_by_path.values():
        for ev in evs:
            if ev.delete_time_ns is None:
                continue
            for (start_lba, length) in ev.extents:
                deleted_extents.append((start_lba, length, ev.delete_time_ns))

    dead_copy_count = 0
    dead_copy_bytes = 0
    total_gc_bytes = 0

    for (gc_time, gc_lba, gc_len) in gc_events:
        total_gc_bytes += gc_len

        for (d_start, d_len, delete_time) in deleted_extents:
            if not ranges_overlap(gc_lba, gc_len, d_start, d_len):
                continue
            if gc_time < delete_time:
                continue  # 삭제 이전에 일어난 복사는 해당 안 됨

            discard_time = find_discard_time_for_lba(d_start, d_len, discard_events)
            # discard가 아예 안 왔거나, GC 복사가 discard 도착보다 먼저였다면 "헛복사"
            if discard_time is None or gc_time < discard_time:
                dead_copy_count += 1
                dead_copy_bytes += gc_len
                break  # 이 GC 이벤트는 이미 헛복사로 집계했으니 다음 GC 이벤트로

    dead_ratio = (dead_copy_bytes / total_gc_bytes) if total_gc_bytes else 0.0
    return {
        "dead_copy_count": dead_copy_count,
        "dead_copy_bytes": dead_copy_bytes,
        "total_gc_bytes": total_gc_bytes,
        "dead_copy_ratio": dead_ratio,
    }


def compute_waf(manifest, gc_events, host_write_bytes_override=None):
    total_gc_bytes = sum(length for (_, _, length) in gc_events)
    # host_write_bytes는 host_events.csv의 file_create 이벤트 크기 합으로 추정하거나
    # fio 결과에서 가져올 수 있다. 여기서는 override 값이 있으면 그걸 우선 사용.
    host_write_bytes = host_write_bytes_override or 0
    if host_write_bytes == 0:
        return None
    waf = (host_write_bytes + total_gc_bytes) / host_write_bytes
    return waf


def load_fio_percentiles(fio_json_path: Path):
    if not fio_json_path.exists():
        return None
    with open(fio_json_path) as f:
        data = json.load(f)
    try:
        job = data["jobs"][0]
        clat_ns = job.get("read", {}).get("clat_ns", {})
        pct = clat_ns.get("percentile", {})
        return {
            "p50_ns": pct.get("50.000000"),
            "p95_ns": pct.get("95.000000"),
            "p99_ns": pct.get("99.000000"),
        }
    except (KeyError, IndexError):
        return None


def sum_host_write_bytes(host_events_csv: Path):
    total = 0
    with open(host_events_csv, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            if row["event_type"] == "file_create":
                size_str = row.get("length_bytes", "")
                if size_str.endswith("MiB"):
                    try:
                        total += int(float(size_str.replace("MiB", "")) * 1024 * 1024)
                    except ValueError:
                        pass
    return total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dir", type=Path)
    ap.add_argument("--out", type=Path, default=None)
    args = ap.parse_args()

    run_dir = args.run_dir
    host_events_csv = run_dir / "host_events.csv"
    ftl_log_csv = run_dir / "ftl_gc_log.csv"
    fio_probe_json = run_dir / "fio_probe.json"
    manifest_json = run_dir / "manifest.json"

    if not host_events_csv.exists():
        sys.exit(f"[ERROR] {host_events_csv} 없음")
    if not ftl_log_csv.exists():
        sys.exit(
            f"[ERROR] {ftl_log_csv} 없음. FEMU/Cosmos+에서 받은 GC 로그를 "
            f"이 경로로 복사해두세요 (README 참고)"
        )

    manifest = {}
    if manifest_json.exists():
        with open(manifest_json) as f:
            manifest = json.load(f)

    deletes_by_path = load_host_events(host_events_csv)
    gc_events, discard_events = load_ftl_log(ftl_log_csv)

    dead_copy_result = compute_dead_copy(deletes_by_path, gc_events, discard_events)

    host_write_bytes = sum_host_write_bytes(host_events_csv)
    waf = compute_waf(manifest, gc_events, host_write_bytes_override=host_write_bytes)

    latency = load_fio_percentiles(fio_probe_json)

    summary = {
        "run_id": manifest.get("run_id", run_dir.name),
        "workload": manifest.get("workload"),
        "policy": manifest.get("policy"),
        "rep": manifest.get("rep"),
        "host_write_bytes": host_write_bytes,
        "waf": waf,
        "latency_ns": latency,
        **dead_copy_result,
    }

    print(json.dumps(summary, indent=2, ensure_ascii=False))

    out_path = args.out or (run_dir / "summary.json")
    with open(out_path, "w") as f:
        json.dump(summary, f, indent=2, ensure_ascii=False)
    print(f"\n[OK] {out_path} 에 저장됨")


if __name__ == "__main__":
    main()
