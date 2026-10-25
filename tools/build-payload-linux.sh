#!/usr/bin/env bash
# Linux (Dell WSL) build of the PS5 payload, same steps as build-payload.ps1
# -HomeIcon. Toolchain is pinned in tools/blazing-toolchain.txt; this script
# sets it up under $TC (default ../toolchain next to the checkout).
#   tools/build-payload-linux.sh <version>
set -euo pipefail
VERSION="${1:?version}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TC="${TC:-$ROOT/../toolchain}"
SDK="$TC/ps5-payload-sdk"
GOROOT_PS5="$TC/goroot"
GO_TGZ="$TC/go1.27.1.linux-amd64.tar.gz"
SDK_ZIP="$TC/ps5-payload-sdk-v0.43.zip"

check() { echo "$2  $1" | sha256sum -c --quiet - || { echo "checksum mismatch: $1"; exit 1; }; }
check "$GO_TGZ"  63d339f0da5ab53635a56f2490a7984dfe12dfcff22ad749f63edaf590168445
check "$SDK_ZIP" a9cc9929f21b2b2c5d5b309f3bab4997067c45281c0622cf4838b1aecba66fcb

[ -d "$SDK" ] || (cd "$TC" && unzip -q "$SDK_ZIP")
if [ ! -x "$GOROOT_PS5/bin/go" ] || [ ! -f "$GOROOT_PS5/.ps5-patched" ]; then
    rm -rf "$GOROOT_PS5" "$TC/go"
    tar -xzf "$GO_TGZ" -C "$TC" && mv "$TC/go" "$GOROOT_PS5"
    (cd "$GOROOT_PS5" && git apply -p1 "$ROOT/patches/go1.27.1-ps5.patch" \
        && cp bin/go bin/go-bootstrap \
        && GOTOOLCHAIN=local GOROOT="$GOROOT_PS5" ./bin/go-bootstrap install cmd/go cmd/link \
        && touch .ps5-patched)
fi

OUT="$ROOT/out"; mkdir -p "$OUT" "$ROOT/.gotmp" "$ROOT/.gocache"
(cd "$ROOT/tsd" && GOROOT="$GOROOT_PS5" GOOS=freebsd GOARCH=amd64 CGO_ENABLED=0 GOTOOLCHAIN=local \
    GOTMPDIR="$ROOT/.gotmp" GOCACHE="$ROOT/.gocache" \
    "$GOROOT_PS5/bin/go" build -buildmode=pie -trimpath \
    -ldflags="-s -w -X main.version=$VERSION" -o "$OUT/tailscale.bin" .)

# The SDK wrapper takes the newest llvm-config it finds; pick one whose LLVM
# also has ld.lld (Ubuntu's llvm-19 here came without lld).
if [ -z "${LLVM_CONFIG:-}" ]; then
    for c in llvm-config-21 llvm-config-20 llvm-config-19 llvm-config-18 llvm-config; do
        if command -v "$c" >/dev/null && [ -x "$("$c" --bindir)/ld.lld" ]; then export LLVM_CONFIG="$c"; break; fi
    done
fi
echo "LLVM: ${LLVM_CONFIG:-?} $(${LLVM_CONFIG:-llvm-config} --version)"
CC="$SDK/bin/prospero-clang"
"$CC" -O2 -Wall -DASSET_DIR="\"$ROOT/appicon\"" \
    -lSceIpmi -lSceAppInstUtil -lSceUserService -lSceSystemService \
    -o "$OUT/appicon.elf" "$ROOT/appicon/main.c"
"$CC" -O2 -Wall -DGO_IMAGE="\"$OUT/tailscale.bin\"" -DICON_HELPER="\"$OUT/appicon.elf\"" \
    -o "$OUT/tailscale.elf" "$ROOT/launcher/main.c" "$ROOT/launcher/goload.c" \
    "$ROOT/launcher/homeicon.c" "$ROOT/launcher/report.c"
ls -la "$OUT/tailscale.elf"; sha256sum "$OUT/tailscale.elf"
