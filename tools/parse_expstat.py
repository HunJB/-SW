#!/usr/bin/env python3
"""
펌웨어 카운터 스냅샷(벤더 명령 0xC2)을 읽어 두 시점 사이의 차이를 계산한다.

사용법
  parse_expstat.py --bin start.bin end.bin          # 구간 차이, WAF, DSM 처리 시간 분포
  parse_expstat.py --bin start.bin end.bin --json   # 같은 내용을 JSON 한 줄로 (스크립트용)
  parse_expstat.py --show snap.bin                  # 스냅샷 하나의 누적값
  parse_expstat.py uart.log [--from N --to M]       # UART 로그의 EXPSTAT 줄을 CSV로

필드 순서는 src/exp_stat.h 의 exp_stat_t, src/nvme/dsm_deallocate.h 의 DSM_STATS 와 같아야 한다.
tests/host 의 make test 가 이를 검사한다. UART 로그(EXPSTAT,tag=... 줄)도 읽을 수 있다.
"""
import argparse
import csv
import json
import struct
import sys

MAGIC = 0x3354415453505845  # "EXPSTAT3"
HIST_TICKS_NR = 40
HIST_LBA_NR = 32
SLICE_BYTES = 16384

# src/exp_stat.h 의 exp_stat_t 순서. 이름은 UART 출력(EXPSTAT 줄)과 같게 맞췄다.
EXP_FIELDS = [
    "host_wr_B", "host_wr_cmd", "gc_copy_B", "gc_scheduled", "gc_victim_valid_B",
    "erase_issued", "erase_cnt", "erase_fail",
    "dsm_cmd", "dsm_range", "dsm_req_B", "dsm_inval_B", "dsm_ignored_B", "dsm_already_free_B",
    "dsm_ticks", "dsm_ticks_max",
    "prog_host_B", "prog_gc_B", "prog_meta_B",
    "dsm_nest_err", "epoch", "seq",
] + [f"hist_ticks_{i}" for i in range(HIST_TICKS_NR)] + [f"hist_lba_{i}" for i in range(HIST_LBA_NR)]

# src/nvme/dsm_deallocate.h 의 DSM_STATS 순서
DSM_FIELDS = [
    "dsm_s_cmd", "dsm_s_range", "dsm_s_merged_range", "dsm_s_req_B",
    "dsm_s_inval_slices", "dsm_s_inval_B", "dsm_s_unmapped_slices", "dsm_s_ignored_B",
    "dsm_busy_slices", "dsm_clean_evict_slices", "dsm_gc_busy_cmds",
    "dsm_bad_nsid_cmds", "dsm_oor_ranges", "dsm_errors", "dsm_s_ticks",
]
FIELDS = EXP_FIELDS + DSM_FIELDS
SCALAR_FIELDS = [f for f in FIELDS if not f.startswith("hist_")]
# 차이를 내지 않는 항목
NOT_CUMULATIVE = ("seq", "epoch", "dsm_ticks_max", "cps")


def read_bin(path):
    data = open(path, "rb").read()
    if len(data) < 32:
        sys.exit(f"{path}: 크기가 너무 작습니다 ({len(data)} 바이트)")
    magic, tick, cps, n = struct.unpack("<4Q", data[:32])
    if magic != MAGIC:
        sys.exit(f"{path}: EXPSTAT3 스냅샷이 아닙니다 (magic=0x{magic:x}). "
                 "펌웨어가 0xC2 명령을 처리하지 않거나 다른 버전입니다.")
    if n != len(EXP_FIELDS):
        sys.exit(f"{path}: exp_stat 필드 수가 다릅니다 (펌웨어 {n}, 스크립트 {len(EXP_FIELDS)}). "
                 "src/exp_stat.h 와 tools/parse_expstat.py 를 같은 버전으로 맞추세요.")
    off = 32
    vals = struct.unpack(f"<{n}Q", data[off:off + n * 8])
    off += n * 8
    (nd,) = struct.unpack("<Q", data[off:off + 8])
    off += 8
    if nd != len(DSM_FIELDS):
        sys.exit(f"{path}: DSM 통계 필드 수가 다릅니다 (펌웨어 {nd}, 스크립트 {len(DSM_FIELDS)}).")
    dvals = struct.unpack(f"<{nd}Q", data[off:off + nd * 8])
    row = {"tick": tick, "cps": cps}
    row.update(dict(zip(EXP_FIELDS, vals)))
    row.update(dict(zip(DSM_FIELDS, dvals)))
    return row


