"""Hüllen der C-Bibliothek slc, Etappe 9.2 (SimLev core): lineare Algebra, Matrixprodukt,
kleinste Quadrate und Logit-IRLS, Stineman-Interpolation, Glättungsspline, Kerndichte.

Gegenstück zu ``r/R/slc_linalg.R`` (R) und ``julia/src/slib_linalg.jl`` (Julia). Die Rechnung
steht in ``src/core/slc_{linalg,matmul,lsq,stine,spline,kde}.c`` (Kopien von ``core/``), die Hülle
in ``src/_ext_slc_linalg.c`` (Modul ``simlev._ext``). Fehlertexte und Warnungen kommen aus dem
Kern (Fehler: ``ValueError``; Warnung: ``warnings.warn``). Die Funktionen sind über
``simlev._lib`` erreichbar. Matrizen sind 2-D-Felder (intern spaltenweise), Vektoren 1-D.

Seit Etappe 9.6b rufen die Ports diese Hüllen an denselben Stellen wie R.
"""
from __future__ import annotations

import numpy as np

from . import _ext

__all__ = ["chol", "chol_band", "backsolve", "forwardsolve", "solve_spd", "logdet_spd", "eigen_sym",
           "matmul", "crossprod", "tcrossprod", "lsfit", "logit_irls", "stineman", "stineman_slopes",
           "stineman_eval", "smspline_fit", "smspline_predict", "bw_silverman", "kde"]


def _arr(x):
    if hasattr(x, "to_numpy"):
        x = x.to_numpy()
    return np.asarray(x, dtype=np.float64)


def _fmat(x):
    """(Puffer spaltenweise, Zeilen, Spalten); 1-D als Spaltenvektor."""
    a = _arr(x)
    if a.ndim == 0:
        a = a.reshape(1, 1)
    elif a.ndim == 1:
        a = a.reshape(-1, 1)
    elif a.ndim != 2:
        raise ValueError("interner Fehler: Matrix erwartet")
    return np.ascontiguousarray(a.ravel(order="F")), a.shape[0], a.shape[1]


def _mat(buf, m, n):
    return buf.reshape((m, n), order="F")


def _vec(x):
    return np.ascontiguousarray(_arr(x).reshape(-1))


def _is_mat(x):
    return _arr(x).ndim == 2


# ── lineare Algebra ─────────────────────────────────────────────────────────

def chol(x):
    """chol(x): obere Dreiecksmatrix R mit R'R = x (gelesen wird das obere Dreieck)."""
    a, m, n = _fmat(x)
    if m != n:
        raise ValueError("chol: Matrix nicht quadratisch")
    out = np.empty(m * n)
    _ext.slc_chol(a, out, n)
    return _mat(out, n, n)


def chol_band(ab, kd):
    """Band-Cholesky (Prüfung): ab = (kd + 1) x n, unteres Band spaltenweise."""
    a, r, n = _fmat(ab)
    if r != int(kd) + 1:
        raise ValueError("interner Fehler: ab muss kd + 1 Zeilen haben")
    out = a.copy()
    _ext.slc_chol_band(out, n, int(kd))
    return _mat(out, r, n)


def backsolve(r, x, upper_tri=True, transpose=False):
    """backsolve(r, x, upper.tri, transpose) mit k = ncol(r); Vektor bleibt Vektor."""
    ra, m, n = _fmat(r)
    vec = not _is_mat(x)
    b, bm, bn = _fmat(x)
    if m != n or bm != m:
        raise ValueError("backsolve: Dimensionen passen nicht")
    out = b.copy()
    _ext.slc_trisolve(ra, out, n, bn, bool(upper_tri), bool(transpose))
    return out if vec else _mat(out, bm, bn)


def forwardsolve(l, x, upper_tri=False, transpose=False):  # noqa: E741 (Name wie in R)
    return backsolve(l, x, upper_tri=upper_tri, transpose=transpose)


def solve_spd(a, b=None):
    """solve(a, b) für symmetrisch positiv definites a (oberes Dreieck gelesen); ohne b die Inverse."""
    aa, m, n = _fmat(a)
    if m != n:
        raise ValueError("solve: Matrix nicht quadratisch")
    if b is None:
        out = np.ascontiguousarray(np.eye(n).ravel(order="F"))
        _ext.slc_solve_spd(aa, out, n, n)
        return _mat(out, n, n)
    vec = not _is_mat(b)
    bb, bm, bn = _fmat(b)
    if bm != n:
        raise ValueError("solve: Dimensionen von a und b passen nicht")
    out = bb.copy()
    _ext.slc_solve_spd(aa, out, n, bn)
    return out if vec else _mat(out, bm, bn)


