#!/usr/bin/env python3
"""win_evtx_report.py <Windows-dir> [days] — read-only summary of Windows event logs (System/Application .evtx)
from a Windows disk mounted read-only (e.g. in a Linux rescue system). Prints '!! ' lines for problems, then details."""
import os, re, sys, collections, datetime
from Evtx.Evtx import Evtx

WIN = sys.argv[1]; DAYS = int(sys.argv[2]) if len(sys.argv) > 2 else 30
LOGS = os.path.join(WIN, 'System32', 'winevt', 'Logs')
SINCE = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) - datetime.timedelta(days=DAYS)
# (provider substring, event id) -> (severity, meaning)
RULES = {
    ('Kernel-Power', 41): ('bad', 'внезапная перезагрузка/выключение без штатного завершения (зависание, синий экран или пропало питание)'),
    ('EventLog', 6008): ('bad', 'предыдущее выключение было неожиданным'),
    ('WER-SystemErrorReporting', 1001): ('bad', 'синий экран (BugCheck) — код в деталях'),
    ('BugCheck', 1001): ('bad', 'синий экран (BugCheck) — код в деталях'),
    ('disk', 7): ('bad', 'на диске найден повреждённый блок (bad block)'),
    ('disk', 11): ('bad', 'ошибка контроллера диска'),
    ('disk', 51): ('bad', 'ошибка при записи страницы на диск'),
    ('disk', 153): ('bad', 'повторные попытки ввода-вывода на диске'),
    ('disk', 157): ('warn', 'диск внезапно отключался'),
    ('storahci', 129): ('warn', 'сброс контроллера диска (зависание ввода-вывода)'),
    ('stornvme', 129): ('warn', 'сброс NVMe-контроллера'),
    ('Ntfs', 55): ('bad', 'повреждение файловой системы NTFS'),
    ('Ntfs', 98): ('bad', 'том NTFS требует проверки (chkdsk)'),
    ('Ntfs', 137): ('warn', 'ошибка журнала транзакций NTFS'),
    ('WHEA-Logger', 1): ('bad', 'аппаратная ошибка (WHEA)'),
    ('WHEA-Logger', 17): ('warn', 'исправленная аппаратная ошибка PCIe (WHEA)'),
    ('WHEA-Logger', 18): ('bad', 'фатальная аппаратная ошибка процессора/памяти (WHEA)'),
    ('WHEA-Logger', 19): ('warn', 'исправленная аппаратная ошибка (WHEA)'),
    ('WHEA-Logger', 47): ('warn', 'исправленная ошибка памяти (WHEA)'),
    ('Service Control Manager', 7031): ('warn', 'служба неожиданно завершилась'),
    ('Service Control Manager', 7034): ('warn', 'служба неожиданно завершилась'),
    ('Service Control Manager', 7000): ('warn', 'служба не смогла запуститься'),
    ('Service Control Manager', 7023): ('warn', 'служба завершилась с ошибкой'),
    ('Resource-Exhaustion-Detector', 2004): ('bad', 'Windows не хватало памяти'),
    ('Srv', 2019): ('warn', 'кончился невыгружаемый пул памяти'),
    ('Kernel-Processor-Power', 37): ('warn', 'процессор снижал частоту (перегрев/питание)'),
    ('Time-Service', 36): ('warn', 'часы давно не синхронизировались'),
    ('Application Error', 1000): ('info', 'падение программы'),
    ('Application Hang', 1002): ('info', 'программа зависла'),
    ('Kernel-General', 12): ('info', 'загрузка системы'),
    ('User32', 1074): ('info', 'штатная перезагрузка/выключение (кто и почему)'),
    ('WLMS', 100): ('bad', 'истёк срок лицензии/ознакомительной версии Windows — служба WLMS выключает сервер каждый час'),
    ('EventLog', 6006): ('info', 'журнал событий остановлен (выключение)'),
}
rx_prov = re.compile(r'<Provider Name="([^"]+)"'); rx_id = re.compile(r'<EventID[^>]*>(\d+)</EventID>')
rx_time = re.compile(r'<TimeCreated SystemTime="([^"]+)"'); rx_data = re.compile(r'<Data(?: Name="([^"]*)")?>([^<]*)</Data>')


