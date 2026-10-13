#!/usr/bin/env bash
set -Eeuo pipefail
root="$RUNNER_TEMP/core-mirror"
out="$root/new"
existing="$root/existing"
mkdir -p "$out" "$existing"

gh release view core-binaries >/dev/null
gh release download core-binaries --pattern SHA256SUMS --dir "$existing"
test -s "$existing/SHA256SUMS"

gh api repos/XTLS/Xray-core/releases/latest > "$root/xray.json"
gh api repos/SagerNet/sing-box/releases/latest > "$root/sing-box.json"
gh api repos/HyNetworks/hysteria/releases/latest > "$root/hysteria.json"

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

xray_tag="$(validate_release_tag "$root/xray.json" '^v[0-9]+\.[0-9]+\.[0-9]+$')"
singbox_tag="$(validate_release_tag "$root/sing-box.json" '^v[0-9]+\.[0-9]+\.[0-9]+$')"
hysteria_tag="$(validate_release_tag "$root/hysteria.json" '^app/v[0-9]+\.[0-9]+\.[0-9]+$')"

declare -a mirror_names=()
declare -a mirror_paths=()
declare -a mirror_digests=()
declare -a upload_paths=()

download_verified_asset() {
  local repo="$1" release_file="$2" upstream_name="$3" mirror_name="$4" kind="$5"
  local tag asset_json url digest expected actual path bin member version_output
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
      version_output="$("$bin" version 2>&1)" || {
        echo "::error::Xray binary failed its version probe: $mirror_name"
        return 1
      }
      grep -Fq "${tag#v}" <<< "$version_output" || {
        echo "::error::Xray binary version does not match $tag"
        return 1
      }
      ;;
    sing-box)
      tar -tzf "$path" >/dev/null
      member="$(tar -tzf "$path" | awk '/(^|\/)sing-box$/ {print; n++} END {if (n != 1) exit 1}')"
      bin="$root/sing-box-check"
      tar -xOzf "$path" "$member" > "$bin"
      chmod 700 "$bin"
      version_output="$("$bin" version 2>&1)" || {
        echo "::error::sing-box binary failed its version probe: $mirror_name"
        return 1
      }
      expected_version="${tag#v}"
                grep -Fq "$expected_version" <<< "$version_output" || {
        echo "::error::sing-box binary version does not match $tag"
        return 1
      }
      ;;
    hysteria)
      chmod 700 "$path"
      version_output="$("$path" version 2>&1)" || {
        echo "::error::Hysteria binary failed its version probe: $mirror_name"
        return 1
      }
      expected_version="${tag#app/}"
                grep -Fq "$expected_version" <<< "$version_output" || {
        echo "::error::Hysteria binary version does not match $tag"
        return 1
      }
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
hysteria_leaf="$(tr '/' '-' <<< "$hysteria_tag" | tr -d '\n')"

download_verified_asset XTLS/Xray-core "$root/xray.json" Xray-linux-64.zip "$xray_amd64_name" xray
download_verified_asset XTLS/Xray-core "$root/xray.json" Xray-linux-arm64-v8a.zip "$xray_arm64_name" xray

download_verified_asset SagerNet/sing-box "$root/sing-box.json" "sing-box-$singbox_version-linux-amd64-glibc.tar.gz" "sing-box-$singbox_version-linux-amd64-glibc.tar.gz" sing-box
download_verified_asset SagerNet/sing-box "$root/sing-box.json" "sing-box-$singbox_version-linux-amd64-musl.tar.gz" "sing-box-$singbox_version-linux-amd64-musl.tar.gz" sing-box
download_verified_asset SagerNet/sing-box "$root/sing-box.json" "sing-box-$singbox_version-linux-arm64-glibc.tar.gz" "sing-box-$singbox_version-linux-arm64-glibc.tar.gz" sing-box
download_verified_asset SagerNet/sing-box "$root/sing-box.json" "sing-box-$singbox_version-linux-arm64-musl.tar.gz" "sing-box-$singbox_version-linux-arm64-musl.tar.gz" sing-box

download_verified_asset HyNetworks/hysteria "$root/hysteria.json" hysteria-linux-amd64 "hysteria-$hysteria_leaf-linux-amd64" hysteria
download_verified_asset HyNetworks/hysteria "$root/hysteria.json" hysteria-linux-arm64 "hysteria-$hysteria_leaf-linux-arm64" hysteria

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

# A manual dispatch defaults to dry-run. All upstream downloads, digests,
# binary probes, existing asset digests and the merged manifest are validated
# before any Release mutation.
if [[ "${CORE_MIRROR_DRY_RUN:-0}" == '1' ]]; then
  echo "Dry-run complete; no Release assets were changed."
  printf 'Verified latest tags: Xray=%s sing-box=%s Hysteria=%s\n' "$xray_tag" "$singbox_tag" "$hysteria_tag"
  printf 'Would upload new versioned asset: %s\n' "${upload_paths[@]}"
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
printf '  Xray: %s\n  sing-box: %s\n  Hysteria: %s\n' "$xray_tag" "$singbox_tag" "$hysteria_tag"
echo "Versioned assets are retained for rollback; fixed compatibility-pin assets are not replaced."

