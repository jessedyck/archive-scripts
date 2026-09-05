# archive-create / archive-restore

Bash scripts for creating durable, long-term archives for cloud or HDD storage. Each archive is compressed, encrypted, split into upload-friendly chunks, and protected with parity and checksums — designed to survive partial data loss from bit rot, incomplete uploads, or degraded drives.

**Primary use case:** Files stored on a single HDD/SDD which may degrade over time. These scripts allow for compression and encryption so the files can be uploaded to a public cloud for redundancy.

## How it works

`archive-create.sh` takes a file or directory and produces an output folder containing:

- `<name>_00000`, `<name>_00001`, ... — encrypted 950 MB chunks
- `<name>.par2` — PAR2 parity files (15% recovery redundancy)
- `checksums.sha256` — SHA-256 checksums for all chunks and parity files
- `key.pub` — age public key fingerprint that was used to encrypt this archive
- `README.txt` — the configuration used to create this archive (source, exclusions, compression, etc.)
- `archive-restore.sh` — copy of the restore script

`archive-restore.sh` reverses the process: verifies checksums, reassembles chunks, decrypts, and decompresses.

The output folder is self-contained — `archive-restore.sh` and `key.pub` are bundled inside it at creation time. You do not need this repo to restore an archive years later.

Before doing any work, `archive-create.sh` prints a summary of the configuration (source, destination, key file, compression, exclusions) and asks for confirmation.

## Dependencies

**macOS:**
```
brew install zstd age par2 pv
```

**Linux (Debian/Ubuntu):**
```
apt install zstd age par2 pv
```

| Tool | Purpose |
|------|---------|
| zstd | Compression |
| age  | Encryption |
| par2 | Parity / recovery |
| pv   | Progress display |

## Usage

**Create an archive:**
```bash
./archive-create.sh <file-or-directory>
./archive-create.sh --key ~/.config/age/my.key <file-or-directory>
./archive-create.sh --exclude node_modules --exclude '.cache' <directory>
./archive-create.sh --include-sockets <directory>
./archive-create.sh -y <file-or-directory>   # skip the confirmation prompt
./archive-create.sh --exclude cache --resolve-exclusions <directory>  # show what each --exclude actually matches
```

**Restore an archive:**
```bash
./archive-restore.sh <archive-folder>
./archive-restore.sh --key ~/.config/age/my.key <archive-folder>
./archive-restore.sh --no-verify <archive-folder>
```

## ‼️ Encryption key

On first run, `archive-create.sh` generates `age.key` in the current directory if no key is provided via `--key`. **Back this file up immediately and separately from the archive.** Without it the archive cannot be decrypted.

## Design decisions

**Any error anywhere in the pipeline aborts the entire archive — single-file failures are never silently skipped** — `set -euo pipefail` plus a global `ERR` trap means one unreadable file, one bsdtar warning that happens to be fatal, one stalled network read, anything, kills the whole run and deletes the partial output. This is deliberate, confirmed explicitly rather than assumed: the alternative — skip the failing file, keep going — would produce an archive that looks complete (exits 0, checksums pass) but is silently missing content, discovered only if and when that specific file is needed during a restore, possibly years later. For a tool whose entire purpose is trustworthy long-term storage, a loud failure you have to re-run beats a quiet gap you find out about on restore day. The cost — a single bad file on a multi-hour run means starting over — is accepted, and mitigated by making failures diagnosable (see: tar stderr capture) rather than by tolerating them.

**950 MB chunks, not 1 GB** — many cloud storage services impose a 1 GB file size limit. 950 MB gives a safe margin below that threshold.

**Chunk filenames use sequence numbers only, not content hashes** — integrity is fully covered by `checksums.sha256`. Embedding a SHA-256 hash in every filename added complexity to both scripts with no practical benefit.

**PAR2 at 15% parity** — protects against partial loss from bit rot or incomplete transfers on HDD or cloud storage. PAR2 is not a substitute for a second copy: it cannot recover a fully deleted or overwritten archive.

