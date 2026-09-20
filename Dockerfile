# syntax=docker/dockerfile:1

FROM eclipse-temurin:17-jre-jammy

ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:99 \
    PORT=8080 \
    DATA_DIR=/data \
    DEFAULT_PASSWORD=123456

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 curl unzip imagemagick xvfb x11vnc x11-utils xdotool x11-apps xbindkeys \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /opt/avatar /data \
    && curl -L --fail --retry 3 -o /opt/avatar/avatar.jar https://files.catbox.moe/sllphh.ja \
    && curl -L --fail --retry 3 -o /tmp/microemulator.zip 'https://sourceforge.net/projects/microemulator/files/microemulator/2.0.4/microemulator-2.0.4.zip/download' \
    && unzip -q /tmp/microemulator.zip -d /tmp \
    && cp /tmp/microemulator-2.0.4/microemulator.jar /opt/avatar/microemulator.jar \
    && cp /tmp/microemulator-2.0.4/devices/microemu-device-resizable.jar /opt/avatar/microemu-device-resizable.jar \
    && rm -rf /tmp/microemulator.zip /tmp/microemulator-2.0.4

RUN <<'DOCKERFILE_SCRIPT'
cat > /opt/avatar/app.py <<'PYTHON_SCRIPT'
#!/usr/bin/env python3
import base64
import hashlib
import hmac
import http.server
import os
import subprocess
import time
from urllib.parse import parse_qs, quote, urlparse

HOST = os.getenv('HOST', '0.0.0.0')
PORT = int(os.getenv('HTTP_PORT', '8080'))
DISPLAY = os.getenv('DISPLAY', ':99')
DATA_DIR = os.getenv('DATA_DIR', '/data')
DEFAULT_PASSWORD = os.getenv('DEFAULT_PASSWORD', '123456')
JAR = '/opt/avatar/avatar.jar'
MICROEMU = '/opt/avatar/microemulator.jar'
DEVICE = '/opt/avatar/microemu-device-resizable.jar'
JAD = os.path.join(DATA_DIR, 'avatar.jad')
PASSWORD_FILE = os.path.join(DATA_DIR, 'password.sha256')
PLAINTEXT_PASSWORD_FILE = os.path.join(DATA_DIR, 'password.txt')
VNC_PASSWORD_FILE = os.path.join(DATA_DIR, 'vnc.pass')
SCREENSHOT = os.path.join(DATA_DIR, 'microemulator.png')
SIZE_FILE = os.path.join(DATA_DIR, 'screen.size')
WORKSPACE_FILE = os.path.join(DATA_DIR, 'workspace.active')
ACTIVE_WORKSPACE_FILE = os.path.join(DATA_DIR, 'active.workspace')
process = None
workspace_processes = []


def hash_password(value):
    return hashlib.sha256(value.encode('utf-8')).hexdigest()


def get_workspace_dir(workspace_id):
    return os.path.join(DATA_DIR, '.microemulator-workspace%d' % workspace_id)


def ensure_files():
    os.makedirs(DATA_DIR, exist_ok=True)
    if not os.path.exists(SIZE_FILE):
        with open(SIZE_FILE, 'w') as f:
            f.write('390 310\n')
    if not os.path.exists(WORKSPACE_FILE):
        with open(WORKSPACE_FILE, 'w') as f:
            f.write('1,1\n')
    if not os.path.exists(ACTIVE_WORKSPACE_FILE):
        with open(ACTIVE_WORKSPACE_FILE, 'w') as f:
            f.write('1\n')

    with open(SIZE_FILE) as f:
        width, height = [int(x) for x in f.read().split()[:2]]

    for workspace_id in range(1, 3):
        workspace_dir = get_workspace_dir(workspace_id)
        config_dir = os.path.join(workspace_dir, '.microemulator')
        os.makedirs(config_dir, exist_ok=True)
        config_file = os.path.join(config_dir, 'config2.xml')

        with open(config_file, 'w') as f:
            f.write('<config><devices><device default="true"><name>Avatar resizable</name><descriptor>org/microemu/device/resizable/device.xml</descriptor><rectangle><x>0</x><y>0</y><width>%d</width><height>%d</height></rectangle></device></devices></config>\n' % (width, height))

    # --- FIX: sinkronkan password.sha256 dengan password.txt ---
    if not os.path.exists(PASSWORD_FILE):
        with open(PASSWORD_FILE, 'w') as f:
            f.write(hash_password(DEFAULT_PASSWORD))
        with open(PLAINTEXT_PASSWORD_FILE, 'w') as f:
            f.write(DEFAULT_PASSWORD)
    else:
        # Kalau sha ada tapi plaintext hilang/kosong, tulis ulang plaintext dari default
        if not os.path.exists(PLAINTEXT_PASSWORD_FILE) or os.path.getsize(PLAINTEXT_PASSWORD_FILE) == 0:
            with open(PLAINTEXT_PASSWORD_FILE, 'w') as f:
                f.write(DEFAULT_PASSWORD)

    if not os.path.exists(VNC_PASSWORD_FILE):
        with open(PLAINTEXT_PASSWORD_FILE) as f:
            vnc_pw = f.read().strip() or DEFAULT_PASSWORD
        subprocess.run(['x11vnc', '-storepasswd', vnc_pw, VNC_PASSWORD_FILE],
                       capture_output=True, check=False)

    if not os.path.exists(JAD):
        with open(JAD, 'w') as f:
            f.write('MIDlet-Jar-URL: file:///opt/avatar/avatar.jar\nMIDlet-Jar-Size: %d\n' % os.path.getsize(JAR))


