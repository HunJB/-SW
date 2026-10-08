# discard 방식별 GC 영향 실험 — 실행 코드

"대량 삭제 워크로드에서 ext4 discard 전달 방식이 SSD 내부 GC와 호스트 지연에 미치는 영향" 실험을 실행하고 정리하는 코드다. Cosmos+ OpenSSD 보드(주 실험)와 FEMU(보조 실험)에서 같은 스크립트를 쓴다.

비교하는 정책은 네 가지다.

| 이름 | 동작 |
| --- | --- |
| `nodiscard` (`none`) | discard를 보내지 않음 |
| `immediate` | `mount -o discard`. 삭제할 때마다 전달 |
| `batch` (`fstrim`) | `TRIM_EVERY` cycle마다 `fstrim` 한 번 |
| `split` | 같은 시점에 `fstrim`을 K조각으로 나눠 조각 사이에 쉼 |

## 구성

```
ssd_discard_experiment/
├── scripts/
│   ├── common.sh                 공통 함수: 장치 확인, 이벤트 기록, TRIM, 카운터 스냅샷
│   ├── apply_discard_policy.sh   포맷하고 정책에 맞게 마운트
│   ├── run_experiment.sh         한 조합(워크로드 × 정책) 1회 실행
│   ├── run_all.sh                여러 조합 반복 실행 (poc / main / ksweep / ctrl)
│   └── workloads/
│       ├── w1_retention_delete.sh   보존 기간 만료형 삭제 (주 워크로드)
│       ├── w2_checkpoint_rotate.sh  체크포인트 순환
│       └── w3_random_overwrite.sh   삭제 없는 대조군
├── analysis/
│   ├── correlate_and_compute.py  실행 하나를 summary.json 으로 정리
│   └── aggregate_and_plot.py     여러 실행을 정책별 표와 그래프로
└── femu_patch/                   FEMU FTL에 넣을 이벤트 기록 코드(템플릿)
```

저장소의 다른 폴더와의 관계:

- `src/` — Cosmos+ 펌웨어. Deallocate 처리와 카운터(`exp_stat`)가 들어 있다.
- `tools/uart_capture.py` — 펌웨어가 UART로 내보내는 카운터를 받은 시각과 함께 저장한다.
- `tools/parse_expstat.py` — 그 UART 로그 해석. 분석 스크립트가 불러 쓴다.
- `tools/split_trim.sh` — `split` 정책이 호출한다.
- `tools/fw_verify.sh` — 실험 전에 펌웨어가 정상인지 확인한다. 통과한 뒤에 이 폴더의 스크립트를 쓴다.

## 실행

모든 스크립트는 root로 실행한다. 장치는 시리얼로 지정한다. 보드를 재부팅하면 `/dev/nvme0n1`과 `/dev/nvme1n1`이 바뀔 수 있기 때문이다.

```bash
# (UART가 연결된 PC) 실험 내내 UART 로그를 받아 둔다. SDK 터미널 등 같은 포트를 연 프로그램은 닫는다.
sudo python3 tools/uart_capture.py /dev/ttyUSB<번호> ~/uart.log

# (실험 호스트)
sudo nvme list            # OpenSSD의 시리얼 확인
cd ssd_discard_experiment/scripts
export EXPECTED_SERIAL=<시리얼> MNT=/mnt/ssd-test EXPSTAT=1
# UART를 이 PC에서 받고 있으면 UART_LOG=~/uart.log 도 export 한다

sudo -E ./run_experiment.sh w1 batch 5 1   # W1, 5 cycle마다 fstrim, 1회차
sudo -E ./run_all.sh poc                   # W1 × 4정책 × 1회
sudo -E ./run_all.sh main                  # W1 × 4정책 × 5회 (REPS로 조정)
sudo -E ./run_all.sh ksweep                # split의 K = 1, 4, 8, 16
sudo -E ./run_all.sh ctrl                  # W3 × 4정책 (대조군)

python3 ../analysis/aggregate_and_plot.py ../runs --out-dir ../report
```

