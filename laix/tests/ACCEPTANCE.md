# Проверка первого этапа LA/IX

Проверено 2026-10-03 на Darwin arm64 с готовыми `bin/wrm081632` и
`bin/firmware.rom`. Три тестовых образа собраны из текущих исходников;
эмулятор и прошивка не пересобирались. Изменения исходников были поверх
коммита `72d96fa7eda3dd9be2bfdabebbbfb86cc5f83b54`.

> После этого отчёта изменены исходники: принимаются только ожидаемые
> self-test `BREAK`/`SYSCALL`, слова входа перенесены в `[0x1FF0, 0x2000)`,
> страница 0 больше не отображается. Отчёт относится к образам до этих
> изменений; для них нужен повторный прогон. Добавлен образ `null_call`
> (`LAIX_MAIN=laix/tests/null_call.m`): вызов по NULL должен дать
> CAUSE=8, EPC=0, BADADDR=0, `r31` = `nullCallReturn`, exit 254. Для W^X
> добавлены `text_write` (store в `.text`: CAUSE=10) и `data_exec` (вызов в
> `.data`: CAUSE=8). Маркер `trap` теперь требует `kernel W^X`, а runner
> проверяет выравнивание секций по карте. `stack_overflow` проверяет аварию
> при отвергнутом стеке: ранняя строка с `sp`, `scratch`, границами и `ra`,
> затем полный dump с `stage`. Ранний panic без trap больше не печатает
> `CAUSE/EPC/BADADDR`. Новые образы ещё не собирались и не запускались.

## Дополнительная проверка неожиданных BREAK/SYSCALL, 2026-10-03

Готовый `laix/build/laix.img` содержит `trapExpect` и проверен без сборки
через `tests/probe_unexpected_traps.py`. Старые три приёмочных образа выше
не содержат этого обработчика; результаты ниже относятся только к `laix.img`.

| Источник | Ожидание | Сценарии | Результат |
| --- | --- | --- | --- |
| supervisor | отсутствует либо другая причина | BREAK и SYSCALL, 4 запуска | panic, EPC без сдвига, exit 254 |
| user | отсутствует, другая причина либо совпадает | BREAK и SYSCALL, 6 запусков | panic, EPC без сдвига, exit 254 |

Каждый запуск сначала проверяет штатный ожидаемый boot BREAK: ожидание
погашено, сохранённый EPC увеличен ровно на 4. Затем monitor меняет данные
временной машины: ожидание и сохранённый контекст IRET. Для user mode
добавляется временный RXU superpage alias существующих инструкций,
`sp=0xFFFFFFF8` остаётся недоступным. CPU выполняет настоящий IRET и
BREAK/SYSCALL; monitor сверяет аппаратные CAUSE, EPC и STATUS на входе.
Аварийный TrapFrame находится на доверенном стеке, его EPC перед вызовом
panic не изменён, ожидание не погашено. UART содержит правильную причину,
origin, точные EPC, STATUS, BADADDR, PTBR, FCSR и все 32 исходных GPR.
Таким образом, неожиданный SYSCALL также не заменяет `r1` на `-ENOSYS`.

EPC для supervisor: BREAK `0x00010880`, SYSCALL `0x00010984`;
для user alias: BREAK `0x00410880`, SYSCALL `0x00410984`.
Инструкции ядра, исходные образ и карта не изменялись. Это проверка
аварийного user entry через monitor; пользовательские задачи и планировщик
этим прогоном не проверяются.

```sh
python3 -B laix/tests/probe_unexpected_traps.py laix/build/laix.img laix/build/laix.map
```

UART, вывод эмулятора и monitor для каждого случая, а также `results.json`
с SHA-256 сохранены в `laix/build/acceptance/unexpected_traps/` (вне Git).
Эмулятор и ROM имеют те же SHA-256, что указаны в исходном отчёте ниже.
Все 64 теста исходников и тестовых инструментов прошли командой
`python3 -B -m unittest discover -s laix/tests -p 'test_*.py'`.

| Артефакт | SHA-256 |
| --- | --- |
| `laix/build/laix.img` | `017f01e0057cd50d46e3ef6c5be052d7608dfbe3f413834219c7dc400f8e19a5` |
| `laix/build/laix.map` | `8bde68e10d4d90da6c8b411c048b87a5a677d2a872639da8a9d3a4e2ba81012b` |

## Дополнительная проверка низких страниц и NULL call, 2026-10-03

На том же готовом `laix/build/laix.img` выполнен `tests/probe_null_page.py`
без сборки. Проверены настоящие слова RAM и активная таблица страниц:

