#!/bin/bash
# PowerVPS — помощник сброса пароля администратора в rescue.
#
# ВАЖНО: скрипт НЕ принимает, не спрашивает и не хранит пароль.
#   Windows — пароль задаётся руками в VNC командой net user (раскладка EN).
#   Linux   — пароль задаётся руками в passwd.
# Скрипт только находит нужный диск и готовит/выполняет механические шаги.
#
# Режимы:
#   (без аргумента)      определить раскладку и напечатать готовые команды, НИЧЕГО не меняя
#   win-swap             Windows: подменить Utilman.exe → cmd.exe на найденном диске C (с резервной копией)
#   win-restore          Windows: вернуть настоящий Utilman.exe из резервной копии
#                        (ОБЯЗАТЕЛЬНО после смены пароля — иначе на экране входа остаётся открытый cmd от SYSTEM!)
#   linux                Linux: смонтировать корень и войти в chroot (там выполнить passwd root)
#
# Можно указать устройство вторым аргументом, если автоопределение ошиблось:
#   bash reset_password.sh win-swap /dev/mapper/ldm_vol_SERVER-Dg0_Volume2

set -u
MNT=/mnt/pvreset
RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; BLD=$'\033[1m'; RST=$'\033[0m'
msg(){ echo "$*"; }
warn(){ echo "${YEL}$*${RST}"; }
err(){ echo "${RED}$*${RST}" >&2; }
has(){ command -v "$1" >/dev/null 2>&1; }

[ "$(id -u)" = 0 ] || { err "Запустите от root."; exit 1; }

# ---- сборка «динамических дисков» Windows (LDM) и RAID, чтобы появились /dev/mapper/ldm_vol_* и /dev/md*
assemble(){
  if has ldmtool && fdisk -l 2>/dev/null | grep -qiE ' 42 | SFS|LDM'; then
    ldmtool scan >/dev/null 2>&1; ldmtool create all >/dev/null 2>&1
  fi
  has mdadm && mdadm --assemble --scan >/dev/null 2>&1
  return 0
}

# ---- путь внутри смонтированного раздела без учёта регистра (NTFS хранит регистр как есть): rel_ci <mnt> Windows/System32
rel_ci(){
  local base="$1" cur="$1" part rest="$2" hit
  IFS='/' read -ra part <<<"$rest"
  for p in "${part[@]}"; do
    [ -z "$p" ] && continue
    hit=$(find "$cur" -maxdepth 1 -iname "$p" 2>/dev/null | head -n1)
    [ -z "$hit" ] && return 1
    cur="$hit"
  done
  printf '%s\n' "$cur"
}

umnt(){ umount "$MNT" 2>/dev/null; }

# ---- все NTFS-устройства: обычные разделы + собранные LDM-тома
ntfs_devices(){
  { lsblk -lno NAME,FSTYPE 2>/dev/null | awk '$2=="ntfs"||$2=="ntfs3"{print "/dev/"$1}'
    ls /dev/mapper/ldm_vol_* 2>/dev/null; } | sort -u
}
# ---- кандидаты в корень Linux: RAID-массивы + разделы с ext*/xfs/btrfs
linux_devices(){
  { awk '/^md[0-9]/{print "/dev/"$1}' /proc/mdstat 2>/dev/null
    lsblk -lno NAME,FSTYPE 2>/dev/null | awk '$2 ~ /^(ext[234]|xfs|btrfs)$/{print "/dev/"$1}'; } | sort -u
}

# ---- найти том Windows (где есть Windows/System32/Utilman.exe); печатает: <dev>\t<путь к System32>
find_windows(){
  local d sys
  for d in $(ntfs_devices); do
    [ -b "$d" ] || continue
    umnt; mkdir -p "$MNT"
    mount -t ntfs-3g -o ro "$d" "$MNT" 2>/dev/null || mount -o ro "$d" "$MNT" 2>/dev/null || continue
    sys=$(rel_ci "$MNT" "Windows/System32")
    if [ -n "$sys" ] && [ -n "$(find "$sys" -maxdepth 1 -iname 'Utilman.exe' 2>/dev/null | head -n1)" ]; then
      umnt; printf '%s\t%s\n' "$d" "${sys#$MNT/}"; return 0
    fi
    umnt
  done
  return 1
}

