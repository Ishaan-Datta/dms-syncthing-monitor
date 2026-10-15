#!/usr/bin/env bash

set -euo pipefail

project_root="${PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
temporary_directory="$(mktemp -d)"
trap 'rm -rf -- "$temporary_directory"' EXIT

mkdir -p \
  "$temporary_directory/bin" \
  "$temporary_directory/Documents/ignored" \
  "$temporary_directory/Documents/.stversions" \
  "$temporary_directory/Obsidian"

{
  printf '#!%s\n' "$(command -v bash)"
  cat <<'EOF'
cat "$MOCK_CONNECTIONS_FILE"
EOF
} > "$temporary_directory/bin/curl"
chmod +x "$temporary_directory/bin/curl"

settings_file="$temporary_directory/plugin_settings.json"
connections_file="$temporary_directory/connections.json"

jq -n \
  --arg documents "$temporary_directory/Documents" \
  --arg obsidian "$temporary_directory/Obsidian" \
  '{
    dmsSyncthingMonitor: {
      pollIntervalMinutes: 1,
      apiUrl: "http://127.0.0.1:8384",
      apiKey: "secret-test-key",
      folders: [
        {label: "Documents", path: $documents},
        {label: "Obsidian", path: $obsidian}
      ]
    }
  }' > "$settings_file"

printf 'conflict\n' > "$temporary_directory/Documents/report.sync-conflict-20261014-120000-ABC.txt"
printf 'conflict\n' > "$temporary_directory/Documents/ignored/notes.sync-conflict-20261014-120100-ABC.md"
printf 'archived\n' > "$temporary_directory/Documents/.stversions/old.sync-conflict-20261014-120200-ABC.txt"
printf 'ignored/*\n' > "$temporary_directory/Documents/.gitignore"

cat > "$connections_file" <<'EOF'
{
  "connections": {
    "DEVICE-A": {"connected": true},
    "DEVICE-B": {"connected": false}
  }
}
EOF

run_monitor() {
  PATH="$temporary_directory/bin:$PATH" \
  DMS_PLUGIN_SETTINGS_FILE="$settings_file" \
  MOCK_CONNECTIONS_FILE="$connections_file" \
    bash "$project_root/syncthing_monitor.sh"
}

snapshot="$(run_monitor)"
jq -e '
  .status == "alert" and
  .conflicts.known == true and
  .conflicts.complete == true and
  .conflicts.count == 2 and
  (.conflicts.files | map(.path) | sort) == [
    "Documents/ignored/notes.sync-conflict-20261014-120100-ABC.md",
    "Documents/report.sync-conflict-20261014-120000-ABC.txt"
  ] and
  .connections.connected == 1 and
  .connections.configured == 2 and
  .connections.noneConnected == false and
  (.errors | length) == 0
' >/dev/null <<< "$snapshot"
if [[ "$snapshot" == *"secret-test-key"* ]]; then
  printf 'API key leaked into helper output\n' >&2
  exit 1
fi

cat > "$connections_file" <<'EOF'
{"connections":{"DEVICE-A":{"connected":false},"DEVICE-B":{"connected":false}}}
EOF
snapshot="$(run_monitor)"
jq -e '
  .status == "alert" and
  .connections.connected == 0 and
  .connections.noneConnected == true
' >/dev/null <<< "$snapshot"

rm \
  "$temporary_directory/Documents/report.sync-conflict-20261014-120000-ABC.txt" \
  "$temporary_directory/Documents/ignored/notes.sync-conflict-20261014-120100-ABC.md"
cat > "$connections_file" <<'EOF'
{"connections":{"DEVICE-A":{"connected":true}}}
EOF
snapshot="$(run_monitor)"
jq -e '
  .status == "healthy" and
  .conflicts.count == 0 and
  .connections.connected == 1
' >/dev/null <<< "$snapshot"

jq \
  '.dmsSyncthingMonitor.folders[1].path = "/missing/syncthing-folder"' \
  "$settings_file" > "$settings_file.next"
mv "$settings_file.next" "$settings_file"
snapshot="$(run_monitor)"
jq -e '
  .status == "unknown" and
  .conflicts.known == false and
  .conflicts.complete == false and
  .connections.known == true and
  any(.errors[]; .code == "FOLDER_MISSING")
' >/dev/null <<< "$snapshot"

PATH="$temporary_directory/bin:$PATH" bash "$project_root/syncthing_monitor.sh" --self-test