def hist_percentile(hist, q):
    """log2 구간 분포에서 분위수가 속한 구간의 번호. 표본이 없으면 None."""
    total = sum(hist)
    if total == 0:
        return None
    need, acc = q * total, 0
    for i, c in enumerate(hist):
        acc += c
        if acc >= need:
            return i
    return len(hist) - 1


def diff(ra, rb):
    d = {}
    for k in rb:
        if k in NOT_CUMULATIVE:
            continue
        try:
            d[k] = int(rb[k]) - int(ra[k])
        except (KeyError, ValueError):
            pass
    return d


def summarize(ra, rb):
    """두 스냅샷의 차이와 거기서 계산한 값을 dict 로 돌려준다."""
    cps = int(rb["cps"])
    d = diff(ra, rb)
    out = {k: v for k, v in d.items() if not k.startswith("hist_")}
    out["seconds"] = d["tick"] / cps
    out["rebooted"] = any(v < 0 for v in d.values()) or int(ra.get("epoch", 0)) != int(rb.get("epoch", 0))
    out["dsm_busy_B"] = d.get("dsm_busy_slices", 0) * SLICE_BYTES
    out["dsm_ticks_max_abs"] = int(rb.get("dsm_ticks_max", 0))

    host = d.get("host_wr_B", 0)
    if host > 0:
        out["gc_copy_ratio"] = d.get("gc_copy_B", 0) / host
        prog = d.get("prog_host_B", 0) + d.get("prog_gc_B", 0) + d.get("prog_meta_B", 0)
        out["device_waf"] = prog / host
    if d.get("dsm_cmd", 0) > 0:
        out["dsm_ms_total"] = d["dsm_ticks"] / cps * 1000
        out["dsm_ms_mean"] = out["dsm_ms_total"] / d["dsm_cmd"]

    ht = [d.get(f"hist_ticks_{i}", 0) for i in range(HIST_TICKS_NR)]
    hl = [d.get(f"hist_lba_{i}", 0) for i in range(HIST_LBA_NR)]
    out["hist_ticks"], out["hist_lba"] = ht, hl
    for name, q in (("p50", 0.50), ("p99", 0.99)):
        b = hist_percentile(ht, q)
        if b is not None:
            # 구간 b 는 [2^b, 2^(b+1)) tick 이므로 상한을 적는다
            out[f"dsm_ms_{name}_upper"] = (2 ** (b + 1)) / cps * 1000
    return out


def fmt_size(lbas):
    b = lbas * 4096
    for unit, div in (("GiB", 1 << 30), ("MiB", 1 << 20), ("KiB", 1 << 10)):
        if b >= div:
            return f"{b / div:g}{unit}"
    return f"{b}B"


def report(ra, rb):
    s = summarize(ra, rb)
    cps = int(rb["cps"])
    if s["rebooted"]:
        print("주의: 값이 줄었거나 epoch가 바뀌었습니다. 두 시점 사이에 보드가 재부팅됐거나 리셋 명령이 있었습니다.")
    print(f"구간 길이: {s['seconds']:.1f} 초")
    for k in SCALAR_FIELDS:
        if k in s:
            print(f"  {k:22s} {s[k]}")
    print(f"  {'dsm_busy_B':22s} {s['dsm_busy_B']}  (dirty buffer 때문에 건너뛴 양, dsm_ignored_B 에 포함)")
    if s.get("dsm_gc_busy_cmds"):
        print(f"주의: GC 복사가 진행 중이라 통째로 적용되지 않은 DSM 명령 {s['dsm_gc_busy_cmds']}개")
    if "gc_copy_ratio" in s:
        print(f"GC 복사 비율  gc_copy/host   = {s['gc_copy_ratio']:.3f}")
        print(f"장치 WAF      program/host   = {s['device_waf']:.3f}")
    if "dsm_ms_total" in s:
        print(f"DSM 처리 시간 합계 {s['dsm_ms_total']:.2f} ms, 명령당 평균 {s['dsm_ms_mean']:.3f} ms")
        print(f"  명령당 시간 p50 <= {s['dsm_ms_p50_upper']:.3f} ms, p99 <= {s['dsm_ms_p99_upper']:.3f} ms "
              "(2배 간격 구간의 상한)")
        print("  명령당 처리 시간 분포")
        for i, c in enumerate(s["hist_ticks"]):
            if c:
                print(f"    {2 ** i / cps * 1000:10.3f} ~ {2 ** (i + 1) / cps * 1000:10.3f} ms : {c}")
        print("  명령당 요청 크기 분포")
        for i, c in enumerate(s["hist_lba"]):
            if c:
                print(f"    {fmt_size(2 ** i):>8s} ~ {fmt_size(2 ** (i + 1)):>8s} : {c}")


