#!/bin/bash
# Проверка подключения к Яндексу и Gmail кодом UniMail (без паролей). Лог — в .netcheck.log рядом.
cd "$(dirname "$0")/.."
LOG=".netcheck.log"
{
  echo "=== $(date) ==="
  M=Sources/UniMail/Core
  xcrun swiftc -swift-version 5 -O -o /tmp/unimail-netcheck \
    $M/Models/*.swift $M/Mail/Transport.swift $M/Mail/StreamTransport.swift \
    $M/Mail/IMAP/*.swift $M/Mail/SMTP/*.swift $M/Mail/MIME/*.swift \
    scripts/netcheck/main.swift && /tmp/unimail-netcheck
  echo "=== exit: $? ==="
} 2>&1 | tee "${LOG}"
echo
echo "Окно можно закрыть."
