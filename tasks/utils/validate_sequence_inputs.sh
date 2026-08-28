#!/bin/bash
# Cheap integrity validation for sequence-file inputs (BAM/CRAM/FASTQ/VCF/...).
#
# Motivation: a customer-supplied uBAM that had been truncated mid-transfer sent
# pbmm2 through 46 minutes of alignment on each of 3 retries before aborting with
# "terminate called without an active exception" and an empty log. The defect was
# detectable in milliseconds. This runs before the expensive step and says so.
#
# Design notes:
#   * O(1) for BGZF files (BAM/CRAM/VCF.gz/...). Reads the first 18 bytes and the
#     last 1 MiB -- NOT the whole file. Safe to run on 18 GB inputs over CIFS.
#   * Distinguishes "only the 28-byte EOF marker is missing" (recoverable) from
#     "final block is incomplete" (real data loss, re-transfer required), because
#     the operator response differs.
#   * Plain-gzip streams (most FASTQ.gz) are not seekable, so a full integrity
#     check means decompressing everything. That is opt-in via THOROUGH=1.
#
# Usage:
#     source validate_sequence_inputs.sh
#     validate_sequence_files "${bam_array[@]}"   # exits non-zero on first failure
#
#     ./validate_sequence_inputs.sh FILE [FILE...]        # standalone
#     THOROUGH=1 ./validate_sequence_inputs.sh FILE ...   # full gzip decode too

_vsi_python() { command -v python3 >/dev/null 2>&1 && echo python3 || echo python; }

# Inspect BGZF structure from the tail. Prints one of:
#   OK | MARKER_ONLY:<detail> | TRUNCATED:<detail> | NOTBGZF | UNKNOWN:<detail>
_vsi_bgzf_probe() {
    "$(_vsi_python)" - "$1" <<'PYEOF'
import os, sys, zlib

EOF_MARKER = bytes.fromhex("1f8b08040000000000ff0600424302001b0003000000000000000000")
TAIL = 1 << 20

path = sys.argv[1]
size = os.path.getsize(path)

with open(path, "rb") as fh:
    head = fh.read(18)
    # BGZF == gzip with FEXTRA and a 'BC' subfield carrying the block size
    if len(head) < 18 or head[:4] != b"\x1f\x8b\x08\x04" or head[12:16] != b"\x42\x43\x02\x00":
        print("NOTBGZF"); raise SystemExit(0)

    if size >= len(EOF_MARKER):
        fh.seek(size - len(EOF_MARKER))
        if fh.read(len(EOF_MARKER)) == EOF_MARKER:
            print("OK"); raise SystemExit(0)

    start = max(0, size - TAIL)
    fh.seek(start)
    buf = fh.read()

best = None
i = buf.find(b"\x1f\x8b\x08\x04")
while i != -1:
    if buf[i + 12:i + 16] == b"\x42\x43\x02\x00" and i + 18 <= len(buf):
        bsize = int.from_bytes(buf[i + 16:i + 18], "little") + 1
        block = buf[i:i + bsize]
        if len(block) != bsize:
            best = (i, bsize, len(block))          # declared length overruns EOF
        else:
            try:
                zlib.decompress(block[18:], -15)   # raw deflate payload
                best = (i, bsize, len(block))
            except zlib.error:
                pass
    i = buf.find(b"\x1f\x8b\x08\x04", i + 1)

if best is None:
    print(f"UNKNOWN:no BGZF block header in the last {TAIL // 1024} KiB")
    raise SystemExit(0)

off, bsize, got = best
end = start + off + bsize
if end == size:
    print(f"MARKER_ONLY:last block ends exactly at EOF ({size} bytes); "
          f"only the 28-byte BGZF EOF marker is absent")
else:
    print(f"TRUNCATED:final block declares {bsize} bytes but only {got} are present "
          f"({end - size} bytes short); file is {size} bytes")
PYEOF
}

_vsi_fail() {
    echo ""
    echo "❌ ERROR: input file failed integrity validation"
    echo "   File:   $1"
    echo "   Reason: $2"
    shift 2
    for line in "$@"; do echo "   $line"; done
    echo ""
    return 1
}

