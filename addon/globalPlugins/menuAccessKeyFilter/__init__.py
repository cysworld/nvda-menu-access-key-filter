# Menu Access Key Filter, an add-on for NVDA
# Prototype for https://github.com/nvaccess/nvda/issues/20912
# This file may be used under the terms of the GNU General Public License, version 2 or later.

"""Stops NVDA from reporting access keys of menu items that cannot be typed.

For CJK menus, the accessibility API often returns a character of the label as the access key
(for example "Ctrl+O 打" for "打开..."), which NVDA then reads out as if it were useful.
This global plugin strips such values from the C{keyboardShortcut} property of menu related objects.
Speech, braille and the "report shortcut key" command all read that property, so all of them are fixed at once.
"""

import addonHandler
import controlTypes
import globalPluginHandler
import ui
from logHandler import log
from NVDAObjects import NVDAObject
from scriptHandler import script

from . import shortcutFilter

addonHandler.initTranslation()

_MENU_ROLES = frozenset(
	{
		controlTypes.Role.MENU,
		controlTypes.Role.POPUPMENU,
		controlTypes.Role.MENUITEM,
		controlTypes.Role.CHECKMENUITEM,
		controlTypes.Role.RADIOMENUITEM,
	},
)

filterEnabled = True
"""Whether unusable access keys are currently removed. Toggled with a script to compare both behaviours."""


class MenuShortcutOverlay(NVDAObject):
	"""Overlay for menu related objects which hides access keys that cannot be typed."""

	def _get_keyboardShortcut(self):
		shortcut = super()._get_keyboardShortcut()
		if not filterEnabled:
			return shortcut
		filtered, removed = shortcutFilter.filterShortcut(shortcut)
		if removed:
			log.debug(
				f"Removed unusable access key(s) {removed!r} from shortcut {shortcut!r} "
				f"of {self.role!r} named {self.name!r}",
			)
		return filtered


class GlobalPlugin(globalPluginHandler.GlobalPlugin):
	# Translators: The name of the category in the Input gestures dialog for this add-on's commands.
	scriptCategory = _("Menu access key filter")

	def chooseNVDAObjectOverlayClasses(self, obj, clsList):
		if obj.role in _MENU_ROLES:
			clsList.insert(0, MenuShortcutOverlay)

	@script(
		# Translators: The description of the command that toggles the filtering of unusable menu access keys.
		description=_("Toggles the removal of menu access keys that cannot be typed, such as Chinese characters"),
	)
	def script_toggleFilter(self, gesture):
		global filterEnabled
		filterEnabled = not filterEnabled
		if filterEnabled:
			# Translators: Reported when the removal of unusable menu access keys is turned on.
			ui.message(_("Unusable menu access keys hidden"))
		else:
			# Translators: Reported when the removal of unusable menu access keys is turned off.
			ui.message(_("Unusable menu access keys reported"))
