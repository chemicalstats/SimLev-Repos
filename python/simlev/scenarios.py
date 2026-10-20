"""Szenarien mit eigenen Annahmen und Stresstests (Port von ``r/R/scenarios.R``).

- :func:`entropy_pooling`   gewichtet Szenarien so um, dass sie eigene Annahmen
  ("Views") erfüllen, bei minimaler relativer Entropie (Meucci 2008)
- :func:`view_mean`, :func:`view_prob`, :func:`view_vol`   Bausteine für Annahmen
- :func:`copula_scenarios`  Szenarien aus t- bzw. Gauss-Copula mit empirischen
  Rändern, optional unter Stress
- :func:`scenario_risk`     Portfolio-Kennzahlen auf (gewichteten) Szenarien
- :func:`crisis_replay`     ein Portfolio durch historische Krisenfenster
"""
from __future__ import annotations

import math
import warnings
from collections.abc import Mapping

import numpy as np
import pandas as pd

from . import dependence as _dep
from ._r import fmt as _fmt
from ._r import libm as _libm
from ._r.rlist import RList
from ._rnum import LD, r_colsums, r_cumprod, r_rowsums, r_sd, r_sum

__all__ = ["view_mean", "view_prob", "view_vol", "entropy_pooling", "copula_scenarios", "scenario_risk",
           "crisis_replay", "SimLevScenarios"]

_NAN = _fmt.NA_REAL      # R's NA_real_ (alle Verwendungen hier sind NA)


def _match_arg(arg, choices):
    from .data_prep import _match_arg as f
    return f(arg, choices)


def _is_num_scalar(v):
    return isinstance(v, (int, float, np.integer, np.floating)) and not isinstance(v, (bool, np.bool_))


def _view_value(value, what, lo=-math.inf, hi=math.inf):
    """Zielwert einer Annahme prüfen (eine endliche Zahl, ggf. mit Bereich)."""
    a = np.atleast_1d(np.asarray(value, dtype=object)) if value is not None else np.zeros(0, dtype=object)
    ok = a.size == 1 and _is_num_scalar(a[0]) and math.isfinite(float(a[0])) and lo <= float(a[0]) <= hi
    if not ok:
        if math.isfinite(lo) and math.isfinite(hi):
            rng = _fmt.sprintf(" zwischen %g und %g", lo, hi)
        elif math.isfinite(lo):
            rng = _fmt.sprintf(" >= %g", lo)
        else:
            rng = ""
        got = _dep._fmt1(value) if value is not None and a.size else ""
        raise ValueError("%s: value muss eine endliche Zahl%s sein (erhalten: %s)." % (what, rng, got))
    return value


def view_mean(var, value, op=("=", "<=", ">=")):
    """Annahme an den Erwartungswert einer Spalte (Einheit der Spalte)."""
    v = _view_value(value, "view_mean")
    return {"type": "mean", "var": var, "value": v, "op": _match_arg(op, ("=", "<=", ">="))}


def view_prob(expr, value, op=("=", "<=", ">=")):
    """Annahme an die Wahrscheinlichkeit eines Ereignisses (Ausdruck in R-Syntax über die Spalten,
    z. B. ``"aktien < -2 & inflation > 2"``; siehe :mod:`simlev._r.rexpr`)."""
    v = _view_value(value, "view_prob", 0, 1)
    return {"type": "prob", "expr": expr, "value": v, "op": _match_arg(op, ("=", "<=", ">="))}


def view_vol(var, value, op=("=", "<=", ">=")):
    """Annahme an die Standardabweichung einer Spalte (Einheit der Spalte, >= 0)."""
    v = _view_value(value, "view_vol", 0)
    return {"type": "vol", "var": var, "value": v, "op": _match_arg(op, ("=", "<=", ">="))}


