#!/bin/bash
cd "$(dirname "$0")/.."
exec python3 ble-reader/reader.py
