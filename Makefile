#====================================================================
# AXI Master/Slave testbench Makefile (Verilator)
#====================================================================

VERILATOR = verilator
COMMON_FLAGS = -Wall -Wno-fatal
BUILD_FLAGS  = --binary --build -j 0 --trace
LINT_FLAGS   = --lint-only

# Пути к папкам с исходниками
SRC_DIR = src
HEADERS_DIR = headers
TB_DIR = tb

# Директории для include
INCLUDE_DIRS = -I$(HEADERS_DIR) -I$(SRC_DIR)

# Все SV-файлы из src и tb (но .svh не включаем, они через include)
SOURCES = $(wildcard $(SRC_DIR)/*.sv) $(wildcard $(TB_DIR)/*.sv)

# Цель по умолчанию
.PHONY: all run lint clean sim

all: build/sim

# Сборка симулятора
build/sim: $(SOURCES)
	mkdir -p build
	$(VERILATOR) --top-module tb_top $(COMMON_FLAGS) $(BUILD_FLAGS) $(INCLUDE_DIRS) \
		-DVCD_FILE=\"sim.vcd\" \
		$(SOURCES)
	mv obj_dir/Vtb_top $@

# Запуск симуляции
run: build/sim
	./build/sim

# Линт (проверка синтаксиса)
lint:
	$(VERILATOR) $(LINT_FLAGS) --top-module tb_top $(COMMON_FLAGS) $(INCLUDE_DIRS) $(SOURCES)

# Очистка
clean:
	rm -rf build obj_dir
	rm -f sim.vcd

# Полная пересборка и запуск
sim: clean all run

.PHONY: sim clean
