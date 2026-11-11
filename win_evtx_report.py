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
rx_level = re.compile(r'<Level>(\d)</Level>')
rx_time = re.compile(r'<TimeCreated SystemTime="([^"]+)"'); rx_data = re.compile(r'<Data(?: Name="([^"]*)")?>([^<]*)</Data>')


def clean(v):
    # старые события (6008 и др.) хранят параметры как экранированный XML <string>…</string>; убираем экранирование и метки направления текста
    v = html.unescape(html.unescape(v or '')).replace('\u200e', '').replace('\u200f', '')
    parts = re.findall(r'<string>(.*?)</string>', v, re.S)
    if parts: v = ' | '.join(p.strip() for p in parts if p.strip())
    return re.sub(r'\s+', ' ', v).strip()


STATS = {}
ALLEV = []   # (ts, provider, id) — все события окна: по ним видно, когда система в последний раз «подавала признаки жизни» перед сбоем
TL = []      # (ts, level, provider, id, data) — критические/ошибки/предупреждения окна: что происходило перед сбоем


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
                if t0 and ts0 >= SINCE.strftime('%Y-%m-%d %H:%M:%S'):
                    if st is STATS.get('System.evtx'): ALLEV.append((ts0, prov, eid))
                    lv = rx_level.search(x)
                    if lv and lv.group(1) in '123' and len(TL) < 400000:
                        TL.append((ts0, int(lv.group(1)), prov, eid, ' | '.join((n + '=' if n else '') + clean(v) for n, v in rx_data.findall(x) if clean(v))[:160]))
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
            ahead = (last - NOW).total_seconds() / 3600
            if ahead > 0.25:
                # события «из будущего»: часы Windows сбиты (часто — после rescue: Linux пишет в аппаратные часы UTC, а Windows читает их как местное время)
                print('!! ℹ️ часы Windows спешат примерно на %.1f ч: последнее событие в журнале — %s UTC, а сейчас %s UTC. Время последних событий Windows в этом отчёте сдвинуто (верить можно числу сбоев и интервалам между ними, но не точному времени)' % (ahead, st['last'], NOW.strftime('%Y-%m-%d %H:%M')))
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
                if st['win'] >= st['n'] * 0.7:
                    print('!! ℹ️ журнал System: %d из %d событий — за последние %d дн., старейшее — %s: Windows развёрнута из готового образа недавно (свежая установка у клиента), а не работает годами' % (st['win'], st['n'], DAYS, st['first'][:10]))
                else:
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
# 1074 — штатные перезагрузки: обновления Windows и ручные (shutdown.exe / меню Пуск) — это не сбой
kinds = collections.Counter()
for (sev, prov, eid, txt), ev in allh.items():
    if eid == 1074 and 'user32' in prov.lower():
        for _, d in ev:
            f = dict(x.split('=', 1) for x in re.split(r'\s*\|\s*', d) if '=' in x)
            who = f.get('param1', '').lower(); why = f.get('param3', '').lower(); usr = f.get('param7', '')
            if 'upgrade' in why or 'update' in why or 'trustedinstaller' in who or 'musnotif' in who: kinds['обновления Windows'] += 1
            elif 'wlms' in who: kinds['служба лицензий WLMS'] += 1
            elif 'shutdown.exe' in who or 'explorer.exe' in who or 'winlogon' in who: kinds['вручную' + (' (' + usr.split('\\')[-1] + ')' if usr and 'NT AUTHORITY' not in usr else '')] += 1
            else: kinds[(f.get('param1', '?').split('\\')[-1] or '?')[:60]] += 1
if inits:
    top, n = inits.most_common(1)[0]
    planned = sum(v for k, v in kinds.items() if k == 'обновления Windows' or k.startswith('вручную'))
    if planned == sum(kinds.values()) and n < 3:
        print('!! ℹ️ штатные перезагрузки (не сбой): %s' % ', '.join('%s — %d' % kv for kv in kinds.most_common()))
    else:
        print('!! %s кто выключал/перезагружал сервер чаще всего: %s (%d раз); по причинам: %s' % ('🔴' if n >= 3 else '🟡', top, n, ', '.join('%s — %d' % kv for kv in kinds.most_common())))
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
# часовой пояс Windows: 6008 пишет время остановки по местным часам сервера, а загрузку — в UTC
SI = {}
try:
    from win_accounts import sys_info
    SI = sys_info(WIN)
