"""Nachbildung von ``rugarch::ugarchfit`` für die Spezifikation aus ``.fit_garch11``.

Herkunft: R-Paket rugarch 1.5-6 (CRAN, 2026-07-18), ``R/rugarch-*.R`` und
``src/garchmodels.c``, ``src/filters.c``, ``src/distributions.c``; Autoren:
Alexios Galanos [aut, cre, cph], Tobias Kley [ctb]. Lizenz: GPL-3. Nach
Python übertragen und angepasst für SimLev (siehe ``python/COPYRIGHTS.md``);
im R-Paket übernommen als ``.rugarch_ugarchfit`` (``r/R/vendor_rugarch.R``,
``r/src/vendor_rugarch.c``). Hesse-Matrix und Scores rechnet statt numDeriv
die eigenständig geschriebene Richardson-Extrapolation
(``_richardson_hessian``, ``_richardson_jacobian``; im R-Paket
``.sl_richardson_hessian``/``.sl_richardson_jacobian`` in
``r/R/richardson.R``, gegen numDeriv als Prüf-Orakel bitgleich).

R (``r/R/bootstrap.R``, ``.fit_garch11``) schätzt GARCH(1,1) bzw.
GJR-GARCH(1,1) mit der aus rugarch 1.5-6 übernommenen Fassung::

    spec <- ugarchspec(variance.model = list(model = "sGARCH" | "gjrGARCH", garchOrder = c(1, 1)),
                       mean.model = list(armaOrder = c(0, 0), include.mean = TRUE),
                       distribution.model = "norm")
    fit <- ugarchfit(spec = spec, data = e, solver = "hybrid")
    coef(fit)

Nachgebildet sind genau die Schritte dieses Aufrufs:

* ``.sgarchfit``/``.gjrgarchfit`` mit den Voreinstellungen von
  ``fit.control`` (keine Skalierung, ``rec.init = "all"``), Startwerte und
  Schranken aus ``.meqstartpars``, ``.meqstart``, ``.aparchstart``
  (``rugarch-startpars.R``), die Warnung bei weniger als 100 Beobachtungen;
* die Likelihood ``.sgarchLLH``/``.gjrgarchLLH`` mit dem C-Filter
  ``sgarchfilterC``/``gjrgarchfilterC`` (``garchmodels.c``, ``filters.c``,
  ``dnormstd`` aus ``distributions.c``), dem Straf-Wert nach
  ``rugarch_llh`` bei nicht endlicher Likelihood und dem Fehlerweg von
  ``.C`` bei nicht endlichen Argumenten;
* die Stationaritätsbedingung ``.sgarchcon``/``.gjrgarchcon`` (für GJR mit
  ``pneg`` der Normalverteilung, s. ``KAPPA_NORM``);
* ``.hybridsolver``: ``solnp`` (:mod:`simlev._r.solnp`), bei fehlender
  Konvergenz ``nlminb`` (:func:`simlev._r.stats.nlminb`), danach bis zu
  zweimal ``.gosolnpsolver`` (:func:`simlev._r.solnp.gosolnp` mit
  ``n.restarts = 1``, ``n.sim = 500``, gestutzter Normalverteilung um die
  Startwerte, ``rseed = NULL``: der Startwert ist die Uhrzeit,
  :func:`simlev._r.base.sys_time`, und ``set.seed`` überschreibt wie in R
  den globalen Zufallszustand);
* ``.makefitmodel`` (``rugarch-helperfn.R``): Hesse-Matrix per
  Richardson-Extrapolation (``_richardson_hessian``), Prüfung durch ``eigen`` (nur die
  Fehlerprüfung auf nicht endliche Werte, die Eigenwerte gehen nur in
  ``condH`` ein), ``solve`` mit Ersatzweg ``.hessian2sided`` und der
  Warnung „failed to invert hessian“, der Aufruf mit ``returnType = "all"``,
  ``robustvcv`` mit ``neweywestcv`` und die Warnung von ``sqrt`` bei
  negativen Diagonalelementen der robusten Kovarianz; die Scores
  (``_richardson_jacobian``) nur mit ``full = True`` (das Ergebnis geht nicht in ``coef`` ein
  und kann weder warnen noch scheitern);
* die Konvergenzprüfung: bei ``convergence != 0`` ist ``coef(fit)`` leer
  (``None``).

Nicht nachgebildet: andere Modelle, Verteilungen, ARMA-Ordnungen, feste
Parameter, ``out.sample`` und die übrigen Bestandteile des
``uGARCHfit``-Objekts. Die Daten werden wie ein unbenannter Vektor
behandelt (rugarch ordnet benannte Vektoren, deren Namen als Datum lesbar
sind, über ``xts`` nach dem Datum; das ist nicht nachgebildet).
"""
from __future__ import annotations

