#!/usr/bin/env python3
"""App Store Connect helpers for the TestFlight job.

Reads ASC_ISSUER_ID, ASC_KEY_ID and ASC_PRIVATE_KEY from the environment.
Never prints those values. Team ID may be printed; it is not one of those secrets.
"""

import base64
import json
import os
import plistlib
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BUNDLE_ID = "de.barczewski.vela"
APP_NAME = "Vela"
APP_SKU = "vela"
API = "https://api.appstoreconnect.apple.com"


def env(name):
    return os.environ.get(name, "") or ""


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def der_to_raw(sig):
    """Convert an OpenSSL ECDSA DER signature to the 64-byte R||S form JWT uses."""
    if len(sig) < 8 or sig[0] != 0x30:
        fail("Could not sign the App Store Connect token.")
    index = 2
    if sig[1] & 0x80:
        index = 2 + (sig[1] & 0x7F)
    raw = []
    for _ in range(2):
        if index >= len(sig) or sig[index] != 0x02:
            fail("Could not sign the App Store Connect token.")
        length = sig[index + 1]
        index += 2
        value = sig[index:index + length]
        index += length
        if value[:1] == b"\x00":
            value = value[1:]
        if len(value) > 32:
            fail("Could not sign the App Store Connect token.")
        raw.append(value.rjust(32, b"\x00"))
    return raw[0] + raw[1]


def normalize_pem(text):
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    # A secret pasted as one line keeps the PEM escapes as the two characters \n.
    if text.count("\n") < 2 and "\\n" in text:
        text = text.replace("\\n", "\n")
    text = text.strip() + "\n"
    if "-----BEGIN" not in text or "-----END" not in text:
        fail("ASC_PRIVATE_KEY is missing the PEM BEGIN/END lines.")
    return text


def write_key():
    path = env("KEY_PATH")
    if not path:
        fail("KEY_PATH is not set.")
    pem = normalize_pem(env("ASC_PRIVATE_KEY"))
    with open(path, "w", encoding="ascii") as handle:
        handle.write(pem)
    os.chmod(path, 0o600)


def jwt_token():
    key_id = env("ASC_KEY_ID").strip()
    issuer = env("ASC_ISSUER_ID").strip()
    if not key_id or not issuer:
        fail("ASC_KEY_ID or ASC_ISSUER_ID is empty.")
    now = int(time.time())
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}, separators=(",", ":")).encode())
    payload = b64url(json.dumps({
        "iss": issuer,
        "iat": now - 30,
        "exp": now + 15 * 60,
        "aud": "appstoreconnect-v1",
    }, separators=(",", ":")).encode())
    signing_input = f"{header}.{payload}".encode("ascii")
    signed = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", env("KEY_PATH")],
        input=signing_input,
        capture_output=True,
        check=False,
    )
    if signed.returncode != 0:
        fail("Could not sign the App Store Connect token. Check that ASC_PRIVATE_KEY is the .p8 file.")
    return signing_input.decode("ascii") + "." + b64url(der_to_raw(signed.stdout))


def error_text(raw):
    text = raw.decode("utf-8", errors="replace")
    if "-----BEGIN" in text:
        return "App Store Connect returned an error body that was redacted."
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        return text[:800]
    lines = []
    for item in payload.get("errors") or []:
        title = item.get("title") or ""
        detail = item.get("detail") or ""
        lines.append(f"{title}: {detail}".strip(": "))
    return "\n".join(lines)[:1200] or text[:800]


