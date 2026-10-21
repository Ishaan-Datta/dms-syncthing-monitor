import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root
    layerNamespacePlugin: "syncthing-monitor"

    PluginGlobalVar {
        id: sharedState
        varName: "syncthingState"
        defaultValue: ({
            schemaVersion: 1,
            phase: "loading",
            issues: []
        })
    }

    readonly property var monitorState: sharedState.value ?? ({})
    readonly property var activeIssues: {
        const issues = Array.isArray(monitorState.issues) ? monitorState.issues.slice() : []
        issues.sort((left, right) => Number(right.occurredAt ?? 0) - Number(left.occurredAt ?? 0))
        return issues
    }
    readonly property bool hasIssues: monitorState.phase === "ready" && activeIssues.length > 0
    readonly property real issueListViewportHeight: Math.min(issueListContentHeight, 380)
    property string expandedIssueId: ""
    property real issueListContentHeight: 0

    function updateVisibility() {
        setVisibilityOverride(hasIssues)
        if (!hasIssues) {
            expandedIssueId = ""
            closePopout()
        }
    }

    function formatTimestamp(timestamp) {
        const value = Number(timestamp ?? 0)
        if (value <= 0)
            return ""
        return Qt.formatDateTime(new Date(value), "MMM d, hh:mm")
    }

    onHasIssuesChanged: updateVisibility()
    Component.onCompleted: updateVisibility()

    popoutWidth: 420
    popoutHeight: issueListViewportHeight + 100

    popoutContent: Component {
        PopoutComponent {
            headerText: "Syncthing warnings"
            detailsText: ""
            showCloseButton: true

            Item {
                width: parent.width
                implicitHeight: root.issueListViewportHeight

                Flickable {
                    anchors.fill: parent
                    contentWidth: width
                    contentHeight: issueList.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    interactive: contentHeight > height

                    Column {
                        id: issueList
                        width: parent.width
                        spacing: Theme.spacingS
                        onImplicitHeightChanged: root.issueListContentHeight = implicitHeight
                        Component.onCompleted: root.issueListContentHeight = implicitHeight

                        Repeater {
                            model: root.activeIssues

                            StyledRect {
                                id: issueCard
                                required property var modelData
                                readonly property var issue: modelData
                                readonly property var paths: issue.paths ?? []
                                readonly property bool expandable: Number(paths.length ?? 0) > 0
                                readonly property bool expanded: root.expandedIssueId === String(issue.id ?? "")

                                width: issueList.width
                                height: issueContent.implicitHeight + Theme.spacingM * 2
                                radius: Theme.cornerRadius
                                color: Theme.surfaceContainerHigh

                                Column {
                                    id: issueContent
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    anchors.margins: Theme.spacingM
                                    spacing: Theme.spacingS

                                    Row {
                                        width: parent.width
                                        spacing: Theme.spacingM

                                        DankIcon {
                                            name: String(issueCard.issue.icon ?? "warning")
                                            size: Theme.iconSize
                                            color: Theme.error
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        Column {
                                            width: parent.width - Theme.iconSize - expandIcon.width - Theme.spacingM * 2
                                            spacing: Theme.spacingXS
                                            anchors.verticalCenter: parent.verticalCenter

                                            StyledText {
                                                width: parent.width
                                                text: String(issueCard.issue.title ?? "Syncthing warning")
                                                font.pixelSize: Theme.fontSizeMedium
                                                font.weight: Font.Medium
                                                color: Theme.widgetTextColor
                                                elide: Text.ElideRight
                                            }

                                            StyledText {
                                                width: parent.width
                                                text: root.formatTimestamp(issueCard.issue.occurredAt)
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.withAlpha(Theme.widgetTextColor, 0.65)
                                                visible: text !== ""
                                            }
                                        }

                                        DankIcon {
                                            id: expandIcon
                                            name: issueCard.expanded ? "expand_less" : "expand_more"
                                            size: Theme.iconSize
                                            color: Theme.surfaceVariantText
                                            visible: issueCard.expandable
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }

                                    StyledText {
                                        width: parent.width
                                        text: String(issueCard.issue.summary ?? "")
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.withAlpha(Theme.widgetTextColor, 0.8)
                                        wrapMode: Text.WordWrap
                                    }

                                    Column {
                                        width: parent.width
                                        spacing: Theme.spacingXS
                                        visible: issueCard.expanded && issueCard.expandable

                                        Repeater {
                                            model: issueCard.paths

                                            StyledText {
                                                required property string modelData
                                                width: parent.width
                                                text: modelData
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceVariantText
                                                wrapMode: Text.WrapAnywhere
                                            }
                                        }
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    enabled: issueCard.expandable
                                    hoverEnabled: enabled
                                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: {
                                        root.expandedIssueId = issueCard.expanded ? "" : String(issueCard.issue.id ?? "")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    horizontalBarPill: Component {
        DankIcon {
            name: "warning"
            size: root.iconSize
            color: Theme.error
        }
    }

    verticalBarPill: Component {
        DankIcon {
            name: "warning"
            size: root.iconSize
            color: Theme.error
        }
    }
}