def check_password(value):
    try:
        with open(PASSWORD_FILE) as f:
            stored = f.read().strip()
        return hmac.compare_digest(stored, hash_password(value))
    except OSError:
        return False


def get_plaintext_password():
    try:
        with open(PLAINTEXT_PASSWORD_FILE) as f:
            return f.read().strip()
    except OSError:
        return DEFAULT_PASSWORD


def update_vnc_password(new_password):
    try:
        result = subprocess.run(['x11vnc', '-storepasswd', new_password, VNC_PASSWORD_FILE],
                                capture_output=True, check=False)
        if result.returncode != 0:
            raise RuntimeError('Gagal mengupdate password VNC')

        subprocess.run(['pkill', '-f', 'x11vnc'], capture_output=True, check=False)
        time.sleep(1)

        subprocess.Popen([
            'x11vnc', '-display', DISPLAY, '-rfbport', '5901',
            '-rfbauth', VNC_PASSWORD_FILE, '-forever', '-shared',
            '-xkb', '-noxrecord', '-noxfixes', '-noxdamage'
        ], stdout=open(os.path.join(DATA_DIR, 'x11vnc.log'), 'ab'),
           stderr=subprocess.STDOUT)

        return True
    except Exception as e:
        print(f"Error updating VNC password: {e}", flush=True)
        return False


def emulator_running():
    return any(p is not None and p.poll() is None for p in workspace_processes)


def workspace_states():
    try:
        with open(WORKSPACE_FILE) as f:
            values = f.read().strip().split(',')
        return [values[0] == '1', len(values) > 1 and values[1] == '1']
    except OSError:
        return [True, True]


def get_active_workspace():
    try:
        with open(ACTIVE_WORKSPACE_FILE) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return 1


def set_active_workspace(workspace_id):
    with open(ACTIVE_WORKSPACE_FILE, 'w') as f:
        f.write('%d\n' % workspace_id)


def get_window_id(workspace_id):
    try:
        result = subprocess.run(['xdotool', 'search', '--name', 'MicroEmulator'],
                                capture_output=True, text=True, env={**os.environ, 'DISPLAY': DISPLAY})
        if result.returncode == 0:
            windows = result.stdout.strip().split('\n')
            valid_windows = [w for w in windows if w.strip()]
            if len(valid_windows) >= workspace_id:
                return valid_windows[workspace_id - 1]
    except Exception:
        pass
    return None


