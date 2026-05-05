# Agent Instructions

## Project overview

Two bash scripts for creating and restoring durable long-term archives. The pipeline is: tar (if directory) → zstd compress → age encrypt → split into 950 MB chunks → PAR2 parity → SHA-256 checksums.

## Files

- `archive-create.sh` — creates an archive from a file or directory
- `archive-restore.sh` — restores an archive created by archive-create.sh
- `README.md` — user-facing documentation

## Key conventions

- Both scripts use `set -euo pipefail` and an `ERR` trap for cleanup
- Chunk filenames: `<BASENAME>_00000`, `<BASENAME>_00001`, etc. (sequence only, no hash)
- Output directory: `<BASENAME>-archive-YYYY-MM-DD`
- Both scripts use identical `while/case` arg parsing style
- Both script headers follow the same format: description, Steps, Usage, Options, Output/Prerequisites, Requires
- `archive-create.sh` copies `archive-restore.sh` into the output folder at runtime

## Testing changes

There is no test suite. Validate end-to-end by running archive-create.sh on a small file and confirming archive-restore.sh fully recovers it:

```bash
echo "test data" > test.txt
./archive-create.sh test.txt
./archive-restore.sh test.txt-archive-*/
diff test.txt test.txt
```

## Things to be careful about

- The chunk naming format is load-bearing: `archive-restore.sh` auto-detects the basename using `grep -E '_[0-9]{5}$'` — changes to chunk naming must be reflected in both scripts
- `checksums.sha256` only covers chunks and PAR2 files — not README.txt or archive-restore.sh
- The `age.key` file must never be committed or included in archives
- Chunk size is 950 MB, not 1 GB — this is intentional to stay safely under cloud storage service file size limits; do not change it to `1g`
- Compression must happen before encryption — encrypted data is pseudorandom and does not compress; reversing this order would produce much larger output