import math
import warnings

import numpy as np
import pandas as pd

from . import rnum as _rn
from . import libm as _libm
from . import linalg as _la
from . import solnp as _solnp_mod
from .linalg import RError
from .rlist import RList

__all__ = ["ugarchfit", "coef", "UGARCHfit", "KAPPA_NORM"]

_EPS = 2.220446049250313e-16          # rugarch: eps <- .Machine$double.eps
_TINY = 1.0e-8                        # rugarch: TinY
_SQ2PI = math.sqrt(2.0 * math.pi)     # sqrt(2.0 * M_PI) in dnormstd
_PDF_FLOOR = 2.22507e-24              # dnormstd: if (pdf == 0.0) pdf = 0.0 + 2.22507e-24
_ZERO_TOL = math.sqrt(_EPS / 7e-7)    # sqrt(.Machine$double.eps/7e-7)
_EPS13 = _rn.r_pow(_EPS, 1.0 / 3.0)   # eps^(1/3)

# pneg(ghlambda, shape, skew, "norm") = integrate(dnorm, -Inf, 0)$value (QUADPACK dqagi
# in R 4.3.3); der Wert hängt nicht von den Parametern ab und ist hier als Konstante aus R
# übernommen (sprintf("%a", rugarch:::pneg(0, 0, 0, "norm"))).
KAPPA_NORM = float.fromhex("0x1.fffffffe3b5ap-2")


class UGARCHfit(RList):
    """Ergebnis von :func:`ugarchfit` (Auszug aus dem ``uGARCHfit``-Objekt)."""


def _warn(msg):
    warnings.warn(msg, UserWarning, stacklevel=3)


def _rmax2(a, b):
    """``max(a, b)`` wie R (NaN gewinnt)."""
    if a != a:
        return a
    if b != b:
        return b
    return b if b > a else a


def _finite(x):
    return x == x and x not in (math.inf, -math.inf)


# ── Likelihood ──────────────────────────────────────────────────────────────

class _GarchEnv:
    """``garchenv`` (``rugarch_llh``, ``rugarch_csol``)."""

    __slots__ = ("llh", "csol")

    def __init__(self):
        self.llh = 1.0
        self.csol = 0


class _LLH:
    """``.sgarchLLH``/``.gjrgarchLLH`` für ARMA(0,0) mit Mittelwert und Normalverteilung."""

    def __init__(self, data, gjr, env):
        self.x = np.asarray(data, dtype=np.float64)
        self.T = self.x.size
        self.gjr = gjr
        self.env = env
        self.var_data = None

    def _penalty(self):
        v = self.env.llh
        return v + 0.1 * abs(v)

    def __call__(self, pars, returnType="llh"):
        x = self.x
        T = self.T
        p = np.asarray(pars, dtype=np.float64).ravel()
        mu = float(p[0])
        om = float(p[1])
        al = float(p[2])
        be = float(p[3])
        ga = float(p[4]) if self.gjr else 0.0
        # .arfimaxfilter (ARMA(0,0)): res = data - mu - imx - archm * h^0 (imx = 0, archm = 0)
        with np.errstate(all="ignore"):
            res = ((x - mu) - 0.0) - 0.0 * 1.0
            res[~np.isfinite(res)] = 0.0
            if self.gjr:
                persist = (al + be) + ga * KAPPA_NORM
            else:
                persist = al + be
            mvar = _rn.r_mean(res * res)
        hEst = mvar
        om = _rmax2(_EPS, om)
        if not _finite(hEst):
            if self.var_data is None:
                self.var_data = _rn.r_var(x)
            hEst = self.var_data * (1 - persist)
        # .C(..., NAOK = FALSE): nicht endliche Argumente -> Fehler -> try-error
        if not (_finite(mu) and _finite(om) and _finite(al) and _finite(be) and _finite(ga)
                and _finite(hEst)):
            self.env.csol = 1
            return self._penalty()
        self.env.csol = 0
        with np.errstate(all="ignore"):
            cm = 0.0 + mu                     # condm[i] += constm[i]
            r = x - cm                        # res[i] = x[i] - condm[i]
            e = r * r
            h = np.empty(T)
            if T > 0:
                h[0] = hEst
            el = e.tolist()
            if self.gjr:
                nres = np.where(r < 0.0, e, 0.0)
                nl = nres.tolist()
                hp = hEst
                for i in range(1, T):
                    hp = (((0.0 + om) + al * el[i - 1]) + ga * nl[i - 1]) + be * hp
                    h[i] = hp
            else:
                hp = hEst
                for i in range(1, T):
                    hp = ((0.0 + om) + al * el[i - 1]) + be * hp
                    h[i] = hp
            sh = np.sqrt(np.abs(h))
            z = r / sh
            pdf = np.asarray(_libm.exp((-0.5 * z) * z), dtype=np.float64) / _SQ2PI
            pdf[pdf == 0.0] = 0.0 + _PDF_FLOOR
            LHT = np.asarray(_libm.log(pdf / sh), dtype=np.float64)
            lk = float(np.cumsum(np.concatenate([[0.0], -LHT]))[-1]) if T else 0.0
        llh = lk
        if _finite(llh):
            self.env.llh = llh
        else:
            llh = self._penalty()
        if returnType == "llh":
            return llh
        if returnType == "LHT":
            return -LHT
        return {"llh": llh, "h": h, "epsx": r, "z": z, "LHT": -LHT, "persistence": persist}


