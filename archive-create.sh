#!/usr/bin/env bash
#
# archive-create.sh — Create a cloud-friendly, integrity-checked archive.
#
# Steps:
#   0. (Optional) Tar if input is a directory
#   1. Compress with zstd
#   2. Encrypt with age
#   3. Split into 950 MB chunks
#   4. Rename chunks to sequence-numbered filenames
#   5. Create PAR2 parity
#   6. Generate checksums
#   7. Write key fingerprint and copy restore script
#
# Usage:
#   ./archive-create.sh [options] <input-file-or-directory>
#
# Options:
#   --key <keyfile>         age private key file (default: age.key in current directory)
#   --compression <level>   zstd compression level 1-22 (default: 15; levels 20-22 are slow)
#
# Output (all in <input>-archive-YYYY-MM-DD/ subfolder):
#   <BASENAME>_<NNNNN>            encrypted chunks
#   <BASENAME>.par2               parity recovery files
#   checksums.sha256              chunk checksums
#   key.pub                       age public key fingerprint
#
# Requires: zstd, age, par2, pv  (macOS: brew install zstd age par2 pv)
#
set -euo pipefail

INPUT=""
KEY="age.key"
COMPRESSION=15

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key)         KEY="$2"; shift 2 ;;
    --compression) COMPRESSION="$2"; shift 2 ;;
    -*)            echo "Unknown flag: $1"; exit 1 ;;
    *)
      if [[ -z "$INPUT" ]]; then
        INPUT="$1"
      else
        echo "Unexpected argument: $1"; exit 1
      fi
      shift ;;
  esac
done

if [[ -z "$INPUT" ]]; then
  echo "Usage: $0 [--key <keyfile>] [--compression <level>] <input-file-or-directory>"
  exit 1
fi
if [[ ! -e "$INPUT" ]]; then
  echo "Error: '$INPUT' not found"
  exit 1
fi

BASENAME="$(basename "$INPUT")"
OUTDIR="${BASENAME}-archive-$(date +%Y-%m-%d)"

PARITY_PERCENT=15
[[ "$COMPRESSION" -gt 19 ]] && ZSTD_FLAGS="--ultra -${COMPRESSION}" || ZSTD_FLAGS="-${COMPRESSION}"

if [[ -d "$OUTDIR" ]]; then
  echo "Error: output directory '$OUTDIR' already exists. Move or remove it first."
  exit 1
fi

mkdir -p "$OUTDIR"

trap 'echo "==> Error — cleaning up intermediate files..."; rm -f "$OUTDIR/$BASENAME.zst" "$OUTDIR/$BASENAME.zst.age"' ERR

# Tar if directory
if [ -d "$INPUT" ]; then
    echo "==> Input is a directory, creating and compressing tar archive..."
    SIZE=$(du -sk "$INPUT" | awk '{print $1*1024}')
    tar -cf - "$INPUT" | pv -s $SIZE | zstd $ZSTD_FLAGS -o "$OUTDIR/$BASENAME.zst"
else
    echo "==> Compressing..."
    zstd $ZSTD_FLAGS "$INPUT" -o "$OUTDIR/$BASENAME.zst"
fi

echo "==> Verifying compression..."
zstd -t "$OUTDIR/$BASENAME.zst"

echo "==> Encrypting with age..."
if [ ! -f "$KEY" ]; then
  echo "No key file found at '$KEY', generating one..."
  age-keygen -o "$KEY"
  echo ""
  echo "  *** IMPORTANT: $KEY has been created. Back it up to a secure,       ***"
  echo "  *** separate location immediately. If this file is lost, the        ***"
  echo "  *** archive CANNOT be decrypted.                                    ***"
  echo ""
fi
RECIPIENT="$(age-keygen -y "$KEY")"
pv "$OUTDIR/$BASENAME.zst" | age -r "$RECIPIENT" -o "$OUTDIR/$BASENAME.zst.age"

echo "==> Verifying encryption..."
age -d -i "$KEY" "$OUTDIR/$BASENAME.zst.age" > /dev/null

echo "==> Splitting into 950 MB chunks..."
split -b 950m -a 4 "$OUTDIR/$BASENAME.zst.age" "$OUTDIR/$BASENAME.zst.age.part-"

echo "==> Renaming chunks..."
SEQ=0
for f in "$OUTDIR/$BASENAME.zst.age.part-"*; do
  mv "$f" "$OUTDIR/${BASENAME}_$(printf '%05d' $SEQ)"
  SEQ=$((SEQ + 1))
done

echo "==> Creating PAR2 parity (${PARITY_PERCENT}%)..."
par2 create -r"$PARITY_PERCENT" "$OUTDIR/$BASENAME.par2" "$OUTDIR/${BASENAME}_"*

echo "==> Generating checksums..."
(cd "$OUTDIR" && shasum -a 256 "${BASENAME}_"* "$BASENAME.par2"* > checksums.sha256)

echo "==> Copying restore script..."
RESTORE_SCRIPT="$(dirname "$0")/archive-restore.sh"
if [[ -f "$RESTORE_SCRIPT" ]]; then
  cp "$RESTORE_SCRIPT" "$OUTDIR/archive-restore.sh"
else
  echo "Warning: archive-restore.sh not found at '$RESTORE_SCRIPT', skipping."
fi

echo "==> Writing key fingerprint..."
age-keygen -y "$KEY" > "$OUTDIR/key.pub"

echo "==> Cleaning intermediate files..."
rm "$OUTDIR/$BASENAME.zst" "$OUTDIR/$BASENAME.zst.age"

echo "==> Done. Output folder: $OUTDIR/"
echo "Files created:"
echo "  - $OUTDIR/${BASENAME}_NNNNN  (chunks)"
echo "  - $OUTDIR/$BASENAME.par2"
echo "  - $OUTDIR/checksums.sha256"
echo "  - $OUTDIR/key.pub"
echo "  - $OUTDIR/archive-restore.sh"
