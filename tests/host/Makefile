# PC에서 Deallocate 처리 로직과 카운터를 시험한다. 보드나 Xilinx SDK가 필요 없다.
#   make test     펌웨어 파일 두 개(dsm_deallocate.c, exp_stat.c)를 그대로 컴파일해 시험
#   make syntax   수정한 펌웨어 파일 전체의 문법 검사
#   make clean

SRC    := ../../src
TOOLS  := ../../tools
CC     ?= gcc
CFLAGS := -std=gnu99 -O1 -Wall -Wextra -Wno-int-to-pointer-cast -Wno-unused-parameter \
          -Istub -I$(SRC)
FW     := $(SRC)/nvme/dsm_deallocate.c $(SRC)/exp_stat.c
# make syntax 대상: 패치가 손댄 파일
CHANGED := exp_stat.c nvme/dsm_deallocate.c nvme/nvme_io_cmd.c nvme/nvme_admin_cmd.c \
           nvme/nvme_identify.c nvme/nvme_main.c garbage_collection.c address_translation.c \
           request_transform.c

.PHONY: test syntax clean

test: build/test_direct build/test_auto
	./build/test_direct build/before.bin build/after.bin
	./build/test_auto
	python3 $(TOOLS)/parse_expstat.py --selftest build/before.bin build/after.bin
	@echo "PC 시험 통과"

build/test_direct: test_dsm.c $(FW) $(SRC)/exp_stat.h $(SRC)/nvme/dsm_deallocate.h
	@mkdir -p build
	$(CC) $(CFLAGS) -o $@ test_dsm.c $(FW)

build/test_auto: test_dsm.c $(FW) $(SRC)/exp_stat.h $(SRC)/nvme/dsm_deallocate.h
	@mkdir -p build
	$(CC) $(CFLAGS) -DDSM_PAYLOAD_USE_AUTO_DMA=1 -o $@ test_dsm.c $(FW)

syntax:
	@for f in $(CHANGED); do \
		$(CC) $(CFLAGS) -w -fsyntax-only -I$(SRC)/nvme $(SRC)/$$f || exit 1; \
		echo "ok  $$f"; \
	done

clean:
	rm -rf build
