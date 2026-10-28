"""Lineare und verallgemeinerte lineare Modelle (``lm.fit``, ``lm``, ``poly``, ``summary.lm``, ``glm``,
``binomial``, ``coef``, ``fitted``, ``residuals``, generisches ``predict``) sowie ``p.adjust``, ``ecdf``, ``ave``,
``aggregate`` und ``t.test``, nachgebildet aus R 4.3.3 ``stats/R/lm.R``, ``glm.R``, ``contr.poly.R``,
``family.R``, ``p.adjust.R``, ``ecdf.R``, ``ave.R``, ``aggregate.R``, ``t.test.R`` und ``stats/src/family.c``.
"""
from __future__ import annotations

import math

import numpy as np
import pandas as pd

from .linalg import RError, _out, _vec_out
from .rlist import RList
from . import rnum as _rn
from .rnum import NA_REAL
from .stats_sort import LD, _DBL_EPS, _NAN, _rmean, _rsum, _vec, _warn, order, sort, tabulate
from .stats_cor import var
from .stats_smooth import SmoothSpline, _SmoothSplineFit, _predict_ssfit, approxfun, predict_smooth_spline

__all__ = [
    "LMFit", "GLMFit", "glm_fit", "lm_fit", "lm", "poly", "summary_lm", "glm", "binomial",
    "predict", "p_adjust", "t_test", "ave", "aggregate", "ecdf", "fitted", "coef", "residuals",
]


# ── lm.fit / lm / poly / glm ─────────────────────────────────────────────

class LMFit(RList):
    r_class = ("lm",)


class GLMFit(RList):
    r_class = ("glm", "lm")


class _Family(RList):
    r_class = ("family",)


def lm_fit(x, y, offset=None, method="qr", tol=1e-07, singular_ok=True):
    """``lm.fit(x, y, offset, method, tol, singular.ok)`` (LINPACK ``dqrls``).

    Ergebnis: ``RList`` mit ``coefficients`` (Series), ``residuals``,
    ``effects`` (Series), ``rank``, ``fitted.values``, ``assign``, ``qr``
    (``RQR`` mit ``qr``, ``qraux``, ``pivot``, ``tol``, ``rank``),
    ``df.residual``.
    """
    from . import _linpack as LP
    from .linalg import RQR
    if isinstance(x, pd.DataFrame):
        X = x.to_numpy(dtype=np.float64)
        cn = None if isinstance(x.columns, pd.RangeIndex) else [str(c) for c in x.columns]
        rn_x = None if isinstance(x.index, pd.RangeIndex) else [str(i) for i in x.index]
    else:
        X = np.asarray(x, dtype=np.float64)
        cn = None
        rn_x = None
        if X.ndim != 2:
            raise RError("'x' must be a matrix")
    n = X.shape[0]
    if n == 0:
        raise RError("0 (non-NA) cases")
    p = X.shape[1]
    ynames = None
    if isinstance(y, pd.Series):
        ynames = None if isinstance(y.index, pd.RangeIndex) else [str(i) for i in y.index]
        Y = y.to_numpy(dtype=np.float64)
    elif isinstance(y, pd.DataFrame):
        Y = y.to_numpy(dtype=np.float64)
    else:
        Y = np.asarray(y, dtype=np.float64)
    ymat = Y.ndim == 2 and Y.shape[1] > 1
    if Y.ndim == 2 and Y.shape[1] == 1:
        Y = Y[:, 0]
    if p == 0:
        res = LMFit()
        res["coefficients"] = np.zeros(0)
        res["residuals"] = y
        res["fitted.values"] = 0 * Y
        res["rank"] = 0
        res["df.residual"] = Y.shape[0]
        return res
    if offset is not None:
        Y = Y - np.asarray(offset, dtype=np.float64)
    if Y.shape[0] != n:
        raise RError("incompatible dimensions")
    if method != "qr":
        _warn("method = '%s' is not supported. Using 'qr'" % method)
    if not np.isfinite(X).all():
        raise RError("NA/NaN/Inf in 'x'")
    if not np.isfinite(Y).all():
        raise RError("NA/NaN/Inf in 'y'")
    Y2 = Y.reshape(n, -1)
    with np.errstate(all="ignore"):
        z = LP.dqrls(X, Y2, float(tol))
    if not singular_ok and z["rank"] < p:
        raise RError("singular fit encountered")
    rank = z["rank"]
    pivot = z["pivot"]
    dn = cn if cn is not None else ["x%d" % (i + 1) for i in range(p)]
    nmeff = [dn[pivot[i] - 1] for i in range(rank)] + [""] * (n - rank)
    coef = z["coefficients"].copy()
    coef[rank:, :] = NA_REAL
    if z["pivoted"]:
        c2 = np.empty_like(coef)
        c2[pivot - 1, :] = coef
        coef = c2
    resid = z["residuals"]
    eff = z["effects"]
    with np.errstate(all="ignore"):
        fitted = Y2 - resid
        if offset is not None:
            fitted = fitted + np.asarray(offset, dtype=np.float64).reshape(n, -1)
    qrm = z["qr"]
    qcn = None
    if cn is not None:
        qcn = [cn[i - 1] for i in pivot] if z["pivoted"] else cn
    q = RQR()
    q["qr"] = _out(qrm, rn_x, qcn)
    q["qraux"] = z["qraux"]
    q["pivot"] = pivot
    q["tol"] = float(tol)
    q["rank"] = rank
    res = LMFit()
    if ymat:
        res["coefficients"] = pd.DataFrame(coef, index=dn)
        res["residuals"] = resid
        res["effects"] = pd.DataFrame(eff, index=nmeff)
        res["rank"] = rank
        res["fitted.values"] = fitted
    else:
        res["coefficients"] = pd.Series(coef[:, 0], index=dn)
        res["residuals"] = _vec_out(resid[:, 0], ynames)
        res["effects"] = pd.Series(eff[:, 0], index=nmeff)
        res["rank"] = rank
        res["fitted.values"] = _vec_out(fitted[:, 0], ynames)
    res["assign"] = None
    res["qr"] = q
    res["df.residual"] = n - rank
    return res


