"""Interpolation, Filter, Fourier-Transformation, Kerndichte und Glättungssplines (``approx``, ``approxfun``,
``filter``, ``fft``, ``bw.nrd0``, ``density``, ``smooth.spline``, ``predict.smooth.spline``), nachgebildet aus
R 4.3.3 ``stats/R/approx.R``, ``filter.R``, ``fft.R``, ``bandwidths.R``, ``density.R``, ``smspline.R`` und
``stats/src/approx.c``, ``filter.c``, ``fourier.c``, ``massdist.c``, ``sbart.c``.
"""
from __future__ import annotations

import math

import numpy as np
import pandas as pd

from .linalg import RError
from .rlist import RList
from .rnum import NA_REAL
from .stats_sort import _NAN, _rmean, _rsum, _vec, _warn, quantile, seq_len_out, weighted_mean
from .stats_cor import sd, var

__all__ = [
    "SmoothSpline", "approx", "approxfun", "filter", "smooth_spline", "predict_smooth_spline",
    "density", "bw_nrd0", "fft",
]


# ── approx / filter ──────────────────────────────────────────────────────

def _regularize(x, y, ties, warn_collapsing, na_rm):
    xv, _ = _vec(x)
    if y is None:
        yv = xv
        xv = np.arange(1, xv.size + 1, dtype=np.float64)
    else:
        yv, _ = _vec(y)
    if xv.size != yv.size:
        raise RError("'x' and 'y' lengths differ")
    kept_na = False
    na = np.isnan(xv) | np.isnan(yv)
    ok = ~na
    if na.any():
        if na_rm:
            xv = xv[ok]
            yv = yv[ok]
            nx = xv.size
        else:
            kept_na = True
            nx = int(ok.sum())
    else:
        nx = xv.size
    ordered = False
    fun = ties
    if isinstance(ties, str) and ties == "ordered":
        ordered = True
        fun = None
    elif isinstance(ties, (list, tuple)) and len(ties) == 2 and callable(ties[1]):
        fun = ties[1]
        ordered = ties[0] == "ordered"
    if not (isinstance(ties, str) and ties == "ordered"):
        xx = xv[ok] if kept_na else xv
        if not ordered and xx.size > 1 and (np.diff(xx) < 0).any():
            o = np.argsort(xv, kind="stable")
            xv = xv[o]
            yv = yv[o]
        ux = pd.unique(xv)
        if ux.size < nx:
            if warn_collapsing:
                _warn("collapsing to unique 'x' values")
            if fun is None or fun is _rmean or fun == "mean":
                f = _rmean
            else:
                f = fun
            groups = {}
            keys = []
            for xi, yi in zip(xv.tolist(), yv.tolist()):
                k = xi if xi == xi else "NA"
                if k not in groups:
                    groups[k] = []
                    keys.append(k)
                groups[k].append(yi)
            yv = np.array([float(f(np.array(groups[k]))) for k in keys])
            xv = np.asarray(ux, dtype=np.float64)
            if kept_na:
                ok = ~np.isnan(xv)
    return xv, yv, kept_na, (ok if kept_na else None)


def _approx_core(x, y, v, method, yleft, yright, f):
    n = x.size
    out = np.empty(v.size)
    if n == 0:
        out[:] = np.nan
        return out
    f2 = f
    f1 = 1 - f
    with np.errstate(all="ignore"):
        for k, vk in enumerate(v.tolist()):
            if vk != vk:
                out[k] = vk
                continue
            i = 0
            j = n - 1
            if vk < x[i]:
                out[k] = yleft
                continue
            if vk > x[j]:
                out[k] = yright
                continue
            while i < j - 1:
                ij = (i + j) // 2
                if vk < x[ij]:
                    j = ij
                else:
                    i = ij
            if vk == x[j]:
                out[k] = y[j]
                continue
            if vk == x[i]:
                out[k] = y[i]
                continue
            if method == 1:
                out[k] = y[i] + (y[j] - y[i]) * ((vk - x[i]) / (x[j] - x[i]))
            else:
                out[k] = (y[i] * f1 if f1 != 0.0 else 0.0) + (y[j] * f2 if f2 != 0.0 else 0.0)
    return out


