#!/bin/bash
# 간담회 기록 도우미 - 맥미니 전사 서버 설치 (관리자 암호 불필요)
#   사용: bash install.sh            설치/업데이트
#   설치 위치: ~/MeetNoteServer  (엔진·모델·서버·기록 백업)
set -euo pipefail

WHISPER_SHA="79b11911d9d38c4be2fc7dc8b4efeff3324c090f"      # 이 버전으로 한국어 전사를 시험함
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"
MODEL_SIZE=574041195
VAD_URL="https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin"
VAD_SIZE=885098
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/MeetNoteServer"
LA="$HOME/Library/LaunchAgents"
UIDN="$(id -u)"

say(){ printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
die(){ printf '\n\033[31m✖ %s\033[0m\n' "$*" >&2; exit 1; }

say "1/7 맥 환경 확인"
[ "$(uname -s)" = "Darwin" ] || die "맥(macOS)에서만 실행할 수 있습니다."
[ "$(uname -m)" = "arm64" ] || die "애플 실리콘(M 칩) 맥이 필요합니다."
if ! xcode-select -p >/dev/null 2>&1; then
  xcode-select --install >/dev/null 2>&1 || true
  die "개발 도구(Command Line Tools) 설치 창이 떴습니다. 설치를 마친 뒤 이 스크립트를 다시 실행해 주세요."
fi
command -v python3 >/dev/null || die "python3가 없습니다. 개발 도구 설치를 확인해 주세요."
mkdir -p "$APP"/{bin,models,logs,data,src} "$LA"
echo "   설치 위치: $APP"

say "2/7 빌드 도구(cmake) 준비"
if command -v cmake >/dev/null 2>&1; then CMAKE="$(command -v cmake)"
else
  [ -x "$APP/venv/bin/cmake" ] || { python3 -m venv "$APP/venv" && "$APP/venv/bin/pip" install -q --upgrade pip && "$APP/venv/bin/pip" install -q cmake; }
  CMAKE="$APP/venv/bin/cmake"
fi
echo "   $("$CMAKE" --version | head -1)"

say "3/7 위스퍼 엔진 빌드 (애플 칩 그래픽 가속 사용, 수 분 소요)"
if [ ! -x "$APP/bin/whisper-server" ] || [ "$(cat "$APP/bin/.sha" 2>/dev/null)" != "$WHISPER_SHA" ]; then
  rm -rf "$APP/src/whisper.cpp" && mkdir -p "$APP/src/whisper.cpp"
  ( cd "$APP/src/whisper.cpp" && git init -q && git remote add origin https://github.com/ggml-org/whisper.cpp.git &&
    git fetch -q --depth 1 origin "$WHISPER_SHA" && git checkout -q FETCH_HEAD )
  ( cd "$APP/src/whisper.cpp" &&
    "$CMAKE" -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_SERVER=ON -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON >/dev/null &&
    "$CMAKE" --build build -j "$(sysctl -n hw.ncpu)" --target whisper-server >/dev/null )
  cp "$APP/src/whisper.cpp/build/bin/whisper-server" "$APP/bin/whisper-server"
  echo "$WHISPER_SHA" > "$APP/bin/.sha"
fi
echo "   엔진 준비됨: $APP/bin/whisper-server"

say "4/7 모델 받기 (한국어 고성능 모델 약 550MB, 처음 한 번)"
get(){ local url="$1" out="$2" size="$3"
  if [ -f "$out" ] && [ "$(stat -f%z "$out")" = "$size" ]; then echo "   있음: $(basename "$out")"; return; fi
  curl -fL --retry 5 -C - -o "$out" "$url" || curl -fL --retry 5 -o "$out" "$url"
  [ "$(stat -f%z "$out")" = "$size" ] || die "모델 파일 크기가 맞지 않습니다: $out (다시 실행해 주세요)"; }
get "$MODEL_URL" "$APP/models/ggml-large-v3-turbo-q5_0.bin" "$MODEL_SIZE"
get "$VAD_URL" "$APP/models/ggml-silero-v6.2.0.bin" "$VAD_SIZE"

say "5/7 안내 서버 설치·접속 키 만들기"
cp "$HERE/meetnote_server.py" "$APP/meetnote_server.py"
TOKEN="$(MEETNOTE_HOME="$APP" /usr/bin/python3 "$APP/meetnote_server.py" --show-token)"
cat > "$APP/run-whisper.sh" <<EOF
#!/bin/bash
# 위스퍼 엔진 실행(설정 바꾸려면 이 파일 수정 후: launchctl kickstart -k gui/$UIDN/kr.meetnote.whisper)
exec "$APP/bin/whisper-server" -m "$APP/models/ggml-large-v3-turbo-q5_0.bin" --host 127.0.0.1 --port 8178 -l ko -nf --vad -vm "$APP/models/ggml-silero-v6.2.0.bin"
EOF
chmod +x "$APP/run-whisper.sh"

say "6/7 맥이 켜지면 자동 실행되도록 등록"
plist(){ local label="$1" cmd="$2" log="$3"
  cat > "$LA/$label.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>-c</string><string>$cmd</string></array>
  <key>EnvironmentVariables</key><dict><key>MEETNOTE_HOME</key><string>$APP</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$APP/logs/$log.log</string>
  <key>StandardErrorPath</key><string>$APP/logs/$log.log</string>
</dict></plist>
EOF
  launchctl bootout "gui/$UIDN/$label" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$UIDN" "$LA/$label.plist"; }
plist kr.meetnote.whisper "exec '$APP/run-whisper.sh'" whisper
plist kr.meetnote.server "exec /usr/bin/python3 '$APP/meetnote_server.py'" server
printf '   엔진 준비 확인 중'
for _ in $(seq 1 90); do
  if curl -fs http://127.0.0.1:8765/health 2>/dev/null | grep -q '"engineReady": true'; then echo " → 준비됨"; break; fi
  printf '.'; sleep 2
done
curl -fs http://127.0.0.1:8765/health | grep -q '"engineReady": true' || die "서버가 준비되지 않았습니다. 기록 확인: $APP/logs/"

say "7/7 iPad에서 접속할 수 있도록 연결(Tailscale)"
TS=""
for c in tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale; do command -v "$c" >/dev/null 2>&1 && { TS="$c"; break; }; [ -x "$c" ] && { TS="$c"; break; }; done
URL=""
if [ -n "$TS" ] && "$TS" status >/dev/null 2>&1; then
  "$TS" serve --bg 8765 >/dev/null 2>&1 || "$TS" serve --bg http://127.0.0.1:8765 >/dev/null 2>&1 || true
  DNS="$("$TS" status --json 2>/dev/null | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null || true)"
  [ -n "$DNS" ] && URL="https://$DNS"
fi

SHOWURL="${URL:-(Tailscale 연결 후 표시됩니다 — 아래 안내 참고)}"
cat <<EOF

============================================================
 ✅ 맥미니 전사 서버 설치 완료
------------------------------------------------------------
 앱 ⚙ 설정 → '🖥 맥미니 서버'에 아래 두 가지를 넣으세요.
   서버 주소 : $SHOWURL
   접속 키   : $TOKEN
------------------------------------------------------------
EOF
if [ -z "$URL" ]; then cat <<'EOF'
 [남은 일: Tailscale 연결]
   1) 맥미니: App Store에서 'Tailscale' 설치 → 로그인
   2) iPad : App Store에서 'Tailscale' 설치 → 같은 계정으로 로그인
   3) 관리 화면(login.tailscale.com/admin/dns)에서 MagicDNS와 HTTPS Certificates 켜기
   4) 이 스크립트를 한 번 더 실행하면 서버 주소가 표시됩니다.
EOF
fi
cat <<EOF
 [24시간 운영 권장 설정] 시스템 설정 → 에너지:
   '디스플레이가 꺼져 있을 때 자동으로 잠자기 방지' 켜기, '정전 후 자동으로 시동' 켜기
 기록 백업 위치: $APP/data     로그: $APP/logs
============================================================
EOF
