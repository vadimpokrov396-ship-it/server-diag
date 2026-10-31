#!/bin/bash
# diag_windows_rescue.sh — read-only diagnosis of a WINDOWS server booted into a LINUX rescue system
# (Hetzner Rescue, OVH rescue, any live Linux). Changes nothing: Windows partitions are mounted READ-ONLY.
# Run as root:   bash diag_windows_rescue.sh
# Checks: disk health (SMART), partitions, NTFS "dirty" flag, free space, crash dumps (blue screens),
# pending Windows updates, and Windows event logs (unexpected shutdowns, blue screens, disk/NTFS/hardware errors,
# low memory, crashed services) for the last 30 days. Report: diag_windows_<host>_<date>.txt next to the script.
LC_ALL=C
DIR="$(dirname "$(readlink -f "$0")")"; DAYS=${DAYS:-30}
OUT="$DIR/diag_windows_$(hostname -s)_$(date +%Y%m%d_%H%M).txt"
ISSUES=(); bad(){ ISSUES+=("🔴 $*"); }; warn(){ ISSUES+=("🟡 $*"); }; note(){ ISSUES+=("ℹ️ $*"); }
SEC=$(mktemp); MNT=$(mktemp -d /tmp/winro.XXXX); trap 'for m in "$MNT"/*; do mountpoint -q "$m" && umount "$m"; done; rm -rf "$SEC" "$MNT"' EXIT
sec(){ printf '\n==================== %s\n' "$*" >> "$SEC"; }
run(){ { echo "\$ $*"; timeout 120 bash -c "$*" 2>&1 | head -n 200; } >> "$SEC"; }
has(){ command -v "$1" >/dev/null 2>&1; }
[ "$(id -u)" = 0 ] || { echo "Нужен root: sudo bash $0"; exit 1; }
# Машиночитаемая сводка для расширения/ИИ: одна строка на диск, значения SMART без разбора текста. «-» — показателя нет.
pvsummary(){ local os="$1" d i a v
  echo "===PVSUMMARY==="
  echo "os=$os cpu=\"$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)\" threads=$(nproc) ram_gb=$(free -g | awk '/Mem:/{print $2}')"
  echo "nvme_pci=$( (lspci -d ::0108 2>/dev/null || lspci 2>/dev/null | grep -i 'non-volatile') | grep -c . ) nvme_disks=$(lsblk -dno NAME,TYPE | awk '$2=="disk" && $1 ~ /^nvme/' | grep -c .) disks=$(lsblk -dno NAME,TYPE | awk '$2=="disk"' | grep -vE '^(loop|zram|sr|ram)' | grep -c .)"
  for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}' | grep -vE '^(loop|zram|sr|ram)'); do
    i=$(smartctl -i /dev/$d 2>/dev/null); a=$(smartctl -H -A /dev/$d 2>/dev/null)
    f(){ printf "%s\n%s\n" "$i" "$a" | awk -F: -v k="$1" '$1 ~ "^"k"$" {sub(/^[ \t]+/,"",$2); for(j=3;j<=NF;j++) $2=$2":"$j; print $2; exit}'; }
    at(){ echo "$a" | awk -v n="$1" '$2==n{print $10; exit}' | grep -oE '^[0-9]+'; }
    nv(){ f "$1" | tr -d ' ,%' | grep -oE '^(0x)?[0-9a-fA-F]+'; }
    local model serial typ health poh temp
    model=$(f '(Device Model|Model Number|Product)' | tr -d '"'); serial=$(f 'Serial Number' | tr -d ' ')
    case "$d" in nvme*) typ=nvme;; *) [ "$(cat /sys/block/$d/queue/rotational 2>/dev/null)" = 1 ] && typ=hdd || typ=ssd;; esac
    health=$(f '(SMART overall-health self-assessment test result|SMART Health Status)' | awk '{print $1}')
    poh=$(at Power_On_Hours); [ -z "$poh" ] && poh=$(nv 'Power On Hours')
    temp=$(at Temperature_Celsius); [ -z "$temp" ] && temp=$(f 'Temperature' | grep -oE '^[0-9]+')
    printf 'DISK dev=/dev/%s type=%s size=%s model="%s" serial=%s health=%s realloc=%s pending=%s uncorr=%s crc=%s media=%s wear=%s crit=%s temp=%s poh=%s unsafe=%s errlog=%s\n' \
      "$d" "$typ" "$(lsblk -dno SIZE /dev/$d | xargs)" "${model:--}" "${serial:--}" "${health:-unknown}" \
      "$(v=$(at Reallocated_Sector_Ct); echo ${v:--})" "$(v=$(at Current_Pending_Sector); echo ${v:--})" "$(v=$(at Offline_Uncorrectable); echo ${v:--})" "$(v=$(at UDMA_CRC_Error_Count); echo ${v:--})" \
      "$(v=$(nv 'Media and Data Integrity Errors'); echo ${v:--})" "$(v=$(nv 'Percentage Used'); [ -z "$v" ] && v=$(echo "$a" | awk '$2 ~ /^(Wear_Leveling_Count|Media_Wearout_Indicator|Percent_Lifetime_Remain)$/{print 100-$4; exit}'); echo ${v:--})" \
      "$(v=$(nv 'Critical Warning'); echo ${v:--})" "${temp:--}" "${poh:--}" "$(v=$(nv 'Unsafe Shutdowns'); echo ${v:--})" \
      "$(v=$(nv 'Error Information Log Entries'); [ -z "$v" ] && v=$(smartctl -l error /dev/$d 2>/dev/null | awk '/ATA Error Count:/{print $4; exit}'); echo ${v:--})"
  done
  echo "===PVSUMMARY-END==="; }
