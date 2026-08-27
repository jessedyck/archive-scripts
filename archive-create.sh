#!/usr/bin/env bash
#
# archive-create.sh — Create a cloud-friendly, integrity-checked archive.
#
# Steps:
#   0. Display configuration summary and require confirmation
#   1. (Optional) Tar if input is a directory
#   2. Compress with zstd
#   3. Encrypt with age
#   4. Split into 950 MB chunks
#   5. Rename chunks to sequence-numbered filenames
#   6. Create PAR2 parity
#   7. Generate checksums
#   8. Write key fingerprint, configuration summary, and copy restore script
#
# Usage:
#   ./archive-create.sh [options] <input-file-or-directory>
#
# Options:
#   --key <keyfile>         age private key file (default: age.key in current directory)
#   --compression <level>   zstd compression level 1-22 (default: 15; levels 20-22 are slow)
#   --exclude <pattern>     exclude files/folders matching pattern (directory input only,
#                            repeatable); passed through to tar --exclude
#   --include-sockets       do not auto-exclude unix domain sockets (directory input only;
#                            by default they are auto-detected and excluded since no tar
#                            format can archive them)
#   --resolve-exclusions    for each --exclude pattern, list the actual paths it matches
#                            in the configuration summary (directory input only; adds a
#                            filesystem scan before archiving starts)
#   -y                       skip the configuration confirmation prompt and proceed automatically
#
# Output (all in <input>-archive-YYYY-MM-DD/ subfolder):
#   <BASENAME>_<NNNNN>            encrypted chunks
#   <BASENAME>.par2               parity recovery files
#   checksums.sha256              chunk checksums
#   key.pub                       age public key fingerprint
#   README.txt                    configuration used to create this archive
#
# Requires: zstd, age, par2, pv  (macOS: brew install zstd age par2 pv)
#
set -euo pipefail

log() { echo "[$(date +%H:%M:%S)] $*"; }
filesize() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1"; }

INPUT=""
KEY="age.key"
COMPRESSION=15
EXCLUDES=()
INCLUDE_SOCKETS=false
RESOLVE_EXCLUSIONS=false
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key)               KEY="$2"; shift 2 ;;
    --compression)       COMPRESSION="$2"; shift 2 ;;
    --exclude)           EXCLUDES+=("$2"); shift 2 ;;
    --include-sockets)   INCLUDE_SOCKETS=true; shift ;;
    --resolve-exclusions) RESOLVE_EXCLUSIONS=true; shift ;;
    -y)                  ASSUME_YES=true; shift ;;
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
  echo "Usage: $0 [--key <keyfile>] [--compression <level>] [--exclude <pattern>]... [--include-sockets] [--resolve-exclusions] [-y] <input-file-or-directory>"
  exit 1
fi
if [[ ! -e "$INPUT" ]]; then
  echo "Error: '$INPUT' not found"
  exit 1
fi

BASENAME="$(basename "$INPUT")"
OUTDIR="${BASENAME}-archive-$(date +%Y-%m-%d)"

PARITY_PERCENT=15
[[ "$COMPRESSION" -gt 19 ]] && ZSTD_FLAGS="--ultra -${COMPRESSION} -q" || ZSTD_FLAGS="-${COMPRESSION} -q"

if [[ -d "$OUTDIR" ]]; then
  echo "Error: output directory '$OUTDIR' already exists. Move or remove it first."
  exit 1
fi

INPUT_TYPE="file"
[[ -d "$INPUT" ]] && INPUT_TYPE="directory"

if [[ "$INPUT_TYPE" == "directory" ]]; then
  ABS_INPUT="$(cd "$INPUT" && pwd)"
else
  ABS_INPUT="$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")"
fi
ABS_OUTDIR="$(pwd)/$OUTDIR"

SOCKETS=()
if [[ "$INPUT_TYPE" == "directory" && "$INCLUDE_SOCKETS" != true ]]; then
  log "==> Scanning for sockets to exclude (this can take a while on large directories)..."
  while IFS= read -r sock; do
    SOCKETS+=("$sock")
  done < <(find "$INPUT" -type s)
fi

