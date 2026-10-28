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
from index_sessions import ensure_search_acceleration, prune_semantic_changes

MODEL = 'minilm-l6-v2-qint8-arm64-1110a243-mean-256-v1'
PENDING = f"embedding IS NULL OR model IS NULL OR model!='{MODEL}' OR length(embedding)!=1536"
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
        encoded = self.tokenizer.encode_batch(texts)
        return self.encode_tokens(encoded)

    def encode_tokens(self, encoded):
        np = self.np
        width = max(len(e.ids) for e in encoded)
        def pad(values):
            return values + [0] * (width - len(values))
        inputs = {
            'input_ids': np.array([pad(e.ids) for e in encoded], dtype=np.int64),
            'attention_mask': np.array([pad(e.attention_mask) for e in encoded], dtype=np.int64),
            'token_type_ids': np.array([pad(e.type_ids) for e in encoded], dtype=np.int64),
        }
        output = self.session.run(None, inputs)[0]
        mask = inputs['attention_mask'][..., None]
        vectors = (output * mask).sum(axis=1) / np.maximum(mask.sum(axis=1), 1)
        return (vectors / np.maximum(np.linalg.norm(vectors, axis=1, keepdims=True), 1e-9)).astype(np.float32)

    def encode_query(self, text):
        # A descriptive search may exceed MiniLM's 256-token window. Include
        # every overflow window instead of silently discarding the query's end.
        encoded = self.tokenizer.encode(text)
        windows = [encoded] + encoded.overflowing
        if len(windows) == 1:
            return self.encode_tokens(windows)[0]
        total = self.np.zeros(384, dtype=self.np.float32)
        for offset in range(0, len(windows), 8):
            batch = windows[offset:offset + 8]
            vectors = self.encode_tokens(batch)
            for window, vector in zip(batch, vectors):
                total += vector * max(1, sum(window.attention_mask) - 2)
        return total / max(float(self.np.linalg.norm(total)), 1e-9)


def save_embeddings(db, rows, vectors):
    # Index refresh can replace/reuse a row ID while encoding runs outside SQLite.
    # Never attach a vector to a different passage that now occupies that ID.
    cursor = db.executemany(f'UPDATE passages SET embedding=?,model=? WHERE id=? AND text=? AND ({PENDING})',
                   [(v.tobytes(), MODEL, r[0], r[1]) for r, v in zip(rows, vectors)])
    db.commit()
    return cursor.rowcount


def pending_page(db, limit=256):
    return db.execute(f"SELECT p.id,p.text FROM passages p INDEXED BY pending_embeddings JOIN session_recency s ON s.id=p.session_id WHERE {PENDING} ORDER BY s.updated DESC,p.id LIMIT ?", (limit,)).fetchall()


def index(path):
    try:
        os.nice(10)  # Best effort: sandboxed hosts may prohibit priority changes.
    except PermissionError:
        pass
    parent = os.getppid()
    if parent == 1:
        return
    # Only one semantic backfill, across app/diagnostics processes.
    with (path.parent / '.semantic.lock').open('w') as lock:
        while os.getppid() == parent:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                time.sleep(0.1)
        else:
            return
        with sqlite3.connect(path, timeout=30) as db:
            ensure_search_acceleration(db)
            encoder = None
            count = 0
            start = time.monotonic()
            while os.getppid() == parent:
                # Sort/select once per work page, but retain small inference
                # batches and durable commits to keep memory and cancellation bounded.
                rows = pending_page(db)
                if not rows:
                    break
                if encoder is None:
                    encoder = Encoder(threads=2)
                for offset in range(0, len(rows), 8):
                    if os.getppid() != parent:
                        break
                    batch = rows[offset:offset + 8]
                    vectors = encoder.encode([r[1] for r in batch])
                    count += save_embeddings(db, batch, vectors)
                prune_semantic_changes(db)
                db.commit()
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
            print(json.dumps(encoder.encode_query(request['query']).tolist(), separators=(',', ':')), flush=True)

if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        print(str(e), file=sys.stderr)
        sys.exit(1)
