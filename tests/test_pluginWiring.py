"""Checks how the global plugin hooks into NVDA, using minimal stand-ins for the NVDA modules it imports.

This cannot prove that the real NVDA behaves the same way. It only guards the plugin's own logic
(role selection, MRO with the overlay, toggling) against regressions.
"""

import enum
import importlib.util
import pathlib
import sys
import types
import unittest

_PACKAGE_DIR = (
	pathlib.Path(__file__).resolve().parent.parent / "addon" / "globalPlugins" / "menuAccessKeyFilter"
)


class _Role(enum.Enum):
	MENU = enum.auto()
	POPUPMENU = enum.auto()
	MENUITEM = enum.auto()
	CHECKMENUITEM = enum.auto()
	RADIOMENUITEM = enum.auto()
	BUTTON = enum.auto()


class _FakeNVDAObject:
	role = None
	name = ""

	def _get_keyboardShortcut(self):
		return ""


class _FakeGlobalPlugin:
	def chooseNVDAObjectOverlayClasses(self, obj, clsList):
		pass


def _installNvdaStubs():
	messages = []
	stubs = {
		"addonHandler": types.SimpleNamespace(initTranslation=lambda: None),
		"controlTypes": types.SimpleNamespace(Role=_Role),
		"globalPluginHandler": types.SimpleNamespace(GlobalPlugin=_FakeGlobalPlugin),
		"ui": types.SimpleNamespace(message=messages.append),
		"logHandler": types.SimpleNamespace(log=types.SimpleNamespace(debug=lambda *a, **k: None)),
		"NVDAObjects": types.SimpleNamespace(NVDAObject=_FakeNVDAObject),
		"scriptHandler": types.SimpleNamespace(script=lambda **kwargs: (lambda f: f)),
	}
	previous = {name: sys.modules.get(name) for name in stubs}
	sys.modules.update(stubs)
	# addonHandler.initTranslation() normally injects "_" into the importing module.
	import builtins

	hadUnderscore = hasattr(builtins, "_")
	if not hadUnderscore:
		builtins._ = lambda s: s
	return messages, previous, hadUnderscore


class TestPluginWiring(unittest.TestCase):
	@classmethod
	def setUpClass(cls):
		cls.messages, cls._previousModules, cls._hadUnderscore = _installNvdaStubs()
		spec = importlib.util.spec_from_file_location(
			"menuAccessKeyFilter",
			_PACKAGE_DIR / "__init__.py",
			submodule_search_locations=[str(_PACKAGE_DIR)],
		)
		cls.plugin = importlib.util.module_from_spec(spec)
		sys.modules["menuAccessKeyFilter"] = cls.plugin
		spec.loader.exec_module(cls.plugin)

	@classmethod
	def tearDownClass(cls):
		sys.modules.pop("menuAccessKeyFilter", None)
		sys.modules.pop("menuAccessKeyFilter.shortcutFilter", None)
		for name, module in cls._previousModules.items():
			if module is None:
				sys.modules.pop(name, None)
			else:
				sys.modules[name] = module
		if not cls._hadUnderscore:
			import builtins

			del builtins._

	def setUp(self):
		self.plugin.filterEnabled = True
		self.messages.clear()

	def _makeObject(self, role, shortcut):
		"""Build an object the way NVDA does: a dynamic class with the overlay in front of the API class."""

		class FakeIAccessible(_FakeNVDAObject):
			def _get_keyboardShortcut(self):
				return shortcut

		obj = FakeIAccessible()
		obj.role = role
		clsList = [FakeIAccessible]
		self.plugin.GlobalPlugin().chooseNVDAObjectOverlayClasses(obj, clsList)
		obj.__class__ = type("Dynamic", tuple(clsList), {})
		return obj, clsList

	def test_menuRolesGetTheOverlay(self):
		for role in (
			_Role.MENU,
			_Role.POPUPMENU,
			_Role.MENUITEM,
			_Role.CHECKMENUITEM,
			_Role.RADIOMENUITEM,
		):
			with self.subTest(role=role):
				_, clsList = self._makeObject(role, "Ctrl+O 打")
				self.assertIs(clsList[0], self.plugin.MenuShortcutOverlay)

	def test_otherRolesDoNotGetTheOverlay(self):
		_, clsList = self._makeObject(_Role.BUTTON, "Alt+确")
		self.assertNotIn(self.plugin.MenuShortcutOverlay, clsList)

	def test_overlayFiltersTheShortcutOfTheWrappedClass(self):
		obj, _ = self._makeObject(_Role.MENUITEM, "Ctrl+O 打")
		self.assertEqual(obj._get_keyboardShortcut(), "Ctrl+O")

	def test_overlayPassesThroughNoneAndLatinMnemonics(self):
		obj, _ = self._makeObject(_Role.MENUITEM, None)
		self.assertIsNone(obj._get_keyboardShortcut())
		obj, _ = self._makeObject(_Role.MENUITEM, "Alt+T")
		self.assertEqual(obj._get_keyboardShortcut(), "Alt+T")

	def test_toggleScript(self):
		obj, _ = self._makeObject(_Role.MENUITEM, "Alt+任")
		gp = self.plugin.GlobalPlugin()
		gp.script_toggleFilter(None)
		self.assertFalse(self.plugin.filterEnabled)
		self.assertEqual(obj._get_keyboardShortcut(), "Alt+任")
		gp.script_toggleFilter(None)
		self.assertTrue(self.plugin.filterEnabled)
		self.assertEqual(obj._get_keyboardShortcut(), "")
		self.assertEqual(len(self.messages), 2)


if __name__ == "__main__":
	unittest.main()
