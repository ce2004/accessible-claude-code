# Console Redraw Fix, an NVDA add-on.
# Some console programs, such as Claude Code, wipe the console and draw everything again.
# NVDA then sees the whole screen as new, reads it all from the top,
# and the review cursor lands at the top.
# This add-on spots those redraws in Claude Code windows (in Windows Terminal or the classic console),
# speaks only lines you have not heard yet, and puts the review cursor on the last line of text.
#
# It also adds Find for Claude Code conversations. The terminal only keeps the last screen or so,
# so Control+F in a Claude Code window asks for text, then opens the whole conversation
# as a document in browse mode, with the cursor on the most recent place the text appears.
# The arrow keys read on from there. F3 and Shift+F3 go to the next and previous match.
# NVDA+Control+L reads Claude's last reply; pressed twice, it opens the reply in browse mode.
# It finds the conversation through small files the quiet-tools mod writes, one per session,
# naming the window title and the conversation's transcript file.
#
# Everything here works only in Claude Code windows, known by the window titles the quiet-tools
# mod sets; every other terminal works as if the add-on were not there.
#
# The review cursor stays where you are reading: new text in Claude Code does not move it,
# unless "Move the review cursor to new text" is turned on in NVDA's settings, under
# Console Redraw Fix. NVDA+A (say all) reads from the review cursor to the end, and
# pressing Down Arrow puts the review cursor on the last line of text.

import html
import inspect
import json
import os
import threading
import time
from collections import OrderedDict

import api
import config
import core
import globalPluginHandler
import gui
import queueHandler
import scriptHandler
import speech
import textInfos
import ui
import wx
from gui import guiHelper, settingsDialogs
from logHandler import log
from NVDAObjects.behaviors import LiveText
from scriptHandler import script

try:
	from speech import sayAll as _sayAll
except Exception:
	_sayAll = None

_CONF = "consoleRedrawFix"
config.conf.spec[_CONF] = {
	# Off: new text in a terminal leaves the review cursor where it is.
	"moveReviewToNewText": "boolean(default=False)",
}


def _movesReview() -> bool:
	try:
		return bool(config.conf[_CONF]["moveReviewToNewText"])
	except Exception:
		return False

# How many recently seen lines to remember.
_MAX_SEEN = 4000
# A change counts as a redraw when it has at least this many lines
# and at least this share of them were already on screen before.
_MIN_REDRAW_LINES = 3
_REDRAW_SHARE = 0.5
# Short fragments are too common to judge, so they are never treated as repeats.
_MIN_FRAGMENT_LEN = 8
# Wait this long after a redraw before moving the review cursor,
# so caret moves from the redraw itself are done first.
_REVIEW_DELAY_MS = 300
# NVDA's own classes for terminal text areas that read new text by diffing.
_TERMINAL_CLASSES = frozenset(("WinConsoleUIA", "_DiffBasedWinTerminalUIA", "WinConsole"))

_CATEGORY = "Console Redraw Fix"
# Text typed into the find box, offered again next time.
_lastFind = ""
# Window files older than this are from sessions long gone, and are deleted.
_WINDOW_FILE_MAX_AGE = 30 * 86400


def _norm(line: str) -> str:
	return " ".join(line.split())


# ---------------------------------------------------------------- Claude Code conversations


def _configDir() -> str:
	return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")


def _windowFiles() -> list[dict]:
	folder = os.path.join(_configDir(), "claude-accessibility", "windows")
	found = []
	try:
		names = os.listdir(folder)
	except OSError:
		return found
	now = time.time()
	for name in names:
		path = os.path.join(folder, name)
		try:
			if now - os.path.getmtime(path) > _WINDOW_FILE_MAX_AGE:
				os.remove(path)
				continue
			with open(path, encoding="utf-8") as f:
				entry = json.load(f)
			if isinstance(entry, dict) and entry.get("transcript"):
				entry["mtime"] = os.path.getmtime(path)
				found.append(entry)
		except Exception:
			continue
	return sorted(found, key=lambda e: e["mtime"], reverse=True)


def _isClaudeTitle(windowTitle: str) -> bool:
	"""Whether a window title is one the quiet-tools mod sets for Claude Code:
	what Claude is doing ("Claude is working"), after the conversation's name if it has one."""
	title = windowTitle or ""
	return title.startswith("Claude") or " - Claude" in title


def _inClaudeWindow() -> bool:
	try:
		return _isClaudeTitle(api.getForegroundObject().name)
	except Exception:
		return False


def _findConversation(windowTitle: str):
	"""The window file of the Claude Code session drawn in a window with this title, or None."""
	entries = [e for e in _windowFiles() if os.path.isfile(e["transcript"])]
	for entry in entries:
		if entry.get("title") == windowTitle:
			return entry
	# The title can change between the mod writing it and Windows showing it.
	if _isClaudeTitle(windowTitle) and entries:
		return entries[0]
	return None