def _scen_frame(x, assets, states, frequency):
    """Szenario-Tabelle aus Daten (Renditen in Prozent je Periode, Zustände verzögert)."""
    if isinstance(x, pd.DataFrame) and "date" in x.columns:
        rd = _dep._dep_returns(x, assets, states, frequency)
        for a in _dep._as_names(assets):
            rd[a] = 100 * _libm.expm1(rd[a].to_numpy(dtype=np.float64))
        ok = _dep._complete_rows(*[rd[c].to_numpy() for c in rd.columns])
        return rd.loc[ok]
    if isinstance(x, pd.DataFrame):
        return x
    if isinstance(x, Mapping):
        return pd.DataFrame(dict(x))
    a = np.asarray(x)
    if a.ndim == 1:
        a = a.reshape(-1, 1)
    return pd.DataFrame(a, columns=["V%d" % (j + 1) for j in range(a.shape[1])])


def _cov2cor(V):
    V = np.asarray(V, dtype=np.float64)
    p = V.shape[0]
    Is = np.sqrt(1 / np.diag(V))
    r = Is.reshape(-1, 1) * V * Is.reshape(1, -1)
    r[np.arange(p), np.arange(p)] = 1.0
    return r


def _eval_expr(expr, S, env=None):
    """``as.numeric(eval(parse(text = expr), S, env))`` (R-Syntax über :mod:`simlev._r.rexpr`)."""
    from ._r import rexpr as _rexpr
    v = _dep._eval_condition(expr, S, env)
    return _rexpr.as_numeric(v) if isinstance(expr, str) else np.asarray(v)


class SimLevScenarios(RList):
    """Szenarien aus :func:`entropy_pooling` bzw. :func:`copula_scenarios`."""

    r_class = ("SimLevScenarios",)

    def format(self):
        x = self
        fr = {"week": "Woche", "day": "Tag", "month": "Monat"}[x["frequency"]]
        lines = [_fmt.sprintf("SimLev-Szenarien (%s): %d Szenarien, effektiv %.0f, Renditen in %% je %s",
                              x["kind"], len(x["scenarios"]), float(x["effective_n"]), fr)]
        cop = x.get("copula")
        if cop is not None:
            st = x.get("stress")
            extra = ""
            if st:
                extra = ", Stress: " + "; ".join(_fmt.sprintf("%s in [%g, %g]", k, float(np.asarray(b, float)[0]),
                                                             float(np.asarray(b, float)[1])) for k, b in st.items())
            lines.append(_fmt.sprintf("Copula: %s, Freiheitsgrade %.1f%s", cop["family"], float(cop["df"]), extra))
        s = x["summary"]
        y = pd.DataFrame({"Variable": s["var"].to_numpy(dtype=object),
                          "Mittel vorher": _dep._sprintf_vec("%.3f", s["mean_prior"].to_numpy(dtype=np.float64)),
                          "Mittel nachher": _dep._sprintf_vec("%.3f", s["mean_post"].to_numpy(dtype=np.float64)),
                          "Sd vorher": _dep._sprintf_vec("%.3f", s["sd_prior"].to_numpy(dtype=np.float64)),
                          "Sd nachher": _dep._sprintf_vec("%.3f", s["sd_post"].to_numpy(dtype=np.float64))})
        lines.append(_fmt.print_data_frame(y, row_names=False))
        lines.append("\nKorrelation nachher")
        C = x["correlation"]
        if isinstance(C, pd.DataFrame):
            lines.append(_fmt.print_matrix(pd.DataFrame(_fmt.r_round(C.to_numpy(dtype=np.float64), 3),
                                                        index=C.index, columns=C.columns)))
        else:
            lines.append(_fmt.print_matrix(_fmt.r_round(np.asarray(C, dtype=np.float64), 3)))
        return "\n".join(lines)


