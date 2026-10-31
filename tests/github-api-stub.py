"""A fake of the few GitHub REST endpoints the App token flow uses.

It checks what the real API would: the JWT is RS256, signed by the App's key
(read from the same file the machine uses) and current; installation tokens are
only handed to a JWT; a registration token only to an installation token that
carries organization_self_hosted_runners=write. Every token request is appended
to a JSON-lines log, so the test can see how it was narrowed.

Usage: github-api-stub.py PORT LOG APP_ID=KEY_FILE...
"""

import itertools
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import jwt
from cryptography.hazmat.primitives import serialization

port = int(sys.argv[1])
log_path = sys.argv[2]
apps = dict(arg.split("=", 1) for arg in sys.argv[3:])

INSTALLATIONS = [
    {"id": 7, "account": {"login": "Avunu"}},
    {"id": 8, "account": {"login": "someone-else"}},
]

counter = itertools.count(1)
issued = {}  # installation token -> what it was narrowed to


def public_key(app_id):
    with open(apps[app_id], "rb") as f:
        return serialization.load_pem_private_key(f.read(), None).public_key()


def log(entry):
    with open(log_path, "a") as f:
        f.write(json.dumps(entry) + "\n")


class Handler(BaseHTTPRequestHandler):
    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        return json.loads(raw) if raw.strip() else {}

    def app_from_jwt(self):
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return None
        token = auth[len("Bearer ") :]
        iss = jwt.decode(token, options={"verify_signature": False})["iss"]
        if iss not in apps:
            return None
        claims = jwt.decode(token, public_key(iss), algorithms=["RS256"])
        if not claims["iat"] <= time.time() <= claims["exp"]:
            return None
        if claims["exp"] - claims["iat"] > 600:
            return None
        return iss

    def do_GET(self):
        if self.path.startswith("/app/installations"):
            if self.app_from_jwt() is None:
                return self.reply(401, {"message": "A JSON web token could not be decoded"})
            return self.reply(200, INSTALLATIONS)
        self.reply(404, {"message": "Not Found"})

    def do_POST(self):
        body = self.body()
        if self.path == "/app/installations/7/access_tokens":
            app_id = self.app_from_jwt()
            if app_id is None:
                return self.reply(401, {"message": "A JSON web token could not be decoded"})
            token = f"ghs_stub{next(counter):04d}"
            issued[token] = body
            log({"kind": "installation", "app": app_id, "body": body})
            return self.reply(201, {"token": token, "expires_at": "2099-01-01T00:00:00Z"})
        if self.path == "/orgs/Avunu/actions/runners/registration-token":
            auth = self.headers.get("Authorization", "")
            token = auth.removeprefix("token ").removeprefix("Bearer ")
            grant = issued.get(token)
            if grant is None:
                return self.reply(401, {"message": "Bad credentials"})
            if grant.get("permissions", {}).get("organization_self_hosted_runners") != "write":
                return self.reply(403, {"message": "Resource not accessible by integration"})
            log({"kind": "registration", "grant": grant})
            return self.reply(201, {"token": f"REGSTUB{next(counter):04d}"})
        self.reply(404, {"message": "Not Found"})

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
