"""Bootstrap-Pfade für Indizes, Hebelprodukte und Signale (Gegenstück zu ``r/R/bootstrap.R``).

Öffentliche Funktionen:

- :func:`bootstrap_config` – Spezifikation (Indizes,
  Hebelprodukte, Zusatzreihen)
- :func:`bootstrap` – erzeugt Preis-Pfade im Speicher
- :func:`bootstrap_validate` – bereinigt ein Bootstrap-Ergebnis
- :func:`bootstrap_data` – ein Pfad als ``DataFrame`` für :func:`simlev.simulation`
- :func:`bootstrap_study` – Strategien auf Bootstrap-Pfaden auswerten
- :func:`bootstrap_study_metrics` – Standard-Kennzahlen einer Simulation
- :func:`bootstrap_probability` – Wahrscheinlichkeiten aus einer Studie
- :func:`bootstrap_block_length` – automatische Blocklänge (Politis & White 2004)

Verfahren: raw, block, circular, stationary, wild, regime, evt, tails, reset,
garch, gjr_garch, ms_garch, ms_ar_garch_m, tvtp_ms_garch (die MS-GARCH-Familie
schätzt ihr Modell wie R selbst, :mod:`simlev.ms_garch`).

Datenstrukturen: Pfade sind ``pandas.DataFrame`` (Spalten = Pfadnamen, eine
Zeile je Pfadzeile); die Niveau-Variante der Zusatzreihen steht in
``P.attrs["aux_level"]`` (Attribut ``aux_level`` in R). Zufallszahlen
ausschließlich aus der C-Bibliothek slc (:mod:`simlev._lib`): ein Strom je Pfad
U_i = J^i(S_0), gezogen über die Kerne slc_boot (:mod:`simlev._lib_models`), bitgleich zu R.
"""
from __future__ import annotations

import contextlib
import io
import math
import os
import pickle
import sys
import time
import warnings
import weakref
from collections.abc import Mapping

import numpy as np
import pandas as pd

from ._sim_base import _study_scope  # Prüf-Cache je Studie (seit 1.5.1)
from ._r import fmt as _fmt
from ._r.base import env_from_caller
from ._r import libm as _libm
from ._r import parallel as _par
from . import _ext
from . import _lib as _sl
from . import _lib_models as _slm
from ._r.rlist import RList
from ._r.rnum import r_cumprod, r_cumsum, r_mean, r_median, r_pow, r_sd, r_sum, r_var
from ._util import _match_arg
from .data_prep import _to_date
from ._util import _stats
from ._util import _fmt1, _is_strategy, _message, _pow_rec, _unique as _uniq
from ._r.rformat import _is_num

__all__ = [
    "bootstrap_config", "BootstrapConfig", "bootstrap_block_length", "bootstrap",
    "BootstrapResult", "bootstrap_validate", "bootstrap_data", "bootstrap_study_metrics", "bootstrap_study",
    "SimLevBootstrapStudy", "SummarySimLevBootstrapStudy", "bootstrap_probability", "summary",
    "plot",
]

_NAN = _fmt.NA_REAL      # R's NA_real_ (alle Verwendungen hier sind NA; NaN: math.nan)


# ═══════════════════════════════════════════════════════════════════════════
# Kleine R-Hilfen
# ═══════════════════════════════════════════════════════════════════════════

def _quiet(fn):
    """numpy-Gleitkommawarnungen unterdrücken (R warnt bei Arithmetik nicht)."""
    import functools

    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        with np.errstate(all="ignore"):
            return fn(*args, **kwargs)
    return wrapper


def _warn(text) -> None:
    warnings.warn(str(text), UserWarning, stacklevel=3)


def _stop(text):
    raise ValueError(str(text))


def _sp(fmt, *args) -> str:
    """R-``sprintf`` (Skalar)."""
    return _fmt.sprintf(fmt, *args)


def _show(x) -> str:
    """``paste(format(x), collapse = ", ")``."""
    if x is None:
        return ""
    if isinstance(x, (list, tuple)):
        x = np.asarray(x, dtype=object if any(isinstance(v, str) for v in x) else None)
    r = _fmt.format(x)
    if isinstance(r, str):
        return r
    return ", ".join(str(s) for s in np.asarray(r, dtype=object).ravel())


def _as_char(x) -> str:
    """``as.character`` einer Zahl (15 signifikante Stellen)."""
    r = _fmt.as_character(x)
    if isinstance(r, str):
        return r
    return str(np.asarray(r, dtype=object).ravel()[0])


def _num_vec(x):
    """Numerischer Vektor (float-Array) oder ``None``, wenn nicht numerisch."""
    if x is None:
        return None
    if isinstance(x, (bool, np.bool_, str)):
        return None
    if _is_num(x):
        return np.array([float(x)])
    if isinstance(x, pd.Series):
        x = x.to_numpy()
    if isinstance(x, (list, tuple)):
        if any(isinstance(v, (str, bool, np.bool_)) for v in x):
            return None
        try:
            return np.asarray(x, dtype=np.float64).ravel()
        except (TypeError, ValueError):
            return None
    if isinstance(x, np.ndarray):
        if x.dtype.kind in "iuf":
            return x.astype(np.float64).ravel()
        return None
    return None


def _num1(v) -> bool:
    """``is.numeric(v) && length(v) == 1L && is.finite(v)``."""
    a = _num_vec(v)
    return a is not None and a.size == 1 and math.isfinite(a[0])


def _get(x, name, default=None):
    """``x$name`` für dict-artige Objekte, Attribut-Objekte und ``None``."""
    if x is None:
        return default
    if isinstance(x, Mapping):
        v = x.get(name, default)
        return default if v is None else v
    try:
        v = x[name]
        return default if v is None else v
    except (KeyError, TypeError, IndexError, AttributeError):
        pass
    v = getattr(x, name, default)
    return default if v is None else v


def _names(x):
    """``names(x)`` für benannte Vektoren (dict, Series) oder ``None``."""
    if isinstance(x, pd.Series):
        if isinstance(x.index, pd.RangeIndex):
            return None
        return [str(k) for k in x.index]
    if isinstance(x, Mapping):
        return [str(k) for k in x.keys()]
    return None


def _values(x):
    if isinstance(x, pd.Series):
        return list(x.to_numpy())
    if isinstance(x, Mapping):
        return list(x.values())
    if isinstance(x, (list, tuple, np.ndarray)):
        return list(np.asarray(x, dtype=object).ravel())
    return [x]


def _nvec(names, values, dtype=object) -> pd.Series:
    """Benannter Vektor als ``Series`` (Duplikate erlaubt)."""
    return pd.Series(list(values), index=list(names), dtype=dtype)


def _duplicated(seq):
    seen = set()
    out = []
    for s in seq:
        out.append(s in seen)
        seen.add(s)
    return out


def _setdiff(a, b):
    out = []
    for v in a:
        if v not in b and v not in out:
            out.append(v)
    return out


def _r_round0(x: float) -> float:
    return float(_fmt.r_round(float(x), 0))


def _quantile7(x, probs):
    """``stats::quantile(x, probs, names = FALSE, type = 7)``."""
    st = _stats()
    r = st.quantile(np.asarray(x, dtype=np.float64), np.atleast_1d(np.asarray(probs, dtype=np.float64)),
                    names=False, type=7)
    return np.asarray(r, dtype=np.float64).ravel()


def _weighted_mean(x, w, na_rm=False) -> float:
    """``stats::weighted.mean(x, w, na.rm)`` (Standardmethode)."""
    x = np.asarray(x, dtype=np.float64).ravel()
    w = np.asarray(w, dtype=np.float64).ravel()
    if len(w) != len(x):
        _stop("'x' and 'w' must have the same length")
    if na_rm:
        i = ~np.isnan(x)
        w = w[i]
        x = x[i]
    xw = x * w
    return _div(r_sum(xw[w != 0]), r_sum(w))


def _rel_dates(d):
    """datetime64[D]-Array → int-Tage seit 1970."""
    a = np.asarray(d).astype("datetime64[D]")
    return a.astype(np.int64)


def _seq_dates(start, n):
    s = np.asarray(start).astype("datetime64[D]").ravel()[0]
    return s + np.arange(int(n)).astype("timedelta64[D]")


# ═══════════════════════════════════════════════════════════════════════════
# Zufall: Ströme aus simlev._lib; .par_lapply in _r.parallel
# ═══════════════════════════════════════════════════════════════════════════

# ``.par_lapply`` steht in Schicht 0 (``simlev._r.parallel``); dieser Name leitet weiter.
_par_lapply = _par.par_lapply


# ═══════════════════════════════════════════════════════════════════════════
# Konfiguration
# ═══════════════════════════════════════════════════════════════════════════

class BootstrapConfig(RList):
    """Bootstrap-Konfiguration (R-Klasse ``bootstrap_config``)."""

    r_class = ("bootstrap_config",)

    def format(self) -> str:
        return _strip1(_cat_config(self))


def _strip1(s: str) -> str:
    return s[:-1] if s.endswith("\n") else s


def _cat_config(x) -> str:
    out = ["SimLev Bootstrap-Konfiguration\n------------------------------\n"]
    idx = ", ".join("%s=%s" % (nm, ix["col"]) for nm, ix in zip(x["index_names"], x["indices"]))
    out.append("  Indizes:      %s\n" % idx)
    out.append("  Referenz:     %s (Kopplung: %s, Eingabe: %s)\n" % (x["regime_index"], x["cross"], x["input"]))
    if x["n_aux"]:
        sets = list(_get(x, "aux_type_set", []) or [])
        at = _get(x, "aux_type")
        parts = []
        for nm, col in zip(x["aux_names"], _values(x["aux"])):
            typ = " (%s)" % _aux_type_of(at, nm) if nm in sets else ""
            parts.append("%s=%s%s" % (nm, col, typ))
        out.append("  Zusatzreihen: %s\n" % ", ".join(parts))
    for lt in x["letfs"]:
        fin = lt["finance"]
        out.append(_sp("  Produkt %-8s Basis %s, L = %g, Zins = %s, TER = %g %%, Spread = %g %%\n",
                       lt["name"], lt["base"], float(lt["leverage"]), fin if isinstance(fin, str) else _fmt1(fin),
                       float(lt["expense"]), float(lt["spread"])))
    return "".join(out)


def _aux_type_of(at, nm):
    """``aux_type[[nm]]`` (oder ``None``)."""
    if at is None:
        return None
    if isinstance(at, pd.Series):
        if nm in at.index:
            v = at[nm]
            return v.iloc[0] if isinstance(v, pd.Series) else v
        return None
    if isinstance(at, Mapping):
        return at.get(nm)
    return None


def bootstrap_config(indices, *, letfs=(), regime_index=None, aux=None, aux_type=None,
                     cross=("ratio", "joint"), input=("returns", "prices")):  # noqa: A002
    """Bootstrap-Konfiguration erstellen.

    Beschreibt, welche Spalten eines Datensatzes gebootstrappt werden, welche Hebelprodukte (LETFs) daraus je Pfad
    abgeleitet werden und welche Zusatzreihen (Zinsen, Inflation, Kalendertage, ...) jeweils aus derselben
    historischen Zeile mitgezogen werden. Das Ergebnis ist die Eingabe ``config`` von ``bootstrap()`` und
    ``bootstrap_study()``.

    Args:
        indices: Benannter Zeichenvektor oder benannte Liste: Pfadname -> Spaltenname in ``data``, z. B. ``{"us":
            "us_index_l1_return", "eu": "eu_index_l1_return"}``. Die Pfadnamen werden zu Spaltennamen der
            erzeugten Pfade.
        letfs: Liste von Hebelprodukten (Standard: keine). Jedes Element ist eine Liste mit

            - base: Name des Basisindex (Pfadname aus ``indices``), Pflicht.
            - leverage: Hebel L als Zahl ungleich 0 (Standard 2; negativ für Short-Produkte).
            - finance: Finanzierungszins in Prozent p. a. (3.5 = 3,5 Prozent) als Skalar oder Name einer
              Zusatzreihe aus ``aux``, deren Werte ebenfalls in Prozent p. a. vorliegen (Standard 3.5).
            - expense: TER in Prozent p. a. (Standard 0.5; muss >= 0 sein).
            - spread: Spread auf den finanzierten bzw. leerverkauften Anteil m(L) in Prozent p. a. (Standard 0).
            - days: Kalendertage je Zeile: Skalar (Standard 1, passend für Kalendertagsdaten) oder Name einer
              Zusatzreihe (z. B. Datumsabstand bei Handelstagsdaten).
            - rate_basis, ter_basis: Tagesbasis für Zins und Spread bzw. TER (Standard 360 bzw. 365).
            - name: Spaltenname im Pfad (Standard ``<base>_l<L>``, z. B. "eu_l2", bei negativem Hebel
              ``<base>_inv<|L|>``, z. B. "us_inv1").

            Zahlen sind einzelne endliche Zahlen, ``base`` und ``name`` ein einzelner Text, ``finance`` und ``days``
            eine Zahl oder ein Name aus ``aux``; andere Werte (Listen, Felder, bool, NaN) ergeben einen Fehler (seit
            1.6.3).

            Tagesrendite (MSCI Daily Leveraged/Short, plus Fondskosten): r = 1 + L (R - 1) + (1 - L) i · d / 360 -
            TER · d / 365
            - s · m(L) · d / 360 mit Brutto-Indexrendite R, Tagen je Zeile d, i, TER und s als Anteil
              (Prozentangabe / 100) und m(L) = max(L-1,0) + max(-L,0); 360 und 365 stehen für ``rate_basis`` und
              ``ter_basis``. Fällt r auf 0 oder darunter, bleibt das Produkt ab diesem Tag bei 0 (Totalverlust).
              Für L = 2 und konstantem Zins entspricht das dem Original (Finanzierung auf L - 1); für
              Short-Produkte wird - anders als im Original - der Zinsertrag auf Kapital und Leerverkaufserlös
              gutgeschrieben (MSCI-Methodik: -R + 2i).
        regime_index: Pfadname des Referenzindex für die Verfahren "regime", "evt", "tails" und die GARCH-Familie
            (Standard ``None`` = erster Index).
        aux: Optional (Standard ``None`` = keine) benannter Zeichenvektor Zusatzreihen: Pfadname -> Spaltenname,
            z. B. ``{"rate": "eu_rate", "cpi": "eu_cpi"}``. Zusatzreihen werden nicht simuliert, sondern aus
            denselben historischen Zeilen gezogen wie die Renditen; wie sie in den Pfad und in die
            Weiterverarbeitung eingehen, legt ``aux_type`` fest.
        aux_type: Optional (Standard ``None`` = keine Angabe) benannter Zeichenvektor: Art je Zusatzreihe, Name
            aus ``aux`` -> ``"level"`` oder ``"rate"``. Ein leerer Vektor (``character(0)``) gilt wie ``None``.
            Nicht genannte Reihen stehen wie ``"rate"`` mit ihren Originalwerten im Pfad, behalten aber in der
            Weiterverarbeitung das bisherige Verhalten (siehe unten).

            - "level": Niveau, z. B. ein Preisindex (CPI). Die Reihe wird in Zeilenverhältnisse zerlegt (Wert je
              Zeile / Wert der Vorzeile); der Pfad enthält das Niveau, das sich durch Kumulieren der Verhältnisse
              der gezogenen Zeilen ergibt. Startwert (Pfadzeile 1) ist der Wert der ersten verwendeten
              Historienzeile, bei ``input = "prices"`` der Wert der Zeile davor (Startzeile der Kurse). So
              entstehen keine Sprünge an Blockgrenzen. Bei ``input = "returns"`` hat die erste Historienzeile
              mangels Vorzeile das Verhältnis 1. Die Werte müssen positiv und endlich sein.
            - "rate": Rate in Prozent pro Jahr (2 = 2 % p. a.; nicht je Datenperiode, kein Anteil wie 0.02), z. B.
              ein Zins oder eine Inflationsrate: Werte der gezogenen Zeilen unverändert (keine Normierung auf 100;
              Pfadzeile 1 wiederholt den Wert der ersten gezogenen Zeile). Als Inflation wird die Rate je
              Pfadzeile über die Kalendertage seit der Vorzeile aufgezinst, Π (1 + r/100)^Tage/365.25; eine
              konstante Rate 2 ergibt damit je Jahr 1.02^Tage/365.25 (1,02 bei 365,25 Tagen), bei Kalender- wie
              Handelstagsdaten.

            Eine ausdrückliche Angabe gilt einheitlich in allen Funktionen, die die Reihe weiterverarbeiten:
            ``keep_aux`` in ``bootstrap_study()``, ``inflation`` in ``withdrawal_paths()`` und
            ``withdrawal_simulation()`` (``"level"`` = Preisindex, ``"rate"`` = Inflationsrate in Prozent p. a.;
            ``inflation_type`` muss nicht erneut angegeben werden) und ``withdrawal_cohorts()`` mit einer Tabelle
            aus ``bootstrap_data()``. Widersprechende Angaben dort (z. B. ``inflation_type = "level"`` bei
            ``"rate"``) sind ein Fehler. Ohne Angabe gilt das bisherige Verhalten: Originalwerte im Pfad; als
            Inflation (``keep_aux``, ``withdrawal_paths()`` mit ``inflation_type = "level"``) dient die
            Niveau-Variante (Attribut ``aux_level``, siehe ``bootstrap()``), also die kumulierten
            Zeilenverhältnisse, als wäre die Reihe ein Preisindex; eine Rate in Prozent p. a. muss dann mit
            ``inflation_type = "rate_pa"`` in ``withdrawal_paths()`` angegeben werden. Der Finanzierungszins von
            Hebelprodukten (``finance``) ist ebenfalls in Prozent p. a. (einfache Verzinsung je Zeile über
            ``rate_basis``) und darf nicht ``"level"`` sein; ebenso die Tage je Zeile (``days``, Werte unverändert
            verwendet, am besten ohne Angabe).
        cross: Kopplung der Nicht-Referenzindizes bei den Verfahren "garch", "gjr_garch", "ms_garch",
            "ms_ar_garch_m" und "tvtp_ms_garch": ``"ratio"`` (Standard, wie Original: GARCH(1,1) auf das
            Verhältnis zur Referenz, z. B. EUR-Index = USD-Index x Wechselkurs) oder ``"joint"`` (eigene
            GARCH(1,1)-Dynamik je Reihe, Kopplung nur über das gemeinsame Residuendatum). Bei den übrigen
            Verfahren ohne Wirkung.
        input: ``"returns"`` (Standard; Brutto-Renditen > 0 je Zeile, wie im Original) oder ``"prices"``
            (Kursniveaus; Renditen werden intern als Verhältnis aufeinanderfolgender Zeilen gebildet, die erste
            Zeile entfällt).

    Returns:
        Objekt der Klasse ``bootstrap_config`` (Liste mit ``indices``, ``letfs`` (mit allen Standardwerten
        ergänzt), ``regime_index``, ``aux``, ``aux_type`` (Art je Zusatzreihe, vollständig), ``aux_type_set``
        (Namen der ausdrücklich angegebenen Arten), ``cross``, ``input``, ``n_indices``, ``n_letfs``, ``n_aux``,
        ``index_names``, ``letf_names``, ``aux_names``).

    Details:
        Eingabedaten (``data`` in ``bootstrap()``): ein DataFrame oder eine Matrix mit einer Zeile je Beobachtung
        (z. B. Kalendertage oder Handelstage) und den hier genannten Spalten. Mit ``input = "returns"`` enthalten
        die Index-Spalten Brutto-Renditen je Zeile (z. B. 1.002 für +0,2 Prozent), mit ``input = "prices"``
        Kursniveaus. Eine Datumsspalte wird nicht benötigt und nicht ausgewertet; Zeilen mit fehlenden Werten in
        den verwendeten Spalten werden entfernt.

    Beispiel::

        import simlev
        cfg = simlev.bootstrap_config({"us": "us_ret", "eu": "eu_ret"}, regime_index="us",
                                      letfs=[{"base": "eu", "leverage": 2, "finance": "rate", "expense": 0.5}],
                                      aux={"rate": "eu_rate"})
        print(cfg["letf_names"])
    """
    cross = _match_arg(cross, ("ratio", "joint"))
    input = _match_arg(input, ("returns", "prices"))  # noqa: A001
    inames = _names(indices)
    if inames is None or any(n == "" for n in inames):
        _stop("indices muss vollständig benannt sein: c(name1 = 'spalte1', ...)")
    index_names = inames
    icols = [str(v) for v in _values(indices)]
    if any(_duplicated(index_names)):
        _stop("Doppelte Index-Namen: " + ", ".join(n for n, d in zip(index_names, _duplicated(index_names)) if d))
    if aux is not None and (_names(aux) is None or any(n == "" for n in _names(aux))):
        _stop("aux muss benannt sein.")
    aux_names = _names(aux) if aux is not None else []
    if aux_type is not None and not len(_values(aux_type) if not isinstance(aux_type, str) else [aux_type]):
        aux_type = None
    if aux_type is not None:
        at_names = _names(aux_type)
        at_vals = _values(aux_type) if at_names is not None else None
        if (at_names is None or any(n == "" for n in at_names)
                or not all(isinstance(v, str) for v in at_vals)):
            _stop("aux_type muss ein benannter Zeichenvektor sein: c(<Name aus aux> = 'level' oder 'rate'), "
                  "z. B. c(cpi = 'level', zins = 'rate').")
        bad = _setdiff(at_names, aux_names)
        if bad:
            _stop("aux_type: '%s' ist keine Zusatzreihe aus aux (verfügbar: %s)."
                  % ("', '".join(bad), ", ".join(aux_names) if aux_names else "keine"))
        dup = [n for n, d in zip(at_names, _duplicated(at_names)) if d]
        if dup:
            _stop("aux_type: Name '%s' doppelt angegeben." % dup[0])
        bad = [i for i, v in enumerate(at_vals) if v not in ("level", "rate")]
        if bad:
            _stop("aux_type['%s'] = '%s': erlaubt sind nur 'level' (Niveau, z. B. Preisindex) und 'rate' "
                  "(Rate, z. B. Zins in Prozent)." % (at_names[bad[0]], at_vals[bad[0]]))
    full = {nm: "rate" for nm in aux_names}
    if aux_type is not None:
        for k, v in zip(_names(aux_type), _values(aux_type)):
            full[k] = v
    aux_type_full = _nvec(aux_names, [full[n] for n in aux_names])

    def is_level(nm):
        return isinstance(nm, str) and full.get(nm) == "level"

    # LETF-Felder (seit 1.6.3 mit Typ und Länge wie in R): Zahlen einzeln und endlich, base und name einzelner Text,
    # finance und days Zahl oder Name einer Zusatzreihe
    def num1(v):
        return _is_num(v) and math.isfinite(float(v))

    def chk_num(i, v, nm):
        if not num1(v):
            _stop("LETF %d: %s muss eine einzelne endliche Zahl sein" % (i, nm))

    def chk_col(i, v, nm):
        if not num1(v) and not isinstance(v, str):
            _stop("LETF %d: %s muss eine einzelne endliche Zahl oder der Name einer Zusatzreihe aus aux sein" % (i, nm))

    letf_list = []
    for i, lt in enumerate(list(letfs or []), start=1):
        lt = dict(lt) if isinstance(lt, Mapping) else {}
        base = lt.get("base")
        if base is None:
            _stop("LETF %d: 'base' muss angegeben werden" % i)
        if not isinstance(base, str):
            _stop("LETF %d: base muss ein einzelner Name (Text) sein" % i)
        if base not in index_names:
            _stop("LETF %d: base '%s' nicht in indices. Verfügbar: %s" % (i, base, ", ".join(index_names)))
        lev = lt.get("leverage")
        lev = 2 if lev is None else lev
        chk_num(i, lev, "leverage")
        if lev == 0:
            _stop("LETF %d: leverage darf nicht 0 sein" % i)
        fin = lt.get("finance")
        fin = 3.5 if fin is None else fin
        chk_col(i, fin, "finance")
        if isinstance(fin, str) and fin not in aux_names:
            _stop("LETF %d: finance-Reihe '%s' nicht in aux." % (i, fin))
        if is_level(fin):
            _stop("LETF %d: finance-Reihe '%s' ist in aux_type als 'level' gekennzeichnet; der Finanzierungszins "
                  "muss eine Rate (Prozent p. a.) sein." % (i, fin))
        if _is_num(fin) and fin < 0:
            _warn("LETF %d: negativer Finanzierungszins." % i)
        exp_ = lt.get("expense")
        exp_ = 0.5 if exp_ is None else exp_
        chk_num(i, exp_, "expense")
        if exp_ < 0:
            _stop("LETF %d: expense muss >= 0 sein" % i)
        days = lt.get("days")
        days = 1 if days is None else days
        chk_col(i, days, "days")
        if isinstance(days, str) and days not in aux_names:
            _stop("LETF %d: days-Reihe '%s' nicht in aux." % (i, days))
        if is_level(days):
            _stop("LETF %d: days-Reihe '%s' ist in aux_type als 'level' gekennzeichnet; Tage je Zeile werden "
                  "unverändert gebraucht ('rate')." % (i, days))
        sp = lt.get("spread")
        sp = 0 if sp is None else sp
        rb = lt.get("rate_basis")
        rb = 360 if rb is None else rb
        tb = lt.get("ter_basis")
        tb = 365 if tb is None else tb
        chk_num(i, sp, "spread")
        chk_num(i, rb, "rate_basis")
        chk_num(i, tb, "ter_basis")
        name = lt.get("name")
        if name is not None and not isinstance(name, str):
            _stop("LETF %d: name muss ein einzelner Name (Text) sein" % i)
        if name is None:
            name = (base + "_l" + _as_char(lev)) if lev > 0 else (base + "_inv" + _as_char(abs(lev)))
        letf_list.append({"name": name, "base": base, "leverage": lev, "finance": fin, "expense": exp_,
                          "spread": sp, "days": days, "rate_basis": rb, "ter_basis": tb})
    letf_names = [lt["name"] for lt in letf_list]
    if any(_duplicated(index_names + letf_names + aux_names)):
        _stop("Namen von Indizes, LETFs und aux müssen eindeutig sein.")
    if regime_index is None:
        regime_index = index_names[0]
    elif regime_index not in index_names:
        _stop("regime_index '%s' nicht in indices" % regime_index)
    aux_out = None if aux is None else _nvec(aux_names, [str(v) for v in _values(aux)])
    return BootstrapConfig([
        ("indices", [{"name": nm, "col": c} for nm, c in zip(index_names, icols)]),
        ("letfs", letf_list), ("regime_index", regime_index), ("aux", aux_out),
        ("aux_type", aux_type_full),
        ("aux_type_set", list(_names(aux_type)) if aux_type is not None else []),
        ("cross", cross), ("input", input),
        ("n_indices", len(index_names)), ("n_letfs", len(letf_list)), ("n_aux", len(aux_names)),
        ("index_names", list(index_names)), ("letf_names", letf_names), ("aux_names", list(aux_names)),
    ])


