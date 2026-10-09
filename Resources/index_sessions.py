#!/usr/bin/env python3
"""Read-only adapters for native agent stores. No network, hooks, or CLI invocation."""
import argparse
import contextlib
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import re
import sqlite3
import sys
import tempfile
import time
import uuid
from history_cache import read_histories

VERSION = 1
PARENT_PID = None  # Set only by the subprocess entry point, not library/tests.
UUID = re.compile(r'^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$')


def check_parent():
    if PARENT_PID is not None and (PARENT_PID == 1 or os.getppid() != PARENT_PID):
        raise SystemExit(0)


def clean(s, limit=1600):
    return re.sub(r'\s+', ' ', s if isinstance(s, str) else '').strip()[:limit]


def stamp(value):
    try:
        if isinstance(value, (float, int)):
            return value / 1000 if value > 1e11 else value
        return dt.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
    except (ValueError, TypeError, AttributeError):
        return 0


def lines(path):
    try:
        with path.open('rb') as f:
            for raw in f:
                try:
                    d = json.loads(raw)
                    if isinstance(d, dict):
                        yield d
                except (ValueError, UnicodeError):
                    pass  # A live append may have an incomplete final line.
    except OSError:
        return


def read_json(path, default):
    try:
        return json.loads(path.read_bytes())
    except (OSError, ValueError):
        return default


def codex_meta(path, sid):
    try:
        with Path(path).open('rb') as f:
            item = json.loads(f.readline(2 * 1024 * 1024))
        p = item.get('payload', {})
        if item.get('type') == 'session_meta' and p.get('id') == sid and isinstance(p.get('cwd'), str) and p['cwd'].startswith('/'):
            return p
    except (OSError, ValueError, AttributeError):
        pass
    return None


def human_source(source):
    return not isinstance(source, dict) and 'subagent' not in str(source).lower() and source != 'exec'


def claude_metadata(path, sid):
    """Bounded head/tail read; history supplies prompts outside these windows."""
    result = {}
    try:
        with path.open('rb') as f:
            size = os.fstat(f.fileno()).st_size
            head = f.read(512 * 1024)
            chunks = [head if size <= len(head) else head.rsplit(b'\n', 1)[0]]
            if size > len(head):
                f.seek(max(len(head), size - 512 * 1024))
                # At a nonzero offset, discard the partial first line.
                chunks.append(f.read().split(b'\n', 1)[-1])
        for raw in b'\n'.join(chunks).splitlines():
            try:
                d = json.loads(raw)
            except (ValueError, UnicodeError):
                continue
            if d.get('sessionId') != sid or d.get('isSidechain'):
                continue
            cwd = d.get('cwd')
            if isinstance(cwd, str) and cwd.startswith('/'):
                result['cwd'] = cwd
                result['branch'] = clean(d.get('gitBranch'))
                result['verified'] = True
            if d.get('type') in ('custom-title', 'ai-title'):
                key = 'customTitle' if d['type'] == 'custom-title' else 'aiTitle'
                result[key] = clean(d.get(key), 180)
            if d.get('type') == 'user':
                content = d.get('message', {}).get('content')
                if isinstance(content, str) and not d.get('isMeta') and not content.startswith('<'):
                    text = clean(content)
                    result.setdefault('first', text)
                    result['latest'] = text
                    result['updated'] = max(result.get('updated', 0), stamp(d.get('timestamp')))
        return result
    except OSError:
        return {}


def record(sid, provider, cwd, transcript):
    return dict(id=provider + ':' + sid, sessionID=sid, provider=provider, cwd=cwd,
                transcript=str(transcript), title='', titleSource='', branch='', first='', latest='',
                searchText='', updated=0.0, available=True)


