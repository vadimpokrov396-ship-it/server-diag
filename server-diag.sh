#!/usr/bin/env bash
# server-diag.sh — read-only health check of a Linux server with a plain-language verdict (Russian / English).
# Project: https://github.com/vadimpokrov396-ship-it/server-diag   (MIT license)
#
#   curl -fsSL https://raw.githubusercontent.com/vadimpokrov396-ship-it/server-diag/main/server-diag.sh | sudo bash
#   sudo bash server-diag.sh [--full] [--lang en] [--out DIR] [--no-html] [--no-color]
#
#   --full      slower, deeper checks (10 s sampling instead of 2 s, more boots, MTU test, coredumps, docker, journal errors)
#   --lang en   English verdict (default: Russian)
#   --out DIR   folder for the HTML report (default: the current folder)
#
# shellcheck disable=SC1111  # typographic quotes inside English UI strings are intentional
# SAFE: the script only READS — files in /proc and /sys, logs, and read-only commands (df, lsblk, smartctl -a,
# journalctl, systemctl show, ip, ping). It installs nothing, restarts nothing and changes no settings.
# The only file it creates is the HTML report server-diag-report-<host>-<date>.html (+ temp files, removed at exit).

main() {
VERSION=2.0
LNG=ru FULL=0 HTML=1 COLOR=auto OUTDIR=
while [ $# -gt 0 ]; do
  case $1 in
    --full) FULL=1 ;;
    --lang) LNG=${2:-ru}; shift ;;
    --lang=*) LNG=${1#*=} ;;
    --en|--english) LNG=en ;;
    --ru) LNG=ru ;;
    --out) OUTDIR=${2:-}; shift ;;
    --out=*) OUTDIR=${1#*=} ;;
    --no-html) HTML=0 ;;
    --no-color) COLOR=0 ;;
    -h|--help) printf '%s\n' "server-diag $VERSION — read-only Linux server health check" \
                 "usage: sudo bash server-diag.sh [--full] [--lang en|ru] [--out DIR] [--no-html] [--no-color]"; return 0 ;;
    *) printf 'unknown option: %s (see --help)\n' "$1" >&2; return 2 ;;
  esac
  shift
done
case $LNG in en*|EN*) LNG=en ;; *) LNG=ru ;; esac

export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"
# a UTF-8 locale for correct text width; command output stays in English (C) for stable parsing
if locale -a 2>/dev/null | grep -qiE '^c\.utf-?8$'; then export LC_ALL=C.UTF-8
elif locale -a 2>/dev/null | grep -qiE '^en_US\.utf-?8$'; then export LC_ALL=en_US.UTF-8
else export LC_ALL=C; fi
if [ "$COLOR" = auto ]; then if [ -t 1 ]; then COLOR=1; else COLOR=0; fi; fi
if [ "$COLOR" = 1 ]; then BO=$'\033[1m' DI=$'\033[2m' RE=$'\033[31m' YE=$'\033[33m' GR=$'\033[32m' NC=$'\033[0m'
else BO='' DI='' RE='' YE='' GR='' NC=''; fi

ROOT=0; [ "$(id -u)" = 0 ] && ROOT=1
TMP=$(mktemp -d "${TMPDIR:-/tmp}/server-diag.XXXXXX") || { echo "mktemp failed" >&2; return 1; }
trap 'rm -rf "$TMP"' EXIT
TECH=$TMP/tech KLOG=$TMP/klog
: > "$TECH"; : > "$KLOG"
FN=0; F_SEV=(); F_AREA=(); F_SC=(); F_CONF=(); F_T=(); F_WHY=(); F_DO=(); F_EV=()
declare -A OK=()
NOTES=(); LIMITS=()
GiB=1048576
T_START=$(date +%s)

say "$(L "server-diag $VERSION: проверяю сервер. Только чтение — ничего не меняю (обычно 10–30 секунд)…" \
         "server-diag $VERSION: checking the server. Read-only — nothing is changed (usually 10–30 seconds)…")"

# ------------------------------------------------------------------ system
HOST=$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname); HOST=${HOST%%.*}
OS=$(awk -F= '$1=="PRETTY_NAME"{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null); [ -n "$OS" ] || OS=$(uname -s)
KERNEL=$(uname -r)
CORES=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo); [ "${CORES:-0}" -gt 0 ] 2>/dev/null || CORES=1
CPU_MODEL=$(awk -F': *' '/^model name/{print $2; exit}' /proc/cpuinfo)
read -r UP_S _ < /proc/uptime; UP_S=${UP_S%.*}
NOW=$(date +%s); BOOT=$((NOW - UP_S))
MEM_T=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
VIRT=none
if has systemd-detect-virt; then VIRT=$(systemd-detect-virt 2>/dev/null); VIRT=${VIRT:-none}
elif grep -q '^flags.* hypervisor' /proc/cpuinfo 2>/dev/null; then VIRT=vm; fi
CONT=0
if has systemd-detect-virt && systemd-detect-virt -cq 2>/dev/null; then CONT=1
elif [ -f /.dockerenv ] || grep -qaE 'docker|lxc|kubepods' /proc/1/cgroup 2>/dev/null; then CONT=1; fi
IS_VM=0; if [ "$VIRT" != none ] || [ "$CONT" = 1 ]; then IS_VM=1; fi
HZ=$(getconf CLK_TCK 2>/dev/null || echo 100)
sec "System"
run "uname -a; grep PRETTY_NAME /etc/os-release; uptime; echo virtualization: $VIRT container: $CONT"
run "lscpu 2>/dev/null | head -20"

[ "$ROOT" = 1 ] || limit "$(L "Запущено без прав root: здоровье дисков (SMART), часть журналов и RAID не проверены. Для полной проверки: sudo bash server-diag.sh" \
                              "Not running as root: disk health (SMART), some logs and RAID were not checked. For a full check: sudo bash server-diag.sh")"
[ "$CONT" = 1 ] && limit "$(L "Скрипт запущен внутри контейнера: диски, температура и ядро принадлежат хост-машине и здесь почти не видны." \
                               "Running inside a container: disks, temperature and the kernel belong to the host and are mostly invisible here.")"

# CPU / swap / process sample in a QUIET window (the script itself does nothing meanwhile): 2 s, 10 s with --full
SAMPLE=2; [ "$FULL" = 1 ] && SAMPLE=10
read -r C1B _ C1W C1S C1T < <(cpu_snap)
read -r S1I S1O < <(swp_snap)
dproc > "$TMP/d1"; proc_snap > "$TMP/p1"
T1=$(date +%s%N)
sleep "$SAMPLE"
read -r C2B _ C2W C2S C2T < <(cpu_snap)
read -r S2I S2O < <(swp_snap)
dproc > "$TMP/d2"; proc_snap > "$TMP/p2"
DT=$(( ($(date +%s%N) - T1) / 1000000 )); [ "$DT" -gt 0 ] || DT=1

# ------------------------------------------------------------------ kernel log (read once)
# current boot: dmesg ring buffer or the journal, whichever is longer; previous boots of 30 days: journal only
if ! dmesg --time-format iso > "$TMP/dm" 2>/dev/null; then
  dmesg 2>/dev/null | sed "s/^/$(date -d "@$BOOT" +%Y-%m-%dT%H:%M:%S) /" > "$TMP/dm"
