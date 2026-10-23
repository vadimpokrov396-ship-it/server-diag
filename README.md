# server-diag

Скрипты диагностики сервера. Они **только читают** систему и ничего не меняют.
Наверху отчёта идёт список найденных проблем: 🔴 серьёзные, 🟡 на заметку. Полный отчёт сохраняется в файл `diag_*.txt` в текущей папке.

## 1. Linux-сервер (рабочий или в rescue)

```bash
curl -fsSL https://raw.githubusercontent.com/vadimpokrov396-ship-it/server-diag/main/diag_linux.sh | sudo bash
```

Что проверяет:
- нагрузку на процессор, температуру и память, в том числе нехватку памяти (OOM);
- место на дисках и inode, разделы, перешедшие в режим «только чтение»;
- SMART: битые сектора и износ NVMe, ошибки ввода-вывода в журнале ядра;
- RAID (mdadm, ZFS);
- зависания и падения: загрузки, после которых не было штатного выключения, kernel panic, soft lockup, ошибки железа MCE/EDAC, перегрев;
- упавшие службы и процессы, зависшие на диске;
- сеть, DNS и выход в интернет;
- безопасность: подбор паролей SSH, лишние пользователи с uid 0, обновления.

Занимает ~10–30 секунд.

## 2. Windows-сервер, загруженный в Linux rescue (Hetzner / OVH / любой live-Linux)

```bash
curl -fsSL https://raw.githubusercontent.com/vadimpokrov396-ship-it/server-diag/main/diag_windows_rescue.sh | sudo bash
```

Разделы Windows подключаются **только на чтение**. Что проверяет:
- SMART и RAID;
- разделы NTFS: флаг «с ошибками» (dirty), заполненность, BitLocker;
- синие экраны: минидампы и MEMORY.DMP;
- незавершённые обновления (pending.xml), отчёт автовосстановления (SrtTrail.txt);
- журналы событий Windows за 30 дней:
  - внезапные выключения (Kernel-Power 41, 6008);
  - BugCheck;
  - ошибки дисков (7/11/51/153/129);
  - повреждения NTFS (55/98);
  - аппаратные ошибки WHEA;
  - нехватку памяти;
  - падения служб и программ.

Занимает 3–10 минут: дольше всего разбираются журналы событий. Для разбора журналов скрипт сам ставит в rescue-систему `python-evtx`, поэтому нужен интернет. Срок можно поменять: `DAYS=60`.

```bash
curl -fsSL https://raw.githubusercontent.com/vadimpokrov396-ship-it/server-diag/main/diag_windows_rescue.sh | sudo DAYS=60 bash
```