def poly(x, degree=1, coefs=None, raw=False, simple=False):
    """``poly(x, degree, coefs, raw, simple)`` (orthogonale Polynome wie R).

    Ergebnis: n×degree-Matrix (``ndarray``) mit Attribut ``coefs``
    (``dict`` mit ``alpha``, ``norm2``) als Eigenschaft ``.coefs``.
    """
    from .rnum import r_pow
    from . import linalg as LA
    xv, _ = _vec(x)
    degree = int(degree)
    if degree < 1:
        raise RError("'degree' must be at least 1")
    n = xv.size
    if raw:
        Z = np.column_stack([np.array([r_pow(v, k) for v in xv.tolist()]) for k in range(1, degree + 1)])
        return _PolyMatrix(Z, None, list(range(1, degree + 1)))
    if coefs is None:
        if np.isnan(xv).any():
            raise RError("missing values are not allowed in 'poly'")
        if degree >= np.unique(xv).size:
            raise RError("'degree' must be less than number of unique points")
        xbar = _rmean(xv)
        xc = xv - xbar
        X = np.column_stack([np.array([r_pow(v, k) for v in xc.tolist()]) for k in range(0, degree + 1)])
        QR = LA.qr(X)
        if QR["rank"] < degree:
            raise RError("'degree' must be less than number of unique points")
        zq = np.asarray(QR["qr"], dtype=np.float64)
        i, j = np.indices(zq.shape)
        zq = zq * (i == j)
        Z = np.asarray(LA.qr_qy(QR, zq), dtype=np.float64)
        Z2 = Z * Z
        norm2 = np.array([_rsum(Z2[:, k]) for k in range(Z.shape[1])])
        alpha = (np.array([_rsum(xc * Z2[:, k]) for k in range(Z.shape[1])]) / norm2 + xbar)[:degree]
        norm2 = np.concatenate([[1.0], norm2])
    else:
        alpha = np.asarray(coefs["alpha"], dtype=np.float64)
        norm2 = np.asarray(coefs["norm2"], dtype=np.float64)
        Z = np.ones((n, degree + 1))
        Z[:, 1] = xv - alpha[0]
        for i in range(2, degree + 1):
            Z[:, i] = (xv - alpha[i - 1]) * Z[:, i - 1] - (norm2[i] / norm2[i - 1]) * Z[:, i - 2]
    with np.errstate(all="ignore"):
        Z = Z / np.sqrt(norm2[1:])[None, :]
    Z = Z[:, 1:]
    out = _PolyMatrix(Z, {"alpha": alpha, "norm2": norm2}, list(range(1, degree + 1)))
    return out


class _PolyMatrix(np.ndarray):
    """Matrix mit ``coefs``/``degree`` wie R's ``poly``-Objekt."""

    def __new__(cls, a, coefs, degree):
        obj = np.asarray(a, dtype=np.float64).view(cls)
        obj.coefs = coefs
        obj.degree = degree
        return obj

    def __array_finalize__(self, obj):
        self.coefs = getattr(obj, "coefs", None)
        self.degree = getattr(obj, "degree", None)


# Minimaler Formel-Parser für die Formen, die das Paket nutzt:
#   y ~ x,  y ~ x1 + x2,  y ~ X (Matrix),  y ~ poly(x, d),  y ~ stats::poly(x, d),
#   Achsenabschnitt entfernen mit "- 1" oder "0 +".

def _split_top(s, sep):
    out = []
    depth = 0
    cur = ""
    for ch in s:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == sep and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    out.append(cur)
    return out


def _deparse_call(term):
    """Spaltennamen-Präfix wie R's deparse (", " zwischen Argumenten)."""
    t = term.strip()
    if "(" not in t:
        return t
    fn, rest = t.split("(", 1)
    inner = rest[:rest.rindex(")")]
    args = [a.strip() for a in _split_top(inner, ",")]
    return fn.strip() + "(" + ", ".join(args) + ")"


def _eval_term(term, ns):
    t = term.strip()
    if t in ns:
        return ns[t]
    tt = t
    for pre in ("stats::", "base::"):
        tt = tt.replace(pre, "")
    if tt.startswith("poly("):
        inner = tt[5:tt.rindex(")")]
        args = [a.strip() for a in _split_top(inner, ",")]
        xv = _eval_term(args[0], ns)
        kw = {}
        pos = []
        for a in args[1:]:
            if "=" in a and not a.startswith("="):
                k, v = a.split("=", 1)
                kw[k.strip()] = _eval_py(v.strip(), ns)
            else:
                pos.append(_eval_py(a, ns))
        if pos:
            kw["degree"] = pos[0]
        if "raw" in kw:
            kw["raw"] = bool(kw["raw"])
        return poly(xv, **kw)
    return _eval_py(tt, ns)


def _eval_py(expr, ns):
    e = expr.replace("TRUE", "True").replace("FALSE", "False")
    env = dict(ns)
    env.setdefault("np", np)
    return eval(e, {"__builtins__": {"abs": abs, "float": float, "int": int, "len": len,
                                     "min": min, "max": max, "True": True, "False": False}}, env)


def _model_frame(formula, data, env):
    if "~" not in formula:
        raise RError("invalid formula")
    lhs, rhs = formula.split("~", 1)
    ns = {}
    if env:
        ns.update(env)
    rownames = None
    nrow = None
    if data is not None:
        if isinstance(data, pd.DataFrame):
            for c in data.columns:
                ns[str(c)] = data[c].to_numpy()
            if not isinstance(data.index, pd.RangeIndex):
                rownames = [str(i) for i in data.index]
            nrow = len(data)
        else:
            ns.update(dict(data))
    intercept = True
    terms = []
    rhs_terms = [t.strip() for t in _split_top(rhs, "+")]
    expanded = []
    for t in rhs_terms:
        parts = _split_top(t, "-")
        expanded.append(parts[0].strip())
        for pp in parts[1:]:
            if pp.strip() in ("1",):
                intercept = False
            elif pp.strip():
                raise NotImplementedError("Formelterm '-%s' wird nicht unterstützt" % pp.strip())
    for t in expanded:
        if t == "":
            continue
        if t in ("0", "-1"):
            intercept = False
            continue
        if t == "1":
            continue
        terms.append(t)
    yv = _eval_term(lhs.strip(), ns)
    cols = []
    for t in terms:
        cols.append((t, _eval_term(t, ns)))
    return lhs.strip(), yv, cols, intercept, rownames, nrow


