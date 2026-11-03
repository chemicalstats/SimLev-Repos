"""Gemeinsame Hilfen der Engine-Tests (Nachbildung der Helfer aus r/tests/testthat)."""
import contextlib
import io
import warnings

import numpy as np
import pandas as pd

import simlev


def days(start, end):
    """``seq.Date(from, to, by = "day")``."""
    return pd.date_range(start, end, freq="D")


def days_n(start, n):
    return pd.date_range(start, periods=n, freq="D")


def step(dates, at, v):
    """Stückweise konstanter Kurs: Wert v[i] ab Datum at[i] (``v[findInterval(dates, at)]``)."""
    at = pd.to_datetime(at)
    idx = np.searchsorted(at.values, pd.DatetimeIndex(dates).values, side="right") - 1
    return np.asarray(v, dtype=float)[idx]


def lin(dates, at, v):
    """``approx(at, v, xout = dates, rule = 2)$y``."""
    x = pd.to_datetime(at).values.astype("datetime64[D]").astype(np.int64)
    xo = pd.DatetimeIndex(dates).values.astype("datetime64[D]").astype(np.int64)
    return np.interp(xo, x, np.asarray(v, dtype=float))


def flag(dates, at):
    return pd.DatetimeIndex(dates).isin(pd.to_datetime(at if isinstance(at, (list, tuple)) else [at]))


def sim(*a, **k):
    """``suppressWarnings(suppressMessages(simulation(...)))``."""
    with warnings.catch_warnings(), contextlib.redirect_stderr(io.StringIO()):
        warnings.simplefilter("ignore")
        return simlev.simulation(*a, **k)


def sim_out(*a, **k):
    """Simulation mit ``details = TRUE``; Rückgabe (Ergebnis, Ausgabezeilen)."""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        r = sim(*a, details=True, **k)
    return r, buf.getvalue().splitlines()


def sim_warn(*a, **k):
    """Simulation; Rückgabe (Ergebnis, Liste der Warnungstexte)."""
    with warnings.catch_warnings(record=True) as wl, contextlib.redirect_stderr(io.StringIO()):
        warnings.simplefilter("always")
        r = simlev.simulation(*a, **k)
    return r, [str(w.message) for w in wl]


def idx(r, date):
    """Index des Datums in ``r.dates``."""
    return int(np.flatnonzero(r.dates == np.datetime64(date))[0])


def _dca():
    """Sparplan-Fall aus den Handrechnungen (bis T18 in test_tax_law.py; genutzt von test_dashboard.py)."""
    dd = days("2020-01-01", "2021-12-31")
    p = np.where(dd < pd.Timestamp("2020-06-01"), 100.0, np.where(dd < pd.Timestamp("2021-07-01"), 80.0, 100.0))
    p[-1] = 150
    return sim(pd.DataFrame({"date": dd, "A": p}),
               simlev.create_strategy(A=simlev.asset_config(asset_class="etf", trading="bnh", share=1, spread=0)),
               start_value=1000, dca=simlev.dca_plan(value=1000, span=1, unit="year", skip=True))