fi
J_FIRST='' J_PERSIST=0
if has journalctl; then
  timeout 25 journalctl _TRANSPORT=kernel -q --no-pager -o short-iso --since "$(date -d '-30 days' '+%Y-%m-%d %H:%M:%S')" \
    --until "$(date -d "@$BOOT" '+%Y-%m-%d %H:%M:%S')" > "$KLOG" 2>/dev/null
  timeout 20 journalctl -k -b 0 -q --no-pager -o short-iso > "$TMP/jk0" 2>/dev/null
  if [ "$(wc -l < "$TMP/jk0")" -gt "$(wc -l < "$TMP/dm")" ]; then cat "$TMP/jk0" >> "$KLOG"; else cat "$TMP/dm" >> "$KLOG"; fi
  J_FIRST=$(timeout 10 journalctl -q --no-pager -o short-iso 2>/dev/null | head -n 1 | cut -c1-19)
  ls /var/log/journal/*/*.journal* >/dev/null 2>&1 && J_PERSIST=1
else
  cat "$TMP/dm" > "$KLOG"
fi
CUT1=$(date -d '-1 day' +%Y-%m-%dT%H:%M:%S); CUT7=$(date -d '-7 days' +%Y-%m-%dT%H:%M:%S)
[ -s "$KLOG" ] || limit "$(L "Журнал ядра недоступен (нужен root) — аппаратные ошибки, OOM и сбои дисков в логах не проверены." \
                             "The kernel log is not readable (root needed) — hardware errors, OOM and disk errors in logs were not checked.")"

# ================================================================== DISKS
say "$(L "• диски: место, inode, ошибки, SMART, RAID" "• disks: space, inodes, errors, SMART, RAID")"
DFX=(-x tmpfs -x devtmpfs -x squashfs -x overlay -x iso9660 -x udf -x ramfs -x efivarfs -x nsfs)
sec "Disks: space / inodes / block devices"
run "df -hTl -x tmpfs -x devtmpfs -x squashfs -x overlay"
run "df -hiTl -x tmpfs -x devtmpfs -x squashfs -x overlay"
run "lsblk -o NAME,SIZE,TYPE,FSTYPE,MODEL,MOUNTPOINT"
MAXP=0 MAXM=/ MAXA=0 seen=' '
while read -r dev typ size used avail pct mnt; do
  case $typ in fuse*) continue ;; esac
  case "$seen" in *" $dev "*) continue ;; esac; seen="$seen$dev "
  [ "$pct" -gt "$MAXP" ] && { MAXP=$pct; MAXM=$mnt; MAXA=$avail; }
  sev=0
  if [ "$size" -lt $((3*GiB)) ]; then
    if [ "$pct" -ge 97 ]; then sev=2; elif [ "$pct" -ge 90 ]; then sev=1; fi
  elif [ "$avail" -lt "$GiB" ] || [ "$pct" -ge 98 ] || { [ "$pct" -ge 95 ] && [ "$avail" -lt $((20*GiB)) ]; }; then sev=2
  elif { [ "$pct" -ge 90 ] && [ "$avail" -lt $((50*GiB)) ]; } || { [ "$pct" -ge 85 ] && [ "$avail" -lt $((5*GiB)) ]; }; then sev=1; fi
  [ "$sev" = 0 ] && continue
  sc=56; [ "$sev" = 2 ] && sc=90; case $mnt in /|/var|/var/*|/home|/srv) sc=$((sc+4)) ;; esac
  ev="df: $dev ($typ) on $mnt: size $(human "$size"), used $(human "$used"), free $(human "$avail"), $pct%"
  if [ "$mnt" = /boot ]; then
    add "$sev" disk "$sc" h "$(L "Раздел /boot почти заполнен: занято $pct%" "The /boot partition is almost full: $pct% used")" \
      "$(L "В /boot лежат ядра Linux. Когда он заполнен, обновление ядра ломается, и после обновления сервер может не загрузиться." \
           "/boot holds the Linux kernels. When it is full, kernel updates fail and the server may not boot after an update.")" \
      "$(L "Удалите старые ядра: sudo apt autoremove --purge (Debian/Ubuntu) или sudo dnf remove --oldinstallonly (RHEL/Alma/Rocky)
Проверьте, что место освободилось: df -h /boot
Не удаляйте файлы из /boot вручную — только через менеджер пакетов" \
           "Remove old kernels: sudo apt autoremove --purge (Debian/Ubuntu) or sudo dnf remove --oldinstallonly (RHEL/Alma/Rocky)
Check that space was freed: df -h /boot
Do not delete files in /boot by hand — only via the package manager")" "$ev"
  else
    add "$sev" disk "$sc" h "$(L "Диск «$mnt» почти заполнен: занято $pct%, свободно $(human "$avail")" "Disk “$mnt” is almost full: $pct% used, $(human "$avail") free")" \
      "$(L "Когда место заканчивается, сайты и базы данных не могут записывать данные: появляются ошибки, падают службы, перестают писаться логи и бэкапы." \
           "When a disk runs out of space, websites and databases cannot write data: errors appear, services crash, logs and backups stop.")" \
      "$(L "Найдите, что занимает место: sudo du -xh --max-depth=2 $mnt 2>/dev/null | sort -h | tail -15
Удалите ненужное: старые бэкапы, архивы, большие логи. Журнал systemd можно ужать: sudo journalctl --vacuum-size=200M, кэш пакетов: sudo apt clean (или sudo dnf clean all)
Если удалять нечего — увеличьте диск у хостера или перенесите данные на другой диск" \
           "Find what takes the space: sudo du -xh --max-depth=2 $mnt 2>/dev/null | sort -h | tail -15
Delete what you do not need: old backups, archives, big logs. Shrink the systemd journal: sudo journalctl --vacuum-size=200M; package cache: sudo apt clean (or sudo dnf clean all)
If nothing can be deleted, enlarge the disk at your provider or move data to another disk")" "$ev"
  fi
done < <(timeout 15 df -PTkl "${DFX[@]}" 2>/dev/null | awk 'NR>1{p=$6; sub(/%/,"",p); m=$7; for(i=8;i<=NF;i++) m=m" "$i; if (p ~ /^[0-9]+$/ && $3 > 0) print $1, $2, $3, $4, $5, p, m}')
OK[disk]="$(L "занято не больше $MAXP% (самый заполненный: $MAXM, свободно $(human "$MAXA"))" "at most $MAXP% used (fullest: $MAXM, $(human "$MAXA") free)")"

while read -r dev typ itot ipct mnt; do
  [ "$ipct" -ge 90 ] || continue
  sev=1 sc=60; [ "$ipct" -ge 95 ] && { sev=2; sc=92; }
  add "$sev" disk "$sc" h "$(L "На диске «$mnt» заканчиваются inode: занято $ipct%" "Disk “$mnt” is running out of inodes: $ipct% used")" \
    "$(L "Inode — это «ячейки» для файлов. Когда они кончаются, новые файлы создать нельзя, даже если место есть. Обычно виноваты миллионы мелких файлов: кэш, сессии PHP, очередь почты." \
         "Inodes are “slots” for files. When they run out, no new files can be created even if there is free space. Usually millions of tiny files are to blame: cache, PHP sessions, a mail queue.")" \
    "$(L "Найдите папку с огромным числом файлов: sudo du --inodes -x $mnt 2>/dev/null | sort -n | tail -15
Удалите старые файлы кэша, сессий, писем в очереди (или настройте их автоочистку)
Если файлов действительно столько нужно — понадобится диск, отформатированный с большим числом inode" \
         "Find the folder with a huge number of files: sudo du --inodes -x $mnt 2>/dev/null | sort -n | tail -15
Delete old cache / session / mail-queue files (or set up automatic cleanup)
If you really need that many files, the disk must be re-formatted with more inodes")" "df -i: $dev ($typ) on $mnt: $itot inodes, $ipct% used"
done < <(timeout 15 df -PTil "${DFX[@]}" 2>/dev/null | awk 'NR>1{p=$6; sub(/%/,"",p); m=$7; for(i=8;i<=NF;i++) m=m" "$i; if (p ~ /^[0-9]+$/ && $3 > 0) print $1, $2, $3, p, m}')

ro=''
while read -r dev mnt typ opts _; do
  case $typ in ext2|ext3|ext4|xfs|btrfs|f2fs|jfs|reiserfs) ;; *) continue ;; esac
  case $dev in /dev/*) ;; *) continue ;; esac
  case ",$opts," in *,ro,*) ;; *) continue ;; esac
  case $mnt in /snap/*|/sysroot*|/usr|/media/*|/run/media/*|/boot/efi) continue ;; esac
  awk -v m="$mnt" '$1 !~ /^#/ && $2==m && $4 ~ /(^|,)ro(,|$)/{f=1} END{exit !f}' /etc/fstab 2>/dev/null && continue
  ro="$ro $mnt"
done < /proc/mounts
if [ -n "$ro" ]; then
  add 2 disk 95 h "$(L "Диск переключился в режим «только чтение»:$ro" "A filesystem switched to read-only mode:$ro")" \
    "$(L "Linux сам запрещает запись на диск, когда находит на нём ошибки, чтобы не испортить данные. Программы, которым нужно что-то записать, перестают работать." \
         "Linux blocks writes to a filesystem when it detects errors, to protect the data. Programs that need to write stop working.")" \
    "$(L "Сделайте копию важных данных, пока диск читается
Напишите хостеру/в дата-центр: «файловая система перешла в read-only, проверьте диск». Сами без опыта ничего не перемонтируйте
Проверку и ремонт (fsck) делают при выключенном разделе — обычно из rescue-режима" \
         "Copy important data while the disk is still readable
Tell your provider / data center: “the filesystem went read-only, please check the disk”. Do not remount it yourself without experience
Checking and repair (fsck) is done with the filesystem unmounted — usually from rescue mode")" \
    "$(grep -E " ($(echo "$ro" | sed 's/^ //; s/ /|/g' | sed 's/[.[\*^$]/\\&/g')) " /proc/mounts | head -5)"
fi

FSE=$(kgrep 7 'EXT4-fs error|EXT4-fs \(.*\): .*(corrupt|checksum)|XFS \(.*\): (Corruption|metadata I/O error|Internal error|.*[Ss]hut ?down)|BTRFS (error|critical)|Remounting filesystem read-only|Aborting journal on device|JBD2: .*error')
if [ -n "$FSE" ]; then
  add 2 disk 91 h "$(L "Ошибки файловой системы за 7 дней: $(lc "$FSE")" "Filesystem errors in the last 7 days: $(lc "$FSE")")" \
    "$(L "Файловая система повреждена или диск отдаёт испорченные данные. Возможны сбои программ и потеря файлов." \
         "The filesystem is damaged or the disk returns corrupted data. Programs may fail and files may be lost.")" \
    "$(L "Сделайте свежую копию важных данных
Проверьте здоровье диска (пункт SMART в этом отчёте) и сообщите хостеру
Запланируйте проверку файловой системы (fsck / xfs_repair) из rescue-режима" \
         "Make a fresh backup of important data
Check the disk health (the SMART item in this report) and tell your provider
Schedule a filesystem check (fsck / xfs_repair) from rescue mode")" "$(printf '%s\n' "$FSE" | tail -n 6)"
fi

EXCL='(dev|on dev|device) (fd[0-9]|sr[0-9]|loop[0-9]|nbd|zram)|floppy|sr[0-9]+:|loop[0-9]+|blk_update_request: I/O error, dev fd'
IOE=$(kgrep 7 'I/O error|critical medium error|Medium Error|Unrecovered read error|failed command: (READ|WRITE)|Sense Key *: *(Medium|Hardware) Error|\bUNC\b' "$EXCL")
LNK=$(kgrep 7 'ata[0-9.]+: (exception Emask|hard resetting link|SError|link is slow|failed to IDENTIFY)|nvme[0-9]+: (I/O [0-9]+ QID [0-9]+ timeout|controller is down|resetting controller|Device not ready|Removing after probe failure)' "$EXCL")
if [ -n "$IOE" ]; then
  add 2 disk 92 h "$(L "Диск выдаёт ошибки чтения/записи: $(lc "$IOE") записей в журнале ядра за 7 дней" "The disk reports read/write errors: $(lc "$IOE") kernel log entries in 7 days")" \
    "$(L "Система не смогла прочитать или записать данные на диск. Это частый признак умирающего диска (или проблем хранилища у хостера, если сервер виртуальный)." \
         "The system failed to read or write data on the disk. This is a typical sign of a dying disk (or of the provider's storage if the server is virtual).")" \
    "$(L "Срочно сделайте копию важных данных
Сообщите хостеру/в дата-центр: «I/O errors на диске, проверьте/замените диск» и приложите этот отчёт
Не запускайте тяжёлые операции (дефрагментацию, большие копирования) на этом диске до замены" \
         "Back up important data right away
Tell your provider / data center: “I/O errors on the disk, please check/replace it” and attach this report
Avoid heavy operations on this disk until it is replaced")" "$(printf '%s\n' "$IOE" | tail -n 6)"
elif [ -n "$LNK" ]; then
  add 1 disk 58 m "$(L "Сбросы связи с диском за 7 дней: $(lc "$LNK")" "Disk link resets / timeouts in 7 days: $(lc "$LNK")")" \
    "$(L "Диск или контроллер переставал отвечать, и система переподключала его. Причина — кабель, контроллер, перегрев или начало отказа диска. В эти моменты сервер «подвисает»." \
         "The disk or controller stopped responding and the system had to reset the link. Causes: cable, controller, overheating or an early disk failure. The server freezes during resets.")" \
    "$(L "Проверьте SMART диска (пункт в этом отчёте)
Сообщите хостеру: «ATA/NVMe link resets, проверьте кабель/диск»
Если сбросы повторяются — планируйте замену диска" \
         "Check the disk SMART data (see this report)
Tell your provider: “ATA/NVMe link resets, please check cable/disk”
If resets repeat, plan a disk replacement")" "$(printf '%s\n' "$LNK" | tail -n 6)"
fi

# ---- SMART
sec "Disks: SMART"
SM_OK=0 SM_NA='' SM_SLEEP=0
if [ "$IS_VM" = 1 ]; then
  note "$(L "Сервер виртуальный ($VIRT): здоровье физических дисков (SMART) и температуру контролирует хостер — это нормально." \
            "The server is virtual ($VIRT): physical disk health (SMART) and temperatures are the provider's job — this is normal.")"
elif [ "$ROOT" = 0 ]; then :
elif ! has smartctl; then
  limit "$(L "Не установлен smartmontools — здоровье дисков (SMART) не проверено. Установка (это уже изменение системы, решайте сами): sudo apt install smartmontools или sudo dnf install smartmontools" \
             "smartmontools is not installed — disk health (SMART) was not checked. To install (this changes the system, your call): sudo apt install smartmontools or sudo dnf install smartmontools")"
else
  SMDEV=$(timeout 30 smartctl --scan-open 2>/dev/null | awk '$1 ~ /^\// {t=""; for(i=2;i<=NF;i++){ if($i=="#") break; if($i=="-d") t=$(i+1) } print $1"|"t}')
  [ -n "$SMDEV" ] || SMDEV=$(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk" && $1 !~ /^(loop|zram|sr|rbd|nbd|md|dm-)/{print "/dev/"$1"|"}')
  for e in $SMDEV; do smart_check "${e%%|*}" "${e#*|}"; done
fi
SMS=''; [ "$SM_OK" -gt 0 ] && SMS="$(L "; SMART: дисков без замечаний — $SM_OK" "; SMART: $SM_OK disk(s) fine")"
[ "$IS_VM" = 1 ] && SMS="$(L "; SMART не нужен (VPS)" "; SMART n/a (virtual)")"
OK[disk]="${OK[disk]}$SMS"
[ "$SM_SLEEP" -gt 0 ] && note "$(L "Дисков в спящем режиме: $SM_SLEEP — их SMART не читали, чтобы не будить." "$SM_SLEEP disk(s) are asleep — SMART was not read to avoid waking them.")"

# ---- RAID / ZFS / LVM thin
sec "RAID / ZFS / LVM"
if [ -r /proc/mdstat ] && grep -q '^md' /proc/mdstat; then
  run "cat /proc/mdstat"
  MDBAD=$(awk '/^md/{n=$1; if ($3=="inactive") print n" (inactive)"} /blocks/ && match($0,/\[[U_]+\]/){s=substr($0,RSTART,RLENGTH); if (s ~ /_/) print n" "s}' /proc/mdstat | tr '\n' ' ')
  MDF=$(grep -oE '[a-z0-9]+\[[0-9]+\]\(F\)' /proc/mdstat | tr '\n' ' ')
  if [ -n "$MDBAD" ]; then
    add 2 disk 96 h "$(L "RAID-массив работает без одного из дисков (деградировал): $MDBAD" "A RAID array is running without one of its disks (degraded): $MDBAD")" \
      "$(L "Данные пока целы, но запаса больше нет: отказ ещё одного диска — и они пропадут. Деградированный массив к тому же работает медленнее." \
           "Data is still intact, but there is no redundancy left: one more disk failure and it is lost. A degraded array is also slower.")" \
      "$(L "Сделайте свежий бэкап важных данных
Попросите хостера/дата-центр заменить выпавший диск (напишите: «mdadm RAID degraded: $MDBAD ${MDF}») и приложите отчёт
После замены массив пересоберётся — проследите, чтобы в /proc/mdstat снова было [UU]" \
           "Make a fresh backup of important data
Ask your provider / data center to replace the failed disk (say: “mdadm RAID degraded: $MDBAD ${MDF}”) and attach the report
After the replacement the array rebuilds — make sure /proc/mdstat shows [UU] again")" "$(grep -A2 '^md' /proc/mdstat | head -12)"
  fi
  MDR=$(grep -oE '(recovery|resync|reshape|check) *= *[0-9.]+%' /proc/mdstat | head -1)
  [ -n "$MDR" ] && note "$(L "RAID сейчас пересобирается/проверяется ($MDR) — в это время диски загружены сильнее обычного." "RAID is rebuilding/checking right now ($MDR) — disks are busier than usual.")"
fi
if has zpool && [ "$ROOT" = 1 ]; then
  run "zpool status -x; zpool list"
  ZS=$(timeout 15 zpool status -x 2>&1)
  if ! printf '%s' "$ZS" | grep -qE 'all pools are healthy|no pools available'; then
    add 2 disk 96 h "$(L "ZFS-пул не в порядке (DEGRADED/FAULTED или ошибки)" "A ZFS pool is not healthy (DEGRADED/FAULTED or errors)")" \
      "$(L "Один из дисков пула отказал или выдаёт ошибки. Пока есть избыточность — данные целы, но запас уменьшился." \
           "A disk in the pool failed or returns errors. Data is safe while redundancy remains, but the margin is smaller.")" \
      "$(L "Посмотрите подробности: sudo zpool status -v
Замените сбойный диск (попросите хостера) и дождитесь resilver
Сделайте бэкап, пока пул доступен" \
           "See details: sudo zpool status -v
Replace the failing disk (ask your provider) and wait for the resilver
Make a backup while the pool is available")" "$(printf '%s\n' "$ZS" | head -20)"
  fi
  while read -r zn zc; do
    zc=${zc%\%}; [ "${zc:-0}" -ge 90 ] 2>/dev/null || continue
    add 1 disk 58 h "$(L "ZFS-пул $zn заполнен на $zc%" "ZFS pool $zn is $zc% full")" \
      "$(L "При заполнении больше 80–90% ZFS сильно замедляется, а при 100% запись прекращается." "Above 80–90% ZFS slows down a lot, and at 100% writes stop.")" \
      "$(L "Удалите ненужные данные и старые снапшоты: zfs list -t snapshot
Добавьте диски в пул или перенесите часть данных" "Delete unneeded data and old snapshots: zfs list -t snapshot
Add disks to the pool or move data elsewhere")" "zpool $zn capacity $zc%"
  done < <(timeout 10 zpool list -H -o name,capacity 2>/dev/null)
fi
if has lvs && [ "$ROOT" = 1 ]; then
  while IFS='|' read -r vg lv dp mp attr; do
    case $attr in t*) ;; *) continue ;; esac
    dp=${dp%%.*}; mp=${mp%%.*}; dp=${dp// /}; mp=${mp// /}; m=$dp; [ "${mp:-0}" -gt "${m:-0}" ] 2>/dev/null && m=$mp
    [ "${m:-0}" -ge 85 ] 2>/dev/null || continue
    sev=1 sc=62; [ "$m" -ge 95 ] && { sev=2; sc=93; }
    add "$sev" disk "$sc" h "$(L "LVM thin-пул $vg/$lv заполнен: данные $dp%, метаданные $mp%" "LVM thin pool $vg/$lv is filling up: data $dp%, metadata $mp%")" \
      "$(L "Когда thin-пул заполняется до конца, виртуальные машины и тома на нём получают ошибки записи и могут повредиться (часто на Proxmox)." \
           "When a thin pool fills up completely, the VMs/volumes on it get write errors and can be corrupted (common on Proxmox).")" \
      "$(L "Удалите ненужные снапшоты и диски виртуальных машин
Расширьте пул (lvextend) или перенесите часть машин на другое хранилище
Включите мониторинг заполнения пула" "Delete unneeded snapshots and VM disks
Extend the pool (lvextend) or move some VMs to other storage
Set up monitoring of pool usage")" "lvs: $vg/$lv data=$dp% meta=$mp%"
  done < <(timeout 10 lvs --noheadings --separator '|' -o vg_name,lv_name,data_percent,metadata_percent,lv_attr 2>/dev/null | sed 's/^ *//')
fi
HWR=$(lsmod 2>/dev/null | awk '$1 ~ /^(megaraid_sas|aacraid|hpsa|smartpqi|arcmsr|mpt3sas)$/{print $1}' | tr '\n' ' ')
[ -n "$HWR" ] && limit "$(L "Найден драйвер аппаратного RAID/HBA ($HWR): состояние такого массива скрипт не видит — проверьте его в панели хостера или утилитой производителя (storcli, ssacli, arcconf)." \
                             "A hardware RAID/HBA driver is loaded ($HWR): the script cannot see that array's state — check it in the provider panel or with the vendor tool (storcli, ssacli, arcconf).")"

# ---- I/O pressure (CPU waits for the disk) — needs the sample window, measured below together with the CPU

# ================================================================== MEMORY
say "$(L "• память: свободная, swap, OOM, ошибки ECC" "• memory: free RAM, swap, OOM, ECC errors")"
sec "Memory"
run "free -h"
run "cat /proc/pressure/memory /proc/pressure/io /proc/pressure/cpu 2>/dev/null"
read -r MT MA ST SF < <(awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}/^SwapTotal:/{st=$2}/^SwapFree:/{sf=$2}END{print t+0,a+0,st+0,sf+0}' /proc/meminfo)
[ "$MT" -gt 0 ] || MT=1
AP=$((MA*100/MT))
TOPMEM=$(ps -eo rss=,comm= 2>/dev/null | awk '{a[$2]+=$1; n[$2]++} END{for(k in a) print a[k], n[k], k}' | sort -rn | head -5)
TOPMEM_H=$(printf '%s\n' "$TOPMEM" | while read -r kb n c; do [ -n "$c" ] && printf '%s %s%s, ' "$c" "$(human "$kb")" "$([ "$n" -gt 1 ] && L " ($n проц.)" " ($n procs)")"; done | sed 's/, $//')
run "ps -eo rss=,comm= | awk '{a[\$2]+=\$1; n[\$2]++} END{for(k in a) printf \"%8.0f MB %4d  %s\n\", a[k]/1024, n[k], k}' | sort -rn | head -12"

