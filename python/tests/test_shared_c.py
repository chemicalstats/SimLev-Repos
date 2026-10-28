"""Gemeinsame native Kerne für R und Python (Etappe 7.2, 7.3a Kerne ohne Zufallszahlen, 7.3b mit Zufallszahlen).

- Die Kopien in ``python/src/`` sind Byte für Byte gleich den kanonischen Quellen in
  ``r/src/`` (übersprungen, wenn das R-Paket nicht daneben liegt, etwa beim Prüfen
  eines entpackten Quellpakets); die Liste ``SHARED`` ist vollständig (jede
  ``*_impl.*``-Datei in ``r/src/`` steht darin) und stimmt mit ``setup.py`` überein.
- Ist die Erweiterung ``simlev._ext`` gebaut, rechnet sie bitgleich zum reinen
  Python-Kern; ``SIMLEV_NO_EXT=1`` schaltet sie ab (Rückfall).
- Kerne mit Zufallszahlen (Etappe 7.3b): die C-Nachbildung von R's RNG
  (``python/src/_rng_r.c``) zieht dieselben Zahlen wie :mod:`simlev._r.rng`, und der Zustand
  danach ist derselbe wie nach dem reinen Python-Kern (auch ``rpois``, Ausgabepuffer, beide
  Arten); nicht nachgebildete Arten und ungültige Eingaben rechnet der reine Kern.

Die Referenzfälle aller Module laufen in ``test_module_reference.py`` und
``test_golden.py`` mit dem Weg, den die Umgebung wählt (mit Erweiterung, wenn gebaut;
mit ``SIMLEV_NO_EXT=1`` ohne).
"""
import copy
import os
import re

import numpy as np
import pytest

from simlev import _bootstrap_core as C
from simlev import _core
from simlev._r import env, nmath, parallel, rng, truncnorm
from simlev._r.rnum import NA_REAL

HERE = os.path.dirname(os.path.abspath(__file__))
PY_SRC = os.path.join(HERE, "..", "src")
R_SRC = os.path.join(HERE, "..", "..", "r", "src")

# Gemeinsame Dateien (kanonisch in r/src/, Kopie in python/src/)
SHARED = [
    "simlev_core.h",
    "ms_garch_impl.c", "ms_garch_impl.h",
    "research_core_impl.h", "withdrawal_core_impl.h", "dependence_core_impl.h",
    "vendor_rugarch_impl.h", "vendor_evd_impl.h", "vendor_imputets_impl.h",
    "simulation_core_impl.h", "fifo_core_impl.h", "tax_core_impl.h",
    "bootstrap_core_impl.h", "vendor_truncnorm_impl.h",
]
# Nur in python/src/ (keine Kopie): C-Nachbildung von R's Zufallszahlen (Etappe 7.3b)
PY_ONLY = ["_rng_r.c", "_rng_r.h"]

# Kerne (Funktionen von simlev._ext) je gemeinsamer Datei
METHODS = {
    "ms_garch_impl.c": ["ms_garch_filter"],
    "research_core_impl.h": ["proj_box_simplex", "qp_box_simplex", "min_cvar_core", "min_cdar_core",
                             "roll_mean_core", "roll_cov_core", "kendall_tau_core", "quantile_reg_core",
                             "hmm_forward_backward", "garch_filter"],
    "withdrawal_core_impl.h": ["wd_simulate"],
    "dependence_core_impl.h": ["dcc_filter"],
    "vendor_rugarch_impl.h": ["rugarch_filter"],
    "vendor_evd_impl.h": ["evd_nlgpd"],
    "vendor_imputets_impl.h": ["imputets_locf"],
    "simulation_core_impl.h": ["sim_dca_flows", "sim_buy_report", "sim_sell_report", "sim_total_report", "sim_buy",
                               "sim_market_update", "sim_market_update_batch"],
    "fifo_core_impl.h": ["sim_fifo_price", "sim_fifo_vp", "sim_private_sale_tax", "sim_fifo_consume"],
    "tax_core_impl.h": ["sim_flat_rate", "sim_p20_tax", "sim_vp_tax", "sim_sell_count"],
    "bootstrap_core_impl.h": ["boot_idx_iid", "boot_idx_block", "boot_idx_stationary", "boot_idx_regime",
                              "boot_idx_tails", "boot_wild", "boot_reset", "boot_evt", "boot_garch", "boot_ms_garch",
                              "rolling_vol", "assign_regimes", "estimate_trans_mat"],
    "vendor_truncnorm_impl.h": ["truncnorm_rtruncnorm"],
    "_rng_r.c": ["rng_draw", "rng_qnorm", "rng_dnorm"],          # Prüfzugang (_ext_rng.cpp)
}


