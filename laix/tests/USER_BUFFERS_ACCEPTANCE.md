# Приёмка пользовательских буферов, 2026-10-04

CPU эмулятора WRM на Darwin arm64 выполнил 9 сценариев, 18 вызовов
`copyFromUser/copyToUser`. Пункт о границе страницы, NULL, supervisor-буфере
и переполнении закрыт. Все функции вошли и вернулись при STATUS=`0x10`
(EXL=1, UM/IE=0), сохранив kernel SP, PTBR, FCSR и callee-saved GPR.
Недопустимые буферы вернули `FFFFFFF2` (`-EFAULT`, -14) без частичной записи.
CPU после всех проверок дошёл до штатного HLT, exit эмулятора 0;
panic и double fault отсутствуют.

## Подготовка и метод

Предыдущий готовый образ не содержал функций копирования. После явного
разрешения пользователя на исключение из запрета сборки в `AGENTS.md`
выполнена одна сборка `./laix/build.sh`. Эмулятор и ROM не пересобирались.
CPU-проба `probe_user_buffers_cpu.py` сама ничего не собирает и работает
на временной копии диска; SHA-256 исходных артефактов проверены после прогона.

Проба исполняет настоящие функции копирования из обновлённого образа.
Kernel API создаёт каталог и два RWU-отображения по обе стороны границы
каталога страниц. User-кадры разделены отдельным физическим кадром.
Копирование начинается за три байта до конца первой страницы, длина 11,
kernel-буфер также невыровнен. Сверяются реальные байты RAM и соседние
байты; отрицательные случаи сравнивают полностью оба user-кадра и
kernel-буфер до/после вызова.

Для EXL=1 CPU `memcpy` копирует четыре существующие инструкции из образа
в выделенный кадр до выдачи RXU: `MTCR STATUS,r10`, `JALR r0,r12,0`,
`MTCR STATUS,r0`, `BREAK`. Сохранённый IRET-кадр задаёт аргументы функции,
EXL в r10, её адрес в r12 и RA на инструкцию снятия EXL. Monitor сверяет
аппаратный STATUS на входе функции и после её возврата. BREAK bridge
исполняется только после снятия EXL; recoverable faults не используются.
Новые инструкции не генерируются, код функций копирования не изменяется.

Нормальные отображения меняются только исполняемым MMU API. Для отдельного
отрицательного случая monitor снимает только U в PTE второй user-страницы
временной машины, затем CPU исполняет `FENCE/TLBI.ALL`. Настоящий supervisor
`memcpy` читает этот же VA успешно. User-копирование отвергает весь диапазон
из-за отсутствия U на поздней странице. PTE восстановлен и CPU снова
инвалидирует TLB. Это контролируемая fixture прав, не обход MMU API в ядре.

## Результаты

| Сценарий | Буфер | copyFromUser | copyToUser |
| --- | --- | --- | --- |
| `boundary_valid` | 11 байт, две RWU-страницы, несмежные кадры | 0, точные байты | 0, точные байты |
| `boundary_unmapped` | последний байт первой страницы и первый байт снятой второй | -EFAULT | -EFAULT |
| `boundary_readonly` | первая RWU, вторая RO/U | 0 | -EFAULT |
| `boundary_supervisor_leaf` | первая RWU, у второй снят U; supervisor-чтение успешно | -EFAULT | -EFAULT |
| `null` | address=0, length=1 | -EFAULT | -EFAULT |
| `supervisor` | физический supervisor RW-алиас user-кадра | -EFAULT | -EFAULT |
| `length_overflow` | address=`403FF000`, length=`FFFFFFFF` | -EFAULT | -EFAULT |
| `address_wrap` | address=`FFFFFFFC`, length=8 | -EFAULT | -EFAULT |
| `user_end` | последний user-байт, length=2 | -EFAULT | -EFAULT |

Проверяются внутренние API ядра при EXL=1; нового буферного syscall нет.
После этой проверки также повторно прошли все 11 сценариев Task, user
syscall/exit/fault и supervisor-регрессии на том же новом образе:
[приёмка user-задачи](USER_ACCEPTANCE.md). Все 132 теста исходников и
инструментов прошли без дополнительных сборок.

## Воспроизведение и артефакты

```sh
python3 -B laix/tests/probe_user_buffers_cpu.py laix/build/laix.img laix/build/laix.map
python3 -B laix/tests/probe_user_cpu.py laix/build/laix.img laix/build/laix.map
python3 -B -m unittest discover -s laix/tests -p 'test_*.py'
```

Логи monitor/UART/эмулятора, частичные результаты и итоговый `results.json`
лежат в `laix/build/acceptance/user_buffers_cpu/` (вне Git). Итоговый отчёт:
`complete=true`, `exl_verified=true`, `no_double_fault=true`, `exit_code=0`.
При отсутствии функций в карте probe возвращает exit 2 и не запускает CPU.

| Артефакт | SHA-256 |
| --- | --- |
| `laix/build/laix.img` | `c6e2f3f454600cbc96de899281d002f7f81ea69717c3c062fea027bcec340ef3` |
| `laix/build/laix.map` | `2846b89283b6abe28089d758d81ca3673e985a9e11543738bf2a350c8f10bc81` |
| `bin/wrm081632` | `a38d4d6b60fd24df495f9a2af0b2f5409d1de6eccabc64f4abd26735a5cf96dd` |
| `bin/firmware.rom` | `6693e6349d322f516b61b6954c60a7ed3148e1f64e82d25031c0332f6179846f` |
