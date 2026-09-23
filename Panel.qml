import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "zykyaka.omaclean"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // 视图：caches（clean）与 artifacts（purge）
  property string view: "caches"

  // 由 BarWidget 注入的扫描结果与执行状态
  property var items: []
  property int selectable: 0
  property string reclaimable: ""
  property string freeSpace: ""
  property bool hasData: false
  property bool scanning: false
  property bool stale: false
  property bool execRunning: false
  property var lastExec: ({})
  property var purgeItems: []
  property int purgeCandidates: 0
  property string purgeDefaultDisplay: ""
  property bool purgeHasData: false
  property bool purgeScanning: false

  // Artifacts 排序：size（体积降序）| age（最旧优先）
  property string purgeSort: "size"
  onPurgeSortChanged: rebuildPurgeRows()

  // 勾选行模型：{key, category, label, display, bytes, system, ready, checked}
  property var rows: []
  property var purgeRows: []

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  // 灰阶从前景色派生，跟随主题
  readonly property color faint: Util.alpha(foreground, 0.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var categories: ["Package Management", "System", "User Caches", "Developer Caches"]

  // "1.2GiB" → "1.2G"：hero meta 会被 PanelHero 大写，单位保持单字母
  function shortSize(s) {
    return String(s).replace(/iB$/, "").replace(/B$/, "")
  }

  function humanBytes(n) {
    if (!n || n <= 0) return "0B"
    if (n >= 1073741824) return (n / 1073741824).toFixed(1) + "G"
    if (n >= 1048576) return (n / 1048576).toFixed(1) + "M"
    if (n >= 1024) return Math.round(n / 1024) + "K"
    return n + "B"
  }

  readonly property string heroMeta: {
    if (root.view === "artifacts") {
      if (root.purgeScanning && !root.purgeHasData) return "Scanning…"
      if (!root.purgeHasData) return "Waiting for scan"
      return shortSize(root.purgeDefaultDisplay) + " preselected · " + root.purgeCandidates + " candidates"
    }
    if (!root.hasData) return root.scanning ? "Scanning…" : "Waiting for scan"
    return shortSize(root.selectable > 0 ? root.reclaimable : "0B") + " reclaimable · " +
           shortSize(root.freeSpace) + " free"
  }

  // 扫描刷新后重建勾选：可选项按 omaclean 推荐默认勾选
  onItemsChanged: rebuildRows()
  onPurgeItemsChanged: rebuildPurgeRows()

  function rebuildRows() {
    var prev = {}
    for (var j = 0; j < root.rows.length; j++) prev[root.rows[j].key] = root.rows[j].checked
    var out = []
    for (var i = 0; i < root.items.length; i++) {
      var it = root.items[i]
      if (!it || it.status !== "ready") continue
      out.push({
        key: it.id,
        category: it.category,
        label: it.label,
        display: it.display,
        bytes: it.bytes,
        system: it.system === true,
        ready: true,
        checked: prev[it.id] !== undefined ? prev[it.id] : it.recommended === true
      })
    }
    root.rows = out
  }

  function rebuildPurgeRows() {
    var prev = {}
    for (var j = 0; j < root.purgeRows.length; j++) prev[root.purgeRows[j].key] = root.purgeRows[j].checked
    var out = []
    for (var i = 0; i < root.purgeItems.length; i++) {
      var it = root.purgeItems[i]
      if (!it) continue
      out.push({
        key: it.path,
        category: "",
        label: it.display,
        display: it.display_bytes + " · " + it.age_days + "d",
        bytes: it.bytes,
        ageDays: it.age_days,
        system: false,
        ready: true,
        checked: prev[it.path] !== undefined ? prev[it.path] : it.recommended === true
      })
    }
    if (root.purgeSort === "age") {
      out.sort(function(a, b) { return b.ageDays - a.ageDays })
    } else {
      out.sort(function(a, b) { return b.bytes - a.bytes })
    }
    root.purgeRows = out
  }

  function toggleIn(list, key) {
    var out = list.slice()
    for (var i = 0; i < out.length; i++) {
      if (out[i].key !== key) continue
      var copy = {}
      for (var k in out[i]) copy[k] = out[i][k]
      copy.checked = !out[i].checked
      out[i] = copy
      break
    }
    return out
  }

  function toggleRow(key) {
    if (root.execRunning) return
    root.rows = toggleIn(root.rows, key)
    root.purgeRows = toggleIn(root.purgeRows, key)
  }

  readonly property var activeRows: root.view === "artifacts" ? root.purgeRows : root.rows
  readonly property var selectedKeys: {
    var out = []
    for (var i = 0; i < activeRows.length; i++) if (activeRows[i].checked) out.push(activeRows[i].key)
    return out
  }
  readonly property int selectedCount: selectedKeys.length
  // 必须是 real（double）：全选合计可超过 int32（2GiB 上限）会溢出成负数
  readonly property real selectedBytes: {
    var total = 0
    for (var i = 0; i < activeRows.length; i++) if (activeRows[i].checked) total += (activeRows[i].bytes || 0)
    return total
  }

  readonly property bool allSelected: {
    if (activeRows.length === 0) return false
    for (var i = 0; i < activeRows.length; i++) {
      if (!activeRows[i].checked) return false
    }
    return true
  }

  function setAllChecked(list, value) {
    var out = []
    for (var i = 0; i < list.length; i++) {
      var copy = {}
      for (var k in list[i]) copy[k] = list[i][k]
      copy.checked = value
      out.push(copy)
    }
    return out
  }

  // 全选 / 全不选（与 CLI 的 a 键同语义：未全选时全选，已全选时清空）
  function toggleAll() {
    if (root.execRunning) return
    var value = !root.allSelected
    if (root.view === "artifacts") root.purgeRows = setAllChecked(root.purgeRows, value)
    else root.rows = setAllChecked(root.rows, value)
  }

  function rowsByCategory(cat) {
    var out = []
    for (var i = 0; i < root.rows.length; i++) {
      if (root.rows[i].category === cat) out.push(root.rows[i])
    }
    return out
  }

  readonly property var visibleCategories: {
    var out = []
    for (var c = 0; c < categories.length; c++) {
      if (rowsByCategory(categories[c]).length > 0) out.push(categories[c])
    }
    return out
  }

  readonly property var blockedItems: {
    var out = []
    for (var i = 0; i < root.items.length; i++) {
      var it = root.items[i]
      if (!it) continue
      if ((it.status === "skipped" || it.status === "protected") && it.bytes > 0) out.push(it)
    }
    return out
  }

  // 首个失败项的说明（如「admin component missing — install the reviewed privileged artifact」），
  // 存在时整条状态行让给它，避免被右侧提示和省略号截断。
  readonly property string failNote: {
    var list = root.lastExec && root.lastExec.items
    if (!list) return ""
    for (var i = 0; i < list.length; i++) {
      if (list[i] && list[i].status === "failed" && list[i].text) return list[i].text
    }
    return ""
  }

  readonly property string statusText: {
    if (root.execRunning) return root.view === "artifacts" ? "Purging…" : "Cleaning…"
    if (root.lastExec && root.lastExec.error) return "Cleanup failed"
    if (root.failNote !== "") return root.failNote
    if (root.lastExec && (root.lastExec.cleaned !== undefined || root.lastExec.purged !== undefined)) {
      var isPurge = root.lastExec.cleaned === undefined
      var count = isPurge ? root.lastExec.purged : root.lastExec.cleaned
      var parts = []
      if (count > 0) parts.push(count + (isPurge ? " purged" : " cleaned") + " · freed " + root.lastExec.freed)
      if (root.lastExec.skipped > 0) parts.push(root.lastExec.skipped + " skipped")
      if (root.lastExec.failed > 0) parts.push(root.lastExec.failed + " failed")
      if (parts.length > 0) return parts.join(" · ")
    }
    if (root.view === "artifacts") {
      return root.purgeScanning ? "Scanning artifacts…" : "Select artifacts, then Purge"
    }
    if (root.scanning) return "Scanning…"
    if (root.stale) return "Scan failed · showing last result"
    if (root.hasData && root.selectable === 0) return "Nothing to clean"
    return "Select items, then Clean"
  }

  function open() {
    root.refreshActive()
    root.controller.show()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function refreshActive() {
    if (root.hostWidget && root.hostWidget.refresh) root.hostWidget.refresh()
    if (root.view === "artifacts" && root.hostWidget && root.hostWidget.scanPurge) root.hostWidget.scanPurge()
  }

  // 面板内执行选中项；clean 的系统项由 omaclean 走 polkit 图形认证提权
  function startExec() {
    if (root.execRunning || root.selectedCount === 0) return
    var keys = root.selectedKeys
    if (root.view === "artifacts") {
      if (hostWidget && hostWidget.runPurge) hostWidget.runPurge(keys)
    } else {
      if (hostWidget && hostWidget.runClean) hostWidget.runClean(keys)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: Style.space(420)
    contentHeight: panel.fittedContentHeight(
                     hero.implicitHeight + Style.space(12) + controls.implicitHeight +
                     Style.space(12) + column.implicitHeight +
                     Style.space(6) + footerRow.implicitHeight,
                     Style.space(740))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_R) {
          root.refreshActive()
          event.accepted = true
        } else if (event.key === Qt.Key_A) {
          root.toggleAll()
          event.accepted = true
        }
      }

      PanelHero {
        id: hero
        anchors.top: parent.top
        title: "omaclean"
        meta: root.heroMeta
        foreground: root.foreground
        fontFamily: root.fontFamily
        iconOpacity: 1.0
        iconComponent: Component {
          Text {
            text: "\uf1f8"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }
        }
        trailingControl: headerActions
      }

      // 固定控制区：视图切换、全选与执行按钮不随列表滚动
      Column {
        id: controls
        anchors.top: hero.bottom
        anchors.topMargin: Style.space(12)
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(8)

        Row {
          width: parent.width
          spacing: Style.space(8)

          ButtonGroup {
            id: viewGroup
            width: parent.width - selectAllButton.width - parent.spacing
            options: [{ label: "Caches", value: "caches" }, { label: "Artifacts", value: "artifacts" }]
            value: root.view
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            focusable: false
            cursorIndex: -1
            onChanged: function(val) {
              root.view = val
              if (val === "artifacts" && root.hostWidget && root.hostWidget.scanPurge
                  && !root.purgeHasData && !root.purgeScanning)
                root.hostWidget.scanPurge()
            }
          }

          Button {
            id: selectAllButton
            text: root.allSelected ? "None" : "All"
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            enabled: !root.execRunning && root.activeRows.length > 0
            onClicked: root.toggleAll()
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          Button {
            id: execButton
            text: {
              if (root.execRunning) return root.view === "artifacts" ? "Purging…" : "Cleaning…"
              var verb = root.view === "artifacts" ? "Purge" : "Clean"
              return root.selectedCount > 0 ? verb + " · " + root.humanBytes(root.selectedBytes) : verb
            }
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            enabled: !root.execRunning && root.selectedCount > 0
            onClicked: root.startExec()
          }

          ButtonGroup {
            visible: root.view === "artifacts"
            width: visible ? parent.width - execButton.width - parent.spacing : 0
            options: [{ label: "Size", value: "size" }, { label: "Age", value: "age" }]
            value: root.purgeSort
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            focusable: false
            cursorIndex: -1
            onChanged: function(val) { root.purgeSort = val }
          }
        }
      }

      Flickable {
        id: panelFlick
        anchors.top: controls.bottom
        anchors.topMargin: Style.space(12)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footerRow.top
        anchors.bottomMargin: Style.space(6)
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        pixelAligned: true
        flickDeceleration: 6000
        maximumFlickVelocity: 2500
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        function scrollBy(dy) {
          contentY = Math.max(0, Math.min(contentHeight - height, contentY - dy))
        }

        WheelHandler {
          acceptedDevices: PointerDevice.Mouse
          target: null
          onWheel: function(event) {
            panelFlick.scrollBy((event.angleDelta.y / 120) * Style.space(240))
          }
        }

        WheelHandler {
          acceptedDevices: PointerDevice.TouchPad
          target: null
          onWheel: function(event) {
            var dy = event.pixelDelta.y !== 0
              ? event.pixelDelta.y * 2.5
              : (event.angleDelta.y / 120) * Style.space(240)
            panelFlick.scrollBy(dy)
          }
        }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ── Caches 视图：本轮可清理项，按分类分组；点击行切换勾选 ──
          Column {
            width: parent.width
            spacing: Style.space(12)
            visible: root.view === "caches"

            Repeater {
              model: root.visibleCategories
              delegate: Column {
                id: categoryColumn
                required property string modelData
                width: column.width
                spacing: Style.space(6)

                PanelSectionHeader {
                  width: parent.width
                  text: categoryColumn.modelData.toUpperCase()
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Repeater {
                  model: root.rowsByCategory(categoryColumn.modelData)
                  delegate: EntryRow {
                    required property var modelData
                    width: column.width
                    entry: modelData
                    onToggled: root.toggleRow(modelData.key)
                  }
                }
              }
            }

            // 空态
            Item {
              width: parent.width
              implicitHeight: Style.space(36)
              visible: root.hasData && root.selectable === 0

              Text {
                anchors.centerIn: parent
                text: "No reclaimable caches"
                color: root.faint
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            // 运行中浏览器、受保护回收站等本轮不可选项
            Column {
              width: parent.width
              spacing: Style.space(6)
              visible: root.blockedItems.length > 0

              PanelSeparator { foreground: root.foreground }

              PanelSectionHeader {
                width: parent.width
                text: "Not selectable this run"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: root.blockedItems
                delegate: EntryRow {
                  required property var modelData
                  width: column.width
                  entry: modelData
                  dimmed: true
                }
              }
            }
          }

          // ── Artifacts 视图：项目构建产物 ──
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.view === "artifacts"

            Item {
              width: parent.width
              implicitHeight: Style.space(36)
              visible: root.purgeScanning && !root.purgeHasData

              Text {
                anchors.centerIn: parent
                text: "Scanning project artifacts…"
                color: root.faint
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            Item {
              width: parent.width
              implicitHeight: Style.space(36)
              visible: root.purgeHasData && root.purgeRows.length === 0

              Text {
                anchors.centerIn: parent
                text: "No project artifacts"
                color: root.faint
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            Repeater {
              model: root.purgeRows
              delegate: EntryRow {
                required property var modelData
                width: column.width
                entry: modelData
                onToggled: root.toggleRow(modelData.key)
              }
            }
          }

        }
      }

      // 固定底栏：状态与快捷键提示不随列表滚动
      Item {
        id: footerRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        implicitHeight: Style.space(20)

        Text {
          anchors.left: parent.left
          anchors.right: hintKeys.left
          anchors.rightMargin: Style.spacing.sm
          anchors.verticalCenter: parent.verticalCenter
          text: root.statusText
          color: root.faint
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Text {
          id: hintKeys
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: root.failNote !== "" ? "" : "a all · r refresh · Esc close"
          color: root.faint
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  property Component headerActions: Component {
    Row {
      spacing: Style.space(6)

      Button {
        text: (root.view === "artifacts" ? root.purgeScanning : root.scanning) ? "Scanning…" : "Refresh"
        iconText: "󰑐"
        iconSize: Style.font.bodySmall
        iconSpinning: root.view === "artifacts" ? root.purgeScanning : root.scanning
        fontSize: Style.font.bodySmall
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: !root.scanning && !root.purgeScanning && !root.execRunning
        onClicked: root.refreshActive()
      }
    }
  }

  component EntryRow: Item {
    id: entryRow
    property var entry: null
    property bool dimmed: false
    signal toggled()

    readonly property bool selectable: entry ? entry.ready === true : false
    readonly property bool on: entry ? entry.checked === true : false

    implicitHeight: Math.max(labelText.implicitHeight, valueText.implicitHeight)
    width: parent ? parent.width : 0

    MouseArea {
      anchors.fill: parent
      enabled: entryRow.selectable && !root.execRunning
      cursorShape: entryRow.selectable ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: entryRow.toggled()
    }

    Text {
      id: marker
      visible: entryRow.selectable
      text: entryRow.on ? "●" : "○"
      color: entryRow.on ? root.foreground : root.faint
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: labelText
      text: entryRow.entry ? entryRow.entry.label : ""
      color: entryRow.dimmed ? root.faint : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: entryRow.selectable ? marker.implicitWidth + Style.space(6) : 0
      anchors.right: adminBadge.visible ? adminBadge.left : valueText.left
      anchors.rightMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: adminBadge
      visible: entryRow.entry && entryRow.entry.system === true
      text: "admin"
      color: root.faint
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.right: valueText.left
      anchors.rightMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: valueText
      text: entryRow.entry ? entryRow.entry.display : ""
      color: root.faint
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
    }
  }
}
