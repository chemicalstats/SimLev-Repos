"""Zeichenketten-Kollation wie R 4.3.3 (``Scollate`` in ``src/main/util.c``).

R vergleicht und sortiert Zeichenketten (``sort``, ``order``, ``rank``,
``factor``-Stufen, ``table``, ``split``, ``<``/``>``, ``min``/``max``) nicht
nach Codepunkten, sondern mit ``Scollate``:

* Ist ``LC_ALL`` (oder, wenn leer, ``LC_COLLATE``) ``"C"``, oder ist das
  Kollations-Locale ``"C"``/``"POSIX"`` (``R_ICU_LOCALE``, sonst das Locale
  aus ``LC_ALL``/``LC_COLLATE``/``LANG``), nimmt R ``strcoll`` im C-Locale,
  also die Byte-Reihenfolge der UTF-8-Kodierung.
* Sonst öffnet R über ICU ``uloc_setDefault(<locale>)`` und
  ``ucol_open(NULL)`` einen Collator, ohne Attribute zu setzen, und
  vergleicht mit ``ucol_strcollIter`` (UTF-8). Unter ``LC_ALL=C.UTF-8`` ist
  das der Collator ``"root"`` (``icuGetCollate()``): ``a A b B``.

Hier dasselbe über ctypes mit der System-ICU (``libicui18n.so.<N>``; die
Funktionen tragen das Versionssuffix ``_<N>``, das automatisch ermittelt
wird; Pfad über ``$SIMLEV_ICU``). ``SIMLEV_COLLATE=C`` erzwingt die
Byte-Reihenfolge (wie R unter ``LC_ALL=C``), ``SIMLEV_COLLATE=icu:root`` die ICU-Kollation
„root“ (wie R unter ``LC_ALL=C.UTF-8``) unabhängig vom Locale. Ohne ICU wird nach Codepunkten
verglichen, mit einer einmaligen Warnung (nicht bitgleich zu R).
"""
from __future__ import annotations

import ctypes
import ctypes.util
import glob
import os
import re
import warnings

from . import env as _env

__all__ = ["str_collate", "collate_key", "collate_mode", "collate_reset", "r_key"]

_ST = {"init": False, "mode": None, "coll": None, "lib": None, "f": {}, "warned": False}


def _env_collate_locale():
    """(useC, locale) wie R's ``Scollate``/``getLocale`` auf Unix."""
    sc = _env.collate()
    if sc.lower().startswith("icu:"):          # ICU mit festem Locale, unabhängig von LC_ALL
        return False, sc[4:] or "root"
    envl = os.environ.get("LC_ALL") or os.environ.get("LC_COLLATE") or ""
    use_c = envl == "C"
    p = os.environ.get("R_ICU_LOCALE")
    if p:
        return use_c, p
    # setlocale(LC_COLLATE, "") beim Start von R
    loc = os.environ.get("LC_ALL") or os.environ.get("LC_COLLATE") or os.environ.get("LANG") or "C"
    return use_c, loc


def _icu_candidates():
    cands = []
    env = _env.icu_path()
    if env:
        cands.append(env)
    for d in ("/usr/lib/x86_64-linux-gnu", "/lib/x86_64-linux-gnu", "/usr/lib/aarch64-linux-gnu",
              "/usr/lib64", "/usr/lib", "/usr/local/lib", "/opt/homebrew/opt/icu4c/lib",
              "/usr/local/opt/icu4c/lib"):
        hits = glob.glob(os.path.join(d, "libicui18n.so.[0-9]*")) + glob.glob(os.path.join(d, "libicui18n.[0-9]*.dylib"))
        hits = [h for h in hits if re.search(r"libicui18n\.(so\.\d+|\d+\.dylib)$", h)]
        cands += sorted(hits, key=lambda h: -int(re.findall(r"\d+", os.path.basename(h))[0]))
    fl = ctypes.util.find_library("icui18n")
    if fl:
        cands.append(fl)
    return env, cands


def _suffixes(lib, path):
    m = re.search(r"libicui18n\.(?:so\.)?(\d+)", os.path.basename(path))
    out = []
    if m:
        out.append("_" + m.group(1))
    out.append("")
    out += ["_%d" % v for v in range(99, 39, -1)]
    for suf in out:
        try:
            getattr(lib, "ucol_open" + suf)
            return suf
        except AttributeError:
            continue
    return None


def _load_icu():
    env, cands = _icu_candidates()
    for c in cands:
        try:
            lib = ctypes.CDLL(c)
        except OSError:
            lib = None
        suf = _suffixes(lib, c) if lib is not None else None
        if suf is None:
            if env and c == env:
                warnings.warn("SIMLEV_ICU=%s: keine ICU-Bibliothek (libicui18n) mit ucol_open ladbar; "
                              "suche die System-ICU." % env, stacklevel=4)
            continue
        f = {}
        try:
            for nm in ("ucol_open", "ucol_close", "uloc_setDefault"):
                f[nm] = getattr(lib, nm + suf)
        except AttributeError:
            continue
        for nm in ("ucol_strcollUTF8", "ucol_strcoll", "ucol_getSortKey", "ucol_getLocaleByType"):
            try:
                f[nm] = getattr(lib, nm + suf)
            except AttributeError:
                pass
        if "ucol_strcollUTF8" not in f and "ucol_strcoll" not in f:
            continue
        P = ctypes.c_void_p
        I = ctypes.c_int
        f["ucol_open"].restype = P
        f["ucol_open"].argtypes = [ctypes.c_char_p, ctypes.POINTER(I)]
        f["ucol_close"].restype = None
        f["ucol_close"].argtypes = [P]
        f["uloc_setDefault"].restype = None
        f["uloc_setDefault"].argtypes = [ctypes.c_char_p, ctypes.POINTER(I)]
        if "ucol_strcollUTF8" in f:
            f["ucol_strcollUTF8"].restype = I
            f["ucol_strcollUTF8"].argtypes = [P, ctypes.c_char_p, I, ctypes.c_char_p, I, ctypes.POINTER(I)]
        if "ucol_strcoll" in f:
            f["ucol_strcoll"].restype = I
            f["ucol_strcoll"].argtypes = [P, ctypes.c_char_p, I, ctypes.c_char_p, I]
        if "ucol_getSortKey" in f:
            f["ucol_getSortKey"].restype = I
            f["ucol_getSortKey"].argtypes = [P, ctypes.c_char_p, I, ctypes.c_char_p, I]
        if "ucol_getLocaleByType" in f:
            f["ucol_getLocaleByType"].restype = ctypes.c_char_p
            f["ucol_getLocaleByType"].argtypes = [P, I, ctypes.POINTER(I)]
        return lib, f
    return None, None