# OOM killer
OOM7=$(kgrep 7 'Killed process [0-9]+|oom-kill:.*task=|Out of memory: Kill')
OOMK=$(printf '%s\n' "$OOM7" | grep -ac 'Killed process')
OOM1=$(kgrep 1 'Killed process [0-9]+' | grep -ac .)
OOMCG=$(kgrep 7 'Memory cgroup out of memory' | grep -ac .)
OOMN=$(printf '%s\n' "$OOM7" | sed -nE 's/.*Killed process [0-9]+ \(([^)]+)\).*/\1/p' | sort | uniq -c | sort -rn | head -5 | awk '{printf "%s%s ×%s", (NR>1?", ":""), $2, $1}')
OOMD=0; has journalctl && OOMD=$(timeout 10 journalctl -u systemd-oomd --since -7d -q --no-pager -o cat 2>/dev/null | grep -ac 'Killed')
if [ "$OOMK" -gt 0 ]; then
  if [ "$OOMCG" -gt 0 ] && [ "$OOMCG" -ge "$OOMK" ]; then
    add 1 mem 62 h "$(L "Служба/контейнер упирается в свой лимит памяти: убито процессов за 7 дней — $OOMK ($OOMN)" "A service/container hits its own memory limit: $OOMK process(es) killed in 7 days ($OOMN)")" \
      "$(L "У службы или контейнера стоит ограничение памяти (cgroup). Когда она его превышает, Linux убивает её процессы, хотя у сервера в целом память ещё есть." \
           "The service or container has a memory limit (cgroup). When it exceeds it, Linux kills its processes even though the server as a whole still has memory.")" \
      "$(L "Найдите, какой службе тесно: sudo journalctl -k | grep -i 'memory cgroup' | tail
Увеличьте ей лимит (MemoryMax в systemd, --memory в Docker) или уменьшите её аппетит (число воркеров, кэш)
Проверьте, нет ли утечки памяти: растёт ли потребление со временем" \
           "Find which service is constrained: sudo journalctl -k | grep -i 'memory cgroup' | tail
Raise its limit (MemoryMax in systemd, --memory in Docker) or reduce its appetite (workers, cache)
Check for a memory leak: does usage grow over time?")" "$(printf '%s\n' "$OOM7" | grep -a 'Killed process' | tail -n 5)"
  else
    sev=1 sc=64; { [ "$OOM1" -gt 0 ] || [ "$OOMK" -ge 3 ]; } && { sev=2; sc=89; }
    add "$sev" mem "$sc" h "$(L "Серверу не хватало памяти: Linux убил процессов за 7 дней — $OOMK, из них за сутки — $OOM1 ($OOMN)" "The server ran out of memory: Linux killed $OOMK process(es) in 7 days, $OOM1 in the last 24 h ($OOMN)")" \
      "$(L "Когда оперативная память кончается, ядро принудительно завершает самый «тяжёлый» процесс (OOM killer). Снаружи это выглядит как внезапное падение сайта, базы или программы." \
           "When RAM runs out, the kernel force-kills the heaviest process (the OOM killer). From outside it looks like a website, database or program suddenly crashing.")" \
      "$(L "Посмотрите, кто ест память (список ниже: ${TOPMEM_H:-—}) и что именно убивали: ${OOMN:-—}
Уменьшите аппетит: меньше воркеров PHP-FPM/Apache, меньший кэш базы данных (innodb_buffer_pool_size), найдите утечку памяти
Если нагрузка выросла законно — добавьте оперативной памяти (тариф выше) или хотя бы swap-файл на 1–2 ГБ" \
           "See who uses the memory (list below: ${TOPMEM_H:-—}) and what got killed: ${OOMN:-—}
Reduce the appetite: fewer PHP-FPM/Apache workers, a smaller database cache (innodb_buffer_pool_size), look for a memory leak
If the load legitimately grew, add RAM (a bigger plan) or at least a 1–2 GB swap file")" "$(printf '%s\n' "$OOM7" | grep -a 'Killed process' | tail -n 5)"
  fi
fi
[ "${OOMD:-0}" -gt 0 ] && add 1 mem 55 h "$(L "systemd-oomd завершал программы из-за нехватки памяти: $OOMD раз за 7 дней" "systemd-oomd killed programs due to memory pressure: $OOMD time(s) in 7 days")" \
  "$(L "Служба systemd-oomd заранее убивает программы, когда памяти становится мало." "systemd-oomd kills programs early when memory runs low.")" \
  "$(L "Посмотрите, что убивалось: journalctl -u systemd-oomd --since -7d
Уменьшите потребление памяти или добавьте RAM" "See what was killed: journalctl -u systemd-oomd --since -7d
Reduce memory usage or add RAM")" ""

# EDAC (ECC memory error counters, readable without root)
CE=0 UE=0
for f in /sys/devices/system/edac/mc/mc*/ce_count; do [ -r "$f" ] && CE=$((CE + $(cat "$f" 2>/dev/null || echo 0))); done
for f in /sys/devices/system/edac/mc/mc*/ue_count; do [ -r "$f" ] && UE=$((UE + $(cat "$f" 2>/dev/null || echo 0))); done
EDAC_EV=$(for d in /sys/devices/system/edac/mc/mc*/dimm*; do [ -r "$d/dimm_ce_count" ] || continue; c=$(cat "$d/dimm_ce_count"); u=$(cat "$d/dimm_ue_count" 2>/dev/null); [ "$c$u" != 00 ] && echo "$(cat "$d/dimm_label" 2>/dev/null || basename "$d"): CE=$c UE=${u:-0}"; done; kgrep 30 'EDAC .*(CE|UE|error)' | tail -n 4)
if [ "$UE" -gt 0 ]; then
  add 2 mem 97 h "$(L "Неисправна оперативная память: НЕисправимых ошибок ECC — $UE" "Faulty RAM: $UE uncorrectable ECC error(s)")" \
    "$(L "Модуль памяти выдаёт ошибки, которые уже нельзя исправить. Это приводит к зависаниям, перезагрузкам и порче данных." \
         "A memory module returns errors that can no longer be corrected. This causes freezes, reboots and data corruption.")" \
    "$(L "Сообщите хостеру/дата-центру: «EDAC uncorrectable memory errors, проверьте/замените модуль памяти» — слот указан ниже
Сделайте бэкап важных данных
До замены памяти не доверяйте результатам расчётов и целостности баз" \
         "Tell your provider / data center: “EDAC uncorrectable memory errors, please test/replace the DIMM” — the slot is listed below
Back up important data
Until the RAM is replaced, do not trust computations or database integrity")" "$EDAC_EV"
elif [ "$CE" -gt 0 ]; then
  sev=1 sc=62; [ "$CE" -ge 1000 ] && { sev=2; sc=80; }
  add "$sev" mem "$sc" h "$(L "Память исправляет ошибки сама (ECC), но модуль начинает сдавать: исправлено ошибок — $CE" "ECC memory is correcting errors, but a module is starting to fail: $CE corrected error(s)")" \
    "$(L "Пока ошибки исправляются на лету и данные целы. Но рост числа ошибок — частый предвестник отказа модуля памяти." \
         "Errors are still corrected on the fly and data is intact. A growing count often precedes a module failure.")" \
    "$(L "Запустите проверку ещё раз через несколько дней: растёт ли счётчик
Если растёт — попросите хостера проверить/заменить модуль (слот указан ниже)
Держите свежий бэкап" "Run the check again in a few days: is the counter growing?
If it grows, ask the provider to test/replace the module (slot below)
Keep a fresh backup")" "$EDAC_EV"
fi

# ================================================================== CPU (+ sample end) / I/O pressure
say "$(L "• процессор: нагрузка, steal, температура, аппаратные ошибки" "• CPU: load, steal, temperature, hardware errors")"
DTT=$((C2T - C1T)); [ "$DTT" -gt 0 ] || DTT=1
BUSY=$(( (C2B - C1B) * 100 / DTT )); IOW=$(( (C2W - C1W) * 100 / DTT )); STEAL=$(( (C2S - C1S) * 100 / DTT ))
STEAL_BOOT=$(( C1S * 1000 / (C1T > 0 ? C1T : 1) ))   # per mille since boot
SWAPR=$(( ( (S2I - S1I) + (S2O - S1O) ) * 1000 / DT ))  # pages/s
DSTUCK=$(comm -12 "$TMP/d1" "$TMP/d2" | grep -c .)
TOPCPU=$(awk -F'\t' -v hz="$HZ" -v dt="$DT" -v n="$CORES" 'NR==FNR{a[$1]=$2; next} {d=($1 in a) ? $2-a[$1] : $2; if(d>0) u[$3]+=d} END{for(k in u){p=u[k]*100000/hz/dt/n; if(p>=1) printf "%.0f\t%s\n", p, k}}' "$TMP/p1" "$TMP/p2" | sort -rn | head -5)
TOPCPU_H=$(printf '%s\n' "$TOPCPU" | awk -F'\t' 'NF==2{printf "%s%s %s%%", (NR>1?", ":""), $2, $1}')
read -r L1 L5 L15 _ < /proc/loadavg
sec "CPU"
run "cat /proc/loadavg; nproc"
run "top -bn1 | head -22"
printf '%s\n' "sample ${DT} ms: busy ${BUSY}%  iowait ${IOW}%  steal ${STEAL}%  (steal since boot $((STEAL_BOOT/10)).$((STEAL_BOOT%10))%)  swap in+out ${SWAPR} pages/s  D-state stuck: ${DSTUCK}" \
  "top CPU now (% of all cores): ${TOPCPU_H:-none}" >> "$TECH"

# memory pressure / swap thrash (needs the sample)
PSI_MS=$(psi memory some avg60); PSI_MF=$(psi memory full avg60)
PSI_IOF=$(psi io full avg60); PSI_IOF3=$(psi io full avg300); PSI_CPU3=$(psi cpu some avg300)
if { [ "$SWAPR" -ge 2500 ] || fgt "$PSI_MF" 10; } && [ "$AP" -lt 20 ]; then
  add 2 mem 85 h "$(L "Сервер «задыхается»: памяти не хватает, и он постоянно перекладывает её на диск (swap)" "The server is thrashing: RAM is short and it constantly swaps memory to disk")" \
    "$(L "Свободной памяти нет, поэтому система всё время пишет и читает swap. Всё работает в десятки раз медленнее; это главный признак нехватки RAM." \
         "There is no free RAM, so the system keeps reading and writing swap. Everything becomes many times slower; this is the main sign of too little RAM.")" \
    "$(L "Посмотрите, кто ест память: ${TOPMEM_H:-—}
Перезапустите или ограничьте самую «прожорливую» программу; уменьшите число воркеров/кэшей
Если так постоянно — добавьте оперативной памяти (тариф выше)" \
         "See who uses the memory: ${TOPMEM_H:-—}
Restart or limit the hungriest program; reduce workers/caches
If it is permanent, add RAM (a bigger plan)")" "swap in+out ${SWAPR} pages/s; PSI memory some/full avg60: ${PSI_MS:-n/a}/${PSI_MF:-n/a}; MemAvailable $(human "$MA") of $(human "$MT")"
elif [ "$AP" -lt 5 ] && [ "$MA" -lt $((2*GiB)) ]; then
  add 2 mem 84 h "$(L "Оперативная память почти закончилась: доступно $(human "$MA") из $(human "$MT") ($AP%)" "RAM is almost exhausted: $(human "$MA") of $(human "$MT") available ($AP%)")" \
    "$(L "Ещё немного — и Linux начнёт убивать процессы (OOM) или сервер станет очень медленным." "A bit more and Linux will start killing processes (OOM) or the server will crawl.")" \
    "$(L "Посмотрите, кто ест память: ${TOPMEM_H:-—}
Перезапустите или ограничьте самую «прожорливую» программу
Добавьте RAM или swap-файл, если нагрузка выросла законно" \
         "See who uses the memory: ${TOPMEM_H:-—}
Restart or limit the hungriest program
Add RAM or a swap file if the load legitimately grew")" "MemAvailable $(human "$MA") of $(human "$MT"); swap used $(human $((ST-SF))) of $(human "$ST")"
elif { [ "$AP" -lt 10 ] && [ "$MA" -lt $((4*GiB)) ]; } || { { [ "$SWAPR" -ge 250 ] || fgt "$PSI_MS" 10; } && [ "$AP" -lt 25 ]; }; then
  add 1 mem 52 m "$(L "Памяти впритык: доступно $(human "$MA") из $(human "$MT") ($AP%)" "Memory is tight: $(human "$MA") of $(human "$MT") available ($AP%)")" \
    "$(L "Сейчас сервер работает, но запаса почти нет: при всплеске нагрузки начнутся тормоза или падения программ." \
         "The server works now, but there is little headroom: a load spike will cause slowdowns or crashes.")" \
    "$(L "Посмотрите, кто ест память: ${TOPMEM_H:-—}
Уменьшите аппетит программ (воркеры, кэши) или добавьте RAM" "See who uses the memory: ${TOPMEM_H:-—}
Reduce programs' appetite (workers, caches) or add RAM")" "MemAvailable $(human "$MA"); swap rate ${SWAPR} pages/s; PSI memory some avg60 ${PSI_MS:-n/a}"
fi
SWP=''; [ "$ST" -gt 0 ] && SWP="$(L ", swap занят на $(( (ST-SF)*100/ST ))%" ", swap $(( (ST-SF)*100/ST ))% used")"
OK[mem]="$(L "доступно $(human "$MA") из $(human "$MT") ($AP%)$SWP, нехватки памяти (OOM) за 7 дней не было" "$(human "$MA") of $(human "$MT") available ($AP%)$SWP, no out-of-memory kills in 7 days")"

# I/O pressure -> disk area
if fgt "$PSI_IOF3" 60; then sev=2 sc=78; elif fgt "$PSI_IOF3" 25 || fgt "$PSI_IOF" 40 || { [ -z "$PSI_IOF3" ] && [ "$IOW" -ge 40 ]; }; then sev=1 sc=50; else sev=0; fi
if [ "$sev" -gt 0 ]; then
  add "$sev" disk "$sc" m "$(L "Диск не успевает за нагрузкой: программы ждут диск ${PSI_IOF3:-$IOW}% времени" "The disk cannot keep up: programs wait for it ${PSI_IOF3:-$IOW}% of the time")" \
    "$(L "Сервер «тормозит», хотя процессор свободен: все ждут чтения/записи. Причины: медленный диск (HDD), тяжёлая задача (бэкап, база данных), умирающий диск или перегруженное хранилище у хостера." \
         "The server is slow although the CPU is free: everything waits for disk reads/writes. Causes: a slow disk (HDD), a heavy job (backup, database), a dying disk or overloaded provider storage.")" \
    "$(L "Посмотрите, кто нагружает диск: sudo iotop -o (или: pidstat -d 5)
Перенесите тяжёлые задачи (бэкапы, архивацию, индексацию) на ночь
Если так постоянно — нужен SSD/NVMe или более быстрый тариф" \
         "See who loads the disk: sudo iotop -o (or: pidstat -d 5)
Move heavy jobs (backups, archiving, indexing) to the night
If it is permanent, you need SSD/NVMe or a faster plan")" "PSI io full avg60/avg300: ${PSI_IOF:-n/a}/${PSI_IOF3:-n/a}; iowait now ${IOW}%; processes stuck in D state: $DSTUCK"
fi

# CPU load / steal
if fgt "$L5" $((CORES*2)) && fgt "$L15" "$(awk -v c="$CORES" 'BEGIN{print c*1.5}')" && [ "$BUSY" -ge 80 ]; then sev=2 sc=80
elif { fgt "$L5" "$CORES" && [ "$BUSY" -ge 80 ]; } || { [ "$BUSY" -ge 95 ] && fgt "$L1" "$CORES"; } || fgt "$PSI_CPU3" 60; then sev=1 sc=46
else sev=0; fi
if [ "$sev" -gt 0 ]; then
  add "$sev" cpu "$sc" h "$(L "Процессор перегружен: занят на $BUSY%, нагрузка $L5 при $CORES ядрах" "The CPU is overloaded: $BUSY% busy, load $L5 on $CORES cores")" \
    "$(L "Задач больше, чем ядер успевают обработать, поэтому всё отвечает медленнее. Больше всего процессор занимают: ${TOPCPU_H:-—}." \
         "There is more work than the cores can process, so everything responds slower. Top CPU users: ${TOPCPU_H:-—}.")" \
    "$(L "Проверьте программы из списка: ${TOPCPU_H:-—}. Если среди них незнакомая — выясните, что это
