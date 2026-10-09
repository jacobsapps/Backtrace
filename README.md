# Backtrack

A native, local Mac library for finding and reopening Codex and Claude Code
conversations. Full-text search includes saved user **and assistant messages**,
not just session titles. No transcript is sent to a service.

## Build and use

Requires macOS 14+, Swift/Xcode command-line tools, and `/usr/bin/python3`.
The `codex` and/or `claude` CLI must be installed to resume their sessions.

Compile and launch directly from a checkout, without installing:

```sh
git clone https://github.com/jacobsapps/Backtrack.git
cd Backtrack
bash scripts/build-app.sh
open dist/Backtrack.app
```

Or quit an existing Backtrack instance and install into `/Applications`:

```sh
bash scripts/build-app.sh --install
open /Applications/Backtrack.app
```

For meaning-based search, install the optional local model/runtime once:

```sh
# Apple Silicon; Homebrew Python 3.13, or set BACKTRACK_PYTHON explicitly.
bash scripts/setup-semantic.sh
```

Setup downloads pinned ONNX Runtime, Tokenizers, NumPy, and the ~23 MB ARM64
quantized `sentence-transformers/all-MiniLM-L6-v2` model. Search itself is offline.
The runtime/model lives in `~/Library/Application Support/Backtrack/`, not in
system Python. Missing dependencies show a status warning; full-text search
continues working. The model is English-focused, not an LLM or an answer engine.

Restart Backtrack or choose **Refresh sessions** after installing the model.
Do not run both the checkout app and installed app at the same time: they share
the cache and global keyboard shortcut.

In restricted build environments that prohibit SwiftPM's nested sandbox, use
`BACKTRACK_DISABLE_SPM_SANDBOX=1 bash scripts/build-app.sh` and
`swift test --disable-sandbox`. This does not grant extra host permissions;
installation still requires write access to `/Applications`.

- **Control–Option–Space** summons Backtrack; **⌘L** focuses search.
- **↑/↓** selects a conversation; **Return** or a click reopens it in a new tab.
- The main window stays compact: search, tab titles, folders, dates, and matching excerpts.
- Results show short highlighted excerpts. Meaning-only matches have a sparkle indicator
  (with an explicit tooltip) and do not fake keyword highlights; full match details are in ⋯.
- Provider filters, meaning search, ranking, refresh, and index status live in ⋯, not a toolbar.
- **⌘⇧C** copies the exact resume command; **⌘R** refreshes the library.
- Closing the window keeps the app and global shortcut running; **⌘Q** quits.

Reopening creates a **fresh tab in the frontmost iTerm window**, using a command
at tab creation, never typing into an existing tab. With no iTerm window it makes
one. If iTerm is not installed, the Terminal fallback makes a new window (Terminal
has no equivalent safe native tab-creation command). Automation permission may
be required. Backtrack never closes, retitles, or injects keystrokes into your
working sessions. It does not deduplicate against currently running agent sessions.

## Search and ranking

SQLite FTS5 indexes titles, paths, branches, IDs, prompt history, and all saved
user/assistant text. Tool output, hidden reasoning, system/developer instructions,
and known harness boilerplate are excluded. Every query token must match;
prefixes and an edit-distance fallback handle partial names and common typos.
Search syntax characters are treated as text, not raw SQL/FTS instructions.

The default **Recent & relevant** ranking combines text relevance with a 14-day
exponential decay and a 0.03 floor: otherwise equal new transcript matches can
rank roughly 33× above old ones. Old unique matches remain discoverable. **Best
match** removes the age penalty. Empty search is strictly newest first.

Semantic retrieval uses real, normalized 384-dimensional MiniLM embeddings of
overlapping conversation passages. Cosine similarity has a minimum threshold;
up to 12 meaning-only results for multiword queries supplement sparse lexical
results without replacing exact excerpts. Single names and IDs stay lexical to
avoid spurious semantic neighbours. Semantic suggestions are fallible. Embeddings
are built incrementally in the background, newest conversations first, with
progress in the options menu and durable eight-passage batches. They use the same
strong recency bias as full-text results.

