"""Umgebungsschalter ``SIMLEV_*`` – die einzige Stelle, an der Python sie liest oder setzt.

Alle übrigen Stellen (Paket, Tests, Werkzeuge) holen die Werte über diese Funktionen. Jede
Funktion liest die Umgebung bei jedem Aufruf neu; wann gelesen wird, bestimmt der Aufrufer
(z. B. ``reftree`` beim Laden, ``_collate`` beim ersten Vergleich nach ``collate_reset()``).

| Schalter | Zweck | Art |
|---|---|---|
| ``SIMLEV_COLLATE`` | Sortierung: ``icu:<Locale>`` (``icu:root`` wie R unter C.UTF-8) oder ``C`` (Bytes) | Nutzer |
| ``SIMLEV_ICU`` | Pfad zur ICU-Bibliothek (``libicui18n``) | Nutzer |
| ``SIMLEV_LAPACK`` | Pfad zur Referenz-LAPACK (``dsyevr_``) | Nutzer |
| ``SIMLEV_R_SYS_TIME`` | feste Uhr für ``sys_time()`` (gosolnp), Sekunden seit 1970 | Prüfung |
| ``SIMLEV_LAX_NA`` | ``1``: NA = NaN im Vergleich mit den Referenzfällen | Prüfung |
| ``SIMLEV_STRICT_ZERO`` | ``0``: −0 = +0 im Vergleich mit den Referenzfällen | Prüfung |
| ``SIMLEV_GOLDEN_DIR`` | andere Ordner der Engine-Fälle für pytest (mit ``os.pathsep`` getrennt) | Prüfung |
| ``SIMLEV_MODULE_DIR`` | anderer Ordner der Modul-Fälle für pytest | Prüfung |
"""
import contextlib
import os

__all__ = ["SWITCHES", "collate", "icu_path", "lapack_path", "r_sys_time", "fixed_r_sys_time",
           "lax_na", "strict_zero", "set_collate_default", "golden_dir", "module_dir"]

# Name -> (Zweck, Art); Art: Nutzer, Prüfung (Julia zusätzlich: Entwicklung; R-Generatoren: Generator)
SWITCHES = {
    "SIMLEV_COLLATE": ("Sortierung: icu:<Locale> (icu:root wie R unter C.UTF-8) oder C (Bytes)", "Nutzer"),
    "SIMLEV_ICU": ("Pfad zur ICU-Bibliothek (libicui18n)", "Nutzer"),
    "SIMLEV_LAPACK": ("Pfad zur Referenz-LAPACK (dsyevr_)", "Nutzer"),
    "SIMLEV_R_SYS_TIME": ("feste Uhr für sys_time() (gosolnp), Sekunden seit 1970", "Prüfung"),
    "SIMLEV_LAX_NA": ("1: NA = NaN im Vergleich mit den Referenzfällen", "Prüfung"),
    "SIMLEV_STRICT_ZERO": ("0: -0 = +0 im Vergleich mit den Referenzfällen", "Prüfung"),
    "SIMLEV_GOLDEN_DIR": ("andere Ordner der Engine-Fälle für pytest (os.pathsep-getrennt)", "Prüfung"),
    "SIMLEV_MODULE_DIR": ("anderer Ordner der Modul-Fälle für pytest", "Prüfung"),
}


# ── Nutzer ──────────────────────────────────────────────────────────────────

def collate():
    """``SIMLEV_COLLATE`` (leer, wenn nicht gesetzt)."""
    return os.environ.get("SIMLEV_COLLATE", "")


def icu_path():
    """``SIMLEV_ICU`` oder ``None``."""
    return os.environ.get("SIMLEV_ICU")


def lapack_path():
    """``SIMLEV_LAPACK`` oder ``None``."""
    return os.environ.get("SIMLEV_LAPACK")


# ── Prüfung ─────────────────────────────────────────────────────────────────

def r_sys_time():
    """``SIMLEV_R_SYS_TIME`` als Text oder ``None``."""
    return os.environ.get("SIMLEV_R_SYS_TIME")


@contextlib.contextmanager
def fixed_r_sys_time(st):
    """Setzt ``SIMLEV_R_SYS_TIME`` auf ``st`` (Text oder Zahl) und danach zurück; ``None``: nichts."""
    if st is None:
        yield
        return
    name = "SIMLEV_R_SYS_TIME"
    old = os.environ.get(name)
    os.environ[name] = st if isinstance(st, str) else repr(float(st))
    try:
        yield
    finally:
        if old is None:
            os.environ.pop(name, None)
        else:
            os.environ[name] = old


def lax_na():
    """``SIMLEV_LAX_NA=1``: NA und NaN im Vergleich gleich (Voreinstellung: unterschieden)."""
    return os.environ.get("SIMLEV_LAX_NA", "0") == "1"


def strict_zero():
    """``SIMLEV_STRICT_ZERO`` ungleich ``0``: Vorzeichen der Null wird verglichen (Voreinstellung)."""
    return os.environ.get("SIMLEV_STRICT_ZERO", "1") != "0"


def set_collate_default(value="icu:root"):
    """Setzt ``SIMLEV_COLLATE`` auf ``value``, falls nicht gesetzt (Kollation der Referenzfälle)."""
    os.environ.setdefault("SIMLEV_COLLATE", value)


def golden_dir():
    """``SIMLEV_GOLDEN_DIR`` als Text oder ``None``."""
    return os.environ.get("SIMLEV_GOLDEN_DIR")


def module_dir():
    """``SIMLEV_MODULE_DIR`` als Text oder ``None``."""
    return os.environ.get("SIMLEV_MODULE_DIR")