inst(){ # install a missing tool in the rescue system (only the rescue RAM disk is touched, not Windows)
  has apt-get && { apt-get -qq update >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get -qq install -y "$@" >/dev/null 2>&1; return; }
  has dnf && { dnf -q install -y "$@" >/dev/null 2>&1; return; }; has yum && yum -q install -y "$@" >/dev/null 2>&1; }
has smartctl || inst smartmontools
has ntfsinfo || inst ntfs-3g
echo "Шаг 1/4: диски и SMART..."

sec "Disks"
run "lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MODEL,SERIAL"
if has smartctl; then
  for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}' | grep -vE '^(loop|zram|sr|ram)'); do
    run "smartctl -H -A /dev/$d"
    smartctl -H /dev/$d 2>/dev/null | grep -qiE 'FAILED|FAILING' && bad "диск /dev/$d: SMART сообщает о неисправности"
    a=$(smartctl -A /dev/$d 2>/dev/null)
    for attr in Reallocated_Sector_Ct Current_Pending_Sector Offline_Uncorrectable; do
      v=$(echo "$a" | awk -v n="$attr" '$2==n{print $10}'); [ -n "$v" ] && [ "$v" -gt 0 ] 2>/dev/null && bad "диск /dev/$d: $attr = $v (битые сектора)"; done
    me=$(echo "$a" | awk -F: '/Media and Data Integrity Errors/{gsub(/ /,"",$2);print $2}'); [ -n "$me" ] && [ "$me" != 0 ] && bad "NVMe /dev/$d: ошибки целостности данных = $me"
    pu=$(echo "$a" | awk -F: '/Percentage Used/{gsub(/[ %]/,"",$2);print $2}'); [ -n "$pu" ] && [ "$pu" -ge 80 ] 2>/dev/null && warn "NVMe /dev/$d: износ ${pu}%"
  done
else warn "smartctl недоступен — здоровье дисков не проверено"; fi

# Пропавшие диски: NVMe-контроллер есть на шине PCI, но диска нет (отвалился/отключён ядром после таймаута)
sec "Disk controllers (PCI) and NVMe state"
run "lspci -nn 2>/dev/null | grep -iE 'non-volatile|nvme|sata|raid|sas|scsi'"
for c in /sys/class/nvme/nvme*; do [ -e "$c" ] || continue; n=$(basename "$c")
  mdl=$(cat "$c/model" 2>/dev/null | xargs); sn=$(cat "$c/serial" 2>/dev/null | xargs); st=$(cat "$c/state" 2>/dev/null); addr=$(cat "$c/address" 2>/dev/null)
  echo "$n: state=${st:-?} model=$mdl serial=$sn pci=$addr namespaces=$(ls -d "$c"/${n}n* 2>/dev/null | xargs -n1 basename 2>/dev/null | xargs)" >> "$SEC"
  if [ "$st" != "live" ] || ! ls -d "$c"/${n}n* >/dev/null 2>&1; then bad "NVMe $n${mdl:+ ($mdl${sn:+, SN $sn})}${addr:+, PCI $addr}: не работает (состояние ${st:-неизвестно}) — диск не виден системе"; fi
