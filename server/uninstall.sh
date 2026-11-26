#!/bin/bash
# 맥미니 전사 서버 끄기·제거 (기록 백업 폴더는 남김)
UIDN="$(id -u)"; LA="$HOME/Library/LaunchAgents"
for l in kr.meetnote.server kr.meetnote.whisper; do
  launchctl bootout "gui/$UIDN/$l" >/dev/null 2>&1 || true
  rm -f "$LA/$l.plist"
done
for c in tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
  if command -v "$c" >/dev/null 2>&1 || [ -x "$c" ]; then "$c" serve reset >/dev/null 2>&1 || true; break; fi
done
echo "서버를 껐고 자동 실행을 해제했습니다."
echo "엔진·모델을 지우려면: rm -rf ~/MeetNoteServer/bin ~/MeetNoteServer/models ~/MeetNoteServer/src ~/MeetNoteServer/venv"
echo "기록 백업(~/MeetNoteServer/data)은 그대로 두었습니다."
