"""歌词岛 —— 三行歌词（HTTP 渠道）+ 底部进度条（SMTC）。

歌词：本地 HTTP 渠道 127.0.0.1:50063/component/lyrics/lyrics/
      payload 防御性解析（lyric/basic、extra、next、progress、lyrics…）。
进度：Windows SMTC（系统媒体会话）读取当前歌曲的播放位置 / 总时长。

核验：发送端在换歌时会推一次 {"lyric": 歌名, "extra": 歌手}，
      用它与 SMTC 的歌名做相似度比对，只有确认是同一首歌时才采用 SMTC 进度，
      避免把 A 歌的进度显示到 B 歌的歌词上。
"""

import json
import re
import threading
import time
import unicodedata
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from typing import Optional

from loguru import logger
from PySide6.QtCore import (
    QAbstractListModel,
    QModelIndex,
    QObject,
    Property,
    Qt,
    Signal,
    Slot,
)
from PySide6.QtGui import QImage

from ClassWidgets.SDK import CW2Plugin, PluginAPI


def _data_dir() -> Path:
    """插件用户数据目录：<主程序根>/configs/plugins/<插件ID>。

    不能写进插件自己的目录：覆盖更新会把 plugins/<插件ID>/ 整个替换掉，
    专辑封面缓存和上一次的播放状态会跟着消失。
    """
    try:
        d = Path(__file__).resolve().parent.parent.parent / "configs" / "plugins" / "com.lyricswidget"
        d.mkdir(parents=True, exist_ok=True)
        return d
    except Exception:
        return Path(__file__).resolve().parent


def _restore_winrt_native() -> None:
    """还原打包时被丢弃的 winrt 原生模块（*.pyd）。

    cw-plugin-pack 会排除手工放置的 *.pyd（.dll / .pyi / .py 都保留），而 winrt
    全靠 _winrt*.pyd 才能工作：少了它 import winrt._winrt 必失败，SMTC 的进度与
    封面整体失效（表现为「winrt 不可用，进度读取关闭」）。这些 .pyd 以 *.pyd.dll
    随包分发，这里在导入 winrt 之前按需还原。只补缺失的，可反复执行。
    """
    log = globals().get("logger")
    try:
        import shutil

        winrt_dir = Path(__file__).resolve().parent / "libs" / "winrt"
        if not winrt_dir.is_dir():
            return
        restored = []
        for stash in winrt_dir.glob("*.pyd.dll"):
            target = stash.with_name(stash.name[:-4])       # 去掉结尾的 .dll
            if not target.exists():
                shutil.copy2(stash, target)
                restored.append(target.name)
        if restored and log is not None:
            log.info(f"[lyricswidget] 已还原 winrt 原生模块: {' '.join(restored)}")
    except Exception as e:                                  # noqa: BLE001
        if log is not None:
            log.warning(f"[lyricswidget] 还原 winrt 原生模块失败: {e}")


_restore_winrt_native()

# smtc_progress 与 main.py 同目录；SDK 一般已把插件目录加入 sys.path，这里兜底
try:
    from smtc_progress import SmtcProgress
except ImportError:  # pragma: no cover
    import os
    import sys

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from smtc_progress import SmtcProgress

try:
    import netease_lyrics          # 仅用于 SMTC 缺时长时兜底补全
except ImportError:  # pragma: no cover
    netease_lyrics = None

# 常量定义
WIDGET_ID = "com.lyricswidget"
SERVER_HOST = "127.0.0.1"
SERVER_PORT = 50063

# 核验阈值：歌名相似度达到该值即认为是同一首歌
_MATCH_THRESHOLD = 0.6
# 时序回看窗口（秒）：SMTC 与 HTTP 推送可能有先后差
_MATCH_LOOKBACK_S = 180.0
# 诊断日志上限（字节），超过则清空重写
_DEBUG_MAX_BYTES = 400_000
# 逐字高亮提前量：动画在本句结束前多少毫秒读完
_KARAOKE_LEAD_MS = 1000

_backend: Optional["Plugin"] = None

_STRIP_CHARS = re.compile(r"[\s\-—–_·・'\"“”‘’【】\[\]（）()<>《》,，.。!！?？:：|]")


_BRACKET = re.compile(r"[（(\[【][^）)\]】]*[）)\]】]")


def _norm(s):
    """归一化：NFKC → 小写 → 去括号内容 → 去标点空白。"""
    if not s:
        return ""
    s = unicodedata.normalize("NFKC", str(s)).lower()
    s = _BRACKET.sub("", s)
    return _STRIP_CHARS.sub("", s)


def _similar(a, b):
    """粗略相似度：相等 1.0；包含关系按长度比；否则按二元组 Dice 系数。"""
    na, nb = _norm(a), _norm(b)
    if not na or not nb:
        return 0.0
    if na == nb:
        return 1.0
    if na in nb or nb in na:
        # 一方包含另一方（如 SMTC 标题带 " - 歌手" 后缀）：给较高分
        return max(0.8, min(len(na), len(nb)) / max(len(na), len(nb)))
    from collections import Counter

    ba = [na[i:i + 2] for i in range(len(na) - 1)]
    bb = [nb[i:i + 2] for i in range(len(nb) - 1)]
    if not ba or not bb:
        return 0.0
    common = Counter(ba) & Counter(bb)
    inter = sum(common.values())
    return 2.0 * inter / (len(ba) + len(bb))


