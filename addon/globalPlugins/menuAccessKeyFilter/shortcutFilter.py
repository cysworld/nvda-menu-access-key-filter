# Menu Access Key Filter, an add-on for NVDA
# Prototype for https://github.com/nvaccess/nvda/issues/20912
# This file may be used under the terms of the GNU General Public License, version 2 or later.

"""Pure-Python logic for dropping unusable access keys from a keyboard shortcut string.

This module deliberately imports nothing from NVDA, so it can be unit tested outside of NVDA.

Background (nvaccess/nvda#20912):
Menus in Chinese, Japanese and Korean user interfaces often expose a character taken from the item's own label
as its access key, e.g. the MSAA shortcut for "打开..." is "Ctrl+O 打" and the one for "任务" is "Alt+任".
A Windows menu mnemonic has to be typed with a single key press, and Han, kana and hangul characters can only
be produced through an IME, which is not available while a menu is active.
Such an access key is therefore not actionable: it only makes NVDA repeat part of the label.

The rule implemented here is intentionally narrow:
only a shortcut made of a single character from an IME-composed script (optionally preceded by modifiers,
e.g. "Alt+任") is removed.
Everything else is kept untouched: accelerators like "Ctrl+O", Latin mnemonics like "T" (including those
contained in the label, which are useful in English menus), and mnemonics from scripts that can be typed
directly on a keyboard layout (Cyrillic, Greek, Arabic, Hebrew, Thai, Devanagari, ...).
"""

import re

# Code point ranges of the scripts that can only be entered through an IME.
# Each range is inclusive and sorted by start so that it can be searched with a bisection.
_IME_ONLY_RANGES: tuple[tuple[int, int], ...] = (
	(0x1100, 0x11FF),  # Hangul Jamo
	(0x2E80, 0x2FDF),  # CJK Radicals Supplement, Kangxi Radicals
	(0x3040, 0x309F),  # Hiragana
	(0x30A0, 0x30FF),  # Katakana
	(0x3100, 0x312F),  # Bopomofo
	(0x3130, 0x318F),  # Hangul Compatibility Jamo
	(0x31A0, 0x31BF),  # Bopomofo Extended
	(0x31F0, 0x31FF),  # Katakana Phonetic Extensions
	(0x3400, 0x4DBF),  # CJK Unified Ideographs Extension A
	(0x4E00, 0x9FFF),  # CJK Unified Ideographs
	(0xA960, 0xA97F),  # Hangul Jamo Extended-A
	(0xAC00, 0xD7AF),  # Hangul Syllables
	(0xD7B0, 0xD7FF),  # Hangul Jamo Extended-B
	(0xF900, 0xFAFF),  # CJK Compatibility Ideographs
	(0xFF66, 0xFFDC),  # Halfwidth Katakana and Halfwidth Hangul
	(0x1B000, 0x1B16F),  # Kana Supplement, Kana Extended-A, Small Kana Extension
	(0x20000, 0x323AF),  # CJK Unified Ideographs Extensions B to H and CJK Compatibility Ideographs Supplement
)

_WHITESPACE_RE = re.compile(r"(\s+)")


def isImeOnlyCharacter(char: str) -> bool:
	"""Whether the given character belongs to a script that can only be typed through an IME."""
	codePoint = ord(char)
	if codePoint < _IME_ONLY_RANGES[0][0]:
		return False
	return any(start <= codePoint <= end for start, end in _IME_ONLY_RANGES)


def isUnusableAccessKey(token: str) -> bool:
	"""Whether a single shortcut token is an access key that cannot be typed.

	The token is one whitespace-free part of a shortcut string, such as "Ctrl+O", "T", "Alt+任" or "打".
	The key is the last character, optionally preceded by modifier names joined with "+".
	Modifier names are not interpreted because they can be localized.
	"""
	if not token:
		return False
	key = token[-1]
	modifiers = token[:-1]
	if modifiers and not modifiers.endswith("+"):
		# Multi-character key names such as "Enter" or "F10", or a sequence like "Alt,".
		return False
	return isImeOnlyCharacter(key)


def filterShortcut(shortcut: str | None) -> tuple[str | None, list[str]]:
	"""Remove unusable access keys from a keyboard shortcut string.

	The shortcut may contain several shortcuts separated by whitespace.
	NVDA joins the UIA access key and accelerator key with two spaces, whereas MSAA providers return
	whatever string they like, so any run of whitespace is accepted as a separator.
	Separators between the tokens that are kept are left unchanged.

	@param shortcut: The value of an NVDA object's C{keyboardShortcut} property.
	@return: The filtered shortcut and the list of tokens that were removed.
		When nothing is removed, the original value is returned as is.
	"""
	if not shortcut:
		return shortcut, []
	# With a capturing group, split() returns tokens at even indexes and the separators at odd indexes.
	parts = _WHITESPACE_RE.split(shortcut.strip())
	tokens = parts[0::2]
	separators = parts[1::2]
	removed = [token for token in tokens if isUnusableAccessKey(token)]
	if not removed:
		return shortcut, []
	kept: list[str] = []
	for index, token in enumerate(tokens):
		if isUnusableAccessKey(token):
			continue
		# Use the separator that originally preceded this token, except for the first token kept.
		if kept:
			kept.append(separators[index - 1])
		kept.append(token)
	return "".join(kept), removed