# ── numerische Ableitungen (Richardson-Extrapolation, eigenständig) ─────────
#
# Eigenständig geschrieben nach dem veröffentlichten Verfahren (zentrale
# Differenzen, Schrittweite |d x| bzw. zusätzlich eps nahe null, r Stufen mit
# Faktor v, Richardson-Extrapolation; Beschreibung in der Dokumentation von
# numDeriv, Linfield & Penny 1989). Kein Code aus numDeriv; wie im R-Paket
# (``.sl_richardson_hessian``/``.sl_richardson_jacobian`` in
# ``r/R/richardson.R``), dort gegen numDeriv als Prüf-Orakel bitgleich.
# Auswertungsfolge und Klammerung sind fest: die Likelihood merkt sich ihren
# letzten endlichen Wert (Strafwert), jede andere Folge ändert das Ergebnis.

def _richardson_steps(x, d, eps, zero_tol):
    """Anfangsschritt je Koordinate: ``|d x|``, nahe null zusätzlich ``eps``."""
    with np.errstate(all="ignore"):
        return np.abs(d * x) + eps * (np.abs(x) < zero_tol)


def _richardson_collapse(tab, v):
    """Tableau (letzte Achse = Stufen, grob zuerst) auf den extrapolierten Wert falten.

    Schritt ``m`` tilgt den Fehlerterm ``h^(2m)`` mit dem Gewicht ``w = v^(2m)``:
    ``neu_k = (alt_(k+1) * w - alt_k) / (w - 1)``.
    """
    lvl = 0
    with np.errstate(all="ignore"):
        while tab.shape[-1] > 1:
            lvl += 1
            w = _rn.r_pow(float(v), 2.0 * lvl)
            tab = (tab[..., 1:] * w - tab[..., :-1]) / (w - 1)
    return tab[..., 0]


def _richardson_hessian(f, x, eps=1e-4, d=0.1, zero_tol=_ZERO_TOL, r=4, v=2):
    """Hesse-Matrix einer skalaren Funktion (``.sl_richardson_hessian``)."""
    x = np.asarray(x, dtype=np.float64)
    p = x.size
    f(x)                              # Prüfauswertung (skalar), wie in R
    centre = f(x)
    start = _richardson_steps(x, d, eps, zero_tol)
    axis = np.eye(p)
    tab = np.zeros(r)
    pure = np.zeros(p)
    with np.errstate(all="ignore"):
        # reine zweite Ableitungen, Achse für Achse
        for a in range(p):
            h = start
            for s in range(r):
                fwd = f(x + h * axis[:, a])
                bwd = f(x - h * axis[:, a])
                tab[s] = ((fwd - 2 * centre) + bwd) / (h[a] * h[a])
                h = h / v
            pure[a] = _richardson_collapse(tab, v)
        # gemischte Ableitungen im unteren Dreieck (a > b), zeilenweise
        low = np.zeros((p, p))
        for a in range(p):
            low[a, a] = pure[a]
            for b in range(a):
                h = start
                for s in range(r):
                    fwd = f(x + h * axis[:, a] + h * axis[:, b])
                    bwd = f(x - h * axis[:, a] - h * axis[:, b])
                    tab[s] = ((((fwd - 2 * centre) + bwd) - pure[a] * (h[a] * h[a]))
                              - pure[b] * (h[b] * h[b])) / (2 * h[a] * h[b])
                    h = h / v
                low[a, b] = _richardson_collapse(tab, v)
        # symmetrisch ergänzen, verdoppelte Diagonale halbieren
        hess = low + low.T
        hess[np.diag_indices(p)] = np.diag(hess) / 2
    return hess


