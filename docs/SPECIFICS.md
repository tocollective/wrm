# Особенности WRM.081632 для ядра, runtime и драйверов

Этот документ объясняет, какие свойства WRM нужно учитывать при разработке
LA/IX и программ на M: что делает CPU, что обязан делать программный код и
какие ошибки приводят к потере контекста, нарушению изоляции или остановке
машины. Он охватывает ISA, ABI, загрузку, память, все устройства и средства
эмулятора. Полные таблицы опкодов и регистров остаются в исходных спецификациях.

Источники: [ISA](INSTRUCTIONS.md), [машина и устройства](SPECIFICATION.md),
[ABI](ABI.md), [эмулятор](../README.md). Особенности текущей реализации
сверены с [CPU](../source/cpu.c), [MMU](../source/mmu.c),
[шиной](../source/motherboard.c) и [драйверами устройств эмулятора](../source/devices/).
Расхождения спецификаций с реализацией исправляются в самих спецификациях;
границы текущей реализации и решения LA/IX собраны в
[разделе 13](#clarifications).

Чек-листы ниже — требования для разработки и проверки, а не отчёт о том,
что LA/IX уже всё реализовал. Статус этапов находится в
[плане микроядра](../laix/docs/KERNEL.md).

## Содержание

- [1. Архитектура, инструкции и адреса](#architecture)
- [2. ABI, стек, M и исполняемые файлы](#abi)
- [3. Reset, firmware и вход в ядро](#boot)
- [4. Trap, IRQ, EPC и возврат](#traps)
- [5. Низкие слова входа и TrapFrame](#entry)
- [6. MMU, права, ASID и TLB](#mmu)
- [7. Атомики, порядок памяти и изменение кода](#ordering)
- [8. Floating point и FCSR](#floating-point)
- [9. MMIO и DMA: общие правила](#io-dma)
- [10. Особенности каждого устройства](#devices)
- [11. Время, pipeline и производительность](#timing)
- [12. Диагностика, debugging и snapshots](#diagnostics)
- [13. Границы текущей реализации и решения LA/IX](#clarifications)
- [14. Сквозная проверка LA/IX](#acceptance)

<a id="architecture"></a>

## 1. Архитектура, инструкции и адреса

### Размеры и режимы

WRM — 32-битная little-endian машина. Указатель и слово занимают 4 байта.
CPU имеет 32 целочисленных регистра, `pc` и control registers. Только `r0`
аппаратно закреплён за нулём; роли остальных регистров задаёт ABI.
Запись результата в `r0` не сохраняет его, но сама инструкция всё равно
выполняется: load в `r0` может вызвать fault или прочитать MMIO с побочным эффектом.

Все инструкции занимают 4 байта и должны быть выровнены на 4. Переменной
длины инструкций и delay slots нет. Адреса данных для `LH/SH` выравниваются
на 2, для `LW/SW/LL/SC` — на 4. Неравненные обращения вызывают исключение;
для packed-структур нужны байтовые обращения или явная сборка значения.

`STATUS.UM` выбирает user/supervisor mode. `HLT`, `WFI`, `IRET`, `TLBI` и
обычный доступ к control registers требуют supervisor. Пользователь может
читать `CYCLE/CYCLEH/INSTRET/INSTRETH`, читать и писать `FCSR`.
При выключенной MMU user mode **не ограничивает доступ к физической памяти**:
для изоляции одновременно нужны `UM=1`, `PTBR.EN=1` и корректные таблицы.

`CPUID` сейчас равен `0x010000FF`: версия ISA 1 в битах 31–24, расширения
MMU, binary32, LL/SC, high multiply, дополнительные режимы TLBI, debug,
bit operations и FCSR — в битах 0–7. Ядро читает его в supervisor mode.
`HARTID=0`: текущая машина однопроцессорная. Обсуждение нескольких ядер в
ISA описывает будущую модель, а не действующий SMP.

### Кодирование и целочисленные операции

Опкод занимает младшие 8 бит. Форматы R/I/U/N различаются расположением
регистров и immediate. Зарезервированные поля инструкции должны быть
нулевыми; неправильное кодирование, неизвестный control register и запись
в read-only control register дают illegal instruction.
Правило относится и к неиспользуемым полям: например, `rs1` у `MFCR`,
`rd` у `MTCR/TLBI`, `rs2` у одновходовых R-инструкций.

Большинство `imm14` знаковые: диапазон −8192…8191. У `ANDI/ORI/XORI` и
immediate shift/rotate поле беззнаковое. Сдвиги и вращения используют только
младшие 5 бит счётчика: сдвиг на 32 действует как сдвиг на 0.
`SHR` логический, `SAR` арифметический. `LB/LH` расширяют знак,
`LBU/LHU` дополняют нулями. В `SW` поле `rd` обозначает источник записи.

Сложение, вычитание и умножение работают modulo 2³², без overflow trap.
`MULH/MULHU/MULHSU` различают знаковость при вычислении старшего слова.
`DIV/REM` знаковые, `DIVU/REMU` беззнаковые. При делении на ноль CPU
возвращает `0xFFFFFFFF`, остаток равен делимому; исключения нет.
Для `INT_MIN / -1` результат `INT_MIN`, остаток 0. Если язык требует
ошибку деления, её должен проверять compiler/runtime.

Есть `CLZ/CTZ/POPCNT`, `BSWAP`, sign extension, `ROL/ROR/RORI`, signed и
unsigned min/max. `CLZ(0)` и `CTZ(0)` равны 32. Отдельной `ROLI` нет:
для вращения влево на n используется вращение вправо на `(32-n) & 31`.
Полный перечень и точные имена — в [опкодах](INSTRUCTIONS.md#opcodes).

### Формирование адресов и переходы

`LUI` сдвигает immediate на **13**, а не на 12 или 16 бит:

```text
hi(x) = x >> 13
lo(x) = x & 0x1FFF
x = (hi(x) << 13) | lo(x)
```

Низкая часть неотрицательна и помещается в знаковый `imm14`, поэтому
`LUI` + `ORI` и `LUI` + `ADDI` не требуют коррекции high part.
`AUIPC` прибавляет к адресу самой инструкции. В `%pcrel_hi/%pcrel_lo`
вторая инструкция должна непосредственно следовать за `AUIPC` и быть
`ADDI`, load или store. `ORI` для этой пары неверен: в результате `AUIPC`
уже присутствуют низкие биты адреса `pc`.

Условный переход считает смещение от своего адреса: `imm14 << 2`,
диапазон около ±32 KiB. `JAL` имеет `imm19 << 2`, около ±1 MiB;
return address равен `pc+4`. `JALR` вычисляет `(rs1 + imm14) & ~3`:
младшие два бита отбрасываются, а не вызывают alignment fault.
Такой переход может скрыть ошибку испорченного function pointer.

Чек-лист:

- [ ] Проверять alignment инструкций, стека и данных в assembly/runtime.
- [ ] Не переносить на WRM разбиение констант и смещений другой ISA.
- [ ] Различать signed/unsigned load, compare, divide и high multiply.
- [ ] Явно проверять деление на ноль, если этого требует семантика языка.
- [ ] Запускать недоверенный код только с включённой MMU и user permissions.

<a id="abi"></a>

## 2. ABI, стек, M и исполняемые файлы

По [ABI](ABI.md) используется ILP32: `int`, `long`, pointer — 4 байта;
`long long`, `double`, `long double` — 8 байт и alignment 8. `float` —
binary32 в GPR, `double` — binary64 в software runtime. Поля структуры
имеют собственное выравнивание; размер структуры дополняется до кратности
максимальному alignment. C bit-fields заполняются от младшего бита вверх.

| Регистры | Соглашение ABI |
| --- | --- |
| `r1–r8` | Аргументы; `r1–r2` также результат |
| `r9` | Scratch, номер syscall, временный регистр linker veneer |
| `r10–r27` | Callee-saved |
| `r28/tp` | Thread pointer; обычная функция его не меняет |
| `r29/fp` | Frame pointer либо callee-saved |
| `r30/sp` | Stack pointer |
| `r31/ra` | Return address, caller-saved |

64-битный аргумент занимает два последовательных регистра, low word первым;
пара не обязана начинаться с чётного номера. Если аргумент целиком не
помещается в оставшиеся регистры, он и последующие аргументы идут на стек.
Struct/union до 8 байт передаются как одно/два слова, более крупные — через
указатель на копию. Для большого результата первым аргументом передаётся
скрытый указатель на result buffer.

Стек растёт вниз, на каждом вызове `sp` кратен 8. **Red zone нет**:
память ниже `sp` может занять interrupt handler. `ra` не сохраняется
аппаратно при обычном вызове. При наличии frame pointer `fp` равен входному
`sp`, сохранённые `ra` и `fp` находятся по `fp-4` и `fp-8`.
Без frame pointers проход по цепочке стековых кадров не гарантирован.
Для frame больше диапазона `imm14` нужен дополнительный адресный расчёт.

`r9` нельзя использовать для скрытого аргумента функции или ожидать, что
он доживёт до её первой инструкции: дальний `JAL` linker может направить
через veneer, который загружает target в `r9` и делает `JALR`.
Дальние условные ветвления linker не исправляет; compiler разворачивает
условие и использует jump. Global pointer register отсутствует.

### Два разных variadic ABI

C `...` всегда передаёт дополнительные аргументы на стеке с C promotions:
`char/short → int`, `float → double`. M `args: ...` передаёт borrowed pack
`{data: pointer, count: UWord}` размером 8 байт, alignment 4, как малый
aggregate после фиксированных аргументов. На стеке pack занимает
8-aligned slot и никогда не разделяется между регистрами и стеком.

В M каждый trailing scalar занимает одно 4-байтовое слово;
`Float` сохраняет binary32, `Bool` нормализуется к 0/1. Aggregates в
trailing arguments запрещены. Пустой pack — `{0, 0}`.
`vaArg(args, i, T)` не проверяет границы и тип и не преобразует число:
callee обязан знать формат и соблюдать `i < vaCount(args)`.
Pack можно переслать, но он заимствует память исходного caller и не может
пережить его вызов. M variadic-функция не совместима напрямую с C `...`.
Это особенно важно для `panic/debugPrint` и format string.

### TLS, ELF и старт процесса

Определён только local-exec TLS: `.tdata`, затем `.tbss`, отдельная копия
на поток, `tp` указывает на начало копии. Ядро сохраняет пользовательский
`tp` при trap; код ядра не должен считать его своим TLS автоматически.

Формат object/executable — ELF32 little-endian, private `EM_WRM=0x0816`,
`e_flags=0`; relocations в `SHT_RELA`, addend хранится явно. `%hi/%lo`,
`%pcrel*`, `%tprel*`, branch и JAL имеют собственные WRM relocation types.
Обычные ELF-инструменты могут читать заголовки, но поддержка чужой ISA
не означает поддержку WRM disassembly или relocation.

ELF loader использует `PT_LOAD`, сохраняет `p_vaddr ≡ p_offset mod 4096`,
применяет `PF_R/PF_W/PF_X` и обнуляет `p_memsz-p_filesz`.
`PT_TLS` описывает TLS. Разные права секций требуют отдельных страниц.
Flat boot image не является ELF и не несёт автоматического zero-fill BSS.
Dynamic linking, PIE, другие модели TLS и формат debug information пока
не определены ABI.

При старте user process ОС создаёт 8-aligned стек с `argc`, `argv`,
нулевым terminator, `envp`, terminator и auxv (type/value, конец type 0).
`ra/fp` и остальные GPR, включая `tp`, исходно 0. `crt0` создаёт TLS,
обнуляет BSS, если loader этого не сделал, вызывает `main` и `exit`.
Boot entry firmware имеет другой контракт, описанный далее.

Compiler может генерировать вызовы `memcpy/memmove/memset/memcmp`, функций
64-битной арифметики и software double даже в freestanding-коде.
Ядру нужны соответствующие runtime symbols и корректный ABI этих функций.

Чек-лист:

- [ ] Assembly↔M соблюдает register roles, hidden result и alignment 8.
- [ ] Trap сохраняет больше, чем callee-saved: весь прерванный контекст.
- [ ] Variadic printing использует pack ABI M и проверяет число аргументов.
- [ ] Pack и указатели на caller frame не остаются после возврата.
- [ ] Loader проверяет размеры, переполнение диапазонов, entry и права ELF.
- [ ] TLS и необходимые compiler runtime functions подготовлены до user start.

<a id="boot"></a>

## 3. Reset, firmware и вход в ядро

Аппаратный reset начинает исполнение с `pc=0xFE000000`, supervisor,
`STATUS=0x10` (`EXL=1`), MMU выключена, TLB и counters очищены.
Остальные регистры CPU исходно 0. Пока не установлен `IVEC` и не очищен
`EXL`, любой fault останавливает CPU: ранний старт должен быть безошибочным.

Reset сохраняет **RAM, VRAM и содержимое дисков**. Он останавливает DMA,
очищает FIFOs/IRQ masks, выключает таймер, звук, watchdog, сеть и display;
сбрасывает палитру и cursor, закрывает shared-folder handles. Время RTC
и последовательность RNG продолжаются. На power-on VRAM нулевая, однако
для BSS и свободной RAM нельзя рассчитывать на нули.

Firmware ищет boot image сначала на floppy, затем disk 0. Disk 1 не
является следующим кандидатом boot в текущей firmware. Без пригодного
образа открывается экранное меню; сообщения firmware не идут в UART.

Заголовок flat image: `MAGIC=0x424D5257` (`WRMB`), количество 512-байтовых
секторов, `ENTRY` — 4-aligned offset внутрь образа, `FLAGS=0`.
Firmware загружает весь образ вместе с заголовком в physical `0x10000`.
Нельзя адресовать его код так, будто header был удалён loader.

| При входе в boot image | Значение/свойство |
| --- | --- |
| `pc` | `0x10000 + ENTRY` |
| `r1` | Boot info по `0x1000` |
| `sp` | `0x10000`, пустой стек вниз |
| `r2`, `ra` | 0; прочие GPR не определены |
| `STATUS`, `IVEC`, `PTBR` | `0x10`, 0, 0 |
| PIC `ENABLE` | 0 |
| Boot disk | Idle, `DONE` clear |
| Video | Firmware console 640×480×8 bpp, display on, IRQ off |

Boot info содержит `INFO` magic `0x4F464E49`, `SIZE` (сейчас 40),
`RAM_SIZE`, boot controller, disk size, image address/size, clock frequency,
число и physical address device entries. Проверять `SIZE` до доступа к
полям; device table — пары `{ADDRESS, ID}` по 8 байт, заканчивается ниже
`0x2000`. Другие control registers на boot entry не определены.

Низкая память: `0…0xFFF` unspecified; `0x1000…0x1FFF` boot info/table;
`0x2000…0xFFFF` свободна, но там firmware stack. Ядро копирует нужные boot
данные, переходит на собственный стек, обнуляет свою BSS и резервирует
образ, BSS, stack, таблицы MMU и entry state до раздачи страниц.
Свободной страницей не является любая RAM-страница вне file image:
неинициализированные секции и стек тоже занимают RAM.

Firmware font расположен в VRAM по offset `0x3FF000`: 256 glyphs 8×16,
16 байт на glyph, bit 7 слева. Codes `0x20–0xFF` — Windows-1252,
низкие codes — symbols/box drawing. Это не UTF-8/Unicode font.
Переключение mode не очищает VRAM; собственная консоль должна явно
инициализировать экран, font/palette и состояние engine.

Чек-лист:

- [ ] Сохранить входной `r1` до вызовов, проверить boot info и диапазоны.
- [ ] Обнулить BSS даже после warm reset с грязной RAM.
- [ ] Установить собственный `sp`, entry state и `IVEC` до clear `EXL`.
- [ ] Зарезервировать все занятые physical pages, включая низкую память.
- [ ] Не включать IRQ до готовности handlers и device acknowledgement.

<a id="traps"></a>

## 4. Trap, IRQ, EPC и возврат

### Control registers и STATUS

| CR | Имя | Назначение |
| --- | --- | --- |
| 0 | STATUS | Mode, IRQ, exception level и step flags |
| 1, 2, 3 | EPC, IVEC, SCRATCH | Return PC, единый vector и software temporary |
| 4, 5, 6 | CAUSE, BADADDR, PTBR | Причина trap, дополнительные данные и MMU context |
| 7, 8 | CYCLE, CYCLEH | Low/high word счётчика cycles, read-only |
| 9, 10 | INSTRET, INSTRETH | Low/high retired count, read-only |
| 11 | CPUID | ISA version/extensions, read-only |
| 12, 13, 14, 15 | TADDR0, TCTRL0, TADDR1, TCTRL1 | Два debug triggers |
| 16 | HARTID | Номер core, сейчас 0, read-only |
| 17 | FCSR | FP flags/rounding mode |

Номера bits STATUS: `IE=0`, `PIE=1`, `UM=2`, `PUM=3`, `EXL=4`, `SS=5`,
`PSS=6`; остальные bits read-as-zero. Не путать bit number и mask:
например, `EXL` mask равна `1<<4`, то есть `0x10`.
`MFCR/MTCR/IRET` ждут завершения старых instructions; control write
вступает в силу для следующих instructions. Номера CR и TLBI mode
кодируются непосредственно в instruction; в M `mfcr/mtcr` требуют
constant expression, а не runtime index.

### Что CPU сохраняет, а что оставляет программе

При trap CPU записывает control state, но **не сохраняет GPR, не меняет
`sp`, не переключает `PTBR` и не создаёт аппаратный stack frame**.
Один `IVEC` обслуживает все причины. Вход:

```text
PIE = IE;   IE = 0
PUM = UM;   UM = 0
PSS = SS;   SS = 0
EXL = 1
CAUSE = причина
EPC = адрес согласно типу события
pc = IVEC
```

`PUM` сообщает происхождение trap; текущий `UM` на входе уже 0.
`PIE/PSS` — сохранённые значения, а не действующие IRQ/step flags.
`SCRATCH` — программный control register для временного сохранения,
а не автоматически заполненный указатель или swap-инструкция.

### Точное правило EPC

| CAUSE | Событие | EPC при входе | BADADDR | Действие перед возвратом |
| --- | --- | --- | --- | --- |
| 0 | IRQ | Следующая ещё не выполненная инструкция | Не изменяется | Оставить EPC |
| 1 | Illegal instruction | Ошибочная инструкция | Instruction word | Исправить/эмулировать либо завершить задачу |
| 2 | Misaligned fetch | Ошибочный PC | PC | Исправить target либо завершить задачу |
| 3, 4 | Misaligned load/store | Ошибочная инструкция | Data address | Эмулировать либо завершить задачу |
| 5, 6, 7 | Fetch/load/store bus error | Ошибочная инструкция | Fetch/data address | Разобрать неисправный physical доступ |
| 8, 9, 10 | Fetch/load/store page fault | Ошибочная инструкция | Virtual address | После исправления mapping повторить с тем же EPC |
| 11 | Privileged instruction из UM | Ошибочная инструкция | Instruction word | Обычно завершить задачу |
| 12 | SYSCALL | Сама SYSCALL | 0 | Для обычного завершённого syscall прибавить 4 |
| 13 | BREAK | Сама BREAK | 0 | При продолжении после breakpoint прибавить 4 |
| 14 | Single-step | Следующая инструкция | PC предыдущей | Оставить EPC |
| 15 | Debug trigger | Совпавшая инструкция | Match address | Убрать причину совпадения, затем повторить |

Для fault результат самой ошибочной инструкции не завершён; все более
старые инструкции завершены, более молодые не имеют архитектурных эффектов.
После исправления page fault `EPC += 4` пропустит требуемый load/store.
После IRQ такой же сдвиг потеряет следующую инструкцию. При `SYSCALL/BREAK`
без сдвига произойдёт повторный trap на той же инструкции.
`BADADDR` при IRQ может содержать значение от старого fault: его нельзя
печатать как адрес причины IRQ. При illegal/privileged это instruction word,
а не pointer, который можно разыменовать.

ABI syscall: номер в `r9`, не более 6 слов аргументов в `r1–r6`,
без stack arguments; результат `r1` либо `r1/r2`, ошибки `-4095…-1`.
Все остальные GPR должны сохраниться. Номера и смысл syscall выбирает ОС.
Блокирующий syscall должен возобновляться по согласованному kernel protocol,
а не случайно повторяться из-за несохранённого EPC.

### IE, EXL, nested faults и IRET

`IE` маскирует только IRQ. Исключения возможны при `IE=0` в обоих modes.
`EXL=1` блокирует IRQ и обработку нового fault: второй fault **останавливает
CPU**, без второго входа в `IVEC`. Это не отдельный exception vector,
не аппаратный emergency stack и не автоматический reset.
Первый сохранённый `EPC/CAUSE/BADADDR` остаётся состоянием первого trap;
вторую неисправную инструкцию надо искать в dump/pipeline эмулятора.

Если ядро хочет обрабатывать fault при `copy_from_user`, сначала нужны
полный frame, валидный kernel stack, сохранённые `EPC/STATUS/CAUSE/BADADDR`
и fault-fixup protocol, затем clear `EXL`. Оставить `IE=0` при этом можно.
Если требуются nested IRQ, после сохранения контекста дополнительно ставится
`IE=1`. Вложенность требует отдельных frames; общий temporary slot опасен.

`IRET` выполняет `pc=EPC`, `IE=PIE`, `UM=PUM`, `SS=PSS`, `EXL=0`.
Перед восстановлением EPC надо снова обеспечить `IE=0, EXL=1`;
пользовательские `UM` и `sp` не должны стать действующими посреди restore.
Запись `MTCR STATUS` с `UM=1` переключает mode уже для следующей инструкции;
для контролируемого входа в user mode обычно используется `IRET`.
IRQ может быть принят сразу после разрешающего `MTCR STATUS`.

### WFI и HLT

`WFI` ждёт **asserted CPU IRQ line**, даже если `IE=0` или `EXL=1`.
При `IE=1, EXL=0` CPU входит в handler с EPC после `WFI`;
иначе просто продолжает следующую инструкцию. PIC всё равно должен
разрешать хотя бы соответствующую линию: pending при `ENABLE=0` не будит.
Постоянно asserted IRQ может превратить idle в busy loop.

`HLT` останавливает машину до reset; это не idle instruction. После HLT
не идут ticks устройств, не работает watchdog и не завершается DMA.

Чек-лист:

- [ ] Выбирать retry/skip/next по CAUSE, не применять общий `EPC += 4`.
- [ ] Определять user origin по `PUM`, сохранять исходный `sp` и GPR.
- [ ] Не делать потенциально faulting access до готовности frame/nesting.
- [ ] Restore выполняется при `IE=0, UM=0, EXL=1`, затем единственный `IRET`.
- [ ] Idle использует `WFI`, panic stop — отдельную политику HLT/power off.

<a id="entry"></a>

## 5. Низкие слова входа и TrapFrame

### Зачем слова ниже 8 KiB

На первой инструкции trap нет свободного GPR: каждый содержит прерванное
значение. Пользовательскому `sp` доверять нельзя. Адрес `offset(r0)` в
диапазоне signed `imm14` позволяет обратиться к заранее известному слову
без загрузки адреса в temporary register. [ABI рекомендует](ABI.md#entering-the-kernel)
хранить текущий kernel stack pointer в таком низком слове.

В текущем LA/IX [defs.inc](../laix/src/arch/wrm081632/defs.inc) выделяет:

| Virtual address | Назначение LA/IX |
| --- | --- |
| `0x00001FF0` | `KERNEL_SP`: kernel stack текущей задачи |
| `0x00001FF4` | `KERNEL_STACK_BOTTOM` |
| `0x00001FF8` | `KERNEL_STACK_TOP` |
| `0x00001FFC` | `TRAP_SAVED_R1`: временное сохранение `r1` |

**Эти адреса выбирает LA/IX, аппаратно они не зарезервированы.**
Слова лежат в конце страницы boot info, поэтому boot info и таблица
устройств обязаны заканчиваться ниже `0x1FF0`; ядро это проверяет.
ОС обязана зарезервировать physical storage и установить mapping сама. Для каждой пользовательской
page directory низкие виртуальные слова должны вести к нужной kernel
странице с `U=0`; mapping должен существовать уже при входе в trap.
CPU не переключит directory за ядро.

Не стоит размещать эти слова в page zero. `U=0` закрыл бы её только для
пользователя: в ядре **разыменование NULL не дало бы fault**, а читало бы
или портило entry state. Вызов по NULL исполнил бы слово `0x00000000`, то
есть `HLT`, и headless-эмулятор вышел бы с кодом 0, как при успехе.
Поэтому LA/IX не отображает page zero ни в одном каталоге: NULL load, store
и call со смещением меньше 4 KiB дают page fault. До включения MMU эта
защита не действует. Запрещены пользовательские aliases physical page
со словами входа: иначе задача перезапишет stack pointer/границы через другой VA.
Supervisor-доступ тоже требует `R/W` по виду операции.
Следует защищать весь physical frame, а не только четыре адреса.

Entry path, stack, frame, handler code, необходимые tables и аварийный
output должны быть доступны в **каждом активном address space**. Для смены
`PTBR` новые таблицы заранее включают отображения текущего кода/стека;
частично готовый каталог даст fault при EXL и остановку CPU.

### Frame и пределы текущего entry

`TrapFrame` — программная структура ОС, не формат CPU. Текущий
[layout LA/IX](../laix/src/trap/trap_layout.inc): 32 GPR (128 байт),
`EPC/STATUS/CAUSE/BADADDR/FCSR/PTBR` (24 байта), два reserved words;
итого **160 байт**, кратно 8. `r30` в frame — прерванный stack pointer,
а не адрес frame. `r0` сохраняется явно как 0 для диагностики.

[trap.asm](../laix/src/trap/trap.asm) сначала сохраняет `sp` в `SCRATCH`,
проверяет `PUM`, выбирает trusted kernel stack для user origin либо
прерванный stack для supervisor. Он сохраняет `r1` через низкое слово,
проверяет alignment и границы с запасом под frame, bottom canary и
512 байт dispatcher headroom, затем сохраняет остальные значения.
Этот запас — политика LA/IX, а не аппаратная гарантия максимальной
глубины вызовов M. Canary дополняет, но не заменяет MMU guard page.

Один `TRAP_SAVED_R1` подходит для нынешней однопроцессорной невложенной
начальной части входа с `EXL=1`. При расширении nesting он не должен быть
живым во время следующего входа; для будущего SMP нужны per-core entry state
и stacks. Наличие user ветки в assembly ещё не доказывает user-mode return:
нужна проверка реального входа со злонамеренным пользовательским `sp`.

`PTBR` в frame полезен для диагностики, но сохранение поля не является
автоматическим переключением address space. Планировщик обязан выбрать
каталог возвращаемой задачи, сохранить доступ к frame и восстановить
остальное thread state. `FCSR` требует отдельного restore.

Чек-лист:

- [ ] Низкие слова и все их physical aliases недоступны пользователю.
- [ ] Каждый address space отображает entry code/state, stack и panic path.
- [ ] M/assembly совпадают по offsets, размеру и alignment TrapFrame.
- [ ] Проверены все GPR, исходный `sp`, `tp`, `ra`, EPC, STATUS и FCSR.
- [ ] Смена задачи обновляет `KERNEL_SP`, stack bounds и выбранный PTBR.
- [ ] User trap со `sp=0`, невыравненным или kernel-like `sp` берёт kernel stack.
- [ ] Overflow stack имеет проверенный аварийный путь без обращения к плохому стеку.

<a id="mmu"></a>

## 6. MMU, права, ASID и TLB

### Таблицы и permissions

WRM использует двухуровневые таблицы: 4 KiB directory, 1024 entries по
4 байта; следующий уровень такого же размера. VA разбивается на
`dir[31:22]`, `table[21:12]`, `offset[11:0]`. Базовый page size 4 KiB,
superpage 4 MiB. `PTBR` содержит physical directory base в битах 31–12,
8-битный ASID в 11–4, `EN` в бите 0; биты 3–1 reserved/read-as-zero.

Номера bits PTE: `V=0`, `R=1`, `W=2`, `X=3`, `U=4`, `A=5`, `D=6`, `G=7`,
bits 11–8 reserved, physical base — 31–12. В non-leaf PDE `V=1`,
`R/W/X=0`, base ведёт на table. Если PDE имеет любой `R/W/X`, это leaf
superpage; physical bits 21–12 обязаны быть 0. PTE без `V` или без
какого-либо `R/W/X` не отображает страницу.

Fetch требует `X`, load — `R`, store — `W`, независимо друг от друга.
`W` не подразумевает `R`. User mode дополнительно требует `U` в leaf;
`U` non-leaf PDE не задаёт права children. Supervisor обходит только
проверку `U`, но не `R/W/X`. Нет автоматического запрета supervisor на
user pages: проверки пользовательских указателей остаются задачей ОС.

`IVEC/EPC` и адресные значения `BADADDR` виртуальны при MMU on.
Directory/table storage адресуется физически. Walk читает RAM/ROM,
не MMIO/VRAM; недоступная entry даёт page fault, не побочный эффект device.
После успешной translation hardware выставляет `A`, при записи — `D`,
в **leaf** entry; для superpage это PDE. Writeback failure тоже page fault.
Таблицы обычно должны быть в RAM; read-only ROM возможен только если
необходимые A/D заранее выставлены.

`A` может установиться от speculative fetch, даже если инструкция не
исполнялась. Очистить A/D в памяти без TLB invalidate недостаточно:
cached entry может помнить старые flags. Неуспешный `SC` не устанавливает D.
PTE permissions не отменяют physical bus rules: `X` у MMIO/VRAM всё равно
не позволяет fetch, `W` у ROM всё равно приводит к store bus error.

### ASID и invalidation

| Операция | Что инвалидируется |
| --- | --- |
| `TLBI rs1, 0` | Одна 4 KiB VA page текущего ASID и совпавшая global translation |
| `TLBI rs1, 1` | Все non-global translations ASID из `rs1 & 255` |
| `TLBI r0, 2` / `TLBI.ALL` | Весь TLB, включая global; `rs1` должен быть 0 |
| `MTCR PTBR` с тем же ASID | Non-global entries этого ASID |
| `MTCR PTBR` с другим ASID | Старые contexts сохраняются; global entries сохраняются |

ASID — tag, а не permission или номер CPU. Перед выдачей ранее
использованного ASID другому address space нужны invalidate этого ASID
или full flush. Разные каталоги с одним ASID требуют согласованной политики
refresh; одной смены physical directory base недостаточно для global entries.

`G` у leaf делает translation общей для ASID; `G` у non-leaf PDE —
**все** pages этой table global. Ошибочный `G` у user directory entry
позволяет TLB использовать перевод другой задачи. Global mappings должны
иметь одинаковые адреса, backing и права во всех contexts.

Superpage кэшируется отдельными 4 KiB fragments. Один page TLBI не
удаляет остальные cached fragments 4 MiB region. После изменения
superpage нужны все соответствующие page invalidations либо более широкий
flush; для global superpage безопасный простой вариант — `TLBI.ALL`.

`V=0` не кэшируется, поэтому превращение заведомо invalid entry в valid
не требует удаления negative translation. Это не отменяет необходимость
полностью подготовить table до публикации PDE и проверить, что старого
valid mapping в TLB нет.

Valid entry попадает в TLB при walk **до проверки прав**. Поэтому TLBI
нужен при любой смене `R/W/X/U`, в том числе при **расширении** прав:
если после store page fault добавить `W` в PTE и вернуться без TLBI,
повторный store снова получит page fault из старой cached entry, и задача
зациклится. Это касается COW, demand write и выдачи `U`/`X`.
Для valid→invalid, смены frame или сужения прав устаревшие translations
обязательно удаляются **до переиспользования frame**.

Guard page должна отсутствовать вместе со всеми обходными mappings к
её physical storage. Большая identity superpage не оставляет дырку 4 KiB:
для guard нужно разбить соответствующий регион на обычные pages.
То же относится к RX code, R-only constants, RW data и W^X policy.

Чек-лист:

- [ ] Таблицы 4 KiB aligned и зарезервированы в physical allocator.
- [ ] Tail RAM не отображает отсутствующие frames через большую superpage.
- [ ] User/kernel права проверены fetch/load/store, включая supervisor R/W/X.
- [ ] Unmap/revoke удаляет translations до освобождения physical frame.
- [ ] Fault handler, расширяющий права (COW, demand write), делает TLBI до retry.
- [ ] ASID reuse, global mappings и superpage fragments имеют явную TLBI policy.
- [ ] Guard, read-only sections и низкие entry frames не имеют permissive aliases.
- [ ] Сбор A/D учитывает speculative fetch и cached flags.

<a id="ordering"></a>

## 7. Атомики, порядок памяти и изменение кода

`LL` читает word и резервирует **physical**, 4-aligned word. `SC` пишет
только при сохранившейся reservation: результат **0 — успех, 1 — отказ**.
Каждый `SC` очищает reservation. Даже неуспешный SC проверяет alignment
и write permissions; нельзя использовать его как безопасный probe pointer.
Он может дать fault, но при обычном отказе не отмечает page dirty.

Reservation снимают overlapping CPU/DMA write, trap, `MTCR PTBR`,
`TLBI`, reset. Два VA aliases одного physical word связаны одной
reservation. IRQ между `LL/SC` способен вызвать отказ без конкурирующего
потока, поэтому update всегда делается retry loop, с корректной политикой
ожидания для lock. При успехе SC атомарен относительно CPU и DMA.

Для MMIO `LL/SC` не является обычной lock primitive: чтение уже может
извлечь FIFO item, а попытка записи — иметь device-specific последствия.
На VRAM LL/SC работает, но **прямые записи drawing engine не снимают
reservation**; CPU и DMA записи снимают. Следовательно, SC не гарантирует
отсутствие intervening engine draw в том же pixel storage.

`FENCE` упорядочивает data memory operations. Текущий single-core CPU
выполняет их по порядку, но compiler тоже обязан сохранять нужный порядок
MMIO, descriptor publication и `OWN`. В M для MMIO используются
`*volatile T` / `*volatile mut T`: accesses выполняются по одному, своей
ширины, в исходном порядке относительно других volatile accesses.
Обычная память может переставляться относительно volatile; `fence()`
упорядочивает их. `mtcr`, `tlbi`, atomics и `asm` тоже имеют compiler
ordering contract. Подробнее — [hardware API M](../mc/docs/spec/07-hardware.md).
`atomicCompareSwap` в M возвращает старое значение, а не код SC.
`asm` не имеет operands и не разрешает менять stack/callee-saved registers
или передавать управление за пределы вставки: полноценный trap entry
пишется отдельной assembly function.

Frontend заранее fetch-ит инструкции. После patch code store нужен
переход, сбрасывающий prefetched instructions: taken branch, `JAL/JALR`,
`IRET`, `MTCR STATUS/PTBR` или `TLBI`. При fallthrough в изменённый код
может исполниться старая или новая инструкция. **FENCE не синхронизирует
instruction fetch.** Для DMA-generated code сначала ждать completion,
затем выполнить такой control transfer и обеспечить `X` mapping.

Чек-лист:

- [ ] SC success сравнивается с 0; failures повторяются без потери update.
- [ ] Interrupt/nesting path не рассчитывает сохранить reservation.
- [ ] Atomics не применяются к FIFO/MMIO с побочными эффектами.
- [ ] Descriptor data публикуются до OWN/start doorbell.
- [ ] Изменённый CPU/DMA код запускается после completion и refetch transition.

<a id="floating-point"></a>

## 8. Floating point и FCSR

Аппаратный float — IEEE binary32 в тех же GPR. Отдельного FPU register file
и lazy FPU trap нет; float load/store используют обычные words.
`FMADD/FMSUB` используют **старое значение rd** как addend и округляют
один раз: FMSUB вычисляет `old_rd - rs1*rs2`.
Поддерживаются subnormals; floating-point exceptions не вызывают trap,
а устанавливают sticky flags в `FCSR`.

| FCSR | Значение |
| --- | --- |
| bits 0–4 | `NX` inexact, `UF` underflow, `OF` overflow, `DZ` division by zero, `NV` invalid |
| bits 7–5 | `FRM`: 0 nearest ties-even, 1 toward zero, 2 down, 3 up, 4 nearest ties-away |
| FRM 5–7 | Reserved: запись сохраняет прежний mode, но обновляет flags |

Reset FCSR=0: nearest ties-even, flags clear. Запись flags заменяет их,
а не выполняет W1C, как многие device status registers.
Flags устанавливаются на retirement, squashed instruction их не оставляет.
`MFCR` видит эффекты старых операций; `MTCR FCSR` refetch-ит молодые
инструкции с новым rounding mode. Mode ABI сохраняется через обычные
вызовы, exception flags — нет. Оба принадлежат **потоку** и должны
сохраняться ядром; software double использует тот же FCSR environment.

Для trap ядро сохраняет FCSR до собственной FP работы и может установить
свой mode/flags; при возврате восстанавливает состояние задачи. Одного
сохранения GPR недостаточно. Текущий LA/IX делает это в trap entry/exit.

Граничная семантика:

- Arithmetic NaN канонизируется в `0x7FC00000`, без сохранения payload/sign.
  `FSGNJ/FSGNJN/FSGNJX` меняют только sign и сохраняют payload.
- `FEQ/FLT/FLE` при NaN дают false; `+0` и `-0` равны.
  `FMIN/FMAX` выбирают не-NaN operand, если NaN только один; оба NaN дают
  canonical NaN. Для min/max `-0 < +0`.
- `FTOI/FTOU` **всегда truncate toward zero**, независимо от FRM, с
  saturation к пределу integer range; NaN даёт максимальное integer value.
- `NV` возникает при invalid arithmetic, out-of-range conversion,
  signaling NaN; для `FLT/FLE` — при любом NaN. `DZ` — finite nonzero / 0;
  `0/0` даёт NV. Overflow также даёт NX. Underflow использует tininess
  **до округления** и требует inexact result.
- `FCLASS` возвращает один bit для класса: −∞, negative normal/subnormal,
  −0, +0, positive subnormal/normal, +∞, signaling/quiet NaN (bits 0–9).
  Sign operations и FCLASS не выставляют flags. Exact cancellation даёт
  +0, кроме rounding down, где получается −0.

Чек-лист:

- [ ] FCSR сохраняется при syscall, IRQ и context switch, включая sticky flags.
- [ ] FP в kernel не меняет environment прерванной задачи.
- [ ] Проверены NaN, signed zero, subnormals, saturation и rounding modes.
- [ ] Software double/runtime соблюдают тот же FCSR contract.

<a id="io-dma"></a>

## 9. MMIO и DMA: общие правила

### Physical map и доступ к регистрам

| Physical range | Назначение |
| --- | --- |
| `0x00000000…RAM_SIZE-1` | RAM; установленные slots подряд без дырок |
| `0xFC000000…0xFC3FFFFF` | 4 MiB VRAM window |
| `0xFD000000…0xFDFFFFFF` | I/O region, отдельная 4 KiB page на устройство |
| `0xFE000000…0xFFFFFFFF` | 32 MiB read-only ROM |

Остальные адреса не существуют на physical bus. Эмулятор поддерживает
четыре RAM slots: по 1/2/4/8/16/32 MiB, default 4 MiB суммарно в одном
slot, максимум 128 MiB. Пустой slot не расходует адресное пространство.
ОС получает фактический размер из boot info, а не из default config.

MMIO registers — 32-битные, **адрес каждого access кратен 4 даже для
byte/half-word операции**. `LBU UART+0` читает low byte, а `LBU UART+1`
даёт bus error; это не byte-addressable массив частей register.
Narrow read сохраняет полный побочный эффект чтения register:
например, RNG расходует word, FIFO извлекает event. Narrow write — запись
low value, а не универсальная операция слияния одного byte со старым word.
Пользоваться шириной, указанной register interface, обычно `UWord`.

Запись в существующий read-only device register игнорируется. Доступ к
неописанному offset или отсутствующей device page даёт bus error.
У каждой device page по `+0xFFC` read-only `ID`:
`TYPE[31:16]`, `VERSION[15:8]` (сейчас 1), `IRQ[7:0]` (`0xFF` — без IRQ).
Проверять тип/версию и пользоваться firmware device table предпочтительнее,
чем без handler пробовать все addresses. Такой probe может вызвать fault.

В device status часто используется **W1C**: запись единицы очищает
конкретный flag. `status = status | mask` может нечаянно подтвердить другие
события, прочитанные в status. Записывать только известную ack mask.
Другие status bits clear-on-read — чтение диагностическим кодом тоже
изменяет устройство. Snapshot структуры MMIO целиком опасен для DATA/FIFO.

### DMA обходит MMU

DMA register/descriptor содержит **physical address**. Device не читает
`PTBR`, не проверяет `U/R/W/X` PTE и не генерирует CPU page fault:
неправильный bus access отражается в device error/fault state.
Virtual buffer по VA `0x40000000` не становится таким же DMA address;
нужны physical frames, contiguous buffer либо scatter-gather, если device
его поддерживает. Непрерывный VA range может состоять из разрозненных frames.

Доступность в текущем эмуляторе по [DMA bus callbacks](../source/motherboard.c):

| Device family | DMA read | DMA write |
| --- | --- | --- |
| HDD/floppy | RAM и VRAM window | RAM и VRAM window |
| Video/Ethernet/audio/shared folder | RAM, VRAM window, ROM | RAM и VRAM window |
| Все | MMIO и unmapped запрещены | MMIO, ROM и unmapped запрещены |

Alignment, lengths и descriptor constraints добавляются самим device.
ROM read не означает допустимость ROM descriptor, который device должен
обновлять. Для Ethernet OWN возвращается через запись descriptor;
размещать rings следует в writable RAM.

У WRM нет реализованного IOMMU или hardware whitelist DMA frames.
Драйвер с raw MMIO командой может указать physical address ядра, entry
state или другой задачи. **Вынос такого драйвера в user mode сам по себе
не даёт изоляции от его DMA**. Capability на MMIO page ограничивает доступ
к контроллеру, но не destinations, которые он запрограммирует.

Рабочие варианты для микроядра:

1. Ядро/доверенный broker принимает запрос, проверяет physical ranges,
   формирует descriptors и единолично пишет raw DMA command registers.
2. Драйвер получает raw DMA/MMIO и считается доверенным компонентом с
   соответствующими полномочиями; это явная граница доверия.
3. Для полной изоляции raw DMA driver меняется сама модель оборудования:
   добавляется IOMMU/проверка допустимых ranges. В текущей WRM её нет.

Один bounce buffer не защищает от недоверенного драйвера, если тот по-прежнему
может запрограммировать произвольный ADDRESS. После проверки descriptors
они и их pointer graph не должны изменяться пользователем до completion:
диск читает scatter-gather entry по мере продвижения, поэтому иначе
получается подмена после проверки.

Пока DMA активна, frames и descriptors pinned: allocator не раздаёт их
другим задачам, unmap не освобождает backing, владелец не изменяет источник
и не использует незавершённый destination. Отмена IPC или гибель драйвера
не отменяют DMA автоматически. Освобождать buffer можно после device stop
или подтверждённого completion; HDD transfer останавливается только reset.

DMA failure бывает после partial transfer. Проверять одновременно completion,
error и прогресс, не считать DONE признаком успеха. Disk WRITE сохраняет
только целые sectors, disk READ мог уже изменить часть sector в RAM;
video EXPAND мог нарисовать только первые lines; shared READ/WRITE имеет
partial byte count. Уже сделанные внешние writes не откатываются reset.

Чек-лист:

- [ ] MMIO pointers volatile, register offsets/ширины верны.
- [ ] Clear-on-read и W1C не теряют события при диагностике/ack.
- [ ] DMA API принимает проверенные ranges/handles, переводит VA→PA.
- [ ] Проверены overflow `address+length`, frame ownership и alignment.
- [ ] DMA buffers/descriptors pinned и защищены от изменения после проверки.
- [ ] Exit/crash/cancel не освобождает storage активной DMA.
- [ ] Определена граница доверия для каждого user driver с raw DMA MMIO.

<a id="devices"></a>

## 10. Особенности каждого устройства

Ниже перечислены все 17 занятых device pages (16 типов: два HDD одного
типа). IRQ column описывает PIC line; CPU получает один общий IRQ input.
Полные register layouts — в [Devices](SPECIFICATION.md#devices).

| Device | Physical page | IRQ | Главная особенность |
| --- | --- | --- | --- |
| PIC | `0xFD000000` | — | 32 level-triggered lines, CLAIM не подтверждает event |
| Keyboard | `0xFD001000` | 0 | HID events, FIFO, overflow clear-on-read |
| UART | `0xFD002000` | 1 | DATA имеет read/write side effects, TX всегда ready |
| Timer | `0xFD003000` | 2 | COUNT 64-bit, EXPIRED схлопывает пропущенные periods |
| Power | `0xFD004000` | 11 | OFF/RESET прекращают исполнение после store |
| HDD 0 | `0xFD005000` | 3 | DMA, 512-byte sectors, DONE даже при error |
| HDD 1 | `0xFD006000` | 4 | Тот же interface; firmware не boot-ит с него |
| Video | `0xFD007000` | 5 | VRAM, sync/async commands, общий DONE/VBLANK IRQ |
| Floppy | `0xFD008000` | 6 | Removable, медленная DMA, CHANGED |
| Beeper | `0xFD009000` | — | Один tone, duration в ticks |
| Mouse | `0xFD00A000` | 7 | FIFO relative/absolute events, отключена при reset |
| Ethernet | `0xFD00B000` | 8 | Physical descriptor rings, OWN, host NAT |
| Audio | `0xFD00C000` | 9 | 8 DMA voices; FAULT сам по себе не поднимает IRQ |
| RTC | `0xFD00D000` | 10 | Read-low latch, host wall time, one-shot alarm |
| RNG | `0xFD00E000` | — | Read consumes word; seeded mode не секретен |
| Shared folder | `0xFD00F000` | — | Synchronous host operations, 16 handles |
| Watchdog | `0xFD010000` | 12 | Bark, grace, reset; ack не заменяет kick |

### 10.1 PIC

`PENDING` — текущие device line levels, `ENABLE` — mask (reset 0),
`ACTIVE = PENDING & ENABLE`. `CLAIM` возвращает **наименьший номер**
active line или `0xFFFFFFFF`. Чтение CLAIM не меняет state, нет отдельного
EOI register. Handler должен очистить источник **в устройстве**, иначе
после IRET тот же IRQ немедленно повторится.

Низкий номер имеет приоритет при каждом CLAIM; один не обслуженный source
может мешать остальным. Handler может иметь budget и mask проблемной линии,
но masking не устраняет pending condition. Polling разрешён при ENABLE=0.
При IRQ dispatch всегда проверять sentinel, не использовать его как index.

- [ ] Обслуживать device source до IRQ return; проверять все shared flags.
- [ ] Проверить два одновременно pending IRQ и отсутствие starvation.
- [ ] Mask/unmask protocol согласован с device polling и event delivery.

### 10.2 Keyboard

FIFO на 32 events; `DATA` извлекает event, empty — 0. Low 16 bits — USB
HID usage page `0x07`, bit 31 — release. Это key code, не ASCII и не
Unicode; layout, modifiers, compose и autorepeat реализует software.
Hardware key repeat нет. Overflow означает потерянное событие и очищается
чтением STATUS; потерянный release может оставить software key state stuck.
CONTROL bit 0 flush-ит FIFO. IRQ 0 держится, пока очередь не пуста.

- [ ] Отделить HID key events от text input и учитывать press/release.
- [ ] Drain FIFO и обработать overflow с восстановлением key state.

### 10.3 UART

`DATA` write отправляет low byte в host stdout, read извлекает RX byte.
Empty read возвращает 0, который неотличим от настоящего NUL без STATUS.
RX FIFO 64 bytes, IRQ 1 держится пока он не пуст. STATUS overflow
clear-on-read; CONTROL bit 0 flush. TX не блокирует, TX-ready всегда 1;
TX IRQ отсутствует. Не нужен цикл ожидания освобождения transmit FIFO.

Native stdin terminal работает raw без local echo: echo/line editing делает
guest. Host ограничивает чтение piped input свободным местом FIFO; input
scripts могут переполнить его. UART stdout отделён от emulator stderr.
В browser UART input отсутствует, output идёт в page/JS console.

- [ ] Проверять RX-ready перед read, не считать NUL отсутствием byte.
- [ ] Panic output не зависит от IRQ, heap, scheduler и сложного formatter.

### 10.4 Timer

Free-running COUNT 64-bit и down-counter идут каждый system tick.
Согласованное чтение COUNT: **HI, LO, HI**, повтор при разных HI.
FREQUENCY сообщает ticks/second. Запись CONTROL загружает VALUE из RELOAD,
то есть даже изменение mode/enable перезапускает счётчик.
`RELOAD=N` истекает через N ticks; 0 действует как 1.

One-shot сбрасывает enable после expiry, periodic перезагружает VALUE.
EXPIRED W1C; disable не очищает его. Пока bit выставлен, несколько expiry
не считаются отдельно. Для времени и пропущенных quantum вычислять delta
по COUNT, а не умножать число IRQ на RELOAD.

- [ ] Частоту получать из boot info/register; переводить время с overflow checks.
- [ ] Перезапуск CONTROL и отдельный ack EXPIRED проверены.
- [ ] Проверить delayed handler: один IRQ после нескольких periods.

### 10.5 Power controller

OFF использует low 8 bits как exit code процесса эмулятора; RESET value
игнорируется. Request применяется в конце tick store; следующие инструкции
не выполняются. OFF/RESET read возвращает 0. До OFF нужно завершить
сохранение данных и disk FLUSH/shared SYNC; код после store ничего не исправит.

Host close/Ctrl+C устанавливает STATUS power-request и IRQ 11 только если
PIC разрешил IRQ 11 и CPU не halted. Иначе host прекращает работу сразу;
повторный request тоже выходит немедленно. STATUS request W1C.
RESET_CAUSE: 0 power-on, 1 software, 2 host key, 4 watchdog;
3 зарезервирован для double fault, но сейчас double fault останавливает CPU.

- [ ] Shutdown request имеет worker для flush, затем OFF; ack не означает shutdown.
- [ ] Отличать clean guest exit, HLT и unhandled fault по log и exit code.

### 10.6 HDD 0 и HDD 1

Сектора 512 bytes. READ/WRITE используют SECTOR, COUNT, physical ADDRESS;
FLUSH и IDENTIFY — отдельные команды. COMMAND очищает прошлые DONE/ERROR,
проверяет arguments; ошибочная команда может завершиться синхронно с DONE.
COUNT=0 для READ/WRITE заканчивается без error. При BUSY запись transfer
registers и COMMAND игнорируется; отдельной cancel command нет.

HDD DMA: 4000000 bytes/s, слово раз в `floor(clock_rate*4/4000000)` ticks
(32 при 32 MHz), 4096 ticks/sector; первое слово через W ticks после COMMAND.
ADDRESS растёт на word, SECTOR/COUNT меняются после целого sector.
DONE level IRQ W1C либо очищается следующей COMMAND; ERROR остаётся до
следующей команды. Проверять bounds SECTOR+COUNT без integer wrap,
alignment 4 и device ERROR (1…7), а не только DONE.

Scatter-gather: COMMAND.LIST bit 8, LIST указывает на массив entries
`{physical ADDRESS, LENGTH}` по 8 bytes; address/length кратны 4, length>0.
End marker нет: объём задаёт COUNT sectors (IDENTIFY — один block).
Entry читается при первом word его участка, LIST продвигается на 8;
descriptor не обязан совпадать с sector boundary. После конца посреди
entry продолжение требует нового descriptor для остатка, а не повторного
использования текущего LIST как continuation pointer.

READ failure может оставить partial sector в памяти; WRITE failure не
пишет partial sector на диск, но предыдущие whole sectors уже записаны.
Progress registers нужны для диагностики и retry policy.
DMA диска также достигает [VRAM window](SPECIFICATION.md#vram-window).

WRITE completion означает, что bytes достигли host file, **не durable
storage**. FLUSH делает host sync; machine стоит, пока host выполняет
операцию, но для guest команда завершается в tick store. Read-only FLUSH
успешен. Перед `fsync` success и shutdown нужен успешный FLUSH.

IDENTIFY пишет 512-byte `WRMD` block: version, size, flags, UUID, serial,
model. Numeric fields little-endian, UUID bytes — обычный big-endian UUID
order. IDENTIFY игнорирует SECTOR/COUNT и требует inserted disk.
Default serial зависит от absolute image path; при deterministic — имени
файла. Rename/move может изменить identity; explicit serial стабилизирует её.
Host блокирует совместный доступ к images: writable exclusive, read-only
shared; нельзя рассчитывать на live sharing меняющегося image между VMs.
Доступны whole sectors, trailing file bytes не видны.

- [ ] Проверены immediate error, partial failure, BUSY writes и zero COUNT.
- [ ] SG list валидируется целиком, закреплена до completion и не меняется.
- [ ] Flush failure не возвращает клиенту ложный durable success.
- [ ] UUID/serial controller не смешиваются с UUID filesystem.

### 10.7 Floppy

Register interface HDD, но носитель removable и DMA медленнее: 62500 bytes/s,
word period `floor(clock_rate*4/62500)` ticks (2048 при 32 MHz).
Insertion/ejection ставит CHANGED; CHANGED и DONE держат общий IRQ 6,
каждый flag требует ack. После reset CHANGED clear даже с inserted disk.
Eject при BUSY останавливает transfer с no-disk error 2; whole sectors,
уже записанные на image, остаются.
Размер не обязан быть 1.44 MB, но не больше: максимум 2880 секторов, больший
образ не вставляется. Читать SECTORS заново при смене media.

- [ ] CHANGED инвалидирует cached sectors, geometry и filesystem state.
- [ ] Обработаны оба IRQ source и removal во время DMA.

### 10.8 Video card и VRAM

4 MiB VRAM, 2D engine и cursor. Text mode нет: text рисуется glyph bitmap.
Resolution 320×240/640×480/800×600/1024×768 сочетается с 1/4/8/16/32 bpp.
1/4 bpp packed **MSB first**, 8 bpp palette, 16 bpp little-endian RGB565,
32 bpp little-endian XRGB8888. Palette values `0x00RRGGBB`, cursor ARGB.
MODE с invalid depth/extra bits игнорируется; valid mode change сохраняет
VRAM/palette. WIDTH/HEIGHT/BPP/PITCH отражают mode; visible PITCH fixed.

Display показывает visible region от START в конце frame (~60 Hz ticks).
START flip позволяет double buffering, но write не запускает immediate
scanout. Lines вне VRAM и выключенный display чёрные. FRAME увеличивается,
VBLANK sticky до W1C; несколько frames схлопываются в один bit.
Engine surfaces имеют свои BASE/PITCH/XY и могут быть offscreen.

FILL/COPY/EXPAND из VRAM выполняются синхронно при store COMMAND.
LOAD/STORE и EXPAND.MEMORY — DMA, BUSY до завершения; engine register writes
при BUSY игнорируются. Другие registers, включая MODE/palette, меняются;
EXPAND.MEMORY использует destination depth на момент старта.
Zero-size rectangle ничего не рисует; invalid bounds дают error до draw.
COPY с одинаковым pitch имеет memmove overlap semantics;
при разных pitches overlapping result undefined.

LOAD копирует physical RAM/ROM/VRAM в VRAM, STORE — VRAM в RAM/VRAM,
word/tick, addresses/count кратны 4. EXPAND.MEMORY читает aligned words,
содержащие source line bits; source может начинаться на любом byte/bit,
но **все читаемые words**, включая края, должны быть доступны и разрешены
DMA broker. Завершённые lines сохраняются при последующей ошибке.
VRAM window позволяет также CPU reads/writes любой обычной ширины.
Code fetch и page table walk оттуда запрещены.

DONE и VBLANK — общий IRQ 5 с отдельными CONTROL enables и W1C bits.
ENGINE ERROR означает failure, даже при DONE. Cursor — 64×64 ARGB8888,
256 bytes/line, alpha-blended поверх frame без изменения VRAM;
XY signed, HOT задаёт hotspot, offscreen pixels clipped.
Это отдельный ресурс VRAM, который нельзя затереть screen/font allocator.

- [ ] VRAM allocator резервирует visible buffers, font и cursor без overlap.
- [ ] Pixel packing, pitch, mode и rectangle bounds проверяются до команды.
- [ ] BUSY запрещает повторную передачу engine другому request.
- [ ] Оба IRQ source подтверждаются отдельно; MODE/START updates согласованы с frame.
- [ ] DMA validation учитывает aligned-word overread у EXPAND.MEMORY.

### 10.9 Beeper

Один square-wave tone; FREQUENCY Hz, 0 — silence. DURATION в ticks,
0 — бесконечно до disable; ненулевая duration убывает только когда on,
после expiry CONTROL on очищается. Manual off сохраняет remaining duration.
Новая enable начинает wave заново. Frequency выше половины clock rate
даёт silence. IRQ нет, completion можно poll-ить.
Звук host может задерживаться примерно до 85 ms; headless/mute не меняет
device state и timing, только воспроизведение.

- [ ] Не ждать IRQ beeper; пауза/таймаут учитывает ticks, а не host playback.

### 10.10 Mouse

FIFO на 64 events, disabled после reset; CONTROL enable обязателен. DATA pop,
empty — 0; каждый event имеет bit 31=1. Relative DX/DY/WHEEL — signed 8-bit,
Y растёт вниз; buttons — состояние после event. Длинное движение дробится,
соседние совместимые motion events сливаются. Overflow clear-on-read STATUS.
IRQ 7 держится пока FIFO не пуст; flush не заменяет обновление button state.

Relative units — host window pixels, не обязательно pixels video mode.
Pointer capture получает guest после click, сам capture click не event;
Ctrl+Alt/focus loss освобождают pointer и дают release held buttons.
В absolute mode capture нет: event bit 27=1, DX/DY — 0, POSITION в pixels
current mode. **Сначала DATA, затем POSITION**: POSITION привязан к
последнему popped event, а не к голове FIFO. Соседние moves coalesce;
нельзя ожидать event на каждую промежуточную позицию. Headless events
могут поступать из input script.

- [ ] Signed motion и button state обрабатываются раздельно.
- [ ] Absolute position читается после своего DATA, mode switch проверен.
- [ ] Overflow/focus loss не оставляют stuck buttons.

### 10.11 Ethernet card

Ethernet II frames 14…1514 bytes без FCS. Link status не означает CONTROL on.
RX/TX rings — physical arrays 8-byte descriptors `{ADDRESS, CONTROL}`,
ring base alignment 8, до 1024 entries. Buffer byte address не требует
word alignment. Length low 16, ERROR bit 30, OWN bit 31.
OWN=1 отдаёт descriptor device; менять buffer/descriptor в это время нельзя.

Для RX length сначала capacity; device пишет frame, фактическую length и
возвращает OWN=0. Слишком длинный frame обрезается с ERROR. Для TX length
— размер frame, после публикации OWN требуется TX_KICK. Sending завершается
внутри store TX_KICK, он обрабатывает descriptors до первого OWN=0.
Ring base/size меняются только при off; enable сбрасывает NEXT indices 0.

RX/TX/LOST/FAULT в PENDING W1C, IRQ 8 зависит от CONTROL masks; FAULT
разрешён любой из RX/TX IRQ enables. DMA fault останавливает card на
descriptor и выключает её. Без free RX descriptor host queue удерживает
до 64 frames, затем теряет их. Off card drops incoming frames.
Драйвер читает ring state, не считает sticky RX bit числом packets.

Guest сам реализует ARP/IP/TCP/UDP/DHCP. Native backend — host NAT:
guest `10.0.2.15/24`, gateway/DHCP `10.0.2.2`, DNS `10.0.2.3`,
MAC guest `52:54:00:12:34:56`. Gateway поддерживает TCP/UDP и условно
unprivileged ping; fragments не собирает/не посылает, MSS до 1460.
DNS отвечает A, другие types без answer. По умолчанию разрешены public
destinations, local/private blocked; последний совпавший allow/deny rule
решает доступ. Port forwarding отдельно открывает host→guest path.

`--no-net` даёт link down. Browser backend использует proxy для TCP/DNS,
без native UDP/ping. Reset/load snapshot теряют host connections:
guest networking должен справляться с исчезновением transport state.

- [ ] OWN publication/return упорядочены, rings writable и buffers pinned.
- [ ] RX truncation, TX invalid length, ring exhaustion и FAULT не зависают.
- [ ] После off/fault/restart indices и descriptors переинициализированы.
- [ ] Backend/network policy и snapshot disconnect учитываются в тестах.

### 10.12 Audio card

8 DMA voices, host mix 48000 stereo frames/s. Sample data signed 8-bit либо
signed 16-bit little-endian, mono/stereo: frame 1/2/4 bytes. ADDRESS physical,
LENGTH/LOOP/POSITION в **frames**, не bytes; RATE low 24 bits в frames/s.
16-bit values требуют even addresses. Читать можно RAM/ROM/VRAM.
No interpolation; fractional advance накоплен внутри device, RATE 0
держит текущий frame. MASTER и voice VOLUME задают left/right0…255;
MASTER reset 0, поэтому voice on ещё не означает слышимый звук.

Enable не сбрасывает POSITION; для replay поставить его 0. Write POSITION
сбрасывает fractional phase. При loop и LOOP<LENGTH voice возвращается
в loop region; иначе заканчивает на LENGTH и выключается.
End/halfway signals выставляют voice bit STATUS; IRQ 9 при STATUS≠0,
STATUS W1C. Несколько signals одного voice схлопываются; refill stream
сверяется с POSITION и временем, иначе возможен underrun.

Bad DMA/alignment выключает voice и ставит FAULT bit **без STATUS signal**;
FAULT сам по себе IRQ не поднимает. Ошибку нужно проверять программно.
Loop buffer pinned пока voice играет; одну половину refilling делать после
прохождения device этой половины, а не просто по любому voice IRQ.
Mute/headless сохраняют device operation. Host playback latency не равна
guest POSITION и может достигать примерно 85 ms.

- [ ] Frame sizes/length multiplication и sample physical ranges проверены.
- [ ] STATUS и FAULT обслуживаются раздельно; silence MASTER учтён.
- [ ] Streaming выдерживает delayed handler и повторные half/end events.

### 10.13 RTC

Host wall time в Unix seconds + nanoseconds, local UTC_OFFSET signed
seconds, DST included. **Читать LO первым**: это latch всей даты;
HI/NANOSECONDS/UTC_OFFSET относятся к этому latch до следующего LO.
Это другой протокол, чем HI–LO–HI counters. RTC не устанавливается guest;
для собственного времени ОС хранит offset. Leap seconds не учитываются.

Alarm one-shot: целые seconds сравниваются с ALARM при arm и затем
примерно каждые 1 ms machine time. Past alarm срабатывает сразу.
ALARM sticky/IRQ 10 W1C, disarm не очищает status. Host time может
отличаться от guest ticks; monotonic deadlines/scheduler используют Timer.
`--rtc` даёт virtual epoch + ticks since power-on, UTC_OFFSET0;
virtual RTC, как и host RTC, не откатывает время при guest reset.

- [ ] Clock APIs отделяют monotonic ticks от wall time.
- [ ] Latch reads, past alarm, clear/disarm и reset проверены.

### 10.14 RNG

DATA выдаёт новое 32-bit word без ожидания; narrow read расходует весь
word. STATUS bit 0 означает **seeded**, а не «готово» или «достаточно entropy».
В обычном режиме источник — host CSPRNG. `--seed`/deterministic выбирают
воспроизводимый ChaCha20 stream: N little-endian в первых 8 bytes key,
остаток 0, nonce 0, 64-bit block counter начиная 0.
Такой seed не источник секретных ключей.

Последовательность продолжается при reset. Snapshot seeded stream
продолжается со своего state; host mode после load берёт новые bytes.
Новая выборка может численно совпасть с прежней: uniqueness ID нужно
обеспечивать отдельно, а не предполагать из random32.

- [ ] Seeded mode явно различается с host entropy mode.
- [ ] Key/ID generation не полагается на уникальность каждого random word.

### 10.15 Shared folder

Host filesystem proxy, **не block disk и не filesystem LA/IX**. Команды
OPEN/CLOSE/READ/WRITE/STAT/READDIR/MKDIR/REMOVE/RENAME/TRUNCATE/SYNC
выполняются синхронно в store COMMAND, без IRQ. Host operation может
занять wall time, хотя guest tick не продвигается. ERROR/RESULT надо
читать сразу; следующий COMMAND сбросит RESULT/изменит outcome.

PATH/PATH2/data — physical, paths RAM/ROM/VRAM по текущей bus реализации,
READ destinations writable RAM/VRAM. Paths NUL-terminated, максимум 1023
bytes + NUL; relative to shared root. Empty slash components пропускаются,
`.`/`..`, control chars, backslash, colon запрещены. Encoding/case решает
host. Symlink вне root запрещён на native POSIX, **Windows links не
проверяются** по текущему documented contract; не приписывать этот sandbox
LA/IX filesystem policy. Read-only share или handle запрещает изменения.

16 handles0…15, OPEN выбирает lowest free. Directories требуют DIRECTORY
flag отдельно; handles общие всему device, изоляцию клиентов создаёт
сервер. READ/WRITE до 1 MiB за команду, без alignment constraints;
64-bit POSITION и ADDRESS растут, COUNT уменьшается, RESULT — actual bytes.
EOF/partial DMA error допускают short result. Writes могут расширять file,
gap читается как zeros. SYNC нужен для durable acknowledgement.

STAT record 32 bytes с type/size/mtime, READDIR — record и name, buffer
не меньше 288; RESULT 0 — конец directory. Порядок entries host-dependent,
`.`/`..` и недопустимые names опускаются. Reset/load snapshot закрывают все
handles; files не откатываются. Error7 после load требует reopen.

- [ ] Server проверяет paths, flags, handles, short I/O и RESULT/ERROR.
- [ ] Physical buffers проверены до synchronous host command.
- [ ] Read-only и SYNC входят в контракт; snapshot закрывает client handles.
- [ ] Tests не зависят от READDIR order и особенностей host case/encoding.

### 10.16 Watchdog

TIMEOUT/GRACE в ticks; 0 действует как 1. Enable загружает TIMEOUT.
Expiry ставит BARK/IRQ 12, начинает grace; её конец reset с cause 4.
KICK перезагружает TIMEOUT, выходит из grace и очищает BARK.
W1C BARK только снимает IRQ, **не отменяет reset после grace**.
Изменённые TIMEOUT/GRACE учитываются после следующего kick.

LOCK делает CONTROL/TIMEOUT/GRACE read-only до reset, KICK остаётся.
NMI нет: при masked IRQ/EXL=1 bark не попадёт в handler, но countdown
идёт до reset. При HLT ticks остановлены, поэтому watchdog **не способен
восстановить CPU после HLT/double fault**. Во время WFI countdown идёт.

- [ ] Проверены kick, ack-only, locked state и reset cause 4.
- [ ] Не рассчитывать на bark при IE0 или на watchdog recovery после halt.

<a id="timing"></a>

## 11. Время, pipeline и производительность

Default clock 32 MHz настраивается host; это не обязательная константа ISA.
Timer, DMA, video frames, beep duration, audio sampling, watchdog работают
в machine ticks. Обычная RTC использует host wall clock; это отдельная
шкала. При slow emulation guest monotonic time отстаёт от host time,
при unthrottled может опережать. CPU HLT останавливает ticks, WFI — нет.

На tick устройства идут в фиксированном порядке: Timer → HDD0/HDD1 →
Video → Floppy → Beeper → Audio → RTC → Watchdog → CPU. IRQ/DMA event
на этом tick может быть виден CPU на том же tick. Эмулятор оптимизирует
пустые промежутки и синхронизирует lazy devices перед register access;
это не разрешение software полагаться на скорость host polling loop.

Pipeline IF/ID/EX/MEM/WB имеет latency 5 cycles, throughput до 1 instruction
за cycle. Есть forwarding; immediate load-use dependency добавляет 1 cycle.
Branches predicted not taken; taken branch/jump удаляет две младшие
инструкции, penalty 2 cycles. Arithmetic, в том числе division и float,
в нынешней модели выполняется за один EX cycle; это не latency реального
host arithmetic. `IRET` redirect на WB имеет penalty 4 cycles.
Control accesses сериализуют старые операции; mode/PTBR/trigger/FCSR
changes и TLBI refetch-ят молодые instructions.
TLB walk выполняется в том же cycle без дополнительного timing penalty.

Нет delay slots и обязанности вставлять NOP для forwarding. Loads/stores
в MEM не выполняются спекулятивно; speculative IF может walk page tables
и выставить A. Squashed instructions не меняют GPR, RAM или FCSR flags,
но наблюдение A не доказывает retirement. Fetch/walk не вызывает MMIO
side effects, поскольку MMIO/VRAM запрещены для этих bus операций.

64-bit `CYCLE` и `INSTRET` читаются HI–LO–HI с retry при rollover.
CYCLE учитывает WFI, не HLT; INSTRET считает только успешно retired
instructions: faulting SYSCALL/BREAK не добавляются, IRQ не instruction,
squashed instructions не считаются. Guest reset обнуляет CPU counters
и Timer COUNT; RTC virtual epoch + power-on ticks продолжает идти.
Нельзя смешивать эти origins после reset.

Размер TLB (сейчас 64 entries в [mmu.h](../include/mmu.h)), replacement,
host-side caches и ускорение lazy devices — детали эмулятора. Kernel
correctness не должна зависеть от eviction, случайно очищающего stale mapping.
Pipeline timing пригоден для ISA regression, но throughput host emulator
не является оценкой реального аппаратного WRM implementation.

Чек-лист:

- [ ] Все сроки явно указывают шкалу: ticks, monotonic duration или wall time.
- [ ] 64-bit counters читаются согласованно, reset origins учитываются.
- [ ] Timing-sensitive tests задают clock и контролируют внешний input.
- [ ] Устаревшие mappings удаляются TLBI, а не надеждой на eviction.

<a id="diagnostics"></a>

## 12. Диагностика, debugging и snapshots

### Kernel panic и ранний failure path

Kernel panic должен печатать stage, origin по PUM, CAUSE и его имя,
EPC, BADADDR, STATUS с flags, PTBR, FCSR, все GPR и состояние stack bounds.
Полезны current task/address space, last IRQ/device error и kernel image
identity. Hex addresses нужны с ведущими нулями для сравнения с symbol map.
Не разыменовывать неизвестные pointers ради красивого diagnostic message.

Сбой entry до полного frame требует отдельного early panic path:
нельзя читать ещё не сохранённые поля, вызывать обычную функцию на плохом
stack или обращаться к отсутствующему framebuffer mapping.
Polling UART — простая основа: нет TX IRQ, ожидания DMA и allocation.
Поздний графический dump возможен только при гарантированно valid video
mapping/engine state; очередная неисправная операция при EXL приведёт к halt.
Рекурсивный panic/formatter failure должен иметь ограниченный fallback.

Запись вида `CAUSE=13 (breakpoint), stage=trap-selftest` доказывает, что
BREAK дошёл до handler и dump напечатан. Она **не доказывает корректность
IRET или сохранения всех registers**. Для ожидаемого self-test BREAK
нужно проверить allow condition, обновить EPC ровно на 4, вернуться и сравнить
контекст. Не превращать любое BREAK в success: unexpected breakpoint
в kernel по-прежнему требует диагностики.

После CPU double fault software panic может уже не исполняться. Эмулятор
печатает unhandled fault state на stderr, а `--debug` также dump-ит HLT,
power-off и quit. Остановленный CPU хранит pipeline: MEM/WB показывает
вторую остановившую инструкцию; saved EPC может относиться к первому trap.
Для EPC lookup использовать map **того же image**, а не свежие symbols
для старого binary. Для page fault дополнительно разобрать PTBR/PDE/PTE,
permissions и physical accessibility; отсутствие page mapping и bus error
после успешной translation — разные неисправности.

### Guest single-step и triggers

`STATUS.SS` даёт trap 14 после instruction, EPC следующая, BADADDR предыдущая.
SS оценивается в начале instruction: включающая его MTCR не step-ится,
следующая instruction step-ится; instruction, очищающая уже установленный
SS, всё ещё вызывает step. HLT не даёт step, WFI при stepping не ждёт,
а даёт step trap. Entry сохраняет SS в PSS; IRET восстанавливает SS=PSS.
Во время EXL1 guest step/triggers подавлены.

Два triggers: TADDR0/TCTRL0 и TADDR1/TCTRL1, virtual addresses.
TCTRL содержит X/R/W bits 0/1/2 и SIZE bits 12–8: aligned region 2^SIZE,
содержащий TADDR. Match любого затронутого byte даёт cause 15 **до effects**
инструкции. Для data alignment check идёт прежде trigger, trigger прежде
translation; для fetch сначала fetch (его fault имеет приоритет), затем
trigger. После IRET к прежнему EPC trigger снова совпадёт.
Для выполнения одной instruction debugger временно выключает trigger,
делает step через PSS и включает trigger обратно. Если triggers принадлежат
задачам, scheduler сохраняет/восстанавливает и этот state.

### Host monitor и trace

Host monitor (`--monitor`, `--pause`) имеет собственные breakpoints и
watchpoints, **не guest triggers**. Он останавливает между instructions,
не входит в IVEC, не меняет guest trap frame и работает с ROM. Breakpoint
срабатывает перед instruction, watchpoint — после load/store. Поэтому
host watchpoint и guest trigger имеют разный момент наблюдения effects.

Полезные commands: `r`, `d`, `x` virtual, `xp` physical, `b`, `watch`,
`s`, `c`, `info`. `w/wp` меняют RAM; такие edits — debugger actions,
а не безопасный runtime memory API ядра. Monitor слушает localhost.
Для исследования active mappings различать VA и PA; physical read
не является доказательством user permissions.

`--trace` пишет дошедшие до WB instructions, изменения и faults,
IRQ отдельной строкой. Squashed instructions не видны; faulting instruction
видна, хотя не прибавляет INSTRET. Trace растёт примерно 80 bytes/instruction
и замедляет host; запускать на коротком воспроизводимом сценарии.
UART log stdout и emulator diagnostic stderr сохранять раздельно.

### Snapshots и воспроизводимость

Snapshot хранит CPU/pipeline/TLB, RAM/VRAM и devices. Нужны та же ROM,
clock, RAM config и **тот же build эмулятора**. Disk images **не копируются**:
snapshot не откатывает disk/shared-folder writes, load предупреждает об
изменившемся image. Network connections теряются, shared handles закрываются;
host RNG берёт свежие bits, seeded RNG продолжает stream.
Snapshot — удобная точка исследования CPU, но не transaction всей host среды.

`--deterministic` включает unthrottled, virtual RTC, seeded RNG и fixed-tick
network polling. Сам по себе он не делает live terminal/window/network,
shared directory contents/order и ответы host servers воспроизводимыми.
Для regression задавать ROM/disk/config/seed/input script и контролировать
внешнюю сеть; для чистых CPU tests обычно отключать её.
Input script инжектирует key/UART/mouse/power перед указанным power-on tick;
full FIFO drops events, disabled mouse ignores их, как при настоящем input.

Browser имеет дополнительные ограничения: UART без input, network через
proxy, images сохраняются в IndexedDB для origin. Disk writes сохраняются
при FLUSH и периодически; downloaded image — отдельный артефакт.
Native shutdown/host filesystem поведение нельзя автоматически переносить
на browser persistence.

Чек-лист:

- [ ] Fault dump пригоден без heap/scheduler и не создаёт новый fault.
- [ ] Trap self-test проверяет return state, а не только наличие dump.
- [ ] EPC сопоставляется с правильными map/image и instruction bytes.
- [ ] Guest trigger и host monitor breakpoint не смешиваются в тестах.
- [ ] Regression сохраняет config, input, logs и identity ready binary.
- [ ] Snapshot tests учитывают внешние files, закрытые handles и connections.

<a id="clarifications"></a>

## 13. Границы текущей реализации и решения LA/IX

Здесь собрано то, что легко принять за свойство ISA или за готовую
функциональность. Этот файл не меняет ISA, emulator code или готовность LA/IX.

| Тема | Уточнение и источник |
| --- | --- |
| Multi-core section | [Cores](INSTRUCTIONS.md#cores) — направление расширения. HARTID=0, один CPU; AP start, работающий shootdown и SMP scheduler отсутствуют. |
| LA/IX low words/frame | `0x1FF0…0x1FFC`, page zero без mapping, frame 160, stack 8192 и headroom 512 — [решения LA/IX](../laix/src/arch/wrm081632/defs.inc), не обязательные hardware constants. |
| Kernel features | Наличие machine instruction/branch в assembly не означает готовность user launcher, allocator, scheduler, IPC или isolated driver. Проверять [план и критерии этапов](../laix/docs/KERNEL.md). |

CPU ISA не задаёт syscall numbers, policies IPC/capabilities, fault fixup
tables, user virtual layout, allocator ownership и service restart.
Это контракты LA/IX, которые надо описывать и проверять отдельно.
ABI пока не определяет dynamic linker/PIE/debug info; hardware пока не
реализует SMP/IOMMU/NMI. Не строить архитектуру микроядра на их наличии.

<a id="acceptance"></a>

## 14. Сквозная проверка LA/IX

Проверки выполняются по исходникам и на готовом image с известными
ROM/config/map. Следующие пункты — критерии приёмки, а не отчёт о
пройденных tests.

| Направление | Где искать исходный контракт/сценарии |
| --- | --- |
| ISA, modes, traps, atomics, FP | [tests/isa](../tests/isa/), [INSTRUCTIONS](INSTRUCTIONS.md) |
| Precise effects, redirects, timing | [tests/pipeline](../tests/pipeline/) |
| MMU, permissions, superpages, TLB | [tests/mmu](../tests/mmu/) |
| IRQ/device/DMA behaviour | [tests](../tests/), соответствующие sections SPECIFICATION |
| LA/IX boot/trap/guard и ready image | [приёмка LA/IX](../laix/tests/ACCEPTANCE.md), [этап 1](../laix/docs/01_BOOT_TRAPS.md) |
| User/tasks/IPC/services | [этап 3](../laix/docs/03_USER_TASK_SYSCALLS.md), [этап 4](../laix/docs/04_SCHEDULER_IRQ.md), [этап 5](../laix/docs/05_IPC_RIGHTS.md), [этап 6](../laix/docs/06_USER_SERVICES.md) |

- [ ] Warm boot с грязной BSS обнуляет её, сохраняет boot info и reserves.
- [ ] Supervisor и user trap восстанавливают все GPR, sp/tp/FCSR/status.
- [ ] User entry работает с неисправным пользовательским stack pointer.
- [ ] IRQ возвращается на next EPC; syscall/BREAK skip4; page fault retry.
- [ ] EXL nesting policy и авария до frame проверены отдельно от обычного panic.
- [ ] Kernel frames, entry state, RX/RW sections и guards защищены без aliases.
- [ ] ASID reuse и revoke mappings не оставляют доступ через старый TLB.
- [ ] Две задачи не портят memory/TLS/FCSR/debug state друг друга.
- [ ] Device IRQ ack действительно снимает source, включая shared flags.
- [ ] WFI idle просыпается, pending/masked IRQ не создаёт вечного busy loop.
- [ ] DMA не использует VA как PA, frames pinned, partial errors видны клиенту.
- [ ] Недоверенный driver не имеет обхода broker через raw DMA registers.
- [ ] Device/service crash не освобождает storage незавершённой DMA.
- [ ] Shutdown ждёт durable FLUSH/SYNC и завершает работу с явным exit code.
- [ ] Проверки на native/browser/reset/snapshot учитывают их разные contracts.

Для микроядра главный следующий рубеж — реальная user task с отдельным
address space и безопасным trap return. Supervisor self-test необходим,
но не заменяет эту проверку и не доказывает изоляцию DMA drivers.
