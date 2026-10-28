"""``simlev._r.parallel.par_lapply`` (Etappe 5): Fork-Semantik von ``mclapply``.

Die Ergebnisse der Aufrufer prüfen die Referenzfälle mit ``cores = 2``; hier stehen die
Eigenschaften, die kein Fall abdeckt: Zufallszustand, Ausgabereihenfolge, Warnungen,
Fehler, nicht pickelbare Ergebnisse, Bitmuster von NA und der sequentielle Ersatzweg.
"""
import contextlib
import io
import struct
import sys
import time
import warnings

import numpy as np
import pandas as pd
import pytest

from simlev._r import parallel as P
from simlev._r import rng
from simlev._r.rlist import RList
from simlev._r.rnum import NA_REAL

FORK = P.fork_available()


def _bits(x):
    return struct.pack("<d", float(x)).hex()


@pytest.mark.parametrize("cores", [2, 3])
def test_rng_like_fork(cores):
    rng.set_seed(1)
    s0 = rng.get_random_seed()
    out = P.par_lapply(range(4), lambda i: rng.runif(1)[0], cores)
    assert len(set(out)) == 1                       # jedes Element startet mit dem Zustand des Aufrufers
    assert (rng.get_random_seed() == s0).all()      # Zustand danach unverändert
    rng.set_seed(1)
    seq = P.par_lapply(range(4), lambda i: rng.runif(1)[0], 1)
    assert out[0] == seq[0] and len(set(seq)) == 4  # cores = 1: fortlaufender Strom


def test_lapply_cases():
    rng.set_seed(3)
    a = P.par_lapply(range(3), lambda i: rng.runif(1)[0], 1.5)   # as.integer(1.5) = 1 -> lapply
    assert len(set(a)) == 3
    rng.set_seed(3)
    b = P.par_lapply([0], lambda i: rng.runif(1)[0], 4)          # ein Element -> lapply
    assert b[0] == a[0] and rng.get_random_seed() is not None
    assert P.par_lapply([], lambda i: i, 2) == []


def test_order_output_and_warnings():
    def f(i):
        if i == 0:
            time.sleep(0.2)
        print("out", i)
        sys.stderr.write("err %d\n" % i)
        warnings.warn("w%d" % i)
        return i * 10
    out, err = io.StringIO(), io.StringIO()
    with warnings.catch_warnings(record=True) as wl:
        warnings.simplefilter("always")
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            res = P.par_lapply(range(4), f, 2)
    assert res == [0, 10, 20, 30]
    assert out.getvalue() == "".join("out %d\n" % i for i in range(4))
    assert err.getvalue() == "".join("err %d\n" % i for i in range(4))
    assert wl == []                                 # Warnungen der Elemente gehen verloren


def test_first_error_in_order():
    def g(i):
        print("g", i)
        if i in (2, 4):
            raise ValueError("kaputt %d" % i)
        return i
    out = io.StringIO()
    with contextlib.redirect_stdout(out), pytest.raises(ValueError, match="kaputt 2"):
        P.par_lapply(range(6), g, 2)
    assert out.getvalue() == "g 0\ng 1\ng 2\n"


def test_values_bitwise_and_unpicklable():
    def h(i):
        return RList(a=np.array([NA_REAL, -0.0, np.nan]), b=pd.DataFrame({"x": [NA_REAL, 1.0]}),
                     c=pd.Series([NA_REAL], index=["q"]), d=NA_REAL, f=(lambda: i))
    res = P.par_lapply(range(3), h, 2)
    for i, r in enumerate(res):
        assert isinstance(r, RList) and r["f"]() == i
        assert [_bits(v) for v in r["a"]] == [_bits(NA_REAL), _bits(-0.0), _bits(np.nan)]
        assert _bits(r["b"]["x"].iloc[0]) == _bits(NA_REAL) and _bits(r["c"].iloc[0]) == _bits(NA_REAL)
        assert _bits(r["d"]) == _bits(NA_REAL)
    assert P.par_lapply(range(3), lambda i: None if i == 1 else i, 2) == [0, None, 2]


def test_nested_and_sequential_fallback(monkeypatch):
    rng.set_seed(5)
    nested = P.par_lapply(range(2), lambda i: P.par_lapply(range(2), lambda j: rng.runif(1)[0], 2), 2)
    assert len({v for row in nested for v in row}) == 1
    rng.set_seed(5)
    par = P.par_lapply(range(3), lambda i: (rng.runif(1)[0], rng.rnorm(2)), 2)
    monkeypatch.setattr(P, "fork_available", lambda: False)
    rng.set_seed(5)
    seq = P.par_lapply(range(3), lambda i: (rng.runif(1)[0], rng.rnorm(2)), 2)
    assert [(a, list(b)) for a, b in par] == [(a, list(b)) for a, b in seq]


@pytest.mark.skipif(not FORK, reason="ohne fork rechnet par_lapply sequentiell")
def test_really_parallel():
    t0 = time.perf_counter()
    P.par_lapply(range(2), lambda i: time.sleep(0.5), 2)
    assert time.perf_counter() - t0 < 0.9