def _approx_setup(x, y, method, yleft, yright, rule, f, ties, na_rm, ties_missing):
    meth = {"linear": 1, "constant": 2}
    m = [v for k, v in meth.items() if k.startswith(method)] if method else []
    if len(m) != 1:
        raise RError("invalid interpolation method")
    method = m[0]
    rule = list(np.atleast_1d(rule))
    if len(rule) == 1:
        rule = rule * 2
    xv, yv, kept_na, notna = _regularize(x, y, ties, ties_missing, na_rm)
    nona = na_rm or not kept_na
    nx = xv.size if nona else int(notna.sum())
    if nx <= 1:
        if method == 1:
            raise RError("need at least two non-NA values to interpolate")
        if nx == 0:
            raise RError("zero non-NA points")
    if yleft is None:
        yleft = NA_REAL if rule[0] == 1 else float(yv[0])
    if yright is None:
        yright = NA_REAL if rule[1] == 1 else float(yv[-1])
    if method == 2:
        if not math.isfinite(f) or f < 0 or f > 1:
            raise RError("approx(): invalid f value")
    if na_rm:
        if np.isnan(xv).any() or np.isnan(yv).any():
            raise RError("approx(): attempted to interpolate NA values")
    else:
        if np.isnan(xv).any():
            raise RError("approx(x,y, .., na.rm=FALSE): NA values in x are not allowed")
    return xv, yv, method, float(yleft), float(yright), nona, notna, nx


class _XY(RList):
    pass


def approx(x, y=None, xout=None, method="linear", n=50, yleft=None, yright=None, rule=1, f=0,
           ties=None, na_rm=True):
    """``approx(x, y, xout, method, n, yleft, yright, rule, f, ties, na.rm)``.

    ``ties=None`` entspricht R's Voreinstellung ``mean`` (mit Warnung beim
    Zusammenfassen); ``"ordered"``, eine Funktion oder ``("ordered", fun)``.
    Ergebnis: ``RList`` mit ``x`` und ``y``.
    """
    ties_missing = ties is None
    xv, yv, meth, yl, yr, nona, notna, nx = _approx_setup(
        x, y, method, yleft, yright, rule, float(f), _rmean if ties is None else ties, na_rm, ties_missing)
    if xout is None:
        if n <= 0:
            raise RError("'approx' requires n >= 1")
        if nona:
            xo = seq_len_out(xv[0], xv[nx - 1], n)
        else:
            xs = xv[notna]
            xo = seq_len_out(xs[0], xs[-1], n)
    else:
        xo, _ = _vec(xout)
    res = _XY()
    res["x"] = xo if xout is None else (xout if not np.isscalar(xout) else float(xout))
    yo = _approx_core(xv, yv, xo, meth, yl, yr, float(f))
    res["y"] = float(yo[0]) if np.isscalar(xout) else yo
    return res


def approxfun(x, y=None, method="linear", yleft=None, yright=None, rule=1, f=0, ties=None, na_rm=True):
    """``approxfun(...)``: liefert eine Funktion ``v -> y``."""
    ties_missing = ties is None
    xv, yv, meth, yl, yr, nona, notna, nx = _approx_setup(
        x, y, method, yleft, yright, rule, float(f), _rmean if ties is None else ties, na_rm, ties_missing)
    ff = float(f)

    def fun(v):
        vv, _ = _vec(v)
        out = _approx_core(xv, yv, vv, meth, yl, yr, ff)
        if np.isscalar(v):
            return float(out[0])
        return out
    fun.x = xv
    fun.y = yv
    return fun