Оптимизируйте или ограничьте тяжёлые задачи (кэш сайта, число воркеров, расписание фоновых задач)
Если такая нагрузка — норма для вашей работы, нужен тариф с большим числом ядер" \
         "Check the programs in the list: ${TOPCPU_H:-—}. If one is unfamiliar, find out what it is
Optimize or limit heavy jobs (site cache, number of workers, background job schedule)
If this load is normal for your work, you need a plan with more cores")" "load $L1 $L5 $L15, cores $CORES, busy ${BUSY}% iowait ${IOW}% over ${DT} ms; PSI cpu some avg300 ${PSI_CPU3:-n/a}"
fi
if [ "$IS_VM" = 1 ]; then
  if [ "$STEAL" -ge 20 ]; then sev=2 sc=82; elif [ "$STEAL" -ge 8 ] || [ "$STEAL_BOOT" -ge 50 ]; then sev=1 sc=56; else sev=0; fi
  if [ "$sev" -gt 0 ]; then
    add "$sev" cpu "$sc" h "$(L "Хостер перегружен: вашему VPS не хватает процессора (steal сейчас $STEAL%, в среднем $((STEAL_BOOT/10))%)" "The host is overloaded: your VPS is starved of CPU (steal now $STEAL%, average $((STEAL_BOOT/10))%)")" \
      "$(L "Steal — это время, когда физический процессор занят другими клиентами на том же сервере, а ваш VPS ждёт. Изнутри VPS это не исправить." \
           "Steal is the time the physical CPU serves other customers on the same host while your VPS waits. It cannot be fixed from inside the VPS.")" \
      "$(L "Напишите в поддержку хостера: «высокий CPU steal ($STEAL%), перенесите VPS на менее загруженный узел»
Запустите проверку ещё раз в другое время — постоянно ли это
Если повторяется — тариф с выделенными ядрами или другой хостер" \
           "Write to your provider: “high CPU steal ($STEAL%), please move my VPS to a less loaded node”
Run the check again at another time — is it permanent?
If it repeats — a plan with dedicated cores or another provider")" "steal ${STEAL}% over ${DT} ms; since boot $((STEAL_BOOT/10)).$((STEAL_BOOT%10))%"
  fi
fi

