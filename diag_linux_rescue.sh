#!/bin/bash
# diag_linux_rescue.sh — read-only diagnosis of a LINUX server booted into a rescue system (Hetzner/OVH rescue, any live Linux).
# Changes nothing: the installed system's partitions are mounted READ-ONLY (ext4 noload, xfs norecovery), RAID arrays are assembled read-only.
# Checks: disk health (SMART, NVMe), RAID, ECC memory counters, free space/inodes, and the installed system's kernel log for the last 30 days:
# filesystem and I/O errors, disk link resets, out-of-memory kills, hardware errors (MCE), kernel crashes and hangs, unclean shutdowns,
# segfaults, saved kernel crash dumps (kdump/pstore), services that failed in the last 7 days, disk temperature and SMART error logs.
# Run as root: bash diag_linux_rescue.sh     Report: diag_linux_rescue_<host>_<date>.txt next to the script.
LC_ALL=C
DIR="$(dirname "$(readlink -f "$0")")"; DAYS=${DAYS:-30}
OUT="$DIR/diag_linux_rescue_$(hostname -s)_$(date +%Y%m%d_%H%M).txt"
ISSUES=(); bad(){ ISSUES+=("🔴 $*"); }; warn(){ ISSUES+=("🟡 $*"); }; note(){ ISSUES+=("ℹ️ $*"); }
SEC=$(mktemp); KL=$(mktemp); MNT=$(mktemp -d /tmp/linro.XXXX)
trap 'for m in $(ls -d "$MNT"/* 2>/dev/null | sort -r); do mountpoint -q "$m" && umount "$m"; done; rm -rf "$SEC" "$KL" "$MNT"' EXIT
sec(){ printf '\n==================== %s\n' "$*" >> "$SEC"; }
run(){ { echo "\$ $*"; timeout 120 bash -c "$*" 2>&1 | head -n 200; } >> "$SEC"; }
has(){ command -v "$1" >/dev/null 2>&1; }
[ "$(id -u)" = 0 ] || { echo "Нужен root: sudo bash $0"; exit 1; }
inst(){ has apt-get && { apt-get -qq update >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get -qq install -y "$@" >/dev/null 2>&1; return; }
  has dnf && { dnf -q install -y "$@" >/dev/null 2>&1; return; }; has yum && yum -q install -y "$@" >/dev/null 2>&1; }
has smartctl || inst smartmontools

echo "Шаг 1/4: диски, SMART, RAID..."
sec "Disks"
run "lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MODEL,SERIAL"
if has smartctl; then
  for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}' | grep -vE '^(loop|zram|sr|ram)'); do
    run "smartctl -H -A /dev/$d"
    smartctl -H /dev/$d 2>/dev/null | grep -qiE 'FAILED|FAILING' && bad "диск /dev/$d: SMART сообщает о неисправности"
    a=$(smartctl -A /dev/$d 2>/dev/null)
    for attr in Reallocated_Sector_Ct Current_Pending_Sector Offline_Uncorrectable; do
      v=$(echo "$a" | awk -v n="$attr" '$2==n{print $10}'); [ -n "$v" ] && [ "$v" -gt 0 ] 2>/dev/null && bad "диск /dev/$d: $attr = $v (битые сектора)"; done
    v=$(echo "$a" | awk '$2=="UDMA_CRC_Error_Count"{print $10}'); [ -n "$v" ] && [ "$v" -gt 0 ] 2>/dev/null && warn "диск /dev/$d: ошибки передачи по кабелю UDMA_CRC = $v"
    me=$(echo "$a" | awk -F: '/Media and Data Integrity Errors/{gsub(/ /,"",$2);print $2}'); [ -n "$me" ] && [ "$me" != 0 ] && bad "NVMe /dev/$d: ошибки целостности данных = $me"
    pu=$(echo "$a" | awk -F: '/Percentage Used/{gsub(/[ %]/,"",$2);print $2}'); [ -n "$pu" ] && [ "$pu" -ge 80 ] 2>/dev/null && warn "NVMe /dev/$d: износ ${pu}%"
    cw=$(echo "$a" | awk -F: '/Critical Warning/{gsub(/ /,"",$2);print $2}'); [ -n "$cw" ] && [ "$cw" != 0x00 ] && [ "$cw" != 0 ] && bad "NVMe /dev/$d: Critical Warning = $cw"
    tc=$(echo "$a" | awk '$2=="Temperature_Celsius"{print $10} /^Temperature:/{print $2}' | head -1); [ -n "$tc" ] && [ "$tc" -ge 70 ] 2>/dev/null && warn "диск /dev/$d: температура ${tc}°C"
    ae=$(smartctl -l error /dev/$d 2>/dev/null | awk '/ATA Error Count:/{print $4}'); [ -n "$ae" ] && [ "$ae" -gt 0 ] 2>/dev/null && { warn "диск /dev/$d: в журнале ошибок диска $ae записей"; run "smartctl -l error /dev/$d | head -40"; }
    run "smartctl -i /dev/$d | grep -E 'Model|Serial|Capacity|Firmware|Power_On|Rotation'"
  done
