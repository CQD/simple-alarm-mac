#!/bin/sh
# 編譯成 ./bin/alarm（只用系統內建的 Swift 和 AppKit）
set -e
cd "$(dirname "$0")"
mkdir -p bin
swiftc -O alarm.swift -o bin/alarm
echo "built: $(pwd)/bin/alarm"
