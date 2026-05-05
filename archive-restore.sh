#!/usr/bin/env bash
#
# archive-restore.sh — Restore an archive created by archive-create.sh.
#
# Steps:
#   1. Verify checksums
#   2. Concatenate chunks in sequence order
#   3. Decrypt with age
#   4. Decompress with zstd
#   5. (Optional) Extract tar if input was a directory
#
# Usage:
#   ./archive-restore.sh [options] [<input-dir>] [<output-name>]
#
# Options:
#   --key <keyfile>   age private key file (default: age.key in current directory)
#   --no-verify       skip checksum verification
#
# Prerequisites:
#   <input-dir> must contain chunk files named <BASENAME>_<NNNNN>
#   checksums.sha256 must be present unless --no-verify is passed
#
# Requires: zstd, age, pv  (macOS: brew install zstd age pv)
# Optional: par2  — only needed to repair corrupt chunks before restoring
#
set -euo pipefail

VERIFY=true
INPUT_DIR=""
OUTPUT=""
KEY="age.key"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-verify) VERIFY=false; shift ;;
    --key)       KEY="$2"; shift 2 ;;
    -*)          echo "Unknown flag: $1"; exit 1 ;;
    *)
      if [[ -z "$INPUT_DIR" ]]; then
        INPUT_DIR="$1"
      elif [[ -z "$OUTPUT" ]]; then
        OUTPUT="$1"
      else
        echo "Unexpected argument: $1"; exit 1
      fi
      shift ;;
  esac
done

if [[ -z "$INPUT_DIR" ]]; then
  INPUT_DIR="."
fi

if [[ ! -d "$INPUT_DIR" ]]; then
  echo "Error: input directory not found: $INPUT_DIR"
  exit 1
fi

if [[ -z "$OUTPUT" ]]; then
  SAMPLE=$(ls "$INPUT_DIR/" | grep -E '_[0-9]{5}$' | head -1)
  if [[ -n "$SAMPLE" ]]; then
    OUTPUT="${SAMPLE%_*}"
    echo "==> Auto-detected output name: $OUTPUT"
  else
    echo "Error: no chunk files found in $INPUT_DIR. Provide <output-name> as argument."
    exit 1
  fi
fi

if [[ ! -f "$KEY" ]]; then
  echo "Error: key file not found: $KEY"
  exit 1
fi

if [[ -e "${OUTPUT}.zst.age" || -e "${OUTPUT}.zst" || -e "${OUTPUT}" || -d "${OUTPUT}.extracted" ]]; then
  echo "Error: output file(s) for '$OUTPUT' already exist in current directory. Move or remove them first."
  exit 1
fi

trap 'echo "==> Error — cleaning up intermediate files..."; rm -f "${OUTPUT}.zst.age" "${OUTPUT}.zst"' ERR

# Step 1: Verify checksums
if $VERIFY; then
  CHECKSUM_FILE="$INPUT_DIR/checksums.sha256"
  if [[ ! -f "$CHECKSUM_FILE" ]]; then
    echo "Error: checksums.sha256 not found in $INPUT_DIR. Use --no-verify to skip."
    exit 1
  fi
  echo "==> Verifying checksums..."
  if ! (cd "$INPUT_DIR" && shasum -a 256 -c checksums.sha256); then
    echo "Checksum verification FAILED. Use --no-verify to skip (not recommended)."
    exit 1
  fi
  echo "==> Checksums OK."
fi

# Step 2: Concatenate chunks
# NOTE: Chunks are concatenated in sequence-number order (_00000_, _00001_, ...).
# Bash glob expansion is lexicographic, so the glob below naturally produces the correct order.
echo "==> Concatenating chunks from $INPUT_DIR/..."
CHUNK_COUNT=$(ls "$INPUT_DIR/" | grep -c "^${OUTPUT}_" || true)
echo "    Found ${CHUNK_COUNT} chunk(s)."

TOTAL_SIZE=$(du -sk "$INPUT_DIR/${OUTPUT}_"* | awk '{sum += $1} END {print sum * 1024}')
cat "$INPUT_DIR/${OUTPUT}_"* | pv -s "$TOTAL_SIZE" > "${OUTPUT}.zst.age"

# Step 3: Decrypt
echo "==> Decrypting with age..."
pv "${OUTPUT}.zst.age" | age -d -i "$KEY" -o "${OUTPUT}.zst"
rm "${OUTPUT}.zst.age"

# Step 4: Decompress
echo "==> Verifying decrypted archive..."
zstd -t "${OUTPUT}.zst"

echo "==> Decompressing with zstd..."
pv "${OUTPUT}.zst" | zstd -d -o "${OUTPUT}.restored"
rm "${OUTPUT}.zst"

# Step 5: Extract tar if the file looks like a tar
if tar -tf "${OUTPUT}.restored" > /dev/null 2>&1; then
  echo "==> Extracting tar archive..."
  mkdir -p "${OUTPUT}.extracted"
  tar -xf "${OUTPUT}.restored" -C "${OUTPUT}.extracted"
  rm "${OUTPUT}.restored"
  echo "==> Done. Extracted to: ${OUTPUT}.extracted/"
else
  mv "${OUTPUT}.restored" "${OUTPUT}"
  echo "==> Done. Restored file: ${OUTPUT}"
fi