**PAR2 volumes use `-l` (limit size), not the default variable/doubling scheme** — the default lets later volumes grow far larger than any single input file (tested: ~5x a chunk's size at high redundancy), risking the same 1 GB limit the 950 MB chunk size exists to avoid. `-l` caps each volume at roughly the largest protected file's size — already ≤950 MB — so no separate size constant needs to be kept in sync.

**Compression before encryption** — encrypted data is pseudorandom and does not compress. Compressing first with zstd yields significantly smaller output.

**age for encryption** — simple, modern, scriptable. No key infrastructure required beyond a single key file.

**zstd level 15 (default)** — good compression ratio with reasonable speed. Levels 20–22 (ultra) compress more but can be prohibitively slow for large files. The `--compression` flag lets you override if needed.

**`--exclude` passes patterns straight to `tar --exclude`, repeatable** — no custom matching logic, so exclude semantics follow whatever `tar` on the host already does. A pattern with no `/` (e.g. `--exclude node_modules`) matches that name at any depth, which covers the common "skip this cache dir wherever it appears" case on both GNU tar (Linux) and bsdtar (macOS). Only applies when the input is a directory; a warning is printed (not an error) if `--exclude` is passed for a single-file input, since it's harmless to ignore.

**tar's stderr is captured to a temp file during the directory-tar step, not left to print directly to the terminal** — `tar` and `pv` both write to the terminal unsynchronized while the tar stage runs (tar's occasional message, `pv`'s constantly-updating `\r` progress line), and when they race the two outputs visually clobber each other — real errors have shown up as unreadable garbage like `tar: (null)` with `pv`'s progress bar fused into the same line. Redirecting tar's stderr to a `mktemp` file and printing its contents as a clean block afterward (on both success and failure, via the `ERR` trap) means the actual message is always legible. Confirmed against a real permission-denied failure: without this, the terminal showed `tar: (null)` fused with pv's progress bar; with it, the full sequence — `Removing leading '/' from member names`, `Couldn't list extended attributes: Permission denied`, `(null)` — comes through cleanly. (`(null)` itself appears to be a bsdtar quirk that trails a real error rather than a distinct one.)

**The `pv` progress estimate for the tar/zstd stage also gets `--exclude` applied to `du`** — the progress bar's percentage is `bytes piped so far / du -sk "$INPUT"`, computed once up front. Without applying the same excludes, `du` counts the *entire* source tree while the tar stream only contains what's left after exclusion — for a source where most of the bulk is an excluded directory (e.g. `node_modules`), this made the bar crawl at a tiny fraction of complete for the whole run instead of tracking real progress. GNU du takes `--exclude=PATTERN` (repeatable); BSD du (macOS default) has no long-option equivalent and instead takes `-I mask` — detected at runtime via `du --version`, so the right flag is used on either platform without assuming from the OS. Patterns get the same trailing-slash strip (`${pattern%/}`) as `--resolve-exclusions`, since both BSD and GNU du fail to match a pattern like `node_modules/` for the same reason `find -path` does.

**Configuration summary + confirmation prompt before any work starts** — archiving a large directory can take a long time, and a wrong `--key`, wrong exclusion, or wrong source path is easy to typo. Printing the full resolved configuration and requiring an explicit `y` gives one last chance to catch mistakes before the pipeline starts writing output.

**Tool versions (`zstd`, `age`, `tar`, `par2`, `pv`, `shasum`) are captured in the configuration summary via `"$tool" --version`** — this archive is meant to be restorable years later, potentially with a different major version of any of these tools installed. zstd frame format, age's format, and PAR2's recovery format have all been stable across versions, but if a future restore ever behaves differently than expected, knowing exactly which version created the archive narrows down whether it's a version-format mismatch. `--version` was checked to exit 0 and print to stdout on every tool this project depends on before relying on it here; `tool_version()` just takes the first line, since some tools (`pv`) print a multi-line license banner after it.

**Platform (`macOS`/`Linux`, plus the raw `uname -srm`) is recorded alongside tool versions** — `uname -s` is the standard way to distinguish the two on both platforms without any new dependency; `Darwin` is mapped to the friendlier `macOS` label, `Linux` passes through as-is, and anything else falls back to the raw `uname -s` value rather than erroring, since the rest of the script only assumes POSIX tools and could plausibly run elsewhere. The full `uname -srm` (kernel, release, architecture) is kept alongside the friendly label for the same reason tool versions are recorded — bsdtar vs. GNU tar behavior and `du`'s `-I` vs. `--exclude` are both platform-dependent, so knowing the exact platform an archive was created on is useful context if a restore years later behaves unexpectedly.

**Source/destination in the configuration summary are resolved to absolute paths via `cd ... && pwd`, not `realpath`** — `realpath` isn't guaranteed to be preinstalled on macOS, while `cd`/`pwd`/`dirname`/`basename` are always available. This keeps a relative input like `mydir` from being ambiguous in `README.txt` years later when the archive has moved.

**`README.txt` records the exact configuration used, not generic instructions** — an earlier version of this script wrote a static `README.txt` with restoration instructions, which was removed as redundant (it duplicated this file and `archive-restore.sh`). This `README.txt` is different: it's the resolved configuration for *this specific run* (source, exclusions, sockets skipped, compression, timestamps) — information that exists nowhere else once the archive is years old and the exact command used has been forgotten.

**`--resolve-exclusions` shows matched paths via `find`, not by test-running tar** — a naive way to preview what `--exclude` matches would be to actually run tar (even to `/dev/null`), but that reads every file's content a second time, doubling I/O on a large source tree for what's meant to be a quick sanity check. Instead, `find "$INPUT" -path "*/$pattern" -print -prune` replicates tar's own (default `--no-anchored`) matching — a pattern matches wherever its slash-separated components appear consecutively in the path, regardless of what precedes them — and `-prune` stops descending once a match is found, so a match on `node_modules` reports the directory once instead of every file inside it. This was cross-checked against real `tar --exclude` output (comparing full vs. excluded listings) for both bare and slash-containing patterns before shipping. Off by default since it adds a filesystem scan; only runs when both `--exclude` and `--resolve-exclusions` are given.

**`--resolve-exclusions` strips a trailing `/` before matching, but keeps it in the pattern shown and passed to tar** — a trailing slash (e.g. `node_modules/`, common when a pattern is copy-pasted from a `.gitignore`) is meaningful to `tar --exclude`, which still matches it correctly against directory entries. But `find`'s printed paths never end in `/` for anything below the search root, so matching `-path "*/$pattern"` literally against a slash-terminated pattern always produced `(no matches found)` even when the exclusion was working correctly. The fix only affects the internal `find` glob; the pattern is displayed and handed to `tar --exclude` unchanged.

**`README.txt` always states whether exclusion paths were resolved** — since resolving is opt-in and adds a filesystem scan, most runs won't have it on. Rather than silently omitting the matched-paths list, each `--exclude` entry in the configuration summary either lists its resolved matches (`--resolve-exclusions` was given) or explicitly notes `(not resolved — rerun with --resolve-exclusions to see matching paths)`. This avoids ambiguity years later between "this pattern matched nothing" and "matches were never checked."

**`README.txt` gets counts, not the full path lists, for `--resolve-exclusions` matches and excluded sockets** — those lists are real filesystem paths from inside the source tree, and `README.txt` sits in the output folder *unencrypted*, right next to the encrypted archive chunks. Writing the full list there would leak directory/file names — potentially revealing exactly what the archive contains — to anyone who can see the output folder, defeating part of the point of encrypting the archive in the first place. The terminal output at confirmation time still shows the full detail, since the person running the command already has full access to the source and needs to be able to verify the exclusions are correct before proceeding. `print_config()` takes a `redact` argument for this: the terminal call omits it (full detail, matching current behavior), the `README.txt` call passes `true` (paths replaced with counts and a pointer back to the terminal output). Resolving the exclusion matches was moved out of `print_config()` into a one-time precompute step (`EXCLUDE_MATCHES`, indexed in parallel with `EXCLUDES`) specifically so redaction doesn't require a second filesystem scan — `print_config()` is called twice (once per destination) but `find` only runs once per pattern.

**bsdtar's default sparse-file detection (`lseek(fd, 0, SEEK_HOLE)` per file) is left enabled** — this was disabled via `--no-read-sparse` for a period after a run failed with `lseek(SEEK_HOLE) failed: Operation timed out`, on the theory that the probe itself was hanging on a network mount or a degrading drive. It was reverted: disabling it forces every file to be read at full logical size instead of hole-compacted, and on a source with large sparse files (VM disk images, etc.) this was observed to multiply actual read/write volume several-fold over the real data size — plausibly making network-mount reliability *worse*, not better, by keeping the connection under heavy transfer for far longer. Whether the original `SEEK_HOLE` timeout was actually caused by the probe itself, versus some other transient condition on that specific run, was never conclusively confirmed. If it recurs, the tar-stderr capture (see below) will at least surface the real error clearly instead of it being garbled by `pv`'s progress line.

**Unix domain sockets are auto-detected and excluded by default** — no tar format (ustar/pax/gnu) can store a socket; it's a limitation of the tar format itself, not a specific implementation. Since inclusion is never possible, `archive-create.sh` runs `find <input> -type s` before archiving and folds every match into the tar exclude list, so the run is silent instead of spamming "pax format cannot archive sockets" once per socket — this is common with directories like `~/Library/Containers/*/Data` (Docker Desktop, etc.) that hold live IPC sockets. The scan is directory-input only and adds one extra tree walk; `--include-sockets` skips it and falls back to tar's native (noisy but harmless) skip-and-warn behavior.

**The socket scan prunes anything already covered by `--exclude`** — the socket scan and `--exclude` are independent features, but a directory matched by `--exclude` (e.g. `Library/Containers/com.docker.docker`) is never handed to tar in the first place, so sockets inside it don't need tar's socket handling at all. Without pruning, the socket scan would still walk into and report those sockets, showing up in the configuration summary as "excluded (cannot be archived)" even though the real reason they're absent from the archive is the `--exclude` pattern — misleading, and wasted I/O on large excluded trees (e.g. `node_modules`). The scan builds the same `-path "*/pattern"` prune expression used by `--resolve-exclusions` and passes it to `find ... -prune -o -type s -print` so excluded subtrees are skipped entirely rather than just filtered from the results afterward.

## Verifying and repairing

```bash
cd <archive-folder>
shasum -a 256 -c checksums.sha256

# If files are corrupt, repair with PAR2 (up to 15% loss recoverable):
par2 repair <name>.par2
```