def _messageText(content) -> str:
	if isinstance(content, str):
		return content
	if not isinstance(content, list):
		return ""
	return "\n".join(
		b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text"
	)


def _readConversation(path: str) -> list[tuple[str, str]]:
	"""The conversation as (who, text) pairs, Claude's replies in one turn joined together."""
	messages: list[tuple[str, str]] = []
	with open(path, encoding="utf-8", errors="replace") as f:
		for line in f:
			head = line[:400]
			if '"isSidechain":false' not in head:
				continue
			isUser = '"type":"user"' in head
			if not isUser and '"role":"assistant"' not in line:
				continue
			try:
				entry = json.loads(line)
			except ValueError:
				continue
			kind = entry.get("type")
			message = entry.get("message") or {}
			if kind == "user" and not entry.get("isMeta"):
				text = _messageText(message.get("content")).strip()
				if text and not text.startswith("<"):
					messages.append(("You", text))
			elif kind == "assistant":
				text = _messageText(message.get("content")).strip()
				if not text:
					continue
				if messages and messages[-1][0] == "Claude":
					messages[-1] = ("Claude", messages[-1][1] + "\n\n" + text)
				else:
					messages.append(("Claude", text))
	return messages


def _conversationHtml(title: str, messages: list[tuple[str, str]], matches: int, query: str) -> str:
	# The query is left out of the opening line, so a search backwards from the end
	# never lands on it.
	parts = [f"<h1>{html.escape(title)}</h1>"]
	parts.append(
		f"<p>{matches} {'message' if matches == 1 else 'messages'} matched. You are on the most recent match. "
		"Press Shift+F3 for the one before, F3 for the one after, Escape to close.</p>"
	)
	for who, text in messages:
		parts.append(f"<h2>{who}</h2>")
		for para in text.split("\n\n"):
			para = para.strip("\n")
			if para.strip():
				parts.append("<p>" + html.escape(para).replace("\n", "<br>") + "</p>")
	return "\n".join(parts)


def _showDocument(htmlText: str, title: str):
	kwargs = {"isHtml": True}
	try:
		params = inspect.signature(ui.browseableMessage).parameters
		if "sanitizeHtmlFunc" in params:
			# Everything from the transcript is escaped above.
			kwargs["sanitizeHtmlFunc"] = lambda text: text
		if "closeButton" in params:
			kwargs["closeButton"] = True
	except Exception:
		pass
	ui.browseableMessage(htmlText, title, **kwargs)


# ---------------------------------------------------------------- The terminal overlay


