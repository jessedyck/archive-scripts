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
#   7. Write README and copy restore script
#
# Usage:
#   ./archive-create.sh [options] <input-file-or-directory>
#
# Options:
#   --key <keyfile>   age private key file (default: age.key in current directory)
#
# Output (all in <input>-archive-YYYY-MM-DD/ subfolder):
#   <BASENAME>_<NNNNN>            encrypted chunks
#   <BASENAME>.par2               parity recovery files
#   checksums.sha256              chunk checksums
#   README.txt                    restoration instructions
#
# Requires: zstd, age, par2, pv  (macOS: brew install zstd age par2 pv)
#
set -euo pipefail

INPUT=""
KEY="age.key"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) KEY="$2"; shift 2 ;;
    -*)    echo "Unknown flag: $1"; exit 1 ;;
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
  echo "Usage: $0 [--key <keyfile>] <input-file-or-directory>"
  exit 1
fi
if [[ ! -e "$INPUT" ]]; then
  echo "Error: '$INPUT' not found"
  exit 1
fi

BASENAME="$(basename "$INPUT")"
OUTDIR="${BASENAME}-archive-$(date +%Y-%m-%d)"

ZSTD_LEVEL=15
PARITY_PERCENT=15

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
    tar -cf - "$INPUT" | pv -s $SIZE | zstd -"$ZSTD_LEVEL" -o "$OUTDIR/$BASENAME.zst"
else
    echo "==> Compressing..."
    zstd -"$ZSTD_LEVEL" "$INPUT" -o "$OUTDIR/$BASENAME.zst"
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
split -b 950m --suffix-length=4 "$OUTDIR/$BASENAME.zst.age" "$OUTDIR/$BASENAME.zst.age.part-"

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

echo "==> Writing README..."
RECIPIENT_PUBKEY="$(age-keygen -y "$KEY")"
cat > "$OUTDIR/README.txt" <<EOF
Archive: ${BASENAME}
Created: $(date +%Y-%m-%d)

--- TOOLS REQUIRED FOR RESTORATION ---
  zstd    https://github.com/facebook/zstd
  age     https://github.com/FiloSottile/age
  par2    https://github.com/Parchive/par2cmdline

  macOS:  brew install zstd age par2
  Linux:  apt install zstd age par2  (or equivalent)

--- ENCRYPTION KEY ---
  Encrypted with age public key: ${RECIPIENT_PUBKEY}
  Private key file: ${KEY} (keep this safe — without it, the archive cannot be decrypted)

--- VERIFY INTEGRITY ---
  cd <this folder>
  shasum -a 256 -c checksums.sha256

  If files are corrupt, repair with PAR2 (up to ${PARITY_PERCENT}% loss recoverable):
    par2 repair ${BASENAME}.par2

--- RESTORE ---
  1. Verify and repair (see above)
  2. Reassemble chunks in order:
       cat ${BASENAME}_* > ${BASENAME}.zst.age
  3. Decrypt:
       age -d -i /path/to/age.key -o ${BASENAME}.zst ${BASENAME}.zst.age
  4. Decompress:
       zstd -d ${BASENAME}.zst -o ${BASENAME}
  5. If original input was a directory, untar:
       tar -xf ${BASENAME}
EOF

echo "==> Cleaning intermediate files..."
rm "$OUTDIR/$BASENAME.zst" "$OUTDIR/$BASENAME.zst.age"

echo "==> Done. Output folder: $OUTDIR/"
echo "Files created:"
echo "  - $OUTDIR/${BASENAME}_NNNNN  (chunks)"
echo "  - $OUTDIR/$BASENAME.par2"
echo "  - $OUTDIR/checksums.sha256"
echo "  - $OUTDIR/archive-restore.sh"