def scan(path):
    hits = collections.defaultdict(list)
    try:
        with Evtx(path) as log:
            for rec in log.records():
                try: x = rec.xml()
                except Exception: continue
                m = rx_id.search(x); p = rx_prov.search(x)
                if not m or not p: continue
                eid = int(m.group(1)); prov = p.group(1)
                for (ps, rid), (sev, txt) in RULES.items():
                    if rid == eid and ps.lower() in prov.lower():
                        t = rx_time.search(x); ts = t.group(1)[:19].replace('T', ' ') if t else '?'
                        try:
                            if datetime.datetime.strptime(ts, '%Y-%m-%d %H:%M:%S') < SINCE: break
                        except ValueError: pass
                        data = ' | '.join((n + '=' if n else '') + v for n, v in rx_data.findall(x) if v.strip())[:220]
                        hits[(sev, prov, eid, txt)].append((ts, data)); break
    except Exception as e:
        print('!! 🟡 не удалось прочитать %s: %s' % (os.path.basename(path), e))
    return hits


allh = {}
for name in ('System.evtx', 'Application.evtx'):
    f = os.path.join(LOGS, name)
    if os.path.exists(f): allh.update(scan(f))
    else: print('!! 🟡 нет журнала', os.path.basename(f))
order = {'bad': 0, 'warn': 1, 'info': 2}
items = sorted(allh.items(), key=lambda kv: (order[kv[0][0]], -len(kv[1])))
for (sev, prov, eid, txt), ev in items:
    if sev != 'info':
        print('!! %s %s: %d раз за %d дн. (последний %s) [%s/%d]' % ('🔴' if sev == 'bad' else '🟡', txt, len(ev), DAYS, max(e[0] for e in ev), prov, eid))
# ---- pattern analysis (28/10): who shuts the server down, and does it happen on a schedule?
def _dt(ts):
    try: return datetime.datetime.strptime(ts, '%Y-%m-%d %H:%M:%S')
    except ValueError: return None
inits = collections.Counter()
for (sev, prov, eid, txt), ev in allh.items():
    if eid == 1074 and 'user32' in prov.lower():
        for _, d in ev: inits[re.split(r'\s*\|\s*', d)[0].split('=')[-1].strip()[:90]] += 1
if inits:
    top, n = inits.most_common(1)[0]
    print('!! %s кто выключал/перезагружал сервер чаще всего: %s (%d раз)' % ('🔴' if n >= 3 else '🟡', top, n))
    if 'wlms' in ' '.join(inits).lower():
        print('!! 🔴 ГЛАВНАЯ ПРИЧИНА, вероятно: сервер выключает служба лицензий WLMS (wlms.exe) — Windows не активирована или закончилась ознакомительная (Evaluation) версия. Нужна активация/лицензия.')
stops = sorted({t for (sev, prov, eid, txt), ev in allh.items() if (eid in (41, 6008, 1074, 6006)) for t in (_dt(e[0]) for e in ev) if t})
if len(stops) >= 4:
    gaps = [(b - a).total_seconds() / 60 for a, b in zip(stops, stops[1:]) if (b - a).total_seconds() > 300]
    if len(gaps) >= 3:
        gs = sorted(gaps); med = gs[len(gs) // 2]
        near = sum(1 for g in gaps if abs(g - med) <= max(10, med * 0.15))
        if near >= max(3, len(gaps) * 0.6):
            print('!! 🔴 выключения идут ПО РАСПИСАНИЮ: примерно каждые %d мин (%d из %d интервалов). Ищи причину-«таймер»: лицензия (WLMS), задача в Планировщике, политика/скрипт, ИБП/BIOS, хостер.' % (round(med), near, len(gaps)))
print('\n---- details (last 8 of each)')
for (sev, prov, eid, txt), ev in items:
    print('\n[%s] %s / %d — %s — %d' % (sev, prov, eid, txt, len(ev)))
    if (prov, eid) == ('Application Error', 1000) or eid == 1000:   # top crashing programs
        c = collections.Counter(re.split(r'\s*\|\s*', d)[0] for _, d in ev)
        for k, n in c.most_common(8): print('   %4d × %s' % (n, k[:120]))
    for ts, d in sorted(ev)[-8:]: print('   %s  %s' % (ts, d))