def _repo():
    if not os.path.isdir(R_SRC):
        pytest.skip("r/src nicht vorhanden (kein Repo neben dem Python-Paket)")


@pytest.mark.parametrize("name", SHARED)
def test_kopie_byte_gleich(name):
    _repo()
    with open(os.path.join(R_SRC, name), "rb") as fh:
        a = fh.read()
    with open(os.path.join(PY_SRC, name), "rb") as fh:
        b = fh.read()
    assert a == b, ("python/src/%s weicht von r/src/%s ab; die kanonische Quelle ist r/src/, "
                    "danach kopieren: cp r/src/%s python/src/" % (name, name, name))


def test_liste_vollstaendig():
    """Jede Kerndatei in r/src/ ist geteilt; python/src/ enthält nur Kopien und Hüllen (_ext*)."""
    _repo()
    impl = sorted(f for f in os.listdir(R_SRC) if re.search(r"_impl\.(c|h)$", f))
    assert sorted(f for f in SHARED if f != "simlev_core.h") == impl
    py = sorted(f for f in os.listdir(PY_SRC) if not f.startswith("_ext") and not f.startswith("."))
    assert py == sorted(SHARED + PY_ONLY)
    assert not any(os.path.exists(os.path.join(R_SRC, f)) for f in PY_ONLY)


def test_setup_listen():
    """setup.py baut genau die gemeinsamen Dateien mit (Quellen und Abhängigkeiten)."""
    src = open(os.path.join(HERE, "..", "setup.py"), encoding="utf-8").read()

    def lst(name):
        m = re.search(name + r"\s*=\s*\[(.*?)\]", src, re.S)
        return re.findall(r'"([^"]+)"', m.group(1))
    assert sorted(lst("CORES") + lst("SHARED_HEADERS")) == sorted(SHARED)
    assert lst("RNG") == ["_rng_r.c"] and "_rng_r.h" in src
    wrappers = lst("WRAPPERS")
    assert sorted(wrappers) == sorted(f for f in os.listdir(PY_SRC) if f.startswith("_ext") and not f.endswith(".h"))


def test_schalter_no_ext():
    with env.use_ext(False):
        assert env.no_ext() and env.ext() is None


def _ext_or_skip():
    with env.use_ext(True):
        ext = env.ext()
    if ext is None:
        pytest.skip("simlev._ext ist nicht gebaut (reine Python-Kerne)")
    return ext


def test_erweiterung_hat_alle_kerne():
    ext = _ext_or_skip()
    names = sorted(n for n in dir(ext) if not n.startswith("_"))
    assert names == sorted(sum(METHODS.values(), []))


# ── MS-GARCH (Pilot, Etappe 7.2) ─────────────────────────────────────────────

def _filter(args, no_ext):
    with env.use_ext(not no_ext), np.errstate(all="ignore"):
        return C.ms_garch_filter(*args)


def _cases():
    rng.set_seed(42)
    out = []
    for K, n, gjr in ((2, 2000, True), (3, 500, False), (1, 7, True), (2, 1, False), (4, 60, True)):
        y = np.asarray(rng.rnorm(n, 0, 0.01), dtype=np.float64)
        om = np.linspace(1e-6, 2e-5, K)
        al = np.linspace(0.02, 0.08, K)
        be = np.linspace(0.92, 0.85, K)
        ga = np.linspace(0.03, 0.1, K) if gjr else np.zeros(K)
        P = np.full((K, K), 0.05 / max(K - 1, 1))
        np.fill_diagonal(P, 0.95 if K > 1 else 1.0)
        xi = np.full(K, 1.0 / K)
        out.append((y, om, al, be, ga, P, xi, float(np.var(y))))
    # Randfälle: Inf in y (loglik -Inf, Rechnung läuft weiter), Varianz 0, Startverteilung 0,
    # NA und NaN in y (Etappe 7.3a: auch der reine Python-Kern liefert dann R's NaN-Bits)
    y, om, al, be, ga, P, xi, h1 = out[0]
    y2 = y.copy()
    y2[10] = np.inf
    y3 = y.copy()
    y3[5] = np.nan
    y3[20] = NA_REAL
    out += [(y2, om, al, be, ga, P, xi, h1), (y, om, al, be, ga, P, xi, 0.0),
            (y, om, al, be, ga, P, np.zeros(2), h1), (y3, om, al, be, ga, P, xi, h1),
            (y, om, al, -be, ga, P, xi, -h1)]
    return out