# temperature (physical servers)
TMAX=''
if [ "$IS_VM" = 0 ]; then
  temps > "$TMP/temps"
  if [ -s "$TMP/temps" ]; then
    { echo '$ temperatures (sensor|label|°C|max|crit)'; cat "$TMP/temps"; } >> "$TECH"
    TMAX=$(awk -F'|' '$1 ~ /^(coretemp|k10temp|zenpower|cpu_thermal|x86_pkg_temp|cpu)/ && $3>tm{tm=$3} END{if(tm) print tm}' "$TMP/temps")
    THOT=$(awk -F'|' -v r=2 '
      { t=$3; mx=$4; cr=$5; s=0
        if ($1 ~ /^(coretemp|k10temp|zenpower|cpu_thermal|x86_pkg_temp|cpu)/) { if (t>=95 || (cr>=60 && t>=cr-3)) s=2; else if (t>=85 || (mx>=60 && t>=mx)) s=1 }
        else if ($1 ~ /^nvme/) { if (cr>=60 && t>=cr) s=2; else if ((mx>=50 && t>=mx) || (mx<50 && t>=75)) s=1 }
        else if ($1 ~ /^drivetemp/) { if (t>=65) s=2; else if (t>=55) s=1 }
        else if (cr>=60 && t>=cr) s=2
        if (s) print s"|"$1" "$2": "t"°C" }' "$TMP/temps")
    if [ -n "$THOT" ]; then
      sev=1 sc=58; printf '%s\n' "$THOT" | grep -q '^2|' && { sev=2; sc=89; }
      add "$sev" cpu "$sc" h "$(L "Перегрев: $(printf '%s\n' "$THOT" | head -3 | cut -d'|' -f2 | tr '\n' ';' | sed 's/;$//; s/;/; /g')" "Overheating: $(printf '%s\n' "$THOT" | head -3 | cut -d'|' -f2 | tr '\n' ';' | sed 's/;$//; s/;/; /g')")" \
        "$(L "При перегреве процессор сбрасывает частоту (сервер тормозит), а при критической температуре сервер может внезапно выключиться. Обычно виноваты пыль, сломанный вентилятор, высохшая термопаста или жарко в стойке." \
             "When overheating, the CPU lowers its clock (the server slows down), and at a critical temperature it can suddenly power off. Usual causes: dust, a broken fan, dried thermal paste or a hot rack.")" \
        "$(L "Сообщите хостеру/в дата-центр: «перегрев CPU/дисков, проверьте охлаждение и вентиляторы»
Если сервер у вас — почистите от пыли, проверьте вентиляторы, замените термопасту
Временно снизьте нагрузку, чтобы избежать аварийного выключения" \
             "Tell your provider / data center: “CPU/disk overheating, please check cooling and fans”
If the server is yours — clean the dust, check the fans, replace thermal paste
Reduce the load for now to avoid an emergency shutdown")" "$(printf '%s\n' "$THOT" | cut -d'|' -f2)"
    fi
  else
    note "$(L "Датчики температуры недоступны (нет драйвера датчиков) — температура не проверена." "No temperature sensors are visible (no sensor driver) — temperature was not checked.")"
  fi
  THR=$(kgrep 7 'temperature above threshold|cpu clock throttled|Package temperature above')
  if [ -n "$THR" ] && ! printf '%s' "${F_T[*]:-}" | grep -qE 'Перегрев|Overheating'; then
    add 1 cpu 52 h "$(L "Процессор перегревался и сбрасывал частоту: $(lc "$THR") раз за 7 дней" "The CPU overheated and throttled $(lc "$THR") time(s) in 7 days")" \
      "$(L "Сейчас температура в норме, но под нагрузкой процессор греется до предела и замедляется." "The temperature is fine right now, but under load the CPU hits its limit and slows down.")" \
      "$(L "Попросите хостера проверить охлаждение (вентиляторы, пыль, термопасту)
Посмотрите, в какое время это происходит: sudo journalctl -k | grep -i throttl" "Ask your provider to check cooling (fans, dust, thermal paste)
See when it happens: sudo journalctl -k | grep -i throttl")" "$(printf '%s\n' "$THR" | tail -n 4)"
  fi
fi
CPUOK="$(L "нагрузка $L5 на $CORES ядер (CPU занят $BUSY%)" "load $L5 on $CORES cores (CPU $BUSY% busy)")"
[ -n "$TMAX" ] && CPUOK="$CPUOK, $(L "температура CPU" "CPU temperature") ${TMAX}°C"
[ "$IS_VM" = 1 ] && CPUOK="$CPUOK, steal $STEAL%"
OK[cpu]=$CPUOK

# machine check exceptions (CPU / memory / bus hardware errors)
MCE=$(kgrep 30 'mce: \[Hardware Error\]|Machine check events logged|Machine Check Exception|\[Hardware Error\]:|mce: .*(Uncorrected|Corrected) error' 'mce: CPU[0-9]* supports|MCE banks|mce: Using|mce: .*(init|enabled)')
if [ -n "$MCE" ]; then
  sev=1 sc=60; printf '%s\n' "$MCE" | grep -qiE 'uncorrect|fatal|PCC|panic' && { sev=2; sc=95; }
  [ "$IS_VM" = 1 ] && [ "$sev" = 1 ] && sc=45
  add "$sev" cpu "$sc" h "$(L "Процессор/память сообщают об аппаратных ошибках (MCE): $(lc "$MCE") записей за 30 дней" "CPU/memory report hardware errors (MCE): $(lc "$MCE") entries in 30 days")" \
    "$(L "Machine Check — сигнал самого «железа» об ошибке процессора, памяти или шины. Исправленные ошибки — предупреждение, неисправленные — причина зависаний и перезагрузок." \
         "A machine check is the hardware itself reporting a CPU, memory or bus error. Corrected ones are a warning; uncorrected ones cause freezes and reboots.")" \
    "$(L "Сообщите хостеру/дата-центру: «MCE hardware errors», приложите отчёт — нужна диагностика железа
Если сервер ваш — проверьте память (memtest86+), обновите BIOS/микрокод, проверьте охлаждение
Держите свежий бэкап" \
         "Tell your provider / data center: “MCE hardware errors” and attach this report — hardware diagnostics are needed
If the server is yours — test RAM (memtest86+), update BIOS/microcode, check cooling
Keep a fresh backup")" "$(printf '%s\n' "$MCE" | tail -n 6)"
fi

# ================================================================== CRASHES / REBOOTS
say "$(L "• сбои: аварийные перезагрузки, kernel panic, зависания" "• crashes: unclean reboots, kernel panics, hangs")"
sec "Boots / crashes"
run "journalctl --list-boots --no-pager 2>/dev/null | tail -12"
run "last -x -n 15 2>/dev/null | head -20"
J_DAYS=''; JF=''; J_DUR=''
if [ -n "$J_FIRST" ]; then JF=$(date -d "$J_FIRST" +%s 2>/dev/null); [ -n "$JF" ] && { J_DAYS=$(( (NOW - JF) / 86400 )); J_DUR=$(dur $((NOW - JF))); }; fi
UNC=0 UNCL='' UNC7=0 B7=0 NB=0
if has journalctl; then
  MAXB=5; [ "$FULL" = 1 ] && MAXB=15
  for b in $(seq 1 $MAXB); do
    timeout 15 journalctl -b "-$b" -n 60 -q --no-pager -o short-iso > "$TMP/b" 2>/dev/null || break
    [ -s "$TMP/b" ] || break
    last_ts=$(tail -n 1 "$TMP/b" | cut -c1-19); le=$(date -d "$last_ts" +%s 2>/dev/null) || break
    [ $((NOW - le)) -gt $((30*86400)) ] && break
    NB=$((NB+1)); [ $((NOW - le)) -le $((7*86400)) ] && B7=$((B7+1))
    if ! grep -qaiE 'systemd-shutdown|Reached target.*(Shutdown|Power-Off|Power Off|Reboot|Halt|Final Step|kexec)|Journal stopped|Stopping Journal Service|Received SIGTERM from PID 1|journald.*Received SIGTERM|Shutting down\.|reboot: (Restarting system|Power down)|System is (rebooting|powering down)|Power key pressed|Stopped target.*(Multi-User|Graphical)' "$TMP/b"; then
      UNC=$((UNC+1)); [ $((NOW - le)) -le $((7*86400)) ] && UNC7=$((UNC7+1))
      UNCL="$UNCL$(fdate "$le"), "
      { echo "\$ boot -$b ended without a clean shutdown; last journal lines:"; tail -n 4 "$TMP/b"; } >> "$TECH"
    fi
  done
fi
UNCL=${UNCL%, }
PST=$(command find /sys/fs/pstore /var/lib/systemd/pstore -type f -mtime -30 2>/dev/null | head -5)
KDUMP=$(command find /var/crash -mindepth 2 -maxdepth 2 \( -name 'vmcore*' -o -name 'dmesg*' \) -mtime -30 2>/dev/null | head -5)
if [ -n "$PST$KDUMP" ]; then
  PEV=$(for f in $PST $KDUMP; do echo "== $f"; grep -aiE -m3 'Kernel panic|BUG:|Oops|RIP:|Call Trace' "$f" 2>/dev/null; done | head -16)
  add 2 crash 93 h "$(L "Ядро Linux аварийно падало (kernel panic) — сохранён отчёт о падении" "The Linux kernel crashed (kernel panic) — a crash record was saved")" \
    "$(L "Kernel panic — полная остановка системы с перезагрузкой. Причина обычно в драйвере, неисправной памяти/процессоре или ошибке ядра; подсказка — в строках отчёта ниже." \
         "A kernel panic stops the whole system and reboots it. The cause is usually a driver, faulty RAM/CPU or a kernel bug; the lines below give a hint.")" \
    "$(L "Отправьте строки ниже (или файлы $PST $KDUMP) хостеру или специалисту
Обновите систему и ядро до последней версии из официальных пакетов
Если паника повторяется — проверьте память (memtest86+) и попросите хостера проверить железо" \
         "Send the lines below (or the files $PST $KDUMP) to your provider or an admin
Update the system and kernel to the latest official packages
If panics repeat — test RAM (memtest86+) and ask the provider to check the hardware")" "$PEV"
fi
if [ "$UNC" -gt 0 ]; then
  sev=1 sc=55; [ "$UNC7" -ge 1 ] && sc=66; [ "$UNC" -ge 2 ] && { sev=2; sc=84; }
  add "$sev" crash "$sc" m "$(L "Сервер выключался аварийно (без нормального завершения работы): $UNC раз за 30 дней — $UNCL" "The server went down uncleanly (no normal shutdown) $UNC time(s) in 30 days — $UNCL")" \
    "$(L "Журнал оборвался без записи о выключении. Так бывает при пропадании питания, принудительной перезагрузке у хостера, полном зависании системы или аппаратном сбое. Время указано по последней записи в журнале перед сбоем." \
         "The log stopped without a shutdown record. This happens on power loss, a forced reset by the provider, a complete system freeze or a hardware fault. The time is the last journal entry before the crash.")" \
    "$(L "Спросите хостера, не было ли в это время работ, сбоя питания или перезагрузки по их инициативе
Посмотрите другие пункты отчёта: перегрев, ошибки памяти/дисков, нехватка памяти — частые причины зависаний
Посмотрите, что было перед сбоем: sudo journalctl -b -1 -n 100" \
         "Ask your provider whether there was maintenance, a power failure or a reset on their side at that time
Look at other items in this report: overheating, memory/disk errors, out-of-memory — common causes of freezes
See what happened before the crash: sudo journalctl -b -1 -n 100")" "unclean boots (by last journal entry): $UNCL"
fi
[ "$B7" -ge 4 ] && add 1 crash 50 h "$(L "Сервер часто перезагружается: $B7 раз за 7 дней" "The server reboots often: $B7 times in 7 days")" \
  "$(L "Частые перезагрузки — признак нестабильности или чьих-то регулярных ручных перезапусков." "Frequent reboots indicate instability or someone restarting it regularly.")" \
  "$(L "Выясните, кто и зачем перезагружает (last -x, панель хостера)
Если перезагрузки сами собой — смотрите пункты про сбои, память и перегрев" "Find out who reboots it and why (last -x, provider panel)
If they happen by themselves, see the crash, memory and overheating items")" ""
OOPS=$(kgrep 30 'kernel BUG at|BUG: (unable to handle|kernel NULL pointer|scheduling while atomic|Bad page)|general protection fault|Oops: ')
LOCK=$(kgrep 30 'soft lockup|hard LOCKUP|rcu_(sched|preempt|bh) (self-)?detected stall|rcu: INFO: .*stall|watchdog: BUG')
HUNG=$(kgrep 30 'blocked for more than [0-9]+ seconds' 'echo 0 >')
[ -n "$OOPS" ] && add 1 crash 64 h "$(L "Ядро Linux сообщало о внутренних ошибках (Oops/BUG): $(lc "$OOPS") за 30 дней" "The Linux kernel reported internal errors (Oops/BUG): $(lc "$OOPS") in 30 days")" \
  "$(L "Система продолжила работу, но такая ошибка ядра часто вызвана драйвером или неисправным железом и может привести к зависанию." "The system kept running, but such kernel errors are often caused by a driver or faulty hardware and can lead to a freeze.")" \
  "$(L "Обновите ядро и систему до последних официальных пакетов
Отправьте строки ниже специалисту или хостеру — по ним видно, какой драйвер виноват" "Update the kernel and system to the latest official packages
Send the lines below to an admin or your provider — they show which driver is at fault")" "$(printf '%s\n' "$OOPS" | tail -n 5)"
if [ -n "$LOCK" ]; then
  if [ "$IS_VM" = 1 ]; then w="$(L "На виртуальном сервере это почти всегда значит, что физический сервер хостера перегружен и ваш VPS «замирал» на десятки секунд." "On a virtual server this almost always means the provider's host was overloaded and your VPS froze for tens of seconds.")"
  else w="$(L "Процессор «завис» на десятки секунд: обычно драйвер, прошивка или неисправное железо." "A CPU was stuck for tens of seconds: usually a driver, firmware or faulty hardware.")"; fi
  add 1 crash 57 h "$(L "Система «замирала» (soft lockup / RCU stall): $(lc "$LOCK") за 30 дней" "The system froze (soft lockup / RCU stall): $(lc "$LOCK") in 30 days")" "$w" \
    "$(L "Если сервер виртуальный — напишите хостеру: «soft lockup / RCU stall, проверьте загрузку узла»
Если физический — обновите BIOS, микрокод и ядро; проверьте охлаждение" "If the server is virtual — tell your provider: “soft lockup / RCU stall, please check the node load”
If physical — update BIOS, microcode and kernel; check cooling")" "$(printf '%s\n' "$LOCK" | tail -n 5)"
fi
[ -n "$HUNG" ] && add 1 crash 55 h "$(L "Программы зависали больше чем на 2 минуты, ожидая диск или сеть: $(lc "$HUNG") раз за 30 дней" "Programs hung for over 2 minutes waiting for disk or network: $(lc "$HUNG") time(s) in 30 days")" \
  "$(L "Процессы надолго застревали на операциях ввода-вывода. Обычно это медленный или сбоящий диск, перегруженное хранилище или зависший сетевой диск (NFS)." "Processes were stuck on I/O for a long time. Usually a slow or failing disk, overloaded storage or a hung network share (NFS).")" \
  "$(L "Проверьте пункты про диски в этом отчёте (ошибки, SMART, нагрузка)
Если используете NFS/сетевые диски — проверьте их доступность
Сообщите хостеру, если сервер виртуальный" "Check the disk items in this report (errors, SMART, load)
If you use NFS/network shares — check that they are reachable
Tell your provider if the server is virtual")" "$(printf '%s\n' "$HUNG" | tail -n 4)"
CROK="$(L "аварийных выключений не найдено, работает без перезагрузки $(dur "$UP_S")" "no unclean shutdowns found, up $(dur "$UP_S") without a reboot")"
if [ -n "$J_DAYS" ] && [ "$NB" = 0 ] && [ $((NOW - JF)) -lt "$UP_S" ]; then
  CROK="$(L "сбоев не видно, работает без перезагрузки $(dur "$UP_S"); журнал хранит только $J_DUR, более ранние события неизвестны" "no crashes seen, up $(dur "$UP_S"); the journal keeps only $J_DUR, earlier events are unknown")"
elif [ -n "$J_DAYS" ] && [ "$J_DAYS" -lt 30 ]; then CROK="$CROK $(L "(журнал за $J_DUR)" "(journal covers $J_DUR)")"; fi
OK[crash]=$CROK

# ================================================================== SERVICES
say "$(L "• службы и программы: упавшие, перезапуски, падения" "• services: failed, restarting, crashing")"
sec "Services / processes"
NRUN=0
if has systemctl && [ -d /run/systemd/system ]; then
  run "systemctl --failed --no-pager"
  NRUN=$(systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null | grep -c .)
  IMP='' OTH='' BEN=''
  for u in $(systemctl --failed --no-legend --plain 2>/dev/null | awk '{u=$1; if (u=="●"||u=="*") u=$2; print u}'); do
    b=${u%.*}
    if printf '%s' "$b" | grep -qE '^(systemd-networkd-wait-online|NetworkManager-wait-online|plymouth.*|motd-news|apt-daily.*|apt-news|fwupd.*|man-db|e2scrub.*|mdmonitor-oneshot|snapd\..*|ua-.*|ubuntu-advantage.*|grub-.*|secureboot-db|systemd-backlight@.*|cloud-init.*|cloud-config|cloud-final|update-notifier.*|packagekit.*|multipathd|open-iscsi|iscsid|sssd-kcm|dmesg)$'; then BEN="$BEN $u"
    elif { [ "$IS_VM" = 1 ] && printf '%s' "$b" | grep -qE '^(smartd|smartmontools|lm-sensors|fancontrol|irqbalance)$'; } || { [ "$b" = mdmonitor ] && ! grep -q '^md' /proc/mdstat 2>/dev/null; }; then BEN="$BEN $u"
    elif printf '%s' "$b" | grep -qE '^(ssh|sshd|nginx|apache2|httpd|lighttpd|caddy|openresty|mysql|mysqld|mariadb|postgresql.*|php.*-fpm|docker|containerd|redis.*|valkey.*|mongod|memcached|exim4|postfix|dovecot|named|bind9|haproxy|pveproxy|pvedaemon|pve-cluster|pvestatd|corosync|libvirtd|kubelet|k3s.*|elasticsearch|opensearch|rabbitmq-server|cron|crond|systemd-journald|systemd-resolved|systemd-networkd|NetworkManager|networking|network|chronyd|chrony|ntp|ntpd|systemd-timesyncd|zfs-.*|smartd|supervisor|pm2-.*|gunicorn.*|uwsgi.*|tomcat.*|jetty.*|nodered|plesk.*|sw-cp-server|cpanel|lsws|lshttpd|vesta|hestia)$'; then IMP="$IMP $u"
    else OTH="$OTH $u"; fi
  done
  FEV=$(for u in $IMP $OTH; do echo "== $u"; timeout 5 journalctl -u "$u" -n 3 -q --no-pager -o cat 2>/dev/null | cut -c1-200; done | head -24)
  if [ -n "$IMP" ]; then
    u1=${IMP# }; u1=${u1%% *}
    add 2 svc 85 h "$(L "Не работает важная служба:$IMP" "An important service is down:$IMP")" \
      "$(L "Служба упала и не поднялась сама. Пока она стоит, не работает то, за что она отвечает (сайт, база данных, почта, доступ по SSH…)." \
           "The service crashed and did not come back. While it is down, whatever it provides (website, database, mail, SSH access…) does not work.")" \
      "$(L "Посмотрите причину: sudo systemctl status $u1 и sudo journalctl -u $u1 -n 50
Частые причины — кончилось место на диске, ошибка в конфиге после изменений, не хватило памяти (см. другие пункты отчёта)
Когда причина устранена, запустите службу: sudo systemctl restart $u1" \
           "See why: sudo systemctl status $u1 and sudo journalctl -u $u1 -n 50
Common causes — a full disk, a config error after changes, out of memory (see other items in this report)
Once fixed, start it: sudo systemctl restart $u1")" "$FEV"
  fi
  if [ -n "$OTH" ]; then
    u1=${OTH# }; u1=${u1%% *}
    add 1 svc 42 h "$(L "Упавшие службы:$OTH" "Failed services:$OTH")" \
      "$(L "Эти службы завершились с ошибкой. Часто это мелочь (разовая задача), но иногда — важная фоновая работа: бэкап, очистка логов, обновление сертификатов." \
           "These units ended with an error. Often harmless (a one-off job), but sometimes important background work: backups, log cleanup, certificate renewal.")" \
      "$(L "Посмотрите причину: sudo systemctl status $u1
Если служба не нужна — отключите её; если нужна — исправьте ошибку из журнала и перезапустите" \
           "See why: sudo systemctl status $u1
If the unit is not needed, disable it; if it is, fix the error from the log and restart it")" "$FEV"
  fi
  [ -n "$BEN" ] && note "$(L "Упали неважные служебные задачи (обычно безвредно):$BEN" "Some unimportant helper units failed (usually harmless):$BEN")"
  # restart loops
  UNITS=$(systemctl list-units --type=service --no-legend --plain 2>/dev/null | awk '{print $1}')
  if [ -n "$UNITS" ]; then
    # shellcheck disable=SC2086
    RL=$(systemctl show -p Id -p NRestarts $UNITS 2>/dev/null | awk -F= '/^Id=/{id=$2} /^NRestarts=/{n=$2+0} /^$/{if (n>=5) print n, id; id=""; n=0} END{if (n>=5) print n, id}' | sort -rn | head -5)
    if [ -n "$RL" ]; then
      RLH=$(printf '%s\n' "$RL" | awk '{printf "%s%s ×%s", (NR>1?", ":""), $2, $1}'); u1=$(printf '%s\n' "$RL" | awk 'NR==1{print $2}')
      sc=45; [ "$(printf '%s\n' "$RL" | awk 'NR==1{print $1}')" -ge 50 ] && sc=60
      add 1 svc "$sc" h "$(L "Служба постоянно падает и перезапускается: $RLH (с момента загрузки)" "A service keeps crashing and restarting: $RLH (since boot)")" \
        "$(L "systemd поднимает службу после каждого падения, поэтому снаружи она «вроде работает», но в моменты падений запросы теряются." \
             "systemd restarts the service after each crash, so it “seems to work”, but requests are lost during the crashes.")" \
        "$(L "Посмотрите, почему падает: sudo journalctl -u $u1 -n 80
Частые причины — нехватка памяти, ошибка в конфиге, недоступна база/сеть
Если служба больше не нужна — остановите и отключите её: sudo systemctl disable --now $u1" "See why it crashes: sudo journalctl -u $u1 -n 80
Common causes — out of memory, a config error, an unreachable database/network
If the service is no longer needed, stop and disable it: sudo systemctl disable --now $u1")" "$RL"
    fi
  fi
else
  limit "$(L "systemd не найден — проверка служб упрощена." "systemd not found — the service check is simplified.")"
fi
# crashing programs: segfaults, core dumps, apport crash reports
SEGV=$(kgrep 7 'segfault at|traps: .*(general protection|trap invalid opcode|trap divide error)' | sed -nE 's/.* ([^ ]+)\[[0-9]+\]: (segfault|trap).*/\1/p; s/.*traps: ([^[]+)\[[0-9]+\].*/\1/p')
CORES_L=''; has coredumpctl && CORES_L=$(timeout 10 coredumpctl list --since=-7d --no-legend --no-pager -q 2>/dev/null | awk '{print $(NF-1)}' | sed 's#.*/##')
APP=$(for f in $(command find /var/crash -maxdepth 1 -name '*.crash' -mtime -7 2>/dev/null); do grep -a -m1 '^ExecutablePath:' "$f" 2>/dev/null | sed 's/^ExecutablePath: *//; s#.*/##' || basename "$f"; done)
CRASHN=$(printf '%s\n%s\n%s\n' "$SEGV" "$CORES_L" "$APP" | grep -v '^$' | sort | uniq -c | sort -rn)
CH=$(printf '%s\n' "$CRASHN" | head -5 | awk 'NF{printf "%s%s ×%s", (NR>1?", ":""), $2, $1}')
if [ "$(printf '%s\n' "$CRASHN" | awk '{s+=$1} END{print s+0}')" -lt 3 ] && [ -n "$CH" ]; then
  note "$(L "Единичные падения программ за 7 дней: $CH (подробности: /var/crash, coredumpctl list)." "Isolated program crashes in 7 days: $CH (details: /var/crash, coredumpctl list).")"
elif [ -n "$CH" ]; then
  add 1 svc 38 h "$(L "Программы аварийно завершались за 7 дней: $CH" "Programs crashed in the last 7 days: $CH")" \
    "$(L "Программа «вылетала» с ошибкой (segfault / core dump). Если это ваш сайт, бот или база — в эти моменты они не работали." \
         "A program crashed (segfault / core dump). If it is your site, bot or database, it was down at those moments.")" \
    "$(L "Обновите эти программы до свежих версий
Посмотрите подробности: sudo journalctl -k | grep segfault, coredumpctl list, файлы в /var/crash
Если падения частые — проверьте память сервера (пункт про ECC/MCE) и библиотеки, с которыми работает программа" \
         "Update these programs to current versions
See details: sudo journalctl -k | grep segfault, coredumpctl list, files in /var/crash
If crashes are frequent, check the server memory (ECC/MCE item) and the libraries the program uses")" "$CRASHN"
fi
# docker containers (only when docker answers quickly)
if [ "$ROOT" = 1 ] && has docker && timeout 5 docker info >/dev/null 2>&1; then
  run "docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' | head -30"
  DBAD=$(timeout 10 docker ps -a --format '{{.Names}}|{{.Status}}' 2>/dev/null | awk -F'|' '$2 ~ /Restarting|unhealthy/{printf "%s%s (%s)", (n++?", ":""), $1, $2}')
  [ -n "$DBAD" ] && add 1 svc 46 h "$(L "Контейнеры Docker перезапускаются или нездоровы: $DBAD" "Docker containers are restarting or unhealthy: $DBAD")" \
    "$(L "Контейнер падает сразу после запуска или не проходит проверку здоровья — его сервис фактически не работает." "The container crashes right after start or fails its health check — its service is effectively down.")" \
    "$(L "Посмотрите логи: docker logs --tail 50 <имя>
Частые причины — ошибка конфигурации, нет доступа к базе, не хватает памяти" "See the logs: docker logs --tail 50 <name>
Common causes — a config error, no database access, out of memory")" "$DBAD"
fi
[ -f /var/run/reboot-required ] && note "$(L "Система просит перезагрузку после установки обновлений (/var/run/reboot-required)." "The system asks for a reboot after installing updates (/var/run/reboot-required).")"
ZOMB=$(ps -eo stat= 2>/dev/null | awk '/^Z/{n++} END{print n+0}')
[ "$ZOMB" -ge 50 ] && note "$(L "Процессов-зомби: $ZOMB — какая-то программа не «прибирает» за своими дочерними процессами (обычно безвредно)." "Zombie processes: $ZOMB — some program does not reap its children (usually harmless).")"
run "ps aux --sort=-%cpu | head -12"
run "ps aux --sort=-rss | head -12"
if [ "$FULL" = 1 ] && has journalctl; then run "journalctl -p err -b --since -24h -q --no-pager -o cat | sort | uniq -c | sort -rn | head -15"; fi
OK[svc]="$(L "упавших служб нет" "no failed services")$([ "$NRUN" -gt 0 ] && L " (работает: $NRUN)" " ($NRUN running)")"

# ================================================================== NETWORK / TIME
say "$(L "• сеть и время: DNS, интернет, потери, MTU, часы" "• network & time: DNS, internet, loss, MTU, clock")"
sec "Network"
run "ip -br addr 2>/dev/null; ip route 2>/dev/null | head -12; ip -6 route show default 2>/dev/null"
run "grep -vE '^\s*(#|$)' /etc/resolv.conf"
run "ss -tulpn 2>/dev/null | head -40"
NET_OK=1 INET=0 DNS=0
DEFR=$(ip route show default 2>/dev/null | head -1); [ -n "$DEFR" ] || DEFR=$(ip -6 route show default 2>/dev/null | head -1)
for h in 1.1.1.1 8.8.8.8 77.88.8.8; do tcp_ok "$h" 443 && { INET=1; break; }; done
for n in google.com cloudflare.com ya.ru; do timeout 4 getent ahosts "$n" >/dev/null 2>&1 && { DNS=1; break; }; done
if [ -z "$DEFR" ] && [ "$INET" = 0 ]; then
  NET_OK=0
  add 2 net 88 h "$(L "Нет маршрута в интернет (не задан шлюз по умолчанию)" "No route to the internet (no default gateway)")" \
    "$(L "Сервер не знает, куда отправлять пакеты за пределы своей сети, поэтому снаружи он недоступен, а сам не может ничего скачать." "The server does not know where to send packets outside its network, so it is unreachable and cannot download anything.")" \
    "$(L "Проверьте сетевые настройки (netplan / /etc/network/interfaces / NetworkManager) — их могли изменить
Сверьте IP, маску и шлюз с данными в панели хостера
Если доступ есть только через консоль хостера — исправьте настройки там или обратитесь в поддержку" \
         "Check the network config (netplan / /etc/network/interfaces / NetworkManager) — it may have been changed
Compare IP, netmask and gateway with your provider's panel
If you only have the provider's console, fix it there or contact support")" "$(ip -br addr 2>/dev/null)"
elif [ "$INET" = 0 ]; then
  NET_OK=0
  add 2 net 86 m "$(L "Нет выхода в интернет: не открываются соединения к 1.1.1.1, 8.8.8.8, 77.88.8.8" "No internet access: connections to 1.1.1.1, 8.8.8.8, 77.88.8.8 fail")" \
    "$(L "Сервер не может подключиться наружу. Причина — файрвол, блокировка у хостера или сбой сети. Если сервер намеренно изолирован — это нормально." \
         "The server cannot connect out. Causes: a firewall, a block at the provider or a network fault. If the server is isolated on purpose, this is fine.")" \
    "$(L "Проверьте файрвол на исходящие соединения (iptables -S / nft list ruleset / ufw status)
Проверьте, не заблокирован ли сервер хостером (письма от хостера, статус в панели)
Сообщите хостеру, если файрвол ни при чём" \
         "Check the firewall for outgoing connections (iptables -S / nft list ruleset / ufw status)
Check whether the provider blocked the server (provider e-mails, panel status)
Contact the provider if the firewall is not the cause")" "default route: ${DEFR:-none}"
elif [ "$DNS" = 0 ]; then
  NET_OK=0
  add 2 net 87 h "$(L "Не работает DNS: имена сайтов не превращаются в адреса (интернет при этом есть)" "DNS is broken: names do not resolve to addresses (the internet itself works)")" \
    "$(L "Сервер не может узнать адрес по имени (google.com и т.п.), поэтому не работают обновления, отправка почты, запросы к API — всё, что обращается по имени." \
         "The server cannot resolve names (google.com etc.), so updates, outgoing mail, API calls — everything that uses names — fail.")" \
    "$(L "Посмотрите, какие DNS-серверы указаны: cat /etc/resolv.conf (и resolvectl status)
Пропишите рабочие DNS — от хостера или публичные, например 1.1.1.1 и 8.8.8.8
Проверьте, не блокирует ли файрвол порт 53" \
         "See which DNS servers are configured: cat /etc/resolv.conf (and resolvectl status)
Set working DNS servers — your provider's or public ones such as 1.1.1.1 and 8.8.8.8
Check that the firewall does not block port 53")" "$(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null)"
fi
# IPv6 configured but broken
if [ "$INET" = 1 ] && ip -6 route show default 2>/dev/null | grep -q . && ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
  tcp_ok 2606:4700:4700::1111 443 || tcp_ok 2001:4860:4860::8888 443 || add 1 net 40 m "$(L "IPv6 настроен, но не работает" "IPv6 is configured but does not work")" \
    "$(L "Программы сначала пробуют IPv6 и долго ждут ответа — отсюда «подвисания» при обновлениях, curl и отправке почты." "Programs try IPv6 first and wait for a long time — hence hangs in updates, curl and mail.")" \
    "$(L "Сверьте IPv6-адрес и шлюз с панелью хостера
Если IPv6 не нужен — попросите специалиста корректно отключить его" "Compare the IPv6 address and gateway with your provider's panel
If IPv6 is not needed, have an admin disable it properly")" "$(ip -6 route show default 2>/dev/null | head -2)"
fi
# packet loss and MTU
PING_RES=''
if [ "$INET" = 1 ] && has ping; then
  PING_RES=$(timeout 8 ping -n -c 5 -i 0.2 -W 2 -q 1.1.1.1 2>&1)
  LOSS=$(printf '%s' "$PING_RES" | grep -oE '[0-9.]+% packet loss' | cut -d% -f1 | cut -d. -f1)
  RTT=$(printf '%s' "$PING_RES" | awk -F'/' '/^(rtt|round-trip)/{print $5}')
  printf '%s\n' '$ ping -c 5 1.1.1.1' "$PING_RES" >> "$TECH"
  if [ "${LOSS:-100}" -ge 100 ]; then
    note "$(L "Ping (ICMP) до интернета не проходит, хотя соединения работают — ICMP просто фильтруется, это не ошибка." "Ping (ICMP) does not pass although connections work — ICMP is filtered; not an error.")"
  else
    if [ "${LOSS:-0}" -ge 20 ]; then
      add 1 net 46 m "$(L "Потери пакетов до интернета: $LOSS%" "Packet loss to the internet: $LOSS%")" \
        "$(L "Часть пакетов теряется по дороге. Сайты открываются с задержками, SSH «подтормаживает», загрузки обрываются." "Some packets are lost on the way. Sites load with delays, SSH lags, downloads break.")" \
        "$(L "Повторите проверку через несколько минут — разовая ли это проблема
Если повторяется — напишите хостеру: «потери пакетов $LOSS% до 1.1.1.1», приложите результат mtr -rwc 50 1.1.1.1" \
             "Re-run the check in a few minutes — is it a one-off?
If it repeats, tell your provider: “$LOSS% packet loss to 1.1.1.1” and attach mtr -rwc 50 1.1.1.1")" "$PING_RES"
    fi
    IFMTU=$(ip route get 1.1.1.1 2>/dev/null | grep -oE 'dev [^ ]+' | awk '{print $2}' | head -1)
    IFMTU=$(cat "/sys/class/net/${IFMTU:-none}/mtu" 2>/dev/null)
    if [ "${IFMTU:-0}" -ge 1500 ]; then
      BIG=$(timeout 6 ping -n -c 2 -W 2 -M "do" -s 1472 1.1.1.1 2>&1)
      if printf '%s' "$BIG" | grep -qE ' 0 received|100% packet loss' && ! printf '%s' "$BIG" | grep -qiE 'too long|mtu|invalid|usage'; then
        add 1 net 35 l "$(L "Возможна проблема MTU: большие пакеты (1500 байт) теряются, маленькие проходят" "Possible MTU problem: large packets (1500 bytes) are lost while small ones pass")" \
          "$(L "Если по пути есть туннель или VPN с меньшим MTU, большие пакеты пропадают: сайты открываются частично, SSH зависает при выводе большого текста, загрузки «замирают»." \
               "If a tunnel/VPN with a smaller MTU is on the path, large packets vanish: pages load partially, SSH hangs on large output, downloads stall.")" \
          "$(L "Если такие симптомы есть — попробуйте временно MTU 1400 на сетевом интерфейсе и сравните
Сообщите хостеру: «теряются пакеты 1500 байт с флагом DF»" "If you see such symptoms, temporarily try MTU 1400 on the interface and compare
Tell your provider: “1500-byte packets with DF are dropped”")" "$BIG"
      fi
    fi
  fi
fi
# physical NIC errors / duplex / speed
NICEV=''
for n in /sys/class/net/*; do
  [ -e "$n/device" ] || continue
  i=${n##*/}; [ "$(cat "$n/operstate" 2>/dev/null)" = up ] || continue
  rxe=$(cat "$n/statistics/rx_errors" 2>/dev/null || echo 0); txe=$(cat "$n/statistics/tx_errors" 2>/dev/null || echo 0)
  rxp=$(cat "$n/statistics/rx_packets" 2>/dev/null || echo 0); txp=$(cat "$n/statistics/tx_packets" 2>/dev/null || echo 0)
  dup=$(cat "$n/duplex" 2>/dev/null); spd=$(cat "$n/speed" 2>/dev/null)
  err=$((rxe + txe)); pk=$((rxp + txp + 1))
  [ "$err" -ge 1000 ] && [ $((err * 1000000 / pk)) -ge 100 ] && NICEV="$NICEV$i: rx_errors=$rxe tx_errors=$txe of $pk packets; "
  [ "$dup" = half ] && NICEV="$NICEV$i: half duplex; "
  [ "$IS_VM" = 0 ] && [ "${spd:--1}" -gt 0 ] 2>/dev/null && [ "$spd" -le 100 ] && NICEV="$NICEV$i: link speed ${spd} Mbit/s; "
done
[ -n "$NICEV" ] && add 1 net 44 m "$(L "Сетевая карта работает с ошибками или на низкой скорости: $NICEV" "The network card has errors or a low link speed: $NICEV")" \
  "$(L "Ошибки приёма/передачи, полудуплекс или скорость 100 Мбит/с обычно означают плохой кабель, порт коммутатора или драйвер." "Receive/transmit errors, half duplex or 100 Mbit/s usually mean a bad cable, switch port or driver.")" \
  "$(L "Попросите дата-центр проверить кабель и порт коммутатора
Проверьте настройки скорости/дуплекса (ethtool <интерфейс>)" "Ask the data center to check the cable and the switch port
Check speed/duplex settings (ethtool <interface>)")" "$NICEV"
# conntrack table
CTC=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null); CTM=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)
CTF=$(kgrep 7 'nf_conntrack: (nf_conntrack: )?table full')
CTP=0; [ "${CTM:-0}" -gt 0 ] && CTP=$((CTC * 100 / CTM))
if [ -n "$CTF" ] || [ "$CTP" -ge 75 ]; then
  sev=1 sc=50; { [ -n "$CTF" ] || [ "$CTP" -ge 90 ]; } && { sev=2; sc=83; }
  add "$sev" net "$sc" h "$(L "Таблица соединений (conntrack) переполнена: $CTP%$([ -n "$CTF" ] && echo ', пакеты отбрасывались')" "The connection-tracking table is full: $CTP%$([ -n "$CTF" ] && echo ', packets were dropped')")" \
    "$(L "Файрвол запоминает каждое соединение. Когда таблица полна, новые соединения молча отбрасываются — сайт «иногда не открывается». Бывает при большом трафике или DDoS." \
         "The firewall tracks every connection. When the table is full, new connections are silently dropped — the site “sometimes does not open”. Happens under heavy traffic or DDoS.")" \
    "$(L "Проверьте, нет ли атаки или аномального трафика (ss -s, кто открывает соединения)
