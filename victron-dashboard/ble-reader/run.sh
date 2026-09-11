#!/bin/bash
cd "$(dirname "$0")/.."
while true; do
  python3 ble-reader/reader.py
  status=$?
  # Clean Ctrl+C / SIGTERM — don't respawn
  if [ "$status" -eq 0 ] || [ "$status" -eq 130 ] || [ "$status" -eq 143 ]; then
    exit "$status"
  fi
  echo "BLE reader exited ($status), restarting in 5s..."
  sleep 5
done