# ═══════════════════════════════════════════════════════════════════════════
# Interne Daten- und Parameterhelfer
# ═══════════════════════════════════════════════════════════════════════════

_BOOT_METHODS = ("raw", "block", "circular", "stationary", "wild", "regime", "evt",
                 "tails", "reset", "garch", "gjr_garch", "ms_garch",
                 "ms_ar_garch_m", "tvtp_ms_garch")


def _is_config(x) -> bool:
    return isinstance(x, BootstrapConfig) or (isinstance(x, RList) and "bootstrap_config" in getattr(x, "r_class", ()))


def _data_cols(data):
    if isinstance(data, pd.DataFrame):
        return [str(c) for c in data.columns]
    return []


def _as_numeric_col(v) -> np.ndarray:
    a = np.asarray(v)
    if a.dtype.kind in "biuf":
        return a.astype(np.float64).ravel()
    out = []
    for z in a.ravel():
        try:
            out.append(_NAN if z is None else float(z))
        except (TypeError, ValueError):
            out.append(_NAN)
    return np.array(out, dtype=np.float64)


def _complete_rows(m) -> np.ndarray:
    if m is None:
        return None
    return ~np.isnan(m).any(axis=1)


@_quiet
def _extract_returns(data, config):
    """Renditematrix und Zusatzreihen extrahieren (R: ``.extract_returns``).

    Returns:
        dict mit ``ret`` (n x k), ``aux`` (n x a oder ``None``), ``aux_ratio``,
        ``aux_start`` (float-Arrays).
    """
    is_df = isinstance(data, pd.DataFrame)
    if not is_df and not (isinstance(data, np.ndarray) and data.ndim == 2):
        _stop("data muss ein data.frame oder eine Matrix sein")
    nrow = data.shape[0]
    if nrow == 0:
        _stop("data darf nicht leer sein")
    nms = _data_cols(data)

    def get_col(col):
        if col not in nms:
            _stop("Spalte '%s' nicht gefunden. Verfügbar: %s" % (col, ", ".join(nms)))
        return _as_numeric_col(data[col].to_numpy())

    ret = np.column_stack([get_col(ix["col"]) for ix in config["indices"]]) if config["indices"] else \
        np.zeros((nrow, 0))
    aux = aux0 = aux_ratio = aux_start = None
    aux_cols = _values(config["aux"]) if config["n_aux"] else []
    if config["n_aux"]:
        aux = np.column_stack([get_col(str(c)) for c in aux_cols])
        aux0 = aux
    if config["input"] == "prices":
        ret = ret[1:, :] / ret[:-1, :]
        if aux is not None:
            aux = aux[1:, :]
    ok = _complete_rows(ret) & (True if aux is None else _complete_rows(aux))
    if not ok.all():
        _message("Hinweis: %d unvollständige Zeilen entfernt." % int((~ok).sum()))
        ret = ret[ok, :]
        if aux is not None:
            aux = aux[ok, :]
    if not ret.shape[0]:
        _stop("data enthält keine vollständige Zeile in den verwendeten Spalten.")
    bad = ~np.isfinite(ret)
    if bad.any():
        lin = np.flatnonzero(bad.ravel(order="F"))[0]
        r0, c0 = lin % ret.shape[0], lin // ret.shape[0]
        _stop("Renditen enthalten nicht endliche Werte (Inf), erste in Spalte '%s', Zeile %d der verwendeten Daten."
              % (config["index_names"][c0], r0 + 1))
    if aux is not None:
        okw = np.flatnonzero(ok)
        prev1 = (aux0[okw[0], :] if config["input"] == "prices" else aux[0, :]).copy()
        rows = (np.concatenate([[okw[0] + 1], okw + 2]) if config["input"] == "prices"
                else np.concatenate([[okw[0] + 1], okw + 1]))
        at = _get(config, "aux_type")
        anames = list(config["aux_names"])
        lvl = []
        if at is not None:
            lvl = [n for n, v in zip(_names(at) or [], _values(at)) if v == "level"]
        for a in lvl:
            j = anames.index(a)
            v = np.concatenate([[prev1[j]], aux[:, j]])
            b = np.flatnonzero(~np.isfinite(v) | (v <= 0))
            if len(b):
                _stop("aux_type: Zusatzreihe '%s' (Spalte '%s') ist als 'level' gekennzeichnet und muss positiv und "
                      "endlich sein; Zeile %d von data hat den Wert %s."
                      % (a, str(aux_cols[j]), int(rows[b[0]]), _fmt1(float(v[b[0]]))))
        nf = ~np.isfinite(prev1)
        prev1[nf] = aux[0, nf]
        den = np.vstack([prev1[None, :], aux[:-1, :]])
        aux_ratio = aux / den
        aux_start = prev1
    if (ret <= 0).any():
        _stop("Renditen <= 0 gefunden (erwartet: Brutto-Renditen > 0, z. B. 1.002).")
    if r_median(np.abs(ret - 1).ravel(order="F")) > 0.5:
        _warn("Renditen sehen nicht wie Brutto-Tagesrenditen aus (Median |R - 1| > 0.5). input = 'prices' vergessen?")
    return {"ret": ret, "aux": aux, "aux_ratio": aux_ratio, "aux_start": aux_start}


_PARAM_DEFAULTS = (
    ("L", 20), ("block_length", 20), ("wild_type", 0), ("n_regimes", 2), ("vol_window", 20),
    ("tail_prob", 0.05), ("both_tails", True), ("p_break", 0.02), ("garch_order", [1, 1]),
    ("ms_n_regimes", 2), ("ms_garch_model", "gjrGARCH"), ("ms_ar_n_regimes", 2),
    ("ms_ar_garch_model", "gjrGARCH"), ("tvtp_n_regimes", 2), ("tvtp_garch_model", "gjrGARCH"))


def _get_base_params(params):
    """Standardparameter je Verfahren (R: ``.get_base_params``)."""
    p = dict(params or {})
    for nm, dv in _PARAM_DEFAULTS:
        if p.get(nm) is None:
            p[nm] = list(dv) if isinstance(dv, list) else dv
    return p


_ESS_GRIDS = {
    "raw": None, "stationary": {"L": [5, 10, 20, 30, 50, 75, 100]},
    "block": {"block_length": [5, 10, 20, 30, 50, 75, 100]},
    "circular": {"block_length": [5, 10, 20, 30, 50, 75, 100]},
    "wild": {"wild_type": [0, 1, 2]}, "regime": {"n_regimes": [2, 3, 4]},
    "evt": {"tail_prob": [0.01, 0.025, 0.05, 0.10]},
    "tails": {"tail_prob": [0.01, 0.025, 0.05, 0.10]},
    "reset": {"p_break": [0.01, 0.02, 0.05, 0.10]}, "garch": None, "gjr_garch": None,
    "ms_garch": {"ms_n_regimes": [2, 3]}, "ms_ar_garch_m": {"ms_ar_n_regimes": [2, 3]},
    "tvtp_ms_garch": {"tvtp_n_regimes": [2, 3]}}


def _get_ess_grid(method, n):
    """Standard-ESS-Gitter je Verfahren (R: ``.get_ess_grid``)."""
    g = _ESS_GRIDS.get(method)
    if g is None:
        return None
    g = {k: list(v) for k, v in g.items()}
    for nm in ("L", "block_length"):
        if nm in g:
            g[nm] = [v for v in g[nm] if v <= n / 2]
            if not g[nm]:
                g[nm] = [min(5, math.floor(n / 4))]
    return g


def _pget(params, nm, default):
    v = params.get(nm) if params is not None else None
    return default if v is None else v


def _calculate_ess(n, method, params, info=None):
    """Effektive Stichprobengröße je Konfiguration (R: ``.calculate_ess``)."""
    n = float(n)
    if method in ("raw", "wild", "reset", "garch", "gjr_garch"):
        ess = n
    elif method == "stationary":
        ess = n / float(_pget(params, "L", 20))
    elif method in ("block", "circular"):
        ess = n / float(_pget(params, "block_length", 20))
    elif method == "regime":
        K = float(_pget(params, "n_regimes", 2))
        ms = 1.0
        tr = _get(info, "trans")
        if tr is not None:
            d = np.diag(np.asarray(tr, dtype=np.float64))
            ms = r_mean(1.0 / np.maximum(1e-6, 1.0 - d))
        ess = n / (K * ms)
    elif method in ("evt", "tails"):
        ess = n * (1.0 - 2.0 * float(_pget(params, "tail_prob", 0.05)))
    elif method == "ms_garch":
        ess = n / (float(_pget(params, "ms_n_regimes", 2)) * 2)
    elif method == "ms_ar_garch_m":
        ess = n / (float(_pget(params, "ms_ar_n_regimes", 2)) * 2)
    elif method == "tvtp_ms_garch":
        ess = n / (float(_pget(params, "tvtp_n_regimes", 2)) * 2)
    else:
        ess = n
    return max(1.0, ess)


# ═══════════════════════════════════════════════════════════════════════════
# Automatische Blocklänge
# ═══════════════════════════════════════════════════════════════════════════

@_quiet
def _pw_block(x):
    """Optimale Blocklänge nach Politis & White (2004), R: ``.pw_block``.

    Returns:
        ``pandas.Series`` mit ``stationary`` und ``circular``.
    """
    x = np.asarray(x, dtype=np.float64).ravel()
    n = len(x)
    one = pd.Series([1.0, 1.0], index=["stationary", "circular"])
    if n < 20:
        return one
    l10 = math.log10(n)
    KN = max(5.0, math.sqrt(l10))
    mmax = math.ceil(math.sqrt(n)) + KN
    bmax = float(math.ceil(min(3 * math.sqrt(n), n / 3)))
    crit = 2 * math.sqrt(l10 / n)
    xc = x - r_mean(x)

    def acov(k):
        return r_sum(xc[0:n - k] * xc[k:n]) / n

    r0 = acov(0)
    if r0 <= 0:
        return one
    nlag = int(math.floor(mmax))
    rho = np.array([acov(k) for k in range(1, nlag + 1)]) / r0
    insig = np.abs(rho) < crit
    KNi = int(math.ceil(KN))
    mhat = None
    for k in range(1, max(0, len(insig) - KNi + 1) + 1):
        if insig[k - 1:k - 1 + KNi].all():
            mhat = k
            break
    if mhat is None:
        sig = np.flatnonzero(~insig)
        mhat = int(sig.max()) + 1 if len(sig) else 1
    M = min(2 * mhat, nlag)
    kk = np.arange(1, M + 1, dtype=np.float64)
    t = np.abs(kk / M)
    lam = np.where(t <= 0.5, 1.0, np.where(t <= 1, 2 * (1 - t), 0.0))
    Rk = np.array([acov(int(k)) for k in kk])
    G = 2 * r_sum(lam * kk * Rk)
    g0 = r0 + 2 * r_sum(lam * Rk)
    if g0 <= 0:
        return one
    n13 = r_pow(float(n), 1 / 3)
    b_sb = r_pow(2 * (G * G) / (2 * (g0 * g0)), 1 / 3) * n13
    b_cb = r_pow(2 * (G * G) / ((4 / 3) * (g0 * g0)), 1 / 3) * n13
    return pd.Series([min(max(1.0, b_sb), bmax), min(max(1.0, b_cb), bmax)], index=["stationary", "circular"])


@_quiet
def bootstrap_block_length(x, *, transform=("none", "abs", "squared")):
    """Optimale Blocklänge nach Politis & White (2004) mit Korrektur von Patton et al. (2009).

    Schätzt die optimale (erwartete) Blocklänge für den stationären und den zirkulären Block-Bootstrap nach
    Politis & White (2004) mit der Korrektur von Patton, Politis & White (2009) (Flat-Top-Lagfenster, c = 2, K_N =
    max(5, √log_10 n)).

    Args:
        x: Numerischer Vektor oder Matrix (Spalten = Reihen), z. B. (Log-)Renditen je Zeile. Nicht-endliche Werte
            werden je Spalte entfernt.
        transform: Transformation vor der Schätzung: ``"none"`` (Standard, Reihe selbst), ``"abs"`` (|x - bar x|)
            oder ``"squared"`` ((x - bar x)^2).

    Returns:
        Matrix mit Spalten ``stationary`` (erwartete Blocklänge für den stationären Bootstrap, Parameter ``L``)
        und ``circular`` (feste Blocklänge für den zirkulären Block-Bootstrap, Parameter ``block_length``), eine
        Zeile je Reihe (Zeilennamen = Spaltennamen von ``x`` bzw. V1, V2, ...). Einheit: Zeilen (Beobachtungen)
        von ``x``; Werte sind nicht gerundet, mindestens 1 und höchstens ⌈min(3√(n), n/3)⌉; bei weniger als 20
        Beobachtungen 1.

    Details:
        Hinweis: Das Verfahren optimiert die Varianzschätzung des Mittelwerts. Für tägliche Aktienrenditen ergeben
        sich oft sehr kurze Blöcke, weil die Renditen kaum autokorreliert sind. Für Pfad-Simulationen mit
        Trendfolge-Signalen ist daher ``transform = "abs"`` (Volatilitäts- Clustering) und eine
        Sensitivitätsanalyse über mehrere Blocklängen zu empfehlen; die Blocklänge sollte die
        Signal-Lookback-Länge nicht weit unterschreiten.

        Mit ``params = {"L": "auto"}`` bzw. ``{"block_length": "auto"}`` verwenden ``bootstrap()`` und
        ``bootstrap_study()`` diese Schätzung (Maximum über alle Indizes, jeweils für Log-Renditen und deren
        Beträge).

    Literatur:
        Politis, D.N. & White, H. (2004), Econometric Reviews 23(1); Patton, A., Politis, D.N. & White, H. (2009),
        Econometric Reviews 28(4).

    Beispiel::

        import numpy as np, simlev
        rng = np.random.default_rng(1)
        e = rng.normal(size=2000); x = np.empty(2000); x[0] = e[0]
        for t in range(1, 2000): x[t] = 0.5 * x[t - 1] + e[t]   # AR(1)
        print(simlev.bootstrap_block_length(x))
    """
    transform = _match_arg(transform, ("none", "abs", "squared"))
    if isinstance(x, pd.DataFrame):
        cols = [str(c) for c in x.columns]
        M = x.to_numpy(dtype=np.float64)
    else:
        M = np.asarray(x, dtype=np.float64)
        cols = None
        if M.ndim == 1:
            M = M.reshape(-1, 1)
    rows = []
    for j in range(M.shape[1]):
        v = M[:, j]
        v = v[np.isfinite(v)]
        if transform == "abs":
            v = np.abs(v - r_mean(v))
        elif transform == "squared":
            d = v - r_mean(v)
            v = d * d
        rows.append(_pw_block(v).to_numpy())
    rn = cols if cols is not None else ["V%d" % (j + 1) for j in range(M.shape[1])]
    return pd.DataFrame(np.array(rows).reshape(-1, 2), index=rn, columns=["stationary", "circular"])