def entropy_pooling(x, assets, views, states=None, frequency=("week", "day", "month"), prior=None, env=None):
    """Entropy Pooling: Szenarien auf eigene Annahmen umgewichten.

    Args:
        x: DataFrame mit ``date`` und Kursspalten oder fertige Szenario-Tabelle.
        assets: Anlagespalten.
        views: Liste von Annahmen aus :func:`view_mean`, :func:`view_prob`, :func:`view_vol`.
        states: Zustandsspalten (bei Kursdaten verzögert).
        frequency: ``"week"`` (Standard), ``"day"`` oder ``"month"``.
        prior: Ausgangswahrscheinlichkeiten (ein Wert je Szenario; ``None`` = gleichverteilt).
        env: Mapping für freie Variablen und Funktionen in den Ausdrücken von
            :func:`view_prob` (Voreinstellung: Namensraum des Aufrufers).

    Returns:
        :class:`SimLevScenarios`.
    """
    frequency = _match_arg(frequency, ("week", "day", "month"))
    if env is None:
        import inspect
        fr = inspect.currentframe().f_back
        env = dict(fr.f_globals)
        env.update(fr.f_locals)
        del fr
    assets = _dep._as_names(assets)
    states_l = _dep._as_names(states)
    S = _scen_frame(x, assets, states, frequency)
    Tn = len(S)
    if prior is not None:
        pa = np.atleast_1d(np.asarray(prior.to_numpy() if isinstance(prior, pd.Series) else prior))
        isnum = pa.dtype.kind in "fiu"
        bad = (not isnum or pa.size != Tn)
        if not bad:
            pf = pa.astype(np.float64)
            bad = (not np.isfinite(pf).all()) or (pf < 0).any() or r_sum(pf) <= 0
        if bad:
            neg = ", negative Werte" if isnum and (pa.astype(np.float64)[~np.isnan(pa.astype(np.float64))] < 0).any() else ""
            raise ValueError("entropy_pooling: prior muss %d endliche Werte >= 0 mit positiver Summe haben (einer je Szenario; "
                             "erhalten: Länge %d%s)." % (Tn, pa.size, neg))
        p = pa.astype(np.float64)
    else:
        p = np.full(Tn, 1 / Tn)
    p = p / r_sum(p)
    vars_ = [v for v in dict.fromkeys(assets + states_l) if v in S.columns]
    cols = {v: S[v].to_numpy(dtype=np.float64) for v in vars_}
    m0 = {v: r_sum(p * cols[v]) for v in vars_}
    mean_view = {}
    views = list(views) if views is not None else []
    for v in views:
        if v["type"] == "mean" and v["op"] == "=":
            mean_view[v["var"]] = v["value"]
    rows = []
    for v in views:
        t = v["type"]
        if t == "mean":
            f = S[v["var"]].to_numpy(dtype=np.float64) if v["var"] in S.columns else None
        elif t == "prob":
            f = _eval_expr(v["expr"], S, env)
            f = np.atleast_1d(np.asarray(f, dtype=np.float64))
        elif t == "vol":
            if v["var"] in S.columns:
                mu = mean_view.get(v["var"], m0.get(v["var"], _NAN))
                if mu is None or (isinstance(mu, float) and math.isnan(mu)):
                    mu = m0.get(v["var"], _NAN)
                d = S[v["var"]].to_numpy(dtype=np.float64) - mu
                f = d * d
            else:
                f = np.zeros(0)
        else:
            raise ValueError("Unbekannter View-Typ.")
        if f is None or len(f) != Tn:
            raise ValueError("View '%s' passt nicht zu den Szenarien." % (v.get("var") if v.get("var") is not None else v.get("expr")))
        if t == "vol" and not (_is_num_scalar(v["value"]) and v["value"] >= 0):
            raise ValueError("view_vol: Standardabweichung muss >= 0 sein.")
        val = float(v["value"]) * float(v["value"]) if t == "vol" else float(v["value"])
        sg = {"=": 0, "<=": 1, ">=": -1}[v["op"]]
        rows.append((-f if sg == -1 else f, -val if sg == -1 else val, sg != 0))
    la = _dep._linalg()
    if not rows:
        q = p
    else:
        A = np.vstack([r[0] for r in rows])
        b = np.array([r[1] for r in rows], dtype=np.float64)
        ineq = np.array([r[2] for r in rows], dtype=bool)

        def dual(l):
            l = np.asarray(l, dtype=np.float64)
            e = -np.asarray(la.crossprod(A, l.reshape(-1, 1)), dtype=np.float64).ravel()
            mx = _dep._rmax(e)
            w = p * _libm.exp(e - mx)
            Z = r_sum(w)
            return math.log(Z) + mx + r_sum(l * b), w / Z

        def fn(l):
            return dual(l)[0]

        def gr(l):
            q_ = dual(l)[1]
            return b - np.asarray(la.matprod(A, q_.reshape(-1, 1)), dtype=np.float64).ravel()
        lower = np.where(ineq, 0.0, -math.inf)
        o = _dep._stats().optim(np.zeros(b.size), fn, gr, method="L-BFGS-B", lower=lower,
                                control={"maxit": 5000, "factr": 1e3, "pgtol": 1e-12})
        q = dual(np.asarray(o["par"], dtype=np.float64))[1]
        viol = np.asarray(la.matprod(A, q.reshape(-1, 1)), dtype=np.float64).ravel() - b
        viol[ineq] = np.maximum(viol[ineq], 0)
        mv = _dep._rmax(np.abs(viol))
        if mv > 1e-4 * _dep._rmax(1, np.abs(b)):
            warnings.warn("Annahmen nicht vollständig erfüllbar (Abweichung %s)." % _fmt.sprintf("%.2e", mv))

    def wsd(v, w):
        m = r_sum(w * v)
        d = v - m
        return math.sqrt(r_sum(w * (d * d)))
    summ = pd.DataFrame({"var": vars_, "mean_prior": [m0[v] for v in vars_],
                         "mean_post": [r_sum(q * cols[v]) for v in vars_],
                         "sd_prior": [wsd(cols[v], p) for v in vars_], "sd_post": [wsd(cols[v], q) for v in vars_]})
    Xa = S[assets].to_numpy(dtype=np.float64)
    mu = r_colsums(Xa * q.reshape(-1, 1))
    C = np.asarray(la.crossprod((Xa - mu.reshape(1, -1)) * np.sqrt(q).reshape(-1, 1)), dtype=np.float64)
    Cc = np.asarray(_dep._stats().cov2cor(C), dtype=np.float64)
    Cc[np.isnan(Cc)] = _fmt.R_NAN            # arithmetisch entstanden: NaN (nicht NA) wie in R
    qp = q[q > 0]
    out = SimLevScenarios()
    out["scenarios"] = S
    out["prob"] = q
    out["prior"] = p
    out["assets"] = assets
    out["states"] = states
    out["views"] = views
    out["effective_n"] = _libm.exp(-r_sum(qp * _libm.log(qp)))
    out["summary"] = summ
    out["correlation"] = pd.DataFrame(Cc, index=assets, columns=assets)
    out["frequency"] = frequency
    out["kind"] = "entropy_pooling"
    return out


