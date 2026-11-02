#!/usr/bin/env python3
"""win_evtx_report.py <Windows-dir> [days] — read-only summary of Windows event logs (System/Application .evtx)
from a Windows disk mounted read-only (e.g. in a Linux rescue system). Prints '!! ' lines for problems, then details."""
import os, re, sys, collections, datetime, html
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
    ('volmgr', 46): ('warn', 'Windows не может записать дамп падения (не настроен файл подкачки/дамп) — причину синих экранов не узнать'),
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


def clean(v):
    # старые события (6008 и др.) хранят параметры как экранированный XML <string>…</string>; убираем экранирование и метки направления текста
    v = html.unescape(html.unescape(v or '')).replace('\u200e', '').replace('\u200f', '')
    parts = re.findall(r'<string>(.*?)</string>', v, re.S)
    if parts: v = ' | '.join(p.strip() for p in parts if p.strip())
    return re.sub(r'\s+', ' ', v).strip()


STATS = {}


def scan(path):
    hits = collections.defaultdict(list)
    st = STATS.setdefault(os.path.basename(path), {'n': 0, 'bad': 0, 'first': None, 'last': None, 'win': 0})
    try:
        with Evtx(path) as log:
            for rec in log.records():
                try: x = rec.xml()
                except Exception: st['bad'] += 1; continue
                st['n'] += 1
                t0 = rx_time.search(x)
                if t0:
                    ts0 = t0.group(1)[:19].replace('T', ' ')
                    if not st['first'] or ts0 < st['first']: st['first'] = ts0
                    if not st['last'] or ts0 > st['last']: st['last'] = ts0
                    if ts0 >= SINCE.strftime('%Y-%m-%d %H:%M:%S'): st['win'] += 1
                m = rx_id.search(x); p = rx_prov.search(x)
                if not m or not p: continue
                eid = int(m.group(1)); prov = p.group(1)
                for (ps, rid), (sev, txt) in RULES.items():
                    if rid == eid and ps.lower() in prov.lower():
                        if (ps, rid) == ('Ntfs', 98):   # 28/10: Win11/2025 log «volume is healthy» as 98 with Level 4 -> only warnings/errors count
                            lv = re.search(r'<Level>(\d)</Level>', x)
                            if lv and lv.group(1) == '4': break
                        t = rx_time.search(x); ts = t.group(1)[:19].replace('T', ' ') if t else '?'
                        try:
                            if datetime.datetime.strptime(ts, '%Y-%m-%d %H:%M:%S') < SINCE: break
                        except ValueError: pass
                        data = ' | '.join((n + '=' if n else '') + clean(v) for n, v in rx_data.findall(x) if clean(v))[:220]
                        hits[(sev, prov, eid, txt)].append((ts, data)); break
    except Exception as e:
        print('!! 🟡 не удалось прочитать %s: %s' % (os.path.basename(path), e))
    return hits


allh = {}
for name in ('System.evtx', 'Application.evtx'):
    f = os.path.join(LOGS, name)
    if os.path.exists(f): allh.update(scan(f))
    else: print('!! 🟡 нет журнала', os.path.basename(f))
# Журналы прочитались? Пустой/непрочитанный журнал ≠ «ошибок нет» (28/10: сервер гас, а отчёт был чистым — журналы не разобрались)
NOW = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
for name, st in STATS.items():
    if st['n'] == 0:
        print('!! 🟡 журнал %s не прочитан (записей 0, ошибок разбора %d) — события Windows НЕ проверены, вывод «ошибок нет» по нему делать нельзя' % (name, st['bad']))
        continue
    if st['bad'] > st['n']:
        print('!! 🟡 журнал %s прочитан частично: записей %d, ошибок разбора %d — часть событий могла не попасть в проверку' % (name, st['n'], st['bad']))
    if name == 'System.evtx' and st['last']:
        try:
            last = datetime.datetime.strptime(st['last'], '%Y-%m-%d %H:%M:%S')
            age = (NOW - last).days
            if age >= 3:
                # Windows при этом работала? Реестр (config) и CBS.log пишутся, пока система запущена
                alive = []
                for p in ('System32/config/SYSTEM', 'System32/config/SOFTWARE', 'Logs/CBS/CBS.log'):
                    try: alive.append(datetime.datetime.fromtimestamp(os.path.getmtime(os.path.join(WIN, p)), datetime.timezone.utc).replace(tzinfo=None))
                    except OSError: pass
                ran = max(alive) if alive else None
                if ran and (ran - last).days >= 2:
                    print('!! 🟡 журнал событий Windows НЕ ПИШЕТСЯ: последнее событие %s UTC, а Windows работала как минимум до %s UTC (реестр/CBS.log) — служба «Журнал событий Windows» отключена или журналы очищаются. Причину сбоев по журналам не установить: попросите клиента включить службу журнала (Windows Event Log → Автоматически)' % (st['last'], ran.strftime('%Y-%m-%d %H:%M')))
                else:
                    print('!! 🟡 последнее событие в журнале System — %s UTC (%d дн. назад): журнал не пишется, был очищен или часы Windows сбиты — события последних дней не видны' % (st['last'], age))
            if st['n'] < 2000 and st['first'] and (last - datetime.datetime.strptime(st['first'], '%Y-%m-%d %H:%M:%S')).days > 180:
                print('!! ℹ️ в журнале System всего %d записей за %s — %s: для работающей Windows это очень мало (журнал чистили или ведение отключено)' % (st['n'], st['first'][:10], st['last'][:10]))
        except ValueError: pass
    if name == 'System.evtx' and st['first'] and st['first'] > SINCE.strftime('%Y-%m-%d %H:%M:%S'):
        print('!! ℹ️ журнал System хранит события только с %s UTC (меньше %d дн.) — старые сбои могли не попасть в проверку' % (st['first'], DAYS))
