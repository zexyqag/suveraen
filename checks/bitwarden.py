"""A device of a Bitwarden account, as Bitwarden's own apps are to a server: it signs in through the server's single
sign-on, gives a new account its keys under a master password, keeps a login item with an attachment, and reads the
vault back, encrypting and decrypting all of it itself. What the device holds between calls is in its STATE file.

usage: bitwarden [--resolve HOST:ADDRESS]... --cacert FILE SERVER STATE COMMAND...
  authorize               prints the server's sign-in page for a new device, which sends a browser on to the
                          identity provider and back
  sso URL                 takes the code from the page the browser ended at, and signs the device in
  set-password MASTER [--hint HINT]
                          makes the account's keys and protects them with the master password
  api-key MASTER          prints the account's API key
  login ID SECRET MASTER [--phone]
                          signs a new device in by an API key, an Android phone with --phone, and unlocks the vault
                          with the master password
  push TOKEN              gives the server the token a phone's push service knows the phone by, as the phone apps do
                          once signed in, and prints the device's ID
  put NAME USERNAME PASSWORD FILE
                          stores a login item, and FILE as its attachment
  get                     prints each item of the vault, with its attachments, decrypted
  refresh                 renews the device's session by its refresh token
  upload ITEM SIZE RATE   sends an attachment of SIZE bytes, RATE bytes a second, takes it back as the apps do when
                          an upload fails, and prints how the upload ended
  hub SECONDS             holds the server's notifications open as the apps do, answering its pings, and prints what
                          came, with when
  call METHOD PATH [JSON] prints the server's status and answer to a call as the device
Each prints JSON, and fails when the server refuses what a device of an account in order would be given."""

import argparse
import base64
import hashlib
import hmac
import http.client
import json
import os
import re
import secrets
import socket
import ssl
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

from cryptography.hazmat.primitives import padding, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

parser = argparse.ArgumentParser()
parser.add_argument("--resolve", action="append", default=[], help="HOST:ADDRESS, as curl's")
parser.add_argument("--cacert", required=True)
parser.add_argument("server")
parser.add_argument("state")
commands = parser.add_subparsers(dest="command", required=True)
commands.add_parser("authorize")
commands.add_parser("sso").add_argument("url")
set_password = commands.add_parser("set-password")
set_password.add_argument("master")
set_password.add_argument("--hint")
commands.add_parser("api-key").add_argument("master")
login = commands.add_parser("login")
for name in ["id", "secret", "master"]:
    login.add_argument(name)
login.add_argument("--phone", action="store_true")
commands.add_parser("push").add_argument("token")
put = commands.add_parser("put")
for name in ["name", "username", "password", "file"]:
    put.add_argument(name)
commands.add_parser("get")
commands.add_parser("refresh")
upload = commands.add_parser("upload")
upload.add_argument("item")
upload.add_argument("size", type=int)
upload.add_argument("rate", type=int)
commands.add_parser("hub").add_argument("seconds", type=int)
call = commands.add_parser("call")
call.add_argument("method")
call.add_argument("path")
call.add_argument("body", nargs="?")
args = parser.parse_args()

# The names the test reaches through the server's gateway, which nothing resolves here.
pinned = dict(r.split(":", 1) for r in args.resolve)
lookup = socket.getaddrinfo


def pinned_lookup(host, *rest, **kw):
    return lookup(pinned.get(host, host), *rest, **kw)


socket.getaddrinfo = pinned_lookup

context = ssl.create_default_context(cafile=args.cacert)
# The test CA's root lacks extensions Python's strict mode wants; the chain is still verified.
context.verify_flags &= ~ssl.VERIFY_X509_STRICT
web = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=context))
server = args.server.rstrip("/")
# What Bitwarden's apps send: the web vault for a sign-in through the server's single sign-on, and for one by an API key
# the command line client, or an Android phone's app; and their release, as the web vault's that the server serves.
WEB, CLI, PHONE = {"client_id": "web", "deviceType": "9"}, {"deviceType": "25"}, {"deviceType": "0"}
ITERATIONS = 600000
with web.open(f"{server}/version.json", timeout=60) as r:
    release = {"Bitwarden-Client-Version": json.load(r)["version"]}

state = json.load(open(args.state)) if os.path.exists(args.state) else {}


def save():
    with open(args.state, "w") as f:
        json.dump(state, f)