def _resolve_auto(params, returns):
    """"auto"-Parameter auflösen (R: ``.resolve_auto``)."""
    params = dict(params or {})
    for nm in ("L", "block_length"):
        if isinstance(params.get(nm), str) and params.get(nm) == "auto":
            lr = np.asarray(_libm.log(returns), dtype=np.float64)
            b = pd.concat([bootstrap_block_length(lr), bootstrap_block_length(lr, transform="abs")])
            col = "stationary" if nm == "L" else "circular"
            params[nm] = max(1.0, _r_round0(float(b[col].max())))
            _message("Automatische Blocklänge (%s, Politis-White, max. über Reihen und |r|): %d"
                     % (nm, int(params[nm])))
    return params


# ═══════════════════════════════════════════════════════════════════════════
# Modellanpassung (GARCH-Familie, Regime, EVT)
# ═══════════════════════════════════════════════════════════════════════════


@_quiet
def _fit_garch11(e, gjr=False, quiet=False):
    """GARCH(1,1) / GJR-GARCH(1,1) schätzen (ML -> Momente), R: ``.fit_garch11``.

    Seit 1.0.0 wie R über die C-Bibliothek slc (``_lib.fit_garch11``):
    ML-Punktschätzer unter Normalverteilung (Raster-Starts, BFGS; GJR mit α + γ >= 0, also auch
    γ < 0, und BFGS von allen sieben Rasterpunkten), bei Fehlschlag die
    Momente mit Warnung; Methodenlabel ``"konstant"``, ``"ml"`` oder ``"momente"``. Der frühere
    Weg über die rugarch-Nachbildung (mit gosolnp und Uhrzeit-Seed) und Nelder-Mead entfällt.
    """
    return _slm.fit_garch11(np.asarray(e, dtype=np.float64).ravel(), gjr=gjr, quiet=quiet)


@_quiet
def _fit_cross(returns, config, base):
    """Nicht-Referenzreihen als GARCH(1,1) modellieren (R: ``.fit_cross``); ``base`` 1-basiert."""
    k = returns.shape[1]
    n = returns.shape[0]
    others = [j for j in range(1, k + 1) if j != base]
    if not others:
        return {"cols": np.zeros(0, dtype=np.int64), "mu": np.zeros(0), "om": np.zeros(0), "al": np.zeros(0),
                "be": np.zeros(0), "ratio": np.zeros(0, dtype=bool), "s2": np.zeros(0), "z": np.zeros((n, 0))}
    ratio = config["cross"] == "ratio"
    fits = []
    for j in others:
        e = returns[:, j - 1] / returns[:, base - 1] - 1 if ratio else returns[:, j - 1] - 1
        f = _fit_garch11(e, gjr=False, quiet=True)
        _message("  Kopplung %s (%s): mu=%.2e, omega=%.2e, alpha=%.4f, beta=%.4f [%s]"
                 % (config["index_names"][j - 1], config["cross"], f["mu"], f["omega"], f["alpha"], f["beta"],
                    f["method"]))
        fits.append(f)
    return {"cols": np.array([j - 1 for j in others], dtype=np.int64),
            "mu": np.array([f["mu"] for f in fits]), "om": np.array([f["omega"] for f in fits]),
            "al": np.array([f["alpha"] for f in fits]), "be": np.array([f["beta"] for f in fits]),
            "ratio": np.array([ratio] * len(others)), "s2": np.array([f["s2_init"] for f in fits]),
            "z": np.column_stack([f["z"] for f in fits])}


@_quiet
def _fit_tail(base_ret, prob, side):
    """Tail-Schätzung (GPD-ML -> Momente -> empirisch -> Default), R: ``.fit_tail``.

    Den GPD-Fit (``_lib.gpd_fit``, C-Bibliothek slc) nimmt R bei mindestens 30
    Überschreitungen; Fehler darin (z. B. Suche an der Grenze ξ = -0,999) führen wie das
    ``tryCatch`` in R zum Momenten-Schätzer.
    """
    base_ret = np.asarray(base_ret, dtype=np.float64)
    thr = float(_quantile7(base_ret, prob if side == "left" else 1 - prob)[0])
    mask = base_ret < thr if side == "left" else base_ret > thr
    exc = thr - base_ret[mask] if side == "left" else base_ret[mask] - thr
    ne = len(exc)
    scale = shape = None
    method = "none"
    if ne >= 30:
        try:
            f = _slm.gpd_fit(exc)
            if math.isfinite(f["scale"]) and f["scale"] > 0 and math.isfinite(f["shape"]):
                scale = float(f["scale"])
                shape = float(f["shape"])
                method = "MLE"
        except Exception:      # tryCatch(..., error = function(e) NULL)
            pass
    if scale is None and ne >= 20:
        m = r_mean(exc)
        v = r_var(exc)
        if v > 0 and m > 0:
            ratio = m * m / v
            shape = max(-0.5, min(1.0, 0.5 * (1 - ratio)))
            scale = max(1e-3, 0.5 * m * (1 + ratio))
            method = "Momente"
    if scale is None and ne >= 5:
        scale = max(1e-3, r_sd(exc))
        shape = 0.1
        method = "empirisch"
    if scale is None:
        scale = max(0.005, 2 * r_sd(base_ret - 1))
        shape = 0.1
        method = "Default"
        _warn("Tail-Fit: Default-Parameter (nur %d Tail-Beobachtungen)" % ne)
    if shape >= 0.5:
        _warn(_sp("GPD shape = %.3f (%s): unendliche Varianz", shape, side))
    return {"prob": prob, "thresh": thr, "scale": scale, "shape": shape,
            "pool": np.flatnonzero(mask) + 1, "method": method}


def _seq_len_out(n_out):
    """``seq(0, 1, length.out = n_out)`` über den Kern ``sl_r_seq_len`` (seit 1.6.3; gleiche Werte). ``n_out <= 0``
    (``n_regimes <= -1``, R: Fehler) wie bis 1.6.2: ``[0, 1][:n_out]``, damit die Folgemeldung gleich bleibt."""
    n_out = int(n_out)
    if n_out > 0:
        return _stats().seq_len_out(0.0, 1.0, n_out)
    return np.array([0.0, 1.0])[:n_out]


@_quiet
def _prepare_regime_info(base_ret, vol_window, n_regimes):
    """Regime aus rollierender Volatilität (R: ``.prepare_regime_info``)."""
    vol = _slm.rolling_vol(base_ret, int(vol_window))
    th = _quantile7(vol, _seq_len_out(float(n_regimes) + 1))
    th[-1] = th[-1] + 1e-10
    reg = _slm.assign_regimes(vol, th)
    return {"regimes": reg, "trans": _slm.estimate_trans_mat(reg, int(n_regimes)), "vol": vol}


@_quiet
def _prepare_ms_info(returns, config, base, K, garch_model, ar_gm, tvtp, cores=1):
    """MS-GARCH-Familie vorbereiten (R: ``.prepare_ms_info``; eigene ML-Schätzung
    :func:`simlev.ms_garch._ms_garch_fit`); ``base`` 1-basiert."""
    from . import ms_garch as _msg
    _msg._ms_garch_check(K, garch_model)
    ex = returns[:, base - 1] - 1
    n = len(ex)
    try:
        fit = _msg._ms_garch_fit(ex, K, garch_model, cores)   # cores Threads für die Starts
    except Exception as e:  # noqa: BLE001 - tryCatch(..., error = function(e) stop(...))
        _stop(_sp("MS-GARCH(%d, %s) Fit fehlgeschlagen: %s", int(float(np.asarray(K).ravel()[0])), garch_model, str(e)))
    K = int(float(np.asarray(K).ravel()[0]))
    om, al, be, ga = fit["omega"], fit["alpha"], fit["beta"], fit["gamma"]
    P = fit["P"]
    reg = np.asarray(fit["regimes"], dtype=np.int64)
    idx = [np.flatnonzero(reg == r) for r in range(1, K + 1)]
    mu = np.array([r_mean(ex[i]) if len(i) >= 10 else r_mean(ex) for i in idx], dtype=np.float64)
    s2 = fit["s2"]
    sig = np.sqrt(np.where(np.isnan(s2), s2, np.maximum(s2, 1e-14)))
    phi = np.zeros(K)
    lam = np.zeros(K)
    lag_ex = np.concatenate([[0.0], ex[:-1]])
    if ar_gm:
        for r in range(K):
            i = idx[r]
            if len(i) < 30:
                continue
            try:
                b = float(np.asarray(_sl.lsfit(np.column_stack([np.ones(len(i)), lag_ex[i]]), ex[i])["coefficients"],
                                     dtype=np.float64)[1])
            except Exception:  # noqa: BLE001 - tryCatch(..., error = function(e) NA)
                b = _NAN
            if math.isfinite(b):
                phi[r] = max(-0.5, min(0.5, b))
            try:
                lv = float(np.asarray(_sl.lsfit(sig[i].reshape(-1, 1), ex[i] - mu[r] - phi[r] * lag_ex[i])["coefficients"],
                                      dtype=np.float64)[0])
            except Exception:  # noqa: BLE001
                lv = _NAN
            if math.isfinite(lv):
                lam[r] = max(-5.0, min(5.0, lv))
    unc = np.zeros(K)
    for r in range(K):
        p = al[r] + be[r] + ga[r] / 2
        if p < 0.9999 and om[r] > 0:
            unc[r] = om[r] / (1 - p)
        else:
            i = idx[r]
            unc[r] = r_var(ex[i]) if len(i) >= 10 else r_var(ex)
    delta = np.zeros((K, K))
    if tvtp:
        for i in range(K):
            frm = np.flatnonzero(reg[:-1] == i + 1)
            if len(frm) < 50:
                continue
            x = s2[frm] / unc[i] - 1
            to = reg[frm + 1]
            for j in range(K):
                if j != i and int(np.sum(to == j + 1)) >= 5:
                    try:
                        g = _sl.logit_irls(np.column_stack([np.ones(x.size), x]), (to == j + 1).astype(np.float64))
                        d = float(g["coefficients"][1])   # Logit-IRLS
                    except Exception:  # noqa: BLE001 - tryCatch(..., error = function(e) NA)
                        d = _NAN
                    if math.isfinite(d):
                        delta[i, j] = max(-3.0, min(3.0, d))
    ri = reg - 1
    cm = mu[ri] + phi[ri] * lag_ex + lam[ri] * sig
    z = (ex - cm) / sig
    z[~np.isfinite(z)] = 0.0
    pools = [i + 1 if len(i) >= 10 else np.arange(1, n + 1) for i in idx]
    for r in range(K):
        i = pools[r] - 1
        sv = r_sd(z[i])
        if math.isfinite(sv) and sv > 0:
            z[i] = (z[i] - r_mean(z[i])) / sv
    pi_ = _msg._ms_garch_stat(P)
    _message(_sp("MS-GARCH(%d, %s%s%s): P(stay) = %s", K, garch_model, ", AR-M" if ar_gm else "",
                 ", TVTP" if tvtp else "", "/".join(_sp("%.3f", float(v)) for v in np.diag(P))))
    return {"K": K, "mu": mu, "omega": om, "alpha": al, "beta": be, "gamma": ga, "phi": phi, "lambda": lam,
            "trans": P, "delta": delta, "unc": unc, "stat": pi_ / r_sum(pi_),
            "pools": [np.asarray(p, dtype=np.int64) for p in pools], "z": z, "regimes": reg,
            "cross": _fit_cross(returns, config, base)}


def _prepare_method_info(returns, config, method, params, cores=1):
    """Verfahrensspezifische Vorberechnung (R: ``.prepare_method_info``)."""
    p = _get_base_params(params)
    base = config["index_names"].index(config["regime_index"]) + 1
    br = returns[:, base - 1]
    info = {"base": base}
    if method == "regime":
        info.update(_prepare_regime_info(br, p["vol_window"], p["n_regimes"]))
    if method == "evt":
        info["left"] = _fit_tail(br, p["tail_prob"], "left")
        info["right"] = _fit_tail(br, p["tail_prob"], "right") if p["both_tails"] is True or \
            (isinstance(p["both_tails"], (bool, np.bool_)) and bool(p["both_tails"])) else None
        bulk = br >= info["left"]["thresh"]
        if info["right"] is not None:
            bulk = bulk & (br <= info["right"]["thresh"])
        info["bulk"] = np.flatnonzero(bulk) + 1
        if not len(info["bulk"]):
            info["bulk"] = np.arange(1, len(br) + 1)
    if method == "tails":
        lt = float(_quantile7(br, p["tail_prob"])[0])
        rt = float(_quantile7(br, 1 - p["tail_prob"])[0])
        info["left"] = np.flatnonzero(br < lt) + 1
        info["right"] = np.flatnonzero(br > rt) + 1
        info["bulk"] = np.flatnonzero((br >= lt) & (br <= rt)) + 1
        if not len(info["bulk"]):
            info["bulk"] = np.arange(1, len(br) + 1)
        info["p"] = p["tail_prob"]
    if method in ("garch", "gjr_garch"):
        f = _fit_garch11(br - 1, gjr=method == "gjr_garch")
        if "persistence" not in f:
            # R: sprintf(..., NULL) und if (NULL >= 0.999) -> Fehler
            _stop("argument is of length zero")
        _message("%s(1,1) [%s]: mu=%.2e, omega=%.2e, alpha=%.4f, beta=%.4f, gamma=%.4f, Persistenz=%.4f"
                 % (method.upper(), f["method"], f["mu"], f["omega"], f["alpha"], f["beta"], f["gamma"],
                    f["persistence"]))
        if f["persistence"] >= 0.999:
            _warn(_sp("GARCH: Persistenz %.4f (nahe IGARCH)", f["persistence"]))
        info["garch"] = f
        info["cross"] = _fit_cross(returns, config, base)
    if method == "ms_garch":
        info["ms"] = _prepare_ms_info(returns, config, base, p["ms_n_regimes"], p["ms_garch_model"], False, False, cores)
    if method == "ms_ar_garch_m":
        info["ms"] = _prepare_ms_info(returns, config, base, p["ms_ar_n_regimes"], p["ms_ar_garch_model"], True, False, cores)
    if method == "tvtp_ms_garch":
        info["ms"] = _prepare_ms_info(returns, config, base, p["tvtp_n_regimes"], p["tvtp_garch_model"], True, True, cores)
    return info


# ═══════════════════════════════════════════════════════════════════════════
# Pfaderzeugung
# ═══════════════════════════════════════════════════════════════════════════

def _as_int(x) -> int:
    """``as.integer`` (Abschneiden)."""
    return int(float(x)) if not isinstance(x, (int, np.integer)) else int(x)


@_quiet
def _generate_returns(returns, method, p, info, n_out, stream):
    """Eine Renditematrix samt Quellzeilen erzeugen (R: ``.generate_returns``).

    Ziehungen aus dem Strom des Pfads (Kerne slc_boot)."""
    n, k = returns.shape

    def from_idx(idx):
        idx = np.asarray(idx, dtype=np.int64)
        if _src_rows_ok(returns):   # Zeilen liest der Pfadkern direkt aus returns (seit 1.6.3, ohne Kopie)
            return {"ret": None, "src": returns, "idx": idx}
        return {"ret": returns[idx - 1, :], "idx": idx}

    if method == "raw":
        g = from_idx(_slm.boot_idx_iid(n, n_out, stream=stream))
    elif method == "block":
        g = from_idx(_slm.boot_idx_block(n, n_out, _as_int(p["block_length"]), False, stream=stream))
    elif method == "circular":
        g = from_idx(_slm.boot_idx_block(n, n_out, _as_int(p["block_length"]), True, stream=stream))
    elif method == "stationary":
        g = from_idx(_slm.boot_idx_stationary(n, n_out, float(p["L"]), stream=stream))
    elif method == "regime":
        g = from_idx(_slm.boot_idx_regime(info["regimes"], info["trans"], n_out, stream=stream))
    elif method == "tails":
        g = from_idx(_slm.boot_idx_tails(n_out, info["p"], info["p"], info["bulk"], info["left"], info["right"], stream=stream))
    elif method == "wild":
        g = {"ret": _slm.boot_wild(returns, _as_int(p["wild_type"]), stream=stream), "idx": np.arange(1, n + 1)}
    elif method == "reset":
        g = {"ret": _slm.boot_reset(returns, p["p_break"], stream=stream), "idx": np.arange(1, n + 1)}
    elif method == "evt":
        lt, rt = info["left"], info["right"]
        g = _slm.boot_evt(returns, info["base"] - 1, n_out, lt["prob"], lt["thresh"], lt["scale"], lt["shape"],
                           lt["pool"], 0 if rt is None else rt["prob"], math.inf if rt is None else rt["thresh"],
                           0 if rt is None else rt["scale"], 0 if rt is None else rt["shape"],
                           np.zeros(0, dtype=np.int64) if rt is None else rt["pool"], info["bulk"], stream=stream)
    elif method in ("garch", "gjr_garch"):
        f, cr = info["garch"], info["cross"]
        g = _slm.boot_garch(n_out, info["base"] - 1, k, f["mu"], f["omega"], f["alpha"], f["beta"], f["gamma"],
                             f["s2_init"], f["z"], np.arange(1, n + 1), cr["cols"], cr["mu"], cr["om"], cr["al"],
                             cr["be"], cr["ratio"], cr["s2"], cr["z"], stream=stream)
    elif method in ("ms_garch", "ms_ar_garch_m", "tvtp_ms_garch"):
        m = info["ms"]
        cr = m["cross"]
        g = _slm.boot_ms_garch(n_out, info["base"] - 1, k, int(m["K"]), m["mu"], m["omega"], m["alpha"], m["beta"],
                                m["gamma"], m["phi"], m["lambda"], m["trans"], m["delta"], m["unc"], m["stat"],
                                m["pools"], m["z"], cr["cols"], cr["mu"], cr["om"], cr["al"], cr["be"], cr["ratio"],
                                cr["s2"], cr["z"], stream=stream)
    else:
        _stop("Unbekannte Methode: %s" % method)
    return g


@_quiet
def _boot_path_spec(aux, config, aux_ratio, aux_start):
    """Angaben für den Kern ``sl_boot_path`` (seit 1.6.0; wie ``.boot_path_spec`` in R) oder ``None`` (seit 1.6.3 ein
    interner Fehler in :func:`_build_path`): Zusatzreihen spaltenweise, Merker der Niveau-Reihen, Hebelprodukte als
    Zeilen (Basis, L, Zinsspalte, Zins, Tagespalte, Tage, rate_basis, ter_basis, expense, spread)."""
    try:
        inames = list(config["index_names"])
        anames = list(config["aux_names"]) if aux is not None else []
        lnames = list(config["letf_names"]) if config["n_letfs"] else []
        if len(set(inames + lnames + anames)) != len(inames) + len(lnames) + len(anames):
            return None
        auxT = ratioT = startv = level = None
        if aux is not None:
            aux = np.asarray(aux)
            if aux.dtype != np.float64 or aux.ndim != 2 or aux.shape[1] != len(anames):
                return None
            auxT = np.ascontiguousarray(aux.T)
            if aux_ratio is not None:
                ar = np.asarray(aux_ratio)
                if ar.dtype != np.float64 or ar.shape != aux.shape:
                    return None
                ratioT = np.ascontiguousarray(ar.T)
                if aux_start is not None:
                    startv = np.ascontiguousarray(np.asarray(aux_start, dtype=np.float64))
                    if startv.shape != (len(anames),):
                        return None
            at = _get(config, "aux_type")
            level = np.array([_aux_type_of(at, a) == "level" for a in anames], dtype=np.int32)
        letf = np.zeros((len(lnames), 10))
        for i, lt in enumerate(config["letfs"] if lnames else []):
            def col_or_val(v):
                return (float(anames.index(v)), 0.0) if isinstance(v, str) else (-1.0, float(v))
            letf[i] = [inames.index(lt["base"]), float(lt["leverage"]), *col_or_val(lt["finance"]),
                       *col_or_val(lt["days"]), float(lt["rate_basis"]), float(lt["ter_basis"]), float(lt["expense"]),
                       float(lt["spread"])]
    except (KeyError, ValueError, TypeError, IndexError):
        return None
    return {"auxT": auxT, "ratioT": ratioT, "start": startv, "level": level, "letf": letf,
            "cols": pd.Index(inames + lnames + anames), "anames": pd.Index(anames)}


