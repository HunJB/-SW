# ftl_instrumentation.c 적용 가이드

FEMU 소스 전체를 알 수 없는 상태에서 작성한 **템플릿**입니다. 실제 적용은 아래 순서로 하세요.

## 1. 적용 대상 파일 찾기

FEMU 저장소(https://github.com/MoatLab/FEMU)에서 쓰는 FTL에 따라 파일 위치가 다릅니다.

```bash
# FEMU 소스 루트에서
grep -rn "clean_one_block\|do_gc\|gc_write" --include="*.c" .
grep -rn "nvme_dsm\|deallocate\|NVME_DSM" --include="*.c" .
```

- 첫 번째 grep 결과 중 "victim block을 골라서 valid page를 옮기는" 함수가 GC 삽입 지점
- 두 번째 grep 결과 중 "DSM 명령을 파싱해서 L2P를 해제하는" 함수가 discard 삽입 지점

## 2. 삽입

1. `ftl_instrumentation.c`의 상단 타입/버퍼/함수 정의부를 FTL 소스 상단 또는 별도 헤더(`ftl_instrumentation.h`)로 분리해 include
2. **TODO 1** 위치 — GC 함수 안, 페이지 복사가 "완료"되는 지점에 `io_log_push(EVT_GC_COPY, ...)` 호출 삽입
3. **TODO 2** 위치 — DSM/Deallocate 처리 함수 안, 매핑 해제가 "완료"되는 지점에 `io_log_push(EVT_DISCARD_ARRIVE, ...)` 호출 삽입
4. **TODO 3** — FEMU 종료 시점에 `io_log_flush_to_csv()` 호출 연결

## 3. 역방향 매핑(LBA 조회) 관련 주의

GC 복사 지점에서는 **물리 주소(PPA)만 들고 있고 LBA를 모르는 경우**가 많습니다. FTL이 P2L(physical-to-logical) 역방향 매핑을 유지하고 있는지 확인하세요.

- 유지하고 있다면: 그 테이블에서 조회
- 유지하지 않는다면: GC 복사 직전에 "이 페이지가 어떤 LBA의 데이터인지"를 한 번 역산하는 로직을 추가해야 함 (대부분의 page-mapping FTL은 OOB(spare area)에 LBA를 같이 저장해두므로, 그 값을 읽으면 됨)

## 4. 빌드 전 확인

```bash
cd femu-build-dir  # FEMU 빌드 스크립트가 있는 디렉토리
make clean
make -j$(nproc)
```

컴파일 경고(특히 배열 범위, 형 변환, 포인터 관련)는 무시하지 마세요 — 첫 번째 실험 계획서 PDF에서도 강조된 부분입니다.

## 5. 동작 확인 (작은 스모크 테스트)

```bash
# 게스트 부팅 후
sudo mkfs.ext4 -F /dev/vdb -E nodiscard
sudo mount -o discard /dev/vdb /mnt/test
echo "hello" > /mnt/test/a.txt
rm /mnt/test/a.txt
sync
sudo umount /mnt/test
# FEMU 종료 후 /tmp/femu_ftl_log.csv 가 생성되고,
# type=1(EVT_DISCARD_ARRIVE) 행이 적어도 1개 이상 있는지 확인
```

이 스모크 테스트에서 discard 이벤트가 안 잡히면, FEMU가 애초에 DSM을 처리하지 않는 버전일 수 있습니다 (연구 PDF 8장에서 이미 예상한 상황). 그 경우 `nvme_dsm()` 자체에 Deallocate 처리 로직을 새로 추가해야 합니다.
