#!/usr/bin/env python3
"""간담회 기록 도우미 - 맥미니 전사 서버 (파이썬 표준 라이브러리만 사용)

역할
  - 웹앱(iPad)에서 보낸 음성(16kHz WAV)을 로컬 위스퍼 엔진(whisper.cpp 서버)으로 전사
  - 접속 키 확인, 허용된 웹앱 주소만 응답(CORS), 무음·흔한 엉뚱한 문장 거르기
  - 회의 기록·녹음 백업 저장

엔드포인트
  GET  /health                       상태(접속 키 불필요)
  GET  /check                        접속 키 확인
  POST /transcribe?prompt=...        본문: audio/wav  → {text, segments, ms, rms}
  POST /backup?sid=...&name=...      본문: 파일 내용   → 데이터 폴더/sid/name 에 저장
"""
import json, os, re, secrets, struct, sys, time, urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "1.0.0"
HOME = os.path.expanduser("~")
BASE = os.environ.get("MEETNOTE_HOME", os.path.join(HOME, "MeetNoteServer"))
CONFIG_PATH = os.path.join(BASE, "config.json")
DEFAULT_CONFIG = {
    "port": 8765,                                   # 이 서버(127.0.0.1에서만 받음, 외부는 Tailscale이 https로 연결)
    "whisper_url": "http://127.0.0.1:8178/inference",
    "token": "",
    "data_dir": os.path.join(BASE, "data"),
    "allow_origins": ["https://hyeop2da.github.io", "null", "http://localhost", "http://127.0.0.1"],
    "silence_rms": 0.003,                           # 이보다 작으면 무음으로 보고 전사하지 않음
    "quiet_rms": 0.02,                              # 이보다 작은데 흔한 엉뚱한 문장만 나오면 버림
    "max_upload_mb": 200,
}
# 위스퍼가 무음·잡음 구간에 자주 지어내는 문장(전체가 이것뿐일 때만, 소리가 작을 때만 버림)
HALLUCINATIONS = [
    "감사합니다", "시청해 주셔서 감사합니다", "시청해주셔서 감사합니다", "구독과 좋아요 부탁드립니다", "구독과 좋아요",
    "다음 영상에서 만나요", "자막 제공 및 자막 편집", "자막 제공", "mbc 뉴스", "kbs 뉴스", "sbs 뉴스", "고맙습니다", "네", "음",
]

def load_config():
    os.makedirs(BASE, exist_ok=True)
    cfg = dict(DEFAULT_CONFIG)
    if os.path.exists(CONFIG_PATH):
        with open(CONFIG_PATH, encoding="utf-8") as f:
            cfg.update(json.load(f))
    if not cfg.get("token"):
        cfg["token"] = secrets.token_urlsafe(18)    # 처음 실행 시 접속 키 생성
        with open(CONFIG_PATH, "w", encoding="utf-8") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2)
        os.chmod(CONFIG_PATH, 0o600)
    os.makedirs(cfg["data_dir"], exist_ok=True)
    return cfg

CFG = load_config()

def wav_rms(data):
    """16bit PCM WAV의 소리 크기(0~1). 형식이 다르면 None."""
    try:
        if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
            return None
        i = 12
        while i + 8 <= len(data):
            cid, size = data[i:i + 4], struct.unpack("<I", data[i + 4:i + 8])[0]
            if cid == b"data":
                pcm = data[i + 8:i + 8 + size]
                n = len(pcm) // 2
                if n == 0:
                    return 0.0
                step = max(1, n // 40000)               # 큰 파일은 표본만
                vals = struct.unpack("<%dh" % n, pcm[:n * 2])[::step]
                return (sum(v * v for v in vals) / len(vals)) ** 0.5 / 32768
            i += 8 + size + (size & 1)
    except Exception:
        return None
    return None

def norm(t):
    return re.sub(r"[\s.,!?~·…'\"]+", "", t or "").lower()

HALL_SET = {norm(h) for h in HALLUCINATIONS}

def multipart(fields, file_field, filename, content, ctype):
    boundary = "----meetnote" + secrets.token_hex(8)
    out = []
    for k, v in fields.items():
        out.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode())
    out.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{file_field}\"; filename=\"{filename}\"\r\nContent-Type: {ctype}\r\n\r\n".encode())
    out.append(content)
    out.append(f"\r\n--{boundary}--\r\n".encode())
    return b"".join(out), f"multipart/form-data; boundary={boundary}"