_SRC_OK = (None, False)   # (schwacher Verweis auf die Quellrenditen, alle endlich und > 0?)


def _src_rows_ok(returns) -> bool:
    """Gilt für jede Zeilenauswahl von ``returns`` die Pfadprüfung von ``_build_path`` (alle Renditen endlich und
    > 0, float64, zeilenweise zusammenhängend)? Einmal je Matrix (Studie) geprüft."""
    ref, ok = _SRC_OK
    if ref is not None and ref() is returns:
        return ok
    ok = (isinstance(returns, np.ndarray) and returns.ndim == 2 and returns.dtype == np.float64
          and returns.flags.c_contiguous and bool(np.isfinite(returns).all()) and bool((returns > 0).all()))
    globals()["_SRC_OK"] = (weakref.ref(returns), ok)
    return ok


@_quiet
def _build_path(g, aux, config, start=100, aux_ratio=None, aux_start=None, spec=None):
    """Preis-Pfad aus Renditen bauen (R: ``.build_path``); ``DataFrame`` oder ``None``.

    Seit 1.6.0 mit ``spec`` (:func:`_boot_path_spec`) im Kern ``sl_boot_path`` (ein Aufruf je Pfad); seit 1.6.3 ohne
    Rückfall in Python (unerreichbar: ``bootstrap_config`` prüft die LETF-Felder, die Renditen sind float64-Matrizen
    mit ganzzahligen Zeilen)."""
    ret = g["ret"]
    src = g.get("src")
    idx = np.asarray(g["idx"], dtype=np.int64)
    if src is not None:   # Zeilen idx der geprüften Quelle (_src_rows_ok): Prüfung gilt schon, Kern liest selbst
        n_out, k = idx.size, src.shape[1]
        ret = src
    elif not isinstance(ret, np.ndarray) or ret.ndim != 2 or (~np.isfinite(ret)).any() or (ret <= 0).any():
        return None
    else:
        n_out, k = ret.shape
    na = 0 if spec is None or spec["auxT"] is None else spec["auxT"].shape[0]
    if (spec is None or ret.dtype != np.float64 or n_out < 1 or idx.shape != (n_out,)
            or k != len(spec["cols"]) - spec["letf"].shape[0] - na
            or (na and (idx.min() < 1 or idx.max() > spec["auxT"].shape[1]))):
        _stop("bootstrap: interner Fehler: Angaben für den Pfadkern unvollständig (.boot_path_spec)")
    nL = spec["letf"].shape[0]
    P = np.empty((k + nL + na, n_out + 1))
    lv = np.empty((na, n_out + 1)) if spec["ratioT"] is not None else None
    if src is not None:
        if not _ext.slc_boot_path_src(src.shape[0], k, src, np.ascontiguousarray(idx), spec["auxT"], spec["ratioT"],
                                      spec["start"], spec["level"], spec["letf"], float(start), P, lv):
            return None
    elif not _ext.slc_boot_path(n_out, k, np.ascontiguousarray(ret), np.ascontiguousarray(idx), spec["auxT"],
                                spec["ratioT"], spec["start"], spec["level"], spec["letf"], float(start), P, lv):
        return None
    out = pd.DataFrame(P.T, columns=spec["cols"], copy=False)
    if lv is not None:
        out.attrs["aux_level"] = pd.DataFrame(lv.T, columns=spec["anames"], copy=False)
    return out


@_quiet
def _ess_design(method, grid, budget, n_obs):
    """ESS-Design (R: ``.ess_design``): ``DataFrame`` oder ``None``."""
    if grid is None:
        grid = _get_ess_grid(method, n_obs)
    if grid is None or not len(grid):
        return None
    ess_params = ("L", "block_length", "n_regimes", "tail_prob", "ms_n_regimes", "ms_ar_n_regimes", "tvtp_n_regimes")
    non_ess = ("vol_window", "wild_type", "both_tails", "p_break", "garch_order", "ms_garch_model")
    nm = [str(k) for k in grid.keys()]
    vals = [list(np.atleast_1d(np.asarray(v, dtype=object)).ravel()) for v in grid.values()]
    # expand.grid: erster Faktor läuft am schnellsten
    rows = [[]]
    for v in vals:
        rows = [r + [x] for x in v for r in rows]
    design = pd.DataFrame({k: [r[i] for r in rows] for i, k in enumerate(nm)})
    for k in nm:
        try:
            design[k] = design[k].astype(np.float64)
        except (TypeError, ValueError):
            pass
    design["ess_per_boot"] = [
        _calculate_ess(n_obs, method, {k: float(design[k].iloc[i]) for k in nm}) for i in range(len(design))]
    if any(k in non_ess for k in nm):
        ec = [k for k in nm if k in ess_params]
        if ec:
            grp = ["_".join(_as_char(float(design[k].iloc[i])) for k in ec) for i in range(len(design))]
        else:
            grp = ["all"] * len(design)
        design["ess_group"] = grp
        cnt = {}
        for gname in grp:
            cnt[gname] = cnt.get(gname, 0) + 1
        design["n_variants"] = [float(cnt[gname]) for gname in grp]
        design["weight_alloc"] = (1 / design["ess_per_boot"].to_numpy()) / design["n_variants"].to_numpy()
    else:
        design["n_variants"] = 1.0
        design["weight_alloc"] = 1 / design["ess_per_boot"].to_numpy()
    wa = design["weight_alloc"].to_numpy()
    sw = r_sum(wa)
    ns = np.array([max(1.0, _r_round0(budget * w / sw)) for w in wa])
    while r_sum(ns) > budget:
        i = int(np.argmax(ns))
        ns[i] -= 1
    design["n_sims"] = ns
    tot = design["ess_per_boot"].to_numpy() * ns
    design["total_ESS"] = tot
    target = r_median(tot[tot > 0])
    with np.errstate(divide="ignore", invalid="ignore"):
        design["weight"] = np.where(tot > 0, target / tot, 0.0)
    design.attrs["param_names"] = nm
    return design


def _check_boot_params(method, p, n_obs):
    """Verfahrensparameter vor dem Ziehen prüfen (R: ``.check_boot_params``)."""
    if method == "stationary" and (not _num1(p.get("L")) or float(_num_vec(p.get("L"))[0]) < 1):
        _stop("params$L (erwartete Blocklänge) muss eine Zahl >= 1 sein (erhalten: %s)." % _show(p.get("L")))
    if method in ("block", "circular"):
        b = p.get("block_length")
        hi = n_obs - 1 if method == "block" else n_obs
        bv = float(_num_vec(b)[0]) if _num1(b) else None
        if bv is None or bv != _r_round0(bv) or bv < 1 or bv > hi:
            _stop("params$block_length muss eine ganze Zahl von 1 bis %d sein (%d Zeilen Historie%s; erhalten: %s)."
                  % (hi, n_obs, ", sonst gäbe es nur einen Blockstart" if method == "block" else "", _show(b)))
    if method == "wild":
        w = p.get("wild_type")
        if not _num1(w) or float(_num_vec(w)[0]) not in (0.0, 1.0, 2.0):
            _stop("params$wild_type muss 0 (Rademacher), 1 (Mammen) oder 2 (Normal) sein (erhalten: %s)." % _show(w))
    if method == "reset":
        pb = p.get("p_break")
        if not _num1(pb) or float(_num_vec(pb)[0]) < 0 or float(_num_vec(pb)[0]) > 1:
            _stop("params$p_break muss ein Anteil zwischen 0 und 1 sein (erhalten: %s)." % _show(pb))
    return True


def _modify_list(base, val):
    out = dict(base)
    for k, v in val.items():
        out[k] = v
    return out


@_quiet
def _boot_setup(data, config, method, n, params, ess, ess_grid, path_length, cores=1):
    """Gemeinsame Vorbereitung für bootstrap() und bootstrap_study() (R: ``.boot_setup``)."""
    if not _is_config(config):
        _stop("config muss mit bootstrap_config() erstellt werden")
    if method not in _BOOT_METHODS:
        _stop("Unbekannte Methode '" + str(method) + "'. Verfügbar: " + ", ".join(_BOOT_METHODS))
    if not _is_num(n) or n < 1:
        _stop("n muss eine positive Zahl sein")
    if path_length is not None and (not _num1(path_length) or path_length < 1 or
                                    float(path_length) != _r_round0(float(path_length))):
        _stop("path_length muss eine ganze Zahl >= 1 sein (erhalten: %s)." % _show(path_length))
    ex = _extract_returns(data, config)
    n_obs = ex["ret"].shape[0]
    n_out = _as_int(path_length if path_length is not None else n_obs)
    if method in ("wild", "reset") and n_out != n_obs:
        _stop("Verfahren '%s' erhält die Chronologie; path_length muss %d sein." % (method, n_obs))
    params = _resolve_auto(params, ex["ret"])
    design = _ess_design(method, ess_grid, _as_int(n), n_obs) if ess else None
    if ess and design is None:
        _message("Keine Hyperparameter für ESS - nutze Standard-Bootstrap")
    if design is None:
        combos = [params]
        combo_of_path = np.ones(int(math.floor(float(n))) if float(n) >= 1 else 0, dtype=np.int64)
    else:
        pn = design.attrs["param_names"]
        combos = [_modify_list(params, {k: float(design[k].iloc[i]) for k in pn}) for i in range(len(design))]
        combo_of_path = np.repeat(np.arange(1, len(design) + 1), design["n_sims"].to_numpy().astype(np.int64))
    n_paths = len(combo_of_path)
    infos = []
    for cp in combos:
        try:
            infos.append(_prepare_method_info(ex["ret"], config, method, cp, cores))
        except (ImportError, ModuleNotFoundError, NotImplementedError):
            raise
        except Exception as err:  # noqa: BLE001
            _stop("Vorberechnung fehlgeschlagen: %s" % err)
    base_p = [_get_base_params(cp) for cp in combos]
    for bp in base_p:
        _check_boot_params(method, bp, n_obs)
    weights = np.ones(n_paths) if design is None else design["weight"].to_numpy()[combo_of_path - 1]
    weights = weights / r_sum(weights) * len(weights)
    return {"ex": ex, "n_obs": n_obs, "n_out": n_out, "design": design, "combos": combos, "base_p": base_p,
            "infos": infos, "combo_of_path": combo_of_path, "n_paths": n_paths, "weights": weights}


@_quiet
def _draw_path(setup, i, stream, config, method, max_tries):
    """Einen gültigen Pfad mit eigenem Zufallsstrom erzeugen (R: ``.draw_path``); ``i`` 1-basiert.

    ``stream`` ist der SimLev-Strom des Pfads; Wiederholungen ziehen daraus weiter."""
    c_id = int(setup["combo_of_path"][i - 1])
    err = "Pfad ungültig (Indexrendite <= 0 oder nicht endlich)"
    ex = setup["ex"]
    for tr in range(1, int(max_tries) + 1):
        try:
            g = _generate_returns(ex["ret"], method, setup["base_p"][c_id - 1], setup["infos"][c_id - 1],
                                  setup["n_out"], stream)
        except (ImportError, ModuleNotFoundError):
            raise
        except Exception as e:  # noqa: BLE001
            err = str(e)
            g = None
        if g is not None:
            if "_path_spec" not in ex:          # Angaben für den Kern sl_boot_path einmal je Lauf (seit 1.6.0)
                ex["_path_spec"] = _boot_path_spec(ex["aux"], config, ex["aux_ratio"], ex["aux_start"])
            P = _build_path(g, ex["aux"], config, aux_ratio=ex["aux_ratio"], aux_start=ex["aux_start"],
                            spec=ex["_path_spec"])
            if P is not None:
                return {"path": P, "tries": tr}
    return {"path": None, "tries": int(max_tries), "err": err}


# ═══════════════════════════════════════════════════════════════════════════
# bootstrap()
# ═══════════════════════════════════════════════════════════════════════════

class BootstrapResult(RList):
    """Ergebnis von :func:`bootstrap` (R-Klasse ``bootstrap_result``)."""

    r_class = ("bootstrap_result",)

    def format(self) -> str:
        P = self["paths"][0]
        ess = ""
        if self.get("ess") is True:
            ess = ", ESS-gewichtet (%d Kombinationen)" % len(self["ess_design"])
        return "SimLev Bootstrap '%s': %d Pfade, je %d Zeilen x %d Spalten (%s)%s" % (
            self["method"], len(self["paths"]), P.shape[0], P.shape[1], ", ".join(str(c) for c in _colnames(P)), ess)


def _colnames(P):
    if isinstance(P, pd.DataFrame):
        return [str(c) for c in P.columns]
    return []