def _design(yv, cols, intercept, rownames):
    """Modellmatrix, Antwort, Spaltennamen, assign, behaltene Zeilen."""
    ylab, y = yv
    y = np.asarray(y.to_numpy() if isinstance(y, pd.Series) else y)
    if y.dtype == bool:
        y = y.astype(np.float64)
    y = y.astype(np.float64)
    n = y.shape[0]
    mats = []
    names = []
    assign = []
    ok = ~np.isnan(y) if y.ndim == 1 else ~np.isnan(y).any(axis=1)
    for k, (lab, v) in enumerate(cols, start=1):
        if isinstance(v, pd.DataFrame):
            cn = [str(c) for c in v.columns] if not isinstance(v.columns, pd.RangeIndex) else None
            a = v.to_numpy(dtype=np.float64)
        elif isinstance(v, _PolyMatrix):
            a = np.asarray(v, dtype=np.float64)
            cn = [str(d) for d in v.degree]
        else:
            a = np.asarray(v.to_numpy() if isinstance(v, pd.Series) else v)
            if a.dtype == bool:
                a = a.astype(np.float64)
            a = a.astype(np.float64)
            cn = None
        if a.ndim == 1:
            mats.append(a.reshape(-1, 1))
            names.append(_deparse_call(lab))
            assign.append(k)
            ok &= ~np.isnan(a)
        else:
            mats.append(a)
            pre = _deparse_call(lab)
            if a.shape[1] == 1:
                # model.matrix: einspaltige Matrix-Terme ohne Spaltensuffix
                names.append(pre)
                assign.append(k)
                ok &= ~np.isnan(a).any(axis=1)
                continue
            if cn is None:
                cn = [str(j + 1) for j in range(a.shape[1])]
            names.extend(pre + c for c in cn)
            assign.extend([k] * a.shape[1])
            ok &= ~np.isnan(a).any(axis=1)
    X = np.column_stack(([np.ones(n)] if intercept else []) + mats) if (mats or intercept) else np.zeros((n, 0))
    if intercept:
        names = ["(Intercept)"] + names
        assign = [0] + assign
    if rownames is None:
        rownames = [str(i + 1) for i in range(n)]
    return X, y, names, np.array(assign, dtype=np.int64), ok, rownames


def lm(formula, data=None, env=None, **kwargs):
    """``lm(formula, data)`` für einfache Formeln (``y ~ x``, ``y ~ x1 + x2``,
    ``y ~ X`` mit Matrix ``X``, ``y ~ poly(x, d)``, ohne Achsenabschnitt mit
    ``- 1``/``0 +``). Variablen aus ``data`` (DataFrame/dict), ``env`` oder
    Schlüsselwortargumenten. Fehlende Werte: ``na.omit``.

    Ergebnis ``LMFit`` (RList, Klasse ``lm``) mit den Elementen von ``lm.fit``
    plus ``model``; :func:`coef`, :func:`fitted`, :func:`residuals`,
    :func:`summary_lm`.
    """
    ns = dict(env or {})
    ns.update(kwargs)
    ylab, yv, cols, intercept, rownames, nrow = _model_frame(formula, data, ns)
    X, y, names, assign, ok, rn = _design((ylab, yv), cols, intercept, rownames)
    keep = ok
    Xk = X[keep]
    yk = y[keep]
    rnk = [r for r, b in zip(rn, keep) if b]
    fit = lm_fit(pd.DataFrame(Xk, columns=names, index=rnk), pd.Series(yk, index=rnk))
    fit["assign"] = assign
    fit["qr"]["qr"] = pd.DataFrame(np.asarray(fit["qr"]["qr"]), index=rnk,
                                   columns=list(fit["qr"]["qr"].columns))
    fit["xlevels"] = {}
    fit["call"] = None
    fit["terms"] = {"intercept": 1 if intercept else 0, "formula": formula}
    model = {ylab: yk}
    for lab, v in cols:
        model[lab] = v[keep] if not isinstance(v, pd.DataFrame) else v[keep]
    fit["model"] = model
    if not keep.all():
        fit["na.action"] = np.where(~keep)[0] + 1
    return fit


def coef(obj):
    """``coef(obj)``."""
    return obj["coefficients"]


def fitted(obj):
    """``fitted(obj)``."""
    return obj["fitted.values"]


def residuals(obj):
    """``residuals(obj)`` (Antwort-Residuen)."""
    return obj["residuals"]


class _SummaryLM(RList):
    r_class = ("summary.lm",)


