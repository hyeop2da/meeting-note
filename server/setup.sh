#!/bin/bash
# 맥미니 터미널에서 한 줄로 설치:
#   curl -fsSL https://hyeop2da.github.io/meeting-note/server/setup.sh | bash
set -euo pipefail
BASE="https://hyeop2da.github.io/meeting-note/server"
D="$(mktemp -d)"
for f in install.sh uninstall.sh meetnote_server.py; do
  curl -fsSL "$BASE/$f" -o "$D/$f"
done
bash "$D/install.sh"
cp "$D/uninstall.sh" "$HOME/MeetNoteServer/uninstall.sh"
echo "끄거나 제거하려면: bash ~/MeetNoteServer/uninstall.sh"
