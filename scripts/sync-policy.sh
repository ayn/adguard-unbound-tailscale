#!/usr/bin/env bash
set -euo pipefail

DEFAULT_SRC="https://agh-source.example"
DEFAULT_DST="https://agh-dest.example"

SRC="${SRC:-$DEFAULT_SRC}"
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
Usage: $SCRIPT_NAME [--src URL] [--dst URL ...]

Sync global AdGuard Home policy from a source instance to one or more
destination instances using the HTTP API and netrc credentials.

This script syncs:
  - global custom filtering rules from /control/filtering/status
  - global blocklist filters from /control/filtering/status
  - global SafeSearch settings from /control/safesearch/status

Defaults:
  SRC=$DEFAULT_SRC
  DST=$DEFAULT_DST

Flags:
  -s, --src URL       Source AdGuard Home base URL
  -d, --dst URL       Destination AdGuard Home base URL (repeatable)
  -h, --help          Show this help text

Environment overrides:
  SRC=...
  DST=...
  DSTS="https://agh-a.example https://agh-b.example"

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME --dst https://agh-b.example --dst https://agh-c.example
  SRC=https://agh-a.example DSTS="https://agh-b.example https://agh-c.example" \\
    $SCRIPT_NAME

Notes:
  - Uses curl -n, so credentials are read from ~/.netrc.
  - Does not print secrets.
  - Treats source blocklist filters as authoritative: missing filters are added,
    matching filters are updated, and destination-only filters are removed.
  - Skips writes when a destination is already in sync.
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

[[ "${#DEST_URLS[@]}" -gt 0 ]] || die "at least one destination URL is required"

need_cmd curl
need_cmd jq

SRC="$(trim_url "$SRC")"
for i in "${!DEST_URLS[@]}"; do
  DEST_URLS[i]="$(trim_url "${DEST_URLS[$i]}")"
done

src_filtering_file="$TMPDIR/src-filtering.json"
src_safesearch_file="$TMPDIR/src-safesearch.json"
rules_payload_file="$TMPDIR/rules-payload.json"
safesearch_payload_file="$TMPDIR/safesearch-payload.json"

request_json GET "$SRC/control/filtering/status" "$src_filtering_file"
request_json GET "$SRC/control/safesearch/status" "$src_safesearch_file"

jq '
  {
    rules: (.user_rules // [])
  }
' "$src_filtering_file" > "$rules_payload_file"

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
    "enabled",
    "bing",
    "duckduckgo",
    "ecosia",
    "google",
    "pixabay",
    "yandex",
    "youtube"
  ])
' "$src_safesearch_file" > "$safesearch_payload_file"

