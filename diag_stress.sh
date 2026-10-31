#!/bin/bash
# diag_stress.sh — load test of a server booted into rescue: full CPU + part of RAM, CPU temperature every STEP seconds.
# Stops by itself when the CPU reaches STOP °C (default 100) or after MIN minutes (default 20). Changes nothing on the disks.
# Run as root:   MIN=20 STOP=100 bash diag_stress.sh      Report: diag_stress_<host>_<date>.txt next to the script.
# If the SSH session drops and the server goes off during the test — that is the result too (thermal/power shutdown).
LC_ALL=C
DIR="$(dirname "$(readlink -f "$0")")"; MIN=${MIN:-20}; STOP=${STOP:-100}; STEP=${STEP:-15}; DUR=${DUR:-$((MIN*60))}
OUT="$DIR/diag_stress_$(hostname -s)_$(date +%Y%m%d_%H%M).txt"
has(){ command -v "$1" >/dev/null 2>&1; }
[ "$(id -u)" = 0 ] || { echo "Нужен root: sudo bash $0"; exit 1; }
modprobe k10temp 2>/dev/null; modprobe coretemp 2>/dev/null
has stress-ng || { has apt-get && { apt-get -qq update >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get -qq install -y stress-ng >/dev/null 2>&1; }; }

# температура CPU из /sys/class/hwmon (k10temp — AMD, coretemp — Intel); lm-sensors не нужен
temps(){ for h in ${HWMON_ROOT:-/sys/class/hwmon}/hwmon*; do n=$(cat "$h/name" 2>/dev/null); case "$n" in k10temp|coretemp|zenpower)
  for f in "$h"/temp*_input; do [ -r "$f" ] || continue; l=$(cat "${f%_input}_label" 2>/dev/null | tr -d ' '); [ -z "$l" ] && l=$(basename "${f%_input}")
    printf '%s=%s ' "$l" $(( $(cat "$f") / 1000 )); done;; esac; done; }
tmax(){ temps | tr ' ' '\n' | awk -F= 'NF==2{if($2+0>m)m=$2+0}END{print m+0}'; }
mhz(){ awk -F: '/cpu MHz/{s+=$2;n++}END{if(n)printf "%d", s/n}' /proc/cpuinfo; }
hwerr(){ dmesg 2>/dev/null | grep -aiE 'mce: \[Hardware Error\]|Machine check|\[Hardware Error\]|EDAC MC[0-9]+: [0-9]+ (CE|UE)' | wc -l; }

CPU=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs); CORES=$(nproc); RAM=$(free -g | awk '/Mem:/{print $2}')
IDLE=$(tmax); E0=$(hwerr)
echo "Тест под нагрузкой: $CPU, $CORES потоков, ${RAM} ГБ RAM · до $MIN мин, стоп при ${STOP} °C · без нагрузки: ${IDLE} °C"
[ "$IDLE" = 0 ] && echo "⚠ датчики температуры не найдены — смотрите только, не выключится ли сервер"

PIDS=()
if has stress-ng; then stress-ng --cpu 0 --vm 2 --vm-bytes 60% --timeout "${DUR}s" >/dev/null 2>&1 & PIDS+=($!); TOOL="stress-ng (все ядра + 60% RAM)"
else for i in $(seq "$CORES"); do ( while :; do :; done ) & PIDS+=($!); done; TOOL="встроенная нагрузка на все ядра (stress-ng не установился)"; fi
stopload(){ for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; pkill -f 'stress-ng' 2>/dev/null; }
trap 'stopload' EXIT INT TERM

T0=$(date +%s); PEAK=0; PEAKAT=0; REASON=time; SAMPLES=""
while :; do
  sleep "$STEP"; EL=$(( $(date +%s) - T0 )); M=$(tmax)
  [ "$M" -gt "$PEAK" ] && { PEAK=$M; PEAKAT=$EL; }
  L="$(date +%T)  +$((EL/60))м$(printf '%02d' $((EL%60)))с  max=${M}°C  $(mhz)МГц  $(temps)"
  echo "$L"; SAMPLES+="$L"$'\n'
  if [ "$M" -ge "$STOP" ]; then REASON=overheat; break; fi
  [ "$EL" -ge "$DUR" ] && break
done
stopload; trap - EXIT INT TERM
echo "Нагрузка снята, жду 30 с — смотрю, как остывает…"; sleep 30; COOL=$(tmax); E1=$(hwerr)

ISSUES=()
if [ "$PEAK" = 0 ]; then ISSUES+=("🟡 датчики температуры CPU недоступны — тест показал только, что сервер не выключился за $((EL/60)) мин")
elif [ "$REASON" = overheat ]; then ISSUES+=("🔴 перегрев CPU: ${PEAK} °C через $((PEAKAT/60)) мин $((PEAKAT%60)) с под нагрузкой (без нагрузки было ${IDLE} °C) — тест остановлен на пороге ${STOP} °C; обычный предел для серверных CPU — 90–95 °C. Похоже на неисправность охлаждения (кулер, вентилятор, термопаста)")
elif [ "$PEAK" -ge 95 ]; then ISSUES+=("🔴 CPU очень горячий: до ${PEAK} °C за $((EL/60)) мин под нагрузкой — охлаждение на пределе")
elif [ "$PEAK" -ge 90 ]; then ISSUES+=("🟡 CPU горячий: до ${PEAK} °C за $((EL/60)) мин под нагрузкой (на пределе нормы)")
else ISSUES+=("✅ $((EL/60)) мин под полной нагрузкой без отключения, максимум ${PEAK} °C — охлаждение справляется"); fi
[ "$PEAK" -gt 0 ] && [ $((PEAK - COOL)) -lt 15 ] && ISSUES+=("🟡 через 30 с после снятия нагрузки всё ещё ${COOL} °C — остывает медленно (слабый обдув)")
[ "$E1" -gt "$E0" ] && ISSUES+=("🔴 во время нагрузки появились аппаратные ошибки процессора/памяти (MCE/EDAC): $((E1 - E0))")

{ echo "ТЕСТ ПОД НАГРУЗКОЙ (из rescue) $(hostname) — $(date '+%F %T %Z')"
  echo; printf '%s\n' "${ISSUES[@]}"; echo
  echo "CPU: $CPU · потоков: $CORES · RAM: ${RAM} ГБ · нагрузка: $TOOL"
  echo "STRESS-SUMMARY idle=${IDLE} peak=${PEAK} peak_at=${PEAKAT} cool=${COOL} dur=${EL} reason=${REASON} stop=${STOP} mce_new=$((E1 - E0)) cpu=\"${CPU}\""
  echo "Без нагрузки: ${IDLE} °C · пик: ${PEAK} °C на +$((PEAKAT/60))м$((PEAKAT%60))с · через 30 с после нагрузки: ${COOL} °C · длительность: $((EL/60))м$((EL%60))с · остановлен: $([ "$REASON" = overheat ] && echo "по перегреву (порог ${STOP} °C)" || echo "по времени")"
  echo; echo "Замеры:"; printf '%s' "$SAMPLES"
  [ "$E1" -gt "$E0" ] && { echo; echo "Аппаратные ошибки в dmesg:"; dmesg | grep -aiE 'mce: \[Hardware Error\]|Machine check|\[Hardware Error\]|EDAC MC[0-9]+: [0-9]+ (CE|UE)' | tail -n 20; }
} > "$OUT"
echo; printf '%s\n' "${ISSUES[@]}"; echo "Полный отчёт: $OUT"
