# 계측·Deallocate 펌웨어 검증과 측정

대상: Cosmos+ OpenSSD GreedyFTL (`src`). 펌웨어는 팀이 보드에서 다듬은 버전(`DSM_IMPL_VERSION 3`, UART `schema=2`)을 **그대로** 쓴다. 이 문서의 도구들은 `src`를 바꾸지 않고, 펌웨어가 UART로 내보내는 카운터를 읽는다.

PC에서 한 것은 문법 검사, 처리 로직 시험, 보드 동작을 흉내 낸 모형으로 스크립트를 돌려 본 것까지다. 보드에서 이 도구들을 돌린 적은 아직 없다.

## 1. 구성

| 위치 | 내용 |
| --- | --- |
| `src/` | 펌웨어 (팀 버전 그대로). Deallocate 처리, 카운터, 10초마다 UART 출력 |
| `quickstart.sh` | 보드 점검을 단계별로 실행 |
| `tests/host/` | PC에서 돌리는 로직 시험 (`make test`, `make syntax`) |
| `tools/uart_capture.py` | UART 출력을 받은 시각과 함께 파일로 저장 |
| `tools/parse_expstat.py` | UART 로그의 EXPSTAT 줄 해석, 두 시점의 차이, `fw_verify.sh` 결과 판정 |
| `tools/fw_verify.sh` | 보드 검증 T0~T5 |
| `tools/split_trim.sh` | Split Batch용 fstrim 분할 |
| `tools/discard_check.sh` | discard 뒤 쓰기 성능이 회복되는지 확인(장치 전체를 채우므로 오래 걸림) |
| `ssd_discard_experiment/` | 4가지 방식 측정 실행기(W1~W3)와 분석 스크립트. 자체 README 참고 |

## 2. 카운터를 읽는 방법

펌웨어(`src/exp_stat.c`)는 10초마다 누적 카운터를 UART로 한 줄씩 내보낸다.

```
EXPSTAT,tag=PERIOD,schema=2,...,epoch=0,seq=12,tick=...,cps=...,host_wr_B=...,gc_copy_B=...,...
```

호스트는 이 값을 직접 읽을 방법이 없으므로 다음처럼 맞춘다.

1. UART가 연결된 PC에서 `uart_capture.py`로 받는다. 줄마다 받은 시각(epoch ns)이 붙는다.
2. 실험 스크립트는 카운터를 끊어 볼 시점마다 `sync` 후 13초 동안 아무것도 하지 않고, 그 시각을 기록한다.
3. 분석할 때 각 쉬는 구간 안에 찍힌 `PERIOD` 줄을 그 시점의 값으로 쓴다.

그래서 두 PC의 시계가 맞아 있어야 한다. 양쪽에서 `timedatectl`을 실행해 `System clock synchronized: yes`인지 본다. 허용 오차는 기본 1초(`--skew`)다.

UART를 받는 프로그램은 하나만 열어 둔다. SDK 터미널과 `uart_capture.py`가 같은 포트를 동시에 읽으면 줄이 나뉘어 양쪽 모두 일부만 받는다.

## 3. 빌드

`src`는 저장소 그대로 SDK에서 빌드한다. 빌드 전에 리눅스 PC에서 먼저 확인할 수 있다.

```bash
cd tests/host
make test      # Deallocate 처리와 카운터 시험(13가지 경우), 펌웨어 UART 줄을 파서가 읽는지 확인
make syntax    # 실험 때문에 손댄 펌웨어 파일 문법 검사
```

## 4. 보드 검증

```bash
# UART가 연결된 PC
sudo python3 tools/uart_capture.py /dev/ttyUSB<번호> ~/uart.log

# 실험 호스트
sudo ./quickstart.sh                  # 단계별 안내 (권장)
# 또는 검증만:
sudo DEV=/dev/nvme1n1 EXPECTED_SERIAL=<시리얼> tools/fw_verify.sh
```

`fw_verify.sh`는 데이터 내용 검사(경계 slice 내용, discard하지 않은 범위 보존, 다시 쓴 내용, 동시 실행 중 CRC)를 바로 판정하고, 카운터 기대값은 `expect.csv`에 적어 둔다. 끝난 뒤 UART 로그로 카운터를 판정한다.

```bash
python3 tools/parse_expstat.py --check <fw_verify 결과 폴더> <uart.log>
```

UART를 실험 호스트에서 받고 있다면 `UART_LOG=~/uart.log`를 주면 끝에서 바로 판정한다. 카운터 시점이 15개라 기다리는 시간만 약 3분 더 걸린다.