class LyricListModel(QAbstractListModel):
    """歌词行模型。

    每行是一个 dict：
      - text       行文本
      - kind       "line"（真正的歌词行）/ "extra"（附加行：译文或下一句）
      - extra_kind "trans"（译文）/ "next"（下一句）/ ""
    追加行不整体重置模型，ListView 才能平滑滚动。
    """

    LineRole = Qt.UserRole + 1
    KindRole = Qt.UserRole + 2
    ExtraKindRole = Qt.UserRole + 3

    def __init__(self, parent=None):
        super().__init__(parent)
        self._rows = []

    def roleNames(self):
        return {
            self.LineRole: b"lineText",
            self.KindRole: b"rowKind",
            self.ExtraKindRole: b"extraKind",
        }

    def rowCount(self, parent=QModelIndex()):
        return 0 if parent.isValid() else len(self._rows)

    def data(self, index, role=Qt.DisplayRole):
        if not index.isValid() or not (0 <= index.row() < len(self._rows)):
            return None
        row = self._rows[index.row()]
        if role == self.LineRole:
            return row["text"]
        if role == self.KindRole:
            return row["kind"]
        if role == self.ExtraKindRole:
            return row["extra_kind"]
        return None

    def count(self):
        return len(self._rows)

    def row_text(self, i):
        return self._rows[i]["text"] if 0 <= i < len(self._rows) else ""

    def row_kind(self, i):
        return self._rows[i]["kind"] if 0 <= i < len(self._rows) else ""

    def reset_rows(self, rows):
        self.beginResetModel()
        self._rows = [
            (r if isinstance(r, dict) else {"text": str(r), "kind": "line", "extra_kind": ""})
            for r in rows
        ]
        self.endResetModel()

    def append_row(self, text, kind="line", extra_kind=""):
        r = len(self._rows)
        self.beginInsertRows(QModelIndex(), r, r)
        self._rows.append({"text": str(text), "kind": kind, "extra_kind": extra_kind})
        self.endInsertRows()

    def set_row(self, i, text, kind="line", extra_kind=""):
        if not (0 <= i < len(self._rows)):
            return
        row = self._rows[i]
        if row["text"] == text and row["kind"] == kind and row["extra_kind"] == extra_kind:
            return
        self._rows[i] = {"text": str(text), "kind": kind, "extra_kind": extra_kind}
        idx = self.index(i, 0)
        self.dataChanged.emit(idx, idx, [self.LineRole, self.KindRole, self.ExtraKindRole])

    def reclassify_extra(self, text, extra_kind):
        """把内容匹配的附加行重新分类（回溯纠正用）。

        附加行是"译文"还是"下一句"只能靠猜，猜错会让它套上错误的字号。
        但"下一句"必然会以 lyric 身份再出现一次 —— 那一刻就是确定性判据。
        按内容匹配而不是记行号：中间可能发生过 trim_after，记行号会改错行。
        """
        changed = False
        for i, row in enumerate(self._rows):
            if (row["kind"] == "extra" and row["text"] == str(text)
                    and row["extra_kind"] != extra_kind):
                self._rows[i] = {"text": row["text"], "kind": "extra",
                                 "extra_kind": extra_kind}
                idx = self.index(i, 0)
                self.dataChanged.emit(idx, idx, [self.ExtraKindRole])
                changed = True
        return changed

    def trim_after(self, i):
        if i + 1 < len(self._rows):
            self.beginRemoveRows(QModelIndex(), i + 1, len(self._rows) - 1)
            del self._rows[i + 1:]
            self.endRemoveRows()

    def remove_row(self, i):
        if 0 <= i < len(self._rows):
            self.beginRemoveRows(QModelIndex(), i, i)
            del self._rows[i]
            self.endRemoveRows()


_CJK_RE = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\u3040-\u30ff\uac00-\ud7af]")


def _is_translation(lyric, extra):
    """推测 extra 是当前句的译文还是下一句。

    发送端 extra 是二选一（有翻译给翻译，否则给下一句），没有显式标记。
    经验：两者书写系统不同（如英文原词 + 中文翻译）判为译文，否则判为下一句。
    """
    if not lyric or not extra:
        return False
    return bool(_CJK_RE.search(lyric)) != bool(_CJK_RE.search(extra))


def _first(payload, *keys):
    for k in keys:
        v = payload.get(k)
        if isinstance(v, str) and v.strip():
            return v.strip()
        if isinstance(v, (int, float)):
            return str(v)
    return ""


def _norm_progress(payload):
    """从 payload 里提取播放进度并归一化到 0~1；取不到返回 None。"""
    p = payload.get("progress")
    pos = payload.get("position")
    dur = payload.get("duration") or payload.get("total")
    if p is None:
        p = pos
    if p is None:
        return None
    try:
        v = float(p)
    except (TypeError, ValueError):
        return None
    d = None
    try:
        if dur is not None:
            d = float(dur)
    except (TypeError, ValueError):
        d = None
    if d and d > 0 and v > 1.0001:
        return max(0.0, min(1.0, v / d))
    if v <= 1.0:
        return max(0.0, min(1.0, v))
    if v <= 100.0:
        return max(0.0, min(1.0, v / 100.0))
    return None


