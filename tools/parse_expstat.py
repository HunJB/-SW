#!/usr/bin/env python3
"""
펌웨어 UART 출력의 EXPSTAT 줄을 읽어 두 시점 사이의 카운터 차이를 계산한다.

펌웨어(src/exp_stat.c)는 10초마다 한 줄씩 누적 카운터를 UART로 내보낸다:
  EXPSTAT,tag=PERIOD,schema=2,...,epoch=0,seq=12,tick=...,cps=...,host_wr_B=...,...
tools/uart_capture.py 로 받으면 줄 앞에 받은 시각(epoch ns)과 탭이 붙는다.
이 시각이 있어야 호스트 쪽 이벤트 시각과 맞춰 구간을 자를 수 있다.

사용법
  parse_expstat.py uart.log                         # EXPSTAT 줄을 expstat.csv 로
  parse_expstat.py uart.log --from 12 --to 40       # seq 12 줄과 40 줄의 차이
  parse_expstat.py uart.log --window T0 T1 [--json] # 호스트 시각 T0, T1(epoch ns) 직후의 PERIOD 줄 차이
  parse_expstat.py --check RUN_DIR uart.log         # fw_verify.sh 결과 폴더의 기대값을 판정
"""
import argparse
import csv
import json
import os
import sys

# 펌웨어가 한 줄에 반드시 내보내야 하는 항목 (src/exp_stat.c 의 exp_stat_dump)
REQUIRED = [
    "epoch", "seq", "tick", "cps",
    "host_wr_B", "host_wr_cmd", "gc_copy_B", "gc_scheduled", "gc_victim_valid_B",
    "erase_issued", "erase_cnt", "erase_fail",
    "prog_host_B", "prog_gc_B", "prog_meta_B",
    "dsm_cmd", "dsm_range", "dsm_req_B", "dsm_inval_B", "dsm_ignored_B", "dsm_already_free_B",
    "dsm_ticks", "dsm_ticks_max", "dsm_nest_err",
]
# 차이를 내지 않는 항목
NOT_CUMULATIVE = ("seq", "epoch", "tick", "cps", "dsm_ticks_max", "host_ns")
REPORT_ORDER = [k for k in REQUIRED if k not in NOT_CUMULATIVE]

# 호스트 시각과 UART를 받은 PC 시각의 차이로 허용하는 범위(초).
# 두 PC가 NTP로 맞춰져 있으면 보통 수십 ms 안쪽이다.
DEFAULT_SKEW = 1.0


# ---------- 읽기 ----------

def parse_line(line):
    """한 줄을 dict 로. EXPSTAT 줄이 아니면 None."""
    host_ns = None
    if "\t" in line:
        head, line = line.split("\t", 1)
        if head.strip().isdigit():
            host_ns = int(head.strip())
    i = line.find("EXPSTAT,")
    if i < 0:
        return None
    row = {"host_ns": host_ns}
    for kv in line[i + len("EXPSTAT,"):].strip().split(","):
        if "=" not in kv:
            continue
        k, v = kv.split("=", 1)
        try:
            row[k] = int(v)
        except ValueError:
            row[k] = v
    if "seq" not in row:
        return None
    return row


def read_uart(path):
    rows = []
    with open(path, errors="ignore") as f:
        for line in f:
            r = parse_line(line.rstrip("\r\n"))
            if r is not None:
                rows.append(r)
    return rows


def check_fields(rows, path):
    if not rows:
        sys.exit(f"{path}: EXPSTAT 줄을 찾지 못했습니다.")
    missing = [k for k in REQUIRED if k not in rows[-1]]
    if missing:
        sys.exit(f"{path}: EXPSTAT 줄에 다음 항목이 없습니다: {missing}. 펌웨어 버전을 확인하세요.")