def request(method, path, body=None, form=None, data=None, headers=None, auth=True):
    """The server's status and answer, parsed when it is JSON."""
    headers = {**release, **(headers or {})}
    if form is not None:
        data = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if auth:
        headers["Authorization"] = f"Bearer {state['access']}"
    asked = urllib.request.Request(server + path, data=data, headers=headers, method=method)
    try:
        with web.open(asked, timeout=60) as r:
            status, text = r.status, r.read()
    except urllib.error.HTTPError as e:
        status, text = e.code, e.read()
    try:
        return status, json.loads(text)
    except ValueError:
        return status, text


def ok(method, path, **kw):
    status, answer = request(method, path, **kw)
    if status != 200:
        sys.exit(f"{method} {path}: {status} {answer}")
    return answer


def claims(token):
    payload = token.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))


def b64(data):
    return base64.b64encode(data).decode()


# Bitwarden's keys: a master key from the master password and the account's mail, and keys of 64 bytes, one half to
# encrypt with AES-CBC and the other to authenticate with HMAC-SHA256.
def master_key(password, salt, iterations):
    return hashlib.pbkdf2_hmac("sha256", password.encode(), salt.strip().lower().encode(), iterations, 32)


def password_hash(key, password):
    return b64(hashlib.pbkdf2_hmac("sha256", key, password.encode(), 1, 32))


def stretched(key):
    # HKDF's expansion alone, of one block each.
    return b"".join(hmac.new(key, info + b"\x01", hashlib.sha256).digest() for info in [b"enc", b"mac"])


def encrypt(key, data):
    iv = os.urandom(16)
    pad = padding.PKCS7(128).padder()
    aes = Cipher(algorithms.AES(key[:32]), modes.CBC(iv)).encryptor()
    ciphertext = aes.update(pad.update(data) + pad.finalize()) + aes.finalize()
    return iv, ciphertext, hmac.new(key[32:], iv + ciphertext, hashlib.sha256).digest()


def decrypt(key, iv, ciphertext, mac):
    if not hmac.compare_digest(hmac.new(key[32:], iv + ciphertext, hashlib.sha256).digest(), mac):
        sys.exit("a MAC doesn't match")
    aes = Cipher(algorithms.AES(key[:32]), modes.CBC(iv)).decryptor()
    pad = padding.PKCS7(128).unpadder()
    return pad.update(aes.update(ciphertext) + aes.finalize()) + pad.finalize()


# Type 2 as the apps write it: as text, or as bytes for a file.
def seal(key, data):
    iv, ciphertext, mac = encrypt(key, data)
    return f"2.{b64(iv)}|{b64(ciphertext)}|{b64(mac)}"


def unseal(key, text):
    kind, _, parts = text.partition(".")
    assert kind == "2", text[:2]
    iv, ciphertext, mac = map(base64.b64decode, parts.split("|"))
    return decrypt(key, iv, ciphertext, mac)


def seal_file(key, data):
    iv, ciphertext, mac = encrypt(key, data)
    return b"\x02" + iv + mac + ciphertext


def unseal_file(key, data):
    assert data[0] == 2, data[:1]
    return decrypt(key, data[1:17], data[49:], data[17:49])


def user_key():
    return base64.b64decode(state["key"])


def signed_in(answer):
    state["access"] = answer["access_token"]
    state["refresh"] = answer.get("refresh_token")
    state["user"] = claims(answer["access_token"])["sub"]
    save()


def device():
    state.setdefault("device", str(uuid.uuid4()))
    return {"deviceIdentifier": state["device"], "deviceName": "e2e"}


def multipart(name, filename):
    """The content type of a form that sends one file, and what goes before and after the file."""
    boundary = secrets.token_hex(16)
    head = (
        f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"; filename="{filename}"\r\n'
        "Content-Type: application/octet-stream\r\n\r\n"
    ).encode()
    return f"multipart/form-data; boundary={boundary}", head, f"\r\n--{boundary}--\r\n".encode()


def attach(item, key, name, size):
    """A new attachment's record, as the apps ask for one before they send its file, and its ID."""
    return ok("POST", f"/api/ciphers/{item}/attachment/v2", body={
        "key": seal(user_key(), key), "fileName": name, "fileSize": size, "adminRequest": False,
    })["attachmentId"]


