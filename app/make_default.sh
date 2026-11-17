#!/bin/bash
# 生成"办公默认壁纸"快照：把当前系统墙纸配置存档
BASE="$HOME/Library/Application Support/wallpaper-rotate"
mkdir -p "$BASE"
cp "$HOME/Library/Application Support/com.apple.wallpaper/Store/Index.plist" "$BASE/office.plist"
echo "已存档当前壁纸为办公默认：$(date '+%F %T')"