def pick_after(rows, t_ns, until_ns=None, skew=DEFAULT_SKEW):
    """호스트 시각 t_ns 뒤(시계 차이 skew 초 여유)에 받은 첫 PERIOD 줄.
    until_ns 가 있으면 그 전(역시 여유를 두고)에 받은 줄이어야 한다."""
    lo = t_ns + int(skew * 1e9)
    hi = None if until_ns is None else until_ns - int(skew * 1e9)
    for r in rows:
        if r.get("tag") != "PERIOD" or r["host_ns"] is None:
            continue
        if r["host_ns"] > lo and (hi is None or r["host_ns"] < hi):
            return r
    return None


def boot_between(rows, ra, rb):
    """두 줄 사이에 재부팅(BOOT 줄, seq 감소, epoch 변화)이 있었는가."""
    if rb["seq"] < ra["seq"] or rb.get("epoch") != ra.get("epoch"):
        return True
    for r in rows:
        if r.get("tag") == "BOOT" and ra["seq"] < r["seq"] <= rb["seq"]:
            return True
    return False


# ---------- 계산 ----------

def summarize(ra, rb, rows=None):
    d = {}
    for k in rb:
        if k in NOT_CUMULATIVE or k not in ra:
            continue
        if isinstance(rb[k], int) and isinstance(ra[k], int):
            d[k] = rb[k] - ra[k]
    cps = int(rb["cps"])
    out = dict(d)
    out["seconds"] = (int(rb["tick"]) - int(ra["tick"])) / cps
    out["seq_from"], out["seq_to"] = ra["seq"], rb["seq"]
    out["rebooted"] = (boot_between(rows, ra, rb) if rows else False) or any(v < 0 for v in d.values())
    out["dsm_ms_max_since_boot"] = int(rb.get("dsm_ticks_max", 0)) / cps * 1000
    host = d.get("host_wr_B", 0)
    if host > 0:
        out["gc_copy_ratio"] = d.get("gc_copy_B", 0) / host
        prog = d.get("prog_host_B", 0) + d.get("prog_gc_B", 0) + d.get("prog_meta_B", 0)
        out["device_waf"] = prog / host
    if d.get("dsm_cmd", 0) > 0:
        out["dsm_ms_total"] = d.get("dsm_ticks", 0) / cps * 1000
        out["dsm_ms_mean"] = out["dsm_ms_total"] / d["dsm_cmd"]
    return out


def report(s):
    if s["rebooted"]:
        print("주의: 두 줄 사이에 재부팅 또는 카운터 리셋이 있었습니다. 차이가 의미 없습니다.")
    print(f"구간: seq {s['seq_from']} → {s['seq_to']}, 보드 시간 {s['seconds']:.1f} 초")
    for k in REPORT_ORDER:
        if k in s:
            print(f"  {k:22s} {s[k]}")
    if "gc_copy_ratio" in s:
        print(f"GC 복사 비율  gc_copy/host   = {s['gc_copy_ratio']:.3f}")
        print(f"장치 WAF      program/host   = {s['device_waf']:.3f}")
    if "dsm_ms_total" in s:
        print(f"DSM 처리 시간 합계 {s['dsm_ms_total']:.2f} ms, 명령당 평균 {s['dsm_ms_mean']:.3f} ms, "
              f"부팅 후 최대 {s['dsm_ms_max_since_boot']:.3f} ms")


def window(rows, t0, t1, skew=DEFAULT_SKEW, t0_until=None, t1_until=None):
    ra = pick_after(rows, t0, t0_until, skew)
    rb = pick_after(rows, t1, t1_until, skew)
    if ra is None or rb is None:
        which = "시작" if ra is None else "끝"
        raise LookupError(f"{which} 시각 뒤의 PERIOD 줄을 찾지 못했습니다. "
                          "UART 로그가 그 시간을 포함하는지, 두 PC의 시계가 맞는지, "
                          "펌웨어 주기 출력(10초)이 켜져 있는지 확인하세요.")
    return summarize(ra, rb, rows)


# ---------- fw_verify.sh 결과 판정 ----------

