"""App Store Connect API client shared by the scripts/asc-*.py tools.

Standard library only and Python 3.9 compatible: the scripts run on the Mac's
/usr/bin/python3 (Apple's 3.9) over a bare SSH session, as well as on the CI
runners.

Credentials are the App Store Connect API key the upload uses:
ASC_API_KEY_ID, ASC_API_ISSUER_ID and the .p8 at ASC_API_KEY_PATH (default
~/.appstoreconnect/private/AuthKey_<ASC_API_KEY_ID>.p8, as in the Makefile).
A non-interactive SSH session reads no ~/.env, so Client.from_env() loads it
first; variables already set win. ASC_APP_ID overrides the app (Waycar).

Every request times out after 30 s. A GET that fails for a temporary reason
(HTTP 5xx or 429, a refused, reset or timed-out connection) is retried with
exponential backoff, four attempts in all. A POST is never replayed blindly:
after a temporary failure it is sent again only when the caller's verify()
says the earlier attempt did not land. Failures raise ASCError, whose message
names the request and Apple's error detail; .temporary says whether a later
try may succeed.
"""
import base64
import http.client
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

API = "https://api.appstoreconnect.apple.com"
WAYCAR_APP_ID = "6815881853"
TOKEN_LIFETIME = 20 * 60  # the longest App Store Connect accepts
TOKEN_REFRESH = 15 * 60
TEMPFAIL = 75  # EX_TEMPFAIL: the exit code of a temporary failure


class ASCError(Exception):
    def __init__(self, message, temporary=False, retry_after=None):
        super().__init__(message)
        self.temporary = temporary
        self.retry_after = retry_after


def log(message):
    print(f"asc: {message}", file=sys.stderr, flush=True)


def load_env(path="~/.env"):
    """Export the KEY=value lines of path, keeping variables already set."""
    try:
        with open(os.path.expanduser(path)) as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        return
    for line in lines:
        line = line.strip()
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        name, sep, value = line.partition("=")
        if not sep or not name.isidentifier():
            continue
        value = value.strip()
        if value[:1] in ("'", '"') and value.find(value[0], 1) > 0:
            value = value[1:value.find(value[0], 1)]
        else:
            value = value.split(" #", 1)[0].rstrip()
        os.environ.setdefault(name, value)


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=")


def der_to_raw(der):
    """openssl prints an ECDSA signature as a DER SEQUENCE of r and s; ES256 wants r || s."""
    r_length = der[3]
    r = der[4:4 + r_length]
    s_length = der[5 + r_length]
    s = der[6 + r_length:6 + r_length + s_length]
    return r.lstrip(b"\x00").rjust(32, b"\x00") + s.lstrip(b"\x00").rjust(32, b"\x00")


def sign_token(key_id, issuer, key_path, now):
    """An ES256 API token, signed by openssl (the standard library has no ECDSA)."""
    header = b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    payload = b64(json.dumps({"iss": issuer, "iat": int(now), "exp": int(now) + TOKEN_LIFETIME,
                              "aud": "appstoreconnect-v1"}).encode())
    signing = header + b"." + payload
    try:
        proc = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path],
                              input=signing, capture_output=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as error:
        raise ASCError(f"signing the API token failed: {error}")
    if proc.returncode != 0:
        detail = proc.stderr.decode(errors="replace").strip()
        raise ASCError(f"signing the API token with {key_path} failed: {detail}")
    return (signing + b"." + b64(der_to_raw(proc.stdout))).decode()


def http_error(method, path, error):
    detail = ""
    try:
        errors = json.loads(error.read() or b"{}").get("errors") or []
        detail = "; ".join(" ".join(filter(None, (e.get("code"), e.get("detail") or e.get("title"))))
                           for e in errors)
    except (ValueError, OSError, AttributeError, http.client.HTTPException):
        pass
    retry_after = None
    try:
        retry_after = float(error.headers.get("Retry-After"))
    except (TypeError, ValueError, AttributeError):
        pass
    return ASCError(f"{method} {path} failed: HTTP {error.code} {detail or error.reason}",
                    temporary=error.code == 429 or error.code >= 500, retry_after=retry_after)


