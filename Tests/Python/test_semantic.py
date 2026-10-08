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
