# Backtrack

A native, local Mac library for finding and reopening Codex and Claude Code
conversations. Full-text search includes saved user **and assistant messages**,
not just session titles. No transcript is sent to a service.

## Build and use

Requires macOS 14+, Swift/Xcode command-line tools, and `/usr/bin/python3`.

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
