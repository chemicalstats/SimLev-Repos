"""Vergleich der Kerne core/slc_rbase*.c (über simlev._ext) mit den R-Ergebnissen aus rbase_fuzz.R;
seit 1.3.0 auch slc_rbase_num.c über seine Nutzer (R_strtod in RExpr, %% und %/%, format mit scientific()).

    Rscript tests/werkzeuge/gleichlauf/rbase_fuzz.R <ordner> [fälle]      # R als Orakel
    python3 tests/werkzeuge/gleichlauf/rbase_fuzz_cmp.py <ordner>         # Python (simlev._ext)
    julia --project=julia tests/werkzeuge/gleichlauf/rbase_fuzz_cmp.jl <ordner>   # Julia (libslc)
Bitgleich heißt: gleiche 64 Bit; NaN-Ergebnisse gelten als gleich, wenn beide NA (Nutzlast 1954) oder
beide NaN sind (Spalte nan_vz zählt NaN, die sich nur im Vorzeichenbit unterscheiden).
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "python"))
from simlev import _ext  # noqa: E402

D = sys.argv[1]


def reader(k):
    a = np.fromfile(os.path.join(D, k + ".bin"), dtype=np.float64)
    pos = [0]

    def nxt():
        n = a[pos[0]]
        pos[0] += 1
        if n < 0:
            return None
        n = int(n)
        v = a[pos[0]:pos[0] + n].copy()
        pos[0] += n
        return v

    def done():
        return pos[0] >= a.size
    return nxt, done


def isna(v):
    b = np.asarray(v, dtype=np.float64).view(np.uint64)
    return np.isnan(v) & ((b & np.uint64(0xFFFFFFFF)) == np.uint64(1954))


def same(a, b):
    """→ (gleich, nur NaN-Vorzeichen verschieden)"""
    a = np.asarray(a, dtype=np.float64).ravel()
    b = np.asarray(b, dtype=np.float64).ravel()
    if a.size != b.size:
        return False, False
    ba, bb = a.view(np.uint64), b.view(np.uint64)
    eq = ba == bb
    nan = np.isnan(a) & np.isnan(b)
    nan_ok = nan & (isna(a) == isna(b))
    ok = eq | nan_ok
    return bool(ok.all()), bool((nan_ok & ~eq).any())


stats = {}


def check(k, got, exp, info):
    s = stats.setdefault(k, [0, 0, 0, []])
    s[0] += 1
    if exp is None or got is None:
        ok = (exp is None) == (got is None)
        sg = False
    else:
        ok, sg = same(got, exp)
    if ok:
        s[2] += sg
    else:
        s[1] += 1
        if len(s[3]) < 5:
            s[3].append((info, got, exp))


def f(x):
    return np.ascontiguousarray(x, dtype=np.float64)


# 1 Summen
nxt, done = reader("sums")
while not done():
    x, narm = nxt(), bool(nxt()[0])
    rs = [nxt() for _ in range(8)]
    xn = f(x[~np.isnan(x)])
    check("sum", _ext.slc_r_sum(x, 0, narm), rs[0], x)
    check("prod", _ext.slc_r_sum(x, 1, narm), rs[1], x)
    check("mean", _ext.slc_r_sum(xn if narm else x, 2, 0), rs[2], x)
    check("var", _ext.slc_r_sum(xn, 3, 0), rs[3], x)
    for kind, nm in enumerate(("cumsum", "cumprod", "cummax", "cummin")):
        o = np.empty(x.size)
        _ext.slc_r_cum(kind, x, o)
        check(nm, o, rs[4 + kind], x)
nxt, done = reader("meanint")
while not done():
    x, r = nxt(), nxt()
    check("mean_int", _ext.slc_r_mean_int(np.ascontiguousarray(x, dtype=np.int64)), r, x)
nxt, done = reader("margins")
while not done():
    nr, nc, x, narm = int(nxt()[0]), int(nxt()[0]), nxt(), bool(nxt()[0])
    rs = [nxt() for _ in range(4)]
    for i, (rows, mean, nm) in enumerate(((0, 0, "colSums"), (0, 1, "colMeans"), (1, 0, "rowSums"), (1, 1, "rowMeans"))):
        o = np.empty(nr if rows else nc)
        _ext.slc_r_margsums(x, nr, nc, narm, bool(mean), bool(rows), o)
        check(nm, o, rs[i], (nr, nc, x, narm))
nxt, done = reader("pow")
while not done():
    x, y, r = nxt(), nxt()[0], nxt()
    o = np.empty(x.size)
    _ext.slc_r_pow(x, float(y), o)
    check("pow", o, r, (x, y))
nxt, done = reader("order")
while not done():
    nk = int(nxt()[0]); keys = nxt(); dec = nxt(); nl = int(nxt()[0]); r = nxt()
    n = keys.size // nk
    o = np.empty(n, dtype=np.int64)
    m = _ext.slc_r_order(keys, n, nk, np.ascontiguousarray(dec, dtype=np.int32), nl, o)
    check("order", o[:m].astype(np.float64), r, (keys, dec, nl))
nxt, done = reader("rank")
while not done():
    x, t, r = nxt(), int(nxt()[0]), nxt()
    o = np.empty(x.size)
    _ext.slc_r_rank(x, t, o)
    check("rank", o, r, (x, t))
nxt, done = reader("psort")
while not done():
    x, k, r = nxt(), nxt(), nxt()
    v = x.copy()
    _ext.slc_r_psort(v, np.ascontiguousarray(k, dtype=np.int64))
    check("psort", v, r, (x, k))
nxt, done = reader("quantile")
while not done():
    x, p, t, r = nxt(), nxt(), int(nxt()[0]), nxt()
    o = np.empty(p.size)
    _ext.slc_r_quantile(x, p, t, o)
    check("quantile", o, r, (x, p, t))
nxt, done = reader("tabulate")
while not done():
    b, nb, r = nxt(), int(nxt()[0]), nxt()
    o = np.zeros(nb, dtype=np.int64)
    _ext.slc_r_tabulate(b, o)
    check("tabulate", o.astype(np.float64), r, (b, nb))
nxt, done = reader("findint")
while not done():
    v, x, fl, r = nxt(), nxt(), nxt(), nxt()
    o = np.empty(x.size)
    _ext.slc_r_findinterval(v, x, bool(fl[0]), bool(fl[1]), bool(fl[2]), o)
    check("findInterval", o, r, (v, x, fl))
nxt, done = reader("cov")
while not done():
    n, ncx, x, ncy, y = int(nxt()[0]), int(nxt()[0]), nxt(), int(nxt()[0]), nxt()
    use, kend, cr = int(nxt()[0]), int(nxt()[0]), int(nxt()[0])
    r = nxt()
    hasy = ncy > 0
    got = None
    if not (x.size == 0 and use not in (4, 5)):
        a = np.empty(ncx * (ncy if hasy else ncx))
        try:
            _ext.slc_r_cov(x, n, ncx, y if hasy else None, ncy, use, kend, cr, a)
            got = a
        except ValueError:
            got = None
    check("cov" + ("_kendall" if kend else "") + ("_cor" if cr else ""), got, r, (n, ncx, x, ncy, y, use))

# 12 (seit 1.3.0) Nutzer von slc_rbase_num.c: R_strtod (as.numeric), %% und %/%, format (scientific())
if os.path.exists(os.path.join(D, "strtod.bin")):
    import warnings
    from simlev._r import fmt as _fmt, rexpr as _rexpr, rformat as _rformat
    nxt, done = reader("strtod")
    while not done():
        s, r = "".join(chr(int(c)) for c in nxt()), nxt()
        check("as.numeric", [_rexpr._str2num(s)[0]], r, s)
    if os.path.exists(os.path.join(D, "strtod_long.bin")):
        nxt, done = reader("strtod_long")
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            while not done():
                s, r, w = "".join(chr(int(c)) for c in nxt()), nxt(), nxt()
                v, bad = _rexpr._str2num(s)
                check("as.numeric lang (RExpr)", [v, float(bad)], np.concatenate([r, w]), s)
                z, na_, nan_, bad = _fmt._r_strtod(s)
                check("as.numeric lang (fmt)", [_rexpr.NA_REAL if na_ else z, float(bad)], np.concatenate([r, w]), s)
    nxt, done = reader("mod")
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        while not done():
            x, y, r1, r2 = nxt()[0], nxt()[0], nxt(), nxt()
            g1 = np.array([_rexpr.r_fmod(float(x), float(y))])
            check("%%", g1, r1, (x, y))
            # %% streng (alle 64 Bit, auch Vorzeichen und Nutzlast eines NaN)
            st = stats.setdefault("%% streng", [0, 0, 0, []])
            st[0] += 1
            if g1.view(np.uint64)[0] != np.asarray(r1, dtype=np.float64).view(np.uint64)[0]:
                st[1] += 1
                if len(st[3]) < 5:
                    st[3].append(((x, y), g1, r1))
            check("%/%", [_rexpr.r_idiv(float(x), float(y))], r2, (x, y))
    nxt, done = reader("format")
    nfmt = [0, 0, 0, []]
    while not done():
        x, dg, r = nxt(), int(nxt()[0]), "".join(chr(int(c)) for c in nxt())
        for nm, g in (("format (fmt)", "|".join(_fmt.format(x, digits=dg))),
                      ("format (rformat)", "|".join(_rformat.r_format([float(v) for v in x], digits=dg)))):
            s = stats.setdefault(nm, [0, 0, 0, []])
            s[0] += 1
            if g != r:
                s[1] += 1
                if len(s[3]) < 5:
                    s[3].append(((x.tolist(), dg), g, r))

tot_bad = 0
for k, (n, bad, sg, ex) in stats.items():
    tot_bad += bad
    print("%-14s %6d Fälle, %d abweichend, %d nur NaN-Vorzeichen" % (k, n, bad, sg))
    for e in ex[:2]:
        print("    Beispiel:", e)
print("GESAMT", "ok" if tot_bad == 0 else "%d ABWEICHUNGEN" % tot_bad)
sys.exit(1 if tot_bad else 0)
