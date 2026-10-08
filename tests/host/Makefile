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
# make syntax 대상: 실험 때문에 손댄 파일
CHANGED := exp_stat.c nvme/dsm_deallocate.c nvme/nvme_io_cmd.c nvme/nvme_admin_cmd.c \
           nvme/nvme_identify.c nvme/nvme_main.c garbage_collection.c request_schedule.c \
           data_buffer.c

.PHONY: test syntax clean

test: build/test_dsm
	./build/test_dsm build/uart.log
	python3 $(TOOLS)/parse_expstat.py --selftest build/uart.log
	python3 $(TOOLS)/parse_expstat.py build/uart.log --from 2 --to 3 --json > build/diff.json
	python3 -c 'import json; d = json.load(open("build/diff.json")); assert d["host_wr_B"] == 1234 and d["gc_copy_B"] == 56, d'

	@echo "PC 시험 통과"

build/test_dsm: test_dsm.c $(FW) $(SRC)/exp_stat.h $(SRC)/nvme/dsm_deallocate.h
	@mkdir -p build
	$(CC) $(CFLAGS) -o $@ test_dsm.c $(FW)

syntax:
	@for f in $(CHANGED); do \
		$(CC) $(CFLAGS) -w -fsyntax-only -include stdint.h -I$(SRC)/nvme $(SRC)/$$f || exit 1; \
		echo "ok  $$f"; \
	done

clean:
	rm -rf build
