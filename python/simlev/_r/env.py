"""Umgebungsschalter ``SIMLEV_*`` – die einzige Stelle, an der Python sie liest oder setzt.

Alle übrigen Stellen (Paket, Tests, Werkzeuge) holen die Werte über diese Funktionen. Jede
Funktion liest die Umgebung bei jedem Aufruf neu; wann gelesen wird, bestimmt der Aufrufer
(z. B. ``reftree`` beim Laden, ``_collate`` beim ersten Vergleich nach ``collate_reset()``).

| Schalter | Zweck | Art |
|---|---|---|
| ``SIMLEV_COLLATE`` | Sortierung: ``icu:<Locale>`` (``icu:root`` wie R unter C.UTF-8) oder ``C`` (Bytes) | Nutzer |
| ``SIMLEV_ICU`` | Pfad zur ICU-Bibliothek (``libicui18n``) | Nutzer |
| ``SIMLEV_LAX_NA`` | ``1``: NA = NaN im Vergleich mit den Referenzfällen | Prüfung |
| ``SIMLEV_STRICT_ZERO`` | ``0``: −0 = +0 im Vergleich mit den Referenzfällen | Prüfung |
| ``SIMLEV_GOLDEN_DIR`` | andere Ordner der Engine-Fälle für pytest (mit ``os.pathsep`` getrennt) | Prüfung |
| ``SIMLEV_MODULE_DIR`` | anderer Ordner der Modul-Fälle für pytest | Prüfung |
| ``SIMLEV_LEGACY_TESTS`` | ``1``: die alten Tests und Referenzvergleiche laufen (Etappe 9: sonst ausgesetzt) | Prüfung |

Seit Etappe 9.6c (Entwurf C.6 Nr. 10) entfallen ``SIMLEV_NO_EXT`` (die C-Erweiterung ist
Pflicht, es gibt keine reinen Python-Kerne mehr), ``SIMLEV_LAPACK`` (keine System-LAPACK) und
``SIMLEV_R_SYS_TIME`` (feste Uhr für gosolnp).
"""
import os

__all__ = ["SWITCHES", "collate", "icu_path", "lax_na", "strict_zero", "set_collate_default",
           "golden_dir", "module_dir", "legacy_tests"]

# Name -> (Zweck, Art); Art: Nutzer, Prüfung (Julia zusätzlich: Entwicklung; R-Generatoren: Generator)
SWITCHES = {
    "SIMLEV_COLLATE": ("Sortierung: icu:<Locale> (icu:root wie R unter C.UTF-8) oder C (Bytes)", "Nutzer"),
    "SIMLEV_ICU": ("Pfad zur ICU-Bibliothek (libicui18n)", "Nutzer"),
    "SIMLEV_LAX_NA": ("1: NA = NaN im Vergleich mit den Referenzfällen", "Prüfung"),
    "SIMLEV_STRICT_ZERO": ("0: -0 = +0 im Vergleich mit den Referenzfällen", "Prüfung"),
    "SIMLEV_GOLDEN_DIR": ("andere Ordner der Engine-Fälle für pytest (os.pathsep-getrennt)", "Prüfung"),
    "SIMLEV_MODULE_DIR": ("anderer Ordner der Modul-Fälle für pytest", "Prüfung"),
    "SIMLEV_LEGACY_TESTS": ("1: die alten Tests und Referenzvergleiche laufen (Etappe 9: sonst ausgesetzt)", "Prüfung"),
}


# ── Nutzer ──────────────────────────────────────────────────────────────────

def collate():
    """``SIMLEV_COLLATE`` (leer, wenn nicht gesetzt)."""
    return os.environ.get("SIMLEV_COLLATE", "")


def icu_path():
    """``SIMLEV_ICU`` oder ``None``."""
    return os.environ.get("SIMLEV_ICU")


# ── Prüfung ─────────────────────────────────────────────────────────────────

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


def legacy_tests():
    """``SIMLEV_LEGACY_TESTS=1``: die alten Tests (pytest) und Referenzvergleiche laufen; ohne den
    Schalter sind sie in Etappe 9 ausgesetzt (Entwurf C.7), nur die Rauchproben laufen."""
    return os.environ.get("SIMLEV_LEGACY_TESTS", "") == "1"