print_config() {
  echo "Archive configuration:"
  echo "    Archive:      $BASENAME"
  echo "    Created:      $(date '+%Y-%m-%d %H:%M:%S')"
  echo "    Source:       $ABS_INPUT ($INPUT_TYPE)"
  echo "    Destination:  $ABS_OUTDIR/"
  echo "    Key file:     $KEY"
  echo "    Compression:  $COMPRESSION"
  if [[ "$INPUT_TYPE" == "directory" ]]; then
    if [[ ${#EXCLUDES[@]} -gt 0 ]]; then
      echo "    Exclusions:"
      for pattern in "${EXCLUDES[@]}"; do
        echo "      - $pattern"
        if [[ "$RESOLVE_EXCLUSIONS" == true ]]; then
          local matches
          matches="$(find "$INPUT" -path "*/$pattern" -print -prune 2>/dev/null)"
          if [[ -n "$matches" ]]; then
            while IFS= read -r m; do
              echo "          -> $m"
            done <<< "$matches"
          else
            echo "          (no matches found)"
          fi
        fi
      done
    else
      echo "    Exclusions:   (none)"
    fi
    if [[ "$INCLUDE_SOCKETS" == true ]]; then
      echo "    Sockets:      included (--include-sockets set; tar will warn and skip natively)"
    elif [[ ${#SOCKETS[@]} -gt 0 ]]; then
      echo "    Sockets excluded (cannot be archived):"
      for sock in "${SOCKETS[@]}"; do
        echo "      - $sock"
      done
    else
      echo "    Sockets:      (none found)"
    fi
  else
    if [[ ${#EXCLUDES[@]} -gt 0 ]]; then
      echo "    Exclusions:   (ignored — input is a single file)"
    fi
  fi
}

if [[ "$INPUT_TYPE" == "directory" && "$RESOLVE_EXCLUSIONS" == true && ${#EXCLUDES[@]} -gt 0 ]]; then
  log "==> Resolving real paths for each exclusion..."
fi
CONFIG_SUMMARY="$(print_config)"
echo "==> $CONFIG_SUMMARY"
echo ""
if [[ "$ASSUME_YES" == true ]]; then
  echo "-y set, proceeding automatically."
else
  read -r -p "Proceed with this configuration? [y/N] " CONFIRM
  case "$CONFIRM" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

mkdir -p "$OUTDIR"

trap 'log "==> Error — cleaning up intermediate files..."; rm -f "$OUTDIR/$BASENAME.zst" "$OUTDIR/$BASENAME.zst.age"' ERR

# Tar if directory
if [ -d "$INPUT" ]; then
    log "==> Input is a directory, creating and compressing tar archive..."
    TAR_EXCLUDE_ARGS=()
    if [[ ${#EXCLUDES[@]} -gt 0 ]]; then
      for pattern in "${EXCLUDES[@]}"; do
        TAR_EXCLUDE_ARGS+=(--exclude="$pattern")
      done
    fi
    if [[ ${#SOCKETS[@]} -gt 0 ]]; then
      for sock in "${SOCKETS[@]}"; do
        TAR_EXCLUDE_ARGS+=(--exclude="$sock")
      done
    fi
    SIZE=$(du -sk "$INPUT" | awk '{print $1*1024}')
    tar -cf - "${TAR_EXCLUDE_ARGS[@]+"${TAR_EXCLUDE_ARGS[@]}"}" "$INPUT" | pv -s $SIZE | zstd $ZSTD_FLAGS -o "$OUTDIR/$BASENAME.zst"
else
    if [[ ${#EXCLUDES[@]} -gt 0 ]]; then
      log "==> Warning: --exclude has no effect on single-file input; ignoring."
    fi
    log "==> Compressing..."
    pv -s "$(filesize "$INPUT")" "$INPUT" | zstd $ZSTD_FLAGS -o "$OUTDIR/$BASENAME.zst"
fi

log "==> Verifying compression..."
pv -s "$(filesize "$OUTDIR/$BASENAME.zst")" "$OUTDIR/$BASENAME.zst" | zstd -qt -

log "==> Encrypting with age..."
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
pv -s "$(filesize "$OUTDIR/$BASENAME.zst")" "$OUTDIR/$BASENAME.zst" | age -r "$RECIPIENT" -o "$OUTDIR/$BASENAME.zst.age"

log "==> Verifying encryption..."
pv -s "$(filesize "$OUTDIR/$BASENAME.zst.age")" "$OUTDIR/$BASENAME.zst.age" | age -d -i "$KEY" - > /dev/null

log "==> Splitting into 950 MB chunks..."
pv -s "$(filesize "$OUTDIR/$BASENAME.zst.age")" "$OUTDIR/$BASENAME.zst.age" | split -b 950m -a 4 - "$OUTDIR/$BASENAME.zst.age.part-"

log "==> Renaming chunks..."
SEQ=0
for f in "$OUTDIR/$BASENAME.zst.age.part-"*; do
  mv "$f" "$OUTDIR/${BASENAME}_$(printf '%05d' $SEQ)"
  SEQ=$((SEQ + 1))
done

log "==> Creating PAR2 parity (${PARITY_PERCENT}%)..."
par2 create -r"$PARITY_PERCENT" "$OUTDIR/$BASENAME.par2" "$OUTDIR/${BASENAME}_"*

log "==> Generating checksums..."
(cd "$OUTDIR" && for f in "${BASENAME}_"* "$BASENAME.par2"*; do
  pv -s "$(filesize "$f")" "$f" | shasum -a 256 - | sed "s|  -$|  $f|"
done > checksums.sha256)

log "==> Copying restore script..."
RESTORE_SCRIPT="$(dirname "$0")/archive-restore.sh"
if [[ -f "$RESTORE_SCRIPT" ]]; then
  cp "$RESTORE_SCRIPT" "$OUTDIR/archive-restore.sh"
else
  echo "Warning: archive-restore.sh not found at '$RESTORE_SCRIPT', skipping."
fi

log "==> Writing key fingerprint..."
age-keygen -y "$KEY" > "$OUTDIR/key.pub"

log "==> Writing configuration summary..."
echo "$CONFIG_SUMMARY" > "$OUTDIR/README.txt"

log "==> Cleaning intermediate files..."
rm "$OUTDIR/$BASENAME.zst" "$OUTDIR/$BASENAME.zst.age"

log "==> Done. Output folder: $OUTDIR/"
echo "Files created:"
echo "  - $OUTDIR/${BASENAME}_NNNNN  (chunks)"
echo "  - $OUTDIR/$BASENAME.par2"
echo "  - $OUTDIR/checksums.sha256"
echo "  - $OUTDIR/key.pub"
echo "  - $OUTDIR/README.txt"
echo "  - $OUTDIR/archive-restore.sh"
