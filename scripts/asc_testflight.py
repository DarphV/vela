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
# Apple allows three Apple Distribution certificates. A lower effective limit is handled when the API refuses.
DISTRIBUTION_LIMIT = 3


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


def resolve_team():
    """Read a team id if one is already visible. Never creates or revokes a certificate."""
    supplied = env("DEVELOPMENT_TEAM").strip()
    if supplied:
        if not re.fullmatch(r"[A-Z0-9]{10}", supplied):
            fail("DEVELOPMENT_TEAM is set but is not a 10-character Team ID.")
        print("Using Team ID from DEVELOPMENT_TEAM.")
        return supplied
    for finder in (team_from_certificates, team_from_profiles):
        team = finder()
        if team:
            print(f"Team ID: {team}")
            return team
    return ""


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


def bundle_resource_id():
    query = urllib.parse.urlencode({"filter[identifier]": BUNDLE_ID, "limit": "5"})
    status, payload = api("GET", "/v1/bundleIds?" + query)
    if status >= 400:
        return None
    for item in payload.get("data") or []:
        if (item.get("attributes") or {}).get("identifier") == BUNDLE_ID:
            return item.get("id")
    return None


def ensure_bundle_id(team):
    found = bundle_resource_id()
    if found:
        print(f"Bundle ID already registered: {BUNDLE_ID}")
        return found
    attributes = {"name": APP_NAME, "identifier": BUNDLE_ID, "platform": "IOS"}
    if team:
        attributes["seedId"] = team
    status, payload = api("POST", "/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": attributes}})
    if status in (200, 201):
        print(f"Registered bundle ID {BUNDLE_ID}.")
        return (payload.get("data") or {}).get("id") or bundle_resource_id()
    detail = error_text(json.dumps(payload).encode())
    if status == 409 or "already" in detail.lower() or "ENTITY_ERROR" in detail:
        print(f"Bundle ID already registered: {BUNDLE_ID}")
        return bundle_resource_id()
    print(f"Could not register bundle ID {BUNDLE_ID} (HTTP {status}).")
    print(detail)
    return None


def distribution_certificates():
    status, payload = api("GET", "/v1/certificates?limit=200")
    if status >= 400:
        print("Certificates could not be listed.")
        print(error_text(json.dumps(payload).encode()))
        return None
    found = []
    for item in payload.get("data") or []:
        kind = ((item.get("attributes") or {}).get("certificateType") or "").upper()
        if "DISTRIBUTION" in kind:
            found.append(item)
    return found


def certificate_serial(pem):
    inspected = subprocess.run(
        ["openssl", "x509", "-noout", "-serial"],
        input=pem if isinstance(pem, bytes) else pem.encode(),
        capture_output=True,
        check=False,
    )
    if inspected.returncode != 0:
        return ""
    text = inspected.stdout.decode("utf-8", errors="replace").strip()
    if "=" in text:
        text = text.split("=", 1)[1]
    return text.upper().lstrip("0")


def secrets_env():
    token = env("GH_SECRETS_TOKEN").strip()
    if not token:
        return None
    child = os.environ.copy()
    child["GH_TOKEN"] = token
    return child


def remember_signing_secret(name, path):
    """Store a secret for the next run. The file contents are never printed."""
    repo = os.environ.get("GITHUB_REPOSITORY") or "DarphV/vela"
    child = secrets_env()
    if child is None:
        print("GH_SECRETS_TOKEN is not set, so the p12 cannot be stored.")
        return False
    with open(path, "rb") as handle:
        stored = subprocess.run(
            ["gh", "secret", "set", name, "--repo", repo],
            stdin=handle,
            capture_output=True,
            check=False,
            env=child,
        )
    if stored.returncode != 0:
        detail = stored.stderr.decode("utf-8", errors="replace")
        detail = re.sub(r"[A-Za-z0-9+/=]{24,}", "***", detail)
        print(f"Could not save {name} for later runs ({detail.strip()[:240]}).")
        return False
    print(f"Saved {name} for later runs. The value was not printed.")
    return True


