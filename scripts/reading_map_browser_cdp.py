#!/usr/bin/env python3
"""Real-browser check without external tooling: launches local Chrome headless
with a CDP endpoint, loads the mapped reader snapshot and asserts the graph
map renders, routes on click, and produces no console errors.

Pure Python standard library: the DevTools protocol is spoken over a minimal
hand-rolled WebSocket client (HTTP upgrade handshake, client frame masking,
text frame read/write), so no Node.js is involved.
Usage: python3 scripts/reading_map_browser_cdp.py [file-url] [chrome-path]
"""
import base64
import hashlib
import json
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

DEFAULT_URL = 'file:///tmp/corridor-rich-reading/.corridor/map-viewer.html'
WEBSOCKET_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'


def fail(message):
    raise SystemExit(message)


def arg_text(arg):
    if not isinstance(arg, dict) or 'value' not in arg:
        return ''
    value = arg['value']
    if value is True:
        return 'true'
    if value is False:
        return 'false'
    return '' if value is None else str(value)


def http_get_json(port, path, timeout=5.0):
    # Chrome's DevTools server keeps the connection alive, so the body must be
    # framed by headers + Content-Length (or chunk size), never by EOF.
    with socket.create_connection(('127.0.0.1', port), timeout=timeout) as probe:
        probe.sendall(('GET ' + path + ' HTTP/1.1\r\nHost: 127.0.0.1:' + str(port) +
                       '\r\n\r\n').encode())
        data = b''
        while b'\r\n\r\n' not in data:
            chunk = probe.recv(65536)
            if not chunk:
                raise ConnectionError('DevTools HTTP connection closed before headers')
            data += chunk
        head, _, body = data.partition(b'\r\n\r\n')
        if b' 200 ' not in head.split(b'\r\n', 1)[0]:
            raise ConnectionError('unexpected DevTools HTTP response')
        headers = {}
        for line in head.decode('iso-8859-1').split('\r\n')[1:]:
            name, _, value = line.partition(':')
            headers[name.strip().lower()] = value.strip()
        if headers.get('transfer-encoding', '').lower() == 'chunked':
            while not body.endswith(b'0\r\n\r\n'):
                chunk = probe.recv(65536)
                if not chunk:
                    raise ConnectionError('DevTools HTTP connection closed mid-body')
                body += chunk
            payload = b''
            while body:
                size_line, _, body = body.partition(b'\r\n')
                size = int(size_line.split(b';')[0], 16)
                if size == 0:
                    break
                payload += body[:size]
                body = body[size + 2:]
            return json.loads(payload)
        length = int(headers.get('content-length', '0'))
        while len(body) < length:
            chunk = probe.recv(65536)
            if not chunk:
                raise ConnectionError('DevTools HTTP connection closed mid-body')
            body += chunk
        return json.loads(body)


