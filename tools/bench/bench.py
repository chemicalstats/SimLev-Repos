#!/usr/bin/env python3
"""Messbasis SimLev, Python (Etappe 3, tools/bench). Aufgaben siehe README.md.

Aufruf aus der Repo-Wurzel::

    LC_ALL=C.UTF-8 python3 tools/bench/bench.py [ausgabe.csv] [aufgaben]

aufgaben: kommagetrennt (z. B. T1,T8), Voreinstellung alle außer P1 (= P1c1,
P1c2: bootstrap mit cores=1 und 2, Fork; nur auf Anforderung). Je Aufgabe 1
Aufwärmlauf (erster_lauf_s), dann 3 gemessene Läufe (Median, Min, Max). Ein
Kern: cores=1, wo die Funktion es kennt; BLAS-Threads setzt run.sh. Die Daten
entstehen mit dem R-Zufallsgenerator der Python-Fassung (simlev._r.rng) und
sind dieselben Zahlen wie in bench.R (Prüfsumme in der Ausgabe).
"""
import contextlib
import io
import os
import statistics
import sys
import time
import warnings

ROOT = os.getcwd()
sys.path.insert(0, os.path.join(ROOT, "python"))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join("tools", "bench", "out", "python.csv")
ONLY = sys.argv[2].split(",") if len(sys.argv) > 2 else None
RUNS = 3

t0 = time.perf_counter()
import simlev as sl  # noqa: E402
T_LOAD = time.perf_counter() - t0

import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402
from simlev._r import rng  # noqa: E402
from simlev._r.rnum import r_cumprod, r_sum  # noqa: E402
from simlev.ms_garch import _ms_garch_fit  # noqa: E402
from simlev import _bootstrap_core  # noqa: E402

# Sprache in der CSV: "Python" mit C-Erweiterung (seit Etappe 7.3a simlev._ext mit allen gemeinsamen
# Kernen, Etappe 7.2 simlev._ext_msgarch), "Python ohne C" mit reinen Python-Kernen (nicht gebaut oder
# SIMLEV_NO_EXT=1); getattr: auch für ältere Stände
def _ext_active():
    from simlev._r import env as _env
    if hasattr(_env, "ext"):
        return _env.ext() is not None
    return getattr(_bootstrap_core, "_ext_msgarch", lambda: None)() is not None


LANG = "Python" if _ext_active() else "Python ohne C"
print("C-Erweiterung simlev._ext: %s (Sprache %s)" % ("aktiv" if LANG == "Python" else "aus", LANG))


def dates(start, n):
    return pd.date_range(start, periods=n, freq="D")


def path(level, n, m, s):
    return level * r_cumprod(1 + rng.rnorm(n, m, s))


# ── Daten wie bench.R ──
rng.set_seed(1); n = 10958
A = path(100, n, 3e-4, 0.01); B = path(50, n, 1e-4, 0.003)
d30 = pd.DataFrame({"date": dates("1995-01-01", n), "A": A, "B": B})
rng.set_seed(7); n = 7305
cols = {}
for nm, m, s in (("aktien", 3e-4, 0.011), ("bonds", 1e-4, 0.003), ("gold", 2e-4, 0.009), ("em", 3e-4, 0.014)):
    cols[nm] = path(100, n, m, s)
d = pd.DataFrame({"date": dates("2000-01-01", n), **cols})
W = (1 + rng.rnorm(30 * 2000, 0.05, 0.15)).reshape((30, 2000), order="F")


def sim_msgjr(n, om, al, ga, be, P, seed):
    rng.set_seed(seed); K = len(om)
    om, al, ga, be, P = (np.asarray(v, dtype=float) for v in (om, al, ga, be, P))
    hk = om / (1 - al - ga / 2 - be); s = 1; y = np.zeros(n)
    for t in range(1, n + 1):
        if t > 1:
            s = int(rng.sample_int(K, 1, prob=P[s - 1, :])[0]); e = y[t - 2]
            hk = om + (al + ga * float(e < 0)) * (e * e) + be * hk
        y[t - 1] = np.sqrt(hk[s - 1]) * rng.rnorm(1)[0]
    return y