def api(method, path, body=None):
    data = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(
        API + path,
        data=data,
        method=method,
        headers={
            "Authorization": "Bearer " + jwt_token(),
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": "Vela-CI",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read()
            status = response.status
    except urllib.error.HTTPError as error:
        raw = error.read()
        status = error.code
    if status == 401:
        fail("App Store Connect rejected the API key (HTTP 401). The key material was not printed.")
    if status >= 400:
        return status, {"errors": [{"title": "HTTP", "detail": error_text(raw)}]}
    if not raw:
        return status, {}
    return status, json.loads(raw)


def team_in_text(text):
    match = re.search(r"\(([A-Z0-9]{10})\)", text or "")
    if match:
        return match.group(1)
    match = re.search(r"(?:^|,|\s)OU=([A-Z0-9]{10})(?:,|$)", text or "")
    return match.group(1) if match else None


def team_from_certificate(b64_der):
    der = base64.b64decode(b64_der)
    inspected = subprocess.run(
        ["openssl", "x509", "-inform", "DER", "-noout", "-subject", "-nameopt", "RFC2253"],
        input=der,
        capture_output=True,
        check=False,
    )
    if inspected.returncode != 0:
        return None
    return team_in_text(inspected.stdout.decode("utf-8", errors="replace"))


def team_from_certificates():
    status, payload = api("GET", "/v1/certificates?limit=200")
    if status >= 400:
        print("Certificates could not be listed.")
        print(error_text(json.dumps(payload).encode()))
        return None
    for item in payload.get("data") or []:
        attributes = item.get("attributes") or {}
        team = team_in_text(attributes.get("name") or "")
        if team:
            return team
        content = attributes.get("certificateContent")
        if content:
            team = team_from_certificate(content)
            if team:
                return team
    return None


def team_from_profiles():
    status, payload = api("GET", "/v1/profiles?limit=20")
    if status >= 400:
        print("Profiles could not be listed.")
        print(error_text(json.dumps(payload).encode()))
        return None
    for item in payload.get("data") or []:
        content = (item.get("attributes") or {}).get("profileContent")
        if not content:
            continue
        try:
            decoded = subprocess.run(
                ["security", "cms", "-D"],
                input=base64.b64decode(content),
                capture_output=True,
                check=False,
            )
        except OSError:
            return None
        text = decoded.stdout.decode("utf-8", errors="replace")
        match = re.search(r"<key>TeamIdentifier</key>\s*<array>\s*<string>([A-Z0-9]{10})</string>", text)
        if match:
            return match.group(1)
        match = re.search(r"<key>ApplicationIdentifierPrefix</key>\s*<array>\s*<string>([A-Z0-9]{10})</string>", text)
        if match:
            return match.group(1)
    return None


def team_by_issuing_certificate():
    work = env("ASC_DIR")
    key_path = os.path.join(work, "lookup.key")
    csr_path = os.path.join(work, "lookup.csr")
    created = subprocess.run(
        [
            "openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes",
            "-keyout", key_path, "-out", csr_path,
            "-subj", "/CN=Vela CI team lookup",
        ],
        capture_output=True,
        check=False,
    )
    try:
        os.remove(key_path)
    except OSError:
        pass
    if created.returncode != 0:
        print("Could not build a certificate request to discover the Team ID.")
        return None
    with open(csr_path, "r", encoding="ascii") as handle:
        csr = handle.read()
    status, payload = api("POST", "/v1/certificates", {
        "data": {
            "type": "certificates",
            "attributes": {"certificateType": "DISTRIBUTION", "csrContent": csr},
        }
    })
    if status >= 400:
        print("No distribution certificate could be created to discover the Team ID.")
        print(error_text(json.dumps(payload).encode()))
        return None
    issued = payload.get("data") or {}
    attributes = issued.get("attributes") or {}
    team = team_in_text(attributes.get("name") or "")
    if not team and attributes.get("certificateContent"):
        team = team_from_certificate(attributes["certificateContent"])
    cert_id = issued.get("id")
    if cert_id:
        removed, _ = api("DELETE", "/v1/certificates/" + urllib.parse.quote(cert_id))
        if removed in (200, 202, 204):
            print("Removed the temporary distribution certificate used only to read the Team ID.")
        else:
            print("Could not remove the temporary distribution certificate.")
    return team


def resolve_team():
    supplied = env("DEVELOPMENT_TEAM").strip()
    if supplied:
        if not re.fullmatch(r"[A-Z0-9]{10}", supplied):
            fail("DEVELOPMENT_TEAM is set but is not a 10-character Team ID.")
        print("Using Team ID from DEVELOPMENT_TEAM.")
        return supplied
    for finder in (team_from_certificates, team_from_profiles, team_by_issuing_certificate):
        team = finder()
        if team:
            print(f"Team ID: {team}")
            return team
    fail(
        "Die Team-ID (10 Zeichen) konnte aus dem App-Store-Connect-Schlüssel nicht ermittelt werden.\n"
        "Automatisches Signieren braucht sie. Bitte das Repository-Secret DEVELOPMENT_TEAM setzen\n"
        "(App Store Connect → Benutzer und Zugriffsrechte, Mitgliedschaft, oder\n"
        "developer.apple.com/account → Membership Details).\n"
        "Es wurde kein Zertifikat und kein Profil gefunden, aus dem die Team-ID abgelesen werden kann."
    )


def revoke_unreferenced_distribution_certs():
    """Drop distribution certs no profile uses. CI has no private key for them, and a keyless cert blocks cloud signing."""
    status, payload = api("GET", "/v1/profiles?include=certificates&limit=50")
    if status >= 400:
        print("Skipping certificate cleanup because profiles could not be listed.")
        return
    used = set()
    for item in payload.get("data") or []:
        related = ((item.get("relationships") or {}).get("certificates") or {}).get("data") or []
        for cert in related:
            if cert.get("id"):
                used.add(cert["id"])
    for item in payload.get("included") or []:
        if item.get("type") == "certificates" and item.get("id"):
            used.add(item["id"])
    status, payload = api("GET", "/v1/certificates?limit=200")
    if status >= 400:
        return
    for item in payload.get("data") or []:
        kind = ((item.get("attributes") or {}).get("certificateType") or "").upper()
        if "DISTRIBUTION" not in kind:
            continue
        cert_id = item.get("id")
        if not cert_id or cert_id in used:
            continue
        removed, _ = api("DELETE", "/v1/certificates/" + urllib.parse.quote(cert_id))
        if removed in (200, 202, 204):
            print("Revoked an unused distribution certificate so cloud signing can create one that has a private key.")


def ensure_ci_device():
    """Archive automatic signing asks for a development profile, which Apple will not issue with zero devices."""
    status, payload = api("GET", "/v1/devices?filter[platform]=IOS&limit=5")
    if status >= 400:
        print("Could not list devices.")
        print(error_text(json.dumps(payload).encode()))
    elif payload.get("data"):
        print("An iOS device is already registered.")
        return
    # Stable fake UDID. 40 hex chars, then the newer 8-16 form if Apple rejects the first.
    candidates = (
        "A1B2C3D4E5F60718293A4B5C6D7E8F9012345678",
        "00008030-001C7D6E1A88002E",
    )
    last = ""
    for udid in candidates:
        status, payload = api("POST", "/v1/devices", {
            "data": {
                "type": "devices",
                "attributes": {"name": "Vela CI", "platform": "IOS", "udid": udid},
            }
        })
        if status in (200, 201, 409):
            print("Registered a CI device so Xcode can create a development profile without a plugged-in iPhone.")
            return
        last = error_text(json.dumps(payload).encode())
        if "duplicate" in last.lower() or "already" in last.lower():
            print("CI device is already registered.")
            return
    print("Could not register a CI device.")
    print(last)
    fail(
        "OWNER ACTION: The team has no iOS device, so Apple will not create a development profile.\n"
        "Add any iPhone under developer.apple.com/account → Certificates, Identifiers & Profiles → Devices,\n"
        "or let the API key register one (Admin). Then re-run this workflow."
    )


def ensure_bundle_id(team):
    query = urllib.parse.urlencode({"filter[identifier]": BUNDLE_ID, "limit": "5"})
    status, payload = api("GET", "/v1/bundleIds?" + query)
    if status < 400:
        for item in payload.get("data") or []:
            if (item.get("attributes") or {}).get("identifier") == BUNDLE_ID:
                print(f"Bundle ID already registered: {BUNDLE_ID}")
                return
    attributes = {"name": APP_NAME, "identifier": BUNDLE_ID, "platform": "IOS"}
    if team:
        attributes["seedId"] = team
    status, payload = api("POST", "/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": attributes}})
    if status in (200, 201):
        print(f"Registered bundle ID {BUNDLE_ID}.")
        return
    detail = error_text(json.dumps(payload).encode())
    if status == 409 or "already" in detail.lower() or "ENTITY_ERROR" in detail:
        print(f"Bundle ID already registered: {BUNDLE_ID}")
        return
    print(f"Could not register bundle ID {BUNDLE_ID} (HTTP {status}).")
    print(detail)
    print("Continuing; Xcode may register it during automatic signing.")


