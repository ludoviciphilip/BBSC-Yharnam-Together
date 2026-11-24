#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# The Linux release: the port, its launcher (Python + Tk, run from source), shadnet and the backend
# in one folder, packed as YharnamTogether-<version>-linux-x86_64.tar.gz. The Windows release's
# counterpart (tools/make-release.ps1): the same layout, so the launcher sees a co-op install.
#
#   tools/make-release-linux.sh -v 1.5.1 [-g <game>/CUSA03173 | -r <Windows release zip>]
#                               [-o out/release-linux] [--skip-port-build] [--skip-server-build]
#                               [--no-fsr4]
#
# The binaries link the system's libraries (SDL3, FFmpeg, protobuf, Qt 6.8+ ...), so the package
# runs on the distribution it was built on and those close to it (built on Arch: Arch, CachyOS,
# EndeavourOS, Manjaro after its next sync). docs/LINUX.md lists the packages.
#
# event-reference.json (the tested event files' hashes, which setup compares the player's with)
# is made from a game folder with -g, as make-release.ps1 does, or taken from the Windows release
# of the same version with -r. Without either the release has none and setup cannot tell players
# whether their event files match.
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
version='' game='' winzip='' out="$root/out/release-linux" port_build=1 server_build=1 fsr4=1
while (($#)); do
    case $1 in
        -v|--version) version=${2#v}; shift 2 ;;
        -g|--game-dir) game=$2; shift 2 ;;
        -r|--release-zip) winzip=$2; shift 2 ;;
        -o|--out) out=$2; shift 2 ;;
        --skip-port-build) port_build=0; shift ;;
        --skip-server-build) server_build=0; shift ;;
        --no-fsr4) fsr4=0; shift ;;
        -h|--help) sed -n '3,18p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || { echo 'Give the version: -v 1.5.1' >&2; exit 2; }
tag="v$version"
name="YharnamTogether-$tag-linux-x86_64"
step() { printf '\n== %s\n' "$*"; }

for tool in clang cmake ninja python3 tar sha256sum; do
    command -v "$tool" >/dev/null || { echo "Need $tool (docs/LINUX.md)." >&2; exit 1; }
done
python3 -c 'import tkinter' 2>/dev/null || echo 'Warning: no Tk for python3 here (package tk): the launcher needs it to run.' >&2

bbport="$root/bbport"
if ((port_build)); then
    step "Port ($tag, production)"
    (cd "$bbport" && CC=${CC:-clang} CXX=${CXX:-clang++} BB_PRODUCTION=1 BB_RELEASE_VERSION="$tag" bash build.sh)
fi
for need in out/bb-probe out/bb-gpu-capabilities out/gpu/libbbgpu.so; do
    [[ -f $bbport/$need ]] || { echo "Missing bbport/$need (build it, or drop --skip-port-build)." >&2; exit 1; }
done
[[ $(cat "$bbport/out/build-mode.txt" 2>/dev/null) == production ]] ||
    echo 'Warning: the port is a dev build (cheats and debug tools): a release is BB_PRODUCTION=1.' >&2

server_out="$root/out/release-linux-server"
if ((server_build)); then
    step 'Server (shadnet)'
    git -C "$root" submodule update --init --depth 1 server/externals/protobuf
    cmake -S "$root/server" -B "$server_out" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
        -DCMAKE_C_COMPILER="${CC:-clang}" -DCMAKE_CXX_COMPILER="${CXX:-clang++}" -Wno-dev >/dev/null
    ninja -C "$server_out" shadnet
fi
[[ -x $server_out/shadnet ]] || { echo "Missing $server_out/shadnet (drop --skip-server-build)." >&2; exit 1; }

# zlib's own library for the event patcher (bbport_coop.zlib_folder): Arch's libz.so.1 is zlib-ng,
# whose deflate makes event files that differ from the Windows release's byte for byte.
zlib_version=1.3.2
zlib_sha256=bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16
zlib_out="$root/out/release-linux-zlib"
if [[ ! -f $zlib_out/libz.so.1 ]]; then
    step "zlib $zlib_version (for the event files)"
    mkdir -p "$zlib_out/src"
    tarball="$zlib_out/zlib-$zlib_version.tar.gz"
    [[ -f $tarball ]] || curl -fsSL -o "$tarball" "https://github.com/madler/zlib/releases/download/v$zlib_version/zlib-$zlib_version.tar.gz"
    echo "$zlib_sha256  $tarball" | sha256sum -c --quiet
    tar -C "$zlib_out/src" --strip-components=1 -xzf "$tarball"
    (cd "$zlib_out/src" && CC=${CC:-clang} CFLAGS=-O2 ./configure --shared >/dev/null && make -s libz.so.$zlib_version)
    cp -L "$zlib_out/src/libz.so.$zlib_version" "$zlib_out/libz.so.1"
