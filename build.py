"""Builds dist/<name>-<version>.nvda-addon from the addon folder, without needing scons or gettext.

Usage: python build.py
"""

import ast
import pathlib
import re
import struct
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent
ADDON_DIR = ROOT / "addon"
DIST_DIR = ROOT / "dist"
EXCLUDED_DIR_NAMES = {"__pycache__"}
EXCLUDED_SUFFIXES = {".pyc", ".po"}


def readManifestValue(key: str) -> str:
	# NVDA reads manifest.ini with ConfigObj, whose multi-line values configparser cannot parse.
	# Single-line keys such as name and version are all that is needed here.
	text = (ADDON_DIR / "manifest.ini").read_text(encoding="utf-8")
	match = re.search(rf"^{re.escape(key)}\s*=\s*(.+?)\s*$", text, re.MULTILINE)
	if not match:
		raise KeyError(f"{key} not found in manifest.ini")
	return match.group(1).strip('"')


def parsePo(path: pathlib.Path) -> dict[str, str]:
	"""Minimal .po parser: msgid/msgstr pairs only, no contexts or plurals."""
	entries: dict[str, str] = {}
	msgid = msgstr = None
	current = None
	for lineNumber, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
		line = line.strip()
		if not line or line.startswith("#"):
			continue
		if line.startswith(("msgctxt", "msgid_plural", "msgstr[")):
			raise ValueError(f"{path}:{lineNumber}: contexts and plurals are not supported")
		if line.startswith("msgid "):
			if msgid is not None:
				entries[msgid] = msgstr or ""
			msgid, msgstr, current = ast.literal_eval(line[6:]), None, "msgid"
		elif line.startswith("msgstr "):
			msgstr, current = ast.literal_eval(line[7:]), "msgstr"
		elif line.startswith('"'):
			text = ast.literal_eval(line)
			if current == "msgid":
				msgid += text
			elif current == "msgstr":
				msgstr += text
		else:
			raise ValueError(f"{path}:{lineNumber}: unexpected line {line!r}")
	if msgid is not None:
		entries[msgid] = msgstr or ""
	return entries


def compileMo(entries: dict[str, str]) -> bytes:
	"""Serialize translations in the GNU .mo format, leaving out untranslated entries."""
	items = sorted((k.encode("utf-8"), v.encode("utf-8")) for k, v in entries.items() if v or not k)
	count = len(items)
	keysOffset = 7 * 4 + 16 * count
	valuesOffset = keysOffset + sum(len(k) + 1 for k, _ in items)
	keyTable, valueTable = [], []
	keyData, valueData = b"", b""
	for key, value in items:
		keyTable.append((len(key), keysOffset + len(keyData)))
		keyData += key + b"\0"
		valueTable.append((len(value), valuesOffset + len(valueData)))
		valueData += value + b"\0"
	header = struct.pack("<7I", 0x950412DE, 0, count, 7 * 4, 7 * 4 + 8 * count, 0, 0)
	tables = b"".join(struct.pack("<2I", *pair) for pair in keyTable + valueTable)
	return header + tables + keyData + valueData


def buildMoFiles() -> list[pathlib.Path]:
	built = []
	for po in ADDON_DIR.glob("locale/*/LC_MESSAGES/nvda.po"):
		mo = po.with_suffix(".mo")
		mo.write_bytes(compileMo(parsePo(po)))
		built.append(mo)
	return built


def main() -> None:
	name, version = readManifestValue("name"), readManifestValue("version")
	moFiles = buildMoFiles()
	DIST_DIR.mkdir(exist_ok=True)
	target = DIST_DIR / f"{name}-{version}.nvda-addon"
	with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
		for path in sorted(ADDON_DIR.rglob("*")):
			relative = path.relative_to(ADDON_DIR)
			if path.is_dir() or EXCLUDED_DIR_NAMES & set(relative.parts) or path.suffix in EXCLUDED_SUFFIXES:
				continue
			archive.write(path, relative.as_posix())
	# The .mo files only exist to be packaged.
	for mo in moFiles:
		mo.unlink()
	print(f"Built {target}")


if __name__ == "__main__":
	main()
