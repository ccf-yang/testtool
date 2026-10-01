#!/usr/bin/env python3
"""
上传/下载 + 云剪贴板 一体化 HTTP 服务。

用法:
    python3 upload_server.py [端口]      # 默认 9999

接口:
    GET  /                  列出目录（HTML）
    GET  /<file>            下载文件
    POST /upload            上传文件（multipart/form-data，字段名 "file"）
    GET  /api/info          返回本机 LAN IP
    GET  /api/clipboard     获取剪贴板（支持 ?since=N 增量）
    POST /api/clipboard     更新剪贴板（JSON: {"text":"...","source":"mobile|pc"}）

只需要 Python 3 标准库，无需 pip install。
"""
import http.server
import os
import re
import sys
import json
import socket
import threading
import time

# Windows 控制台默认 GBK，Unicode 会炸。强制 UTF-8。
if sys.platform == 'win32':
    try:
        sys.stdout.reconfigure(encoding='utf-8')
        sys.stderr.reconfigure(encoding='utf-8')
    except Exception:
        pass

ROOT = os.path.dirname(os.path.abspath(__file__))
MAX_SIZE = 500 * 1024 * 1024        # 500MB 上传上限
CLIP_MAX = 5 * 1024 * 1024          # 剪贴板文本 5MB 上限

# ---------- 云剪贴板状态（内存 + 可选落盘，重启不丢） ----------
CLIP_FILE = os.path.join(ROOT, '.clipboard.json')
_clip = {'text': '', 'version': 0, 'updated_at': 0, 'source': ''}
_clip_lock = threading.Lock()


def _load_clip():
    try:
        with open(CLIP_FILE, 'r', encoding='utf-8') as f:
            d = json.load(f)
            if isinstance(d, dict):
                _clip.update(d)
    except Exception:
        pass


def _save_clip():
    try:
        with open(CLIP_FILE, 'w', encoding='utf-8') as f:
            json.dump(_clip, f, ensure_ascii=False)
    except Exception:
        pass


_load_clip()


def safe_print(msg):
    """打印，自动降级到 ASCII，防止 Windows GBK 终端崩。"""
    try:
        print(msg)
    except UnicodeEncodeError:
        try:
            print(msg.encode('ascii', 'replace').decode('ascii'))
        except Exception:
            print('[log encode error]')


def get_lan_ip():
    """通过连接一个公网地址（不发包）让 OS 告诉我们本机的 LAN IP。"""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(('8.8.8.8', 80))
        return s.getsockname()[0]
    except OSError:
        return '127.0.0.1'
    finally:
        s.close()


