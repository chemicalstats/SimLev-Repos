"""Umgebungsschalter ``SIMLEV_*`` – die einzige Stelle, an der Python sie liest oder setzt.

Alle übrigen Stellen (Paket, Tests, Werkzeuge) holen die Werte über diese Funktionen. Jede
Funktion liest die Umgebung bei jedem Aufruf neu; wann gelesen wird, bestimmt der Aufrufer
(z. B. die Tests beim Laden, ``_collate`` beim ersten Vergleich nach ``collate_reset()``).

| Schalter | Zweck | Art |
|---|---|---|
| ``SIMLEV_COLLATE`` | Sortierung: ``icu:<Locale>`` (``icu:root`` wie R unter C.UTF-8) oder ``C`` (Bytes) | Nutzer |
| ``SIMLEV_ICU`` | Pfad zur ICU-Bibliothek (``libicui18n``) | Nutzer |
| ``SIMLEV_LAX_NA`` | ``1``: NA = NaN im Vergleich mit den Referenzfällen | Prüfung |
| ``SIMLEV_STRICT_ZERO`` | ``0``: −0 = +0 im Vergleich mit den Referenzfällen | Prüfung |

Seit 1.0.0 entfallen ``SIMLEV_NO_EXT`` (die C-Erweiterung ist
Pflicht, es gibt keine reinen Python-Kerne mehr), ``SIMLEV_LAPACK`` (keine System-LAPACK) und
``SIMLEV_R_SYS_TIME`` (feste Uhr für gosolnp), ``SIMLEV_LEGACY_TESTS`` (Tests neu aufgebaut, wirkte nicht mehr),
seit 1.4.2 ``SIMLEV_GOLDEN_DIR`` und ``SIMLEV_MODULE_DIR`` (Ordner der Fälle bis 1.4.0; die Tests lesen ``SIMLEV_FAELLE_DIR``).
"""
import os

__all__ = ["SWITCHES", "collate", "icu_path", "lax_na", "strict_zero", "set_collate_default"]

# Name -> (Zweck, Art); Art: Nutzer, Prüfung (Julia zusätzlich: Entwicklung; R-Generatoren: Generator)
SWITCHES = {
    "SIMLEV_COLLATE": ("Sortierung: icu:<Locale> (icu:root wie R unter C.UTF-8) oder C (Bytes)", "Nutzer"),
    "SIMLEV_ICU": ("Pfad zur ICU-Bibliothek (libicui18n)", "Nutzer"),
    "SIMLEV_LAX_NA": ("1: NA = NaN im Vergleich mit den Referenzfällen", "Prüfung"),
    "SIMLEV_STRICT_ZERO": ("0: -0 = +0 im Vergleich mit den Referenzfällen", "Prüfung"),
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