def summary_lm(object):
    """``summary.lm(object)``: residuals, coefficients (DataFrame), aliased,
    sigma, df, r.squared, adj.r.squared, fstatistic, cov.unscaled."""
    from . import nmath as NM
    from . import linalg as LA
    z = object
    p = int(z["rank"])
    rdf = z["df.residual"]
    r = np.asarray(z["residuals"], dtype=np.float64)
    ans = _SummaryLM()
    intercept = int((z.get("terms") or {}).get("intercept", 1))
    if p == 0:
        n = r.size
        rss = _rsum(r * r)
        resvar = rss / rdf
        ans["residuals"] = z["residuals"]
        ans["aliased"] = np.isnan(np.asarray(z["coefficients"], dtype=np.float64))
        ans["df"] = np.array([0, n, ans["aliased"].size])
        ans["coefficients"] = pd.DataFrame(np.zeros((0, 4)), columns=["Estimate", "Std. Error", "t value", "Pr(>|t|)"])
        ans["sigma"] = math.sqrt(resvar)
        ans["r.squared"] = 0.0
        ans["adj.r.squared"] = 0.0
        return ans
    Qr = z["qr"]
    Q = np.asarray(Qr["qr"], dtype=np.float64)
    n = Q.shape[0]
    if n - p != rdf:
        _warn('residual degrees of freedom in object suggest this is not an "lm" fit')
    f = np.asarray(z["fitted.values"], dtype=np.float64)
    with np.errstate(all="ignore"):
        if intercept:
            d = f - _rmean(f)
            mss = _rsum(d * d)
        else:
            mss = _rsum(f * f)
        rss = _rsum(r * r)
        resvar = float(np.float64(rss) / np.float64(rdf))
        if math.isfinite(resvar):
            mf = _rmean(f)
            if resvar < (mf * mf + var(f)) * 1e-30:
                _warn("essentially perfect fit: summary may be unreliable")
        R = LA.chol2inv(Q[:p, :p])
        se = np.sqrt(np.diag(R) * resvar)
        cf = z["coefficients"]
        cfv = np.asarray(cf, dtype=np.float64)
        piv = np.asarray(Qr["pivot"])
        est = cfv[piv[:p] - 1]
        tval = est / se
        pv = 2 * np.asarray(NM.pt(np.abs(tval), rdf, lower_tail=False), dtype=np.float64)
    cnames = list(cf.index) if isinstance(cf, pd.Series) else [str(i) for i in range(cfv.size)]
    rn = [cnames[i - 1] for i in piv[:p]]
    ans["residuals"] = z["residuals"]
    ans["coefficients"] = pd.DataFrame({"Estimate": est, "Std. Error": se, "t value": tval, "Pr(>|t|)": pv},
                                       index=rn)
    ans["aliased"] = pd.Series(np.isnan(cfv), index=cnames)
    ans["sigma"] = math.sqrt(resvar)
    ans["df"] = np.array([p, rdf, Q.shape[1]], dtype=np.int64)
    if p != intercept:
        df_int = 1 if intercept else 0
        rsq = mss / (mss + rss)
        ans["r.squared"] = rsq
        ans["adj.r.squared"] = 1 - (1 - rsq) * ((n - df_int) / rdf)
        ans["fstatistic"] = pd.Series([(mss / (p - df_int)) / resvar, float(p - df_int), float(rdf)],
                                      index=["value", "numdf", "dendf"])
    else:
        ans["r.squared"] = 0.0
        ans["adj.r.squared"] = 0.0
    ans["cov.unscaled"] = pd.DataFrame(R, index=rn, columns=rn)
    return ans


def binomial(link="logit"):
    """``binomial(link = "logit")`` (nur der Logit-Link aus family.c)."""
    if link != "logit":
        raise NotImplementedError("binomial(): nur link = 'logit' ist portiert")
    fam = _Family()
    fam["family"] = "binomial"
    fam["link"] = "logit"
    fam["linkfun"] = _logit_link
    fam["linkinv"] = _logit_linkinv
    fam["variance"] = lambda mu: mu * (1 - mu)
    fam["dev.resids"] = _binomial_dev_resids
    fam["aic"] = _binomial_aic
    fam["mu.eta"] = _logit_mu_eta
    fam["validmu"] = lambda mu: bool(np.isfinite(mu).all() and ((mu > 0) & (mu < 1)).all())
    fam["valideta"] = lambda eta: True
    fam["dispersion"] = 1
    return fam


def _logit_link(mu):
    mu = np.asarray(mu, dtype=np.float64)
    out = np.empty_like(mu)
    for i, x in enumerate(mu.tolist()):
        if x < 0 or x > 1:
            raise RError("Value %g out of range (0, 1)" % x)
        q = x / (1 - x) if x != 1 else math.inf
        out[i] = math.log(q) if q > 0 else (-math.inf if q == 0 else math.nan)
    return out


_INVEPS = 1 / _DBL_EPS


def _logit_linkinv(eta):
    eta = np.asarray(eta, dtype=np.float64)
    out = np.empty_like(eta)
    for i, e in enumerate(eta.tolist()):
        tmp = _DBL_EPS if e < -30.0 else (_INVEPS if e > 30.0 else math.exp(e))
        out[i] = tmp / (1 + tmp)
    return out


def _logit_mu_eta(eta):
    eta = np.asarray(eta, dtype=np.float64)
    out = np.empty_like(eta)
    for i, e in enumerate(eta.tolist()):
        if e > 30.0 or e < -30.0:
            out[i] = _DBL_EPS
        else:
            ex = math.exp(e)
            opexp = 1 + ex
            out[i] = ex / (opexp * opexp)
    return out


def _y_log_y(y, mu):
    if y != 0.0:
        q = y / mu
        return y * (math.log(q) if q > 0 else (-math.inf if q == 0 else math.nan))
    return 0.0


def _binomial_dev_resids(y, mu, wt):
    y = np.atleast_1d(np.asarray(y, dtype=np.float64))
    mu = np.atleast_1d(np.asarray(mu, dtype=np.float64))
    wt = np.atleast_1d(np.asarray(wt, dtype=np.float64))
    n = y.size
    out = np.empty(n)
    with np.errstate(all="ignore"):
        for i in range(n):
            mui = mu[i] if mu.size > 1 else mu[0]
            yi = y[i]
            w = wt[i] if wt.size > 1 else wt[0]
            out[i] = 2 * w * (_y_log_y(yi, mui) + _y_log_y(1 - yi, 1 - mui))
    return out


def _binomial_aic(y, n, mu, wt, dev):
    from . import nmath as NM
    m = n if (np.asarray(n) > 1).any() else wt
    m = np.asarray(m, dtype=np.float64)
    from .fmt import r_round
    with np.errstate(all="ignore"):
        fac = np.where(m > 0, wt / m, 0.0)
        db = np.asarray(NM.dbinom(np.asarray(r_round(m * y), dtype=np.float64),
                                  np.asarray(r_round(m), dtype=np.float64), mu, log=True), dtype=np.float64)
    return -2 * _rsum(fac * db)