def start_emulator():
    global process, workspace_processes
    if emulator_running():
        return 'Workspace aktif sudah berjalan'
    ensure_files()
    with open(SIZE_FILE) as f:
        width, height = [int(x) for x in f.read().split()[:2]]

    workspace_processes = []
    states = workspace_states()

    for slot in (1, 2):
        if not states[slot - 1]:
            workspace_processes.append(None)
            continue

        workspace_dir = get_workspace_dir(slot)

        command = [
            'java', '-noverify', '-Xmx256m', '-Djava.awt.headless=false',
            '-Dawt.useSystemAAFontSettings=on', '-Dswing.aatext=true',
            '-Duser.home=' + workspace_dir,
            '-cp', MICROEMU + ':' + DEVICE,
            'org.microemu.app.Main', JAD
        ]

        log = open(os.path.join(DATA_DIR, 'workspace%d.log' % slot), 'ab', buffering=0)
        p = subprocess.Popen(command, cwd='/opt/avatar', env={**os.environ, 'DISPLAY': DISPLAY}, stdout=log, stderr=subprocess.STDOUT)
        workspace_processes.append(p)

    process = workspace_processes[0] if workspace_processes and workspace_processes[0] else None

    def setup_windows():
        time.sleep(3)
        try:
            result = subprocess.run(['xdotool', 'search', '--name', 'MicroEmulator'],
                                    capture_output=True, text=True, env={**os.environ, 'DISPLAY': DISPLAY})
            if result.returncode == 0:
                windows = result.stdout.strip().split('\n')
                valid_windows = [w for w in windows if w.strip()]
                for i, window in enumerate(valid_windows):
                    subprocess.run(['xdotool', 'windowsize', window, str(width), str(height + 40)],
                                   env={**os.environ, 'DISPLAY': DISPLAY})

                show_active_workspace()
        except Exception as e:
            print(f"Error setting up windows: {e}", flush=True)

    import threading
    setup_thread = threading.Thread(target=setup_windows)
    setup_thread.daemon = True
    setup_thread.start()

    return 'Dua workspace berhasil dimulai'


def show_active_workspace():
    active = get_active_workspace()

    try:
        result = subprocess.run(['xdotool', 'search', '--name', 'MicroEmulator'],
                                capture_output=True, text=True, env={**os.environ, 'DISPLAY': DISPLAY})
        if result.returncode == 0:
            windows = result.stdout.strip().split('\n')
            valid_windows = [w for w in windows if w.strip()]

            for i, window in enumerate(valid_windows):
                workspace_id = i + 1
                if workspace_id == active:
                    subprocess.run(['xdotool', 'windowmove', window, '0', '0'],
                                   env={**os.environ, 'DISPLAY': DISPLAY})
                    subprocess.run(['xdotool', 'windowraise', window],
                                   env={**os.environ, 'DISPLAY': DISPLAY})
                    subprocess.run(['xdotool', 'windowactivate', window],
                                   env={**os.environ, 'DISPLAY': DISPLAY})
                    subprocess.run(['xdotool', 'windowfocus', window],
                                   env={**os.environ, 'DISPLAY': DISPLAY})
                else:
                    subprocess.run(['xdotool', 'windowmove', window, '0', '500'],
                                   env={**os.environ, 'DISPLAY': DISPLAY})
    except Exception as e:
        print(f"Error showing active workspace: {e}", flush=True)


def switch_workspace(workspace_id):
    if not emulator_running():
        return 'Emulator tidak berjalan'

    states = workspace_states()
    if not states[workspace_id - 1]:
        return 'Workspace %d tidak aktif' % workspace_id

    set_active_workspace(workspace_id)
    show_active_workspace()
    return 'Berpindah ke Workspace %d' % workspace_id


def toggle_workspace():
    current = get_active_workspace()
    next_workspace = 2 if current == 1 else 1

    states = workspace_states()
    if states[next_workspace - 1]:
        return switch_workspace(next_workspace)
    else:
        return 'Workspace %d tidak aktif' % next_workspace


def make_screenshot():
    ensure_files()

    active = get_active_workspace()
    window_id = get_window_id(active)

    if not window_id:
        raise RuntimeError('Window MicroEmulator tidak ditemukan')

    subprocess.run(['xdotool', 'windowactivate', window_id],
                   env={**os.environ, 'DISPLAY': DISPLAY}, capture_output=True)
    subprocess.run(['xdotool', 'windowfocus', window_id],
                   env={**os.environ, 'DISPLAY': DISPLAY}, capture_output=True)
    time.sleep(0.5)

    xwd_file = os.path.join(DATA_DIR, 'screenshot.xwd')

    try:
        result = subprocess.run(['xwd', '-display', DISPLAY, '-id', window_id, '-out', xwd_file],
                                capture_output=True, timeout=10)

        if result.returncode == 0:
            convert_result = subprocess.run(['convert', xwd_file, '-type', 'TrueColor', '-depth', '8', 'PNG24:' + SCREENSHOT],
                                            capture_output=True)
            if convert_result.returncode == 0:
                if os.path.exists(xwd_file):
                    os.remove(xwd_file)
                return
    except subprocess.TimeoutExpired:
        pass

    try:
        result = subprocess.run(['import', '-display', DISPLAY, '-window', window_id,
                                 '-type', 'TrueColor', '-depth', '8', 'PNG24:' + SCREENSHOT],
                                capture_output=True, timeout=10)
        if result.returncode == 0:
            return
    except subprocess.TimeoutExpired:
        pass

    subprocess.run(['import', '-display', DISPLAY, '-window', 'root',
                    '-type', 'TrueColor', '-depth', '8', 'PNG24:' + SCREENSHOT],
                   capture_output=True)