if args.command == "authorize":
    state.clear()
    state["verifier"] = secrets.token_urlsafe(48)
    state["state"] = secrets.token_urlsafe(16)
    save()
    challenge = base64.urlsafe_b64encode(hashlib.sha256(state["verifier"].encode()).digest()).decode().rstrip("=")
    print(f"{server}/identity/connect/authorize?" + urllib.parse.urlencode({
        "client_id": "web", "redirect_uri": f"{server}/sso-connector.html", "response_type": "code",
        "scope": "api offline_access", "state": state["state"], "code_challenge": challenge,
        "code_challenge_method": "S256", "response_mode": "query",
    }))
elif args.command == "sso":
    back = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(args.url).query))
    assert back.get("state") == state["state"], back
    answer = ok("POST", "/identity/connect/token", auth=False, form={
        "grant_type": "authorization_code", "code": back["code"], "code_verifier": state["verifier"],
        "redirect_uri": f"{server}/sso-connector.html", "scope": "api offline_access", **WEB, **device(),
    })
    signed_in(answer)
    print(json.dumps({"user": state["user"], "keys": "Key" in answer}))
elif args.command == "set-password":
    mail = ok("GET", "/api/accounts/profile")["email"]
    master = master_key(args.master, mail, ITERATIONS)
    key = os.urandom(64)
    private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    public = private.public_key().public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    der = private.private_bytes(
        serialization.Encoding.DER, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    )
    status, answer = request("POST", "/api/accounts/set-password", body={
        "kdf": 0, "kdfIterations": ITERATIONS, "kdfMemory": None, "kdfParallelism": None,
        "key": seal(stretched(master), key), "keys": {"encryptedPrivateKey": seal(key, der), "publicKey": b64(public)},
        "masterPasswordHash": password_hash(master, args.master), "masterPasswordHint": args.hint,
    })
    if status != 200:
        sys.exit(f"set-password: {status} {answer}")
    state["key"] = b64(key)
    save()
    print(json.dumps({"mail": mail}))
elif args.command == "api-key":
    mail = ok("GET", "/api/accounts/profile")["email"]
    hashed = password_hash(master_key(args.master, mail, ITERATIONS), args.master)
    answer = ok("POST", "/api/accounts/api-key", body={"masterPasswordHash": hashed})
    print(json.dumps({"id": f"user.{state['user']}", "secret": answer["apiKey"]}))
elif args.command == "login":
    state.clear()
    answer = ok("POST", "/identity/connect/token", auth=False, form={
        "grant_type": "client_credentials", "client_id": args.id, "client_secret": args.secret, "scope": "api",
        **(PHONE if args.phone else CLI), **device(),
    })
    signed_in(answer)
    unlock = answer["UserDecryptionOptions"]["MasterPasswordUnlock"]
    master = master_key(args.master, unlock["Salt"], unlock["Kdf"]["Iterations"])
    key = unseal(stretched(master), answer["Key"])
    serialization.load_der_private_key(unseal(key, answer["PrivateKey"]), None)
    state["key"] = b64(key)
    save()
    print(json.dumps({"user": state["user"], "mail": unlock["Salt"]}))
elif args.command == "push":
    ok("PUT", f"/api/devices/identifier/{state['device']}/token", body={"pushToken": args.token})
    print(json.dumps({"device": state["device"]}))
elif args.command == "put":
    key = user_key()
    with open(args.file, "rb") as f:
        data = f.read()
    item = ok("POST", "/api/ciphers", body={
        "type": 1, "name": seal(key, args.name.encode()), "notes": None, "favorite": False, "reprompt": 0,
        "login": {"username": seal(key, args.username.encode()), "password": seal(key, args.password.encode()),
                  "uris": None, "totp": None},
        "fields": None, "passwordHistory": None, "key": None, "folderId": None, "organizationId": None,
        "encryptedFor": state["user"],
    })["id"]
    attachment_key = os.urandom(64)
    name = seal(key, os.path.basename(args.file).encode())
    sealed = seal_file(attachment_key, data)
    attachment = attach(item, attachment_key, name, len(sealed))
    content, head, tail = multipart("data", name)
    ok("POST", f"/api/ciphers/{item}/attachment/{attachment}", data=head + sealed + tail,
       headers={"Content-Type": content})
    print(json.dumps({"item": item, "attachment": attachment}))
