import hashlib
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
import sys
sys.path.insert(0, str(Path(__file__).parents[2] / "Resources"))

spec = importlib.util.spec_from_file_location('indexer', Path(__file__).parents[2] / 'Resources/index_sessions.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
SID = '12345678-1234-1234-1234-123456789abc'
OTHER = '12345678-1234-1234-1234-123456789def'

class NativeFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.cache = self.home / 'cache'
        self.cwd = self.home / "folder with spaces and 'quotes'"
        self.cwd.mkdir()
        self.codex = self.home / '.codex'
        self.codex.mkdir()
        self.path = self.codex / 'sessions/2026/10/07' / ('rollout-test-' + SID + '.jsonl')
        self.write(self.path, dict(type='session_meta', payload=dict(id=SID, cwd=str(self.cwd), source='cli', timestamp='2026-10-07T10:00:00Z')))
        self.db = self.codex / 'state_5.sqlite'
        with sqlite3.connect(self.db) as c:
            c.execute('CREATE TABLE threads (id TEXT, rollout_path TEXT, source TEXT, cwd TEXT, name TEXT, title TEXT, updated_at INTEGER)')
            c.execute('INSERT INTO threads VALUES (?,?,?,?,?,?,?)', (SID, str(self.path), 'cli', '/wrong/index/cwd', 'Short native title', 'First prompt', 100))

    def write(self, path, *items):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(''.join(json.dumps(d) + '\n' for d in items))

    def run_index(self):
        return m.index(self.home, self.cache)['sessions']


class IndexTests(NativeFixture):
    def test_native_title_and_transcript_identity_win(self):
        s = self.run_index()[0]
        self.assertEqual(s['title'], 'Short native title')
        self.assertEqual(s['cwd'], str(self.cwd))
        self.assertEqual(m.validate(s), {'valid': True})

    def test_no_source_mutations(self):
        before = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in self.codex.rglob('*') if p.is_file()}
        self.run_index()
        self.assertEqual(before, {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in before})

    def test_phantom_ledger_is_not_a_session(self):
        (self.home / 'agent-sessions.md').write_text(f'- **2026-10-07** · **codex** · `/tmp` — Fake title job — resume: `cd /tmp && codex resume {OTHER}`\n')
        self.assertEqual(len(self.run_index()), 1)

    def test_mismatched_and_deleted_rollout_rejected(self):
        self.write(self.path, dict(type='session_meta', payload=dict(id=OTHER, cwd=str(self.cwd))))
        self.assertEqual(self.run_index(), [])
        self.path.unlink()
        self.assertEqual(self.run_index(), [])

    def test_subagents_excluded(self):
        with sqlite3.connect(self.db) as c:
            c.execute('UPDATE threads SET source=?', ('{"subagent":{}}',))
        self.assertEqual(self.run_index(), [])

    def test_missing_database_falls_back(self):
        self.db.unlink()
        self.write(self.codex / 'session_index.jsonl', dict(id=SID, thread_name='Fallback title'))
        s = self.run_index()[0]
        self.assertEqual(s['sessionID'], SID)
        self.assertEqual(s['title'], 'Fallback title')

    def test_history_and_partial_append(self):
        self.write(self.codex / 'history.jsonl', dict(session_id=SID, text='first history', ts=200), dict(session_id=SID, text='latest history', ts=300))
        with (self.codex / 'history.jsonl').open('a') as f:
            f.write('{incomplete')
        s = self.run_index()[0]
        self.assertEqual(s['latest'], 'latest history')
        self.assertIn('first history', s['searchText'])
        self.assertEqual(s['updated'], 300)

    def test_parked_title_requires_exact_id_and_cwd(self):
        folder = self.home / 'Library/Application Support/Car Park'
        folder.mkdir(parents=True)
        (folder / 'car.json').write_text(json.dumps(dict(created_at=500, tabs=[dict(provider='codex', session_id=SID, cwd='/incorrect', title='Wrong alias')])))
        self.assertEqual(self.run_index()[0]['title'], 'Short native title')
        (folder / 'car.json').write_text(json.dumps(dict(created_at=500, tabs=[dict(provider='codex', session_id=SID, cwd=str(self.cwd), title='Actual tab title')])))
        self.assertEqual(self.run_index()[0]['title'], 'Actual tab title')

    def test_deleted_folder_is_visible_but_cannot_launch(self):
        self.cwd.rmdir()
        s = self.run_index()[0]
        self.assertFalse(s['available'])
        with self.assertRaisesRegex(ValueError, 'folder no longer exists'):
            m.validate(s)

    def test_revalidation_prevents_stale_cache_launch(self):
        s = self.run_index()[0]
        self.path.unlink()
        with self.assertRaisesRegex(ValueError, 'missing or its identity changed'):
            m.validate(s)

    def test_claude_native_id_title_and_incremental_update(self):
        path = self.home / '.claude/projects/-not-a-reversible-path' / (OTHER + '.jsonl')
        self.write(path, dict(type='user', sessionId=OTHER, cwd=str(self.cwd), timestamp='2026-10-07T12:00:00Z', message=dict(content='A Claude prompt')), dict(type='ai-title', sessionId=OTHER, aiTitle='Native Claude title'))
        s = next(s for s in self.run_index() if s['provider'] == 'claude')
        self.assertEqual(s['title'], 'Native Claude title')
        self.assertEqual(s['cwd'], str(self.cwd))
        self.assertEqual(m.validate(s), {'valid': True})
        with path.open('a') as f:
            f.write(json.dumps(dict(type='custom-title', sessionId=OTHER, customTitle='Renamed title')) + '\n')
        s = next(s for s in self.run_index() if s['provider'] == 'claude')
        self.assertEqual(s['title'], 'Renamed title')
        path.unlink()
        self.assertEqual(len(self.run_index()), 1)

    def test_claude_cannot_be_inferred_from_filename(self):
        path = self.home / '.claude/projects/-tmp' / (OTHER + '.jsonl')
        self.write(path, dict(type='user', sessionId=SID, cwd='/tmp'))
        self.assertEqual(len(self.run_index()), 1)

    def test_cache_private_and_atomic(self):
        self.run_index()
        self.assertEqual((self.cache / 'sessions.json').stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads((self.cache / 'sessions.json').read_text())['version'], 1)

