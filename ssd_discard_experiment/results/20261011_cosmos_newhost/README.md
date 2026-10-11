# Cosmos+ OpenSSD discard 정책 실험 (2026-10-11~12, 새 호스트)

## 조건
- 보드: Cosmos+ OpenSSD GreedyFTL (팀 펌웨어, victim 진단 카운터 포함), 시리얼 SSDD515T, 논리 용량 15.43 GB, LBA 4 KiB
- 호스트: Ubuntu, ext4 (`mkfs -E nodiscard -m 0`), 실행마다 FTL 초기화(X) 후 시작
- 공통: 목표 사용률 U=0.85, cycle마다 용량의 10% 삭제 후 같은 양 쓰기, 20 cycle, 배경 4 KiB 랜덤 읽기 200 IOPS
- batch/split: 기본 5 cycle마다 TRIM (`T=1`은 매 cycle)
- W1: 16 MiB 파일 묶음(세대) 단위로 가장 오래된 세대를 지우고 새 세대를 씀
- W4: 4 MiB 파일 중 무작위 10%를 지우고 같은 양을 새로 씀 (정책 간 같은 시드)
- 정책별 1회 측정

## 파일
- `policy_comparison_7runs.csv`: `aggregate_and_plot.py` 출력 (W1 4개, W4 nodiscard·batch T=5·immediate). 측정 구간(사전 쓰기 제외) 기준
- `uart/`: 보드 UART 로그(Windows 수집, 줄마다 받은 시각 ns). W1 immediate·split 로그는 호스트 쪽 실행 폴더에만 있음

## W1, 측정 구간 호스트 쓰기 29.94 GB
| | nodiscard | immediate | batch | split K=8 |
|---|---|---|---|---|
| GC 복사량 | 54.7 MB | 51.1 MB | 52.5 MB | 52.0 MB |
| 장치 WAF | 1.003 | 1.003 | 1.003 | 1.003 |
| GC victim / 유효 데이터 0 비율 | 6,072 / 45.0% | 6,072 / 48.6% | 6,072 / 47.2% | 6,072 / 47.7% |
| DSM 무효화량 | 0 | 29.86 GB | 14.45 GB | 14.45 GB |
| 펌웨어 DSM 처리 시간 합 | 0 | 1,287 ms | 641 ms | 641 ms |
| fstrim 소요 합 | - | - | 0.71 s | 28.8 s |
| 읽기 p99 (UART 출력 구간 제외) | 6.43 ms | 6.01 ms | 6.47 ms | 5.71 ms |
| 읽기 p99, TRIM 중 / 그 밖 | - | - | 11.71 / 6.54 ms | 4.65 / 5.76 ms |

## W4 (값은 UART 로그 전체 구간 기준. 측정 구간 값은 CSV 참고)
| | nodiscard | batch T=5 | batch T=1 | immediate |
|---|---|---|---|---|
| 호스트 쓰기 | 43.12 GB | 43.12 GB | 43.12 GB | 43.12 GB |
| GC 복사량 | 14.55 GB | 13.37 GB (-8%) | 6.57 GB (-55%) | 6.48 GB (-55%) |
| 장치 WAF | 1.339 | 1.311 | 1.154 | 1.151 |
| GC 시작 후(호스트 24 GB 이후) GC 복사 / 쓰기 | 0.639 | 0.595 | 0.282 | 0.284 |
| 유효 데이터 0인 victim | 1.6% | 3.0% | 12.7% | 13.4% |
| DSM 요청 / 무효화 | 0 | 10.8 / 8.0 GB | 40.7 / 29.9 GB | 31.2 / 29.8 GB |
| 펌웨어 DSM 처리 시간 합 | 0 | 400 ms | 1,490 ms | 1,329 ms |

측정 구간 기준 읽기 p99: W4 nodiscard 88.0 ms, batch T=5 88.0 ms, immediate 60.9 ms.

## 해석
- W1은 지운 자리를 ext4가 곧바로 다시 써서 덮어쓰기만으로 옛 데이터가 무효가 된다. discard 정책 간 GC 차이가 없고, 차이는 discard 전달 비용(처리 시간, TRIM 중 지연)에서만 났다.
- W4는 지운 자리가 흩어져 블록 안에 살아 있는 데이터와 지운 데이터가 섞인다. 지운 데이터를 GC 전에 알려 준 양(무효화량)에 따라 GC 복사가 줄었다. batch도 매 cycle 보내면 immediate와 같은 효과를 냈다.

## 측정상 유의점
- Windows 수집 창이 몇 차례 일시 정지했다. 줄은 보존되어 보드 tick으로 시각을 보정해 분석했다 (`correlate_and_compute.py`의 retime).
- W4 immediate(seq 82, 100, 118), W4 batch T=1(seq 69, 105), W4 batch T=5(seq 145), W1 batch(seq 81)에서 UART 줄이 빠졌다. 측정 구간 시작·끝 합계는 정상이고, cycle별 구간 일부가 합쳐졌다.
- W1 batch는 이전 호스트(팀원 측정)와 GC victim 수·DSM 수가 같고 GC 복사량 차이가 1.3%였다.
