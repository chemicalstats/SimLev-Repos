"""Gemeinsame Hilfen der Python-Grafiktests (tests/ausgabe/test_grafik.py; bis 1.6.2 mit weiteren, ungenutzten
Nachbildungen der Helfer aus r/tests/testthat)."""
import contextlib
import io
import warnings

import numpy as np
import pandas as pd

import simlev


def days(start, end):
    """``seq.Date(from, to, by = "day")``."""
    return pd.date_range(start, end, freq="D")


def sim(*a, **k):
    """``suppressWarnings(suppressMessages(simulation(...)))``."""
    with warnings.catch_warnings(), contextlib.redirect_stderr(io.StringIO()):
        warnings.simplefilter("ignore")
        return simlev.simulation(*a, **k)


def _dca():
    """Sparplan-Fall aus den Handrechnungen (bis 1.4.0 in test_tax_law.py; genutzt von test_grafik.py)."""
    dd = days("2020-01-01", "2021-12-31")
    p = np.where(dd < pd.Timestamp("2020-06-01"), 100.0, np.where(dd < pd.Timestamp("2021-07-01"), 80.0, 100.0))
    p[-1] = 150
    return sim(pd.DataFrame({"date": dd, "A": p}),
               simlev.create_strategy(A=simlev.asset_config(asset_class="etf", trading="bnh", share=1, spread=0)),
               start_value=1000, dca=simlev.dca_plan(value=1000, span=1, unit="year", skip=True))
