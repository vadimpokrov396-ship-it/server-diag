#!/bin/bash
# diag_linux.sh — read-only health check of a Linux server (changes nothing).
# Run as root for full results:   sudo bash diag_linux.sh
# Result: diag_<host>_<date>.txt next to the script; problems are listed at the top (🔴 serious, 🟡 worth a look).
LC_ALL=C
OUT="$(dirname "$(readlink -f "$0")")/diag_$(hostname -s)_$(date +%Y%m%d_%H%M).txt"
ISSUES=(); bad(){ ISSUES+=("🔴 $*"); }; warn(){ ISSUES+=("🟡 $*"); }
SEC=$(mktemp); trap 'rm -f "$SEC"' EXIT
sec(){ printf '\n==================== %s\n' "$*" >> "$SEC"; }
run(){ { echo "\$ $*"; timeout 60 bash -c "$*" 2>&1 | head -n 200; } >> "$SEC"; }
has(){ command -v "$1" >/dev/null 2>&1; }
[ "$(id -u)" = 0 ] || warn "запущен не от root — часть проверок (SMART, журналы) неполная. Лучше: sudo bash $0"

sec "System"; run "uname -a; cat /etc/os-release 2>/dev/null | head -3; uptime; who -b"
up_days=$(awk '{print int($1/86400)}' /proc/uptime)

sec "CPU / load"
cores=$(nproc); load=$(awk '{print $2}' /proc/loadavg)   # 5-min average
run "nproc; cat /proc/loadavg; top -bn1 | head -20"
awk -v l="$load" -v c="$cores" 'BEGIN{exit !(l > c*1.5)}' && bad "нагрузка CPU высокая: load5=$load при $cores ядрах"
awk -v l="$load" -v c="$cores" 'BEGIN{exit !(l > c && l <= c*1.5)}' && warn "нагрузка CPU выше числа ядер: load5=$load / $cores"
if has sensors; then run "sensors"; t=$(sensors 2>/dev/null | grep -oE '\+[0-9]+\.[0-9]°C' | tr -d '+°C' | sort -n | tail -1); [ -n "$t" ] && awk -v t="$t" 'BEGIN{exit !(t>85)}' && bad "высокая температура: ${t}°C"; fi