| Проверка | Значение |
| --- | --- |
| `KERNEL_SP`, `KERNEL_STACK_BOTTOM`, `KERNEL_STACK_TOP`, `TRAP_SAVED_R1` | адреса `0x1FF0`, `0x1FF4`, `0x1FF8`, `0x1FFC` |
| Начальные слова перед `main` | `0x8B000`, `0x89000`, `0x8B000`, `0` — согласованы с картой стека |
| PTE страницы 0 | `0`, страница не отображена |
| PTE страницы 1 | `0x1007`, identity supervisor RW, без X и U |
| Физическое слово по адресу 0 | `0` (HLT), но CPU не исполняет его |
| NULL call | CAUSE=8 (fetch page fault), EPC=BADADDR=0, supervisor |
| Адрес возврата `r31` | `0x00401248`, ровно после инструкции вызова |
| Аварийный выход | полный UART-дамп, stage=null-call-test, exit 254 |

Готового `null_call.img` нет. Вместо него monitor меняет только данные
временной машины: после первого ожидаемого BREAK контекст IRET направлен
на существующую инструкцию `jalr r31, r1, 0` из ROM (`0xFE001244`),
отображённую supervisor RX alias по `0x00401244`, с `r1=0`. CPU выполняет
настоящий косвенный вызов NULL. Страница 0 и инструкции ядра не изменяются;
неотображённая страница проверена также после аппаратного исключения.
Слова доверенного стека остаются неизменными. Для diagnostic stage используется
строка в свободной нижней части стека, вне canary и активного контекста.

Вывод проверен функцией `check_output("null_call", ...)` из `run_ready.py`:
точный адрес возврата fixture передан как ожидаемый `nullCallReturn`.
Отдельный образ `tests/null_call.m` этим прогоном не запускался.
SHA-256 образа, карты, эмулятора и ROM совпадают с таблицами выше.
UART, вывод эмулятора, monitor и `results.json` сохранены в
`laix/build/acceptance/null_page/` (вне Git).

```sh
python3 -B laix/tests/probe_null_page.py laix/build/laix.img laix/build/laix.map
```

Все 67 тестов исходников и тестовых инструментов прошли командой
`python3 -B -m unittest discover -s laix/tests -p 'test_*.py'`.

## Дополнительная проверка аварии исчерпанного стека, 2026-10-03

На том же готовом `laix/build/laix.img` выполнен
`tests/probe_stack_overflow.py`, без сборки и изменения инструкций/PTE.
Готового `stack_overflow.img` нет; рекурсивный `tests/stack_overflow.m`
не запускался. Проверен аппаратный аварийный путь при контролируемом
исчерпании стека через monitor.

После первого ожидаемого BREAK контекст IRET направлен в существующий
пролог `main` (`0x10214`), с SP на нижней границе `0x89000`. CPU выполняет
`addi sp, sp, -8`, затем `sw ra, 4(sp)` в guard. До входа в обработчик
все GPR, кроме r0/SP, заполнены различными значениями, FCSR задан как `0x61`.
Stage указывает на тестовую строку вне canary и активного контекста.

| Проверка | Результат |
| --- | --- |
| Аппаратное исключение | CAUSE=10, EPC=`0x10218`, BADADDR=`0x88FFC`, supervisor |
| Отвергнутый стек | SP=SCRATCH=`0x88FF8`, ниже bottom=`0x89000` |
| Ранняя диагностика | причина, EPC, BADADDR, SP, SCRATCH, границы, RA |
| Статический TrapFrame | `0x8F000`, все 32 GPR и управляющие поля совпадают с контекстом CPU |
| Вызов `trapBadStack` | кадр `0x8F000`, отвергнутый SP `0x88FF8`, аварийный SP `0x8F8A0` |
| Guard и обычный стек | все 3072 слова неизменны до вызова `trapBadStack`, PTE guard=0 |
| Полный dump | stage=stack-overflow-test; те же EPC/BADADDR/SP/RA, исходные GPR, STATUS/PTBR/FCSR |
| Завершение | exit 254; ранняя строка предшествует полному dump |

Вывод прошёл `check_output("stack_overflow", ...)` из `run_ready.py`.
Runner дополнительно требует совпадения EPC и BADADDR между ранней строкой
и полным dump. UART, вывод эмулятора, monitor и SHA-256 находятся в
`laix/build/acceptance/stack_overflow_probe/` (вне Git). SHA-256 образа,
карты, эмулятора и ROM совпадают с приведёнными выше.

```sh
python3 -B laix/tests/probe_stack_overflow.py laix/build/laix.img laix/build/laix.map
```

Все 69 тестов исходников и тестовых инструментов прошли командой
`python3 -B -m unittest discover -s laix/tests -p 'test_*.py'`.

## Исходная проверка трёх приёмочных образов

