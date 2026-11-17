#!/usr/bin/env python3
"""PowerVPS — память сервера: как стоят модули (dmidecode) и что говорят дампы синих экранов Windows.

  python3 hw_memory.py modules            # модули памяти: сколько, тип, частота, ECC
  python3 hw_memory.py dumps <Windows> [дней]   # коды синих экранов из Minidump/*.dmp и MEMORY.DMP

Строки, начинающиеся с '!! ', попадают в список находок отчёта; строка 'MEM ...' — машинная сводка для правил.
Зачем: нестабильная память даёт «случайные» сбои — разные коды синих экранов, падения разных программ, а короткий
тест под нагрузкой её не ловит. Здесь мы сами собираем то, что обычно присылает клиент после разбора в WinDbg.
"""
import os, re, struct, subprocess, sys, datetime, glob

# ---------- модули памяти ----------
def parse_dmidecode(text):
    """→ (modules, ecc, slots). modules: [{size_gb, type, speed, conf, part, vendor, loc}]"""
    mods = []; ecc = None; slots = 0
    for blk in re.split(r'\n\s*\n', text):
        if 'Physical Memory Array' in blk:
            m = re.search(r'Error Correction Type:\s*(.+)', blk)
            if m: ecc = not re.match(r'(None|Unknown|Other)', m.group(1).strip(), re.I)
        if not re.search(r'^Memory Device\s*$', blk, re.M): continue
        f = dict((k.strip(), v.strip()) for k, v in re.findall(r'^\s+([^:\n]+):\s*(.*)$', blk, re.M))
        if 'Size' not in f: continue
        slots += 1
        ms = re.match(r'(\d+)\s*(MB|GB|TB)', f.get('Size', ''))
        if not ms: continue                                   # «No Module Installed»
        gb = int(ms.group(1)) * {'MB': 1 / 1024, 'GB': 1, 'TB': 1024}[ms.group(2)]
        num = lambda s: int(re.match(r'(\d+)', s).group(1)) if re.match(r'\d+', s or '') else 0
        mods.append({'size_gb': int(round(gb)), 'type': f.get('Type', '?'), 'speed': num(f.get('Speed', '')),
                     'conf': num(f.get('Configured Memory Speed', f.get('Configured Clock Speed', ''))),
                     'part': f.get('Part Number', '').strip(), 'vendor': f.get('Manufacturer', '').strip(), 'loc': f.get('Locator', ''),
                     'serial': re.sub(r'(?i)^(unknown|not specified|none|0+)$', '', f.get('Serial Number', '').strip())})
    return mods, ecc, slots

def mem_overspec(mods, ecc, slots):
    """Четыре небуферизованных модуля DDR5 (по два на канал) на высокой частоте — выше того, что гарантируют процессоры.
    AMD AM5 для четырёх модулей даёт DDR5-3600, Intel 12–14 поколения — DDR5-4000…4400. Серверные платформы (ECC, много слотов) не трогаем."""
    if not mods or ecc: return False
    conf = max(m['conf'] or m['speed'] for m in mods)
    return slots <= 4 and len(mods) == 4 and all('DDR5' in m['type'].upper() for m in mods) and conf >= 5200

def edac_dimms(root='/sys/devices/system/edac/mc'):
    """Память с ECC сама считает ошибки по каждому модулю — только так можно назвать конкретный слот.
    Без ECC (обычная настольная память) тест видит, что ошибки есть, но не видит, в какой планке."""
    import glob as _g
    for d in sorted(_g.glob(os.path.join(root, 'mc*', 'dimm*')) + _g.glob(os.path.join(root, 'mc*', 'rank*'))):
        rd = lambda n: (open(os.path.join(d, n)).read().strip() if os.path.exists(os.path.join(d, n)) else '')
        try: ce = int(rd('dimm_ce_count') or 0); ue = int(rd('dimm_ue_count') or 0)
        except ValueError: continue
        if not ce and not ue: continue
        label = rd('dimm_label') or rd('dimm_location') or os.path.basename(d)
        print('MEMERR slot="%s" ce=%d ue=%d' % (label, ce, ue))
        if ue: print('!! 🔴 память: неисправимые ошибки ECC в модуле %s = %d (исправленных: %d) — этот модуль нужно заменить' % (label, ue, ce))
        else: print('!! 🟡 память: исправленные ошибки ECC в модуле %s = %d — модуль деградирует, заменить планово' % (label, ce))