def whisper(data, prompt):
    fields = {"language": "ko", "response_format": "verbose_json", "temperature": "0.0"}
    if prompt:
        fields["prompt"] = prompt[:400]
    body, ctype = multipart(fields, "file", "audio.wav", data, "audio/wav")
    req = urllib.request.Request(CFG["whisper_url"], data=body, headers={"Content-Type": ctype}, method="POST")
    with urllib.request.urlopen(req, timeout=180) as r:
        return json.loads(r.read().decode("utf-8"))

def safe_name(s, default):
    s = re.sub(r"[^0-9A-Za-z가-힣._-]", "_", s or "")[:80].strip("._")
    return s or default

class H(BaseHTTPRequestHandler):
    server_version = "MeetNoteServer/" + VERSION

    def log_message(self, fmt, *args):            # 회의 내용은 기록하지 않음(요청 종류만)
        sys.stderr.write("%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), fmt % args))

    def cors(self):
        origin = self.headers.get("Origin", "")
        allowed = CFG["allow_origins"]
        if origin and (origin in allowed or any(origin.startswith(a) for a in allowed if a.startswith("http://"))):
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")
            self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Max-Age", "600")

    def reply(self, code, obj):
        b = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code); self.cors()
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)

    def authed(self):
        a = self.headers.get("Authorization", "")
        return a.startswith("Bearer ") and secrets.compare_digest(a[7:].strip(), CFG["token"])

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > CFG["max_upload_mb"] * 1048576:
            raise ValueError("파일이 너무 큽니다")
        return self.rfile.read(n) if n > 0 else b""

    def do_OPTIONS(self):
        self.send_response(204); self.cors(); self.send_header("Content-Length", "0"); self.end_headers()

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path == "/health":
            ok = True
            try:
                urllib.request.urlopen(CFG["whisper_url"].rsplit("/", 1)[0] + "/", timeout=3).read(1)
            except Exception:
                ok = False
            return self.reply(200, {"ok": True, "service": "meetnote", "version": VERSION, "engine": "whisper.cpp", "engineReady": ok})
        if u.path == "/check":
            return self.reply(200 if self.authed() else 401, {"ok": self.authed()})
        return self.reply(404, {"error": "없는 주소"})

    def do_POST(self):
        u = urllib.parse.urlparse(self.path); q = urllib.parse.parse_qs(u.query)
        if not self.authed():
            return self.reply(401, {"error": "접속 키가 맞지 않습니다"})
        try:
            data = self.body()
        except ValueError as e:
            return self.reply(413, {"error": str(e)})
        if u.path == "/transcribe":
            t0 = time.time(); rms = wav_rms(data)
            if rms is None:
                return self.reply(400, {"error": "16비트 WAV 음성만 받습니다"})
            if rms < CFG["silence_rms"]:
                return self.reply(200, {"text": "", "segments": [], "ms": 0, "rms": rms, "skipped": "silence"})
            try:
                r = whisper(data, (q.get("prompt") or [""])[0])
            except Exception as e:
                return self.reply(502, {"error": "전사 엔진 오류: %s" % e})
            segs = []
            for s in r.get("segments", []):
                t = (s.get("text") or "").strip()
                if not t:
                    continue
                if norm(t) in HALL_SET and rms < CFG["quiet_rms"]:
                    continue                          # 작은 소리에서 나온 흔한 엉뚱한 문장
                segs.append({"start": round(float(s.get("start", 0)), 2), "end": round(float(s.get("end", 0)), 2), "text": t})
            return self.reply(200, {"text": " ".join(s["text"] for s in segs), "segments": segs, "ms": int((time.time() - t0) * 1000), "rms": round(rms, 4)})
        if u.path == "/backup":
            sid = safe_name((q.get("sid") or [""])[0], "")
            name = safe_name((q.get("name") or [""])[0], "")
            if not sid or not name:
                return self.reply(400, {"error": "sid와 name이 필요합니다"})
            d = os.path.join(CFG["data_dir"], sid); os.makedirs(d, exist_ok=True)
            tmp = os.path.join(d, name + ".part")
            with open(tmp, "wb") as f:
                f.write(data)
            os.replace(tmp, os.path.join(d, name))     # 쓰다 끊겨도 기존 파일은 온전히
            return self.reply(200, {"ok": True, "bytes": len(data)})
        return self.reply(404, {"error": "없는 주소"})

def main():
    host = "127.0.0.1"
    print(f"간담회 전사 서버 {VERSION} · http://{host}:{CFG['port']} · 데이터 {CFG['data_dir']}", flush=True)
    ThreadingHTTPServer((host, CFG["port"]), H).serve_forever()

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--show-token":
        print(CFG["token"])
    else:
        main()