Увеличьте лимит net.netfilter.nf_conntrack_max (попросите специалиста)
Если это DDoS — включите защиту у хостера/Cloudflare" "Check for an attack or abnormal traffic (ss -s, who opens connections)
Raise net.netfilter.nf_conntrack_max (ask an admin)
If it is a DDoS — enable protection at your provider/Cloudflare")" "conntrack $CTC / $CTM; $(printf '%s\n' "$CTF" | tail -n 2)"
fi
# time
sec "Time"
run "timedatectl 2>/dev/null; chronyc -n tracking 2>/dev/null | head -12"
SYNC=''
if has timedatectl; then SYNC=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
  [ -n "$SYNC" ] || SYNC=$(timedatectl status 2>/dev/null | awk -F': ' '/(NTP|System clock) synchronized/{print $2; exit}'); fi
DRIFT=''
if [ "$INET" = 1 ]; then RD=$(http_date); [ -n "$RD" ] && DRIFT=$(( $(date +%s) - RD )); fi
AD=${DRIFT#-}
if [ -n "$AD" ] && [ "$AD" -ge 10 ]; then
  sev=1 sc=50; [ "$AD" -ge 120 ] && { sev=2; sc=75; }
  add "$sev" net "$sc" h "$(L "Часы сервера отстают/спешат на $AD секунд" "The server clock is off by $AD seconds")" \
    "$(L "Неточное время ломает HTTPS-сертификаты, вход по одноразовым кодам (2FA), подписи API, порядок записей в логах и расписание задач." \
         "A wrong clock breaks HTTPS certificates, one-time codes (2FA), API signatures, log order and job schedules.")" \
    "$(L "Включите автоматическую синхронизацию времени: sudo timedatectl set-ntp true (или установите chrony)
Проверьте результат: timedatectl (должно быть «System clock synchronized: yes»)
Если сервер виртуальный и часы снова уходят — сообщите хостеру" \
         "Enable automatic time sync: sudo timedatectl set-ntp true (or install chrony)
Check: timedatectl (should say “System clock synchronized: yes”)
If the server is virtual and the clock drifts again, tell your provider")" "local clock - HTTP Date = ${DRIFT}s; NTPSynchronized=${SYNC:-unknown}"
elif [ "$SYNC" = no ] && [ "$CONT" = 0 ]; then
  add 1 net 38 h "$(L "Часы не синхронизируются с интернетом (сейчас время ещё точное)" "The clock is not synchronized with the internet (it is still accurate for now)")" \
    "$(L "Без синхронизации часы постепенно уходят, и через недели начнутся проблемы с сертификатами, 2FA и логами." "Without sync the clock drifts, and in weeks certificates, 2FA and logs will have problems.")" \
    "$(L "Включите синхронизацию: sudo timedatectl set-ntp true (или установите chrony)
Проверьте: timedatectl" "Enable sync: sudo timedatectl set-ntp true (or install chrony)
Check: timedatectl")" "NTPSynchronized=no; drift ${DRIFT:-unknown}s"
fi
NOK="$(L "интернет и DNS работают" "internet and DNS work")"
[ -n "${RTT:-}" ] && NOK="$NOK, ping ${RTT%.*} ms"
[ -n "$DRIFT" ] && NOK="$NOK, $(L "часы точные (±${AD} с)" "clock accurate (±${AD} s)")"
[ "$NET_OK" = 1 ] && OK[net]=$NOK

# journal coverage (after the services check: a restart loop is a typical journal flooder)
if [ -z "$J_FIRST" ] && has journalctl; then :
elif [ "$J_PERSIST" = 0 ] && has journalctl; then
  limit "$(L "Журнал systemd не сохраняется на диск: после перезагрузки история стирается, поэтому прошлые сбои не видны. Чтобы видеть их в будущем: sudo mkdir -p /var/log/journal (это уже изменение — решайте сами)." \
             "The systemd journal is not stored on disk: history is lost on reboot, so past crashes are invisible. To keep it in future: sudo mkdir -p /var/log/journal (that is a change — your call).")"
elif [ -n "$J_DAYS" ] && [ "$J_DAYS" -lt 7 ]; then
  JW=''; [ -n "${RL:-}" ] && JW="$(L " Возможно, его забивает служба, которая постоянно перезапускается (см. выше)." " It may be flooded by the service that keeps restarting (see above).")"
  limit "$(L "Журнал событий хранит всего $J_DUR (с $(fdate "$JF")) — сбои до этой даты не видны. Обычно журнал ограничен по размеру (SystemMaxUse в /etc/systemd/journald.conf).$JW" \
             "The event journal covers only $J_DUR (since $(fdate "$JF")) — earlier crashes are invisible. The journal is usually capped by size (SystemMaxUse in /etc/systemd/journald.conf).$JW")"
fi
# ================================================================== VERDICT
ORDER=$(for ((i=0; i<FN; i++)); do printf '%s %s\n' "${F_SC[i]}" "$i"; done | sort -k1,1nr -k2,2n | awk '{print $2}')
declare -A AW=() AT=() AN=()
for i in $ORDER; do
  a=${F_AREA[i]}; AN[$a]=$(( ${AN[$a]:-0} + 1 ))
  if [ "${F_SEV[i]}" -gt "${AW[$a]:-0}" ]; then AW[$a]=${F_SEV[i]}; AT[$a]=${F_T[i]}; fi
done
WORST=0; for a in disk mem cpu crash svc net; do [ "${AW[$a]:-0}" -gt "$WORST" ] && WORST=${AW[$a]}; done
MAIN=$(printf '%s\n' "$ORDER" | head -n 1)
ELAPSED=$(( $(date +%s) - T_START ))
REPORT=''
if [ "$HTML" = 1 ]; then
  D=''
  for d in "$OUTDIR" "$PWD" "$HOME" /tmp; do [ -n "$d" ] && [ "$d" != / ] && [ -d "$d" ] && [ -w "$d" ] && { D=$d; break; }; done
  if [ -n "$D" ]; then
    REPORT="$D/server-diag-report-$HOST-$(date +%Y-%m-%d).html"
    [ -e "$REPORT" ] && REPORT="$D/server-diag-report-$HOST-$(date +%Y-%m-%d-%H%M%S).html"
    html_report > "$REPORT" 2>/dev/null || REPORT=''
  fi
fi
print_verdict
}