def cmd_modules(text=None):
    if text is None:
        try: text = subprocess.run(['dmidecode', '-t', '16', '-t', '17'], capture_output=True, text=True, timeout=20).stdout
        except Exception as e: print('   dmidecode недоступен: %s' % e); return
    mods, ecc, slots = parse_dmidecode(text)
    if not mods: print('   модули памяти не определены (dmidecode ничего не вернул)'); return
    conf = max(m['conf'] or m['speed'] for m in mods); rated = max(m['speed'] for m in mods)
    parts = sorted({m['part'] for m in mods if m['part']}); typ = mods[0]['type']
    for m in mods:
        print('   %-12s %3d ГБ %s  паспорт %s МГц, работает на %s МГц  %s %s' % (m['loc'], m['size_gb'], m['type'], m['speed'] or '?', m['conf'] or '?', m['vendor'], m['part']))
    print('   слотов %d, занято %d, ECC: %s' % (slots, len(mods), 'есть' if ecc else 'нет' if ecc is False else 'неизвестно'))
    # машинные строки по каждому модулю — из них собирается список модулей для заявки в дата-центр
    for m in mods:
        print('MEMDIMM loc="%s" size_gb=%d type=%s speed=%d conf=%d vendor="%s" part="%s" serial="%s"' % (m['loc'], m['size_gb'], m['type'].replace(' ', ''), m['speed'], m['conf'] or m['speed'], m['vendor'], m['part'], m['serial']))
    edac_dimms()
    over = mem_overspec(mods, ecc, slots)
    print('MEM slots=%d used=%d type=%s ecc=%d speed=%d rated=%d size_gb=%d mixed=%d overspec=%d part="%s"' % (
        slots, len(mods), typ.replace(' ', ''), 1 if ecc else 0, conf, rated, sum(m['size_gb'] for m in mods), 1 if len(parts) > 1 else 0, 1 if over else 0, ', '.join(parts)[:60]))
    if over:
        print('!! ℹ️ память: %d × %d ГБ %s без ECC работают на %d МГц — для четырёх модулей это выше гарантированного процессором (обычно 3600–4400 МГц). Сама по себе такая настройка не ошибка, но при случайных сбоях (разные синие экраны, падения разных программ) это первый подозреваемый: попросите дата-центр снизить частоту памяти в BIOS до стандартной (DDR5-4800 или ниже)' % (
            len(mods), mods[0]['size_gb'], typ, conf))
    if len(parts) > 1: print('!! ℹ️ память: стоят разные модули (%s) — разнотипные планки на высокой частоте работают менее стабильно' % ', '.join(parts)[:120])

