import QtQuick
import Quickshell.Io
import qs.Common
import qs.Modules.Plugins

PluginComponent {
    id: root

    Item {}

    readonly property int pollIntervalMinutes: {
        const configured = Number(pluginData.pollIntervalMinutes ?? 1)
        return Number.isFinite(configured) ? Math.max(1, Math.min(60, Math.round(configured))) : 1
    }
    readonly property string helperPath: Paths.strip(Qt.resolvedUrl("./syncthing_monitor.sh"))

    property bool initialized: false
    property bool pollInProgress: false
    property bool pollPending: false
    property var notificationState: ({
        conflictCount: 0,
        conflictPaths: [],
        conflictOccurredAt: 0,
        peersOffline: false,
        monitorFailed: false,
        peersOfflineAt: 0,
        monitorFailedAt: 0
    })

    Timer {
        id: pollTimer
        interval: root.pollIntervalMinutes * 60 * 1000
        repeat: true
        running: false
        onTriggered: root.requestPoll()
    }

    Component {
        id: notificationProcess

        Process {
            property string notificationTitle: ""
            property string notificationBody: ""
            property string notificationUrgency: "normal"

            command: [
                "notify-send",
                "--app-name=Syncthing Monitor",
                "--icon=warning",
                "--urgency=" + notificationUrgency,
                "--expire-time=15000",
                notificationTitle,
                notificationBody
            ]

            onExited: (exitCode, exitStatus) => {
                if (exitCode !== 0)
                    console.error("SyncthingMonitor: notify-send exited with code", exitCode)
                destroy()
            }
        }
    }

    function loadingState() {
        return {
            schemaVersion: 1,
            phase: "loading",
            status: "unknown",
            checkedAt: 0,
            conflicts: { known: false, complete: false, count: 0, files: [] },
            connections: { known: false, connected: null, configured: null, noneConnected: null },
            errors: [],
            issues: []
        }
    }

    function failedState(message) {
        return {
            schemaVersion: 1,
            status: "unknown",
            checkedAt: Date.now(),
            conflicts: { known: false, complete: false, count: 0, files: [] },
            connections: { known: false, connected: null, configured: null, noneConnected: null },
            errors: [{ code: "HELPER_FAILED", scope: "monitor", message: message }]
        }
    }

    function requestPoll() {
        if (!initialized)
            return
        if (pollInProgress) {
            pollPending = true
            return
        }

        pollInProgress = true
        pollPending = false
        Proc.runCommand(
            "dmsSyncthingMonitor.snapshot",
            ["bash", helperPath],
            (stdout, exitCode) => {
                let snapshot
                try {
                    snapshot = JSON.parse(String(stdout ?? ""))
                    if (snapshot.schemaVersion !== 1)
                        throw new Error("unsupported helper schema")
                } catch (error) {
                    console.error("SyncthingMonitor: invalid helper response:", error)
                    snapshot = failedState("The Syncthing status helper returned an invalid response")
                }

                processSnapshot(snapshot)
                pollInProgress = false
                if (pollPending)
                    Qt.callLater(requestPoll)
            },
            0,
            120000,
            root
        )
    }

    function processSnapshot(snapshot) {
        const now = Number(snapshot.checkedAt ?? Date.now())
        const conflicts = snapshot.conflicts ?? { known: false, complete: false, count: 0, files: [] }
        const connections = snapshot.connections ?? { known: false, connected: null, configured: null, noneConnected: null }
        const errors = Array.isArray(snapshot.errors) ? snapshot.errors : []
        const files = Array.isArray(conflicts.files) ? conflicts.files : []
        const conflictCount = Math.max(0, Number(conflicts.count ?? files.length))
        const conflictsKnown = conflicts.known === true
        const conflictsComplete = conflicts.complete === true
        const connectionKnown = connections.known === true
        const peersOfflineNow = connectionKnown && connections.noneConnected === true
        const peersOnlineNow = connectionKnown && connections.noneConnected === false
        const monitorFailed = errors.length > 0
        const previous = notificationState ?? {}
        const previousConflictPaths = Array.isArray(previous.conflictPaths) ? previous.conflictPaths : []
        const conflictPaths = files.map(file => String(file.path ?? ""))
        const hasNewConflicts = conflictsKnown
            && conflictPaths.some(path => previousConflictPaths.indexOf(path) === -1)
        const trackedConflictPaths = conflictsComplete
            ? conflictPaths
            : previousConflictPaths.concat(
                conflictPaths.filter(path => previousConflictPaths.indexOf(path) === -1)
            )
        const trackedConflictCount = conflictsComplete
            ? conflictCount
            : Math.max(Number(previous.conflictCount ?? 0), trackedConflictPaths.length)

        let conflictOccurredAt = Number(previous.conflictOccurredAt ?? 0)
        if (conflictsKnown) {
            if (conflictCount === 0)
                conflictOccurredAt = 0
            else if (hasNewConflicts || conflictOccurredAt <= 0)
                conflictOccurredAt = now
        }

        let peersOfflineAt = Number(previous.peersOfflineAt ?? 0)
        let peersOffline = previous.peersOffline === true
        if (connectionKnown) {
            peersOffline = peersOfflineNow
            if (peersOfflineNow && previous.peersOffline !== true)
                peersOfflineAt = now
            else if (peersOnlineNow)
                peersOfflineAt = 0
        }

        let monitorFailedAt = Number(previous.monitorFailedAt ?? 0)
        if (monitorFailed && previous.monitorFailed !== true)
            monitorFailedAt = now
        else if (!monitorFailed)
            monitorFailedAt = 0

        const nextNotificationState = {
            conflictCount: trackedConflictCount,
            conflictPaths: trackedConflictPaths,
            conflictOccurredAt: conflictOccurredAt,
            peersOffline: peersOffline,
            monitorFailed: monitorFailed,
            peersOfflineAt: peersOfflineAt,
            monitorFailedAt: monitorFailedAt
        }

        if (conflictCount > 0 && hasNewConflicts)
            sendConflictNotification(files, conflictCount)
        if (peersOfflineNow && previous.peersOffline !== true)
            sendNotification(
                "Syncthing has no peers online",
                "No remote Syncthing devices are currently connected.",
                "critical"
            )
        else if (peersOnlineNow && previous.peersOffline === true)
            sendNotification(
                "Syncthing connection restored",
                Number(connections.connected ?? 0) + " remote device(s) connected.",
                "normal"
            )
        if (monitorFailed && previous.monitorFailed !== true)
            sendNotification(
                "Syncthing monitor check failed",
                errorMessages(errors).join("\n"),
                "critical"
            )
        else if (!monitorFailed && previous.monitorFailed === true)
            sendNotification("Syncthing monitor recovered", "Status checks are working again.", "normal")

        notificationState = nextNotificationState
        persistNotificationState()

        const issues = buildIssues(
            conflicts,
            connections,
            errors,
            conflictOccurredAt,
            peersOfflineAt,
            monitorFailedAt,
            now
        )
        const published = Object.assign({}, snapshot, {
            phase: "ready",
            issues: issues
        })
        publishState(published)
    }

    function buildIssues(conflicts, connections, errors, conflictOccurredAt, peersOfflineAt, monitorFailedAt, checkedAt) {
        const issues = []
        const files = Array.isArray(conflicts.files) ? conflicts.files : []
        const conflictCount = Math.max(0, Number(conflicts.count ?? files.length))

        if (conflictCount > 0) {
            issues.push({
                id: "conflicts",
                icon: "file_copy",
                title: conflictCount === 1 ? "1 conflicted file" : conflictCount + " conflicted files",
                summary: "Syncthing conflict copies need attention.",
                occurredAt: conflictOccurredAt || checkedAt,
                paths: files.map(file => String(file.path ?? ""))
            })
        }

        if (connections.known === true && connections.noneConnected === true) {
            const configured = Number(connections.configured ?? 0)
            issues.push({
                id: "peers",
                icon: "devices_off",
                title: "No peer devices connected",
                summary: configured === 0
                    ? "No remote Syncthing devices are configured."
                    : configured + " configured remote device(s) are offline.",
                occurredAt: peersOfflineAt || checkedAt,
                paths: []
            })
        }

        if (errors.length > 0) {
            issues.push({
                id: "monitor",
                icon: "sync_problem",
                title: "Status check incomplete",
                summary: errorMessages(errors).join(" "),
                occurredAt: monitorFailedAt || checkedAt,
                paths: []
            })
        }

        issues.sort((left, right) => Number(right.occurredAt ?? 0) - Number(left.occurredAt ?? 0))
        return issues
    }

    function errorMessages(errors) {
        const messages = errors
            .map(error => String(error.message ?? "Syncthing status could not be checked"))
            .filter((message, index, all) => message !== "" && all.indexOf(message) === index)
        return messages.length > 0 ? messages : ["Syncthing status could not be checked"]
    }

    function htmlEscape(value) {
        return String(value ?? "")
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
    }

    function sendConflictNotification(files, total) {
        const visiblePaths = files.slice(0, 5)
        const lines = [
            "<b>" + total + (total === 1 ? " conflict file detected." : " conflict files detected.") + "</b>"
        ]
        visiblePaths.forEach(file => {
            lines.push("<code>" + htmlEscape(file.path ?? "") + "</code>")
        })
        if (total > visiblePaths.length)
            lines.push("<i>and " + (total - visiblePaths.length) + " more</i>")
        sendNotification("Syncthing conflicts detected", lines.join("<br/>\n"), "critical")
    }

    function sendNotification(title, body, urgency) {
        const process = notificationProcess.createObject(root, {
            notificationTitle: title,
            notificationBody: body,
            notificationUrgency: urgency
        })
        process.running = true
    }

    function publishState(state) {
        if (pluginService && pluginId)
            pluginService.setGlobalVar(pluginId, "syncthingState", state)
    }

    function persistNotificationState() {
        if (pluginService && pluginId)
            pluginService.savePluginState(pluginId, "notificationState", notificationState)
    }

    function updatePollTimer() {
        if (!initialized)
            return
        pollTimer.restart()
    }

    function initialize() {
        if (initialized || !pluginService || !pluginId)
            return
        initialized = true
        const savedNotificationState = pluginService.loadPluginState(pluginId, "notificationState", {}) ?? {}
        notificationState = Object.assign({}, notificationState, savedNotificationState)
        publishState(loadingState())
        updatePollTimer()
        requestPoll()
    }

    onPollIntervalMinutesChanged: updatePollTimer()
    onPluginDataChanged: requestPoll()
    onPluginServiceChanged: Qt.callLater(initialize)
    Component.onCompleted: Qt.callLater(initialize)

    Component.onDestruction: {
        pollTimer.stop()
        pollPending = false
    }
}
