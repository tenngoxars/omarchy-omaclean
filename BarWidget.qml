import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "zykyaka.omaclean"

  readonly property string omacleanBin: Quickshell.env("HOME") + "/.local/bin/omaclean"

  // omaclean clean --json 的扫描结果
  property string freeSpace: ""
  property int selectable: 0
  property string reclaimable: ""
  property var items: []
  property bool hasData: false
  property bool scanning: false
  property bool stale: false

  // 面板内执行的运行状态与最近一次结果
  property bool execRunning: false
  property var lastExec: ({})

  // purge（项目构建产物）扫描结果
  property var purgeItems: []
  property int purgeCandidates: 0
  property string purgeDefaultDisplay: ""
  property bool purgeHasData: false
  property bool purgeScanning: false

  // 面板勾选后调用：非交互执行选中项（系统项由 omaclean 经 polkit 弹窗提权）
  function runClean(ids) {
    if (root.execRunning || !ids || ids.length === 0) return
    root.execRunning = true
    root.lastExec = ({})
    execProc.command = [root.omacleanBin, "clean", "--exec", ids.join(",")]
    execProc.running = true
  }

  function scanPurge() {
    if (purgeProc.running) return
    root.purgeScanning = true
    purgeProc.running = true
  }

  function runPurge(paths) {
    if (root.execRunning || !paths || paths.length === 0) return
    root.execRunning = true
    root.lastExec = ({})
    purgeExecProc.command = [root.omacleanBin, "purge", "--exec"].concat(paths)
    purgeExecProc.running = true
  }

  function openPurge() {
    var target = ensurePanel()
    if (target && "view" in target) target.view = "artifacts"
    root.open()
  }

  // chip：垃圾桶图标 + 本轮可回收量；失败时保留旧值由 dimmed 标记过期
  property string displayText: root.hasData
    ? "\uf1f8 " + (root.selectable > 0 ? root.reclaimable : "0B")
    : "\uf1f8"

  function refresh() {
    if (scanProc.running) return
    root.scanning = true
    scanProc.running = true
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() {
    root.refresh()
    var target = ensurePanel()
    if (target) target.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggle() {
    if (!root.opened) root.refresh()
    var target = ensurePanel()
    if (target) target.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function ensurePanel() {
    if (!panelLoader.active) panelLoader.active = true
    return panelLoader.item
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("items" in target) target.items = root.items
    if ("selectable" in target) target.selectable = root.selectable
    if ("reclaimable" in target) target.reclaimable = root.reclaimable
    if ("freeSpace" in target) target.freeSpace = root.freeSpace
    if ("hasData" in target) target.hasData = root.hasData
    if ("scanning" in target) target.scanning = root.scanning
    if ("stale" in target) target.stale = root.stale
    if ("execRunning" in target) target.execRunning = root.execRunning
    if ("lastExec" in target) target.lastExec = root.lastExec
    if ("purgeItems" in target) target.purgeItems = root.purgeItems
    if ("purgeCandidates" in target) target.purgeCandidates = root.purgeCandidates
    if ("purgeDefaultDisplay" in target) target.purgeDefaultDisplay = root.purgeDefaultDisplay
    if ("purgeHasData" in target) target.purgeHasData = root.purgeHasData
    if ("purgeScanning" in target) target.purgeScanning = root.purgeScanning
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  onItemsChanged: injectPanel()
  onSelectableChanged: injectPanel()
  onReclaimableChanged: injectPanel()
  onFreeSpaceChanged: injectPanel()
  onHasDataChanged: injectPanel()
  onScanningChanged: injectPanel()
  onStaleChanged: injectPanel()
  onExecRunningChanged: injectPanel()
  onLastExecChanged: injectPanel()
  onPurgeItemsChanged: injectPanel()
  onPurgeCandidatesChanged: injectPanel()
  onPurgeDefaultDisplayChanged: injectPanel()
  onPurgeHasDataChanged: injectPanel()
  onPurgeScanningChanged: injectPanel()

  Component.onCompleted: root.refresh()

  Process {
    id: scanProc
    running: false
    command: [root.omacleanBin, "clean", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!text || text.trim() === "") return
        try {
          var res = JSON.parse(text)
          root.items = res.items || []
          root.selectable = res.selectable || 0
          root.reclaimable = res.reclaimable || "0B"
          root.freeSpace = res.free_space || ""
          root.hasData = true
          root.stale = false
        } catch (e) {
          root.stale = true
        }
      }
    }
    onExited: function(exitCode) {
      root.scanning = false
      if (exitCode !== 0) root.stale = true
    }
  }

  // 兜底低频校正：缓存体积变化没有事件源，按小时级刷新即可
  Timer {
    interval: 7200000
    running: true
    repeat: true
    triggeredOnStart: false
    onTriggered: root.refresh()
  }

  Process {
    id: execProc
    running: false
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!text || text.trim() === "") return
        try {
          root.lastExec = JSON.parse(text)
        } catch (e) {
          root.lastExec = { error: true }
        }
      }
    }
    onExited: function(exitCode) {
      root.execRunning = false
      root.refresh()
    }
  }

  Process {
    id: purgeProc
    running: false
    command: [root.omacleanBin, "purge", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!text || text.trim() === "") return
        try {
          var res = JSON.parse(text)
          root.purgeItems = res.items || []
          root.purgeCandidates = res.candidates || 0
          root.purgeDefaultDisplay = res.default_display || ""
          root.purgeHasData = true
        } catch (e) {
        }
      }
    }
    onExited: function(exitCode) {
      root.purgeScanning = false
    }
  }

  Process {
    id: purgeExecProc
    running: false
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!text || text.trim() === "") return
        try {
          root.lastExec = JSON.parse(text)
        } catch (e) {
          root.lastExec = { error: true }
        }
      }
    }
    onExited: function(exitCode) {
      root.execRunning = false
      root.scanPurge()
    }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "zykyaka.omaclean"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function clean(ids: string): void {
      var list = String(ids || "").split(",").filter(function(s) { return s !== "" })
      if (list.length > 0) root.runClean(list)
    }
    function purge(): void { root.openPurge() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.displayText
    fontSize: Style.font.bodySmall
    horizontalMargin: 8.5
    verticalPadding: 6
    active: root.opened
    dimmed: root.stale || !root.hasData
    onPressed: function(b) {
      if (b === Qt.RightButton) root.refresh()
      else root.toggle()
    }
  }
}