def filter(x, filter, method="convolution", sides=2, circular=False, init=None):
    """``filter(x, filter, method, sides, circular, init)`` (ohne ts-Attribute)."""
    meth = [m for m in ("convolution", "recursive") if m.startswith(method)]
    if len(meth) != 1:
        raise RError("'arg' should be one of “convolution”, “recursive”")
    method = meth[0]
    X = np.asarray(x.to_numpy() if isinstance(x, (pd.Series, pd.DataFrame)) else x, dtype=np.float64)
    is_mat = X.ndim == 2
    if not is_mat:
        X = X.reshape(-1, 1)
    n, nser = X.shape
    fv = np.atleast_1d(np.asarray(filter, dtype=np.float64)).ravel()
    nf = fv.size
    if np.isnan(fv).any():
        raise RError("missing values in 'filter'")
    Y = np.full((n, nser), NA_REAL)
    with np.errstate(all="ignore"):
        if method == "convolution":
            if nf > n:
                raise RError("'filter' is longer than time series")
            sides = int(sides)
            if sides not in (1, 2):
                raise RError("argument 'sides' must be 1 or 2")
            nshift = nf // 2 if sides == 2 else 0
            for s in range(nser):
                xs = X[:, s]
                if not circular:
                    i = np.arange(n)
                    valid = (i + nshift - (nf - 1) >= 0) & (i + nshift < n)
                    iv = i[valid]
                    z = np.zeros(iv.size)
                    bad = np.zeros(iv.size, dtype=bool)
                    for j in range(nf):
                        t = xs[iv + nshift - j]
                        bad |= np.isnan(t)
                        z = z + fv[j] * t
                    z[bad] = NA_REAL
                    Y[iv, s] = z
                else:
                    i = np.arange(n)
                    z = np.zeros(n)
                    bad = np.zeros(n, dtype=bool)
                    for j in range(nf):
                        ii = i + nshift - j
                        ii = np.where(ii < 0, ii + n, ii)
                        ii = np.where(ii >= n, ii - n, ii)
                        t = xs[ii]
                        bad |= np.isnan(t)
                        z = z + fv[j] * t
                    z[bad] = NA_REAL
                    Y[:, s] = z
        else:
            if init is None:
                ini = np.zeros((nf, nser))
            else:
                ia = np.asarray(init, dtype=np.float64)
                ni = ia.shape[0] if ia.ndim >= 1 else 1
                if ia.ndim == 0:
                    ia = ia.reshape(1)
                    ni = 1
                if ni != nf:
                    raise RError("length of 'init' must equal length of 'filter'")
                ncol = ia.shape[1] if ia.ndim == 2 else 1
                if ncol != 1 and ncol != nser:
                    if nser == 1:
                        raise RError("'init' must have %d column" % nser)
                    raise RError("'init' must have 1 or %d columns" % nser)
                ini = ia.reshape(nf, -1) if ia.ndim == 2 else ia.reshape(nf, 1)
                if ini.shape[1] == 1 and nser > 1:
                    ini = np.repeat(ini, nser, axis=1)
            for s in range(nser):
                r = np.concatenate([ini[::-1, s], np.zeros(n)]).tolist()
                xs = X[:, s].tolist()
                fl = fv.tolist()
                for i in range(n):
                    sm = xs[i]
                    if sm != sm:
                        r[nf + i] = NA_REAL
                        continue
                    badf = False
                    for j in range(nf):
                        tmp = r[nf + i - j - 1]
                        if tmp == tmp:
                            sm += tmp * fl[j]
                        else:
                            r[nf + i] = NA_REAL
                            badf = True
                            break
                    if not badf:
                        r[nf + i] = sm
                Y[:, s] = r[nf:]
    if is_mat:
        return Y
    return Y[:, 0]


# ── fft / density ────────────────────────────────────────────────────────

def fft(z, inverse=False):
    """``fft(z, inverse)`` (R's gemischte Basis); Ergebnis ``complex128``-Array
    gleicher Form (Matrizen: räumliche Transformation wie R)."""
    from ._fft import fft_vec
    a = np.asarray(z)
    if a.dtype.kind not in "biufc":
        raise RError("non-numeric argument")
    shape = a.shape
    flat = a.ravel(order="F")
    re = np.real(flat).astype(np.float64)
    im = np.imag(flat).astype(np.float64) if np.iscomplexobj(flat) else np.zeros(flat.size)
    dims = list(shape) if a.ndim >= 2 else None
    r, i = fft_vec(re, im, bool(inverse), dims)
    out = np.array(r, dtype=np.float64) + 1j * np.array(i, dtype=np.float64)
    out = np.empty(len(r), dtype=np.complex128)
    out.real = r
    out.imag = i
    return out.reshape(shape, order="F") if a.ndim >= 1 else out[0]