def test_erweiterung_bitgleich_zum_python_kern():
    _ext_or_skip()
    for args in _cases():
        a = _filter(args, False)
        b = _filter(args, True)
        assert list(a) == list(b) == ["loglik", "h", "pred", "filt", "lB"]
        assert type(a["loglik"]) is float and np.float64(a["loglik"]).tobytes() == np.float64(b["loglik"]).tobytes()
        for k in ("h", "pred", "filt", "lB"):
            assert a[k].dtype == b[k].dtype == np.float64 and a[k].shape == b[k].shape
            assert a[k].flags.c_contiguous and b[k].flags.c_contiguous
            assert a[k].tobytes() == b[k].tobytes(), k


def test_erweiterung_fehlermeldungen_wie_python():
    """Die Prüfungen laufen vor dem Kern in Python: gleiche Meldungen mit und ohne Erweiterung."""
    y, om, al, be, ga, P, xi, h1 = _cases()[0]
    bad = [((np.zeros(0), om, al, be, ga, P, xi, h1), "'y' darf nicht leer sein"),
           ((y, om, al[:1], be, ga, P, xi, h1), "'alpha' muss die Länge 2 haben"),
           ((y, om, al, be, ga, P, xi, [1.0, 2.0]), "'h1' muss die Länge 1 haben"),
           ((y, om, al, be, ga, P, ["a", "b"], h1), "'xi0' muss numerisch sein")]
    for no_ext in (False, True):
        for args, msg in bad:
            with pytest.raises(ValueError, match=msg):
                _filter(args, no_ext)


def test_erweiterung_prueft_puffer():
    """Die C-Hülle selbst lehnt falsche Puffer ab (Schutz gegen Aufrufe ohne Python-Prüfung)."""
    ext = _ext_or_skip()
    y = np.zeros(5)
    k1 = np.ones(1)
    out = [np.empty(5) for _ in range(4)]
    with pytest.raises(ValueError, match="'h' muss die Länge 5 haben"):
        ext.ms_garch_filter(y, k1, k1, k1, k1, k1, k1, 1.0, np.empty(4), *out[1:])
    with pytest.raises(TypeError, match="'y' muss ein double-Puffer sein"):
        ext.ms_garch_filter(y.astype(np.float32), k1, k1, k1, k1, k1, k1, 1.0, *out)
    with pytest.raises((BufferError, ValueError)):          # numpy: "buffer source array is read-only"
        ro = np.empty(5)
        ro.flags.writeable = False
        ext.ms_garch_filter(y, k1, k1, k1, k1, k1, k1, 1.0, ro, *out[1:])
    assert isinstance(ext.ms_garch_filter(y, k1, k1, k1, k1, k1, k1, 1.0, *out), float)


# ── Engine-Kerne (Etappe 7.3a): Zustand sim wie _sim_phases ─────────────────

def _sim(n=6):
    names = ["a", "Ä"]
    sim = {"assets": names, "status": {}, "market": {}, "trades": {}, "report": {}, "totals": {}}
    for k, nm in enumerate(names):
        sim["status"][nm] = {"count": 3.0 + k, "price": 10.0, "worth": 30.0, "money": 100.0 * (k + 1),
                             "total": 130.0, "actual": 0.5, "differ": 0.5}
        sim["market"][nm] = {"asset_day": np.arange(18260, 18260 + n, dtype=np.int64),
                             "asset_price": np.linspace(10.0, 12.5 + k, n)}
        sim["trades"][nm] = {"buys": [], "buy_count": 0, "fifo_front": 1}
        sim["report"][nm] = {f: np.zeros(n) for f in ("worth", "money", "flows", "total", "share")}
    sim["totals"] = {"loss_capital_gains": 50.0, "cgt_loss_added_ytd": 0.0, "cgt_loss_used_ytd": 0.0,
                     "sparer_pauschbetrag_remaining": 1000.0, "sparer_pauschbetrag_used_total": 0.0,
                     "cgt_base_taxed_ytd": 0.0, "total_taxes": 0.0}
    return sim


def _run_engine(no_ext):
    sim = _sim()
    out = []
    with env.use_ext(not no_ext), np.errstate(all="ignore"):
        _core.batch_market_update(sim, sim["assets"], 1, 2)
        _core.dca_flows_allocation(sim, "a", 250.0, 3)
        _core.perform_trade_buy_cpp(sim, "a", 3, 7.5, 10.7, 10.6)
        _core.perform_trade_buy_cpp(sim, "Ä", 4, 2.0, 12.1, 12.0)
        _core.perform_trade_buy_cpp(sim, "a", 4, 1.25, 11.2, 11.1)
        _core.perform_market_update(sim, sim["assets"], 5)
        tr = sim["trades"]["a"]
        out.append(_core._calculate_fifo_price(tr["buys"], 8.0, tr["fifo_front"]))
        out.append(_core._calculate_fifo_vorabpauschale(tr["buys"], 8.0, tr["fifo_front"]))
        out.append(_core._calculate_private_sale_tax(tr["buys"], tr["fifo_front"], 8.0, 12.0, 18700))
        out.append(_core.sell_count(tr["buys"], tr["fifo_front"], 50.0, 12.0, 8.75, True, 1, 0.3, 10.0, 0.26375))
        out.append(_core.flat_rate(tr["buys"], tr["fifo_front"], 0.0255, 10.0, 12.0, 18262, 18627))
        out.append(_core.p20_tax(40.0, 0.3, sim["totals"], 0.26375, True))
        out.append(_core.vp_tax(5.0, 0.3, sim["totals"], 0.26375, True))
        _core.calculate_sell_report(sim, "a", 6, 8.0, 12.0, 12.1, 3.5)
        _core.fifo_consume(sim, "a", 8.0)
        _core.calculate_total_report(sim, sim["assets"], 6)
    return sim, out