# ---- найти корень Linux (где есть /etc/shadow); печатает <dev>, самый большой — первым
find_linux(){
  local d best="" bestsz=0 sz
  for d in $(linux_devices); do
    [ -b "$d" ] || continue
    umnt; mkdir -p "$MNT"
    mount -o ro "$d" "$MNT" 2>/dev/null || continue
    if [ -f "$MNT/etc/shadow" ]; then
      sz=$(blockdev --getsize64 "$d" 2>/dev/null || echo 0)
      [ "$sz" -gt "$bestsz" ] && { best="$d"; bestsz=$sz; }
    fi
    umnt
  done
  [ -n "$best" ] && { printf '%s\n' "$best"; return 0; }
  return 1
}

users_hint(){  # имена учёток Windows по папкам в Users (подсказка для net user <user>); том уже смонтирован в $MNT
  local udir; udir=$(rel_ci "$MNT" "Users")
  [ -n "$udir" ] && ls "$udir" 2>/dev/null | grep -viE '^(Public|Default|Default User|All Users|desktop.ini)$' | paste -sd', ' -
}

RESTORE_NOTE="${BLD}${RED}После смены пароля ОБЯЗАТЕЛЬНО верните Utilman!${RST} Загрузите rescue ещё раз и выполните:
    bash reset_password.sh win-restore
  Иначе на экране входа останется открытый cmd с правами SYSTEM — это дыра в безопасности."

mode="${1:-detect}"; dev="${2:-}"