def _cmul_conj(ar, ai, br, bi):
    """(a) * Conj(b) wie C99-Komplexmultiplikation (ohne FMA)."""
    cr = br
    ci = -bi
    re = ar * cr - ai * ci
    im = ar * ci + ai * cr
    return re, im


def bw_nrd0(x):
    """``bw.nrd0(x)``."""
    from .rnum import r_pow
    xv, _ = _vec(x)
    if xv.size < 2:
        raise RError("need at least 2 data points")
    hi = sd(xv)
    q = quantile(xv, [0.25, 0.75], names=False)
    iqr = float(q[1] - q[0])
    lo = min(hi, iqr / 1.34) if not (hi != hi) else hi
    if hi == hi and (iqr / 1.34) != (iqr / 1.34):
        lo = _NAN
    if not lo:
        lo = hi
        if not lo:
            lo = abs(float(xv[0]))
            if not lo:
                lo = 1.0
    return 0.9 * lo * r_pow(float(xv.size), -0.2)


class _Density(RList):
    r_class = ("density",)


def density(x, bw="nrd0", adjust=1, kernel="gaussian", weights=None, n=512, from_=None, to=None,
            cut=3, na_rm=False, **kw):
    """``density.default(x, bw, adjust, kernel, weights, n, from, to, cut, na.rm)``.

    ``from`` heißt hier ``from_`` (auch ``**{"from": ...}`` möglich).
    Ergebnis ``RList`` (Klasse ``density``) mit ``x``, ``y``, ``bw``, ``n``.
    """
    from . import nmath as NM
    from .rnum import r_pow
    if "from" in kw:
        from_ = kw.pop("from")
    kernels = ["gaussian", "epanechnikov", "rectangular", "triangular", "biweight", "cosine", "optcosine"]
    km = [k for k in kernels if k.startswith(kernel)]
    if len(km) != 1:
        raise RError("'arg' should be one of " + ", ".join("“%s”" % k for k in kernels))
    kernel = km[0]
    xv, _ = _vec(x)
    N = xv.size
    has_wts = weights is not None
    if has_wts:
        wv, _ = _vec(weights)
        if wv.size != N:
            raise RError("'x' and 'weights' have unequal length")
    xna = np.isnan(xv)
    if xna.any():
        if na_rm:
            xv = xv[~xna]
            N = xv.size
            if has_wts:
                from .linalg import all_equal_numeric
                trueD = all_equal_numeric(1.0, _rsum(wv)) is True
                wv = wv[~xna]
                if trueD:
                    wv = wv / _rsum(wv)
        else:
            raise RError("'x' contains missing values")
    nx = N
    xfin = np.isfinite(xv)
    if not xfin.all():
        xv = xv[xfin]
        nx = xv.size
    if not has_wts:
        wv = np.full(nx, 1.0 / nx) if nx else np.zeros(0)
        totMass = nx / N
    else:
        if not np.isfinite(wv).all():
            raise RError("'weights' must all be finite")
        if (wv < 0).any():
            raise RError("'weights' must not be negative")
        wsum = _rsum(wv)
        if not xfin.all():
            wv = wv[xfin]
            totMass = _rsum(wv) / wsum
        else:
            totMass = 1.0
        from .linalg import all_equal_numeric
        if all_equal_numeric(1.0, wsum) is not True:
            _warn("sum(weights) != 1  -- will not get true density")
    n_user = int(n)
    n = max(n_user, 512)
    if n > 512:
        n = int(r_pow(2.0, math.ceil(math.log2(n))))
    if isinstance(bw, str):
        if nx < 2:
            raise RError("need at least 2 points to select a bandwidth automatically")
        if has_wts and var(wv) > 0:
            _warn("Selecting bandwidth *not* using 'weights'")
        if bw.lower() != "nrd0":
            raise NotImplementedError("density(): nur bw = 'nrd0' ist portiert")
        bw = bw_nrd0(xv)
    bw = float(bw)
    if not math.isfinite(bw):
        raise RError("non-finite 'bw'")
    bw = adjust * bw
    if bw <= 0:
        raise RError("'bw' is not positive.")
    if from_ is None:
        from_ = float(xv.min()) - cut * bw
    if to is None:
        to = float(xv.max()) + cut * bw
    if not math.isfinite(from_):
        raise RError("non-finite 'from'")
    if not math.isfinite(to):
        raise RError("non-finite 'to'")
    lo = from_ - 4 * bw
    up = to + 4 * bw
    y = _bindist(xv, wv, lo, up, n) * totMass
    kords = seq_len_out(0.0, 2 * (up - lo), 2 * n)
    kords[n + 1:2 * n] = -kords[n - 1:0:-1]
    with np.errstate(all="ignore"):
        if kernel == "gaussian":
            kords = np.asarray(NM.dnorm(kords, sd=bw), dtype=np.float64)
        elif kernel == "rectangular":
            a = bw * math.sqrt(3)
            kords = np.where(np.abs(kords) < a, 0.5 / a, 0.0)
        elif kernel == "triangular":
            a = bw * math.sqrt(6)
            ax = np.abs(kords)
            kords = np.where(ax < a, (1 - ax / a) / a, 0.0)
        elif kernel == "epanechnikov":
            a = bw * math.sqrt(5)
            ax = np.abs(kords)
            q = ax / a
            kords = np.where(ax < a, 3 / 4 * (1 - q * q) / a, 0.0)
        elif kernel == "biweight":
            a = bw * math.sqrt(7)
            ax = np.abs(kords)
            q = ax / a
            t = 1 - q * q
            kords = np.where(ax < a, 15 / 16 * (t * t) / a, 0.0)
        elif kernel == "cosine":
            a = bw / math.sqrt(1 / 3 - 2 / (math.pi * math.pi))
            c = np.array([math.cos(v) for v in (math.pi * kords / a).tolist()])
            kords = np.where(np.abs(kords) < a, (1 + c) / (2 * a), 0.0)
        else:
            a = bw / math.sqrt(1 - 8 / (math.pi * math.pi))
            c = np.array([math.cos(v) for v in (math.pi * kords / (2 * a)).tolist()])
            kords = np.where(np.abs(kords) < a, math.pi / 4 * c / a, 0.0)
        fy = fft(y)
        fk = fft(kords)
        re, im = _cmul_conj(fy.real.copy(), fy.imag.copy(), fk.real.copy(), fk.imag.copy())
        prod = np.empty(re.size, dtype=np.complex128)
        prod.real = re
        prod.imag = im
        kk = fft(prod, inverse=True)
        kv = kk.real[:n] / y.size
        kv = np.where(np.isnan(kv), kv, np.maximum(0.0, kv))
    xords = seq_len_out(lo, up, n)
    xo = seq_len_out(from_, to, n_user)
    res = _Density()
    res["x"] = xo
    res["y"] = approx(xords, kv, xout=xo)["y"]
    res["bw"] = bw
    res["n"] = N
    res["call"] = None
    res["data.name"] = "x"
    res["has.na"] = False
    return res


