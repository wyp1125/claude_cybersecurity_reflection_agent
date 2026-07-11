"""
Local client for the Strands Agent API Gateway endpoint.

Authentication flow (PKCE):
  1. Opens a browser tab to the Cognito hosted UI → user signs in with Google
  2. Cognito redirects to localhost:9999/callback with an authorization code
  3. Script exchanges the code for tokens using the PKCE verifier
  4. Uses the id_token as a Bearer token for the API call

Required environment variables:
  COGNITO_DOMAIN     e.g. https://cybersecurity-reflection-agent-auth.auth.us-east-1.amazoncognito.com
  COGNITO_CLIENT_ID  from `terraform output user_pool_client_id`
  API_URL            from `terraform output api_url`
"""

import base64
import hashlib
import http.server
import json
import os
import secrets
import sys
import threading
import urllib.parse
import urllib.request
import webbrowser

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

COGNITO_DOMAIN = os.environ["COGNITO_DOMAIN"].rstrip("/")
CLIENT_ID = os.environ["COGNITO_CLIENT_ID"]
API_URL = os.environ["API_URL"]

CALLBACK_PORT = 9999
CALLBACK_URL = f"http://localhost:{CALLBACK_PORT}/callback"
LOGIN_TIMEOUT_SECONDS = 120


def _pkce_pair() -> tuple[str, str]:
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode()
    challenge = (
        base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest())
        .rstrip(b"=")
        .decode()
    )
    return verifier, challenge


def _get_id_token() -> str:
    """Open browser for Google login, catch the OAuth callback, return id_token."""
    verifier, challenge = _pkce_pair()
    state = secrets.token_hex(8)
    code_holder: dict = {}

    class _CallbackHandler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path.startswith("/callback"):
                params = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                code_holder["code"] = params.get("code", [None])[0]
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"Login successful. You can close this tab.")
            else:
                self.send_response(404)
                self.end_headers()

        def log_message(self, *args):
            pass  # suppress server output

    server = http.server.HTTPServer(("localhost", CALLBACK_PORT), _CallbackHandler)
    thread = threading.Thread(target=server.handle_request, daemon=True)
    thread.start()

    auth_url = (
        f"{COGNITO_DOMAIN}/oauth2/authorize"
        f"?response_type=code"
        f"&client_id={CLIENT_ID}"
        f"&redirect_uri={urllib.parse.quote(CALLBACK_URL)}"
        f"&scope=email+openid+profile"
        f"&code_challenge={challenge}"
        f"&code_challenge_method=S256"
        f"&identity_provider=Google"
        f"&state={state}"
    )
    print("Opening browser for Google login...")
    webbrowser.open(auth_url)
    thread.join(timeout=LOGIN_TIMEOUT_SECONDS)

    code = code_holder.get("code")
    if not code:
        raise RuntimeError("Login timed out or was cancelled")

    # Exchange authorization code for tokens
    token_body = urllib.parse.urlencode({
        "grant_type": "authorization_code",
        "client_id": CLIENT_ID,
        "redirect_uri": CALLBACK_URL,
        "code": code,
        "code_verifier": verifier,
    }).encode()

    req = urllib.request.Request(
        f"{COGNITO_DOMAIN}/oauth2/token",
        data=token_body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    with urllib.request.urlopen(req) as resp:
        tokens = json.loads(resp.read())

    return tokens["id_token"]


def invoke(input_text: str, id_token: str) -> dict | None:
    payload = json.dumps({"inputText": input_text}).encode()
    req = urllib.request.Request(
        API_URL,
        data=payload,
        headers={
            "Authorization": f"Bearer {id_token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        body = exc.read().decode(errors="replace")
        if exc.code == 429:
            error = json.loads(body).get("error", "Call limit reached")
            print(f"Quota exhausted: {error}")
            return None
        raise RuntimeError(f"HTTP {exc.code}: {body}") from exc


if __name__ == "__main__":
    id_token = _get_id_token()
    print("Login successful.")

    issue = input("Describe your cybersecurity issue: ").strip()
    if not issue:
        print("No input provided.")
        sys.exit(0)

    result = invoke(issue, id_token)
    if result:
        print("\n--- NIST 800-53 Mapping ---")
        print(result.get("response", result))
        if "score" in result:
            print(f"\nScore: {result['score']}/5  |  Rounds: {result['rounds']}")
