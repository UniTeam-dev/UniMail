#!/bin/bash
# Сборка UniMail.app из SwiftPM-таргета.
#
#   ./scripts/build.sh          — release
#   ./scripts/build.sh debug    — debug
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${ROOT}/dist/UniMail.app"
# По умолчанию используем тот же самоподписанный сертификат, что и NotchApp:
# стабильная подпись = Keychain не спрашивает пароль после каждой пересборки.
CERT_NAME="${UNIMAIL_CERT:-NotchApp Dev}"

cd "${ROOT}"

pkill -x UniMail 2>/dev/null || true

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN="$(swift build -c "${CONFIG}" --show-bin-path)/UniMail"
if [ ! -f "${BIN}" ]; then
  echo "не нашёл собранный бинарь: ${BIN}" >&2
  exit 1
fi

echo "==> собираю бандл"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/UniMail"
cp "${ROOT}/Resources/Info.plist" "${APP}/Contents/Info.plist"
if [ -f "${ROOT}/Resources/AppIcon.icns" ]; then
  cp "${ROOT}/Resources/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"
fi

if security find-identity -v -p codesigning | grep -q "${CERT_NAME}"; then
  echo "==> подписываю как «${CERT_NAME}»"
  codesign --force --options runtime \
    --entitlements "${ROOT}/Resources/UniMail.entitlements" \
    --sign "${CERT_NAME}" "${APP}"
else
  echo "!! сертификат «${CERT_NAME}» не найден — подписываю ad-hoc."
  echo "!! Keychain может спрашивать доступ после каждой пересборки."
  codesign --force --sign - "${APP}"
fi

echo "==> готово: ${APP}"