def _bindist(x, w, xlo, xhi, n):
    y = [0.0] * (2 * n)
    ixmin = 0
    ixmax = n - 2
    xdelta = (xhi - xlo) / (n - 1)
    for xi, wi in zip(x.tolist(), w.tolist()):
        if math.isfinite(xi):
            xpos = (xi - xlo) / xdelta
            if xpos > 2147483647 or xpos < -2147483648:
                continue
            ix = int(math.floor(xpos))
            fx = xpos - ix
            if ixmin <= ix <= ixmax:
                y[ix] += (1 - fx) * wi
                y[ix + 1] += fx * wi
            elif ix == -1:
                y[0] += fx * wi
            elif ix == ixmax + 1:
                y[ix] += (1 - fx) * wi
    return np.array(y)


# ── smooth.spline ────────────────────────────────────────────────────────

class SmoothSpline(RList):
    r_class = ("smooth.spline",)


class _SmoothSplineFit(RList):
    r_class = ("smooth.spline.fit",)


def _nknots_smspl(n):
    from .rnum import r_pow
    if n < 50:
        return n
    a1 = math.log2(50)
    a2 = math.log2(100)
    a3 = math.log2(140)
    a4 = math.log2(200)
    if n < 200:
        v = r_pow(2.0, a1 + (a2 - a1) * (n - 50) / 150)
    elif n < 800:
        v = r_pow(2.0, a2 + (a3 - a2) * (n - 200) / 600)
    elif n < 3200:
        v = r_pow(2.0, a3 + (a4 - a3) * (n - 800) / 2400)
    else:
        v = 200 + r_pow(float(n - 3200), 0.2)
    return int(math.trunc(v))