def _approx_fn(xg, yg):
    st = _dep._stats()

    def f(u):
        return np.asarray(st.approx(xg, yg, xout=np.asarray(u, dtype=np.float64), rule=2)["y"], dtype=np.float64)
    return f


def _matprod(A, B):
    return np.asarray(_dep._linalg().matprod(np.asarray(A, dtype=np.float64), np.asarray(B, dtype=np.float64)),
                      dtype=np.float64)


def _chol(A):
    return np.asarray(_dep._linalg().chol(np.asarray(A, dtype=np.float64)), dtype=np.float64)


def _solve(A):
    return np.asarray(_dep._linalg().solve(np.asarray(A, dtype=np.float64)), dtype=np.float64)


def _rnorm_mat(m, k):
    v = np.asarray(_dep._rng().rnorm(int(m * k)), dtype=np.float64)
    return v.reshape((k, m)).T.copy()


def copula_scenarios(x, assets, n=10000, family=("t", "gaussian"), stress=None, frequency=("week", "day", "month"),
                     seed=None):
    """Szenarien aus einer Copula mit empirischen Rändern.

    Args:
        x: DataFrame mit ``date`` und Kursspalten oder fertige Renditetabelle.
        assets: Kurs- bzw. Renditespalten.
        n: Anzahl Szenarien.
        family: ``"t"`` (Standard) oder ``"gaussian"``.
        stress: dict ``{anlage: (von, bis)}`` mit Quantilbändern (Anteile);
            ``None`` = unbedingte Simulation.
        frequency: ``"week"``, ``"day"`` oder ``"month"``.
        seed: Startwert der Ziehung.

    Returns:
        :class:`SimLevScenarios`.
    """
    family = _match_arg(family, ("t", "gaussian"))
    frequency = _match_arg(frequency, ("week", "day", "month"))
    assets = _dep._as_names(assets)
    n = int(n)
    S = _scen_frame(x, assets, None, frequency)
    X = S[assets].to_numpy(dtype=np.float64)
    Tn, k = X.shape
    U = np.column_stack([_dep._pobs(X[:, j]) for j in range(k)])
    tau = np.asarray(_dep._kendall(pd.DataFrame(X, columns=assets)), dtype=np.float64)
    R = np.asarray(_libm.sin(_PI_HALF_FACTOR * tau / 2), dtype=np.float64)
    named = True
    la = _dep._linalg()
    ev = la.eigen(R, symmetric=True)
    vals = np.asarray(ev["values"], dtype=np.float64)
    if _dep._rmin(vals) < 1e-6:
        V = np.asarray(ev["vectors"], dtype=np.float64)
        R = _matprod(_matprod(V, np.diag(np.maximum(vals, 1e-6))), V.T)
        R = _cov2cor(R)
        named = False
    Ri = _solve(R)
    ldR = float(la.determinant(R)["modulus"])
    nm = _dep._nmath()

    def ll_t(nu):
        Z = np.asarray(nm.qt(U, nu), dtype=np.float64).reshape(U.shape)
        qv = r_rowsums(_matprod(Z, Ri) * Z)
        c0 = (_dep._lgamma((nu + k) / 2) + (k - 1) * _dep._lgamma(nu / 2) - k * _dep._lgamma((nu + 1) / 2) - 0.5 * ldR)
        terms = c0 - (nu + k) / 2 * _libm.log1p(qv / nu) + (nu + 1) / 2 * r_rowsums(_libm.log1p(Z * Z / nu))
        return r_sum(terms)
    nu = _dep._optimize(lambda v: -ll_t(v), 2.1, 100)[0] if family == "t" else math.inf
    grid = (np.arange(1, Tn + 1) - 0.5) / Tn
    qmarg = [_approx_fn(grid, np.sort(X[:, j])) for j in range(k)]
    if stress is not None:
        if (not isinstance(stress, Mapping) or not len(stress) or any(str(nm_) == "" for nm_ in stress.keys())):
            raise ValueError("stress: benannte Liste von Quantilbändern je Anlage erwartet, z. B. list(aktien = c(0, 0.05)).")
        unk = [a for a in stress.keys() if a not in assets]
        if unk:
            raise ValueError("stress: unbekannte Anlage(n) %s; vorhanden: %s." % (", ".join("'%s'" % u for u in unk), ", ".join(assets)))
        for a, b in stress.items():
            ba = np.atleast_1d(np.asarray(b, dtype=object))
            good = (ba.size == 2 and all(_is_num_scalar(v) for v in ba) and all(math.isfinite(float(v)) for v in ba)
                    and float(ba[0]) >= 0 and float(ba[1]) <= 1 and float(ba[0]) < float(ba[1]))
            if not good:
                raise ValueError("stress: Band für '%s' muss c(von, bis) mit 0 <= von < bis <= 1 sein (Anteile, keine Prozent; "
                                 "erhalten: %s)." % (a, _dep._fmt1(b)))
    rng = _dep._rng()

    def draw():
        st = [] if stress is None else [assets.index(a) for a in stress.keys()]
        Z = np.zeros((n, k))
        fin = math.isfinite(nu)
        if len(st) == 1:
            band = [float(v) for v in np.asarray(list(stress.values())[0], dtype=np.float64)]
            u = np.asarray(rng.runif(n, band[0], band[1]), dtype=np.float64)
            Z[:, st[0]] = np.asarray(nm.qt(u, nu) if fin else nm.qnorm(u), dtype=np.float64)
        elif len(st) > 1:
            ks = len(st)
            Ls = _chol(R[np.ix_(st, st)])
            lo = np.array([float(np.asarray(b, float)[0]) for b in stress.values()])
            hi = np.array([float(np.asarray(b, float)[1]) for b in stress.values()])
            parts = []
            nz = 0
            drawn = 0.0
            m = 100000
            while True:
                E = _matprod(_rnorm_mat(m, ks), Ls)
                if fin:
                    E = E / np.sqrt(np.asarray(rng.rchisq(m, nu), dtype=np.float64) / nu).reshape(-1, 1)
                Ub = np.asarray(nm.pt(E, nu) if fin else nm.pnorm(E), dtype=np.float64).reshape(E.shape)
                hit = ((Ub >= lo.reshape(1, -1)) & (Ub <= hi.reshape(1, -1))).sum(axis=1) == ks
                parts.append(E[hit, :])
                nz += int(hit.sum())
                drawn += m
                if nz >= n:
                    break
                if drawn >= 5e7:
                    raise ValueError("stress: Bänder gemeinsam zu unwahrscheinlich (Trefferquote %s bei %s Ziehungen); "
                                     "Bänder erweitern oder weniger Anlagen stressen."
                                     % (_fmt.sprintf("%.1e", nz / drawn), _fmt.sprintf("%.0e", drawn)))
                m = int(min(1e6, max(1e5, math.ceil(1.2 * (n - nz) / max(nz / drawn, 1e-7)))))
            Zs = np.vstack(parts)
            Z[:, st] = Zs[:n, :]
        if st:
            rest = [j for j in range(k) if j not in st]
            if rest:
                Rss = R[np.ix_(st, st)]
                Rrs = R[np.ix_(rest, st)]
                Rss_i = _solve(Rss)
                RR = _matprod(Rrs, Rss_i)
                M = _matprod(Z[:, st], RR.T)
                Sc = R[np.ix_(rest, rest)] - _matprod(RR, Rrs.T)
                L = _chol(Sc + np.eye(len(rest)) * 1e-12)
                E = _matprod(_rnorm_mat(n, len(rest)), L)
                if fin:
                    Zst = Z[:, st]
                    dq = r_rowsums(_matprod(Zst, Rss_i) * Zst)
                    ns = len(st)
                    chi = np.asarray(rng.rchisq(n, nu + ns), dtype=np.float64)
                    scale = np.sqrt((nu + dq) / (nu + ns) / (chi / (nu + ns)))
                    Z[:, rest] = M + E * scale.reshape(-1, 1)
                else:
                    Z[:, rest] = M + E
        else:
            Z = _matprod(_rnorm_mat(n, k), _chol(R))
            if fin:
                Z = Z / np.sqrt(np.asarray(rng.rchisq(n, nu), dtype=np.float64) / nu).reshape(-1, 1)
        return Z
    sim = _dep._with_rng_restore(draw, seed)
    if math.isfinite(nu):
        V = np.asarray(nm.pt(sim, nu), dtype=np.float64).reshape(sim.shape)
    else:
        V = np.asarray(nm.pnorm(sim), dtype=np.float64).reshape(sim.shape)
    Y = np.column_stack([qmarg[j](V[:, j]) for j in range(k)]) if k else np.zeros((n, 0))
    out_df = pd.DataFrame(Y, columns=assets)
    out = SimLevScenarios()
    out["scenarios"] = out_df
    out["prob"] = np.full(n, 1 / n)
    out["prior"] = np.full(n, 1 / n)
    out["assets"] = assets
    out["states"] = None
    out["effective_n"] = n
    out["copula"] = {"family": family, "correlation": pd.DataFrame(R, index=assets, columns=assets) if named else R,
                     "df": nu}
    out["stress"] = stress
    out["summary"] = pd.DataFrame({"var": assets, "mean_prior": _dep._colmeans(X), "mean_post": _dep._colmeans(Y),
                                   "sd_prior": [r_sd(X[:, j]) for j in range(k)],
                                   "sd_post": [r_sd(Y[:, j]) for j in range(k)]})
    out["correlation"] = pd.DataFrame(_dep._cormat(Y), index=assets, columns=assets)
    out["frequency"] = frequency
    out["kind"] = "copula"
    return out