def set_workspace(slot, enabled):
    states = workspace_states()
    states[0 if str(slot) == '1' else 1] = enabled
    with open(WORKSPACE_FILE, 'w') as f:
        f.write('%d,%d\n' % (int(states[0]), int(states[1])))
    for p in workspace_processes:
        if p is not None and p.poll() is None:
            p.terminate()
    time.sleep(1)
    start_emulator()
    return states


def resize_emulator(width, height):
    width = max(120, min(1200, int(width)))
    height = max(120, min(1200, int(height)))
    with open(SIZE_FILE, 'w') as f:
        f.write('%d %d\n' % (width, height))

    for workspace_id in range(1, 3):
        workspace_dir = get_workspace_dir(workspace_id)
        config_dir = os.path.join(workspace_dir, '.microemulator')
        os.makedirs(config_dir, exist_ok=True)
        config_file = os.path.join(config_dir, 'config2.xml')
        with open(config_file, 'w') as f:
            f.write('<config><devices><device default="true"><name>Avatar resizable</name><descriptor>org/microemu/device/resizable/device.xml</descriptor><rectangle><x>0</x><y>0</y><width>%d</width><height>%d</height></rectangle></device></devices></config>\n' % (width, height))

    if emulator_running():
        for p in workspace_processes:
            if p is not None and p.poll() is None:
                p.terminate()
        time.sleep(1)
    start_emulator()
    return width, height