def index(home, cache):
    started = time.monotonic()
    codex = home / '.codex'
    claude = home / '.claude'
    warnings = []
    records = {}
    names = {d.get('id'): clean(d.get('thread_name'), 180) for d in lines(codex / 'session_index.jsonl')}
    databases = sorted(codex.glob('state_*.sqlite'), key=lambda p: int(p.stem.split('_')[-1]) if p.stem.split('_')[-1].isdigit() else -1, reverse=True)
    db_ok = False
    if databases:
        try:
            with contextlib.closing(sqlite3.connect(databases[0].resolve().as_uri() + '?mode=ro', uri=True, timeout=1)) as db:
                db.row_factory = sqlite3.Row
                for row in db.execute('SELECT * FROM threads'):
                    r = dict(row)
                    sid = r.get('id', '')
                    if not UUID.fullmatch(sid) or not human_source(r.get('source')):
                        continue
                    meta = codex_meta(r.get('rollout_path', ''), sid)
                    if not meta or not human_source(meta.get('source')):
                        continue
                    s = record(sid, 'codex', meta['cwd'], r['rollout_path'])
                    s.update(title=clean(r.get('name'), 180) or names.get(sid) or clean(r.get('title'), 180),
                             titleSource='Native session title' if r.get('name') or names.get(sid) else 'First prompt',
                             first=clean(r.get('first_user_message') or r.get('title')),
                             branch=clean(r.get('git_branch') or meta.get('git', {}).get('branch')),
                             updated=float(r.get('recency_at') or r.get('updated_at') or 0))
                    records[s['id']] = s
                db_ok = True
        except (sqlite3.Error, OSError) as e:
            warnings.append('Codex database unavailable; using saved transcripts: ' + str(e))
    # The database is preferred. Scan metadata only if it is missing/unreadable.
    if not db_ok:
        for folder in ('sessions', 'archived_sessions'):
            for path in (codex / folder).rglob('rollout-*.jsonl'):
                sid = path.stem[-36:]
                meta = codex_meta(path, sid)
                if not UUID.fullmatch(sid) or not meta or not human_source(meta.get('source')):
                    continue
                s = record(sid, 'codex', meta['cwd'], path)
                s.update(title=names.get(sid, ''), titleSource='Native session title',
                         branch=clean(meta.get('git', {}).get('branch')), updated=stamp(meta.get('timestamp')))
                records[s['id']] = s
    previous = read_json(cache / 'claude-metadata.json', {})
    next_cache = {}
    native = {}
    for path in (claude / 'projects').glob('*/sessions-index.json'):
        data = read_json(path, {})
        for entry in data.get('entries', []):
            if not entry.get('isSidechain'):
                native[entry.get('sessionId')] = entry
    for path in (claude / 'projects').glob('*/*.jsonl'):
        sid = path.stem
        if not UUID.fullmatch(sid):
            continue
        try:
            stat = path.stat()
        except OSError:
            continue
        fingerprint = [stat.st_mtime_ns, stat.st_size]
        old = previous.get(str(path), {})
        meta = old.get('meta', {}) if old.get('fingerprint') == fingerprint else claude_metadata(path, sid)
        next_cache[str(path)] = dict(fingerprint=fingerprint, meta=meta)
        if not meta.get('verified'):
            continue
        entry = native.get(sid, {})
        s = record(sid, 'claude', meta['cwd'], path)
        title = meta.get('customTitle') or meta.get('aiTitle') or clean(entry.get('summary'), 180)
        s.update(title=title, titleSource='Native session title' if title else 'First prompt',
                 branch=meta.get('branch') or clean(entry.get('gitBranch')),
                 first=meta.get('first') or clean(entry.get('firstPrompt')),
                 latest=meta.get('latest', ''), updated=meta.get('updated') or stamp(entry.get('modified')) or stat.st_mtime)
        records[s['id']] = s
    # Only new complete prompt-history records are parsed/normalized on refresh.
    with contextlib.closing(open_search_db(cache)) as history_db:
        prompt_history = read_histories(home, history_db, clean, stamp)
    for key, h in prompt_history.items():
        if key not in records:
            continue
        s = records[key]
        s['first'] = s['first'] or h['first']
        s['latest'] = h['latest']
        s['updated'] = max(s['updated'], h['updated'])
        s['searchText'] = '\n'.join(h['prompts'])[-16000:]
    # The ledger augments known durable sessions, never creates identities.
    for line in (home / 'agent-sessions.md').read_text(errors='replace').splitlines() if (home / 'agent-sessions.md').exists() else []:
        match = re.search(r'\*\*(codex|claude)\*\*.* — (.*?) — resume: `.*(?:resume |--resume )([\da-f-]{36})`', line)
        if match:
            provider, description, sid = match.groups()
            s = records.get(provider + ':' + sid)
            if s:
                first, _, latest = description.partition(' — latest: ')
                s['first'] = s['first'] or first
                s['latest'] = s['latest'] or latest
                s['searchText'] += '\n' + description
    # Exact-ID parked tab labels are useful aliases, never identity evidence.
    parked = {}
    for path in (home / 'Library/Application Support/Car Park').glob('*.json'):
        d = read_json(path, {})
        ts = stamp(d.get('created_at'))
        for tab in d.get('tabs', []):
            key = str(tab.get('provider')) + ':' + str(tab.get('session_id'))
            s = records.get(key)
            title = clean(tab.get('title'), 180)
            if s and s['cwd'] == tab.get('cwd') and title and not title.startswith('Default'):
                if ts >= parked.get(key, (0, ''))[0]:
                    parked[key] = (ts, title)
    for key, s in records.items():
        if key in parked:
            s['searchText'] += '\n' + s['title']
            s['title'] = parked[key][1]
            s['titleSource'] = 'Saved Free Parking tab title'
        s['title'] = s['title'] or clean(s['first'], 120) or 'Untitled session'
        s['latest'] = s['latest'] or s['first']
        s['available'] = Path(s['cwd']).is_dir()
    result = dict(version=VERSION, indexedAt=time.time(), duration=time.monotonic() - started,
                  warnings=warnings, sessions=sorted(records.values(), key=lambda s: s['updated'], reverse=True))
    if previous != next_cache:
        atomic_json(cache / 'claude-metadata.json', next_cache)
    old_index = read_json(cache / 'sessions.json', {})
    metadata_changed = (old_index.get('version') != VERSION or
                        old_index.get('sessions') != result['sessions'] or
                        old_index.get('warnings') != result['warnings'])
    # Publish metadata early during an initial/changed transcript backfill.
    if metadata_changed:
        atomic_json(cache / 'sessions.json', result)
    failed, transcript_changes = index_transcripts(result['sessions'], cache)
    if failed:
        result['warnings'].append(f'{failed} conversations could not be indexed; refresh to retry.')
        atomic_json(cache / 'sessions.json', result)
    result['duration'] = time.monotonic() - started
    result['changed'] = metadata_changed or transcript_changes > 0 or failed > 0
    return result



