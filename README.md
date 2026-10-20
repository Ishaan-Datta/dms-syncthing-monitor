# Syncthing Monitor for DMS

A [DankMaterialShell](https://danklinux.com/docs/dankmaterialshell/plugin-development)
plugin that shows a red warning icon in DankBar when Syncthing has conflict
copies, no connected peers, or cannot be checked.

## Features

- Hidden DankBar widget while Syncthing is healthy
- Red warning icon when one or more issues are active
- Active issues ordered from newest to oldest
- Expandable, scrollable list of all current conflict paths
- Conflict notifications with the total and up to five relative paths
- Peer disconnect, recovery, monitor failure, and monitor recovery notifications
- Persisted transition state to avoid duplicate notifications after DMS restarts
- Fast conflict searches using `fd` or `fdfind`
- Horizontal and vertical DankBar support

## Requirements

- DankMaterialShell 1.6 or newer
- Bash
- curl
- jq
- coreutils
- libxml2
- `fd` or `fdfind`
- `notify-send` from libnotify
- A local Syncthing GUI/API

## Nix installation

Add this repository as a flake input and pass its package to the official DMS
Home Manager module:

```nix
{
  inputs.dms-syncthing-monitor.url = "github:Ishaan-Datta/dms-syncthing-monitor";

  outputs = inputs@{ nixpkgs, ... }: {
    homeConfigurations.your-user = inputs.home-manager.lib.homeManagerConfiguration {
      # ...
      modules = [
        inputs.dms.homeModules.default
        ({ pkgs, ... }: {
          home.packages = with pkgs; [
            bash
            coreutils
            curl
            fd
            jq
            libnotify
            libxml2
          ];

          programs.dank-material-shell.plugins.dmsSyncthingMonitor = {
            enable = true;
            src = inputs.dms-syncthing-monitor.packages.${pkgs.system}.default;
          };
        })
      ];
    };
  };
}
```

## Configuration

Add the plugin configuration to `~/.config/DankMaterialShell/plugin_settings.json`:

```json
{
  "dmsSyncthingMonitor": {
    "pollIntervalMinutes": 1,
    "apiUrl": "http://127.0.0.1:8384",
    "insecureTls": false,
    "folders": [
      {
        "label": "Documents",
        "path": "/home/user/Documents"
      },
      {
        "label": "Obsidian",
        "path": "/home/user/Obsidian"
      }
    ]
  }
}
```

`apiUrl`, and at least one labeled absolute folder path are required.
The polling interval defaults to one minute and is clamped to 1–60 minutes.
Set `insecureTls` to `true` only when a local HTTPS GUI uses Syncthing's
self-signed certificate.

## Conflict Detection

Each configured folder is searched with the equivalent of:

```console
fd --type file --hidden --no-ignore --case-sensitive --absolute-path \
  --exclude .stfolder --exclude .stversions '\.sync-conflict-' /folder/path
```

The search includes hidden and ignored files, does not follow nested symlinks,
and excludes Syncthing metadata and standard version-history directories. File
contents are never read.

Paths are displayed as `label/relative/path`. The desktop notification contains
at most five paths followed by `and N more`; the plugin popout provides the
complete scrollable list.