def _richardson_jacobian(f, x, eps=1e-4, d=1e-4, zero_tol=_ZERO_TOL, r=4, v=2):
    """Jacobi-Matrix ``len(f(x))`` x ``len(x)`` (``.sl_richardson_jacobian``)."""
    x = np.asarray(x, dtype=np.float64)
    p = x.size
    q = np.asarray(f(x), dtype=np.float64).size
    h = _richardson_steps(x, d, eps, zero_tol)
    axis = np.eye(p)
    tab = np.full((q, p, r), np.nan)  # Einträge x Stufen
    with np.errstate(all="ignore"):
        for s in range(r):
            for a in range(p):
                fwd = np.asarray(f(x + h * axis[:, a]), dtype=np.float64)
                bwd = np.asarray(f(x - h * axis[:, a]), dtype=np.float64)
                tab[:, a, s] = (fwd - bwd) / (2 * h[a])
            h = h / v
    return _richardson_collapse(tab, v).copy()


def _hessian2sided(f, x):
    """``.hessian2sided(f, x, ...)`` (rugarch-numderiv.R)."""
    x = np.asarray(x, dtype=np.float64)
    n = x.size
    with np.errstate(all="ignore"):
        fx = f(x)
        h = np.array([_rmax2(abs(z * _EPS13), 1e-9) for z in x.tolist()])
        xh = x + h
        h = xh - x
        ee = np.diag(h) if n > 1 else h.reshape(1, 1)
        gp = np.array([f(x + ee[:, i]) for i in range(n)])
        gm = np.array([f(x - ee[:, i]) for i in range(n)])
        H = _solnp_mod._outer(h)
        Hp = H.copy()
        Hm = H.copy()
        for i in range(n):
            for j in range(i, n):
                Hp[i, j] = f(x + ee[:, i] + ee[:, j])
                Hp[j, i] = Hp[i, j]
                Hm[i, j] = f(x - ee[:, i] - ee[:, j])
                Hm[j, i] = Hm[i, j]
        for i in range(n):
            for j in range(i, n):
                H[i, j] = ((((((((Hp[i, j] - gp[i]) - gp[j]) + fx) + fx) - gm[i]) - gm[j])
                            + Hm[i, j]) / H[i, j]) / 2
                H[j, i] = H[i, j]
    return H


def _neweywestcv(data, nlag):
    """``neweywestcv(data, nlag, center = TRUE)`` (Newey-West, Bartlett-Gewichte)."""
    from . import base as _base
    X = np.asarray(data, dtype=np.float64)
    N = X.shape[0]
    with np.errstate(all="ignore"):
        cmeans = np.asarray(_base.colMeans(X), dtype=np.float64)
        X = X - cmeans[None, :]
        bw = ((nlag + 1) - np.arange(0.0, nlag + 1.0)) / (nlag + 1)
        cv = (1 / N) * _solnp_mod._mm(X.T, X)
        for i in range(1, int(nlag) + 1):
            if N - i < 2 or N - (i + 1) + 1 < 2:
                raise RError("non-conformable arrays")
            gmi = (1 / N) * _solnp_mod._mm(X[i:N, :].T, X[0:N - i, :])
            gpp = gmi + gmi.T
            cv = cv + bw[i] * gpp
    return cv