# ---------- дампы синих экранов ----------
BUG = {0x0A: 'IRQL_NOT_LESS_OR_EQUAL', 0x18: 'REFERENCE_BY_POINTER', 0x19: 'BAD_POOL_HEADER', 0x1A: 'MEMORY_MANAGEMENT', 0x1E: 'KMODE_EXCEPTION_NOT_HANDLED',
       0x21: 'QUOTA_UNDERFLOW', 0x24: 'NTFS_FILE_SYSTEM', 0x3B: 'SYSTEM_SERVICE_EXCEPTION', 0x4E: 'PFN_LIST_CORRUPT', 0x50: 'PAGE_FAULT_IN_NONPAGED_AREA',
       0x7A: 'KERNEL_DATA_INPAGE_ERROR', 0x7E: 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED', 0x7F: 'UNEXPECTED_KERNEL_MODE_TRAP', 0x8E: 'KERNEL_MODE_EXCEPTION_NOT_HANDLED',
       0x9C: 'MACHINE_CHECK_EXCEPTION', 0x9F: 'DRIVER_POWER_STATE_FAILURE', 0xC2: 'BAD_POOL_CALLER', 0xC4: 'DRIVER_VERIFIER_DETECTED_VIOLATION', 0xC5: 'DRIVER_CORRUPTED_EXPOOL',
       0xD1: 'DRIVER_IRQL_NOT_LESS_OR_EQUAL', 0xEF: 'CRITICAL_PROCESS_DIED', 0xF7: 'DRIVER_OVERRAN_STACK_BUFFER', 0xFC: 'ATTEMPTED_EXECUTE_OF_NOEXECUTE_MEMORY',
       0x101: 'CLOCK_WATCHDOG_TIMEOUT', 0x109: 'CRITICAL_STRUCTURE_CORRUPTION', 0x116: 'VIDEO_TDR_FAILURE', 0x124: 'WHEA_UNCORRECTABLE_ERROR', 0x12B: 'FAULTY_HARDWARE_CORRUPTED_PAGE',
       0x133: 'DPC_WATCHDOG_VIOLATION', 0x139: 'KERNEL_SECURITY_CHECK_FAILURE', 0x13A: 'KERNEL_MODE_HEAP_CORRUPTION', 0x154: 'UNEXPECTED_STORE_EXCEPTION', 0x1000007E: 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED_M', 0x1000008E: 'KERNEL_MODE_EXCEPTION_NOT_HANDLED_M'}
HW_CODES = {0x124, 0x12B, 0x9C}                      # прямо называют аппаратную ошибку
# «повреждение памяти»: ядро наткнулось на испорченные данные/код. Один и тот же код раз за разом — чаще драйвер; разные коды — чаще оперативная память
MEM_FAMILY = {0x0A, 0x18, 0x19, 0x1A, 0x1E, 0x21, 0x3B, 0x4E, 0x50, 0x7E, 0x7F, 0x8E, 0xC2, 0xC5, 0xD1, 0xF7, 0xFC, 0x109, 0x139, 0x13A, 0x1000007E, 0x1000008E}

def read_dump_header(path):
    """Заголовок дампа ядра Windows: → (код, [4 параметра]) или None. 64-бит: 'PAGEDU64', код @0x38, параметры @0x40; 32-бит: 'PAGEDUMP', код @0x20."""
    try:
        with open(path, 'rb') as f: h = f.read(0x80)
    except OSError: return None
    if h[:8] == b'PAGEDU64' and len(h) >= 0x60:
        return struct.unpack_from('<I', h, 0x38)[0], list(struct.unpack_from('<4Q', h, 0x40))
    if h[:8] == b'PAGEDUMP' and len(h) >= 0x34:
        return struct.unpack_from('<I', h, 0x20)[0], list(struct.unpack_from('<4I', h, 0x24))
    return None

def code_name(c): return '0x%X %s' % (c, BUG.get(c, '')) if BUG.get(c) else '0x%X' % c

def cmd_dumps(win, days=30, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    files = []
    for pat in ('Minidump/*.dmp', 'minidump/*.dmp', 'Minidump/*.DMP', 'MEMORY.DMP', 'memory.dmp', 'LiveKernelReports/*/*.dmp'):
        files += glob.glob(os.path.join(win, pat))
    rows = []
    for p in sorted(set(files)):
        hd = read_dump_header(p)
        try: mt = datetime.datetime.fromtimestamp(os.path.getmtime(p), datetime.timezone.utc).replace(tzinfo=None)
        except OSError: continue
        if 'LiveKernelReports' in p: continue          # «живые» отчёты — не падения
        rows.append({'path': p, 'name': os.path.basename(p), 'time': mt, 'hd': hd})
    if not rows: print('   дампов синих экранов нет'); return
    print('   дамп, время записи (UTC), код синего экрана и параметры:')
    for r in sorted(rows, key=lambda r: r['time']):
        if r['hd']: print('   %-28s %s  %s  (%s)' % (r['name'], r['time'].strftime('%Y-%m-%d %H:%M'), code_name(r['hd'][0]), ', '.join('0x%X' % x for x in r['hd'][1])))
        else: print('   %-28s %s  заголовок не распознан' % (r['name'], r['time'].strftime('%Y-%m-%d %H:%M')))
    since = now - datetime.timedelta(days=days)
    # полный MEMORY.DMP и минидамп одного и того же падения не считаем дважды (тот же код, запись в пределах 10 минут)
    ev = []
    for r in sorted((r for r in rows if r['hd'] and r['time'] >= since), key=lambda r: r['time']):
        if any(e['hd'][0] == r['hd'][0] and abs((e['time'] - r['time']).total_seconds()) < 600 for e in ev): continue
        ev.append(r)
    if not ev: return
    lst = ', '.join('%s (%s)' % (code_name(r['hd'][0]).strip(), r['time'].strftime('%d.%m %H:%M')) for r in ev[-6:])
    codes = [r['hd'][0] for r in ev]; distinct = sorted(set(codes))
    hw = [c for c in distinct if c in HW_CODES]
    if hw:
        print('!! 🔴 синий экран с кодом аппаратной ошибки: %s — Windows сама сообщает о сбое железа (процессор, память, плата)' % lst)
    elif len(ev) >= 2 and len(distinct) >= 2 and sum(1 for c in codes if c in MEM_FAMILY) >= 2:
        print('!! 🟡 синие экраны с разными кодами: %s — когда коды каждый раз разные и все из группы «повреждение памяти», причина обычно не драйвер (он даёт один и тот же код), а оперативная память: нужен долгий тест памяти и проверка модулей' % lst)
    elif len(ev) >= 2 and len(distinct) == 1:
        print('!! 🟡 синие экраны с одним и тем же кодом: %s — %d раз. Повторяющийся код чаще указывает на конкретный драйвер или программу; разберите дамп (WinDbg, !analyze -v)' % (code_name(distinct[0]).strip(), len(ev)))
    else:
        print('!! ℹ️ коды синих экранов из дампов: %s' % lst)
    pt = [r for r in ev if r['hd'][0] == 0x1A and r['hd'][1][0] in (0x41790, 0x41792, 0x41201, 0x403, 0x61941, 0x61948)]
    if pt: print('!! ℹ️ MEMORY_MANAGEMENT с подкодом 0x%X — повреждена таблица страниц памяти: при исправных драйверах так проявляется сбой оперативной памяти' % pt[-1]['hd'][1][0])

if __name__ == '__main__':
    a = sys.argv[1:]
    if not a or a[0] == 'modules': cmd_modules()
    elif a[0] == 'dumps' and len(a) >= 2: cmd_dumps(a[1], int(a[2]) if len(a) > 2 else 30)
    else: print(__doc__)