done
np=$( (lspci -d ::0108 2>/dev/null || lspci 2>/dev/null | grep -i 'non-volatile') | grep -c . ); nc=$(ls -d /sys/class/nvme/nvme* 2>/dev/null | grep -c .); nd=$(lsblk -dno NAME,TYPE | awk '$2=="disk" && $1 ~ /^nvme/' | grep -c .)
echo "NVMe: контроллеров на PCI $np, видит ядро $nc, дисков $nd" >> "$SEC"
[ "$np" -gt "$nd" ] && bad "на шине PCI NVMe-контроллеров: $np, а дисков NVMe в системе: $nd — один диск пропал (не отвечает или отключён ядром)"
DN=$(dmesg 2>/dev/null | grep -aiE 'nvme[0-9]+: .*(disable controller|controller is down|Removing after probe failure|Device not ready|failed to set APST|Identify .* failed|frozen state)|ata[0-9.]+: (failed to IDENTIFY|link is slow|COMRESET failed)' | tail -n 10)
[ -n "$DN" ] && { echo "$DN" >> "$SEC"; for k in $(echo "$DN" | grep -oE 'nvme[0-9]+' | sort -u); do bad "контроллер $k отключён ядром после ошибки: $(echo "$DN" | grep "$k" | tail -1 | sed -E 's/^\[[^]]*\] *//' | cut -c1-120)"; done; }
run "dmesg 2>/dev/null | grep -aiE 'nvme|ata[0-9]+[.:]' | head -n 40"
# диски без разделов
for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}' | grep -vE '^(loop|zram|sr|ram)'); do
  [ "$(lsblk -no NAME "/dev/$d" | wc -l)" -le 1 ] && [ -z "$(lsblk -dno FSTYPE "/dev/$d")" ] && note "диск /dev/$d без разделов (пустой, или система была на другом диске, или таблица разделов повреждена)"
done
[ -r /proc/mdstat ] && grep -q '^md' /proc/mdstat && { run "cat /proc/mdstat"; grep -qE '\[[U_]*_[U_]*\]' /proc/mdstat && bad "программный RAID деградировал"; }
has mdadm && run "mdadm --examine --scan 2>/dev/null"
grep -qiE 'ddf|isw|imsm' <(lsblk -o FSTYPE 2>/dev/null) && warn "есть диски в аппаратном/Intel RAID — Windows-тома могут быть видны только через dmraid/mdadm"

echo "Шаг 2/4: разделы Windows (только чтение)..."
sec "NTFS partitions"
WINROOT=""; n=0
for p in $(lsblk -lno NAME,FSTYPE | awk '$2=="ntfs"{print $1}'); do
  dev=/dev/$p; n=$((n+1))
  run "ntfsinfo -m $dev 2>/dev/null | grep -iE 'Volume Name|Volume Flags|Cluster Size|Volume Size'"
  ntfsinfo -m "$dev" 2>/dev/null | grep -i 'Volume Flags' | grep -qi dirty && bad "раздел $dev помечен как «с ошибками» (dirty) — Windows хочет chkdsk"
  m="$MNT/$p"; mkdir -p "$m"
  if mount -t ntfs-3g -o ro "$dev" "$m" 2>>"$SEC" || mount -o ro "$dev" "$m" 2>>"$SEC"; then
    run "df -h $m"
    pct=$(df -P "$m" | awk 'NR==2{print int($5)}'); [ "${pct:-0}" -ge 95 ] && bad "раздел $dev заполнен на ${pct}%" || { [ "${pct:-0}" -ge 88 ] && warn "раздел $dev заполнен на ${pct}%"; }
    [ -f "$m/hiberfil.sys" ] && run "ls -la $m/hiberfil.sys"
    for w in "$m/Windows" "$m/WINDOWS"; do [ -d "$w/System32" ] && WINROOT="$w"; done
  else warn "раздел $dev не удалось подключить даже на чтение (повреждение или Windows в гибернации/быстром запуске)"; fi
done
[ $n = 0 ] && bad "разделов NTFS не найдено — диск Windows не виден (умер диск, RAID-контроллер или BitLocker)"
lsblk -lno FSTYPE | grep -qi bitlocker && warn "есть тома BitLocker — без ключа восстановления их содержимое не прочитать"
[ -n "$n" ] && [ $n -gt 0 ] && [ -z "$WINROOT" ] && bad "папка Windows не найдена ни на одном разделе"

