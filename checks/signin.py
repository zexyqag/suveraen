"""Signs a person in with a password at Kanidm's own pages, as a browser that holds no session does, for an OAuth2
authorize URL: the sign-in, the consent page whenever Kanidm shows one, and the redirect Kanidm ends at.

usage: signin deliver URL PERSON PASSWORD [--resolve HOST:ADDRESS]... --cacert FILE
           URL is the one a device's client printed; its loopback listener gets the redirect, as from a browser
       signin token ORIGIN CLIENT REDIRECT PERSON PASSWORD [--resolve HOST:ADDRESS]... --cacert FILE
           asks Kanidm at ORIGIN for CLIENT's tokens by PKCE, as the dashboard does, and prints them
       signin app URL PERSON PASSWORD [--resolve HOST:ADDRESS]... --cacert FILE
           opens an app's sign-in at URL, which sends the browser to Kanidm and takes it back, and prints the page the
           app sends it to last, which must load
Fails, with the page Kanidm ended at, when it sends the browser nowhere."""

import argparse
import base64
import hashlib
import html
import http.cookiejar
import json
import re
import secrets
import socket
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument("--resolve", action="append", default=[], help="HOST:ADDRESS, as curl's")
parser.add_argument("--cacert", required=True)
modes = parser.add_subparsers(dest="mode", required=True)
deliver = modes.add_parser("deliver")
deliver.add_argument("url")
token = modes.add_parser("token")
token.add_argument("origin")
token.add_argument("client")
token.add_argument("redirect")
app = modes.add_parser("app")
app.add_argument("url")
for mode in [deliver, token, app]:
    mode.add_argument("person")
    mode.add_argument("password")
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


class Keep(http.cookiejar.DefaultCookiePolicy):
    def set_ok(self, cookie, request):
        return True

    def return_ok(self, cookie, request):
        return True


class Stay(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_):
        return None


# A new jar each time: no session of an earlier sign-in carries over.
browser = urllib.request.build_opener(
    Stay,
    urllib.request.ProxyHandler({}),
    urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar(policy=Keep())),
    urllib.request.HTTPSHandler(context=context),
)


def go(url, form=None):
    data = urllib.parse.urlencode(form).encode() if form is not None else None
    try:
        with browser.open(urllib.request.Request(url, data=data), timeout=30) as r:
            return r.status, r.headers.get("Location"), r.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("Location"), e.read().decode(errors="replace")


def walk(url):
    """Where Kanidm sends the browser once the person is signed in and has consented."""
    parts = urllib.parse.urlsplit(url)
    origin = f"{parts.scheme}://{parts.netloc}"
    steps = []

    def step(path, form=None):
        here = urllib.parse.urljoin(origin, path)
        while True:
            status, location, body = go(here, form)
            steps.append((urllib.parse.urlsplit(here).path, status))
            # Kanidm's own redirects are followed; the one out of Kanidm is where the walk ends.
            if status not in (302, 303, 307) or not location:
                return status, location, body
            here, form = urllib.parse.urljoin(here, location), None
            if not here.startswith(origin + "/"):
                return status, here, body

    step(url)
    status, location, body = step("/ui/login/begin", {"username": args.person, "password": "", "totp": ""})
    if "/ui/login/pw" in body:
        status, location, body = step("/ui/login/pw", {"password": args.password})
    consent = re.search(r'name="consent_token"\s+value="([^"]+)"', body) or re.search(
        r'value="([^"]+)"\s+name="consent_token"', body
    )
    if consent:
        status, location, body = step("/ui/oauth2/consent", {"consent_token": html.unescape(consent.group(1))})
    if status in (302, 303, 307) and location:
        return location
    text = re.sub(r"\s+", " ", re.sub(r"<[^>]*>", " ", body)).strip()
    sys.exit(f"Kanidm sent the browser nowhere: {steps}: {text[:600]}")


if args.mode == "deliver":
    query = urllib.parse.parse_qs(urllib.parse.urlsplit(args.url).query)
    back = walk(args.url)
    assert back.startswith(query["redirect_uri"][0]), (back, query["redirect_uri"])
    # The device's listener takes the code from here, as from the browser, and says how its own exchange went. It
    # may start listening only after its client printed the page.
    plain = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    for attempt in range(30):
        try:
            with plain.open(back, timeout=60) as r:
                status, page = r.status, r.read().decode(errors="replace")
            break
        except urllib.error.HTTPError as e:
            status, page = e.code, e.read().decode(errors="replace")
            break
        except urllib.error.URLError as e:
            if not isinstance(e.reason, ConnectionRefusedError) or attempt == 29:
                raise
            time.sleep(1)
    print(json.dumps({"status": status, "page": re.sub(r"\s+", " ", re.sub(r"<[^>]*>", " ", page)).strip()[:300]}))
elif args.mode == "app":
    # The app sends the browser to Kanidm with a cookie of its own, which its way back checks.
    status, location, _ = go(args.url)
    assert status in (302, 303, 307) and location, (status, location)
    here = walk(urllib.parse.urljoin(args.url, location))
    for _ in range(10):
        status, location, body = go(here)
        if status not in (302, 303, 307) or not location:
            break
        here = urllib.parse.urljoin(here, location)
    else:
        sys.exit(f"the app kept sending the browser on, last to {here}")
    if status != 200:
        sys.exit(f"the app ended the sign-in at {here} with {status}: {body[:300]}")
    print(json.dumps({"url": here}))
else:
    verifier = secrets.token_urlsafe(48)
    state = secrets.token_urlsafe(16)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    authorize = f"{args.origin}/ui/oauth2?" + urllib.parse.urlencode({
        "response_type": "code", "client_id": args.client, "redirect_uri": args.redirect, "scope": "openid",
        "state": state, "code_challenge": challenge, "code_challenge_method": "S256",
    })
    back = urllib.parse.urlsplit(walk(authorize))
    got = dict(urllib.parse.parse_qsl(back.query))
    assert f"{back.scheme}://{back.netloc}{back.path}" == args.redirect and got.get("state") == state, back
    status, _, body = go(f"{args.origin}/oauth2/token", {
        "grant_type": "authorization_code", "code": got["code"], "redirect_uri": args.redirect,
        "client_id": args.client, "code_verifier": verifier,
    })
    assert status == 200, (status, body)
    print(body)