def _same(a, b):
    """Gleiche Struktur, gleiche Typen der Blätter (float/int/str/Array) und gleiche Bits."""
    if isinstance(a, dict):
        assert isinstance(b, dict) and list(a) == list(b)
        for k in a:
            _same(a[k], b[k])
    elif isinstance(a, (list, tuple)):
        assert type(a) is type(b) and len(a) == len(b)
        for x, y in zip(a, b):
            _same(x, y)
    elif isinstance(a, np.ndarray):
        assert isinstance(b, np.ndarray) and a.dtype == b.dtype and a.tobytes() == b.tobytes()
    elif isinstance(a, float):
        assert type(b) is float and np.float64(a).tobytes() == np.float64(b).tobytes()
    else:
        assert type(a) is type(b) and a == b


def test_engine_erweiterung_bitgleich_zum_python_kern():
    _ext_or_skip()
    a = _run_engine(False)
    b = _run_engine(True)
    _same(a, b)


def test_engine_index_ausserhalb():
    """Die Hülle prüft die Tagesindizes vor dem Kern (R prüft nicht): IndexError statt Speicherfehler."""
    ext = _ext_or_skip()
    sim = _sim()
    for f, args in ((ext.sim_dca_flows, (sim, "a", 1.0, 7)), (ext.sim_total_report, (sim, ["a"], 0)),
                    (ext.sim_market_update_batch, (sim, ["a", "Ä"], 2, 9)), (ext.sim_buy, (sim, "Ä", 99, 1.0, 1.0, 1.0))):
        before = copy.deepcopy(sim)
        with pytest.raises(IndexError):
            f(*args)
        _same(before, sim)
    with pytest.raises(KeyError):
        ext.sim_dca_flows(sim, "fehlt", 1.0, 1)
    with pytest.raises(IndexError):
        ext.sim_fifo_consume({"assets": [], "status": {}, "market": {}, "trades": {"a": {"buys": [], "buy_count": 2,
                              "fifo_front": 1}}}, "a", 1.0)


# ── Kerne mit Zufallszahlen (Etappe 7.3b) ───────────────────────────────────

def _state():
    """Vollständiger Zustand der Python-Nachbildung: .Random.seed, Arten, rpois, und 700 weitere
    unif_rand-Werte (prüft auch den Ausgabepuffer des Mersenne-Twisters)."""
    sd = rng.get_random_seed()
    rp = {k: (list(v) if isinstance(v, list) else v) for k, v in rng._RP.items()}
    snap = parallel.rng_snapshot()
    nxt = np.array([rng.unif_rand() for _ in range(700)])
    parallel.rng_reset(snap)
    return sd, (rng._S.kind, rng._S.n01, rng._S.sample, rng._S.exists), rp, nxt


def _same_state(a, b):
    assert (a[0] is None) == (b[0] is None)
    if a[0] is not None:
        assert a[0].tobytes() == b[0].tobytes()
    assert a[1] == b[1]
    assert list(a[2]) == list(b[2])
    for k in a[2]:
        va, vb = np.asarray(a[2][k], dtype=np.float64), np.asarray(b[2][k], dtype=np.float64)
        assert va.tobytes() == vb.tobytes(), k
    assert a[3].tobytes() == b[3].tobytes()


def _start(kind, seed, skip, mti=None):
    """Zustand setzen: set.seed mit Art, optional Position mti (625 = ungesetzt), skip Werte ziehen."""
    rng.set_seed(seed, kind=kind)
    if mti is not None:
        sd = rng.get_random_seed()
        sd[1] = mti
        rng.set_random_seed(sd)
    if skip:
        rng.runif(skip)


STARTS = [("Mersenne-Twister", 1, 0, None), ("Mersenne-Twister", 42, 623, None), ("Mersenne-Twister", 7, 0, 625),
          ("Mersenne-Twister", 9, 0, 1), ("L'Ecuyer-CMRG", 3, 0, None), ("L'Ecuyer-CMRG", 2024, 17, None)]


