#!/usr/bin/env python3
"""Offline MiniLM embeddings. Stdio worker (no listening socket or API calls)."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import sqlite3
import sys
import time
from index_sessions import ensure_search_acceleration

MODEL = 'minilm-l6-v2-qint8-arm64-1110a243-mean-256-v1'
ROOT = Path.home() / 'Library/Application Support/Backtrack'

class Encoder:
    def __init__(self, threads=2):
        import numpy as np
        import onnxruntime as ort
        from tokenizers import Tokenizer
        self.np = np
        folder = ROOT / 'models/minilm'
        self.tokenizer = Tokenizer.from_file(str(folder / 'tokenizer.json'))
        self.tokenizer.enable_truncation(max_length=256)
        self.tokenizer.enable_padding(pad_id=0, pad_token='[PAD]')
        options = ort.SessionOptions()
        options.intra_op_num_threads = threads
        options.inter_op_num_threads = 1
        options.log_severity_level = 3
        self.session = ort.InferenceSession(str(folder / 'model_qint8_arm64.onnx'), sess_options=options, providers=['CPUExecutionProvider'])

    def encode(self, texts):
        np = self.np
        encoded = self.tokenizer.encode_batch(texts)
        inputs = {
            'input_ids': np.array([e.ids for e in encoded], dtype=np.int64),
            'attention_mask': np.array([e.attention_mask for e in encoded], dtype=np.int64),
            'token_type_ids': np.array([e.type_ids for e in encoded], dtype=np.int64),
        }
        output = self.session.run(None, inputs)[0]
        mask = inputs['attention_mask'][..., None]
        vectors = (output * mask).sum(axis=1) / np.maximum(mask.sum(axis=1), 1)
        return (vectors / np.maximum(np.linalg.norm(vectors, axis=1, keepdims=True), 1e-9)).astype(np.float32)


def save_embeddings(db, rows, vectors):
    # Index refresh can replace/reuse a row ID while encoding runs outside SQLite.
    # Never attach a vector to a different passage that now occupies that ID.
    db.executemany('UPDATE passages SET embedding=?,model=? WHERE id=? AND text=?',
                   [(v.tobytes(), MODEL, r[0], r[1]) for r, v in zip(rows, vectors)])
    db.commit()


def index(path):
    os.nice(10)  # Yield CPU priority to interactive work and other apps.
    # Only one semantic backfill, across app/diagnostics processes.
    with (path.parent / '.semantic.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with sqlite3.connect(path, timeout=30) as db:
            ensure_search_acceleration(db)
            encoder = None
            count = 0
            start = time.monotonic()
            while os.getppid() != 1:
                rows = db.execute(f"SELECT p.id,p.text FROM passages p INDEXED BY pending_embeddings JOIN session_recency s ON s.id=p.session_id WHERE p.embedding IS NULL OR p.model IS NULL OR p.model!='{MODEL}' ORDER BY s.updated DESC,p.id LIMIT 8").fetchall()
                if not rows:
                    break
                if encoder is None:
                    encoder = Encoder(threads=2)
                vectors = encoder.encode([r[1] for r in rows])
                save_embeddings(db, rows, vectors)
                count += len(rows)
            print(json.dumps(dict(embedded=count, seconds=time.monotonic()-start)))


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--index', type=Path)
    p.add_argument('--serve', action='store_true')
    args = p.parse_args()
    if args.index:
        index(args.index)
    elif args.serve:
        encoder = Encoder()
        for line in sys.stdin:
            request = json.loads(line)
            print(json.dumps(encoder.encode([request['query']])[0].tolist(), separators=(',', ':')), flush=True)

if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        print(str(e), file=sys.stderr)
        sys.exit(1)
