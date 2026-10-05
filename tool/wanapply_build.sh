#!/bin/sh
# Cross-compile wanapply for the RTL9607C (MIPS big-endian, uClibc) with the
# Realtek msdk toolchain.  No libmib at link time — it is dlopen()ed on device.
#   TC=/msdk-4.8.5-mips-EB-4.4-g2.23-m32ut-190619-cmcc ./build.sh
set -e
TC=${TC:-/msdk-4.8.5-mips-EB-4.4-g2.23-m32ut-190619-cmcc}
HERE=$(cd "$(dirname "$0")" && pwd)
CC="$TC/bin/msdk-linux-gcc"
"$CC" -Os -Wall -Wextra -s -o "$HERE/wanapply" "$HERE/wanapply.c" -ldl
"$TC/bin/msdk-linux-strip" "$HERE/wanapply" 2>/dev/null || true
ls -l "$HERE/wanapply"