@_quiet
def bootstrap(data, config, *, method="raw", n=1000, params=None, ess=False, ess_grid=None, path_length=None,
              max_tries=10, seed=None, cores=1, progress=True):
    """Bootstrap-Pfade erzeugen.

    Erzeugt ``n`` simulierte Preis-Pfade für alle Indizes der Konfiguration, leitet daraus die Hebelprodukte ab
    und zieht Zusatzreihen mit. Eingabe ist ein Datensatz mit historischen Renditen oder Kursen (Format siehe
    ``bootstrap_config()``); Ergebnis sind Pfadmatrizen im Speicher. Einen einzelnen Pfad macht
    ``bootstrap_data()`` zum DataFrame für ``simulation()``; ``withdrawal_paths()`` wandelt alle Pfade in
    Periodenrenditen für ``withdrawal_simulation()`` um. Für Strategievergleiche über viele Pfade ohne Speicherung
    der Pfade dient ``bootstrap_study()``.

    Args:
        data: DataFrame oder Matrix mit den in ``config`` genannten Spalten (Index-Spalten als Brutto-Renditen je
            Zeile oder, bei ``input = "prices"``, als Kursniveaus; Zusatzreihen beliebig). Jede Zeile ist ein
            Simulationsschritt ("Tag"); eine Datumsspalte wird nicht ausgewertet.
        config: Objekt aus ``bootstrap_config()``.
        method: Verfahren (Standard in ``bootstrap()``: ``"raw"``, in ``bootstrap_study()``: ``"stationary"``). In
            Klammern die Einträge von ``params``, die das Verfahren verwendet:

            - "raw": IID-Zeilen-Bootstrap (Efron 1979); zerstört Zeitabhängigkeit (Nullmodell). Keine Parameter.
            - "block": Moving Block Bootstrap (Künsch 1989) (``block_length``)
            - "circular": Circular Block Bootstrap (Politis & Romano 1992) (``block_length``)
            - "stationary": Stationärer Bootstrap (Politis & Romano 1994), geometrisch verteilte Blöcke (``L``)
            - "wild": Wild Bootstrap mit gemeinsamem Gewicht je Zeile für alle Reihen (``wild_type``); erhält die
              Chronologie
            - "regime": Volatilitätsregime-Markov-Bootstrap: Regime aus Quantilen der rollierenden Volatilität des
              Referenzindex (``n_regimes``, ``vol_window``)
            - "evt": GPD-Tails des Referenzindex plus empirischer Bulk (``tail_prob``, ``both_tails``); übrige
              Indizes über das historische Verhältnis zum Referenzindex gekoppelt
            - "tails": Empirische Tail-Schichtung des Referenzindex (``tail_prob``)
            - "reset": Chronologie mit zufällig gespiegelten Segmenten (``p_break``); erhält die Chronologie
            - "garch", "gjr_garch": (GJR-)GARCH(1,1) mit Filtered Historical Simulation (keine Parameter; Kopplung
              über ``cross`` in ``bootstrap_config()``). Geschätzt per Maximum Likelihood unter Normalverteilung
              mit der C-Bibliothek von SimLev (GJR mit α + γ ≥ 0, also auch γ < 0; bis Version 1.0.0 γ ≥ 0; BFGS
              von sieben Rasterpunkten), notfalls mit Momentschätzern; die Meldungen nennen den Weg "ml" bzw.
              "momente" (bis 0.10.0 "rugarch"/"optim")
            - "ms_garch", "ms_ar_garch_m", "tvtp_ms_garch": Markov-Switching-GARCH-Familie: eigene ML-Schätzung
              des MS-GARCH-Modells nach Haas, Mittnik und Paolella (2004), Normalverteilung, Varianzmodell
              "sGARCH" oder "gjrGARCH" je Regime (GJR mit α + γ ≥ 0, also auch γ < 0; BFGS mit analytischem
              Gradienten von 12 bzw. bei "gjrGARCH" 20 Startpunkten); "ms_ar_garch_m" zusätzlich mit AR- und
              GARCH-in-Mean-Termen je Regime, "tvtp_ms_garch" mit zeitvariablen Uebergangswahrscheinlichkeiten
              (``ms_n_regimes``/``ms_garch_model``, ``ms_ar_n_regimes``/``ms_ar_garch_model`` bzw.
              ``tvtp_n_regimes``/``tvtp_garch_model``)

            Bei "wild" und "reset" muss ``path_length`` der Länge der Historie entsprechen.
        n: Anzahl Pfade (Standard 1000); bei ``ess = True`` das Gesamtbudget, das auf die Parameterkombinationen
            verteilt wird. Pfade, die nach ``max_tries`` Versuchen ungültig bleiben, fehlen im Ergebnis.
        params: Benannte Liste von Verfahrensparametern; nicht angegebene Einträge erhalten den Standardwert
            (Standard ``{}`` = alle Standardwerte). Je Verfahren werden nur die oben genannten Einträge verwendet:

            - L: Erwartete Blocklänge in Zeilen für "stationary" (Zahl >= 1, Standard 20) oder ``"auto"``
              (``bootstrap_block_length()``, Spalte ``stationary``).
            - block_length: Feste Blocklänge in Zeilen für "block" und "circular" (ganze Zahl, Standard 20; bei
              "block" höchstens Zeilen der Historie minus 1, bei "circular" höchstens Zeilen der Historie) oder
              ``"auto"`` (``bootstrap_block_length()``, Spalte ``circular``).
            - wild_type: Gewichte beim Wild Bootstrap: 0 = Rademacher (Standard), 1 = Mammen, 2 = Standardnormal;
              andere Werte sind ein Fehler.
            - n_regimes: Anzahl Volatilitätsregime für "regime" (Standard 2).
            - vol_window: Fensterlänge der rollierenden Volatilität in Zeilen für "regime" (Standard 20).
            - tail_prob: Tail-Wahrscheinlichkeit je Seite als Anteil für "evt" und "tails" (Standard 0.05 = 5
              Prozent).
            - both_tails: Logisch, nur "evt": auch den rechten Tail mit einer GPD modellieren (Standard ``True``).
            - p_break: Wahrscheinlichkeit je Zeile als Anteil (0 bis 1), dass bei "reset" ein neues Segment
              beginnt (Standard 0.02).
            - ms_n_regimes, ms_ar_n_regimes, tvtp_n_regimes: Anzahl Regime für "ms_garch", "ms_ar_garch_m" bzw.
              "tvtp_ms_garch" (Standard je 2). Hat die Reihe weniger deutlich getrennte Regime als angefordert (z.
              B. drei Regime auf einer Reihe mit nur einem oder zwei Volatilitätszuständen), kann ein Regime
              entarten: Verweilwahrscheinlichkeit nahe 0 (Meldung "P(stay)"), kaum oder keine Tage im Regimepfad,
              mitunter Persistenz nahe 1 mit unplausibel hoher unbedingter Varianz; die Log-Likelihood liegt dann
              kaum über der mit einem Regime weniger. In diesem Fall die Anzahl Regime verkleinern.
            - ms_garch_model, ms_ar_garch_model, tvtp_garch_model: Varianzmodell je Regime: "sGARCH" (GARCH(1,1))
              oder "gjrGARCH" (GJR-GARCH(1,1), Standard je "gjrGARCH"); andere Werte sind ein Fehler.

            Der Eintrag ``garch_order`` (Standard ``[1, 1]``) ist vorhanden, ändert aber nichts: die
            GARCH-Verfahren schätzen immer GARCH(1,1).
        ess: Logisch (Standard ``False``): ESS-gewichtete Gittersuche über Hyperparameter (wie im Original). Das
            Budget ``n`` wird invers zur effektiven Stichprobengröße (ESS) je Kombination verteilt; die Pfade
            erhalten Gewichte (Mittel 1), mit denen ``bootstrap_probability()`` und ``summary()`` rechnen. Für
            "raw", "garch" und "gjr_garch" gibt es kein Standardgitter (dann normaler Bootstrap).
        ess_grid: Benannte Liste von Wertevektoren je Hyperparameter (z. B. ``{"L": [20, 50, 100]}``); ``None``
            (Standard) = Standardgitter des Verfahrens (z. B. ``L`` bzw. ``block_length`` 5, 10, 20, 30, 50, 75,
            100 Zeilen, begrenzt auf die halbe Historienlänge). Nur bei ``ess = True`` verwendet.
        path_length: Pfadlänge in Zeilen (simulierte Schritte, ganze Zahl, mindestens 1); ``None`` (Standard) =
            Anzahl verwendbarer Zeilen der Historie. Damit lassen sich z. B. 50-jährige Pfade aus 30 Jahren
            Historie erzeugen. Jeder Pfad hat ``path_length + 1`` Zeilen (Startzeile plus Schritte).
        max_tries: Versuche je Pfad (Standard 10), falls ein Pfad ungültig ist (Indexrendite <= 0 oder nicht
            endlich). Ein Totalverlust eines Hebelprodukts macht den Pfad nicht ungültig.
        seed: Ganzzahliger Startwert (|seed| < 2^53); ``None`` (Standard) = genau einmal aus dem Zufallszustand
            von SimLev gezogen (siehe ``simlev_seed()``; ganze Zahl von 0 bis 2^31 - 1, im Ergebnis unter ``seed``
            gespeichert, damit reproduzierbar). Jeder Pfad i erhält einen eigenen Strom (Sprung um 2^128 Schritte
            je Pfad), so dass Pfad i unabhängig von ``cores`` (und bei ``bootstrap_study()`` von ``chunk_size``)
            ist und ``bootstrap()`` und ``bootstrap_study()`` mit gleichem Seed (und gleichen Daten, Verfahren,
            ``params``, ``ess`` und ``path_length``) dieselben Pfade erzeugen. Mit angegebenem Seed bleibt der
            Zufallszustand von SimLev unverändert; mit ``seed = None`` liefern wiederholte Aufrufe verschiedene
            Pfade. ``set.seed()`` wirkt nicht.
        cores: Anzahl Prozesse (Standard 1; Fork auf Unix, PSOCK-Cluster auf Windows). Bei den MS-GARCH-Verfahren
            (``ms_garch``, ``ms_ar_garch_m``, ``tvtp_ms_garch``) rechnet der Fit seine Startpunkte zudem auf so
            vielen Threads; das Ergebnis hängt davon nicht ab.
        progress: Logisch: Fortschritts- und Abschlussmeldung per ``message()`` ausgeben (Standard ``True``).

    Returns:
        Objekt der Klasse ``bootstrap_result``, eine Liste mit

        - paths: Liste von Matrizen, eine je gültigem Pfad, mit ``path_length + 1`` Zeilen: Zeile 1 = Startwert
          100 für Indizes und Hebelprodukte, danach je Simulationsschritt. Spalten: Indizes, Hebelprodukte,
          Zusatzreihen in dieser Reihenfolge. Keine Datumsspalte. Zusatzreihen mit ``aux_type = "rate"`` (Prozent
          p. a.) und ohne Angabe in ``aux_type`` enthalten die Originalwerte der gezogenen Zeilen, solche mit
          ``"level"`` das kumulierte Niveau (Startwert = erste verwendete Historienzeile bzw. Startzeile der
          Kurse, danach die historischen Zeilenverhältnisse der gezogenen Zeilen kumuliert; keine Sprünge an
          Blockgrenzen). Bei Zusatzreihen trägt jede Matrix zusätzlich das Attribut ``aux_level``: diese
          Niveau-Variante für alle Zusatzreihen (für ``"level"``-Reihen identisch mit der Pfadspalte). Ihr
          Startwert (Zeile 1) ist die erste Historienzeile (bzw. Startzeile der Kurse) und damit für alle Pfade
          gleich; früher war es der Wert der Historienzeile vor dem ersten gezogenen Schritt (je Pfad
          verschieden). Die Zeilenverhältnisse sind unverändert die historischen Verhältnisse der gezogenen
          Zeilen, können aber durch die andere Startskalierung um 1 ulp von früheren Läufen abweichen
          (beabsichtigt; betrifft z. B. ``withdrawal_paths()`` mit ``inflation_type = "level"`` und ``keep_aux``).
          Es dient als Inflation für Reihen ohne Angabe in ``aux_type`` (``withdrawal_paths()`` mit
          ``inflation_type = "level"``, ``keep_aux`` in ``bootstrap_study()``); für Reihen mit ``aux_type =
          "rate"`` wird es dort nicht verwendet.
        - weights: Pfadgewichte (Mittel 1; ohne ESS alle 1).
        - method, config, seed: Verfahren, Konfiguration und verwendeter Seed.
        - params: Vollständige Parameterliste (bei ESS: der ersten Kombination).
        - ess, ess_design: Logisch, ob ESS verwendet wurde, und das ESS-Design (DataFrame je Kombination mit
          Parametern, ``ess_per_boot``, ``n_sims``, ``weight`` u. a.) bzw. ``None``.
        - param_values: Bei ESS: Parameterliste je Pfad, sonst ``None``.
        - knockout_rate: Anteil der ungültigen Versuche an allen Versuchen in Prozent (``100 *
          stats["knockout_rate"]``).
        - stats: Liste mit ``attempts`` (Versuche gesamt), ``success`` (gültige Pfade), ``null`` (Versuche ohne
          gültigen Pfad) und ``knockout_rate`` (``null / attempts``, als Anteil).

    Literatur:
        Haas, M., Mittnik, S. & Paolella, M.S. (2004), A New Approach to Markov-Switching GARCH Models, Journal of
        Financial Econometrics 2(4) (Verfahren "ms_garch", "ms_ar_garch_m", "tvtp_ms_garch"); Hamilton, J.D.
        (1989), Econometrica 57(2) (Filter).

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(2)
        d = pd.DataFrame({"us": 1 + rng.normal(3e-4, 0.01, 1500)})
        d["eu"] = d["us"] * (1 + rng.normal(0, 0.004, 1500))
        d["rate"] = 2.0
        cfg = simlev.bootstrap_config({"us": "us", "eu": "eu"}, aux={"rate": "rate"},
                                      letfs=[{"base": "eu", "leverage": 2, "finance": "rate"}])
        b = simlev.bootstrap(d, cfg, method="stationary", n=5, params={"L": 50}, seed=1, progress=False)
        print(b["paths"][0].shape)
    """
    t0 = time.time()
    setup = _boot_setup(data, config, method, n, params, ess, ess_grid, path_length, cores)
    if seed is None:                    # None -> einmal k aus G
        seed = _sl.next_seed()
    else:
        _sl.check_seed(seed)
    streams = _sl.streams(seed, setup["n_paths"])                                 # U_i = J^i(S_0)
    res = _par_lapply(
        range(1, setup["n_paths"] + 1),
        lambda i: _draw_path(setup, i, streams[i - 1], config, method, max_tries), cores)
    ok = np.array([r["path"] is not None for r in res], dtype=bool)
    tries = np.array([float(r["tries"]) for r in res])
    if not ok.any():
        last = res[-1].get("err") if res else None
        _stop("Keine gültigen Pfade erzeugt (%d Versuche; letzte Ursache: %s)."
              % (int(r_sum(tries)), last if last is not None else "unbekannt"))
    st = r_sum(tries)
    ko = (st - int(ok.sum())) / st
    w = setup["weights"][ok]
    w = w / r_sum(w) * len(w)
    if progress:
        _message("Bootstrap '%s': %d Pfade x %d Tage in %.1f s (Knockout-Rate %.2f %%)."
                 % (method, int(ok.sum()), setup["n_out"], time.time() - t0, 100 * ko))
    design = setup["design"]
    return BootstrapResult([
        ("paths", [r["path"] for r, o in zip(res, ok) if o]), ("weights", w), ("method", method),
        ("config", config), ("params", setup["base_p"][0]), ("ess", design is not None), ("ess_design", design),
        ("param_values", [setup["combos"][c - 1] for c, o in zip(setup["combo_of_path"], ok) if o]
         if design is not None else None),
        ("seed", seed), ("knockout_rate", 100 * ko),
        ("stats", {"attempts": st, "success": int(ok.sum()), "null": st - int(ok.sum()), "knockout_rate": ko}),
    ])


def _is_boot_result(x) -> bool:
    return isinstance(x, BootstrapResult) or (isinstance(x, RList) and "bootstrap_result" in getattr(x, "r_class", ()))


@_quiet
def bootstrap_validate(result, *, min_rows=None, verbose=True):
    """Bootstrap-Ergebnis validieren und bereinigen.

    Entfernt leere, unvollständige (``NA``) oder nicht endliche Pfade sowie Pfade, deren Zeilenzahl von der
    häufigsten Zeilenzahl abweicht, und normiert die Gewichte neu auf Mittel 1 (wie im Original). Nützlich vor der
    Weiterverarbeitung von ``bootstrap()``-Ergebnissen, die z. B. von Hand verändert oder aus mehreren Läufen
    zusammengesetzt wurden.

    Args:
        result: Objekt der Klasse ``bootstrap_result`` aus ``bootstrap()``.
        min_rows: Mindestzeilenzahl je Pfad; ``None`` (Standard) = keine Mindestlänge.
        verbose: Logisch: Anzahl entfernter und gültiger Pfade ausgeben (Standard ``True``).

    Returns:
        Das bereinigte ``bootstrap_result`` (``paths``, ``weights`` und ``param_values`` gekürzt). Bleibt kein
        Pfad übrig, bricht die Funktion mit einem Fehler ab.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        d = pd.DataFrame({"r": 1 + rng.normal(3e-4, 0.01, 500)})
        b = simlev.bootstrap(d, simlev.bootstrap_config({"idx": "r"}), method="stationary", n=3, params={"L": 20},
                             seed=1, progress=False)
        b["paths"][1][9, 0] = np.nan       # einen Pfad beschädigen
        b = simlev.bootstrap_validate(b)
        print(len(b["paths"]))
    """
    if not _is_boot_result(result):
        _stop("result muss ein bootstrap_result-Objekt sein")
    P = list(result.get("paths") or [])
    if not P:
        _stop("Keine Pfade im Ergebnis vorhanden")

    def valid(p):
        if p is None or not isinstance(p, (pd.DataFrame, np.ndarray)) or p.shape[0] == 0:
            return False
        a = p.to_numpy(dtype=np.float64) if isinstance(p, pd.DataFrame) else np.asarray(p, dtype=np.float64)
        return not np.isnan(a).any() and bool(np.isfinite(a).all())

    ok = np.array([valid(p) for p in P], dtype=bool)
    if ok.any():
        ln = [None if p is None else p.shape[0] for p in P]
        cnt = {}
        for v, o in zip(ln, ok):
            if o:
                cnt[v] = cnt.get(v, 0) + 1
        keys = sorted(cnt)
        mode_len = max(keys, key=lambda k: (cnt[k], -keys.index(k)))
        ok = ok & np.array([v == mode_len for v in ln])
        if min_rows is not None:
            ok = ok & np.array([v is not None and v >= min_rows for v in ln])
    if not ok.any():
        _stop("Keine gültigen Pfade nach Validierung übrig")
    if verbose and (~ok).any():
        sys.stdout.write("%d von %d Pfaden entfernt\n" % (int((~ok).sum()), len(ok)))
    out = BootstrapResult(result.items())
    out["paths"] = [p for p, o in zip(P, ok) if o]
    if result.get("weights") is not None:
        w = np.asarray(result["weights"], dtype=np.float64)[ok]
        out["weights"] = w / r_sum(w) * len(w)
    if result.get("param_values") is not None:
        out["param_values"] = [p for p, o in zip(result["param_values"], ok) if o]
    if verbose:
        sys.stdout.write("%d valide Pfade, je %d Zeilen\n" % (len(out["paths"]), out["paths"][0].shape[0]))
    return out


@_quiet
def bootstrap_data(result, *, i=1, dates=None, start="2000-01-01"):
    """Bootstrap-Pfad als ``DataFrame`` für :func:`simlev.simulation`.

    Wandelt einen Pfad aus ``bootstrap()`` in einen DataFrame mit Datumsspalte um, der direkt an ``simulation()``
    übergeben werden kann. Die Spaltennamen sind die Pfadnamen aus ``bootstrap_config()`` (Indizes, Hebelprodukte,
    Zusatzreihen); die Strategie muss Assets mit diesen Namen verwenden.

    Args:
        result: ``bootstrap_result`` aus ``bootstrap()`` oder eine einzelne Pfadmatrix (z. B.
            ``result["paths"][[i]]``).
        i: Pfadnummer (Standard 1); nur bei ``bootstrap_result`` verwendet.
        dates: Datumsvektor mit genau so vielen Elementen wie der Pfad Zeilen hat (``path_length + 1``), z. B. ein
            Handelstagskalender; ``None`` (Standard) = aufeinanderfolgende Kalendertage ab ``start``.
        start: Startdatum für ``dates = None`` (Zeichenkette oder Date, Standard "2000-01-01").

    Returns:
        DataFrame mit Spalte ``date`` (Klasse Date) und allen Pfadspalten (Kursniveaus mit Startwert 100;
        Zusatzreihen mit ``aux_type = "rate"`` (Prozent p. a.) und ohne Angabe als Originalwerte der gezogenen
        Zeilen, mit ``"level"`` als kumuliertes Niveau, z. B. ein durchgehender CPI ohne Sprünge an Blockgrenzen;
        siehe ``bootstrap_config()``). Bei einem ``bootstrap_result``, dessen Konfiguration Reihen ausdrücklich
        als ``aux_type = "rate"`` kennzeichnet, trägt der DataFrame das Attribut ``aux_type`` mit diesen Reihen
        (z. B. ``{"infl": "rate"}``); ``withdrawal_cohorts()`` behandelt sie als Inflationsrate in Prozent p. a.
        Ohne solche Angabe entfällt das Attribut (Ergebnis wie bisher). Umformungen wie ``transform()``,
        ``merge()``, ``cbind()`` oder CSV-Export entfernen das Attribut; dann in ``withdrawal_cohorts()``
        ``inflation_type = "rate_pa"`` angeben.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        d = pd.DataFrame({"r": 1 + rng.normal(3e-4, 0.01, 800)})
        cfg = simlev.bootstrap_config({"idx": "r"}, letfs=[{"base": "idx", "leverage": 2}])
        b = simlev.bootstrap(d, cfg, method="stationary", n=2, params={"L": 20}, path_length=400, seed=1, progress=False)
        x = simlev.bootstrap_data(b, i=2, start="2030-01-01")
        res = simlev.simulation(x, simlev.create_strategy(idx_l2=simlev.asset_config(asset_class="etf")))
        print(res["cagr"])
    """
    is_res = _is_boot_result(result)
    if not is_res:
        # R: result$config auf einer Pfadmatrix -> Fehler (auch bei einer einzelnen Pfadmatrix)
        _stop("$ operator is invalid for atomic vectors")
    P = result["paths"][int(i) - 1]
    nr = P.shape[0]
    if dates is None:
        dates = _seq_dates(_to_date(start, "start"), nr)
    if len(np.atleast_1d(dates)) != nr:
        _stop("dates hat Länge %d, Pfad hat %d Zeilen." % (len(np.atleast_1d(dates)), nr))
    d = _to_date(dates, "dates")
    out = pd.DataFrame({"date": d})
    for c in P.columns:
        out[c] = P[c].to_numpy()
    if is_res:
        cfg = result["config"]
        sets = list(_get(cfg, "aux_type_set", []) or [])
        at = _get(cfg, "aux_type")
        keep = [s for s in sets if _aux_type_of(at, s) == "rate"]
        if keep:
            out.attrs["aux_type"] = _nvec(keep, ["rate"] * len(keep))
    return out


# Kennzahlen, bei denen ein kleinerer Wert günstiger ist (Drawdowns)
_LOWER_BETTER = ("max_drawdown", "avg_drawdown", "dd_q50", "dd_q90", "ulcer_index", "longest_drawdown")


def _res_get(res, name, default=None):
    if isinstance(res, Mapping):
        v = res.get(name, default)
    else:
        try:
            v = res[name]
        except (KeyError, TypeError, AttributeError):
            v = getattr(res, name, default)
    return default if v is None else v


@_quiet
def bootstrap_study_metrics(res):
    """Standard-Kennzahlen für :func:`bootstrap_study` (benannter Vektor).

    Fasst ein Ergebnis von ``simulation()`` zu einem benannten Kennzahlenvektor zusammen. Standardwert des
    Arguments ``metrics`` von ``bootstrap_study()``, ``sensitivity_grid()``, ``sensitivity_rebalancing()`` und
    ``sensitivity_leverage()``; eigene Kennzahlfunktionen müssen ebenfalls ein ``SimLevResult`` entgegennehmen und
    einen benannten numerischen Vektor liefern.

    Args:
        res: ``SimLevResult`` aus ``simulation()``.

    Returns:
        Benannter numerischer Vektor mit

        - cagr, ttwror: CAGR und annualisierte TTWROR als Anteil (0.05 = 5 Prozent). Mit Sparplan (Einzahlungen
          nach dem Starttag, ``res["external_flows"]``) ist ``cagr`` die geldgewichtete Jahresrendite (XIRR, siehe
          ``simulation()``), ``ttwror`` die zeitgewichtete.
        - final_value: Endwert des Depots (Währungseinheiten).
        - max_drawdown, avg_drawdown: Maximaler und mittlerer Drawdown (Mittel über Zeilen mit Drawdown > 0), als
          positiver Anteil.
        - dd_q50, dd_q90: Median und 90-Prozent-Quantil der Drawdowns über alle Zeilen, als Anteil.
        - ulcer_index: Ulcer Index (Drawdowns als Anteil).
        - longest_drawdown: Längste Drawdown-Phase in Zeilen der Daten.
        - sharpe, sortino, calmar, omega: Kennzahlen aus ``res["statistics"]``, wie in ``simulation()`` berechnet.
        - mean, sd, skewness, kurtosis, lpm, hpm: Momente und partielle Momente der Renditen je Zeile aus
          ``res["statistics"]``.
        - taxes: Gezahlte Steuern gesamt (Währungseinheiten; 0 ohne Steuerbericht).
        - trades: Käufe plus Verkäufe je Jahr, summiert über alle Assets.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 1095
        d = pd.DataFrame({"date": pd.date_range("2015-01-01", periods=n)})
        d["aktien"] = 100 * np.cumprod(1 + rng.normal(3e-4, 0.01, n))
        res = simlev.simulation(d, simlev.create_strategy(aktien=simlev.asset_config(asset_class="etf")))
        print(simlev.bootstrap_study_metrics(res))
    """
    s = _res_get(res, "statistics", {})
    dq = _quantile7(np.asarray(_res_get(res, "drawdowns"), dtype=np.float64), [0.5, 0.9])
    worth = np.asarray(_res_get(res, "worth"), dtype=np.float64)
    tr = _res_get(res, "tax_report")
    taxes = _get(tr, "total_taxes_paid") if tr is not None else None

    def tot(v):
        if v is None:
            return 0.0
        if isinstance(v, Mapping):
            vals = [np.asarray(x, dtype=np.float64).ravel() for x in v.values() if x is not None]
            return r_sum(np.concatenate(vals)) if vals else 0.0
        return r_sum(np.asarray(v, dtype=np.float64).ravel())

    items = [("cagr", _res_get(res, "cagr")), ("ttwror", _res_get(res, "ttwror")), ("final_value", worth[-1]),
             ("max_drawdown", _get(s, "max_drawdown")), ("avg_drawdown", _get(s, "average_drawdown")),
             ("dd_q50", dq[0]), ("dd_q90", dq[1]), ("ulcer_index", _get(s, "ulcer_index")),
             ("longest_drawdown", _get(s, "longest_drawdown")), ("sharpe", _get(s, "sharpe")),
             ("sortino", _get(s, "sortino")), ("calmar", _get(s, "calmar")), ("omega", _get(s, "omega")),
             ("mean", _get(s, "mean")), ("sd", _get(s, "sd")), ("skewness", _get(s, "skewness")),
             ("kurtosis", _get(s, "kurtosis")), ("lpm", _get(s, "lpm")), ("hpm", _get(s, "hpm")),
             ("taxes", 0.0 if taxes is None else taxes),
             ("trades", tot(_res_get(res, "buys")) + tot(_res_get(res, "sells")))]
    items = [(k, float(v)) for k, v in items if v is not None]
    return pd.Series([v for _, v in items], index=[k for k, _ in items], dtype=np.float64)