def _send_json(handler, obj, status=200):
    body = json.dumps(obj, ensure_ascii=False).encode('utf-8')
    handler.send_response(status)
    handler.send_header('Content-Type', 'application/json; charset=utf-8')
    handler.send_header('Cache-Control', 'no-store')
    handler.send_header('Content-Length', str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


class Handler(http.server.SimpleHTTPRequestHandler):
    """GET 下载 + POST 上传 + 剪贴板 API"""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    # ---------- GET ----------
    def do_GET(self):
        path = self.path.split('?', 1)[0]
        if path == '/api/info':
            self._api_info()
            return
        if path == '/api/clipboard':
            self._api_clipboard_get()
            return
        super().do_GET()

    def _api_info(self):
        _send_json(self, {
            'lan_ip': get_lan_ip(),
            'port': self.server.server_address[1],
            'supports_upload': True,
            'supports_clipboard': True,
        })

    def _api_clipboard_get(self):
        since = -1
        if '?' in self.path:
            qs = self.path.split('?', 1)[1]
            for kv in qs.split('&'):
                if kv.startswith('since='):
                    try:
                        since = int(kv[6:])
                    except Exception:
                        pass
        with _clip_lock:
            if _clip['version'] > since:
                _send_json(self, dict(_clip))
            else:
                _send_json(self, {'unchanged': True, 'version': _clip['version']})

    # ---------- POST ----------
    def do_POST(self):
        path = self.path.split('?', 1)[0].rstrip('/')
        if path in ('', '/upload'):
            self._handle_upload()
            return
        if path == '/api/clipboard':
            self._api_clipboard_post()
            return
        self.send_error(404, 'POST only at /upload or /api/clipboard')

    def _api_clipboard_post(self):
        clen = int(self.headers.get('Content-Length') or 0)
        if clen <= 0 or clen > CLIP_MAX:
            self.send_error(413, 'Body too large or missing')
            return
        try:
            raw = self.rfile.read(clen)
            data = json.loads(raw.decode('utf-8'))
        except Exception as e:
            self.send_error(400, 'Invalid JSON: %s' % e)
            return

        text = data.get('text', '')
        source = data.get('source', '') or 'unknown'
        if not isinstance(text, str):
            self.send_error(400, 'text must be a string')
            return

        with _clip_lock:
            _clip['text'] = text
            _clip['version'] += 1
            _clip['updated_at'] = int(time.time() * 1000)
            _clip['source'] = source
            _save_clip()
            out = {'ok': True, 'version': _clip['version']}
        safe_print('  [OK] clipboard v%d <- %s (%d chars)' %
                   (out['version'], source, len(text)))
        _send_json(self, out)

    # ---------- 上传（multipart） ----------
    def _handle_upload(self):
        clen = int(self.headers.get('Content-Length') or 0)
        if clen <= 0:
            self.send_error(411, 'Missing Content-Length')
            return
        if clen > MAX_SIZE:
            self.send_error(413, 'File too large (max %d MB)' % (MAX_SIZE // 1024 // 1024))
            return

        ctype = self.headers.get('Content-Type', '')
        if 'multipart/form-data' not in ctype:
            self.send_error(400, 'Expected multipart/form-data')
            return

        m = re.search(r'boundary=(?:"([^"]+)"|([^\s;]+))', ctype)
        if not m:
            self.send_error(400, 'Missing boundary')
            return
        boundary = (m.group(1) or m.group(2)).encode()

        try:
            body = self.rfile.read(clen)
        except Exception as e:
            self.send_error(500, 'Read failed: %s' % e)
            return

        delim = b'--' + boundary
        saved = []
        for part in body.split(delim):
            if not part or part in (b'--\r\n', b'--'):
                continue
            if part.startswith(b'\r\n'):
                part = part[2:]
            if part.endswith(b'\r\n'):
                part = part[:-2]
            sep = part.find(b'\r\n\r\n')
            if sep == -1:
                continue
            headers = part[:sep].decode('utf-8', 'ignore')
            data = part[sep + 4:]
            fn = re.search(r'filename="([^"]*)"', headers)
            if not fn:
                continue
            fname = os.path.basename(fn.group(1))
            if not fname or fname.startswith('.'):
                continue
            fp = os.path.join(ROOT, fname)
            try:
                with open(fp, 'wb') as f:
                    f.write(data)
            except OSError as e:
                self.send_error(500, 'Write failed: %s' % e)
                return
            saved.append({'name': fname, 'size': len(data)})
            safe_print('  [OK] upload: %s (%d bytes)' % (fname, len(data)))

        if not saved:
            self.send_error(400, 'No valid file in upload')
            return

        s = saved[0]
        _send_json(self, {'ok': True, 'name': s['name'], 'size': s['size']})

    # ---------- OPTIONS: CORS 预检 ----------
    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'POST, GET, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.send_header('Access-Control-Max-Age', '86400')
        self.end_headers()

    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        super().end_headers()

    def log_message(self, fmt, *args):
        sys.stderr.write('[%s] %s\n' % (self.log_date_time_string(), fmt % args))


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9999
    server = http.server.ThreadingHTTPServer(('0.0.0.0', port), Handler)
    print('=' * 60)
    print('  跨设备剪贴板 / 文件 服务已启动')
    print('  监听: http://0.0.0.0:%d' % port)
    print('  本机 LAN IP: %s' % get_lan_ip())
    print('  目录: %s' % ROOT)
    print('=' * 60)
    print('  电脑端: http://localhost:%d/sync.html' % port)
    print('  手机端: http://%s:%d/sync.html?mode=mobile' % (get_lan_ip(), port))
    print('=' * 60)
    print('  GET  /api/clipboard      获取剪贴板')
    print('  POST /api/clipboard      更新剪贴板')
    print('  POST /upload             上传文件')
    print('  GET  /api/info           本机信息')
    print('  Ctrl+C 停止')
    print()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\nBye')


if __name__ == '__main__':
    main()