def glm(formula, family=None, data=None, weights=None, control=None, env=None, **kwargs):
    """``glm(formula, family = binomial(), data)`` mit IRLS wie ``glm.fit``.

    Unterstützt die Familie :func:`binomial` (Logit). Ergebnis ``GLMFit``
    mit coefficients, residuals, fitted.values, rank, linear.predictors,
    deviance, aic, null.deviance, iter, weights, prior.weights,
    df.residual, df.null, y, converged, boundary.
    """
    if family is None:
        family = binomial()
    if callable(family) and not isinstance(family, dict):
        family = family()
    ns = dict(env or {})
    ns.update(kwargs)
    ylab, yv, cols, intercept, rownames, nrow = _model_frame(formula, data, ns)
    X, y, names, assign, ok, rn = _design((ylab, yv), cols, intercept, rownames)
    X = X[ok]
    y = y[ok]
    rn = [r for r, b in zip(rn, ok) if b]
    ctl = {"epsilon": 1e-8, "maxit": 25, "trace": False}
    if control:
        ctl.update(control)
    fit = glm_fit(X, y, weights=weights, family=family, control=ctl, intercept=intercept,
                  xnames=names, ynames=rn)
    fit["call"] = None
    fit["formula"] = formula
    fit["terms"] = {"intercept": 1 if intercept else 0}
    return fit


def glm_fit(x, y, weights=None, start=None, etastart=None, mustart=None, offset=None,
            family=None, control=None, intercept=True, singular_ok=True, xnames=None, ynames=None):
    """``glm.fit`` (IRLS) wie R."""
    from . import _linpack as LP
    from . import linalg as LA
    if family is None:
        raise RError("'family' argument seems not to be a valid family object")
    ctl = {"epsilon": 1e-8, "maxit": 25, "trace": False}
    if control:
        ctl.update(control)
    eps_c = float(ctl["epsilon"])
    if eps_c <= 0:
        raise RError("value of 'epsilon' must be > 0")
    maxit = int(ctl["maxit"])
    if maxit <= 0:
        raise RError("maximum number of iterations must be > 0")
    X = np.asarray(x, dtype=np.float64)
    if X.ndim == 1:
        X = X.reshape(-1, 1)
    y = np.asarray(y, dtype=np.float64).copy()
    nobs = y.shape[0]
    nvars = X.shape[1]
    if xnames is None:
        xnames = None
    wts = np.ones(nobs) if weights is None else np.asarray(weights, dtype=np.float64).copy()
    off = np.zeros(nobs) if offset is None else np.asarray(offset, dtype=np.float64)
    variance = family["variance"]
    linkinv = family["linkinv"]
    dev_resids = family["dev.resids"]
    mu_eta = family["mu.eta"]
    valideta = family.get("valideta") or (lambda e: True)
    validmu = family.get("validmu") or (lambda m: True)
    # binomInitialize (Vektor-Antwort)
    with np.errstate(all="ignore"):
        n_ = np.ones(nobs)
        y[wts == 0] = 0
        if ((y < 0) | (y > 1)).any():
            raise RError("y values must be 0 <= y <= 1")
        ms = (wts * y + 0.5) / (wts + 1)
        mm = wts * y
        from .fmt import r_round
        if (np.abs(mm - np.asarray(r_round(mm), dtype=np.float64)) > 1e-3).any():
            _warn("non-integer #successes in a binomial glm!")
    if mustart is None:
        mustart = ms
    conv = False
    coefold = None
    if etastart is not None:
        eta = np.asarray(etastart, dtype=np.float64)
    elif start is not None:
        start = np.asarray(start, dtype=np.float64)
        if start.size != nvars:
            raise RError("length of 'start' should equal %d and correspond to initial coefs" % nvars)
        coefold = start.copy()
        eta = off + np.asarray(LA.matprod(X, start), dtype=np.float64).ravel()
    else:
        eta = family["linkfun"](mustart)
    mu = linkinv(eta)
    if not (validmu(mu) and valideta(eta)):
        raise RError("cannot find valid starting values: please specify some")
    devold = _rsum(dev_resids(y, mu, wts))
    boundary = False
    if start is None:
        start = np.full(nvars, NA_REAL)
    coef = None
    fit = None
    it = 0
    good = wts > 0
    w = None
    with np.errstate(all="ignore"):
        for it in range(1, maxit + 1):
            good = wts > 0
            varmu = variance(mu)[good]
            if np.isnan(varmu).any():
                raise RError("NAs in V(mu)")
            if (varmu == 0).any():
                raise RError("0s in V(mu)")
            mev = mu_eta(eta)
            if np.isnan(mev[good]).any():
                raise RError("NAs in d(mu)/d(eta)")
            good = (wts > 0) & (mev != 0)
            if not good.any():
                conv = False
                _warn("no observations informative at iteration %d" % it)
                break
            z = (eta - off)[good] + (y - mu)[good] / mev[good]
            w = np.sqrt((wts[good] * (mev[good] * mev[good])) / variance(mu)[good])
            fit = LP.dqrls(X[good] * w[:, None], (z * w).reshape(-1, 1), min(1e-7, eps_c / 1000))
            cf = fit["coefficients"][:, 0]
            if not np.isfinite(cf).all():
                conv = False
                _warn("non-finite coefficients at iteration %d" % it)
                break
            if nobs < fit["rank"]:
                raise RError(("X matrix has rank %d, but only %d observation" if nobs == 1 else
                              "X matrix has rank %d, but only %d observations") % (fit["rank"], nobs))
            if not singular_ok and fit["rank"] < nvars:
                raise RError("singular fit encountered")
            start = start.copy()
            start[fit["pivot"] - 1] = cf
            eta = np.asarray(LA.matprod(X, start), dtype=np.float64).ravel()
            eta = eta + off
            mu = linkinv(eta)
            dev = _rsum(dev_resids(y, mu, wts))
            if ctl["trace"]:
                print("Deviance = %s Iterations - %d" % (_fmt_num(dev), it))
            boundary = False
            if not math.isfinite(dev):
                if coefold is None:
                    raise RError("no valid set of coefficients has been found: please supply starting values")
                _warn("step size truncated due to divergence")
                ii = 1
                while not math.isfinite(dev):
                    if ii > maxit:
                        raise RError("inner loop 1; cannot correct step size")
                    ii += 1
                    start = (start + coefold) / 2
                    eta = np.asarray(LA.matprod(X, start), dtype=np.float64).ravel() + off
                    mu = linkinv(eta)
                    dev = _rsum(dev_resids(y, mu, wts))
                boundary = True
            if not (valideta(eta) and validmu(mu)):
                if coefold is None:
                    raise RError("no valid set of coefficients has been found: please supply starting values")
                _warn("step size truncated: out of bounds")
                ii = 1
                while not (valideta(eta) and validmu(mu)):
                    if ii > maxit:
                        raise RError("inner loop 2; cannot correct step size")
                    ii += 1
                    start = (start + coefold) / 2
                    eta = np.asarray(LA.matprod(X, start), dtype=np.float64).ravel() + off
                    mu = linkinv(eta)
                boundary = True
                dev = _rsum(dev_resids(y, mu, wts))
            if abs(dev - devold) / (0.1 + abs(dev)) < eps_c:
                conv = True
                coef = start.copy()
                break
            devold = dev
            coef = start.copy()
            coefold = start.copy()
    if not conv:
        _warn("glm.fit: algorithm did not converge")
    if boundary:
        _warn("glm.fit: algorithm stopped at boundary value")
    epsw = 10 * _DBL_EPS
    if (mu > 1 - epsw).any() or (mu < epsw).any():
        _warn("glm.fit: fitted probabilities numerically 0 or 1 occurred")
    if coef is None:
        coef = start.copy()
    rank = fit["rank"] if fit is not None else 0
    if fit is not None and rank < nvars:
        piv = fit["pivot"]
        coef[piv[rank:] - 1] = NA_REAL
    with np.errstate(all="ignore"):
        resid = (y - mu) / mu_eta(eta)
    xn = xnames if xnames is not None else None
    res = GLMFit()
    res["coefficients"] = pd.Series(coef, index=xn) if xn is not None else coef
    res["residuals"] = _vec_out(resid, ynames)
    res["fitted.values"] = _vec_out(mu, ynames)
    if fit is not None:
        xxnames = [xn[i - 1] for i in fit["pivot"]] if xn is not None else None
        eff = fit["effects"][:, 0]
        res["effects"] = pd.Series(eff, index=(xxnames[:rank] + [""] * (int(good.sum()) - rank))) \
            if xxnames is not None else eff
        qrm = np.asarray(fit["qr"])
        nr = min(int(good.sum()), nvars)
        if nr < nvars:
            Rmat = np.eye(nvars)
            Rmat[:nr, :nvars] = qrm[:nr, :nvars]
        else:
            Rmat = qrm[:nvars, :nvars].copy()
        i, j = np.indices(Rmat.shape)
        Rmat[i > j] = 0.0
        res["R"] = _out(Rmat, xxnames, xxnames)
    res["rank"] = rank
    from .linalg import RQR
    if fit is not None:
        q = RQR()
        q["qr"] = _out(np.asarray(fit["qr"]), None, xxnames)
        q["rank"] = rank
        q["qraux"] = fit["qraux"]
        q["pivot"] = fit["pivot"]
        q["tol"] = min(1e-7, eps_c / 1000)
        res["qr"] = q
    res["family"] = family
    res["linear.predictors"] = _vec_out(eta, ynames)
    res["deviance"] = dev if fit is not None else devold
    with np.errstate(all="ignore"):
        wtdmu = (_rsum(wts * y) / _rsum(wts)) if intercept else linkinv(off)
        nulldev = _rsum(dev_resids(y, wtdmu, wts))
    n_ok = nobs - int((wts == 0).sum())
    nulldf = n_ok - int(bool(intercept))
    resdf = n_ok - rank
    try:
        aic_model = family["aic"](y, n_, mu, wts, res["deviance"]) + 2 * rank
    except Exception:  # noqa: BLE001 - nmath.dbinom ggf. nicht vorhanden
        aic_model = _NAN
    res["aic"] = aic_model
    res["null.deviance"] = nulldev
    res["iter"] = it
    wt = np.zeros(nobs)
    if w is not None:
        wt[good] = w * w
    res["weights"] = _vec_out(wt, ynames)
    res["prior.weights"] = _vec_out(wts, ynames)
    res["df.residual"] = resdf
    res["df.null"] = nulldf
    res["y"] = _vec_out(y, ynames)
    res["converged"] = conv
    res["boundary"] = boundary
    return res


