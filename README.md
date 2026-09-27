# AXI4 Master/Slave

## Описание

Реализация подмножества протокола AMBA AXI4 на SystemVerilog. Предназначена для интеграции в RISC-V конвейер в качестве интерфейса памяти. Проект включает master, slave, интерфейс, пакет с типами и вспомогательный макрос для вычисления адресов при burst-транзакциях.

## Структура проекта

```
.
├── build
│   └── sim                  # директория для сборки симулятора
├── headers
│   ├── addr_next_macro.svh  # макрос ADDR_NEXT_FUNC для вычисления следующего адреса
│   ├── axi4_if.svh          # интерфейс AXI4 с modport'ами master и slave
│   └── axi4_pkg.svh         # пакет с типами resp_t и burst_t
├── Makefile                 # сборка, линт и запуск симуляции через Verilator
├── src
│   ├── axi4_master.sv       # мастер AXI4 с поддержкой outstanding транзакций
│   ├── axi4_slave.sv        # слейв AXI4 с байтовой памятью
│   └── top_module.sv        # top-level модуль, соединяющий master и slave
└── tb
    └── tb_top.sv            # тестбенч (в предоставленных файлах отсутствует)
```

## Компоненты

### axi4_if
Параметризованный интерфейс AXI4 (ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, USER_WIDTH). Содержит все сигналы каналов AW, W, B, AR, R. Определены два modport: master и slave.

### axi4_pkg
Пакет axi4_pkg с типами:
- resp_t: OKAY, EXOKAY, SLVERR, DECERR.
- burst_t: FIXED, INCR, WRAP.

### addr_next_macro
Макрос ADDR_NEXT_FUNC(WIDTH) создаёт функцию addr_next, которая по текущему адресу, размеру beat'а, длине burst'а и типу burst'а возвращает следующий адрес. Поддерживаются FIXED, INCR, WRAP.

### axi4_master
Параметры: ADDR_WIDTH, DATA_WIDTH, ID_WIDTH, MAX_OUTSTANDING. MAX_OUTSTANDING должен быть степенью двойки.

Чтение:
- Очередь запросов read_req_q и массив pending read_pending для отслеживания активных чтений.
- Поддерживает множественные outstanding чтения.
- Выдаёт ARVALID, ARADDR, ARLEN, ARSIZE, ARBURST, ARID.
- Принимает RVALID, RDATA, RRESP, RLAST, RID.
- Сопоставляет ответы по RID с помощью find_read_by_id.
- Формирует read_done, read_data_out, read_resp_out, read_rid_out.
- При RLAST деактивирует соответствующий pending-слот.

Запись:
- Очередь запросов write_req_q и FIFO данных wdata_fifo (по одному слову DATA_WIDTH на запрос).
- Поддерживает множественные outstanding записи.
- Выдаёт AWVALID, AWADDR, AWLEN, AWSIZE, AWBURST, AWID.
- Выдаёт WVALID, WDATA, WSTRB, WLAST.
- Принимает BVALID, BRESP, BID.
- Формирует write_done, write_id_out, write_resp_out.
- Ответы записи обрабатываются в порядке выдачи AW (b_ptr и aw_head).

### axi4_slave
Параметры: MEM_SIZE, ADDR_WIDTH, DATA_WIDTH, ID_WIDTH. MEM_SIZE должен быть степенью двойки.

Память:
- Байтовый массив mem [0:MEM_SIZE-1].
- Адресация с маской (addr & (MEM_SIZE-1)).

Чтение:
- Конечный автомат: READ_IDLE -> READ_DATA.
- Принимает AR, фиксирует ARADDR, ARSIZE, ARLEN, ARBURST, ARID.
- Выдаёт RVALID, RDATA, RRESP, RLAST, RID.
- Читает из памяти по байтам, собирает слово в соответствии с offset и size.
- Поддерживает burst-чтение (FIXED, INCR, WRAP).
- Может принять новый AR в цикле завершения предыдущего чтения (back-to-back), но не имеет очереди для множественных outstanding чтений.

Запись:
- Конечный автомат: WRITE_IDLE -> WRITE_DATA -> WRITE_RESP.
- Принимает AW, фиксирует AWADDR, AWSIZE, AWLEN, AWBURST, AWID.
- В WRITE_DATA принимает WVALID, WDATA, WSTRB, WLAST и пишет в память по байтам согласно WSTRB.
- В WRITE_RESP выдаёт BVALID, BRESP, BID и ждёт BREADY.
- Поддерживает burst-запись.
- Не имеет очереди для множественных outstanding записей.

Ошибки:
- RRESP и BRESP устанавливаются в SLVERR, если размер burst'а превышает DATA_WIDTH_BYTES.
- В остальных случаях OKAY.

### top_module
Инстанциирует axi4_if, axi4_master и axi4_slave. Выведены порты для управления чтением и записью: start_read, read_id, read_addr, read_len, read_size, read_burst, start_write, write_id, write_addr, write_len, write_size, write_burst, write_data, а также выходы read_rid_out, read_resp_out, read_data_out, read_done, write_id_out, write_resp_out, write_done.

## Особенности реализации

- Поддержка burst-транзакций типов FIXED, INCR, WRAP.
- Поддержка outstanding транзакций на стороне мастера (чтение и запись).
- Использование ID для сопоставления ответов чтения.
- Простой слейв с байтовой памятью, не поддерживающий конвейеризацию.
- Все сигналы AXI4, кроме необходимых, игнорируются: AWQOS, AWREGION, AWCACHE, AWPROT, AWLOCK, AWUSER, ARQOS, ARREGION, ARCACHE, ARPROT, ARLOCK, ARUSER, WUSER, BUSER, RUSER.

## Что не реализовано / ограничения

- Нет поддержки exclusive access (AWLOCK/ARLOCK игнорируются).
- Нет поддержки QoS, Region, Cache, Protect, User сигналов.
- Нет проверки выравнивания адреса. Предполагается, что мастер выдаёт выровненные адреса.
- MEM_SIZE должен быть степенью двойки.
- MAX_OUTSTANDING должен быть степенью двойки.
- Нет обработки ошибок протокола, таймаутов, нет механизмов восстановления.

## Сборка и запуск

Используется Verilator и Makefile.

- make lint — проверка синтаксиса.
- make build/sim — сборка симулятора.
- make run — запуск симуляции.
- make sim — очистка, сборка и запуск.
- make clean — удаление артефактов сборки и VCD-файла.