def _robustvcv(fun, pars, nlag, hess, n):
    """``robustvcv(fun, pars, nlag, hess, n, ...)`` (rugarch-numderiv.R)."""
    pars = np.asarray(pars, dtype=np.float64)
    k = pars.size
    with np.errstate(all="ignore"):
        h = np.array([_rmax2(abs(z * _EPS13), 1e-9) for z in pars.tolist()])
        hplus = pars + h
        hminus = pars - h
        plus = np.empty((n, k))
        minus = np.empty((n, k))
        rows_p = []
        rows_m = []
        for i in range(k):
            rp = pars.copy()
            rp[i] = hplus[i]
            rows_p.append(rp)
            rm = pars.copy()
            rm[i] = hminus[i]
            rows_m.append(rm)
        for i in range(k):
            plus[:, i] = _lht_vec(fun(rows_p[i]), n)
        for i in range(k):
            minus[:, i] = _lht_vec(fun(rows_m[i]), n)
        scores = (plus - minus) / (2 * h[None, :])
        A = hess / n
    try:
        Ainv = np.asarray(_la.solve(A), dtype=np.float64)
    except RError:
        # vcv = NA; B ist nicht gesetzt -> list(vcv = vcv, B = B, ...) scheitert
        raise RError("object 'B' not found") from None
    with np.errstate(all="ignore"):
        if nlag > 0:
            B = _neweywestcv(scores, nlag)
        else:
            from . import stats as _st
            B = np.asarray(_st.cov(scores), dtype=np.float64)
        vcv = _solnp_mod._mm(_solnp_mod._mm(Ainv, B), Ainv) / n
    return {"vcv": vcv, "B": B, "A": A, "info": 0, "scores": scores}


def _lht_vec(v, n):
    v = np.asarray(v, dtype=np.float64).ravel()
    if v.size != n:
        # .C-Fehler: die Likelihood liefert einen Skalar statt der Scores; apply() ergibt dann
        # eine Liste und die Differenz scheitert
        raise RError("non-numeric argument to binary operator")
    return v


# ── Solver ──────────────────────────────────────────────────────────────────

def _solnpsolver(pars, fun, ifn, ilb, iub, control, LB, UB, names):
    try:
        ans = _solnp_mod.solnp(pars, fun, ineqfun=ifn, ineqLB=ilb, ineqUB=iub, LB=LB, UB=UB,
                               control=control)
    except RError as exc:
        _warn("\nrugarch-->warning: no convergence...\n")
        return {"convergence": 1, "message": str(exc), "par": np.full(len(pars), _rn.NA_REAL),
                "solver": "solnp"}
    return {"convergence": int(ans["convergence"]), "message": None,
            "par": np.asarray(ans["pars"], dtype=np.float64), "solver": "solnp", "raw": ans}


def _nlminbsolver(pars, fun, parscale, control, LB, UB):
    from . import stats as _st
    try:
        with np.errstate(all="ignore"):
            scale = 1 / parscale
        ans = _st.nlminb(pars, lambda p: fun(np.asarray(p, dtype=np.float64)), scale=scale,
                         control=control, lower=LB, upper=UB)
    except RError as exc:
        return {"convergence": 1, "message": str(exc), "par": np.full(len(pars), _rn.NA_REAL),
                "solver": "nlminb"}
    return {"convergence": int(ans["convergence"]), "message": ans["message"],
            "par": np.asarray(ans["par"], dtype=np.float64), "solver": "nlminb", "raw": ans}


_SOLNP_CTRL = {"rho": 1.0, "outer.iter": 50.0, "inner.iter": 1800.0, "delta": 1.0e-8,
               "tol": 1.0e-8, "trace": 0.0}             # rugarch:::.solnpctrl(list())
_NLMINB_CTRL = {"eval.max": 2000, "trace": 0, "iter.max": 1500, "abs.tol": 1e-20,
                "rel.tol": 1e-10, "x.tol": 1.5e-8, "step.min": 2.2e-14}   # .nlminbctrl(list())