class Client:
    def __init__(self, key_id, issuer, key_path, app_id=WAYCAR_APP_ID, timeout=30, attempts=4,
                 backoff=2.0, urlopen=urllib.request.urlopen, sleep=time.sleep, clock=time.time,
                 sign=sign_token):
        self.key_id = key_id
        self.issuer = issuer
        self.key_path = key_path
        self.app_id = app_id
        self.timeout = timeout
        self.attempts = attempts
        self.backoff = backoff
        self.urlopen = urlopen
        self.sleep = sleep
        self.clock = clock
        self.sign = sign
        self._token = None
        self._token_at = 0.0

    @classmethod
    def from_env(cls, **options):
        load_env()
        missing = [name for name in ("ASC_API_KEY_ID", "ASC_API_ISSUER_ID") if not os.environ.get(name)]
        if missing:
            raise ASCError(f"{' and '.join(missing)} not set: export it or add it to ~/.env")
        key_id = os.environ["ASC_API_KEY_ID"]
        key_path = os.path.expanduser(os.path.expandvars(
            os.environ.get("ASC_API_KEY_PATH") or f"~/.appstoreconnect/private/AuthKey_{key_id}.p8"))
        if not os.path.isfile(key_path):
            raise ASCError(f"no API key at {key_path} (set ASC_API_KEY_PATH)")
        return cls(key_id, os.environ["ASC_API_ISSUER_ID"], key_path,
                   app_id=os.environ.get("ASC_APP_ID") or WAYCAR_APP_ID, **options)

    def token(self):
        now = self.clock()
        if self._token is None or now - self._token_at >= TOKEN_REFRESH:
            self._token = self.sign(self.key_id, self.issuer, self.key_path, now)
            self._token_at = now
        return self._token

    def _send(self, method, path, body):
        """One attempt: the decoded JSON body, or None when it is empty."""
        request = urllib.request.Request(
            API + path, method=method, data=None if body is None else json.dumps(body).encode(),
            headers={"Authorization": "Bearer " + self.token(), "Content-Type": "application/json"})
        try:
            with self.urlopen(request, timeout=self.timeout) as response:
                raw = response.read()
        except urllib.error.HTTPError as error:
            raise http_error(method, path, error)
        except (OSError, http.client.HTTPException) as error:
            reason = getattr(error, "reason", None) or error
            raise ASCError(f"{method} {path} failed: {type(error).__name__}: {reason}", temporary=True)
        try:
            return json.loads(raw) if raw else None
        except ValueError as error:
            raise ASCError(f"{method} {path} answered with no JSON: {error}", temporary=True)

    def _delay(self, attempt, error):
        delay = self.backoff * 2 ** (attempt - 1)
        if error.retry_after is not None:
            delay = max(delay, min(error.retry_after, 60.0))
        return delay

    def get(self, path):
        for attempt in range(1, self.attempts + 1):
            try:
                return self._send("GET", path, None)
            except ASCError as error:
                if not error.temporary or attempt == self.attempts:
                    raise
                delay = self._delay(attempt, error)
                log(f"{error}; retrying in {delay:g} s (attempt {attempt + 1} of {self.attempts})")
                self.sleep(delay)

    def get_all(self, path):
        """Every item of a paged list, following links.next."""
        items = []
        while path:
            page = self.get(path)
            items.extend(page.get("data") or [])
            following = (page.get("links") or {}).get("next")
            if following and not following.startswith(API + "/"):
                raise ASCError(f"GET {path}: next page outside {API}: {following}")
            path = following[len(API):] if following else None
        return items

    def post(self, path, body, verify=None):
        """POST once. After a temporary failure, wait, then ask verify() whether the
        earlier attempt landed: True counts as success, False sends it again.
        Without verify, a failed POST is never replayed."""
        for attempt in range(1, self.attempts + 1):
            try:
                return self._send("POST", path, body)
            except ASCError as error:
                if not error.temporary or verify is None or attempt == self.attempts:
                    raise
                delay = self._delay(attempt, error)
                log(f"{error}; checking in {delay:g} s whether it landed")
                self.sleep(delay)
                if verify():
                    log(f"POST {path} had landed")
                    return None
                log(f"POST {path} did not land; sending it again (attempt {attempt + 1} of {self.attempts})")


def run(main):
    """Run a script's main(): an ASCError goes to stderr as one line, and the exit
    code is TEMPFAIL for a temporary failure, 1 otherwise."""
    try:
        return main()
    except ASCError as error:
        print(f"{os.path.basename(sys.argv[0])}: {error}", file=sys.stderr, flush=True)
        return TEMPFAIL if error.temporary else 1