elif args.command == "get":
    key = user_key()
    items = []
    for c in ok("GET", "/api/sync?excludeDomains=true")["ciphers"]:
        attachments = []
        for a in c.get("attachments") or []:
            attachment_key = unseal(key, a["key"])
            with web.open(a["url"], timeout=60) as r:
                data = unseal_file(attachment_key, r.read())
            attachments.append({"id": a["id"], "name": unseal(key, a["fileName"]).decode(),
                                "sha256": hashlib.sha256(data).hexdigest()})
        items.append({
            "id": c["id"], "name": unseal(key, c["name"]).decode(),
            "username": unseal(key, c["login"]["username"]).decode(),
            "password": unseal(key, c["login"]["password"]).decode(),
            "attachments": sorted(attachments, key=lambda a: a["id"]),
        })
    print(json.dumps(sorted(items, key=lambda i: i["id"])))
elif args.command == "refresh":
    answer = ok("POST", "/identity/connect/token", auth=False, form={
        "grant_type": "refresh_token", "refresh_token": state["refresh"], "client_id": WEB["client_id"],
    })
    signed_in(answer)
    print(json.dumps({"user": state["user"]}))
elif args.command == "upload":
    name = seal(user_key(), b"paced")
    attachment = attach(args.item, os.urandom(64), name, args.size)
    content, head, tail = multipart("data", name)
    where = urllib.parse.urlsplit(server)
    connection = http.client.HTTPSConnection(where.hostname, where.port or 443, context=context,
                                             timeout=args.size / args.rate * 2)

    def paced():
        yield head
        for _ in range(args.size // args.rate):
            yield os.urandom(args.rate)
            time.sleep(1)
        yield os.urandom(args.size % args.rate) + tail

    start = time.monotonic()
    ended = {"attachment": attachment}
    try:
        connection.request("POST", f"/api/ciphers/{args.item}/attachment/{attachment}", body=paced(), headers={
            **release, "Authorization": f"Bearer {state['access']}", "Content-Type": content,
            "Content-Length": str(len(head) + args.size + len(tail)),
        })
        response = connection.getresponse()
        ended["status"] = response.status
        ended["answer"] = response.read().decode(errors="replace")[:300]
    except OSError as e:
        ended["error"] = repr(e)
    ended["seconds"] = round(time.monotonic() - start)
    connection.close()
    ended["rollback"] = request("DELETE", f"/api/ciphers/{args.item}/attachment/{attachment}")[0]
    print(json.dumps(ended))
elif args.command == "hub":
    where = urllib.parse.urlsplit(server)
    hub = context.wrap_socket(socket.create_connection((where.hostname, where.port or 443), timeout=30),
                              server_hostname=where.hostname)
    hub.sendall((
        f"GET /notifications/hub?access_token={state['access']} HTTP/1.1\r\nHost: {where.netloc}\r\n"
        f"Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {b64(os.urandom(16))}\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    ).encode())
    received = b""
    while b"\r\n\r\n" not in received:
        received += hub.recv(4096) or sys.exit(f"the hub answered {received!r}")
    head, _, received = received.partition(b"\r\n\r\n")
    assert head.startswith(b"HTTP/1.1 101 "), head

    def read(n):
        global received
        while len(received) < n:
            received += hub.recv(65536) or sys.exit("the hub closed the connection")
        data, received = received[:n], received[n:]
        return data

    def send(opcode, payload):
        mask = os.urandom(4)
        n = len(payload)
        size = bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack(">H", n)
        hub.sendall(bytes([0x80 | opcode]) + size + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    send(1, json.dumps({"protocol": "messagepack", "version": 1}).encode() + b"\x1e")
    start = time.monotonic()
    came = []
    ended = "held"
    while (left := start + args.seconds - time.monotonic()) > 0:
        hub.settimeout(left)
        try:
            first, second = read(2)
            n = second & 0x7F
            n = struct.unpack(">H", read(2))[0] if n == 126 else struct.unpack(">Q", read(8))[0] if n == 127 else n
            opcode, payload = first & 0x0F, read(n)
        except TimeoutError:
            break
        except SystemExit as e:
            ended = str(e)
            break
        if opcode == 9:
            send(10, payload)
        elif opcode == 8:
            ended = "closed by the server"
            break
        else:
            came.append([round(time.monotonic() - start), re.sub(rb"[^ -~]", b".", payload).decode()])
    hub.close()
    print(json.dumps({"ended": ended, "came": came}))
elif args.command == "call":
    status, answer = request(args.method, args.path, body=None if args.body is None else json.loads(args.body))
    if isinstance(answer, bytes):
        answer = answer.decode(errors="replace")
    print(json.dumps({"status": status, "answer": answer}))
