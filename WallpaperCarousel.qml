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

    readonly property string _overrideDir: (pluginData && pluginData.wallpaperDirectory) || ""
    readonly property string _carouselMode: (pluginData && pluginData.carouselMode) || "wrap"
    readonly property bool _isInfinite: _carouselMode === "infinite"
    readonly property bool _wrapsIndex: _carouselMode !== "standard"
    on_CarouselModeChanged: if (_initialSyncDone) Qt.callLater(_syncStableModel)

    // Unified access to whichever view is active
    readonly property var _currentView: _isInfinite ? pathView : listView

    readonly property string wallpaperFolder: {
        if (_overrideDir)
            return _overrideDir;
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
    ListModel { id: weCarouselModel }
    // Combined "All" tab model: entries have { kind: "image"|"we", fileName, fileUrl, sceneId, name }
    ListModel { id: allModel }

    property bool _weInitialFocusSet: false
    readonly property int _weBaseSceneCount: weSceneFilteredModel.count

    // "all" tab filter: 0 = All, 1 = Images, 2 = WE
    property int allFilter: 0
    property bool _allInitialFocusSet: false
    property int _allBaseCount: 0

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
        const activeView = root._currentView;
        const savedIndex = activeView.currentIndex;
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

        // When looping, duplicate entries so PathView has enough items
        // to fill the entire viewport and look truly infinite.
        if (root._isInfinite && folderModel.count > 0) {
            const viewWidth = pathView.width > 0 ? pathView.width : 2560;
            const minCount = Math.ceil(viewWidth / carousel.itemWidth) + 6;
            const baseCount = folderModel.count;
            const targetCount = baseCount * Math.ceil(minCount / baseCount);
            while (stableModel.count < targetCount) {
                for (let i = 0; i < baseCount && stableModel.count < targetCount; i++) {
                    stableModel.append({
                        fileName: folderModel.get(i, "fileName"),
                        fileUrl: folderModel.get(i, "fileUrl").toString()
                    });
                }
            }
        }

        if (savedFile) {
            for (let i = 0; i < stableModel.count; i++) {
                if (stableModel.get(i).fileName === savedFile) {
                    activeView.currentIndex = i;
                    break;
                }
            }
        }

        carousel.tryFocus();
        Qt.callLater(_syncAllModel);
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
        _syncWeCarouselModel();
        Qt.callLater(_syncAllModel);
    }

    function _syncWeCarouselModel() {
        const v = root._isInfinite ? weCarouselPathView : weCarouselListView;
        const savedIndex = v.currentIndex;
        const savedId = (savedIndex >= 0 && savedIndex < weCarouselModel.count)
            ? weCarouselModel.get(savedIndex).sceneId : "";

        weCarouselModel.clear();
        for (let i = 0; i < weSceneFilteredModel.count; i++) {
            const s = weSceneFilteredModel.get(i);
            weCarouselModel.append({ sceneId: s.sceneId, name: s.name });
        }

        // Duplicate entries for infinite scroll so PathView fills the viewport
        if (root._isInfinite && weSceneFilteredModel.count > 0) {
            const viewWidth = weCarouselPathView.width > 0 ? weCarouselPathView.width : 2560;
            const minCount = Math.ceil(viewWidth / carousel.itemWidth) + 6;
            const baseCount = weSceneFilteredModel.count;
            const targetCount = baseCount * Math.ceil(minCount / baseCount);
            while (weCarouselModel.count < targetCount) {
                for (let i = 0; i < baseCount && weCarouselModel.count < targetCount; i++) {
                    const s = weSceneFilteredModel.get(i);
                    weCarouselModel.append({ sceneId: s.sceneId, name: s.name });
                }
            }
        }

        // Restore position or jump to active scene
        root._weInitialFocusSet = false;
        _tryFocusWeCarousel();
    }

    function _tryFocusWeCarousel() {
        if (root._weInitialFocusSet) return;
        let targetIndex = 0;
        if (root.activeWeScene && weCarouselModel.count > 0) {
            for (let i = 0; i < weCarouselModel.count; i++) {
                if (weCarouselModel.get(i).sceneId === root.activeWeScene) {
                    targetIndex = i;
                    break;
                }
            }
        }
        const v = root._isInfinite ? weCarouselPathView : weCarouselListView;
        if (v.count > targetIndex) {
            v.currentIndex = targetIndex;
            if (!root._isInfinite)
                v.positionViewAtIndex(targetIndex, ListView.Center);
            root._weInitialFocusSet = true;
        } else if (v.count > 0) {
            v.currentIndex = 0;
            root._weInitialFocusSet = true;
        }
    }

    // -------------------------------------------------------------------------

    function _syncAllModel() {
        allModel.clear();
        const f = root.allFilter;
        const baseEntries = [];
        if (f === 0 || f === 1) {
            for (let i = 0; i < stableModel.count; i++) {
                const e = stableModel.get(i);
                baseEntries.push({ kind: "image", fileName: e.fileName, fileUrl: e.fileUrl, sceneId: "", name: "" });
            }
        }
        if (f === 0 || f === 2) {
            for (let i = 0; i < weSceneFilteredModel.count; i++) {
                const s = weSceneFilteredModel.get(i);
                baseEntries.push({ kind: "we", fileName: "", fileUrl: "", sceneId: s.sceneId, name: s.name });
            }
        }
        root._allBaseCount = baseEntries.length;
        for (const entry of baseEntries)
            allModel.append(entry);

        // Duplicate entries for infinite scroll
        if (root._isInfinite && baseEntries.length > 0) {
            const viewWidth = (typeof allPathView !== "undefined" && allPathView.width > 0)
                ? allPathView.width : 2560;
            const minCount = Math.ceil(viewWidth / carousel.itemWidth) + 6;
            const baseCount = baseEntries.length;
            const targetCount = baseCount * Math.ceil(minCount / baseCount);
            while (allModel.count < targetCount) {
                for (let i = 0; i < baseCount && allModel.count < targetCount; i++)
                    allModel.append(baseEntries[i]);
            }
        }

        root._allInitialFocusSet = false;
        _tryFocusAllCarousel();
    }

    function _tryFocusAllCarousel() {
        if (root._allInitialFocusSet) return;
        const v = root._isInfinite ? allPathView : allListView;
        if (v.count > 0) {
            v.currentIndex = 0;
            if (!root._isInfinite)
                v.positionViewAtIndex(0, ListView.Center);
            root._allInitialFocusSet = true;
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
        root._weInitialFocusSet = false;
        root._allInitialFocusSet = false;
        const focusedScreen = CompositorService.getFocusedScreen();
        if (focusedScreen)
            overlay.screen = focusedScreen;
        overlay.visible = true;
        if (carousel.activeTab === 1) {
            carousel.tryFocus();
            root._currentView.forceActiveFocus();
            Qt.callLater(() => root._currentView.forceActiveFocus());
        } else if (carousel.activeTab === 2) {
            root._tryFocusWeCarousel();
            const wv = root._isInfinite ? weCarouselPathView : weCarouselListView;
            Qt.callLater(() => wv.forceActiveFocus());
        } else {
            root._tryFocusAllCarousel();
            const av = root._isInfinite ? allPathView : allListView;
            Qt.callLater(() => av.forceActiveFocus());
        }
    }

    function close() {
        overlay.visible = false;
    }

    function cycle(direction: int): string {
        const v = root._currentView;
        if (!overlay.visible) {
            open();
            return "opened:" + v.currentIndex;
        }

        if (direction > 0)
            v.incrementCurrentIndex();
        else
            v.decrementCurrentIndex();

        return "index:" + v.currentIndex;
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
                    model: ["All", "Images", "WE Scenes"]
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
                            onClicked: carousel.switchToTab(index)
                        }
                    }
                }
            }
        }

        // -------------------------------------------------------------------------
        // CAROUSEL  (tab 1 — Images)
        // -------------------------------------------------------------------------
        Item {
            id: carousel
            anchors.fill: parent
            opacity: overlay.visible ? 1 : 0
            visible: activeTab === 1
            Behavior on opacity { NumberAnimation { duration: 150 } }

            property bool initialFocusSet: false
            property int activeTab: 0

            function switchToTab(idx) {
                activeTab = idx;
                if (idx === 2) {
                    if (!root._weScanDone) root._startWeScan();
                    const wv = root._isInfinite ? weCarouselPathView : weCarouselListView;
                    Qt.callLater(() => wv.forceActiveFocus());
                } else if (idx === 1) {
                    Qt.callLater(() => root._currentView.forceActiveFocus());
                } else {
                    const av = root._isInfinite ? allPathView : allListView;
                    Qt.callLater(() => av.forceActiveFocus());
                }
            }

            function cycleTab(dir) {
                switchToTab((activeTab + 3 + dir) % 3);
            }

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

                const v = root._currentView;
                if (v.count > targetIndex) {
                    v.currentIndex = targetIndex;
                    if (!root._isInfinite)
                        v.positionViewAtIndex(targetIndex, ListView.Center);
                    initialFocusSet = true;
                } else if (v.count > 0) {
                    const safeIndex = Math.min(targetIndex, v.count - 1);
                    v.currentIndex = safeIndex;
                    if (!root._isInfinite)
                        v.positionViewAtIndex(safeIndex, ListView.Center);
                    initialFocusSet = true;
                }
            }

            readonly property int itemWidth: 300
            readonly property int itemHeight: 420
            readonly property int borderWidth: 3
            readonly property real skewFactor: -0.35
            readonly property int _baseWallpaperCount: folderModel.count

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

            // -----------------------------------------------------------------
            // Shared delegate component used by both views
            // -----------------------------------------------------------------
            Component {
                id: carouselDelegate

                Item {
                    id: delegateRoot
                    width: carousel.itemWidth
                    height: carousel.itemHeight

                    // In a horizontal ListView the delegate is not
                    // vertically centered by default; anchor it.
                    // PathView overrides x/y via the path so the
                    // anchor is harmlessly ignored in that mode.
                    anchors.verticalCenter: parent ? parent.verticalCenter : undefined

                    required property int index
                    required property string fileName
                    required property string fileUrl

                    readonly property bool isCurrent: root._isInfinite
                        ? PathView.isCurrentItem
                        : ListView.isCurrentItem

                    // Wrap-aware distance from the highlighted item.
                    readonly property int distFromCenter: {
                        if (root._isInfinite) {
                            const n = stableModel.count;
                            if (n <= 1) return 0;
                            const d = Math.abs(index - pathView.currentIndex);
                            return Math.min(d, n - d);
                        }
                        return Math.abs(index - listView.currentIndex);
                    }

                    // 1/(1+sq(d)) falloff — identical curve for both views
                    readonly property real falloff: 1.0 / (1.0 + distFromCenter * distFromCenter)

                    // When looping with duplicated entries, only show
                    // Y unique tiles: floor(Y/2) to the left of the
                    // current wallpaper and floor((Y-1)/2) to the right.
                    // For each visible slot, compute the exact model index
                    // that should occupy it (direction-aware).
                    readonly property real _dupeFade: {
                        if (!root._isInfinite) return 1.0;
                        const base = carousel._baseWallpaperCount;
                        if (base <= 0 || base >= stableModel.count) return 1.0;
                        const n = stableModel.count;
                        const cur = pathView.currentIndex;
                        const wpOffset = ((index % base) - (cur % base) + base) % base;
                        const leftCount  = Math.floor(base / 2);
                        const rightCount = Math.floor((base - 1) / 2);

                        let target;
                        if (wpOffset === 0)
                            target = cur;
                        else if (wpOffset <= rightCount)
                            target = (cur + wpOffset) % n;
                        else if (base - wpOffset <= leftCount)
                            target = (cur - (base - wpOffset) + n) % n;
                        else
                            return 0.0;
                        return index === target ? 1.0 : 0.0;
                    }

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

                        readonly property bool isConfirmed: carousel.confirmingIndex === delegateRoot.index
                        readonly property bool isOtherConfirming: carousel.confirmingIndex >= 0 && !isConfirmed
                        readonly property bool isHovered: delegateMouseArea.containsMouse && carousel.confirmingIndex < 0

                        scale: isConfirmed ? 1.6
                             : isOtherConfirming ? (0.75 + 0.40 * delegateRoot.falloff) * 0.8
                             : isHovered ? 0.75 + 0.60 * delegateRoot.falloff
                             : 0.75 + 0.40 * delegateRoot.falloff
                        opacity: (isConfirmed ? 0.0
                               : isOtherConfirming ? 0.0
                               : isHovered ? 1.0
                               : 0.1 + 0.9 * delegateRoot.falloff) * delegateRoot._dupeFade
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
                            source: delegateRoot.fileUrl
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
                                source: delegateRoot.fileUrl
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

            // -----------------------------------------------------------------
            // PathView — looping
            // -----------------------------------------------------------------
            PathView {
                id: pathView
                anchors.fill: parent
                visible: root._isInfinite

                model: root._isInfinite ? stableModel : null
                delegate: carouselDelegate

                pathItemCount: Math.max(1, Math.min(stableModel.count,
                    Math.ceil(width / carousel.itemWidth) + 4))
                cacheItemCount: 4

                preferredHighlightBegin: 0.5
                preferredHighlightEnd: 0.5
                highlightRangeMode: PathView.StrictlyEnforceRange

                highlightMoveDuration: carousel.initialFocusSet ? 150 : 0
                movementDirection: PathView.Shortest

                focus: root._isInfinite && overlay.visible && carousel.activeTab === 1

                Keys.onPressed: event => {
                    if (carousel.confirmingIndex >= 0) {
                        event.accepted = true;
                        return;
                    }
                    if (event.key === Qt.Key_Escape) {
                        root.close();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Tab) {
                        carousel.cycleTab(+1); event.accepted = true;
                    } else if (event.key === Qt.Key_Backtab) {
                        carousel.cycleTab(-1); event.accepted = true;
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

                // Horizontal line through the vertical centre of the view.
                // Length = pathItemCount * itemWidth so items are always
                // spaced exactly one itemWidth apart regardless of how
                // many are on screen.
                readonly property real _pathLen: pathItemCount * carousel.itemWidth
                readonly property real _pathX0: (width - _pathLen) / 2
                path: Path {
                    startX: pathView._pathX0
                    startY: pathView.height / 2 - carousel.itemHeight / 2
                    PathLine {
                        x: pathView._pathX0 + pathView._pathLen
                        y: pathView.height / 2 - carousel.itemHeight / 2
                    }
                }
            }

            // -----------------------------------------------------------------
            // ListView — index is looping, but not visuals
            // -----------------------------------------------------------------
            ListView {
                id: listView
                anchors.fill: parent
                visible: !root._isInfinite

                model: root._isInfinite ? null : stableModel
                delegate: carouselDelegate

                spacing: 0
                orientation: ListView.Horizontal
                clip: false
                cacheBuffer: 5000

                highlightRangeMode: ListView.StrictlyEnforceRange
                preferredHighlightBegin: (width / 2) - (carousel.itemWidth / 2)
                preferredHighlightEnd:   (width / 2) + (carousel.itemWidth / 2)

                highlightMoveDuration: carousel.initialFocusSet ? 150 : 0

                focus: !root._isInfinite && overlay.visible && carousel.activeTab === 1

                Keys.onPressed: event => {
                    if (carousel.confirmingIndex >= 0) {
                        event.accepted = true;
                        return;
                    }
                    if (event.key === Qt.Key_Escape) {
                        root.close();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Tab) {
                        carousel.cycleTab(+1); event.accepted = true;
                    } else if (event.key === Qt.Key_Backtab) {
                        carousel.cycleTab(-1); event.accepted = true;
                    } else if (event.key === Qt.Key_Left) {
                        if (currentIndex > 0)
                            decrementCurrentIndex();
                        else if (root._wrapsIndex)
                            currentIndex = count - 1;
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Right) {
                        if (currentIndex < count - 1)
                            incrementCurrentIndex();
                        else if (root._wrapsIndex)
                            currentIndex = 0;
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Home) {
                        currentIndex = 0;
                        event.accepted = true;
                    } else if (event.key === Qt.Key_End) {
                        currentIndex = count - 1;
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        if (currentItem)
                            currentItem.pickWallpaper();
                        event.accepted = true;
                    }
                }

                onCountChanged: carousel.tryFocus()
            }
        }

        // Invalid directory message (override set but folder model never loads)
        Column {
            anchors.centerIn: parent
            spacing: 12
            visible: overlay.visible && root._overrideDir && folderModel.status !== FolderListModel.Ready

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Directory not found"
                font.pixelSize: 24
                font.bold: true
                color: "white"
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "The configured directory '" + root._overrideDir + "' does not exist.\nCheck the path in Wallpaper Carousel settings."
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

        // -------------------------------------------------------------------------
        // WE SCENES  (tab 2 — Wallpaper Engine)
        // -------------------------------------------------------------------------
        Item {
            id: weTab
            anchors.fill: parent
            visible: carousel.activeTab === 2
            opacity: overlay.visible ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 150 } }

            // Swallow clicks so they don't reach the close MouseArea below
            MouseArea { anchors.fill: parent; onClicked: {} }

            property bool showPreview: true

            // -----------------------------------------------------------------
            // Toolbar: search + counts + mute + refresh
            // -----------------------------------------------------------------
            Item {
                id: weToolbar
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.topMargin: tabBar.height + tabBar.anchors.topMargin + 12
                anchors.leftMargin: 20
                anchors.rightMargin: 20
                height: 40

                Rectangle {
                    id: weSearchBox
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(400, parent.width * 0.4)
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
                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Left || event.key === Qt.Key_Right ||
                                event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                const wv = root._isInfinite ? weCarouselPathView : weCarouselListView;
                                wv.forceActiveFocus();
                                event.accepted = true;
                            }
                        }
                        onTextChanged: root._filterWeScenes(text)
                    }
                }

                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: weSceneFilteredModel.count + " scene" + (weSceneFilteredModel.count !== 1 ? "s" : "")
                        color: "#BBBBBB"
                        font.pixelSize: 12
                    }

                    Rectangle {
                        width: previewToggleLabel.implicitWidth + 20
                        height: 28
                        radius: 14
                        color: weTab.showPreview ? "#80FFFFFF" : (previewToggleMa.containsMouse ? "#50FFFFFF" : "#30FFFFFF")

                        Text {
                            id: previewToggleLabel
                            anchors.centerIn: parent
                            text: weTab.showPreview ? "👁 Preview" : "👁 Hidden"
                            color: "white"
                            font.pixelSize: 12
                        }

                        MouseArea {
                            id: previewToggleMa
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: weTab.showPreview = !weTab.showPreview
                        }
                    }

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
            }

            // -----------------------------------------------------------------
            // WE Carousel — PathView (infinite) / ListView (standard + wrap)
            // -----------------------------------------------------------------
            readonly property int weItemWidth: carousel.itemWidth
            readonly property int weItemHeight: carousel.itemHeight
            readonly property real weSkewFactor: carousel.skewFactor
            readonly property int weBorderWidth: carousel.borderWidth

            property int weConfirmingIndex: -1

            function weConfirmPick(idx, sceneId) {
                weConfirmingIndex = idx;
                wePickTimer.start();
                root.pickWeScene(sceneId);
            }

            Timer {
                id: wePickTimer
                interval: 300
                onTriggered: weTab.weConfirmingIndex = -1
            }

            // Shared delegate for both WE views
            Component {
                id: weCarouselDelegate

                Item {
                    id: weDelegateRoot
                    width: weTab.weItemWidth
                    height: weTab.weItemHeight
                    anchors.verticalCenter: parent ? parent.verticalCenter : undefined

                    required property int index
                    required property string sceneId
                    required property string name

                    readonly property bool isCurrent: root._isInfinite
                        ? PathView.isCurrentItem
                        : ListView.isCurrentItem

                    readonly property int distFromCenter: {
                        if (root._isInfinite) {
                            const n = weCarouselModel.count;
                            if (n <= 1) return 0;
                            const d = Math.abs(index - weCarouselPathView.currentIndex);
                            return Math.min(d, n - d);
                        }
                        return Math.abs(index - weCarouselListView.currentIndex);
                    }

                    readonly property real falloff: 1.0 / (1.0 + distFromCenter * distFromCenter)

                    readonly property real _dupeFade: {
                        if (!root._isInfinite) return 1.0;
                        const base = root._weBaseSceneCount;
                        if (base <= 0 || base >= weCarouselModel.count) return 1.0;
                        const n = weCarouselModel.count;
                        const cur = weCarouselPathView.currentIndex;
                        const wpOffset = ((index % base) - (cur % base) + base) % base;
                        const leftCount  = Math.floor(base / 2);
                        const rightCount = Math.floor((base - 1) / 2);
                        let target;
                        if (wpOffset === 0)
                            target = cur;
                        else if (wpOffset <= rightCount)
                            target = (cur + wpOffset) % n;
                        else if (base - wpOffset <= leftCount)
                            target = (cur - (base - wpOffset) + n) % n;
                        else
                            return 0.0;
                        return index === target ? 1.0 : 0.0;
                    }

                    z: weTab.weConfirmingIndex === index ? 100
                       : isCurrent ? 10 : Math.max(1, 10 - distFromCenter)

                    function pickScene() {
                        if (weTab.weConfirmingIndex >= 0) return;
                        weTab.weConfirmPick(index, sceneId);
                    }

                    MouseArea {
                        id: weDelegateMa
                        x: weTab.weSkewFactor * weTab.weItemHeight / 2
                        width: parent.width
                        height: parent.height
                        hoverEnabled: true
                        onClicked: weDelegateRoot.pickScene()
                    }

                    Item {
                        anchors.centerIn: parent
                        width: parent.width
                        height: parent.height

                        readonly property bool isConfirmed: weTab.weConfirmingIndex === weDelegateRoot.index
                        readonly property bool isOtherConfirming: weTab.weConfirmingIndex >= 0 && !isConfirmed
                        readonly property bool isHovered: weDelegateMa.containsMouse && weTab.weConfirmingIndex < 0

                        scale: isConfirmed ? 1.6
                             : isOtherConfirming ? (0.75 + 0.40 * weDelegateRoot.falloff) * 0.8
                             : isHovered ? 0.75 + 0.60 * weDelegateRoot.falloff
                             : 0.75 + 0.40 * weDelegateRoot.falloff
                        opacity: (isConfirmed ? 0.0
                               : isOtherConfirming ? 0.0
                               : isHovered ? 1.0
                               : 0.1 + 0.9 * weDelegateRoot.falloff) * weDelegateRoot._dupeFade
                        layer.enabled: opacity < 1

                        Behavior on scale   { NumberAnimation { duration: 300; easing.type: Easing.OutBack } }
                        Behavior on opacity { NumberAnimation { duration: 300 } }

                        transform: Matrix4x4 {
                            property real s: weTab.weSkewFactor
                            matrix: Qt.matrix4x4(1, s, 0, 0,
                                                 0, 1, 0, 0,
                                                 0, 0, 1, 0,
                                                 0, 0, 0, 1)
                        }

                        // Active scene indicator ring
                        Rectangle {
                            anchors.fill: parent
                            color: "transparent"
                            border.width: root.activeWeScene === weDelegateRoot.sceneId ? 3 : 0
                            border.color: "#AAFFFFFF"
                            z: 5
                        }

                        // Outer skewed border preview
                        AnimatedImage {
                            id: weOuterImg
                            anchors.fill: parent
                            fillMode: Image.Stretch
                            asynchronous: true
                            visible: weInnerImg.status === Image.Ready

                            property var exts: [".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"]
                            property int extIdx: 0
                            function tryLoad() {
                                if (extIdx >= exts.length) { source = ""; return; }
                                source = "file://" + root.weWorkshopPath + "/" + weDelegateRoot.sceneId
                                         + "/preview" + exts[extIdx];
                            }
                            Component.onCompleted: tryLoad()
                            onStatusChanged: {
                                if (status === Image.Error) { extIdx += 1; tryLoad(); }
                            }
                            playing: weDelegateRoot.isCurrent && status === Image.Ready
                                     && source.toString().toLowerCase().endsWith(".gif")
                        }

                        Item {
                            anchors.fill: parent
                            anchors.margins: weTab.weBorderWidth
                            visible: weInnerImg.status === Image.Ready

                            Rectangle { anchors.fill: parent; color: "black" }
                            clip: true

                            AnimatedImage {
                                id: weInnerImg
                                anchors.centerIn: parent
                                anchors.horizontalCenterOffset: -50

                                width: parent.width + (parent.height * Math.abs(weTab.weSkewFactor)) + 50
                                height: parent.height

                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true

                                property var exts: [".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"]
                                property int extIdx: 0
                                function tryLoad() {
                                    if (extIdx >= exts.length) { source = ""; return; }
                                    source = "file://" + root.weWorkshopPath + "/" + weDelegateRoot.sceneId
                                             + "/preview" + exts[extIdx];
                                }
                                Component.onCompleted: tryLoad()
                                onStatusChanged: {
                                    if (status === Image.Error) { extIdx += 1; tryLoad(); }
                                }
                                playing: weDelegateRoot.isCurrent && status === Image.Ready
                                         && source.toString().toLowerCase().endsWith(".gif")

                                transform: Matrix4x4 {
                                    property real s: -weTab.weSkewFactor
                                    matrix: Qt.matrix4x4(1, s, 0, 0,
                                                         0, 1, 0, 0,
                                                         0, 0, 1, 0,
                                                         0, 0, 0, 1)
                                }
                            }
                        }

                        // Fallback: no preview placeholder
                        Rectangle {
                            anchors.fill: parent
                            color: "#28FFFFFF"
                            visible: weInnerImg.status !== Image.Ready && weInnerImg.status !== Image.Loading

                            Text {
                                anchors.centerIn: parent
                                text: "No Preview"
                                color: "#80FFFFFF"
                                font.pixelSize: 13
                            }
                        }
                    }
                }
            }

            // PathView for infinite mode — fills parent like the images carousel
            PathView {
                id: weCarouselPathView
                anchors.top: weToolbar.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                visible: root._isInfinite

                model: root._isInfinite ? weCarouselModel : null
                delegate: weCarouselDelegate

                pathItemCount: Math.max(1, Math.min(weCarouselModel.count,
                    Math.ceil(width / weTab.weItemWidth) + 4))
                cacheItemCount: 4

                preferredHighlightBegin: 0.5
                preferredHighlightEnd: 0.5
                highlightRangeMode: PathView.StrictlyEnforceRange
                highlightMoveDuration: root._weInitialFocusSet ? 150 : 0
                movementDirection: PathView.Shortest

                focus: root._isInfinite && overlay.visible && carousel.activeTab === 2

                Keys.onPressed: event => {
                    if (weTab.weConfirmingIndex >= 0) { event.accepted = true; return; }
                    if (event.key === Qt.Key_Escape) {
                        root.close(); event.accepted = true;
                    } else if (event.key === Qt.Key_Tab) {
                        carousel.cycleTab(+1); event.accepted = true;
                    } else if (event.key === Qt.Key_Backtab) {
                        carousel.cycleTab(-1); event.accepted = true;
                    } else if (event.key === Qt.Key_Left) {
                        decrementCurrentIndex(); event.accepted = true;
                    } else if (event.key === Qt.Key_Right) {
                        incrementCurrentIndex(); event.accepted = true;
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        if (currentItem) currentItem.pickScene();
                        event.accepted = true;
                    }
                }

                onCountChanged: root._tryFocusWeCarousel()

                readonly property real _pathLen: pathItemCount * weTab.weItemWidth
                readonly property real _pathX0: (width - _pathLen) / 2
                path: Path {
                    startX: weCarouselPathView._pathX0
                    startY: weCarouselPathView.height / 2 - weTab.weItemHeight / 2
                    PathLine {
                        x: weCarouselPathView._pathX0 + weCarouselPathView._pathLen
                        y: weCarouselPathView.height / 2 - weTab.weItemHeight / 2
                    }
                }
            }

            // ListView for standard / wrap modes — fills parent like the images carousel
            ListView {
                id: weCarouselListView
                anchors.top: weToolbar.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                visible: !root._isInfinite

                model: root._isInfinite ? null : weCarouselModel
                delegate: weCarouselDelegate

                spacing: 0
                orientation: ListView.Horizontal
                clip: false
                cacheBuffer: 5000

                highlightRangeMode: ListView.StrictlyEnforceRange
                preferredHighlightBegin: (width / 2) - (weTab.weItemWidth / 2)
                preferredHighlightEnd:   (width / 2) + (weTab.weItemWidth / 2)
                highlightMoveDuration: root._weInitialFocusSet ? 150 : 0

                focus: !root._isInfinite && overlay.visible && carousel.activeTab === 2

                Keys.onPressed: event => {
                    if (weTab.weConfirmingIndex >= 0) { event.accepted = true; return; }
                    if (event.key === Qt.Key_Escape) {
                        root.close(); event.accepted = true;
                    } else if (event.key === Qt.Key_Tab) {
                        carousel.cycleTab(+1); event.accepted = true;
                    } else if (event.key === Qt.Key_Backtab) {
                        carousel.cycleTab(-1); event.accepted = true;
                    } else if (event.key === Qt.Key_Left) {
                        if (currentIndex > 0)
                            decrementCurrentIndex();
                        else if (root._wrapsIndex)
                            currentIndex = count - 1;
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Right) {
                        if (currentIndex < count - 1)
                            incrementCurrentIndex();
                        else if (root._wrapsIndex)
                            currentIndex = 0;
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Home) {
                        currentIndex = 0; event.accepted = true;
                    } else if (event.key === Qt.Key_End) {
                        currentIndex = count - 1; event.accepted = true;
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        if (currentItem) currentItem.pickScene();
                        event.accepted = true;
                    }
                }

                onCountChanged: root._tryFocusWeCarousel()
            }

            // -----------------------------------------------------------------
            // Compact info strip — pinned to the bottom of the WE tab
            // -----------------------------------------------------------------
            Item {
                id: weInfoStrip
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 24
                width: Math.min(parent.width - 40, 700)
                height: weInfoRow.implicitHeight + 12
                visible: weDetailPanel.currentSceneId !== "" && weSceneFilteredModel.count > 0

                // small preview thumbnail
                Item {
                    id: weThumb
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: weTab.showPreview ? 96 : 0
                    height: weTab.showPreview ? 54 : 0
                    clip: true
                    visible: weTab.showPreview

                    Rectangle {
                        anchors.fill: parent
                        color: "#20FFFFFF"
                        radius: 6
                    }

                    AnimatedImage {
                        id: weDetailImg
                        anchors.fill: parent
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: true

                        property string watchedId: weDetailPanel.currentSceneId
                        property var exts: [".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"]
                        property int extIdx: 0

                        function tryLoad() {
                            if (extIdx >= exts.length) { source = ""; return; }
                            source = "file://" + root.weWorkshopPath + "/" + watchedId
                                     + "/preview" + exts[extIdx];
                        }
                        onWatchedIdChanged: { extIdx = 0; tryLoad(); }
                        Component.onCompleted: tryLoad()
                        onStatusChanged: {
                            if (status === Image.Error) { extIdx += 1; tryLoad(); }
                            else if (status === Image.Ready)
                                playing = source.toString().toLowerCase().endsWith(".gif");
                        }
                    }
                }

                Row {
                    id: weInfoRow
                    anchors.left: weThumb.right
                    anchors.leftMargin: weTab.showPreview ? 12 : 0
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 10

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: weDetailPanel.currentName
                        color: "white"
                        font.pixelSize: 15
                        font.weight: Font.Medium
                        elide: Text.ElideRight
                        width: Math.min(implicitWidth, 280)
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "ID: " + weDetailPanel.currentSceneId
                        color: "#80FFFFFF"
                        font.pixelSize: 12
                    }

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: activeStripLabel.implicitWidth + 16
                        height: 22
                        radius: 11
                        color: "#6600CC66"
                        border.width: 1
                        border.color: "#80AAFFAA"
                        visible: weDetailPanel.isActive

                        Text {
                            id: activeStripLabel
                            anchors.centerIn: parent
                            text: "● Active"
                            color: "#AAFFAA"
                            font.pixelSize: 11
                            font.weight: Font.Medium
                        }
                    }

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: applyStripLabel.implicitWidth + 20
                        height: 28
                        radius: 14
                        color: applyStripMa.containsMouse ? "#DDFFFFFF" : "#80FFFFFF"

                        Text {
                            id: applyStripLabel
                            anchors.centerIn: parent
                            text: weDetailPanel.isActive ? "Restart" : "Apply"
                            color: "#CC000000"
                            font.pixelSize: 12
                            font.weight: Font.Medium
                        }

                        MouseArea {
                            id: applyStripMa
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: {
                                const v = root._isInfinite ? weCarouselPathView : weCarouselListView;
                                weTab.weConfirmPick(v.currentIndex, weDetailPanel.currentSceneId);
                            }
                        }
                    }
                }
            }

            // detail state (no separate panel — just the info strip above)
            readonly property var _weCurrentModel: {
                const v = root._isInfinite ? weCarouselPathView : weCarouselListView;
                const idx = v.currentIndex;
                return (idx >= 0 && idx < weCarouselModel.count) ? weCarouselModel.get(idx) : null;
            }

            Item {
                id: weDetailPanel
                readonly property string currentSceneId: weTab._weCurrentModel ? weTab._weCurrentModel.sceneId : ""
                readonly property string currentName: weTab._weCurrentModel ? (weTab._weCurrentModel.name || weTab._weCurrentModel.sceneId) : ""
                readonly property bool isActive: root.activeWeScene === currentSceneId && currentSceneId !== ""
            }

            // Empty / scanning state
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

        // -------------------------------------------------------------------------
        // ALL TAB  (tab 0 — default, shows images + WE scenes together)
        // -------------------------------------------------------------------------
        Item {
            id: allTab
            anchors.fill: parent
            visible: carousel.activeTab === 0
            opacity: overlay.visible ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 150 } }

            MouseArea { anchors.fill: parent; onClicked: {} }

            property bool showPreview: true

            // -----------------------------------------------------------------
            // Toolbar: filter dropdown + counts
            // -----------------------------------------------------------------
            Item {
                id: allToolbar
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.topMargin: tabBar.height + tabBar.anchors.topMargin + 12
                anchors.leftMargin: 20
                anchors.rightMargin: 20
                height: 40

                Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6

                    Repeater {
                        model: ["All", "Images", "WE Scenes"]
                        Rectangle {
                            readonly property int filterIdx: index
                            width: filterLabel.implicitWidth + 24
                            height: 32
                            radius: 16
                            color: root.allFilter === filterIdx
                                   ? "#80FFFFFF"
                                   : (filterMa.containsMouse ? "#50FFFFFF" : "#30FFFFFF")

                            Text {
                                id: filterLabel
                                anchors.centerIn: parent
                                text: modelData
                                color: "white"
                                font.pixelSize: 13
                                font.weight: root.allFilter === parent.filterIdx ? Font.Medium : Font.Normal
                            }

                            MouseArea {
                                id: filterMa
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: {
                                    root.allFilter = parent.filterIdx;
                                    root._syncAllModel();
                                }
                            }
                        }
                    }
                }

                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: allModel.count + " item" + (allModel.count !== 1 ? "s" : "")
                        color: "#BBBBBB"
                        font.pixelSize: 12
                    }

                    Rectangle {
                        width: allPreviewToggleLabel.implicitWidth + 20
                        height: 28
                        radius: 14
                        color: allTab.showPreview ? "#80FFFFFF" : (allPreviewToggleMa.containsMouse ? "#50FFFFFF" : "#30FFFFFF")

                        Text {
                            id: allPreviewToggleLabel
                            anchors.centerIn: parent
                            text: allTab.showPreview ? "\uD83D\uDC41 Preview" : "\uD83D\uDC41 Hidden"
                            color: "white"
                            font.pixelSize: 12
                        }

                        MouseArea {
                            id: allPreviewToggleMa
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: allTab.showPreview = !allTab.showPreview
                        }
                    }
                }
            }

            // Shared delegate for both All-tab views
            Component {
                id: allCarouselDelegate

                Item {
                    id: allDelegateRoot
                    width: carousel.itemWidth
                    height: carousel.itemHeight
                    anchors.verticalCenter: parent ? parent.verticalCenter : undefined

                    required property int index
                    required property string kind
                    required property string fileUrl
                    required property string sceneId
                    required property string name

                    readonly property bool isCurrent: root._isInfinite
                        ? PathView.isCurrentItem
                        : ListView.isCurrentItem

                    readonly property bool isActiveItem: {
                        if (kind === "image") {
                            const wp = (SessionData.perMonitorWallpaper && overlay.screen)
                                       ? SessionData.getMonitorWallpaper(overlay.screen.name)
                                       : SessionData.wallpaperPath;
                            return fileUrl !== "" && fileUrl === wp;
                        }
                        return sceneId !== "" && sceneId === root.activeWeScene;
                    }

                    readonly property int distFromCenter: {
                        if (root._isInfinite) {
                            const n = allModel.count;
                            if (n <= 1) return 0;
                            const d = Math.abs(index - allPathView.currentIndex);
                            return Math.min(d, n - d);
                        }
                        return Math.abs(index - allListView.currentIndex);
                    }

                    readonly property real falloff: 1.0 / (1.0 + distFromCenter * distFromCenter)

                    readonly property real _dupeFade: {
                        if (!root._isInfinite) return 1.0;
                        const base = root._allBaseCount;
                        if (base <= 0 || base >= allModel.count) return 1.0;
                        const n = allModel.count;
                        const cur = allPathView.currentIndex;
                        const wpOffset = ((index % base) - (cur % base) + base) % base;
                        const leftCount  = Math.floor(base / 2);
                        const rightCount = Math.floor((base - 1) / 2);
                        let target;
                        if (wpOffset === 0)
                            target = cur;
                        else if (wpOffset <= rightCount)
                            target = (cur + wpOffset) % n;
                        else if (base - wpOffset <= leftCount)
                            target = (cur - (base - wpOffset) + n) % n;
                        else
                            return 0.0;
                        return index === target ? 1.0 : 0.0;
                    }

                    function activateItem() {
                        if (kind === "image") {
                            carousel.confirmPick(index, fileUrl);
                        } else {
                            allTab._allConfirmingIndex = index;
                            allPickTimer.start();
                            root.pickWeScene(sceneId);
                        }
                    }

                    z: allTab._allConfirmingIndex === index ? 100
                       : isCurrent ? 10 : Math.max(1, 10 - distFromCenter)

                    MouseArea {
                        id: allDelegateMa
                        x: carousel.skewFactor * carousel.itemHeight / 2
                        width: parent.width
                        height: parent.height
                        hoverEnabled: true
                        onClicked: allDelegateRoot.activateItem()
                    }

                    Item {
                        anchors.centerIn: parent
                        width: parent.width
                        height: parent.height

                        readonly property bool isConfirmed: allTab._allConfirmingIndex === allDelegateRoot.index
                        readonly property bool isOtherConfirming: allTab._allConfirmingIndex >= 0 && !isConfirmed
                        readonly property bool isHovered: allDelegateMa.containsMouse && allTab._allConfirmingIndex < 0

                        scale: isConfirmed ? 1.6
                             : isOtherConfirming ? (0.75 + 0.40 * allDelegateRoot.falloff) * 0.8
                             : isHovered ? 0.75 + 0.60 * allDelegateRoot.falloff
                             : 0.75 + 0.40 * allDelegateRoot.falloff
                        opacity: (isConfirmed ? 0.0
                               : isOtherConfirming ? 0.0
                               : isHovered ? 1.0
                               : 0.1 + 0.9 * allDelegateRoot.falloff) * allDelegateRoot._dupeFade
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

                        // Active indicator ring
                        Rectangle {
                            anchors.fill: parent
                            color: "transparent"
                            border.width: allDelegateRoot.isActiveItem ? 3 : 0
                            border.color: "#AAFFFFFF"
                            z: 5
                        }

                        // Outer skewed border image
                        AnimatedImage {
                            id: allOuterImg
                            anchors.fill: parent
                            fillMode: Image.Stretch
                            asynchronous: true
                            visible: allInnerImg.status === Image.Ready
                            playing: allDelegateRoot.isCurrent && status === Image.Ready
                                     && source.toString().toLowerCase().endsWith(".gif")

                            property var weExts: [".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"]
                            property int weExtIdx: 0
                            function tryLoadWe() {
                                if (weExtIdx >= weExts.length) { source = ""; return; }
                                source = "file://" + root.weWorkshopPath + "/" + allDelegateRoot.sceneId
                                         + "/preview" + weExts[weExtIdx];
                            }
                            source: allDelegateRoot.kind === "image" ? allDelegateRoot.fileUrl : ""
                            Component.onCompleted: { if (kind === "we") tryLoadWe(); }
                            onStatusChanged: { if (status === Image.Error && kind === "we") { weExtIdx += 1; tryLoadWe(); } }
                        }

                        Item {
                            anchors.fill: parent
                            anchors.margins: carousel.borderWidth
                            visible: allInnerImg.status === Image.Ready

                            Rectangle { anchors.fill: parent; color: "black" }
                            clip: true

                            AnimatedImage {
                                id: allInnerImg
                                anchors.centerIn: parent
                                anchors.horizontalCenterOffset: -50

                                width: parent.width + (parent.height * Math.abs(carousel.skewFactor)) + 50
                                height: parent.height

                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                playing: allDelegateRoot.isCurrent && status === Image.Ready
                                         && source.toString().toLowerCase().endsWith(".gif")

                                property var weExts: [".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"]
                                property int weExtIdx: 0
                                function tryLoadWe() {
                                    if (weExtIdx >= weExts.length) { source = ""; return; }
                                    source = "file://" + root.weWorkshopPath + "/" + allDelegateRoot.sceneId
                                             + "/preview" + weExts[weExtIdx];
                                }
                                source: allDelegateRoot.kind === "image" ? allDelegateRoot.fileUrl : ""
                                Component.onCompleted: { if (kind === "we") tryLoadWe(); }
                                onStatusChanged: { if (status === Image.Error && kind === "we") { weExtIdx += 1; tryLoadWe(); } }

                                transform: Matrix4x4 {
                                    property real s: -carousel.skewFactor
                                    matrix: Qt.matrix4x4(1, s, 0, 0,
                                                         0, 1, 0, 0,
                                                         0, 0, 1, 0,
                                                         0, 0, 0, 1)
                                }
                            }
                        }

                        // Kind badge
                        Rectangle {
                            anchors.top: parent.top
                            anchors.right: parent.right
                            anchors.margins: 4
                            width: allKindBadgeLabel.implicitWidth + 12
                            height: 18
                            radius: 9
                            color: allDelegateRoot.kind === "we" ? "#80660099" : "#80004466"
                            visible: allDelegateRoot.isCurrent || allDelegateRoot.isActiveItem
                            z: 6

                            Text {
                                id: allKindBadgeLabel
                                anchors.centerIn: parent
                                text: allDelegateRoot.kind === "we" ? "WE" : "IMG"
                                color: "white"
                                font.pixelSize: 9
                                font.weight: Font.Bold
                            }
                        }
                    }
                }
            }

            property int _allConfirmingIndex: -1

            Timer {
                id: allPickTimer
                interval: 300
                onTriggered: allTab._allConfirmingIndex = -1
            }

            // PathView for infinite mode
            PathView {
                id: allPathView
                anchors.top: allToolbar.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                visible: root._isInfinite

                model: root._isInfinite ? allModel : null
                delegate: allCarouselDelegate

                pathItemCount: Math.max(1, Math.min(allModel.count,
                    Math.ceil(width / carousel.itemWidth) + 4))
                cacheItemCount: 4

                preferredHighlightBegin: 0.5
                preferredHighlightEnd: 0.5
                highlightRangeMode: PathView.StrictlyEnforceRange
                highlightMoveDuration: root._allInitialFocusSet ? 150 : 0
                movementDirection: PathView.Shortest

                focus: root._isInfinite && overlay.visible && carousel.activeTab === 0

                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) {
                        root.close(); event.accepted = true;
                    } else if (event.key === Qt.Key_Tab) {
                        carousel.cycleTab(+1); event.accepted = true;
                    } else if (event.key === Qt.Key_Backtab) {
                        carousel.cycleTab(-1); event.accepted = true;
                    } else if (event.key === Qt.Key_Left) {
                        decrementCurrentIndex(); event.accepted = true;
                    } else if (event.key === Qt.Key_Right) {
                        incrementCurrentIndex(); event.accepted = true;
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        if (currentItem) currentItem.activateItem();
                        event.accepted = true;
                    }
                }

                onCountChanged: root._tryFocusAllCarousel()

                readonly property real _pathLen: pathItemCount * carousel.itemWidth
                readonly property real _pathX0: (width - _pathLen) / 2
                path: Path {
                    startX: allPathView._pathX0
                    startY: allPathView.height / 2 - carousel.itemHeight / 2
                    PathLine {
                        x: allPathView._pathX0 + allPathView._pathLen
                        y: allPathView.height / 2 - carousel.itemHeight / 2
                    }
                }
            }

            // ListView for standard / wrap modes
            ListView {
                id: allListView
                anchors.top: allToolbar.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                visible: !root._isInfinite

                model: root._isInfinite ? null : allModel
                delegate: allCarouselDelegate

                spacing: 0
                orientation: ListView.Horizontal
                clip: false
                cacheBuffer: 5000

                highlightRangeMode: ListView.StrictlyEnforceRange
                preferredHighlightBegin: (width / 2) - (carousel.itemWidth / 2)
                preferredHighlightEnd:   (width / 2) + (carousel.itemWidth / 2)
                highlightMoveDuration: root._allInitialFocusSet ? 150 : 0

                focus: !root._isInfinite && overlay.visible && carousel.activeTab === 0

                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) {
                        root.close(); event.accepted = true;
                    } else if (event.key === Qt.Key_Tab) {
                        carousel.cycleTab(+1); event.accepted = true;
                    } else if (event.key === Qt.Key_Backtab) {
                        carousel.cycleTab(-1); event.accepted = true;
                    } else if (event.key === Qt.Key_Left) {
                        if (currentIndex > 0)
                            decrementCurrentIndex();
                        else if (root._wrapsIndex)
                            currentIndex = count - 1;
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Right) {
                        if (currentIndex < count - 1)
                            incrementCurrentIndex();
                        else if (root._wrapsIndex)
                            currentIndex = 0;
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Home) {
                        currentIndex = 0; event.accepted = true;
                    } else if (event.key === Qt.Key_End) {
                        currentIndex = count - 1; event.accepted = true;
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        if (currentItem) currentItem.activateItem();
                        event.accepted = true;
                    }
                }

                onCountChanged: root._tryFocusAllCarousel()
            }

            // Compact info strip — pinned to the bottom of the All tab
            Item {
                id: allInfoStrip
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 24
                width: Math.min(parent.width - 40, 700)
                height: allInfoRow.implicitHeight + 12
                visible: allTab.showPreview && allInfoStrip._currentKind !== ""

                readonly property var _currentEntry: {
                    const v = root._isInfinite ? allPathView : allListView;
                    const idx = v.currentIndex;
                    return (idx >= 0 && idx < allModel.count) ? allModel.get(idx) : null;
                }
                readonly property string _currentKind: _currentEntry ? _currentEntry.kind : ""
                readonly property string _displayName: {
                    if (!_currentEntry) return "";
                    return _currentEntry.kind === "we"
                        ? (_currentEntry.name || _currentEntry.sceneId)
                        : _currentEntry.fileName;
                }
                readonly property string _previewSource: {
                    if (!_currentEntry) return "";
                    if (_currentEntry.kind === "image") return _currentEntry.fileUrl;
                    if (_currentEntry.sceneId)
                        return "file://" + root.weWorkshopPath + "/" + _currentEntry.sceneId + "/preview.jpg";
                    return "";
                }
                readonly property bool _isActiveItem: {
                    if (!_currentEntry) return false;
                    if (_currentEntry.kind === "image") {
                        const wp = (SessionData.perMonitorWallpaper && overlay.screen)
                                   ? SessionData.getMonitorWallpaper(overlay.screen.name)
                                   : SessionData.wallpaperPath;
                        return _currentEntry.fileUrl !== "" && _currentEntry.fileUrl === wp;
                    }
                    return _currentEntry.sceneId === root.activeWeScene;
                }

                Item {
                    id: allThumb
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: 96; height: 54
                    clip: true

                    Rectangle {
                        anchors.fill: parent
                        color: "#20FFFFFF"
                        radius: 6
                    }

                    Image {
                        anchors.fill: parent
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: true
                        source: allInfoStrip._previewSource
                    }
                }

                Row {
                    id: allInfoRow
                    anchors.left: allThumb.right
                    anchors.leftMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 10

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: allInfoStrip._displayName
                        color: "white"
                        font.pixelSize: 15
                        font.weight: Font.Medium
                        elide: Text.ElideRight
                        width: Math.min(implicitWidth, 280)
                    }

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: allActiveLabel.implicitWidth + 16
                        height: 22
                        radius: 11
                        color: "#6600CC66"
                        border.width: 1
                        border.color: "#80AAFFAA"
                        visible: allInfoStrip._isActiveItem

                        Text {
                            id: allActiveLabel
                            anchors.centerIn: parent
                            text: "● Active"
                            color: "#AAFFAA"
                            font.pixelSize: 11
                            font.weight: Font.Medium
                        }
                    }

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: allApplyLabel.implicitWidth + 20
                        height: 28
                        radius: 14
                        color: allApplyMa.containsMouse ? "#DDFFFFFF" : "#80FFFFFF"

                        Text {
                            id: allApplyLabel
                            anchors.centerIn: parent
                            text: allInfoStrip._isActiveItem
                                  ? (allInfoStrip._currentKind === "we" ? "Restart" : "Current")
                                  : "Apply"
                            color: "#CC000000"
                            font.pixelSize: 12
                            font.weight: Font.Medium
                        }

                        MouseArea {
                            id: allApplyMa
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: {
                                const v = root._isInfinite ? allPathView : allListView;
                                if (v.currentItem) v.currentItem.activateItem();
                            }
                        }
                    }
                }
            }

            // Empty state
            Column {
                anchors.centerIn: parent
                spacing: 10
                visible: allModel.count === 0

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "No items found"
                    color: "white"
                    font.pixelSize: 18
                    font.bold: true
                }
            }
        }

        // Empty state message (Images tab)
        Column {
            anchors.centerIn: parent
            spacing: 12
            visible: overlay.visible && carousel.activeTab === 1 &&
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