class LyricsHandler(BaseHTTPRequestHandler):
    """接收音乐软件推送歌词的 HTTP 处理器"""

    def do_POST(self):
        if self.path != "/component/lyrics/lyrics/":
            self._send_error(404, "Not Found")
            return

        try:
            content_length = int(self.headers.get("Content-Length", 0))
            if content_length == 0:
                raise ValueError("Empty request body")
            data = json.loads(self.rfile.read(content_length).decode("utf-8"))
            backend = _backend
            if backend is not None:
                backend.post_lyrics(data)      # 跨线程排队到主线程
            self._send_response(200, "OK")
        except json.JSONDecodeError:
            logger.error("Invalid JSON format")
            self._send_error(400, "Invalid JSON format")
        except ValueError as e:
            logger.error(f"Invalid request: {str(e)}")
            self._send_error(400, str(e))
        except Exception as e:
            logger.error(f"Server error: {str(e)}")
            self._send_error(500, "Internal Server Error")

    def _send_response(self, code: int, message: str):
        self.send_response(code)
        self.send_header("Content-type", "text/plain")
        self.end_headers()
        self.wfile.write(message.encode())

    def _send_error(self, code: int, message: str):
        self.send_response(code)
        self.send_header("Content-type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"error": message}).encode())

    def log_message(self, format, *args):
        return


class HTTPServerWithStop(HTTPServer):
    def serve_forever(self):
        self.running = True
        while self.running:
            self.handle_request()

    def stop(self):
        self.running = False


class Plugin(CW2Plugin):
    """歌词岛组件：三行歌词 + 底部播放进度条（SMTC 进度 + 同曲核验）。"""

    lyricsChanged = Signal()
    linesDirty = Signal()
    progressTick = Signal()
    _postReceived = Signal(dict)
    _durFound = Signal(str, str, int)
    coverChanged = Signal()

    def __init__(self, api: PluginAPI):
        super().__init__(api)
        global _backend
        _backend = self
        self._lyric = ""
        self._extra = ""
        self._last_footer = ""     # 上一条附加行的内容，供回溯确认"下一句"
        self._status = "waiting"
        # —— 「没有歌词就隐藏」的判定状态（纯歌词侧，刻意不掺 SMTC）——
        # 换歌后开始计时；宽限期到点仍一行歌词都没有，就认定「无歌词 / 纯音乐」。
        # 真正的判定在 _get_lyrics_absent()：行数为 0 且宽限期已过，二者同时成立才算。
        self._lyrics_grace_expired = False
        # 30s：避开「换歌 → 歌词推送到达」的空窗。原为 4s，实测偏短，
        # 无词时组件会过早隐藏（换歌瞬间闪一下）。
        self._lyrics_grace_ms = 30000
        from PySide6.QtCore import QTimer as _QTimer
        self._lyrics_grace = _QTimer(self)
        self._lyrics_grace.setSingleShot(True)
        self._lyrics_grace.setInterval(self._lyrics_grace_ms)
        self._lyrics_grace.timeout.connect(self._on_lyrics_grace_timeout)

        # —— 推送看门狗：LyricsIsland 停播时不再推任何东西，靠「多久没收到推送」
        # 判断是否已经没在播放。纯歌词侧，不掺 SMTC（与显隐设计意图一致）。
        self._last_post_at = 0.0
        self._post_stalled = False
        # 45s 没收到任何推送即认定停播。取值偏宽松：歌词行间隔最长也就几秒，
        # 留足余量避免长间奏被误判成停播。要更灵敏就调小。
        self._post_stall_ms = 45000
        self._push_watch = _QTimer(self)
        self._push_watch.setInterval(5000)
        self._push_watch.timeout.connect(self._on_push_watch)
        self._push_watch.start()
        # 计时器原先只在「换歌」时启动（_on_track_changed）。
        # 若插件加载时已在播放、且这首歌没有歌词，就不会有任何换歌事件，
        # 计时器永不启动 -> _lyrics_grace_expired 恒为 False -> 组件永不隐藏。
        # 这里在启动时也起一次；有词时 _on_lyrics_grace_timeout 会先查
        # model.count()，不会误判。
        self._lyrics_grace.start()
        self.server: Optional[HTTPServerWithStop] = None
        self._server_thread: Optional[threading.Thread] = None

        self._model = LyricListModel(self)
        self._idx = 0
        self._progress = 0.0
        self._has_progress = False

        # SMTC 进度 + 核验状态
        self._smtc: Optional[SmtcProgress] = None
        self._smtc_on = False
        self._smtc_title = ""
        self._smtc_artist = ""
        self._smtc_pos = 0
        self._smtc_dur = 0
        self._smtc_playing = False
        self._claim_title = ""     # 发送端声明的歌名
        self._claim_artist = ""
        self._matched = False      # 是否确认同一首歌
        self._recent = []          # 最近收到的 (ts, lyric, extra)，供时序回看
        self._line_ts = 0.0        # 上一次换行的时刻（用于估算每行时长）
        self._line_dur_ms = 0      # 估算的每行时长（毫秒）
        self._line_start_pos = None  # 本句开始时的 SMTC 播放位置（ms）
        self._last_tick_log = 0.0
        self._dur_cache = {}          # (title, artist) -> duration_ms（网易云兜底）
        self._dur_pending = set()
        self._duration_override = 0   # SMTC 没给时长时使用的兜底总时长
        self._http_progress = None    # 歌词渠道自带的进度（若有）
        self._cover_url = ""          # 封面文件 URL（带版本号防缓存）
        self._cover_is_light = False  # 封面平均亮度是否偏亮
        self._cover_color = ""        # 封面平均色（#rrggbb）
        self._cover_seq = 0
        self._smtc_gate = True        # SMTC 体检闸门：未通过则停用 SMTC 功能并释放占用

        self._postReceived.connect(self._apply_post)
        self._durFound.connect(self._on_duration_found)

    # ---- QML 属性：单行回退 ----
    def _get_lyric(self):
        return self._lyric

    def _get_extra(self):
        return self._extra

    def _get_status(self):
        return self._status

    lyricText = Property(str, _get_lyric, notify=lyricsChanged)
    extraText = Property(str, _get_extra, notify=lyricsChanged)
    lyricStatus = Property(str, _get_status, notify=lyricsChanged)

    # ---- QML 属性：没有歌词就隐藏 ----
    def _get_lyrics_absent(self):
        """是否"确实没有歌词"—— 供 QML 决定隐藏组件。

        刻意只看歌词，不掺任何 SMTC 播放状态：
        - 模型里已经有歌词行 → 有词，不隐藏；
        - 一行都还没有，且宽限期已过（或对方明确推了"纯音乐"占位）→ 认定无词。

        宽限期是用来避开「换歌 → 歌词推送到达」之间那段空窗的，
        否则每次换歌组件都会闪一下（隐藏再弹出）。
        """
        if self._model.count() > 0:
            return False
        return bool(self._lyrics_grace_expired)

    lyricsAbsent = Property(bool, _get_lyrics_absent, notify=linesDirty)

    # ---- QML 属性：组件是否应当显示 ----
    def _get_showable(self):
        """组件是否应当显示 —— 只认「传统歌词渠道」。

        - 模型里已经有歌词行（歌词渠道推来的）→ 显示；
        - 一行都还没有时，只在插件刚加载、尚未判定「无歌词」且仍在等待状态时
          给出一段等待提示（宽限期到点后会判定无词并隐藏）。

        SMTC 的歌名 / 专辑封面 / 播放状态，以及桥接用的「歌名 + 歌手」推送都
        不参与这个判定，因此非传统渠道（浏览器视频等）被 SMTC 识别时不会让
        组件重新弹出；只有传统渠道真的推来歌词才会恢复显示。
        """
        if self._model.count() > 0:
            return True
        return (not self._lyrics_grace_expired) and self._status == "waiting"

    showable = Property(bool, _get_showable, notify=linesDirty)

    # ---- QML 属性：三行 + 进度 ----
    def _get_model(self):
        return self._model

    def _get_index(self):
        return self._idx

    def _get_progress(self):
        return self._progress

    def _get_has_lyrics(self):
        return self._model.count() > 0

    def _get_has_progress(self):
        return self._has_progress

    def _get_line_duration(self):
        return self._line_dur_ms

    def _get_line_progress(self):
        """本句已播放比例（0-1）。拿不到 SMTC 进度时返回 -1，QML 会退回估算动画。"""
        if not self._smtc_gate or not self._smtc_title \
                or self._line_start_pos is None or self._line_dur_ms <= 0:
            return -1.0
        span = max(400.0, self._line_dur_ms - _KARAOKE_LEAD_MS)
        p = (self._smtc_pos - self._line_start_pos) / span
        return max(0.0, min(1.0, p))

    def _get_line_remain(self):
        """本句按 SMTC 估计的剩余毫秒；不可用时返回 -1。"""
        if not self._smtc_gate or not self._smtc_title \
                or self._line_start_pos is None or self._line_dur_ms <= 0:
            return -1
        span = max(400.0, self._line_dur_ms - _KARAOKE_LEAD_MS)
        remain = span - (self._smtc_pos - self._line_start_pos)
        return int(max(0.0, min(span, remain)))

    def _get_line_playing(self):
        return self._smtc_gate and bool(self._smtc_title) and self._smtc_playing

    def _get_lyric_progress_available(self):
        """歌词渠道自己带了进度（不依赖 SMTC）。"""
        return self._http_progress is not None

    def _get_playback_known(self):
        """SMTC 是否正在提供可用的播放状态（与是否通过核验无关）。"""
        return self._smtc_on and bool(self._smtc_title)

    def _get_playback_paused(self):
        """已知播放暂停。用于让逐字高亮的估算动画也跟着定格。"""
        return self._get_playback_known() and not self._smtc_playing

    def _get_cover_url(self):
        return self._cover_url if self._smtc_gate else ""

    def _get_cover_light(self):
        return self._cover_is_light

    def _get_cover_color(self):
        return self._cover_color

    def _get_smtc_gate(self):
        return self._smtc_gate

    def _set_smtc_gate(self, on):
        """SMTC 体检结果：未通过时停用进度 / 封面 / 逐字同步，并释放封面占用。"""
        on = bool(on)
        if on == self._smtc_gate:
            return
        self._smtc_gate = on
        if self._smtc is not None:
            try:
                self._smtc.set_thumbnails_enabled(on)
            except Exception:
                pass
        if on:
            self._debug_log("gate", smtc_gate=True)
        else:
            self._release_cover()
            self._debug_log("gate", smtc_gate=False, reason=self._get_match_state())
        self._recompute_progress()
        self.progressTick.emit()

    def _release_cover(self):
        """释放封面：删掉落盘文件并清空，图片与解码占用随之释放。"""
        if self._cover_url:
            for ext in (".png", ".jpg"):
                try:
                    _data_dir().joinpath("cover" + ext).unlink(missing_ok=True)
                except Exception:
                    pass
        self._cover_url = ""
        self._cover_color = ""
        self._cover_is_light = False
        self.coverChanged.emit()

    def _get_match_state(self):
        if not self._smtc_on:
            return "smtc_off"
        if self._matched:
            return "matched"
        if self._claim_title:
            return "mismatch"
        return "unknown"

    lyricModel = Property(QObject, _get_model, constant=True)
    currentIndex = Property(int, _get_index, notify=progressTick)
    progress = Property(float, _get_progress, notify=progressTick)
    hasLyrics = Property(bool, _get_has_lyrics, notify=linesDirty)
    hasProgress = Property(bool, _get_has_progress, notify=progressTick)
    lineDuration = Property(int, _get_line_duration, notify=progressTick)
    # 逐字高亮用：本句真实进度 / 剩余时间 / 是否正在播放
    lineProgress = Property(float, _get_line_progress, notify=progressTick)
    lineRemainMs = Property(int, _get_line_remain, notify=progressTick)
    linePlaying = Property(bool, _get_line_playing, notify=progressTick)
    coverUrl = Property(str, _get_cover_url, notify=coverChanged)
    coverIsLight = Property(bool, _get_cover_light, notify=coverChanged)
    coverColor = Property(str, _get_cover_color, notify=coverChanged)
    # SMTC 体检闸门：由界面按核验结果写入，未通过即停用 SMTC 功能
    smtcGate = Property(bool, _get_smtc_gate, _set_smtc_gate)
    matchState = Property(str, _get_match_state, notify=progressTick)
    # 歌词渠道自带进度（不依赖 SMTC）
    lyricProgressAvailable = Property(bool, _get_lyric_progress_available, notify=progressTick)
    # 原始播放状态（不受核验闸门影响）：暂停时连估算动画也应定格
    playbackKnown = Property(bool, _get_playback_known, notify=progressTick)
    playbackPaused = Property(bool, _get_playback_paused, notify=progressTick)

    # ---- 临时诊断（定位背景错位用，定位完删除）----
    @Slot(str)
    def diag(self, msg):
        try:
            logger.info(f"[lyricswidget][diag] {msg}")
        except Exception:
            pass

    # ---- HTTP 线程入口 ----
    def post_lyrics(self, payload: dict):
        if isinstance(payload, dict):
            self._postReceived.emit(payload)

    # ---- 主线程：处理歌词推送 ----
    @Slot(dict)
    def _apply_post(self, payload):
        # 看门狗用：记下最近一次收到歌词推送的时刻。
        # LyricsIsland 停播时【什么也不推】，没有这个时间戳就无从判断「已经没在放了」。
        self._last_post_at = time.monotonic()
        self._post_stalled = False
        try:
            logger.info(f"[lyricswidget] payload: {payload}")
            _data_dir().joinpath("last_payload.json").write_text(
                json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        except Exception:
            pass

        cur = _first(payload, "lyric", "basic", "text")
        extra = _first(payload, "extra", "translation", "trans", "sub")
        nxt = _first(payload, "next", "nextLyric", "next_line")
        footer = nxt or extra

        # 回溯确认：上一条被判成"译文"的附加行，如果现在以歌词身份出现，
        # 它本来就是"下一句"。这是确定性判据（不是猜测），立即回头改对。
        if cur and self._last_footer and cur.strip() == self._last_footer.strip():
            if self._model.reclassify_extra(self._last_footer, "next"):
                self.linesDirty.emit()
                self.lyricsChanged.emit()
            self._last_footer = ""

        if cur:
            self._recent.append((time.monotonic(), cur, extra))
            if len(self._recent) > 40:
                del self._recent[0]

        # 该条其实是"歌曲信息条"（与 SMTC 歌名一致）→ 不当歌词，只用于核验
        if cur and self._is_song_info(cur, extra):
            self._claim_title = cur
            self._claim_artist = extra
            self._lyric = cur
            self._extra = extra
            self._status = "ok"
            self._refresh_match()
            # 换歌识别：这里只用于核验，不在这里清空歌词行 —— 新歌的第一句歌词
            # 到达时增量逻辑会 trim_after + append，把上一首的行整体换掉；
            # 提前清空会让组件在换歌空窗期先隐藏再弹出（小组件栏会抖一下）。
            self.lyricsChanged.emit()
            self.linesDirty.emit()      # 通知显隐判定重新求值（showable）
            self.progressTick.emit()
            return

        # 对方推的是"纯音乐"占位（如 `[00:00.00]纯音乐，请欣赏`）→ 直接判定无词
        if cur and self._is_pure_music(cur):
            self._mark_no_lyrics("pure")
            return

        # 1) 完整歌词表
        full = payload.get("lyrics") or payload.get("lines")
        if isinstance(full, list) and full:
            rows = []
            for it in full:
                if isinstance(it, dict):
                    t = it.get("text") or it.get("lyric") or ""
                    if t:
                        rows.append(t)
                elif isinstance(it, str) and it:
                    rows.append(it)
            if rows:
                self._model.reset_rows(rows)
                n = _norm_progress(payload)
                if n is not None:
                    self._idx = max(0, min(len(rows) - 1, int(len(rows) * n)))
                self._status = "ok"
                self._lyric = cur or self._model.row_text(self._idx)
                self._extra = footer
                self._emit_all()
                self._update_progress(payload)
                return

        # 2) 增量模式
        if cur:
            self._lyric = cur
            self._status = "ok"
            if self._model.count() == 0:
                self._model.append_row(cur, "line")
                self._idx = 0
                self._note_line_change()
            else:
                at_text = self._model.row_text(self._idx)
                ahead_text = self._model.row_text(self._idx + 1)
                if cur == at_text:
                    pass
                elif cur == ahead_text:
                    # 正好是我们预留的附加行 → 确认为真正的歌词行并推进
                    self._idx += 1
                    self._model.set_row(self._idx, cur, "line")
                    self._model.trim_after(self._idx)
                    self._note_line_change()
                else:
                    # 新行或跳转：截断后续并追加
                    self._model.trim_after(self._idx)
                    self._model.append_row(cur, "line")
                    self._idx = self._model.count() - 1
                    self._note_line_change()
            self._emit_all()
            self.lyricsChanged.emit()

        # 3) 附加行：区分"译文"与"下一句"
        #    判定按可信度排序：
        #      ① 发送端显式给了 next / nextLyric / next_line → 就是下一句，不必猜
        #      ② 值来自 translation / trans / sub 这类明确表示译文的键 → 就是译文
        #      ③ 只有通用的 extra 键时才退回"脚本差异"猜测
        #    原来一律走 ③：中文歌配英文下一句（两边脚本不同）会被判成译文，
        #    附加行于是套上主字号，看起来和当前句一起被加粗。
        if footer and cur:
            self._extra = footer
            self._last_footer = footer
            explicit_trans = _first(payload, "translation", "trans", "sub")
            if nxt:
                ekind = "next"
            elif explicit_trans and explicit_trans == extra:
                ekind = "trans"
            else:
                ekind = "trans" if _is_translation(cur, footer) else "next"
            ni = self._idx + 1
            if ni < self._model.count():
                self._model.set_row(ni, footer, "extra", ekind)
            else:
                self._model.append_row(footer, "extra", ekind)
            self.linesDirty.emit()
            self.lyricsChanged.emit()

        self._update_progress(payload)

    # ── 「没有歌词就隐藏」的判定（纯歌词侧，不依赖 SMTC）────────────

    _PURE_MUSIC_RE = re.compile(r"纯音乐|请欣赏|instrumental|no\s*lyric|无歌词|暂无歌词", re.I)
    # 结构字符：LRC 时间戳、标点、空白、数字
    _STRUCT_RE = re.compile(r"[\s\d:\-–—,，。.、!！?？~～\[\]()（）]+")

    def _is_pure_music(self, text):
        """判断一条歌词是不是"纯音乐"占位。

        只在**整条内容被占位词和结构字符完全覆盖**时才判定为纯音乐，
        因此 `[00:00.00]纯音乐，请欣赏` 会命中，而任何含真实文字的歌词都不会。
        刻意**不匹配**"作词/作曲"：那是正常歌词里常见的署名行，
        匹配了会把真歌误判成纯音乐。
        """
        if not text or not str(text).strip():
            return False
        try:
            rest = self._PURE_MUSIC_RE.sub("", str(text))
            rest = self._STRUCT_RE.sub("", rest)
        except Exception:
            return False
        return rest == ""

    def _begin_lyrics_wait(self):
        """歌词侧检测到换歌：清空上一首的歌词，重新开始等新歌词。"""
        try:
            if self._model.count() > 0:
                self._model.reset_rows([])
                self._idx = 0
                self.linesDirty.emit()
        except Exception:
            pass
        self._lyrics_grace_expired = False
        try:
            self._lyrics_grace.start()
        except Exception:
            pass

    def _mark_no_lyrics(self, status="empty"):
        """明确判定没有可显示的歌词（空 / 纯音乐）。

        除了置状态，还要把残留歌词清掉：判定无词时若模型里还留着上一首/上一句的行，
        hasLyrics / showable 仍然为真，组件根本不会隐藏（纯音乐占位是最常见的场景）。
        """
        self._status = status
        self._lyrics_grace_expired = True
        try:
            self._lyrics_grace.stop()
        except Exception:
            pass
        try:
            if self._model.count() > 0:
                self._model.reset_rows([])
                self._idx = 0
        except Exception:
            pass
        self.lyricsChanged.emit()
        self.linesDirty.emit()

    def _on_push_watch(self):
        """太久没收到歌词推送 -> 认定已停播，清词并判定无词。

        只在「从有推送变成长时间无推送」时动手一次，靠 _post_stalled 去重；
        一旦又有新推送，_apply_post 会把标志复位。
        """
        if not self._last_post_at:
            return
        if self._post_stalled:
            return
        import time as _t
        if (_t.monotonic() - self._last_post_at) * 1000 < self._post_stall_ms:
            return
        self._post_stalled = True
        try:
            if self._model.count() > 0:
                self._model.reset_rows([])
                self._idx = 0
        except Exception:
            pass
        self._mark_no_lyrics("empty")
        self._debug_log("push_stalled")

    def _on_lyrics_grace_timeout(self):
        """换歌后等满宽限期，仍然一行歌词都没有 → 判定无歌词。"""
        if self._model.count() == 0:
            self._lyrics_grace_expired = True
            self.linesDirty.emit()

    def _emit_all(self):
        self.linesDirty.emit()
        self.progressTick.emit()

    def _note_line_change(self):
        """记录换行时刻，估算每行时长（供逐字高亮）。

        优先用 SMTC 播放位置的差值：它不受缓冲、变速、暂停影响，比墙上时钟准；
        拿不到位置时退回墙上时钟。
        """
        now = time.monotonic()
        smtc_ok = bool(self._smtc_title) and self._smtc_pos > 0
        if self._line_ts:
            pos_delta = None
            if smtc_ok and self._line_start_pos is not None:
                d = self._smtc_pos - self._line_start_pos
                if 300 <= d <= 60000:
                    pos_delta = d
            if pos_delta is not None:
                self._line_dur_ms = pos_delta
            else:
                d = int((now - self._line_ts) * 1000)
                if 800 <= d <= 60000:
                    self._line_dur_ms = d
        self._line_ts = now
        self._line_start_pos = self._smtc_pos if smtc_ok else None

    def _debug_log(self, event, **fields):
        """诊断：把核验相关事件追加到 smtc_debug.log，便于定位匹配失败原因。"""
        try:
            rec = {"t": time.strftime("%H:%M:%S"), "ev": event}
            rec.update(fields)
            p = _data_dir().joinpath("smtc_debug.log")
            if p.exists() and p.stat().st_size > _DEBUG_MAX_BYTES:
                p.write_text("", encoding="utf-8")
            with p.open("a", encoding="utf-8") as f:
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        except Exception:
            pass

    def _drop_row(self, text):
        """把已被判定为"歌名"的那一行从歌词行里删除（它不该当歌词显示）。"""
        for i in range(self._model.count()):
            if self._model.row_text(i) == text:
                self._model.remove_row(i)
                if self._idx > i:
                    self._idx -= 1
                elif self._idx == i:
                    self._idx = max(0, i - 1)
                self.linesDirty.emit()
                return

    # ---- SMTC 进度 ----
    def _start_smtc(self):
        try:
            self._smtc = SmtcProgress(self)
            self._smtc.updated.connect(self._on_smtc_updated)
            self._smtc.started.connect(self._on_smtc_started)
            self._smtc.thumbnail.connect(self._on_thumbnail)
            self._smtc.start()
        except Exception as e:
            logger.error(f"[lyricswidget] SMTC 启动失败: {e}")
            self._smtc = None

    def _stop_smtc(self):
        if self._smtc is not None:
            try:
                self._smtc.stop()
            except Exception as e:
                logger.error(f"[lyricswidget] SMTC 停止失败: {e}")
            self._smtc = None

    @Slot(bool)
    def _on_smtc_started(self, ok):
        self._smtc_on = ok
        self.progressTick.emit()

    @Slot(str, str, int, int, bool, str)
    def _on_smtc_updated(self, title, artist, pos_ms, dur_ms, playing, raw):
        if title != self._smtc_title:
            if title:      # 仅在拿到非空新标题时作废旧声明，避免抖动误清
                self._claim_title = ""
                self._claim_artist = ""
                self._matched = False
                self._duration_override = 0
                self._http_progress = None
                self._line_start_pos = None
                self._line_dur_ms = 0
                self._debug_log("song", smtc=title, smtc_artist=artist)
            self._smtc_title = title
        self._smtc_artist = artist
        self._smtc_pos = pos_ms
        self._smtc_dur = dur_ms
        self._smtc_playing = playing
        self._refresh_match()
        self._recompute_progress()
        self._ensure_duration()
        self.progressTick.emit()
        now = time.monotonic()
        if now - self._last_tick_log >= 10.0:
            self._last_tick_log = now
            self._debug_log("tick", title=title, artist=artist, pos=pos_ms, dur=dur_ms,
                            playing=playing, has_progress=self._has_progress,
                            matched=self._matched, raw=raw)

    def _is_song_info(self, line, extra=""):
        """判断某条歌词其实是不是"歌名"（与 SMTC 歌名 + 歌手一致）。"""
        return self._claim_matches(line, extra)

    def _claim_matches(self, title, artist):
        """歌词侧声明的 (歌名, 歌手) 与 SMTC 当前歌曲是否一致。"""
        if not self._smtc_title:
            return False
        if _similar(title, self._smtc_title) < _MATCH_THRESHOLD:
            return False
        # 歌手二次确认：双方都有歌手信息时才校验，降低误判
        if artist and self._smtc_artist and _similar(artist, self._smtc_artist) < 0.4:
            return False
        return True

    def _refresh_match(self):
        prev = self._matched
        self._matched = False
        if self._smtc_title:
            if self._claim_title and self._claim_matches(self._claim_title, self._claim_artist):
                self._matched = True
            else:
                # 时序回看：近期收到的歌词里是否有歌名
                now = time.monotonic()
                for ts, line, extra in reversed(self._recent):
                    if now - ts > _MATCH_LOOKBACK_S:
                        break
                    if self._claim_matches(line, extra):
                        self._claim_title = line
                        self._claim_artist = extra
                        self._matched = True
                        self._drop_row(line)
                        break
        if self._matched != prev:
            self._debug_log(
                "match",
                matched=self._matched,
                smtc=self._smtc_title,
                smtc_artist=self._smtc_artist,
                claim=self._claim_title,
                claim_artist=self._claim_artist,
                candidates=[c[1] for c in self._recent[-6:]],
            )

    def _recompute_progress(self):
        total = self._smtc_dur if self._smtc_dur > 0 else self._duration_override
        if self._smtc_gate and total > 0 and self._smtc_title:
            self._progress = max(0.0, min(1.0, self._smtc_pos / total))
            self._has_progress = True
        elif self._http_progress is not None:
            self._progress = self._http_progress
            self._has_progress = True
        else:
            # 拿不到任何进度数据 → 不显示进度条
            self._progress = 0.0
            self._has_progress = False

    # ---- SMTC 缺时长时的兜底：用网易云搜索结果补总时长 ----
    def _ensure_duration(self):
        if netease_lyrics is None or self._smtc_dur > 0 or not self._matched or not self._smtc_title:
            return
        key = (self._smtc_title, self._smtc_artist)
        if key in self._dur_cache:
            d = self._dur_cache[key]
            if d > 0 and self._duration_override != d:
                self._duration_override = d
                self._recompute_progress()
                self.progressTick.emit()
            return
        if key in self._dur_pending:
            return
        self._dur_pending.add(key)
        threading.Thread(target=self._lookup_duration_worker, args=(key,), daemon=True).start()

    def _lookup_duration_worker(self, key):
        title, artist = key
        dur = 0
        try:
            best, best_score = None, 0.0
            queries = []
            if title and artist:
                queries.append(f"{title} {artist}")
            if title:
                queries.append(title)
            for q in queries:
                songs = netease_lyrics.search_songs(q)
                for s in songs:
                    sc = netease_lyrics.score_song(s, title, artist, 0)
                    if sc > best_score:
                        best, best_score = s, sc
                if best_score >= 4.5:
                    break
            if best is not None and best_score >= 3.6:
                dur = int(best.get("duration") or 0)
        except Exception as e:
            logger.debug(f"[lyricswidget] duration lookup failed: {e}")
        self._durFound.emit(title, artist, dur)

    def _on_thumbnail(self, title, data):
        """把 SMTC 封面存成文件交给 QML，并算出平均色与亮度（供配色 / 自适应）。"""
        try:
            raw = bytes(data) if data is not None else b""
        except Exception:
            raw = b""
        if not raw or not self._smtc_gate:
            return
        try:
            img = QImage.fromData(raw)
            if img.isNull():
                return
            # 缩到 1x1 即"重模糊"后的平均色，与背景观感一致
            small = img.scaled(1, 1, Qt.IgnoreAspectRatio, Qt.SmoothTransformation)
            col = small.pixelColor(0, 0)
            lum = 0.2126 * col.redF() + 0.7152 * col.greenF() + 0.0722 * col.blueF()
            ext = ".png" if raw[:4] == b"\x89PNG" else ".jpg"
            path = _data_dir().joinpath("cover" + ext)
            path.write_bytes(raw)
            self._cover_seq += 1
            self._cover_url = path.as_uri() + f"?v={self._cover_seq}"
            self._cover_is_light = lum >= 0.55
            self._cover_color = col.name()
            self._debug_log("cover", title=title, color=self._cover_color,
                            light=self._cover_is_light)
            self.coverChanged.emit()
        except Exception as e:
            logger.debug(f"[lyricswidget] 处理封面失败: {e}")

    @Slot(str, str, int)
    def _on_duration_found(self, title, artist, dur):
        self._dur_pending.discard((title, artist))
        self._dur_cache[(title, artist)] = dur
        if dur > 0:
            self._debug_log("duration", title=title, artist=artist, dur=dur)
        if dur > 0 and self._smtc_dur <= 0 and title == self._smtc_title:
            self._duration_override = dur
            self._recompute_progress()
            self.progressTick.emit()

    def _update_progress(self, payload):
        # 已与 SMTC 核验一致时，进度以 SMTC 为准
        if self._matched:
            return
        n = _norm_progress(payload)
        if n is not None:
            self._http_progress = n
            self._progress = n
            self._has_progress = True
            self.progressTick.emit()

    # ---- 生命周期 ----
    def on_load(self):
        super().on_load()
        self.api.widgets.register(
            widget_id=WIDGET_ID,
            name="歌词",
            qml_path="qml/lyrics.qml",
            settings_qml="qml/lyrics-settings.qml",
            backend_obj=self,
            default_settings={
                "lyric_font_size": 13,
                "sub_font_size": 10,
                "lyric_color": "auto",
                "lyric_color_custom": "#ffffff",
                # 背景：cover=封面模糊 / solid=纯色 / none=无背景；
                # bg_opacity 是「整层背景不透明度」，100 = 原样，0 = 只留文字
                "bg_mode": "cover",
                "bg_color": "#1b1e26",
                "bg_blur": 32,
                "bg_opacity": 100,
                "switch_anim_ms": 1500,
                "auto_show": True,
                "show_progress": True,
                "progress_unverified": False,
                "karaoke_enabled": True,
                "extra_font_size": 12,
                "anim_mode": "off",
                "scroll_seconds": 8,
                "scroll_delay": 0.5,
            },
        )
        self._start_server()
        self._start_smtc()
        print(f"[lyricswidget] 插件已加载，服务端口 {SERVER_PORT}")

    def on_unload(self):
        global _backend
        self._stop_smtc()
        self._stop_server()
        if _backend is self:
            _backend = None
        print("[lyricswidget] 插件已卸载")

    # ---- HTTP 服务 ----
    def _start_server(self):
        def server_worker():
            try:
                self.server = HTTPServerWithStop((SERVER_HOST, SERVER_PORT), LyricsHandler)
                logger.info(f"Lyrics server started at http://{SERVER_HOST}:{SERVER_PORT}")
                self.server.serve_forever()
            except OSError as e:
                logger.error(f"Lyrics server failed to bind {SERVER_HOST}:{SERVER_PORT}: {e}")
            except Exception as e:
                logger.error(f"Lyrics server error: {e}")

        self._server_thread = threading.Thread(target=server_worker, daemon=True)
        self._server_thread.start()

    def _stop_server(self):
        if self.server:
            try:
                self.server.stop()
                logger.info("Lyrics server stopped")
            except Exception as e:
                logger.error(f"Failed to stop lyrics server: {e}")
        self.server = None
