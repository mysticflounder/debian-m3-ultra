#!/bin/bash
# Decode only the bounded, hashed source inventory from a disposable guest.
set -euo pipefail
umask 077
[ "$#" -eq 1 ] || { echo 'usage: extract-abi-inventory.sh serial.raw.log' >&2; exit 1; }
[ -f "$1" ] && [ ! -L "$1" ] || exit 1
HERE="$(cd "$(/usr/bin/dirname "$0")/.." && pwd -P)"
[ ! -L "$HERE/scratch" ] || exit 1
/bin/mkdir -p "$HERE/scratch"
[ "$(cd "$HERE/scratch" && pwd -P)" = "$HERE/scratch" ] || exit 1
dest="$(/usr/bin/mktemp -d "$HERE/scratch/abi-sources.XXXXXX")"
# A failed extraction leaves a private diagnostic directory, never a PASS.
/usr/bin/awk -v dest="$dest" '
    BEGIN {
        split("Makefile ptrace.c syscall-abi.c syscall-abi-asm.S syscall-abi.h tpidr2.c hwcap.c kselftest.h lib.mk", names, " ")
        for (i in names) allowed[names[i]]=1
    }
    function reject() { bad=1; exit 1 }
    {
        sub(/\r$/, "")
        if ($0 ~ /^M3_ABI_FILE_BEGIN /) {
            if (active || NF != 4) reject()
            name=$2; sub(/^name=/, "", name)
            sha=$3; sub(/^sha256=/, "", sha)
            bytes=$4; sub(/^bytes=/, "", bytes)
            if ($2 != "name=" name || $3 != "sha256=" sha || $4 != "bytes=" bytes ||
                !allowed[name] || seen[name] || length(sha)!=64 || sha !~ /^[0-9a-f]+$/ ||
                bytes !~ /^[1-9][0-9]*$/ || length(bytes)>6 || bytes+0>131072) reject()
            total+=bytes; if (total>524288) reject()
            seen[name]=1; count++; active=1; encoded=0
            print name "\t" sha "\t" bytes >> (dest "/inventory.tsv")
            next
        }
        if ($0 ~ /^M3_ABI_FILE_END /) {
            if (!active || $0 != "M3_ABI_FILE_END name=" name || encoded==0) reject()
            close(dest "/" name ".base64"); active=0; next
        }
        if ($0 ~ /^M3_ABI_FILE_/) reject()
        if (active) {
            if ($0 !~ /^[A-Za-z0-9+\/=]+$/ || length($0)>128) reject()
            encoded+=length($0); if (encoded>174764) reject()
            print > (dest "/" name ".base64")
        }
    }
    END {
        if (bad || active || count!=9) exit 1
        for (i in names) if (!seen[names[i]]) exit 1
    }
' "$1"
total=0
while IFS=$'\t' read -r name expected bytes; do
    /usr/bin/base64 -D -i "$dest/$name.base64" -o "$dest/$name"
    [ "$(/usr/bin/stat -f %z "$dest/$name")" = "$bytes" ]
    actual="$(/usr/bin/openssl dgst -sha256 -r "$dest/$name")"
    [ "${actual%% *}" = "$expected" ]
    total=$((total+bytes))
done < "$dest/inventory.tsv"
printf 'ABI inventory verified: files=9 bytes=%s\n%s\n' "$total" "$dest"