def write_p12(key_path, cert_pem, password):
    work = env("ASC_DIR")
    cert_path = os.path.join(work, "cert.pem")
    p12_path = os.path.join(work, "dist.p12")
    pass_path = os.path.join(work, "p12.pass")
    with open(cert_path, "wb") as handle:
        handle.write(cert_pem if isinstance(cert_pem, bytes) else cert_pem.encode())
    with open(pass_path, "w", encoding="utf-8") as handle:
        handle.write(password)
    os.chmod(pass_path, 0o600)
    exported = subprocess.run(
        [
            "openssl", "pkcs12", "-export", "-legacy",
            "-inkey", key_path, "-in", cert_path, "-out", p12_path,
            "-passout", "file:" + pass_path,
        ],
        capture_output=True,
        check=False,
    )
    if exported.returncode != 0:
        exported = subprocess.run(
            [
                "openssl", "pkcs12", "-export",
                "-inkey", key_path, "-in", cert_path, "-out", p12_path,
                "-passout", "file:" + pass_path,
            ],
            capture_output=True,
            check=False,
        )
    if exported.returncode != 0:
        fail("Could not build the distribution PKCS#12 file.")
    os.chmod(p12_path, 0o600)
    b64_path = os.path.join(work, "dist.p12.b64")
    with open(p12_path, "rb") as src, open(b64_path, "wb") as dst:
        dst.write(base64.b64encode(src.read()))
    os.chmod(b64_path, 0o600)
    saved = remember_signing_secret("VELA_DIST_P12_BASE64", b64_path) and remember_signing_secret("VELA_DIST_P12_PASSWORD", pass_path)
    try:
        os.remove(b64_path)
    except OSError:
        pass
    if saved:
        print("The distribution certificate will be reused on the next run.")
    else:
        print("This run can still sign. The workflow token could not store the private key, so a later run cannot reuse this certificate.")
    return saved


def reuse_saved_p12():
    encoded = env("VELA_DIST_P12_BASE64").strip()
    password = env("VELA_DIST_P12_PASSWORD")
    if not encoded or not password:
        return None
    try:
        raw = base64.b64decode(encoded, validate=True)
    except Exception:
        fail("The saved distribution certificate could not be read. Nothing was revoked or replaced.")
    work = env("ASC_DIR")
    p12_path = os.path.join(work, "dist.p12")
    pass_path = os.path.join(work, "p12.pass")
    with open(p12_path, "wb") as handle:
        handle.write(raw)
    with open(pass_path, "w", encoding="utf-8") as handle:
        handle.write(password)
    os.chmod(p12_path, 0o600)
    os.chmod(pass_path, 0o600)
    pem = subprocess.run(
        ["openssl", "pkcs12", "-in", p12_path, "-nokeys", "-passin", "file:" + pass_path, "-legacy"],
        capture_output=True,
        check=False,
    )
    if pem.returncode != 0:
        pem = subprocess.run(
            ["openssl", "pkcs12", "-in", p12_path, "-nokeys", "-passin", "file:" + pass_path],
            capture_output=True,
            check=False,
        )
    if pem.returncode != 0 or b"BEGIN CERTIFICATE" not in pem.stdout:
        fail("The saved distribution certificate could not be unlocked. Nothing was revoked or replaced.")
    with open(os.path.join(work, "cert.pem"), "wb") as handle:
        handle.write(pem.stdout)
    print("Reusing the saved distribution certificate. No certificate will be created or revoked.")
    return pem.stdout


def profile_for_certificate(cert_id, bundle):
    status, payload = api("GET", "/v1/profiles?filter[profileType]=IOS_APP_STORE&include=bundleId,certificates&limit=100")
    if status >= 400:
        return None
    included = {item.get("id"): item for item in payload.get("included") or []}
    for item in payload.get("data") or []:
        relationships = item.get("relationships") or {}
        certs = ((relationships.get("certificates") or {}).get("data") or [])
        if cert_id not in {cert.get("id") for cert in certs}:
            continue
        bundle_ref = ((relationships.get("bundleId") or {}).get("data") or {})
        bundle_item = included.get(bundle_ref.get("id")) or {}
        identifier = (bundle_item.get("attributes") or {}).get("identifier")
        if bundle and identifier and identifier != BUNDLE_ID:
            continue
        content = (item.get("attributes") or {}).get("profileContent")
        name = (item.get("attributes") or {}).get("name") or "Vela App Store"
        if content and name:
            return name, content
    return None