class ConsoleRedrawFix(LiveText):
	def initOverlayClass(self):
		self._crfSeen = OrderedDict()
		self._crfReviewTimer = None

	def _crfRemember(self, text: str):
		seen = self._crfSeen
		for line in text.splitlines():
			key = _norm(line)
			if not key:
				continue
			if key in seen:
				seen.move_to_end(key)
			else:
				seen[key] = None
		while len(seen) > _MAX_SEEN:
			seen.popitem(last=False)

	def _crfIsSeen(self, key: str, oldText: str) -> bool:
		if key in self._crfSeen:
			return True
		# Character diffing can hand back pieces of lines.
		if len(key) >= _MIN_FRAGMENT_LEN:
			for seenLine in reversed(self._crfSeen):
				if key in seenLine:
					return True
		return False

	def _calculateNewText(self, newText: str, oldText: str) -> list[str]:
		outLines = super()._calculateNewText(newText, oldText)
		if not _inClaudeWindow():
			return outLines
		self._crfRemember(oldText)
		try:
			pieces = []
			for out in outLines:
				for line in out.splitlines():
					key = _norm(line)
					if key:
						pieces.append((line, self._crfIsSeen(key, oldText)))
			repeats = sum(1 for _, isSeen in pieces if isSeen)
			log.debug(f"Console Redraw Fix: change with {len(pieces)} lines, {repeats} already heard")
			if len(pieces) >= _MIN_REDRAW_LINES and repeats >= len(pieces) * _REDRAW_SHARE:
				log.debug(f"Console Redraw Fix: redraw, {repeats} of {len(pieces)} lines already heard")
				outLines = [line for line, isSeen in pieces if not isSeen]
				queueHandler.queueFunction(queueHandler.eventQueue, self._crfScheduleReview)
		except Exception:
			log.exception("Console Redraw Fix: error filtering new text")
		self._crfRemember(newText)
		return outLines

	def _crfScheduleReview(self):
		# Runs on the main thread. Restart the timer so a burst of redraws moves review once.
		if self._crfReviewTimer is not None:
			self._crfReviewTimer.Stop()
		self._crfReviewTimer = core.callLater(_REVIEW_DELAY_MS, self._crfMoveReviewToBottom)

	def _crfMoveReviewToBottom(self):
		self._crfReviewTimer = None
		if api.getFocusObject() is not self or not _movesReview():
			return
		try:
			info = self._crfLastLineInfo()
			if info is not None:
				api.setReviewPosition(info)
				log.debug(f"Console Redraw Fix: review moved to line {self._crfLineText(info)!r}")
		except Exception:
			log.exception("Console Redraw Fix: couldn't move the review cursor")

	@staticmethod
	def _crfLineText(info) -> str:
		line = info.copy()
		line.expand(textInfos.UNIT_LINE)
		return line.text.strip()

	def _crfLastLineInfo(self):
		# Start from the bottom of what's on screen, then step up past blank lines.
		try:
			rng = self.UIATextPattern.GetVisibleRanges().GetElement(0)
			info = self.TextInfo(self, textInfos.POSITION_FIRST, _rangeObj=rng)
			info.collapse(end=True)
			info.move(textInfos.UNIT_CHARACTER, -1)
		except Exception:
			info = self.makeTextInfo(textInfos.POSITION_LAST)
		info.expand(textInfos.UNIT_LINE)
		for _ in range(200):
			if info.text.strip():
				break
			info.collapse()
			if info.move(textInfos.UNIT_LINE, -1) == 0:
				break
			info.expand(textInfos.UNIT_LINE)
		info.collapse()
		return info

	# ---------------------------------------------------------------- Where the review cursor goes

	def event_caret(self):
		# NVDA moves the review cursor to the caret, and in a terminal the caret moves
		# with every bit of new output. Unless the setting asks for that, keep the
		# review cursor where the person is reading; braille and the rest still follow.
		if _movesReview() or not _inClaudeWindow():
			return super().event_caret()
		kept = api.getReviewPosition()
		super().event_caret()
		try:
			if kept is not None and kept.obj is self and api.getReviewPosition() is not kept:
				api.setReviewPosition(kept, clearNavigatorObject=False)
		except Exception:
			log.exception("Console Redraw Fix: couldn't keep the review cursor in place")

	@script(
		description="In a Claude Code window, reads from the review cursor to the end",
		gestures=["kb:NVDA+a", "kb(desktop):NVDA+downArrow"],
		category=_CATEGORY,
	)
	def script_crfSayAll(self, gesture):
		if _sayAll is None or not _inClaudeWindow():
			# Anywhere else, NVDA's own say all.
			import globalCommands
			globalCommands.commands.script_sayAll(gesture)
			return
		_sayAll.SayAllHandler.readText(_sayAll.CURSOR.REVIEW)

	@script(
		description="In a Claude Code window, sends Down Arrow and puts the review cursor on the last line of text",
		gesture="kb:downArrow",
		category=_CATEGORY,
	)
	def script_crfDownToEnd(self, gesture):
		gesture.send()
		if not _inClaudeWindow():
			return
		core.callLater(100, self._crfReviewToEnd)

	def _crfReviewToEnd(self):
		try:
			info = self._crfLastLineInfo()
			api.setReviewPosition(info)
			line = info.copy()
			line.expand(textInfos.UNIT_LINE)
			speech.cancelSpeech()
			ui.message(line.text.strip() or "blank")
		except Exception:
			log.exception("Console Redraw Fix: couldn't move the review cursor to the end")

	# ---------------------------------------------------------------- Find

	@script(
		description="In a Claude Code window, finds text in the conversation and opens it there to read",
		gestures=["kb:control+f", "kb:NVDA+control+f"],
		category=_CATEGORY,
	)
	def script_crfFind(self, gesture):
		windowTitle = api.getForegroundObject().name or ""
		conversation = _findConversation(windowTitle)
		if conversation is None or not _isClaudeTitle(windowTitle):
			# Not a Claude Code window: the program gets the key as usual.
			gesture.send()
			return
		wx.CallAfter(self._crfAskFind, conversation)

	@script(
		description="In a Claude Code window, reads Claude's last reply. Pressed twice, opens it in browse mode",
		gesture="kb:NVDA+control+l",
		category=_CATEGORY,
	)
	def script_crfLastReply(self, gesture):
		windowTitle = api.getForegroundObject().name or ""
		conversation = _findConversation(windowTitle)
		if conversation is None or not _isClaudeTitle(windowTitle):
			gesture.send()
			return
		isTwice = scriptHandler.getLastScriptRepeatCount() >= 1
		threading.Thread(
			target=self._crfLastReply, args=(conversation, isTwice), daemon=True, name="consoleRedrawFixReply"
		).start()

	def _crfLastReply(self, conversation: dict, isTwice: bool):
		try:
			messages = _readConversation(conversation["transcript"])
		except Exception:
			log.exception("Console Redraw Fix: couldn't read the conversation")
			queueHandler.queueFunction(queueHandler.eventQueue, ui.message, "The conversation could not be read")
			return
		replies = [body for who, body in messages if who == "Claude"]
		if not replies:
			queueHandler.queueFunction(queueHandler.eventQueue, ui.message, "Claude has not replied yet")
			return
		reply = replies[-1]
		if isTwice:
			page = "<h1>Claude's last reply</h1>\n" + "\n".join(
				"<p>" + html.escape(p.strip("\n")).replace("\n", "<br>") + "</p>"
				for p in reply.split("\n\n")
				if p.strip()
			)
			wx.CallAfter(_showDocument, page, "Claude's last reply")
		else:
			queueHandler.queueFunction(queueHandler.eventQueue, self._crfSpeak, reply)

	@staticmethod
	def _crfSpeak(text: str):
		speech.cancelSpeech()
		ui.message(text)

	def _crfAskFind(self, conversation: dict):
		global _lastFind
		text = ""
		isOk = False
		gui.mainFrame.prePopup()
		try:
			dialog = wx.TextEntryDialog(
				gui.mainFrame, "Text to find in this conversation:", "Find in conversation", _lastFind
			)
			isOk = dialog.ShowModal() == wx.ID_OK
			text = dialog.GetValue().strip()
			dialog.Destroy()
		except Exception:
			log.exception("Console Redraw Fix: the find box failed")
		finally:
			gui.mainFrame.postPopup()
		if not (isOk and text):
			return
		_lastFind = text
		ui.message("Searching")
		threading.Thread(
			target=self._crfSearch, args=(conversation, text), daemon=True, name="consoleRedrawFixFind"
		).start()

	def _crfSearch(self, conversation: dict, text: str):
		# Runs on its own thread, since a long conversation takes a moment to read.
		try:
			messages = _readConversation(conversation["transcript"])
		except Exception:
			log.exception("Console Redraw Fix: couldn't read the conversation")
			queueHandler.queueFunction(queueHandler.eventQueue, ui.message, "The conversation could not be read")
			return
		needle = text.lower()
		matches = sum(1 for _, body in messages if needle in body.lower())
		if not matches:
			queueHandler.queueFunction(
				queueHandler.eventQueue, ui.message, f"{text} is not in this conversation"
			)
			return
		convTitle = conversation.get("name") or "Claude Code conversation"
		page = _conversationHtml(convTitle, messages, matches, text)
		wx.CallAfter(self._crfOpen, page, f"{convTitle} - find {text}", text)

	def _crfOpen(self, page: str, title: str, text: str):
		try:
			_showDocument(page, title)
		except Exception:
			log.exception("Console Redraw Fix: couldn't open the conversation")
			ui.message("The conversation could not be opened")
			return
		self._crfLandTries = 0
		core.callLater(400, self._crfLand, text)

	def _crfLand(self, text: str):
		# Wait for the document to load in browse mode, then find the last match from the end.
		self._crfLandTries += 1
		try:
			ti = api.getFocusObject().treeInterceptor
			if ti is None or not getattr(ti, "isReady", False) or not hasattr(ti, "doFindText"):
				if self._crfLandTries < 40:
					core.callLater(250, self._crfLand, text)
				return
			try:
				import cursorManager
				cursorManager.CursorManager._lastFindText = text
			except Exception:
				pass
			ti._lastFindText = text
			ti.selection = ti.makeTextInfo(textInfos.POSITION_LAST)
			ti.doFindText(text, reverse=True)
		except Exception:
			log.exception("Console Redraw Fix: couldn't move to the match")