def _gosolnpsolver(pars, fun, ifn, ilb, iub, LB, UB):
    """``.gosolnpsolver`` mit ``gocontrol = list()`` (``.gosolnpctrl``: ``n.restarts = 1``,
    ``n.sim = 500``, ``rseed = NULL``, ohne Parallelisierung).

    ``options(warn = 0)`` und das Zurücksetzen der Optionen haben in der
    Nachbildung keine Entsprechung (Warnungen werden immer gemeldet).
    """
    pars = np.asarray(pars, dtype=np.float64)
    distr_opt = []
    with np.errstate(all="ignore"):
        for p in pars.tolist():
            distr_opt.append({"mean": p, "sd": 0.1 if p == 0 else math.sqrt(p * p) * 2})
    try:
        ans = _solnp_mod.gosolnp(pars=pars, fixed=None, fun=fun, eqfun=None, eqB=None, ineqfun=ifn,
                                 ineqLB=ilb, ineqUB=iub, LB=LB, UB=UB, control=_SOLNP_CTRL,
                                 distr=[2.0] * len(LB), distr_opt=distr_opt, n_restarts=1,
                                 n_sim=500, cluster=None, rseed=None)
    except RError as exc:
        return {"convergence": 1, "message": str(exc), "par": np.full(len(pars), _rn.NA_REAL),
                "solver": "gosolnp"}
    return {"convergence": int(ans["convergence"]), "message": None,
            "par": np.asarray(ans["pars"], dtype=np.float64), "solver": "gosolnp", "raw": ans}


def _hybridsolver(pars, fun, ifn, ilb, iub, parscale, LB, UB, names):
    ans = _solnpsolver(pars, fun, ifn, ilb, iub, _SOLNP_CTRL, LB, UB, names)
    ans["path"] = ["solnp"]
    if ans["convergence"] >= 1:
        path = ans["path"]
        ans = _nlminbsolver(pars, fun, parscale, _NLMINB_CTRL, LB, UB)
        ans["path"] = path = path + ["nlminb"]
        if ans["convergence"] >= 1:
            ans = _gosolnpsolver(pars, fun, ifn, ilb, iub, LB, UB)
            ans["path"] = path = path + ["gosolnp"]
            if ans["convergence"] >= 1:
                ans = _gosolnpsolver(pars, fun, ifn, ilb, iub, LB, UB)
                ans["path"] = path + ["gosolnp"]
    return ans


# ── ugarchfit ───────────────────────────────────────────────────────────────

def ugarchfit(data, model="sGARCH", solver="hybrid", full=False):
    """``ugarchfit(spec, data, solver = "hybrid")`` mit der Spezifikation aus ``.fit_garch11``.

    Argumente:
        data: Beobachtungen (numerischer Vektor, wird wie ein unbenannter
            Vektor behandelt).
        model: ``"sGARCH"`` oder ``"gjrGARCH"`` (GARCH(1,1), ARMA(0,0) mit
            Mittelwert, Normalverteilung).
        solver: nur ``"hybrid"`` (wie in ``.fit_garch11``).
        full: zusätzlich die Scores (``_richardson_jacobian``) berechnen.

    Ergebnis: :class:`UGARCHfit` mit ``coef`` (benannte ``Series`` oder
    ``None`` wie ``coef(fit)``), ``convergence``, ``message``,
    ``solver_path`` (durchlaufene Solver), ``LLH``, ``hessian``, ``cvar``,
    ``robust_cvar``, ``scores`` (nur mit ``full``) und ``persistence``.

    Warnungen und Fehler wie rugarch. Erreicht die Solver-Kette ``gosolnp``,
    zieht es wie in R Zufallsstartwerte und setzt dabei den globalen
    Zufallszustand mit ``set.seed(as.numeric(Sys.time()))``
    (:func:`simlev._r.base.sys_time`, Prüfschalter ``SIMLEV_R_SYS_TIME``).
    """
    if model not in ("sGARCH", "gjrGARCH"):
        raise ValueError("rugarch-Nachbildung: nur model = \"sGARCH\" oder \"gjrGARCH\"")
    if solver != "hybrid":
        raise ValueError("rugarch-Nachbildung: nur solver = \"hybrid\"")
    gjr = model == "gjrGARCH"
    if isinstance(data, pd.Series):
        x = data.to_numpy(dtype=np.float64).copy()
    else:
        x = np.atleast_1d(np.asarray(data, dtype=np.float64)).ravel().copy()
    n = x.size
    if n < 100:
        _warn("\nugarchfit-->waring: using less than 100 data\n points for estimation\n")
    T = n
    env = _GarchEnv()
    llh = _LLH(x, gjr, env)
    # Startwerte und Schranken (.meqstartpars, .meqstart, .aparchstart)
    mdat = _rn.r_mean(x)
    vdat = _rn.r_var(x)
    names = ["mu", "omega", "alpha1", "beta1"] + (["gamma1"] if gjr else [])
    with np.errstate(all="ignore"):
        if mdat == 0:
            mu_lb, mu_ub = -0.5, 0.5
        else:
            mu_lb, mu_ub = -100 * abs(mdat), 100 * abs(mdat)
        start = [mdat, vdat / 1000, 0.05 / 1, 0.9 / 1] + ([0.05 / 1] if gjr else [])
        LB = [mu_lb, _EPS, 0.0, 0.0] + ([-1 + _TINY] if gjr else [])
        UB = [mu_ub, vdat * 1000, 1 - _TINY, 1 - _TINY] + ([1 - _TINY] if gjr else [])
        parscale = [abs(mdat), vdat, 1.0, 1.0] + ([1.0] if gjr else [])
    start = np.array(start, dtype=np.float64)
    LB = np.array(LB, dtype=np.float64)
    UB = np.array(UB, dtype=np.float64)
    parscale = np.array(parscale, dtype=np.float64)

    def fun(p, *a):
        return llh(p, "llh")

    if gjr:
        def ifn(p, *a):
            p = np.asarray(p, dtype=np.float64)
            con = (p[3] + p[2]) + p[4] * KAPPA_NORM       # .persistgjrgarch1
            return np.array([1.0 if con != con else con])
    else:
        def ifn(p, *a):
            p = np.asarray(p, dtype=np.float64)
            return np.array([p[2] + p[3]])                  # .persistsgarch1

    sol = _hybridsolver(start, fun, ifn, _EPS, 0.999, parscale, LB, UB, names)
    par = np.asarray(sol["par"], dtype=np.float64).copy()
    with np.errstate(all="ignore"):
        par = par * np.array([1.0, 1.0, 1.0, 1.0] + ([1.0] if gjr else []))   # * dscale (= 1)
    convergence = sol["convergence"]
    if convergence != 0 and not gjr:
        _warn("\nugarchfit-->warning: solver failer to converge.")
    out = UGARCHfit()
    out["coef"] = None
    out["convergence"] = 1 if convergence != 0 else 0
    out["message"] = sol.get("message")
    out["solver_path"] = sol.get("path")
    if convergence != 0:
        return out
    fit = _makefitmodel(llh, par, T, full)
    out["coef"] = pd.Series(par, index=names)
    out.update(fit)
    out["convergence"] = 0
    return out