def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(value, f, ensure_ascii=False, separators=(',', ':'))
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def validate(session):
    sid = session['sessionID']
    if not UUID.fullmatch(sid):
        raise ValueError('Invalid session ID. Refresh the index.')
    if not Path(session['cwd']).is_dir():
        raise ValueError('The original folder no longer exists. Nothing was opened.')
    if session['provider'] == 'codex':
        meta = codex_meta(session['transcript'], sid)
        cwd = meta.get('cwd') if meta else None
    elif session['provider'] == 'claude':
        meta = claude_metadata(Path(session['transcript']), sid)
        cwd = meta.get('cwd') if meta.get('verified') else None
    else:
        raise ValueError('Unknown provider.')
    if cwd != session['cwd']:
        raise ValueError('The saved conversation is missing or its identity changed. Refresh the index. Nothing was opened.')
    return {'valid': True}


# Full-text and semantic source cache. Only this private cache is writable.
def conversation_message(d, s):
    if s['provider'] == 'codex':
        p = d.get('payload', {})
        if d.get('type') == 'response_item' and p.get('type') == 'message':
            role, content = p.get('role'), p.get('content')
            if p.get('channel') == 'analysis':
                return None
        elif d.get('type') == 'event_msg' and p.get('type') in ('user_message', 'agent_message'):
            role = 'user' if p['type'] == 'user_message' else 'assistant'
            content = p.get('message')
        else:
            return None
    else:
        if d.get('sessionId') != s['sessionID'] or d.get('isSidechain') or d.get('isMeta'):
            return None
        role = d.get('type')
        content = d.get('message', {}).get('content')
    if role not in ('user', 'assistant'):
        return None
    if isinstance(content, list):
        content = '\n'.join(b.get('text', '') for b in content if isinstance(b, dict) and b.get('type') in ('text', 'input_text', 'output_text'))
    if not isinstance(content, str) or not content.strip():
        return None
    # Harness instructions are not a conversation, and overwhelm relevance.
    if role == 'user' and content.lstrip().startswith(('# AGENTS.md', '<environment_context>', '<INSTRUCTIONS>', '<system-reminder>', '[Request interrupted')):
        return None
    return role, re.sub(r'\s+', ' ', content).strip()


