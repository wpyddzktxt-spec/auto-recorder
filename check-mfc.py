#!/usr/bin/env python3
"""MFC model status checker via WebSocket protocol.
Connects to wchat[N].myfreecams.com:443/fcsl (WSS), authenticates as guest,
receives model data broadcast, and returns online/offline status + HLS URL.

Usage: python3 check-mfc.py <model_uid>
Output: "online|<hls_url>|<viewers>|" or "offline"
"""

import sys, socket, ssl, random, string, time, base64, json, urllib.parse

CHAT_SERVERS = [
    "wchat28", "wchat29", "wchat30", "wchat10", "wchat11", "wchat12",
    "wchat13", "wchat14", "wchat15", "wchat16", "wchat17", "wchat18",
    "wchat19", "wchat21", "wchat22", "wchat23", "wchat24", "wchat25",
    "wchat26", "wchat31", "wchat32", "wchat33", "wchat34", "wchat35",
    "wchat36", "wchat37", "wchat38", "wchat39", "wchat40", "wchat41",
    "wchat43", "wchat44", "wchat45", "wchat46", "wchat47", "wchat48",
    "wchat49", "wchat50", "wchat51", "wchat52", "wchat53", "wchat54",
    "wchat55", "wchat56", "wchat57", "wchat58", "wchat59", "wchat60",
    "wchat61", "wchat62", "wchat63", "wchat64", "wchat66", "wchat67",
    "wchat68", "wchat69", "wchat70", "wchat71", "wchat72", "wchat73",
    "wchat74", "wchat75",
]

TIMEOUT_CONNECT = 8
MAX_WAIT = 25


def ws_send(sock, msg):
    data = msg.encode()
    length = len(data)
    frame = bytearray()
    frame.append(0x81)
    if length < 126:
        frame.append(0x80 | length)
    elif length < 65536:
        frame.append(0x80 | 126)
        frame.extend(length.to_bytes(2, 'big'))
    else:
        frame.append(0x80 | 127)
        frame.extend(length.to_bytes(8, 'big'))
    mask_key = bytes(random.choices(range(256), k=4))
    frame.extend(mask_key)
    masked = bytes(b ^ mask_key[i % 4] for i, b in enumerate(data))
    frame.extend(masked)
    sock.send(bytes(frame))


def ws_recv(sock, timeout=3):
    sock.settimeout(timeout)
    try:
        data = sock.recv(65536)
        if len(data) < 2:
            return None
        opcode = data[0] & 0x0F
        length = data[1] & 0x7F
        offset = 2
        if length == 126:
            if len(data) < 4:
                return None
            length = int.from_bytes(data[2:4], 'big')
            offset = 4
        elif length == 127:
            if len(data) < 10:
                return None
            length = int.from_bytes(data[2:10], 'big')
            offset = 10
        payload = data[offset:]
        while len(payload) < length:
            chunk = sock.recv(min(65536, length - len(payload)))
            if not chunk:
                break
            payload += chunk
        if opcode == 0x01:
            return payload[:length].decode('utf-8', errors='replace')
        elif opcode == 0x09:
            pong_data = payload[:length]
            pong = bytearray([0x8A, len(pong_data)])
            pong.extend(pong_data)
            try:
                sock.send(bytes(pong))
            except Exception:
                pass
            return None
        return None
    except socket.timeout:
        return None
    except Exception:
        return None


