#!/usr/bin/env bash

set -uo pipefail

plugin_id="dmsSyncthingMonitor"
settings_file="${DMS_PLUGIN_SETTINGS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell/plugin_settings.json}"

find_fd() {
  local candidate
  local candidate_path
  local version

  for candidate in fdfind fd; do
    candidate_path="$(command -v "$candidate" 2>/dev/null)" || continue
    version="$("$candidate_path" --version 2>/dev/null)" || continue
    if [[ "$version" == fd\ * ]]; then
      printf '%s\n' "$candidate_path"
      return 0
    fi
  done
  return 1
}

self_test() {
  local missing=()
  local command_name

  for command_name in chmod curl date jq mktemp rm stat; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
  done
  find_fd >/dev/null || missing+=("fd or fdfind")

  if (( ${#missing[@]} > 0 )); then
    printf 'Missing required command(s): %s\n' "${missing[*]}"
    return 1
  fi
}

emit_configuration_error() {
  local code="$1"
  local message="$2"
  local checked_at

  checked_at="$(date +%s%3N)"
  jq -cn \
    --argjson checkedAt "$checked_at" \
    --arg code "$code" \
    --arg message "$message" \
    '{
      schemaVersion: 1,
      status: "unknown",
      checkedAt: $checkedAt,
      conflicts: {known: false, complete: false, count: 0, files: []},
      connections: {known: false, connected: null, configured: null, noneConnected: null},
      errors: [{code: $code, scope: "configuration", message: $message}]
    }'
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit $?
fi

if ! self_test >/dev/null; then
  printf '%s\n' '{"schemaVersion":1,"status":"unknown","checkedAt":0,"conflicts":{"known":false,"complete":false,"count":0,"files":[]},"connections":{"known":false,"connected":null,"configured":null,"noneConnected":null},"errors":[{"code":"DEPENDENCY_MISSING","scope":"monitor","message":"A required command is unavailable"}]}'
  exit 0
fi

if [[ ! -r "$settings_file" ]]; then
  emit_configuration_error \
    "SETTINGS_MISSING" \
    "Configure Syncthing Monitor in plugin_settings.json"
  exit 0
fi

if ! config="$(jq -ce --arg pluginId "$plugin_id" '.[$pluginId] | select(type == "object")' "$settings_file" 2>/dev/null)"; then
  emit_configuration_error \
    "SETTINGS_INVALID" \
    "Syncthing Monitor settings are missing or invalid"
  exit 0
fi

if ! jq -e '
  (.apiUrl | type == "string" and length > 0) and
  (.apiKey | type == "string" and length > 0) and
  ((.insecureTls // false) | type == "boolean") and
  (.folders | type == "array" and length > 0) and
  all(.folders[];
    type == "object" and
    (.label | type == "string" and length > 0) and
    (.path | type == "string" and startswith("/"))
  )
' >/dev/null 2>&1 <<< "$config"; then
  emit_configuration_error \
    "SETTINGS_INVALID" \
    "Set apiUrl, apiKey, and at least one labeled absolute folder path"
  exit 0
fi

api_url="$(jq -r '.apiUrl' <<< "$config")"
api_key="$(jq -r '.apiKey' <<< "$config")"
insecure_tls="$(jq -r '.insecureTls // false' <<< "$config")"
api_url="${api_url%/}"
fd_command="$(find_fd)"

runtime_parent="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
if ! temporary_directory="$(mktemp -d "$runtime_parent/dms-syncthing-monitor.XXXXXX")"; then
  emit_configuration_error \
    "RUNTIME_UNAVAILABLE" \
    "Syncthing Monitor could not create private runtime files"
  exit 0
fi
chmod 700 "$temporary_directory"
trap 'rm -rf -- "$temporary_directory"' EXIT

headers_file="$temporary_directory/headers"
conflict_records="$temporary_directory/conflicts.jsonl"
error_records="$temporary_directory/errors.jsonl"
matches_file="$temporary_directory/matches"
: > "$conflict_records"
: > "$error_records"

umask 077
printf 'X-API-Key: %s\n' "$api_key" > "$headers_file"
unset api_key

add_error() {
  local code="$1"
  local scope="$2"
  local message="$3"

  jq -cn \
    --arg code "$code" \
    --arg scope "$scope" \
    --arg message "$message" \
    '{code: $code, scope: $scope, message: $message}' \
    >> "$error_records"
}

connections='{"known":false,"connected":null,"configured":null,"noneConnected":null}'
curl_arguments=(
  --fail
  --silent
  --show-error
  --connect-timeout 2
  --max-time 5
  -H "@$headers_file"
)
if [[ "$insecure_tls" == "true" ]]; then
  curl_arguments+=(--insecure)
fi
if connection_response="$(
  curl "${curl_arguments[@]}" \
    "$api_url/rest/system/connections"
)"; then
  if parsed_connections="$(
    jq -ce '
      if (.connections | type) != "object" then
        error("connections is not an object")
      elif any(.connections[]; (.connected | type) != "boolean") then
        error("connected is not a boolean")
      else
        (.connections | [.[] | select(.connected == true)] | length) as $connected
        | {
            known: true,
            connected: $connected,
            configured: (.connections | length),
            noneConnected: ($connected == 0)
          }
      end
    ' <<< "$connection_response"
  )"; then
    connections="$parsed_connections"
  else
    add_error \
      "API_RESPONSE_INVALID" \
      "syncthing" \
      "Syncthing returned invalid connection data"
  fi
else
  add_error \
    "API_UNAVAILABLE" \
    "syncthing" \
    "Syncthing REST API is unreachable or rejected the API key"
fi

scan_complete=true
mapfile -t configured_folders < <(jq -c '.folders[]' <<< "$config")
for folder in "${configured_folders[@]}"; do
  IFS= read -r -d '' folder_label < <(jq -j '.label, "\u0000"' <<< "$folder")
  IFS= read -r -d '' folder_root < <(jq -j '.path, "\u0000"' <<< "$folder")
  while [[ "$folder_root" != "/" && "$folder_root" == */ ]]; do
    folder_root="${folder_root%/}"
  done

  if [[ ! -d "$folder_root" ]]; then
    scan_complete=false
    add_error \
      "FOLDER_MISSING" \
      "folder:$folder_label" \
      "$folder_label is not currently accessible"
    continue
  fi

  : > "$matches_file"
  if ! "$fd_command" \
    --type file \
    --hidden \
    --no-ignore \
    --case-sensitive \
    --absolute-path \
    --color never \
    --print0 \
    --exclude .stfolder \
    --exclude .stversions \
    '\.sync-conflict-' \
    "$folder_root" \
    > "$matches_file"; then
    scan_complete=false
    add_error \
      "FOLDER_UNREADABLE" \
      "folder:$folder_label" \
      "$folder_label could not be completely searched"
    continue
  fi

  while IFS= read -r -d '' absolute_path; do
    relative_path="${absolute_path#"$folder_root"}"
    relative_path="${relative_path#/}"
    if ! modified_at="$(stat --format='%Y' -- "$absolute_path" 2>/dev/null)"; then
      scan_complete=false
      add_error \
        "FILE_UNREADABLE" \
        "folder:$folder_label" \
        "A conflict in $folder_label changed while it was being inspected"
      continue
    fi

    jq -cn \
      --arg folderLabel "$folder_label" \
      --arg path "$folder_label/$relative_path" \
      --argjson modifiedAt "$((modified_at * 1000))" \
      '{folderLabel: $folderLabel, path: $path, modifiedAt: $modifiedAt}' \
      >> "$conflict_records"
  done < "$matches_file"
done

conflicts="$(jq -s 'sort_by(.modifiedAt) | reverse' "$conflict_records")"
errors="$(jq -s 'unique_by([.code, .scope, .message])' "$error_records")"
conflict_count="$(jq 'length' <<< "$conflicts")"
error_count="$(jq 'length' <<< "$errors")"
none_connected="$(jq -r '.noneConnected // false' <<< "$connections")"

if (( conflict_count > 0 )) || [[ "$none_connected" == "true" ]]; then
  status="alert"
elif (( error_count > 0 )); then
  status="unknown"
else
  status="healthy"
fi

if (( conflict_count > 0 )) || [[ "$scan_complete" == "true" ]]; then
  conflicts_known=true
else
  conflicts_known=false
fi

checked_at="$(date +%s%3N)"
jq -cn \
  --arg status "$status" \
  --argjson checkedAt "$checked_at" \
  --argjson conflictsKnown "$conflicts_known" \
  --argjson scanComplete "$scan_complete" \
  --argjson conflicts "$conflicts" \
  --argjson connections "$connections" \
  --argjson errors "$errors" \
  '{
    schemaVersion: 1,
    status: $status,
    checkedAt: $checkedAt,
    conflicts: {
      known: $conflictsKnown,
      complete: $scanComplete,
      count: ($conflicts | length),
      files: $conflicts
    },
    connections: $connections,
    errors: $errors
  }'