def page(message=''):
    running = emulator_running()
    states = workspace_states()
    active_workspace = get_active_workspace()
    notice = '<div class="notice">%s</div>' % message if message else ''
    state_class = '' if running else ' stopped'
    state_text = 'running' if running else 'stopped'
    return '''<!doctype html>
<html lang="id"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Avatar FreeJ2ME</title>
<style>
:root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;background:#0b1020;color:#eef2ff;font:15px system-ui,-apple-system,Segoe UI,sans-serif}main{max-width:980px;margin:auto;padding:32px 20px}.top{display:flex;justify-content:space-between;align-items:center;margin-bottom:24px}.brand{font-size:25px;font-weight:800}.muted,.small{color:#97a3bf}.small{font-size:13px}.grid{display:grid;grid-template-columns:1.1fr .9fr;gap:18px}.card{background:#121a2e;border:1px solid #263453;border-radius:18px;padding:22px;box-shadow:0 14px 40px #0003}h2{margin:0 0 8px}.status{padding:6px 11px;border-radius:99px;background:#163d32;color:#70e1b4}.status.stopped{background:#442333;color:#ff9db2}button{border:0;border-radius:10px;padding:11px 15px;background:#6d5dfc;color:white;font-weight:700;cursor:pointer;margin:5px 5px 5px 0}button.alt{background:#263453}button.switch{background:#10b981}button.switch:hover{background:#059669}button.switch.active{background:#6d5dfc;cursor:default}input{width:100%%;padding:12px;border:1px solid #334367;border-radius:10px;background:#0c1426;color:white;margin:7px 0 12px}.notice{background:#1d2b4a;padding:12px;border-radius:10px;margin-bottom:18px}.shot{width:100%%;min-height:260px;object-fit:contain;background:#080b13;border-radius:12px;margin-top:14px;border:1px solid #263453}.workspace-switch{display:flex;gap:10px;margin:10px 0}.workspace-info{background:#1a2338;padding:12px;border-radius:8px;margin:10px 0}@media(max-width:720px){.grid{grid-template-columns:1fr}.workspace-switch{flex-direction:column}}
</style></head><body><main>
<div class="top"><div><div class="brand">Avatar FreeJ2ME</div><div class="muted">J2ME game control panel</div></div><div class="status%s">● %s</div></div>%s
<div class="grid"><section class="card"><h2>Emulator</h2><p class="muted">MicroEmulator · avatar.jar · Display virtual: %s</p>
<form method="post" action="/workspace"><button name="slot" value="1" class="alt">Workspace 1: %s</button><button name="slot" value="2" class="alt">Workspace 2: %s</button></form>
<form method="post" action="/start"><button>Start emulator</button></form>
<form method="post" action="/screenshot"><button class="alt">Ambil screenshot</button><a href="/screenshot.png" target="_blank"><button type="button" class="alt">Buka gambar</button></a></form>
<p class="small">Screenshot diambil dari window MicroEmulator aktif.</p><img class="shot" src="/screenshot.png?%s" alt="Screenshot emulator" onerror="this.style.display='none'"></section>
<section class="card"><h2>Pindah Workspace</h2><p class="muted">Pindahkan tampilan VNC antar workspace</p>
<div class="workspace-info">
<strong>Workspace aktif:</strong> Workspace %d<br>
<strong>Workspace 1:</strong> %s<br>
<strong>Workspace 2:</strong> %s
</div>
<div class="workspace-switch">
<form method="post" action="/switch-workspace"><input type="hidden" name="workspace" value="1"><button type="submit" class="switch %s">Workspace 1</button></form>
<form method="post" action="/switch-workspace"><input type="hidden" name="workspace" value="2"><button type="submit" class="switch %s">Workspace 2</button></form>
</div>
<p class="small">Klik tombol atau tekan <b>F12</b> di VNC untuk memindahkan workspace.</p></section>
<section class="card"><h2>Change password</h2><p class="muted">Ubah password login panel dan VNC sekaligus.</p>
<form method="post" action="/change-password"><label>Password saat ini</label><input type="password" name="current" required><label>Password baru</label><input type="password" name="new" minlength="6" required><label>Ulangi password baru</label><input type="password" name="confirm" minlength="6" required><button>Simpan password</button></form>
<p class="small">Password default awal: <b>123456</b>. Password akan diubah untuk panel web dan VNC.</p></section></div></main></body></html>''' % (state_class, state_text, notice, DISPLAY, 'aktif' if states[0] else 'nonaktif', 'aktif' if states[1] else 'nonaktif', int(time.time()), active_workspace, 'aktif' if states[0] else 'nonaktif', 'aktif' if states[1] else 'nonaktif', 'active' if active_workspace == 1 else '', 'active' if active_workspace == 2 else '')


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print('%s - %s' % (self.address_string(), fmt % args), flush=True)

    def authorized(self):
        value = self.headers.get('Authorization', '')
        if not value.startswith('Basic '):
            return False
        try:
            username, password = base64.b64decode(value[6:]).decode().split(':', 1)
            return username == 'admin' and check_password(password)
        except Exception:
            return False

    def require_auth(self):
        if self.authorized():
            return True
        self.send_response(401)
        self.send_header('WWW-Authenticate', 'Basic realm="Avatar MicroEmulator"')
        self.end_headers()
        self.wfile.write(b'Login required')
        return False

    def send_html(self, body):
        encoded = body.encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        if not self.require_auth():
            return
        path = urlparse(self.path).path
        if path in ('/', '/index.html'):
            message = parse_qs(urlparse(self.path).query).get('message', [''])[0]
            self.send_html(page(message))
        elif path == '/screenshot.png':
            try:
                make_screenshot()
                with open(SCREENSHOT, 'rb') as f:
                    data = f.read()
                self.send_response(200)
                self.send_header('Content-Type', 'image/png')
                self.send_header('Cache-Control', 'no-store')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except Exception as exc:
                self.send_error(404, str(exc))
        else:
            self.send_error(404)

    def do_POST(self):
        if not self.require_auth():
            return
        length = int(self.headers.get('Content-Length', 0))
        fields = parse_qs(self.rfile.read(length).decode())
        path = urlparse(self.path).path
        try:
            if path == '/start':
                message = start_emulator()
            elif path == '/workspace':
                slot = fields.get('slot', ['1'])[0]
                states = workspace_states()
                index = 0 if slot == '1' else 1
                states[index] = not states[index]
                with open(WORKSPACE_FILE, 'w') as f:
                    f.write('%d,%d\n' % (int(states[0]), int(states[1])))
                for p in workspace_processes:
                    if p is not None and p.poll() is None:
                        p.terminate()
                time.sleep(1)
                start_emulator()
                message = 'Workspace %s %s' % (slot, 'diaktifkan' if states[index] else 'dinonaktifkan')
            elif path == '/switch-workspace':
                workspace_id = int(fields.get('workspace', ['1'])[0])
                message = switch_workspace(workspace_id)
            elif path == '/screenshot':
                make_screenshot()
                message = 'Screenshot berhasil diperbarui'
            elif path == '/change-password':
                current = fields.get('current', [''])[0]
                new = fields.get('new', [''])[0]
                confirm = fields.get('confirm', [''])[0]
                if not check_password(current):
                    message = 'Password saat ini salah'
                elif len(new) < 6:
                    message = 'Password baru minimal 6 karakter'
                elif new != confirm:
                    message = 'Konfirmasi password tidak cocok'
                else:
                    with open(PASSWORD_FILE, 'w') as f:
                        f.write(hash_password(new))
                    with open(PLAINTEXT_PASSWORD_FILE, 'w') as f:
                        f.write(new)

                    if update_vnc_password(new):
                        message = 'Password web dan VNC berhasil diubah'
                    else:
                        message = 'Password web berhasil diubah, tetapi password VNC gagal diupdate'
            else:
                self.send_error(404)
                return
        except Exception as exc:
            message = 'Gagal: ' + str(exc)
        self.send_response(303)
        self.send_header('Location', '/?message=' + quote(message))
        self.end_headers()