def _fmt_num(x):
    from . import fmt as _fmt
    return _fmt.as_character(x) if hasattr(_fmt, "as_character") else repr(x)


# ── p.adjust / ecdf / ave / aggregate / t.test ───────────────────────────

_PADJ = ["holm", "hochberg", "hommel", "bonferroni", "BH", "BY", "fdr", "none"]


def p_adjust(p, method="holm", n=None):
    """``p.adjust(p, method, n)``."""
    hits = [m for m in _PADJ if m.startswith(method)]
    if method in _PADJ:
        hits = [method]
    if len(hits) != 1:
        raise RError("'arg' should be one of " + ", ".join("“%s”" % m for m in _PADJ))
    method = hits[0]
    if method == "fdr":
        method = "BH"
    pv, nm = _vec(p)
    p0 = pv.copy()
    nna = ~np.isnan(pv)
    pp = pv[nna]
    lp = pp.size
    if n is None:
        n = lp          # R: Promise length(p) wird erst nach p <- p[nna] ausgewertet
    if not n >= lp:
        raise RError("n >= lp is not TRUE")
    if n <= 1:
        return _vec_out(p0, nm) if (nm is not None or p0.size != 1) else float(p0[0])
    if n == 2 and method == "hommel":
        method = "hochberg"
    with np.errstate(all="ignore"):
        if method == "bonferroni":
            r = np.minimum(1.0, n * pp)
        elif method == "holm":
            i = np.arange(1, lp + 1)
            o = order(pp) - 1
            ro = order(o.astype(np.float64)) - 1
            r = np.minimum(1.0, _cummax((n + 1 - i) * pp[o]))[ro]
        elif method == "hommel":
            q_p = np.concatenate([pp, np.ones(int(n) - lp)]) if n > lp else pp.copy()
            nn_ = int(n)
            i = np.arange(1, nn_ + 1)
            o = order(q_p) - 1
            q_p = q_p[o]
            ro = order(o.astype(np.float64)) - 1
            mn = float(np.min(nn_ * q_p / i))
            q = np.full(nn_, mn)
            pa = np.full(nn_, mn)
            for j in range(nn_ - 1, 1, -1):
                ij = np.arange(0, nn_ - j + 1)
                i2 = np.arange(nn_ - j + 1, nn_)
                q1 = float(np.min(j * q_p[i2] / np.arange(2, j + 1)))
                q[ij] = np.minimum(j * q_p[ij], q1)
                q[i2] = q[nn_ - j]
                pa = np.maximum(pa, q)
            r = np.maximum(pa, q_p)[ro[:lp] if lp < nn_ else ro]
        elif method == "hochberg":
            i = np.arange(lp, 0, -1)
            o = order(pp, decreasing=True) - 1
            ro = order(o.astype(np.float64)) - 1
            r = np.minimum(1.0, _cummin((n + 1 - i) * pp[o]))[ro]
        elif method == "BH":
            i = np.arange(lp, 0, -1)
            o = order(pp, decreasing=True) - 1
            ro = order(o.astype(np.float64)) - 1
            r = np.minimum(1.0, _cummin(n / i * pp[o]))[ro]
        elif method == "BY":
            i = np.arange(lp, 0, -1)
            o = order(pp, decreasing=True) - 1
            ro = order(o.astype(np.float64)) - 1
            q = _rsum(1.0 / np.arange(1, int(n) + 1))
            r = np.minimum(1.0, _cummin(q * n / i * pp[o]))[ro]
        else:
            r = pp
    p0[nna] = r
    return _vec_out(p0, nm) if (nm is not None or p0.size != 1) else float(p0[0])