def parse_mfc_message(msg):
    """Parse a single MFC message. Returns dict with uid,vs,camserv or None.
    
    Message formats:
    - Login:     "1 0 <sid> 0 0 <username>" (5 fields, no JSON)
    - Context:   "30 1 <sid> 0 0 <json>" (5 fields, JSON in last)
    - RespKey:   "81 0 <sid> 14 256 <json>" (5 fields)
    - Session:   "5 0 <sid> 0 0 <json>" (5 fields, uid=0)
    - Model:     "20 <from_sid> <to_sid> <vs> <uid> <json>" (6 fields!)
    """
    fields = msg.strip().split(None, 5)
    if len(fields) < 5:
        return None

    # For model messages (6 fields): fields[3] is vs, fields[4] starts with uid
    # For other messages (5 fields): JSON is in fields[4]
    
    # Try to extract JSON from the last field
    last_field = fields[-1]
    json_str = last_field
    
    # Check if the last field is "uid {json}" (model message)
    # or just "{json}" (other messages)
    space_idx = last_field.find(' ')
    if space_idx > 0:
        first_token = last_field[:space_idx]
        if first_token.lstrip('-').isdigit():
            # This is a model message: "uid {json}"
            uid_from_field = int(first_token)
            json_str = last_field[space_idx + 1:]
    
    # Try parsing as URL-encoded JSON
    try:
        json_str = urllib.parse.unquote(json_str)
        data = json.loads(json_str)
    except (json.JSONDecodeError, ValueError):
        return None
    
    if not isinstance(data, dict):
        return None
    
    uid = data.get('uid')
    vs = data.get('vs')
    
    # For model messages, vs may also be in fields[3]
    if vs is None and len(fields) >= 5:
        try:
            vs = int(fields[3])
        except (ValueError, TypeError):
            pass
    
    if uid is None or vs is None or uid <= 0:
        return None
    
    camserv = None
    u = data.get('u')
    if isinstance(u, dict):
        camserv = u.get('camserv')
    
    return {'uid': uid, 'vs': vs, 'camserv': camserv}


def connect_and_listen(target_uid):
    """Connect to MFC and listen for target model. Returns (online, hls_url)"""
    server = random.choice(CHAT_SERVERS)
    host = f"{server}.myfreecams.com"

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(TIMEOUT_CONNECT)
    sock.connect((host, 443))
    ctx = ssl.create_default_context()
    ssock = ctx.wrap_socket(sock, server_hostname=host)

    key = ''.join(random.choices(string.ascii_letters + string.digits, k=16))
    key_b64 = base64.b64encode(key.encode()).decode()
    upgrade = (
        f"GET /fcsl HTTP/1.1\r\n"
        f"Host: {host}\r\n"
        f"Upgrade: websocket\r\n"
        f"Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key_b64}\r\n"
        f"Sec-WebSocket-Version: 13\r\n"
        f"\r\n"
    )
    ssock.send(upgrade.encode())
    ssock.settimeout(5)
    response = ssock.recv(4096)
    if b'101' not in response:
        ssock.close()
        return False, ""

    ws_send(ssock, 'hello fcserver\n\x00')
    r_id = ''.join(random.choices('0123456789abcdef', k=32))
    ws_send(ssock, f'1 0 0 20071025 0 {r_id}@guest:guest\n')

    found = None
    start = time.time()

    try:
        while time.time() - start < MAX_WAIT:
            resp = ws_recv(ssock, timeout=3)
            if resp is None:
                continue

            buf = resp
            while len(buf) >= 6:
                try:
                    msglen = int(buf[:6])
                except ValueError:
                    buf = buf[1:]
                    continue
                if msglen <= 0:
                    buf = buf[1:]
                    continue
                if len(buf) < 6 + msglen:
                    break
                msg = buf[6:6 + msglen]
                buf = buf[6 + msglen:]

                entry = parse_mfc_message(msg)
                if entry and entry['uid'] == target_uid:
                    found = entry
                    break

            if found:
                break
    except Exception:
        pass
    finally:
        try:
            ssock.close()
        except Exception:
            pass

    if found and found['vs'] not in (None, 127):
        hls = ""
        if found.get('camserv'):
            uid_video = found['uid'] + 100000000
            hls = f"https://video{found['camserv']}.myfreecams.com/NxServer/ngrp:mfc_{uid_video}.mp4_mobile/playlist.m3u8"
        return True, hls

    return False, ""


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("offline")
        sys.exit(0)

    try:
        target_uid = int(sys.argv[1])
    except ValueError:
        print("offline")
        sys.exit(0)

    online, hls_url = connect_and_listen(target_uid)

    if online:
        print(f"online|{hls_url}|0||")
    else:
        print("offline")