# ═══════════════════════════════════════════════════════════════════════════
# bootstrap_study()
# ═══════════════════════════════════════════════════════════════════════════

class SimLevBootstrapStudy(RList):
    """Ergebnis von :func:`bootstrap_study` (R-Klasse ``SimLevBootstrapStudy``)."""

    r_class = ("SimLevBootstrapStudy",)

    def summary(self, metrics=("cagr", "ttwror", "max_drawdown", "sharpe", "ulcer_index", "final_value"),
                probs=(0.05, 0.25, 0.5, 0.75, 0.95)):
        return _summary_study(self, metrics=metrics, probs=probs)

    def format(self) -> str:
        head = _sp("SimLev Bootstrap-Studie '%s': %d Pfade, Strategien: %s, %d Ergebniszeilen, %.1f s\n",
                   self["method"], int(self["n_paths"]), ", ".join(self["strategies"]), len(self["results"]),
                   float(self["elapsed"]))
        return _strip1(head + _cat_summary_study(self.summary()))


class SummarySimLevBootstrapStudy(RList):
    """Zusammenfassung einer Bootstrap-Studie (R-Klasse ``summary.SimLevBootstrapStudy``)."""

    r_class = ("summary.SimLevBootstrapStudy",)

    def format(self) -> str:
        return _strip1(_cat_summary_study(self))


def _is_study(x) -> bool:
    return isinstance(x, SimLevBootstrapStudy) or (
        isinstance(x, RList) and "SimLevBootstrapStudy" in getattr(x, "r_class", ()))


def _sim_call(df, strategy, args):
    """``simulation()`` mit den aufgelösten sim_args (R: ``.sim_call``)."""
    from ._sim_blocks import _sim_call as call
    return call(df, strategy, args)


def _anniv_ends(dates, frequency):
    from .withdrawal import _anniv_ends as _ae
    return _ae(dates, frequency)


def _result_index(res):
    from .withdrawal import result_index
    return result_index(res)


def _keep_count(x, n, who):
    """Anzahl behaltener Pfade aus ``keep_paths`` (R: ``.keep_count``).

    ``True`` = alle Pfade, ``False`` oder 0 = keine, ganze Zahl k >= 1 = die ersten k Pfade (k > n: still alle).
    Logisch wird vor der Ganzzahl geprüft (``True`` ist in Python eine Ganzzahl). Fehler bei NA, Text, Vektor,
    negativen oder nicht ganzen Zahlen. Ergebnis: Anzahl in ``0..n`` (float; ``n`` darf ``inf`` sein).
    """
    if isinstance(x, (bool, np.bool_)):
        return float(n) if x else 0.0
    ok = isinstance(x, (int, float, np.integer, np.floating)) and math.isfinite(float(x)) and float(x) >= 0 and \
        float(x) == _r_round0(float(x))
    if not ok:
        _stop("%s: keep_paths muss TRUE (alle Pfade), FALSE/0 (keine) oder eine ganze Zahl k >= 1 (die ersten k Pfade) "
              "sein, nicht %s." % (who, _show(x)))
    return min(float(x), float(n))


# Chunk-Dateien von bootstrap_study(chunk_dir) (seit 1.6.3 je Sprache; R: .chunk_stem, .chunk_pruefen): Stamm
# chunk_<Nr>_seed<Seed>[_<keep_returns>][_keep<k>], Kennung R "_r.rds", Python "_py.pkl" (pickle), Julia "_jl.bin";
# bis 1.6.2 "<Stamm>.rds" in allen Sprachen. Liegt zu einem Chunk ohne eigene Datei eine fremde oder alte vor: Fehler
# (gleiche Meldung in R, Python und Julia).
_CHUNK_KENNUNG = (".rds", "_r.rds", "_py.pkl", "_jl.bin")


def _chunk_stem(ci, seed, keep_returns, keep_paths):
    return "chunk_%05d_seed%d%s%s" % (ci, int(seed), ("_" + keep_returns) if keep_returns != "none" else "",
                                      ("_keep%d" % int(keep_paths)) if keep_paths > 0 else "")


def _chunk_meldung(datei):
    return ("chunk_dir: '%s' stammt von einer anderen Sprache oder einer älteren Fassung von SimLev (bis 1.6.2) und "
            "wird nicht gelesen; je Sprache ein eigenes Verzeichnis verwenden." % datei)


def _chunk_pruefen(d, n_chunks, seed, keep_returns, keep_paths, eigen):
    for ci in range(1, n_chunks + 1):
        st = _chunk_stem(ci, seed, keep_returns, keep_paths)
        if os.path.exists(os.path.join(d, st + eigen)):
            continue
        for k in _CHUNK_KENNUNG:
            if k != eigen and os.path.exists(os.path.join(d, st + k)):
                _stop(_chunk_meldung(st + k))