| 단계 | 확인하는 것 | 통과 기준 |
| --- | --- | --- |
| T0 | 시리얼, 마운트 여부, DSM 지원 표시 | ONCS에 DSM 비트, `DISC-MAX` ≠ 0 |
| T1 | 쓰기 카운터 | 256MiB 쓰기 → `host_wr_B` = 268435456, `dsm_cmd` = 0 |
| T2 | 기본 동작 | 64MiB discard → `dsm_inval_B` = 64MiB. 재요청 시 `dsm_already_free_B` = 64MiB. 방금 쓴 1MiB는 `dsm_ignored_B`로 잡히고, buffer를 비운 뒤에는 무효화됨 |
| T3 | slice 경계 | 한 LBA 어긋난 1MiB → 63 slice만 무효화, 16KB 무시. 양쪽 slice 내용 그대로 |
| T4 | 데이터 보존 | discard하지 않은 범위 내용 유지, discard한 범위에 다시 쓴 내용 일치 |
| T5 | 동시 실행 | fio 쓰기·CRC 검증 중 다른 범위에 쓰기·discard 반복. 검증 오류 0, `dsm_nest_err` 0 |

## 5. 측정

측정은 `ssd_discard_experiment/scripts`에서 한다. 자세한 사용법은 그 폴더의 README에 있다.

```bash
cd ssd_discard_experiment/scripts
export EXPECTED_SERIAL=<시리얼> MNT=/mnt/ssd-test EXPSTAT=1
sudo -E ./run_all.sh poc                     # W1 × 4정책 × 1회
sudo -E ./run_all.sh main                    # W1 × 4정책 × 5회
sudo -E ./run_all.sh ksweep                  # Split Batch 조각 수 K = 1, 4, 8, 16
```

UART 로그를 다른 PC에서 받았다면, 측정이 끝난 뒤 그 파일을 각 실행 폴더에 `uart.log`로 복사하고 분석을 다시 돌린다.

```bash
for d in ../runs/*/; do cp ~/uart.log "$d/uart.log"; python3 ../analysis/correlate_and_compute.py "$d"; done
python3 ../analysis/aggregate_and_plot.py ../runs --out-dir ../report
```

### 카운터의 뜻

| 이름 | 뜻 |
| --- | --- |
| `host_wr_B`, `host_wr_cmd` | 호스트 쓰기 명령이 요청한 바이트, 명령 수 |
| `gc_copy_B` | GC가 옮기기로 한 유효 slice의 바이트. 복사 요청을 낸 시점에 센다 |
| `gc_scheduled` | 복사·erase 요청을 모두 낸 victim 블록 수 |
| `erase_issued` | NAND 드라이버에 넘긴 erase 요청 수. `erase_cnt`(완료 기준)는 이 빌드에서 세지 않는다 |
| `prog_host_B`, `prog_gc_B`, `prog_meta_B` | 원인별 NAND program 바이트. 합을 `host_wr_B`로 나눈 값이 장치 WAF |
| `dsm_cmd`, `dsm_range`, `dsm_req_B` | 받은 DSM 명령 수, range 수, 요청 바이트 |
| `dsm_inval_B` | 유효하던 slice를 새로 무효화한 바이트 |
| `dsm_already_free_B` | 이미 매핑이 없던 slice |
| `dsm_ignored_B` | 적용하지 않은 바이트. slice 일부만 걸친 LBA, dirty buffer slice, GC 진행 중이라 건너뛴 명령 |
| `dsm_ticks`, `dsm_ticks_max` | DSM 처리 시간 합계와 부팅 후 최댓값 |

정상 완료된 명령에 대해서는 `dsm_req_B = dsm_inval_B + dsm_already_free_B + dsm_ignored_B`가 성립한다.

## 6. 알고 써야 할 점

- **카운터 해상도는 10초다.** 구간은 쉬는 시점 단위로만 자를 수 있고, 명령 하나하나의 처리 시간 분포는 얻을 수 없다(합계와 최댓값만).
- **UART 출력 때마다 펌웨어가 약 40ms 멈춘다.** 읽기 지연 p99에 섞일 수 있어, 분석 결과에 그 앞뒤 0.25초 표본을 뺀 p99(`without_uart_stall`)를 따로 낸다.
- **GC가 진행 중일 때 온 DSM 명령은 적용되지 않는다.** `dsm_ignored_B`에 합쳐져 나오고, UART 줄에는 따로 구분되지 않는다. GC가 활발한 구간에서 discard 효과가 줄어 보일 수 있다.
- **원본 펌웨어에는 discard를 보내지 않는다.** `nvme dsm` 같은 passthrough 명령은 커널을 거치지 않고 보드에 도달한다. `blkdiscard`와 스크립트들은 장치가 지원을 표시하지 않으면 보내지 않는다.
- **보드를 재부팅하면 데이터와 카운터가 모두 지워진다.** 매핑이 DRAM에만 있고 부팅 때 전체 erase를 한다. 분석은 재부팅이 끼면 그 실행을 버린다.
- **마지막에 쓴 2MB는 discard되지 않을 수 있다.** data buffer(128 엔트리)에 dirty로 남은 slice는 건너뛴다.
- **4KB 임의 쓰기는 WAF가 부풀려진다.** 16KB slice 단위로 program하기 때문이다. 본 실험의 주 지표는 `gc_copy_B`다.
- **펌웨어가 UART에 내보내는 항목 이름을 바꾸면** `tools/parse_expstat.py`의 `REQUIRED`도 같이 고친다. `make test`가 실제 펌웨어 출력으로 이를 검사한다.