def check_run(run_dir, log, skew):
    rows = read_uart(log)
    check_fields(rows, log)
    cps = {}
    with open(os.path.join(run_dir, "checkpoints.csv")) as f:
        for r in csv.DictReader(f):
            cps[r["name"]] = (int(r["epoch_ns"]), int(r["idle_until_ns"]))
    picked = {}
    for name, (t, until) in cps.items():
        picked[name] = pick_after(rows, t, until, skew)
    lines, fails = [], 0
    with open(os.path.join(run_dir, "expect.csv")) as f:
        for e in csv.DictReader(f):
            a, b = picked.get(e["from"]), picked.get(e["to"])
            if a is None or b is None:
                lines.append(f"FAIL  {e['label']}: 기준 시점({e['from'] if a is None else e['to']})의 PERIOD 줄 없음")
                fails += 1
                continue
            s = summarize(a, b, rows)
            got = s.get(e["field"])
            want = int(e["value"])
            ok = {"eq": got == want, "ge": got is not None and got >= want}[e["op"]]
            sign = "=" if e["op"] == "eq" else "≥"
            lines.append(f"{'ok  ' if ok else 'FAIL'}  {e['label']}: {e['field']} = {got} (기대 {sign} {want})")
            fails += 0 if ok else 1
            if s["rebooted"]:
                lines.append(f"FAIL  {e['label']}: 구간 안에 재부팅/리셋")
                fails += 1
    for name, r in picked.items():
        if r is None:
            lines.append(f"참고  시점 {name}: 대기 구간 안의 PERIOD 줄 없음")
    lines.append(f"\n카운터 판정: {'전체 통과' if fails == 0 else f'{fails}개 실패'}")
    out = "\n".join(lines)
    print(out)
    with open(os.path.join(run_dir, "counter_check.txt"), "w") as f:
        f.write(out + "\n")
    return fails


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log", nargs="?")
    ap.add_argument("--out", default="expstat.csv")
    ap.add_argument("--from", dest="a", type=int)
    ap.add_argument("--to", dest="b", type=int)
    ap.add_argument("--window", nargs=2, type=int, metavar=("T0_NS", "T1_NS"))
    ap.add_argument("--skew", type=float, default=DEFAULT_SKEW, help="허용하는 두 PC의 시계 차이(초)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--check", nargs=2, metavar=("RUN_DIR", "UART_LOG"))
    ap.add_argument("--selftest", metavar="LOG", help=argparse.SUPPRESS)
    args = ap.parse_args()

    if args.check:
        sys.exit(1 if check_run(args.check[0], args.check[1], args.skew) else 0)
    if args.selftest:
        rows = read_uart(args.selftest)
        check_fields(rows, args.selftest)
        print(f"parse_expstat.py: 펌웨어 UART 줄에서 {len(REQUIRED)}개 항목 확인")
        return
    if not args.log:
        ap.error("UART 로그 파일 또는 --check 를 지정하세요")

    rows = read_uart(args.log)
    check_fields(rows, args.log)

    if args.window:
        try:
            s = window(rows, args.window[0], args.window[1], args.skew)
        except LookupError as e:
            sys.exit(str(e))
        if args.json:
            print(json.dumps(s))
        else:
            report(s)
        return
    if args.a is not None and args.b is not None:
        by_seq = {r["seq"]: r for r in rows}
        for q in (args.a, args.b):
            if q not in by_seq:
                sys.exit(f"seq {q} 인 줄이 없습니다 (로그의 seq 범위: {rows[0]['seq']}~{rows[-1]['seq']})")
        s = summarize(by_seq[args.a], by_seq[args.b], rows)
        if args.json:
            print(json.dumps(s))
        else:
            report(s)
        return

    keys = list(rows[-1].keys())
    with open(args.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    timed = sum(1 for r in rows if r["host_ns"] is not None)
    print(f"{len(rows)}줄 -> {args.out} (받은 시각이 붙은 줄 {timed}개)")


if __name__ == "__main__":
    main()