case "$mode" in
  detect)
    assemble
    msg "${BLD}Определяю раскладку сервера…${RST}"
    if win=$(find_windows); then
      d=${win%%$'\t'*}; sys=${win#*$'\t'}
      msg "${GRN}Найден Windows${RST}: диск C → ${BLD}$d${RST}  (Windows: /$sys/..)"
      mount -t ntfs-3g -o ro "$d" "$MNT" 2>/dev/null && { uh=$(users_hint); umnt; }
      [ -n "${uh:-}" ] && msg "Учётки на сервере (для net user): ${BLD}${uh}${RST}"
      cat <<EOF

${BLD}Готовые команды — сброс пароля Windows${RST} (проверьте устройство $d):

  # 1) чиним NTFS (после hard reset том монтируется только для чтения) и подменяем Utilman на cmd
  bash reset_password.sh win-swap $d

  # 2) перезагрузите сервер в обычную ОС (в панели), дождитесь RDP
  # 3) откройте VNC/KVM, на экране входа нажмите «Специальные возможности» (Utilman) — откроется cmd
  # 4) задайте пароль РУКАМИ (раскладка EN):
  #       net user <имя_учётки> <новый_пароль>
  #       shutdown -s -t 1
  # 5) войдите по RDP, затем вернитесь в rescue и ОБЯЗАТЕЛЬНО:
  bash reset_password.sh win-restore

EOF
      warn "Временный пароль клиенту не передаём."
    elif root=$(find_linux); then
      msg "${GRN}Найден Linux${RST}: корень → ${BLD}$root${RST}"
      cat <<EOF

${BLD}Готовые команды — сброс пароля Linux${RST} (проверьте устройство $root):

  bash reset_password.sh linux          # смонтирует $root и войдёт в chroot
    passwd root                          # задайте пароль РУКАМИ
    exit
  # дальше скрипт сам размонтирует и предложит reboot

Или вручную:
  mkdir -p $MNT && mount $root $MNT
  chroot $MNT passwd root
  sync && umount $MNT && reboot

EOF
    else
      err "Не нашёл ни Windows (Utilman.exe), ни Linux (/etc/shadow)."
      msg "Проверьте вручную: ${BLD}fdisk -l${RST} и ${BLD}lsblk -f${RST}. Для динамических дисков Windows: ${BLD}ldmtool scan && ldmtool create all${RST}."
      exit 2
    fi
    ;;

  win-swap)
    assemble
    if [ -z "$dev" ]; then win=$(find_windows) || { err "Не нашёл том Windows. Укажите устройство: bash reset_password.sh win-swap /dev/..."; exit 2; }; dev=${win%%$'\t'*}; fi
    [ -b "$dev" ] || { err "Нет такого устройства: $dev"; exit 2; }
    msg "Чиню NTFS на $dev…"; ntfsfix "$dev" || warn "ntfsfix вернул ошибку — продолжаю, монтирование может всё равно сработать."
    umnt; mkdir -p "$MNT"
    mount -t ntfs-3g "$dev" "$MNT" 2>/dev/null || mount "$dev" "$MNT" || { err "Не смонтировать $dev."; exit 2; }
    sys=$(rel_ci "$MNT" "Windows/System32") || { err "На $dev нет Windows/System32 — это не диск C."; umnt; exit 2; }
    util=$(find "$sys" -maxdepth 1 -iname 'Utilman.exe' 2>/dev/null | head -n1)
    cmd=$(find "$sys" -maxdepth 1 -iname 'cmd.exe' 2>/dev/null | head -n1)
    [ -n "$util" ] && [ -n "$cmd" ] || { err "Не нашёл Utilman.exe/cmd.exe в $sys."; umnt; exit 2; }
    if [ ! -e "$util.pvbak" ]; then cp -p "$util" "$util.pvbak" && msg "Резервная копия: $(basename "$util").pvbak"; else warn "Резервная копия уже есть — не перезаписываю."; fi
    cp -f "$cmd" "$util" && msg "${GRN}Utilman.exe подменён на cmd.exe.${RST}"
    sync; umnt
    echo; msg "$RESTORE_NOTE"
    echo; warn "Дальше: перезагрузка в ОС → VNC → Utilman → net user <user> <пароль> (руками, EN) → shutdown -s -t 1."
    ;;

  win-restore)
    assemble
    if [ -z "$dev" ]; then win=$(find_windows) || { err "Не нашёл том Windows."; exit 2; }; dev=${win%%$'\t'*}; fi
    [ -b "$dev" ] || { err "Нет такого устройства: $dev"; exit 2; }
    ntfsfix "$dev" >/dev/null 2>&1
    umnt; mkdir -p "$MNT"; mount -t ntfs-3g "$dev" "$MNT" 2>/dev/null || mount "$dev" "$MNT" || { err "Не смонтировать $dev."; exit 2; }
    sys=$(rel_ci "$MNT" "Windows/System32"); bak=$(find "$sys" -maxdepth 1 -iname 'Utilman.exe.pvbak' 2>/dev/null | head -n1)
    util=$(find "$sys" -maxdepth 1 -iname 'Utilman.exe' 2>/dev/null | head -n1)
    if [ -n "$bak" ]; then cp -f "$bak" "$util" && rm -f "$bak" && msg "${GRN}Настоящий Utilman.exe восстановлен.${RST}"; else warn "Резервной копии Utilman.exe.pvbak нет — возможно, уже восстановлено."; fi
    sync; umnt
    ;;

  linux)
    assemble
    if [ -z "$dev" ]; then dev=$(find_linux) || { err "Не нашёл корень Linux (/etc/shadow). Укажите устройство: bash reset_password.sh linux /dev/md2"; exit 2; }; fi
    [ -b "$dev" ] || { err "Нет такого устройства: $dev"; exit 2; }
    umnt; mkdir -p "$MNT"; mount "$dev" "$MNT" || { err "Не смонтировать $dev."; exit 2; }
    [ -f "$MNT/etc/shadow" ] || { err "На $dev нет /etc/shadow — это не корень системы."; umnt; exit 2; }
    for d in dev proc sys; do mount --bind "/$d" "$MNT/$d" 2>/dev/null; done
    msg "${GRN}Смонтировано $dev → $MNT.${RST} Выполните ${BLD}passwd root${RST} (пароль руками), затем ${BLD}exit${RST}."
    chroot "$MNT" /bin/bash -l
    for d in sys proc dev; do umount "$MNT/$d" 2>/dev/null; done
    sync; umnt
    warn "Готово. Перезагрузите сервер: reboot (или в панели)."
    ;;

  *) err "Неизвестный режим: $mode"; grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//' | head -n 22; exit 2 ;;
esac