@_quiet
@_study_scope
def bootstrap_study(data, config, method="stationary", n=1000, strategies=None, *, params=None, ess=False,
                    ess_grid=None, path_length=None, dates=None, start="2000-01-01", burn_in=0,
                    sim_args=None, metrics=bootstrap_study_metrics, benchmark=None, chunk_dir=None, keep_paths=0,
                    keep_returns=("none", "year", "quarter", "month"), keep_aux=None, max_tries=10, chunk_size=25,
                    seed=None, cores=1, progress=True):
    """Strategien auf Bootstrap-Pfaden auswerten.

    Erzeugt Bootstrap-Pfade wie ``bootstrap()``, berechnet je Pfad die Signale, simuliert alle Strategien mit
    ``simulation()`` auf DEMSELBEN Pfad (Common Random Numbers, gepaarter Vergleich) und speichert nur Kennzahlen.
    Pfade werden nach der Auswertung verworfen; der Speicherbedarf ist daher unabhängig von ``n``. Entspricht der
    Pipeline aus '06 Bootstraps' (Chunks, Parallelisierung), ohne die Pfade zwischenzuspeichern.

    Args:
        data: DataFrame oder Matrix mit den in ``config`` genannten Spalten (Index-Spalten als Brutto-Renditen je
            Zeile oder, bei ``input = "prices"``, als Kursniveaus; Zusatzreihen beliebig). Jede Zeile ist ein
            Simulationsschritt ("Tag"); eine Datumsspalte wird nicht ausgewertet.
        config: Objekt aus ``bootstrap_config()``.
        method: Verfahren (Standard in ``bootstrap()``: ``"raw"``, in ``bootstrap_study()``: ``"stationary"``). In
            Klammern die Einträge von ``params``, die das Verfahren verwendet:

            - "raw": IID-Zeilen-Bootstrap (Efron 1979); zerstört Zeitabhängigkeit (Nullmodell). Keine Parameter.
            - "block": Moving Block Bootstrap (Künsch 1989) (``block_length``)
            - "circular": Circular Block Bootstrap (Politis & Romano 1992) (``block_length``)
            - "stationary": Stationärer Bootstrap (Politis & Romano 1994), geometrisch verteilte Blöcke (``L``)
            - "wild": Wild Bootstrap mit gemeinsamem Gewicht je Zeile für alle Reihen (``wild_type``); erhält die
              Chronologie
            - "regime": Volatilitätsregime-Markov-Bootstrap: Regime aus Quantilen der rollierenden Volatilität des
              Referenzindex (``n_regimes``, ``vol_window``)
            - "evt": GPD-Tails des Referenzindex plus empirischer Bulk (``tail_prob``, ``both_tails``); übrige
              Indizes über das historische Verhältnis zum Referenzindex gekoppelt
            - "tails": Empirische Tail-Schichtung des Referenzindex (``tail_prob``)
            - "reset": Chronologie mit zufällig gespiegelten Segmenten (``p_break``); erhält die Chronologie
            - "garch", "gjr_garch": (GJR-)GARCH(1,1) mit Filtered Historical Simulation (keine Parameter; Kopplung
              über ``cross`` in ``bootstrap_config()``). Geschätzt per Maximum Likelihood unter Normalverteilung
              mit der C-Bibliothek von SimLev (GJR mit α + γ ≥ 0, also auch γ < 0; bis Version 1.0.0 γ ≥ 0; BFGS
              von sieben Rasterpunkten), notfalls mit Momentschätzern; die Meldungen nennen den Weg "ml" bzw.
              "momente" (bis 0.10.0 "rugarch"/"optim")
            - "ms_garch", "ms_ar_garch_m", "tvtp_ms_garch": Markov-Switching-GARCH-Familie: eigene ML-Schätzung
              des MS-GARCH-Modells nach Haas, Mittnik und Paolella (2004), Normalverteilung, Varianzmodell
              "sGARCH" oder "gjrGARCH" je Regime (GJR mit α + γ ≥ 0, also auch γ < 0; BFGS mit analytischem
              Gradienten von 12 bzw. bei "gjrGARCH" 20 Startpunkten); "ms_ar_garch_m" zusätzlich mit AR- und
              GARCH-in-Mean-Termen je Regime, "tvtp_ms_garch" mit zeitvariablen Uebergangswahrscheinlichkeiten
              (``ms_n_regimes``/``ms_garch_model``, ``ms_ar_n_regimes``/``ms_ar_garch_model`` bzw.
              ``tvtp_n_regimes``/``tvtp_garch_model``)

            Bei "wild" und "reset" muss ``path_length`` der Länge der Historie entsprechen.
        n: Anzahl Pfade (Standard 1000); bei ``ess = True`` das Gesamtbudget, das auf die Parameterkombinationen
            verteilt wird. Pfade, die nach ``max_tries`` Versuchen ungültig bleiben, fehlen im Ergebnis.
        strategies: Benannte, nicht leere Liste. Jedes Element ist entweder direkt eine Strategie
            (``create_strategy()``) oder eine Liste mit

            - strategy: Strategie (Pflicht).
            - signal: Optional Funktion, die den Pfad-DataFrame (alle Zeilen einschließlich ``burn_in``) erhält
              und entweder einen DataFrame (ersetzt den Pfad-DataFrame) oder eine benannte Liste von Spalten
              gleicher Länge zurückgibt, z. B. ``{"buy": ..., "sell": ...}``; ``NA`` in logischen Spalten wird zu
              ``False``.
            - args: Liste von Argumenten für ``simulation()``, die ``sim_args`` für diese Strategie überschreiben.
            - map: Spalten-Aliase als benannter Zeichenvektor Alias -> Pfadspalte, z. B. ``{"letf": "eu_l2"}``.

            Die Asset-Namen der Strategien müssen Spaltennamen des Pfads (bzw. Aliase aus ``map``) sein. Schlägt
            Signal, Simulation oder Kennzahlberechnung für einen Pfad fehl, fehlt diese Zeile im Ergebnis; die
            Funktion warnt mit der Anzahl und der häufigsten Fehlermeldung (alle in ``errors``). Schlagen alle
            Kombinationen fehl, bricht sie mit dieser Meldung ab. Warnungen aus Signal, Simulation und Kennzahlen
            werden je Pfad gesammelt, dedupliziert und am Ende als eine Warnung ausgegeben (mit Anzahl der
            betroffenen Pfade; alle in ``warnings``); bei ``cores > 1`` ebenso.
        params: Benannte Liste von Verfahrensparametern; nicht angegebene Einträge erhalten den Standardwert
            (Standard ``{}`` = alle Standardwerte). Je Verfahren werden nur die oben genannten Einträge verwendet:

            - L: Erwartete Blocklänge in Zeilen für "stationary" (Zahl >= 1, Standard 20) oder ``"auto"``
              (``bootstrap_block_length()``, Spalte ``stationary``).
            - block_length: Feste Blocklänge in Zeilen für "block" und "circular" (ganze Zahl, Standard 20; bei
              "block" höchstens Zeilen der Historie minus 1, bei "circular" höchstens Zeilen der Historie) oder
              ``"auto"`` (``bootstrap_block_length()``, Spalte ``circular``).
            - wild_type: Gewichte beim Wild Bootstrap: 0 = Rademacher (Standard), 1 = Mammen, 2 = Standardnormal;
              andere Werte sind ein Fehler.
            - n_regimes: Anzahl Volatilitätsregime für "regime" (Standard 2).
            - vol_window: Fensterlänge der rollierenden Volatilität in Zeilen für "regime" (Standard 20).
            - tail_prob: Tail-Wahrscheinlichkeit je Seite als Anteil für "evt" und "tails" (Standard 0.05 = 5
              Prozent).
            - both_tails: Logisch, nur "evt": auch den rechten Tail mit einer GPD modellieren (Standard ``True``).
            - p_break: Wahrscheinlichkeit je Zeile als Anteil (0 bis 1), dass bei "reset" ein neues Segment
              beginnt (Standard 0.02).
            - ms_n_regimes, ms_ar_n_regimes, tvtp_n_regimes: Anzahl Regime für "ms_garch", "ms_ar_garch_m" bzw.
              "tvtp_ms_garch" (Standard je 2). Hat die Reihe weniger deutlich getrennte Regime als angefordert (z.
              B. drei Regime auf einer Reihe mit nur einem oder zwei Volatilitätszuständen), kann ein Regime
              entarten: Verweilwahrscheinlichkeit nahe 0 (Meldung "P(stay)"), kaum oder keine Tage im Regimepfad,
              mitunter Persistenz nahe 1 mit unplausibel hoher unbedingter Varianz; die Log-Likelihood liegt dann
              kaum über der mit einem Regime weniger. In diesem Fall die Anzahl Regime verkleinern.
            - ms_garch_model, ms_ar_garch_model, tvtp_garch_model: Varianzmodell je Regime: "sGARCH" (GARCH(1,1))
              oder "gjrGARCH" (GJR-GARCH(1,1), Standard je "gjrGARCH"); andere Werte sind ein Fehler.

            Der Eintrag ``garch_order`` (Standard ``[1, 1]``) ist vorhanden, ändert aber nichts: die
            GARCH-Verfahren schätzen immer GARCH(1,1).
        ess: Logisch (Standard ``False``): ESS-gewichtete Gittersuche über Hyperparameter (wie im Original). Das
            Budget ``n`` wird invers zur effektiven Stichprobengröße (ESS) je Kombination verteilt; die Pfade
            erhalten Gewichte (Mittel 1), mit denen ``bootstrap_probability()`` und ``summary()`` rechnen. Für
            "raw", "garch" und "gjr_garch" gibt es kein Standardgitter (dann normaler Bootstrap).
        ess_grid: Benannte Liste von Wertevektoren je Hyperparameter (z. B. ``{"L": [20, 50, 100]}``); ``None``
            (Standard) = Standardgitter des Verfahrens (z. B. ``L`` bzw. ``block_length`` 5, 10, 20, 30, 50, 75,
            100 Zeilen, begrenzt auf die halbe Historienlänge). Nur bei ``ess = True`` verwendet.
        path_length: Pfadlänge in Zeilen (simulierte Schritte, ganze Zahl, mindestens 1); ``None`` (Standard) =
            Anzahl verwendbarer Zeilen der Historie. Damit lassen sich z. B. 50-jährige Pfade aus 30 Jahren
            Historie erzeugen. Jeder Pfad hat ``path_length + 1`` Zeilen (Startzeile plus Schritte).
        dates, start: Kalender der Pfade: ``dates`` ist ein Datumsvektor der Länge ``path_length + 1``; ``None``
            (Standard) = aufeinanderfolgende Kalendertage ab ``start`` (Standard "2000-01-01"), siehe
            ``bootstrap_data()``.
        burn_in: Anzahl Anfangszeilen des Pfads, die nach der Signalberechnung verworfen werden (Signal-Vorlauf,
            z. B. 730 Tage für eine 430-Tage-SMA; Standard 0). Muss kleiner als ``path_length`` sein.
        sim_args: Benannte Liste gemeinsamer Argumente für ``simulation()`` (Standard ``{}``), z. B.
            ``{"start_value": 1000, "tax": tax_profile()}``: Argumente von ``simulation()`` außer ``data`` und
            ``strategy``, also auch Bausteine (z. B. ``dca = dca_plan(100, 1)``, ``tax = tax_profile()``) und
            Pfade zu Parametern der Bausteine (``"dca.value"``, siehe ``sensitivity_grid``). Alte Einzelargumente
            (bis 0.8.0, vor den Bausteinen, z. B. ``dca_value``) ergeben einen Fehler, der den Baustein nennt.
        metrics: Funktion ``SimLevResult -> benannter numerischer Vektor`` (Standard
            ``bootstrap_study_metrics()``); die Namen werden zu Spalten von ``results``.
        benchmark: Name einer Strategie aus ``strategies`` als Vergleich für die gepaarte Auswertung in
            ``summary()``; ``None`` (Standard) = keine.
        chunk_dir: Optional (Standard ``None``) Verzeichnis für Zwischenergebnisse je Chunk (Dateien
            ``chunk_<Nr>_seed<Seed>_py.pkl``, bei ``keep_returns`` mit Frequenz-Suffix, bei ``keep_paths`` > 0 mit
            Suffix ``_keep<k>``, jeweils vor ``_py.pkl``; R schreibt ``_r.rds``, Julia ``_jl.bin``). Liegt zu einem
            Chunk nur eine Datei einer anderen Sprache oder der Form bis 1.6.2 (``chunk_<Nr>_seed<Seed>.rds``),
            bricht die Studie mit einer Meldung ab. Vorhandene Dateien werden gelesen statt neu gerechnet; so wird ein abgebrochener
            Lauf mit gleichem Seed fortgesetzt. Die Dateien werden nur über Chunk-Nummer, Seed, ``keep_returns``
            und ``keep_paths`` zugeordnet: bei geänderten Strategien, Daten oder Parametern ein neues Verzeichnis
            verwenden.
        keep_paths: Pfadmatrizen zusätzlich zurückgeben (Diagnose): ``True`` = alle Pfade, ``False`` oder 0
            (Standard) = keine, ganze Zahl k >= 1 = die ersten k Pfade (k größer als die Pfadzahl: alle); ``NA``,
            Text, Vektoren, negative oder nicht ganze Zahlen ergeben einen Fehler. Speicherbedarf: Alle behaltenen
            Pfadmatrizen bleiben im Ergebnis und gehen bei ``cores > 1`` auch durch die Prozessgrenze, ungefähr
            Pfade x (Pfadlänge + 1) x Reihen x 8 Byte (z. B. 10 000 Pfade x 7 300 Tage x 3 Reihen x 8 Byte = 1,75
            GB).
        keep_returns: ``"none"`` (Standard) oder ``"year"``, ``"quarter"``, ``"month"``: speichert je Strategie
            und Pfad die zeitgewichteten Brutto-Periodenrenditen (aus ``result_index()``, Perioden ab dem ersten
            Tag nach ``burn_in``). Die Studie kann dann direkt an ``withdrawal_simulation()`` bzw.
            ``withdrawal_paths()`` übergeben werden.
        keep_aux: Zeichenvektor mit Namen von Zusatzreihen aus ``config``, deren Brutto-Inflation je Periode
            ebenfalls gespeichert wird (Inflation für die Entnahmephase, Argument ``inflation`` von
            ``withdrawal_paths()``); nur zusammen mit ``keep_returns`` wirksam. Die Behandlung folgt ``aux_type``
            in ``bootstrap_config()``: ``"level"`` (Preisindex) = Periodenverhältnisse des kumulierten Niveaus in
            der Pfadspalte; ausdrücklich ``"rate"`` = Inflationsrate in Prozent pro Jahr (2 = 2 % p. a.; nicht je
            Datenperiode, kein Anteil), je Pfadzeile über die Kalendertage aus ``dates`` aufgezinst, Π (1 +
            r/100)^Tage/365.25 über die Zeilen der Periode (wie ``inflation_type = "rate_pa"`` in
            ``withdrawal_paths()``, das dann nicht erneut angegeben werden muss). Ohne Angabe in ``aux_type`` gilt
            die Reihe wie bisher als Niveau (Niveau-Variante des Pfads, Attribut ``aux_level``, siehe
            ``bootstrap()``: Verhältnis der kumulierten Zeilenverhältnisse an den Periodenenden), so dass jede
            Periode die Inflation der gezogenen Zeilen eines Preisindex enthält; eine Ratenspalte ergibt so keine
            Inflation in Prozent p. a. Sind gespeicherte Faktoren nicht endlich oder <= 0 (z. B. eine nicht
            gekennzeichnete Zinsreihe mit Vorzeichenwechsel), warnt die Funktion, und ``withdrawal_paths()``
            bricht mit dieser Reihe als Inflation ab. Standard ``None``.
        max_tries: Versuche je Pfad (Standard 10), falls ein Pfad ungültig ist (Indexrendite <= 0 oder nicht
            endlich). Ein Totalverlust eines Hebelprodukts macht den Pfad nicht ungültig.
        chunk_size: Pfade je Arbeitspaket (Standard 25); Einheit der Parallelisierung und der Zwischenspeicherung.
        seed: Ganzzahliger Startwert (|seed| < 2^53); ``None`` (Standard) = genau einmal aus dem Zufallszustand
            von SimLev gezogen (siehe ``simlev_seed()``; ganze Zahl von 0 bis 2^31 - 1, im Ergebnis unter ``seed``
            gespeichert, damit reproduzierbar). Jeder Pfad i erhält einen eigenen Strom (Sprung um 2^128 Schritte
            je Pfad), so dass Pfad i unabhängig von ``cores`` (und bei ``bootstrap_study()`` von ``chunk_size``)
            ist und ``bootstrap()`` und ``bootstrap_study()`` mit gleichem Seed (und gleichen Daten, Verfahren,
            ``params``, ``ess`` und ``path_length``) dieselben Pfade erzeugen. Mit angegebenem Seed bleibt der
            Zufallszustand von SimLev unverändert; mit ``seed = None`` liefern wiederholte Aufrufe verschiedene
            Pfade. ``set.seed()`` wirkt nicht.
        cores: Anzahl Prozesse (Standard 1); parallelisiert wird über Chunks. Der MS-GARCH-Fit der Vorberechnung
            nutzt ebenso viele Threads (Ergebnis unabhängig davon).
        progress: Logisch: Fortschrittsmeldungen per ``message()`` (Standard ``True``; Meldung je Chunk nur bei
            ``cores = 1``).

    Returns:
        Objekt der Klasse ``SimLevBootstrapStudy``, eine Liste mit

        - results: DataFrame mit einer Zeile je Pfad und Strategie: ``strategy``, ``path`` (Pfadnummer),
          ``weight`` (Pfadgewicht), ``combo`` (ESS-Kombination), ``tries`` (Versuche) und den Kennzahlen aus
          ``metrics`` (bei ``bootstrap_study_metrics()`` z. B. ``cagr`` und ``max_drawdown`` als Anteil).
        - method, n_paths, strategies, benchmark, config, params, seed, burn_in, path_length, elapsed: Metadaten
          (``elapsed`` in Sekunden).
        - ess_design, path_weights: ESS-Design (oder ``None``) und Gewichte aller Pfade.
        - paths: Liste der mit ``keep_paths`` behaltenen Pfadmatrizen.
        - returns, aux_returns: Bei ``keep_returns``: je Strategie bzw. Zusatzreihe eine Matrix (Perioden x Pfade)
          von Brutto-Periodenrenditen bzw. Brutto-Inflation (z. B. 1.05 bzw. 1.02), sonst ``None``.
        - returns_frequency, returns_dates: Frequenz und Periodenenden (Datum) der gespeicherten Renditen.
        - errors: DataFrame der Fehler der Einzelsimulationen (``strategy``, ``stage`` = "Signal", "Simulation"
          oder "Kennzahlen", ``message``, ``n`` = Anzahl Pfade, ``first_path``), nach Häufigkeit sortiert;
          ``None``, wenn keine.
        - warnings: DataFrame der deduplizierten Warnungen (``strategy``, ``message``, ``n`` = Anzahl Pfade mit
          dieser Warnung, ``first_path``); ``None``, wenn keine.

    Details:
        Ablauf je Pfad: Pfadmatrix erzeugen, mit ``dates`` zu einem DataFrame wie in ``bootstrap_data()`` machen
        (Spalte ``date`` plus Pfadspalten aus ``bootstrap_config()``), je Strategie optional ``signal`` und
        ``map`` anwenden, die ersten ``burn_in`` Zeilen verwerfen, ``simulation()`` mit ``sim_args`` aufrufen und
        ``metrics`` auswerten. Weiterverarbeitung: ``summary()`` und ``plot()`` (siehe SimLevBootstrap-methods),
        ``bootstrap_probability()``; mit ``keep_returns`` zusätzlich ``withdrawal_paths()`` bzw.
        ``withdrawal_simulation()`` (Entnahmephase auf den simulierten Strategiepfaden).

    Literatur:
        Haas, M., Mittnik, S. & Paolella, M.S. (2004), A New Approach to Markov-Switching GARCH Models, Journal of
        Financial Econometrics 2(4) (Verfahren "ms_garch", "ms_ar_garch_m", "tvtp_ms_garch"); Hamilton, J.D.
        (1989), Econometrica 57(2) (Filter).

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 1095
        d = pd.DataFrame({"date": pd.date_range("2015-01-01", periods=n)})
        d["aktien"] = 100 * np.cumprod(1 + rng.normal(3e-4, 0.01, n))
        cfg = simlev.bootstrap_config({"akt": "aktien"}, input="prices",
                                      letfs=[{"base": "akt", "leverage": 2, "finance": 2}])
        st = simlev.bootstrap_study(d, cfg, "stationary", 5, params={"L": 30}, path_length=500, seed=1, progress=False,
                                    strategies={"etf": simlev.create_strategy(akt=simlev.asset_config(asset_class="etf")),
                                                "letf": simlev.create_strategy(akt_l2=simlev.asset_config(asset_class="etf"))})
        print(st["results"][["strategy", "path", "cagr", "max_drawdown"]].head())
    """
    keep_returns = _match_arg(keep_returns, ("none", "year", "quarter", "month"))
    if keep_aux is not None:
        keep_aux = [keep_aux] if isinstance(keep_aux, str) else [str(a) for a in keep_aux]
        if not all(a in config["aux_names"] for a in keep_aux):
            _stop("keep_aux muss Namen aus config$aux enthalten.")
    t0 = time.time()
    if strategies is None or not len(strategies) or not isinstance(strategies, Mapping) or \
            any(str(k) == "" for k in strategies.keys()):
        _stop("'strategies' muss eine benannte, nicht-leere Liste sein.")
    specs = {}
    for k, s in strategies.items():
        if isinstance(s, Mapping) and s.get("strategy") is not None and not _is_strategy(s):
            specs[str(k)] = dict(s)
        else:
            specs[str(k)] = {"strategy": s}
    snames = list(specs.keys())
    if benchmark is not None and benchmark not in snames:
        _stop("benchmark muss einer der Strategienamen sein.")
    # Argumente für simulation() je Strategie einmal auflösen (Bausteine, Pfade; alte flache Namen: Fehler)
    from ._sim_blocks import _sim_args_set
    sim_args = _sim_args_set({}, sim_args, "bootstrap_study")
    for nm0 in snames:
        specs[nm0]["sim"] = _sim_args_set(sim_args, specs[nm0].get("args"), "bootstrap_study")
    setup = _boot_setup(data, config, method, n, params, ess, ess_grid, path_length, cores)
    keep_paths = _keep_count(keep_paths, setup["n_paths"], "bootstrap_study")   # True = alle Pfade
    n_out = setup["n_out"]
    if dates is None:
        dates = _seq_dates(_to_date(start, "start"), n_out + 1)
    if len(np.atleast_1d(dates)) != n_out + 1:
        _stop("dates braucht Länge %d (Pfadlänge + 1)." % (n_out + 1))
    dates = _to_date(dates, "dates")
    if burn_in >= n_out:
        _stop("burn_in ist länger als der Pfad.")
    if seed is None:                    # None -> einmal k aus G
        seed = _sl.next_seed()
    else:
        _sl.check_seed(seed)
    n_paths = setup["n_paths"]
    streams = _sl.streams(seed, n_paths)                                          # U_i = J^i(S_0)
    ids = np.arange(1, n_paths + 1)
    chunk_size = float(chunk_size)
    keys = np.ceil(ids / chunk_size)
    chunks = [ids[keys == k] for k in sorted(set(keys.tolist()))]
    if chunk_dir is not None:
        os.makedirs(chunk_dir, exist_ok=True)
        _chunk_pruefen(chunk_dir, len(chunks), seed, keep_returns, keep_paths, "_py.pkl")
    burn_in = int(burn_in)
    sim_rows = np.arange(burn_in + 1, n_out + 2)
    dsim = dates[sim_rows - 1]
    ret_ends = _anniv_ends(dsim, keep_returns) if keep_returns != "none" else None
    if ret_ends is not None and len(ret_ends) < 2:
        _stop("Pfad nach burn_in zu kurz für eine volle Periode in keep_returns.")

    def per_ret(v):
        v = np.asarray(v, dtype=np.float64)[np.asarray(ret_ends) - 1]
        return v[1:] / v[:-1]

    at = _get(config, "aux_type")
    sets = list(_get(config, "aux_type_set", []) or [])
    rate_set = [s for s in sets if _aux_type_of(at, s) == "rate"]
    rate_aux = [a for a in (keep_aux or []) if a in rate_set]
    rate_aux = list(dict.fromkeys(rate_aux))
    dt_sim = np.diff(_rel_dates(dsim)).astype(np.float64) / 365.25

    def aux_level_of(P, a):
        if a in rate_aux:
            v = P[a].to_numpy()[sim_rows[1:] - 1]
            m = min(len(v), len(dt_sim))   # wie zip()
            f = _pow_rec(1 + v[:m] / 100, dt_sim[:m])
            return r_cumprod(np.concatenate([[1.0], f]))
        if _aux_type_of(at, a) == "level":
            return P[a].to_numpy()[sim_rows - 1]
        return P.attrs["aux_level"][a].to_numpy()[sim_rows - 1]

    def eval_path(i):
        dp = _draw_path(setup, i, streams[i - 1], config, method, max_tries)
        if dp["path"] is None:
            return None
        P = dp["path"]
        df0 = pd.DataFrame({"date": dates, **{c: P[c].to_numpy() for c in P.columns}})   # ein Aufbau (seit 1.6.1)
        rows = {}
        for nm in snames:
            sp = specs[nm]
            # Kopie nur, wenn Signalfunktion oder map den Rahmen ändern (seit 1.6.3; simulation() ändert ihn nicht)
            df = df0.copy() if sp.get("signal") is not None or sp.get("map") is not None else df0
            wr = []

            def fail(stage, msg, wr=wr):
                return {"row": None, "ret": None, "err": {"stage": stage, "message": msg}, "warn": _uniq(wr)}

            def run(fn, wr=wr):
                with warnings.catch_warnings(record=True) as wl:
                    warnings.simplefilter("always")
                    try:
                        return fn()
                    finally:
                        wr.extend(str(w.message) for w in wl)

            if sp.get("signal") is not None:
                try:
                    sg = run(lambda: sp["signal"](df))
                except Exception as e:  # noqa: BLE001
                    rows[nm] = fail("Signal", str(e))
                    continue
                if sg is None:
                    rows[nm] = fail("Signal", "Signal-Funktion lieferte NULL")
                    continue
                if isinstance(sg, pd.DataFrame):
                    df = sg
                else:
                    for k2, v in sg.items():
                        v = _logical_fill(v)
                        df[k2] = v
            if sp.get("map") is not None:
                for a2, col in dict(sp["map"]).items():
                    df[a2] = df[col]
            if burn_in > 0:
                df = df.iloc[burn_in:].reset_index(drop=True)
            args = sp["sim"]
            try:
                with contextlib.redirect_stderr(io.StringIO()):
                    res = run(lambda: _sim_call(df, sp["strategy"], args))
            except Exception as e:  # noqa: BLE001
                rows[nm] = fail("Simulation", str(e))
                continue
            try:
                m = run(lambda: metrics(res))
            except Exception as e:  # noqa: BLE001
                rows[nm] = fail("Kennzahlen", str(e))
                continue
            if m is None:
                rows[nm] = fail("Kennzahlen", "metrics() lieferte NULL")
                continue
            if isinstance(m, Mapping):
                m = pd.Series(list(m.values()), index=list(m.keys()), dtype=np.float64)
            m = pd.Series(np.asarray(m, dtype=np.float64), index=list(m.index) if isinstance(m, pd.Series) else None)
            row = pd.Series(np.concatenate([[float(i), float(setup["weights"][i - 1]),
                                             float(setup["combo_of_path"][i - 1]), float(dp["tries"])], m.to_numpy()]),
                            index=["path", "weight", "combo", "tries"] + list(m.index), dtype=np.float64)
            rows[nm] = {"row": row, "ret": per_ret(_result_index(res)["value"].to_numpy()) if ret_ends is not None
                        else None, "warn": _uniq(wr)}
        aux_ret = None
        if ret_ends is not None and keep_aux:
            aux_ret = {a: per_ret(aux_level_of(P, a)) for a in keep_aux}
        return {"id": i, "rows": rows, "aux": aux_ret, "path": P if i <= keep_paths else None}

    def run_chunk(ci):
        f = None
        if chunk_dir is not None:
            f = os.path.join(chunk_dir, _chunk_stem(ci, seed, keep_returns, keep_paths) + "_py.pkl")
        if f is not None and os.path.exists(f):
            with open(f, "rb") as fh:
                return pickle.load(fh)
        out = [eval_path(int(i)) for i in chunks[ci - 1]]
        if f is not None:
            with open(f, "wb") as fh:
                pickle.dump(out, fh)
        if progress and cores <= 1:
            _message("  Chunk %d/%d fertig (%.0f s)" % (ci, len(chunks), time.time() - t0))
        return out

    if progress:
        _message("Bootstrap-Studie '%s': %d Pfade x %d Strategien, %d Chunks, %d Kern(e)"
                 % (method, n_paths, len(specs), len(chunks), int(cores)))
    res = _par_lapply(range(1, len(chunks) + 1), run_chunk, cores)
    res = [r for ch in res for r in ch]
    tab_parts = []
    for nm in snames:
        rws = [r["rows"][nm]["row"] for r in res if r is not None and r["rows"][nm]["row"] is not None]
        if not rws:
            continue
        cols = list(rws[0].index)
        mat = np.array([np.asarray(rw, dtype=np.float64) for rw in rws])
        d = pd.DataFrame({"strategy": [nm] * len(rws), **{c: mat[:, j] for j, c in enumerate(cols)}})   # einmal
        tab_parts.append(d)
    tab = pd.concat(tab_parts, ignore_index=True) if tab_parts else None

    def cond_tab(field):
        st, sg, ms, pa = [], [], [], []
        for r in res:
            if r is None:
                continue
            for nm in snames:
                v = r["rows"][nm].get(field)
                if not v:
                    continue
                if field == "err":
                    sg.append(v["stage"])
                    vv = [v["message"]]
                else:
                    vv = list(v)
                    sg.extend([None] * len(vv))
                st.extend([nm] * len(vv))
                ms.extend(vv)
                pa.extend([int(r["id"])] * len(vv))
        if not st:
            return None
        key = ["%s\r%s\r%s" % (a, "NA" if b is None else b, c) for a, b, c in zip(st, sg, ms)]
        cnt = {}
        for k in key:
            cnt[k] = cnt.get(k, 0) + 1
        first = [not d for d in _duplicated(key)]
        idx = [i for i, f0 in enumerate(first) if f0]
        out = pd.DataFrame({"strategy": [st[i] for i in idx], "stage": [sg[i] for i in idx],
                            "message": [ms[i] for i in idx], "n": [cnt[key[i]] for i in idx],
                            "first_path": [pa[i] for i in idx]})
        if field == "warn":
            out = out.drop(columns="stage")
        order = sorted(range(len(out)), key=lambda i: -out["n"].iloc[i])
        out = out.iloc[order].reset_index(drop=True)
        return out

    errs = cond_tab("err")
    warns = cond_tab("warn")
    first_err = None
    if errs is not None:
        first_err = "Strategie '%s', %s, %d-mal: %s" % (errs["strategy"].iloc[0], errs["stage"].iloc[0],
                                                       int(errs["n"].iloc[0]), errs["message"].iloc[0])
    if tab is None:
        if first_err is None:
            _stop("Keine Strategie-Ergebnisse - Strategie, Signale und sim_args prüfen.")
        _stop("Keine Strategie-Ergebnisse: alle %d Pfad-Strategie-Kombinationen fehlgeschlagen (%d verschiedene "
              "Fehlermeldung(en)). Häufigster Fehler (%s) - Strategie, Signale und sim_args prüfen."
              % (n_paths * len(specs), len(errs), first_err))
    n_fail = n_paths * len(specs) - len(tab)
    if n_fail > 0:
        _warn("%d Pfad-Strategie-Kombinationen ohne Ergebnis (Simulation/Signal fehlgeschlagen)%s."
              % (n_fail, "" if first_err is None else
                 "; häufigster Fehler (%s); alle Fehler in $errors" % first_err))
    if warns is not None:
        k = min(3, len(warns))
        txt = "; ".join("[Strategie '%s', %d von %d Pfaden] %s" % (warns["strategy"].iloc[j], int(warns["n"].iloc[j]),
                                                                   n_paths, warns["message"].iloc[j])
                        for j in range(k))
        _warn("Warnungen der Einzelsimulationen (%d verschiedene, zusammengefasst; alle in $warnings): %s%s"
              % (len(warns), txt, "; ... und %d weitere" % (len(warns) - k) if len(warns) > k else ""))
    returns = aux_returns = None
    if ret_ends is not None:
        n_per = len(ret_ends) - 1

        def fill_mat(get):
            M = np.full((n_per, n_paths), _NAN)
            for r in res:
                if r is None:
                    continue
                v = get(r)
                if v is not None:
                    M[:, int(r["id"]) - 1] = v
            return M

        returns = {nm: fill_mat(lambda r, nm=nm: r["rows"][nm]["ret"]) for nm in snames}
        if keep_aux:
            aux_returns = {a: fill_mat(lambda r, a=a: (r["aux"] or {}).get(a)) for a in keep_aux}
        for a in (keep_aux or []):
            r = aux_returns[a]
            r = r[~np.isnan(r)]
            badv = r[~np.isfinite(r) | (r <= 0)] if r.size else r
            if badv.size:
                if a in rate_aux:
                    msg = ("keep_aux: Zusatzreihe '%s' (aux_type 'rate') ergibt nicht endliche oder nicht positive "
                           "Periodenfaktoren (z. B. %s; Rate <= -100 %%?); als Inflation in withdrawal_paths()/"
                           "withdrawal_simulation() nicht verwendbar.")
                else:
                    msg = ("keep_aux: Zusatzreihe '%s' ist kein positives Niveau (Periodenverhältnisse nicht "
                           "endlich oder <= 0, z. B. %s); als Inflation in withdrawal_paths()/withdrawal_simulation() "
                           "nicht verwendbar. Für eine Rate aux_type = c(<Name> = 'rate') in bootstrap_config() "
                           "angeben.")
                _warn(msg % (a, _fmt1(float(badv[0]), digits=4)))
    elapsed = time.time() - t0
    if progress:
        _message("Fertig: %d Ergebniszeilen in %.1f s." % (len(tab), elapsed))
    return SimLevBootstrapStudy([
        ("results", tab), ("method", method), ("n_paths", n_paths), ("strategies", snames),
        ("benchmark", benchmark), ("config", config), ("params", setup["base_p"][0]),
        ("ess_design", setup["design"]), ("seed", seed), ("burn_in", burn_in), ("path_length", n_out),
        ("elapsed", elapsed), ("paths", [r["path"] for r in res if r is not None and r["path"] is not None]),
        ("returns", returns), ("aux_returns", aux_returns),
        ("returns_frequency", keep_returns if keep_returns != "none" else None),
        ("returns_dates", dsim[np.asarray(ret_ends) - 1] if ret_ends is not None else None),
        ("path_weights", setup["weights"]), ("errors", errs), ("warnings", warns),
    ])


def _div(a: float, b: float) -> float:
    """IEEE-Division wie in R (x/0 = Inf, 0/0 = NaN)."""
    a = float(a)
    b = float(b)
    if b == 0.0:
        if math.isnan(a):
            return a
        if a == 0.0:
            return math.nan
        return math.copysign(math.inf, a) * math.copysign(1.0, b)
    return a / b


def _sqrt(v: float) -> float:
    if math.isnan(v):
        return v
    return math.sqrt(v) if v >= 0 else math.nan


def _logical_fill(v):
    """Logische Spalten: ``NA`` -> ``FALSE``."""
    if isinstance(v, pd.Series):
        if v.dtype == bool:
            return v.to_numpy()
        if v.dtype == object and all(x is None or isinstance(x, (bool, np.bool_)) or
                                     (isinstance(x, float) and math.isnan(x)) for x in v):
            return np.array([bool(x) if isinstance(x, (bool, np.bool_)) else False for x in v], dtype=bool)
        if str(v.dtype) == "boolean":
            return v.fillna(False).to_numpy(dtype=bool)
        return v.to_numpy()
    a = np.asarray(v)
    if a.dtype == object and len(a) and all(x is None or isinstance(x, (bool, np.bool_)) for x in a):
        return np.array([bool(x) if x is not None else False for x in a], dtype=bool)
    return a