def install_profile(name, content_b64):
    with open(os.path.join(env("ASC_DIR"), "vela.mobileprovision"), "wb") as handle:
        handle.write(base64.b64decode(content_b64))
    with open(os.path.join(env("ASC_DIR"), "profile_name"), "w", encoding="utf-8") as handle:
        handle.write(name + "\n")
    print(f"Using App Store profile {name}.")


def create_profile(team, cert_id, preferred_name):
    bundle = ensure_bundle_id(team)
    if not bundle:
        fail(f"Bundle ID {BUNDLE_ID} is not registered, so no App Store profile can be created.")
    run = env("GITHUB_RUN_NUMBER").strip() or "ci"
    names = []
    for name in (preferred_name, f"Vela App Store {run}", f"Vela {run}"):
        if name and name not in names:
            names.append(name)
    last = ""
    for name in names:
        status, payload = api("POST", "/v1/profiles", {
            "data": {
                "type": "profiles",
                "attributes": {"name": name, "profileType": "IOS_APP_STORE"},
                "relationships": {
                    "bundleId": {"data": {"type": "bundleIds", "id": bundle}},
                    "certificates": {"data": [{"type": "certificates", "id": cert_id}]},
                },
            }
        })
        if status in (200, 201):
            content = ((payload.get("data") or {}).get("attributes") or {}).get("profileContent")
            if content:
                install_profile(name, content)
                return
            fail("App Store Connect created a profile but did not return its contents. Nothing was revoked.")
        detail = error_text(json.dumps(payload).encode()) if status >= 400 else ""
        print(f"Profile '{name}' was not created (HTTP {status}).")
        if detail:
            print(detail[:500])
        last = detail
        duplicate = status == 409 or "already" in detail.lower() or "duplicate" in detail.lower()
        if not duplicate:
            fail("Could not create the App Store provisioning profile. Nothing was revoked.")
    fail("Could not create the App Store provisioning profile because those names are already used. Nothing was revoked.\n" + last[:400])


def issue_app_store_signing(team):
    """Use one distribution certificate forever. This function never deletes or revokes certificates."""
    reused = reuse_saved_p12()
    cert_id = None
    if reused:
        serial = certificate_serial(reused)
        listed = distribution_certificates()
        if listed is None:
            fail("Could not list certificates. Nothing was revoked.")
        for item in listed:
            raw = ((item.get("attributes") or {}).get("serialNumber") or "").upper().lstrip("0")
            if serial and raw == serial:
                cert_id = item.get("id")
                learned = team_in_text((item.get("attributes") or {}).get("name") or "")
                if not learned and (item.get("attributes") or {}).get("certificateContent"):
                    learned = team_from_certificate(item["attributes"]["certificateContent"])
                if learned:
                    team = learned
                break
        if not cert_id:
            fail(
                "The saved distribution certificate is not on the Apple account.\n"
                "This workflow will not revoke anything and will not create a replacement over a saved key."
            )
    else:
        fail(
            "No saved distribution certificate (VELA_DIST_P12_BASE64 / VELA_DIST_P12_PASSWORD).\n"
            "OWNER ACTION, from the iPhone:\n"
            "1. Create a fine-grained GitHub token with Secrets read and write on DarphV/vela, and save it as the secret GH_SECRETS_TOKEN.\n"
            "2. If the account is already full, revoke one old Apple Distribution certificate yourself in the developer portal.\n"
            "3. Actions → Create signing cert → Run workflow.\n"
            "4. Re-run iOS Build.\n"
            "This release job does not create or revoke certificates."
        )
    existing = profile_for_certificate(cert_id, team)
    if existing:
        install_profile(existing[0], existing[1])
        print("Reusing the existing App Store profile. No profile was deleted.")
    else:
        create_profile(team, cert_id, "Vela App Store")
    return team


def write_export_options(team, profile_name):
    path = os.path.join(env("ASC_DIR"), "ExportOptions.plist")
    with open(path, "wb") as handle:
        plistlib.dump({
            "method": "app-store-connect",
            "destination": "upload",
            "signingStyle": "manual",
            "signingCertificate": "Apple Distribution",
            "teamID": team,
            "provisioningProfiles": {BUNDLE_ID: profile_name},
            "uploadSymbols": True,
            "manageAppVersionAndBuildNumber": False,
        }, handle, fmt=plistlib.FMT_XML)
    print("ExportOptions: method app-store-connect, destination upload, signingStyle manual.")