# ====================================================================== helpers
L() { if [ "$LNG" = en ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }
has() { command -v "$1" >/dev/null 2>&1; }
command -v timeout >/dev/null 2>&1 || timeout() { shift; "$@"; }
say() { printf '%s\n' "${DI}$*${NC}" >&2; }
sec() { printf '\n=== %s\n' "$*" >> "$TECH"; }
run() { { printf '$ %s\n' "$*"; timeout 20 bash -c "$*" 2>&1 | head -n 120; } >> "$TECH"; }
add() { F_SEV[FN]=$1; F_AREA[FN]=$2; F_SC[FN]=$3; F_CONF[FN]=$4; F_T[FN]=$5; F_WHY[FN]=$6; F_DO[FN]=$7; F_EV[FN]=${8:-}
        [ "$4" = l ] && F_SC[FN]=$(( $3 - 10 )); FN=$((FN + 1)); }
note() { NOTES+=("$*"); }
limit() { LIMITS+=("$*"); }
lc() { printf '%s\n' "$1" | grep -c .; }
fgt() { [ -n "$1" ] && awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 > b+0)}'; }
human() { awk -v k="${1:-0}" -v u="$(L 'КБ МБ ГБ ТБ ПБ' 'KB MB GB TB PB')" 'BEGIN{n=split(u,a," "); i=1; while (k>=1024 && i<n) {k/=1024; i++} printf (k<10 ? "%.1f %s" : "%.0f %s"), k, a[i]}'; }
dur() { local s=$1 d h m; d=$((s/86400)); h=$((s%86400/3600)); m=$((s%3600/60))
        if [ "$d" -gt 0 ]; then L "$d дн. $h ч" "${d}d ${h}h"; elif [ "$h" -gt 0 ]; then L "$h ч $m мин" "${h}h ${m}m"; else L "$m мин" "${m} min"; fi; }
fdate() { if [ "$LNG" = en ]; then date -d "@$1" '+%Y-%m-%d %H:%M'; else date -d "@$1" '+%d.%m.%Y %H:%M'; fi; }
psi() { [ -r "/proc/pressure/$1" ] && awk -v k="$2" -v f="$3" '$1==k{for(i=2;i<=NF;i++){split($i,a,"="); if(a[1]==f) print a[2]}}' "/proc/pressure/$1"; }
cpu_snap() { awk '/^cpu /{print $2+$3+$4+$7+$8, $5, $6, $9+0, $2+$3+$4+$5+$6+$7+$8+$9}' /proc/stat; }
swp_snap() { awk '/^pswpin /{i=$2} /^pswpout /{o=$2} END{print i+0, o+0}' /proc/vmstat; }
dproc() { ps -eo pid=,stat= 2>/dev/null | awk '$2 ~ /^D/{print $1}' | sort; }
proc_snap() { awk '{i=index($0,"("); j=match($0,/\) [A-Za-z] /); if(!i||!j) next; c=substr($0,i+1,j-i-1); split(substr($0,j+2),a," "); print $1"\t"(a[12]+a[13])"\t"c}' /proc/[0-9]*/stat 2>/dev/null; }
tcp_ok() { timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }
kgrep() { # kgrep DAYS(1|7|30) REGEX [EXCLUDE-REGEX] -> matching kernel log lines within DAYS
  local c=0; [ "$1" = 1 ] && c=$CUT1; [ "$1" = 7 ] && c=$CUT7
  awk -v c="$c" 'substr($0,1,19) >= c' "$KLOG" | grep -aiE -- "$2" | if [ -n "${3:-}" ]; then grep -aivE -- "$3"; else cat; fi
}
http_date() { local u h
  for u in http://www.google.com/ http://www.cloudflare.com/ http://ya.ru/; do
    if has curl; then h=$(curl -sI --max-time 4 "$u" 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="date"{print $2; exit}')
    elif has wget; then h=$(wget -qS --spider -T 4 -t 1 "$u" 2>&1 | tr -d '\r' | awk -F': ' 'tolower($1)~/^ *date$/{print $2; exit}')
    else return; fi
    [ -n "$h" ] && date -d "$h" +%s 2>/dev/null && return
  done; }
temps() { # sensor|label|°C|max|crit for every readable hwmon / thermal sensor (bogus values skipped)
  local h n f b v mx cr lab
  for h in /sys/class/hwmon/hwmon*; do
    n=$(cat "$h/name" 2>/dev/null)
    for f in "$h"/temp*_input; do
      [ -r "$f" ] || continue; b=${f%_input}; v=$(cat "$f" 2>/dev/null) || continue
      mx=$(cat "${b}_max" 2>/dev/null); cr=$(cat "${b}_crit" 2>/dev/null); lab=$(cat "${b}_label" 2>/dev/null)
      awk -v n="$n" -v l="${lab:-${b##*/}}" -v v="$v" -v mx="${mx:-0}" -v cr="${cr:-0}" 'BEGIN{t=v/1000; if (t>5 && t<125) printf "%s|%s|%.0f|%.0f|%.0f\n", n, l, t, (mx/1000<125?mx/1000:0), (cr/1000<130?cr/1000:0)}'
    done
  done
  if ! ls /sys/class/hwmon/hwmon*/temp*_input >/dev/null 2>&1; then
    for h in /sys/class/thermal/thermal_zone*; do
      [ -r "$h/temp" ] || continue; n=$(cat "$h/type" 2>/dev/null); v=$(cat "$h/temp" 2>/dev/null)
      awk -v n="$n" -v v="$v" 'BEGIN{t=v/1000; if (t>5 && t<125) printf "%s|zone|%.0f|0|0\n", (n=="x86_pkg_temp"?"x86_pkg_temp":n), t}'
    done
  fi; }
smart_check() { # $1 device, $2 smartctl -d type (may be empty) -> adds findings, counts SM_OK / SM_NA / SM_SLEEP
  local d=$1 t=$2 rc model rot realloc pend offu repu crc life pu mde spare sthr temp wt ct gd sev=0 sc=0 pr='' pe=''
  if [ -n "$t" ]; then SM=$(timeout 25 smartctl -a -n standby -d "$t" "$d" 2>&1); else SM=$(timeout 25 smartctl -a -n standby "$d" 2>&1); fi
  rc=$?
  { echo "\$ smartctl -a -n standby ${t:+-d $t }$d"; printf '%s\n' "$SM" | grep -vE '^(smartctl |Copyright|=== START)' | head -n 70; } >> "$TECH"
  if printf '%s' "$SM" | grep -qiE 'in (STANDBY|SLEEP) mode'; then SM_SLEEP=$((SM_SLEEP+1)); return; fi
  if printf '%s' "$SM" | grep -qiE 'SMART support is: *(Unavailable|Disabled)|lacks SMART capability|Unable to detect device type|Unknown USB bridge' || [ $((rc & 2)) -ne 0 ]; then SM_NA="$SM_NA $d"; return; fi
  model=$(printf '%s\n' "$SM" | awk -F': *' '/^(Device Model|Model Number|Product):/{print $2; exit}')
  rot=$(printf '%s\n' "$SM" | awk -F': *' '/^Rotation Rate:/{print $2; exit}')
  realloc=$(sm_attr Reallocated_Sector_Ct); pend=$(sm_attr Current_Pending_Sector); offu=$(sm_attr Offline_Uncorrectable)
  repu=$(sm_attr Reported_Uncorrect); crc=$(sm_attr UDMA_CRC_Error_Count)
  life=$(for a in Media_Wearout_Indicator Wear_Leveling_Count SSD_Life_Left Percent_Lifetime_Remain Remaining_Lifetime_Perc; do sm_norm "$a"; done | sort -n | head -1)
  pu=$(sm_kv 'Percentage Used:'); mde=$(sm_kv 'Media and Data Integrity Errors:'); spare=$(sm_kv 'Available Spare:'); sthr=$(sm_kv 'Available Spare Threshold:')
  gd=$(sm_kv 'Elements in grown defect list:')
  temp=$(sm_kv 'Temperature:'); [ -n "$temp" ] || temp=$(sm_attr Temperature_Celsius); [ -n "$temp" ] || temp=$(sm_attr Airflow_Temperature_Cel); [ -n "$temp" ] || temp=$(sm_kv 'Current Drive Temperature:')
  wt=$(sm_kv 'Warning  Comp. Temp. Threshold:'); ct=$(sm_kv 'Critical Comp. Temp. Threshold:')
  p() { pr="$pr$(L "$1" "$2"); "; }
  if printf '%s' "$SM" | grep -qiE 'self-assessment test result: *FAILED|SMART Health Status: *(FAIL|IMPENDING|DATA CHANNEL)' || [ $((rc & 8)) -ne 0 ]; then sev=2 sc=98; p "SMART: диск сам сообщает о неисправности (FAILED)" "SMART: the disk reports itself as FAILING"; fi
  printf '%s' "$SM" | grep -qiE 'Critical Warning: +0x0*[1-9a-f]' && { sev=2; sc=98; p "NVMe: критическое предупреждение" "NVMe critical warning"; }
  [ "${pend:-0}" -gt 0 ] && { sev=2; sc=98; p "нечитаемых секторов: $pend" "$pend unreadable (pending) sectors"; }
  [ "${offu:-0}" -gt 0 ] && { sev=2; sc=97; p "неисправимых секторов: $offu" "$offu uncorrectable sectors"; }
  [ "${mde:-0}" -gt 0 ] && { sev=2; sc=97; p "ошибок целостности данных NVMe: $mde" "$mde NVMe media/data integrity errors"; }
  [ -n "$spare" ] && [ -n "$sthr" ] && [ "$sthr" -gt 0 ] && [ "$spare" -lt "$sthr" ] && { sev=2; sc=96; p "резерв NVMe исчерпан ($spare% < $sthr%)" "NVMe spare exhausted ($spare% < $sthr%)"; }
  [ "${realloc:-0}" -ge 100 ] && { sev=2; [ "$sc" -lt 95 ] && sc=95; p "переназначено секторов: $realloc" "$realloc reallocated sectors"; }
  [ "${repu:-0}" -gt 0 ] && { sev=2; [ "$sc" -lt 90 ] && sc=90; p "ошибок чтения, о которых диск сообщил системе: $repu" "$repu uncorrectable errors reported to the host"; }
  [ "${pu:-0}" -ge 100 ] && { sev=2; [ "$sc" -lt 88 ] && sc=88; p "ресурс NVMe исчерпан: $pu%" "NVMe endurance used up: $pu%"; }
  if [ "$sev" -lt 2 ]; then
    [ "${realloc:-0}" -gt 0 ] && { sev=1; sc=66; p "переназначено секторов: $realloc" "$realloc reallocated sectors"; }
    [ "${gd:-0}" -gt 0 ] && { sev=1; sc=64; p "дефектов в списке: $gd" "$gd grown defects"; }
    [ "${pu:-0}" -ge 90 ] && { sev=1; [ "$sc" -lt 60 ] && sc=60; p "ресурс NVMe израсходован на $pu%" "NVMe endurance $pu% used"; }
    [ -n "$life" ] && [ "$life" -le 10 ] && { sev=1; [ "$sc" -lt 60 ] && sc=60; p "остаток ресурса SSD: ~$life%" "SSD life left: ~$life%"; }
    [ "${crc:-0}" -gt 10 ] && { sev=1; [ "$sc" -lt 40 ] && sc=40; p "ошибок передачи по кабелю: $crc (кабель/разъём)" "$crc interface CRC errors (cable/connector)"; }
  fi
  if [ -n "$temp" ] && [ "$temp" -gt 0 ] 2>/dev/null; then
    local tw=70 tc=80; case $rot in *rpm*) tw=55; tc=65 ;; esac
    [ -n "$wt" ] && [ "$wt" -gt 40 ] && tw=$wt; [ -n "$ct" ] && [ "$ct" -gt 40 ] && tc=$ct
    if [ "$temp" -ge "$tc" ]; then sev=2; [ "$sc" -lt 86 ] && sc=86; p "температура $temp°C (критическая)" "temperature $temp°C (critical)"
    elif [ "$temp" -ge "$tw" ]; then [ "$sev" -lt 1 ] && sev=1; [ "$sc" -lt 55 ] && sc=55; p "температура $temp°C (высокая)" "temperature $temp°C (high)"; fi
  fi
  pe="SMART $d ${model:+($model) }: realloc=${realloc:--} pending=${pend:--} offline_unc=${offu:--} reported_unc=${repu:--} crc=${crc:--} nvme_used=${pu:--}% media_err=${mde:--} spare=${spare:--}/${sthr:--} grown_defects=${gd:--} life=${life:--} temp=${temp:--}C"
  if [ "$sev" = 0 ]; then SM_OK=$((SM_OK+1)); return; fi
  pr=${pr%; }
  if [ "$sev" = 2 ]; then
    add 2 disk "$sc" h "$(L "Диск $d ${model:+($model) }неисправен или отказывает: $pr" "Disk $d ${model:+($model) }is failing: $pr")" \
      "$(L "Сам диск сообщает о проблемах с поверхностью/памятью. Такой диск может отказать в любой момент, а часть данных уже может не читаться." \
           "The disk itself reports media problems. It can fail at any moment, and some data may already be unreadable.")" \
      "$(L "Немедленно сделайте копию важных данных на другой диск или сервер
Попросите хостера/дата-центр заменить диск: «SMART errors on $d (${model:-disk}), please replace», приложите этот отчёт
Если диск в RAID — после замены дождитесь окончания пересборки" \
           "Back up important data to another disk/server immediately
Ask your provider / data center to replace the disk: “SMART errors on $d (${model:-disk}), please replace” and attach this report
If the disk is in a RAID, wait for the rebuild to finish after the replacement")" "$pe"
  else
    add 1 disk "$sc" h "$(L "Диск $d ${model:+($model) }начинает изнашиваться: $pr" "Disk $d ${model:+($model) }shows early wear: $pr")" \
      "$(L "Диск работает, но есть первые признаки износа или проблем. Если значения растут — диск скоро откажет." \
           "The disk works, but shows first signs of wear or trouble. If the numbers grow, it will fail soon.")" \
      "$(L "Держите свежий бэкап важных данных
Повторите проверку через неделю: если значения выросли — меняйте диск
Высокая температура — попросите дата-центр проверить охлаждение" \
           "Keep a fresh backup of important data
Re-run the check in a week: if the numbers grew, replace the disk
High temperature — ask the data center to check cooling")" "$pe"
  fi; }
sm_attr() { printf '%s\n' "$SM" | awk -v n="$1" '$2==n{v=$10; sub(/[^0-9].*/,"",v); print v+0; exit}'; }
sm_norm() { printf '%s\n' "$SM" | awk -v n="$1" '$2==n{print $4+0; exit}'; }
sm_kv() { printf '%s\n' "$SM" | awk -v k="$1" 'index($0,k)==1{v=substr($0,length(k)+1); gsub(/,/,"",v); if (match(v,/[0-9]+/)) print substr(v,RSTART,RLENGTH); exit}'; }
pad() { local s=$1; while [ "${#s}" -lt "$2" ]; do s="$s "; done; printf '%s' "$s"; }
area_name() { case $1 in
  disk) L "Диски" "Disks" ;; mem) L "Память (ОЗУ)" "Memory (RAM)" ;; cpu) L "Процессор и температура" "CPU & temperature" ;;
  crash) L "Сбои и перезагрузки" "Crashes & reboots" ;; svc) L "Службы и программы" "Services & programs" ;; net) L "Сеть и время" "Network & time" ;; esac; }