def logdet_spd(a):
    """log det a für symmetrisch positiv definites a (ersetzt determinant(a)$modulus)."""
    aa, m, n = _fmat(a)
    if m != n:
        raise ValueError("determinant: Matrix nicht quadratisch")
    return _ext.slc_logdet_spd(aa, n)


def eigen_sym(x, only_values=False):
    """eigen(x, symmetric = TRUE): absteigend, gelesen wird das untere Dreieck."""
    a, m, n = _fmat(x)
    if m != n:
        raise ValueError("eigen: Matrix nicht quadratisch")
    val = np.empty(n)
    vec = None if only_values else np.empty(n * n)
    _ext.slc_eigen_sym(a, n, val, vec)
    return {"values": val, "vectors": None if vec is None else _mat(vec, n, n)}


# ── Matrixprodukt ──────────────────────────────────────────────────────────

def _err_mm():
    return ValueError("%m%: nicht passende Argumente")


def matmul(x, y):
    """x %*% y mit den Vektorregeln von %*% (1-D-Felder sind Vektoren)."""
    xm, ym = _is_mat(x), _is_mat(y)
    xv, yv = _vec(x), _vec(y)
    if not xm and not ym:
        nx, ny = xv.size, yv.size
        if nx == ny:
            X, Y = (xv, 1, nx), (yv, ny, 1)
        elif nx == 1:
            X, Y = (xv, 1, 1), (yv, 1, ny)
        elif ny == 1:
            X, Y = (xv, nx, 1), (yv, 1, 1)
        else:
            raise _err_mm()
    elif not xm:
        Y = _fmat(y)
        if xv.size == Y[1]:
            X = (xv, 1, xv.size)
        elif Y[1] == 1:
            X = (xv, xv.size, 1)
        else:
            raise _err_mm()
    elif not ym:
        X = _fmat(x)
        if yv.size == X[2]:
            Y = (yv, yv.size, 1)
        elif X[2] == 1:
            Y = (yv, 1, yv.size)
        else:
            raise _err_mm()
    else:
        X, Y = _fmat(x), _fmat(y)
    (a, m, k), (b, k2, n) = X, Y
    if k != k2:
        raise _err_mm()
    out = np.empty(m * n)
    _ext.slc_matmul(a, b, out, m, k, n)
    return _mat(out, m, n)


def crossprod(x, y=None):
    """crossprod(x, y) = t(x) %*% y; Vektoren als Spaltenmatrix."""
    a, m, k = _fmat(x)
    b, m2, n = (a, m, k) if y is None else _fmat(y)
    if m != m2:
        raise ValueError("crossprod: nicht passende Argumente")
    out = np.empty(k * n)
    _ext.slc_crossprod(a, b, out, m, k, n)
    return _mat(out, k, n)


def tcrossprod(x, y=None):
    """tcrossprod(x, y) = x %*% t(y)."""
    a, m, k = _fmat(x)
    b, n, k2 = (a, m, k) if y is None else _fmat(y)
    if k != k2:
        raise ValueError("tcrossprod: nicht passende Argumente")
    out = np.empty(m * n)
    _ext.slc_tcrossprod(a, b, out, m, k, n)
    return _mat(out, m, n)


# ── kleinste Quadrate, Logit-IRLS ──────────────────────────────────────────

def lsfit(x, y, w=None, tol=1e-7, pivot=1):
    """lm.fit/lm.wfit/qr.coef: Householder-QR mit begrenzter Spaltenpivotisierung; ausgefallene
    Koeffizienten NA; pivot 1-basiert."""
    a, m, n = _fmat(x)
    yv = _vec(y)
    if yv.size != m:
        raise ValueError("lm: Längen von x und y passen nicht")
    wv = None if w is None else _vec(w)
    if wv is not None and wv.size != m:
        raise ValueError("lm: Längen von x und w passen nicht")
    coef, fit, perm = np.empty(n), np.empty(m), np.empty(n, dtype=np.int32)
    rank = _ext.slc_lsfit(a, yv, wv, m, n, float(tol), int(pivot), coef, fit, perm)
    return {"coefficients": coef, "fitted.values": fit, "rank": rank, "pivot": perm, "residuals": yv - fit}