sec "Memory"
run "free -h; vmstat 1 3"
avail=$(awk '/MemAvailable/{a=$2}/MemTotal/{t=$2}END{print int(a*100/t)}' /proc/meminfo)
[ "$avail" -lt 5 ] && bad "свободной памяти почти нет: ${avail}% доступно" || { [ "$avail" -lt 15 ] && warn "мало свободной памяти: ${avail}%"; }
swp=$(awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{if(t>0)print int((t-f)*100/t); else print 0}' /proc/meminfo)
[ "$swp" -gt 50 ] && warn "swap занят на ${swp}%"
oom=$( (journalctl -k --since "-7 days" 2>/dev/null || dmesg 2>/dev/null) | grep -ciE 'out of memory|oom-kill|killed process')
[ "$oom" -gt 0 ] && bad "за 7 дней OOM (не хватило памяти, процессы убиты): $oom раз" && run "(journalctl -k --since '-7 days' 2>/dev/null || dmesg) | grep -iE 'out of memory|killed process' | tail -15"

sec "Disks: space / inodes"
run "df -hT -x tmpfs -x devtmpfs -x squashfs -x overlay"
while read -r pct mnt; do p=${pct%\%}; [ "$p" -ge 95 ] && bad "диск $mnt заполнен на $pct" || { [ "$p" -ge 85 ] && warn "диск $mnt заполнен на $pct"; }; done < <(df -P -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR>1{print $5, $6}')
run "df -i -x tmpfs -x devtmpfs -x squashfs -x overlay"
while read -r pct mnt; do p=${pct%\%}; [ "$p" != "-" ] && [ "${p:-0}" -ge 90 ] 2>/dev/null && bad "кончаются inode на $mnt: $pct"; done < <(df -Pi -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR>1{print $5, $6}')
grep -qE '\sro[\s,]' /proc/mounts && awk '$4 ~ /^ro/ && $3 ~ /ext4|xfs|btrfs/' /proc/mounts | grep -q . && bad "есть раздел в режиме только-чтение (часто = ошибка диска): $(awk '$4 ~ /^ro/ && $3 ~ /ext4|xfs|btrfs/{print $2}' /proc/mounts | tr '\n' ' ')"

sec "Disks: health (SMART)"
run "lsblk -o NAME,SIZE,TYPE,MODEL,SERIAL,MOUNTPOINT"
if has smartctl; then
  for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}' | grep -vE '^(loop|zram|sr)'); do
    run "smartctl -H -A /dev/$d"
    s=$(smartctl -H /dev/$d 2>/dev/null); echo "$s" | grep -qiE 'FAILED|FAILING' && bad "диск /dev/$d: SMART сообщает о неисправности"
    a=$(smartctl -A /dev/$d 2>/dev/null)
    for attr in Reallocated_Sector_Ct Current_Pending_Sector Offline_Uncorrectable; do
      v=$(echo "$a" | awk -v n="$attr" '$2==n{print $10}'); [ -n "$v" ] && [ "$v" -gt 0 ] 2>/dev/null && bad "диск /dev/$d: $attr = $v (битые сектора)"; done
    me=$(echo "$a" | awk -F: '/Media and Data Integrity Errors/{gsub(/ /,"",$2);print $2}'); [ -n "$me" ] && [ "$me" != 0 ] && bad "NVMe /dev/$d: ошибки целостности данных = $me"
    pu=$(echo "$a" | awk -F: '/Percentage Used/{gsub(/[ %]/,"",$2);print $2}'); [ -n "$pu" ] && [ "$pu" -ge 80 ] 2>/dev/null && warn "NVMe /dev/$d: износ ${pu}%"
  done
else warn "smartctl не установлен — здоровье дисков не проверено (apt/yum install smartmontools)"; fi
dmerr=$( (journalctl -k --since "-7 days" 2>/dev/null || dmesg 2>/dev/null) | grep -ciE 'I/O error|medium error|blk_update_request|ata[0-9.]+: .*(failed|error)|nvme.*(timeout|reset)')
[ "$dmerr" -gt 0 ] && bad "ошибки ввода-вывода дисков в журнале ядра за 7 дней: $dmerr" && run "(journalctl -k --since '-7 days' 2>/dev/null || dmesg) | grep -iE 'I/O error|medium error|blk_update_request|nvme.*(timeout|reset)' | tail -15"

sec "RAID"
if [ -r /proc/mdstat ] && grep -q '^md' /proc/mdstat; then
  run "cat /proc/mdstat"
  grep -qE '\[[U_]*_[U_]*\]' /proc/mdstat && bad "программный RAID деградировал (выпал диск): $(grep -B1 -E '\[[U_]*_[U_]*\]' /proc/mdstat | awk '/^md/{print $1}' | tr '\n' ' ')"
  grep -qE 'recovery|resync|reshape' /proc/mdstat && warn "RAID сейчас пересобирается: $(grep -oE '(recovery|resync|reshape) = *[0-9.]+%' /proc/mdstat | head -1)"
fi
has zpool && { run "zpool status -x"; zpool status -x 2>/dev/null | grep -q 'all pools are healthy' || bad "ZFS: пул не в порядке (zpool status)"; }

sec "Crashes, hangs, hardware errors"
run "journalctl --list-boots 2>/dev/null | tail -10"
run "last -x reboot shutdown 2>/dev/null | head -15"
# boots that ended without a clean shutdown = crash/hang/power loss
if journalctl --list-boots >/dev/null 2>&1; then
  unclean=0
  for b in $(journalctl --list-boots 2>/dev/null | awk '{print $1}' | grep -E '^-[0-9]+$' | tail -10); do
    journalctl -b "$b" -n 60 --no-pager 2>/dev/null | grep -qiE 'reached target.*(shutdown|power-off|reboot)|systemd-shutdown|Journal stopped|Shutting down' || unclean=$((unclean+1)); done
  [ "$unclean" -gt 0 ] && bad "из последних загрузок $unclean закончились НЕ штатным выключением (зависание/падение/пропало питание)"
fi
pan=$( (journalctl -k -b -1 2>/dev/null; journalctl -k --since "-30 days" 2>/dev/null) | grep -ciE 'kernel panic|BUG:|Oops|soft lockup|hard LOCKUP|hung_task|blocked for more than')
[ "$pan" -gt 0 ] && bad "в журнале ядра зависания/паники/блокировки задач: $pan" && run "journalctl -k --since '-30 days' 2>/dev/null | grep -iE 'kernel panic|BUG:|Oops|soft lockup|hard LOCKUP|blocked for more than' | tail -15"
mce=$( (journalctl -k --since "-30 days" 2>/dev/null || dmesg) | grep -ciE 'mce:|machine check|EDAC.*(error|CE|UE)|Hardware Error')
[ "$mce" -gt 0 ] && bad "ошибки железа (память/процессор, MCE/EDAC) за 30 дней: $mce" && run "journalctl -k --since '-30 days' 2>/dev/null | grep -iE 'mce:|machine check|EDAC|Hardware Error' | tail -15"
thr=$( (journalctl -k --since "-7 days" 2>/dev/null || dmesg) | grep -ciE 'temperature above threshold|throttl')
[ "$thr" -gt 0 ] && warn "перегрев/троттлинг CPU за 7 дней: $thr"
pw=$(journalctl --since "-30 days" 2>/dev/null | grep -cE 'power (failure|loss)|[Oo]n battery|\bUPS\b')
[ "$pw" -gt 0 ] && warn "упоминания питания/ИБП в журнале за 30 дней: $pw"

sec "Services"
if has systemctl; then run "systemctl --failed --no-legend"; nf=$(systemctl --failed --no-legend 2>/dev/null | grep -c .); [ "$nf" -gt 0 ] && warn "упавших служб: $nf ($(systemctl --failed --no-legend 2>/dev/null | awk '{print $2=="●"?$3:$1}' | head -5 | tr '\n' ' '))"; fi
run "ps aux --sort=-%cpu | head -12"; run "ps aux --sort=-%mem | head -12"
zomb=$(ps -eo stat | grep -c '^Z'); [ "$zomb" -gt 20 ] && warn "процессов-зомби: $zomb"
dstate=$(ps -eo stat | grep -c '^D'); [ "$dstate" -gt 5 ] && warn "процессов, зависших на диске (D): $dstate"

sec "Network"
run "ip -br addr; ip route | head"
run "ss -tulpn 2>/dev/null | head -40"
timeout 5 getent hosts google.com >/dev/null || bad "DNS не работает (не резолвится google.com)"
timeout 5 bash -c '</dev/tcp/1.1.1.1/443' 2>/dev/null || bad "нет выхода в интернет (1.1.1.1:443)"

sec "Security quick look"
run "journalctl -u ssh -u sshd --since '-1 day' 2>/dev/null | grep -c 'Failed password' ; grep -E '^(PermitRootLogin|PasswordAuthentication)' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null"
fails=$(journalctl -u ssh -u sshd --since "-1 day" 2>/dev/null | grep -c 'Failed password')
[ "${fails:-0}" -gt 500 ] && warn "за сутки $fails неудачных входов по SSH (подбор пароля) — нужен вход по ключу/fail2ban"
run "awk -F: '\$3==0{print \"uid0:\",\$1}' /etc/passwd"
[ "$(awk -F: '$3==0' /etc/passwd | wc -l)" -gt 1 ] && bad "больше одного пользователя с правами root (uid 0)"
has apt && { up=$(apt list --upgradable 2>/dev/null | grep -c security); [ "$up" -gt 0 ] && warn "доступно обновлений безопасности: $up"; }
[ "$up_days" -gt 180 ] && warn "сервер не перезагружался $up_days дней (ядро могло не обновиться)"

{ echo "ДИАГНОСТИКА $(hostname) — $(date '+%F %T %Z')"
  echo
  if [ ${#ISSUES[@]} -eq 0 ]; then echo "✅ Проблем не найдено."; else echo "Найдено: ${#ISSUES[@]}"; printf '%s\n' "${ISSUES[@]}"; fi
  echo; echo "Подробности ниже."; cat "$SEC"; } > "$OUT"
sed -n '1,/Подробности ниже/p' "$OUT"
echo "Полный отчёт: $OUT"