def parse_uart(path):
    rows = []
    with open(path, errors="ignore") as f:
        for line in f:
            i = line.find("EXPSTAT,")
            if i < 0:
                continue
            row = {}
            for kv in line[i + len("EXPSTAT,"):].strip().split(","):
                if "=" in kv:
                    k, v = kv.split("=", 1)
                    row[k] = v
            if "seq" in row:
                rows.append(row)
    return rows


def selftest(a, b):
    """tests/host 가 만든 스냅샷 두 개로 필드 순서를 확인한다.
    각 구역의 i번째 필드는 1000+i, 두 번째 파일에서는 7*(i+1) 만큼 크다."""
    ra, rb = read_bin(a), read_bin(b)
    bad = []
    for names in (EXP_FIELDS, DSM_FIELDS):
        for i, k in enumerate(names):
            if int(ra[k]) != 1000 + i or int(rb[k]) - int(ra[k]) != 7 * (i + 1):
                bad.append(k)
    if bad:
        sys.exit(f"필드 순서 불일치: {bad[:5]}")
    print(f"parse_expstat.py: exp_stat {len(EXP_FIELDS)}개, DSM {len(DSM_FIELDS)}개 필드 순서 일치")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log", nargs="?")
    ap.add_argument("--bin", nargs=2, metavar=("START", "END"))
    ap.add_argument("--show", metavar="SNAP")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--selftest", nargs=2, metavar=("A", "B"), help=argparse.SUPPRESS)
    ap.add_argument("--out", default="expstat.csv")
    ap.add_argument("--from", dest="a", type=int)
    ap.add_argument("--to", dest="b", type=int)
    args = ap.parse_args()

    if args.selftest:
        selftest(*args.selftest)
        return
    if args.show:
        r = read_bin(args.show)
        if args.json:
            print(json.dumps(r))
        else:
            print(f"부팅 후 {r['tick'] / r['cps']:.1f} 초")
            for k in SCALAR_FIELDS:
                print(f"  {k:22s} {r[k]}")
        return
    if args.bin:
        ra, rb = read_bin(args.bin[0]), read_bin(args.bin[1])
        if args.json:
            print(json.dumps(summarize(ra, rb)))
        else:
            report(ra, rb)
        return
    if not args.log:
        ap.error("UART 로그 파일, --bin, --show 중 하나를 지정하세요")

    rows = parse_uart(args.log)
    if not rows:
        sys.exit("EXPSTAT 줄을 찾지 못했습니다.")
    keys = list(rows[-1].keys())
    with open(args.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    print(f"{len(rows)}줄 -> {args.out}")

    if args.a is None or args.b is None:
        return
    by_seq = {int(r["seq"]): r for r in rows}
    if any(args.a < int(r["seq"]) <= args.b and r.get("tag") == "BOOT" for r in rows):
        print("주의: 두 시점 사이에 재부팅(BOOT)이 있어 차이가 의미 없을 수 있습니다.")
    ra, rb = by_seq[args.a], by_seq[args.b]
    cps = int(rb["cps"])
    d = diff(ra, rb)
    print(f"구간 길이: {d['tick'] / cps:.1f} 초")
    for k, v in d.items():
        if k != "tick":
            print(f"  {k:22s} {v}")


if __name__ == "__main__":
    main()