- `EXPSTAT=1`은 계측 펌웨어를 올린 Cosmos+ 보드에서 쓴다. 측정 시작·끝과 cycle 끝마다 13초(`CP_WAIT`)씩 쉬면서 그 사이에 찍힌 UART `PERIOD` 줄을 기준점으로 삼는다. 보드에 명령을 따로 보내지는 않는다.
- UART 로그를 다른 PC에서 받았다면, 실험이 끝난 뒤 그 파일을 각 실행 폴더에 `uart.log`로 복사하고 `python3 ../analysis/correlate_and_compute.py <실행 폴더>`를 다시 돌린다. 여러 실행을 한 파일로 받아도 된다. 두 PC의 시계가 맞아 있어야 한다(`timedatectl`).
- FEMU에서는 `EXPSTAT`을 빼고, 시리얼이 없으면 `DEV=/dev/nvme0n1`처럼 장치를 직접 준다(이때는 포맷 전에 확인을 묻는다). 실행 뒤 FEMU 로그를 실행 폴더에 복사해 분석을 다시 돌린다(`femu_patch/README_PATCH.md`).
- `run_all.sh`는 실행마다 멈춰서 보드를 재부팅할 시간을 준다. Cosmos+는 재부팅하면 FTL이 빈 상태로 돌아가므로 모든 실행이 같은 상태에서 시작한다.

### 크기는 장치 용량에 맞춰 정해진다

장치가 충분히 차지 않으면 GC가 일어나지 않아 정책 간 차이가 나오지 않는다. 그래서 `run_experiment.sh`는 마운트한 뒤 용량을 읽어 크기를 정한다(`AUTO_SIZE=1`, 기본).

- 목표 사용률 `U`(기본 0.85)까지 사전 쓰기로 채운 뒤 측정을 시작한다.
- cycle마다 용량의 `DEL_FRAC`(기본 0.10)만큼 지우고 같은 양을 새로 쓴다.
- `NUM_CYCLES`(기본 20)면 측정 구간에 용량의 약 2배를 쓴다.

직접 정하려면 `AUTO_SIZE=0`과 함께 워크로드 스크립트의 환경변수를 준다.

## 결과 (`runs/<run_id>/`)

| 파일 | 내용 |
| --- | --- |
| `manifest.json` | 설정값, 장치 시리얼, 마운트 옵션, 커널·fio 버전 |
| `host_events.csv` | 파일 생성·삭제·TRIM·cycle 시각과 파일이 차지한 장치 범위 |
| `uart.log` | 펌웨어 UART 출력 (복사해 넣은 것) |
| `expstat_summary.json` | 측정 구간의 카운터 차이, WAF, DSM 처리 시간 |
| `cycles.csv` | cycle별 카운터 차이 (GC 복사량, 무효화량 등의 시간 흐름) |
| `fio_probe.json`, `probe_lat.1.log` | 배경 읽기 probe의 지연 |
| `fstrim_output.log` | fstrim이 보고한 TRIM 양 |
| `summary.json` | 위를 모은 한 실행의 요약. `verdict`가 `valid`가 아니면 그 실행은 버린다 |

`host_events.csv`의 `start_lba`는 장치 기준 4KB 블록 번호, `length_bytes`는 바이트다.

## 주의

- 스크립트는 대상 장치를 포맷한다. `/`나 `/boot`가 올라가 있는 디스크는 거부하지만, 시리얼을 직접 확인하고 실행한다.
- 결과는 저장소 안의 `runs/`에 쌓인다(git에는 올리지 않음). 실험 장치의 마운트 지점 아래에 두지 않는다.
- 펌웨어는 UART 한 줄을 내보내는 동안(약 40ms) 멈춘다. 10초마다 일어나므로 읽기 지연에 섞일 수 있어, `summary.json`의 `latency_ns.without_uart_stall`에 그 앞뒤 0.25초 표본을 뺀 값을 따로 둔다.
- 삭제된 데이터의 복사량(`dead_copy_*`)은 FEMU 이벤트 로그가 있을 때만 계산된다. 보드는 합계 카운터만 남기므로 보드 실험의 주 지표는 GC 복사량과 nodiscard 대비 감소율이다.
- 정책 간 TRIM 총량이 같다고 가정하지 않는다. `summary.json`의 `dsm_req_bytes`, `dsm_invalid_bytes`로 실제 전달량을 함께 본다.
