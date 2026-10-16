# F-05: Ed25519 Signing for Mirror Metadata

## What is signed

Detached Ed25519 signatures (`.sig` files, base64 text of the raw 64-byte
signature) are published alongside mirror metadata:

| Metadata file      | Signature file          | Release          |
|--------------------|-------------------------|------------------|
| `CORE-VERSIONS`    | `CORE-VERSIONS.sig`     | `core-binaries`  |
| `SHA256SUMS`       | `SHA256SUMS.sig`        | `core-binaries`  |
| `wallos-manifest.txt` | `wallos-manifest.txt.sig` | `wallos-mirror` |

> **Note (H4):** `test-tools-mirror` Release assets are verified by SHA256
> checksum only (not Ed25519). Test scripts are downloaded upstream-first
> with explicit user confirmation; the mirror is a fallback. Adding
> detached signatures to test-tools is tracked as future work.

Verification uses **only `openssl` + `python3`** (both already in
`install.sh`'s `ensure_commands`). No GPG / minisign / signify dependency —
GPG was rejected (heavy, `~/.gnupg` state issues on Alpine/minimal), and
minisign/signify are missing from CentOS/RHEL default repos.

## Trust root

Public keys are **hardcoded** in `install.sh` (`ABOX_SIGNING_PUBKEYS` array).
A key fetched from the Release being verified would prove nothing (attacker
replaces metadata + sig + key together). `mirrors/SIGNING_PUBKEYS` mirrors
the array for external audit; it is never read at runtime.

## Maintainer setup (do this once)

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

- Replace the `test-only:...` entry in `ABOX_SIGNING_PUBKEYS` (install.sh)
  with `production:<base64-pubkey>`.
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

### 4. Enable enforcement

Set `ABOX_SIGNING_ENFORCE=1` (environment, or change the default in
install.sh) **after** steps 1–3 are live and `.sig` files are published.
With enforcement on: missing/invalid signature → the asset source is
rejected (fail-closed); the client falls back to the next trusted source
and dies if none remain. It never warn-and-continues.

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
