#!/bin/bash
# Проверки ядра UniMail без Mac: IMAP, MIME/SMTP/ICS, SQLite, автоматизация, редактор, провайдер, MailStore.
# Нужен swiftc (Linux или macOS). Пример: SWIFTC=/path/to/swiftc scripts/linux-checks.sh
set -u
cd "$(dirname "$0")/.."
SWIFTC="${SWIFTC:-swiftc}"
OUT="$(mktemp -d)"
FAILED=0
M=Sources/UniMail/Core

run() {
    local name="$1"; shift
    printf '== %-10s ' "$name"
    if ! "$SWIFTC" -swift-version 5 "$@" -o "$OUT/$name" > "$OUT/$name.build" 2>&1; then
        echo "BUILD FAILED"; grep error "$OUT/$name.build" | head -20; FAILED=1; return
    fi
    local home; home="$(mktemp -d)"
    if (cd "$home" && HOME="$home" "$OUT/$name" > "$OUT/$name.log" 2>&1); then
        tail -1 "$OUT/$name.log"
    else
        echo "FAILED"; grep -E "FAIL" "$OUT/$name.log" | head -20; FAILED=1
    fi
}

DB="-I Tests/LinuxChecks/Database"
run imap       $M/Models/*.swift $M/Mail/Transport.swift $M/Mail/IMAP/*.swift Tests/LinuxChecks/IMAP/main.swift
run mime       $M/Models/*.swift $M/Mail/Transport.swift $M/Mail/MIME/*.swift $M/Mail/SMTP/*.swift $M/Mail/ICS/*.swift Tests/LinuxChecks/MIME/*.swift
run database   $DB $M/Models/*.swift $M/Store/Database/*.swift Tests/LinuxChecks/Database/main.swift
run automation $M/Models/*.swift $M/Automation/*.swift Tests/LinuxChecks/Automation/main.swift
run richtext   Sources/UniMail/UI/Compose/RichTextModel.swift Tests/LinuxChecks/RichText/main.swift
run provider   $DB $M/Models/*.swift $M/Mail/*.swift $M/Mail/*/*.swift $M/Store/Database/*.swift $M/Providers/*.swift $M/Render/*.swift Tests/LinuxChecks/Provider/*.swift
run ews        $DB $M/Models/*.swift $M/Mail/*.swift $M/Mail/*/*.swift $M/Store/Database/*.swift $M/Providers/*.swift $M/Render/*.swift Tests/LinuxChecks/EWS/main.swift
run store      $DB $M/Models/*.swift $M/Mail/*.swift $M/Mail/*/*.swift $M/Store/Database/*.swift $M/Providers/*.swift $M/Render/*.swift \
               $M/Automation/*.swift $M/Store/*.swift Tests/LinuxChecks/Provider/FakeServers.swift Tests/LinuxChecks/Store/*.swift

rm -rf "$OUT"
exit $FAILED