else warn "smartctl недоступен — здоровье дисков не проверено"; fi

# RAID: собираем массивы установленной системы только на чтение (если rescue их не собрал сам)
has mdadm && ! grep -q '^md' /proc/mdstat 2>/dev/null && mdadm --assemble --scan --readonly >/dev/null 2>&1
if [ -r /proc/mdstat ] && grep -q '^md' /proc/mdstat; then
  run "cat /proc/mdstat"
  grep -qE '\[[U_]*_[U_]*\]' /proc/mdstat && bad "программный RAID деградировал (в массиве не хватает диска)"
  for md in $(awk '/^md/{print $1}' /proc/mdstat); do run "mdadm --detail /dev/$md 2>/dev/null | grep -E 'State|Devices|Failed|removed|faulty'"; done
fi
has vgchange && vgchange -ay >/dev/null 2>&1

echo "Шаг 2/4: память и процессор (ECC, ошибки железа)..."
sec "Hardware errors (rescue boot)"
for d in /sys/devices/system/edac/mc/mc*; do [ -r "$d/ce_count" ] || continue
  ce=$(cat "$d/ce_count"); ue=$(cat "$d/ue_count" 2>/dev/null); echo "$(basename $d): CE=$ce UE=$ue" >> "$SEC"
  [ "${ue:-0}" -gt 0 ] 2>/dev/null && bad "память: неисправимые ошибки ECC ($(basename $d)) = $ue"
  [ "${ce:-0}" -gt 0 ] 2>/dev/null && warn "память: исправленные ошибки ECC ($(basename $d)) = $ce"
done
RD=$(dmesg 2>/dev/null | grep -aiE 'I/O error|Medium Error|Unrecovered read error|\[Hardware Error\]|Machine check|nvme[0-9]+: (I/O .* timeout|controller is down|resetting controller)|ata[0-9.]+: (exception Emask|hard resetting link)' | grep -v 'loop[0-9]' | tail -n 20)
[ -n "$RD" ] && { echo "$RD" >> "$SEC"; bad "ошибки железа видны уже в rescue (текущая загрузка): $(echo "$RD" | wc -l) строк — см. подробности"; }
run "grep -m1 'model name' /proc/cpuinfo; nproc; free -h"

echo "Шаг 3/4: разделы установленной системы (только чтение)..."
sec "Partitions (read-only)"
ROOT=""; n=0
# только диски сервера: без loop/ram (это сама rescue-система) и без уже подключённых разделов
RESCUE_SRC=$(findmnt -no SOURCE / 2>/dev/null)
for p in $(lsblk -lpno NAME,FSTYPE,TYPE,MOUNTPOINT | awk '$2 ~ /^(ext4|ext3|ext2|xfs|btrfs)$/ && $3 !~ /^(loop|rom|ram)$/ && $4=="" {print $1}'); do
  [ "$p" = "$RESCUE_SRC" ] && continue
  fs=$(lsblk -no FSTYPE "$p" | head -1); m="$MNT/$(echo "$p" | tr '/' '_')"; mkdir -p "$m"
  case "$fs" in ext*) o="ro,noload";; xfs) o="ro,norecovery";; *) o="ro";; esac
  if mount -o "$o" "$p" "$m" 2>>"$SEC"; then
    n=$((n+1)); run "df -h $m; df -i $m | tail -1"
    pct=$(df -P "$m" | awk 'NR==2{print int($5)}'); ipct=$(df -Pi "$m" | awk 'NR==2{print int($5)}')
    [ "${pct:-0}" -ge 95 ] && bad "раздел $p заполнен на ${pct}%" || { [ "${pct:-0}" -ge 90 ] && warn "раздел $p заполнен на ${pct}%"; }
    [ "${ipct:-0}" -ge 95 ] && bad "на разделе $p кончаются inode: ${ipct}%"
    case "$fs" in ext*) has dumpe2fs && { st=$(dumpe2fs -h "$p" 2>/dev/null | grep -E '^Filesystem state:|^FS Error count:|^Last error'); echo "$p: $st" >> "$SEC"
                         echo "$st" | grep -q 'Filesystem state:.*error' && bad "ФС $p помечена «с ошибками» — нужна проверка fsck"
                         echo "$st" | grep -qE '^FS Error count: *[1-9]' && warn "ФС $p: ядро записывало ошибки ($(echo "$st" | awk -F: '/FS Error count/{gsub(/ /,"",$2);print $2}'))"; };; esac
    [ -z "$ROOT" ] && [ -f "$m/etc/os-release" ] && [ -d "$m/var/log" ] && [ -d "$m/usr" ] && { ROOT="$m"; ROOTDEV="$p"; }
  else warn "раздел $p ($fs) не удалось подключить даже на чтение — возможно повреждение"; fi
