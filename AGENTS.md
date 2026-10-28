# AGENTS.md

macOS 的無聲視覺鬧鐘 CLI，全部程式碼在 `alarm.swift`。

- Build：`./build.sh` → `bin/alarm`（已 gitignore）
- 限制：只用系統內建的 Swift/AppKit，不加外部套件；不發出任何聲音；不安裝東西到系統
- 架構：每個鬧鐘是一個 detached 背景程序（`alarm __run <id>`），沒有 daemon；狀態檔在 `$TMPDIR/simple-alarm/`
- 驗證：用 `bin/alarm now <訊息>` 觸發；確認螢幕效果時，若 agent 無螢幕錄製權限可要求使用者截圖
- 使用者看到的文字（help、UI、錯誤訊息）用台灣繁體中文