@pytest.fixture
def keep_rng():
    snap = parallel.rng_snapshot()
    rp = copy.deepcopy(rng._RP)
    yield
    parallel.rng_reset(snap)
    rng._RP.clear()
    rng._RP.update(rp)
    rng.set_seed(1, kind="Mersenne-Twister")


def _py_draw(what, a, b):
    return {0: rng.unif_rand, 1: rng.norm_rand, 2: rng.exp_rand, 3: lambda: rng.runif1(a, b),
            4: lambda: rng.rnorm1(a, b), 5: lambda: rng.rexp1(a), 6: lambda: rng.rgeom1(a),
            7: lambda: rng.rpois1(a)}[what]


DRAWS = [(0, 0, 0), (1, 0, 0), (2, 0, 0), (3, -2.0, 5.0), (3, 1.0, 1.0), (3, 1.0, 0.0), (3, np.inf, 1.0),
         (4, 0.5, 2.0), (4, np.nan, 1.0), (4, 1.0, 0.0), (4, np.inf, 1.0), (4, 0.0, -1.0), (5, 2.5, 0), (5, 0.0, 0),
         (5, -1.0, 0), (6, 0.3, 0), (6, 0.001, 0), (6, 1.0, 0), (6, 0.0, 0), (7, 0.0, 0), (7, 3.5, 0), (7, 9.99, 0),
         (7, 10.0, 0), (7, 57.3, 0), (7, 1e6, 0), (7, np.nan, 0), (7, -1.0, 0)]


@pytest.mark.parametrize("start", STARTS)
def test_rng_c_nachbildung_bitgleich_mit_zustand(start, keep_rng):
    """Jede Zufallsfunktion der C-Nachbildung zieht dieselben Werte wie simlev._r.rng, und der
    Zustand danach (auch rpois, Puffer) ist derselbe."""
    ext = _ext_or_skip()
    for what, a, b in DRAWS:
        for n in (1, 5, 700):
            _start(*start)
            rp0 = copy.deepcopy(rng._RP)
            st = rng.c_state(rpois=True)
            out = np.empty(n)
            try:
                ext.rng_draw(*st, what, n, float(a), float(b), out)
            finally:
                rng.c_state_put(st)
            sc = _state()
            _start(*start)
            rng._RP.clear()
            rng._RP.update(rp0)
            f = _py_draw(what, a, b)
            ref = np.array([float(f()) for _ in range(n)])
            sp = _state()
            assert out.tobytes() == ref.tobytes(), (what, a, b, n)
            _same_state(sc, sp)


def test_rng_rpois_zustand_zwischen_aufrufen(keep_rng):
    """rpois behält seinen Zustand zwischen Aufrufen (wie R): gleiche und wechselnde mu im Wechsel."""
    ext = _ext_or_skip()
    mus = [3.5, 3.5, 12.0, 12.0, 12.0, 0.7, 12.0, 250.0, 250.0, 3.5]
    for start in STARTS[:2] + STARTS[4:5]:
        _start(*start)
        rp0 = copy.deepcopy(rng._RP)
        got = []
        for mu in mus:
            st = rng.c_state(rpois=True)
            out = np.empty(50)
            ext.rng_draw(*st, 7, 50, mu, 0.0, out)
            rng.c_state_put(st)
            got.append(out)
        sc = _state()
        _start(*start)
        rng._RP.clear()
        rng._RP.update(rp0)
        ref = [np.array([float(rng.rpois1(mu)) for _ in range(50)]) for mu in mus]
        _same_state(sc, _state())
        assert all(x.tobytes() == y.tobytes() for x, y in zip(got, ref))


def test_rng_rpois_ohne_zustand_ist_fehler(keep_rng):
    ext = _ext_or_skip()
    rng.set_seed(1)
    st = rng.c_state(rpois=False)
    with pytest.raises(RuntimeError, match="rpois ohne rpois-Zustand"):
        try:
            ext.rng_draw(*st, 7, 3, 2.0, 0.0, np.empty(3))
        finally:
            rng.c_state_put(st)


def test_rng_huelle_prueft_zustand(keep_rng):
    ext = _ext_or_skip()
    rng.set_seed(1)
    ist, mt, pst = rng.c_state()
    with pytest.raises(ValueError, match="'rng_ist' muss die Länge 12 haben"):
        ext.rng_draw(ist[:5].copy(), mt, None, 0, 1, 0.0, 0.0, np.empty(1))
    with pytest.raises(ValueError, match="'rng_mt' muss die Länge 624 haben"):
        ext.rng_draw(ist, mt[:10], None, 0, 1, 0.0, 0.0, np.empty(1))
    bad = ist.copy()
    bad[0] = 1
    with pytest.raises(ValueError, match="RNG-Art 1 .* nicht nachgebildet"):
        ext.rng_draw(bad, mt, None, 0, 1, 0.0, 0.0, np.empty(1))
    bad = ist.copy()
    bad[1] = 5
    with pytest.raises(ValueError, match="nicht nachgebildet"):
        ext.rng_draw(bad, mt, None, 0, 1, 0.0, 0.0, np.empty(1))