def _init():
    if _ST["init"]:
        return
    _ST["init"] = True
    sc = _env.collate()
    if sc.upper() in ("C", "POSIX", "BYTES"):
        _ST["mode"] = "bytes"
        return
    use_c, loc = _env_collate_locale()
    if use_c or loc in ("C", "POSIX"):
        _ST["mode"] = "bytes"
        return
    lib, f = _load_icu()
    if lib is None:
        _ST["mode"] = "codepoint"
        return
    st = ctypes.c_int(0)
    f["uloc_setDefault"](loc.encode(), ctypes.byref(st))
    if st.value > 0:
        raise RuntimeError("failed to set ICU locale (%d)" % st.value)
    st = ctypes.c_int(0)
    coll = f["ucol_open"](None, ctypes.byref(st))
    if st.value > 0 or not coll:
        raise RuntimeError("failed to open ICU collator (%d)" % st.value)
    _ST.update(mode="icu", coll=coll, lib=lib, f=f)


def collate_reset():
    """Liest ``SIMLEV_COLLATE``/``SIMLEV_ICU``/Locale-Variablen neu ein."""
    if _ST["coll"] is not None:
        _ST["f"]["ucol_close"](_ST["coll"])
    _ST.update(init=False, mode=None, coll=None, lib=None, f={}, warned=False)


def collate_mode():
    """``"icu"`` (wie R), ``"bytes"`` (C-Locale) oder ``"codepoint"`` (Ersatzweg ohne ICU)."""
    _init()
    return _ST["mode"]


def collate_locale():
    """Locale des ICU-Collators (wie ``icuGetCollate()``), sonst ``None``."""
    _init()
    if _ST["mode"] != "icu" or "ucol_getLocaleByType" not in _ST["f"]:
        return None
    st = ctypes.c_int(0)
    r = _ST["f"]["ucol_getLocaleByType"](_ST["coll"], 0, ctypes.byref(st))
    return r.decode() if r else None


def _warn_cp():
    if not _ST["warned"]:
        _ST["warned"] = True
        warnings.warn("Zeichenketten-Kollation: keine ICU-Bibliothek (libicui18n) gefunden, Vergleich nach "
                      "Codepunkten (nicht bitgleich zu R; Pfad über SIMLEV_ICU setzen, SIMLEV_COLLATE=C für "
                      "Byte-Reihenfolge).", stacklevel=4)


def _u16(s):
    b = s.encode("utf-16-le", "surrogatepass")
    return b, len(b) // 2


def str_collate(a, b):
    """Vergleich zweier Zeichenketten wie R's ``Scollate``: -1, 0 oder 1."""
    _init()
    mode = _ST["mode"]
    if mode == "icu":
        f = _ST["f"]
        if "ucol_strcollUTF8" in f:
            ab = a.encode("utf-8", "surrogateescape")
            bb = b.encode("utf-8", "surrogateescape")
            st = ctypes.c_int(0)
            r = f["ucol_strcollUTF8"](_ST["coll"], ab, len(ab), bb, len(bb), ctypes.byref(st))
            if st.value > 0:
                raise RuntimeError("could not collate using ICU")
            return int(r)
        ua, na = _u16(a)
        ub, nb = _u16(b)
        return int(f["ucol_strcoll"](_ST["coll"], ua, na, ub, nb))
    if mode == "bytes":
        ab = a.encode("utf-8", "surrogateescape")
        bb = b.encode("utf-8", "surrogateescape")
    else:
        _warn_cp()
        ab, bb = a, b
    return -1 if ab < bb else (1 if ab > bb else 0)


def collate_key(s):
    """Sortierschlüssel: ``key(a) < key(b)`` genau dann, wenn ``str_collate(a, b) < 0``."""
    _init()
    mode = _ST["mode"]
    if mode == "icu":
        f = _ST["f"]
        if "ucol_getSortKey" in f:
            u, n = _u16(s)
            size = 64 + 4 * n
            while True:
                buf = ctypes.create_string_buffer(size)
                need = f["ucol_getSortKey"](_ST["coll"], u, n, buf, size)
                if need <= size:
                    # ohne die abschließende 0 (Sortierschlüssel sind 0-terminiert)
                    return buf.raw[:max(need - 1, 0)]
                size = need
        import functools
        return functools.cmp_to_key(str_collate)(s)
    if mode == "bytes":
        return s.encode("utf-8", "surrogateescape")
    _warn_cp()
    return s


def r_key(v):
    """Sortierschlüssel mit R's Reihenfolge: Zeichenketten über :func:`collate_key`, sonst ``v``."""
    return collate_key(v) if isinstance(v, str) else v
