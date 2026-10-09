"""Incremental, private cache of native prompt histories; never writes native files."""
import hashlib
import json
import os
import re

UUID = re.compile(r'^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$')


def boundary(file, size):
    """Detect replacement/truncate-and-regrow without rereading the complete log."""
    file.seek(0)
    head = file.read(min(4096, size))
    file.seek(max(0, size - 4096))
    return hashlib.sha256(head + file.read(min(4096, size))).hexdigest()


def read_histories(home, db, clean, stamp):
    db.executescript('''
        CREATE TABLE IF NOT EXISTS history_files (
            provider TEXT PRIMARY KEY, device INTEGER, inode INTEGER, size INTEGER,
            mtime INTEGER, offset INTEGER, boundary TEXT);
        CREATE TABLE IF NOT EXISTS history_prompts (
            provider TEXT, sid TEXT, first TEXT, latest TEXT, updated REAL, prompts TEXT,
            PRIMARY KEY(provider,sid));
    ''')
    for provider in ('codex', 'claude'):
        path = home / ('.' + provider) / 'history.jsonl'
        try:
            file = path.open('rb')
        except FileNotFoundError:
            with db:
                db.execute('DELETE FROM history_prompts WHERE provider=?', (provider,))
                db.execute('DELETE FROM history_files WHERE provider=?', (provider,))
            continue
        with file, db:
            stat = os.fstat(file.fileno())
            fingerprint = (stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns)
            old = db.execute('SELECT device,inode,size,mtime,offset,boundary FROM history_files WHERE provider=?', (provider,)).fetchone()
            if old and old[:4] == fingerprint:
                continue
            append = old and old[:2] == fingerprint[:2] and stat.st_size > old[2] and boundary(file, old[2]) == old[5]
            if not append:
                db.execute('DELETE FROM history_prompts WHERE provider=?', (provider,))
            file.seek(old[4] if append else 0)
            touched = {}
            while file.tell() < stat.st_size:
                start = file.tell()
                raw = file.readline(stat.st_size - start)
                if not raw.endswith(b'\n'):
                    file.seek(start)
                    break  # Keep the partial line for the next append.
                try:
                    item = json.loads(raw)
                except (ValueError, UnicodeError):
                    continue
                if not isinstance(item, dict):
                    continue
                sid = item.get('session_id') or item.get('sessionId')
                if not isinstance(sid, str) or not UUID.fullmatch(sid):
                    continue
                text = clean(item.get('text') if provider == 'codex' else item.get('display'))
                if not text:
                    continue
                ts = stamp(item.get('ts') if provider == 'codex' else item.get('timestamp'))
                if sid not in touched:
                    row = db.execute('SELECT first,latest,updated,prompts FROM history_prompts WHERE provider=? AND sid=?', (provider, sid)).fetchone()
                    touched[sid] = dict(first=row[0], latest=row[1], updated=row[2], prompts=json.loads(row[3])) if row else dict(first=text, latest=text, updated=0, prompts=[])
                h = touched[sid]
                if ts >= h['updated']:
                    h.update(latest=text, updated=ts)
                h['prompts'].append(text)
                h['prompts'] = h['prompts'][-24:]
            offset = file.tell()
            db.executemany('INSERT OR REPLACE INTO history_prompts VALUES(?,?,?,?,?,?)',
                           [(provider, sid, h['first'], h['latest'], h['updated'], json.dumps(h['prompts'], ensure_ascii=False)) for sid, h in touched.items()])
            db.execute('INSERT OR REPLACE INTO history_files VALUES(?,?,?,?,?,?,?)',
                       (provider,) + fingerprint + (offset, boundary(file, stat.st_size)))
    return {provider + ':' + sid: dict(first=first, latest=latest, updated=updated, prompts=json.loads(prompts))
            for provider, sid, first, latest, updated, prompts in db.execute('SELECT * FROM history_prompts')}