if [ -n "$WINROOT" ]; then
  echo "Шаг 3/4: дампы падений и обновления..."
  sec "Windows folder: $WINROOT"
  run "ls -la '$WINROOT/Minidump' 2>/dev/null | tail -20; ls -la '$WINROOT/MEMORY.DMP' 2>/dev/null"
  nd=$(command find "$WINROOT/Minidump" -maxdepth 1 -iname '*.dmp' -mtime -$DAYS 2>/dev/null | wc -l)
  [ "$nd" -gt 0 ] && bad "синих экранов за $DAYS дн. (минидампы): $nd — последний $(ls -t "$WINROOT"/Minidump/*.dmp 2>/dev/null | head -1 | xargs -r stat -c %y | cut -c1-16)"
  [ -f "$WINROOT/MEMORY.DMP" ] && warn "есть полный дамп памяти MEMORY.DMP от $(stat -c %y "$WINROOT/MEMORY.DMP" | cut -c1-16)"
  [ -f "$WINROOT/WinSxS/pending.xml" ] && warn "есть незавершённая установка обновлений (WinSxS/pending.xml) — частая причина долгой/зависшей загрузки"
  run "ls -la '$WINROOT/WinSxS/pending.xml' '$WINROOT/SoftwareDistribution/Download' 2>/dev/null | head"
  run "ls -lt '$WINROOT/Logs/CBS' 2>/dev/null | head -5"
  run "tail -c 3000 '$WINROOT/Logs/CBS/CBS.log' 2>/dev/null | grep -iE 'error|fail' | tail -10"
  run "ls -la '$WINROOT/System32/LogFiles/Srt/SrtTrail.txt' 2>/dev/null && tail -40 '$WINROOT/System32/LogFiles/Srt/SrtTrail.txt'"
  [ -f "$WINROOT/System32/LogFiles/Srt/SrtTrail.txt" ] && grep -qiE 'root cause found' "$WINROOT/System32/LogFiles/Srt/SrtTrail.txt" && warn "автовосстановление Windows записало причину сбоя загрузки (SrtTrail.txt — см. подробности)"

  echo "Шаг 4/4: журналы событий Windows за $DAYS дн. (несколько минут)..."
  sec "Windows event logs (last $DAYS days)"
  PY=python3; VENV=/tmp/evtx_venv
  if ! $PY -c 'import Evtx' 2>/dev/null; then
    has python3 || inst python3
    { $PY -m venv $VENV || { inst python3-venv && $PY -m venv $VENV; }; } >/dev/null 2>&1 && $VENV/bin/pip -q install python-evtx >/dev/null 2>&1 && PY=$VENV/bin/python
  fi
  REP="$DIR/win_evtx_report.py"
  [ -f "$REP" ] || curl -fsSL "${DIAG_BASE:-https://raw.githubusercontent.com/vadimpokrov396-ship-it/server-diag/main}/win_evtx_report.py" -o /tmp/win_evtx_report.py 2>/dev/null && [ -f /tmp/win_evtx_report.py ] && REP=/tmp/win_evtx_report.py
  if $PY -c 'import Evtx' 2>/dev/null && [ -f "$REP" ]; then
    ev=$($PY "$REP" "$WINROOT" "$DAYS" 2>&1); echo "$ev" >> "$SEC"
    while IFS= read -r l; do ISSUES+=("${l#!! }"); done < <(echo "$ev" | grep '^!! ')
  else warn "не удалось поставить разборщик журналов (нет интернета в rescue?) — журналы событий не проверены"; fi
fi

# Полные SMART-логи каждого диска (smartctl -x) — для поля «Entire SMART log» в заявке дата-центру
sec "SMART full logs (smartctl -x)"
if has smartctl; then for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}' | grep -vE '^(loop|zram|sr|ram)'); do
  { echo "===SMART-FULL /dev/$d==="; timeout 90 smartctl -x /dev/$d 2>&1 | head -n 400; echo "===SMART-END==="; } >> "$SEC"; done; fi

{ echo "ДИАГНОСТИКА WINDOWS (из rescue) $(hostname) — $(date '+%F %T %Z')"
  echo
  if [ ${#ISSUES[@]} -eq 0 ]; then echo "✅ Проблем не найдено."; else echo "Найдено: ${#ISSUES[@]}"; printf '%s\n' "${ISSUES[@]}"; fi
  echo; pvsummary windows
  echo; echo "Подробности ниже."; cat "$SEC"; } > "$OUT"
sed -n '1,/Подробности ниже/p' "$OUT"
echo "Полный отчёт: $OUT"
