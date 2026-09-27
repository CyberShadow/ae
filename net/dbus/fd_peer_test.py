import array
import os
import select
import socket
import struct

address = os.environ["DBUS_SESSION_BUS_ADDRESS"]
path = address.split("path=", 1)[1].split(",", 1)[0]
u32 = struct.Struct("<I")


def align(data, size):
    return data + b"\0" * (-len(data) % size)


def string(value):
    data = value.encode()
    return u32.pack(len(data)) + data + b"\0"


def signature(value):
    data = value.encode()
    return bytes([len(data)]) + data + b"\0"


def field(code, value):
    kind = {1: "o", 2: "s", 3: "s", 5: "u", 6: "s", 8: "g", 9: "u"}[code]
    prefix = bytes([code]) + signature(kind)
    payload = signature(value) if kind == "g" else (
        u32.pack(value) if kind == "u" else string(value)
    )
    return align(prefix, 4) + payload if kind != "g" else prefix + payload


def frame(serial, fields, body=b"", message_type=1):
    headers = b""
    for code, value in fields:
        headers = align(headers, 8) + field(code, value)
    return b"l" + bytes([message_type, 0, 1]) + u32.pack(len(body)) + u32.pack(serial) + u32.pack(len(headers)) + align(headers, 8) + body


class Peer:
    def __init__(self):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.connect(path)
        uid = str(os.getuid()).encode().hex().encode()
        self.socket.sendall(b"\0AUTH EXTERNAL " + uid + b"\r\n")
        assert self.line().startswith(b"OK ")
        self.socket.sendall(b"NEGOTIATE_UNIX_FD\r\n")
        assert self.line() == b"AGREE_UNIX_FD\r\n"
        self.socket.sendall(b"BEGIN\r\n")
        self.buffer = b""
        self.socket.sendall(frame(1, [
            (1, "/org/freedesktop/DBus"), (2, "org.freedesktop.DBus"),
            (3, "Hello"), (6, "org.freedesktop.DBus")]))
        while True:
            packet, _ = self.read()
            if packet[1] == 2 and packet[8:12] == u32.pack(1):
                body = packet[(16 + int.from_bytes(packet[12:16], "little") + 7) & ~7:]
                self.name = body[4:-1].decode()
                break

    def line(self):
        data = b""
        while not data.endswith(b"\r\n"):
            data += self.socket.recv(1)
        return data

    def read(self):
        while True:
            if len(self.buffer) >= 16:
                header_length = int.from_bytes(self.buffer[12:16], "little")
                body_length = int.from_bytes(self.buffer[4:8], "little")
                length = ((16 + header_length + 7) & ~7) + body_length
                if len(self.buffer) >= length:
                    packet, self.buffer = self.buffer[:length], self.buffer[length:]
                    return packet, self.fds
            assert select.select([self.socket], [], [], 5)[0], "timed out waiting for D-Bus frame"
            data, ancillary, _, _ = self.socket.recvmsg(65536, socket.CMSG_SPACE(16))
            assert data, "D-Bus peer disconnected"
            self.fds = [fd for level, kind, payload in ancillary
                        if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS
                        for fd in array.array("i", payload)]
            self.buffer += data

    def close(self):
        self.socket.close()


receiver = Peer()
sender = Peer()
fd = os.open("/dev/null", os.O_RDONLY)
try:
    deliver_serial = 2
    message = frame(deliver_serial, [
        (1, "/org/freedesktop/Notifications"),
        (2, "org.freedesktop.Notifications"), (3, "Deliver"),
        (6, receiver.name), (8, "h"), (9, 1)], u32.pack(0))
    sender.socket.sendmsg([message], [(socket.SOL_SOCKET, socket.SCM_RIGHTS,
                                       array.array("i", [fd]))])
    while True:
        packet, received_fds = receiver.read()
        if packet[1] == 1:
            assert received_fds, "fd-bearing call arrived without SCM_RIGHTS"
            for received_fd in received_fds:
                os.close(received_fd)
            receiver.socket.sendall(frame(2, [(5, deliver_serial), (6, sender.name)],
                                          message_type=2))
            break
    while True:
        packet, _ = sender.read()
        if packet[1] == 2:
            break
    print(f"deliver-serial={deliver_serial} sender={sender.name}")
finally:
    os.close(fd)
    sender.close()
    receiver.close()