kind() { if [ "$IS_VM" = 1 ]; then L "виртуальный ($VIRT)" "virtual ($VIRT)"; else L "физический" "physical"; fi; }
light() { case $1 in 2) printf '🔴' ;; 1) printf '🟡' ;; *) printf '🟢' ;; esac; }
conf_name() { case $1 in h) L "высокая" "high" ;; m) L "средняя" "medium" ;; *) L "низкая" "low" ;; esac; }
esc() { local s=$1; s=${s//&/"&amp;"}; s=${s//</"&lt;"}; s=${s//>/"&gt;"}; printf '%s' "$s"; }   # quoted: bash 5.2 treats a bare & as the match
overall() { case $WORST in
  2) L "ЕСТЬ СЕРЬЁЗНАЯ ПРОБЛЕМА" "A SERIOUS PROBLEM WAS FOUND" ;;
  1) L "РАБОТАЕТ, НО ЕСТЬ НА ЧТО ОБРАТИТЬ ВНИМАНИЕ" "WORKING, BUT SOME THINGS NEED ATTENTION" ;;
  *) L "ВСЁ В НОРМЕ — серьёзных проблем не найдено" "ALL GOOD — no serious problems found" ;; esac; }
noprob_steps() { L "Ничего срочного делать не нужно — сервер в порядке
Если сервер всё равно «тормозит» или падает — запустите проверку ещё раз прямо в момент проблемы: так видно, что именно перегружено
Сохраните этот отчёт: при следующей проблеме будет с чем сравнить" \
"Nothing urgent to do — the server is healthy
If it still feels slow or crashes, run the check again right when the problem happens: that shows what is overloaded
Keep this report: next time you will have something to compare with"; }

print_verdict() {
  local a w i n=0 c line W=0 first rest
  for a in disk mem cpu crash svc net; do n=$(area_name "$a"); [ "${#n}" -gt "$W" ] && W=${#n}; done
  case $WORST in 2) c=$RE ;; 1) c=$YE ;; *) c=$GR ;; esac
  line='══════════════════════════════════════════════════════════════════════'
  printf '\n%s\n' "$line"
  printf ' %s%s%s · %s · %s\n' "$BO" "$(L "ДИАГНОСТИКА СЕРВЕРА" "SERVER DIAGNOSTICS")" "$NC" "$HOST" "$(fdate "$NOW")"
  printf ' %s · %s %s · %s %s · %s %s · %s\n' "$OS" "$(L "ядро" "kernel")" "$KERNEL" "$CORES" "$(L "ядер" "cores")" "$(human "$MEM_T")" "$(L "ОЗУ" "RAM")" \
    "$(kind), $(L "работает" "up") $(dur "$UP_S")"
  printf '%s\n\n' "$line"
  printf ' %s%s: %s %s%s\n\n' "$BO$c" "$(L "ИТОГ" "RESULT")" "$(light "$WORST")" "$(overall)" "$NC"
  for a in disk mem cpu crash svc net; do
    w=${AW[$a]:-0}
    case $w in 2) c=$RE ;; 1) c=$YE ;; *) c=$GR ;; esac
    if [ "$w" = 0 ]; then
      if [ -n "${OK[$a]:-}" ]; then txt="$(L "норма" "OK") — ${OK[$a]}"; else txt="$(L "норма (проверено частично)" "OK (partially checked)")"; fi
    else txt=${AT[$a]}; [ "${AN[$a]}" -gt 1 ] && txt="$txt $(L "(+ ещё $(( ${AN[$a]} - 1 )))" "(+$(( ${AN[$a]} - 1 )) more)")"; fi
    printf ' %s %s%s%s  %s\n' "$(light "$w")" "$c" "$(pad "$(area_name "$a")" "$W")" "$NC" "$txt"
  done
  printf '\n'
  if [ -n "$MAIN" ]; then
    printf ' %s%s%s  %s(%s: %s)%s\n' "$BO" "$(L "ГЛАВНАЯ ПРИЧИНА" "MAIN CAUSE")" "$NC" "$DI" "$(L "уверенность" "confidence")" "$(conf_name "${F_CONF[MAIN]}")" "$NC"
    printf '   %s %s\n' "$(light "${F_SEV[MAIN]}")" "${F_T[MAIN]}"
    printf '   %s\n\n' "${F_WHY[MAIN]}"
    printf ' %s%s%s\n' "$BO" "$(L "ЧТО СДЕЛАТЬ" "WHAT TO DO")" "$NC"
    i=0; while IFS= read -r s; do [ -n "$s" ] || continue; i=$((i+1)); [ "$i" -le 3 ] && printf '   %s) %s\n' "$i" "$s"; done <<< "${F_DO[MAIN]}"
    rest=$(printf '%s\n' "$ORDER" | tail -n +2)
    if [ -n "$rest" ]; then
      printf '\n %s%s%s\n' "$BO" "$(L "ЕЩЁ ЗАМЕЧЕНО" "ALSO FOUND")" "$NC"
      for i in $rest; do first=$(printf '%s\n' "${F_DO[i]}" | head -n 1)
        printf '   %s %s\n      → %s\n' "$(light "${F_SEV[i]}")" "${F_T[i]}" "$first"; done
    fi
  else
    printf ' %s%s%s\n   🟢 %s\n\n' "$BO" "$(L "ГЛАВНАЯ ПРИЧИНА" "MAIN CAUSE")" "$NC" "$(L "проблем не найдено — все проверенные области в норме." "no problems found — every checked area is fine.")"
    printf ' %s%s%s\n' "$BO" "$(L "ЧТО СДЕЛАТЬ" "WHAT TO DO")" "$NC"
    i=0; while IFS= read -r s; do i=$((i+1)); printf '   %s) %s\n' "$i" "$s"; done <<< "$(noprob_steps)"
  fi
  if [ "${#NOTES[@]}" -gt 0 ] || [ "${#LIMITS[@]}" -gt 0 ]; then
    printf '\n %s%s%s\n' "$BO" "$(L "К СВЕДЕНИЮ / НЕ ПРОВЕРЕНО" "NOTES / NOT CHECKED")" "$NC"
    for s in "${LIMITS[@]}" "${NOTES[@]}"; do [ -n "$s" ] && printf '   • %s\n' "$s"; done
  fi
  printf '\n %s%s%s\n' "$BO" "$(L "ТЕХНИЧЕСКИЕ ПОДРОБНОСТИ (главное)" "TECHNICAL DETAILS (key facts)")" "$NC"
  printf '%s' "$DI"
  printf '   cpu: %s, load %s %s %s, busy %s%% iowait %s%% steal %s%% (%s ms sample)\n' "${CPU_MODEL:-?}" "$L1" "$L5" "$L15" "$BUSY" "$IOW" "$STEAL" "$DT"
  printf '   top cpu: %s\n   top ram: %s\n' "${TOPCPU_H:-—}" "${TOPMEM_H:-—}"
  printf '   ram: avail %s / %s, swap %s / %s, swap io %s pages/s, psi mem %s io %s\n' "$(human "$MA")" "$(human "$MT")" "$(human $((ST-SF)))" "$(human "$ST")" "$SWAPR" "${PSI_MF:-n/a}" "${PSI_IOF3:-n/a}"
  for i in $ORDER; do [ -n "${F_EV[i]}" ] || continue; printf '   [%s] %s\n' "$(area_name "${F_AREA[i]}")" "$(printf '%s\n' "${F_EV[i]}" | head -n 4 | cut -c1-220 | sed '2,$s/^/      /')"; done
  printf '%s' "$NC"
  printf '\n'
  if [ -n "$REPORT" ]; then
    printf ' 📄 %s%s%s %s\n' "$BO" "$(L "Полный отчёт сохранён:" "Full report saved:")" "$NC" "$REPORT"
    printf '    %s\n' "$(L "Откройте его в браузере (скачайте через WinSCP/FileZilla/scp, если сервер удалённый) или отправьте специалисту." "Open it in a browser (download it via WinSCP/FileZilla/scp if the server is remote) or send it to an admin.")"
  fi
  printf ' %s\n\n' "$(L "Проверка заняла $ELAPSED сек. Скрипт ничего не менял на сервере." "The check took $ELAPSED s. The script changed nothing on the server.")"
}

html_report() {
  local a w i s first
  printf '<!DOCTYPE html>\n<html lang="%s"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">\n' "$LNG"
  printf '<title>server-diag: %s — %s</title>\n' "$(esc "$HOST")" "$(fdate "$NOW")"
  cat <<'CSS'
<style>
body{font:15px/1.55 -apple-system,"Segoe UI",Roboto,Arial,sans-serif;margin:0;background:#f3f5f8;color:#1c2330}
main{max-width:980px;margin:0 auto;padding:22px}
.card{background:#fff;border-radius:12px;padding:18px 22px;margin:0 0 16px;box-shadow:0 1px 3px rgba(0,0,0,.08)}
h1{font-size:22px;margin:0 0 4px}h2{font-size:18px;margin:0 0 10px}.meta{color:#5b6475;font-size:13.5px}
.verdict{font-size:21px;font-weight:700;padding:16px 20px;border-radius:12px;margin:0 0 16px}
.v2{background:#fde8e8;color:#9b1c1c}.v1{background:#fdf3d8;color:#7a4d00}.v0{background:#e3f5e9;color:#1d6436}
table{border-collapse:collapse;width:100%}td{padding:9px 6px;border-bottom:1px solid #eef0f3;vertical-align:top}
td.l{font-size:19px;width:30px}td.a{font-weight:600;width:240px}
.f{border-left:5px solid #c9ced6;padding:10px 14px;margin:12px 0;background:#fafbfc;border-radius:8px}
.f.s2{border-color:#e02424}.f.s1{border-color:#e3a008}.f h3{margin:0 0 6px;font-size:16px}
ol{margin:6px 0 4px 22px;padding:0}li{margin:3px 0}.conf{font-size:12.5px;color:#5b6475}
pre{background:#101820;color:#d7e3f1;padding:12px;border-radius:8px;overflow:auto;font-size:12.5px;white-space:pre-wrap;word-break:break-word}
details{margin:8px 0}summary{cursor:pointer;font-weight:600}ul{margin:6px 0 0 20px;padding:0}
footer{color:#5b6475;font-size:12.5px;text-align:center;margin:18px 0}
</style></head><body><main>
CSS
  printf '<div class="card"><h1>%s</h1><div class="meta">%s · %s · %s %s · %s %s · %s %s · %s</div></div>\n' \
    "$(esc "$(L "Диагностика сервера" "Server diagnostics") $HOST")" "$(fdate "$NOW")" "$(esc "$OS")" "$(L "ядро" "kernel")" "$(esc "$KERNEL")" "$CORES" "$(L "ядер" "cores")" \
    "$(human "$MEM_T")" "$(L "ОЗУ" "RAM")" "$(esc "$(kind), $(L "работает" "up") $(dur "$UP_S")")"
  printf '<div class="verdict v%s">%s %s: %s</div>\n' "$WORST" "$(light "$WORST")" "$(L "Итог" "Result")" "$(esc "$(overall)")"
  printf '<div class="card"><h2>%s</h2><table>\n' "$(L "Светофор по областям" "Traffic light by area")"
  for a in disk mem cpu crash svc net; do
    w=${AW[$a]:-0}
    if [ "$w" = 0 ]; then s="$(L "норма" "OK")${OK[$a]:+ — ${OK[$a]}}"; else s=${AT[$a]}; [ "${AN[$a]}" -gt 1 ] && s="$s $(L "(+ ещё $(( ${AN[$a]} - 1 )))" "(+$(( ${AN[$a]} - 1 )) more)")"; fi
    printf '<tr><td class="l">%s</td><td class="a">%s</td><td>%s</td></tr>\n' "$(light "$w")" "$(esc "$(area_name "$a")")" "$(esc "$s")"
  done
  printf '</table></div>\n'
  printf '<div class="card"><h2>%s</h2>\n' "$(L "Главная причина и что сделать" "Main cause and what to do")"
  if [ -n "$MAIN" ]; then
    html_finding "$MAIN"
    first=1
    for i in $(printf '%s\n' "$ORDER" | tail -n +2); do
      [ "$first" = 1 ] && printf '<h2 style="margin-top:18px">%s</h2>\n' "$(L "Ещё замечено" "Also found")"; first=0
      html_finding "$i"
    done
  else
    printf '<p>🟢 %s</p><ol>' "$(esc "$(L "Проблем не найдено — все проверенные области в норме." "No problems found — every checked area is fine.")")"
    while IFS= read -r s; do printf '<li>%s</li>' "$(esc "$s")"; done <<< "$(noprob_steps)"; printf '</ol>\n'
  fi
  printf '</div>\n'
  if [ "${#NOTES[@]}" -gt 0 ] || [ "${#LIMITS[@]}" -gt 0 ]; then
    printf '<div class="card"><h2>%s</h2><ul>\n' "$(L "К сведению / не проверено" "Notes / not checked")"
    for s in "${LIMITS[@]}" "${NOTES[@]}"; do [ -n "$s" ] && printf '<li>%s</li>\n' "$(esc "$s")"; done
    printf '</ul></div>\n'
  fi
  printf '<div class="card"><h2>%s</h2><p class="meta">%s</p>\n' "$(L "Технические подробности" "Technical details")" "$(esc "$(L "Сырые данные для специалиста: вывод команд, которыми проверялся сервер." "Raw data for an admin: output of the commands used for the check.")")"
  awk 'function e(s){gsub(/&/,"\\&amp;",s); gsub(/</,"\\&lt;",s); gsub(/>/,"\\&gt;",s); return s}
       /^=== /{ if (o) print "</pre></details>"; print "<details><summary>" e(substr($0,5)) "</summary><pre>"; o=1; next }
       { if (!o) { if ($0 == "") next; print "<details><summary>misc</summary><pre>"; o=1 } print e($0) }
       END{ if (o) print "</pre></details>" }' "$TECH"
  printf '</div>\n<footer>server-diag %s · %s · <a href="https://github.com/vadimpokrov396-ship-it/server-diag">github.com/vadimpokrov396-ship-it/server-diag</a></footer>\n</main></body></html>\n' \
    "$VERSION" "$(esc "$(L "только чтение — скрипт ничего не менял на сервере; проверка заняла $ELAPSED сек." "read-only — the script changed nothing on the server; the check took $ELAPSED s.")")"
}

html_finding() {
  local i=$1 s
  printf '<div class="f s%s"><h3>%s %s</h3><div class="conf">%s · %s: %s</div><p>%s</p><ol>\n' "${F_SEV[i]}" "$(light "${F_SEV[i]}")" "$(esc "${F_T[i]}")" \
    "$(esc "$(area_name "${F_AREA[i]}")")" "$(L "уверенность" "confidence")" "$(conf_name "${F_CONF[i]}")" "$(esc "${F_WHY[i]}")"
  while IFS= read -r s; do [ -n "$s" ] && printf '<li>%s</li>\n' "$(esc "$s")"; done <<< "${F_DO[i]}"
  printf '</ol>\n'
  [ -n "${F_EV[i]}" ] && printf '<details><summary>%s</summary><pre>%s</pre></details>\n' "$(L "Доказательства" "Evidence")" "$(esc "${F_EV[i]}")"
  printf '</div>\n'
}

# whole script is parsed before it runs (safe for `curl ... | bash`); stdin is not used
main "$@" < /dev/null