# ═══════════════════════════════════════════════════════════════════════════
# Gewichtete Quantile, Wahrscheinlichkeiten, Zusammenfassung
# ═══════════════════════════════════════════════════════════════════════════

@_quiet
def _wquantile(x, w, probs):
    """Gewichtete Quantile (gewichteter Typ 7, Akinshin 2023), R: ``.wquantile``."""
    x = np.asarray(x, dtype=np.float64).ravel()
    w = np.asarray(w, dtype=np.float64).ravel()
    if w.size == 1 and x.size != 1:
        w = np.repeat(w, x.size)
    probs = np.atleast_1d(np.asarray(probs, dtype=np.float64)).ravel()
    ok = np.isfinite(x) & np.isfinite(w)
    x = x[ok]
    w = w[ok]
    if not len(x):
        return np.full(len(probs), _NAN)
    if len(set(float(v) for v in w)) == 1:
        return _quantile7(x, probs)
    sw = r_sum(w)
    if not (sw > 0):
        return np.full(len(probs), _NAN)
    o = np.argsort(x, kind="stable")
    x = x[o]
    w = w[o] / sw
    r = r_cumsum(w)   # C-Kern (cumsum in long double wie R)
    r[-1] = 1.0
    lft = np.concatenate([[0.0], r[:-1]])
    ne = 1 / r_sum(w * w)
    out = np.empty(len(probs))
    for i, p in enumerate(probs):
        a = (ne - 1) * p / ne
        fr = np.minimum(np.maximum((r - a) * ne, 0.0), 1.0)
        fl = np.minimum(np.maximum((lft - a) * ne, 0.0), 1.0)
        out[i] = r_sum((fr - fl) * x)
    return out


def _eval_condition(cond, d, env):
    """Bedingung in ``d`` auswerten wie ``as.logical(eval(cond, d, env))``.

    Text in R-Syntax über :mod:`simlev._r.rexpr` (Spalten haben Vorrang vor
    ``env``; Ergebnis in R's Länge), Python-Funktionen ``DataFrame -> Vektor``
    (Skalar wird auf ``len(d)`` erweitert). Ergebnis: ``object``-Array mit
    ``True``/``False``/``None``.
    """
    if not callable(cond):
        from ._r import rexpr as _rexpr
        return _rexpr.as_logical(_rexpr.eval_r(str(cond), d, env=env))
    v = cond(d)
    a = np.asarray(v)
    if a.ndim == 0:
        a = np.full(len(d), a.item())
    out = np.empty(len(a), dtype=object)
    for i, z in enumerate(a):
        if z is None or (isinstance(z, float) and math.isnan(z)):
            out[i] = None
        else:
            out[i] = bool(z)
    return out


@env_from_caller
def bootstrap_probability(study, *args, thresholds=None, env=None, **kwargs):
    """Wahrscheinlichkeiten aus einer Bootstrap-Studie.

    Wertet beliebige logische Bedingungen je Strategie über alle Pfade einer ``bootstrap_study()`` aus (mit den
    Pfadgewichten, also ESS-gewichtet), z. B. die gemeinsame Wahrscheinlichkeit, eine Mindestrendite zu erreichen
    und einen maximalen Drawdown nicht zu überschreiten (wie ``calc_metrics`` in '06 Bootstraps').

    Args:
        study: Objekt der Klasse ``SimLevBootstrapStudy`` aus ``bootstrap_study()``.
        *args: Benannte oder unbenannte Bedingungen in Kennzahlnamen, z. B. ``ttwror >= 0.13``, ``joint = ttwror
            >= 0.13 & max_drawdown <= 0.95``. Unbenannte Bedingungen werden nach ihrem Ausdruck benannt.
        thresholds: Optional (Standard ``None``) benannte Liste je Strategiename mit einer benannten Liste von
            Ausdrücken (``quote()``), z. B. ``{"sma": {"ziel": quote(cagr >= 0.08)}}``. Für eine hier genannte
            Strategie ersetzen diese Bedingungen die Bedingungen aus ``...`` (strategiespezifische Schwellen).
        env: Mapping für freie Variablen und Funktionen in Bedingungen.
        **kwargs: Benannte oder unbenannte Bedingungen in Kennzahlnamen, z. B. ``ttwror >= 0.13``, ``joint =
            ttwror >= 0.13 & max_drawdown <= 0.95``. Unbenannte Bedingungen werden nach ihrem Ausdruck benannt.

    Returns:
        DataFrame mit einer Zeile je Strategie und Bedingung: ``strategy``, ``condition`` (Name), ``probability``
        (gewichtete Wahrscheinlichkeit als Anteil), ``se`` (Monte-Carlo-Standardfehler √p(1-p)/n_eff mit
        effektiver Pfadzahl n_eff = (Σ w)^2 / Σ w^2) und ``n`` (Anzahl ausgewerteter Pfade).

    Details:
        Die Bedingungen werden zeilenweise in ``study["results"]`` ausgewertet; verwendbar sind dort alle Spalten,
        also die Kennzahlen aus ``metrics`` (bei ``bootstrap_study_metrics()`` z. B. ``cagr``, ``ttwror``,
        ``max_drawdown`` als Anteil) sowie ``path``, ``weight``, ``combo`` und ``tries``. Zeilen mit
        ``NA``-Ergebnis zählen nicht. Freie Variablen in den Bedingungen (z. B. eine Schwelle ``thr``) werden in
        der Umgebung des Aufrufs gesucht (auch lokale Variablen einer aufrufenden Funktion), Spalten von
        ``study["results"]`` haben Vorrang.

    Hinweise (Python):
        Bedingungen als Zeichenketten in R-Syntax (Spaltennamen von
        ``study.results`` als Variablen, z. B. ``"cagr > 0 & max_drawdown <= 0.5"``;
        Vorrang, NA-Logik und Funktionen wie in R, siehe :mod:`simlev._r.rexpr`)
        oder Funktionen ``DataFrame -> bool-Array``. Unbenannte Bedingungen
        (``*args``) werden nach ihrem Text benannt, benannte über Schlüsselwörter
        (``joint="cagr > 0 & max_drawdown <= 0.5"``). Freie Variablen werden in
        ``env`` gesucht (Voreinstellung: Namensraum des Aufrufers).

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 1095
        d = pd.DataFrame({"date": pd.date_range("2015-01-01", periods=n)})
        d["aktien"] = 100 * np.cumprod(1 + rng.normal(3e-4, 0.01, n))
        cfg = simlev.bootstrap_config({"akt": "aktien"}, input="prices",
                                      letfs=[{"base": "akt", "leverage": 2, "finance": 2}])
        st = simlev.bootstrap_study(d, cfg, "stationary", 5, params={"L": 30}, path_length=500, seed=1, progress=False,
                                    strategies={"etf": simlev.create_strategy(akt=simlev.asset_config(asset_class="etf")),
                                                "letf": simlev.create_strategy(akt_l2=simlev.asset_config(asset_class="etf"))})
        print(simlev.bootstrap_probability(st, "cagr > 0", joint="cagr > 0.05 & max_drawdown <= 0.3"))
    """
    if not _is_study(study):
        _stop("study muss ein SimLevBootstrapStudy-Objekt sein.")
    with np.errstate(all="ignore"):
        return _bootstrap_probability(study, args, kwargs, thresholds, env)


def _bootstrap_probability(study, args, kwargs, thresholds, env):
    conds = []
    for c in args:
        conds.append((c if isinstance(c, str) else getattr(c, "__name__", str(c)), c))
    for k, c in kwargs.items():
        conds.append((k, c))
    tab = study["results"]
    out = []
    for s in _uniq(list(tab["strategy"])):
        d = tab[tab["strategy"] == s].reset_index(drop=True)
        th = None if thresholds is None else thresholds.get(s)
        cl = list(th.items()) if th is not None else conds
        for cn, ce in cl:
            v = _eval_condition(ce, d, env)
            w = d["weight"].to_numpy(dtype=np.float64)
            if len(v) != len(w):
                # andere Länge als nrow(d): R's Recycling in w[ok] * v[ok]
                from ._r import rexpr as _rexpr
                r = _rexpr.eval_r("ok <- !is.na(v); sw <- sum(w[ok]); c(sum(w[ok] * v[ok]) / sw, sw^2 / sum(w[ok]^2), sum(ok))",
                                  {"v": v, "w": w}, env={})
                p, neff = float(r[0]), float(r[1])
                out.append({"strategy": s, "condition": cn, "probability": p,
                            "se": _sqrt(_div(p * (1 - p), neff)), "n": int(r[2])})
                continue
            ok = np.array([z is not None for z in v], dtype=bool)
            vv = np.array([1.0 if z else 0.0 for z in v])
            p = _div(r_sum(w[ok] * vv[ok]), r_sum(w[ok]))
            swk = r_sum(w[ok])
            neff = _div(swk * swk, r_sum(w[ok] * w[ok]))
            out.append({"strategy": s, "condition": cn, "probability": p,
                        "se": _sqrt(_div(p * (1 - p), neff)),
                        "n": int(ok.sum())})
    return pd.DataFrame(out, columns=["strategy", "condition", "probability", "se", "n"])


@_quiet
def _summary_study(obj, metrics=("cagr", "ttwror", "max_drawdown", "sharpe", "ulcer_index", "final_value"),
                   probs=(0.05, 0.25, 0.5, 0.75, 0.95)):
    tab = obj["results"]
    metrics = [m for m in _uniq(list(metrics)) if m in tab.columns]
    probs = np.atleast_1d(np.asarray(probs, dtype=np.float64))
    qn = [_sp("q%02d", _r_round0(100 * p)) for p in probs]
    rows = []
    for s in obj["strategies"]:
        d = tab[tab["strategy"] == s]
        for m in metrics:
            q = _wquantile(d[m].to_numpy(), d["weight"].to_numpy(), probs)
            row = {"strategy": s, "metric": m,
                   "mean": _weighted_mean(d[m].to_numpy(dtype=np.float64), d["weight"].to_numpy(), na_rm=True)}
            for k, v in zip(qn, q):
                row[k] = v
            rows.append(row)
    dist = pd.DataFrame(rows, columns=["strategy", "metric", "mean"] + qn) if rows else None
    paired = None
    if obj.get("benchmark") is not None:
        bm = obj["benchmark"]
        b = tab[tab["strategy"] == bm]
        prow = []
        for s in [x for x in obj["strategies"] if x != bm]:
            d = tab[tab["strategy"] == s]
            mm = d.merge(b, on="path", suffixes=("", ".bench"), sort=True)
            for m in metrics:
                dif = mm[m].to_numpy(dtype=np.float64) - mm[m + ".bench"].to_numpy(dtype=np.float64)
                better = dif < 0 if m in _LOWER_BETTER else dif > 0
                w = mm["weight"].to_numpy(dtype=np.float64)
                ok = np.isfinite(dif)
                p = _div(r_sum(w[ok] * better[ok]), r_sum(w[ok]))
                q = _wquantile(dif, w, [0.05, 0.5, 0.95])
                swk = r_sum(w[ok])
                prow.append({"strategy": s, "metric": m, "p_better": p,
                             "se": _sqrt(_div(p * (1 - p), _div(swk * swk, r_sum(w[ok] * w[ok])))),
                             "diff_q05": q[0], "diff_median": q[1], "diff_q95": q[2]})
        paired = pd.DataFrame(prow, columns=["strategy", "metric", "p_better", "se", "diff_q05", "diff_median",
                                             "diff_q95"]) if prow else None
    return SummarySimLevBootstrapStudy([
        ("distribution", dist), ("paired", paired), ("n_paths", obj["n_paths"]), ("method", obj["method"]),
        ("benchmark", obj.get("benchmark")), ("path_length", obj["path_length"])])


_LINE = "═" * 62


def _cat_summary_study(x) -> str:
    def fv(v, m):
        if m in ("cagr", "ttwror", "max_drawdown", "avg_drawdown", "dd_q50", "dd_q90", "p_better"):
            return _sp("%8.2f%%", 100 * v)
        if m in ("final_value", "taxes"):
            return _sp("%10.0f", v)
        return _sp("%9.3f", v)

    out = ["\n%s\n" % _LINE, "                 SimLev Bootstrap-Studie                       \n", "%s\n" % _LINE]
    out.append("  Verfahren: %s | Pfade: %d | Pfadlänge: %d Tage\n" % (x["method"], int(x["n_paths"]),
                                                                      int(x["path_length"])))
    d = x["distribution"]
    if d is not None:
        qc = [c for c in d.columns if len(c) > 1 and c[0] == "q" and c[1].isdigit()]
        for m in _uniq(list(d["metric"])):
            dm = d[d["metric"] == m]
            lab = "cagr (mit Sparplan geldgewichtet, XIRR)" if m == "cagr" else m
            out.append(_sp("\n  %s\n  %-14s %10s %s\n", lab, "Strategie", "Mittel",
                           "".join(_sp("%10s", q) for q in qc)))
            for i in range(len(dm)):
                out.append(_sp("  %-14s %10s %s\n", dm["strategy"].iloc[i], fv(float(dm["mean"].iloc[i]), m),
                               "".join(_sp("%10s", fv(float(dm[q].iloc[i]), m)) for q in qc)))
    if x.get("paired") is not None:
        out.append("\n  Gepaarter Vergleich gegen '%s' (gleiche Pfade)\n" % x["benchmark"])
        out.append(_sp("  %-14s %-14s %10s %8s %11s %11s %11s\n", "Strategie", "Kennzahl", "P(besser)", "SE",
                       "Diff q05", "Diff Median", "Diff q95"))
        p = x["paired"]
        for i in range(len(p)):
            m = p["metric"].iloc[i]
            out.append(_sp("  %-14s %-14s %9.1f%% %7.1f%% %11s %11s %11s\n", p["strategy"].iloc[i], m,
                           100 * float(p["p_better"].iloc[i]), 100 * float(p["se"].iloc[i]),
                           fv(float(p["diff_q05"].iloc[i]), m), fv(float(p["diff_median"].iloc[i]), m),
                           fv(float(p["diff_q95"].iloc[i]), m)))
    out.append("%s\n" % _LINE)
    return "".join(out)


_DARK3 = ["#E16A86", "#50A315", "#009ADE", "#B88A00", "#00AD9A", "#C86DD7"]


def _plot_study(x, metric="cagr", width=640, height=420):
    """Ungewichtete Dichten einer Kennzahl je Strategie als SVG (R: ``plot.SimLevBootstrapStudy``).

    Args:
        metric: Spalte von ``results`` (z. B. ``"cagr"``).
        width, height: Größe in Pixeln.
        file: Dateiname auf ``.svg`` (sonst wird nichts geschrieben).

    Returns:
        :class:`simlev.SimLevPlot`; ``data``: ``density`` (``strategy``, ``x``, ``density``: die gezeichneten
        Punkte der Kerndichte ``.sl_kde`` je Strategie im Wertebereich der Kennzahl).
    """
    from .svg import _jl_fmt, _jl_max, _jl_maximum, _jl_minimum, _jl_str as J
    tab = x["results"]
    strats = [str(v) for v in x["strategies"]]
    mv = tab[metric].to_numpy(dtype=np.float64)
    sv = tab["strategy"].to_numpy()
    dl = [mv[sv == st] for st in strats]
    allv = np.concatenate(dl) if dl else np.array([], dtype=np.float64)
    allv = allv[np.isfinite(allv)]
    dens = []
    for v in dl:
        v = v[np.isfinite(v)]
        dd = _sl.kde(v)   # Gauß-Kerndichte wie .sl_kde in R (slc; nur Grafik)
        dens.append((np.asarray(_get(dd, "x"), dtype=np.float64), np.asarray(_get(dd, "y"), dtype=np.float64)))
    x0, x1 = (0.0, 1.0) if allv.size == 0 else (_jl_minimum(allv), _jl_maximum(allv))
    if x1 == x0:
        x1 = x0 + 1
    y1 = 1e-12
    for d in dens:
        y1 = _jl_max(y1, 0.0 if d[1].size == 0 else _jl_maximum(d[1]))
    ml, mr, mt, mb = 60, 20, 40, 50
    pw, ph = width - ml - mr, height - mt - mb

    def sx(v):
        return ml + (v - x0) / (x1 - x0) * pw

    def sy(v):
        return mt + ph - v / y1 * ph

    out = ["<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%s\" height=\"%s\" viewBox=\"0 0 %s %s\" "
           "font-family=\"sans-serif\" font-size=\"12\">\n" % (J(width), J(height), J(width), J(height)),
           "<rect width=\"100%\" height=\"100%\" fill=\"white\"/>\n",
           "<text x=\"%s\" y=\"22\" text-anchor=\"middle\" font-size=\"14\" font-weight=\"bold\">%s</text>\n"
           % (J(width / 2), "Verteilung %s (%s, %d Pfade)" % (metric, x["method"], int(x["n_paths"]))),
           "<rect x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\" fill=\"none\" stroke=\"black\"/>\n"
           % (J(ml), J(mt), J(pw), J(ph)),
           "<text x=\"%s\" y=\"%s\" text-anchor=\"middle\">%s</text>\n" % (J(ml + pw / 2), J(height - 12), metric),
           "<text x=\"16\" y=\"%s\" text-anchor=\"middle\" transform=\"rotate(-90 16 %s)\">Dichte</text>\n"
           % (J(mt + ph / 2), J(mt + ph / 2))]
    rs, rx, ry = [], [], []
    for i, (gx, gy) in enumerate(dens, start=1):
        col = _DARK3[(i - 1) % len(_DARK3)]
        keep = [(a, b) for a, b in zip(gx.tolist(), gy.tolist()) if x0 <= a <= x1]
        pts = " ".join(_jl_fmt("%.2f", sx(a)) + "," + _jl_fmt("%.2f", sy(b)) for a, b in keep)
        out.append("<polyline fill=\"none\" stroke=\"%s\" stroke-width=\"1.5\" points=\"%s\"/>\n" % (col, pts))
        out.append("<line x1=\"%s\" y1=\"%s\" x2=\"%s\" y2=\"%s\" stroke=\"%s\" stroke-width=\"1.5\"/><text x=\"%s\" "
                   "y=\"%s\">%s</text>\n" % (J(width - mr - 120), J(mt + 16 * i), J(width - mr - 100), J(mt + 16 * i), col,
                                            J(width - mr - 95), J(mt + 16 * i + 4), strats[i - 1]))
        rs += [strats[i - 1]] * len(keep)
        rx += [a for a, _ in keep]
        ry += [b for _, b in keep]
    out.append("</svg>\n")
    data = {"density": pd.DataFrame({"strategy": np.array(rs, dtype=object), "x": np.array(rx, dtype=np.float64),
                                     "density": np.array(ry, dtype=np.float64)})}
    return "".join(out), data


def summary(object, *args, **kwargs):  # noqa: A002
    """``summary()`` für Bootstrap-Studien und Entnahme-Ergebnisse."""
    if hasattr(object, "summary"):
        return object.summary(*args, **kwargs)
    raise TypeError("keine summary-Methode für %s" % type(object).__name__)


def plot(x, *args, **kwargs):
    """``plot()`` für Bootstrap-Studien und Entnahme-Ergebnisse: ruft die Methode ``x.plot()`` auf.

    Ergebnis ist ein :class:`simlev.SimLevPlot` (SVG in ``svg``, dargestellte Werte in ``data``);
    geschrieben wird nur mit ``file="….svg"``."""
    if hasattr(x, "plot"):
        return x.plot(*args, **kwargs)
    raise TypeError("keine plot-Methode für %s" % type(x).__name__)


from .svg import _plot_method  # noqa: E402

SimLevBootstrapStudy.plot = _plot_method(_plot_study, "SimLevBootstrapStudy")

# Rechnen mit NA (signalisierendes NaN) ohne numpy-Warnung "invalid value" wie in R (gemeinsamer Helfer)
from ._r.base import quiet_fp  # noqa: E402

quiet_fp(globals(), list(__all__) + ["_calculate_ess", "_ess_design", "_extract_returns", "_fit_garch11", "_fit_tail", "_get_base_params", "_get_ess_grid", "_prepare_regime_info", "_pw_block", "_wquantile"])  # bootstrap_probability: env aus dem Aufrufer (env_from_caller)


from . import _callable_module  # noqa: E402 (aufrufbar wie die gleichnamige Funktion, PEP 562)
_callable_module("bootstrap")
