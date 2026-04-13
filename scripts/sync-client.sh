#!/usr/bin/env bash
set -euo pipefail

DEFAULT_SRC="https://agh-source.example"
DEFAULT_DST="https://agh-dest.example"

SRC="${SRC:-$DEFAULT_SRC}"
CLIENT_SELECTOR="${CLIENT_NAME:-${CLIENT:-}}"
DSTS_ENV="${DSTS:-}"
DST_ENV="${DST:-}"

declare -a DEST_URLS=()
if [[ -n "$DSTS_ENV" ]]; then
  read -r -a DEST_URLS <<< "${DSTS_ENV//,/ }"
elif [[ -n "$DST_ENV" ]]; then
  DEST_URLS=("$DST_ENV")
else
  DEST_URLS=("$DEFAULT_DST")
fi

SCRIPT_NAME="$(basename "$0")"
TMPDIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMPDIR"
}

trap cleanup EXIT

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME --client NAME_OR_ID [--src URL] [--dst URL ...]

Copy one client policy from a source AdGuard Home instance to one or more
destination instances using the AdGuard Home HTTP API and netrc credentials.

Defaults:
  SRC=$DEFAULT_SRC
  DST=$DEFAULT_DST

Flags:
  -c, --client NAME_OR_ID  Exact client name or exact client ID from ids[]
  -s, --src URL            Source AdGuard Home base URL
  -d, --dst URL            Destination AdGuard Home base URL (repeatable)
  -h, --help               Show this help text

Environment overrides:
  SRC=...
  DST=...
  DSTS="https://agh-a.example https://agh-b.example"
  CLIENT_NAME=...

Examples:
  $SCRIPT_NAME --client "Example Phone"
  $SCRIPT_NAME --client example-phone --dst https://agh-b.example
  SRC=https://agh-a.example DSTS="https://agh-b.example https://agh-c.example" \\
    $SCRIPT_NAME -c example-phone

Notes:
  - Uses curl -n, so credentials are read from ~/.netrc.
  - Does not print secrets.
  - Only syncs selected per-device policy fields and preserves unrelated
    destination-specific client settings during updates.
  - Continues across destinations and exits nonzero if any destination fails.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

trim_url() {
  printf '%s' "${1%/}"
}

slugify() {
  printf '%s' "$1" | sed 's#[^A-Za-z0-9_.-]#_#g'
}

request_json() {
  local method=$1
  local url=$2
  local out_file=$3
  local data_file=${4:-}
  local status
  local curl_args=(
    -sS
    -n
    --request "$method"
    --header "Accept: application/json"
    --output "$out_file"
    --write-out "%{http_code}"
  )

  if [[ -n "$data_file" ]]; then
    curl_args+=(
      --header "Content-Type: application/json"
      --data @"$data_file"
    )
  fi

  status="$(curl "${curl_args[@]}" "$url")" || {
    local rc=$?
    printf 'Request failed: %s %s\n' "$method" "$url" >&2
    if [[ -s "$out_file" ]]; then
      cat "$out_file" >&2
    fi
    return "$rc"
  }

  if [[ ! "$status" =~ ^2[0-9][0-9]$ ]]; then
    printf 'Request failed: %s %s (HTTP %s)\n' "$method" "$url" "$status" >&2
    if [[ -s "$out_file" ]]; then
      cat "$out_file" >&2
    fi
    return 1
  fi
}