Search is debounced by 35 ms, runs off the main thread, and rejects obsolete query
results. Lexical results render first, with excerpts prepared only for the first
page and then on demand as you scroll. If fewer than 20 lexical results match,
meaning search runs after another 140 ms of idle time and arrives separately. A
persistent local stdio worker caches recent query vectors. The in-memory passage
matrix updates from a change journal, rather than reloading all embeddings, and
index progress uses transactionally maintained counters instead of corpus scans.
There is no listening server or network request. Initial indexing never blocks
typing, and completed conversations are searchable during the backfill.

## Architecture

```text
Read-only Codex / Claude stores
          │
          ▼
Python adapters + incremental history/transcript indexing
          │
          ├── sessions.json: compact session metadata → SwiftUI Store
          └── search.sqlite: FTS5 text + passages + embedding blobs
                       │                         ▲
                 Swift keyword search     Python MiniLM / ONNX backfill
                       │                         │
                       └──── Swift semantic comparison (Accelerate)
                                           │
                                  async ranked results + excerpts
                                           │
                         revalidate native ID/cwd → fresh iTerm tab
```

There is no backend service, network search, or listening local server.
The subsystems have deliberately different responsibilities:

| Subsystem | Implementation | Checks |
| --- | --- | --- |
| Native discovery and identity | `Resources/index_sessions.py` | Real-format fixtures: native ID/cwd, title sources, deleted sessions, source immutability, pre-launch revalidation |
| Prompt-history cache | `Resources/history_cache.py` | Unchanged reads, append offsets, partial lines, rewrites, rotation, deletion, late session discovery |
| Transcript/embedding storage | SQLite FTS5 and private cache tables | Incremental append/rewrite, excluded tool/system text, counters, migration, stale embedding writes, journal pruning |
| Lexical retrieval | `Sources/BacktrackCore/LocalSearch.swift` | Transcript-only matches, typos, recency, provider filters, WAL reopen, lazy highlighted excerpts |
| Meaning retrieval | MiniLM helper + Swift `SemanticSearch` actor | Actual-model paraphrase test; replacements/deletions reflected in a warm vector cache |
| Worker protocol | `Sources/BacktrackCore/EmbeddingWorker.swift` | Real subprocesses simulating hangs, exit, malformed/oversized/chunked output, cancellation and fresh-worker recovery |
| UI orchestration | `Sources/Backtrack/Store.swift` | Temporary-cache integration tests: unchanged refreshes, overlapping refreshes, metadata reload, stale queries/snippets |
| Terminal handoff | `TerminalScript.swift` + Store launch | Shell/AppleScript escaping, exact native identity, fresh-tab script shape; live Automation behaviour needs a Mac smoke test |

These tests establish specific behaviours, not a blanket guarantee. Search
quality for every paraphrase is not proven; neither are future changes to native
agent storage formats. UI layout and live iTerm/Terminal Automation are not
covered by the unit suite. The app is still a personal prototype.

### What "semantic" means here

This is **a pretrained model, not custom-trained ML**. Backtrack does not train
on conversations. It performs inference locally using a pinned, ARM64-int8
ONNX export of `sentence-transformers/all-MiniLM-L6-v2`, with ONNX Runtime's
CPU execution provider (two inference threads), Hugging Face Tokenizers, and NumPy.
It does **not** use Core ML, Apple Intelligence, or Apple's Natural Language
sentence embeddings. SwiftUI/AppKit provide the app UI; Apple's **Accelerate**
framework handles the vector-comparison math.

1. Saved user/assistant text is split into roughly 1,100-character passages,
   overlapping by 200 characters. The tokenizer limits each passage to 256 tokens.
2. MiniLM produces token vectors. Masked mean pooling and normalization produce
   one **384-number float vector** per passage, persisted in SQLite.
3. A query goes through the same model. Accelerate computes dot products against
   the normalized cached vectors—equivalent to cosine similarity.