def smooth_spline(x, y=None, w=None, df=None, spar=None, lambda_=None, cv=False, all_knots=False,
                  nknots=None, keep_data=True, df_offset=0, penalty=1, control_spar=None, tol=None,
                  keep_stuff=False, **kw):
    """``smooth.spline(x, y, w, df, spar, lambda, cv, all.knots, nknots, ...)``.

    ``lambda`` heißt ``lambda_`` (oder ``**{"lambda": ...}``); ``cv=None``
    entspricht ``cv = NA``. Ergebnis :class:`SmoothSpline` wie R; Vorhersage
    mit :func:`predict_smooth_spline`.
    """
    from ._sbart import sbart
    if "lambda" in kw:
        lambda_ = kw.pop("lambda")
    contr = {"low": -1.5, "high": 1.5, "tol": 1e-4, "eps": 2e-8, "maxit": 500, "trace": False}
    if control_spar:
        contr.update(control_spar)
    if contr["tol"] < 0 or contr["eps"] <= 0 or contr["maxit"] <= 0:
        raise RError("invalid 'control.spar'")
    xv, _ = _vec(x)
    if y is None:
        yv = xv
        xv = np.arange(1, xv.size + 1, dtype=np.float64)
    else:
        yv, _ = _vec(y)
        if yv.size != xv.size:
            raise RError("'x' and 'y' lengths differ")
    if not (np.isfinite(xv).all() and np.isfinite(yv).all()):
        raise RError("missing or infinite values in inputs are not allowed")
    n = xv.size
    no_wgts = w is None
    if no_wgts:
        wv = None
    else:
        wv, _ = _vec(w)
        if n != wv.size:
            raise RError("lengths of 'x' and 'w' must match")
        if (wv < 0).any():
            raise RError("all weights should be non-negative")
        if (wv == 0).all():
            raise RError("some weights should be positive")
        wv = (wv * float((wv > 0).sum())) / _rsum(wv)
    if tol is None:
        q = quantile(xv, [0.25, 0.75], names=False)
        tol = 1e-6 * float(q[1] - q[0])
    if not math.isfinite(tol) or tol <= 0:
        raise RError("'tol' must be strictly positive and finite")
    with np.errstate(all="ignore"):
        xx = np.rint((xv - _rmean(xv)) / tol)
    uns = n > 1 and bool((np.diff(xv) < 0).any())
    iOx = np.argsort(xv, kind="stable") if uns else np.arange(n)
    xxs = xx[iOx]
    nd = np.concatenate([[True], xxs[:-1] < xxs[1:]])
    ux = xv[iOx][nd]
    nx = ux.size
    if nx <= 3:
        raise RError("need at least four unique 'x' values")
    if nx == n:
        if uns:
            ox = np.empty(n, dtype=np.int64)
            ox[iOx] = np.arange(n)
        else:
            ox = np.arange(n)
        if no_wgts:
            tmp = np.column_stack([np.ones(n), 1 * yv, 1 * (yv * yv)])[iOx]
        else:
            tmp = np.column_stack([wv, wv * yv, wv * (yv * yv)])[iOx]
    else:
        ukeys = xxs[nd]
        ox = np.searchsorted(ukeys, xx)
        rows = []
        for g in range(nx):
            idx = np.where(ox == g)[0]
            if no_wgts:
                rows.append([float(idx.size), _rsum(yv[idx]), _rsum(yv[idx] * yv[idx])])
            else:
                rows.append([_rsum(wv[idx]), _rsum(wv[idx] * yv[idx]), _rsum(wv[idx] * (yv[idx] * yv[idx]))])
        tmp = np.array(rows)
    wbar = tmp[:, 0].copy()
    with np.errstate(all="ignore"):
        ybar = tmp[:, 1] / np.where(wbar > 0, wbar, 1.0)
        yssw = _rsum(tmp[:, 2] - wbar * (ybar * ybar))
    if cv is None and df is not None:
        raise RError("'cv' must not be NA when 'df' is specified")
    CV = cv is not None and bool(cv)
    if CV and nx < n:
        _warn("cross-validation with non-unique 'x' values seems doubtful")
    r_ux = ux[nx - 1] - ux[0]
    xbar = (ux - ux[0]) / r_ux
    if not isinstance(all_knots, (bool, np.bool_)):
        ak = np.asarray(all_knots, dtype=np.float64)
        if ak.size > 1 and (np.diff(ak) <= 0).any():
            raise RError("Numeric 'all.knots' must be strictly increasing")
        if nknots is not None:
            _warn("'all.knots' is vector of knots; 'nknots' specification is disregarded")
        nknots = ak.size
        if 0 < ak[0] or ak[-1] < 1:
            raise RError("numeric 'all.knots' must cover [0,1] (= the transformed data-range)")
        knot = np.concatenate([[ak[0]] * 3, ak, [ak[-1]] * 3])
    else:
        if all_knots:
            if nknots is not None:
                _warn("'all.knots' is TRUE; 'nknots' specification is disregarded")
            nknots = nx
        elif nknots is None:
            nknots = _nknots_smspl(nx)
        else:
            if callable(nknots):
                nknots = nknots(nx)
            if nknots < 1:
                raise RError("'nknots' must be at least 1")
            elif nknots > nx:
                raise RError("cannot use more inner knots than unique 'x' values")
        nknots = int(nknots)
        if all_knots:
            inner = xbar
        else:
            idx = seq_len_out(1, nx, nknots)
            inner = xbar[np.trunc(idx).astype(np.int64) - 1]
        knot = np.concatenate([[xbar[0]] * 3, inner, [xbar[nx - 1]] * 3])
    nk = nknots + 2
    spar_is_lambda = lambda_ is not None
    if spar_is_lambda:
        if spar is not None:
            raise RError("must not specify both 'spar' and 'lambda'")
        ispar = 1
    else:
        ispar = (-1 if contr["trace"] else 0) if spar is None else 1
    sparv = float(lambda_) if spar_is_lambda else (float(spar) if ispar == 1 else 0.0)
    icrit = 0 if cv is None else (2 if cv else 1)
    dofoff = float(df_offset)
    if df is not None:
        if 1 < df <= nx:
            icrit = 3
            dofoff = float(df)
        else:
            _warn("not using invalid df; must have 1 < df <= n := #{unique x} = %d" % nx)
    isetup = 2 if spar_is_lambda else 0
    with np.errstate(all="ignore"):
        fit = sbart(float(penalty), dofoff, [0.0] + xbar.tolist(), [0.0] + ybar.tolist(),
                    [0.0] + wbar.tolist(), yssw, nx, [0.0] + knot.tolist(), nk, icrit, sparv, ispar,
                    int(contr["maxit"]), float(contr["low"]), float(contr["high"]), float(contr["tol"]),
                    float(contr["eps"]), isetup)
    ty = np.array(fit["sz"][1:])
    if cv is None:
        lev = NA_REAL
        dfv = NA_REAL
    else:
        lev = np.array(fit["lev"][1:])
        dfv = _rsum(lev)
        if dfv != dfv:
            raise RError("NA lev[]; probably smoothing parameter 'spar' way too large!")
    if fit["ier"] > 0:
        sml = (not spar_is_lambda) and fit["spar"] < 0.5
        kind = "extreme" if spar_is_lambda else ("small" if sml else "large")
        wtxt = "smoothing parameter value too " + kind
        if spar_is_lambda or sml:
            raise RError(wtxt)
        ty = np.full(nx, _rmean(yv))
        dfv = 1.0
        _warn(wtxt + "\nsetting df = 1  __use with care!__")
    with np.errstate(all="ignore"):
        if cv is None:
            cvcrit = NA_REAL
        else:
            r = yv - ty[ox]
            if CV:
                ww = wbar.copy()
                ww[ww == 0] = 1
                wfac = 1.0 if no_wgts else wv
                r = r / (1 - (lev[ox] * wfac) / ww[ox])
                cvcrit = _rmean(r * r) if no_wgts else weighted_mean(r * r, wv)
            else:
                base = _rmean(r * r) if no_wgts else weighted_mean(r * r, wv)
                t = 1 - (df_offset + penalty * dfv) / n
                cvcrit = base / (t * t)
        d = ybar - ty
        pen = _rsum(wbar * (d * d))
    res = SmoothSpline()
    res["x"] = ux
    res["y"] = ty
    res["w"] = wbar
    res["yin"] = ybar
    res["tol"] = tol
    res["data"] = {"x": xv, "y": yv, "w": 1.0 if no_wgts else wv} if keep_data else None
    res["no.weights"] = no_wgts
    res["n"] = n
    res["lev"] = lev
    res["cv"] = cv
    res["cv.crit"] = cvcrit
    res["pen.crit"] = pen
    res["crit"] = fit["crit"]
    res["df"] = dfv
    res["spar"] = NA_REAL if spar_is_lambda else fit["spar"]
    res["ratio"] = NA_REAL if spar_is_lambda else fit["ratio"]
    res["lambda"] = fit["lspar"]
    res["iparms"] = pd.Series([float(icrit), float(ispar), float(fit["iter"] if ispar != 1 else contr["maxit"]),
                               float(spar_is_lambda), float(fit["ier"]) if fit["ier"] else NA_REAL],
                              index=["icrit", "ispar", "iter", "", "errorI"])
    res["auxM"] = None
    f = _SmoothSplineFit()
    f["knot"] = knot
    f["nk"] = nk
    f["min"] = float(ux[0])
    f["range"] = float(r_ux)
    f["coef"] = np.array(fit["coef"][1:])
    res["fit"] = f
    res["call"] = None
    return res