# validate_sequence_file <path>
validate_sequence_file() {
    local f="$1"
    local base; base=$(basename "$f")

    if [ ! -e "$f" ]; then
        _vsi_fail "$f" "file does not exist" \
            "Check the path and that the storage location is mounted."
        return 1
    fi
    if [ ! -r "$f" ]; then
        _vsi_fail "$f" "file is not readable" "Check permissions on the file and its parents."
        return 1
    fi
    local size; size=$(stat -c%s "$f" 2>/dev/null || echo 0)
    if [ "$size" -eq 0 ]; then
        _vsi_fail "$f" "file is empty (0 bytes)" \
            "This usually means a transfer created the file but never wrote to it."
        return 1
    fi

    case "${base,,}" in
        *.bam|*.cram|*.bcf|*.vcf.gz|*.bed.gz|*.gz|*.bgz)
            local probe; probe=$(_vsi_bgzf_probe "$f" 2>/dev/null)
            case "$probe" in
                OK) ;;
                MARKER_ONLY:*)
                    _vsi_fail "$f" "BGZF EOF marker is missing (${probe#MARKER_ONLY:})" \
                        "All compressed blocks are intact, so no read data was lost." \
                        "The 28-byte end-of-file marker can be appended to repair it:" \
                        "  printf '\\x1f\\x8b\\x08\\x04\\x00\\x00\\x00\\x00\\x00\\xff\\x06\\x00\\x42\\x43\\x02\\x00\\x1b\\x00\\x03\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00' >> '$f'" \
                        "Confirm the read count is unchanged before and after."
                    return 1
                    ;;
                TRUNCATED:*)
                    _vsi_fail "$f" "file is TRUNCATED -- read data is missing (${probe#TRUNCATED:})" \
                        "This is not repairable: reads are absent from the file." \
                        "Re-transfer from the source and verify with a checksum, not a byte count." \
                        "A size that is an exact multiple of 1 MiB indicates a chunked copy that stopped early."
                    return 1
                    ;;
                NOTBGZF)
                    # plain gzip: only a full decode can prove integrity
                    if [ "${THOROUGH:-0}" = "1" ]; then
                        if ! gzip -t "$f" 2>/dev/null; then
                            _vsi_fail "$f" "gzip stream is corrupt or truncated (gzip -t failed)" \
                                "Re-transfer from the source and verify with a checksum."
                            return 1
                        fi
                    fi
                    ;;
                UNKNOWN:*)
                    _vsi_fail "$f" "could not parse BGZF structure (${probe#UNKNOWN:})" \
                        "The file may not be the format its extension claims."
                    return 1
                    ;;
                *)
                    _vsi_fail "$f" "integrity probe failed to run" \
                        "python3 may be unavailable on this agent."
                    return 1
                    ;;
            esac
            ;;
    esac

    # Header must parse. Reads only the header, not the records.
    case "${base,,}" in
        *.bam|*.cram|*.sam)
            if command -v samtools >/dev/null 2>&1; then
                if ! samtools view -H "$f" >/dev/null 2>&1; then
                    _vsi_fail "$f" "header could not be read by samtools" \
                        "The file is not a valid ${base##*.} or its header is damaged."
                    return 1
                fi
            fi
            ;;
    esac

    echo "  ✓ $base ($(numfmt --to=iec --suffix=B "$size" 2>/dev/null || echo "${size} bytes"))"
    return 0
}

# validate_sequence_files <path> [path...]
validate_sequence_files() {
    local failed=0 n=0
    echo "Validating $# input file(s) for integrity..."
    for f in "$@"; do
        [ -z "$f" ] && continue
        n=$((n + 1))
        validate_sequence_file "$f" || failed=$((failed + 1))
    done
    if [ "$failed" -gt 0 ]; then
        echo "❌ $failed of $n input file(s) failed validation. Refusing to start analysis."
        echo "   Fix the inputs above and re-run; continuing would waste hours of compute"
        echo "   and could silently produce results from incomplete data."
        return 1
    fi
    echo "  All $n input file(s) passed integrity validation."
    return 0
}

# validate_sequence_inputs_csv <arg> [arg...]
#
# Accepts task parameters directly, whether they are a single path or a
# "list: true" parameter (which the runtime hands over comma-separated).
# Empty/unset arguments are skipped, so optional parameters can be passed
# unconditionally as "${maybe_unset:-}". This is the entry point task files
# should call -- it keeps the call site identical across every task.
validate_sequence_inputs_csv() {
    local expanded=() arg piece parts
    for arg in "$@"; do
        [ -z "$arg" ] && continue
        # Split on comma only, so paths containing spaces survive intact.
        # "read -ra <<<" is used rather than a "while read" over a pipeline:
        # the latter silently drops the final element when the stream has no
        # trailing newline, which would let a bad file through unvalidated.
        IFS=',' read -ra parts <<< "$arg"
        for piece in "${parts[@]}"; do
            piece="${piece#"${piece%%[![:space:]]*}"}"   # ltrim
            piece="${piece%"${piece##*[![:space:]]}"}"   # rtrim
            [ -n "$piece" ] && expanded+=("$piece")
        done
    done
    if [ ${#expanded[@]} -eq 0 ]; then
        echo "  (no sequence-file inputs to validate)"
        return 0
    fi
    validate_sequence_files "${expanded[@]}"
}

# standalone invocation
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    [ $# -eq 0 ] && { echo "usage: $0 FILE [FILE...]" >&2; exit 2; }
    validate_sequence_files "$@" || exit 1
fi