4. Matches below 0.42 similarity are excluded; surviving passages are grouped by
   session, strongly weighted for recency, and merged with lexical results.
   A meaning match never fabricates literal keyword highlighting.

The model download is about 23 MB, but that is **not total RAM use**: the runtime,
query worker, and float-vector matrix also take memory. At roughly 115,000
passages, the vectors alone occupy about 169 MiB. Warm model/vector caches are
intentionally retained for fast subsequent queries. Disabling meaning search
stops new queries and cancels backfill, but retains those caches for re-enabling.
Deleted vectors are removed from the live matrix; the change journal retains a
bounded tail, and readers that fall behind reload from the authoritative cache.

### Refresh and background work

- On launch, show cached sessions, then refresh.
- On activation, refresh if the last successful refresh was over **20 seconds** ago.
- While the app is active, refresh every **60 seconds**; **⌘R** refreshes manually.
- Native prompt histories and transcripts are incremental. New complete records
  are consumed; unchanged history is not reparsed/normalized. Rewrites/rotation
  rebuild the affected cached history. A successful unchanged refresh advances
  freshness without rewriting metadata or re-running the active search.
- Existing embeddings are reused. Pending work is selected newest-first in
  256-passage pages, encoded/committed eight at a time. The helper exits when done;
  it can continue while the window is hidden. A file lock prevents duplicate
  backfills, and parent-exit/cancellation checks stop abandoned work.
- Progress is polled every two seconds **during indexing**, using small counters,
  not full-vector scans. The query worker waits on stdin between searches.
- The query worker has a five-second deadline and cancellation checks. On failure,
  it is discarded; keyword results remain usable and a later query can restart it.

An initial full transcript scan/embedding backfill is much heavier than a normal
refresh. A cold semantic query loads the model and vector matrix; warm timings do
not include that cost. Query/result work runs off the UI thread.

## Data and correctness

Native session stores are authoritative; `~/agent-sessions.md` only enriches them.
Codex SQLite is opened read-only. Every session's exact native ID and original cwd
are checked against its saved transcript. Top-level Claude sessions are checked
against native `sessionId` and cwd; subagent/sidechain jobs are excluded. Native
names and exact-ID Free Parking aliases are preserved. Native files are never
modified. Claude title metadata still uses bounded head/tail reads; conversation
search does not have that limit.

Transcript indexing uses file identity, size, mtime, and byte offsets. Unchanged
files are skipped; live appends only read new complete records. Rewrites are
rebuilt, and deleted sessions are removed from the search cache. Original folders
and transcript identities are revalidated before launching. Missing folders are
shown but cannot be reopened.

The private cache contains conversation text and embeddings. SQLite/JSON files
are mode 0600 in `~/Library/Application Support/Backtrack/` (directory 0700).
Close Backtrack before deleting `sessions.json`, `search.sqlite*`, and
`claude-metadata.json` to rebuild the indexes; leave `semantic-runtime` and
`models` intact to avoid reinstalling. Default `~/.codex` and `~/.claude` stores
are supported, not custom agent homes.

## Verification

```sh
swift test
/usr/bin/python3 -m unittest discover -s Tests/Python -v
# Real cache timings and matching excerpts; output is private local data:
dist/Backtrack.app/Contents/MacOS/Backtrack --benchmark
# Fictional offscreen UI, no terminal/focus changes:
dist/Backtrack.app/Contents/MacOS/Backtrack --snapshot "$PWD/.local/library.png" --search-preview
# Actual Backtrack search and original development session, still offscreen:
dist/Backtrack.app/Contents/MacOS/Backtrack --snapshot "$PWD/.local/live.png" --live-data
```

Evidence is kept locally in ignored `.local/`. Tests cover native identity,
source immutability, transcript-only matches, incremental appends/rewrites,
deleted conversations, quoted input, highlighted snippets, provider filters,
recency, metadata-only fallback, quiescent WAL caches, lazy excerpts, terminal
scripting, semantic paraphrases, and embedding replacement/deletion.
The semantic integration test requires the optional installed model.

This is an ad-hoc-signed personal prototype, not a notarized distribution.
