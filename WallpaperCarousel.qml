import QtQuick
import QtQuick.Controls
import QtCore
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    // -------------------------------------------------------------------------
    // WALLPAPER FOLDER — derived from the current DMS wallpaper path
    // -------------------------------------------------------------------------
    readonly property string wallpaperFolder: {
        const p = SessionData.wallpaperPath;
        if (!p || p.startsWith("#"))
            return Paths.strip(Paths.pictures);
        const lastSlash = p.lastIndexOf('/');
        return lastSlash > 0 ? p.substring(0, lastSlash) : Paths.strip(Paths.pictures);
    }

    readonly property string wallpaperFolderUrl: "file://" + wallpaperFolder

    // -------------------------------------------------------------------------
    // WALLPAPER ENGINE — Steam Workshop path discovery
    // Checks the four standard Steam install locations for WP Engine (AppID 431960).
    // The first candidate is used unless a saved path exists in pluginData.
    // -------------------------------------------------------------------------
    readonly property string weWorkshopPath: {
        const home = Paths.strip(StandardPaths.writableLocation(StandardPaths.HomeLocation));
        const candidates = [
            home + "/.local/share/Steam/steamapps/workshop/content/431960",
            home + "/.steam/steam/steamapps/workshop/content/431960",
            home + "/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/workshop/content/431960",
            home + "/snap/steam/common/.local/share/Steam/steamapps/workshop/content/431960"
        ];
        if (pluginData.weWorkshopPath) return pluginData.weWorkshopPath;
        return candidates[0];
    }

    property string activeWeScene: pluginData.activeWeScene || ""
    property bool muteWE: pluginData.muteWE || false
    property string swwwTransition: pluginData.swwwTransition || "fade"
    readonly property int swwwTransitionFps: pluginData.swwwTransitionFps || 60
    readonly property int swwwTransitionDuration: pluginData.swwwTransitionDuration || 2
    readonly property var extraFolders: pluginData.extraFolders || []

    // -------------------------------------------------------------------------
    // waits for new files to stabilise before displaying them
    // so that partially-downloaded images are not rendered as corrupted.
    // -------------------------------------------------------------------------
    property bool _initialSyncDone: false

    ListModel { id: stableModel }
    ListModel { id: weSceneModel }
    ListModel { id: weSceneFilteredModel }

    Timer {
        id: modelSyncTimer
        interval: 1500
        onTriggered: root._syncStableModel()
    }

    FolderListModel {
        id: folderModel
        folder: root.wallpaperFolderUrl
        nameFilters: ["*.jpg", "*.jpeg", "*.png", "*.webp", "*.gif",
                      "*.bmp", "*.jxl", "*.avif", "*.heif", "*.exr"]
        showDirs: false
        sortField: FolderListModel.Name

        onStatusChanged: {
            if (status === FolderListModel.Ready && !root._initialSyncDone) {
                root._syncStableModel();
                root._initialSyncDone = true;
            }
        }
        onCountChanged: {
            if (root._initialSyncDone)
                modelSyncTimer.restart();
        }
    }

    // Extra FolderListModels for each additional configured folder
    Instantiator {
        id: extraFolderModels
        model: root.extraFolders
        delegate: FolderListModel {
            required property var modelData
            folder: "file://" + modelData.path
            nameFilters: ["*.jpg", "*.jpeg", "*.png", "*.webp", "*.gif",
                          "*.bmp", "*.jxl", "*.avif", "*.heif", "*.exr"]
            showDirs: false
            sortField: FolderListModel.Name
            onCountChanged: {
                if (root._initialSyncDone)
                    modelSyncTimer.restart();
            }
        }
    }

    function _syncStableModel() {
        const savedIndex = view.currentIndex;
        const savedFile = (savedIndex >= 0 && savedIndex < stableModel.count)
            ? stableModel.get(savedIndex).fileName : "";

        stableModel.clear();

        // Primary folder
        for (let i = 0; i < folderModel.count; i++) {
            stableModel.append({
                fileName: folderModel.get(i, "fileName"),
                fileUrl: folderModel.get(i, "fileUrl").toString()
            });
        }

        // Extra configured folders
        for (let e = 0; e < extraFolderModels.count; e++) {
            const fm = extraFolderModels.objectAt(e);
            if (!fm) continue;
            for (let i = 0; i < fm.count; i++) {
                stableModel.append({
                    fileName: fm.get(i, "fileName"),
                    fileUrl: fm.get(i, "fileUrl").toString()
                });
            }
        }

        if (savedFile) {
            for (let i = 0; i < stableModel.count; i++) {
                if (stableModel.get(i).fileName === savedFile) {
                    view.currentIndex = i;
                    break;
                }
            }
        }

        carousel.tryFocus();
    }

    // -------------------------------------------------------------------------
    // SWWW — handles display of all images/GIFs when built-in wallpapers are
    // disabled. Starts swww-daemon automatically if not already running.
    // -------------------------------------------------------------------------
    Process {
        id: swwwDaemonProc
        command: ["swww-daemon"]
        onExited: (code) => {
            if (code !== 0 && code !== 1) // 1 = already running
                console.warn("WallpaperCarousel: swww-daemon exited with code", code);
        }
    }

    Process {
        id: swwwProc
        command: []
        onExited: (code) => {
            if (code !== 0)
                console.warn("WallpaperCarousel: swww exited with code", code);
        }
    }

    function _setImageWallpaper(path) {
        // Ensure daemon is up, then set image via swww
        swwwDaemonProc.running = true;
        // Small delay so daemon has time to start if it wasn't running
        swwwTimer.pendingPath = path;
        swwwTimer.pendingTransition = root.swwwTransition;
        swwwTimer.restart();
    }

    Timer {
        id: swwwTimer
        interval: 300
        property string pendingPath: ""
        property string pendingTransition: "fade"
        onTriggered: {
            const isInstant = pendingTransition === "none" || pendingTransition === "simple";
            const cmd = ["swww", "img", pendingPath,
                "--transition-type", pendingTransition,
                "--transition-fps", root.swwwTransitionFps.toString()];
            if (!isInstant)
                cmd.push("--transition-duration", root.swwwTransitionDuration.toString());
            swwwProc.command = cmd;
            swwwProc.running = true;
        }
    }

    // -------------------------------------------------------------------------
    // WALLPAPER ENGINE — kill → launch → matugen pipeline
    // -------------------------------------------------------------------------
    Process {
        id: weKillerProc
        command: ["pkill", "-f", "linux-wallpaperengine"]
        onExited: {
            if (root._wePendingSceneId !== "") {
                const sid = root._wePendingSceneId;
                root._wePendingSceneId = "";
                root._launchWeScene(sid);
            }
        }
    }

    Process {
        id: weProc
        command: []
        onExited: (code) => {
            if (code !== 0)
                console.warn("WallpaperCarousel: linux-wallpaperengine exited with code", code);
        }
    }

    // Probes each preview extension in order and calls SessionData.setWallpaper
    // with the first path that actually exists on disk.
    Process {
        id: wePreviewProbeProc
        property string sceneId: ""
        property int extIndex: 0
        property var extensions: [".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"]
        command: []

        function probe(sid) {
            sceneId = sid;
            extIndex = 0;
            _tryNextExt();
        }

        function _tryNextExt() {
            if (extIndex >= extensions.length) {
                console.warn("WallpaperCarousel: no preview image found for WE scene", sceneId);
                return;
            }
            const path = root.weWorkshopPath + "/" + sceneId + "/preview" + extensions[extIndex];
            command = ["test", "-f", path];
            running = true;
        }

        onExited: (code) => {
            if (code === 0) {
                const path = root.weWorkshopPath + "/" + sceneId + "/preview" + extensions[extIndex];
                console.info("WallpaperCarousel: WE preview →", path, "(matugen)");
                Theme.setDesiredTheme("image", path, SessionData.isLightMode,
                    SettingsData.iconTheme, SettingsData.matugenScheme, null);
            } else {
                extIndex += 1;
                _tryNextExt();
            }
        }
    }

    Timer {
        id: weMatugenTimer
        interval: 1500
        repeat: false
        property string sceneId: ""
        onTriggered: wePreviewProbeProc.probe(sceneId)
    }

    property string _wePendingSceneId: ""

    function _launchWeScene(sceneId) {
        const screen = overlay.screen;
        const monitorName = screen ? screen.name : "";
        if (!monitorName) {
            console.warn("WallpaperCarousel: cannot determine monitor name for WE scene");
            return;
        }
        const weCmd = ["linux-wallpaperengine", "--screen-root", monitorName, "--bg", sceneId];
        if (root.muteWE) weCmd.push("--silent");
        weProc.command = weCmd;
        weProc.running = true;
        weMatugenTimer.sceneId = sceneId;
        weMatugenTimer.restart();
    }

    function pickWeScene(sceneId) {
        if (!sceneId) return;
        root.activeWeScene = sceneId;
        if (pluginService && pluginService.savePluginData)
            pluginService.savePluginData(pluginId, "activeWeScene", sceneId);
        _wePendingSceneId = sceneId;
        weKillerProc.running = true;
        weConfirmTimer.restart();
    }

    Timer {
        id: weConfirmTimer
        interval: 300
        onTriggered: root.close()
    }

    // -------------------------------------------------------------------------
    // WE SCENE DISCOVERY — lazy bash scan triggered on first WE tab open
    // -------------------------------------------------------------------------
    property bool _weScanDone: false
    property string _weScanOutput: ""

    Process {
        id: sceneScanProc
        command: []

        stdout: SplitParser {
            onRead: data => { root._weScanOutput += data + "\n"; }
        }

        onExited: (code) => {
            weSceneModel.clear();
            if (code === 0 && root._weScanOutput) {
                const lines = root._weScanOutput.trim().split('\n');
                for (const line of lines) {
                    const trimmed = line.trim();
                    if (!trimmed) continue;
                    const parts = trimmed.split('|');
                    if (parts.length >= 2)
                        weSceneModel.append({ sceneId: parts[0], name: parts.slice(1).join('|') });
                }
            }
            root._weScanOutput = "";
            root._weScanDone = true;
            root._filterWeScenes(weSearchField.text);
        }
    }

    function _startWeScan() {
        _weScanDone = false;
        _weScanOutput = "";
        const p = root.weWorkshopPath;
        sceneScanProc.command = ["bash", "-c",
            `cd "${p}" 2>/dev/null && for dir in */; do
                id="\${dir%/}"
                if [[ "$id" =~ ^[0-9]+$ ]]; then
                    if command -v jq >/dev/null 2>&1 && [[ -f "$id/project.json" ]]; then
                        title=$(jq -r '.title // empty' "$id/project.json" 2>/dev/null)
                        if [[ -n "$title" ]]; then
                            echo "$id|$title"
                        else
                            echo "$id|$id"
                        fi
                    else
                        echo "$id|$id"
                    fi
                fi
            done`
        ];
        sceneScanProc.running = true;
    }

    function _filterWeScenes(query) {
        weSceneFilteredModel.clear();
        const q = (query || "").toLowerCase().trim();
        for (let i = 0; i < weSceneModel.count; i++) {
            const s = weSceneModel.get(i);
            if (!q || s.sceneId.includes(q) || (s.name && s.name.toLowerCase().includes(q)))
                weSceneFilteredModel.append({ sceneId: s.sceneId, name: s.name });
        }
    }

    // -------------------------------------------------------------------------

    function toggle() {
        if (overlay.visible) {
            close();
        } else {
            open();
        }
    }

    function open() {
        carousel.initialFocusSet = false;
        const focusedScreen = CompositorService.getFocusedScreen();
        if (focusedScreen)
            overlay.screen = focusedScreen;
        overlay.visible = true;
        carousel.tryFocus();
        view.forceActiveFocus();
        Qt.callLater(() => view.forceActiveFocus());
    }

    function close() {
        overlay.visible = false;
    }

    function cycle(direction: int): string {
        if (!overlay.visible) {
            open();
            return "opened:" + view.currentIndex;
        }

        if (direction > 0)
            view.incrementCurrentIndex();
        else
            view.decrementCurrentIndex();

        return "index:" + view.currentIndex;
    }

    // -------------------------------------------------------------------------
    // IPC — allows triggering via: dms ipc call wallpaperCarousel <command>
    // (bind these commands to your preferred keys in your compositor config)
    //
    //   toggle         — open / close the overlay
    //   open           — open the overlay (no-op if already open)
    //   close          — close the overlay (no-op if already closed)
    //   cycle-next     — if closed: open; then highlight next wallpaper
    //   cycle-previous — if closed: open; then highlight previous wallpaper
    // -------------------------------------------------------------------------
    IpcHandler {
        target: "wallpaperCarousel"

        function toggle(): string {
            root.toggle();
            return overlay.visible ? "opened" : "closed";
        }

        function open(): string {
            if (!overlay.visible)
                root.open();
            return "opened";
        }

        function close(): string {
            if (overlay.visible)
                root.close();
            return "closed";
        }

        function cycleNext(): string  { return root.cycle(+1); }
        function cyclePrevious(): string { return root.cycle(-1); }
    }

    // -------------------------------------------------------------------------
    // FULLSCREEN OVERLAY WINDOW
    // -------------------------------------------------------------------------
    PanelWindow {
        id: overlay
        visible: false
        color: "transparent"

        WlrLayershell.namespace: "dms:plugins:wallpaperCarousel"
        WlrLayershell.layer: WlrLayershell.Overlay
        WlrLayershell.exclusiveZone: -1
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

        anchors {
            top: true
            left: true
            right: true
            bottom: true
        }

        Rectangle {
            anchors.fill: parent
            color: "#CC000000"
            opacity: overlay.visible ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 150 } }
        }

        // Click background to close (only outside the content area)
        MouseArea {
            anchors.fill: parent
            enabled: overlay.visible && carousel.confirmingIndex < 0
            onClicked: root.close()
        }

        // -------------------------------------------------------------------------
        // TAB BAR
        // -------------------------------------------------------------------------
        Item {
            id: tabBar
            anchors.top: parent.top
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.topMargin: 20
            width: tabRow.width + 8
            height: 40
            z: 20

            Rectangle {
                anchors.fill: parent
                color: "#80000000"
                radius: 20
            }

            Row {
                id: tabRow
                anchors.centerIn: parent
                spacing: 4

                Repeater {
                    model: ["Images", "WE Scenes"]
                    delegate: Rectangle {
                        required property string modelData
                        required property int index

                        width: tabLabel.implicitWidth + 28
                        height: 32
                        radius: 16
                        color: carousel.activeTab === index ? "#DDFFFFFF" : "transparent"

                        Text {
                            id: tabLabel
                            anchors.centerIn: parent
                            text: modelData
                            font.pixelSize: 13
                            font.weight: Font.Medium
                            color: carousel.activeTab === index ? "#CC000000" : "#CCFFFFFF"
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                carousel.activeTab = index;
                                if (index === 1 && !root._weScanDone)
                                    root._startWeScan();
                                if (index === 0)
                                    Qt.callLater(() => view.forceActiveFocus());
                            }
                        }
                    }
                }
            }
        }

        // -------------------------------------------------------------------------
        // CAROUSEL  (tab 0 — Images)
        // -------------------------------------------------------------------------
        Item {
            id: carousel
            anchors.fill: parent
            opacity: overlay.visible ? 1 : 0
            visible: activeTab === 0
            Behavior on opacity { NumberAnimation { duration: 150 } }

            property bool initialFocusSet: false
            property int activeTab: 0

            function tryFocus() {
                if (initialFocusSet)
                    return;

                let targetIndex = 0;
                const wp = (SessionData.perMonitorWallpaper && overlay.screen)
                           ? SessionData.getMonitorWallpaper(overlay.screen.name)
                           : SessionData.wallpaperPath;
                const currentFile = (wp || "").split('/').pop();
                if (currentFile && stableModel.count > 0) {
                    for (let i = 0; i < stableModel.count; i++) {
                        if (stableModel.get(i).fileName === currentFile) {
                            targetIndex = i;
                            break;
                        }
                    }
                }

                if (view.count > targetIndex) {
                    view.currentIndex = targetIndex;
                    view.positionViewAtIndex(targetIndex, ListView.Center);
                    initialFocusSet = true;
                } else if (view.count > 0) {
                    const safeIndex = Math.min(targetIndex, view.count - 1);
                    view.currentIndex = safeIndex;
                    view.positionViewAtIndex(safeIndex, ListView.Center);
                    initialFocusSet = true;
                }
            }

            readonly property int itemWidth: 300
            readonly property int itemHeight: 420
            readonly property int borderWidth: 3
            readonly property real skewFactor: -0.35

            property int confirmingIndex: -1

            function confirmPick(idx, path) {
                confirmingIndex = idx;
                confirmTimer.start();
                if (path) {
                    // Kill any running WE scene so it doesn't overlay the new wallpaper
                    weKillerProc.command = ["pkill", "-f", "linux-wallpaperengine"];
                    weKillerProc.running = true;
                    root.activeWeScene = "";
                    // Display via swww (handles both static images and GIFs)
                    root._setImageWallpaper(path);
                    // Update DMS wallpaperPath for matugen color extraction
                    if (SessionData.perMonitorWallpaper && overlay.screen)
                        SessionData.setMonitorWallpaper(overlay.screen.name, path);
                    else
                        SessionData.setWallpaper(path);
                }
            }

            Timer {
                id: confirmTimer
                interval: 300
                onTriggered: {
                    carousel.confirmingIndex = -1;
                    root.close();
                }
            }

            ListView {
                id: view
                anchors.fill: parent

                spacing: 0
                orientation: ListView.Horizontal
                clip: false

                cacheBuffer: 5000

                highlightRangeMode: ListView.StrictlyEnforceRange
                preferredHighlightBegin: (width / 2) - (carousel.itemWidth / 2)
                preferredHighlightEnd:   (width / 2) + (carousel.itemWidth / 2)

                highlightMoveDuration: carousel.initialFocusSet ? 150 : 0

                focus: overlay.visible && carousel.activeTab === 0
                activeFocusOnTab: true

                Keys.onPressed: event => {
                    if (carousel.confirmingIndex >= 0) {
                        event.accepted = true;
                        return;
                    }
                    if (event.key === Qt.Key_Escape) {
                        root.close();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Left) {
                        decrementCurrentIndex();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Right) {
                        incrementCurrentIndex();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        if (currentItem)
                            currentItem.pickWallpaper();
                        event.accepted = true;
                    }
                }

                onCountChanged: carousel.tryFocus()

                model: stableModel

                delegate: Item {
                    id: delegateRoot
                    width: carousel.itemWidth
                    height: carousel.itemHeight
                    anchors.verticalCenter: parent.verticalCenter

                    readonly property bool isCurrent: ListView.isCurrentItem
                    readonly property int distFromCenter: Math.abs(index - view.currentIndex)

                    z: carousel.confirmingIndex === index ? 100
                       : isCurrent ? 10 : Math.max(1, 10 - distFromCenter)

                    function pickWallpaper() {
                        if (carousel.confirmingIndex >= 0) return;
                        const fullPath = root.wallpaperFolder + "/" + fileName;
                        carousel.confirmPick(index, fullPath);
                    }

                    MouseArea {
                        id: delegateMouseArea
                        x: carousel.skewFactor * carousel.itemHeight / 2
                        width: parent.width
                        height: parent.height
                        hoverEnabled: true
                        onClicked: delegateRoot.pickWallpaper()
                    }

                    Item {
                        anchors.centerIn: parent
                        width: parent.width
                        height: parent.height

                        // Non-linear falloff: center = 1.15, neighbors shrink and fade
                        // using 1/(1+d²) curve for a gentle rolloff
                        readonly property real falloff: 1.0 / (1.0 + delegateRoot.distFromCenter * delegateRoot.distFromCenter)
                        readonly property bool isConfirmed: carousel.confirmingIndex === index
                        readonly property bool isOtherConfirming: carousel.confirmingIndex >= 0 && !isConfirmed
                        readonly property bool isHovered: delegateMouseArea.containsMouse && carousel.confirmingIndex < 0

                        scale: isConfirmed ? 1.6
                             : isOtherConfirming ? (0.75 + 0.40 * falloff) * 0.8
                             : isHovered ? 0.75 + 0.60 * falloff
                             : 0.75 + 0.40 * falloff
                        opacity: isConfirmed ? 0.0
                               : isOtherConfirming ? 0.0
                               : isHovered ? 1.0
                               : 0.25 + 0.75 * falloff
                        layer.enabled: opacity < 1

                        Behavior on scale   { NumberAnimation { duration: 300; easing.type: Easing.OutBack } }
                        Behavior on opacity { NumberAnimation { duration: 300 } }

                        transform: Matrix4x4 {
                            property real s: carousel.skewFactor
                            matrix: Qt.matrix4x4(1, s, 0, 0,
                                                 0, 1, 0, 0,
                                                 0, 0, 1, 0,
                                                 0, 0, 0, 1)
                        }

                        // Outer skewed border image
                        Image {
                            anchors.fill: parent
                            source: fileUrl
                            sourceSize: Qt.size(carousel.itemWidth, carousel.itemHeight)
                            fillMode: Image.Stretch
                            asynchronous: true
                            visible: innerImage.status === Image.Ready
                        }

                        Item {
                            anchors.fill: parent
                            anchors.margins: carousel.borderWidth
                            visible: innerImage.status === Image.Ready

                            Rectangle { anchors.fill: parent; color: "black" }
                            clip: true

                            Image {
                                id: innerImage
                                anchors.centerIn: parent
                                anchors.horizontalCenterOffset: -50

                                width: parent.width + (parent.height * Math.abs(carousel.skewFactor)) + 50
                                height: parent.height

                                fillMode: Image.PreserveAspectCrop
                                source: fileUrl
                                sourceSize: Qt.size(carousel.itemWidth, carousel.itemHeight)
                                asynchronous: true

                                transform: Matrix4x4 {
                                    property real s: -carousel.skewFactor
                                    matrix: Qt.matrix4x4(1, s, 0, 0,
                                                         0, 1, 0, 0,
                                                         0, 0, 1, 0,
                                                         0, 0, 0, 1)
                                }
                            }
                        }
                    }
                }
            }
        }

        // -------------------------------------------------------------------------
        // WE SCENES  (tab 1 — Wallpaper Engine)
        // -------------------------------------------------------------------------
        Item {
            id: weTab
            anchors.fill: parent
            anchors.topMargin: tabBar.height + tabBar.anchors.topMargin + 12
            visible: carousel.activeTab === 1
            opacity: overlay.visible ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 150 } }

            // Swallow clicks so they don't reach the close MouseArea below
            MouseArea { anchors.fill: parent; onClicked: {} }

            Column {
                anchors.fill: parent
                anchors.margins: 20
                spacing: 12

                // Search bar
                Rectangle {
                    width: parent.width
                    height: 40
                    color: "#40FFFFFF"
                    radius: 20

                    TextInput {
                        id: weSearchField
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.margins: 16
                        color: "white"
                        font.pixelSize: 14
                        selectionColor: "#6600AAFF"
                        clip: true

                        Text {
                            anchors.fill: parent
                            text: "Search scenes…"
                            color: "#80FFFFFF"
                            font.pixelSize: 14
                            visible: weSearchField.text.length === 0 && !weSearchField.activeFocus
                        }

                        Keys.onEscapePressed: root.close()
                        onTextChanged: root._filterWeScenes(text)
                    }
                }

                // Scene count + Refresh row
                Row {
                    width: parent.width
                    spacing: 8

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: weSceneFilteredModel.count + " scene" + (weSceneFilteredModel.count !== 1 ? "s" : "")
                        color: "#BBBBBB"
                        font.pixelSize: 12
                    }

                    Item { width: parent.width - parent.children[0].width - parent.children[2].width - parent.children[3].width - 24; height: 1 }

                    Rectangle {
                        width: muteLabel.implicitWidth + 20
                        height: 28
                        radius: 14
                        color: root.muteWE ? "#80FFFFFF" : (muteMa.containsMouse ? "#50FFFFFF" : "#30FFFFFF")

                        Text {
                            id: muteLabel
                            anchors.centerIn: parent
                            text: root.muteWE ? "🔇 Muted" : "🔊 Audio"
                            color: "white"
                            font.pixelSize: 12
                        }

                        MouseArea {
                            id: muteMa
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: {
                                root.muteWE = !root.muteWE;
                                if (pluginService && pluginService.savePluginData)
                                    pluginService.savePluginData(pluginId, "muteWE", root.muteWE);
                                // Restart current scene with new audio setting if one is active
                                if (root.activeWeScene)
                                    root.pickWeScene(root.activeWeScene);
                            }
                        }
                    }

                    Rectangle {
                        width: refreshLabel.implicitWidth + 20
                        height: 28
                        radius: 14
                        color: refreshMa.containsMouse ? "#60FFFFFF" : "#30FFFFFF"

                        Text {
                            id: refreshLabel
                            anchors.centerIn: parent
                            text: root._weScanDone ? "Refresh" : "Scanning…"
                            color: "white"
                            font.pixelSize: 12
                        }

                        MouseArea {
                            id: refreshMa
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: {
                                weSearchField.text = "";
                                root._startWeScan();
                            }
                        }
                    }
                }

                // Scene grid
                Rectangle {
                    width: parent.width
                    height: parent.height - parent.spacing * 2 - 40 - 28
                    color: "transparent"
                    clip: true

                    GridView {
                        id: weGrid
                        anchors.fill: parent
                        clip: true
                        model: weSceneFilteredModel

                        readonly property int columns: Math.max(2, Math.floor(width / 200))
                        cellWidth: Math.floor(width / columns)
                        cellHeight: cellWidth + 48

                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                        Keys.onEscapePressed: root.close()

                        delegate: Item {
                            id: weCard
                            required property var modelData
                            required property int index

                            width: weGrid.cellWidth
                            height: weGrid.cellHeight

                            readonly property string sceneId: modelData.sceneId || ""
                            readonly property string sceneName: modelData.name || modelData.sceneId || ""
                            readonly property bool isActive: root.activeWeScene === sceneId

                            Rectangle {
                                id: cardBg
                                anchors.centerIn: parent
                                width: parent.width - 12
                                height: parent.height - 12
                                radius: 8
                                color: cardMa.containsMouse ? "#50FFFFFF" : "#28FFFFFF"
                                border.width: weCard.isActive ? 2 : 0
                                border.color: "#AAFFFFFF"

                                Column {
                                    anchors.fill: parent
                                    anchors.margins: 6
                                    spacing: 4

                                    Item {
                                        width: parent.width
                                        height: parent.width
                                        clip: true

                                        Rectangle {
                                            anchors.fill: parent
                                            color: "#20FFFFFF"
                                            radius: 4
                                        }

                                        AnimatedImage {
                                            id: previewImg
                                            anchors.fill: parent
                                            fillMode: Image.PreserveAspectCrop
                                            asynchronous: true
                                            cache: true

                                            property var exts: [".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"]
                                            property int extIdx: 0

                                            function tryLoad() {
                                                if (extIdx >= exts.length) { source = ""; return; }
                                                source = "file://" + root.weWorkshopPath + "/" + weCard.sceneId
                                                         + "/preview" + exts[extIdx];
                                            }

                                            Component.onCompleted: tryLoad()

                                            onStatusChanged: {
                                                if (status === Image.Error) {
                                                    extIdx += 1;
                                                    tryLoad();
                                                } else if (status === Image.Ready) {
                                                    playing = source.toString().toLowerCase().endsWith(".gif");
                                                }
                                            }
                                        }

                                        Text {
                                            anchors.centerIn: parent
                                            text: "No Preview"
                                            color: "#80FFFFFF"
                                            font.pixelSize: 11
                                            visible: previewImg.status !== Image.Ready &&
                                                     previewImg.status !== Image.Loading
                                        }
                                    }

                                    Text {
                                        width: parent.width
                                        text: weCard.sceneName
                                        color: "white"
                                        font.pixelSize: 11
                                        font.weight: Font.Medium
                                        elide: Text.ElideRight
                                        wrapMode: Text.NoWrap
                                    }

                                    Text {
                                        width: parent.width
                                        text: "ID: " + weCard.sceneId
                                        color: "#80FFFFFF"
                                        font.pixelSize: 10
                                        elide: Text.ElideRight
                                        wrapMode: Text.NoWrap
                                    }
                                }

                                MouseArea {
                                    id: cardMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: root.pickWeScene(weCard.sceneId)
                                }
                            }
                        }
                    }

                    // Empty/loading state
                    Column {
                        anchors.centerIn: parent
                        spacing: 10
                        visible: weSceneFilteredModel.count === 0

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: root._weScanDone
                                  ? (weSearchField.text ? "No scenes match your search" : "No scenes found")
                                  : "Scanning…"
                            color: "white"
                            font.pixelSize: 18
                            font.bold: true
                        }

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: root._weScanDone && !weSearchField.text
                                  ? "Make sure Steam is installed and Wallpaper Engine (431960) is in your library.\nPath: " + root.weWorkshopPath
                                  : ""
                            color: "#BBBBBB"
                            font.pixelSize: 12
                            horizontalAlignment: Text.AlignHCenter
                            lineHeight: 1.4
                            visible: text.length > 0
                        }
                    }
                }
            }
        }

        // Empty state message (Images tab)
        Column {
            anchors.centerIn: parent
            spacing: 12
            visible: overlay.visible && carousel.activeTab === 0 &&
                     folderModel.status === FolderListModel.Ready && folderModel.count === 0

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: {
                    const p = SessionData.wallpaperPath;
                    return (!p || p.startsWith("#"))
                        ? "No wallpaper configured"
                        : "No images found in wallpaper folder";
                }
                font.pixelSize: 24
                font.bold: true
                color: "white"
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: {
                    const p = SessionData.wallpaperPath;
                    return (!p || p.startsWith("#"))
                        ? "Open DankMaterialShell Settings → Wallpaper,\nenable DMS wallpaper management and select a wallpaper."
                        : "The folder '" + root.wallpaperFolder + "' is empty.\nAdd images or choose a different wallpaper in DMS Settings.";
                }
                font.pixelSize: 14
                color: "#BBBBBB"
                horizontalAlignment: Text.AlignHCenter
                lineHeight: 1.4
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Press Escape to close"
                font.pixelSize: 12
                color: "#888888"
            }
        }
    }

    // -------------------------------------------------------------------------
    // PRE-CACHE — force Qt to decode wallpaper thumbnails at boot by rendering
    // them inside a real 1×1 PanelWindow on the Background layer.
    // -------------------------------------------------------------------------
    PanelWindow {
        id: cacheWindow
        visible: true
        color: "transparent"
        width: 1
        height: 1

        WlrLayershell.namespace: "dms:plugins:wallpaperCarousel:precache"
        WlrLayershell.layer: WlrLayershell.Background
        WlrLayershell.exclusiveZone: 0

        anchors { top: true; left: true }

        Item {
            width: 1; height: 1
            clip: true

            Repeater {
                model: stableModel
                Image {
                    width: carousel.itemWidth
                    height: carousel.itemHeight
                    asynchronous: true
                    source: fileUrl
                    sourceSize: Qt.size(carousel.itemWidth, carousel.itemHeight)
                    fillMode: Image.PreserveAspectCrop
                }
            }
        }
    }

    Component.onDestruction: {
        // Clean up any running linux-wallpaperengine process on exit
        Quickshell.execDetached(["pkill", "-f", "linux-wallpaperengine"])
    }

    Component.onCompleted: {
        console.info("WallpaperCarousel: daemon loaded — use 'dms ipc call wallpaperCarousel toggle' to open");
    }
}