def _cummax(x):
    out = np.empty(x.size)
    m = -math.inf
    for k, v in enumerate(x.tolist()):
        if v != v:
            return _rn._handle_nan(np.asarray(x, dtype=np.float64), out)
        m = m if m > v else v
        out[k] = m
    return out


def _cummin(x):
    out = np.empty(x.size)
    m = math.inf
    for k, v in enumerate(x.tolist()):
        if v != v:
            return _rn._handle_nan(np.asarray(x, dtype=np.float64), out)
        m = m if m < v else v
        out[k] = m
    return out


def ecdf(x):
    """``ecdf(x)``: Funktion mit Attributen ``x`` (Sprungstellen), ``y``, ``nobs``."""
    xv, _ = _vec(x)
    xs = np.sort(xv[~np.isnan(xv)])
    n = xs.size
    if n < 1:
        raise RError("'x' must have 1 or more non-missing values")
    vals = pd.unique(xs)
    idx = np.searchsorted(vals, xs) + 1
    counts = tabulate(idx, nbins=vals.size)
    yv = np.cumsum(counts.astype(LD)).astype(np.float64) / n
    f = approxfun(vals, yv, method="constant", yleft=0.0, yright=1.0, f=0, ties="ordered")
    f.nobs = n
    f.knots = vals
    return f


def ave(x, *groups, FUN=None):
    """``ave(x, ..., FUN = mean)``; ``FUN`` erhält ein ``ndarray``."""
    xv, nm = _vec(x)
    if FUN is None:
        FUN = _rmean
    out = xv.copy()
    if not groups:
        r = np.asarray(FUN(xv), dtype=np.float64)
        out[:] = np.resize(r, xv.size)
        return _vec_out(out, nm)
    keys = list(zip(*[(g.to_numpy() if isinstance(g, pd.Series) else np.asarray(g)).tolist() for g in groups]))
    d = {}
    for i, k in enumerate(keys):
        if any(v is None or (isinstance(v, float) and v != v) for v in k):
            continue
        d.setdefault(k, []).append(i)
    # Gruppen in der Reihenfolge von interaction(...): Stufen wie factor()
    # (Zahlen numerisch, Zeichenketten nach R's Kollation), erste Variable
    # läuft am schnellsten
    pos = []
    for g in groups:
        ga = g.to_numpy() if isinstance(g, pd.Series) else np.asarray(g)
        ok = np.array([not (v is None or (isinstance(v, float) and v != v)) for v in ga.tolist()], dtype=bool)
        lv = sort(pd.unique(ga[ok])) if ok.any() else []
        pos.append({v: i for i, v in enumerate(np.asarray(lv).tolist())})
    def _gord(k):
        return tuple(pos[j][k[j]] for j in range(len(k) - 1, -1, -1))
    for k in sorted(d, key=_gord):
        ix = d[k]
        r = np.asarray(FUN(xv[ix]), dtype=np.float64)
        out[ix] = np.resize(r, len(ix))
    return _vec_out(out, nm)


def aggregate(x, by, FUN):
    """``aggregate(x, by = list(name = g, ...), FUN)`` für einen Vektor ``x``.

    ``by``: ``dict`` (Name → Gruppierungsvektor). Ergebnis-``DataFrame`` mit
    den Gruppenspalten (sortiert wie R: erste Variable läuft am schnellsten)
    und Spalte ``x``.
    """
    xv, _ = _vec(x)
    names = list(by.keys())
    gs = [np.asarray(by[k].to_numpy() if isinstance(by[k], pd.Series) else by[k]) for k in names]
    levels = []
    codes = []
    for g in gs:
        ok = np.array([not (v is None or (isinstance(v, float) and v != v)) for v in g.tolist()])
        lv = sort(pd.unique(g[ok]))
        levels.append(list(lv))
        pos = {v: i for i, v in enumerate(levels[-1])}
        codes.append(np.array([pos.get(v, -1) if o else -1 for v, o in zip(g.tolist(), ok.tolist())]))
    combos = {}
    for i in range(xv.size):
        key = tuple(c[i] for c in codes)
        if any(k < 0 for k in key):
            continue
        combos.setdefault(key, []).append(i)
    # Gruppenindex wie interaction(): erste Variable variiert am schnellsten
    def grp(key):
        g = 0
        mult = 1
        for k, lv in zip(key, levels):
            g += k * mult
            mult *= len(lv)
        return g
    keys = sorted(combos, key=grp)
    data = {nm: [levels[j][k[j]] for k in keys] for j, nm in enumerate(names)}
    data["x"] = [float(np.asarray(FUN(xv[combos[k]]), dtype=np.float64).ravel()[0]) for k in keys]
    return pd.DataFrame(data)


