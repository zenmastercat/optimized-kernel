"""Print scripts/config arguments that switch safety-group modules back on.

Usage: reenable-safety.py FULL_CONFIG TRIMMED_CONFIG SAFETY_LIST

SAFETY_LIST holds one Kconfig path per line, relative to the kernel source:
a path ending in "/" means every Kconfig file below that directory, any other
path is a single Kconfig file. A symbol defined there is switched back to a
module when the full (CachyOS) config has it as "=m" and the trimmed config
does not. Built-in options are never changed.
"""
import pathlib
import re
import sys

full_path, trimmed_path, safety_path = sys.argv[1:4]
symbol_re = re.compile(r"^\s*(?:menu)?config\s+([A-Za-z0-9_]+)\s*$")


def read_config(path):
    values = {}
    for line in pathlib.Path(path).read_text().splitlines():
        if line.startswith("CONFIG_") and "=" in line:
            key, value = line.split("=", 1)
            values[key[len("CONFIG_"):]] = value
    return values


def kconfig_files(entry):
    p = pathlib.Path(entry)
    if entry.endswith("/"):
        if p.is_dir():
            yield from sorted(p.rglob("Kconfig*"))
    elif p.is_file():
        yield p


full = read_config(full_path)
trimmed = read_config(trimmed_path)
symbols = set()
missing = []
for raw in pathlib.Path(safety_path).read_text().splitlines():
    entry = raw.split("#", 1)[0].strip()
    if not entry:
        continue
    files = list(kconfig_files(entry))
    if not files:
        missing.append(entry)
    for f in files:
        for line in f.read_text(errors="replace").splitlines():
            m = symbol_re.match(line)
            if m:
                symbols.add(m.group(1))

restore = sorted(s for s in symbols if full.get(s) == "m" and trimmed.get(s) not in ("m", "y"))
for s in restore:
    print("--module", s)
print(f"safety groups: {len(symbols)} symbols, {len(restore)} modules switched back on", file=sys.stderr)
for entry in missing:
    print(f"warning: safety path not found in this kernel: {entry}", file=sys.stderr)
