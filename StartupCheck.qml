import QtQuick
import qs.Common

QtObject {
    readonly property string helperPath: Paths.strip(Qt.resolvedUrl("./syncthing_monitor.sh"))

    function check(done) {
        Proc.runCommand("dmsSyncthingMonitor.checkBash", ["which", "bash"], (stdout, exitCode) => {
            if (exitCode !== 0) {
                done({
                    title: "Bash is required",
                    details: "Install Bash and ensure bash is available on PATH, then re-enable Syncthing Monitor."
                })
                return
            }

            Proc.runCommand("dmsSyncthingMonitor.checkHelper", ["bash", helperPath, "--self-test"], (helperStdout, helperExitCode) => {
                if (helperExitCode !== 0) {
                    done({
                        title: "Syncthing Monitor dependencies are missing",
                        details: String(helperStdout ?? "").trim() || "Install curl, jq, coreutils, and fd or fdfind, then re-enable Syncthing Monitor."
                    })
                    return
                }

                Proc.runCommand("dmsSyncthingMonitor.checkNotifySend", ["which", "notify-send"], (notifyStdout, notifyExitCode) => {
                    if (notifyExitCode !== 0) {
                        done({
                            title: "notify-send is required",
                            details: "Install libnotify and ensure notify-send is available on PATH, then re-enable Syncthing Monitor."
                        })
                        return
                    }

                    done(null)
                })

                Proc.runCommand("dmsSyncthingMonitor.checkXmllint", ["which", "xmllint"], (notifyStdout, notifyExitCode) => {
                    if (notifyExitCode !== 0) {
                        done({
                            title: "libxml2 is required",
                            details: "Install libnxml and ensure xmllint is available on PATH, then re-enable Syncthing Monitor."
                        })
                        return
                    }

                    done(null)
                })
            })
        })
    }
}