class TranscriptTests(NativeFixture):
    def db_search(self, query):
        with sqlite3.connect(self.cache / 'search.sqlite') as db:
            return db.execute('SELECT id FROM search WHERE search MATCH ?', (query,)).fetchall()

    def append_message(self, role, text):
        with self.path.open('a') as f:
            f.write(json.dumps(dict(type='response_item', payload=dict(type='message', role=role, content=[dict(type='output_text' if role == 'assistant' else 'input_text', text=text)]))) + '\n')

    def test_assistant_and_old_middle_user_messages_are_searchable(self):
        self.append_message('user', 'The secret project codename is papercatalogue.')
        self.append_message('assistant', 'We should call the Mac app Backtrack.')
        for i in range(35):
            self.append_message('user', f'Unrelated later prompt {i}')
        self.run_index()
        self.assertTrue(self.db_search('backtrack'))
        self.assertTrue(self.db_search('papercatalogue'))
        self.assertTrue(self.db_search('backtrack AND papercatalogue'))

    def test_tools_and_system_instructions_are_excluded(self):
        self.append_message('developer', 'excludeddeveloperterm')
        self.append_message('user', '# AGENTS.md instructions\nexcludedharnessterm')
        with self.path.open('a') as f:
            f.write(json.dumps(dict(type='response_item', payload=dict(type='function_call_output', output='excludedtoolterm'))) + '\n')
        self.run_index()
        for word in ['excludeddeveloperterm', 'excludedharnessterm', 'excludedtoolterm']:
            self.assertFalse(self.db_search(word))

    def test_incremental_append_partial_line_and_rewrite(self):
        self.append_message('assistant', 'olduniqueterm')
        self.run_index()
        partial = json.dumps(dict(type='response_item', payload=dict(type='message', role='user', content='newuniqueterm')))
        with self.path.open('a') as f:
            f.write(partial[:20])
        self.run_index()
        self.assertFalse(self.db_search('newuniqueterm'))
        with self.path.open('a') as f:
            f.write(partial[20:] + '\n')
        self.run_index()
        self.assertTrue(self.db_search('newuniqueterm'))
        self.assertTrue(self.db_search('olduniqueterm'))
        self.write(self.path, dict(type='session_meta', payload=dict(id=SID, cwd=str(self.cwd), source='cli')))
        self.run_index()
        self.assertFalse(self.db_search('olduniqueterm'))

    def test_unchanged_index_preserves_vectors_and_deleted_session_removed(self):
        self.append_message('assistant', 'backtrack')
        self.run_index()
        with sqlite3.connect(self.cache / 'search.sqlite') as db:
            db.execute("UPDATE passages SET embedding=x'0000',model='test'")
        self.run_index()
        with sqlite3.connect(self.cache / 'search.sqlite') as db:
            self.assertEqual(db.execute('SELECT count(embedding) FROM passages').fetchone()[0], 1)
        self.path.unlink()
        self.run_index()
        self.assertFalse(self.db_search('backtrack'))
        with sqlite3.connect(self.cache / 'search.sqlite') as db:
            self.assertEqual(db.execute('SELECT count(*) FROM passages').fetchone()[0], 0)

    def test_claude_assistant_text_blocks_and_sidechains(self):
        path = self.home / '.claude/projects/example' / (OTHER + '.jsonl')
        self.write(path,
            dict(type='user', sessionId=OTHER, cwd=str(self.cwd), message=dict(content=[dict(type='text', text='claudeuserterm')])),
            dict(type='assistant', sessionId=OTHER, message=dict(content=[dict(type='text', text='claudeassistantterm'), dict(type='tool_use', input='excludedtoolterm')])),
            dict(type='assistant', sessionId=OTHER, isSidechain=True, message=dict(content='excludedsidechainterm')))
        self.run_index()
        self.assertTrue(self.db_search('claudeassistantterm'))
        self.assertTrue(self.db_search('claudeuserterm'))
        self.assertFalse(self.db_search('excludedsidechainterm'))

    def test_fast_stats_and_change_journal_track_insert_update_delete(self):
        self.append_message('assistant', 'indexed message')
        self.run_index()
        model = 'minilm-l6-v2-qint8-arm64-1110a243-mean-256-v1'
        key = 'embedded:' + model + ':1536'
        with sqlite3.connect(self.cache / 'search.sqlite') as db:
            self.assertEqual(db.execute("SELECT value FROM search_stats WHERE key='passages'").fetchone()[0], 1)
            db.execute('UPDATE passages SET embedding=?,model=?', (bytes(1536),model))
            self.assertEqual(db.execute('SELECT value FROM search_stats WHERE key=?',(key,)).fetchone()[0],1)
            revision = db.execute('SELECT max(seq) FROM semantic_changes').fetchone()[0]
            db.execute('UPDATE passages SET embedding=?,model=?', (bytes(1536),model))
            self.assertEqual(db.execute('SELECT max(seq) FROM semantic_changes').fetchone()[0],revision)
            db.execute('DELETE FROM passages')
            self.assertEqual(db.execute("SELECT value FROM search_stats WHERE key='passages'").fetchone()[0],0)
            self.assertEqual(db.execute('SELECT value FROM search_stats WHERE key=?',(key,)).fetchone()[0],0)
            self.assertGreater(db.execute('SELECT max(seq) FROM semantic_changes').fetchone()[0],revision)

    def test_migration_backfills_stats_without_changing_embeddings(self):
        self.append_message('assistant', 'keep this embedding')
        self.run_index()
        with sqlite3.connect(self.cache / 'search.sqlite') as db:
            for trigger in ('passages_added','passages_removed','embeddings_changed'):
                db.execute('DROP TRIGGER ' + trigger)
            db.execute('DROP TABLE search_stats')
            db.execute('DROP TABLE semantic_changes')
            db.execute('PRAGMA user_version=0')
            db.execute("UPDATE passages SET embedding=x'1234',model='legacy'")
            db.commit()
            m.ensure_search_acceleration(db)
            self.assertEqual(db.execute('SELECT embedding FROM passages').fetchone()[0],bytes.fromhex('1234'))
            self.assertEqual(db.execute("SELECT value FROM search_stats WHERE key='embedded:legacy:2'").fetchone()[0],1)
            m.ensure_search_acceleration(db)
            self.assertEqual(db.execute("SELECT value FROM search_stats WHERE key='passages'").fetchone()[0],1)