_PI_HALF_FACTOR = math.pi


def _named_weights(weights):
    if isinstance(weights, pd.Series):
        return [str(i) for i in weights.index], weights.to_numpy()
    if isinstance(weights, Mapping):
        return [str(k) for k in weights.keys()], np.array(list(weights.values()), dtype=object)
    return None, np.atleast_1d(np.asarray(weights))


def _isnum_arr(a):
    a = np.asarray(a)
    if a.dtype.kind in "fiu":
        return True
    if a.dtype == object:
        return all(_is_num_scalar(v) for v in a)
    return False


def scenario_risk(x, weights, alpha=0.05):
    """Portfolio-Kennzahlen auf Szenarien (gewichtet mit ``x.prob``).

    Args:
        x: :class:`SimLevScenarios`.
        weights: benannter Gewichtsvektor (Series oder dict; Namen = Anlagespalten).
        alpha: Tail-Wahrscheinlichkeit für VaR und CVaR.

    Returns:
        ``pandas.Series`` mit ``mean``, ``volatility``, ``var``, ``cvar``,
        ``q05``, ``q50``, ``q95``, ``prob_loss``.
    """
    if not isinstance(x, SimLevScenarios):
        raise ValueError("x muss ein SimLevScenarios sein.")
    av = np.atleast_1d(np.asarray(alpha, dtype=object))
    if not (av.size == 1 and _is_num_scalar(av[0]) and math.isfinite(float(av[0])) and 0 < float(av[0]) < 1):
        raise ValueError("scenario_risk: alpha muss ein Anteil echt zwischen 0 und 1 sein (erhalten: %s)." % _dep._fmt1(alpha))
    alpha = float(av[0])
    names, vals = _named_weights(weights)
    if not _isnum_arr(vals) or names is None or any(nm_ == "" for nm_ in names):
        raise ValueError("scenario_risk: weights muss ein benannter numerischer Vektor sein (Namen = Anlagespalten der Szenarien).")
    unk = [nm_ for nm_ in names if nm_ not in x["scenarios"].columns]
    if unk:
        raise ValueError("scenario_risk: unbekannte Anlage(n) %s." % ", ".join("'%s'" % u for u in dict.fromkeys(unk)))
    w = np.asarray(vals, dtype=np.float64)
    X = x["scenarios"][names].to_numpy(dtype=np.float64)
    q = np.asarray(x["prob"], dtype=np.float64)
    r = _matprod(X, w.reshape(-1, 1)).ravel()
    o = np.argsort(r, kind="stable")
    nan = np.isnan(r[o])
    o = np.concatenate([o[~nan], o[nan]])
    qo = q[o]
    ro = r[o]
    cw = np.cumsum(qo.astype(LD)).astype(np.float64)

    def qf(a):
        h = np.nonzero(cw >= a)[0]
        return float(ro[h[0]]) if h.size else _NAN
    var_a = -qf(alpha)
    prev = np.concatenate([[0.0], cw[:-1]])
    take = np.minimum(qo, np.maximum(0, alpha - prev))
    cvar = -r_sum(take * ro) / r_sum(take)
    m = r_sum(q * r)
    d = r - m
    return pd.Series({"mean": m, "volatility": math.sqrt(r_sum(q * (d * d))), "var": var_a, "cvar": cvar,
                      "q05": qf(0.05), "q50": qf(0.5), "q95": qf(0.95), "prob_loss": r_sum(q[r < 0])})