def patch_app_signing(team, profile_name):
    """Put the App Store profile on the app target only. A command-line specifier also hits Swift packages, which cannot use it."""
    path = "Vela.xcodeproj/project.pbxproj"
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()
    pieces = text.split("isa = XCBuildConfiguration;")
    rebuilt = [pieces[0]]
    patched = 0
    for piece in pieces[1:]:
        if "PRODUCT_BUNDLE_IDENTIFIER = de.barczewski.vela;" in piece:
            piece, _ = re.subn(r"CODE_SIGN_STYLE = [^;]+;", "CODE_SIGN_STYLE = Manual;", piece)
            piece, _ = re.subn(r"DEVELOPMENT_TEAM = [^;]+;", f"DEVELOPMENT_TEAM = {team};", piece)
            piece, _ = re.subn(r'CODE_SIGN_IDENTITY = [^;]+;', 'CODE_SIGN_IDENTITY = "Apple Distribution";', piece)
            piece, _ = re.subn(
                r'PROVISIONING_PROFILE_SPECIFIER = [^;]+;',
                f'PROVISIONING_PROFILE_SPECIFIER = "{profile_name}";',
                piece,
            )
            extra = []
            if "CODE_SIGN_STYLE = Manual;" not in piece:
                extra.append("CODE_SIGN_STYLE = Manual;")
            if f"DEVELOPMENT_TEAM = {team};" not in piece:
                extra.append(f"DEVELOPMENT_TEAM = {team};")
            if 'CODE_SIGN_IDENTITY = "Apple Distribution";' not in piece:
                extra.append('CODE_SIGN_IDENTITY = "Apple Distribution";')
            quoted = f'PROVISIONING_PROFILE_SPECIFIER = "{profile_name}";'
            if quoted not in piece:
                extra.append(quoted)
            if extra:
                piece = piece.replace(
                    "PRODUCT_BUNDLE_IDENTIFIER = de.barczewski.vela;",
                    "PRODUCT_BUNDLE_IDENTIFIER = de.barczewski.vela;\n\t\t\t\t" + "\n\t\t\t\t".join(extra),
                    1,
                )
            patched += 1
        rebuilt.append("isa = XCBuildConfiguration;" + piece)
    if patched == 0:
        fail("Could not find the Vela target in the Xcode project to attach the App Store profile.")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("".join(rebuilt))
    print(f"App target uses the App Store profile ({patched} configuration(s)).")


def describe_distribution_certificates(certs):
    print("This job did not revoke any certificate.")
    if certs is None:
        print("The certificate list could not be read.")
        return
    print(f"Apple allows {DISTRIBUTION_LIMIT} Apple Distribution certificates. This account has {len(certs)}.")
    print("Revoke one yourself, then run Create signing cert again:")
    print("https://developer.apple.com/account/resources/certificates/list")
    if not certs:
        print("No distribution certificates are listed.")
        return
    for index, item in enumerate(certs, 1):
        attrs = item.get("attributes") or {}
        print(f"{index}. {attrs.get('name') or 'Apple Distribution'}")
        print(f"   expires: {attrs.get('expirationDate') or 'unknown'}")
        print(f"   serial: {attrs.get('serialNumber') or 'unknown'}")
        print(f"   id: {item.get('id') or 'unknown'}")


def saved_certificate_is_current(certs):
    if not env("VELA_DIST_P12_BASE64").strip() or not env("VELA_DIST_P12_PASSWORD"):
        return False
    pem = reuse_saved_p12()
    if not pem:
        return False
    serial = certificate_serial(pem)
    for item in certs:
        raw = ((item.get("attributes") or {}).get("serialNumber") or "").upper().lstrip("0")
        if serial and raw == serial:
            print("The saved certificate is still on the Apple account. Nothing new was created.")
            return True
    print("The saved certificate is no longer on the Apple account.")
    return False


