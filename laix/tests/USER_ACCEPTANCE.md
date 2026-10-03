# Приёмка user-задачи и syscall, 2026-10-04

На Darwin arm64 выполнены 11 CPU-сценариев на готовом `laix/build/laix.img`
с существующими `bin/wrm081632` и `bin/firmware.rom`. После явного разрешения
пользователя образ собран один раз для приёмки функций копирования, затем
эти 11 сценариев повторно пройдены на том же обновлённом образе.
Эмулятор и ROM не пересобирались; CPU-проба сама не собирает код.
CPU здесь — CPU эмулятора WRM.
Исходные файлы образа, карты, эмулятора и ROM сохранили SHA-256 после прогона.

## Метод и границы проверки

`probe_user_cpu.py` запускает отдельную временную машину для каждого случая.
`natural` загружает полный исходный диск, включая шрифт: исходный `main`
выполняет `kernelInit`, консоль, `taskPrepare` и `taskStart`. Monitor только
останавливает CPU и читает регистры/память. Задача выполняет собственный blob:
запись/чтение user-стека, запись маркера в данные, вывод `U\n`, `exit(0)`.

Остальные сценарии исполняют готовые kernel API через сохранённые IRET-кадры.
Настоящий `taskPrepare` выделяет задачу; её начальные GPR/EPC/FCSR меняются
как fixture-данные до настоящего `taskStart`. Для повторных syscall и
привилегированной инструкции выделяется дополнительный user-кадр. CPU
`memcpy` копирует существующие инструкции из образа до `mapPage(RXU)`:
восемь готовых слов SYSCALL и существующую последовательность exit либо
готовую `MTCR PTBR,r10`. Новые инструкции не генерируются. Таблицы страниц
меняет только исполняемый MMU API; исходные executable-байты не изменяются.

На входе user-инструкций STATUS=`0x0C`: UM=1, EXL/IE=0; PUM сохраняется
после IRET. На входе trap STATUS=`0x18`: EXL/PUM=1, UM/IE=0. Для каждого
возвращающего syscall проверены аппаратные регистры, полный TrapFrame,
копия контекста в TCB и аппаратные регистры после IRET. Сверяются все GPR,
включая tp/r28, sp/r30 и ra/r31, FCSR и PTBR. Returning syscall изменяет
только r1 и EPC+4; следующая инструкция выполняется в UM.

User TrapFrame располагается по `0x93F60` на kernel-стеке задачи
`[0x92000, 0x94000)`, независимо от user SP. При exit/fault IRET переводит
CPU на пустой boot-стек с SP=`0x90000`, STATUS/FCSR=0, нулевыми остальными
GPR и kernel PTBR=`0x9C001`. До этого перехода каталог и все user-кадры
ещё имеют ссылки. После `taskReap` они освобождены; каталог и ledger TCB
обнулены. Терминальный user-контекст сохранён. User-сценарии завершаются
HLT в kernel continuation, exit эмулятора 0, без panic/double fault.

## Результаты

| Сценарий | Подтверждение | Завершение |
| --- | --- | --- |
| `natural` | исходный main и blob, UM=1, маркеры стека/данных, `U\n`, два debug syscall | EXITED, code=0 |
| `registers` | восемь последовательных неизвестных syscall; все GPR/FCSR сохранены, r1=`FFFFFFDA` | EXITED, code=0 |
| `sp_zero` | тот же цикл при SP=0 | EXITED, code=0 |
| `sp_unaligned` | тот же цикл при SP=`BFFFFFFD` | EXITED, code=0 |
| `sp_unmapped` | тот же цикл при SP=`BFFFE000` в guard | EXITED, code=0 |
| `kernel_read` | LW из supervisor boot info: CAUSE=9, BADADDR=`1000`, EPC=`4000000C` | FAULTED, code=9 |
| `kernel_write` | SW в supervisor boot info: CAUSE=10, BADADDR=`1000`, EPC=`40000014`; слово не изменилось | FAULTED, code=10 |
| `nx` | fetch из RWU-данных со словом HLT: CAUSE=8, EPC=BADADDR=`40001000` | FAULTED, code=8 |
| `privileged` | MTCR PTBR в UM: CAUSE=11, EPC=`40002000`, BADADDR=opcode `00194005`; PTBR не изменён | FAULTED, code=11 |
| `supervisor_fault` | LW по `1001`: CAUSE=3, EPC=`1A744`; полный supervisor panic dump | exit 254 |
| `supervisor_guard` | SW в kernel guard `8D000`: CAUSE=10, EPC=`1A748`; полный supervisor panic dump | exit 254 |

В `natural` также прошли четыре supervisor self-test trap первого этапа:
builtin BREAK, seeded BREAK, seeded SYSCALL и builtin SYSCALL. Monitor
сравнил GPR/FCSR до/после каждого IRET и EPC+4; UART подтвердил завершение
самопроверок. Две дополнительные supervisor-пробы выполнены после подготовки
Task и проверяют политику panic, полный dump и сохранённый аппаратный контекст.

## Пользовательские буферы

Обновлённый образ содержит `copyFromUser`, `copyToUser`, `mmuUserBufferValid`.
Граница страницы, NULL, supervisor-буфер, отсутствие U/W на поздней странице
и переполнение подтверждены отдельным runner при EXL=1:
[USER_BUFFERS_ACCEPTANCE.md](USER_BUFFERS_ACCEPTANCE.md).
В `user_cpu/results.json` поле `buffer_cpu_check.complete=false` означает,
что эти 11 сценариев не вызывают функции копирования; `missing_symbols=[]`
и `runner=probe_user_buffers_cpu.py` указывают на отдельную проверку.
Её результат в `user_buffers_cpu/results.json` — `complete=true`.

## Воспроизведение и артефакты

```sh
python3 -B laix/tests/probe_user_cpu.py laix/build/laix.img laix/build/laix.map
```

Для отдельных сценариев: `--case sp_zero --case privileged`.
UART, monitor transcript, вывод эмулятора и `results.json` находятся в
`laix/build/acceptance/user_cpu/` (вне Git). Runner сохраняет логи также
при ошибке и записывает завершённые случаи до начала следующего.

Все 132 теста исходников и инструментов прошли без дополнительных сборок:

```sh
python3 -B -m unittest discover -s laix/tests -p 'test_*.py'
```

`test_user_cpu_probe.py` проверяет, что oracle отвергает изменённые GPR,
FCSR/PTBR/STATUS, неверные поля TrapFrame/стек и повтор или пропуск syscall.

| Артефакт | SHA-256 |
| --- | --- |
| `laix/build/laix.img` | `c6e2f3f454600cbc96de899281d002f7f81ea69717c3c062fea027bcec340ef3` |
| `laix/build/laix.map` | `2846b89283b6abe28089d758d81ca3673e985a9e11543738bf2a350c8f10bc81` |
| `bin/wrm081632` | `a38d4d6b60fd24df495f9a2af0b2f5409d1de6eccabc64f4abd26735a5cf96dd` |
| `bin/firmware.rom` | `6693e6349d322f516b61b6954c60a7ed3148e1f64e82d25031c0332f6179846f` |