| Образ | Результат | Код выхода |
| --- | --- | --- |
| `trap` | прямой `breakpoint()`, self-test GPR/sp/tp/ra/FCSR через BREAK и syscall, `-ENOSYS`, `trap runtime OK` | 0 |
| `trap_fault` | CAUSE=3, BADADDR=0x1001, EPC=0x102A4 — ровно `trapFaultInstruction` | 254 |
| `stack_guard` | CAUSE=10, BADADDR=0x85000, EPC=0x102A8 — ровно `stackGuardFaultInstruction` | 254 |

В обоих аварийных дампах присутствуют все 32 GPR, `FCSR`, `STATUS=0x10`
и `PTBR=0x89001`. Не было раннего panic или double fault. Все запуски
выполнены с `--headless --no-net`; runner подключал только загрузочную
часть диска без добавленных растров шрифта. Тестовые main не вызывают
`consoleInit()` и не загружают шрифт.

Дополнительный запуск `trap` через monitor подтвердил:

- Перед `kernelStart` все 7323 слова BSS `[0x85000, 0x8C26C)` заполнены
  `0xA5A5A5A5` и считаны обратно.
- Перед первой инструкцией `main` вся BSS обнулена, кроме намеренно
  установленных canary и адреса boot info; исходный boot info сохранён.
- Guard занимает `[0x85000, 0x86000)`, стек — `[0x86000, 0x88000)`;
  они находятся после образа и вне низких служебных областей.
- Слова `[0xFF0, 0x1000)` содержат правильные `KERNEL_SP`, границы стека
  и обнулённое временное слово.
- После `kernelInit` все десять полей копии boot info совпадают с оригиналом;
  изменение оригинала не изменяет копию.
- Для встроенного BREAK, ассемблерного BREAK, ассемблерного SYSCALL и
  встроенного SYSCALL monitor сравнил все GPR и `FCSR` до пролога и после
  `IRET`. Изменился только syscall `r1` на `0xFFFFFFDA` (`-ENOSYS`).
  Каждый возврат остановлен ровно на следующей инструкции: `pc = EPC + 4`.
- До и после `kernelInit` фактический `sp` выровнен и находится внутри
  стека, `IE = 0`, PIC `ENABLE = 0`; MMU включена после инициализации.

43 проверки исходников, типов, ABI и самого runner также прошли.
Runtime-проверки этого отчёта покрывают supervisor entry. Запуск задач
в user mode и их переключение — следующий этап.

## Артефакты и воспроизведение

Готовые образы и соответствующие карты находятся в `laix/build/acceptance/`:
`trap.img/.map`, `trap_fault.img/.map`, `stack_guard.img/.map`.
Там же сохранены UART, вывод эмулятора, журнал monitor, `boot_probe.json`
и `results.json` с SHA-256 образов, карт, эмулятора и ROM.
Каталог сгенерированных артефактов исключён из Git.

Из корня репозитория, без повторной сборки:

```sh
python3 -B laix/tests/run_ready.py \
    --case trap laix/build/acceptance/trap.img laix/build/acceptance/trap.map \
    --case trap_fault laix/build/acceptance/trap_fault.img laix/build/acceptance/trap_fault.map \
    --case stack_guard laix/build/acceptance/stack_guard.img laix/build/acceptance/stack_guard.map \
    --case null_call laix/build/acceptance/null_call.img laix/build/acceptance/null_call.map \
    --case text_write laix/build/acceptance/text_write.img laix/build/acceptance/text_write.map \
    --case data_exec laix/build/acceptance/data_exec.img laix/build/acceptance/data_exec.map \
    --case stack_overflow laix/build/acceptance/stack_overflow.img laix/build/acceptance/stack_overflow.map \
    --log-dir laix/build/acceptance

python3 -B laix/tests/probe_boot.py \
    laix/build/acceptance/trap.img laix/build/acceptance/trap.map

python3 -B -m unittest discover -s laix/tests -p 'test_*.py'
```

Для `probe_boot.py` нужны локальные сокеты: monitor слушает только
`127.0.0.1` на свободном порту и завершается вместе с тестовым эмулятором.
Все runner и probe работают с копиями готовых образов и не собирают код.

| Артефакт | SHA-256 |
| --- | --- |
| `bin/wrm081632` | `ba94ae858855550779eecf83e3fe4502cfc835f4f857a338da66e38f79597907` |
| `bin/firmware.rom` | `6693e6349d322f516b61b6954c60a7ed3148e1f64e82d25031c0332f6179846f` |
| `trap.img` | `08148849419f246fb3c794fdbd6992fa48126cc4d35fcd73a9e0af2221316772` |
| `trap_fault.img` | `ee11e88460aeec92c73250f61e257699d95bb0cf5ed555a1c606a7e6b4ec5f00` |
| `stack_guard.img` | `deecbaa6f6ea6b38120982035d317c1f388c34c5877fff68f69fe456af6badc7` |
