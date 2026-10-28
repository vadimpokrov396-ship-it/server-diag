# server-diag — диагностика сервера за минуту (Linux и Windows)

Скрипт проверяет здоровье сервера или компьютера и **простыми словами** говорит, что не так: светофор по шести областям, «Главная причина» и «Что сделать: 1) 2) 3)». **Только чтение** — ничего не устанавливает, не перезапускает и не меняет настройки.

[English version below ↓](#english)

📖 Статья для начинающих: [docs/ARTICLE_RU.md](docs/ARTICLE_RU.md) · [на сайте serverrental.store](https://serverrental.store/Server-diag:_%D0%B4%D0%B8%D0%B0%D0%B3%D0%BD%D0%BE%D1%81%D1%82%D0%B8%D0%BA%D0%B0_%D1%81%D0%B5%D1%80%D0%B2%D0%B5%D1%80%D0%B0_Linux_%D0%B8_Windows_%D0%B7%D0%B0_%D0%BC%D0%B8%D0%BD%D1%83%D1%82%D1%83_%D0%BF%D1%80%D0%BE%D1%81%D1%82%D1%8B%D0%BC%D0%B8_%D1%81%D0%BB%D0%BE%D0%B2%D0%B0%D0%BC%D0%B8)

---

## Быстрый старт

### Linux — одна команда

Подключитесь к серверу по SSH и вставьте:

```bash
curl -fsSL https://raw.githubusercontent.com/vadimpokrov396-ship-it/server-diag/main/server-diag.sh | sudo bash
```

Через 5–15 секунд на экране будет вердикт, а в текущей папке появится HTML-отчёт `server-diag-report-<сервер>-<дата>.html`.

Если не любите `curl | bash`: скачайте файл, посмотрите его и запустите.

```bash
wget https://github.com/vadimpokrov396-ship-it/server-diag/releases/latest/download/server-diag-linux.sh
less server-diag-linux.sh          # можно прочитать, что он делает
sudo bash server-diag-linux.sh
```

### Windows — скачать, распаковать, дважды щёлкнуть

1. Скачайте архив **[server-diag-windows.zip](https://github.com/vadimpokrov396-ship-it/server-diag/releases/latest/download/server-diag-windows.zip)**.
2. Распакуйте его: правой кнопкой по архиву → «Извлечь всё…».
3. Дважды щёлкните **`ЗАПУСТИ-МЕНЯ.bat`** (или `RUN-ME.bat`) и в окне запроса прав нажмите «Да».

Через 20–60 секунд в окне появится вердикт, а отчёт откроется в браузере. Копия отчёта сохраняется на Рабочем столе.
Если нажать «Нет», выполнится сокращённая проверка без прав администратора: часть пунктов будет пропущена, и отчёт об этом скажет.

---

## Что вы увидите

```text
 ИТОГ: 🟡 РАБОТАЕТ, НО ЕСТЬ НА ЧТО ОБРАТИТЬ ВНИМАНИЕ

 🟡 Диски                    Диск /dev/sda (CT240BX500SSD1): ошибки передачи данных по кабелю — 1298 (кабель или разъём)
 🟢 Память (ОЗУ)             норма — доступно 144 ГБ из 220 ГБ (65%), нехватки памяти (OOM) за 7 дней не было
 🟢 Процессор и температура  норма — нагрузка 0.05 на 64 ядер (CPU занят 0%), температура CPU 43°C
 🟡 Сбои и перезагрузки      Сервер выключался аварийно (без нормального завершения работы): 1 раз за 30 дней — 21.10.2026 07:43
 🟢 Службы и программы       норма — упавших служб нет (работает: 38)
 🟢 Сеть и время             норма — интернет и DNS работают, ping 2 ms, часы точные (±1 с)

 ГЛАВНАЯ ПРИЧИНА  (уверенность: средняя)
   🟡 Сервер выключался аварийно (без нормального завершения работы): 1 раз за 30 дней — 21.10.2026 07:43
   Журнал оборвался без записи о выключении. Так бывает при пропадании питания, принудительной перезагрузке
   у хостера, полном зависании системы или аппаратном сбое.

 ЧТО СДЕЛАТЬ
   1) Спросите хостера, не было ли в это время работ, сбоя питания или перезагрузки по их инициативе
   2) Посмотрите другие пункты отчёта: перегрев, ошибки памяти/дисков, нехватка памяти — частые причины зависаний
   3) Посмотрите, что было перед сбоем: sudo journalctl -b -1 -n 100
```

Ниже на экране идут «Ещё замечено», «К сведению / не проверено» и «Технические подробности». Полный HTML-отчёт содержит то же самое, а также сырой вывод всех команд для специалиста.

Настоящие отчёты (имена серверов и IP заменены) лежат в папке [`examples/`](examples/):

| Пример | Что нашёл скрипт |
|---|---|
| [linux-physical-server-ru.txt](examples/linux-physical-server-ru.txt) | физический сервер Proxmox: ошибки SATA-кабеля (UDMA CRC) и аварийное выключение |
| [linux-vm-unclean-shutdowns-ru.txt](examples/linux-vm-unclean-shutdowns-ru.txt) | виртуальная машина: 2 аварийных выключения за месяц → 🔴 |
| [linux-vps-ru.txt](examples/linux-vps-ru.txt) · [en](examples/linux-vps-en.txt) · [HTML](examples/linux-vps-report-ru.html) | VPS: служба падает и перезапускается 45 000 раз, журнал хранит всего сутки |
| [windows-ru.txt](examples/windows-ru.txt) · [en](examples/windows-en.txt) · [HTML ru](examples/windows-report-ru.html) · [HTML en](examples/windows-report-en.html) | Windows Server 2025: нехватка памяти 14 раз за неделю, в те же минуты падали программы |

## Что значат цвета

| Цвет | Значит | Что делать |
|---|---|---|
| 🟢 норма | В этой области проблем не найдено. Рядом показан факт, на котором основан вывод, например «доступно 7.8 ГБ из 11 ГБ». | Ничего. |
| 🟡 внимание | Сервер работает, но есть риск или первые признаки проблемы. | Разберитесь в ближайшие дни. |
| 🔴 проблема | Серьёзная неисправность, которая уже мешает работе или вот-вот помешает. | Займитесь сейчас и начните с «Что сделать». |

**Главная причина** — самая важная находка. Находки ранжируются по тяжести: например, отказ диска важнее медленного диска, а нехватка памяти важнее падений программ, которые она вызвала. **Уверенность** показывает, насколько однозначен вывод: «высокая» означает прямое доказательство (SMART, журнал ядра, счётчик), «средняя» — косвенное (например, журнал оборвался без записи о выключении, но точная причина неизвестна).

## Что проверяется

| Область | Linux | Windows |
|---|---|---|
| **Диски** | заполненность и inode; разделы, переключившиеся в «только чтение»; ошибки файловой системы и ввода-вывода в журнале ядра; SMART (сбойные и нечитаемые сектора, износ и ошибки NVMe, ошибки кабеля, температура); RAID mdadm, ZFS, LVM-thin; медленный диск (PSI, iowait) | свободное место; здоровье дисков (Get-PhysicalDisk, счётчики надёжности: неисправимые ошибки, износ, температура; прогноз отказа SMART); состояние томов и Storage Spaces; события диска и NTFS (7, 11, 51, 129, 153, 55, 98); задержка диска |
| **Память** | свободная память; активная работа swap (thrashing); OOM killer — что именно и когда убивалось; лимиты cgroup; ошибки ECC (EDAC) | свободная память и commit; нехватка памяти (событие 2004) с виновниками; активная подкачка с диска |
| **Процессор и температура** | загрузка за замер, load average; **steal** на VPS (хостер перегружен); перегрев и троттлинг; аппаратные ошибки MCE | загрузка, очередь; температура ACPI (где доступна); ограничение частоты прошивкой; схема «Экономия энергии»; аппаратные ошибки WHEA |
| **Сбои и перезагрузки** | аварийные выключения (загрузки, оборвавшиеся без штатного завершения); kernel panic (pstore, kdump); Oops/BUG; soft lockup и RCU stall; зависшие задачи; частые перезагрузки; сколько дней хранит журнал | синие экраны с расшифровкой кода (драйвер, память, диск, железо); минидампы; внезапные выключения (41 Kernel-Power, 6008); кто и зачем перезагружал (1074) |
| **Службы и программы** | упавшие службы systemd, важные отделяются от безвредных; службы, которые бесконечно перезапускаются; segfault и core dump; контейнеры Docker в рестарт-цикле | автоматические службы, остановленные с ошибкой; падения служб (7031, 7034); падения и зависания программ (1000, 1002); неудачные обновления Windows; ожидание перезагрузки; Defender: базы и нагрузка на CPU |
| **Сеть и время** | шлюз, интернет, DNS, IPv6, потери пакетов, MTU, ошибки и дуплекс сетевой карты, переполнение conntrack; точность часов и синхронизация NTP | шлюз, интернет, DNS, потери пакетов, MTU, ошибки сетевой карты; точность часов |

Пороги подобраны так, чтобы не пугать зря. Например, диск на 2 ТБ, заполненный на 86%, считается нормой: свободно ещё 280 ГБ. Занятый swap при большом запасе свободной памяти тоже не тревога. А на VPS отсутствие SMART — это норма, а не проблема.

## Безопасно: только чтение

- Скрипт **ничего не меняет**: не ставит пакеты, не перезапускает службы, не трогает настройки, файлы и автозагрузку.
- Он только читает файлы в `/proc` и `/sys`, журналы и вывод команд вроде `df`, `smartctl -a`, `journalctl`, `systemctl show`. В Windows это журналы событий, WMI/CIM, счётчики дисков и чтение реестра.
- Единственный файл, который он создаёт, — HTML-отчёт. Временные файлы в `/tmp` удаляются при выходе.
- Скрипт никуда не отправляет ваши данные: отчёт остаётся на сервере. Для проверки сети и часов он открывает TCP-соединения к 1.1.1.1, 8.8.8.8 и 77.88.8.8 (порт 443), делает DNS-запросы, ping и запрос заголовков к google.com, cloudflare.com или ya.ru (в Windows также к серверу проверки связи Microsoft), чтобы сверить время.
- В Windows параметр `-ExecutionPolicy Bypass` действует только на этот запуск PowerShell, системная политика не меняется.
- Права администратора нужны, чтобы прочитать SMART и все журналы. Без них проверка всё равно пройдёт и честно скажет, что не удалось проверить.
- Проверка безопасности (пароли, уязвимости, открытые порты) в задачи этой версии не входит: здесь только здоровье, производительность и стабильность.

Не верьте на слово: оба скрипта — обычный текст, их можно прочитать перед запуском.

## Параметры

**Linux:** `sudo bash server-diag.sh [--full] [--lang en] [--out ПАПКА] [--no-html] [--no-color]`

- `--full` — медленнее и глубже: замер 10 с вместо 2 с, до 15 прошлых загрузок, ошибки журнала за сутки.
- `--lang en` — вердикт на английском.
- `--out /путь` — куда сохранить отчёт.

Те же параметры через curl: `curl -fsSL …/server-diag.sh | sudo bash -s -- --full --lang en`

**Windows:** `powershell -ExecutionPolicy Bypass -File server-diag.ps1 [-Lang ru|en|auto] [-Days 30] [-OutDir C:\путь] [-NoElevate] [-NoHtml]`
`ЗАПУСТИ-МЕНЯ.bat` запускает проверку на русском, `RUN-ME.bat` — на языке Windows.

## Вопросы и ответы

**Сколько это занимает?** На Linux обычно 5–15 секунд, с `--full` — около 15–30. На Windows 20–60 секунд.

**Обязательно ли нужен root или администратор?** Нет, но с ними проверка полнее. Без прав не будут проверены SMART и часть журналов, и отчёт прямо об этом напишет.

**Windows пишет «Система Windows защитила ваш компьютер».** Так Windows реагирует на любой скачанный `.bat`. Нажмите «Подробнее» → «Выполнить в любом случае». Скрипт не подписан, но его можно открыть Блокнотом и прочитать.

**Окно мелькнуло и закрылось.** Запустите вручную. Откройте PowerShell в папке со скриптом и выполните `powershell -ExecutionPolicy Bypass -File .\server-diag.ps1 -Pause`. Если запуск PowerShell запрещён групповой политикой, обратитесь к администратору домена.

**Где отчёт и как отправить его специалисту?** На Linux — в папке, где вы запускали команду (путь написан в конце). Скачайте его через WinSCP или FileZilla, либо командой `scp`. На Windows — на Рабочем столе. Отправьте HTML-файл целиком: это один файл без внешних зависимостей.

**Всё зелёное, а сервер тормозит.** Запустите проверку прямо в момент тормозов: загрузка процессора, памяти и диска замеряется «здесь и сейчас». Сравните с отчётом, снятым в спокойное время.

**Почему на VPS не проверяется SMART и температура?** Виртуальный сервер не видит физические диски и датчики. За них отвечает хостер, и это нормально. Зато на VPS проверяется **steal** — сколько процессорного времени у вас «отбирают» соседи по физическому серверу.

**Это антивирус или проверка безопасности?** Нет. Это диагностика здоровья: диски, память, процессор, сбои, службы, сеть.

**Сервер вообще не загружается.** Используйте rescue-режим хостера и скрипты из раздела ниже.

## Если сервер не загружается (rescue-режим)

Эти скрипты в этой версии не менялись:

- [`diag_windows_rescue.sh`](diag_windows_rescue.sh) + [`win_evtx_report.py`](win_evtx_report.py) — для Windows-сервера, загруженного в Linux rescue (Hetzner, OVH или любой live-Linux). Разделы Windows подключаются только на чтение. Скрипт смотрит SMART, флаг «dirty» NTFS, минидампы, незавершённые обновления и журналы событий за 30 дней (3–10 минут):

  ```bash
  curl -fsSL https://raw.githubusercontent.com/vadimpokrov396-ship-it/server-diag/main/diag_windows_rescue.sh | sudo bash
  ```

- [`diag_linux.sh`](diag_linux.sh) — прежняя версия Linux-проверки (v1) без вердикта, оставлена для совместимости.

---

<a id="english"></a>
# English

**server-diag** checks the health of a server or PC and explains in **plain words** what is wrong. You get a traffic light for six areas, the **main cause** and **what to do: 1) 2) 3)**. It is **read-only**: it installs nothing, restarts nothing and changes no settings.

