# F-05: Ed25519 Signing for Mirror Metadata

## What is signed

Detached Ed25519 signatures (`.sig` files, base64 text of the raw 64-byte
signature) are published alongside mirror metadata:

| Metadata file      | Signature file          | Release          |
|--------------------|-------------------------|------------------|
| `CORE-VERSIONS`    | `CORE-VERSIONS.sig`     | `core-binaries`  |
| `SHA256SUMS`       | `SHA256SUMS.sig`        | `core-binaries`  |
| `SHA256SUMS`       | `SHA256SUMS.sig`        | `test-tools-mirror` |
| `wallos-manifest.txt` | `wallos-manifest.txt.sig` | `wallos-mirror` |

> **Note:** `test-tools-mirror` assets were originally verified by
> SHA256 checksum only. Since the P3-02 hardening, the mirror
> workflow also publishes a detached Ed25519 signature for its
> `SHA256SUMS`, and `install.sh` verifies it fail-closed (a missing
> or invalid signature blocks execution of the mirrored test
> scripts; the upstream-first download path is unaffected).

Verification uses **only `openssl` + `python3`** (both already in
`install.sh`'s `ensure_commands`). No GPG / minisign / signify dependency —
GPG was rejected (heavy, `~/.gnupg` state issues on Alpine/minimal), and
minisign/signify are missing from CentOS/RHEL default repos.

## Trust root

Public keys are **hardcoded** in `install.sh` (`ABOX_SIGNING_PUBKEYS` array).
A key fetched from the Release being verified would prove nothing (attacker
replaces metadata + sig + key together). `mirrors/SIGNING_PUBKEYS` mirrors
the array for external audit; it is never read at runtime.

## Maintainer setup

> **Current state:** initial provisioning is complete. `install.sh`'s
> `ABOX_SIGNING_PUBKEYS` already ships the active production key
> (`release-2026`, also mirrored in `mirrors/SIGNING_PUBKEYS` for
> external audit), and signature enforcement is on by default
> (`ABOX_SIGNING_ENFORCE` defaults to 1). A first-time installer takes
> no key action. The steps below provision a **new** key (rotation),
> not a first install.

### 1. Generate the production keypair

```bash
umask 077
openssl genpkey -algorithm ed25519 -out abox-signing-priv.pem
openssl pkey -in abox-signing-priv.pem -pubout -out abox-signing-pub.pem
# raw 32-byte public key, base64:
python3 - <<'PY'
import base64
pem = open('abox-signing-pub.pem').read()
der = base64.b64decode(''.join(l for l in pem.splitlines() if '---' not in l))
print(base64.b64encode(der[-32:]).decode())
PY
```

**Guard the private key.** It signs everything clients trust.

### 2. Install the public key

- Append a new `name:<base64-pubkey>` entry (release-style name, e.g.
  `release-2027`) to `ABOX_SIGNING_PUBKEYS` (install.sh). Keep the
  active key listed until CI has re-signed with the new key; removal
  of the old key follows the Rotation steps below.
- Update `mirrors/SIGNING_PUBKEYS` identically.
- Bump `ABOX_SIGNING_MIN_TIMESTAMP_UTC` to the rotation date.

### 3. Add the private key to GitHub Secrets

Secret name: **`ABOX_SIGNING_PRIVKEY_B64`**
Value: base64 of the **raw 32-byte private seed**, i.e.:

```bash
python3 - <<'PY'
import base64
pem = open('abox-signing-priv.pem').read()
der = base64.b64decode(''.join(l for l in pem.splitlines() if '---' not in l))
# PKCS#8 Ed25519: last 32 bytes are the seed
print(base64.b64encode(der[-32:]).decode())
PY
```

The CI signing step (`Sign mirror metadata (F-05)` in
`update-core-mirror.yml` / `update-mirrors.yml`) reconstructs the PEM from
this secret, signs with `openssl pkeyutl -sign -rawin`, and uploads
`<file>.sig` next to each metadata file. The step skips gracefully when the
secret is absent (so forks/CI without the key don't break).

### 4. Enforcement

Enforcement is already on by default (`ABOX_SIGNING_ENFORCE` defaults
to 1 in install.sh). With enforcement on: missing/invalid signature →
the asset source is rejected (fail-closed); the client falls back to
the next trusted source and dies if none remain. It never
warn-and-continues. (`ABOX_SIGNING_ENFORCE=0` is an explicit escape
hatch only.)

## Rotation

1. Add the new public key to `ABOX_SIGNING_PUBKEYS` (keep the old one).
2. Switch CI to the new private key (`ABOX_SIGNING_PRIVKEY_B64`).
3. After one release cycle, remove the old public key.

## Emergency revocation

1. Add the compromised key's fingerprint
   (`sha256 hex` of the raw 32-byte public key) to `ABOX_REVOKED_PUBKEY_FPS`
   in install.sh and bump `ABOX_BUILD_EPOCH`.
2. Generate a new keypair; add the new public key to `ABOX_SIGNING_PUBKEYS`
   (keep the revoked one listed in `ABOX_REVOKED_PUBKEY_FPS`).
3. CI re-signs all Release metadata with the new private key
   (`ABOX_SIGNING_PRIVKEY_B64` secret must be updated first).
4. Ship the updated install.sh; clients reject anything signed by the
   revoked key even if the signature is otherwise valid.

> **Note (H5):** There is a single active signing key (`release-2026`).
> There is no pre-provisioned backup key; rotation generates a new keypair
> on demand following the steps above.

## Anti-replay

Every signed metadata file carries a UTC timestamp
(`updated_at_utc` in CORE-VERSIONS, `retrieved_at_utc` in
wallos-manifest.txt). Clients reject metadata older than
`ABOX_SIGNING_MIN_TIMESTAMP_UTC` — this blocks downgrade/replay with
stale-but-validly-signed metadata. Bump the floor on every rotation or
revocation event.
