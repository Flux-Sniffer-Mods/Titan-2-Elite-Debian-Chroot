import QtQuick
import QtQuick.Window
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PC3
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

// titan_phonestatus.qml - the "Phone" panel widget for the Titan 2 Elite desktop.
//   Panel: battery percentage, Wi-Fi, mobile signal, Android notification count.
//          (The battery icon comes from Plasma's own battery widget, so it is not
//           drawn twice; this widget supplies the number.)
//   Popup (tap): Wi-Fi networks and connect/forget, mobile data, airplane mode,
//   Bluetooth, battery details and saver, brightness, volume, do-not-disturb.
// Everything is read from /tmp/titan_status and done through /tmp/titan_android_cmd,
// both handled by boot_desktop.sh on the Android side (root).
PlasmoidItem {
    id: root
    property var st: ({})
    property var scan: []
    property string pendingSsid: ""
    property int volLocal: -1        // what the user just set, until the phone confirms it
    property int brightLocal: -1
    Timer { id: settle; interval: 2500; onTriggered: { root.volLocal = -1; root.brightLocal = -1; } }
    property bool pendingSecure: true

    switchWidth: Kirigami.Units.gridUnit * 14
    switchHeight: Kirigami.Units.gridUnit * 10
    toolTipMainText: "Phone"
    toolTipSubText: "Battery " + (st.BAT || "?") + "%" + (st.CHG == "1" ? " (charging)" : "")
        + (st.WIFI ? "\nWi-Fi: " + st.WIFI + " (" + (st.RSSI || "?") + " dBm)" : "\nWi-Fi off")
        + (st.OPERATOR ? "\n" + st.OPERATOR + ", signal " + (st.CELL || "?") + "/4" : "")
        + "\n" + (st.NOTIF || 0) + " Android notifications"

    function lvlName(l) { return ["none", "weak", "ok", "good", "excellent"][Math.max(0, Math.min(4, parseInt(l || 0)))]; }
    function batteryIcon() {
        var l = Math.round(parseInt(st.BAT || 0) / 10) * 10;
        return "battery-" + String(l).padStart(3, "0") + (st.CHG == "1" ? "-charging" : "");
    }
    function on(v) { return v == "1"; }
    function cellLevel() { return Math.max(0, Math.min(4, parseInt(st.CELL || 0))); }
    // titan-android <command> [args...]: appends one tab-separated line to
    // /tmp/titan_android_cmd, read and acted on by boot_desktop.sh.
    function android() {
        var parts = ["/usr/local/bin/titan-android"];
        for (var i = 0; i < arguments.length; i++) {
            parts.push("'" + String(arguments[i]).replace(/'/g, "'\\''") + "'");
        }
        runner.connectSource(parts.join(" "));
    }

    P5Support.DataSource {
        id: runner
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => disconnectSource(source)
    }
    P5Support.DataSource {
        engine: "executable"
        connectedSources: ["cat /tmp/titan_status 2>/dev/null"]
        interval: 700
        onNewData: (source, data) => {
            var o = {};
            (data.stdout || "").split("\n").forEach(function (l) {
                var i = l.indexOf("="); if (i > 0) o[l.slice(0, i)] = l.slice(i + 1);
            });
            root.st = o;
        }
    }
    P5Support.DataSource {
        engine: "executable"
        connectedSources: ["cat /tmp/titan_wifi_scan 2>/dev/null"]
        interval: 5000
        onNewData: (source, data) => {
            var list = [];
            (data.stdout || "").split("\n").forEach(function (l) {
                var p = l.split("\t"); if (p.length >= 3 && p[1] !== "") list.push({ rssi: p[0], ssid: p[1], flags: p[2] });
            });
            root.scan = list;
        }
    }

    // ------------------------------------------------------------ panel
    compactRepresentation: MouseArea {
        id: compact
        // Icons follow the panel height, like the launcher, task and tray icons.
        property real iconPx: Math.max(Kirigami.Units.iconSizes.smallMedium, Math.round(height * 0.6))   // sized from the panel, like tray and tasks
        Layout.preferredWidth: row.implicitWidth + Kirigami.Units.smallSpacing * 2
        Layout.minimumWidth: Layout.preferredWidth
        onClicked: root.expanded = !root.expanded
        RowLayout {
            id: row
            anchors.centerIn: parent
            spacing: Kirigami.Units.smallSpacing
            // Battery is split with Plasma's own battery widget in the tray: that one draws
            // the icon, this one shows the number. Two icons looked like a duplicate, and
            // this percentage is Android's own reading (dumpsys battery) rather than what
            // Plasma can see from inside the chroot.
            PC3.Label { text: (st.BAT || "?") + "%"; font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.2 }
            Kirigami.Icon { source: on(st.WIFI_ON) ? "network-wireless-signal-" + lvlName(st.WIFI_LVL) : "network-wireless-off"; Layout.preferredWidth: compact.iconPx; Layout.preferredHeight: width }
            Kirigami.Icon { source: on(st.AIRPLANE) ? "network-flightmode-on" : "network-mobile-" + [0, 20, 60, 80, 100][cellLevel()]; color: Kirigami.Theme.textColor; isMask: true; Layout.preferredWidth: compact.iconPx; Layout.preferredHeight: width }
            Kirigami.Icon { source: "notifications"; visible: parseInt(st.NOTIF || 0) > 0; Layout.preferredWidth: compact.iconPx; Layout.preferredHeight: width }
            PC3.Label { text: st.NOTIF; visible: parseInt(st.NOTIF || 0) > 0; font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.2 }
        }
    }

    // ------------------------------------------------------------ popup
    fullRepresentation: PC3.ScrollView {
        id: popup
        // Sized in scale-aware units and capped to the screen, so it fits at any
        // UI scale / font size: never wider than the screen, never taller than the
        // space above the panel (the rest scrolls).
        Layout.preferredWidth: Math.min(Kirigami.Units.gridUnit * 24, Screen.width - Kirigami.Units.gridUnit * 2)
        QQC2.ScrollBar.horizontal.policy: QQC2.ScrollBar.AlwaysOff
        Layout.minimumWidth: Layout.preferredWidth
        Layout.maximumWidth: Layout.preferredWidth
        Layout.preferredHeight: Math.min(Kirigami.Units.gridUnit * 30, Screen.desktopAvailableHeight - Kirigami.Units.gridUnit * 5)
        Layout.maximumHeight: Layout.preferredHeight
        onVisibleChanged: if (visible) root.android("wifi_scan")
        ColumnLayout {
            width: popup.availableWidth
            spacing: Kirigami.Units.smallSpacing

            // ---- Wi-Fi
            RowLayout {
                Kirigami.Heading { text: "Wi-Fi"; level: 3; Layout.fillWidth: true }
                PC3.Switch { checked: on(st.WIFI_ON); onToggled: root.android(checked ? "wifi_on" : "wifi_off") }
                PC3.ToolButton { icon.name: "view-refresh"; onClicked: root.android("wifi_scan") }
            }
            PC3.Label { visible: on(st.WIFI_ON); text: st.WIFI ? "Connected to " + st.WIFI + " (" + (st.RSSI || "?") + " dBm)" : "Not connected"; opacity: 0.8 }
            Repeater {
                model: on(st.WIFI_ON) ? root.scan : []
                delegate: PC3.ItemDelegate {
                    required property var modelData
                    Layout.fillWidth: true
                    icon.name: "network-wireless-signal-" + lvlName(rssiLevel(modelData.rssi))
                    text: modelData.ssid + (modelData.ssid == st.WIFI ? "  (connected)" : "")
                    onClicked: {
                        if (modelData.ssid == st.WIFI) return;
                        root.pendingSsid = modelData.ssid;
                        root.pendingSecure = modelData.flags.indexOf("WPA") >= 0 || modelData.flags.indexOf("WEP") >= 0 || modelData.flags.indexOf("SAE") >= 0;
                        if (!root.pendingSecure) root.android("wifi_connect", modelData.ssid, "");
                    }
                }
            }
            RowLayout {
                visible: root.pendingSsid !== "" && root.pendingSecure
                PC3.TextField { id: pw; Layout.fillWidth: true; placeholderText: "Password for " + root.pendingSsid; echoMode: TextInput.Password; onAccepted: connectBtn.clicked() }
                PC3.Button { id: connectBtn; text: "Connect"; onClicked: { root.android("wifi_connect", root.pendingSsid, pw.text); pw.text = ""; root.pendingSsid = ""; } }
                PC3.Button { text: "Forget"; onClicked: { root.android("wifi_forget", root.pendingSsid); root.pendingSsid = ""; } }
            }

            Kirigami.Separator { Layout.fillWidth: true }
            // ---- Mobile
            RowLayout {
                Kirigami.Heading { text: "Mobile" + (st.OPERATOR ? " · " + st.OPERATOR : ""); level: 3; Layout.fillWidth: true }
                Kirigami.Icon { source: "network-mobile-" + [0, 20, 60, 80, 100][cellLevel()]; color: Kirigami.Theme.textColor; isMask: true; Layout.preferredWidth: Kirigami.Units.iconSizes.small; Layout.preferredHeight: width }
            }
            RowLayout { PC3.Label { text: "Mobile data"; Layout.fillWidth: true } PC3.Switch { checked: on(st.DATA_ON); onToggled: root.android(checked ? "data_on" : "data_off") } }
            RowLayout { PC3.Label { text: "Airplane mode"; Layout.fillWidth: true } PC3.Switch { checked: on(st.AIRPLANE); onToggled: root.android(checked ? "airplane_on" : "airplane_off") } }
            RowLayout { PC3.Label { text: "Bluetooth"; Layout.fillWidth: true } PC3.Switch { checked: on(st.BT_ON); onToggled: root.android(checked ? "bt_on" : "bt_off") } }
            RowLayout { PC3.Label { text: "Do not disturb"; Layout.fillWidth: true } PC3.Switch { checked: on(st.DND); onToggled: root.android(checked ? "dnd_on" : "dnd_off") } }

            Kirigami.Separator { Layout.fillWidth: true }
            // ---- Battery
            Kirigami.Heading { text: "Battery"; level: 3 }
            PC3.Label { text: (st.BAT || "?") + "%" + (st.CHG == "1" ? ", charging" : "") + (st.BAT_TEMP ? " · " + st.BAT_TEMP + " °C" : "") + (st.BAT_VOLT ? " · " + st.BAT_VOLT + " V" : "") + (st.BAT_HEALTH ? " · " + st.BAT_HEALTH : ""); opacity: 0.8 }
            RowLayout { PC3.Label { text: "Battery saver"; Layout.fillWidth: true } PC3.Switch { checked: on(st.SAVER); onToggled: root.android(checked ? "saver_on" : "saver_off") } }

            Kirigami.Separator { Layout.fillWidth: true }
            // ---- Display & sound
            Kirigami.Heading { text: "Display and sound"; level: 3 }
            RowLayout {
                Kirigami.Icon { source: "brightness-high"; Layout.preferredWidth: Kirigami.Units.iconSizes.small; Layout.preferredHeight: width }
                PC3.Slider { id: bright; Layout.fillWidth: true; from: 1; to: 255; stepSize: 1
                    Binding on value { value: root.brightLocal >= 0 ? root.brightLocal : parseInt(st.BRIGHT || 128); when: !bright.pressed }
                    onMoved: { root.brightLocal = Math.round(value); settle.restart(); root.android("brightness", Math.round(value)); } }
            }
            RowLayout {
                Kirigami.Icon { source: "audio-volume-high"; Layout.preferredWidth: Kirigami.Units.iconSizes.small; Layout.preferredHeight: width }
                PC3.Slider { id: vol; Layout.fillWidth: true; from: 0; to: parseInt(st.VOL_MAX || 15); stepSize: 1
                    Binding on value { value: root.volLocal >= 0 ? root.volLocal : parseInt(st.VOL || 0); when: !vol.pressed }
                    onMoved: { root.volLocal = Math.round(value); settle.restart(); root.android("volume", Math.round(value)); } }
                PC3.Label { text: (root.volLocal >= 0 ? root.volLocal : (st.VOL || "?")) + "/" + (st.VOL_MAX || 15) }
            }

            Kirigami.Separator { Layout.fillWidth: true }
            RowLayout {
                PC3.Button { text: "Lock"; icon.name: "system-lock-screen"; onClicked: root.android("lock") }
                PC3.Button { text: "Notifications"; icon.name: "notifications"; onClicked: root.android("notifications") }
                PC3.Button { text: "Android settings"; icon.name: "configure"; onClicked: root.android("settings") }
            }
        }
    }
}