def test_qnorm5_bitgleich_zum_python_kern():
    """qnorm5 der C-Nachbildung (Inversion) gleich _qnorm_std der Python-Nachbildung für 0 < p < 1 mit
    r = sqrt(-log(min(p, 1 - p))) <= 27 (norm_rand erreicht nur p >= 2^-60, r < 6.5; den Zweig r > 27 von
    R 4.3 hat nur die C-Nachbildung, verglichen gegen R im Zufallsvergleich der Etappe 7.3b)."""
    ext = _ext_or_skip()
    g = np.random.default_rng(5)
    p = np.concatenate([g.random(200000), 10.0 ** -g.uniform(0, 300, 20000), 1 - 10.0 ** -g.uniform(1, 16, 20000),
                        [1e-300, 2.2e-308, 1.3888e-11, 1.3887e-11, 0.075, 0.925, 0.07499999999999999, 0.5,
                         0.5 + 2 ** -53, 1 - 2 ** -53, np.exp(-25.0), 2.0 ** -60, 2.0 ** -27]])
    p = p[(p > 0) & (p < 1)]
    out = np.empty(p.size)
    ext.rng_qnorm(p, out)
    ref = np.array([rng._qnorm_std(float(v)) for v in p])
    assert out.tobytes() == ref.tobytes()
    edge = np.array([0.0, 1.0, -0.5, 1.5, np.nan, NA_REAL])
    oe = np.empty(edge.size)
    ext.rng_qnorm(edge, oe)
    assert oe[0] == -np.inf and oe[1] == np.inf and np.isnan(oe[2:]).all()
    assert int(oe[5:6].view(np.uint64)[0]) & 0xFFFFFFFF == 1954          # NA bleibt NA (p + mu + sigma)


def test_dnorm4_bitgleich_zum_python_kern():
    ext = _ext_or_skip()
    g = np.random.default_rng(6)
    x = np.concatenate([g.normal(0, 3, 20000), g.uniform(4.9, 40, 5000), [0.0, -0.0, 5.0, 38.5, 38.6, 1e155, 1e300,
                        np.inf, -np.inf, np.nan, NA_REAL]])
    mu = np.where(g.random(x.size) < 0.1, g.normal(0, 1, x.size), 0.0)
    sg = np.where(g.random(x.size) < 0.1, g.choice([0.0, -1.0, np.inf, 1e-300, 2.5], x.size), 1.0)
    mu[-3:] = [np.inf, np.nan, 0.0]
    out = np.empty(x.size)
    ext.rng_dnorm(x, mu, sg, out)
    with np.errstate(all="ignore"):
        ref = np.array([nmath.dnorm4(float(a), float(b), float(c), False) for a, b, c in zip(x, mu, sg)])
    assert out.tobytes() == ref.tobytes()


