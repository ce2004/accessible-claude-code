# Console Redraw Fix, an NVDA add-on.
# Some console programs, such as Claude Code, wipe the console and draw everything again.
# NVDA then sees the whole screen as new, reads it all from the top,
# and the review cursor lands at the top.
# This add-on spots those redraws in terminal windows (Windows Terminal and the classic console),
# speaks only lines you have not heard yet, and puts the review cursor on the last line of text.

from collections import OrderedDict

import api
import core
import globalPluginHandler
import queueHandler
import textInfos
from logHandler import log
from NVDAObjects.behaviors import LiveText

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


def _norm(line: str) -> str:
	return " ".join(line.split())


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
		if api.getFocusObject() is not self:
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


class GlobalPlugin(globalPluginHandler.GlobalPlugin):
	def chooseNVDAObjectOverlayClasses(self, obj, clsList):
		# Only terminal windows that cmd and PowerShell run in:
		# Windows Terminal (diffing mode) and the classic console, UIA or legacy.
		if any(cls.__name__ in _TERMINAL_CLASSES for cls in clsList):
			clsList.insert(0, ConsoleRedrawFix)