def assert_can_store_secrets():
    child = secrets_env()
    if child is None:
        fail(
            "GH_SECRETS_TOKEN is missing. Add a fine-grained PAT with Secrets read and write on DarphV/vela.\n"
            "No certificate was created."
        )
    repo = os.environ.get("GITHUB_REPOSITORY") or "DarphV/vela"
    listed = subprocess.run(
        ["gh", "secret", "list", "--repo", repo],
        capture_output=True,
        check=False,
        env=child,
    )
    if listed.returncode != 0:
        detail = re.sub(r"[A-Za-z0-9+/=]{24,}", "***", listed.stderr.decode("utf-8", errors="replace"))
        fail("GH_SECRETS_TOKEN cannot read repository secrets. No certificate was created.\n" + detail.strip()[:300])


def create_signing_cert():
    """One-time certificate creation. Never deletes or revokes anything."""
    write_key()
    assert_can_store_secrets()
    certs = distribution_certificates()
    if certs is None:
        fail("Could not list certificates. Nothing was created or revoked.")
    if saved_certificate_is_current(certs):
        return
    if len(certs) >= DISTRIBUTION_LIMIT:
        describe_distribution_certificates(certs)
        fail(f"Already at the Apple Distribution limit ({DISTRIBUTION_LIMIT}). No certificate was created.")
    work = env("ASC_DIR")
    key_path = os.path.join(work, "dist.key")
    csr_path = os.path.join(work, "dist.csr")
    created = subprocess.run(
        [
            "openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes",
            "-keyout", key_path, "-out", csr_path,
            "-subj", "/CN=Vela CI Distribution",
        ],
        capture_output=True,
        check=False,
    )
    if created.returncode != 0:
        fail("Could not create a certificate request. No certificate was created.")
    os.chmod(key_path, 0o600)
    with open(csr_path, "r", encoding="ascii") as handle:
        csr = handle.read()
    status, payload = api("POST", "/v1/certificates", {
        "data": {
            "type": "certificates",
            "attributes": {"certificateType": "DISTRIBUTION", "csrContent": csr},
        }
    })
    if status >= 400:
        print(error_text(json.dumps(payload).encode()))
        describe_distribution_certificates(distribution_certificates())
        fail("Apple did not issue a certificate. Nothing was revoked.")
    issued = payload.get("data") or {}
    content = (issued.get("attributes") or {}).get("certificateContent")
    if not content:
        fail("App Store Connect did not return the new certificate. Nothing was revoked.")
    pem = subprocess.run(
        ["openssl", "x509", "-inform", "DER", "-outform", "PEM"],
        input=base64.b64decode(content),
        capture_output=True,
        check=False,
    )
    if pem.returncode != 0:
        fail("Could not read the new certificate. Nothing was revoked.")
    password = base64.b64encode(os.urandom(18)).decode("ascii")
    if not write_p12(key_path, pem.stdout, password):
        attrs = issued.get("attributes") or {}
        fail(
            "The certificate was created, but the private key could not be saved.\n"
            "Revoke that newest Apple Distribution certificate yourself, fix GH_SECRETS_TOKEN, and run this workflow again.\n"
            f"Name: {attrs.get('name') or 'Apple Distribution'}\n"
            f"Expires: {attrs.get('expirationDate') or 'unknown'}\n"
            f"Serial: {attrs.get('serialNumber') or 'unknown'}\n"
            "https://developer.apple.com/account/resources/certificates/list\n"
            "This job will not revoke it."
        )
    try:
        os.remove(key_path)
    except OSError:
        pass
    print("Distribution certificate stored for TestFlight. The private key was not printed.")


def prepare():
    write_key()
    team = resolve_team()
    team = issue_app_store_signing(team)
    if not re.fullmatch(r"[A-Z0-9]{10}", team or ""):
        fail("The Team ID is still unknown. No certificate was created or revoked while looking for it.")
    with open(os.path.join(env("ASC_DIR"), "team_id"), "w", encoding="ascii") as handle:
        handle.write(team + "\n")
    profile_name = open(os.path.join(env("ASC_DIR"), "profile_name"), encoding="utf-8").read().strip()
    patch_app_signing(team, profile_name)
    write_export_options(team, profile_name)
    print("No app extensions. App Intents use " + BUNDLE_ID + ".")