def _boot_calls():
    """(Name, Aufruf) aller Bootstrap-Kerne mit Zufallszahlen, auch mit Randfällen."""
    g = np.random.default_rng(11)
    X = 1.0 + g.normal(0, 0.01, (300, 3))
    Xn = X.copy()
    Xn[5, 1] = NA_REAL
    Xn[9, 0] = np.nan
    Xn[17, 2] = np.inf
    reg = g.integers(1, 4, 300)
    T = np.array([[0.9, 0.08, 0.02], [0.1, 0.8, 0.1], [0.05, 0.15, 0.8]])
    zb = g.normal(0, 1, 300)
    zbn = zb.copy()
    zbn[3] = NA_REAL
    zbn[8] = np.nan
    zc = g.normal(0, 1, (300, 2))
    valid = np.arange(1, 301)
    cross = ([1, 2], [1e-4, 2e-4], [1e-6, 2e-6], [0.05, 0.08], [0.9, 0.85], [True, False], [1e-4, 2e-4], zc)
    pools = [np.arange(1, 101), np.arange(101, 201), np.arange(201, 301)]
    D = np.array([[0.0, 0.3, -0.2], [0.1, 0.0, 0.2], [0.0, -0.4, 0.0]])
    uv = np.array([1e-4, 2e-4, 4e-4])
    th = np.array([-np.inf, 0.005, 0.01, np.inf])
    return [
        ("iid", lambda: C.boot_idx_iid(300, 2520)),
        ("iid0", lambda: C.boot_idx_iid(300, 0)),
        ("block", lambda: C.boot_idx_block(300, 1000, 21, False)),
        ("block_c", lambda: C.boot_idx_block(300, 1000, 300, True)),
        ("stationary", lambda: C.boot_idx_stationary(300, 2520, 20.0)),
        ("stationary_L1", lambda: C.boot_idx_stationary(300, 100, 1.0)),
        ("stationary_gross", lambda: C.boot_idx_stationary(300, 3000, 5000.0)),
        ("stationary_inf", lambda: C.boot_idx_stationary(300, 10, np.inf)),       # reiner Kern (Rückfall)
        ("stationary_L_err", lambda: C.boot_idx_stationary(300, 10, 0.5)),
        ("regime", lambda: C.boot_idx_regime(reg, T, 2000)),
        ("tails", lambda: C.boot_idx_tails(1000, 0.05, 0.07, np.arange(20, 280), np.arange(1, 20), np.arange(280, 301))),
        ("tails_leer", lambda: C.boot_idx_tails(100, 0.5, 0.5, np.arange(1, 5), [], [])),
        ("wild0", lambda: C.boot_wild(X, 0)), ("wild1", lambda: C.boot_wild(X, 1)), ("wild2", lambda: C.boot_wild(Xn, 2)),
        ("wild_leer", lambda: C.boot_wild(np.zeros((0, 2)), 2)),
        ("reset", lambda: C.boot_reset(Xn, 0.02)),
        ("evt", lambda: C.boot_evt(X - 1, 0, 1500, 0.05, -0.015, 0.006, 0.2, np.arange(1, 16), 0.05, 0.016, 0.005, 0.0,
                                   np.arange(285, 301), np.arange(16, 285))),
        ("garch", lambda: C.boot_garch(1500, 0, 3, 3e-4, 2e-6, 0.06, 0.92, 0.04, 1e-4, zb, valid, *cross)),
        ("garch_na", lambda: C.boot_garch(800, 0, 3, 3e-4, 2e-6, 0.06, 0.92, 0.0, 1e-4, zbn, valid, *cross)),
        ("garch_omega_err", lambda: C.boot_garch(10, 0, 1, 0.0, 0.0, 0.06, 0.92, 0.0, 1e-4, zb, valid, [], [], [], [], [], [],
                                                 [], np.zeros((0, 0)))),
        ("ms_garch", lambda: C.boot_ms_garch(1500, 0, 3, 3, [1e-4, 0.0, -1e-4], [1e-6, 2e-6, 5e-6], [0.05] * 3, [0.9] * 3,
                                             [0.0, 0.05, 0.1], [0.0, 0.1, 0.0], [0.0, 0.0, 0.05], T, D, uv,
                                             [0.5, 0.3, 0.2], pools, zbn, *cross)),
    ]


def _run_calls(no_ext):
    out = []
    with env.use_ext(not no_ext), np.errstate(all="ignore"):
        for name, f in _boot_calls() + [
                ("truncnorm", lambda: truncnorm.rtruncnorm(500, [-1.0, 0.5, -np.inf, 2.0, NA_REAL], [1.0, np.inf, 0.3, 8.0, 3.0],
                                                           [0.0, 1.0], [1.0, 0.5, 2.0])),
                ("truncnorm_eng", lambda: truncnorm.rtruncnorm(200, 3.0, 3.01, 0.0, 1.0)),
                ("truncnorm_null", lambda: truncnorm.rtruncnorm(0, 0.0, 1.0))]:
            for start in STARTS:
                _start(*start)
                try:
                    r = ("ok", f())
                except Exception as e:      # noqa: BLE001
                    r = ("err", type(e).__name__, str(e))
                out.append((name, start, r, _state()))
    return out


def test_rng_kerne_erweiterung_bitgleich_mit_zustand(keep_rng):
    """Bootstrap-Kerne und rtruncnorm mit und ohne Erweiterung: gleiche Ergebnisse (Bits, Typen),
    gleiche Fehler und danach derselbe Zustand der Python-Nachbildung (Art für Art)."""
    _ext_or_skip()
    rp0 = copy.deepcopy(rng._RP)
    a = _run_calls(False)
    rng._RP.clear()
    rng._RP.update(rp0)
    b = _run_calls(True)
    assert len(a) == len(b)
    for (na, sa, ra, za), (nb, sb, rb, zb) in zip(a, b):
        assert (na, sa) == (nb, sb)
        assert ra[0] == rb[0], (na, sa, ra[1:], rb[1:])
        if ra[0] == "err":
            assert ra == rb, na
        else:
            _same(ra[1], rb[1])
        _same_state(za, zb)


