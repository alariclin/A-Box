#!/usr/bin/env bash
set -Eeuo pipefail
command -v file >/dev/null 2>&1 || { echo "::error::The file utility is required for architecture validation."; exit 1; }
root="$RUNNER_TEMP/core-mirror"
out="$root/new"
existing="$root/existing"
mkdir -p "$out" "$existing"

gh release view core-binaries >/dev/null
gh release download core-binaries --pattern SHA256SUMS --dir "$existing"
test -s "$existing/SHA256SUMS"
# D-1: download existing CORE-VERSIONS for cooldown fallback (previous
# mirror version when the latest release is < 7 days old).
gh release download core-binaries --pattern CORE-VERSIONS --dir "$existing"
test -s "$existing/CORE-VERSIONS"
# D-1-FIX: Verify CORE-VERSIONS against SHA256SUMS before trusting it for fallback.
# Without this, a tampered mirror could inject a malicious prev_tag.
( cd "$existing" && sha256sum -c --status --ignore-missing <(grep "CORE-VERSIONS" SHA256SUMS) ) || {
  echo "::error::CORE-VERSIONS hash mismatch against SHA256SUMS; aborting"
  exit 1
}

# D-1: 7-day cooldown. A release published < 7 days ago is not yet
# trusted for the mirror. Fall back to the previous mirror version.
COOLDOWN_SECONDS=604800
# D-1-FIX: Per-core skip list (associative array). enforce_cooldown sets
# SKIP_CORES[core_key]=1 on failure instead of return 1 (which aborted whole
# script under set -e, blocking other cores).
declare -A SKIP_CORES=()

