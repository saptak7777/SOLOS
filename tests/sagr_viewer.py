#!/usr/bin/env python3
"""Lightweight PyQt6 VNC (RFB 3.8 Raw + DesktopSize) viewer for SOLOS SAGR on LXQt/X11."""

import os
import socket
import struct
import subprocess
import sys
import threading
import time

from PyQt6.QtCore import QEvent, QObject, QRect, Qt, pyqtSignal
from PyQt6.QtGui import QImage, QPainter
from PyQt6.QtWidgets import QApplication, QWidget

# Qt.Key -> X11 keysym mapping for QEMU RFB keyboard forwarding
_QT_KEY_TO_KEYSYM = {
    Qt.Key.Key_Return: 0xFF0D,
    Qt.Key.Key_Enter: 0xFF8D,
    Qt.Key.Key_Backspace: 0xFF08,
    Qt.Key.Key_Tab: 0xFF09,
    Qt.Key.Key_Backtab: 0xFF09,
    Qt.Key.Key_Escape: 0xFF1B,
    Qt.Key.Key_Delete: 0xFFFF,
    Qt.Key.Key_Home: 0xFF50,
    Qt.Key.Key_Left: 0xFF51,
    Qt.Key.Key_Up: 0xFF52,
    Qt.Key.Key_Right: 0xFF53,
    Qt.Key.Key_Down: 0xFF54,
    Qt.Key.Key_PageUp: 0xFF55,
    Qt.Key.Key_PageDown: 0xFF56,
    Qt.Key.Key_End: 0xFF57,
    Qt.Key.Key_Insert: 0xFF63,
    Qt.Key.Key_Shift: 0xFFE1,
    Qt.Key.Key_Control: 0xFFE3,
    Qt.Key.Key_Alt: 0xFFE9,
    Qt.Key.Key_AltGr: 0xFFEA,
    Qt.Key.Key_Meta: 0xFFEB,
    Qt.Key.Key_Super_L: 0xFFEB,
    Qt.Key.Key_Super_R: 0xFFEC,
    Qt.Key.Key_CapsLock: 0xFFE5,
    Qt.Key.Key_Space: 0x0020,
    Qt.Key.Key_F1: 0xFFBE,
    Qt.Key.Key_F2: 0xFFBF,
    Qt.Key.Key_F3: 0xFFC0,
    Qt.Key.Key_F4: 0xFFC1,
    Qt.Key.Key_F5: 0xFFC2,
    Qt.Key.Key_F6: 0xFFC3,
    Qt.Key.Key_F7: 0xFFC4,
    Qt.Key.Key_F8: 0xFFC5,
    Qt.Key.Key_F9: 0xFFC6,
    Qt.Key.Key_F10: 0xFFC7,
    Qt.Key.Key_F11: 0xFFC8,
    Qt.Key.Key_F12: 0xFFC9,
}

_SHIFTED_PUNCT = {
    Qt.Key.Key_1: ord("!"), Qt.Key.Key_2: ord("@"), Qt.Key.Key_3: ord("#"),
    Qt.Key.Key_4: ord("$"), Qt.Key.Key_5: ord("%"), Qt.Key.Key_6: ord("^"),
    Qt.Key.Key_7: ord("&"), Qt.Key.Key_8: ord("*"), Qt.Key.Key_9: ord("("),
    Qt.Key.Key_0: ord(")"), Qt.Key.Key_Minus: ord("_"), Qt.Key.Key_Equal: ord("+"),
    Qt.Key.Key_BracketLeft: ord("{"), Qt.Key.Key_BracketRight: ord("}"),
    Qt.Key.Key_Backslash: ord("|"), Qt.Key.Key_Semicolon: ord(":"),
    Qt.Key.Key_Apostrophe: ord('"'), Qt.Key.Key_Comma: ord("<"),
    Qt.Key.Key_Period: ord(">"), Qt.Key.Key_Slash: ord("?"),
    Qt.Key.Key_QuoteLeft: ord("~"),
}


def qt_event_to_keysym(ev):
    """Map a PyQt6 QKeyEvent cleanly to an X11 keysym for QEMU RFB."""
    k = ev.key()
    if k in _QT_KEY_TO_KEYSYM:
        return _QT_KEY_TO_KEYSYM[k]

    shift = bool(ev.modifiers() & Qt.KeyboardModifier.ShiftModifier)
    if Qt.Key.Key_A <= k <= Qt.Key.Key_Z:
        base = ord("A") if shift else ord("a")
        return base + (int(k) - int(Qt.Key.Key_A))

    if shift and k in _SHIFTED_PUNCT:
        return _SHIFTED_PUNCT[k]

    if 0x20 <= int(k) <= 0x7E:
        return int(k)

    nvk = ev.nativeVirtualKey()
    if nvk:
        return int(nvk)

    txt = ev.text()
    if txt and 0x20 <= ord(txt[0]) <= 0xFF:
        return ord(txt[0])
    return 0