dst_overridden=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--client)
      [[ $# -ge 2 ]] || die "missing value for $1"
      CLIENT_SELECTOR=$2
      shift 2
      ;;
    -s|--src)
      [[ $# -ge 2 ]] || die "missing value for $1"
      SRC=$2
      shift 2
      ;;
    -d|--dst)
      [[ $# -ge 2 ]] || die "missing value for $1"
      if [[ "$dst_overridden" -eq 0 ]]; then
        DEST_URLS=()
        dst_overridden=1
      fi
      DEST_URLS+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$CLIENT_SELECTOR" ]] || {
  usage >&2
  die "--client or CLIENT_NAME is required"
}
[[ "${#DEST_URLS[@]}" -gt 0 ]] || die "at least one destination URL is required"

need_cmd curl
need_cmd jq

SRC="$(trim_url "$SRC")"
for i in "${!DEST_URLS[@]}"; do
  DEST_URLS[$i]="$(trim_url "${DEST_URLS[$i]}")"
done

src_clients_file="$TMPDIR/src-clients.json"
source_client_file="$TMPDIR/source-client.json"
source_sync_file="$TMPDIR/source-sync.json"

request_json GET "$SRC/control/clients" "$src_clients_file"

src_matches="$(jq -r --arg selector "$CLIENT_SELECTOR" '
  (.clients // [])
  | map(select(
      (.name == $selector)
      or (((.ids // []) | index($selector)) != null)
    ))
  | length
' "$src_clients_file")"

case "$src_matches" in
  0)
    die "client not found on source by name or id: $CLIENT_SELECTOR"
    ;;
  1)
    jq -e --arg selector "$CLIENT_SELECTOR" '
      (.clients // [])
      | map(select(
          (.name == $selector)
          or (((.ids // []) | index($selector)) != null)
        ))
      | .[0]
    ' "$src_clients_file" > "$source_client_file"
    ;;
  *)
    die "multiple source clients matched selector: $CLIENT_SELECTOR"
    ;;
esac

SOURCE_CLIENT_NAME="$(jq -r '.name' "$source_client_file")"

# Sync only policy-related client fields.  The filter is presence-sensitive,
# so fields absent on the source are left untouched on updates.
jq '
  def pick($keys):
    . as $in
    | reduce $keys[] as $key (
        {};
        if $in | has($key) then
          . + {($key): $in[$key]}
        else
          .
        end
      );

  pick([
    "name",
    "ids",
    "tags",
    "use_global_settings",
    "filtering_enabled",
    "safebrowsing_enabled",
    "parental_enabled",
    "safesearch_enabled",
    "safe_search",
    "use_global_blocked_services",
    "blocked_services_schedule",
    "blocked_services"
  ])
' "$source_client_file" > "$source_sync_file"

sync_one_destination() {
  local dst=$1
  local slug dst_clients_file dest_client_file dest_mutable_file
  local update_data_file add_payload_file update_payload_file changed_keys_file
  local response_file dest_matches synced_fields changed_fields added_fields

  slug="$(slugify "$dst")"
  dst_clients_file="$TMPDIR/dst-clients-$slug.json"
  dest_client_file="$TMPDIR/dest-client-$slug.json"
  dest_mutable_file="$TMPDIR/dest-mutable-$slug.json"
  update_data_file="$TMPDIR/update-data-$slug.json"
  add_payload_file="$TMPDIR/add-payload-$slug.json"
  update_payload_file="$TMPDIR/update-payload-$slug.json"
  changed_keys_file="$TMPDIR/changed-keys-$slug.json"
  response_file="$TMPDIR/response-$slug.json"

  if ! request_json GET "$dst/control/clients" "$dst_clients_file"; then
    return 1
  fi

  dest_matches="$(jq -r --arg name "$SOURCE_CLIENT_NAME" '
    (.clients // [])
    | map(select(.name == $name))
    | length
  ' "$dst_clients_file")" || return 1

  case "$dest_matches" in
    0)
      cp "$source_sync_file" "$add_payload_file"
      if ! request_json POST "$dst/control/clients/add" "$response_file" "$add_payload_file"; then
        return 1
      fi

      added_fields="$(jq -r 'keys_unsorted | join(", ")' "$source_sync_file")" || return 1
      printf 'Destination %s: added client "%s".\n' "$dst" "$SOURCE_CLIENT_NAME"
      printf 'Copied fields: %s\n' "${added_fields:-none}"
      ;;
    1)
      jq -e --arg name "$SOURCE_CLIENT_NAME" '
        (.clients // [])
        | map(select(.name == $name))
        | .[0]
      ' "$dst_clients_file" > "$dest_client_file" || return 1

      jq '
        def pick($keys):
          . as $in
          | reduce $keys[] as $key (
              {};
              if $in | has($key) then
                . + {($key): $in[$key]}
              else
                .
              end
            );

        pick([
          "name",
          "ids",
          "use_global_settings",
          "filtering_enabled",
          "parental_enabled",
          "safebrowsing_enabled",
          "safesearch_enabled",
          "safe_search",
          "use_global_blocked_services",
          "blocked_services_schedule",
          "blocked_services",
          "upstreams",
          "tags",
          "ignore_querylog",
          "ignore_statistics",
          "upstreams_cache_enabled",
          "upstreams_cache_size"
        ])
      ' "$dest_client_file" > "$dest_mutable_file" || return 1

      jq -n \
        --slurpfile dst "$dest_mutable_file" \
        --slurpfile src "$source_sync_file" \
        '$dst[0] + $src[0]' \
        > "$update_data_file" || return 1

      if jq -e -n \
        --slurpfile dst "$dest_mutable_file" \
        --slurpfile merged "$update_data_file" \
        '$dst[0] == $merged[0]' >/dev/null; then
        synced_fields="$(jq -r 'keys_unsorted | join(", ")' "$source_sync_file")" || return 1
        printf 'Destination %s: no changes needed for client "%s".\n' "$dst" "$SOURCE_CLIENT_NAME"
        printf 'Fields considered: %s\n' "${synced_fields:-none}"
        return 0
      fi

      jq -n \
        --arg name "$SOURCE_CLIENT_NAME" \
        --slurpfile data "$update_data_file" \
        '{name: $name, data: $data[0]}' \
        > "$update_payload_file" || return 1

      jq -n \
        --slurpfile src "$source_sync_file" \
        --slurpfile dst "$dest_mutable_file" '
          [
            ($src[0] | keys_unsorted[]) as $key
            | select(($dst[0] | has($key) | not) or ($dst[0][$key] != $src[0][$key]))
            | $key
          ]
        ' > "$changed_keys_file" || return 1

      if ! request_json POST "$dst/control/clients/update" "$response_file" "$update_payload_file"; then
        return 1
      fi

      changed_fields="$(jq -r 'join(", ")' "$changed_keys_file")" || return 1
      printf 'Destination %s: updated client "%s".\n' "$dst" "$SOURCE_CLIENT_NAME"
      printf 'Changed fields: %s\n' "${changed_fields:-none}"
      ;;
    *)
      printf 'Error: multiple destination clients matched name "%s" on %s\n' "$SOURCE_CLIENT_NAME" "$dst" >&2
      return 1
      ;;
  esac
}

success_count=0
failure_count=0

printf 'Source client: "%s" (selector: %s)\n' "$SOURCE_CLIENT_NAME" "$CLIENT_SELECTOR"
printf 'Source: %s\n' "$SRC"

for dst in "${DEST_URLS[@]}"; do
  if sync_one_destination "$dst"; then
    success_count=$((success_count + 1))
  else
    failure_count=$((failure_count + 1))
  fi
done

printf 'Completed: %s succeeded, %s failed.\n' "$success_count" "$failure_count"

if [[ "$failure_count" -gt 0 ]]; then
  exit 1
fi