# NOTE: validate_release_tag must be defined BEFORE enforce_cooldown,
# because enforce_cooldown calls it on the fallback path.
validate_release_tag() {
  local file="$1" regex="$2" tag
  jq -e --arg regex "$regex" '
    type == "object"
    and .draft == false
    and .prerelease == false
    and ((.tag_name // "") | type == "string")
    and ((.tag_name // "") | test($regex))
  ' "$file" >/dev/null
  tag="$(jq -er '.tag_name' "$file")"
  printf '%s\n' "$tag"
}

# Enforce cooldown for a release JSON. If the release is < 7 days old,
# replace the JSON file with the previous mirror version's release JSON.
# Args: repo, json_file, core_key (CORE-VERSIONS key), tag_regex
enforce_cooldown() {
  local repo="$1" json_file="$2" core_key="$3" tag_regex="$4"
  local published_at published_epoch now_epoch age latest_tag prev_tag
  # D-1-FIX (set-e safe): All fallible commands wrapped in if ! ... guards.
  # No bare jq/gh/date calls that could abort the whole script under set -e.
  if ! validate_release_tag "$json_file" "$tag_regex" >/dev/null 2>&1 ||
     ! published_at="$(jq -er '.published_at' "$json_file" 2>/dev/null)" ||
     ! published_epoch="$(date -d "$published_at" +%s 2>/dev/null)"; then
    echo "::warning::$core_key latest release metadata invalid; attempting fallback to previous mirror version"
    age=0
    latest_tag="unknown"
  else
    now_epoch="$(date +%s)"
    age=$((now_epoch - published_epoch))
    latest_tag="$(jq -er '.tag_name' "$json_file")"
    if (( age >= COOLDOWN_SECONDS )); then
      return 0
    fi
  fi
  prev_tag="$(awk -F= -v k="$core_key" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "$existing/CORE-VERSIONS")"
  if [[ -z "$prev_tag" ]] || ! [[ "$prev_tag" =~ $tag_regex ]]; then
    echo "::warning::$core_key release $latest_tag is in cooldown and no valid previous tag exists; skipping $core_key"
    SKIP_CORES["$core_key"]=1
    return 0
  fi
  if [[ "$prev_tag" == "$latest_tag" ]]; then
    echo "::notice::$core_key release $latest_tag is already in mirror; proceeding"
    return 0
  fi
  echo "::warning::$core_key release $latest_tag is only $((age / 86400))d old (<7d); falling back to $prev_tag"
  if ! gh api "repos/$repo/releases/tags/$prev_tag" > "$json_file" 2>/dev/null ||
     ! jq -e --arg regex "$tag_regex" 'type == "object" and .draft == false and ((.tag_name // "") | test($regex))' "$json_file" >/dev/null 2>&1; then
    echo "::warning::$core_key fallback release $prev_tag failed validation; skipping $core_key"
    SKIP_CORES["$core_key"]=1
    return 0
  fi
}

gh api repos/XTLS/Xray-core/releases/latest > "$root/xray.json"
enforce_cooldown "XTLS/Xray-core" "$root/xray.json" "Xray" '^v[0-9]+\.[0-9]+\.[0-9]+$'
gh api repos/SagerNet/sing-box/releases/latest > "$root/sing-box.json"
enforce_cooldown "SagerNet/sing-box" "$root/sing-box.json" "sing-box" '^v[0-9]+\.[0-9]+\.[0-9]+$'
gh api repos/HyNetworks/hysteria/releases/latest > "$root/hysteria.json"
enforce_cooldown "HyNetworks/hysteria" "$root/hysteria.json" "Hysteria" '^app/v[0-9]+\.[0-9]+\.[0-9]+$'

# D-1-FIX: For skipped cores, use existing mirror tag (not the too-new release).
if [[ -n "${SKIP_CORES[Xray]:-}" ]]; then
  xray_tag="$(grep '^Xray=' "$existing/CORE-VERSIONS" | cut -d= -f2)"
  echo "::notice::Using existing mirror Xray tag: $xray_tag (latest skipped)"
else
  xray_tag="$(validate_release_tag "$root/xray.json" '^v[0-9]+\.[0-9]+\.[0-9]+$')"
fi
if [[ -n "${SKIP_CORES[sing-box]:-}" ]]; then
  singbox_tag="$(grep '^sing-box=' "$existing/CORE-VERSIONS" | cut -d= -f2)"
  echo "::notice::Using existing mirror sing-box tag: $singbox_tag (latest skipped)"
else
  singbox_tag="$(validate_release_tag "$root/sing-box.json" '^v[0-9]+\.[0-9]+\.[0-9]+$')"
fi
if [[ -n "${SKIP_CORES[Hysteria]:-}" ]]; then
  hysteria_tag="$(grep '^Hysteria=' "$existing/CORE-VERSIONS" | cut -d= -f2)"
  echo "::notice::Using existing mirror Hysteria tag: $hysteria_tag (latest skipped)"
else
  hysteria_tag="$(validate_release_tag "$root/hysteria.json" '^app/v[0-9]+\.[0-9]+\.[0-9]+$')"
fi

# Pinned utilities (cloudflared for Argo, wgcf for WARP): versions are NOT
# latest-tracked; the single source of truth is the pin in install.sh.
[[ -f install.sh ]] || { echo "::error::install.sh not found (run from repo root)"; exit 1; }
CLOUDFLARED_VERSION="$(sed -n "s/^CLOUDFLARED_VERSION='\([0-9.]*\)'$/\1/p" install.sh | head -1)"
[[ "$CLOUDFLARED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error::Cannot parse CLOUDFLARED_VERSION pin from install.sh"; exit 1; }
WGCF_VERSION="$(sed -n "s/^WGCF_VERSION='\([0-9.]*\)'$/\1/p" install.sh | head -1)"
[[ "$WGCF_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error::Cannot parse WGCF_VERSION pin from install.sh"; exit 1; }
gh api "repos/cloudflare/cloudflared/releases/tags/$CLOUDFLARED_VERSION" > "$root/cloudflared.json"
jq -e --arg t "$CLOUDFLARED_VERSION" '.draft == false and .prerelease == false and .tag_name == $t' "$root/cloudflared.json" >/dev/null || {
  echo "::error::cloudflared pinned release $CLOUDFLARED_VERSION invalid or not found"; exit 1; }
gh api "repos/ViRb3/wgcf/releases/tags/v$WGCF_VERSION" > "$root/wgcf.json"
jq -e --arg t "v$WGCF_VERSION" '.draft == false and .prerelease == false and .tag_name == $t' "$root/wgcf.json" >/dev/null || {
  echo "::error::wgcf pinned release v$WGCF_VERSION invalid or not found"; exit 1; }

declare -a mirror_names=()
declare -a mirror_paths=()
declare -a mirror_digests=()
declare -a upload_paths=()

download_verified_asset() {
  local repo="$1" release_file="$2" upstream_name="$3" mirror_name="$4" kind="$5"
  local tag asset_json url digest expected actual path bin member version_output arch_kind file_description expected_version libc_kind
  tag="$(jq -er '.tag_name' "$release_file")"
  asset_json="$(jq -cer --arg name "$upstream_name" '
    [.assets[]? | select(.name == $name)]
    | if length == 1 then .[0] else empty end
  ' "$release_file")"
  url="$(jq -er '.browser_download_url | select(type == "string" and length > 0)' <<< "$asset_json")"
  digest="$(jq -er '.digest | select(type == "string")' <<< "$asset_json")"
  [[ "$url" == "https://github.com/$repo/releases/download/$tag/$upstream_name" ]] || {
    echo "::error::Unexpected official asset URL for $repo:$tag/$upstream_name"
    return 1
  }
  [[ "$digest" =~ ^sha256:[A-Fa-f0-9]{64}$ ]] || {
    echo "::error::Official asset lacks a valid SHA-256 digest: $repo:$tag/$upstream_name"
    return 1
  }
  expected="${digest#sha256:}"
  path="$out/$mirror_name"
  if [[ "$upstream_name" == *arm64* || "$mirror_name" == *arm64* ]]; then arch_kind="arm64"; else arch_kind="amd64"; fi
  if [[ "$mirror_name" == *-musl.tar.gz ]]; then libc_kind="musl"; else libc_kind="glibc"; fi
  curl -fL --retry 3 --retry-all-errors --connect-timeout 15 --max-time 300 "$url" -o "$path"
  actual="$(sha256sum "$path" | awk '{print $1}')"
  [[ "${actual,,}" == "${expected,,}" ]] || {
    echo "::error::SHA-256 mismatch for $repo:$tag/$upstream_name"
    return 1
  }

  case "$kind" in
    xray)
      unzip -tq "$path" >/dev/null
      member="$(unzip -Z1 "$path" | awk '$0 == "xray" {print; n++} END {if (n != 1) exit 1}')"
      bin="$root/xray-check"
      unzip -p "$path" "$member" > "$bin"
      chmod 700 "$bin"
      file_description="$(file -b "$bin")"
      if [[ "$arch_kind" == "arm64" ]]; then
        grep -Eqi 'ARM aarch64|ARM64' <<< "$file_description" || {
          echo "::error::Xray archive does not contain an AArch64 binary: $mirror_name"
          return 1
        }
      else
        grep -Eqi 'x86-64' <<< "$file_description" || {
          echo "::error::Xray archive does not contain an x86-64 binary: $mirror_name"
          return 1
        }
        version_output="$("$bin" version 2>&1)" || {
          echo "::error::Xray binary failed its version probe: $mirror_name"
          return 1
        }
        version_line="$(grep -m1 -E '^Xray ' <<< "$version_output" || true)"
        # F-05 fix: parse the version field exactly; substring matching
        # would accept e.g. "26.7.280" for expected "26.7.28".
        if [[ "$version_line" =~ ^Xray\ ([0-9]+\.[0-9]+\.[0-9]+)([[:space:]]|$) ]]; then
          [[ "${BASH_REMATCH[1]}" == "${tag#v}" ]] || {
            echo "::error::Xray binary version does not match $tag (got ${BASH_REMATCH[1]})"
            return 1
          }
        else
          echo "::error::Could not parse Xray version from probe output"
          return 1
        fi
      fi
      ;;
    sing-box)
      tar -tzf "$path" >/dev/null
      member="$(tar -tzf "$path" | awk '/(^|\/)sing-box$/ {print; n++} END {if (n != 1) exit 1}')"
      bin="$root/sing-box-check"
      tar -xOzf "$path" "$member" > "$bin"
      chmod 700 "$bin"
      file_description="$(file -b "$bin")"
      if [[ "$arch_kind" == "arm64" ]]; then
        grep -Eqi 'ARM aarch64|ARM64' <<< "$file_description" || {
          echo "::error::sing-box archive does not contain an AArch64 binary: $mirror_name"
          return 1
        }
      else
        grep -Eqi 'x86-64' <<< "$file_description" || {
          echo "::error::sing-box archive does not contain an x86-64 binary: $mirror_name"
          return 1
        }
        if [[ "$libc_kind" == "glibc" ]]; then
          version_output="$("$bin" version 2>&1)" || {
            echo "::error::sing-box binary failed its version probe: $mirror_name"
            return 1
          }
          expected_version="${tag#v}"
          version_line="$(grep -m1 -E '^sing-box version ' <<< "$version_output" || true)"
          # F-05 fix: exact version-field parse, not substring matching.
          if [[ "$version_line" =~ ^sing-box\ version\ ([0-9]+\.[0-9]+\.[0-9]+)([[:space:]]|$) ]]; then
            [[ "${BASH_REMATCH[1]}" == "$expected_version" ]] || {
              echo "::error::sing-box binary version does not match $tag (got ${BASH_REMATCH[1]})"
              return 1
            }
          else
            echo "::error::Could not parse sing-box version from probe output"
            return 1
          fi
        fi
      fi
      ;;
    hysteria)
      chmod 700 "$path"
      file_description="$(file -b "$path")"
      if [[ "$arch_kind" == "arm64" ]]; then
        grep -Eqi 'ARM aarch64|ARM64' <<< "$file_description" || {
          echo "::error::Hysteria asset is not an AArch64 binary: $mirror_name"
          return 1
        }
      else
        grep -Eqi 'x86-64' <<< "$file_description" || {
          echo "::error::Hysteria asset is not an x86-64 binary: $mirror_name"
          return 1
        }
        version_output="$("$path" version 2>&1)" || {
          echo "::error::Hysteria binary failed its version probe: $mirror_name"
          return 1
        }
        expected_version="${tag#app/}"
        # F-05 fix: exact version-field parse, not substring matching.
        # Hysteria prints "Version:<TAB>v2.13.0" (tab, not space); accept
        # any whitespace after the label and compare the normalized
        # "v<digits>" token exactly.
        if [[ "$version_output" =~ Version:[[:space:]]+v?([0-9]+\.[0-9]+\.[0-9]+)([[:space:]]|$) ]]; then
          [[ "v${BASH_REMATCH[1]}" == "$expected_version" ]] || {
            echo "::error::Hysteria binary version does not match $tag (got v${BASH_REMATCH[1]})"
            return 1
          }
        else
          echo "::error::Could not parse Hysteria version from probe output"
          return 1
        fi
      fi
      ;;
    cloudflared)
      chmod 700 "$path"
      file_description="$(file -b "$path")"
      if [[ "$arch_kind" == "arm64" ]]; then
        grep -Eqi 'ARM aarch64|ARM64' <<< "$file_description" || {
          echo "::error::cloudflared asset is not an AArch64 binary: $mirror_name"
          return 1
        }
      else
        grep -Eqi 'x86-64' <<< "$file_description" || {
          echo "::error::cloudflared asset is not an x86-64 binary: $mirror_name"
          return 1
        }
        version_output="$("$path" --version 2>&1)" || {
          echo "::error::cloudflared binary failed its version probe: $mirror_name"
          return 1
        }
        if [[ "$version_output" =~ cloudflared\ version\ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
          [[ "${BASH_REMATCH[1]}" == "$tag" ]] || {
            echo "::error::cloudflared binary version does not match $tag (got ${BASH_REMATCH[1]})"
            return 1
          }
        else
          echo "::error::Could not parse cloudflared version from probe output"
          return 1
        fi
      fi
      ;;
    wgcf)
      # wgcf has no reliable version probe; the upstream-attested GitHub
      # digest above (exact tag + asset name) is the verification anchor,
      # plus the ELF architecture check here.
      file_description="$(file -b "$path")"
      if [[ "$arch_kind" == "arm64" ]]; then
        grep -Eqi 'ARM aarch64|ARM64' <<< "$file_description" || {
          echo "::error::wgcf asset is not an AArch64 binary: $mirror_name"
          return 1
        }
      else
        grep -Eqi 'x86-64' <<< "$file_description" || {
          echo "::error::wgcf asset is not an x86-64 binary: $mirror_name"
          return 1
        }
      fi
      ;;
    *) echo "::error::Unknown asset validation type: $kind"; return 1 ;;
  esac
  mirror_names+=("$mirror_name")
  mirror_paths+=("$path")
  mirror_digests+=("$actual")
  echo "Verified $repo:$tag/$upstream_name -> $mirror_name"
}

xray_amd64_name="Xray-$xray_tag-linux-64.zip"
xray_arm64_name="Xray-$xray_tag-linux-arm64-v8a.zip"
singbox_version="${singbox_tag#v}"
# B-13: constructed names for skipped cores must exist in the manifest (fail-closed).
# Only skipped cores are checked: their names are built from the
# existing mirror tag, so they must already be in the manifest. A
# non-skipped core's names carry the NEW upstream tag by definition
# and only enter the manifest through this run's downloads — checking
# them against the old manifest would fail every legitimate update.
declare -a _b13_names=()
if [[ -n "${SKIP_CORES[Xray]:-}" ]]; then
  _b13_names+=("$xray_amd64_name" "$xray_arm64_name")
fi
if [[ -n "${SKIP_CORES[sing-box]:-}" ]]; then
  _b13_names+=("sing-box-$singbox_version-linux-amd64-glibc.tar.gz" "sing-box-$singbox_version-linux-amd64-musl.tar.gz" \
    "sing-box-$singbox_version-linux-arm64-glibc.tar.gz" "sing-box-$singbox_version-linux-arm64-musl.tar.gz")
fi
if [[ -n "${SKIP_CORES[Hysteria]:-}" ]]; then
  _b13_names+=("hysteria-$(tr '/' '-' <<< "$hysteria_tag" | tr -d '\n')-linux-amd64" \
    "hysteria-$(tr '/' '-' <<< "$hysteria_tag" | tr -d '\n')-linux-arm64")
fi
if (( ${#_b13_names[@]} > 0 )); then
  for _b13_name in "${_b13_names[@]}"; do
    grep -q "  $_b13_name$" "$existing/SHA256SUMS" || {
      echo "::error::B-13: constructed asset name not in SHA256SUMS manifest: $_b13_name"
      exit 1
    }
  done
fi
unset _b13_name _b13_names
hysteria_leaf="$(tr '/' '-' <<< "$hysteria_tag" | tr -d '\n')"

# D-1-FIX: Skip downloads for skipped cores (assets already in mirror).
if [[ -z "${SKIP_CORES[Xray]:-}" ]]; then
  download_verified_asset XTLS/Xray-core "$root/xray.json" Xray-linux-64.zip "$xray_amd64_name" xray
  download_verified_asset XTLS/Xray-core "$root/xray.json" Xray-linux-arm64-v8a.zip "$xray_arm64_name" xray
else
  echo "::notice::Skipping Xray downloads (using existing mirror version)"
fi

if [[ -z "${SKIP_CORES[sing-box]:-}" ]]; then
  download_verified_asset SagerNet/sing-box "$root/sing-box.json" "sing-box-$singbox_version-linux-amd64-glibc.tar.gz" "sing-box-$singbox_version-linux-amd64-glibc.tar.gz" sing-box
  download_verified_asset SagerNet/sing-box "$root/sing-box.json" "sing-box-$singbox_version-linux-amd64-musl.tar.gz" "sing-box-$singbox_version-linux-amd64-musl.tar.gz" sing-box
  download_verified_asset SagerNet/sing-box "$root/sing-box.json" "sing-box-$singbox_version-linux-arm64-glibc.tar.gz" "sing-box-$singbox_version-linux-arm64-glibc.tar.gz" sing-box
  download_verified_asset SagerNet/sing-box "$root/sing-box.json" "sing-box-$singbox_version-linux-arm64-musl.tar.gz" "sing-box-$singbox_version-linux-arm64-musl.tar.gz" sing-box
else
  echo "::notice::Skipping sing-box downloads (using existing mirror version)"
fi

if [[ -z "${SKIP_CORES[Hysteria]:-}" ]]; then
  download_verified_asset HyNetworks/hysteria "$root/hysteria.json" hysteria-linux-amd64 "hysteria-$hysteria_leaf-linux-amd64" hysteria
  download_verified_asset HyNetworks/hysteria "$root/hysteria.json" hysteria-linux-arm64 "hysteria-$hysteria_leaf-linux-arm64" hysteria
else
  echo "::notice::Skipping Hysteria downloads (using existing mirror version)"
fi

# Pinned utilities: always fetched at the install.sh pin (no cooldown,
# no skip). Already-mirrored identical bytes are not re-uploaded (the
# immutability merge below handles that).
download_verified_asset cloudflare/cloudflared "$root/cloudflared.json" cloudflared-linux-amd64 "cloudflared-$CLOUDFLARED_VERSION-linux-amd64" cloudflared
download_verified_asset cloudflare/cloudflared "$root/cloudflared.json" cloudflared-linux-arm64 "cloudflared-$CLOUDFLARED_VERSION-linux-arm64" cloudflared
download_verified_asset ViRb3/wgcf "$root/wgcf.json" "wgcf_${WGCF_VERSION}_linux_amd64" "wgcf_${WGCF_VERSION}_linux_amd64" wgcf
download_verified_asset ViRb3/wgcf "$root/wgcf.json" "wgcf_${WGCF_VERSION}_linux_arm64" "wgcf_${WGCF_VERSION}_linux_arm64" wgcf

cat > "$out/CORE-VERSIONS" <<EOF
schema=1
updated_at_utc=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
Xray=$xray_tag
Xray-amd64=$xray_amd64_name
Xray-arm64=$xray_arm64_name
sing-box=$singbox_tag
sing-box-amd64-glibc=sing-box-$singbox_version-linux-amd64-glibc.tar.gz
sing-box-amd64-musl=sing-box-$singbox_version-linux-amd64-musl.tar.gz
sing-box-arm64-glibc=sing-box-$singbox_version-linux-arm64-glibc.tar.gz
sing-box-arm64-musl=sing-box-$singbox_version-linux-arm64-musl.tar.gz
Hysteria=$hysteria_tag
Hysteria-amd64=hysteria-$hysteria_leaf-linux-amd64
Hysteria-arm64=hysteria-$hysteria_leaf-linux-arm64
cloudflared=$CLOUDFLARED_VERSION
cloudflared-amd64=cloudflared-$CLOUDFLARED_VERSION-linux-amd64
cloudflared-arm64=cloudflared-$CLOUDFLARED_VERSION-linux-arm64
wgcf=$WGCF_VERSION
wgcf-amd64=wgcf_${WGCF_VERSION}_linux_amd64
wgcf-arm64=wgcf_${WGCF_VERSION}_linux_arm64
EOF

# Validate the previous manifest against GitHub's per-asset digest metadata.
# No old asset is deleted or overwritten; versioned filenames are immutable.
release_json="$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/core-binaries")"
awk 'NF { if (NF != 2 || $1 !~ /^[A-Fa-f0-9]{64}$/ || $2 !~ /^[A-Za-z0-9._-]+$/ || seen[$2]++) exit 1 }' "$existing/SHA256SUMS"
while read -r old_sum old_name extra; do
  [[ -n "${old_sum:-}" ]] || continue
  [[ -z "${extra:-}" ]] || { echo "::error::Malformed existing SHA256SUMS line"; exit 1; }
  actual_digest="$(jq -er --arg name "$old_name" '
    [.assets[]? | select(.name == $name)]
    | if length == 1 then .[0].digest // empty else empty end
  ' <<< "$release_json")"
  [[ "${actual_digest#sha256:}" == "$old_sum" ]] || {
    echo "::error::Existing manifest digest does not match GitHub asset metadata: $old_name"
    exit 1
  }
done < "$existing/SHA256SUMS"

cp "$existing/SHA256SUMS" "$out/SHA256SUMS"
# CORE-VERSIONS is a mutable pointer; replace only its checksum line.
awk '$2 != "CORE-VERSIONS" {print}' "$out/SHA256SUMS" > "$root/SHA256SUMS.next"
mv "$root/SHA256SUMS.next" "$out/SHA256SUMS"

release_asset_digest() {
  jq -r --arg name "$1" '
    [.assets[]? | select(.name == $name)]
    | if length == 1 then .[0].digest // "" else "" end
  ' <<< "$release_json"
}

for i in "${!mirror_names[@]}"; do
  name="${mirror_names[$i]}"
  digest="${mirror_digests[$i]}"
  prior_digest="$(release_asset_digest "$name")"
  if [[ -n "$prior_digest" ]]; then
    [[ "${prior_digest#sha256:}" == "$digest" ]] || {
      echo "::error::Refusing to overwrite an immutable versioned asset with different bytes: $name"
      exit 1
    }
  else
    upload_paths+=("${mirror_paths[$i]}")
  fi

  manifest_sum="$(awk -v name="$name" '$2 == name {print $1}' "$out/SHA256SUMS")"
  if [[ -n "$manifest_sum" ]]; then
    [[ "$manifest_sum" == "$digest" ]] || {
      echo "::error::Existing manifest entry conflicts with verified asset: $name"
      exit 1
    }
  else
    printf '%s  %s\n' "$digest" "$name" >> "$out/SHA256SUMS"
  fi
done

versions_digest="$(sha256sum "$out/CORE-VERSIONS" | awk '{print $1}')"
printf '%s  CORE-VERSIONS\n' "$versions_digest" >> "$out/SHA256SUMS"
sort -k2,2 "$out/SHA256SUMS" -o "$out/SHA256SUMS"

# F-01 fix: the full SHA256SUMS above lists historical assets that are NOT
# present in out/. Generate a separate incoming manifest listing ONLY the
# files actually present in out/ (new binaries + CORE-VERSIONS), so the
# publish job can verify exactly the artifact contents.
: > "$out/SHA256SUMS.incoming"
for name in "${mirror_names[@]}" CORE-VERSIONS; do
  incoming_sum="$(awk -v name="$name" '$2 == name {print $1}' "$out/SHA256SUMS")"
  [[ -n "$incoming_sum" ]] || {
    echo "::error::Missing manifest entry for incoming file: $name"
    exit 1
  }
  printf '%s  %s\n' "$incoming_sum" "$name" >> "$out/SHA256SUMS.incoming"
done
sort -k2,2 "$out/SHA256SUMS.incoming" -o "$out/SHA256SUMS.incoming"

# A manual dispatch defaults to dry-run. All upstream downloads, digests,
# binary probes, existing asset digests and the merged manifest are validated
# before any Release mutation.
if [[ "${CORE_MIRROR_DRY_RUN:-0}" == '1' ]]; then
  echo "Dry-run complete; no Release assets were changed."
  printf 'Verified tags: Xray=%s sing-box=%s Hysteria=%s cloudflared=%s wgcf=%s\n' "$xray_tag" "$singbox_tag" "$hysteria_tag" "$CLOUDFLARED_VERSION" "$WGCF_VERSION"
  if (( ${#upload_paths[@]} )); then
    printf 'Would upload new versioned asset: %s\n' "${upload_paths[@]}"
  else
    echo "No new versioned binary assets need uploading."
  fi
  echo "Would update CORE-VERSIONS and publish SHA256SUMS last."
  exit 0
fi

for path in "${upload_paths[@]}"; do
  gh release upload core-binaries "$path"
done
# Publish metadata first and the manifest last. Until the new manifest is
# visible, clients reject the new metadata and continue to fail closed.
gh release upload core-binaries "$out/CORE-VERSIONS" --clobber
gh release upload core-binaries "$out/SHA256SUMS" --clobber

echo "Published latest official stable mirror versions:"
printf '  Xray: %s\n  sing-box: %s\n  Hysteria: %s\n  cloudflared: %s\n  wgcf: %s\n' "$xray_tag" "$singbox_tag" "$hysteria_tag" "$CLOUDFLARED_VERSION" "$WGCF_VERSION"
echo "Versioned assets are retained for rollback; fixed compatibility-pin assets are not replaced."