_DEFAULT_CRISES = pd.DataFrame({
    "crisis": ["Ölkrise 1973/74", "Schwarzer Montag 1987", "Dotcom 2000-02", "Finanzkrise 2007-09",
               "Eurokrise 2011", "Covid 2020", "Inflation/Zinsen 2022"],
    "start": np.array(["1973-01-11", "1987-08-25", "2000-03-24", "2007-10-09", "2011-04-29", "2020-02-19", "2022-01-03"],
                      dtype="datetime64[D]"),
    "end": np.array(["1974-10-03", "1987-12-04", "2002-10-09", "2009-03-09", "2011-10-03", "2020-03-23", "2022-10-12"],
                    dtype="datetime64[D]")})


def crisis_replay(data, weights, crises=None, rebalance=False):
    """Portfolio durch historische Krisen führen.

    Args:
        data: DataFrame mit ``date`` und Kursspalten.
        weights: benannter Gewichtsvektor (wird auf Summe 1 normiert).
        crises: DataFrame mit ``crisis``, ``start``, ``end``; ``None`` = eingebaute Liste.
        rebalance: ``False`` (Kaufen und Halten) oder ``True`` (an jeder Zeile zurück auf die Gewichte).

    Returns:
        ``pandas.DataFrame`` je Krise im Datenzeitraum.
    """
    if crises is None:
        crises = _DEFAULT_CRISES
    if not isinstance(data, pd.DataFrame) or "date" not in data.columns:
        raise ValueError("crisis_replay: data.frame mit Spalte 'date' erwartet.")
    if not isinstance(crises, pd.DataFrame) or not all(c in crises.columns for c in ("crisis", "start", "end")):
        raise ValueError("crisis_replay: crises muss ein data.frame mit den Spalten crisis, start, end sein.")
    names, vals = _named_weights(weights)
    if (not _isnum_arr(vals) or names is None or any(nm_ == "" for nm_ in names)
            or not np.isfinite(np.asarray(vals, dtype=np.float64)).all()):
        raise ValueError("crisis_replay: weights muss ein benannter numerischer Vektor ohne NA sein (Namen = Kursspalten).")
    unk = [nm_ for nm_ in names if nm_ not in [c for c in data.columns if c != "date"]]
    if unk:
        raise ValueError("crisis_replay: Kursspalte(n) %s fehlen in data." % ", ".join("'%s'" % u for u in dict.fromkeys(unk)))
    wv = np.asarray(vals, dtype=np.float64)
    sw = r_sum(wv)
    if sw <= 0:
        raise ValueError("crisis_replay: Summe der Gewichte muss positiv sein (erhalten %s); sie wird auf 1 normiert."
                         % _fmt.sprintf("%g", sw))
    data = _dep._dep_sort_dates(data)
    d = _dep._dates_arr(data["date"].to_numpy())
    dd = _dep._days(d)
    w = wv / sw
    cs = _dep._days(_dep._to_date(crises["start"], "crisis_replay: crises$start"))
    ce = _dep._days(_dep._to_date(crises["end"], "crisis_replay: crises$end"))
    P = np.column_stack([_dep._fill_na(_dep._dep_check_prices(_dep._num(data[a]), a, d), "locf", keep_leading=True)
                         for a in names])
    rows = []
    nd = dd.size
    for i in range(len(crises)):
        s_ = np.nonzero(dd >= cs[i])[0]
        e_ = np.nonzero(dd <= ce[i])[0]
        if not s_.size or not e_.size:
            continue
        s, e = int(s_[0]), int(e_[-1])
        if e <= s or np.isnan(P[s, :]).any():
            continue
        rel = P[s:e + 1, :] / P[s, :].reshape(1, -1)
        if rebalance:
            g = _matprod(rel[1:, :] / rel[:-1, :], w.reshape(-1, 1)).ravel()
            port = r_cumprod(np.concatenate([[1.0], g]))
        else:
            port = _matprod(rel, w.reshape(-1, 1)).ravel()
        cm = np.maximum.accumulate(port) if not np.isnan(port).any() else _cummax_nan(port)
        ddn = _dep._rmin(port / cm - 1)
        if e < nd - 1:
            relx = P[e:, :] / P[s, :].reshape(1, -1)
            px = _matprod(relx, w.reshape(-1, 1)).ravel()
            kk = np.nonzero(px >= 1)[0]
            after = float(dd[e + kk[0]] - dd[e]) if kk.size else _NAN
        else:
            after = _NAN
        row = {"crisis": crises["crisis"].iloc[i], "start": d[s], "end": d[e], "portfolio": 100 * (port[-1] - 1),
               "max_drawdown": 100 * ddn, "days_to_recover": after}
        last = 100 * (rel[-1, :] - 1)
        for j, a in enumerate(names):
            row[a] = float(last[j])
        rows.append(row)
    if not rows:
        raise ValueError("Keine Krise liegt im Datenzeitraum.")
    out = pd.DataFrame(rows, columns=["crisis", "start", "end", "portfolio", "max_drawdown", "days_to_recover"] +
                       list(dict.fromkeys(names)))
    out["start"] = out["start"].to_numpy(dtype="datetime64[D]")
    out["end"] = out["end"].to_numpy(dtype="datetime64[D]")
    return out


def _cummax_nan(x):
    from ._rnum import r_cummax
    return r_cummax(x)


# Rechnen mit NA (signalisierendes NaN) ohne numpy-Warnung "invalid value" wie in R (gemeinsamer Helfer)
from .data_prep import _quiet_fp  # noqa: E402

_quiet_fp(globals(), [_n for _n in __all__ if _n != "entropy_pooling"])  # ohne entropy_pooling: liest den Aufrufer-Frame (env)
