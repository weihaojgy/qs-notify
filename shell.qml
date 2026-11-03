import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Services.Notifications
import QtQuick
import QtQuick.Layouts

import "config.js" as Config

Scope {
    id: root

    // Pon a true temporalmente para ver logs de diagnóstico
    readonly property bool debug: false

    property bool centerOpen: false
    property bool modalShown: false

    readonly property int cardWidth: 350
    readonly property int maxHistory: Config.notifications.maxHistory || 60

    property int pidCounter: 0

    Component.onCompleted: if (debug) console.log("[notify-center] módulo cargado")

    onCenterOpenChanged: {
        if (centerOpen) {
            root.flushPopups()
            modalHideTimer.stop()
            modalShown = true
        } else {
            modalHideTimer.restart()
        }
    }

    Timer {
        id: modalHideTimer
        interval: 190
        onTriggered: root.modalShown = false
    }

    function openCenter()  { centerOpen = true }
    function closeCenter() { centerOpen = false }
    function toggleCenter(){ centerOpen = !centerOpen }

    // ------------------------------------------------------------------
    // Helpers seguros
    // ------------------------------------------------------------------
    function safeDismiss(n) {
        try {
            if (n && n.tracked === true) n.dismiss()
        } catch (e) {
            if (debug) console.log("[notify-center] dismiss falló:", e.message)
        }
    }

    ListModel { id: history }
    ListModel { id: popups }

    function pushNotification(n) {
        const pid = ++root.pidCounter

        // Coerción explícita: evita "Unable to assign [undefined] to QString"
        const entry = {
            pid: pid,
            summary: String(n.summary ?? ""),
            body: String(n.body ?? ""),
            appName: String(n.appName ?? ""),
            appIcon: String(n.appIcon ?? ""),
            image: String(n.image ?? ""),
            urgency: n.urgency,
            time: Qt.formatDateTime(new Date(), "HH:mm"),
            notif: n
        }

        history.insert(0, entry)
        while (history.count > root.maxHistory)
            history.remove(history.count - 1)

        if (!root.centerOpen)
            popups.insert(0, entry)

        if (debug)
            console.log("[notify-center] notif:", entry.appName, "|", entry.summary,
                        "| urgency:", entry.urgency,
                        "| popups:", popups.count,
                        "| tracked:", server.trackedNotifications.length)
    }

    function removePopupById(pid) {
        for (let i = 0; i < popups.count; i++) {
            if (popups.get(i).pid === pid) {
                popups.remove(i)
                return
            }
        }
    }

    function dismissPopup(pid, n) {
        root.removePopupById(pid)
        root.safeDismiss(n)
    }

    function flushPopups() {
        for (let i = popups.count - 1; i >= 0; i--)
            root.safeDismiss(popups.get(i).notif)
        popups.clear()
    }

    function dropHistoryEntry(i) {
        if (i < 0 || i >= history.count) return
        const entry = history.get(i)
        if (entry) {
            root.safeDismiss(entry.notif)
            root.removePopupById(entry.pid)
        }
        history.remove(i)
    }

    function clearHistory() {
        for (let i = history.count - 1; i >= 0; i--)
            dropHistoryEntry(i)
        root.flushPopups()
        root.closeCenter()
    }

    NotificationServer {
        id: server
        actionsSupported: true
        bodySupported: true
        imageSupported: true

        onNotification: n => {
            root.pushNotification(n)
            n.tracked = true
        }
    }

    IpcHandler {
        target: "notifications"
        function toggle(): void { root.toggleCenter() }
        function show(): void   { root.openCenter() }
        function hide(): void   { root.closeCenter() }
        function clear(): void  { root.clearHistory() }
    }

    // ====================================================================
    // TOASTS
    // ====================================================================
    PanelWindow {
        id: toastLayer
        anchors { top: true; right: true }
        margins { top: 12; right: 12 }
        exclusionMode: ExclusionMode.Ignore
        aboveWindows: true
        color: "transparent"

        visible: popups.count > 0 && !root.centerOpen

        implicitWidth: root.cardWidth
        implicitHeight: toastColumn.implicitHeight + 12

        onVisibleChanged: if (root.debug) console.log("[notify-center] toastLayer visible:", visible)

        ColumnLayout {
            id: toastColumn
            width: parent.width
            spacing: 8

            Repeater {
                model: popups

                // El delegado es un Item contenedor: así el orden de pintado
                // del halo respecto a la tarjeta es explícito y garantizado.
                delegate: Item {
                    id: toastWrap

                    required property int index
                    required property int pid
                    required property string summary
                    required property string body
                    required property string appName
                    required property string appIcon
                    required property string image
                    required property int urgency
                    required property string time
                    required property var notif

                    readonly property bool critical:
                        toastWrap.urgency === NotificationUrgency.Critical

                    readonly property color urgencyColor: {
                        if (toastWrap.critical) return Config.colors.red
                        if (toastWrap.urgency === NotificationUrgency.Low) return Config.colors.muted
                        return Config.colors.blue
                    }

                    // Los críticos brillan un poco más
                    readonly property real haloBoost: toastWrap.critical ? 1.7 : 1.0

                    Layout.fillWidth: true
                    implicitHeight: toastCard.implicitHeight + 6

                    // ---- HALO: 3 anillos, sin dependencias externas ----
                    Rectangle {
                        anchors.fill: toastCard
                        anchors.margins: -3
                        radius: 11
                        color: toastWrap.urgencyColor
                        opacity: 0.05 * toastWrap.haloBoost
                    }
                    Rectangle {
                        anchors.fill: toastCard
                        anchors.margins: -2
                        radius: 10
                        color: toastWrap.urgencyColor
                        opacity: 0.09 * toastWrap.haloBoost
                    }
                    Rectangle {
                        anchors.fill: toastCard
                        anchors.margins: -1
                        radius: 9
                        color: toastWrap.urgencyColor
                        opacity: 0.15 * toastWrap.haloBoost
                    }

                    // ---- TARJETA ----
                    Rectangle {
                        id: toastCard
                        property bool hovered: false

                        anchors {
                            left: parent.left
                            right: parent.right
                            top: parent.top
                            margins: 3
                        }
                        height: implicitHeight
                        implicitHeight: toastRow.implicitHeight + 20

                        radius: 8
                        // Fondo teñido con el color de urgencia (solo críticos)
                        color: toastWrap.critical
                            ? Qt.tint(Config.colors.bg,
                                      Qt.rgba(toastWrap.urgencyColor.r,
                                              toastWrap.urgencyColor.g,
                                              toastWrap.urgencyColor.b, 0.10))
                            : Config.colors.bg

                        border.width: 2
                        border.color: toastWrap.urgencyColor

                        Timer {
                            running: !toastWrap.critical && !toastCard.hovered
                            interval: Config.notifications.timeout
                            repeat: false
                            onTriggered: toastCard.close()
                        }

                        function close() {
                            root.dismissPopup(toastWrap.pid, toastWrap.notif)
                        }

                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.LeftButton
                            onClicked: toastCard.close()
                        }

                        HoverHandler {
                            onHoveredChanged: toastCard.hovered = hovered
                        }

                        RowLayout {
                            id: toastRow
                            anchors.fill: parent
                            anchors.margins: 10
                            spacing: 10

                            Image {
                                Layout.preferredWidth: 34
                                Layout.preferredHeight: 34
                                Layout.alignment: Qt.AlignTop
                                fillMode: Image.PreserveAspectFit
                                source: toastWrap.image || toastWrap.appIcon || ""
                                visible: source.toString().length > 0
                                asynchronous: true
                                cache: true
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                Layout.minimumWidth: 0
                                spacing: 3

                                Text {
                                    Layout.fillWidth: true
                                    text: toastWrap.summary
                                    color: Config.colors.green
                                    font.family: Config.bar.fontFamily
                                    font.pixelSize: Config.bar.fontSize + 2
                                    font.bold: true
                                    elide: Text.ElideRight
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6

                                    Text {
                                        text: toastWrap.time
                                        color: Config.colors.muted
                                        font.family: Config.bar.fontFamily
                                        font.pixelSize: Config.bar.fontSize - 2
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        text: toastWrap.appName
                                        color: Config.colors.muted
                                        font.family: Config.bar.fontFamily
                                        font.pixelSize: Config.bar.fontSize - 2
                                        elide: Text.ElideRight
                                        horizontalAlignment: Text.AlignRight
                                        visible: text.length > 0
                                    }
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: toastWrap.body
                                    color: Config.colors.fg
                                    font.family: Config.bar.fontFamily
                                    font.pixelSize: Config.bar.fontSize
                                    wrapMode: Text.WordWrap
                                    maximumLineCount: 3
                                    elide: Text.ElideRight
                                    visible: text.length > 0
                                }
                            }

                            Text {
                                id: toastClose
                                Layout.alignment: Qt.AlignTop
                                Layout.preferredWidth: 14
                                text: "✕"
                                color: Config.colors.muted
                                font.family: Config.bar.fontFamily
                                font.pixelSize: Config.bar.fontSize
                                horizontalAlignment: Text.AlignHCenter

                                MouseArea {
                                    anchors.fill: parent
                                    anchors.margins: -6
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: toastCard.close()
                                    onEntered: toastClose.color = Config.colors.red
                                    onExited: toastClose.color = Config.colors.muted
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ====================================================================
    // MODAL
    // ====================================================================
    PanelWindow {
        id: modalLayer
        anchors { top: true; bottom: true; left: true; right: true }
        visible: root.modalShown
        exclusionMode: ExclusionMode.Ignore
        aboveWindows: true
        color: "transparent"

        Rectangle {
            id: scrim
            anchors.fill: parent
            color: Qt.rgba(0.043, 0.043, 0.086, 0.72)
            opacity: root.centerOpen ? 1 : 0
            Behavior on opacity {
                NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
            }

            MouseArea {
                anchors.fill: parent
                onClicked: root.closeCenter()
            }
        }

        Rectangle {
            id: centerCard
            anchors {
                top: parent.top
                right: parent.right
                topMargin: 12
                rightMargin: 12
            }
            width: Math.min(root.cardWidth, parent.width - 24)
            height: Math.min(centerCol.implicitHeight + 26, parent.height - 24)

            radius: 12
            color: Config.colors.bg
            border.width: 1
            border.color: Config.colors.cyan

            opacity: root.centerOpen ? 1 : 0
            Behavior on opacity {
                NumberAnimation { duration: 130; easing.type: Easing.OutCubic }
            }

            MouseArea { anchors.fill: parent }

            ColumnLayout {
                id: centerCol
                anchors {
                    top: parent.top
                    left: parent.left
                    right: parent.right
                    margins: 14
                }
                spacing: 10

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Text {
                        text: "Notificaciones"
                        color: Config.colors.blue
                        font.family: Config.bar.fontFamily
                        font.pixelSize: Config.bar.fontSize + 3
                        font.bold: true
                    }

                    Rectangle {
                        visible: history.count > 0
                        Layout.preferredWidth: countLabel.implicitWidth + 12
                        Layout.preferredHeight: 16
                        radius: 8
                        color: Config.colors.bgDark

                        Text {
                            id: countLabel
                            anchors.centerIn: parent
                            text: history.count
                            color: Config.colors.fg
                            font.family: Config.bar.fontFamily
                            font.pixelSize: Config.bar.fontSize - 2
                        }
                    }

                    Item { Layout.fillWidth: true }

                    Text {
                        id: clearBtn
                        visible: history.count > 0
                        text: "limpiar"
                        color: Config.colors.red
                        font.family: Config.bar.fontFamily
                        font.pixelSize: Config.bar.fontSize - 1

                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -4
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.clearHistory()
                            onEntered: clearBtn.color = Config.colors.yellow
                            onExited: clearBtn.color = Config.colors.red
                        }
                    }

                    Text {
                        id: closeBtn
                        text: "✕"
                        color: Config.colors.muted
                        font.family: Config.bar.fontFamily
                        font.pixelSize: Config.bar.fontSize

                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -4
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.closeCenter()
                            onEntered: closeBtn.color = Config.colors.red
                            onExited: closeBtn.color = Config.colors.muted
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    color: Config.colors.bgDark
                    visible: history.count > 0
                }

                Text {
                    Layout.fillWidth: true
                    Layout.topMargin: 24
                    Layout.bottomMargin: 24
                    visible: history.count === 0
                    text: "Sin notificaciones"
                    horizontalAlignment: Text.AlignHCenter
                    color: Config.colors.muted
                    font.family: Config.bar.fontFamily
                    font.pixelSize: Config.bar.fontSize + 1
                }

                ListView {
                    id: historyList
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(contentHeight, 430)
                    visible: history.count > 0
                    model: history
                    clip: true
                    spacing: 6
                    boundsBehavior: Flickable.StopAtBounds

                    delegate: Rectangle {
                        id: entry
                        required property int index
                        required property int pid
                        required property string summary
                        required property string body
                        required property string appName
                        required property int urgency
                        required property string time

                        readonly property color accent: {
                            if (entry.urgency === NotificationUrgency.Critical) return Config.colors.red
                            if (entry.urgency === NotificationUrgency.Low) return Config.colors.muted
                            return Config.colors.blue
                        }

                        width: historyList.width
                        height: entryCol.implicitHeight + 16
                        radius: 6
                        color: Config.colors.bgDark
                        border.width: 2
                        border.color: entry.accent

                        // Barra lateral de acento (recuperada)
                        Rectangle {
                            anchors {
                                left: parent.left
                                top: parent.top
                                bottom: parent.bottom
                                topMargin: 2
                                bottomMargin: 2
                                leftMargin: 2
                            }
                            width: 3
                            radius: 1.5
                            color: entry.accent
                        }

                        // Las críticas son pegajosas: no se borran con clic
                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.LeftButton
                            enabled: entry.urgency !== NotificationUrgency.Critical
                            onClicked: root.dropHistoryEntry(entry.index)
                        }

                        ColumnLayout {
                            id: entryCol
                            anchors {
                                fill: parent
                                leftMargin: 12
                                rightMargin: 10
                                topMargin: 8
                                bottomMargin: 8
                            }
                            spacing: 4

                            RowLayout {
                                Layout.fillWidth: true

                                Text {
                                    Layout.fillWidth: true
                                    text: entry.summary
                                    color: Config.colors.fg
                                    font.family: Config.bar.fontFamily
                                    font.pixelSize: Config.bar.fontSize + 1
                                    font.bold: true
                                    elide: Text.ElideRight
                                }

                                Text {
                                    text: entry.time
                                    color: Config.colors.muted
                                    font.family: Config.bar.fontFamily
                                    font.pixelSize: Config.bar.fontSize - 3
                                }

                                Text {
                                    id: deleteIcon
                                    text: "✕"
                                    color: Config.colors.muted
                                    font.family: Config.bar.fontFamily
                                    font.pixelSize: Config.bar.fontSize
                                    visible: entry.urgency !== NotificationUrgency.Critical

                                    MouseArea {
                                        anchors.fill: parent
                                        anchors.margins: -4
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.dropHistoryEntry(entry.index)
                                        onEntered: deleteIcon.color = Config.colors.red
                                        onExited: deleteIcon.color = Config.colors.muted
                                    }
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                text: entry.body
                                color: Config.colors.fg
                                font.family: Config.bar.fontFamily
                                font.pixelSize: Config.bar.fontSize - 1
                                wrapMode: Text.WordWrap
                                maximumLineCount: 2
                                elide: Text.ElideRight
                                visible: text.length > 0
                            }

                            Text {
                                text: entry.appName
                                color: Config.colors.muted
                                font.family: Config.bar.fontFamily
                                font.pixelSize: Config.bar.fontSize - 3
                                visible: text.length > 0
                            }
                        }
                    }
                }
            }
        }

        Shortcut {
            sequence: "Escape"
            enabled: root.centerOpen
            onActivated: root.closeCenter()
        }
    }
}