def ensure_search_acceleration_v2(db):
    """One atomic cache-only migration; native agent stores are never touched."""
    if db.execute('PRAGMA user_version').fetchone()[0] >= 2:
        return
    db.executescript('''
        BEGIN IMMEDIATE;
        CREATE TABLE IF NOT EXISTS search_stats (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS semantic_changes (seq INTEGER PRIMARY KEY AUTOINCREMENT, passage_id INTEGER NOT NULL);
        INSERT OR REPLACE INTO search_stats SELECT 'passages', count(*) FROM passages;
        INSERT OR REPLACE INTO search_stats
            SELECT 'embedded:' || model || ':' || length(embedding), count(*) FROM passages
            WHERE model IS NOT NULL AND length(embedding)>0 GROUP BY model,length(embedding);
        CREATE TRIGGER IF NOT EXISTS passages_added AFTER INSERT ON passages BEGIN
            UPDATE search_stats SET value=value+1 WHERE key='passages';
            INSERT INTO search_stats SELECT 'embedded:' || NEW.model || ':' || length(NEW.embedding),1
                WHERE NEW.model IS NOT NULL AND length(NEW.embedding)>0
                ON CONFLICT(key) DO UPDATE SET value=value+1;
            INSERT INTO semantic_changes(passage_id) SELECT NEW.id WHERE NEW.embedding IS NOT NULL;
        END;
        CREATE TRIGGER IF NOT EXISTS passages_removed AFTER DELETE ON passages BEGIN
            UPDATE search_stats SET value=value-1 WHERE key='passages';
            UPDATE search_stats SET value=value-1
                WHERE key='embedded:' || OLD.model || ':' || length(OLD.embedding);
            INSERT INTO semantic_changes(passage_id) SELECT OLD.id WHERE OLD.embedding IS NOT NULL;
        END;
        CREATE TRIGGER IF NOT EXISTS embeddings_changed AFTER UPDATE OF embedding,model ON passages
            WHEN OLD.embedding IS NOT NEW.embedding OR OLD.model IS NOT NEW.model BEGIN
            UPDATE search_stats SET value=value-1
                WHERE key='embedded:' || OLD.model || ':' || length(OLD.embedding);
            INSERT INTO search_stats SELECT 'embedded:' || NEW.model || ':' || length(NEW.embedding),1
                WHERE NEW.model IS NOT NULL AND length(NEW.embedding)>0
                ON CONFLICT(key) DO UPDATE SET value=value+1;
            INSERT INTO semantic_changes(passage_id) VALUES(NEW.id);
        END;
        CREATE INDEX IF NOT EXISTS pending_embeddings ON passages(session_id,id) WHERE embedding IS NULL OR model IS NULL OR model!='minilm-l6-v2-qint8-arm64-1110a243-mean-256-v1';
        PRAGMA user_version=2;
        COMMIT;
    ''')



