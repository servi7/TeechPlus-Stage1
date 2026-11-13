#!/usr/bin/env bash
set -Eeuo pipefail

# Reproducible build script for Xray-core Android AAR (gomobile)
# Usage: XRAY_TAG=v25.3.6 ./scripts/build-xray.sh

XRAY_TAG="${XRAY_TAG:-v25.3.6}"
readonly PINNED_GOMOBILE_COMMIT="5e5de4c8566398af0cdd9ee4164eeded53b1c0b3"
ANDROID_API="${ANDROID_API:-24}"
OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/artifacts/xray"
WORK_BASE="${WORK_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$WORK_BASE"
BUILD_DIR="$(mktemp -d "$WORK_BASE/teechplus-xray.XXXXXX")"
STAGE_DIR="$BUILD_DIR/stage"
BACKUP_DIR="$BUILD_DIR/backup"
mkdir -p "$STAGE_DIR" "$BACKUP_DIR" "$BUILD_DIR/gobin"

PUBLISH_ACTIVE=0
TARGETS=("libxray.aar" "libxray.aar.sha256")

rollback_publish() {
  local rel
  for rel in "${TARGETS[@]}"; do
    rm -f "$OUT_DIR/$rel.staging.$$"
    if [ -f "$BACKUP_DIR/$rel" ]; then
      cp -p "$BACKUP_DIR/$rel" "$OUT_DIR/$rel" || true
    else
      rm -f "$OUT_DIR/$rel"
    fi
  done
  PUBLISH_ACTIVE=0
}

on_err() {
  if [ "${PUBLISH_ACTIVE:-0}" = "1" ]; then
    rollback_publish
  fi
}

cleanup() {
  rm -rf "$BUILD_DIR"
}

trap on_err ERR
trap cleanup EXIT

export ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
: "${ANDROID_HOME:?ANDROID_HOME or ANDROID_SDK_ROOT must be set}"
: "${ANDROID_NDK_HOME:?ANDROID_NDK_HOME must point to an installed Android NDK}"
READELF="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"

for cmd in go git sha256sum unzip "$READELF"; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: Required tool '$cmd' not found." >&2
    exit 1
  }
done

verify_elf() {
  local file="$1" expected_machine="$2" min_align="$3" require_interp="$4"
  local hdr machine etype
  hdr="$("$READELF" -h "$file")"
  etype="$(printf '%s\n' "$hdr" | awk -F: '/Type:/ {print $2}')"
  machine="$(printf '%s\n' "$hdr" | awk -F: '/Machine:/ {print $2}')"
  printf '%s' "$etype" | grep -q "DYN" || { echo "ERROR: $file is not ET_DYN ($etype)" >&2; return 1; }
  printf '%s' "$machine" | grep -Fq "$expected_machine" || { echo "ERROR: $file machine mismatch: $machine != $expected_machine" >&2; return 1; }

  "$READELF" -lW "$file" | awk -v min="$min_align" -v req_interp="$require_interp" '
    function hex2dec(h,   i, c, v, n) {
      sub(/^0[xX]/, "", h); n = 0
      for (i = 1; i <= length(h); i++) {
        c = tolower(substr(h, i, 1))
        v = index("0123456789abcdef", c) - 1
        if (v < 0) return -1
        n = n * 16 + v
      }
      return n
    }
    $1 == "LOAD" { loads++; a = hex2dec($NF); if (a < min) bad = 1 }
    $1 == "INTERP" { interps++ }
    END {
      if (loads == 0 || bad) exit 1
      if (req_interp == 1 && interps != 1) exit 2
      if (req_interp == 0 && interps != 0) exit 3
    }'
}

publish_artifacts() {
  local rel
  mkdir -p "$OUT_DIR"
  for rel in "${TARGETS[@]}"; do
    if [ -f "$OUT_DIR/$rel" ]; then
      mkdir -p "$(dirname "$BACKUP_DIR/$rel")"
      cp -p "$OUT_DIR/$rel" "$BACKUP_DIR/$rel"
    fi
  done

  PUBLISH_ACTIVE=1
  for rel in "${TARGETS[@]}"; do
    cp -p "$STAGE_DIR/$rel" "$OUT_DIR/$rel.staging.$$"
  done
  for rel in "${TARGETS[@]}"; do
    mv -f "$OUT_DIR/$rel.staging.$$" "$OUT_DIR/$rel"
  done
  PUBLISH_ACTIVE=0
}

# Install pinned gomobile/gobind into isolated BUILD_DIR/gobin (preserves existing GOPATH/bin)
GOBIN="$BUILD_DIR/gobin" go install "golang.org/x/mobile/cmd/gomobile@${PINNED_GOMOBILE_COMMIT}"
GOBIN="$BUILD_DIR/gobin" go install "golang.org/x/mobile/cmd/gobind@${PINNED_GOMOBILE_COMMIT}"
export PATH="$BUILD_DIR/gobin:$PATH"
gomobile init

ENGINE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cp -a "$ENGINE_ROOT/engines/xray/source" "$BUILD_DIR/Xray-core"
mkdir -p "$BUILD_DIR/Xray-core/teechplus_bridge"

cat > "$BUILD_DIR/Xray-core/teechplus_bridge/bridge.go" <<'EOF'
package libxray