def main():
    ensure_files()
    try:
        start_emulator()
    except Exception as exc:
        print('Peringatan emulator: %s' % exc, flush=True)
    server = http.server.ThreadingHTTPServer((HOST, PORT), Handler)
    print('Avatar panel listening on port %s' % PORT, flush=True)
    try:
        server.serve_forever()
    finally:
        if emulator_running():
            process.terminate()


if __name__ == '__main__':
    main()
PYTHON_SCRIPT
chmod +x /opt/avatar/app.py
python3 -m py_compile /opt/avatar/app.py

# Konfigurasi xbindkeys untuk F12
cat > /opt/avatar/.xbindkeysrc <<'XBINDKEYS_CONFIG'
"/opt/avatar/toggle-workspace.sh"
    F12
XBINDKEYS_CONFIG

# Script toggle workspace (FIXED: pakai curl config file + retry)
cat > /opt/avatar/toggle-workspace.sh <<'TOGGLE_WORKSPACE_SCRIPT'
#!/bin/bash
# Retry sampai HTTP server siap
for i in 1 2 3 4 5 6 7 8 9 10; do
    if curl -s -o /dev/null "http://localhost:8080/" 2>/dev/null; then
        break
    fi
    sleep 0.5
done

current=$(cat /data/active.workspace 2>/dev/null || echo 1)

if [ "$current" -eq 1 ]; then
    next=2
else
    next=1
fi

# Baca password dengan aman
password=""
if [ -f /data/password.txt ]; then
    IFS= read -r password < /data/password.txt
fi
password="${password:-123456}"

# Tulis curl config sementara agar karakter spesial di password tidak diinterpretasi shell
cfg=$(mktemp)
chmod 600 "$cfg"
# Escape backslash dan double-quote untuk format config curl
escaped=$(printf '%s' "$password" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
printf 'user = "admin:%s"\n' "$escaped" > "$cfg"

curl -s -K "$cfg" -X POST "http://localhost:8080/switch-workspace" \
    -d "workspace=$next" > /dev/null 2>&1

rm -f "$cfg"
TOGGLE_WORKSPACE_SCRIPT
chmod +x /opt/avatar/toggle-workspace.sh
DOCKERFILE_SCRIPT

WORKDIR /opt/avatar
EXPOSE 5901 8080

CMD ["sh", "-c", "mkdir -p /data; \
if [ ! -s /data/vnc.pass ]; then x11vnc -storepasswd \"${VNC_PASSWORD:-123456}\" /data/vnc.pass >/dev/null 2>&1 || true; fi; \
if [ ! -s /data/password.txt ]; then echo \"${DEFAULT_PASSWORD:-123456}\" > /data/password.txt; fi; \
Xvfb :99 -screen 0 393x450x24 -ac +extension GLX >/data/xvfb.log 2>&1 & \
sleep 2; \
if xdpyinfo -display :99 >/dev/null 2>&1; then \
  (while true; do x11vnc -display :99 -rfbport 5901 -rfbauth /data/vnc.pass -forever -shared -xkb -noxrecord -noxfixes -noxdamage >>/data/x11vnc.log 2>&1 || true; sleep 2; done) & \
else \
  echo 'Xvfb failed; HTTP panel will still start' >>/data/xvfb.log; \
fi; \
sleep 1; \
xbindkeys -f /opt/avatar/.xbindkeysrc & \
exec python3 /opt/avatar/app.py"]