y8 = sim_msgjr(2000, [2e-6, 2e-5], [0.02, 0.05], [0.04, 0.10], [0.92, 0.85], [[0.99, 0.01], [0.03, 0.97]], 7)


def fp(x):
    return "%.17g" % float(r_sum(np.ravel(np.asarray(x), order="F")))


print("Daten: S30 %s, T %s, W %s, T8 %s" % (fp(d30["A"].to_numpy()), fp(d["em"].to_numpy()), fp(W), fp(y8)))

st30 = sl.create_strategy(A=sl.asset_config(asset_class="etf", trading="bnh", share=0.7), B=sl.asset_config(asset_class="etf", trading="bnh", share=0.3))
cfg = sl.bootstrap_config({"akt": "aktien"}, input="prices")
st = sl.create_strategy(akt=sl.asset_config(asset_class="etf", trading="bnh"))
A4 = ["aktien", "bonds", "gold", "em"]

TASKS = {
    "S30": lambda: sl.simulation(d30, st30, start_value=1e4, dca=sl.dca_plan(value=200, span=1), rebalance=sl.rebalance_plan(unit="quarter"), tax=sl.tax_profile(base_rate=2)),
    "T1": lambda: sl.bootstrap(d, cfg, method="stationary", n=200, seed=1, progress=False, path_length=2520, cores=1),
    "T2": lambda: sl.bootstrap(d, cfg, method="garch", n=50, seed=1, progress=False, path_length=2520, cores=1),
    "T3": lambda: sl.bootstrap_study(d, cfg, "stationary", n=50, path_length=2520, seed=1, progress=False,
                                     strategies={"a": st}, cores=1),
    "T4": lambda: sl.withdrawal_simulation(W, rule=sl.withdrawal_rule(type="constant", rate=4), start_value=1e6),
    "T5": lambda: sl.dependence_analysis(d, A4, copulas=False),
    "T6": lambda: sl.portfolio_optimize(d, assets=A4, method="min_cvar"),
    "T7": lambda: sl.portfolio_optimize(d, assets=A4, method="hrp"),
    "T8": lambda: _ms_garch_fit(y8, 2, "gjrGARCH"),
    "P1c1": lambda: sl.bootstrap(d, cfg, method="stationary", n=400, seed=1, progress=False, path_length=2520, cores=1),
    "P1c2": lambda: sl.bootstrap(d, cfg, method="stationary", n=400, seed=1, progress=False, path_length=2520, cores=2),
}
if ONLY:
    ONLY = [t for a in ONLY for t in (["P1c1", "P1c2"] if a == "P1" else [a])]
    TASKS = {k: v for k, v in TASKS.items() if k in ONLY}
else:
    TASKS = {k: v for k, v in TASKS.items() if not k.startswith("P")}


def el(f):
    with warnings.catch_warnings(), contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
        warnings.simplefilter("ignore")
        t = time.perf_counter()
        f()
        return time.perf_counter() - t


rows = [("Laden", LANG, T_LOAD, T_LOAD, T_LOAD, T_LOAD)]
for k, f in TASKS.items():
    first = el(f)
    ts = [el(f) for _ in range(RUNS)]
    rows.append((k, LANG, statistics.median(ts), min(ts), max(ts), first))
    print("%-4s median %.3f s (min %.3f, max %.3f; erster Lauf %.3f)" % (k, rows[-1][2], min(ts), max(ts), first), flush=True)
os.makedirs(os.path.dirname(OUT) or ".", exist_ok=True)
with open(OUT, "w", encoding="utf-8") as fh:
    fh.write("aufgabe,sprache,median_s,min_s,max_s,erster_lauf_s\n")
    for r in rows:
        fh.write("%s,%s,%.4f,%.4f,%.4f,%.4f\n" % r)
print("->", OUT)
