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
