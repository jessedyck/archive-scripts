# archive-create / archive-restore

Bash scripts for creating durable, long-term archives for cloud or HDD storage. Each archive is compressed, encrypted, split into upload-friendly chunks, and protected with parity and checksums — designed to survive partial data loss from bit rot, incomplete uploads, or degraded drives.

**Primary use case:** Files stored on a single HDD/SDD which may degrade over time. These scripts allow for compression and encryption so the files can be uploaded to a public cloud for redundancy.

## How it works

`archive-create.sh` takes a file or directory and produces an output folder containing:

- `<name>_00000`, `<name>_00001`, ... — encrypted 950 MB chunks
- `<name>.par2` — PAR2 parity files (15% recovery redundancy)
- `checksums.sha256` — SHA-256 checksums for all chunks and parity files
- `key.pub` — age public key fingerprint that was used to encrypt this archive
- `archive-restore.sh` — copy of the restore script

`archive-restore.sh` reverses the process: verifies checksums, reassembles chunks, decrypts, and decompresses.

The output folder is self-contained — `archive-restore.sh` and `key.pub` are bundled inside it at creation time. You do not need this repo to restore an archive years later.

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

## Verifying and repairing

```bash
cd <archive-folder>
shasum -a 256 -c checksums.sha256

# If files are corrupt, repair with PAR2 (up to 15% loss recoverable):
par2 repair <name>.par2
```
