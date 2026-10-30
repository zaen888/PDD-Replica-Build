#!/bin/sh
set -eu
cd "$(dirname "$0")"
if [ -z "${THEOS:-}" ]; then
  if [ -d "$HOME/theos" ]; then export THEOS="$HOME/theos"; fi
fi
if [ -z "${THEOS:-}" ] || [ ! -f "$THEOS/makefiles/common.mk" ]; then
  echo "ERROR: 找不到 Theos。請先安裝 Theos 並設定 THEOS 環境變數。" >&2
  exit 2
fi
if ! command -v make >/dev/null 2>&1; then
  echo "ERROR: 找不到 make。" >&2
  exit 2
fi
echo "Theos: $THEOS"
echo "Building package; this validates compiler/SDK compatibility but does not replace device testing."
make clean package
