import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import RinUI
import ClassWidgets.Plugins

SettingsLayout {
    id: root

    // 主歌词字号（px）
    property int mainSizeValue: 13
    onMainSizeValueChanged: settings.lyric_font_size = mainSizeValue

    // 上一句 / 下一句字号（px）
    property int subSizeValue: 10
    onSubSizeValueChanged: settings.sub_font_size = subSizeValue

    // 配色方案：auto / light / dark / vivid / soft / tinted / accent / duo / theme / white / black / custom
    property string colorModeValue: "auto"
    onColorModeValueChanged: settings.lyric_color = colorModeValue

    // 自定义颜色（#RRGGBB）
    property string customColorValue: "#ffffff"
    onCustomColorValueChanged: settings.lyric_color_custom = customColorValue

    // 背景样式：cover=封面模糊 / solid=纯色 / none=无背景
    property string bgModeValue: "cover"
    onBgModeValueChanged: settings.bg_mode = bgModeValue

    // 纯色背景颜色（#RRGGBB）
    property string bgColorValue: "#1b1e26"
    onBgColorValueChanged: settings.bg_color = bgColorValue

    // 封面模糊强度（px）
    property int bgBlurValue: 32
    onBgBlurValueChanged: settings.bg_blur = bgBlurValue

    // 背景不透明度（%）：100 = 原样，0 = 完全透明（只留歌词）
    property int bgOpacityValue: 100
    onBgOpacityValueChanged: settings.bg_opacity = bgOpacityValue

    // 切行动画时长（ms）
    property int switchAnimValue: 1500
    onSwitchAnimValueChanged: settings.switch_anim_ms = switchAnimValue

    property bool showProgressValue: true
    onShowProgressValueChanged: settings.show_progress = showProgressValue

    // 逐字高亮
    property bool karaokeValue: true
    onKaraokeValueChanged: settings.karaoke_enabled = karaokeValue

    // 歌词弹出显示
    property bool autoShowValue: true
    onAutoShowValueChanged: settings.auto_show = autoShowValue

    // 未核验时也显示进度
    property bool allowUnverifiedValue: false
    onAllowUnverifiedValueChanged: settings.progress_unverified = allowUnverifiedValue

    Component.onCompleted: {
        mainSizeValue = settings.lyric_font_size !== undefined ? settings.lyric_font_size : 13
        subSizeValue = settings.sub_font_size !== undefined ? settings.sub_font_size : 10
        colorModeValue = settings.lyric_color !== undefined ? settings.lyric_color : "auto"
        customColorValue = settings.lyric_color_custom !== undefined ? settings.lyric_color_custom : "#ffffff"
        bgModeValue = settings.bg_mode !== undefined ? settings.bg_mode : "cover"
        bgColorValue = settings.bg_color !== undefined ? settings.bg_color : "#1b1e26"
        bgBlurValue = settings.bg_blur !== undefined ? settings.bg_blur : 32
        bgOpacityValue = settings.bg_opacity !== undefined ? settings.bg_opacity : 100
        switchAnimValue = settings.switch_anim_ms !== undefined ? settings.switch_anim_ms : 1500
        showProgressValue = settings.show_progress !== undefined ? settings.show_progress : true
        autoShowValue = settings.auto_show !== undefined ? settings.auto_show : true
        allowUnverifiedValue = settings.progress_unverified !== undefined ? settings.progress_unverified : false
        karaokeValue = settings.karaoke_enabled !== undefined ? settings.karaoke_enabled : true
    }

    SettingCard {
        Layout.fillWidth: true
        title: "组件背景"
        description: "背景样式可选封面模糊 / 纯色 / 无背景；下面的不透明度对这一整层背景生效，正常显示时一直有效。"

        // SettingCard 只接受一个内容子项：多个控件必须包进同一个 ColumnLayout，
        // 否则第二个子项会顶掉第一个，表现为整张卡都调不动。
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 8

            RowLayout {
                spacing: 12
                RadioButton {
                    text: "封面模糊"
                    checked: root.bgModeValue === "cover"
                    onCheckedChanged: if (checked) root.bgModeValue = "cover"
                }
                RadioButton {
                    text: "纯色"
                    checked: root.bgModeValue === "solid"
                    onCheckedChanged: if (checked) root.bgModeValue = "solid"
                }
                RadioButton {
                    text: "无背景"
                    checked: root.bgModeValue === "none"
                    onCheckedChanged: if (checked) root.bgModeValue = "none"
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                visible: root.bgModeValue === "cover"
                Text {
                    Layout.fillWidth: true
                    text: qsTr("封面模糊强度")
                }
                Button {
                    text: "−"
                    implicitWidth: 36
                    onClicked: bgBlurValue = Math.max(0, bgBlurValue - 4)
                }
                Text {
                    Layout.preferredWidth: 56
                    horizontalAlignment: Text.AlignHCenter
                    text: bgBlurValue + " px"
                }
                Button {
                    text: "+"
                    implicitWidth: 36
                    onClicked: bgBlurValue = Math.min(64, bgBlurValue + 4)
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                visible: root.bgModeValue === "solid"
                Text {
                    Layout.fillWidth: true
                    text: qsTr("背景颜色")
                }
                Rectangle {
                    width: 28
                    height: 28
                    radius: 6
                    border.width: 1
                    border.color: "#888888"
                    color: root.bgColorValue
                }
                TextField {
                    id: bgColorField
                    Layout.preferredWidth: 140
                    placeholderText: "#RRGGBB"
                    text: root.bgColorValue
                    selectByMouse: true
                    onEditingFinished: {
                        var v = text.trim()
                        if (v.charAt(0) !== "#")
                            v = "#" + v
                        root.bgColorValue = v
                    }
                }
                Repeater {
                    model: ["#1b1e26", "#000000", "#ffffff", "#2b1d2e", "#0f2231", "#1f2a1c"]
                    delegate: Rectangle {
                        width: 22
                        height: 22
                        radius: 4
                        border.width: 1
                        border.color: "#888888"
                        color: modelData
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                root.bgColorValue = modelData
                                bgColorField.text = modelData
                            }
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Text {
                    Layout.fillWidth: true
                    text: qsTr("背景不透明度")
                }
                Button {
                    text: "−"
                    implicitWidth: 36
                    onClicked: bgOpacityValue = Math.max(0, bgOpacityValue - 5)
                }
                Text {
                    Layout.preferredWidth: 56
                    horizontalAlignment: Text.AlignHCenter
                    text: bgOpacityValue + "%"
                }
                Button {
                    text: "+"
                    implicitWidth: 36
                    onClicked: bgOpacityValue = Math.min(100, bgOpacityValue + 5)
                }
            }
        }
    }

    SettingCard {
        Layout.fillWidth: true
        title: "主歌词字号"
        description: "当前这一句歌词的字号（px）。"

        RowLayout {
            spacing: 8
            Button {
                text: "−"
                implicitWidth: 36
                onClicked: mainSizeValue = Math.max(8, mainSizeValue - 1)
            }
            Text {
                Layout.preferredWidth: 80
                horizontalAlignment: Text.AlignHCenter
                text: mainSizeValue + " px"
            }
            Button {
                text: "+"
                implicitWidth: 36
                onClicked: mainSizeValue = Math.min(40, mainSizeValue + 1)
            }
        }
    }

    SettingCard {
        Layout.fillWidth: true
        title: "上/下一句字号"
        description: "上一句、下一句歌词的字号（px），通常比主歌词小。"

        RowLayout {
            spacing: 8
            Button {
                text: "−"
                implicitWidth: 36
                onClicked: subSizeValue = Math.max(6, subSizeValue - 1)
            }
            Text {
                Layout.preferredWidth: 80
                horizontalAlignment: Text.AlignHCenter
                text: subSizeValue + " px"
            }
            Button {
                text: "+"
                implicitWidth: 36
                onClicked: subSizeValue = Math.min(40, subSizeValue + 1)
            }
        }
    }

    SettingCard {
        Layout.fillWidth: true
        title: "歌词配色方案"
        description: "「自适应 / 鲜艳 / 柔和 / 偏色 / 主题强调色 / 封面双色」都跟随封面的主色调与明暗，并按 WCAG 对比度自动保证可读性；" +
                     "「封面双色」让当前句用鲜艳的封面色、上/下一句用同色相的柔和色。"

        ColumnLayout {
            spacing: 10
            Layout.fillWidth: true

            RowLayout {
                spacing: 12
                RadioButton {
                    text: "自适应"
                    checked: root.colorModeValue === "auto"
                    onCheckedChanged: if (checked) root.colorModeValue = "auto"
                }
                RadioButton {
                    text: "深色"
                    checked: root.colorModeValue === "dark"
                    onCheckedChanged: if (checked) root.colorModeValue = "dark"
                }
                RadioButton {
                    text: "浅色"
                    checked: root.colorModeValue === "light"
                    onCheckedChanged: if (checked) root.colorModeValue = "light"
                }
            }

            RowLayout {
                spacing: 12
                RadioButton {
                    text: "鲜艳"
                    checked: root.colorModeValue === "vivid"
                    onCheckedChanged: if (checked) root.colorModeValue = "vivid"
                }
                RadioButton {
                    text: "柔和"
                    checked: root.colorModeValue === "soft"
                    onCheckedChanged: if (checked) root.colorModeValue = "soft"
                }
                RadioButton {
                    text: "偏色"
                    checked: root.colorModeValue === "tinted"
                    onCheckedChanged: if (checked) root.colorModeValue = "tinted"
                }
            }

            RowLayout {
                spacing: 12
                RadioButton {
                    text: "主题强调色"
                    checked: root.colorModeValue === "accent"
                    onCheckedChanged: if (checked) root.colorModeValue = "accent"
                }
                RadioButton {
                    text: "封面双色"
                    checked: root.colorModeValue === "duo"
                    onCheckedChanged: if (checked) root.colorModeValue = "duo"
                }
                RadioButton {
                    text: "跟随主题"
                    checked: root.colorModeValue === "theme"
                    onCheckedChanged: if (checked) root.colorModeValue = "theme"
                }
            }

            RowLayout {
                spacing: 12
                RadioButton {
                    text: "自定义"
                    checked: root.colorModeValue === "custom"
                    onCheckedChanged: if (checked) root.colorModeValue = "custom"
                }
            }

            RowLayout {
                spacing: 10

                Rectangle {
                    width: 28
                    height: 28
                    radius: 6
                    border.width: 1
                    border.color: "#888888"
                    color: root.customColorValue
                }

                TextField {
                    id: colorField
                    Layout.preferredWidth: 140
                    placeholderText: "#RRGGBB"
                    text: root.customColorValue
                    selectByMouse: true
                    onEditingFinished: {
                        var v = text.trim()
                        if (v.charAt(0) !== "#")
                            v = "#" + v
                        root.customColorValue = v
                    }
                }

                // 常用预设色
                Repeater {
                    model: ["#ffffff", "#000000", "#ffd400", "#ff5c8a", "#46cea3", "#4aa3ff"]
                    delegate: Rectangle {
                        width: 22
                        height: 22
                        radius: 4
                        border.width: 1
                        border.color: "#888888"
                        color: modelData
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                root.customColorValue = modelData
                                root.colorModeValue = "custom"
                                colorField.text = modelData
                            }
                        }
                    }
                }
            }
        }
    }

    SettingCard {
        Layout.fillWidth: true
        title: "切行动画时长"
        description: "歌词换到下一句时，整列文字向上移动所用的时间；数值越大越慢、越柔和。"

        RowLayout {
            spacing: 8
            Button {
                text: "−"
                implicitWidth: 36
                onClicked: switchAnimValue = Math.max(400, switchAnimValue - 100)
            }
            Text {
                Layout.preferredWidth: 80
                horizontalAlignment: Text.AlignHCenter
                text: switchAnimValue + " ms"
            }
            Button {
                text: "+"
                implicitWidth: 36
                onClicked: switchAnimValue = Math.min(3000, switchAnimValue + 100)
            }
        }
    }

    SettingCard {
        Layout.fillWidth: true
        title: "显示播放进度条"
        description: "在歌词下方显示播放进度条；拿不到歌曲进度时会自动隐藏。"

        Switch {
            checked: root.showProgressValue
            onCheckedChanged: root.showProgressValue = checked
        }
    }

    SettingCard {
        Layout.fillWidth: true
        title: "未核验时也使用 SMTC 功能"
        description: "默认关闭：只要没确认 SMTC 与歌词是同一首歌，就停用播放进度条、封面背景、" +
                     "以及逐字同步（改为按节奏估算），并释放封面等占用，只保留歌词自身能提供的效果。" +
                     "打开后会退回到「没确认也用」的旧行为。"

        Switch {
            checked: root.allowUnverifiedValue
            onCheckedChanged: root.allowUnverifiedValue = checked
        }
    }

    SettingCard {
        Layout.fillWidth: true
        title: "逐字高亮（读到哪儿亮到哪儿）"
        description: "仅为动画效果：速度按上一句的节奏自适应估算，实际演唱可能比它提前或延后。" +
                     "关闭后当前歌词整行保持满亮度。"

        Switch {
            checked: root.karaokeValue
            onCheckedChanged: root.karaokeValue = checked
        }
    }

    SettingCard {
        Layout.fillWidth: true
        title: "歌词弹出显示"
        description: "只有歌词渠道真的推来歌词时才显示；SMTC 识别到的歌名、封面、播放状态都不会让组件弹出。" +
                     "歌曲暂停或停止、长时间没有新歌词后会自动收起。"

        Switch {
            checked: root.autoShowValue
            onCheckedChanged: root.autoShowValue = checked
        }
    }
}
