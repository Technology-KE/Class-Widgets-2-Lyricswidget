import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects
import Qt5Compat.GraphicalEffects
import QtQuick 2.15 as Quick
import RinUI
import ClassWidgets.Theme

// 歌词岛：上一句 / 当前句 / 附加行（译文或下一句）+ 底部播放进度条。
// - 当前句参考 BetterNCM 的 LyricBar：逐字/逐词点亮，唱到的字不透明并上浮 2px。
// - 附加行区分两类：译文用与当前歌词相同的字号与亮度；下一句做虚化（真模糊）。
// - 背景：封面模糊 / 纯色 / 无背景，整层透明度可调；歌词颜色按方案自适应。
// - 超宽时只有「当前句」横向滚动，上一句 / 下一句一律静止。
Widget {
    id: root
    text: ""

    // 不写死 implicitWidth：和官方小组件一样，让主程序按 contentArea 里内容的实际宽度
    // 计算 implicitWidth（BaseWidget: max(header, contentWidth) + 48），宽度变化时会走
    // 主程序自带的那条展开动画 —— 隐藏/恢复后的尺寸才是主程序认得的。
    // 下面的 content 固定 252 宽（252 + 左右 padding 24*2 = 300）。

    // ---- 设置 ----
    property int mainSize: root.settings && root.settings.lyric_font_size !== undefined
                           ? root.settings.lyric_font_size : 13
    property int subSize: root.settings && root.settings.sub_font_size !== undefined
                          ? root.settings.sub_font_size : 10
    property bool autoShow: root.settings && root.settings.auto_show !== undefined
                            ? root.settings.auto_show : true
    property bool showProgress: root.settings && root.settings.show_progress !== undefined
                                ? root.settings.show_progress : true
    property bool allowUnverified: root.settings && root.settings.progress_unverified !== undefined
                                   ? root.settings.progress_unverified : true
    // auto / light / dark / vivid / soft / tinted / accent / duo / theme / white / black / custom
    property string colorMode: root.settings && root.settings.lyric_color !== undefined
                               ? root.settings.lyric_color : "auto"
    property string customColor: root.settings && root.settings.lyric_color_custom !== undefined
                                 ? root.settings.lyric_color_custom : "#ffffff"
    // 背景样式：cover=封面模糊 / solid=纯色 / none=无背景
    property string bgMode: root.settings && root.settings.bg_mode !== undefined
                            ? root.settings.bg_mode : "cover"
    property string bgColorCustom: root.settings && root.settings.bg_color !== undefined
                                   ? root.settings.bg_color : "#1b1e26"
    property int bgBlurAmount: root.settings && root.settings.bg_blur !== undefined
                               ? Math.max(0, Math.min(64, root.settings.bg_blur)) : 32
    // 背景整层透明度（0-100）：100 = 原样，0 = 完全透明（只留歌词）
    property int bgOpacityPct: {
        var v = root.settings ? root.settings.bg_opacity : undefined
        if (v === undefined || v === null)
            v = 100
        return Math.max(0, Math.min(100, v))
    }
    // 切行动画时长（ms）：越大越慢
    property int switchAnimMs: {
        var v = root.settings ? root.settings.switch_anim_ms : undefined
        if (v === undefined || v === null)
            v = 1500
        return Math.max(200, Math.min(4000, v))
    }

    // ---- SMTC 体检 ----
    // 只有确认 SMTC 与歌词渠道是同一首歌，才启用需要 SMTC 的功能（进度条 / 封面背景 / 逐字同步）。
    // 明确"不是同一首歌"时一律停用；状态未知时由"未核验也使用"开关决定。
    // 主程序是先 Loader.Ready、之后才赋 backend 的，创建期 backend 可能是 null，
    // 这里统一判空，避免一堆 "TypeError: Cannot read property" 警告。
    readonly property bool hasBackend: root.backend !== null && root.backend !== undefined
    readonly property bool smtcVerified: root.hasBackend && backend.matchState === "matched"
    readonly property bool smtcUsable: root.smtcVerified
                                       || (root.hasBackend && root.allowUnverified
                                           && backend.matchState === "unknown")
    onSmtcUsableChanged: if (root.hasBackend) backend.smtcGate = root.smtcUsable

    // ---- 背景与配色 ----
    readonly property string coverUrl: backend.coverUrl
    readonly property bool hasCoverBg: root.bgMode === "cover"
                                       && root.smtcUsable && root.coverUrl !== ""
    readonly property bool hasSolidBg: root.bgMode === "solid"
    readonly property bool hasBg: (root.hasCoverBg || root.hasSolidBg) && root.bgOpacityPct > 0
    readonly property real bgAlpha: root.hasBg ? root.bgOpacityPct / 100 : 0
    readonly property color coverColor: backend.coverColor !== "" ? backend.coverColor : "#808080"
    readonly property color solidBgColor: root.bgColorCustom !== "" ? root.bgColorCustom : "#1b1e26"
    // 没有封面时退回主题明暗
    readonly property bool coverLight: root.hasCoverBg ? backend.coverIsLight : !Theme.isDark()

    readonly property real cvH: root.coverColor.hslHue
    readonly property real cvS: root.coverColor.hslSaturation
    readonly property real cvL: root.coverColor.hslLightness

    // 歌词前景色（当前句 / 译文）
    // auto 按「文字实际压着的底色」的亮度选深浅：比只看封面明暗更稳，
    // 否则纯色深底 + 浅色主题时会被 ensureContrast 推成灰色（刚够 4.5:1 但发灰）。
    readonly property color fgColorRaw: {
        switch (root.colorMode) {
        case "auto":   return root.wcagLuminance(root.backdropColor) < 0.42 ? "#FFFFFF" : "#15171c"
        case "light":  return "#FFFFFF"
        case "dark":   return "#15171c"
        case "vivid":  return Qt.hsla(root.cvH, 0.95, root.coverLight ? 0.30 : 0.70, 1.0)
        case "soft":   return Qt.hsla(root.cvH, 0.34, root.coverLight ? 0.24 : 0.86, 1.0)
        case "tinted": return Qt.hsla(root.cvH, 0.55, root.coverLight ? 0.18 : 0.90, 1.0)
        case "accent": return Theme.currentTheme.colors.primaryColor
        case "duo":    return Qt.hsla(root.cvH, 0.92, root.coverLight ? 0.30 : 0.72, 1.0)
        case "white":  return "#FFFFFF"
        case "black":  return "#000000"
        case "custom": return root.customColor
        default:       return Theme.currentTheme.colors.textColor
        }
    }
    // 上一句 / 下一句的颜色：「封面双色」用同色相的柔和版，其余方案与主色一致
    readonly property color subColorRaw: root.colorMode === "duo"
        ? Qt.hsla(root.cvH, 0.36, root.coverLight ? 0.24 : 0.86, 1.0)
        : root.fgColorRaw

    // 压在封面上的遮罩（保证歌词可读）
    readonly property color scrimColor: {
        switch (root.colorMode) {
        case "dark":  return "#FFFFFF"
        case "light": return "#000000"
        case "vivid": return "#000000"
        case "tinted":
            return Qt.hsla(root.cvH, root.coverLight ? 0.20 : 0.45,
                           root.coverLight ? 0.92 : 0.08, 1.0)
        default: return root.coverLight ? "#FFFFFF" : "#000000"
        }
    }
    readonly property real scrimBase: {
        switch (root.colorMode) {
        case "vivid":  return 0.50
        case "soft":   return 0.62
        case "tinted": return 0.68
        case "dark":   return 0.72
        case "light":  return 0.55
        default:       return 0.58
        }
    }
    // 遮罩浓度：只有封面模式用遮罩；整层透明度由 bgAlpha 统一负责
    readonly property real scrimOpacity: root.hasCoverBg ? root.scrimBase : 0

    // ── 背景自适应配色（WCAG 2.1 对比度）──────────────────────────────
    // 依据：正文文字对比度 ≥ 4.5:1，大字号与 UI 组件 ≥ 3:1，按相对亮度计算。
    function wcagLin(c) {
        return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4)
    }
    function wcagLuminance(c) {
        return 0.2126 * wcagLin(c.r) + 0.7152 * wcagLin(c.g) + 0.0722 * wcagLin(c.b)
    }
    function wcagContrast(a, b) {
        var la = wcagLuminance(a), lb = wcagLuminance(b)
        var hi = Math.max(la, lb), lo = Math.min(la, lb)
        return (hi + 0.05) / (lo + 0.05)
    }

    // 主题卡片底色：插件背景层是半透明时，文字实际压着的是「主题卡片 + 本层」的混合色
    // 注意 RinUI 的键名是 backgroundColor（没有 background 这个键）
    readonly property color themeBackdrop: Theme.currentTheme.colors.backgroundColor

    // 本层背景不透明时的颜色：封面 + 遮罩，或纯色
    readonly property color layerColor: {
        if (root.hasCoverBg) {
            var c = root.coverColor
            var a = Math.max(0.0, Math.min(1.0, root.scrimOpacity))
            var s = root.coverLight ? 1.0 : 0.0
            return Qt.rgba(c.r * (1 - a) + s * a,
                           c.g * (1 - a) + s * a,
                           c.b * (1 - a) + s * a, 1)
        }
        if (root.hasSolidBg)
            return root.solidBgColor
        return root.themeBackdrop
    }

    // 文字与进度条实际压着的底色：本层按透明度叠在主题卡片上
    readonly property color backdropColor: {
        if (!root.hasBg)
            return root.themeBackdrop
        var b = root.themeBackdrop
        var l = root.layerColor
        var a = root.bgAlpha
        return Qt.rgba(l.r * a + b.r * (1 - a),
                       l.g * a + b.g * (1 - a),
                       l.b * a + b.b * (1 - a), 1)
    }

    // 保证对比度：先用给定色，不达标就朝黑/白推进，取第一个达标的
    function ensureContrast(base, backdrop, need) {
        if (wcagContrast(base, backdrop) >= need) return base
        // 两端都算，取能拿到更高对比度的那一端：
        // 中灰背景（亮度约 0.2~0.45）用阈值判断会选错方向，
        // 例如 #858585 对白仅 3.6:1、对黑却有 5.8:1。
        var toBlack = wcagContrast(Qt.rgba(0, 0, 0, 1), backdrop)
        var toWhite = wcagContrast(Qt.rgba(1, 1, 1, 1), backdrop)
        var t = toBlack >= toWhite ? Qt.rgba(0, 0, 0, 1) : Qt.rgba(1, 1, 1, 1)
        for (var i = 1; i <= 20; i++) {
            var k = i / 20
            var c = Qt.rgba(base.r + (t.r - base.r) * k,
                            base.g + (t.g - base.g) * k,
                            base.b + (t.b - base.b) * k, 1)
            if (wcagContrast(c, backdrop) >= need) return c
        }
        return t
    }

    // 进度条颜色：跟随封面主色相，但按 UI 组件标准保证 ≥ 3:1
    readonly property color barColor: {
        if (!root.hasBg)
            return Theme.currentTheme.colors.primaryColor
        var base = root.hasCoverBg
                ? Qt.hsla(root.cvH, root.coverLight ? 0.55 : 0.85,
                          root.coverLight ? 0.32 : 0.74, 1.0)
                : Theme.currentTheme.colors.primaryColor
        return root.ensureContrast(base, root.backdropColor, 3.0)
    }

    // 歌词文字：各档配色先取"原始色"，再按正文标准保证 ≥ 4.5:1
    // 于是鲜艳 / 柔和 / 偏色等档位既能保留色相，又不会糊在背景里
    readonly property color fgColor: root.hasBg
        ? root.ensureContrast(root.fgColorRaw, root.backdropColor, 4.5)
        : root.fgColorRaw
    readonly property color subColor: root.hasBg
        ? root.ensureContrast(root.subColorRaw, root.backdropColor, 4.5)
        : root.subColorRaw

    // karaoke 参数（对齐 LyricBar）
    readonly property real unlitOpacity: 0.34
    readonly property real idleOpacity: 0.42
    readonly property real nextOpacity: 0.55
    readonly property real liftY: -2
    readonly property int karaokeFade: 200
    readonly property real nextBlur: 0.75

    // 自适应：按上一句的实际长度定速，并提前约 1 秒播放完
    readonly property int karaokeDuration: backend.lineDuration > 0
                                           ? Math.max(1200, backend.lineDuration - 1000)
                                           : 4000

    // 逐字高亮：默认开；关掉则当前行整行满亮度
    property bool karaokeOn: root.settings && root.settings.karaoke_enabled !== undefined
                             ? root.settings.karaoke_enabled : true

    property bool hasLyrics: backend.hasLyrics
    // 显隐只看「歌词渠道是否已经推来歌词」；SMTC 的歌名/封面/播放状态都不参与
    property bool showable: root.hasBackend && backend.showable

    // 分词：CJK 每字一个 token，西文按词，空白单独保留
    function tokenize(s) {
        if (!s)
            return []
        var re = /[\u4e00-\u9fff\u3400-\u4dbf\u3040-\u30ff\uac00-\ud7af]|[^\s\u4e00-\u9fff\u3400-\u4dbf\u3040-\u30ff\uac00-\ud7af]+|\s+/g
        return s.match(re) || []
    }


    // 灵动显隐：只看歌词渠道是否已经推来歌词。
    // SMTC 的歌名 / 封面 / 播放状态，以及桥接用的「歌名 + 歌手」推送都不参与判定，
    // 所以非传统渠道（例如浏览器视频）被 SMTC 识别时不会把组件"弹"出来。
    readonly property bool shouldShow: editMode
        || (root.autoShow && root.showable)
    property bool actualVisible: true
    // 已知在暂停 / 已停止：**只用于让逐行歌词动画跟着停住**（避免高亮跑偏），
    // 与组件的显隐判断无关 —— 显隐只看歌词有无，不看播放状态。
    readonly property bool playbackStalled: backend.playbackKnown && backend.playbackPaused

    function updateVisibility() {
        if (shouldShow) {
            // 以动画本身作为状态判断，而不是 actualVisible：
            // exitAnim 还没播完时 actualVisible 仍是 true，旧代码这时不会重启
            // enterAnim，等 exitAnim 结束把 opacity 留在 0 —— 就会"可见但全透明"。
            if (enterAnim.running)
                return
            actualVisible = true
            exitAnim.stop()
            enterAnim.restart()
        } else {
            if (exitAnim.running)
                return
            enterAnim.stop()
            exitAnim.restart()
        }
    }
    onShouldShowChanged: updateVisibility()

    Component.onCompleted: {
        if (root.backend)
            backend.smtcGate = root.smtcUsable
        actualVisible = shouldShow
    }

    // 显隐完全对齐官方 Widget 的「灵动隐藏」写法（src/qml/widgets/dynamicNotification.qml）：
    // 隐藏时把宽度切成 0、动画播完才 actualVisible=false。主程序靠这个宽度变化维护布局
    // 与窗口区域；之前改成"宽度恒定、只切 visible"，真机上就出现背景左侧一块区域整块
    // 不绘制（点一下、触发重新布局才恢复）的问题。
    width: (actualVisible ? implicitWidth : 0) + (root.maskNudge ? 0.05 : 0)
    height: (root.miniMode ? 56 : 100) + (root.maskNudge ? 0.05 : 0)
    visible: actualVisible

    // 主程序用 root_window.setMask(QRegion) 裁剪组件窗口（core/widgets/core.py: update_mask）：
    // mask 只在"布局变化"时重算，而且取的是 delegate 的当前宽度（=naturalWidth*growFactor）。
    // 自动弹出时 delegate 的 growFactor 用 420ms 动画展开，动画期间算出的 mask 是中间值，
    // 动画结束后没有任何几何变化再去通知它 → mask 一直停在中间尺寸，
    // 组件边缘就被窗口 region 裁掉一条（鼠标点一下触发重新布局才恢复）。
    // 这里在入场动画结束后抖两次尺寸（0.05px，肉眼不可见），逼主程序按最终布局重算 mask。
    property bool maskNudge: false
    Timer {
        id: nudgeOffTimer
        interval: 40
        repeat: false
        onTriggered: root.maskNudge = false
    }
    Timer {
        id: nudgeFirstTimer
        interval: 520
        repeat: false
        onTriggered: {
            root.maskNudge = true
            nudgeOffTimer.restart()
            nudgeSecondTimer.restart()
        }
    }
    Timer {
        id: nudgeSecondTimer
        interval: 760
        repeat: false
        onTriggered: {
            root.maskNudge = true
            nudgeOffTimer.restart()
        }
    }

    // 入场：先用 1ms 把 opacity 压到 0，再淡入 + popBack 放大（官方写法，避免闪现）
    SequentialAnimation {
        id: enterAnim
        NumberAnimation { target: root; property: "opacity"; from: 0; to: 0; duration: 1 }
        ParallelAnimation {
            NumberAnimation { target: root; property: "opacity"; from: 0; to: 1; duration: 300; easing.type: Easing.OutCubic }
            NumberAnimation { target: root; property: "scale"; from: 0.8; to: 1; duration: 400; easing.type: Easing.OutBack }
        }
        onFinished: {
            actualVisible = shouldShow
            if (actualVisible)
                nudgeFirstTimer.restart()   // 入场结束后让主程序重算一次窗口 mask
        }
    }
    // 消失：同样先压 1ms，再淡出 + 缩小
    SequentialAnimation {
        id: exitAnim
        NumberAnimation { target: root; property: "opacity"; from: 0; to: 0; duration: 1 }
        ParallelAnimation {
            NumberAnimation { target: root; property: "opacity"; from: 1; to: 0; duration: 200; easing.type: Easing.InQuad }
            NumberAnimation { target: root; property: "scale"; from: 1; to: 0.9; duration: 250; easing.type: Easing.InQuad }
        }
        onFinished: {
            if (shouldShow) {
                // 消失还没播完又该显示了：直接接回入场，否则会停在 opacity=0（可见但全透明）
                enterAnim.restart()
                return
            }
            actualVisible = false
        }
    }

    // ---- 背景 ----
    // 背景放在主程序的 backgroundArea 槽位里（与主题卡片同一层）。
    // 封面模糊用"低分辨率解码 + 平滑放大"（不走 FastBlur），外面只包一层 OpacityMask 做圆角。
    backgroundArea: Item {
        anchors.fill: parent
        visible: root.hasBg
        // 整个背景层（封面/纯色 + 遮罩）一起变透明，正常显示状态下始终生效
        opacity: root.bgAlpha

        // —— 封面模糊 ——
        Item {
            id: coverItem
            anchors.fill: parent
            visible: root.hasCoverBg

            Image {
                id: coverSrc
                anchors.fill: parent
                source: root.hasCoverBg ? root.coverUrl : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: false
                visible: false
                smooth: true
                // bgBlurAmount 0..64 → 解码分辨率 300..100，越小越糊
                sourceSize.width: Math.max(16, Math.round(300 * 32 / (root.bgBlurAmount + 32)))
                sourceSize.height: Math.max(16, Math.round(300 * 32 / (root.bgBlurAmount + 32)))
            }

            // 圆角遮罩源
            Item {
                id: coverMask
                anchors.fill: parent
                visible: false
                Rectangle {
                    anchors.fill: parent
                    radius: root.cornerRadius
                    color: "white"
                }
            }

            OpacityMask {
                id: maskEffect
                anchors.fill: parent
                source: coverSrc
                maskSource: coverMask
            }

            // 可读性遮罩
            Rectangle {
                id: scrimRect
                anchors.fill: parent
                radius: root.cornerRadius
                color: root.scrimColor
                opacity: root.scrimOpacity
            }
        }

        // —— 纯色背景 ——
        Rectangle {
            anchors.fill: parent
            radius: root.cornerRadius
            color: root.solidBgColor
            visible: root.hasSolidBg
        }
    }

    // ---- 主体 ----
    Item {
        id: content
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.miniMode ? -4 : -12
        x: 0
        width: 252
        visible: root.hasLyrics

        readonly property int visibleRows: root.miniMode ? 1 : 3
        readonly property real rowH: Math.max(12, lyricView.height / visibleRows)

        Quick.ListView {
            id: lyricView
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: progressBar.top
            anchors.bottomMargin: 4
            clip: true
            cacheBuffer: content.rowH * 6
            model: backend.lyricModel
            currentIndex: backend.currentIndex

            // 自己控制纵向位置：ListView 默认的 snap 动画只有 ~100ms（表现为"上浮过快"），
            // 这里改成用 switchAnimMs 驱动的 contentY 动画，时长可调。
            highlightRangeMode: Quick.ListView.NoHighlightRange
            snapMode: Quick.ListView.NoSnap
            boundsBehavior: Quick.Flickable.StopAtBounds
            interactive: false

            // 当前句居中所需的位置（受 contentHeight 限制，首尾行会贴边）
            function targetY() {
                var rh = content.rowH
                var y = Math.max(0, currentIndex) * rh - (height - rh) / 2
                var maxY = Math.max(0, contentHeight - height)
                return Math.max(0, Math.min(maxY, y))
            }
            function syncPosition(animated) {
                var y = targetY()
                if (!animated || root.switchAnimMs <= 0) {
                    posAnim.stop()
                    if (Math.abs(contentY - y) >= 0.5)
                        contentY = y
                    return
                }
                if (posAnim.running) {
                    // 目标没变（换行时模型增删行造成的微调）→ 让它自己走完，绝不 restart
                    if (Math.abs(posAnim.to - y) < 0.5)
                        return
                    // 目标真的变了：从当前位置续走，按剩余距离缩短时长（不重置整段缓动）
                    var dist = Math.abs(y - contentY)
                    posAnim.stop()
                    posAnim.from = contentY
                    posAnim.to = y
                    posAnim.duration = Math.max(180,
                                                root.switchAnimMs * Math.min(1, dist / Math.max(1, content.rowH)))
                    posAnim.start()
                } else if (Math.abs(y - contentY) >= 0.5) {
                    posAnim.stop()
                    posAnim.from = contentY
                    posAnim.to = y
                    posAnim.duration = root.switchAnimMs
                    posAnim.start()
                }
            }
            // 用 NumberAnimation + OutCubic 驱动 contentY：换行那一帧就立刻有位移。
            // （之前用 SmoothedAnimation 是"慢慢加速"的曲线，前 ~150ms 几乎不动，
            //  而歌词文字在模型更新那一帧就已经换好了 → 看起来就是"先闪一下再开始滑"。）
            NumberAnimation {
                id: posAnim
                target: lyricView
                property: "contentY"
                duration: root.switchAnimMs
                easing.type: Easing.OutCubic
            }
            onCurrentIndexChanged: syncPosition(true)
            onContentHeightChanged: syncPosition(true)
            onHeightChanged: syncPosition(false)
            Component.onCompleted: contentY = targetY()

            delegate: Item {
                id: cell
                width: lyricView.width
                height: content.rowH
                // 不在行内裁剪：行高（可视区/3）常常比字号的行高略小，
                // 行内 clip 会把当前句的上下笔画（尤其西文降部）切掉一小截。
                // 横向越界交给 ListView 自己的 clip：ListView 宽度 == 行宽，效果一致。
                clip: false

                // 行类型（来自模型）
                readonly property string kind: (rowKind !== undefined) ? rowKind : "line"
                readonly property string ekind: (extraKind !== undefined) ? extraKind : ""
                readonly property bool isCur: Quick.ListView.isCurrentItem && cell.kind === "line"
                readonly property bool isTrans: cell.kind === "extra" && cell.ekind === "trans"
                readonly property bool isNext: cell.kind === "extra" && cell.ekind === "next"
                // 译文与当前歌词同字号；其余用副字号
                readonly property int baseFs: (cell.isCur || cell.isTrans) ? root.mainSize : root.subSize
                readonly property var tokens: root.tokenize((lineText !== undefined) ? lineText : "")
                readonly property int tokenCount: tokens.length
                // 用 TextMetrics 按「未缩放的字号」实测宽度，而不是读 tokenRow 的布局宽度：
                // 布局宽度会滞后于字号变化（字号改了判定不动，要硬超出很多才滚动）。
                // 非当前句（上一句 / 下一句）超宽时按比例缩小字号，让长句也能「横向完整显示」；
                // 当前句保持原字号并横向滚动（需求：只有主歌词滚动）。
                // 这里用 baseW（未缩放宽度）算比例，避免和 fs 互相引用。
                readonly property real baseW: textMetrics.advanceWidth
                readonly property real fitScale: (!cell.isCur && cell.baseW > cell.width - 2)
                                                 ? Math.max(0.5, (cell.width - 2) / cell.baseW) : 1
                readonly property int fs: Math.max(6, Math.round(cell.baseFs * cell.fitScale))
                // 实际渲染宽度 ≈ 基准宽度 × 字号比例（缩小后不能再拿未缩放的宽度判溢出）
                readonly property real measuredW: cell.baseW * (cell.fs / Math.max(1, cell.baseFs))
                readonly property real textW: Math.max(tokenRow.width, measuredW)
                TextMetrics {
                    id: textMetrics
                    font.pixelSize: cell.baseFs
                    font.weight: Font.DemiBold
                    text: cell.tokens.join("")
                }
                readonly property bool overflow: cell.textW > cell.width
                // 只有「当前句」超宽时才横向滚动；上一句 / 下一句一律静止
                readonly property bool canScroll: cell.isCur && cell.overflow
                readonly property real scrollTarget: cell.width - cell.textW
                // 横向滚动的阅读速度（像素/秒），并尽量在本句剩余时间里滚完
                readonly property real scrollSpeed: 46
                property real litCount: 0

                Item {
                    id: lineRoot
                    y: 0
                    height: cell.height
                    width: Math.max(cell.textW, 1)
                    scale: cell.isCur ? 1.0 : 0.9
                    transformOrigin: Item.Center

                    // 缩放只在换行开头快速收/放一下，剩下的时间只有整列滑动 ——
                    // 之前和滑动同长会让「字在变大/变小的同时整列在移动」，看着发飘
                    Behavior on scale {
                        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
                    }

                    Row {
                        id: tokenRow
                        y: 0
                        height: cell.height
                        spacing: 0

                        Repeater {
                            id: tokenRepeater
                            model: cell.tokens
                            delegate: Quick.Text {
                                text: modelData
                                height: cell.height
                                verticalAlignment: Quick.Text.AlignVCenter
                                font.pixelSize: cell.fs
                                font.weight: Font.DemiBold
                                color: (cell.isCur || cell.isTrans) ? root.fgColor : root.subColor
                                opacity: cell.isCur
                                         ? ((!root.karaokeOn || index < cell.litCount) ? 1.0 : root.unlitOpacity)
                                         : cell.isTrans ? 1.0
                                         : cell.isNext ? root.nextOpacity
                                         : root.idleOpacity
                                y: (cell.isCur && root.karaokeOn && index < cell.litCount) ? root.liftY : 0

                                Behavior on opacity {
                                    NumberAnimation { duration: root.karaokeFade; easing.type: Easing.OutQuad }
                                }
                                Behavior on y {
                                    NumberAnimation { duration: root.karaokeFade; easing.type: Easing.OutQuad }
                                }
                            }
                        }

                        // 下一句：虚化（整行模糊）
                        layer.enabled: cell.isNext
                        layer.effect: MultiEffect {
                            blurEnabled: true
                            blur: root.nextBlur
                            blurMax: 24
                            autoPaddingEnabled: true
                        }
                    }
                }

                NumberAnimation {
                    id: karaoke
                    target: cell
                    property: "litCount"
                    from: 0
                    to: cell.tokenCount
                    duration: root.karaokeDuration
                    easing.type: Easing.Linear
                }

                function startKaraoke() {
                    karaoke.stop()
                    karaoke.paused = false
                    cell.litCount = 0
                    if (cell.isCur && cell.tokenCount > 0 && root.karaokeOn)
                        cell.syncKaraoke()
                }

                // 混合驱动：优先用 SMTC 的真实播放位置对齐；
                // 后端约每 500ms 刷新一次进度，每次都重新校准，
                // 于是"读到的字"与播放同步进退，暂停时定格。
                function syncKaraoke() {
                    if (!(cell.isCur && root.karaokeOn && cell.tokenCount > 0))
                        return
                    var p = backend.lineProgress
                    if (p < 0) {
                        // 没有可用的 SMTC 进度：退回按上一句节奏估算。
                        // 已读完就不再重播（否则每个心跳都会从头高亮）。
                        if (cell.litCount >= cell.tokenCount - 0.001)
                            return
                        if (!karaoke.running) {
                            karaoke.from = 0
                            karaoke.to = cell.tokenCount
                            karaoke.duration = root.karaokeDuration
                            karaoke.start()
                        }
                        // 估算动画也要跟着播放状态走：暂停即定格，继续播放再接上
                        if (backend.playbackPaused) {
                            if (!karaoke.paused)
                                karaoke.pause()
                        } else if (karaoke.paused) {
                            karaoke.resume()
                        }
                        return
                    }
                    karaoke.stop()
                    cell.litCount = p * cell.tokenCount
                    if (!backend.linePlaying)
                        return                              // 暂停：定格在真实进度
                    karaoke.from = cell.litCount
                    karaoke.to = cell.tokenCount
                    karaoke.duration = Math.max(250, backend.lineRemainMs)
                    karaoke.start()
                }

                // 横向滚动：匀速向左，播完就停住（不循环）
                SequentialAnimation {
                    id: marquee
                    PauseAnimation { duration: 600 }
                    NumberAnimation {
                        id: scrollAnim
                        target: lineRoot
                        property: "x"
                        from: 0
                        to: cell.scrollTarget
                        easing.type: Easing.Linear
                    }
                }

                // 播放暂停 / 停止时让滚动与逐字动画一起停住，恢复播放再接上
                function syncPlayback() {
                    if (!marquee.running)
                        return
                    if (root.playbackStalled) {
                        if (marquee.running && !marquee.paused)
                            marquee.pause()
                    } else if (marquee.paused) {
                        marquee.resume()
                    }
                }

                // 位置判定：不滚动时按可用宽度居中；需要滚动时只启动一次，
                // 已经在滚且目标没变就不打断（否则每次属性刷新都会被打回起点）。
                function place() {
                    if (!cell.canScroll) {
                        // 正在滚的下场：刚失去「当前句」身份的行停在原地，不要跳回起点/居中，
                        // 否则换行瞬间这行文字会"啪"地平移一下（本句切到下一句一卡一卡的来源之一）
                        if (marquee.running || marquee.paused) {
                            marquee.stop()
                            return
                        }
                        lineRoot.x = cell.overflow ? 0 : Math.max(0, (cell.width - cell.textW) / 2)
                        return
                    }
                    if ((marquee.running || marquee.paused)
                            && Math.abs(scrollAnim.to - cell.scrollTarget) < 0.5) {
                        syncPlayback()
                        return
                    }
                    marquee.stop()
                    lineRoot.x = 0
                    var dist = Math.max(1, -cell.scrollTarget)
                    var ms = Math.max(1000, Math.min(9000, dist / cell.scrollSpeed * 1000))
                    var remain = backend.lineRemainMs
                    if (remain > 600)
                        ms = Math.max(700, Math.min(ms, remain - 250))
                    scrollAnim.duration = ms
                    marquee.start()
                    if (root.playbackStalled)
                        marquee.pause()
                }

                function syncAnim() {
                    syncPlayback()
                    syncKaraoke()
                }

                // 后端每次刷新进度就校准一次
                Connections {
                    target: backend
                    function onProgressTick() {
                        cell.syncAnim()
                    }
                }

                onTokenCountChanged: {
                    place()
                    startKaraoke()
                }
                onTextWChanged: place()
                onWidthChanged: place()
                onFsChanged: place()
                onMeasuredWChanged: place()
                onOverflowChanged: place()
                onCanScrollChanged: place()
                onIsCurChanged: {
                    place()
                    startKaraoke()
                }
                Component.onCompleted: {
                    place()
                    startKaraoke()
                }
            }
        }

        // 播放进度条：钉在组件最底部
        ProgressBar {
            id: progressBar
            // SMTC 可用就用 SMTC 进度；否则用歌词渠道自带的进度（若有）
            visible: root.showProgress && backend.hasProgress
                     && (root.smtcUsable || backend.lyricProgressAvailable)
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 4
            value: backend.progress
            primaryColor: root.barColor

            Behavior on value {
                NumberAnimation { duration: 400; easing.type: Easing.Linear }
            }
        }
    }

    // 等待提示：只在插件刚加载、还没收到任何歌词、且尚未判定「无歌词」时短暂显示；
    // 一旦判定无词就整体隐藏，等传统歌词渠道真的推来歌词再恢复。
    Quick.Text {
        anchors.centerIn: parent
        // 固定宽度：主程序是按 contentArea 里内容的实际宽度算 implicitWidth 的。
        // 等歌词阶段只有这个提示可见，若把 width 绑成 parent.width（= widget 宽 - 48）
        // 就变成自引用，宽度会塌成很小 → 提示文字被挤成一字一行竖排。
        // 这里固定成和 content 一样的 252（+ 左右 padding 24*2 = 300）。
        width: 252
        visible: !root.hasLyrics && root.showable
        text: qsTr("等待音乐软件侧传输歌词...")
        horizontalAlignment: Quick.Text.AlignHCenter
        wrapMode: Quick.Text.NoWrap
        elide: Quick.Text.ElideRight
        color: root.hasBg ? root.fgColor : Theme.currentTheme.colors.textSecondaryColor
        font.pixelSize: 13
    }
}