def write_export_options(team, method):
    path = os.path.join(env("ASC_DIR"), "ExportOptions.plist")
    with open(path, "wb") as handle:
        plistlib.dump({
            "method": method,
            "destination": "upload",
            "signingStyle": "automatic",
            "teamID": team,
            "uploadSymbols": True,
            "manageAppVersionAndBuildNumber": False,
        }, handle, fmt=plistlib.FMT_XML)
    print(f"ExportOptions: method {method}, destination upload, signingStyle automatic.")


def prepare():
    write_key()
    team = resolve_team()
    with open(os.path.join(env("ASC_DIR"), "team_id"), "w", encoding="ascii") as handle:
        handle.write(team + "\n")
    revoke_unreferenced_distribution_certs()
    ensure_ci_device()
    ensure_bundle_id(team)
    write_export_options(team, "app-store-connect")
    print("No app extensions. App Intents use " + BUNDLE_ID + ".")


def owner_app_record():
    print(
        "OWNER ACTION: In App Store Connect gibt es noch keinen App-Eintrag.\n"
        "Apps → + → New App:\n"
        f"  Name: {APP_NAME}\n"
        f"  Bundle ID: {BUNDLE_ID}\n"
        f"  SKU: {APP_SKU}\n"
        "  Primäre Sprache: Deutsch (de-DE)\n"
        "App Intents laufen in derselben Bundle-ID; eine Extension ist nicht nötig."
    )