def ensure_search_acceleration(db):
    ensure_search_acceleration_v2(db)
    if db.execute('PRAGMA user_version').fetchone()[0] >= 3:
        return
    # Also repair invalid-length vectors, rather than repeatedly launching an
    # indexer whose queue incorrectly considers those passages complete.
    db.executescript("""
        BEGIN IMMEDIATE;
        DROP INDEX IF EXISTS pending_embeddings;
        CREATE INDEX pending_embeddings ON passages(session_id,id)
            WHERE embedding IS NULL OR model IS NULL
                OR model!='minilm-l6-v2-qint8-arm64-1110a243-mean-256-v1'
                OR length(embedding)!=1536;
        PRAGMA user_version=3;
        COMMIT;
    """)


def open_search_db(cache):
    path = cache / 'search.sqlite'
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    os.close(fd)
    db = sqlite3.connect(path, timeout=30)
    db.execute('PRAGMA journal_mode=WAL')
    db.executescript('''
        CREATE TABLE IF NOT EXISTS files (id TEXT PRIMARY KEY, path TEXT, inode INTEGER, size INTEGER, mtime INTEGER, offset INTEGER);
        CREATE TABLE IF NOT EXISTS session_recency (id TEXT PRIMARY KEY, updated REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS newest_sessions ON session_recency(updated DESC);
        CREATE TABLE IF NOT EXISTS passages (id INTEGER PRIMARY KEY, session_id TEXT NOT NULL, role TEXT NOT NULL, text TEXT NOT NULL, digest TEXT NOT NULL, embedding BLOB, model TEXT, UNIQUE(session_id, role, digest));
        CREATE INDEX IF NOT EXISTS passages_session ON passages(session_id);
        CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(id UNINDEXED, title, location, context, user, assistant, tokenize='unicode61 remove_diacritics 2', prefix='2 3 4');
        CREATE VIRTUAL TABLE IF NOT EXISTS vocabulary USING fts5vocab(search, 'row');
    ''')
    ensure_search_acceleration(db)
    return db


