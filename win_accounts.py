#!/usr/bin/env python3
"""win_accounts.py <Windows-dir> [days] — read-only check of local accounts and logins on a Windows disk mounted in rescue.
Answers «кто и когда менял пароль», «не взломан ли сервер»:
  • SAM (реестр, без сторонних модулей): для каждой учётной записи — когда создана, когда последний раз менялся пароль,
    последний вход, последний неверный пароль, счётчик неудачных попыток, отключена ли;
  • журнал Security (если есть модуль python-evtx): кто менял/сбрасывал пароль (4723/4724) и с какого IP он вошёл,
    новые учётные записи (4720), добавление в администраторы (4732), очистка журнала (1102),
    удачные удалённые входы (4624) и перебор паролей (4625) по IP;
  • журнал RDP (TerminalServices-LocalSessionManager): входы по RDP с адресами.
Prints '!! ' lines for problems (их собирает diag_windows_rescue.sh), then details. Ничего не меняет."""
import os, re, sys, struct, datetime, collections, time

EPOCH = datetime.datetime(1601, 1, 1)


def filetime(q):
    if not q or q >= 0x7FFFFFFFFFFFFFFF: return None
    try: return EPOCH + datetime.timedelta(microseconds=q // 10)
    except OverflowError: return None


class Hive:
    """Минимальное чтение файла реестра (regf): ключи, значения, время изменения ключа. Только чтение."""
    def __init__(self, path):
        with open(path, 'rb') as f: self.d = f.read()
        if self.d[:4] != b'regf': raise ValueError('not a registry hive')
        self.root = self._nk(struct.unpack_from('<I', self.d, 0x24)[0])

    def _cell(self, off): return 4096 + off + 4

    def _nk(self, off):
        o = self._cell(off); d = self.d
        if d[o:o + 2] != b'nk': return None
        flags = struct.unpack_from('<H', d, o + 2)[0]
        nl = struct.unpack_from('<H', d, o + 0x48)[0]; raw = d[o + 0x4C:o + 0x4C + nl]
        return {'name': raw.decode('latin1') if flags & 0x20 else raw.decode('utf-16le', 'replace'),
                'ts': filetime(struct.unpack_from('<Q', d, o + 4)[0]),
                'nsub': struct.unpack_from('<I', d, o + 0x14)[0], 'subl': struct.unpack_from('<I', d, o + 0x1C)[0],
                'nval': struct.unpack_from('<I', d, o + 0x24)[0], 'vall': struct.unpack_from('<I', d, o + 0x28)[0]}

    def _list(self, off, depth=0):
        o = self._cell(off); d = self.d; sig = d[o:o + 2]; n = struct.unpack_from('<H', d, o + 2)[0]
        if sig in (b'lf', b'lh'): return [struct.unpack_from('<I', d, o + 4 + i * 8)[0] for i in range(n)]
        if sig == b'li': return [struct.unpack_from('<I', d, o + 4 + i * 4)[0] for i in range(n)]
        if sig == b'ri' and depth < 3:
            out = []
            for i in range(n): out += self._list(struct.unpack_from('<I', d, o + 4 + i * 4)[0], depth + 1)
            return out
        return []

    def subkeys(self, k):
        if not k or not k['nsub'] or k['subl'] in (0, 0xFFFFFFFF): return []
        return [x for x in (self._nk(off) for off in self._list(k['subl'])) if x]

    def key(self, path):
        k = self.root
        for part in [p for p in path.split('\\') if p]:
            k = next((s for s in self.subkeys(k) if s['name'].lower() == part.lower()), None)
            if not k: return None
        return k

    def values(self, k):
        """{имя: (тип, данные)}; имя '' — значение по умолчанию"""
        out = {}
        if not k or not k['nval'] or k['vall'] in (0, 0xFFFFFFFF): return out
        d = self.d; lo = self._cell(k['vall'])
        for i in range(k['nval']):
            vo = self._cell(struct.unpack_from('<I', d, lo + i * 4)[0])
            if d[vo:vo + 2] != b'vk': continue
            nl, size, doff, typ, flags = struct.unpack_from('<HIIIH', d, vo + 2)
            raw = d[vo + 20:vo + 20 + nl]; name = raw.decode('latin1') if flags & 1 else raw.decode('utf-16le', 'replace')
            if size & 0x80000000: data = struct.pack('<I', doff)[:size & 0x7FFFFFFF]
            elif size > 16344: data = b''      # большие данные (db) здесь не нужны
            else: data = d[self._cell(doff):self._cell(doff) + size]
            out[name] = (typ, data)
        return out


def sys_info(win):
    """Часовой пояс сервера и время последнего штатного выключения из куста SYSTEM."""
    h = Hive(os.path.join(win, 'System32', 'config', 'SYSTEM'))
    sel = h.values(h.key('Select')).get('Current'); cs = 'ControlSet%03d' % (struct.unpack('<I', sel[1][:4])[0] if sel else 1)
    tz = h.values(h.key(cs + '\\Control\\TimeZoneInformation'))
    bias = struct.unpack('<i', tz['ActiveTimeBias'][1][:4])[0] if 'ActiveTimeBias' in tz else None
    name = tz.get('TimeZoneKeyName', (0, b''))[1].decode('utf-16le', 'replace').split('\0')[0] if 'TimeZoneKeyName' in tz else ''
    sd = h.values(h.key(cs + '\\Control\\Windows')).get('ShutdownTime')
    shut = filetime(struct.unpack('<Q', sd[1][:8])[0]) if sd and len(sd[1]) >= 8 else None
    rtu = h.values(h.key(cs + '\\Control\\TimeZoneInformation')).get('RealTimeIsUniversal')
    return {'bias': bias, 'tz': name, 'shutdown': shut, 'rtu': bool(rtu and rtu[1][:1] not in (b'\0', b''))}


def sam_users(win):
    h = Hive(os.path.join(win, 'System32', 'config', 'SAM'))
    users = h.key('SAM\\Domains\\Account\\Users')
    if not users: return []
    names = {}
    for nk in h.subkeys(h.key('SAM\\Domains\\Account\\Users\\Names')):
        v = h.values(nk).get('')
        if v: names[v[0]] = (nk['name'], nk['ts'])      # тип значения по умолчанию = RID; время ключа ≈ создание учётки
    out = []
    for k in h.subkeys(users):
        if not re.fullmatch(r'[0-9A-Fa-f]{8}', k['name']): continue
        F = h.values(k).get('F', (0, b''))[1]
        if len(F) < 0x44: continue
        rid = int(k['name'], 16); acb = struct.unpack_from('<H', F, 0x38)[0]
        nm, created = names.get(rid, ('RID %d' % rid, None))
        out.append({'rid': rid, 'name': nm, 'created': created, 'changed': k['ts'],
                    'last_logon': filetime(struct.unpack_from('<Q', F, 0x08)[0]), 'pwd_set': filetime(struct.unpack_from('<Q', F, 0x18)[0]),
                    'last_bad': filetime(struct.unpack_from('<Q', F, 0x28)[0]), 'disabled': bool(acb & 0x0001), 'no_pwd': bool(acb & 0x0004),
                    'bad_count': struct.unpack_from('<H', F, 0x40)[0], 'logons': struct.unpack_from('<H', F, 0x42)[0]})
    return sorted(out, key=lambda u: u['rid'])


def lockout_policy(win):
    """Политика блокировки учёток из SAM (Domains\\Account, значение F): порог неверных паролей и длительность блокировки в минутах."""
    try:
        h = Hive(os.path.join(win, 'System32', 'config', 'SAM')); F = h.values(h.key('SAM\\Domains\\Account')).get('F', (0, b''))[1]
        if len(F) < 0x56: return None
        dur = -struct.unpack_from('<q', F, 0x30)[0] / 600000000.0; thr = struct.unpack_from('<H', F, 0x54)[0]
        if not (0 <= thr <= 999) or not (0 <= dur <= 60 * 24 * 365): return None
        return {'threshold': thr, 'minutes': int(round(dur))}
    except Exception: return None


fmt = lambda t: t.strftime('%Y-%m-%d %H:%M') if t else '—'
LOCAL_IP = re.compile(r'^(-|::1|127\.|0\.0\.0\.0|fe80:|$)')


def scan_security(path, since, limit_s=240):
    """События журнала Security, нужные для учёток и входов. Ограничение по времени — журнал бывает большим."""
    from Evtx.Evtx import Evtx
    want = {4624, 4625, 4720, 4722, 4723, 4724, 4725, 4726, 4732, 4738, 4740, 1102, 4781}
    rx_id = re.compile(r'<EventID[^>]*>(\d+)</EventID>'); rx_d = re.compile(r'<Data Name="([^"]+)">([^<]*)</Data>')
    ev = collections.defaultdict(list); st = {'n': 0, 'first': None, 'last': None, 'cut': False}; t0 = time.time()
    with Evtx(path) as log:
        for rec in log.records():
            try: ts = rec.timestamp().replace(tzinfo=None)
            except Exception: continue
            st['n'] += 1
            if ts.year < 1990: continue      # битые записи с нулевым временем
            if not st['first'] or ts < st['first']: st['first'] = ts
            if not st['last'] or ts > st['last']: st['last'] = ts
            if ts < since: continue
            if time.time() - t0 > limit_s: st['cut'] = True; break
            try: x = rec.xml()
            except Exception: continue
            m = rx_id.search(x)
            if not m or int(m.group(1)) not in want: continue
            d = dict(rx_d.findall(x))
            if '<UserData>' in x: d.update(re.findall(r'<(\w+)>([^<]*)</\1>', x.split('<UserData>', 1)[1]))   # 1102 и др. пишут поля в UserData
            ev[int(m.group(1))].append((ts, d))
    return ev, st


def scan_rdp(path, since):
    from Evtx.Evtx import Evtx
    out = []
    rx_id = re.compile(r'<EventID[^>]*>(\d+)</EventID>')
    with Evtx(path) as log:
        for rec in log.records():
            try:
                ts = rec.timestamp().replace(tzinfo=None)
                if ts < since: continue
                x = rec.xml()
            except Exception: continue
            m = rx_id.search(x)
            if m and m.group(1) in ('21', '25'):
                u = re.search(r'<User>([^<]*)</User>', x); a = re.search(r'<Address>([^<]*)</Address>', x)
                out.append((ts, u.group(1) if u else '?', a.group(1) if a else '?', 'вход' if m.group(1) == '21' else 'переподключение'))
    return out


def main():
    win = sys.argv[1]; days = int(sys.argv[2]) if len(sys.argv) > 2 else 30
    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None); since = now - datetime.timedelta(days=days)
    ago = lambda t: ('%d дн. назад' % (now - t).days) if (now - t).days >= 1 else 'сегодня, %d ч назад' % max(0, (now - t).seconds // 3600)
    det = []
    try: users = sam_users(win)
    except Exception as e: users = []; print('!! 🟡 не удалось прочитать учётные записи из SAM: %s' % e)
    active = [u for u in users if not u['disabled']]
    for u in users:
        det.append('   %-22s RID %-5d %s создана %s · пароль изменён %s · последний вход %s · последний неверный пароль %s · неудачных подряд %d · входов %d%s' % (
            u['name'][:22], u['rid'], 'ОТКЛЮЧЕНА ' if u['disabled'] else '', fmt(u['created']), fmt(u['pwd_set']), fmt(u['last_logon']), fmt(u['last_bad']), u['bad_count'], u['logons'], ' · флаг «пароль не обязателен» (PASSWD_NOTREQD)' if u['no_pwd'] else ''))
    # Security: кто менял пароли, входы, перебор
    ev, st = {}, None
    sec = os.path.join(win, 'System32', 'winevt', 'Logs', 'Security.evtx')
    if os.path.exists(sec):
        try: ev, st = scan_security(sec, since)
        except ImportError: print('!! ℹ️ журнал Security не разобран (нет модуля python-evtx) — кто менял пароль, не видно; даты смены пароля — из SAM')
        except Exception as e: print('!! 🟡 журнал Security не прочитан: %s' % e)
    logons = {}      # LogonId → (IP, тип входа, время): откуда вошёл тот, кто потом менял пароль
    for ts, d in ev.get(4624, []): logons[d.get('TargetLogonId', '').lower()] = (d.get('IpAddress', '-'), d.get('LogonType', '?'), ts)
    pw = [(ts, eid, d) for eid in (4723, 4724) for ts, d in ev.get(eid, [])]
    for u in active:
        if not u['pwd_set']: continue
        mine = sorted((x for x in pw if x[2].get('TargetUserName', '').lower() == u['name'].lower()), key=lambda x: x[0])
        recent = u['pwd_set'] >= since
        how = ''
        near = [x for x in mine if abs((x[0] - u['pwd_set']).total_seconds()) < 600]
        if near:
            ts, eid, d = near[-1]; who = d.get('SubjectUserName', '?'); ip = logons.get(d.get('SubjectLogonId', '').lower(), ('', '', None))[0]
            how = (' — сменил сам пользователь' if eid == 4723 else ' — сброшен пользователем %s' % who) + (' (вошёл с IP %s)' % ip if ip and not LOCAL_IP.match(ip) else ' (локально/с консоли)' if ip else '')
        elif recent and st and st['first'] and st['first'] <= u['pwd_set']:
            how = ' — в журнале Security записи о смене нет: пароль меняли не из Windows (из rescue/панели/переустановкой) или аудит учёток выключен'
        if recent and u['created'] and abs((u['pwd_set'] - u['created']).total_seconds()) < 600 and not near:
            print('!! ℹ️ пароль пользователя %s задан при создании учётки %s UTC (%s) и с тех пор не менялся' % (u['name'], fmt(u['pwd_set']), ago(u['pwd_set'])))
        elif recent:
            print('!! 🟡 пароль пользователя %s менялся %s UTC (%s)%s' % (u['name'], fmt(u['pwd_set']), ago(u['pwd_set']), how))
        elif u['name'].lower() in ('administrator', 'администратор', 'root') or u['logons']:
            print('!! ℹ️ пароль пользователя %s не менялся с %s UTC%s' % (u['name'], fmt(u['pwd_set']), how))
        if len(mine) > 1: det.append('   смены пароля %s: %s' % (u['name'], ', '.join('%s %s' % (fmt(t), 'сам' if e == 4723 else 'сброс от ' + d.get('SubjectUserName', '?')) for t, e, d in mine[-8:])))
    # новые учётки и права администратора
    sys_acc = {'administrator', 'guest', 'defaultaccount', 'wdagutilityaccount', 'администратор', 'гость'}
    # учётки, созданные вместе с системой/при выдаче сервера (root, Administrator) — норма; подозрительны созданные ПОЗЖЕ
    base = [u['created'] for u in users if u['created'] and u['name'].lower() in ('root', 'administrator', 'администратор')] or [min((u['created'] for u in users if u['created']), default=None)]
    base = max(b for b in base if b) if any(base) else None
    late = lambda t: t and t >= since and (not base or t > base + datetime.timedelta(hours=1))
    new = [u for u in users if late(u['created']) and u['name'].lower() not in sys_acc]
    if new:
        print('!! 🔴 за %d дн. создана новая учётная запись: %s — если клиент её не создавал, сервер, вероятно, взломан' % (days, ', '.join('%s (%s UTC%s)' % (u['name'], fmt(u['created']), ', отключена' if u['disabled'] else '') for u in new)))
    for ts, d in ev.get(4720, []):
        if late(ts) and not d.get('TargetUserName', '').endswith('$') and not any(u['name'].lower() == d.get('TargetUserName', '').lower() for u in new):
            print('!! 🔴 в журнале Security: создана учётная запись %s %s UTC пользователем %s' % (d.get('TargetUserName', '?'), fmt(ts), d.get('SubjectUserName', '?')))
    for ts, d in ev.get(4732, []):
        if re.search(r'admin|администратор', d.get('TargetUserName', ''), re.I):
            print('!! 🔴 в группу администраторов добавлена учётка (SID %s) %s UTC пользователем %s' % (d.get('MemberSid', '?'), fmt(ts), d.get('SubjectUserName', '?')))
    for ts, d in ev.get(1102, []):
        print('!! 🔴 журнал Security очищен %s UTC пользователем %s — следы входа могли стереть' % (fmt(ts), d.get('SubjectUserName', '?')))
    pol = lockout_policy(win)
    if pol: det.append('   политика блокировки: порог %s, длительность %s' % ('%d неверных паролей' % pol['threshold'] if pol['threshold'] else 'нет (блокировка выключена)', '%d мин' % pol['minutes'] if pol['minutes'] else 'до снятия администратором'))
    if ev.get(4740):
        who = collections.Counter(d.get('TargetUserName', '?') for _, d in ev[4740]); lastlock = max(t for t, _ in ev[4740])
        print('!! 🟡 учётка блокировалась из-за неверных паролей: %d раз (последний %s UTC) — %s. Пользователь при входе видит «учётная запись заблокирована»: блокировка временная%s, но пока идут неверные попытки, она повторяется — сначала уберите их источник (закройте RDP по IP), потом вход заработает сам' % (
            len(ev[4740]), fmt(lastlock), ', '.join('%s — %d' % kv for kv in who.most_common(3)), (' (снимается через %d мин)' % pol['minutes']) if pol and pol['minutes'] else ''))
    # входы: удачные удалённые и перебор
    ok = [(ts, d.get('TargetUserName', '?'), d.get('IpAddress', '-'), d.get('LogonType', '?')) for ts, d in ev.get(4624, [])
          if d.get('LogonType') in ('3', '10') and not LOCAL_IP.match(d.get('IpAddress', '-')) and not d.get('TargetUserName', '').endswith('$') and d.get('TargetUserName', '').upper() != 'ANONYMOUS LOGON']
    bad = collections.Counter(d.get('IpAddress', '-') if not LOCAL_IP.match(d.get('IpAddress', '-')) else 'без IP/локально' for _, d in ev.get(4625, []))
    nbad = sum(bad.values())
    if nbad:
        top = ', '.join('%s — %d' % kv for kv in bad.most_common(5))
        print('!! %s неудачных входов (неверный логин/пароль) за %d дн.: %d с %d IP — %s%s' % ('🟡' if nbad >= 100 else 'ℹ️', days, nbad, len(bad), top, ' — идёт перебор паролей; закройте RDP по IP или смените порт' if nbad >= 100 else ''))
    if nbad >= 20:
        # кто и как ошибается паролем: словарь имён с сети = перебор; служба/задание на самом сервере со старым паролем = блокировка после смены пароля
        LT = {'2': 'с консоли', '3': 'по сети (RDP с NLA, SMB)', '4': 'задание планировщика', '5': 'служба', '7': 'разблокировка экрана', '8': 'по сети (открытый пароль)', '10': 'RDP', '11': 'сохранённые данные'}
        names = collections.Counter(d.get('TargetUserName', '?') or '?' for _, d in ev[4625]); types = collections.Counter(d.get('LogonType', '?') for _, d in ev[4625])
        known = {u['name'].lower() for u in users}
        hitk = sum(n for nm, n in names.items() if nm.lower() in known)
        print('!! ℹ️ неверные пароли — под какими именами: %s%s; как входили: %s' % (', '.join('%s — %d' % kv for kv in names.most_common(5)), ' (всего разных имён: %d)' % len(names) if len(names) > 5 else '',
            ', '.join('%s — %d' % (LT.get(k, 'тип ' + k), n) for k, n in types.most_common(4))))
        loc = [(d.get('TargetUserName', '?'), d.get('LogonType'), (d.get('ProcessName') or d.get('LogonProcessName') or '?').strip()) for _, d in ev[4625] if d.get('LogonType') in ('4', '5')]
        if len(loc) >= 5:
            c = collections.Counter(loc).most_common(1)[0]
            print('!! 🟡 неверный пароль подставляет сам сервер: %s под учёткой %s (%s) — %d раз. Так бывает после смены пароля: в службе или задании остался старый пароль, и учётка блокируется снова и снова — обновите пароль в этой службе/задании' % (LT.get(c[0][1]), c[0][0], c[0][2], len(loc)))
        elif len(names) <= 2 and hitk >= nbad * 0.9 and len(bad) <= 3:
            print('!! ℹ️ почти все неверные попытки — под существующей учёткой (%s) и без словаря имён: это либо целевой перебор именно этой учётки, либо программа/устройство с сохранённым старым паролем (RDP-клиент, сетевой диск, скрипт) — уточните у клиента' % names.most_common(1)[0][0])
    if ok:
        by = collections.defaultdict(list)
        for ts, u, ip, lt in ok: by[(u, ip)].append(ts)
        hit = [(u, ip, max(t)) for (u, ip), t in by.items() if bad.get(ip, 0) >= 20]
        for u, ip, t in hit: print('!! 🔴 успешный вход после перебора паролей: с IP %s (%d неудачных попыток) вошли как %s %s UTC — вероятный взлом' % (ip, bad[ip], u, fmt(t)))
        rows = sorted(((max(t), u, ip, len(t)) for (u, ip), t in by.items()), reverse=True)
        print('!! ℹ️ удачные удалённые входы за %d дн.: %d с %d IP — %s' % (days, len(ok), len({ip for _, _, ip, _ in ok}), '; '.join('%s с %s (%d раз, последний %s)' % (u, ip, n, fmt(t)) for t, u, ip, n in rows[:5])))
        det.append('   удалённые входы (пользователь, IP, раз, последний UTC):'); det += ['     %s  %s  %d  %s' % (u, ip, n, fmt(t)) for t, u, ip, n in rows[:20]]
    if st:
        det.append('   Security.evtx: записей %d, события с %s по %s UTC%s' % (st['n'], fmt(st['first']), fmt(st['last']), ' · разбор остановлен по времени, проверена часть' if st['cut'] else ''))
        if st['first'] and st['first'] > since + datetime.timedelta(days=1):
            print('!! ℹ️ журнал Security хранит события только с %s UTC — более ранние входы и смены пароля не видны' % fmt(st['first']))
    rdp = os.path.join(win, 'System32', 'winevt', 'Logs', 'Microsoft-Windows-TerminalServices-LocalSessionManager%4Operational.evtx')
    if os.path.exists(rdp):
        try:
            r = scan_rdp(rdp, since)
            if r:
                c = collections.Counter(a for _, _, a, _ in r if not LOCAL_IP.match(a) and a != 'LOCAL')
                det.append('   RDP-сессии (последние): ' + '; '.join('%s %s с %s (%s)' % (fmt(t), u, a, k) for t, u, a, k in sorted(r)[-10:]))
                if c: print('!! ℹ️ входы по RDP за %d дн.: %d, адреса — %s' % (days, len(r), ', '.join('%s — %d' % kv for kv in c.most_common(5))))
        except Exception: pass
    print('\n---- local accounts (SAM)')
    for l in det: print(l)


if __name__ == '__main__':
    main()