def poll():
    query = urllib.parse.urlencode({"filter[bundleId]": BUNDLE_ID, "limit": "5"})
    status, payload = api("GET", "/v1/apps?" + query)
    if status >= 400:
        print(f"Could not look up the app record (HTTP {status}).")
        print(error_text(json.dumps(payload).encode()))
        return 0
    apps = payload.get("data") or []
    if not apps:
        owner_app_record()
        return 1
    app_id = apps[0]["id"]
    version = env("GITHUB_RUN_NUMBER").strip()
    print(f"App record exists. Waiting for build {version} to appear in TestFlight processing.")
    deadline = time.time() + 15 * 60
    while time.time() < deadline:
        query = urllib.parse.urlencode({
            "filter[app]": app_id,
            "filter[version]": version,
            "limit": "5",
        })
        status, payload = api("GET", "/v1/builds?" + query)
        builds = payload.get("data") or [] if status < 400 else []
        if builds:
            attributes = builds[0].get("attributes") or {}
            state = attributes.get("processingState") or "unknown"
            print(f"TestFlight build {version}: {state}")
            if state == "VALID":
                print("The build finished processing and is available in TestFlight.")
                return 0
            if state in ("FAILED", "INVALID"):
                print("Apple rejected the build during processing.")
                return 1
        else:
            print("Build not listed yet.")
        time.sleep(30)
    print("Upload was accepted. Apple is still processing the build for TestFlight.")
    return 0


def scrub(path):
    if not os.path.isfile(path):
        return
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    secrets = [env("ASC_PRIVATE_KEY"), env("ASC_KEY_ID"), env("ASC_ISSUER_ID")]
    for secret in secrets:
        if not secret:
            continue
        text = text.replace(secret, "***")
        for line in secret.splitlines():
            if len(line) >= 8:
                text = text.replace(line, "***")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "prepare":
        prepare()
    elif command == "poll":
        raise SystemExit(poll())
    elif command == "scrub" and len(sys.argv) == 3:
        scrub(sys.argv[2])
    elif command == "owner-app":
        owner_app_record()
        raise SystemExit(1)
    else:
        fail("usage: asc_testflight.py prepare|poll|scrub <log>|owner-app")


if __name__ == "__main__":
    main()