def owner_app_record():
    print(
        "OWNER ACTION: In App Store Connect gibt es noch keinen App-Eintrag.\n"
        "Apps → + → New App:\n"
        "  Name: Vela KI\n"
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
    secrets = [
        env("ASC_PRIVATE_KEY"),
        env("ASC_KEY_ID"),
        env("ASC_ISSUER_ID"),
        env("VELA_DIST_P12_BASE64"),
        env("VELA_DIST_P12_PASSWORD"),
        env("GH_SECRETS_TOKEN"),
    ]
    for secret in secrets:
        if not secret:
            continue
        text = text.replace(secret, "***")
        for line in secret.splitlines():
            if len(line) >= 8:
                text = text.replace(line, "***")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def redact_emails(text):
    return re.sub(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", "[email]", text)


def api_bytes(path):
    url = path if path.startswith("http") else API + path
    request = urllib.request.Request(
        url,
        method="GET",
        headers={
            "Authorization": "Bearer " + jwt_token(),
            "Accept": "*/*",
            "User-Agent": "Vela-CI",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            return response.status, response.read(), response.headers.get("Content-Type", "")
    except urllib.error.HTTPError as error:
        return error.code, error.read(), ""


def app_id():
    query = urllib.parse.urlencode({"filter[bundleId]": BUNDLE_ID, "limit": "5"})
    status, payload = api("GET", "/v1/apps?" + query)
    if status >= 400:
        fail("Could not look up the app. " + error_text(json.dumps(payload).encode()))
    for item in payload.get("data") or []:
        if (item.get("attributes") or {}).get("bundleId") == BUNDLE_ID:
            return item["id"]
    fail(f"No App Store Connect app for {BUNDLE_ID}.")


def builds_for_version(app, version):
    query = urllib.parse.urlencode({
        "filter[app]": app,
        "filter[version]": version,
        "limit": "10",
    })
    status, payload = api("GET", "/v1/builds?" + query)
    if status >= 400:
        print(f"Build lookup HTTP {status}: {error_text(json.dumps(payload).encode())[:400]}")
        return []
    return payload.get("data") or []


def interesting_crash_lines(text):
    keep = []
    needles = (
        "exception type", "exception subtype", "termination reason", "termination ",
        "triggered by thread", "application specific", "jetsam", "mlx", "metal",
        "vela", "swift", "abort", "fatal error", "sigkill", "sigabrt", "exc_bad",
        "exc_resource", "memory", "last exception backtrace",
    )
    for line in text.splitlines():
        low = line.lower()
        if any(needle in low for needle in needles):
            keep.append(line.rstrip()[:240])
        if len(keep) >= 80:
            break
    return keep


def save_crash_body(submission_id, status, body, content_type):
    out_dir = env("CRASH_DIR") or "."
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, f"crash-{submission_id}.txt")
    text = ""
    if body[:1] in (b"{", b"["):
        try:
            payload = json.loads(body.decode("utf-8", errors="replace"))
        except json.JSONDecodeError:
            payload = None
        if isinstance(payload, dict):
            data = payload.get("data") or {}
            attributes = data.get("attributes") if isinstance(data, dict) else None
            if isinstance(attributes, dict):
                for key, value in attributes.items():
                    if isinstance(value, str) and len(value) > 40:
                        text = value
                        break
            if not text:
                text = json.dumps(payload)[:2000]
                print(f"Crash log JSON keys: {list(payload.keys())}")
                if isinstance(data, dict):
                    print(f"data keys: {list(data.keys())}")
                    if isinstance(data.get("attributes"), dict):
                        print(f"attribute keys: {list(data['attributes'].keys())}")
        else:
            text = body.decode("utf-8", errors="replace")
    else:
        text = body.decode("utf-8", errors="replace")
    text = redact_emails(text)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    print(f"Saved crash log ({status}, {content_type or 'unknown'}, {len(text)} chars)")
    highlights = interesting_crash_lines(text)
    if highlights:
        print("--- crash excerpt ---")
        print("\n".join(highlights))
    else:
        print(text[:1500])
    return path


def fetch_crash_log(submission):
    submission_id = submission.get("id") or "unknown"
    relationship = ((submission.get("relationships") or {}).get("crashLog") or {})
    related = ((relationship.get("links") or {}).get("related")) or ""
    candidates = []
    if related:
        candidates.append(related)
    candidates.append(f"/v1/betaFeedbackCrashSubmissions/{submission_id}/crashLog")
    candidates.append(f"/v1/betaFeedbackCrashSubmissions/{submission_id}/crashLogs")
    seen = set()
    for path in candidates:
        if path in seen:
            continue
        seen.add(path)
        status, body, content_type = api_bytes(path)
        print(f"GET crash log {submission_id}: HTTP {status} ({len(body)} bytes)")
        if status < 400 and body:
            save_crash_body(submission_id, status, body, content_type)
            return
        if body and status >= 400:
            print(redact_emails(error_text(body)[:400]))


def relationship_names(resource):
    relationships = resource.get("relationships") or {}
    names = sorted(relationships.keys())
    print("relationships: " + ", ".join(names))
    return relationships


def follow_related(label, relationship):
    related = ((relationship or {}).get("links") or {}).get("related")
    if not related:
        return []
    path = related
    if path.startswith(API):
        path = path[len(API):]
    status, payload = api("GET", path + ("&limit=20" if "?" in path else "?limit=20"))
    count = len(payload.get("data") or []) if isinstance(payload.get("data"), list) else (1 if payload.get("data") else 0)
    print(f"{label} HTTP {status} count {count}")
    if status >= 400:
        print(error_text(json.dumps(payload).encode())[:400])
        return []
    data = payload.get("data")
    if isinstance(data, dict):
        return [data]
    return data or []


def crash_reports():
    """Read TestFlight crash feedback for build 19. Does not create or revoke certificates."""
    write_key()
    app = app_id()
    print(f"App {BUNDLE_ID} found.")
    status, app_payload = api("GET", f"/v1/apps/{app}")
    if status < 400 and app_payload.get("data"):
        relationship_names(app_payload["data"])
    builds = builds_for_version(app, "19")
    print(f"Build records with version 19: {len(builds)}")
    submissions = []
    for build in builds:
        build_id = build.get("id")
        print(f"Build {build_id} uploaded {((build.get('attributes') or {}).get('uploadedDate'))}")
        status, full = api("GET", f"/v1/builds/{build_id}")
        resource = full.get("data") if status < 400 else build
        relationships = relationship_names(resource or {})
        for name, relationship in relationships.items():
            low = name.lower()
            if any(word in low for word in ("crash", "feedback", "diagnostic", "log", "beta")):
                found = follow_related(name, relationship)
                for item in found:
                    if item.get("type", "").lower().find("crash") >= 0 or "comment" in (item.get("attributes") or {}) or "deviceModel" in (item.get("attributes") or {}):
                        submissions.append(item)
                    else:
                        print(f"  related {item.get('type')} {item.get('id')}")
    # Individual crash submissions cannot be listed. Probe the build id as an instance id too.
    for build in builds:
        build_id = build.get("id")
        for path in (
            f"/v1/betaFeedbackCrashSubmissions/{build_id}",
            f"/v1/betaFeedbackCrashSubmissions/{build_id}/crashLog",
        ):
            status, body, _ = api_bytes(path)
            print(f"{path} HTTP {status} ({len(body)} bytes)")
            if status < 400 and body:
                save_crash_body(build_id, status, body, "")
                return
            if body:
                print(redact_emails(error_text(body)[:300]))
    if not submissions:
        print("No TestFlight crash submissions were linked from the build.")
        return
    print(f"Crash-like records: {len(submissions)}")
    for item in submissions:
        attrs = item.get("attributes") or {}
        comment = redact_emails(str(attrs.get("comment") or ""))
        print("--- submission ---")
        print(f"type: {item.get('type')} id: {item.get('id')}")
        print(f"created: {attrs.get('createdDate')}")
        print(f"device: {attrs.get('deviceModel')} {attrs.get('osVersion')}")
        if comment:
            print(f"comment: {comment[:500]}")
        relationship_names(item)
        fetch_crash_log(item)


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "prepare":
        prepare()
    elif command == "create-cert":
        create_signing_cert()
    elif command == "crash-logs":
        crash_reports()
    elif command == "poll":
        raise SystemExit(poll())
    elif command == "scrub" and len(sys.argv) == 3:
        scrub(sys.argv[2])
    elif command == "owner-app":
        owner_app_record()
        raise SystemExit(1)
    else:
        fail("usage: asc_testflight.py prepare|create-cert|poll|scrub <log>|owner-app")


if __name__ == "__main__":
    main()