except Exception: pass
def _local(tm, dt):
    tm = tm.strip(); dt = dt.strip()
    for f in ('%m/%d/%Y %I:%M:%S %p', '%m/%d/%Y %H:%M:%S', '%d.%m.%Y %H:%M:%S', '%Y/%m/%d %H:%M:%S', '%d/%m/%Y %H:%M:%S'):
        try: return datetime.datetime.strptime(dt + ' ' + tm, f)
        except ValueError: pass
for (sev, prov, eid, txt), ev in allh.items():
    if eid == 6008 and 'eventlog' in prov.lower():
        for ts, d in sorted(ev)[-3:]:
            m = re.match(r'([\d:]+ ?[AP]?M?) \| ([\d/.]+)', d)
            if not m: continue
            lt = _local(m.group(1), m.group(2)); up = _dt(ts)
            if lt and up and SI.get('bias') is not None:
                stop = lt + datetime.timedelta(minutes=SI['bias']); mins = (up - stop).total_seconds() / 60
                if -5 <= mins:
                    print('!! ℹ️ Windows перестала работать ≈%s UTC (по часам сервера %s, пояс %s), загрузилась %s UTC — недоступна ≈%s' % (stop.strftime('%Y-%m-%d %H:%M'), lt.strftime('%H:%M'), SI.get('tz') or 'UTC%+d' % (-SI['bias'] / 60), ts[:16], ('%d мин' % max(1, round(mins))) if mins < 120 else ('%.1f ч' % (mins / 60)) if mins < 2880 else ('%.1f дн.' % (mins / 1440))))
                    continue
            print('!! ℹ️ Windows перестала работать %s %s (время сервера), следующая загрузка — %s UTC' % (m.group(2), m.group(1), ts))