class WebSocket:
    """Minimal RFC 6455 client: text frames only, mandatory client masking."""

    def __init__(self, host, port, path, timeout=30.0):
        self.socket = socket.create_connection((host, port), timeout=timeout)
        try:
            self._handshake(host, port, path)
        except BaseException:
            self.socket.close()
            raise

    def _handshake(self, host, port, path):
        key = base64.b64encode(os.urandom(16)).decode()
        request = ('GET ' + path + ' HTTP/1.1\r\n'
                   'Host: ' + host + ':' + str(port) + '\r\n'
                   'Upgrade: websocket\r\n'
                   'Connection: Upgrade\r\n'
                   'Sec-WebSocket-Key: ' + key + '\r\n'
                   'Sec-WebSocket-Version: 13\r\n\r\n')
        self.socket.sendall(request.encode())
        response = b''
        while b'\r\n\r\n' not in response:
            chunk = self.socket.recv(4096)
            if not chunk:
                raise ConnectionError('connection closed during handshake')
            response += chunk
        status = response.split(b'\r\n', 1)[0]
        if b' 101 ' not in status:
            raise ConnectionError('websocket handshake rejected: ' + status.decode(errors='replace'))
        expected = base64.b64encode(hashlib.sha1((key + WEBSOCKET_GUID).encode()).digest()).decode()
        headers = response.split(b'\r\n\r\n', 1)[0].decode(errors='replace').split('\r\n')
        accept = [line.split(':', 1)[1].strip() for line in headers
                  if line.lower().startswith('sec-websocket-accept:')]
        if not accept or accept[0] != expected:
            raise ConnectionError('websocket accept key mismatch')

    def _read_exact(self, count):
        data = b''
        while len(data) < count:
            chunk = self.socket.recv(count - len(data))
            if not chunk:
                raise ConnectionError('connection closed by peer')
            data += chunk
        return data

    def _read_frame(self):
        first, second = self._read_exact(2)
        fin = bool(first & 0x80)
        opcode = first & 0x0F
        masked = bool(second & 0x80)
        length = second & 0x7F
        if length == 126:
            length = struct.unpack('>H', self._read_exact(2))[0]
        elif length == 127:
            length = struct.unpack('>Q', self._read_exact(8))[0]
        mask = self._read_exact(4) if masked else b''
        payload = self._read_exact(length)
        if mask:
            payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        return fin, opcode, payload

    def _write_frame(self, opcode, payload):
        header = bytearray([0x80 | opcode])
        length = len(payload)
        if length < 126:
            header.append(0x80 | length)
        elif length < 1 << 16:
            header.append(0x80 | 126)
            header += struct.pack('>H', length)
        else:
            header.append(0x80 | 127)
            header += struct.pack('>Q', length)
        mask = os.urandom(4)
        header += mask
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self.socket.sendall(bytes(header) + masked)

    def send_text(self, text):
        self._write_frame(0x1, text.encode())

    def recv_text(self):
        buffer = b''
        while True:
            fin, opcode, payload = self._read_frame()
            if opcode == 0x8:  # close
                raise ConnectionError('websocket closed by peer')
            if opcode == 0x9:  # ping -> pong
                self._write_frame(0xA, payload)
                continue
            if opcode == 0xA:  # pong
                continue
            buffer += payload
            if fin:
                return buffer.decode()

    def close(self):
        try:
            self._write_frame(0x8, b'')
        except OSError:
            pass
        self.socket.close()


class CdpSession:
    def __init__(self, socket_):
        self.socket = socket_
        self.next_id = 0
        self.console_errors = []

    def send(self, method, params=None, session_id=None):
        self.next_id += 1
        message = {'id': self.next_id, 'method': method, 'params': params or {}}
        if session_id:
            message['sessionId'] = session_id
        self.socket.send_text(json.dumps(message))
        return self.next_id

    def record_event(self, message):
        method = message.get('method')
        params = message.get('params') or {}
        if method == 'Runtime.consoleAPICalled' and params.get('type') == 'error':
            self.console_errors.append(' '.join(arg_text(arg) for arg in params.get('args', [])))
        elif method == 'Runtime.exceptionThrown':
            self.console_errors.append((params.get('exceptionDetails') or {}).get('text', ''))

    def receive(self, message_id):
        while True:
            message = json.loads(self.socket.recv_text())
            if message.get('id') == message_id:
                return message
            self.record_event(message)

    def call(self, method, params=None, session_id=None):
        return self.receive(self.send(method, params, session_id))

    def evaluate(self, expression, session_id):
        response = self.call('Runtime.evaluate',
                             {'expression': expression, 'returnByValue': True, 'awaitPromise': True},
                             session_id)
        if 'error' in response:
            raise RuntimeError(response['error'].get('message', 'CDP call failed'))
        result = response.get('result') or {}
        if 'exceptionDetails' in result:
            raise RuntimeError(result['exceptionDetails'].get('text', 'evaluation failed'))
        return (result.get('result') or {}).get('value')


