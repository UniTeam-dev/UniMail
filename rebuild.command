#!/bin/bash
# Пересобрать и перезапустить UniMail. Лог — в .rebuild.log рядом.
cd "$(dirname "$0")"
LOG=".rebuild.log"
{
  echo "=== $(date) ==="
  ./scripts/build.sh release
  STATUS=$?
  echo "=== build exit: ${STATUS} ==="
  if [ ${STATUS} -eq 0 ]; then
    open dist/UniMail.app && echo "=== launched ==="
  fi
} 2>&1 | tee "${LOG}"
echo
echo "Окно можно закрыть."
