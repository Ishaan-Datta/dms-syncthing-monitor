{
  description = "Syncthing monitor plugin for DankMaterialShell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs, ... }:
    let
      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          plugin = pkgs.stdenvNoCC.mkDerivation {
            pname = "dms-plugin-syncthing-monitor";
            version = "1.0.0";
            src = pkgs.lib.fileset.toSource {
              root = ./.;
              fileset = pkgs.lib.fileset.unions [
                ./SyncthingMonitorDaemon.qml
                ./SyncthingMonitorWidget.qml
                ./StartupCheck.qml
                ./syncthing_monitor.sh
                ./plugin.json
                ./LICENSE
              ];
            };

            dontConfigure = true;
            dontBuild = true;

            installPhase = ''
              runHook preInstall
              mkdir -p "$out"
              cp \
                SyncthingMonitorDaemon.qml \
                SyncthingMonitorWidget.qml \
                StartupCheck.qml \
                syncthing_monitor.sh \
                plugin.json \
                LICENSE \
                "$out/"
              runHook postInstall
            '';

            meta = {
              description = "Show Syncthing conflicts and disconnected peers in DankBar";
              license = pkgs.lib.licenses.gpl2Only;
              platforms = pkgs.lib.platforms.linux;
            };
          };
        in
        {
          default = plugin;
          dmsSyncthingMonitor = plugin;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          package = self.packages.${system}.default;

          manifest =
            pkgs.runCommand "check-dms-syncthing-monitor-manifest"
              {
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                jq -e '
                  .id == "dmsSyncthingMonitor" and
                  .type == "composite" and
                  .components.daemon == "./SyncthingMonitorDaemon.qml" and
                  .components.widget == "./SyncthingMonitorWidget.qml" and
                  .startupCheck == "./StartupCheck.qml" and
                  (has("settings") | not)
                ' ${./plugin.json} >/dev/null

                test -f ${./SyncthingMonitorDaemon.qml}
                test -f ${./SyncthingMonitorWidget.qml}
                test -f ${./StartupCheck.qml}
                test -f ${./syncthing_monitor.sh}
                test -f ${./LICENSE}
                touch "$out"
              '';

          shellcheck =
            pkgs.runCommand "check-dms-syncthing-monitor-shell"
              {
                nativeBuildInputs = [ pkgs.shellcheck ];
              }
              ''
                shellcheck ${./syncthing_monitor.sh} ${./tests/test_syncthing_monitor.sh}
                touch "$out"
              '';

          helper-tests =
            pkgs.runCommand "check-dms-syncthing-monitor-helper"
              {
                nativeBuildInputs = with pkgs; [
                  bash
                  coreutils
                  curl
                  fd
                  jq
                ];
              }
              ''
                PROJECT_ROOT=${./.} bash ${./tests/test_syncthing_monitor.sh}
                touch "$out"
              '';
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShellNoCC {
            packages = with pkgs; [
              bashInteractive
              coreutils
              curl
              fd
              jq
              libnotify
              nixfmt
              shellcheck
            ];
          };
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