# время штатного выключения из реестра: старое значение (за пределами окна) ничего не говорит — не показываем
if SI.get('shutdown') and SI['shutdown'] >= SINCE: print('!! ℹ️ последнее штатное выключение Windows: %s UTC' % SI['shutdown'].strftime('%Y-%m-%d %H:%M'))
stops = sorted({t for (sev, prov, eid, txt), ev in allh.items() if (eid in (41, 6008, 1074, 6006)) for t in (_dt(e[0]) for e in ev) if t})
if len(stops) >= 4:
    gaps = [(b - a).total_seconds() / 60 for a, b in zip(stops, stops[1:]) if (b - a).total_seconds() > 300]
    if len(gaps) >= 3:
        gs = sorted(gaps); med = gs[len(gs) // 2]
        near = sum(1 for g in gaps if abs(g - med) <= max(10, med * 0.15))
        if near >= max(3, len(gaps) * 0.6):
            print('!! 🔴 выключения идут ПО РАСПИСАНИЮ: примерно каждые %d мин (%d из %d интервалов). Ищи причину-«таймер»: лицензия (WLMS), задача в Планировщике, политика/скрипт, ИБП/BIOS, хостер.' % (round(med), near, len(gaps)))
# ---- что было перед каждым внезапным сбоем: сколько система проработала и какие ошибки/предупреждения шли в последние минуты
def fmt_up(sec):
    sec = int(max(0, sec))
    return '%d с' % sec if sec < 60 else '%d мин' % (sec // 60) if sec < 3600 else '%d ч %02d мин' % (sec // 3600, sec % 3600 // 60) if sec < 86400 else '%.1f дн.' % (sec / 86400)
def crash_context(allev, tl, boots, crashes, before=600, bootnoise=120):
    """allev: [(ts, prov, id)] событий System; tl: [(ts, level, prov, id, data)] ошибок; boots/crashes: метки времени 'YYYY-MM-DD HH:MM:SS'.
    Для каждого сбоя: загрузка, после которой он записан → последнее событие предыдущего сеанса (≈ момент остановки) → время работы сеанса → ошибки за последние минуты."""
    import bisect
    allts = sorted(e[0] for e in allev); tl = sorted(tl); tlts = [e[0] for e in tl]; boots = sorted(boots); out = []
    for c in sorted(set(crashes)):
        cd = _dt(c)
        if not cd: continue
        # загрузка, в которой записан сбой: «загрузка системы» идёт за пару секунд до Kernel-Power 41
        bs = [b for b in boots if _dt(b) and -5 <= (cd - _dt(b)).total_seconds() <= 300]
        b = bs[-1] if bs else c
        i = bisect.bisect_left(allts, b)
        if i == 0: continue                      # начало журнала — предыдущего сеанса не видно
        stop = allts[i - 1]; sd = _dt(stop)
        prev = [x for x in boots if x < b and x <= stop]
        up = (sd - _dt(prev[-1])).total_seconds() if prev else None
        lo = sd - datetime.timedelta(seconds=before)
        if prev: lo = max(lo, _dt(prev[-1]) + datetime.timedelta(seconds=bootnoise))   # первые 2 минуты после загрузки — обычный шум запуска служб
        ev = [e for e in tl[bisect.bisect_left(tlts, lo.strftime('%Y-%m-%d %H:%M:%S')):bisect.bisect_right(tlts, stop)] if not (e[3] in (41, 6008) or 'Kernel-Power' in e[2] and e[3] == 41)]
        lastany = [e for e in sorted(allev) if e[0] <= stop][-4:] if len(allev) < 200000 else []
        out.append({'crash': c, 'boot': b, 'stop': stop, 'up': up, 'down': (_dt(b) - sd).total_seconds(), 'ev': ev, 'last': lastany})
    return out
LVL = {1: 'критическая', 2: 'ошибка', 3: 'предупреждение'}
crash_ts = sorted(e[0] for (sev, prov, eid, txt), ev in allh.items() if eid == 41 and 'kernel-power' in prov.lower() for e in ev) or sorted(e[0] for (sev, prov, eid, txt), ev in allh.items() if eid == 6008 for e in ev)
CTX = []
try: CTX = crash_context(ALLEV, TL, boots, crash_ts)
except Exception as e: print('   (разбор событий перед сбоями не удался: %s)' % e)
if CTX:
    ups = [c['up'] for c in CTX if c['up'] is not None]
    if ups:
        early = sum(1 for u in ups if u < 900)
        print('!! ℹ️ сколько Windows проработала до каждого внезапного сбоя (по порядку%s): %s%s' % (', последние 12' if len(ups) > 12 else '', ', '.join(fmt_up(u) for u in ups[-12:]),
            (' — %d из %d сбоев случились в первые 15 минут после загрузки: система падает почти сразу после запуска (железо не держит нагрузку либо драйвер/программа из автозапуска) — нужен тест под нагрузкой и проверка автозапуска' % (early, len(ups))) if early >= 3 and early * 2 >= len(ups) else ''))
    # одно и то же событие перед несколькими сбоями — главный кандидат в причины
    usable = [c for c in CTX if c['up'] is None or c['up'] > 180]
    seen = collections.Counter(); sample = {}
    for c in usable:
        for k in {(e[2], e[3], e[1]) for e in c['ev']}: seen[k] += 1
        for e in c['ev']: sample[(e[2], e[3], e[1])] = e[4]
    rep = [(k, n) for k, n in seen.most_common() if n >= 2 and n * 2 >= len(usable)]
    for (prov, eid, lvl), n in rep[:4]:
        print('!! 🟡 перед внезапными перезагрузками повторяется одно и то же событие: %s / %d (%s) — перед %d из %d сбоев, в последние 10 минут до остановки%s' % (prov, eid, LVL.get(lvl, lvl), n, len(usable), (': ' + sample[(prov, eid, lvl)][:140]) if sample.get((prov, eid, lvl)) else ''))
    if usable and not rep and len(usable) >= 2 and all(not c['ev'] for c in usable):
        print('!! ℹ️ перед внезапными сбоями в журналах нет ни ошибок, ни предупреждений (последние 10 минут до остановки, %d сбоев): Windows не успевала ничего записать — так выглядит мгновенный сброс/пропадание питания или полное зависание, а не программная ошибка' % len(usable))
# Когда Windows в последний раз что-то писала на диск — реестр и CBS.log меняются, пока система работает
traces = []
for p in ('System32/config/SYSTEM', 'System32/config/SOFTWARE', 'System32/config/SAM', 'Logs/CBS/CBS.log', 'System32/winevt/Logs/System.evtx', 'System32/LogFiles'):
    try: traces.append((datetime.datetime.fromtimestamp(os.path.getmtime(os.path.join(WIN, p)), datetime.timezone.utc).replace(tzinfo=None), p))
    except OSError: pass
# время файла журнала часто отстаёт от содержимого — берём и время последней записи в журналах
for name, st in STATS.items():
    t = _dt(st['last']) if st.get('last') else None
    if t: traces.append((t, 'последнее событие в ' + name))
if traces:
    lt, lp = max(traces)
    print('!! ℹ️ Windows в последний раз записывала на диск %s UTC (%s) — примерно тогда система работала в последний раз; если с тех пор прошли дни, сервер с тех пор не загружался в Windows или зависал' % (lt.strftime('%Y-%m-%d %H:%M'), lp))
    # Хронология: последняя загрузка → последняя запись на диск → сейчас (rescue). Нет новых загрузок и дни тишины = зависание
    lb = _dt(boots[-1]) if boots else None
    idle = (NOW - lt).total_seconds() / 86400
    # штатная перезагрузка/выключение после последней загрузки (1074 — кто и почему)
    planned = sorted(e[0] for (sev, prov, eid, txt), ev in allh.items() if eid in (1074, 6006) for e in ev if lb and _dt(e[0]) and _dt(e[0]) >= lb)
    if lb and lt >= lb and idle < 1:
        print('!! ℹ️ после последней активности Windows (%s UTC) новых загрузок Windows нет (последняя загрузка — %s UTC)%s. Если сервер «не загружается» — сбой в самом начале загрузки, до запуска Windows (в журналах его не видно): порядок загрузки/диск в BIOS, загрузчик, проверка диска (chkdsk) или зависание на обновлениях — посмотрите экран сервера через KVM' % (
            lt.strftime('%Y-%m-%d %H:%M'), lb.strftime('%Y-%m-%d %H:%M'), (', перед этим Windows штатно уходила на перезагрузку/выключение в ' + planned[-1][:16] + ' UTC') if planned else ', штатного выключения перед этим не было (сброс/зависание)'))
    if lb and lt >= lb and idle >= 1:
        print('!! 🟡 Windows вероятно зависла: после последней загрузки %s UTC она работала минимум до %s UTC, затем %.1f дн. до этой диагностики ничего не записала на диск и ни разу не перезагрузилась — система висела (или сервер был выключен) с ~%s UTC. Сверьте с историей POWER/PING в панели' % (lb.strftime('%Y-%m-%d %H:%M'), lt.strftime('%Y-%m-%d %H:%M'), idle, lt.strftime('%Y-%m-%d %H:%M')))
print('\n---- event logs read')
for t, p in sorted(traces, reverse=True): print('   изменён %s UTC  %s' % (t.strftime('%Y-%m-%d %H:%M'), p))
for name, st in STATS.items(): print('   %s: записей %d, ошибок разбора %d, в окне %d дн.: %d, события с %s по %s UTC' % (name, st['n'], st['bad'], DAYS, st['win'], st['first'] or '—', st['last'] or '—'))
if CTX:
    print('\n---- before each unexpected stop (last 6): uptime and warnings/errors in the last 10 minutes')
    for c in CTX[-6:]:
        print('\n   сбой: последняя запись %s UTC → загрузка %s UTC (простой %s)%s' % (c['stop'], c['boot'], fmt_up(c['down']), (', проработала ' + fmt_up(c['up'])) if c['up'] is not None else ''))
        if c['up'] is not None and c['up'] <= 180: print('      сеанс короче 3 минут — события запуска не показываю')
        elif not c['ev']: print('      ошибок и предупреждений за последние 10 минут нет')
        for e in c['ev'][-10:]: print('      %s  [%s] %s / %d  %s' % (e[0][11:], LVL.get(e[1], e[1]), e[2], e[3], e[4]))
        if c['last']: print('      последние записи журнала System: ' + '; '.join('%s %s/%d' % (e[0][11:], e[1].replace('Microsoft-Windows-', ''), e[2]) for e in c['last']))
print('\n---- details (last 8 of each)')
for (sev, prov, eid, txt), ev in items:
    print('\n[%s] %s / %d — %s — %d' % (sev, prov, eid, txt, len(ev)))
    if (prov, eid) == ('Application Error', 1000) or eid == 1000:   # top crashing programs
        c = collections.Counter(re.split(r'\s*\|\s*', d)[0] for _, d in ev)
        for k, n in c.most_common(8): print('   %4d × %s' % (n, k[:120]))
    for ts, d in sorted(ev)[-8:]: print('   %s  %s' % (ts, d))
