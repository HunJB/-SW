# SSD Discard 방식별 GC 영향 실험 — 코드 모음

"대량 삭제 워크로드에서 discard 방식이 SSD 내부 GC에 미치는 영향" 연구용 실행 코드.

## 디렉토리 구조

```
ssd_discard_experiment/
├── femu_patch/                 # FEMU FTL에 끼워넣을 계측 코드 템플릿
│   ├── ftl_instrumentation.c   # GC copy / discard 도착 로깅 템플릿
│   └── README_PATCH.md         # 어디에 어떻게 붙일지 설명
├── scripts/
│   ├── workloads/
│   │   ├── w1_retention_delete.sh   # 시계열DB형 보존기간 만료 삭제 (주 워크로드)
│   │   ├── w2_checkpoint_rotate.sh  # 체크포인트 순환 삭제
│   │   └── w3_random_overwrite.sh   # 대조군 (삭제 없음, fio 랜덤 쓰기)
│   ├── apply_discard_policy.sh # mount/fstrim으로 discard 정책 적용
│   ├── record_deletion.sh      # filefrag로 삭제 직전 LBA 범위 기록
│   ├── run_experiment.sh       # 단일 조합(fs×workload×discard×util) 1회 실행
│   └── run_all.sh              # 전체 조합 반복 실행 (POC / 본실험)
└── analysis/
    ├── correlate_and_compute.py # 호스트 로그 + FTL 로그를 맞춰 지표 계산
    └── requirements.txt
```

## 실행 순서

1. **femu_patch/** 의 코드를 FEMU 소스(GC 함수, discard/Deallocate 처리 함수)에 삽입하고 빌드
2. `scripts/run_experiment.sh` 를 손으로 1~2회 돌려서 로그가 정상적으로 쌓이는지 확인 (PDF의 POC 단계)
3. 문제없으면 `scripts/run_all.sh` 로 전체 조합(또는 축소한 9회) 자동 실행
4. `analysis/correlate_and_compute.py` 로 죽은 데이터 복사량 / WAF / p99 지연 계산 및 CSV·그래프 출력

## 결과 파일 (runs/<run_id>/ 아래에 저장됨)

- `host_events.csv` — 파일 생성/삭제 시각, filefrag로 얻은 LBA 범위
- `ftl_gc_log.csv` — FEMU가 남긴 GC 복사 이벤트 (LBA, 시각)
- `ftl_discard_log.csv` — FEMU가 남긴 discard 도착 이벤트 (LBA, 시각)
- `fio_probe.json` — 배경 읽기 probe의 지연 분포 (p50/p95/p99)
- `manifest.json` — 이 실행의 모든 설정값 기록

## 주의

- 실험 대상 장치(DEV) 경로를 반드시 먼저 확인하세요. 스크립트가 실수로 OS 디스크를 포맷하지 않도록, 모든 스크립트는 `DEV` 환경변수를 명시적으로 요구하고 실행 전 확인 프롬프트를 띄웁니다.
- FEMU 빌드/커밋 버전에 따라 GC·discard 처리 함수 이름이 다를 수 있습니다 (PDF에서도 "함수명을 미리 확정하지 않는다"고 명시). `femu_patch/README_PATCH.md` 를 참고해 실제 소스에 맞게 삽입 위치를 찾으세요.
