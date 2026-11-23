"""A stand-in for Bitwarden's push relay and its identity server, over TLS for every name under ZONE, with a
certificate it makes from a CA's key as it starts: it gives any installation a token, answers every call as the relay
does, and keeps each request it gets, with its answer, as a line of JSON in KEPT.

usage: push-relay CA-CERT CA-KEY ZONE ADDRESS KEPT"""
import datetime
import http.server
import json
import secrets
import ssl
import sys
import tempfile

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

ca_cert, ca_key, zone, address, kept = sys.argv[1:]
with open(ca_cert, "rb") as f:
    issuer = x509.load_pem_x509_certificate(f.read())
with open(ca_key, "rb") as f:
    signer = serialization.load_pem_private_key(f.read(), None)
key = ec.generate_private_key(ec.SECP256R1())
now = datetime.datetime.now(datetime.timezone.utc)
certificate = (
    x509.CertificateBuilder()
    .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, f"*.{zone}")]))
    .issuer_name(issuer.subject)
    .public_key(key.public_key())
    .serial_number(x509.random_serial_number())
    .not_valid_before(now - datetime.timedelta(days=1))
    .not_valid_after(now + datetime.timedelta(days=30))
    .add_extension(x509.SubjectAlternativeName([x509.DNSName(f"*.{zone}")]), critical=False)
    .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
    .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
    .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
    .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(issuer.public_key()), critical=False)
    .sign(signer, hashes.SHA256())
)
pem = tempfile.NamedTemporaryFile(suffix=".pem")
pem.write(key.private_bytes(
    serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
))
pem.write(certificate.public_bytes(serialization.Encoding.PEM))
pem.flush()
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(pem.name)
token = secrets.token_hex(32)


class Relay(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode(errors="replace")
        answer = None
        if self.path == "/connect/token":
            answer = {"access_token": token, "expires_in": 3600, "token_type": "Bearer", "scope": "api.push"}
        with open(kept, "a") as f:
            f.write(json.dumps({"host": self.headers["Host"], "path": self.path, "body": body, "answer": answer,
                                "headers": {k.lower(): v for k, v in self.headers.items()}}) + "\n")
        data = b"" if answer is None else json.dumps(answer).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


open(kept, "a").close()
server = http.server.ThreadingHTTPServer((address, 443), Relay)
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