def logit_irls(x, y, maxit=25, tol=1e-8):
    """glm(y ~ x, family = binomial()): Koeffizienten per IRLS (x mit Achsenabschnittsspalte)."""
    a, m, n = _fmat(x)
    yv = _vec(y)
    if yv.size != m:
        raise ValueError("glm: Längen von x und y passen nicht")
    coef = np.empty(n)
    conv = _ext.slc_logit_irls(a, yv, m, n, int(maxit), float(tol), coef)
    return {"coefficients": coef, "converged": bool(conv)}


# ── Stineman ───────────────────────────────────────────────────────────────

def stineman(x, y, xout):
    """stinterp(x, y, xout) (skaliert); NA außerhalb [x_1, x_n]."""
    xv, yv, xo = _vec(x), _vec(y), _vec(xout)
    if xv.size != yv.size:
        raise ValueError("stinterp: x und y ungleich lang")
    out = np.empty(xo.size)
    _ext.slc_stineman(xv, yv, xo, out)
    return out


def stineman_slopes(x, y, scale=True):
    xv, yv = _vec(x), _vec(y)
    if xv.size != yv.size:
        raise ValueError("stinterp: x und y ungleich lang")
    out = np.empty(xv.size)
    _ext.slc_stineman_slopes(xv, yv, bool(scale), out)
    return out


def stineman_eval(x, y, yp, xout):
    xv, yv, pv, xo = _vec(x), _vec(y), _vec(yp), _vec(xout)
    if xv.size != yv.size or xv.size != pv.size:
        raise ValueError("stinterp: x, y und yp ungleich lang")
    out = np.empty(xo.size)
    _ext.slc_stineman_eval(xv, yv, pv, xo, out)
    return out


# ── Glättungsspline ────────────────────────────────────────────────────────

def smspline_fit(x, y, w=None, lam=None):
    """smooth.spline(x, y, w, cv = FALSE): Knoten an allen verschiedenen x, lambda per GCV (None)."""
    xv, yv = _vec(x), _vec(y)
    if xv.size != yv.size:
        raise ValueError("smooth.spline: x und y ungleich lang")
    wv = None if w is None else _vec(w)
    if wv is not None and wv.size != xv.size:
        raise ValueError("smooth.spline: x und w ungleich lang")
    n = xv.size
    kn, g, gam = np.empty(n), np.empty(n), np.empty(n)
    nk, lo, df, gcv = _ext.slc_smspline_fit(xv, yv, wv, 0.0 if lam is None else float(lam), kn, g, gam)
    return {"x": kn[:nk].copy(), "y": g[:nk].copy(), "gam": gam[:nk].copy(), "lambda": lo, "df": df, "gcv": gcv}


def smspline_predict(fit, x):
    """predict(fit, x)$y; außerhalb der Knoten lineare Fortsetzung."""
    xo = _vec(x)
    out = np.empty(xo.size)
    _ext.slc_smspline_predict(_vec(fit["x"]), _vec(fit["y"]), _vec(fit["gam"]), xo, out)
    return out


# ── Kerndichte ─────────────────────────────────────────────────────────────

def bw_silverman(x):
    """Bandbreite nach Silvermans Faustregel (wie bw.nrd0)."""
    return _ext.slc_kde_bw(_vec(x))


def kde(x, bw=None, n=512, from_=None, to=None, cut=3, weights=None):
    """density(x): Gauß-Kern, n Gitterpunkte von min(x) - cut bw bis max(x) + cut bw."""
    xv = _vec(x)
    if bw is None:
        bw = bw_silverman(xv)
    ok = xv.size > 0 and bool(np.all(np.isfinite(xv)))     # sonst meldet der Kern den Fehler
    if from_ is None:
        from_ = float(xv.min()) - cut * bw if ok else 0.0
    if to is None:
        to = float(xv.max()) + cut * bw if ok else 1.0
    n = int(n)
    if n < 2:
        raise ValueError("density: mindestens 2 Gitterpunkte")
    gx, gy = np.empty(n), np.empty(n)
    _ext.slc_kde(xv, None if weights is None else _vec(weights), float(bw), float(from_), float(to), gx, gy)
    return {"x": gx, "y": gy, "bw": float(bw), "n": xv.size}