def _predict_ssfit(obj, x=None, deriv=0):
    from ._sbart import bvalus
    from .rnum import r_pow
    if x is None:
        x = seq_len_out(obj["min"], obj["min"] + obj["range"], len(obj["coef"]) - 4)
    xv, _ = _vec(x)
    with np.errstate(all="ignore"):
        xs = (xv - obj["min"]) / obj["range"]
    el = xs < 0
    er = xs > 1
    ex = el | er
    interp = ~ex
    y = xs.copy()
    if interp.any():
        knot = [0.0] + list(np.asarray(obj["knot"], dtype=np.float64))
        coef = [0.0] + list(np.asarray(obj["coef"], dtype=np.float64))
        y[interp] = bvalus(knot, coef, int(obj["nk"]), xs[interp].tolist(), int(deriv))
    if ex.any():
        xrange = np.array([obj["min"], obj["min"] + obj["range"]])
        if deriv == 0:
            eo = _predict_ssfit(obj, xrange)["y"]
            es = _predict_ssfit(obj, xrange, 1)["y"] * obj["range"]
            if el.any():
                y[el] = eo[0] + es[0] * (xs[el] - 0)
            if er.any():
                y[er] = eo[1] + es[1] * (xs[er] - 1)
        elif deriv == 1:
            es = _predict_ssfit(obj, xrange, 1)["y"] * obj["range"]
            y[el] = es[0]
            y[er] = es[1]
        else:
            y[ex] = 0.0
    if deriv > 0:
        y = y / r_pow(obj["range"], float(deriv))
    out = _XY()
    out["x"] = x
    out["y"] = y
    return out


def predict_smooth_spline(object, x=None, deriv=0):
    """``predict.smooth.spline(object, x, deriv)``: ``RList`` mit ``x``, ``y``."""
    if x is None:
        if deriv == 0:
            out = _XY()
            out["x"] = object["x"]
            out["y"] = object["y"]
            return out
        x = object["x"]
    fit = object.get("fit")
    if fit is None:
        raise RError('not a valid "smooth.spline" object')
    return _predict_ssfit(fit, x, deriv)


from .base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__)