done
[ $n = 0 ] && bad "разделов Linux не найдено — диск системы не виден (умер диск, RAID, шифрование)"
[ -n "$ROOT" ] && { echo "корень установленной системы: $ROOTDEV" >> "$SEC"; run "grep -E '^(PRETTY_NAME|VERSION)=' $ROOT/etc/os-release; cat $ROOT/etc/fstab | grep -v '^#' | grep ."; }
[ $n -gt 0 ] && [ -z "$ROOT" ] && warn "корневой раздел системы не найден (возможно /var на отдельном томе или LVM/шифрование)"

if [ -n "$ROOT" ]; then
  echo "Шаг 4/4: журнал ядра установленной системы за $DAYS дн. ..."
  sec "Kernel log of the installed system (last $DAYS days)"
  LOGD="$ROOT/var/log"
  if [ ! -d "$LOGD/journal" ] && [ ! -f "$LOGD/kern.log" ] && [ ! -f "$LOGD/syslog" ]; then for m in "$MNT"/*; do [ -d "$m/log/journal" ] || [ -f "$m/log/kern.log" ] && { LOGD="$m/log"; echo "журналы найдены на отдельном разделе /var: $m" >> "$SEC"; break; }; done; fi
  J=""; if [ -d "$LOGD/journal" ] && has journalctl && [ -n "$(ls -A "$LOGD/journal" 2>/dev/null)" ]; then J="journalctl -D $LOGD/journal --no-pager -q"; fi
  if [ -n "$J" ]; then
    timeout 120 $J -k --since "-$DAYS days" -o short-iso 2>>"$SEC" | tail -n 300000 > "$KL"
    [ -s "$KL" ] || echo "journalctl не прочитал журнал (возможно, журнал новее версии systemd в rescue) — беру kern.log/syslog" >> "$SEC"
    run "$J --list-boots 2>/dev/null | tail -n 12"
  fi
  if [ ! -s "$KL" ]; then for f in $(ls -tr "$LOGD"/kern.log* "$LOGD"/messages* "$LOGD"/syslog* 2>/dev/null); do case "$f" in *.gz) zcat "$f";; *) cat "$f";; esac; done 2>/dev/null | grep -a 'kernel:' | tail -n 300000 > "$KL"; fi
  [ -s "$KL" ] || warn "журнал ядра установленной системы пуст или не найден — история сбоев не проверена"
  echo "строк журнала ядра: $(wc -l < "$KL")" >> "$SEC"
  chk(){ local sev="$1" title="$2" re="$3" ex="${4:-^$}"; local h; h=$(grep -aiE "$re" "$KL" | grep -avE "$ex"); [ -z "$h" ] && return
    local c; c=$(echo "$h" | wc -l); local last; last=$(echo "$h" | tail -1 | cut -c1-19)
    $sev "$title: $c раз за $DAYS дн., последний раз $last"; { echo "--- $title (последние строки)"; echo "$h" | tail -n 6 | cut -c1-300; } >> "$SEC"; }
  chk bad  "ошибки чтения/записи диска (I/O)" 'I/O error|critical medium error|Medium Error|Unrecovered read error|failed command: (READ|WRITE)|Sense Key *: *(Medium|Hardware) Error' 'loop[0-9]|sr0|fd0'
  chk warn "сбросы связи с диском (кабель/контроллер/NVMe)" 'ata[0-9.]+: (exception Emask|hard resetting link|SError|failed to IDENTIFY)|nvme[0-9]+: (I/O [0-9]+ QID [0-9]+ timeout|controller is down|resetting controller|Removing after probe failure)'
  chk bad  "ошибки файловой системы" 'EXT4-fs error|EXT4-fs \(.*\): .*(corrupt|checksum)|XFS \(.*\): (Corruption|metadata I/O error|Internal error)|BTRFS (error|critical)|Remounting filesystem read-only|Aborting journal on device'
  chk bad  "аппаратные ошибки процессора/памяти (MCE)" 'mce: \[Hardware Error\]|Machine check events logged|Machine Check Exception|\[Hardware Error\]:|EDAC .*(CE|UE) ' 'mce: CPU[0-9]* supports|MCE banks|mce: Using'
  chk warn "нехватка памяти — ядро убивало процессы (OOM)" 'Out of memory: Kill|oom-kill:.*task=|Killed process [0-9]+'
  chk bad  "падения ядра (kernel BUG/Oops/panic)" 'kernel BUG at|BUG: (unable to handle|kernel NULL pointer|Bad page)|general protection fault|Oops: |Kernel panic'
  chk warn "зависания ядра (soft lockup, RCU stall, hung task)" 'soft lockup|hard LOCKUP|rcu_(sched|preempt|bh) (self-)?detected stall|rcu: INFO: .*stall|blocked for more than [0-9]+ seconds'
  chk warn "перегрев процессора" 'temperature above threshold|cpu clock throttled|Package temperature above'
  chk warn "программы падали с ошибкой памяти (segfault)" 'segfault at|traps: .*(general protection|invalid opcode)'
  # сохранённые отчёты о падении ядра (kdump / pstore)
  cr=$(ls -d "$ROOT"/var/crash/*/ "$ROOT"/var/lib/systemd/pstore/* 2>/dev/null | head -5)
  [ -n "$cr" ] && { bad "есть сохранённые отчёты о падении ядра (kdump/pstore): $(echo "$cr" | wc -l)"; run "ls -la $ROOT/var/crash $ROOT/var/lib/systemd/pstore 2>/dev/null | head -20"; }
  if [ -n "$J" ]; then
    first=$($J -o short-iso -n 1 --reverse 2>/dev/null | head -1 | cut -c1-10)
    [ -n "$first" ] && echo "журнал хранится с $first" >> "$SEC"
    [ -n "$first" ] && [ "$(date -d "$first" +%s 2>/dev/null || echo 0)" -gt "$(date -d "-3 days" +%s)" ] && note "журнал хранит меньше 3 дней (с $first) — старые сбои могли не попасть в проверку"
    # службы, которые падали за 7 дней (по журналу systemd) — программная часть
    SV=$(timeout 90 $J --since "-7 days" -o cat _COMM=systemd 2>/dev/null | grep -aE 'Failed with result|Main process exited, code=(killed|dumped)' | sed -nE 's/^([^:]+\.service): .*/\1/p' | sort | uniq -c | sort -rn | head -8)
    [ -n "$SV" ] && { warn "службы падали за 7 дней: $(echo "$SV" | awk '{printf "%s (%s) ", $2, $1}')"; sec "Services that failed in the last 7 days"; echo "$SV" >> "$SEC"; }
  elif [ ! -d "$ROOT/var/log/journal" ]; then note "постоянного журнала systemd нет (/var/log/journal) — проверены только kern.log/syslog"; fi
  if [ -n "$J" ]; then
    # аварийные выключения: загрузка, в конце которой нет штатного завершения. Последняя загрузка оборвана нашей перезагрузкой в rescue — не считаем.
    BOOTS=$($J --list-boots 2>/dev/null | awk '$1 ~ /^-?[0-9]+$/{print $1}' | tail -n 15); last=$(echo "$BOOTS" | tail -1); unc=0; ul=""
    for b in $BOOTS; do [ "$b" = "$last" ] && continue
      t=$($J -b "$b" -n 40 -o short-iso 2>/dev/null)
      echo "$t" | grep -qiE 'systemd-shutdown|Reached target .*(Power-Off|Reboot|Shutdown|Halt)|reboot: (Restarting|Power down)|Journal stopped|System is (rebooting|powering down)' || { unc=$((unc+1)); ul="$ul $(echo "$t" | tail -1 | cut -c1-16)"; }
    done
    [ $unc -gt 0 ] && warn "сервер выключался аварийно (без штатного завершения): $unc раз —$ul"
    if [ -n "$last" ]; then
      sec "Last 60 lines before the restart into rescue (the last boot was interrupted by that restart)"
      run "$J -b $last -n 60 -o short-iso"
    fi
  fi
fi

{ echo "ДИАГНОСТИКА LINUX (из rescue) $(hostname) — $(date '+%F %T %Z')"
  echo
  if [ ${#ISSUES[@]} -eq 0 ]; then echo "✅ Проблем не найдено."; else echo "Найдено: ${#ISSUES[@]}"; printf '%s\n' "${ISSUES[@]}"; fi
  echo; echo "Подробности ниже."; cat "$SEC"; } > "$OUT"
sed -n '1,/Подробности ниже/p' "$OUT"
echo "Полный отчёт: $OUT"
