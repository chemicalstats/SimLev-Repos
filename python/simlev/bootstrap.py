"""Bootstrap-Pfade für Indizes, Hebelprodukte und Signale (Port von ``r/R/bootstrap.R``).

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
ausschließlich über :mod:`simlev._r.rng` (L'Ecuyer-Ströme je Pfad wie R).
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
from collections.abc import Mapping

import numpy as np
import pandas as pd

from . import _bootstrap_core as _core
from ._r import fmt as _fmt
from ._r.base import env_from_caller
from ._r import libm as _libm
from ._r import parallel as _par
from ._r import rng as _rng
from ._r.rlist import RList
from ._r.rnum import r_cumprod, r_mean, r_median, r_pow, r_sd, r_sum, r_var

__all__ = [
    "bootstrap_config", "BootstrapConfig", "bootstrap_block_length", "bootstrap",
    "BootstrapResult", "bootstrap_validate", "bootstrap_data", "bootstrap_study_metrics", "bootstrap_study",
    "SimLevBootstrapStudy", "SummarySimLevBootstrapStudy", "bootstrap_probability", "summary",
    "plot",
]

_NAN = _fmt.NA_REAL      # R's NA_real_ (alle Verwendungen hier sind NA; NaN: math.nan)
LD = np.longdouble


class _Missing:
    def __repr__(self):
        return "<missing>"


_MISSING = _Missing()


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


def _message(text) -> None:
    """R-``message()`` (stderr)."""
    sys.stderr.write(str(text) + "\n")
    sys.stderr.flush()


def _warn(text) -> None:
    warnings.warn(str(text), UserWarning, stacklevel=3)


def _stop(text):
    raise ValueError(str(text))


def _match_arg(arg, choices):
    from .data_prep import _match_arg as _ma
    return _ma(arg, choices)


def _stats():
    from ._r import stats as _st
    return _st


def _sp(fmt, *args) -> str:
    """R-``sprintf`` (Skalar)."""
    return _fmt.sprintf(fmt, *args)


def _fmt1(x, **kw) -> str:
    """R-``format(x)`` einer Zahl/Zeichenkette als Text."""
    r = _fmt.format(x, **kw)
    if isinstance(r, str):
        return r
    return ", ".join(str(s) for s in np.asarray(r, dtype=object).ravel())


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


def _is_num(x) -> bool:
    return isinstance(x, (int, float, np.integer, np.floating)) and not isinstance(x, (bool, np.bool_))


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


def _to_date(x, what="date"):
    from .data_prep import _to_date as _td
    return _td(x, what)


# ═══════════════════════════════════════════════════════════════════════════
# RNG-Hilfen (.with_rng_restore, .make_streams; .par_lapply in _r.parallel)
# ═══════════════════════════════════════════════════════════════════════════

def _with_rng_restore(fn, seed=_MISSING):
    """Zufallszustand sichern und wiederherstellen (Port von ``.with_rng_restore``).

    Ohne ``seed`` wird der Zustand vor dem Aufruf immer wiederhergestellt; mit
    einer Zahl wird ``set_seed(seed)`` gesetzt und danach der vorherige Zustand
    wiederhergestellt; ``seed=None``: nichts setzen, nichts wiederherstellen.
    Ruft ``fn()`` auf und gibt dessen Ergebnis zurück.
    """
    if seed is not _MISSING and seed is None:
        return fn()
    has = _rng.has_random_seed()
    old = _rng.get_random_seed() if has else None
    kind = _rng.rng_kind()
    try:
        if seed is not _MISSING:
            _rng.set_seed(seed)
        return fn()
    finally:
        if has:
            _rng.set_random_seed(old)
        else:
            _rng.rng_kind(kind[0], kind[1], kind[2])
            if _rng.has_random_seed():
                _rng.rm_random_seed()


def _make_streams(seed, n):
    """Zufallsströme je Pfad (L'Ecuyer-CMRG), Port von ``.make_streams``."""
    has = _rng.has_random_seed()
    old = _rng.get_random_seed() if has else None
    old_kind = None if has else _rng.rng_kind()
    try:
        _rng.rng_kind("L'Ecuyer-CMRG")
        _rng.set_seed(seed)
        s = _rng.get_random_seed()
        out = []
        for _ in range(int(n)):
            out.append(s)
            s = _rng.next_rng_stream(s)
        return out
    finally:
        if has:
            _rng.set_random_seed(old)
        else:
            _rng.rng_kind(old_kind[0], old_kind[1], old_kind[2])
            if _rng.has_random_seed():
                _rng.rm_random_seed()


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

    Args:
        indices: Benannter Vektor (``dict``/``Series``) Pfadname -> Spaltenname.
        letfs: Liste von Hebelprodukten (je ein ``dict`` mit ``base`` und
            optional ``leverage``, ``finance``, ``expense``, ``spread``,
            ``days``, ``rate_basis``, ``ter_basis``, ``name``).
        regime_index: Pfadname des Referenzindex (``None`` = erster Index).
        aux: Optional benannter Vektor Zusatzreihen Pfadname -> Spaltenname.
        aux_type: Optional benannter Vektor Art je Zusatzreihe ("level"/"rate").
        cross: "ratio" (Standard) oder "joint".
        input: "returns" (Standard) oder "prices".

    Returns:
        :class:`BootstrapConfig`.
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

    letf_list = []
    for i, lt in enumerate(list(letfs or []), start=1):
        lt = dict(lt) if isinstance(lt, Mapping) else {}
        base = lt.get("base")
        if base is None:
            _stop("LETF %d: 'base' muss angegeben werden" % i)
        if base not in index_names:
            _stop("LETF %d: base '%s' nicht in indices. Verfügbar: %s" % (i, base, ", ".join(index_names)))
        lev = lt.get("leverage")
        lev = 2 if lev is None else lev
        if lev == 0:
            _stop("LETF %d: leverage darf nicht 0 sein" % i)
        fin = lt.get("finance")
        fin = 3.5 if fin is None else fin
        if isinstance(fin, str) and fin not in aux_names:
            _stop("LETF %d: finance-Reihe '%s' nicht in aux." % (i, fin))
        if is_level(fin):
            _stop("LETF %d: finance-Reihe '%s' ist in aux_type als 'level' gekennzeichnet; der Finanzierungszins "
                  "muss eine Rate (Prozent p. a.) sein." % (i, fin))
        if _is_num(fin) and fin < 0:
            _warn("LETF %d: negativer Finanzierungszins." % i)
        exp_ = lt.get("expense")
        exp_ = 0.5 if exp_ is None else exp_
        if exp_ < 0:
            _stop("LETF %d: expense muss >= 0 sein" % i)
        days = lt.get("days")
        days = 1 if days is None else days
        if isinstance(days, str) and days not in aux_names:
            _stop("LETF %d: days-Reihe '%s' nicht in aux." % (i, days))
        if is_level(days):
            _stop("LETF %d: days-Reihe '%s' ist in aux_type als 'level' gekennzeichnet; Tage je Zeile werden "
                  "unverändert gebraucht ('rate')." % (i, days))
        name = lt.get("name")
        if name is None:
            name = (base + "_l" + _as_char(lev)) if lev > 0 else (base + "_inv" + _as_char(abs(lev)))
        sp = lt.get("spread")
        rb = lt.get("rate_basis")
        tb = lt.get("ter_basis")
        letf_list.append({"name": name, "base": base, "leverage": lev, "finance": fin, "expense": exp_,
                          "spread": 0 if sp is None else sp, "days": days,
                          "rate_basis": 360 if rb is None else rb, "ter_basis": 365 if tb is None else tb})
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
    """Renditematrix und Zusatzreihen extrahieren (Port von ``.extract_returns``).

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


def _get_base_params(method, params, n):
    """Standardparameter je Verfahren (Port von ``.get_base_params``)."""
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
    """Standard-ESS-Gitter je Verfahren (Port von ``.get_ess_grid``)."""
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
    """Effektive Stichprobengröße je Konfiguration (Port von ``.calculate_ess``)."""
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
    """Optimale Blocklänge nach Politis & White (2004), Port von ``.pw_block``.

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

    Args:
        x: Numerischer Vektor oder Matrix/``DataFrame`` (Spalten = Reihen).
        transform: "none" (Standard), "abs" (``|x - mean|``) oder "squared".

    Returns:
        ``DataFrame`` mit Spalten ``stationary`` und ``circular``, eine Zeile je Reihe.
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


def _resolve_auto(params, returns, config, method):
    """"auto"-Parameter auflösen (Port von ``.resolve_auto``)."""
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

def _xp(v) -> float:
    return _libm._exp(float(v))


@_quiet
def _fit_garch11(e, gjr=False, quiet=False):
    """GARCH(1,1) / GJR-GARCH(1,1) schätzen (rugarch -> optim -> Momente), Port von ``.fit_garch11``.

    Schätzt wie R (das rugarch übernommen hat, ``.rugarch_ugarchfit``) zuerst
    mit der Nachbildung von ``rugarch::ugarchfit`` (:mod:`simlev._r.rugarch`,
    Solver ``"hybrid"``); scheitert sie mit einem R-Fehler, folgen wie in R
    der optim-Pfad (Nelder-Mead) und die Momente. Warnungen von rugarch
    erscheinen wie in R auch bei ``quiet = True``. Erreicht rugarch den
    Solver gosolnp, setzt dieser wie in R den globalen Zufallszustand neu
    (Startwert aus der Uhrzeit).
    """
    e = np.asarray(e, dtype=np.float64).ravel()
    n = len(e)
    mu = r_mean(e)
    if r_var(e) < 1e-16:
        return {"mu": mu, "omega": 1e-20, "alpha": 0.0, "beta": 0.0, "gamma": 0.0, "s2": np.full(n, 1e-20),
                "z": np.zeros(n), "method": "konstant", "s2_init": 1e-20}
    omega = alpha = beta = None
    gamma = 0.0
    method = "none"
    from ._r import rugarch as _rugarch
    try:
        fit = _rugarch.ugarchfit(e, model="gjrGARCH" if gjr else "sGARCH", solver="hybrid")
        cf = _rugarch.coef(fit)
        ok = cf is not None
    except (ImportError, NotImplementedError):
        raise
    except Exception:  # noqa: BLE001 - tryCatch(..., error = function(err) NULL)
        ok = None
    if ok is False:
        # coef(fit) ist NULL (keine Konvergenz): in R werden mu, omega, ... NULL, der
        # optim-Weg filtert eine leere Reihe und `if (stats::sd(z) > 0)` bricht ab (in R
        # mit erzwungener Nicht-Konvergenz geprüft)
        from ._r.linalg import RError as _RError
        raise _RError("missing value where TRUE/FALSE needed")
    if ok:
        mu = float(cf["mu"])
        omega = float(cf["omega"])
        alpha = float(cf["alpha1"])
        beta = float(cf["beta1"])
        if gjr:
            gamma = float(cf["gamma1"])
        method = "rugarch"

    def filt(om, al, be, ga, m):
        return _core.garch_filter(e - m, om, al, be, ga, om / max(1e-6, 1 - al - be - ga / 2))

    if omega is None:
        try:
            sv = r_var(e)
            ep = e - mu
            ep2 = ep * ep

            def nll(th):
                th = np.asarray(th, dtype=np.float64)
                om = _xp(th[0])
                al = 0.5 / (1 + _xp(-th[1]))
                be = 0.999 / (1 + _xp(-th[2]))
                ga = 0.5 / (1 + _xp(-th[3])) if gjr else 0.0
                if al + be + ga / 2 >= 0.9999:
                    return 1e10
                s2 = filt(om, al, be, ga, mu)
                return 0.5 * r_sum(np.asarray(_libm.log(s2), dtype=np.float64) + ep2 / s2)

            def lg(p):
                return math.log(p / (1 - p))

            st = [math.log(sv * 0.05), lg(0.05 / 0.5), lg(0.90 / 0.999)] + ([lg(0.04 / 0.5)] if gjr else [])
            if gjr:
                st[1] = lg(0.02 / 0.5)
            st_mod = _stats()
            if not hasattr(st_mod, "optim"):
                raise NotImplementedError("simlev._r.stats.optim fehlt (Nelder-Mead f\u00fcr .fit_garch11)")
            o = st_mod.optim(np.array(st, dtype=np.float64), nll, method="Nelder-Mead", control={"maxit": 4000})
            par = np.asarray(_get(o, "par"), dtype=np.float64)
            val = float(_get(o, "value"))
            om = _xp(par[0])
            al = 0.5 / (1 + _xp(-par[1]))
            be = 0.999 / (1 + _xp(-par[2]))
            ga = 0.5 / (1 + _xp(-par[3])) if gjr else 0.0
            if val < 1e9 and al + be + ga / 2 < 0.9999:
                omega, alpha, beta, gamma, method = om, al, be, ga, "optim"
        except (ImportError, ModuleNotFoundError, NotImplementedError):
            raise
        except Exception:  # noqa: BLE001 - tryCatch(..., error = function(err) NULL)
            pass
    if omega is None:
        sv = r_var(e)
        alpha, beta = 0.08, 0.88
        gamma = 0.04 if gjr else 0.0
        omega = sv * (1 - alpha - beta - gamma / 2)
        method = "momente"
        if not quiet:
            _warn("GARCH: rugarch und optim fehlgeschlagen, verwende Moment-Schätzer")
    s2 = filt(omega, alpha, beta, gamma, mu)
    with np.errstate(divide="ignore", invalid="ignore"):
        z = (e - mu) / np.sqrt(s2)
    z[~np.isfinite(z)] = 0.0
    sdz = r_sd(z)
    if sdz > 0:
        z = (z - r_mean(z)) / r_sd(z)
    pers = alpha + beta + gamma / 2
    return {"mu": mu, "omega": omega, "alpha": alpha, "beta": beta, "gamma": gamma, "s2": s2, "z": z,
            "method": method, "persistence": pers,
            "s2_init": omega / (1 - pers) if pers < 0.9999 else r_var(e)}


@_quiet
def _fit_cross(returns, config, base):
    """Nicht-Referenzreihen als GARCH(1,1) modellieren (Port von ``.fit_cross``); ``base`` 1-basiert."""
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
    """Tail-Schätzung (GPD via evd -> Momente -> empirisch -> Default), Port von ``.fit_tail``.

    Den GPD-Fit (``.evd_fpot(exc, threshold = 0, std.err = FALSE)``, aus evd
    2.3-7.1 ins R-Paket übernommen, nachgebildet in ``simlev._r.evd``) nimmt R
    bei mindestens 30 Überschreitungen; Fehler darin führen wie das
    ``tryCatch`` in R zum Momenten-Schätzer.
    """
    from ._r import evd as _evd
    base_ret = np.asarray(base_ret, dtype=np.float64)
    thr = float(_quantile7(base_ret, prob if side == "left" else 1 - prob)[0])
    mask = base_ret < thr if side == "left" else base_ret > thr
    exc = thr - base_ret[mask] if side == "left" else base_ret[mask] - thr
    ne = len(exc)
    scale = shape = None
    method = "none"
    if ne >= 30:
        try:
            f = _evd.fpot(exc, threshold=0, std_err=False)
            scale = float(f["estimate"]["scale"])
            shape = float(f["estimate"]["shape"])
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
    """``seq(0, 1, length.out = n_out)``."""
    n_out = int(n_out)
    if n_out > 2:
        n1 = n_out - 1.0
        return np.concatenate([[0.0], 0.0 + np.arange(1, n_out - 1, dtype=np.float64) * (1.0 / n1), [1.0]])
    return np.array([0.0, 1.0])[:n_out]


@_quiet
def _prepare_regime_info(base_ret, vol_window, n_regimes):
    """Regime aus rollierender Volatilität (Port von ``.prepare_regime_info``)."""
    vol = _core.rolling_vol(base_ret, int(vol_window))
    th = _quantile7(vol, _seq_len_out(float(n_regimes) + 1))
    th[-1] = th[-1] + 1e-10
    reg = _core.assign_regimes(vol, th)
    return {"regimes": reg, "trans": _core.estimate_trans_mat(reg, int(n_regimes)), "vol": vol}


@_quiet
def _prepare_ms_info(returns, config, base, K, garch_model, ar_gm, tvtp):
    """MS-GARCH-Familie vorbereiten (Port von ``.prepare_ms_info``; eigene ML-Schätzung
    :func:`simlev.ms_garch._ms_garch_fit`); ``base`` 1-basiert."""
    from . import ms_garch as _msg
    _msg._ms_garch_check(K, garch_model)
    st = _stats()
    ex = returns[:, base - 1] - 1
    n = len(ex)
    try:
        fit = _msg._ms_garch_fit(ex, K, garch_model)
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
                b = float(np.asarray(st.lm_fit(np.column_stack([np.ones(len(i)), lag_ex[i]]), ex[i])["coefficients"],
                                     dtype=np.float64)[1])
            except Exception:  # noqa: BLE001 - tryCatch(..., error = function(e) NA)
                b = _NAN
            if math.isfinite(b):
                phi[r] = max(-0.5, min(0.5, b))
            try:
                lv = float(np.asarray(st.lm_fit(sig[i].reshape(-1, 1), ex[i] - mu[r] - phi[r] * lag_ex[i])["coefficients"],
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
                        g = st.glm("y ~ x", family=st.binomial(), env={"y": (to == j + 1).astype(np.int64), "x": x})
                        d = float(st.coef(g)["x"])
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


def _prepare_method_info(returns, config, method, params):
    """Verfahrensspezifische Vorberechnung (Port von ``.prepare_method_info``)."""
    p = _get_base_params(method, params, returns.shape[0])
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
        info["ms"] = _prepare_ms_info(returns, config, base, p["ms_n_regimes"], p["ms_garch_model"], False, False)
    if method == "ms_ar_garch_m":
        info["ms"] = _prepare_ms_info(returns, config, base, p["ms_ar_n_regimes"], p["ms_ar_garch_model"], True, False)
    if method == "tvtp_ms_garch":
        info["ms"] = _prepare_ms_info(returns, config, base, p["tvtp_n_regimes"], p["tvtp_garch_model"], True, True)
    return info


# ═══════════════════════════════════════════════════════════════════════════
# Pfaderzeugung
# ═══════════════════════════════════════════════════════════════════════════

def _as_int(x) -> int:
    """``as.integer`` (Abschneiden)."""
    return int(float(x)) if not isinstance(x, (int, np.integer)) else int(x)


@_quiet
def _generate_returns(returns, method, p, info, n_out):
    """Eine Renditematrix samt Quellzeilen erzeugen (Port von ``.generate_returns``)."""
    n, k = returns.shape

    def from_idx(idx):
        idx = np.asarray(idx, dtype=np.int64)
        return {"ret": returns[idx - 1, :], "idx": idx}

    if method == "raw":
        g = from_idx(_core.boot_idx_iid(n, n_out))
    elif method == "block":
        g = from_idx(_core.boot_idx_block(n, n_out, _as_int(p["block_length"]), False))
    elif method == "circular":
        g = from_idx(_core.boot_idx_block(n, n_out, _as_int(p["block_length"]), True))
    elif method == "stationary":
        g = from_idx(_core.boot_idx_stationary(n, n_out, float(p["L"])))
    elif method == "regime":
        g = from_idx(_core.boot_idx_regime(info["regimes"], info["trans"], n_out))
    elif method == "tails":
        g = from_idx(_core.boot_idx_tails(n_out, info["p"], info["p"], info["bulk"], info["left"], info["right"]))
    elif method == "wild":
        g = {"ret": _core.boot_wild(returns, _as_int(p["wild_type"])), "idx": np.arange(1, n + 1)}
    elif method == "reset":
        g = {"ret": _core.boot_reset(returns, p["p_break"]), "idx": np.arange(1, n + 1)}
    elif method == "evt":
        lt, rt = info["left"], info["right"]
        g = _core.boot_evt(returns, info["base"] - 1, n_out, lt["prob"], lt["thresh"], lt["scale"], lt["shape"],
                           lt["pool"], 0 if rt is None else rt["prob"], math.inf if rt is None else rt["thresh"],
                           0 if rt is None else rt["scale"], 0 if rt is None else rt["shape"],
                           np.zeros(0, dtype=np.int64) if rt is None else rt["pool"], info["bulk"])
    elif method in ("garch", "gjr_garch"):
        f, cr = info["garch"], info["cross"]
        g = _core.boot_garch(n_out, info["base"] - 1, k, f["mu"], f["omega"], f["alpha"], f["beta"], f["gamma"],
                             f["s2_init"], f["z"], np.arange(1, n + 1), cr["cols"], cr["mu"], cr["om"], cr["al"],
                             cr["be"], cr["ratio"], cr["s2"], cr["z"])
    elif method in ("ms_garch", "ms_ar_garch_m", "tvtp_ms_garch"):
        m = info["ms"]
        cr = m["cross"]
        g = _core.boot_ms_garch(n_out, info["base"] - 1, k, int(m["K"]), m["mu"], m["omega"], m["alpha"], m["beta"],
                                m["gamma"], m["phi"], m["lambda"], m["trans"], m["delta"], m["unc"], m["stat"],
                                m["pools"], m["z"], cr["cols"], cr["mu"], cr["om"], cr["al"], cr["be"], cr["ratio"],
                                cr["s2"], cr["z"])
    else:
        _stop("Unbekannte Methode: %s" % method)
    return g


@_quiet
def _letf_returns(rb, letf, aux_rows, aux_names):
    """Hebelprodukt-Renditen (MSCI-Formel plus Fondskosten), Port von ``.letf_returns``."""
    L = float(letf["leverage"])
    fin = letf["finance"]
    rate = aux_rows[:, aux_names.index(fin)] if isinstance(fin, str) else float(fin)
    dd = letf["days"]
    d = aux_rows[:, aux_names.index(dd)] if isinstance(dd, str) else float(dd)
    m = max(L - 1, 0.0) + max(-L, 0.0)
    rbas = float(letf["rate_basis"])
    tbas = float(letf["ter_basis"])
    t1 = 1 + L * (rb - 1)
    t2 = (1 - L) * rate / 100 * d / rbas
    t3 = float(letf["expense"]) / 100 * d / tbas
    t4 = float(letf["spread"]) / 100 * m * d / rbas
    return t1 + t2 - t3 - t4


def _cumprod_cols(M):
    """``apply(M, 2, cumprod)`` (long double)."""
    out = np.empty_like(M, dtype=np.float64)
    for j in range(M.shape[1]):
        out[:, j] = r_cumprod(M[:, j])
    return out


@_quiet
def _build_path(g, aux, config, start=100, aux_ratio=None, aux_start=None):
    """Preis-Pfad aus Renditen bauen (Port von ``.build_path``); ``DataFrame`` oder ``None``."""
    ret = g["ret"]
    idx = np.asarray(g["idx"], dtype=np.int64)
    if not isinstance(ret, np.ndarray) or ret.ndim != 2 or (~np.isfinite(ret)).any() or (ret <= 0).any():
        return None
    n_out = ret.shape[0]
    ones = np.ones((1, ret.shape[1]))
    P = start * _cumprod_cols(np.vstack([ones, ret]))
    cols = list(config["index_names"])
    blocks = [P]
    anames = list(config["aux_names"])
    aux_rows = aux[idx - 1, :] if aux is not None else None
    if config["n_letfs"]:
        Ls = []
        for lt in config["letfs"]:
            r = _letf_returns(ret[:, config["index_names"].index(lt["base"])], lt, aux_rows, anames)
            r = np.broadcast_to(np.asarray(r, dtype=np.float64), (n_out,)).copy()
            if (~np.isfinite(r)).any():
                return None
            ko = np.flatnonzero(r <= 0)
            if len(ko):
                r[ko[0]:] = 0.0
            Ls.append(start * r_cumprod(np.concatenate([[1.0], np.maximum(r, 0.0)])))
        blocks.append(np.column_stack(Ls))
        cols += list(config["letf_names"])
    lv = None
    if aux is not None:
        A = aux[np.concatenate([[idx[0]], idx]) - 1, :]
        blocks.append(A)
        cols += anames
    M = np.column_stack(blocks)
    if aux is not None and aux_ratio is not None:
        lvm = _cumprod_cols(np.vstack([np.ones((1, aux.shape[1])), aux_ratio[idx - 1, :]]))
        s0 = aux_start if aux_start is not None else aux[0, :] / aux_ratio[0, :]
        lvm = lvm * np.asarray(s0, dtype=np.float64)[None, :]
        at = _get(config, "aux_type")
        off = len(cols) - len(anames)
        for j, a in enumerate(anames):
            if _aux_type_of(at, a) == "level":
                M[:, off + j] = lvm[:, j]
        lv = pd.DataFrame(lvm, columns=anames)
    out = pd.DataFrame(M, columns=cols)
    if lv is not None:
        out.attrs["aux_level"] = lv
    return out


@_quiet
def _ess_design(method, params, grid, budget, n_obs):
    """ESS-Design (Port von ``.ess_design``): ``DataFrame`` oder ``None``."""
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
    """Verfahrensparameter vor dem Ziehen prüfen (Port von ``.check_boot_params``)."""
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
def _boot_setup(data, config, method, n, params, ess, ess_grid, path_length):
    """Gemeinsame Vorbereitung für bootstrap() und bootstrap_study() (Port von ``.boot_setup``)."""
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
    params = _resolve_auto(params, ex["ret"], config, method)
    design = _ess_design(method, params, ess_grid, _as_int(n), n_obs) if ess else None
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
            infos.append(_prepare_method_info(ex["ret"], config, method, cp))
        except (ImportError, ModuleNotFoundError, NotImplementedError):
            raise
        except Exception as err:  # noqa: BLE001
            _stop("Vorberechnung fehlgeschlagen: %s" % err)
    base_p = [_get_base_params(method, cp, n_obs) for cp in combos]
    for bp in base_p:
        _check_boot_params(method, bp, n_obs)
    weights = np.ones(n_paths) if design is None else design["weight"].to_numpy()[combo_of_path - 1]
    weights = weights / r_sum(weights) * len(weights)
    return {"ex": ex, "n_obs": n_obs, "n_out": n_out, "design": design, "combos": combos, "base_p": base_p,
            "infos": infos, "combo_of_path": combo_of_path, "n_paths": n_paths, "weights": weights}


@_quiet
def _draw_path(setup, i, stream, config, method, max_tries):
    """Einen gültigen Pfad mit eigenem Zufallsstrom erzeugen (Port von ``.draw_path``); ``i`` 1-basiert."""
    _rng.set_random_seed(stream)
    c_id = int(setup["combo_of_path"][i - 1])
    err = "Pfad ungültig (Indexrendite <= 0 oder nicht endlich)"
    ex = setup["ex"]
    for tr in range(1, int(max_tries) + 1):
        try:
            g = _generate_returns(ex["ret"], method, setup["base_p"][c_id - 1], setup["infos"][c_id - 1],
                                  setup["n_out"])
        except (ImportError, ModuleNotFoundError):
            raise
        except Exception as e:  # noqa: BLE001
            err = str(e)
            g = None
        if g is not None:
            P = _build_path(g, ex["aux"], config, aux_ratio=ex["aux_ratio"], aux_start=ex["aux_start"])
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


def _new_seed():
    """``sample.int(.Machine$integer.max, 1L)``."""
    return int(np.asarray(_rng.sample_int(2147483647, 1)).ravel()[0])


@_quiet
def bootstrap(data, config, *, method="raw", n=1000, params=None, ess=False, ess_grid=None, path_length=None,
              max_tries=10, seed=None, cores=1, progress=True):
    """Bootstrap-Pfade erzeugen.

    Args:
        data: ``DataFrame`` mit den in ``config`` genannten Spalten.
        config: Objekt aus :func:`bootstrap_config`.
        method: Verfahren (Standard "raw").
        n: Anzahl Pfade (Standard 1000); bei ``ess=True`` das Gesamtbudget.
        params: dict der Verfahrensparameter (Standard: alle Standardwerte).
        ess: ESS-gewichtete Gittersuche über Hyperparameter.
        ess_grid: dict Wertevektoren je Hyperparameter (``None`` = Standardgitter).
        progress: Fortschrittsmeldung (stderr).
        path_length: Pfadlänge in Zeilen (``None`` = Länge der Historie).
        seed: Startwert (``None`` = aus dem globalen Zufallsstrom gezogen).
        cores: Anzahl Prozesse (Fork wie R; ohne Fork sequentiell, Ergebnis identisch).
        max_tries: Versuche je Pfad (Standard 10).

    Returns:
        :class:`BootstrapResult`.
    """
    t0 = time.time()
    setup = _boot_setup(data, config, method, n, params, ess, ess_grid, path_length)
    if seed is None:
        seed = _new_seed()
    streams = _with_rng_restore(lambda: _make_streams(seed, setup["n_paths"]))
    res = _with_rng_restore(lambda: _par_lapply(
        range(1, setup["n_paths"] + 1),
        lambda i: _draw_path(setup, i, streams[i - 1], config, method, max_tries), cores))
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

    Entfernt leere, unvollständige oder nicht endliche Pfade sowie Pfade mit
    abweichender Zeilenzahl und normiert die Gewichte neu auf Mittel 1.
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

    Args:
        result: :class:`BootstrapResult` oder eine einzelne Pfadmatrix (``DataFrame``).
        i: Pfadnummer (1-basiert wie in R; Standard 1).
        dates: Datumsvektor (Länge = Zeilen des Pfads) oder ``None``.
        start: Startdatum für ``dates=None``.

    Returns:
        ``DataFrame`` mit Spalte ``date`` und allen Pfadspalten; ausdrücklich als
        "rate" gekennzeichnete Zusatzreihen stehen in ``df.attrs["aux_type"]``.
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
    """Standard-Kennzahlen für :func:`bootstrap_study` (benannter Vektor als ``Series``)."""
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


def _is_strategy(s) -> bool:
    try:
        from .config import Strategy
    except ImportError:  # pragma: no cover
        return False
    return isinstance(s, Strategy)


def _deparse(v) -> str:
    from ._r.rformat import r_deparse
    return r_deparse(v)


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


def _year_month(d):
    a = np.asarray(d).astype("datetime64[D]")
    y = a.astype("datetime64[Y]").astype(np.int64) + 1970
    m = a.astype("datetime64[M]").astype(np.int64) % 12 + 1
    return y, m


@_quiet
def bootstrap_study(data, config, method="stationary", n=1000, strategies=None, *, params=None, ess=False,
                    ess_grid=None, path_length=None, dates=None, start="2000-01-01", burn_in=0,
                    sim_args=None, metrics=bootstrap_study_metrics, benchmark=None, chunk_dir=None, keep_paths=0,
                    keep_returns=("none", "year", "quarter", "month"), keep_aux=None, max_tries=10, chunk_size=25,
                    seed=None, cores=1, progress=True):
    """Strategien auf Bootstrap-Pfaden auswerten.

    Erzeugt Pfade wie :func:`bootstrap`, berechnet je Pfad die Signale,
    simuliert alle Strategien mit :func:`simlev.simulation` auf demselben Pfad
    und speichert nur Kennzahlen (siehe R-Dokumentation ``bootstrap_study``).

    Args:
        strategies: dict Name -> Strategie oder dict mit ``strategy`` und optional
            ``signal`` (Funktion ``DataFrame -> DataFrame | dict``), ``args``
            (dict für ``simulation``) und ``map`` (dict Alias -> Pfadspalte).
        Übrige Argumente wie in R.

    Returns:
        :class:`SimLevBootstrapStudy`.
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
    setup = _boot_setup(data, config, method, n, params, ess, ess_grid, path_length)
    n_out = setup["n_out"]
    if dates is None:
        dates = _seq_dates(_to_date(start, "start"), n_out + 1)
    if len(np.atleast_1d(dates)) != n_out + 1:
        _stop("dates braucht Länge %d (Pfadlänge + 1)." % (n_out + 1))
    dates = _to_date(dates, "dates")
    if burn_in >= n_out:
        _stop("burn_in ist länger als der Pfad.")
    if seed is None:
        seed = _new_seed()
    n_paths = setup["n_paths"]
    streams = _with_rng_restore(lambda: _make_streams(seed, n_paths))
    ids = np.arange(1, n_paths + 1)
    chunk_size = float(chunk_size)
    keys = np.ceil(ids / chunk_size)
    chunks = [ids[keys == k] for k in sorted(set(keys.tolist()))]
    if chunk_dir is not None:
        os.makedirs(chunk_dir, exist_ok=True)
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
            f = np.array([r_pow(1 + x / 100, y) for x, y in zip(v, dt_sim)])
            return r_cumprod(np.concatenate([[1.0], f]))
        if _aux_type_of(at, a) == "level":
            return P[a].to_numpy()[sim_rows - 1]
        return P.attrs["aux_level"][a].to_numpy()[sim_rows - 1]

    def eval_path(i):
        dp = _draw_path(setup, i, streams[i - 1], config, method, max_tries)
        if dp["path"] is None:
            return None
        P = dp["path"]
        df0 = pd.DataFrame({"date": dates})
        for c in P.columns:
            df0[c] = P[c].to_numpy()
        rows = {}
        for nm in snames:
            sp = specs[nm]
            df = df0.copy()
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
            row = pd.concat([pd.Series([float(i), float(setup["weights"][i - 1]),
                                        float(setup["combo_of_path"][i - 1]), float(dp["tries"])],
                                       index=["path", "weight", "combo", "tries"]), m])
            rows[nm] = {"row": row, "ret": per_ret(_result_index(res)["value"].to_numpy()) if ret_ends is not None
                        else None, "warn": _uniq(wr)}
        aux_ret = None
        if ret_ends is not None and keep_aux:
            aux_ret = {a: per_ret(aux_level_of(P, a)) for a in keep_aux}
        return {"id": i, "rows": rows, "aux": aux_ret, "path": P if i <= keep_paths else None}

    def run_chunk(ci):
        f = None
        if chunk_dir is not None:
            f = os.path.join(chunk_dir, "chunk_%05d_seed%d%s.rds" % (
                ci, int(seed), ("_" + keep_returns) if keep_returns != "none" else ""))
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
    res = _with_rng_restore(lambda: _par_lapply(range(1, len(chunks) + 1), run_chunk, cores))
    res = [r for ch in res for r in ch]
    tab_parts = []
    for nm in snames:
        rws = [r["rows"][nm]["row"] for r in res if r is not None and r["rows"][nm]["row"] is not None]
        if not rws:
            continue
        cols = list(rws[0].index)
        mat = np.array([np.asarray(rw, dtype=np.float64) for rw in rws])
        d = pd.DataFrame({"strategy": [nm] * len(rws)})
        for j, c in enumerate(cols):
            d[c] = mat[:, j]
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


def _uniq(seq):
    out = []
    for s in seq:
        if s not in out:
            out.append(s)
    return out


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
    """Gewichtete Quantile (gewichteter Typ 7, Akinshin 2023), Port von ``.wquantile``."""
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
    r = np.cumsum(w.astype(LD)).astype(np.float64)
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


class _CondFrame(dict):
    pass


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

    Bedingungen als Zeichenketten in R-Syntax (Spaltennamen von
    ``study.results`` als Variablen, z. B. ``"cagr > 0 & max_drawdown <= 0.5"``;
    Vorrang, NA-Logik und Funktionen wie in R, siehe :mod:`simlev._r.rexpr`)
    oder Funktionen ``DataFrame -> bool-Array``. Unbenannte Bedingungen
    (``*args``) werden nach ihrem Text benannt, benannte über Schlüsselwörter
    (``joint="cagr > 0 & max_drawdown <= 0.5"``). Freie Variablen werden in
    ``env`` gesucht (Voreinstellung: Namensraum des Aufrufers).

    Args:
        study: :class:`SimLevBootstrapStudy`.
        thresholds: dict Strategie -> dict Name -> Bedingung; ersetzt für diese
            Strategie die Bedingungen aus ``*args``/``**kwargs``.
        env: Mapping für freie Variablen und Funktionen in Bedingungen.

    Returns:
        ``DataFrame`` mit ``strategy``, ``condition``, ``probability``, ``se``, ``n``.
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
        Punkte von ``density()`` je Strategie im Wertebereich der Kennzahl).
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
        if v.size < 2:   # R's density(): vor nx / N prüfen (_r.stats.density teilt sonst durch 0)
            raise ValueError("need at least 2 points to select a bandwidth automatically")
        dd = _stats().density(v)
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

quiet_fp(globals(), list(__all__) + ["_calculate_ess", "_ess_design", "_extract_returns", "_fit_garch11", "_fit_tail", "_get_base_params", "_get_ess_grid", "_letf_returns", "_make_streams", "_prepare_regime_info", "_pw_block", "_wquantile"])  # bootstrap_probability: env aus dem Aufrufer (env_from_caller)


def _make_callable():
    """Macht dieses Modul aufrufbar wie die gleichnamige Funktion (``simlev.bootstrap(...)`` wie in R;
    ``simlev.bootstrap.<name>`` und ``import simlev.bootstrap`` erreichen weiter das Modul). Steht hier statt
    in ``__init__.py``, weil das Modul erst bei Bedarf geladen wird (PEP 562)."""
    import sys
    import types

    class _CallableModule(types.ModuleType):
        def __call__(self, *args, **kwargs):
            return getattr(self, "bootstrap")(*args, **kwargs)

    sys.modules[__name__].__class__ = _CallableModule


_make_callable()
del _make_callable