class RfbSignals(QObject):
    resized = pyqtSignal(int, int)
    damaged = pyqtSignal(int, int, int, int)
    closed = pyqtSignal()


class SagrViewer(QWidget):
    """Qt6 canvas streaming QEMU's local VNC Raw BGRA8 framebuffer on LXQt."""

    def __init__(self, port, qemu_proc):
        super().__init__()
        self._port = port
        self._proc = qemu_proc
        self._sock = None
        self._send_lock = threading.Lock()
        self._fb_lock = threading.Lock()
        self._fb_w = 800
        self._fb_h = 600
        self._fb_buf = bytearray(self._fb_w * self._fb_h * 4)
        self._pressed_keysyms = set()
        self._active_key_map = {}
        self._stopping = False

        self.setWindowTitle("SOLOS SAGR Desktop (LXQt Qt6)")
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
        self.resize(1280, 800)

        self._sig = RfbSignals()
        self._sig.resized.connect(self._on_resized)
        self._sig.damaged.connect(self._on_damaged)
        self._sig.closed.connect(self._on_closed)

        self._thread = threading.Thread(target=self._rfb_loop, daemon=True)
        self._thread.start()

    def _recvn(self, n):
        buf = bytearray()
        while len(buf) < n:
            chunk = self._sock.recv(n - len(buf))
            if not chunk:
                raise EOFError("RFB stream closed")
            buf.extend(chunk)
        return bytes(buf)

    def _send(self, payload):
        with self._send_lock:
            if self._sock is not None:
                try:
                    self._sock.sendall(payload)
                except OSError:
                    pass

    def _send_key(self, down, keysym):
        if keysym == 0:
            return
        if down:
            self._pressed_keysyms.add(keysym)
        else:
            self._pressed_keysyms.discard(keysym)
        self._send(struct.pack(">BBHI", 4, 1 if down else 0, 0, keysym & 0xFFFFFFFF))

    def _release_all_keys(self):
        for ks in list(self._pressed_keysyms):
            self._send_key(False, ks)

    def _rfb_loop(self):
        try:
            sock = None
            for _ in range(100):
                if self._stopping or self._proc.poll() is not None:
                    return
                try:
                    sock = socket.create_connection(("127.0.0.1", self._port), timeout=2.0)
                    break
                except OSError:
                    time.sleep(0.05)
            if sock is None:
                return
            sock.settimeout(None)
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            self._sock = sock

            _ = self._recvn(12)  # server RFB version
            self._send(b"RFB 003.008\n")
            n_sec = self._recvn(1)[0]
            secs = self._recvn(n_sec)
            if 1 not in secs:
                return
            self._send(b"\x01")
            if struct.unpack(">I", self._recvn(4))[0] != 0:
                return
            self._send(b"\x01")  # shared ClientInit

            init = self._recvn(24)
            w, h = struct.unpack(">HH", init[:4])
            nlen = struct.unpack(">I", init[20:24])[0]
            _ = self._recvn(nlen)

            with self._fb_lock:
                self._fb_w, self._fb_h = w, h
                self._fb_buf = bytearray(w * h * 4)
            self._sig.resized.emit(w, h)

            # SetEncodings: Raw (0), DesktopSize (-223)
            self._send(struct.pack(">BBHii", 2, 0, 2, 0, -223))
            self._send(struct.pack(">BBHHHH", 3, 0, 0, 0, w, h))

            cur_w, cur_h = w, h
            while not self._stopping:
                msg_type = self._recvn(1)[0]
                if msg_type == 0:  # FramebufferUpdate
                    _pad, nrects = struct.unpack(">BH", self._recvn(3))
                    need_full = False
                    dx0, dy0, dx1, dy1 = cur_w, cur_h, 0, 0
                    for _ in range(nrects):
                        rx, ry, rw, rh, enc = struct.unpack(">HHHHi", self._recvn(12))
                        if enc == -223:
                            cur_w, cur_h = rw, rh
                            with self._fb_lock:
                                self._fb_w, self._fb_h = cur_w, cur_h
                                self._fb_buf = bytearray(cur_w * cur_h * 4)
                            self._sig.resized.emit(cur_w, cur_h)
                            need_full = True
                        elif enc == 0:
                            raw = self._recvn(rw * rh * 4)
                            with self._fb_lock:
                                if rw == cur_w and rx == 0 and (ry + rh) <= cur_h:
                                    off = ry * cur_w * 4
                                    self._fb_buf[off : off + len(raw)] = raw
                                else:
                                    row_bytes = rw * 4
                                    stride = cur_w * 4
                                    for r in range(rh):
                                        if ry + r < cur_h and rx + rw <= cur_w:
                                            dst = (ry + r) * stride + rx * 4
                                            src = r * row_bytes
                                            self._fb_buf[dst : dst + row_bytes] = raw[src : src + row_bytes]
                            dx0 = min(dx0, rx)
                            dy0 = min(dy0, ry)
                            dx1 = max(dx1, rx + rw)
                            dy1 = max(dy1, ry + rh)
                        else:
                            raise ValueError(f"Unsupported RFB encoding {enc}")

                    if dx1 > dx0 and dy1 > dy0:
                        self._sig.damaged.emit(dx0, dy0, dx1 - dx0, dy1 - dy0)
                    self._send(struct.pack(">BBHHHH", 3, 0 if need_full else 1, 0, 0, cur_w, cur_h))
                elif msg_type == 1:  # SetColourMapEntries
                    _ = self._recvn(3)
                    cnt = struct.unpack(">H", self._recvn(2))[0]
                    _ = self._recvn(cnt * 6)
                elif msg_type == 2:  # Bell
                    pass
                elif msg_type == 3:  # ServerCutText
                    _ = self._recvn(3)
                    tlen = struct.unpack(">I", self._recvn(4))[0]
                    _ = self._recvn(tlen)
        except (EOFError, OSError):
            pass
        finally:
            self._sig.closed.emit()

    def _on_resized(self, w, h):
        self.setWindowTitle(f"SOLOS SAGR Desktop ({w}x{h})")
        self.resize(w, h)
        self.update()

    def _on_damaged(self, x, y, w, h):
        if self._fb_w < 1 or self._fb_h < 1:
            return
        if self.width() == self._fb_w and self.height() == self._fb_h:
            self.update(QRect(x, y, w, h))
        else:
            self.update()

    def _on_closed(self):
        self.close()

    def event(self, ev):
        if ev.type() == QEvent.Type.ShortcutOverride:
            ev.accept()
            return True
        return super().event(ev)

    def keyPressEvent(self, ev):
        if ev.isAutoRepeat() and ev.key() in (Qt.Key.Key_Alt, Qt.Key.Key_Shift, Qt.Key.Key_Control, Qt.Key.Key_Meta):
            ev.accept()
            return
        ks = qt_event_to_keysym(ev)
        if ks:
            self._active_key_map[int(ev.key())] = ks
            self._send_key(True, ks)
        ev.accept()

    def keyReleaseEvent(self, ev):
        if ev.isAutoRepeat():
            ev.accept()
            return
        ks = self._active_key_map.pop(int(ev.key()), 0) or qt_event_to_keysym(ev)
        self._send_key(False, ks)
        ev.accept()

    def focusOutEvent(self, ev):
        self._active_key_map.clear()
        self._release_all_keys()
        super().focusOutEvent(ev)

    def paintEvent(self, ev):
        painter = QPainter(self)
        with self._fb_lock:
            img = QImage(self._fb_buf, self._fb_w, self._fb_h, self._fb_w * 4, QImage.Format.Format_RGB32)
            painter.drawImage(self.rect(), img)

    def closeEvent(self, ev):
        self._stopping = True
        self._release_all_keys()
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
        if self._proc.poll() is None:
            self._proc.terminate()
            try:
                self._proc.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                self._proc.kill()
        ev.accept()


def pick_free_vnc_port():
    for port in range(5900, 5999):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            s.bind(("127.0.0.1", port))
            return port
        except OSError:
            pass
        finally:
            s.close()
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("Usage: sagr_viewer.py <qemu_cmd...>\n")
        return 2

    port = pick_free_vnc_port()
    vnc_disp = port - 5900
    qemu_cmd = sys.argv[1:] + ["-vnc", f"127.0.0.1:{vnc_disp}", "-display", "none"]

    proc = subprocess.Popen(qemu_cmd)
    app = QApplication([sys.argv[0]])
    win = SagrViewer(port, proc)
    win.show()
    qt_rc = app.exec()

    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=2.0)
        except subprocess.TimeoutExpired:
            proc.kill()
    rc = proc.returncode if proc.returncode is not None else qt_rc
    # isa-debug-exit 42 -> exit code 85 indicates clean SAGR exit with 0 PMM leaks
    return 0 if rc in (0, 85) else rc


if __name__ == "__main__":
    raise SystemExit(main())
