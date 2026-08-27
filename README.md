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

**950 MB chunks, not 1 GB** — many cloud storage services impose a 1 GB file size limit. 950 MB gives a safe margin below that threshold.

**Chunk filenames use sequence numbers only, not content hashes** — integrity is fully covered by `checksums.sha256`. Embedding a SHA-256 hash in every filename added complexity to both scripts with no practical benefit.

**PAR2 at 15% parity** — protects against partial loss from bit rot or incomplete transfers on HDD or cloud storage. PAR2 is not a substitute for a second copy: it cannot recover a fully deleted or overwritten archive.

**Compression before encryption** — encrypted data is pseudorandom and does not compress. Compressing first with zstd yields significantly smaller output.

**age for encryption** — simple, modern, scriptable. No key infrastructure required beyond a single key file.

**zstd level 15 (default)** — good compression ratio with reasonable speed. Levels 20–22 (ultra) compress more but can be prohibitively slow for large files. The `--compression` flag lets you override if needed.

**`--exclude` passes patterns straight to `tar --exclude`, repeatable** — no custom matching logic, so exclude semantics follow whatever `tar` on the host already does. A pattern with no `/` (e.g. `--exclude node_modules`) matches that name at any depth, which covers the common "skip this cache dir wherever it appears" case on both GNU tar (Linux) and bsdtar (macOS). Only applies when the input is a directory; a warning is printed (not an error) if `--exclude` is passed for a single-file input, since it's harmless to ignore.

**Configuration summary + confirmation prompt before any work starts** — archiving a large directory can take a long time, and a wrong `--key`, wrong exclusion, or wrong source path is easy to typo. Printing the full resolved configuration and requiring an explicit `y` gives one last chance to catch mistakes before the pipeline starts writing output.

**`README.txt` records the exact configuration used, not generic instructions** — an earlier version of this script wrote a static `README.txt` with restoration instructions, which was removed as redundant (it duplicated this file and `archive-restore.sh`). This `README.txt` is different: it's the resolved configuration for *this specific run* (source, exclusions, sockets skipped, compression, timestamps) — information that exists nowhere else once the archive is years old and the exact command used has been forgotten.

**Unix domain sockets are auto-detected and excluded by default** — no tar format (ustar/pax/gnu) can store a socket; it's a limitation of the tar format itself, not a specific implementation. Since inclusion is never possible, `archive-create.sh` runs `find <input> -type s` before archiving and folds every match into the tar exclude list, so the run is silent instead of spamming "pax format cannot archive sockets" once per socket — this is common with directories like `~/Library/Containers/*/Data` (Docker Desktop, etc.) that hold live IPC sockets. The scan is directory-input only and adds one extra tree walk; `--include-sockets` skips it and falls back to tar's native (noisy but harmless) skip-and-warn behavior.

## Verifying and repairing

```bash
cd <archive-folder>
shasum -a 256 -c checksums.sha256

# If files are corrupt, repair with PAR2 (up to 15% loss recoverable):
par2 repair <name>.par2
```