📖 Beginner-friendly article: [docs/ARTICLE_EN.md](docs/ARTICLE_EN.md) · [on serverrental.store](https://serverrental.store/Server-diag:_diagnose_a_Linux_or_Windows_server_in_one_minute,_in_plain_words)

## Quick start

**Linux — one command** (SSH into the server):

```bash
curl -fsSL https://raw.githubusercontent.com/vadimpokrov396-ship-it/server-diag/main/server-diag.sh | sudo bash -s -- --lang en
```

Or download it first: `wget https://github.com/vadimpokrov396-ship-it/server-diag/releases/latest/download/server-diag-linux.sh && sudo bash server-diag-linux.sh --lang en`

**Windows — download, unzip, double-click:**

1. Download **[server-diag-windows.zip](https://github.com/vadimpokrov396-ship-it/server-diag/releases/latest/download/server-diag-windows.zip)**.
2. Unzip it (right-click → Extract All…).
3. Double-click **`RUN-ME.bat`** and click "Yes" in the permission prompt. The check runs in the language of your Windows.

The verdict appears in 20–60 seconds and the report opens in your browser; a copy is saved on the Desktop. If you click "No", a reduced check runs without admin rights.

## Reading the verdict

- 🟢 **OK** — no problems in this area; the fact behind the verdict is shown next to it.
- 🟡 **Warning** — it works, but there is a risk or an early sign of trouble; look into it soon.
- 🔴 **Problem** — a serious fault that already hurts or soon will; act now, starting with "What to do".

**Main cause** is the most important finding: root causes rank above their symptoms, so a failing disk beats a slow disk. **Confidence** is "high" when there is direct evidence (SMART, kernel log, a counter) and "medium" when the evidence is indirect.

## What is checked

- **Disks:** free space and inodes; read-only remounts; filesystem and I/O errors; SMART (pending/reallocated sectors, NVMe wear and media errors, cable CRC errors, temperature); mdadm, ZFS and LVM-thin; a slow disk (PSI, iowait). On Windows: storage reliability counters, SMART failure prediction, volume health, Storage Spaces, disk/NTFS events and disk latency.
- **Memory:** available RAM, swap thrashing, OOM-killer victims, cgroup limits, ECC/EDAC errors. On Windows: low-memory events (2004) with the culprits, commit charge and hard paging.
- **CPU & temperature:** load, **steal on VPS**, overheating and throttling, MCE. On Windows: WHEA errors, firmware throttling and the Power saver plan.
- **Crashes & reboots:** unclean shutdowns, kernel panics (pstore/kdump), Oops, lockups, hung tasks, and how far back the journal goes. On Windows: blue screens with the stop code explained, minidumps, Kernel-Power 41 / 6008, and who rebooted the machine and why.
- **Services & programs:** failed systemd units (important ones separated from harmless ones), restart loops, segfaults and core dumps, Docker restart loops. On Windows: auto-start services stopped with an error, service crashes, application crashes and hangs, failing Windows updates, pending reboot, Defender signatures and CPU use.
- **Network & time:** gateway, internet, DNS, IPv6, packet loss, MTU, NIC errors and duplex, conntrack table, clock accuracy and NTP sync.

Thresholds are tuned against false alarms: free space is judged in gigabytes as well as percent, used swap with plenty of free RAM is fine, and no SMART on a VPS is normal.

## Safe: read-only

The script only reads `/proc`, `/sys`, logs and the output of read-only commands. On Windows it reads event logs, WMI/CIM, storage counters and registry values. The only file it writes is the HTML report. It sends your data nowhere; the network checks are TCP connects to 1.1.1.1, 8.8.8.8 and 77.88.8.8 on port 443, DNS lookups, ping, and an HTTP HEAD request for the clock check. `-ExecutionPolicy Bypass` affects only that one PowerShell process. Without admin rights it still runs and tells you what it could not check. Security auditing is out of scope for this version.

## Options

- Linux: `--full` (deeper, ~15–30 s), `--lang en`, `--out DIR`, `--no-html`, `--no-color`.
- Windows: `-Lang ru|en|auto`, `-Days 30`, `-OutDir C:\path`, `-NoElevate`, `-NoHtml`.

## FAQ

- **"Windows protected your PC"?** Click "More info" → "Run anyway". The files are plain text, so you can read them first.
- **Where is the report?** On Linux it is in the folder you ran the command from; the path is printed at the end. On Windows it is on the Desktop. It is a single self-contained HTML file.
- **Everything is green but the server is slow?** Run the check while it is slow: CPU, memory and disk load are measured live.
- **The server does not boot?** Use rescue mode with [`diag_windows_rescue.sh`](diag_windows_rescue.sh) + [`win_evtx_report.py`](win_evtx_report.py) (Windows disk read-only from a Linux rescue system). [`diag_linux.sh`](diag_linux.sh) is the old v1 Linux check.

Real sample reports with masked names: [`examples/`](examples/).