def main():
    url = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_URL
    chrome_path = next((candidate for candidate in [
        sys.argv[2] if len(sys.argv) > 2 else None,
        os.environ.get('CHROME_BINARY'),
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        shutil.which('google-chrome'), shutil.which('chromium'),
    ] if candidate and os.path.exists(candidate)), None)
    if chrome_path is None:
        fail('no Chrome binary found (pass a chrome path or set CHROME_BINARY)')
    profile = tempfile.mkdtemp(prefix='corridor-cdp-profile-')
    process = subprocess.Popen(
        [chrome_path, '--headless=new', '--disable-gpu', '--no-first-run',
         '--remote-debugging-port=0', '--user-data-dir=' + profile, 'about:blank'],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    state = {'port': None}

    def watch_stderr():
        for line in process.stderr:
            match = re.search(r'DevTools listening on ws://127\.0\.0\.1:(\d+)/', line)
            if match:
                state['port'] = int(match.group(1))

    threading.Thread(target=watch_stderr, daemon=True).start()

    def shutdown():
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        shutil.rmtree(profile, ignore_errors=True)

    session = None
    try:
        for _ in range(100):
            if state['port']:
                break
            time.sleep(0.1)
        if not state['port']:
            fail('chrome did not expose a debugging port')
        port = state['port']
        for _ in range(50):
            time.sleep(0.1)
            try:
                version = http_get_json(port, '/json/version')
                _, _, authority, path = version['webSocketDebuggerUrl'].split('/', 3)
                host, _, host_port = authority.rpartition(':')
                session = CdpSession(WebSocket(host, int(host_port), '/' + path))
                break
            except (OSError, ValueError, KeyError, ConnectionError):
                if session is not None:
                    session.socket.close()
                session = None
        if session is None:
            fail('chrome debugging endpoint unavailable')

        target = session.call('Target.createTarget', {'url': 'about:blank'})['result']['targetId']
        session_id = session.call('Target.attachToTarget', {'targetId': target, 'flatten': True})['result']['sessionId']
        session.call('Runtime.enable', {}, session_id)
        session.call('Page.enable', {}, session_id)
        session.call('Page.navigate', {'url': url}, session_id)
        time.sleep(2.5)

        def evaluate(expression):
            return session.evaluate(expression, session_id)

        checks = []

        def check(ok, label):
            checks.append((bool(ok), label))

        check(evaluate("!!document.querySelector('.graph-panel svg.graph-map')"), 'graph map renders')
        check(evaluate("document.querySelectorAll('.graph-map line.graph-edge').length >= 1"), 'graph edges present')
        check(evaluate("document.querySelectorAll('.graph-map line.graph-shared').length >= 1"),
              'shared-source dashed edges present')
        check(evaluate("document.querySelectorAll('.graph-map circle.graph-node').length >= 2"), 'graph nodes present')
        check(evaluate("document.querySelectorAll(\".graph-map a[href^='#p-']\").length >= 1"),
              'graph nodes are routable links')
        routed = evaluate('''(async () => {
  const link = document.querySelector(".graph-map a[href^='#p-']");
  const href = link.getAttribute('href');
  link.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
  await new Promise(resolve => setTimeout(resolve, 300));
  const visible = [...document.querySelectorAll('.reading')].filter(a => !a.hidden);
  return { href, hash: location.hash, visible: visible.length, id: visible[0]?.dataset?.id || '' };
})()''')
        check(routed['hash'] == routed['href'],
              'graph click updates the hash (' + str(routed['href']) + ' -> ' + str(routed['hash']) + ')')
        check(routed['visible'] == 1, 'graph routing shows one article (' + str(routed['visible']) + ')')
        check(evaluate('document.documentElement.scrollWidth <= innerWidth'),
              'no horizontal overflow at current viewport')
        check(len(session.console_errors) == 0,
              'no console errors (' + '; '.join(session.console_errors) + ')')

        for ok, label in checks:
            print(('ok  ' if ok else 'FAIL ') + label)
        if not all(ok for ok, _ in checks):
            sys.exit(1)
        print('map reader browser check passed')
    finally:
        if session is not None:
            session.socket.close()
        shutdown()


if __name__ == '__main__':
    main()