def test_rng_kerne_nutzen_erweiterung(keep_rng):
    """Mit Erweiterung laufen die Kerne über simlev._ext (nicht still über den Rückfall)."""
    ext = _ext_or_skip()
    calls = []

    class Spy:
        def __getattr__(self, k):
            f = getattr(ext, k)

            def g(*a):
                calls.append(k)
                return f(*a)
            return g
    old = env._EXT
    env._EXT = Spy()
    try:
        with env.use_ext(True):
            rng.set_seed(3)
            for name, f in _boot_calls():
                try:
                    f()
                except ValueError:
                    pass
            truncnorm.rtruncnorm(5, 0.0, 1.0)
            C.rolling_vol(np.linspace(0.99, 1.01, 50), 5)
            C.assign_regimes(np.linspace(0, 0.02, 50), [0.0, 0.01, 1.0])
            C.estimate_trans_mat([1, 2, 2, 1, 3], 3)
    finally:
        env._EXT = old
    assert sorted(set(calls)) == sorted(METHODS["bootstrap_core_impl.h"] + ["truncnorm_rtruncnorm"])


def test_rng_rueckfall_nicht_nachgebildete_art(keep_rng, monkeypatch):
    """Eine Art, die die C-Nachbildung nicht kennt: c_state() ist None, der reine Kern rechnet."""
    ext = _ext_or_skip()
    rng.set_seed(5)
    monkeypatch.setattr(rng._S, "n01", 0)
    assert rng.c_state() is None
    calls = []

    class Spy:
        def __getattr__(self, k):
            calls.append(k)
            return getattr(ext, k)
    old = env._EXT
    env._EXT = Spy()
    try:
        with env.use_ext(True):
            C.boot_idx_iid(10, 5)
            truncnorm.rtruncnorm(3, 0.0, 1.0)
    finally:
        env._EXT = old
    assert calls == []


def test_rng_rueckfall_ungueltige_eingaben(keep_rng):
    """Eingaben, die der C-Kern nicht sicher rechnen kann, gehen an den reinen Kern (gleiches Verhalten)."""
    _ext_or_skip()
    for f in (lambda: C.boot_idx_stationary(50, 10, np.inf), lambda: C.boot_idx_stationary(50, 40, 2e7),
              lambda: C.boot_idx_iid(5, -3), lambda: C.boot_evt(np.ones((5, 2)), 0, 3, 0.5, 0.0, 0.1, 0.0, [0], 0.0, 0.0,
                                                                 0.1, 0.0, [], [1, 2])):
        res = []
        for flag in (True, False):
            with env.use_ext(flag), np.errstate(all="ignore"):
                rng.set_seed(8)
                try:
                    r = ("ok", f())
                except Exception as e:      # noqa: BLE001
                    r = ("err", type(e).__name__, str(e))
                res.append((r, _state()))
        assert res[0][0][0] == res[1][0][0]
        if res[0][0][0] == "ok":
            _same(res[0][0][1], res[1][0][1])
        else:
            assert res[0][0] == res[1][0]
        _same_state(res[0][1], res[1][1])


@pytest.mark.skipif(not parallel.fork_available(), reason="ohne fork keine Kindprozesse")
def test_rng_kerne_in_kindprozessen(keep_rng):
    """cores = 2: Die Kinder ziehen mit eigenen Zuständen über die Erweiterung. Ergebnisse (auch
    .Random.seed am Ende jeder Einheit) und Zustand des Elternprozesses wie ohne Erweiterung; der
    Elternprozess ist danach unverändert (mc.set.seed = FALSE)."""
    _ext_or_skip()

    def unit(i):
        return (C.boot_idx_stationary(200, 300 + i, 7.0), truncnorm.rtruncnorm(20, -1.0, 1.0 + i),
                C.boot_wild(np.ones((30, 2)) + 0.01 * i, 2), rng.get_random_seed())
    out = {}
    rp0 = copy.deepcopy(rng._RP)
    for flag in (True, False):
        for kind in ("Mersenne-Twister", "L'Ecuyer-CMRG"):
            for cores in (1, 2):
                rng._RP.clear()
                rng._RP.update(copy.deepcopy(rp0))
                with env.use_ext(flag):
                    rng.set_seed(12, kind=kind)
                    rng.runif(3)
                    before = _state()
                    res = parallel.par_lapply(range(4), unit, cores=cores)
                    after = _state()
                    if cores == 2:
                        _same_state(before, after)
                    out[(flag, kind, cores)] = (res, after)
    for (flag, kind, cores), (res, st) in out.items():
        if flag:
            ref = out[(False, kind, cores)]
            _same(res, ref[0])
            _same_state(st, ref[1])