order = {'bad': 0, 'warn': 1, 'info': 2}
items = sorted(allh.items(), key=lambda kv: (order[kv[0][0]], -len(kv[1])))
for (sev, prov, eid, txt), ev in items:
    if sev != 'info':
        print('!! %s %s: %d раз за %d дн. (последний %s UTC) [%s/%d]' % ('🔴' if sev == 'bad' else '🟡', txt, len(ev), DAYS, max(e[0] for e in ev), prov, eid))
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
# Kernel-Power 41: BugcheckCode=0 — это не синий экран, а зависание или жёсткий сброс/пропадание питания
kp = [d for (sev, prov, eid, txt), ev in allh.items() if eid == 41 and 'kernel-power' in prov.lower() for _, d in ev]
if kp:
    zero = sum(1 for d in kp if re.search(r'BugcheckCode=0\b', d))
    if zero == len(kp):
        print('!! ℹ️ внезапные перезагрузки (Kernel-Power 41) без кода синего экрана (BugcheckCode=0): система зависла или её сбросили кнопкой/по питанию (в т.ч. Reset из панели); дампа нет')
    elif zero < len(kp):
        print('!! 🔴 среди внезапных перезагрузок есть синие экраны: %d из %d с кодом BugCheck (см. детали)' % (len(kp) - zero, len(kp)))
# 6008: когда система перестала работать и когда загрузилась снова — сколько сервер «лежал»
boots = sorted(e[0] for (sev, prov, eid, txt), ev in allh.items() if eid == 12 and 'kernel-general' in prov.lower() for e in ev)
if STATS.get('System.evtx', {}).get('n'):
    print('!! ℹ️ загрузок Windows за %d дн.: %d%s' % (DAYS, len(boots), (' — последние: ' + ', '.join(b[:16] for b in boots[-5:]) + ' UTC') if boots else ' — Windows за это время ни разу не перезагружалась (если сервер «выключался», а загрузок нет — он пропадал из сети/зависал без перезагрузки или журнал не пишется)'))
for (sev, prov, eid, txt), ev in allh.items():
    if eid == 6008 and 'eventlog' in prov.lower():
        for ts, d in sorted(ev)[-3:]:
            m = re.match(r'([\d:]+ ?[AP]?M?) \| ([\d/.]+)', d)
            if m: print('!! ℹ️ Windows перестала работать %s %s (время сервера), следующая загрузка — %s UTC: всё это время сервер был недоступен' % (m.group(2), m.group(1), ts))
stops = sorted({t for (sev, prov, eid, txt), ev in allh.items() if (eid in (41, 6008, 1074, 6006)) for t in (_dt(e[0]) for e in ev) if t})
if len(stops) >= 4:
    gaps = [(b - a).total_seconds() / 60 for a, b in zip(stops, stops[1:]) if (b - a).total_seconds() > 300]
    if len(gaps) >= 3:
        gs = sorted(gaps); med = gs[len(gs) // 2]
        near = sum(1 for g in gaps if abs(g - med) <= max(10, med * 0.15))
        if near >= max(3, len(gaps) * 0.6):
            print('!! 🔴 выключения идут ПО РАСПИСАНИЮ: примерно каждые %d мин (%d из %d интервалов). Ищи причину-«таймер»: лицензия (WLMS), задача в Планировщике, политика/скрипт, ИБП/BIOS, хостер.' % (round(med), near, len(gaps)))
# Когда Windows в последний раз что-то писала на диск — реестр и CBS.log меняются, пока система работает
traces = []
for p in ('System32/config/SYSTEM', 'System32/config/SOFTWARE', 'System32/config/SAM', 'Logs/CBS/CBS.log', 'System32/winevt/Logs/System.evtx', 'System32/LogFiles'):
    try: traces.append((datetime.datetime.fromtimestamp(os.path.getmtime(os.path.join(WIN, p)), datetime.timezone.utc).replace(tzinfo=None), p))
    except OSError: pass
if traces:
    lt, lp = max(traces)
    print('!! ℹ️ Windows в последний раз записывала на диск %s UTC (%s) — примерно тогда система работала в последний раз; если с тех пор прошли дни, сервер с тех пор не загружался в Windows или зависал' % (lt.strftime('%Y-%m-%d %H:%M'), lp))
print('\n---- event logs read')
for t, p in sorted(traces, reverse=True): print('   изменён %s UTC  %s' % (t.strftime('%Y-%m-%d %H:%M'), p))
for name, st in STATS.items(): print('   %s: записей %d, ошибок разбора %d, в окне %d дн.: %d, события с %s по %s UTC' % (name, st['n'], st['bad'], DAYS, st['win'], st['first'] or '—', st['last'] or '—'))
print('\n---- details (last 8 of each)')
for (sev, prov, eid, txt), ev in items:
    print('\n[%s] %s / %d — %s — %d' % (sev, prov, eid, txt, len(ev)))
    if (prov, eid) == ('Application Error', 1000) or eid == 1000:   # top crashing programs
        c = collections.Counter(re.split(r'\s*\|\s*', d)[0] for _, d in ev)
        for k, n in c.most_common(8): print('   %4d × %s' % (n, k[:120]))
    for ts, d in sorted(ev)[-8:]: print('   %s  %s' % (ts, d))