import (
        "fmt"
        "net"
        "strings"
        "sync"
        "syscall"

        "github.com/sagernet/sing/common/control"
        _ "github.com/xtls/xray-core/main/distro/all"
        "github.com/xtls/xray-core/core"
        "github.com/xtls/xray-core/infra/conf/serial"
        "github.com/xtls/xray-core/transport/internet"
)

type SocketProtector interface {
        Protect(fd int32) bool
}

var (
        instanceMu sync.Mutex
        protectorMu sync.RWMutex
        activeProtector SocketProtector
        runningInstance *core.Instance
        registerOnce sync.Once
        registerErr error
)

func setProtector(p SocketProtector) {
        protectorMu.Lock()
        activeProtector = p
        protectorMu.Unlock()
}

func getProtector() SocketProtector {
        protectorMu.RLock()
        defer protectorMu.RUnlock()
        return activeProtector
}

func protectSocket(network, address string, raw syscall.RawConn) error {
        p := getProtector()
        if p == nil {
                return fmt.Errorf("VPN socket protector is not active")
        }
        return control.Raw(raw, func(fd uintptr) error {
                if fd > uintptr(^uint32(0)>>1) {
                        return fmt.Errorf("socket fd exceeds int32 range")
                }
                if !p.Protect(int32(fd)) {
                        return fmt.Errorf("VpnService.protect(fd) returned false")
                }
                return nil
        })
}

// Protect outbound UDP sockets, but leave loopback UDP listeners
// available for the local client-to-Xray connection.
func protectUDPListener(network, address string, raw syscall.RawConn) error {
        if !strings.HasPrefix(strings.ToLower(network), "udp") {
                return nil
        }
        host, port, err := net.SplitHostPort(address)
        if err != nil || port != "0" {
                return nil
        }
        if strings.EqualFold(host, "localhost") {
                return nil
        }
        if ip := net.ParseIP(host); ip != nil && ip.IsLoopback() {
                return nil
        }
        return protectSocket(network, address, raw)
}

func registerControllers() {
        registerOnce.Do(func() {
                if err := internet.RegisterDialerController(protectSocket); err != nil {
                        registerErr = err
                        return
                }
                if err := internet.RegisterListenerController(protectUDPListener); err != nil {
                        registerErr = err
                }
        })
}

func CoreVersion() string {
        return core.Version()
}

func SupportsSocketProtection() bool {
        return true
}

func TestConfig(jsonConfig string) error {
        _, err := serial.LoadJSONConfig(strings.NewReader(jsonConfig))
        return err
}

func StartInstance(jsonConfig string, socketProtector SocketProtector) error {
        instanceMu.Lock()
        defer instanceMu.Unlock()

        if socketProtector == nil {
                return fmt.Errorf("SocketProtector is required")
        }

        if runningInstance != nil {
                _ = runningInstance.Close()
                runningInstance = nil
        }
        setProtector(nil)

        cfg, err := serial.LoadJSONConfig(strings.NewReader(jsonConfig))
        if err != nil {
                return err
        }

        registerControllers()
        if registerErr != nil {
                return fmt.Errorf("failed to register socket controllers: %w", registerErr)
        }

        setProtector(socketProtector)

        inst, err := core.New(cfg)
        if err != nil {
                setProtector(nil)
                return err
        }
        if err := inst.Start(); err != nil {
                _ = inst.Close()
                setProtector(nil)
                return err
        }

        runningInstance = inst
        return nil
}

func StopInstance() error {
        instanceMu.Lock()
        defer instanceMu.Unlock()

        var err error
        if runningInstance != nil {
                err = runningInstance.Close()
                runningInstance = nil
        }
        setProtector(nil)
        return err
}
EOF

cd "$BUILD_DIR/Xray-core"
go get -tool "golang.org/x/mobile/cmd/gobind@${PINNED_GOMOBILE_COMMIT}"
go get "google.golang.org/genproto@v0.0.0-20250115164207-1a7da9e5054f"

export GODEBUG=gotypesalias=0
export CGO_LDFLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"
gomobile bind -v -androidapi "$ANDROID_API" \
  -target="android/arm64,android/arm,android/amd64" \
  -ldflags="-s -w -checklinkname=0" \
  -o "$STAGE_DIR/libxray.aar" ./teechplus_bridge

unzip -l "$STAGE_DIR/libxray.aar" | grep -q "classes.jar" || { echo "ERROR: Missing classes.jar in libxray.aar" >&2; exit 1; }
mkdir -p "$STAGE_DIR/inspect"
unzip -q "$STAGE_DIR/libxray.aar" "jni/*/libgojni.so" -d "$STAGE_DIR/inspect"

verify_elf "$STAGE_DIR/inspect/jni/arm64-v8a/libgojni.so" "AArch64" 16384 0
verify_elf "$STAGE_DIR/inspect/jni/x86_64/libgojni.so" "Advanced Micro Devices X86-64" 16384 0
verify_elf "$STAGE_DIR/inspect/jni/armeabi-v7a/libgojni.so" "ARM" 4096 0

(cd "$STAGE_DIR" && sha256sum libxray.aar > libxray.aar.sha256)

publish_artifacts

echo "Built $OUT_DIR/libxray.aar (gomobile commit: $PINNED_GOMOBILE_COMMIT)"
cat "$OUT_DIR/libxray.aar.sha256"
