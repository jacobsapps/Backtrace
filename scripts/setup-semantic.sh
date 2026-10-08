#!/bin/bash
# Explicit, one-time model/runtime installation. Searching never uses the network.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$HOME/Library/Application Support/Backtrack"
PYTHON="${BACKTRACK_PYTHON:-/opt/homebrew/bin/python3.13}"
mkdir -p "$ROOT/models/minilm"
chmod 700 "$ROOT"
"$PYTHON" -m venv "$ROOT/semantic-runtime"
"$ROOT/semantic-runtime/bin/pip" install 'onnxruntime==1.23.2' 'tokenizers==0.22.1' 'numpy==2.3.4'
/usr/bin/python3 - "$ROOT/models/minilm" <<'PY'
import hashlib
from pathlib import Path
import sys
import urllib.request
root = Path(sys.argv[1])
revision = '1110a243fdf4706b3f48f1d95db1a4f5529b4d41'
hashes = {
    'onnx/model_qint8_arm64.onnx': '4278337fd0ff3c68bfb6291042cad8ab363e1d9fbc43dcb499fe91c871902474',
    'tokenizer.json': 'be50c3628f2bf5bb5e3a7f17b1f74611b2561a3a27eeab05e5aa30f411572037',
}
for name in ['onnx/model_qint8_arm64.onnx', 'tokenizer.json', 'README.md']:
    target = root / Path(name).name
    if not target.exists() or (name in hashes and hashlib.sha256(target.read_bytes()).hexdigest() != hashes[name]):
        temporary = target.with_suffix(target.suffix + '.download')
        urllib.request.urlretrieve(f'https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/{revision}/{name}', temporary)
        if name in hashes and hashlib.sha256(temporary.read_bytes()).hexdigest() != hashes[name]:
            raise RuntimeError("Model checksum mismatch: " + name)
        temporary.replace(target)
    print(target.name, hashlib.sha256(target.read_bytes()).hexdigest())
license_path = root / 'LICENSE'
if not license_path.exists():
    urllib.request.urlretrieve('https://www.apache.org/licenses/LICENSE-2.0.txt', license_path)
PY