class ConsoleRedrawFixPanel(settingsDialogs.SettingsPanel):
	title = "Console Redraw Fix"

	def makeSettings(self, settingsSizer):
		helper = guiHelper.BoxSizerHelper(self, sizer=settingsSizer)
		self.moveReview = helper.addItem(
			wx.CheckBox(self, label="&Move the review cursor to new text in Claude Code windows")
		)
		self.moveReview.SetValue(_movesReview())

	def onSave(self):
		config.conf[_CONF]["moveReviewToNewText"] = self.moveReview.GetValue()


class GlobalPlugin(globalPluginHandler.GlobalPlugin):
	def __init__(self):
		super().__init__()
		settingsDialogs.NVDASettingsDialog.categoryClasses.append(ConsoleRedrawFixPanel)

	def terminate(self):
		try:
			settingsDialogs.NVDASettingsDialog.categoryClasses.remove(ConsoleRedrawFixPanel)
		except ValueError:
			pass
		super().terminate()

	def chooseNVDAObjectOverlayClasses(self, obj, clsList):
		# Only terminal windows that cmd and PowerShell run in:
		# Windows Terminal (diffing mode) and the classic console, UIA or legacy.
		if any(cls.__name__ in _TERMINAL_CLASSES for cls in clsList):
			clsList.insert(0, ConsoleRedrawFix)