sync_filter_lists() {
  local dst=$1
  local dst_filtering_file=$2
  local response_file=$3
  local slug add_ops_file update_ops_file remove_ops_file op_file
  local add_count update_count remove_count changed_count

  slug="$(slugify "$dst")"
  add_ops_file="$TMPDIR/filter-add-ops-$slug.json"
  update_ops_file="$TMPDIR/filter-update-ops-$slug.json"
  remove_ops_file="$TMPDIR/filter-remove-ops-$slug.json"
  op_file="$TMPDIR/filter-op-$slug.json"

  jq -n \
    --slurpfile src "$src_filtering_file" \
    --slurpfile dst "$dst_filtering_file" '
      def filters($obj):
        ($obj.filters // [])
        | map(select((.url // "") != ""))
        | map({
            name: (.name // .url),
            url,
            enabled: (.enabled // true)
          });

      (filters($src[0])) as $src_filters
      | (filters($dst[0]) | map(.url)) as $dst_urls
      | $src_filters
      | map(select(.url as $url | $dst_urls | index($url) | not))
      | map({
          name,
          url,
          enabled,
          whitelist: false
        })
    ' > "$add_ops_file"

  jq -n \
    --slurpfile src "$src_filtering_file" \
    --slurpfile dst "$dst_filtering_file" '
      def filters($obj):
        ($obj.filters // [])
        | map(select((.url // "") != ""))
        | map({
            name: (.name // .url),
            url,
            enabled: (.enabled // true)
          });

      (filters($src[0])) as $src_filters
      | (filters($dst[0])) as $dst_filters
      | $src_filters
      | map(
          . as $src_filter
          | ($dst_filters[]? | select(.url == $src_filter.url)) as $dst_filter
          | select(
              $dst_filter.name != $src_filter.name
              or $dst_filter.enabled != $src_filter.enabled
            )
          | {
              url: $src_filter.url,
              whitelist: false,
              data: $src_filter
            }
        )
    ' > "$update_ops_file"

  jq -n \
    --slurpfile src "$src_filtering_file" \
    --slurpfile dst "$dst_filtering_file" '
      def filters($obj):
        ($obj.filters // [])
        | map(select((.url // "") != ""))
        | map({
            name: (.name // .url),
            url,
            enabled: (.enabled // true)
          });

      (filters($src[0]) | map(.url)) as $src_urls
      | filters($dst[0])
      | map(select(.url as $url | $src_urls | index($url) | not))
      | map({
          url,
          whitelist: false
        })
    ' > "$remove_ops_file"

  add_count="$(jq 'length' "$add_ops_file")" || return 1
  update_count="$(jq 'length' "$update_ops_file")" || return 1
  remove_count="$(jq 'length' "$remove_ops_file")" || return 1
  changed_count=$((add_count + update_count + remove_count))

  if [[ "$changed_count" -eq 0 ]]; then
    printf 'in sync'
    return 0
  fi

  while IFS= read -r op; do
    printf '%s\n' "$op" | jq '{name, url, whitelist}' > "$op_file"
    if ! request_json POST "$dst/control/filtering/add_url" "$response_file" "$op_file"; then
      return 1
    fi
    if jq -e '.enabled == false' >/dev/null <<< "$op"; then
      printf '%s\n' "$op" | jq '{url, whitelist, data: {name, url, enabled}}' > "$op_file"
      if ! request_json POST "$dst/control/filtering/set_url" "$response_file" "$op_file"; then
        return 1
      fi
    fi
  done < <(jq -c '.[]' "$add_ops_file")

  while IFS= read -r op; do
    printf '%s\n' "$op" > "$op_file"
    if ! request_json POST "$dst/control/filtering/set_url" "$response_file" "$op_file"; then
      return 1
    fi
  done < <(jq -c '.[]' "$update_ops_file")

  while IFS= read -r op; do
    printf '%s\n' "$op" > "$op_file"
    if ! request_json POST "$dst/control/filtering/remove_url" "$response_file" "$op_file"; then
      return 1
    fi
  done < <(jq -c '.[]' "$remove_ops_file")

  printf 'updated (%s added, %s changed, %s pruned)' "$add_count" "$update_count" "$remove_count"
}

sync_one_destination() {
  local dst=$1
  local slug dst_filtering_file dst_safesearch_file response_file
  local filters_status rules_status safesearch_status

  slug="$(slugify "$dst")"
  dst_filtering_file="$TMPDIR/dst-filtering-$slug.json"
  dst_safesearch_file="$TMPDIR/dst-safesearch-$slug.json"
  response_file="$TMPDIR/response-$slug.json"

  if ! request_json GET "$dst/control/filtering/status" "$dst_filtering_file"; then
    return 1
  fi
  if ! request_json GET "$dst/control/safesearch/status" "$dst_safesearch_file"; then
    return 1
  fi

  filters_status="$(sync_filter_lists "$dst" "$dst_filtering_file" "$response_file")" || return 1

  rules_status='in sync'
  if jq -e -n \
    --slurpfile src "$rules_payload_file" \
    --slurpfile dst "$dst_filtering_file" \
    '($src[0].rules // []) == ($dst[0].user_rules // [])' >/dev/null; then
    :
  else
    if ! request_json POST "$dst/control/filtering/set_rules" "$response_file" "$rules_payload_file"; then
      return 1
    fi
    rules_status='updated'
  fi

  safesearch_status='in sync'
  if jq -e -n \
    --slurpfile src "$safesearch_payload_file" \
    --slurpfile dst "$dst_safesearch_file" '
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

      $src[0] == ($dst[0] | pick($src[0] | keys_unsorted))
    ' >/dev/null; then
    :
  else
    if ! request_json PUT "$dst/control/safesearch/settings" "$response_file" "$safesearch_payload_file"; then
      return 1
    fi
    safesearch_status='updated'
  fi

  printf 'Destination %s: blocklists %s, filtering rules %s, SafeSearch %s.\n' "$dst" "$filters_status" "$rules_status" "$safesearch_status"
}

success_count=0
failure_count=0

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
