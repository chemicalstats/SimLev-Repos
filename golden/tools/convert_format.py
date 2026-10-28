"""Stellt die Referenzfälle unter ``golden/modules`` auf das Format 2 um.

Format 2: Eingaben, deren kanonische JSON-Form mindestens ``INLINE_MAX`` Bytes
lang ist, stehen je Modul einmal im Eingabespeicher ``<modul>/_inputs.json.gz``
(``{"format": 2, "module": …, "inputs": {<schlüssel>: <baum>, …}}``, Schlüssel
sortiert); der Fall trägt an ihrer Stelle den Verweis ``{"t": "ref", "k":
<schlüssel>}``. Der Schlüssel ist die MD5-Prüfsumme (hex) der kanonischen
Form: kompaktes JSON ohne Leerzeichen, UTF-8, Felder in der Reihenfolge des
Baums – genau der Text, den ``golden/modules/ref_tools.R`` (jsonlite) für die
Eingabe schreibt. Kleinere Eingaben bleiben im Fall. Der Konverter schreibt
denselben Text wie ``ref_tools.R`` und komprimiert, wenn vorhanden, wie dieses
mit ``gzip -9 -n`` (sonst mit dem Modul ``gzip``), sodass ein neu erzeugter
Fall dieselben Bytes ergibt.

Aufruf (nur Standardbibliothek, beliebig oft wiederholbar):

    python3 golden/tools/convert_format.py [modul ...] [--dir golden/modules] [-n]

Fälle im Format 1 (Eingaben vollständig im Fall) und schon umgestellte Fälle
werden gleich behandelt: Der Konverter löst alle Verweise auf und schreibt
Fall und Speicher neu; Dateien, deren Inhalt sich nicht ändert, bleiben
unberührt.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import shutil
import subprocess
import sys

INPUTS_FILE = "_inputs.json.gz"
INLINE_MAX = 256      # Eingaben mit kürzerer kanonischer Form bleiben im Fall
FORMAT = 2

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..", "modules")


def canonical(tree):
    """Kanonische JSON-Form (wie jsonlite::toJSON in ref_tools.R)."""
    return json.dumps(tree, separators=(",", ":"), ensure_ascii=False)


def key_of(text):
    return hashlib.md5(text.encode("utf-8")).hexdigest()


def read_json(path):
    with gzip.open(path, "rb") as fh:
        return json.loads(fh.read().decode("utf-8"))


def read_text(path):
    with gzip.open(path, "rb") as fh:
        return fh.read().decode("utf-8")


_GZIP = shutil.which("gzip")


def gz(text):
    data = text.encode("utf-8")
    if _GZIP:
        return subprocess.run([_GZIP, "-9", "-n", "-c"], input=data, check=True, capture_output=True).stdout
    return gzip.compress(data, 9, mtime=0)


def write_if_changed(path, text, dry):
    """Schreibt ``text`` gzip-komprimiert, falls sich der Inhalt ändert; True bei Änderung."""
    if os.path.exists(path) and read_text(path) == text:
        return False
    if not dry:
        tmp = path + ".tmp"
        with open(tmp, "wb") as fh:
            fh.write(gz(text))
        os.replace(tmp, path)
    return True


def case_files(d):
    return sorted(f for f in os.listdir(d) if f.endswith(".json.gz") and not f.startswith("_"))


def resolve(case, store, where):
    """Ersetzt Verweise in ``inputs`` durch die Bäume aus ``store`` (neues dict)."""
    inp = case.get("inputs")
    if not isinstance(inp, dict):
        return case
    out = {}
    for k, v in inp.items():
        if isinstance(v, dict) and v.get("t") == "ref":
            if v["k"] not in store:
                raise KeyError("%s: Eingabe %s (Schlüssel %s) fehlt im Speicher" % (where, k, v["k"]))
            v = store[v["k"]]
        out[k] = v
    case = dict(case)
    case["inputs"] = out
    return case


def convert_module(d, module, dry=False):
    sp = os.path.join(d, INPUTS_FILE)
    old_store = read_json(sp)["inputs"] if os.path.exists(sp) else {}
    store = {}
    n = changed = 0
    for f in case_files(d):
        p = os.path.join(d, f)
        case = resolve(read_json(p), old_store, p)
        inp = case.get("inputs")
        if isinstance(inp, dict):
            new = {}
            for k, v in inp.items():
                s = canonical(v)
                if len(s.encode("utf-8")) >= INLINE_MAX:
                    h = key_of(s)
                    store[h] = v
                    v = {"t": "ref", "k": h}
                new[k] = v
            case["inputs"] = new
        changed += write_if_changed(p, canonical(case) + "\n", dry)
        n += 1
    if store:
        doc = {"format": FORMAT, "module": module, "inputs": {k: store[k] for k in sorted(store)}}
        changed += write_if_changed(sp, canonical(doc) + "\n", dry)
    elif os.path.exists(sp):
        changed += 1
        if not dry:
            os.remove(sp)
    return n, len(store), changed


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("modules", nargs="*", help="Module (Standard: alle Unterordner)")
    ap.add_argument("--dir", default=ROOT, help="Ordner der Module (Standard: golden/modules)")
    ap.add_argument("-n", "--dry-run", action="store_true", help="nur zählen, nichts schreiben")
    a = ap.parse_args(argv)
    mods = a.modules or sorted(m for m in os.listdir(a.dir) if os.path.isdir(os.path.join(a.dir, m)))
    tn = ts = tc = 0
    for m in mods:
        n, s, c = convert_module(os.path.join(a.dir, m), m, a.dry_run)
        print("%-16s %5d Fälle, %4d Eingaben im Speicher, %5d Dateien geändert" % (m, n, s, c))
        tn += n; ts += s; tc += c
    print("Gesamt: %d Fälle, %d Eingaben im Speicher, %d Dateien %s" % (
        tn, ts, tc, "zu ändern" if a.dry_run else "geändert"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
