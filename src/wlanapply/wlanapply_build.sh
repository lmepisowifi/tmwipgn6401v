#!/bin/sh
# Cross-compile wlanapply for the RTL9607C (MIPS32r2 big-endian, glibc 2.23) with
# the Realtek msdk toolchain.  No libmib at link time - it is dlopen()ed on device.
#   TC=/msdk-4.8.5-mips-EB-4.4-g2.23-m32ut-190619-cmcc ./wlanapply_build.sh
set -e
TC=${TC:-/msdk-4.8.5-mips-EB-4.4-g2.23-m32ut-190619-cmcc}
HERE=$(cd "$(dirname "$0")" && pwd)
CC="$TC/bin/msdk-linux-gcc"
"$CC" -std=gnu99 -Os -Wall -Wextra -s -o "$HERE/wlanapply" "$HERE/wlanapply.c" -ldl
"$TC/bin/msdk-linux-strip" "$HERE/wlanapply" 2>/dev/null || true
ls -l "$HERE/wlanapply"