class _HTest(RList):
    r_class = ("htest",)


def t_test(x, y=None, alternative="two.sided", mu=0, paired=False, var_equal=False, conf_level=0.95):
    """``t.test.default(x, y, alternative, mu, paired, var.equal, conf.level)``.

    Ergebnis ``RList`` (Klasse ``htest``): statistic, parameter, p.value,
    conf.int, estimate, null.value, stderr, alternative, method, data.name.
    """
    from . import nmath as NM
    from .rnum import r_pow
    alts = ["two.sided", "less", "greater"]
    am = [a for a in alts if a.startswith(alternative)]
    if len(am) != 1:
        raise RError("'arg' should be one of “two.sided”, “less”, “greater”")
    alternative = am[0]
    if np.ndim(mu) != 0 or mu != mu:
        raise RError("'mu' must be a single number")
    if not (np.ndim(conf_level) == 0 and math.isfinite(conf_level) and 0 <= conf_level <= 1):
        raise RError("'conf.level' must be a single number between 0 and 1")
    xv, _ = _vec(x)
    if y is not None:
        yv, _ = _vec(y)
        dname = "x and y"
        if paired:
            ok = ~(np.isnan(xv) | np.isnan(yv))
            xok = yok = ok
        else:
            yok = ~np.isnan(yv)
            xok = ~np.isnan(xv)
        yv = yv[yok]
    else:
        dname = "x"
        if paired:
            raise RError("'y' is missing for paired test")
        xok = ~np.isnan(xv)
        yv = None
    xv = xv[xok]
    if paired:
        xv = xv - yv
        yv = None
    nx = xv.size
    mx = _rmean(xv)
    vx = var(xv) if nx > 1 else NA_REAL
    eps = _DBL_EPS
    with np.errstate(all="ignore"):
        if yv is None:
            if nx < 2:
                raise RError("not enough 'x' observations")
            df = nx - 1
            stderr = math.sqrt(vx / nx)
            if stderr < 10 * eps * abs(mx):
                raise RError("data are essentially constant")
            tstat = (mx - mu) / stderr
            method = "Paired t-test" if paired else "One Sample t-test"
            estimate = pd.Series([mx], index=["mean difference" if paired else "mean of x"])
        else:
            ny = yv.size
            if nx < 1 or (not var_equal and nx < 2):
                raise RError("not enough 'x' observations")
            if ny < 1 or (not var_equal and ny < 2):
                raise RError("not enough 'y' observations")
            if var_equal and nx + ny < 3:
                raise RError("not enough observations")
            my = _rmean(yv)
            vy = var(yv) if ny > 1 else NA_REAL
            method = ("Welch" + " " if not var_equal else " ") + "Two Sample t-test"
            estimate = pd.Series([mx, my], index=["mean of x", "mean of y"])
            if var_equal:
                df = nx + ny - 2
                v = 0.0
                if nx > 1:
                    v = v + (nx - 1) * vx
                if ny > 1:
                    v = v + (ny - 1) * vy
                v = v / df
                stderr = math.sqrt(v * (1 / nx + 1 / ny))
            else:
                stderrx = math.sqrt(vx / nx)
                stderry = math.sqrt(vy / ny)
                stderr = math.sqrt(stderrx * stderrx + stderry * stderry)
                df = float(np.float64(r_pow(stderr, 4)) / (np.float64(r_pow(stderrx, 4)) / (nx - 1) + np.float64(r_pow(stderry, 4)) / (ny - 1)))
            if stderr < 10 * eps * max(abs(mx), abs(my)):
                raise RError("data are essentially constant")
            tstat = (mx - my - mu) / stderr
        if alternative == "less":
            pval = float(NM.pt(tstat, df))
            cint = [-math.inf, tstat + float(NM.qt(conf_level, df))]
        elif alternative == "greater":
            pval = float(NM.pt(tstat, df, lower_tail=False))
            cint = [tstat - float(NM.qt(conf_level, df)), math.inf]
        else:
            pval = 2 * float(NM.pt(-abs(tstat), df))
            alpha = 1 - conf_level
            c = float(NM.qt(1 - alpha / 2, df))
            cint = [tstat - c, tstat + c]
            cint = [tstat + (-c), tstat + c]
        cint = np.array([mu + v * stderr for v in cint])
    res = _HTest()
    res["statistic"] = pd.Series([tstat], index=["t"])
    res["parameter"] = pd.Series([float(df)], index=["df"])
    res["p.value"] = pval
    res["conf.int"] = cint
    res["estimate"] = estimate
    res["null.value"] = pd.Series([float(mu)], index=["mean difference" if paired else
                                                      ("difference in means" if y is not None else "mean")])
    res["stderr"] = stderr
    res["alternative"] = alternative
    res["method"] = method
    res["data.name"] = dname
    return res


def predict(object, *args, **kwargs):
    """Generisches ``predict`` (``smooth.spline``; ``lm``/``glm``: angepasste Werte)."""
    if isinstance(object, SmoothSpline):
        return predict_smooth_spline(object, *args, **kwargs)
    if isinstance(object, _SmoothSplineFit):
        return _predict_ssfit(object, *args, **kwargs)
    if isinstance(object, (LMFit, GLMFit)) and not args and not kwargs:
        return object["fitted.values"] if isinstance(object, LMFit) else object["linear.predictors"]
    raise NotImplementedError("predict() für dieses Objekt ist nicht portiert")


from .base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__)