class RefreshTests(NativeFixture):
    def test_unchanged_refresh_preserves_cache_files_and_skips_prompt_cleaning(self):
        from unittest.mock import patch
        self.write(self.codex / 'history.jsonl', dict(session_id=SID, text='uniqueprompt', ts=200))
        first = m.index(self.home, self.cache)
        self.assertTrue(first['changed'])
        before = (self.cache / 'sessions.json').stat().st_mtime_ns
        original = m.clean
        def no_history_normalization(value, *args):
            self.assertNotEqual(value, 'uniqueprompt')
            return original(value, *args)
        with patch.object(m, 'clean', side_effect=no_history_normalization):
            second = m.index(self.home, self.cache)
        self.assertFalse(second['changed'])
        self.assertEqual(before, (self.cache / 'sessions.json').stat().st_mtime_ns)
        self.assertEqual(first['sessions'], second['sessions'])

    def test_history_append_partial_completion_rewrite_rotation_and_removal(self):
        path = self.codex / 'history.jsonl'
        self.write(path, dict(session_id=SID, text='old prompt', ts=200))
        self.run_index()
        record = json.dumps(dict(session_id=SID, text='new prompt', ts=300)) + '\n'
        with path.open('a') as f: f.write(record[:20])
        self.assertEqual(self.run_index()[0]['latest'], 'old prompt')
        with path.open('a') as f: f.write(record[20:])
        self.assertEqual(self.run_index()[0]['latest'], 'new prompt')
        self.write(path, dict(session_id=SID, text='rewritten', ts=400))
        session = self.run_index()[0]
        self.assertEqual(session['latest'], 'rewritten')
        self.assertNotIn('old prompt', session['searchText'])
        rotated = path.with_suffix('.old')
        path.rename(rotated)
        self.write(path, dict(session_id=SID, text='rotated', ts=500))
        self.assertEqual(self.run_index()[0]['latest'], 'rotated')
        path.unlink()
        self.assertNotIn('rotated', self.run_index()[0]['searchText'])

    def test_history_preserves_prompts_before_session_discovery(self):
        self.write(self.codex / 'history.jsonl', dict(session_id=OTHER, text='late discovered', ts=500))
        self.run_index()
        other_path = self.path.with_name('rollout-test-' + OTHER + '.jsonl')
        self.write(other_path, dict(type='session_meta', payload=dict(id=OTHER, cwd=str(self.cwd), source='cli')))
        with sqlite3.connect(self.db) as db:
            db.execute('INSERT INTO threads VALUES(?,?,?,?,?,?,?)', (OTHER,str(other_path),'cli',str(self.cwd),'Late title','',100))
        session = next(s for s in self.run_index() if s['sessionID'] == OTHER)
        self.assertEqual(session['latest'], 'late discovered')

    def test_history_unchanged_prefix_with_rewrite_and_growth_rebuilds(self):
        path = self.codex / 'history.jsonl'
        self.write(path, dict(session_id=SID, text='original', ts=200))
        self.run_index()
        self.write(path, dict(session_id=SID, text='replacement message with substantially more characters', ts=300))
        self.assertNotIn('original', self.run_index()[0]['searchText'])

    def test_assistant_append_is_changed_without_metadata_change(self):
        m.index(self.home, self.cache)
        before = (self.cache / 'sessions.json').stat().st_mtime_ns
        with self.path.open('a') as f:
            f.write(json.dumps(dict(type='event_msg',payload=dict(type='agent_message',message='new assistant evidence'))) + '\n')
        self.assertTrue(m.index(self.home, self.cache)['changed'])
        self.assertEqual(before, (self.cache / 'sessions.json').stat().st_mtime_ns)

    def test_orphaned_transcript_helper_stops(self):
        from unittest.mock import patch
        with patch.object(m, 'PARENT_PID', 101), patch.object(m.os, 'getppid', return_value=102):
            with self.assertRaises(SystemExit):
                m.check_parent()
        with patch.object(m, 'PARENT_PID', 101), patch.object(m.os, 'getppid', return_value=101):
            m.check_parent()


if __name__ == '__main__':
    unittest.main()
