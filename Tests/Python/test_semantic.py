import importlib.util
from pathlib import Path
import sqlite3
import sys
import unittest
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).parents[2] / 'Resources'))
import semantic_search as semantic


class SemanticWriteTests(unittest.TestCase):
    def test_replaced_passage_does_not_receive_stale_embedding(self):
        with sqlite3.connect(':memory:') as db:
            db.execute('CREATE TABLE passages(id INTEGER PRIMARY KEY,text TEXT,embedding BLOB,model TEXT)')
            db.executemany('INSERT INTO passages(id,text) VALUES(?,?)', [(1,'Original message'),(2,'Unchanged message')])
            batch = db.execute('SELECT id,text FROM passages ORDER BY id').fetchall()
            # A refresh reuses the row ID while the encoder processes this batch.
            db.execute("DELETE FROM passages WHERE id=1")
            db.execute("INSERT INTO passages(id,text) VALUES(1,'Replacement message')")
            vector = Mock()
            vector.tobytes.return_value = bytes(1536)
            semantic.save_embeddings(db, batch, [vector,vector])
            self.assertIsNone(db.execute('SELECT embedding FROM passages WHERE id=1').fetchone()[0])
            self.assertEqual(db.execute('SELECT length(embedding),model FROM passages WHERE id=2').fetchone(), (1536,semantic.MODEL))

    def test_pending_queue_includes_bad_vectors_and_excludes_completed_rows(self):
        from index_sessions import open_search_db
        import tempfile
        with tempfile.TemporaryDirectory() as folder:
            with open_search_db(Path(folder)) as db:
                db.executemany('INSERT INTO session_recency VALUES(?,?)', [('new',200),('old',100)])
                rows = [(1,'old',None,None), (2,'new',bytes(4),semantic.MODEL), (3,'new',bytes(1536),semantic.MODEL), (4,'new',bytes(1536),'old-model')]
                for id, sid, vector, model in rows:
                    db.execute('INSERT INTO passages(id,session_id,role,text,digest,embedding,model) VALUES(?,?,?,?,?,?,?)',(id,sid,'assistant',str(id),str(id),vector,model))
                self.assertEqual([row[0] for row in semantic.pending_page(db)], [2,4,1])
                self.assertEqual([row[0] for row in semantic.pending_page(db,limit=2)], [2,4])
                vector = Mock(); vector.tobytes.return_value = bytes(1536)
                self.assertEqual(semantic.save_embeddings(db, [(2,'2'),(4,'4'),(1,'1')], [vector]*3), 3)
                self.assertEqual(semantic.pending_page(db), [])
                self.assertEqual(semantic.save_embeddings(db, [(1,'1')], [vector]), 0)

    def test_journal_pruning_keeps_latest_revision_and_monotonic_sequence(self):
        from index_sessions import open_search_db, prune_semantic_changes
        import tempfile
        with tempfile.TemporaryDirectory() as folder:
            with open_search_db(Path(folder)) as db:
                db.executemany('INSERT INTO semantic_changes(passage_id) VALUES(?)', [(i,) for i in range(12)])
                revision = db.execute('SELECT max(seq) FROM semantic_changes').fetchone()[0]
                prune_semantic_changes(db, retain=4)
                self.assertEqual(db.execute('SELECT count(*),max(seq) FROM semantic_changes').fetchone(),(4,revision))
                db.execute('INSERT INTO semantic_changes(passage_id) VALUES(100)')
                self.assertGreater(db.execute('SELECT max(seq) FROM semantic_changes').fetchone()[0],revision)
