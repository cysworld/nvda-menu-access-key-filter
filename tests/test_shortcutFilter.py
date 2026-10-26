"""Unit tests for the pure filtering logic. They do not need NVDA.

Run from the repository root with: python -I -m unittest discover -s tests -v
"""

import importlib.util
import pathlib
import unittest

_MODULE_PATH = (
	pathlib.Path(__file__).resolve().parent.parent
	/ "addon"
	/ "globalPlugins"
	/ "menuAccessKeyFilter"
	/ "shortcutFilter.py"
)
_spec = importlib.util.spec_from_file_location("shortcutFilter", _MODULE_PATH)
shortcutFilter = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(shortcutFilter)

filterShortcut = shortcutFilter.filterShortcut


class TestIssueExamples(unittest.TestCase):
	"""The two examples from nvaccess/nvda#20912."""

	def test_bookworm_openKeepsAcceleratorDropsMnemonic(self):
		self.assertEqual(filterShortcut("Ctrl+O 打"), ("Ctrl+O", ["打"]))

	def test_bookworm_withUiaSeparator(self):
		self.assertEqual(filterShortcut("打  Ctrl+O"), ("Ctrl+O", ["打"]))

	def test_idm_tasksMenuDropsWholeShortcut(self):
		self.assertEqual(filterShortcut("Alt+任"), ("", ["Alt+任"]))


class TestValuesProbedFromWindows(unittest.TestCase):
	"""accKeyboardShortcut values returned by oleacc for native Win32 menus, captured on Windows 11.

	Menu bar: "&任务", "文件(&F)", "无助记符" (no ampersand), "Plain" (no ampersand).
	Popup menu: "&打开...\\tCtrl+O", "保存\\tCtrl+S", "导出(&E)\\tCtrl+E".
	For popup items the accelerator is part of the accessible name, not of the shortcut.
	"""

	def test_removed(self):
		for value in ("Alt+任", "Alt+无", "打", "保"):
			with self.subTest(value=value):
				self.assertEqual(filterShortcut(value), ("", [value]))

	def test_kept(self):
		for value in ("Alt+f", "Alt+p", "e"):
			with self.subTest(value=value):
				self.assertEqual(filterShortcut(value), (value, []))


class TestValuesLeftUntouched(unittest.TestCase):
	def assertUnchanged(self, shortcut):
		filtered, removed = filterShortcut(shortcut)
		self.assertEqual(filtered, shortcut)
		self.assertEqual(removed, [])

	def test_none(self):
		self.assertUnchanged(None)

	def test_empty(self):
		self.assertUnchanged("")

	def test_accelerator(self):
		self.assertUnchanged("Ctrl+O")

	def test_latinMnemonicContainedInLabel(self):
		"""English menus: "Open" with access key "O" is useful and must be kept."""
		self.assertUnchanged("O")
		self.assertUnchanged("Alt+O")

	def test_latinMnemonicOnChineseLabel(self):
		"""The usual Chinese convention, "文件(&F)"."""
		self.assertUnchanged("Alt+F")
		self.assertUnchanged("F")

	def test_acceleratorPlusLatinMnemonic(self):
		self.assertUnchanged("Ctrl+O  O")

	def test_multiCharacterKeyNames(self):
		self.assertUnchanged("Enter")
		self.assertUnchanged("Ctrl+Shift+F10")
		self.assertUnchanged("Delete")

	def test_plusKey(self):
		self.assertUnchanged("Ctrl++")

	def test_ribbonSequence(self):
		self.assertUnchanged("Alt, F, L, Y 1")

	def test_multiCharacterCjkIsNotAnAccessKey(self):
		"""Only a single key can be an access key. Anything longer is left to the application."""
		self.assertUnchanged("Alt+任务")
		self.assertUnchanged("任务")

	def test_localizedModifierNames(self):
		self.assertUnchanged("Strg+O")
		self.assertUnchanged("Ctrl+Alt+Entf")


class TestScriptMatrix(unittest.TestCase):
	"""Characters that can be typed directly on a keyboard layout must never be filtered.

	One representative per script used by the languages NVDA is translated into.
	"""

	TYPABLE = {
		"Latin": "T",
		"Latin with diacritic": "Ü",
		"Latin extended (Vietnamese)": "ế",
		"Cyrillic": "Ф",
		"Greek": "Φ",
		"Arabic": "م",
		"Hebrew": "ק",
		"Thai": "ก",
		"Devanagari": "क",
		"Tamil": "க",
		"Kannada": "ಕ",
		"Georgian": "ა",
		"Armenian": "Ա",
		"Ethiopic": "አ",
		"Fullwidth Latin": "Ａ",
		"Digit": "1",
		"Punctuation": "?",
		"CJK punctuation": "。",
	}

	IME_ONLY = {
		"Han": "任",
		"Han (extension A)": "㐀",
		"Han (extension B)": "\U00020000",
		"Han compatibility": "豈",
		"Hiragana": "ひ",
		"Katakana": "カ",
		"Halfwidth katakana": "ｶ",
		"Hangul syllable": "한",
		"Hangul jamo": "ㄱ",
		"Bopomofo": "ㄅ",
	}

	def test_typableCharactersAreKept(self):
		for script, char in self.TYPABLE.items():
			with self.subTest(script=script):
				self.assertEqual(filterShortcut(char), (char, []))
				self.assertEqual(filterShortcut(f"Alt+{char}"), (f"Alt+{char}", []))

	def test_imeOnlyCharactersAreRemoved(self):
		for script, char in self.IME_ONLY.items():
			with self.subTest(script=script):
				self.assertEqual(filterShortcut(char), ("", [char]))
				self.assertEqual(filterShortcut(f"Alt+{char}"), ("", [f"Alt+{char}"]))
				self.assertEqual(filterShortcut(f"Ctrl+S  {char}"), ("Ctrl+S", [char]))


class TestSeparators(unittest.TestCase):
	def test_unusableTokenInTheMiddle(self):
		self.assertEqual(filterShortcut("Ctrl+O  打  F2"), ("Ctrl+O  F2", ["打"]))

	def test_unusableTokenFirst(self):
		self.assertEqual(filterShortcut("打 Ctrl+O"), ("Ctrl+O", ["打"]))

	def test_severalUnusableTokens(self):
		self.assertEqual(filterShortcut("Alt+任  打"), ("", ["Alt+任", "打"]))

	def test_surroundingWhitespaceIgnored(self):
		self.assertEqual(filterShortcut("  Ctrl+O 打 "), ("Ctrl+O", ["打"]))


if __name__ == "__main__":
	unittest.main()