def _makefitmodel(llh, par, T, full):
    """``.makefitmodel`` (ohne feste Parameter): Hesse-Matrix, Kovarianzen, Prüfungen."""
    def f(p):
        return llh(p, "llh")

    H = _richardson_hessian(f, par, eps=1e-4, d=0.1, zero_tol=_ZERO_TOL, r=4, v=2)
    if not np.isfinite(H).all():                      # eigen(): Prüfung der Eingabe
        raise RError("infinite or missing values in 'x'")
    try:
        cvar = np.asarray(_la.solve(H), dtype=np.float64)
    except RError:
        try:
            cvar = np.asarray(_la.solve(_hessian2sided(f, par)), dtype=np.float64)
        except RError:
            cvar = None
            _warn("\nrugarch-->warning: failed to invert hessian\n")
    temp = llh(par, "all")
    if not isinstance(temp, dict):
        raise RError("$ operator is invalid for atomic vectors")
    out = {"LLH": -temp["llh"], "hessian": H, "cvar": cvar, "robust_cvar": None, "scores": None,
           "persistence": temp["persistence"]}
    if cvar is not None:
        nlag = min(math.floor(1.2 * _rn.r_pow(float(T), 1.0 / 3.0)), T)

        def flht(p):
            return llh(p, "LHT")

        rv = _robustvcv(flht, par, nlag, H, T)
        out["robust_cvar"] = rv["vcv"]
        if full:
            out["scores"] = _richardson_jacobian(flht, par, eps=1e-4, d=1e-4, zero_tol=_ZERO_TOL,
                                               r=4, v=2)
        dg = np.diag(rv["vcv"])
        if np.any(dg < 0):                           # sqrt(diag(fit$robust.cvar))
            _warn("NaNs produced")
    return out


def coef(fit):
    """``coef(fit)`` eines :class:`UGARCHfit` (benannte ``Series`` oder ``None``)."""
    return fit["coef"]


from .base import quiet_fp  # noqa: E402

quiet_fp(globals(), ["ugarchfit", "coef"])