fi

if ((fsr4)); then
    step 'FSR 4 shaders (v07, MIT, as the Windows release ships them)'
    bash "$bbport/tools/fetch_fsr4_assets.sh"
fi

step 'Assemble'
release="$out/stage/$name"
rm -rf -- "$out/stage"
mkdir -p "$release"/{bin/gpu,launcher,tools,server,backend,licenses}
cp "$bbport/out/bb-probe" "$bbport/out/bb-gpu-capabilities" "$release/bin/"
cp "$bbport/out/gpu/libbbgpu.so" "$release/bin/gpu/"   # bb-probe's rpath: $ORIGIN/gpu
mkdir -p "$release/bin/zlib" && cp "$zlib_out/libz.so.1" "$release/bin/zlib/"
# The DLSS bridge and NVIDIA's libraries when build.sh copied them (DLSS_SDK_ROOT).
for lib in "$bbport"/out/libbbport_dlss.so "$bbport"/out/libnvidia-ngx-dlss*.so.*; do
    if [[ -f $lib ]]; then cp "$lib" "$release/bin/"; fi
done
cp "$bbport"/launcher/*.py "$bbport"/launcher/bloodborne.png "$bbport"/launcher/bloodborne.ico "$release/launcher/"
cp -r "$bbport/launcher/art" "$release/launcher/"
cp -r "$bbport/scripts" "$bbport/patches" "$release/"
if [[ -d $bbport/fsr4_shaders ]]; then cp -r "$bbport/fsr4_shaders" "$release/"; fi
if [[ -d $bbport/shader_packs ]]; then cp -r "$bbport/shader_packs" "$release/"; fi
cp "$bbport/run.py" "$bbport/run.sh" "$bbport/LICENSE" "$release/"
cp "$root/README.md" "$release/README.md"
cp "$root/docs/LINUX.md" "$release/README-Linux.md"
cp "$bbport/tools/legacy-cpu-plan.json" "$root/tools/re/party_boss_events.py" "$release/tools/"
find "$release/launcher" "$release/scripts" -name __pycache__ -prune -exec rm -rf {} +

# The release kit (CREDITS, the Qt licences, the server's cfg) with LF endings. READ ME FIRST is
# the Windows setup's; README-Linux.md is this package's.
kit="$root/tools/release/kit"
while IFS= read -r -d '' file; do
    rel=${file#"$kit"/}
    [[ $rel == 'READ ME FIRST.txt' ]] && continue
    mkdir -p "$release/$(dirname "$rel")"
    sed 's/\r$//' "$file" > "$release/$rel"
done < <(find "$kit" -type f -print0)
cp "$root/emulator/LICENSES/GPL-2.0-or-later.txt" "$release/licenses/"
sed -n '/^Copyright notice/,$p' "$zlib_out/src/README" > "$release/licenses/zlib-LICENSE.txt"
cp "$server_out/shadnet" "$release/server/"
cp "$root/server/worlds.cfg" "$root/server/scoreboards.cfg" "$release/server/"
if [[ ! -f $release/server/shadnet.cfg ]]; then
    printf '[General]\nHost=0.0.0.0\nUnsecuredPort=31313\nMatchingUdpPort=31314\nWebApiPort=31315\nStatsEnabled=false\nMatching2Enabled=true\nBloodborneSeamlessCoop=true\nBloodborneBackend=true\nBackendPort=20443\nBackendAddress=\nBackendFolder=../backend\n' \
        > "$release/server/shadnet.cfg"
fi
cp "$root"/backend/*.py "$root/backend/ss_info_template.xml" "$root/backend/README.txt" "$release/backend/"
: > "$release/backend/notice.txt"

step 'event-reference.json'
if [[ -n $game ]]; then
    events="$game/dvdroot_ps4/event"
    [[ -f $events/common.emevd.dcx ]] || { echo "No $events/common.emevd.dcx (-g is the CUSA03173 folder with 1.09)." >&2; exit 1; }
    made="$out/event-check"
    rm -rf -- "$made"
    LD_LIBRARY_PATH="$release/bin/zlib" python3 "$release/tools/party_boss_events.py" "$made" "$events" > "$out/event-check.log" 2>&1 ||
        { tail -10 "$out/event-check.log" >&2; echo 'The event patcher failed.' >&2; exit 1; }
    python3 - "$made/manifest.json" "$release/event-reference.json" <<'EOF'
import json, sys
manifest = json.load(open(sys.argv[1], encoding='utf-8'))
files = {name: {'input_sha256': f['input_sha256'], 'output_sha256': f['output_sha256']}
         for name, f in sorted(manifest['files'].items())}
open(sys.argv[2], 'w', encoding='utf-8', newline='\n').write(json.dumps({'files': files}, indent=4) + '\n')
print(f'  {len(files)} event files from the game')
EOF
    rm -rf -- "$made"
elif [[ -n $winzip ]]; then
    python3 - "$winzip" "$release/event-reference.json" "$tag" <<'EOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    names = z.namelist()
    ref = next(n for n in names if n.endswith('/event-reference.json') or n == 'event-reference.json')
    ver = next((n for n in names if n.endswith('/VERSION.txt')), None)
    if ver and sys.argv[3] not in z.read(ver).decode('utf-8', 'replace').splitlines()[0]:
        sys.exit(f'{sys.argv[1]} is not the {sys.argv[3]} release')
    open(sys.argv[2], 'wb').write(z.read(ref).replace(b'\r\n', b'\n'))
print(f'  taken from {sys.argv[1]}')
EOF
else
    echo '  No -g or -r: the release has no event-reference.json, so setup cannot tell players whether their event files match.' >&2
fi

commit=$(git -C "$root" rev-parse HEAD)
dirty=$(git -C "$root" status --porcelain --untracked-files=no -- . ':!bbport/gpu/third_party' | head -1)
{
    echo "Yharnam Together: Bloodborne Seamless Co-op $tag (Linux, Bloodborne PC native port)"
    echo "Commit: $commit${dirty:+ + uncommitted changes (test build)}"
    echo "Built: $(date -u '+%Y-%m-%d %H:%M UTC')"
    echo 'Game: Bloodborne 1.09 (tested with CUSA03173)'
    echo 'Source: https://github.com/Amanises-Yharnam-Together/BBSC-Yharnam-Together'
} > "$release/VERSION.txt"

cat > "$release/Yharnam-Together.sh" <<'EOF'
#!/bin/sh
# Starts the launcher (Python 3 + Tk). The game, the co-op page and the host's servers are in it.
cd -- "$(dirname -- "$0")" || exit 1
if ! python3 -c 'import tkinter' 2>/dev/null; then
    msg='Python 3 with Tk is needed (Arch: sudo pacman -S python tk). See README-Linux.md.'
    echo "$msg" >&2
    command -v notify-send >/dev/null && notify-send 'Yharnam Together' "$msg"
    exit 1
fi
python3 launcher/bbport_launcher_win.py "$@"
code=$?
if [ "$code" -ne 0 ]; then
    echo "The launcher stopped (exit $code): see user/log/launcher-errors.txt" >&2
    tail -5 user/log/launcher-errors.txt 2>/dev/null >&2
fi
exit $code
EOF
cat > "$release/install-desktop.sh" <<'EOF'
#!/bin/sh
# Adds Yharnam Together to the application menu (this folder stays where it is).
here=$(cd -- "$(dirname -- "$0")" && pwd)
apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$apps"
cat > "$apps/yharnam-together.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Yharnam Together
GenericName=Bloodborne Seamless Co-op
Exec="$here/Yharnam-Together.sh"
Path=$here
Icon=$here/launcher/bloodborne.png
Terminal=false
Categories=Game;
StartupWMClass=Tk
DESKTOP
echo "Added $apps/yharnam-together.desktop"
EOF
chmod +x "$release/Yharnam-Together.sh" "$release/install-desktop.sh" "$release/run.sh"

step 'Check'
missing=$(cd "$release/bin" && ldd ./bb-probe ./gpu/libbbgpu.so ../server/shadnet 2>/dev/null | grep 'not found' | sort -u || true)
[[ -z $missing ]] || { echo "Libraries not found:"; echo "$missing"; exit 1; } >&2
grep -q '^Yharnam Together: .* v' "$release/VERSION.txt"

step 'Pack'
mkdir -p "$out"
tar -C "$out/stage" -czf "$out/$name.tar.gz" "$name"
(cd "$out" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")
du -h "$out/$name.tar.gz" | cut -f1 | sed "s|^|  $out/$name.tar.gz: |"