def index_transcripts(sessions, cache):
    import hashlib
    with contextlib.closing(open_search_db(cache)) as db:
        changed = 0
        valid = {s['id'] for s in sessions}
        db.executemany('INSERT INTO session_recency(id,updated) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET updated=excluded.updated WHERE updated!=excluded.updated', [(s['id'], s['updated']) for s in sessions])
        # FTS UNINDEXED identity columns do not have a lookup index. Resolve rowids
        # once, rather than rescanning the entire corpus for every unchanged file.
        rowids = {sid: rowid for rowid, sid in db.execute('SELECT rowid,id FROM search')}
        for (sid,) in db.execute('SELECT id FROM files').fetchall():
            if sid not in valid:
                changed += 1
                db.execute('DELETE FROM search WHERE rowid=?', (rowids.get(sid, -1),))
                db.execute('DELETE FROM passages WHERE session_id=?', (sid,))
                db.execute('DELETE FROM files WHERE id=?', (sid,))
                db.execute('DELETE FROM session_recency WHERE id=?', (sid,))
        db.commit()
        failed = 0
        for s in sessions:  # newest first; results become available during backfill
            check_parent()
            try:
                path = Path(s['transcript'])
                stat = path.stat()
                old = db.execute('SELECT path,inode,size,mtime,offset FROM files WHERE id=?', (s['id'],)).fetchone()
                row = db.execute('SELECT rowid,title,location,context FROM search WHERE rowid=?', (rowids.get(s['id'], -1),)).fetchone()
                metadata = (s['title'], s['cwd'] + ' ' + s['branch'] + ' ' + s['sessionID'], '\n'.join([s['first'], s['latest'], s['searchText']]))
                unchanged = old and old[:4] == (str(path), stat.st_ino, stat.st_size, stat.st_mtime_ns)
                if unchanged and row and row[1:4] == metadata:
                    continue
                append = old and old[0] == str(path) and old[1] == stat.st_ino and stat.st_size > old[2]
                offset = old[4] if append else 0
                if not unchanged:
                    if not append:
                        db.execute('DELETE FROM passages WHERE session_id=?', (s['id'],))
                    # Stop at the captured EOF. Leave an incomplete last line for the next refresh.
                    with path.open('rb') as f:
                        f.seek(offset)
                        records_read = 0
                        while f.tell() < stat.st_size:
                            if records_read % 256 == 0:
                                check_parent()
                            records_read += 1
                            start = f.tell()
                            raw = f.readline()
                            if not raw.endswith(b'\n'):
                                f.seek(start)
                                break
                            try:
                                d = json.loads(raw)
                            except (ValueError, UnicodeError):
                                continue
                            if not isinstance(d, dict):
                                continue
                            message = conversation_message(d, s)
                            if not message:
                                continue
                            role, text = message
                            # Bounded embedding passages, not bounded transcript coverage.
                            # Overlap preserves phrases across chunk boundaries.
                            for i in range(0, len(text), 900):
                                chunk = text[i:i + 1100]
                                digest = hashlib.sha256(chunk.encode()).hexdigest()
                                db.execute('INSERT OR IGNORE INTO passages(session_id,role,text,digest) VALUES(?,?,?,?)', (s['id'], role, chunk, digest))
                        offset = f.tell()
                content = {'user': [], 'assistant': []}
                for role, text in db.execute('SELECT role,text FROM passages WHERE session_id=? ORDER BY id', (s['id'],)):
                    content[role].append(text)
                if row:
                    db.execute('DELETE FROM search WHERE rowid=?', (row[0],))
                db.execute('INSERT INTO search(id,title,location,context,user,assistant) VALUES(?,?,?,?,?,?)', (s['id'],) + metadata + ('\n'.join(content['user']), '\n'.join(content['assistant'])))
                db.execute('INSERT OR REPLACE INTO files VALUES(?,?,?,?,?,?)', (s['id'], str(path), stat.st_ino, stat.st_size, stat.st_mtime_ns, offset if not unchanged else old[4]))
                db.commit()
                changed += 1
            except OSError:
                db.rollback()
                failed += 1
        prune_semantic_changes(db)
        db.commit()
        return failed, changed


def prune_semantic_changes(db, retain=8192):
    # Swift reloads the matrix for gaps >4096, so a larger retained tail safely
    # bounds the journal without losing updates for any incremental reader.
    # Never reset the AUTOINCREMENT sequence or remove the newest revision.
    db.execute('DELETE FROM semantic_changes WHERE seq <= (SELECT coalesce(max(seq),0) FROM semantic_changes)-?', (retain,))


def main():
    global PARENT_PID
    PARENT_PID = os.getppid()
    check_parent()
    p = argparse.ArgumentParser()
    p.add_argument('--home', type=Path, default=Path.home())
    p.add_argument('--cache', type=Path)
    p.add_argument('--validate', action='store_true')
    args = p.parse_args()
    if args.validate:
        print(json.dumps(validate(json.load(sys.stdin))))
        return
    cache = args.cache or args.home / 'Library/Application Support/Backtrack'
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (cache / '.index.lock').open('w') as lock:
        while True:
            check_parent()
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                time.sleep(0.1)
        result = index(args.home, cache)
    print(json.dumps(dict(count=len(result['sessions']), seconds=result['duration'], warnings=result['warnings'], changed=result['changed'])))

if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        print(str(e), file=sys.stderr)
        sys.exit(1)
