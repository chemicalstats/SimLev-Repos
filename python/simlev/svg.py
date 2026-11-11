"""Grafikmodul der Python-Fassung: ``SimLevPlot``, einheitliche plot-API und alle SVG-Zeichenbausteine.

Python zeichnet wie die Julia-Fassung ohne Zusatzpaket als SVG. Dieses Modul (nur
Standardbibliothek und numpy; pandas erst beim Zusammenstellen von ``data``) ist das Gegenstück
zu ``julia/src/svg.jl``; beide haben dieselbe Gliederung und dieselben Namen (Julias ``name!``
heißt hier ``name``):

1. Grafikobjekt: ``SimLevPlot`` mit den Feldern ``svg`` (SVG-Text), ``data``
   (``dict[str, pandas.DataFrame]``, die dargestellten Werte je Panel), ``source`` (das
   Eingabeobjekt, keine Kopie) und ``kind`` (Klasse des Eingabeobjekts).
2. Einheitliche Grafik-API: ``_check_svg_file``, ``_write_svg``, ``_warn_unknown_kw``,
   ``_plot_method``.
3. Gemeinsame Hilfen: ``_esc`` (Textschutz für alle Stile), ``r_pretty``, Farben
   (``_color_table``, ``_col2rgba``, ``_svgcol``, ``_svgop``, ``_col``, ``_alpha``),
   Datumshilfen (``_MONATE_KURZ``, ``_ym``, ``_days_from_civil``, ``_to_days``, ``_fmt_day``).
4. Stil Dashboard (``plot_dashboard``): ``_Canvas``, ``_text``, ``_line``, ``_rect``, ``_Panel``,
   ``_px``/``_py``, ``_decimate``, ``_path``, ``_polyline``, ``_area``, ``_date_ticks``, ``_frame``,
   ``_title``, ``_r_range``, ``_empty_panel``, ``_yaxis`` (Zahlen mit ``%.1f`` wie Julia).
5. Stil Analysegrafiken ``_ana_*`` (deep_analysis, analysis_tests, planning).
6. Stil Rastergrafiken ``_grid_*`` (dependence, regimes).
7. Stil Ergebnisgrafiken ``_res_*`` (overfitting, param_search, sensitivity).
8. Stil Rückrechnung ``_bc_*`` (backcast).
9. Stil Allokationsgrafiken ``_alloc_*`` (optimize, tactical).
10. Zahlen wie in Julia (nur Python): ``_jl_str``, ``_jl_round``, ``_jl_round_sig``,
    ``_jl_pow``/``_jl_pow_int``, ``_jl_log10``, ``_jl_range``, ``_jl_min``/``_jl_max``/
    ``_jl_minimum``/``_jl_maximum``, ``_jl_fmt``, ``_jl_ceil``, ``_rint``, ``_jl_unique``,
    ``_jl_sort_levels`` …, damit das SVG aller Stile Byte für Byte dem der Julia-Fassung gleicht.

Die Module enthalten nur ihre Zeichenfunktionen (``_plot_*``/``plot_SimLev*``) mit der
Datenaufbereitung und holen die Bausteine von hier (``from .svg import …``). Die Grafiken von
withdrawal (``SimLevWithdrawal``) und bootstrap (``SimLevBootstrapStudy``) schreiben ihr SVG
direkt in der Zeichenfunktion.

Nutzung durch eine Modul-Zeichenfunktion (Muster wie in Julia)::

    def _plot_wd(x, probs=(0.05, 0.25, 0.5, 0.75, 0.95), width=900, height=420):
        c = _Canvas({"primary": "#2E86AB", ...})    # Farbtabelle (für _frame/_title: primary, grid, neutral)
        _svg_open(c, width, height)                 # <svg …>-Kopf; eigener Kopf mit c.write(...) ebenso
        p = _Panel(60, 40, width - 100, height - 90, xlo, xhi, ylo, yhi)
        _frame(c, p, title="…", ylabel="…", yticks=yt, ylabels=yl)
        _polyline(c, p, *_decimate(xs, ys), color="#2E86AB")   # ausdünnen nur fürs Zeichnen
        svg = _svg_close(c)                          # "</svg>\n" anhängen, Text liefern
        data = {"wealth": pd.DataFrame({"year": ..., "q05": ..., ...}),
                "spending": pd.DataFrame({...})}
        return svg, data                            # (str, dict) – kein file-Argument nötig

    class SimLevWithdrawal(RList):
        ...
    SimLevWithdrawal.plot = _plot_method(_plot_wd, "SimLevWithdrawal")

``_plot_method(f, cls)`` liefert eine Funktion ``method(x, *args, file=None, **kw)``:

- Schlüsselwörter, die ``f`` nicht deklariert (``**kw`` zählt nicht), ergeben eine Warnung
  (``plot.<cls>: unbekanntes Argument 'a' wird ignoriert (Tippfehler?).``) und werden nicht
  weitergegeben. Optionen gibt es wie in Julia nur als Schlüsselwort: jedes Positionsargument
  nach ``x`` ergibt die Julia-Warnung ``plot.<cls>: n zusätzliche(s) Positionsargument(e)
  wird/werden ignoriert; …`` und wird nicht weitergegeben.
- ``file`` wird vor dem Zeichnen geprüft (nur ``.svg``, sonst ``ValueError`` mit dem
  Julia-Wortlaut); deklariert ``f`` selbst ``file``, bekommt es ``file=None``. Geschrieben
  wird erst nach dem Zeichnen, nur mit ``file``.
- Rückgabe von ``f``: ``(svg, data)`` oder ein ``SimLevPlot``; ``data`` ist ein ``dict`` von
  ``DataFrame`` (oder spaltenweisen ``dict``); die Reihenfolge der Schlüssel bleibt. (Die
  Übergangsformen „nur SVG-Text“ und ``data = None`` entfallen seit 1.6.4: kein Zeichner liefert sie.)
- Ergebnis immer ``SimLevPlot(svg, data, x, cls)``.

Regeln für ``data`` (siehe Spezifikation P2): eine Tabelle je Panel, Schlüssel = Panelname,
eine Spalte für die x-Achse und je gezeichneter Linie/Fläche eine Spalte; Werte nicht
ausgedünnt (vor ``_decimate``) und unskaliert wie im Ergebnisobjekt; leere Panels als
Tabelle mit den Spalten und null Zeilen; Python und Julia gleiche Schlüssel, Spalten, Werte.
"""
from __future__ import annotations

import inspect
import math
import os
import struct
import sys
import warnings
from decimal import Decimal, localcontext
from typing import Any

import numpy as np

from ._r.rformat import r_format1, r_sprintf
from ._r.rnum import r_pow

__all__ = ["SimLevPlot"]


# ═════════════════════════════════════════════════════════════════════════════
# 1. Grafikobjekt
# ═════════════════════════════════════════════════════════════════════════════

class SimLevPlot:
    """Gerenderte Grafik (SVG) mit den dargestellten Daten.

    Felder: ``svg`` (``str``), ``data`` (``dict[str, pandas.DataFrame]``, eine Tabelle je Panel
    in Zeichenreihenfolge), ``source`` (das Eingabeobjekt, keine Kopie), ``kind`` (Klasse des
    Eingabeobjekts, z. B. ``"SimLevResult"``). In Jupyter erscheint die Grafik direkt
    (``_repr_svg_``); ``save(file)`` schreibt das SVG (nur Endung ``.svg``).
    """

    __slots__ = ("svg", "data", "source", "kind")

    def __init__(self, svg: str, data: dict | None = None, source: Any = None, kind: str = ""):
        self.svg = str(svg)
        self.data = {} if data is None else data
        self.source = source
        self.kind = str(kind)

    def _repr_svg_(self) -> str:
        return self.svg

    def __repr__(self) -> str:
        s = "SimLevPlot(%s, SVG, %d Bytes" % (self.kind, len(self.svg.encode("utf-8")))
        if self.data:
            s += ", Panels: " + ", ".join(self.data)
        return s + ")"

    def save(self, file: str) -> None:
        """SVG nach ``file`` schreiben (nur Endung ``.svg``)."""
        _write_svg(file, self, "SimLevPlot.save")


# ═════════════════════════════════════════════════════════════════════════════
# 2. Einheitliche Grafik-API
# ═════════════════════════════════════════════════════════════════════════════
# Alle plot-Methoden und plot_dashboard liefern ein SimLevPlot und schreiben nur, wenn
# file = "….svg" angegeben ist. Andere Dateiendungen brechen mit einer Meldung ab.
# Unbekannte Schlüsselwörter ergeben eine Warnung statt stillem Übergehen.

def _check_svg_file(file: Any, who: str) -> str:
    """Prüft, dass ``file`` auf ``.svg`` endet (Grafiken entstehen nur als SVG); liefert den Pfad."""
    if not isinstance(file, (str, os.PathLike)):
        raise ValueError("%s: file muss ein Dateiname (Zeichenkette) sein, nicht %s." % (who, type(file).__name__))
    f = os.fspath(file)
    ext = os.path.splitext(f)[1]
    if ext.lower() != ".svg":
        raise ValueError("%s: Grafiken werden nur als SVG gespeichert; '%s' hat " % (who, f)
                         + ("keine Dateiendung" if not ext else "die Endung '%s'" % ext)
                         + ". Bitte einen Dateinamen auf .svg angeben (z. B. \"dashboard.svg\").")
    return f


def _write_svg(file: Any, d: SimLevPlot, who: str) -> SimLevPlot:
    """SVG von ``d`` nach ``file`` schreiben (nur ``.svg``)."""
    f = _check_svg_file(file, who)
    with open(f, "w", encoding="utf-8", newline="") as fh:
        fh.write(d.svg)
    return d


def _warn_unknown_kw(who: str, bad, stacklevel: int = 3) -> None:
    """Warnung für unbekannte Schlüsselwörter (deutsch, alle in einer Meldung)."""
    bad = list(bad)
    if not bad:
        return
    nm = ", ".join("'%s'" % k for k in bad)
    msg = ("%s: unbekanntes Argument %s wird ignoriert (Tippfehler?)." % (who, nm) if len(bad) == 1 else
           "%s: unbekannte Argumente %s werden ignoriert (Tippfehler?)." % (who, nm))
    warnings.warn(msg, UserWarning, stacklevel=stacklevel)


def _as_data(data: Any, who: str) -> dict:
    """``data`` einer Zeichenfunktion vereinheitlichen: ``dict[str, DataFrame]``."""
    import pandas as pd
    if not isinstance(data, dict):
        raise ValueError("%s: die Grafikmethode lieferte keine Daten als dict (sondern %s)."
                         % (who, type(data).__name__))
    return {str(k): (v if isinstance(v, pd.DataFrame) else pd.DataFrame(v)) for k, v in data.items()}


def _as_plot(res: Any, who: str, x: Any, cls: str) -> SimLevPlot:
    if isinstance(res, SimLevPlot):
        return SimLevPlot(res.svg, res.data, x, cls)
    if isinstance(res, tuple) and len(res) == 2 and isinstance(res[0], str):
        return SimLevPlot(res[0], _as_data(res[1], who), x, cls)
    raise ValueError("%s: die Grafikmethode lieferte kein SVG (sondern %s)." % (who, type(res).__name__))


_PK = inspect.Parameter


def _plot_method(f, cls: str, strict: bool = False):
    """Macht aus einer Zeichenfunktion ``f(x, **kw) -> (svg, data)`` die plot-Methode für ``cls``.

    ``strict = True`` (seit 1.6.4, ``plot.SimLevResult``, Entscheidung 57): unbekannte Schlüsselwörter sind ein Fehler
    (Meldung ``argument_unbekannt``) statt einer Warnung.

    Nur die von ``f`` deklarierten Schlüsselwörter werden weitergegeben, unbekannte ergeben
    eine Warnung; Ergebnis immer ``SimLevPlot``; geschrieben wird nur mit ``file = "….svg"``.
    Die Methode eignet sich als Klassenattribut (``Klasse.plot = _plot_method(f, "Klasse")``).
    """
    who = "plot.%s" % cls
    sig = inspect.signature(f)
    params = list(sig.parameters.values())[1:]
    known = {p.name for p in params if p.kind in (_PK.POSITIONAL_OR_KEYWORD, _PK.KEYWORD_ONLY)}
    takes_file = "file" in known

    def method(x, *args, file=None, **kw):
        # Wie Julia: Optionen nur als Schlüsselwort; jedes Positionsargument nach x wird ignoriert.
        if args:
            warnings.warn("%s: %d zusätzliche(s) Positionsargument(e) wird/werden ignoriert; Optionen bitte als "
                          "Schlüsselwort angeben." % (who, len(args)), UserWarning, stacklevel=2)
        if strict:
            from ._pruefen import chk_dots
            chk_dots([k for k in kw if k not in known], (), who)
        _warn_unknown_kw(who, [k for k in kw if k not in known])
        if file is not None:
            _check_svg_file(file, who)
        good = {k: v for k, v in kw.items() if k in known}
        if takes_file:
            good["file"] = None
        d = _as_plot(f(x, **good), who, x, cls)
        if file is not None:
            _write_svg(file, d, who)
        return d

    method.__name__ = "plot"
    method.__qualname__ = "%s.plot" % cls
    method.__doc__ = f.__doc__
    method._plot_method = (f, cls)
    kwonly = [p.replace(kind=_PK.KEYWORD_ONLY) for p in params
              if p.name != "file" and p.kind not in (_PK.VAR_KEYWORD, _PK.VAR_POSITIONAL)]
    try:
        method.__signature__ = inspect.Signature([_PK("x", _PK.POSITIONAL_OR_KEYWORD)] + kwonly
                                                 + [_PK("file", _PK.KEYWORD_ONLY, default=None)])
    except ValueError:  # pragma: no cover - ungewöhnliche Signatur, dann ohne
        pass
    return method


# ═════════════════════════════════════════════════════════════════════════════
# 3. Gemeinsame Hilfen (alle Stile)
# ═════════════════════════════════════════════════════════════════════════════

# ── Textschutz ──────────────────────────────────────────────────────────────
# Ein `_esc` für Titel, Achsen- und Legendentexte aller Stile (& < > ").
def _esc(s: Any) -> str:
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")


# ── Farbverläufe wie R (seit 1.6.4, B-062/B-063, Entscheidung 99) ───────────────────────────
def _r_seq01(n: int) -> list:
    """``seq.int(0, 1, length.out = n)`` wie R (``do_seq``: 0 + i by mit by = 1 / (n - 1), letztes Element genau 1)."""
    if n <= 0:
        return []
    if n == 1:
        return [0.0]
    by = 1.0 / (n - 1)
    out = [0.0 + i * by for i in range(n)]
    out[n - 1] = 1.0
    return out


def _r_approx1(v: float, x: list, y: list) -> float:
    """Lineare Interpolation wie R's ``approx1`` (Bisektion, Stützstellen exakt)."""
    i, j = 0, len(x) - 1
    while i < j - 1:
        ij = (i + j) // 2
        if v < x[ij]:
            j = ij
        else:
            i = ij
    if v == x[j]:
        return y[j]
    if v == x[i]:
        return y[i]
    return y[i] + (y[j] - y[i]) * ((v - x[i]) / (x[j] - x[i]))


def _r_ramp_rgb(chans, n: int) -> list:
    """``colorRampPalette(cols)(n)`` aus Kanälen ``col2rgb(cols) / 255`` (0 … 1): lineare Interpolation über
    ``seq.int(0, 1, length.out = length(cols))``, auf [0, 1] begrenzt, mal 255 und wie ``rgb(…, maxColorValue = 255)``
    abgeschnitten, Großbuchstaben wie R."""
    xs = _r_seq01(len(chans))
    out = []
    for v in _r_seq01(n):
        c = []
        for k in range(3):
            z = _r_approx1(v, xs, [float(ch[k]) for ch in chans])
            c.append(int(min(max(z, 0.0), 1.0) * 255))
        out.append("#%02X%02X%02X" % tuple(c))
    return out


def _r_ramp(cols, n: int) -> list:
    """``colorRampPalette(cols)(n)`` für Farbtexte ``#RRGGBB`` (wie R, siehe :func:`_r_ramp_rgb`)."""
    return _r_ramp_rgb([(int(c[1:3], 16) / 255, int(c[3:5], 16) / 255, int(c[5:7], 16) / 255) for c in cols], n)


# ── R-Achsenteilung ─────────────────────────────────────────────────────────
def r_pretty(lo: float, hi: float, n: int = 5, min_n: int | None = None) -> np.ndarray:
    """Nachbildung von R's ``pretty()`` (``R_pretty`` aus ``src/appl/pretty.c``)."""
    if not (math.isfinite(lo) and math.isfinite(hi)):
        return np.array([0.0])
    if hi < lo:
        lo, hi = hi, lo
    h, h5 = 1.5, 0.5 + 1.5 * 1.5
    eps = 1e-10
    if min_n is None:
        min_n = n // 3
    dx = hi - lo
    if dx == 0 and hi == 0:
        cell, i_small = 1.0, True
    else:
        cell = max(abs(lo), abs(hi))
        u = 1 + (1 / (1 + h) if h5 >= 1.5 * h + 0.5 else 1.5 / (1 + h5))
        u *= max(1, n) * sys.float_info.epsilon
        i_small = dx < cell * u * 3
    if i_small:
        if cell > 10:
            cell = 9 + cell / 10
        cell *= 0.75
        if min_n > 1:
            cell /= min_n
    else:
        cell = dx
        if n > 1:
            cell /= n
    base = 10.0 ** math.floor(math.log10(cell))
    unit = base
    if 2 * base - cell < h * (cell - unit):
        unit = 2 * base
        if 5 * base - cell < h5 * (cell - unit):
            unit = 5 * base
            if 10 * base - cell < h * (cell - unit):
                unit = 10 * base
    ns = math.floor(lo / unit + eps)
    nu = math.ceil(hi / unit - eps)
    while ns * unit > lo + eps * unit:
        ns -= 1
    while nu * unit < hi - eps * unit:
        nu += 1
    k = int(0.5 + nu - ns)
    if k < min_n:
        k = min_n - k
        if ns >= 0:
            nu += k // 2
            ns -= k // 2 + k % 2
        else:
            ns -= k // 2
            nu += k // 2 + k % 2
    return np.arange(ns, nu + 1) * unit


# ── Farben (grDevices::col2rgb / adjustcolor) ───────────────────────────────
_R_PALETTE = ("black", "#DF536B", "#61D04F", "#2297E6", "#28E2E5", "#CD0BBC", "#F5C710", "gray62")
_COLOR_TABLE: dict[str, str] | None = None


def _color_table() -> dict[str, str]:
    global _COLOR_TABLE
    if _COLOR_TABLE is None:
        from importlib import resources
        tab = {}
        txt = resources.files("simlev").joinpath("data/r_colors.csv").read_text(encoding="utf-8")
        for line in txt.splitlines()[1:]:
            if line:
                name, hx = line.split(",")
                tab[name] = hx
        _COLOR_TABLE = tab
    return _COLOR_TABLE


def _col2rgba(v: Any) -> tuple[float, float, float, float]:
    """``grDevices::col2rgb(v, alpha = TRUE) / 255`` für einen Wert; Fehler wie in R (ValueError)."""
    if isinstance(v, (bool, np.bool_)):
        raise ValueError("invalid color name '%s'" % ("TRUE" if v else "FALSE"))
    if isinstance(v, (int, float, np.integer, np.floating)):
        f = float(v)
        if not math.isfinite(f) or abs(f) >= 2147483648:   # seit 1.6.4 wie R (NA nach as.integer) transparent (B-049)
            return (1.0, 1.0, 1.0, 0.0)
        if f < 0:
            raise ValueError("numerical color values must be >= 0, found %d" % int(f))
        i = int(f)
        if i == 0:
            raise ValueError("numerical color values must be positive")
        return _col2rgba(_R_PALETTE[(i - 1) % len(_R_PALETTE)])
    if not isinstance(v, str):
        raise ValueError("invalid color specification")
    if v.startswith("#"):
        if len(v) not in (7, 9):
            raise ValueError("invalid RGB specification")
        # seit 1.6.4 nur ASCII-Hexziffern (Entscheidung 27, B-056; bis 1.6.3 auch z. B. "３")
        if not all(c in "0123456789abcdefABCDEF" for c in v[1:]):
            raise ValueError("invalid hex digit in 'color' or 'lty'")
        vals = [int(v[i:i + 2], 16) for i in range(1, len(v), 2)]
        if len(vals) == 3:
            vals.append(255)
        return tuple(c / 255 for c in vals)  # type: ignore[return-value]
    if v in ("NA", "transparent"):
        return (1.0, 1.0, 1.0, 0.0)
    if v[:1] in tuple("0123456789"):   # seit 1.6.4 nur ASCII-Ziffern (Entscheidung 27, B-056)
        # und nur reine Ganzzahltexte als Farbnummer (Entscheidung 55; "3.0", "2e0", "0x1", "9abc" Fehler)
        if not all(c in "0123456789" for c in v):
            raise ValueError('invalid color specification "%s"' % v)
        return _col2rgba(float(int(v)))
    key = v.replace(" ", "").lower()
    hx = _color_table().get(key)
    if hx is None:
        raise ValueError("invalid color name '%s'" % v)
    return _col2rgba(hx)


def _svgcol(rgba) -> str:
    return "#%02X%02X%02X" % (round(rgba[0] * 255), round(rgba[1] * 255), round(rgba[2] * 255))


def _svgop(rgba) -> str:
    return r_sprintf("%.3f", rgba[3])


def _col(c: Any) -> str:
    return _svgcol(_col2rgba(c))


def _alpha(c: Any, a: int) -> tuple[float, float, float, float]:
    """``adjustcolor(c, alpha.f = a / 255)``."""
    r, g, b, al = _col2rgba(c)
    return (r, g, b, al * a / 255)


# ── Datumshilfen (Tage seit 1970) ───────────────────────────────────────────
# Julia: from_days, to_days, days_from_civil aus src/dates.jl.
_MONATE_KURZ = ("Jan", "Feb", "Mär", "Apr", "Mai", "Jun", "Jul", "Aug", "Sep", "Okt", "Nov", "Dez")


def _ym(days: int) -> tuple[int, int]:
    """Jahr und Monat zur Tageszahl ab 1970."""
    mo = int(np.datetime64(int(days), "D").astype("datetime64[M]").astype(np.int64))
    return 1970 + mo // 12, mo % 12 + 1


def _days_from_civil(y: int, m: int, d: int = 1) -> int:
    mo = np.datetime64((y - 1970) * 12 + (m - 1), "M")
    return int(mo.astype("datetime64[D]").astype(np.int64)) + d - 1


def _to_days(dates) -> np.ndarray:
    """Datumsvektor → Tage ab 1970 (``float``)."""
    return np.asarray(dates).astype("datetime64[D]").astype(np.int64).astype(float)


def _fmt_day(day) -> str:
    """``format(<Date>)`` eines Tages (Tage seit 1970; für Achsen ohne Jahresmarke)."""
    from ._r import fmt as _fmt
    d = np.datetime64("1970-01-01", "D") + np.asarray([day], dtype=np.float64).astype(np.int64).astype("timedelta64[D]")
    return str(_fmt.format_date(d)[0])


# ═════════════════════════════════════════════════════════════════════════════
# 4. Stil Dashboard
# ═════════════════════════════════════════════════════════════════════════════
# plot_dashboard bzw. plot(<SimLevResult>) (dashboard.py): Zeichenkontext `_Canvas` mit
# Farbtabelle, Panels `_Panel` mit Datenbereich, Koordinaten mit `%.1f` (`_c`).

def _c(x: Any) -> str:
    """Koordinate mit einer Nachkommastelle (``%.1f`` wie C-printf)."""
    v = float(x)
    return "%.1f" % v if math.isfinite(v) else r_sprintf("%.1f", v)


class _Canvas:
    """SVG-Puffer mit Farbtabelle (``col``: ``primary``, ``neutral``, ``grid``, …)."""

    __slots__ = ("parts", "col")

    def __init__(self, col: dict | None = None):
        self.parts: list[str] = []
        self.col = {} if col is None else col

    def write(self, s: str) -> None:
        """Text ohne Zeilenende anhängen (wie ``print(io, …)`` in Julia)."""
        self.parts.append(s)

    def getvalue(self) -> str:
        return "".join(self.parts)


def _svg(c: _Canvas, s: str) -> None:
    c.parts.append(s + "\n")


def _svg_open(c: _Canvas, width: float, height: float) -> None:
    """``<svg …>``-Kopf wie in ``plot_dashboard`` (Breite/Höhe ganzzahlig gerundet)."""
    w, h = round(width), round(height)
    c.write("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\" "
            "font-family=\"Helvetica, Arial, sans-serif\">\n" % (w, h, w, h))


def _svg_close(c: _Canvas) -> str:
    """``</svg>`` anhängen und den SVG-Text liefern."""
    c.write("</svg>\n")
    return c.getvalue()


def _text(c: _Canvas, x, y, s, size=11, color="#333333", anchor="start", weight="normal", baseline="middle",
          rot=0, bg=None) -> None:
    s = str(s)
    if bg is not None:
        w = 0.58 * size * len(s)
        h = 1.25 * size
        x0 = x if anchor == "start" else (x - w if anchor == "end" else x - w / 2)
        _svg(c, "<rect x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\" fill=\"%s\" fill-opacity=\"%s\"/>"
             % (_c(x0 - 2), _c(y - h / 2), _c(w + 4), _c(h), _svgcol(bg), _svgop(bg)))
    _svg(c, "<text x=\"%s\" y=\"%s\" font-size=\"%s\" fill=\"%s\" text-anchor=\"%s\" "
            "font-weight=\"%s\" dominant-baseline=\"%s\"" % (_c(x), _c(y), size, color, anchor, weight, baseline)
         + (" transform=\"rotate(%s %s %s)\"" % (rot, _c(x), _c(y)) if rot != 0 else "") + ">%s</text>" % _esc(s))


def _line(c: _Canvas, x1, y1, x2, y2, color="#999999", width=1, dash="") -> None:
    _svg(c, "<line x1=\"%s\" y1=\"%s\" x2=\"%s\" y2=\"%s\" stroke=\"%s\" stroke-width=\"%s\""
         % (_c(x1), _c(y1), _c(x2), _c(y2), color, width)
         + ("" if not dash else " stroke-dasharray=\"%s\"" % dash) + "/>")


def _rect(c: _Canvas, x, y, w, h, fill="none", stroke="none", sw=1, opacity=1.0) -> None:
    _svg(c, "<rect x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\" fill=\"%s\" stroke=\"%s\" stroke-width=\"%s\""
         % (_c(x), _c(y), _c(w), _c(h), fill, stroke, sw)
         + (" fill-opacity=\"%s\"" % r_sprintf("%.3f", opacity) if opacity < 1 else "") + "/>")


class _Panel:
    """Zeichenfläche (Pixel ``x0, y0, w, h``) mit Datenbereich ``xlo..xhi``, ``ylo..yhi``."""

    __slots__ = ("x0", "y0", "w", "h", "xlo", "xhi", "ylo", "yhi")

    def __init__(self, x0, y0, w, h, xlo, xhi, ylo, yhi):
        self.x0, self.y0, self.w, self.h = float(x0), float(y0), float(w), float(h)
        self.xlo, self.xhi, self.ylo, self.yhi = float(xlo), float(xhi), float(ylo), float(yhi)


def _px(p: _Panel, x) -> float:
    return p.x0 + (x - p.xlo) / (1.0 if p.xhi == p.xlo else p.xhi - p.xlo) * p.w


def _py(p: _Panel, y) -> float:
    return p.y0 + p.h - (y - p.ylo) / (1.0 if p.yhi == p.ylo else p.yhi - p.ylo) * p.h


def _decimate(xs, ys, maxn: int = 1600) -> tuple[np.ndarray, np.ndarray]:
    """Höchstens ``maxn`` Punkte: je Block Minimum und Maximum (nur fürs Zeichnen)."""
    xs = np.asarray(xs, dtype=float)
    ys = np.asarray(ys, dtype=float)
    n = xs.size
    if n <= maxn:
        return xs, ys
    bucket = math.ceil(n / (maxn // 2))
    # je Block erstes Minimum und erstes Maximum der endlichen Werte, aufsteigend (eines bei Gleichheit); seit 1.6.4
    # über eine Blöcke x bucket-Matrix (B-086; bis 1.6.3 numpy-Aufrufe je Block, gleiche Punkte)
    nb = -(-n // bucket)
    m = np.full(nb * bucket, np.nan)
    m[:n] = ys
    m = m.reshape(nb, bucket)
    fin = np.isfinite(m)
    lo = np.argmin(np.where(fin, m, np.inf), axis=1)
    hi = np.argmax(np.where(fin, m, -np.inf), axis=1)
    keep = fin.any(axis=1)
    base = np.arange(nb) * bucket
    a = (base + np.minimum(lo, hi))[keep]
    b = (base + np.maximum(lo, hi))[keep]
    two = (lo != hi)[keep]
    idx = np.empty(a.size + int(two.sum()), dtype=np.int64)
    pos = np.arange(a.size) + np.concatenate(([0], np.cumsum(two)[:-1])).astype(np.int64)
    idx[pos] = a
    idx[pos[two] + 1] = b[two]
    return xs[idx], ys[idx]


def _path(p: _Panel, xs, ys, step: bool = False) -> str:
    # seit 1.6.4 (B-086) Koordinaten als Feld gerechnet (elementweise wie _px/_py) und je Punkt nur noch verkettet
    xs = np.asarray(xs, dtype=float)
    ys = np.asarray(ys, dtype=float)
    k = min(xs.size, ys.size)                                  # wie zip
    xs, ys = xs[:k], ys[:k]
    with np.errstate(all="ignore"):                            # wie Rechnen mit Python-Zahlen: ohne numpy-Meldung
        X = p.x0 + (xs - p.xlo) / (1.0 if p.xhi == p.xlo else p.xhi - p.xlo) * p.w
        Y = p.y0 + p.h - (ys - p.ylo) / (1.0 if p.yhi == p.ylo else p.yhi - p.ylo) * p.h
    fx = ["%.1f" % v if math.isfinite(v) else _c(v) for v in X.tolist()]
    fy = ["%.1f" % v if math.isfinite(v) else _c(v) for v in Y.tolist()]
    out = []
    first = True
    prev = None
    for i, ok in enumerate(np.isfinite(ys).tolist()):
        if not ok:
            first = True
            continue
        if step and not first:
            out.append("L" + fx[i] + " " + prev)
        out.append(("M" if first else "L") + fx[i] + " " + fy[i])
        first = False
        prev = fy[i]
    return "".join(out)


def _polyline(c: _Canvas, p: _Panel, xs, ys, color, width=1.5, dash="", step=False) -> None:
    _svg(c, "<path d=\"%s\" fill=\"none\" stroke=\"%s\" stroke-width=\"%s\" stroke-linejoin=\"round\""
         % (_path(p, xs, ys, step=step), color, width)
         + ("" if not dash else " stroke-dasharray=\"%s\"" % dash) + "/>")


def _area(c: _Canvas, p: _Panel, xs, ys, base, fill) -> None:
    d = _path(p, xs, ys)
    if not d:
        return
    _svg(c, "<path d=\"%s L%s %s L%s %s Z\" fill=\"%s\" fill-opacity=\"%s\" stroke=\"none\"/>"
         % (d, _c(_px(p, xs[-1])), _c(_py(p, base)), _c(_px(p, xs[0])), _c(_py(p, base)), _svgcol(fill),
            _svgop(fill)))


def _date_ticks(z0: float, z1: float) -> list[tuple[float, str]]:
    """Achsenmarken einer Zeitachse (Tage ab 1970): Jahre ab zwei Jahren, sonst Monate."""
    y0, m0 = _ym(math.floor(z0))
    y1, m1 = _ym(math.ceil(z1))
    years = y1 - y0
    ticks: list[tuple[float, str]] = []
    if years >= 2:
        step = 1 if years <= 8 else (2 if years <= 16 else (5 if years <= 40 else 10))
        for y in range(y0, y1 + 1):
            if y % step != 0:
                continue
            z = float(_days_from_civil(y, 1, 1))
            if z0 <= z <= z1:
                ticks.append((z, str(y)))
    else:
        months = 12 * years + m1 - m0
        step = 1 if months <= 8 else (2 if months <= 16 else (3 if months <= 30 else 6))
        y, m = y0, m0
        while True:
            z = float(_days_from_civil(y, m, 1))
            if z > z1:
                break
            if (m - 1) % step == 0 and z >= z0:
                ticks.append((z, "%s %d" % (_MONATE_KURZ[m - 1], y)))
            m += 1
            if m > 12:
                m = 1
                y += 1
    return ticks


def _frame(c: _Canvas, p: _Panel, title="", xlabel="", ylabel="", yticks=(), ylabels=(), xticks=(),
           grid=True) -> None:
    col = c.col
    _rect(c, p.x0, p.y0, p.w, p.h, fill="white", stroke="#CED4DA", sw=0.8)
    if grid:
        for t in yticks:
            if p.ylo <= t <= p.yhi:
                _line(c, p.x0, _py(p, t), p.x0 + p.w, _py(p, t), color=_col(col["grid"]), width=0.8)
        for t, _ in xticks:
            _line(c, _px(p, t), p.y0, _px(p, t), p.y0 + p.h, color=_col(col["grid"]), width=0.8)
    for t, lab in zip(yticks, ylabels):
        if p.ylo <= t <= p.yhi:
            _text(c, p.x0 - 6, _py(p, t), lab, size=10, color="#495057", anchor="end")
    for t, lab in xticks:
        _text(c, _px(p, t), p.y0 + p.h + 14, lab, size=10, color="#495057", anchor="middle")
    _title(c, p, title)
    if xlabel:
        _text(c, p.x0 + p.w / 2, p.y0 + p.h + 32, xlabel, size=11, color="#495057", anchor="middle")
    if ylabel:
        _text(c, p.x0 - 58, p.y0 + p.h / 2, ylabel, size=11, color="#495057", anchor="middle", rot=-90)


def _title(c: _Canvas, p: _Panel, title: str) -> None:
    if title:
        _text(c, p.x0 + p.w / 2, p.y0 - 16, title, size=15, color=_col(c.col["primary"]), anchor="middle",
              weight="bold")


def _r_range(lo: float, hi: float) -> tuple[float, float]:
    """``yaxs = "r"``: 4 % Rand."""
    if lo == hi:
        return (lo - 1, hi + 1) if lo == 0 else (lo - 0.4 * abs(lo), hi + 0.4 * abs(hi))
    d = (hi - lo) * 0.04
    return (lo - d, hi + d)


def _empty_panel(c: _Canvas, p: _Panel, title: str) -> None:
    _title(c, p, title)
    _text(c, p.x0 + p.w / 2, p.y0 + p.h / 2, "Zu wenige Daten", size=12, color=_col(c.col["neutral"]),
          anchor="middle")


def _yaxis(lo: float, hi: float) -> tuple[np.ndarray, list[str]]:
    t = r_pretty(lo, hi)
    return t, [r_format1(float(v)) for v in t]


# ═════════════════════════════════════════════════════════════════════════════
# 5. Stil Analysegrafiken (`_ana_*`)
# ═════════════════════════════════════════════════════════════════════════════
# plot(<SimLevAnalysis>) (result_analysis), plot(<SimLevSignalAnalysis>) und
# plot(<SimLevHeatmap>) (analysis_tests), plot(<SimLevGoalPlan>) (planning): Zeichenfläche
# `_AnaSvg` mit Feldern `_ana_panel` (Rand 60/30 px, log. y-Achse möglich), Koordinaten
# `string(round(v; digits = 2))` (`_ana_n`), Schrift sans-serif.

class _AnaSvg:
    """Einfache SVG-Zeichenfläche (``buf``: Liste der Textteile)."""

    __slots__ = ("w", "h", "buf")

    def __init__(self, w=900, h=560):
        self.w, self.h = float(w), float(h)
        W, H = int(w), int(h)
        self.buf = ["<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\" "
                    "font-family=\"sans-serif\">\n<rect width=\"100%%\" height=\"100%%\" fill=\"white\"/>\n"
                    % (W, H, W, H)]

    def write(self, s):
        self.buf.append(s)


def _ana_n(v):
    """Koordinate: ``string(round(v; digits = 2))`` wie Julia (nicht endlich → ``"0"``)."""
    v = float(v)
    return _jl_str(_jl_round(v, 2)) if math.isfinite(v) else "0"


class _AnaPanel:
    """Feld: Pixelrechteck (``x0, y0, w, h``) und Wertebereiche; ``logy`` = logarithmische y-Achse."""

    __slots__ = ("x0", "y0", "w", "h", "xr", "yr", "logy")

    def __init__(self, x0, y0, w, h, xr, yr, logy):
        self.x0, self.y0, self.w, self.h = float(x0), float(y0), float(w), float(h)
        self.xr, self.yr, self.logy = xr, yr, logy


def _ana_lg(v):
    """``log10(max(v, 1e-300))`` (Julia: NaN bleibt NaN)."""
    v = float(v)
    return v if v != v else _jl_log10(_jl_max(v, 1e-300))


def _ana_fixr(r):
    a, b = float(r[0]), float(r[1])
    if not (math.isfinite(a) and math.isfinite(b)):
        return (0.0, 1.0)
    return (a - 0.5, b + 0.5) if a == b else (a, b)


def _ana_pretty(r, n=5):
    a, b = r
    d = (b - a) / n
    m = _jl_pow(10.0, math.floor(_jl_log10(d)))
    f = d / m
    st = (1 if f < 1.5 else 2 if f < 3 else 5 if f < 7 else 10) * m
    return _jl_range(_jl_ceil(a / st) * st, st, b)


def _ana_tick_lab(v):
    if isinstance(v, (int, np.integer)) and not isinstance(v, bool):
        v = int(v)
        return str(v) if abs(v) < 1e5 else _jl_str(_jl_round_sig(float(v), 3))
    v = float(v)
    if abs(v) >= 1e5 or (abs(v) < 1e-3 and v != 0):
        return _jl_str(_jl_round_sig(v, 3))
    return str(int(_rint(v))) if v == _rint(v) else _jl_str(_jl_round_sig(v, 4))


def _ana_px(p, x):
    return p.x0 + (x - p.xr[0]) / (p.xr[1] - p.xr[0]) * p.w


def _ana_py(p, y):
    yy = _ana_lg(y) if p.logy else y
    return p.y0 + p.h - (yy - p.yr[0]) / (p.yr[1] - p.yr[0]) * p.h


def _ana_panel(s, x0, y0, w, h, xr, yr, logy=False, title="", xlab="", ylab="", xticks=None, xlabels=None,
               yticks=None, ylabels=None, box=True):
    xr = _ana_fixr(xr)
    if logy:
        yr = (_ana_lg(yr[0]), _ana_lg(yr[1]))
    yr = _ana_fixr(yr)
    p = _AnaPanel(x0 + 60, y0 + 30, w - 75, h - 70, xr, yr, logy)
    if box:
        s.write("<rect x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\" fill=\"none\" stroke=\"#333\"/>\n"
                % (_ana_n(p.x0), _ana_n(p.y0), _ana_n(p.w), _ana_n(p.h)))
    if title:
        s.write("<text x=\"%s\" y=\"%s\" text-anchor=\"middle\" font-size=\"14\" font-weight=\"bold\">%s</text>\n"
                % (_ana_n(p.x0 + p.w / 2), _ana_n(y0 + 18), _esc(title)))
    if xlab:
        s.write("<text x=\"%s\" y=\"%s\" text-anchor=\"middle\" font-size=\"11\">%s</text>\n"
                % (_ana_n(p.x0 + p.w / 2), _ana_n(p.y0 + p.h + 34), _esc(xlab)))
    if ylab:
        s.write("<text x=\"%s\" y=\"%s\" text-anchor=\"middle\" font-size=\"11\" transform=\"rotate(-90 %s %s)\">%s"
                "</text>\n" % (_ana_n(x0 + 12), _ana_n(p.y0 + p.h / 2), _ana_n(x0 + 12), _ana_n(p.y0 + p.h / 2),
                                _esc(ylab)))
    xt = _ana_pretty(xr) if xticks is None else xticks
    xl = [_ana_tick_lab(v) for v in xt] if xlabels is None else xlabels
    for v, lab in zip(xt, xl):
        s.write("<text x=\"%s\" y=\"%s\" text-anchor=\"middle\" font-size=\"9\">%s</text>\n"
                % (_ana_n(_ana_px(p, v)), _ana_n(p.y0 + p.h + 14), _esc(lab)))
    yt = _ana_pretty(yr) if yticks is None else yticks
    yl = [_ana_tick_lab(_jl_pow(10.0, v) if logy else v) for v in yt] if ylabels is None else ylabels
    for v, lab in zip(yt, yl):
        py = p.y0 + p.h - (v - p.yr[0]) / (p.yr[1] - p.yr[0]) * p.h
        s.write("<text x=\"%s\" y=\"%s\" text-anchor=\"end\" font-size=\"9\">%s</text>\n"
                % (_ana_n(p.x0 - 4), _ana_n(py + 3), _esc(lab)))
    return p


def _ana_polyline_txt(col, lwd, dash, pts):
    return "<polyline fill=\"none\" stroke=\"%s\" stroke-width=\"%s\"%s points=\"%s\"/>\n" % (
        col, _jl_str(lwd), "" if not dash else " stroke-dasharray=\"%s\"" % dash, " ".join(pts))


def _ana_lines(s, p, x, y, col="#000", lwd=1.2, dash=""):
    pts = []
    for a, b in zip(np.asarray(x, dtype=np.float64).tolist(), np.asarray(y, dtype=np.float64).tolist()):
        if math.isfinite(a) and math.isfinite(b):
            pts.append(_ana_n(_ana_px(p, a)) + "," + _ana_n(_ana_py(p, b)))
        elif pts:
            s.write(_ana_polyline_txt(col, lwd, dash, pts))
            pts = []
    if pts:
        s.write(_ana_polyline_txt(col, lwd, dash, pts))


def _ana_hline(s, p, y, col="grey", dash="3,3"):
    _ana_lines(s, p, [p.xr[0], p.xr[1]], [y, y], col=col, lwd=1, dash=dash)


def _ana_rect(s, p, x1, y1, x2, y2, fill="#2C6E9B"):
    a, b, c, d = _ana_px(p, x1), _ana_px(p, x2), _ana_py(p, y1), _ana_py(p, y2)
    s.write("<rect x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\" fill=\"%s\"/>\n"
            % (_ana_n(_jl_min(a, b)), _ana_n(_jl_min(c, d)), _ana_n(abs(b - a)), _ana_n(abs(d - c)), fill))


def _ana_text(s, p, x, y, t, size=8, anchor="middle"):
    s.write("<text x=\"%s\" y=\"%s\" text-anchor=\"%s\" font-size=\"%s\">%s</text>\n"
            % (_ana_n(_ana_px(p, x)), _ana_n(_ana_py(p, y) + size / 3), anchor, _jl_str(size), _esc(t)))


def _ana_points(s, p, x, y, col="#2C6E9B", r=1.5, opacity=0.4):
    for a, b in zip(np.asarray(x, dtype=np.float64).tolist(), np.asarray(y, dtype=np.float64).tolist()):
        if not (math.isfinite(a) and math.isfinite(b)):
            continue
        s.write("<circle cx=\"%s\" cy=\"%s\" r=\"%s\" fill=\"%s\" fill-opacity=\"%s\"/>\n"
                % (_ana_n(_ana_px(p, a)), _ana_n(_ana_py(p, b)), _jl_str(r), col, _jl_str(opacity)))


def _ana_legend(s, p, labels, cols, x=None, y=None, box=False):
    lx = p.x0 + 8 if x is None else x
    ly = p.y0 + 14 if y is None else y
    for i, (lab, c) in enumerate(zip(labels, cols)):
        yy = ly + i * 13
        if box:
            s.write("<rect x=\"%s\" y=\"%s\" width=\"10\" height=\"10\" fill=\"%s\"/>\n"
                    % (_ana_n(lx), _ana_n(yy - 8), c))
        else:
            s.write("<line x1=\"%s\" y1=\"%s\" x2=\"%s\" y2=\"%s\" stroke=\"%s\" stroke-width=\"2\"/>\n"
                    % (_ana_n(lx), _ana_n(yy - 3), _ana_n(lx + 16), _ana_n(yy - 3), c))
        s.write("<text x=\"%s\" y=\"%s\" font-size=\"10\">%s</text>\n" % (_ana_n(lx + 20), _ana_n(yy), _esc(lab)))


def _ana_ramp(cols, n):
    """Farbverlauf wie ``colorRampPalette(cols)(n)``; seit 1.6.4 wie R abgeschnitten und in Großbuchstaben (B-063;
    bis 1.6.3 gerundet, Kleinbuchstaben)."""
    return _r_ramp(cols, n)


def _ana_svg_done(s):
    """SVG abschließen; Text zurück (wie Julia; seit 1.6.4 ohne den ungenutzten Parameter ``file``)."""
    s.write("</svg>\n")
    return "".join(s.buf)


def _ana_year_ticks(days):
    """Jahresmarken für eine Zeitachse (Tage seit 1970): Positionen und Beschriftungen."""
    a = float(_jl_minimum(days))
    b = float(_jl_maximum(days))
    ya, yb = _ym(int(a))[0], _ym(int(b))[0]
    step = max(1, math.ceil((yb - ya + 1) / 8))
    t, lab = [], []
    for yv in range(ya, yb + 1, step):
        d = float(_days_from_civil(yv, 1, 1))
        if a <= d <= b:
            t.append(d)
            lab.append(str(yv))
    if not t:
        t = [a]
        lab = [_fmt_day(a)]
    return t, lab


# ═════════════════════════════════════════════════════════════════════════════
# 6. Stil Rastergrafiken (`_grid_*`)
# ═════════════════════════════════════════════════════════════════════════════
# plot(<SimLevDependence>), plot(<SimLevTailRegression>), plot(<SimLevCoVaR>) (dependence),
# plot(<SimLevHMM>) (regimes): Felder `_GridBox` im Raster (`_grid_svg`), Achsen mit
# `_grid_axes`, Koordinaten `@sprintf("%.1f")` (`_grid_c`).

def _grid_c(v):
    return _jl_fmt("%.1f", v)


class _GridBox:
    __slots__ = ("x0", "y0", "w", "h")

    def __init__(self, x0, y0, w, h):
        self.x0, self.y0, self.w, self.h = float(x0), float(y0), float(w), float(h)


def _grid_svg(keys, makefn, ncol=2, width=900, height=650):
    """Felder ``keys`` im Raster (``ncol`` Spalten); ``makefn(key)(out, box)`` zeichnet ein Feld.

    Ergebnis: der SVG-Text (seit 1.6.4; bis 1.6.3 ein :class:`simlev.SimLevPlot`, von dem alle Aufrufer nur ``svg``
    nahmen, und ein ungenutzter Parameter ``file``).
    """
    J = _jl_str
    n = len(keys)
    nc = 1 if n == 1 else min(ncol, n)
    nr = -(-n // nc)
    out = ["<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%s\" height=\"%s\" viewBox=\"0 0 %s %s\" "
           "font-family=\"Helvetica, Arial, sans-serif\">\n" % (J(width), J(height), J(width), J(height)),
           "<rect width=\"100%\" height=\"100%\" fill=\"white\"/>\n"]
    cw = width / nc
    ch = height / nr
    for k, key in enumerate(keys):
        r, cidx = divmod(k, nc)
        makefn(key)(out, _GridBox(cidx * cw + 60, r * ch + 40, cw - 85, ch - 85))
    out.append("</svg>\n")
    return "".join(out)


def _grid_range(vals, lim):
    """Julias ``_rng``: Wertebereich mit 4 % Rand (``lim`` fest); Julia ebenso ``_grid_range``."""
    if lim is not None:
        return float(lim[0]), float(lim[1])
    v = np.asarray(vals, dtype=np.float64)
    v = v[np.isfinite(v)]
    if v.size == 0:
        return 0.0, 1.0
    lo, hi = _jl_minimum(v), _jl_maximum(v)
    if lo == hi:
        lo -= 0.5
        hi += 0.5
    pad = (hi - lo) * 0.04
    return lo - pad, hi + pad


def _grid_tx(b, x, lo, hi):
    return b.x0 + (x - lo) / (hi - lo) * b.w


def _grid_ty(b, y, lo, hi):
    return b.y0 + b.h - (y - lo) / (hi - lo) * b.h


def _grid_ticks(lo, hi, n=5):
    span = hi - lo
    if span <= 0:
        return [lo]
    step = _jl_pow(10.0, math.floor(_jl_log10(span / n)))
    for m in (1, 2, 5, 10):
        if span / (m * step) <= n:
            step *= m
            break
    return _jl_range(_jl_ceil(lo / step) * step, step, hi)


def _grid_tick_lab(t):
    return _jl_fmt("%g", _jl_round_sig(t, 6))


def _grid_axes(out, b, xlo, xhi, ylo, yhi, title="", xlabel="", ylabel="", dates=False, xticks=None):
    out.append("<rect x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\" fill=\"none\" stroke=\"#444\"/>\n"
               % (_grid_c(b.x0), _grid_c(b.y0), _grid_c(b.w), _grid_c(b.h)))
    for t in _grid_ticks(ylo, yhi):
        y = _grid_ty(b, t, ylo, yhi)
        out.append("<line x1=\"%s\" y1=\"%s\" x2=\"%s\" y2=\"%s\" stroke=\"#444\"/>\n"
                   % (_grid_c(b.x0 - 4), _grid_c(y), _grid_c(b.x0), _grid_c(y)))
        out.append("<text x=\"%s\" y=\"%s\" font-size=\"10\" text-anchor=\"end\">%s</text>\n"
                   % (_grid_c(b.x0 - 6), _grid_c(y + 3), _esc(_grid_tick_lab(t))))
    if xticks is not None:
        xt = xticks
    elif dates:
        y0 = _ym(int(math.floor(xlo)))[0]
        y1 = _ym(int(math.floor(xhi)))[0]
        st = max(1, -(-(y1 - y0 + 1) // 8))
        xt = [(float(_days_from_civil(y, 1, 1)), str(y)) for y in range(y0, y1 + 2, st)
              if xlo <= _days_from_civil(y, 1, 1) <= xhi]
    else:
        xt = [(t, _grid_tick_lab(t)) for t in _grid_ticks(xlo, xhi)]
    for t, lab in xt:
        x = _grid_tx(b, t, xlo, xhi)
        out.append("<line x1=\"%s\" y1=\"%s\" x2=\"%s\" y2=\"%s\" stroke=\"#444\"/>\n"
                   % (_grid_c(x), _grid_c(b.y0 + b.h), _grid_c(x), _grid_c(b.y0 + b.h + 4)))
        out.append("<text x=\"%s\" y=\"%s\" font-size=\"10\" text-anchor=\"middle\">%s</text>\n"
                   % (_grid_c(x), _grid_c(b.y0 + b.h + 15), _esc(lab)))
    if title:
        out.append("<text x=\"%s\" y=\"%s\" font-size=\"13\" font-weight=\"bold\" text-anchor=\"middle\">%s</text>\n"
                   % (_grid_c(b.x0 + b.w / 2), _grid_c(b.y0 - 10), _esc(title)))
    if xlabel:
        out.append("<text x=\"%s\" y=\"%s\" font-size=\"11\" text-anchor=\"middle\">%s</text>\n"
                   % (_grid_c(b.x0 + b.w / 2), _grid_c(b.y0 + b.h + 32), _esc(xlabel)))
    if ylabel:
        out.append("<text x=\"%s\" y=\"%s\" font-size=\"11\" text-anchor=\"middle\" transform=\"rotate(-90 %s %s)\">%s"
                   "</text>\n" % (_grid_c(b.x0 - 45), _grid_c(b.y0 + b.h / 2), _grid_c(b.x0 - 45),
                                  _grid_c(b.y0 + b.h / 2), _esc(ylabel)))


def _grid_hline(out, b, y, ylo, yhi, col):
    y = float(y)
    if not (math.isfinite(y) and ylo <= y <= yhi):
        return
    yy = _grid_ty(b, y, ylo, yhi)
    out.append("<line x1=\"%s\" y1=\"%s\" x2=\"%s\" y2=\"%s\" stroke=\"%s\" stroke-dasharray=\"4 3\"/>\n"
               % (_grid_c(b.x0), _grid_c(yy), _grid_c(b.x0 + b.w), _grid_c(yy), col))


def _grid_legend(out, b, items):
    for k, (lab, col) in enumerate(items):
        y = b.y0 + 12 + 13 * k
        out.append("<line x1=\"%s\" y1=\"%s\" x2=\"%s\" y2=\"%s\" stroke=\"%s\" stroke-width=\"2\"/>\n"
                   % (_grid_c(b.x0 + 8), _grid_c(y), _grid_c(b.x0 + 24), _grid_c(y), col))
        out.append("<text x=\"%s\" y=\"%s\" font-size=\"9\">%s</text>\n"
                   % (_grid_c(b.x0 + 28), _grid_c(y + 3), _esc(lab)))


def _grid_clamp(v, lo, hi):
    return hi if v > hi else (lo if v < lo else v)


def _grid_lines(out, b, series, ylim=None, hline=(), dates=False, title="", xlabel="", ylabel="", points=False,
                band=None, xticks=None):
    """Linien (Reihen ``(x, y, Farbe, Name)``), optional Band ``(x, lo, hi)``, Punkte und waagrechte Linien."""
    series = [(np.asarray(sx, dtype=np.float64), np.asarray(sy, dtype=np.float64), c, nm) for sx, sy, c, nm in series]
    allx = np.concatenate([sx for sx, _, _, _ in series]) if series else np.array([], dtype=np.float64)
    ally = [sy for _, sy, _, _ in series]
    if band is not None:
        band = tuple(np.asarray(v, dtype=np.float64) for v in band)
        ally += [band[1], band[2]]
    ally.append(np.array([float(h[0]) for h in hline], dtype=np.float64))
    xlo, xhi = _grid_range(allx, None)
    ylo, yhi = _grid_range(np.concatenate(ally), ylim)
    _grid_axes(out, b, xlo, xhi, ylo, yhi, title=title, xlabel=xlabel, ylabel=ylabel, dates=dates, xticks=xticks)
    if band is not None:
        bx, blo, bhi = band
        pts = [(_grid_tx(b, bx[i], xlo, xhi), _grid_ty(b, blo[i], ylo, yhi)) for i in range(len(bx))
               if math.isfinite(blo[i])]
        pts += list(reversed([(_grid_tx(b, bx[i], xlo, xhi), _grid_ty(b, bhi[i], ylo, yhi)) for i in range(len(bx))
                              if math.isfinite(bhi[i])]))
        if pts:
            out.append("<polygon points=\"%s\" fill=\"#2C6E9B\" fill-opacity=\"0.15\"/>\n"
                       % " ".join("%s,%s" % (_grid_c(p[0]), _grid_c(p[1])) for p in pts))
    for h in hline:
        _grid_hline(out, b, h[0], ylo, yhi, h[1])
    for xs, ys, col, _ in series:
        d = []
        first = True
        for xv, yv in zip(xs.tolist(), ys.tolist()):
            if not math.isfinite(yv):
                first = True
                continue
            d.append(("M" if first else "L") + _grid_c(_grid_tx(b, xv, xlo, xhi)) + " "
                     + _grid_c(_grid_ty(b, _grid_clamp(yv, ylo, yhi), ylo, yhi)))
            first = False
        out.append("<path d=\"%s\" fill=\"none\" stroke=\"%s\" stroke-width=\"1.4\"/>\n" % ("".join(d), col))
        if points:
            for xv, yv in zip(xs.tolist(), ys.tolist()):
                if math.isfinite(yv):
                    out.append("<circle cx=\"%s\" cy=\"%s\" r=\"2.5\" fill=\"%s\"/>\n"
                               % (_grid_c(_grid_tx(b, xv, xlo, xhi)), _grid_c(_grid_ty(b, yv, ylo, yhi)), col))
    _grid_legend(out, b, [(nm, c) for _, _, c, nm in series])


def _grid_bars(out, b, labels, vals, lo=None, hi=None, pts=None, ylim=None, title="", ylabel=""):
    """Balken mit optionalen Intervallen ``lo``/``hi`` und Punkten ``pts``."""
    vals = np.asarray(vals, dtype=np.float64)
    n = len(vals)
    ylo, yhi = _grid_range(vals, ylim)
    _grid_axes(out, b, 0.0, float(n), ylo, yhi, title=title, ylabel=ylabel,
               xticks=[(k - 0.5, str(labels[k - 1])) for k in range(1, n + 1)])
    _grid_hline(out, b, 0.0, ylo, yhi, "#666")
    z = _grid_ty(b, _grid_clamp(0.0, ylo, yhi), ylo, yhi)
    for k in range(1, n + 1):
        v = float(vals[k - 1])
        if not math.isfinite(v):
            continue
        x = _grid_tx(b, k - 0.8, 0.0, n)
        w = _grid_tx(b, k - 0.2, 0.0, n) - x
        y = _grid_ty(b, _grid_clamp(v, ylo, yhi), ylo, yhi)
        out.append("<rect x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\" fill=\"#2C6E9B\"/>\n"
                   % (_grid_c(x), _grid_c(_jl_min(y, z)), _grid_c(w), _grid_c(abs(z - y))))
        if lo is not None and math.isfinite(lo[k - 1]) and math.isfinite(hi[k - 1]):
            xm = _grid_tx(b, k - 0.5, 0.0, n)
            out.append("<line x1=\"%s\" y1=\"%s\" x2=\"%s\" y2=\"%s\" stroke=\"black\"/>\n"
                       % (_grid_c(xm), _grid_c(_grid_ty(b, lo[k - 1], ylo, yhi)), _grid_c(xm),
                          _grid_c(_grid_ty(b, hi[k - 1], ylo, yhi))))
        if pts is not None and math.isfinite(pts[k - 1]):
            out.append("<circle cx=\"%s\" cy=\"%s\" r=\"3\" fill=\"#B5562B\"/>\n"
                       % (_grid_c(_grid_tx(b, k - 0.5, 0.0, n)), _grid_c(_grid_ty(b, pts[k - 1], ylo, yhi))))


def _grid_scatter(out, b, x, y, cols, rects=(), xlabel="", ylabel="", title=""):
    """Streudiagramm mit Farben je Punkt und Rechtecken ``(x0, y0, x1, y1, Farbe)``."""
    x = np.asarray(x, dtype=np.float64)
    y = np.asarray(y, dtype=np.float64)
    xlo, xhi = _grid_range(x, None)
    ylo, yhi = _grid_range(y, None)
    _grid_axes(out, b, xlo, xhi, ylo, yhi, title=title, xlabel=xlabel, ylabel=ylabel)
    for i in range(len(x)):
        if not (math.isfinite(x[i]) and math.isfinite(y[i])):
            continue
        out.append("<circle cx=\"%s\" cy=\"%s\" r=\"1.6\" fill=\"%s\"/>\n"
                   % (_grid_c(_grid_tx(b, x[i], xlo, xhi)), _grid_c(_grid_ty(b, y[i], ylo, yhi)), cols[i]))
    for a0, b0, a1, b1, col in rects:
        X0, X1 = _grid_tx(b, a0, xlo, xhi), _grid_tx(b, a1, xlo, xhi)
        Y0, Y1 = _grid_ty(b, b1, ylo, yhi), _grid_ty(b, b0, ylo, yhi)
        out.append("<rect x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\" fill=\"none\" stroke=\"%s\"/>\n"
                   % (_grid_c(X0), _grid_c(Y0), _grid_c(X1 - X0), _grid_c(Y1 - Y0), col))


# ═════════════════════════════════════════════════════════════════════════════
# 7. Stil Ergebnisgrafiken (`_res_*`)
# ═════════════════════════════════════════════════════════════════════════════
# plot(<SimLevPBO>), plot(<SimLevWalkForward>) (overfitting), plot(<SimLevParamSearch>)
# (param_search), plot(<SimLevSensitivity>) (sensitivity): Abbildung `_ResFig` mit Panels
# `_ResPanel` (Gitterlinien, log. y-Achse möglich), Koordinaten `string(round(x; digits = 1))`
# (`_res_c`).

class _ResFig:
    __slots__ = ("parts", "w", "h")

    def __init__(self, w, h):
        self.parts = []
        self.w, self.h = float(w), float(h)


class _ResPanel:
    __slots__ = ("x0", "y0", "w", "h", "xlo", "xhi", "ylo", "yhi", "logy")

    def __init__(self, x0, y0, w, h, xlo, xhi, ylo, yhi, logy):
        self.x0, self.y0, self.w, self.h = float(x0), float(y0), float(w), float(h)
        self.xlo, self.xhi, self.ylo, self.yhi = float(xlo), float(xhi), float(ylo), float(yhi)
        self.logy = bool(logy)


def _res_c(x):
    """Koordinate wie Julias ``string(round(x; digits = 1))``."""
    return _jl_str(_jl_round(float(x), 1))


def _res_fig(w=720, h=420):
    f = _ResFig(w, h)
    f.parts.append("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%s\" height=\"%s\" viewBox=\"0 0 %s %s\" "
                   "font-family=\"Helvetica, Arial, sans-serif\">\n<rect width=\"%s\" height=\"%s\" fill=\"white\"/>\n"
                   % (_jl_str(w), _jl_str(h), _jl_str(w), _jl_str(h), _jl_str(w), _jl_str(h)))
    return f


def _res_finish(f):
    """SVG abschließen; liefert den Text."""
    f.parts.append("</svg>\n")
    return "".join(f.parts)


def _res_svg(f, s):
    f.parts.append(s + "\n")


def _res_text(f, x, y, s, size=11, anchor="middle", color="#222", rot=0, weight="normal"):
    _res_svg(f, "<text x=\"%s\" y=\"%s\" font-size=\"%s\" text-anchor=\"%s\" fill=\"%s\" font-weight=\"%s\""
             % (_res_c(x), _res_c(y), _jl_str(size), anchor, color, weight)
             + (" transform=\"rotate(%s %s %s)\"" % (_jl_str(rot), _res_c(x), _res_c(y)) if rot != 0 else "")
             + ">%s</text>" % _esc(s))


def _res_tx(p, x):
    return p.x0 + (x - p.xlo) / (1.0 if p.xhi == p.xlo else p.xhi - p.xlo) * p.w


def _res_yv(p, y):
    return _jl_log10(y) if p.logy else y   # seit 1.6.4 wie Julia (B-100; bis 1.6.3 libm)


def _res_ty(p, y):
    return p.y0 + p.h - (_res_yv(p, y) - p.ylo) / (1.0 if p.yhi == p.ylo else p.yhi - p.ylo) * p.h


def _res_ticks(lo, hi, n=5):
    if not (math.isfinite(lo) and math.isfinite(hi)):
        return []
    if hi == lo:
        return [lo]
    raw = (hi - lo) / n
    mag = _jl_pow(10.0, math.floor(_jl_log10(raw)))      # seit 1.6.4 _jl_log10/_jl_ceil wie Julia (B-100)
    st = raw / mag
    step = (1 if st < 1.5 else 2 if st < 3 else 5 if st < 7 else 10) * mag
    t0 = _jl_ceil(lo / step) * step
    return _jl_range(t0, step, hi + step * 1e-9)


def _res_tick_lab(v):
    a = abs(v)
    if a == 0:
        return "0"
    return _jl_str(_jl_round_sig(v, 3)) if (a >= 1e4 or a < 1e-3) else _jl_str(_jl_round_sig(v, 4))


def _res_range(v):
    """Achsenbereich mit 4 % Rand (Julia ``_res_range``)."""
    w = [float(z) for z in v if math.isfinite(float(z))]
    if not w:
        return (0.0, 1.0)
    lo, hi = min(w), max(w)
    if lo == hi:
        return (lo - 0.5, hi + 0.5)
    pad = 0.04 * (hi - lo)
    return (lo - pad, hi + pad)


def _res_panel(f, x0, y0, w, h, xlim, ylim, title="", xlab="", ylab="", logy=False, xticks=None, xticklabels=None,
               yticks=None, yticklabels=None, grid=True):
    """Panel mit Achsen, Titel und Beschriftungen."""
    ylo, yhi = (_jl_log10(ylim[0]), _jl_log10(ylim[1])) if logy else ylim   # seit 1.6.4 wie Julia (B-100)
    p = _ResPanel(x0, y0, w, h, xlim[0], xlim[1], ylo, yhi, logy)
    _res_svg(f, "<rect x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\" fill=\"none\" stroke=\"#555\"/>"
             % (_res_c(x0), _res_c(y0), _res_c(w), _res_c(h)))
    xt = _res_ticks(*xlim) if xticks is None else xticks
    for i, t in enumerate(xt):
        X = _res_tx(p, t)
        if grid:
            _res_svg(f, "<line x1=\"%s\" y1=\"%s\" x2=\"%s\" y2=\"%s\" stroke=\"#e6e6e6\"/>"
                     % (_res_c(X), _res_c(y0), _res_c(X), _res_c(y0 + h)))
        _res_text(f, X, y0 + h + 14, _res_tick_lab(t) if xticklabels is None else xticklabels[i], size=9)
    if yticks is None:
        yt = ([_jl_pow(10.0, k) for k in _jl_range(math.floor(ylo), 1.0, _jl_ceil(yhi)) if ylo <= k <= yhi]
              if logy else _res_ticks(*ylim))
    else:
        yt = yticks
    if logy and len(yt) < 2:
        yt = [ylim[0], ylim[1]]
    for i, t in enumerate(yt):
        Y = _res_ty(p, t)
        if grid:
            _res_svg(f, "<line x1=\"%s\" y1=\"%s\" x2=\"%s\" y2=\"%s\" stroke=\"#e6e6e6\"/>"
                     % (_res_c(x0), _res_c(Y), _res_c(x0 + w), _res_c(Y)))
        _res_text(f, x0 - 5, Y + 3, _res_tick_lab(t) if yticklabels is None else yticklabels[i], size=9, anchor="end")
    if title:
        _res_text(f, x0 + w / 2, y0 - 10, title, size=13, weight="bold")
    if xlab:
        _res_text(f, x0 + w / 2, y0 + h + 32, xlab, size=11)
    if ylab:
        _res_text(f, x0 - 42, y0 + h / 2, ylab, size=11, rot=-90)
    return p


def _res_line(f, p, xs, ys, color="#2C6E9B", width=1.5, dash=""):
    out = []
    first = True
    for x, y in zip(xs, ys):
        x, y = float(x), float(y)
        if not (math.isfinite(x) and math.isfinite(y) and (not p.logy or y > 0)):
            first = True
            continue
        out.append(("M" if first else "L") + _res_c(_res_tx(p, x)) + " " + _res_c(_res_ty(p, y)))
        first = False
    s = "".join(out)
    if s:
        _res_svg(f, "<path d=\"%s\" fill=\"none\" stroke=\"%s\" stroke-width=\"%s\"" % (s, color, _jl_str(width))
                 + ("" if not dash else " stroke-dasharray=\"%s\"" % dash) + "/>")


def _res_points(f, p, xs, ys, color="#2C6E9B", r=3, opacity=1.0):
    for i, (x, y) in enumerate(zip(xs, ys)):
        x, y = float(x), float(y)
        if not (math.isfinite(x) and math.isfinite(y)):
            continue
        col = color[i] if isinstance(color, (list, tuple)) else color
        _res_svg(f, "<circle cx=\"%s\" cy=\"%s\" r=\"%s\" fill=\"%s\" fill-opacity=\"%s\"/>"
                 % (_res_c(_res_tx(p, x)), _res_c(_res_ty(p, y)), _jl_str(r), col, _jl_str(opacity)))


def _res_vline(f, p, x, color="#B5562B", width=2, dash=""):
    if math.isfinite(x):
        _res_svg(f, "<line x1=\"%s\" y1=\"%s\" x2=\"%s\" y2=\"%s\" stroke=\"%s\" stroke-width=\"%s\""
                 % (_res_c(_res_tx(p, x)), _res_c(p.y0), _res_c(_res_tx(p, x)), _res_c(p.y0 + p.h), color,
                    _jl_str(width))
                 + ("" if not dash else " stroke-dasharray=\"%s\"" % dash) + "/>")


def _res_hline(f, p, y, color="grey", width=1, dash="2,3"):
    if math.isfinite(y):
        _res_svg(f, "<line x1=\"%s\" y1=\"%s\" x2=\"%s\" y2=\"%s\" stroke=\"%s\" stroke-width=\"%s\""
                 % (_res_c(p.x0), _res_c(_res_ty(p, y)), _res_c(p.x0 + p.w), _res_c(_res_ty(p, y)), color,
                    _jl_str(width))
                 + ("" if not dash else " stroke-dasharray=\"%s\"" % dash) + "/>")


def _res_abline(f, p, a, b, color="#B5562B", width=2):
    if math.isfinite(a) and math.isfinite(b):
        _res_line(f, p, [p.xlo, p.xhi], [a + b * p.xlo, a + b * p.xhi], color=color, width=width)


def _res_rect(f, p, x1, y1, x2, y2, fill="#2C6E9B", stroke="none"):
    X1, X2 = sorted((_res_tx(p, x1), _res_tx(p, x2)))
    Y1, Y2 = sorted((_res_ty(p, y1), _res_ty(p, y2)))
    _res_svg(f, "<rect x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\" fill=\"%s\" stroke=\"%s\"/>"
             % (_res_c(X1), _res_c(Y1), _res_c(X2 - X1), _res_c(Y2 - Y1), fill, stroke))


def _res_legend(f, x, y, labels, colors):
    for i, (lab, c) in enumerate(zip(labels, colors)):
        Y = y + i * 15
        _res_svg(f, "<line x1=\"%s\" y1=\"%s\" x2=\"%s\" y2=\"%s\" stroke=\"%s\" stroke-width=\"2\"/>"
                 % (_res_c(x), _res_c(Y), _res_c(x + 18), _res_c(Y), c))
        _res_text(f, x + 24, Y + 4, lab, size=10, anchor="start")


_RES_PAL = None


def _res_pal() -> list:
    """64 Stufen ``colorRampPalette(c("#B5562B", "#F2E9DC", "#2C6E9B"))(64)`` wie R ``plot(<SimLevParamSearch>)``
    (seit 1.6.4, B-063; bis 1.6.3 stetiger Verlauf ``_res_ramp``)."""
    global _RES_PAL
    if _RES_PAL is None:
        _RES_PAL = _r_ramp(["#B5562B", "#F2E9DC", "#2C6E9B"], 64)
    return _RES_PAL


# ═════════════════════════════════════════════════════════════════════════════
# 8. Stil Rückrechnung (`_bc_*`)
# ═════════════════════════════════════════════════════════════════════════════
# plot(<SimLevBackcastFit>), plot(<SimLevBackcast>) (backcast): Liniendiagramme mit fünf
# gleichmäßigen Achsenmarken (`%g`, Datum), Zahlen mit `string(x)`.

def _bc_esc(t):
    """Wie ``_esc``, aber ohne ``\"`` (Anführungszeichen bleiben)."""
    return str(t).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _bc_panel(out, series, x0=0, y0=0, w=720, h=360, title="", xlab="", ylab="", logy=False, hlines=(),
               vlines=(), xdate=False, legend=()):
    """Ein Liniendiagramm ins SVG (``out``: Liste der Textteile). ``series``: ``(x, y, Farbe, Linienbreite)``."""
    from .data_prep import _date_str, _sprintf_g
    J = _jl_str
    ml, mr, mt, mb = 70, 15, 30, 45
    xs, ys = [], []
    for sx, sy, _, _ in series:
        for a, b in zip(np.asarray(sx, dtype=np.float64).tolist(), np.asarray(sy, dtype=np.float64).tolist()):
            if math.isfinite(a) and math.isfinite(b) and (not logy or b > 0):
                xs.append(a)
                ys.append(_jl_log10(b) if logy else b)
    if not xs:
        xs, ys = [0.0, 1.0], [0.0, 1.0]
    xlo, xhi = _jl_minimum(xs), _jl_maximum(xs)
    ylo, yhi = _jl_minimum(ys), _jl_maximum(ys)
    for v in hlines:
        yv = _jl_log10(v) if logy else v
        ylo, yhi = _jl_min(ylo, yv), _jl_max(yhi, yv)
    if xhi == xlo:
        xhi = xlo + 1
    if yhi == ylo:
        yhi = ylo + 1
    pad = 0.04 * (yhi - ylo)
    ylo -= pad
    yhi += pad

    def px(a):
        return x0 + ml + (a - xlo) / (xhi - xlo) * (w - ml - mr)

    def py(b):
        return y0 + mt + (yhi - b) / (yhi - ylo) * (h - mt - mb)

    out.append("<rect x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\" fill=\"none\" stroke=\"#333\"/>\n"
               % (J(x0 + ml), J(y0 + mt), J(w - ml - mr), J(h - mt - mb)))
    out.append("<text x=\"%s\" y=\"%s\" text-anchor=\"middle\" font-size=\"14\" font-weight=\"bold\">%s</text>\n"
               % (J(x0 + w / 2), J(y0 + 18), _bc_esc(title)))
    out.append("<text x=\"%s\" y=\"%s\" text-anchor=\"middle\" font-size=\"12\">%s</text>\n"
               % (J(x0 + w / 2), J(y0 + h - 8), _bc_esc(xlab)))
    out.append("<text x=\"%s\" y=\"%s\" text-anchor=\"middle\" font-size=\"12\" transform=\"rotate(-90 %s %s)\">%s"
               "</text>\n" % (J(x0 + 14), J(y0 + h / 2), J(x0 + 14), J(y0 + h / 2), _bc_esc(ylab)))
    for k in range(5):
        yv = ylo + k / 4 * (yhi - ylo)
        lab = _sprintf_g(_jl_pow(10.0, yv)) if logy else _sprintf_g(yv)
        out.append("<text x=\"%s\" y=\"%s\" text-anchor=\"end\" font-size=\"10\">%s</text>\n"
                   % (J(x0 + ml - 4), J(py(yv) + 4), lab))
        xv = xlo + k / 4 * (xhi - xlo)
        xl = _date_str(xv) if xdate else _sprintf_g(xv)
        out.append("<text x=\"%s\" y=\"%s\" text-anchor=\"middle\" font-size=\"10\">%s</text>\n"
                   % (J(px(xv)), J(y0 + h - mb + 14), xl))
    for v in hlines:
        yv = _jl_log10(v) if logy else v
        out.append("<line x1=\"%s\" x2=\"%s\" y1=\"%s\" y2=\"%s\" stroke=\"#7f7f7f\" stroke-dasharray=\"5,4\"/>\n"
                   % (J(px(xlo)), J(px(xhi)), J(py(yv)), J(py(yv))))
    for v in vlines:
        out.append("<line x1=\"%s\" x2=\"%s\" y1=\"%s\" y2=\"%s\" stroke=\"#666\" stroke-dasharray=\"2,3\"/>\n"
                   % (J(px(v)), J(px(v)), J(y0 + mt), J(y0 + h - mb)))
    for sx, sy, col, lw in series:
        pts = []
        for a, b in zip(np.asarray(sx, dtype=np.float64).tolist(), np.asarray(sy, dtype=np.float64).tolist()):
            if math.isfinite(a) and math.isfinite(b) and (not logy or b > 0):
                pts.append(J(_jl_round(px(a), 2)) + "," + J(_jl_round(py(_jl_log10(b) if logy else b), 2)))
        if pts:
            out.append("<polyline fill=\"none\" stroke=\"%s\" stroke-width=\"%s\" points=\"%s\"/>\n"
                       % (col, J(lw), " ".join(pts)))
    for i, (lab, col) in enumerate(legend, start=1):
        yy = y0 + mt + 14 * i
        out.append("<line x1=\"%s\" x2=\"%s\" y1=\"%s\" y2=\"%s\" stroke=\"%s\" stroke-width=\"1.5\"/>\n"
                   % (J(x0 + ml + 8), J(x0 + ml + 28), J(yy - 4), J(yy - 4), col))
        out.append("<text x=\"%s\" y=\"%s\" font-size=\"11\">%s</text>\n" % (J(x0 + ml + 32), J(yy), _bc_esc(lab)))


def _bc_doc(f, w, h):
    """SVG-Rahmen um ``f(out)``; Text zurück (wie Julia; seit 1.6.4 ohne den ungenutzten Parameter ``file``)."""
    J = _jl_str
    out = ["<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%s\" height=\"%s\" viewBox=\"0 0 %s %s\" "
           "font-family=\"sans-serif\">\n" % (J(w), J(h), J(w), J(h)),
           "<rect width=\"100%\" height=\"100%\" fill=\"white\"/>\n"]
    f(out)
    out.append("</svg>\n")
    return "".join(out)


# ═════════════════════════════════════════════════════════════════════════════
# 9. Stil Allokationsgrafiken (`_alloc_*`)
# ═════════════════════════════════════════════════════════════════════════════
# plot(<SimLevOptimization>), plot(<SimLevFrontier>) (optimize), plot(<SimLevWeights>)
# (tactical): Einzelgrafik mit festen Rändern (L, R, T, B in der Zeichenfunktion), Achsen
# `_alloc_ticks`, Koordinaten `string(round(v; digits = 2))` (`_alloc_c`).

def _alloc_ticks(lo, hi, n=5):
    """Achsenteilung (``pretty()`` vereinfacht; Julia ebenso ``_alloc_ticks``)."""
    if not (math.isfinite(lo) and math.isfinite(hi)):
        return []
    if hi <= lo:
        hi = lo + 1
    raw = (hi - lo) / n
    p = _jl_pow(10.0, math.floor(_jl_log10(raw)))        # seit 1.6.4 _jl_log10/_jl_ceil wie Julia (B-100)
    step = min(s_ for s_ in (1 * p, 2 * p, 5 * p, 10 * p) if s_ >= raw)
    return _jl_range(_jl_ceil(lo / step) * step, step, hi + 1e-12)


def _alloc_c(v):
    """Koordinate wie Julias ``string(round(v; digits = 2))``."""
    return _jl_str(_jl_round(float(v), 2))


def _alloc_ramp(n):
    """Farbverlauf wie ``colorRampPalette(c(...))(n)`` (Julia ebenso ``_alloc_ramp``); seit 1.6.4 wie R abgeschnitten
    und in Großbuchstaben (B-063)."""
    return _r_ramp(["#2C6E9B", "#3E8E5A", "#C49A2C", "#B5562B", "#8A5BA8", "#4A4A4A"], n)


# ═════════════════════════════════════════════════════════════════════════════
# 10. Zahlen wie in Julia (nur Python)
# ═════════════════════════════════════════════════════════════════════════════
# Die Julia-Grafiken (overfitting.jl, deep_analysis.jl, dependence.jl, optimize.jl, …)
# schreiben Zahlen mit Julias ``string(x)``, ``round(x; digits/sigdigits)``, ``@sprintf``,
# ``10.0^k``, ``log10``, ``min``/``max``/``minimum``/``maximum`` und Gleitkommabereichen
# ``collect(a:s:b)``. Die Hilfen hier bilden diese Base-Funktionen (Julia 1.10–1.13) genau
# nach, damit Python dasselbe SVG Byte für Byte schreibt. Nur fürs Zeichnen, nie für Werte.
# Genutzt von analysis_tests, backcast, bootstrap, deep_analysis, dependence, optimize,
# overfitting, param_search, planning, regimes, tactical und withdrawal.

_U64 = (1 << 64) - 1
_M24 = 16777216            # maxintfloat(Float32, Int): Grenze von Base.rat
_M53 = 9007199254740992    # maxintfloat(Float64, Int)


def _f2u(x: float) -> int:
    """Bitmuster eines Float64 als vorzeichenlose Ganzzahl (Julia ``reinterpret(UInt64, x)``)."""
    return struct.unpack("<Q", struct.pack("<d", x))[0]


def _u2f(u: int) -> float:
    """Float64 zu einem Bitmuster (Julia ``reinterpret(Float64, u)``)."""
    return struct.unpack("<d", struct.pack("<Q", u & _U64))[0]


def _wrap64(v: int) -> int:
    """Ganzzahl mit Überlauf wie Julias ``Int64`` (für die Bereichsberechnung in ``_jl_range``)."""
    v &= _U64
    return v - (1 << 64) if v >= 1 << 63 else v


def _two_mul(a: float, b: float) -> tuple[float, float]:
    """Julia ``Base.Math.two_mul``: Produkt und exakter Rundungsfehler (für ``_jl_pow_int`` und Bereiche)."""
    p = a * b
    return p, _fma(a, b, -p)


def _fma(a: float, b: float, c: float) -> float:
    """``fma(a, b, c)`` mit IEEE-Ergebnis wie Julia statt Ausnahme (seit 1.6.4, Befund B-099): ungültige Operation
    (z. B. ``inf * inf - inf``, ``0 * inf``) ergibt NaN, Überlauf ±Inf."""
    try:
        return math.fma(a, b, c)
    except ValueError:
        return math.nan
    except OverflowError:
        return math.copysign(math.inf, a * b if math.isfinite(a * b) else (a * b + c if math.isfinite(c) else c))


def _jl_pow_int(x, n) -> float:
    """Julia ``x ^ n`` (Float64, ganzzahliges ``n``): kompensiertes Quadrieren wie ``Base.Math.pow_body``.

    ``muladd`` wird in Julia hier nicht verschmolzen; z. B. ``10.0^-2 = 0.010000000000000002``.
    """
    x = float(x)
    n = int(n)
    if n == 0:
        return 1.0
    if not -4096 <= n <= 3 * 8192:  # pragma: no cover - kommt beim Zeichnen nicht vor
        return math.pow(x, n)
    if n == 3:
        return x * x * x
    y, xnlo, ynlo = 1.0, -0.0, 0.0
    if n < 0:
        rx = 1.0 / x if x != 0 else math.copysign(math.inf, x)
        if n == -2:
            return rx * rx
        if math.isfinite(x):
            xnlo = -_fma(x, rx, -1.0) * rx
        x, n = rx, -n
    while n > 1:
        if n & 1:
            err = y * xnlo + x * ynlo
            y, ynlo = _two_mul(x, y)
            ynlo += err
        err = x * 2 * xnlo
        x, xnlo = _two_mul(x, x)
        xnlo += err
        n >>= 1
    err = y * xnlo + x * ynlo
    if math.isfinite(x) and math.isfinite(err) and err != 0:
        return x * y + err
    return x * y


def _jl_pow(x, y) -> float:
    """Julia ``x ^ y`` für Float64: ganzzahliges ``y`` exakt wie Julia (``_jl_pow_int``), sonst libm.

    Für nicht ganzzahlige Exponenten weicht libm höchstens um 1 ulp von Julias eigenem ``pow`` ab.
    """
    x, y = float(x), float(y)
    if x == 1.0:
        return 1.0
    if math.isfinite(y) and y == int(y):
        return _jl_pow_int(x, int(y))
    return r_pow(x, y)


# Tabelle ``t_log_Float64`` aus Julias ``base/special/log.jl`` (N = 39): je j = 0..128 (hi, lo) mit lb = log(1 + j/128)
# in 80 Dezimalstellen (decimal), hi = lb auf ein Vielfaches von 2^-39 gerundet (half even), lo = lb - hi, beide als
# float. Seit 1.6.4 als Literal (B-111; bis 1.6.3 bei der ersten Nutzung je Prozess mit Decimal berechnet, ≈ 14 ms);
# die Werte sind repr der berechneten Zahlen (verlustfrei, Bit für Bit gleich; Rechnung siehe _tlog_rechnen).
_TLOG = [
    (0.0, 0.0), (0.007782140442941454, -8.865052917267247e-13),
    (0.015504186536418274, -4.530198941364935e-13), (0.0231670592820592, -5.248209479295644e-13),
    (0.03077165866670839, 4.529814257790929e-14), (0.0383188643027097, -5.730994833076631e-13),
    (0.04580953603181115, -5.16945692881222e-13), (0.053244514518155484, 6.567993368985218e-13),
    (0.06062462181580486, 6.299848199383311e-13), (0.06795066190898069, -4.729424109166329e-13),
    (0.07522342123775161, -1.6408301585598662e-13), (0.08244366921098845, 8.614512936087814e-14),
    (0.08961215869021544, -5.283050530808144e-13), (0.09672962645890948, -3.5836667430094137e-13),
    (0.10379679368088546, 7.581073923016376e-13), (0.11081436634049169, -2.0157368416016215e-13),
    (0.11778303565552051, 8.629474042969438e-13), (0.1247034785010328, -7.556920687451337e-14),
    (0.1315763577895268, -8.075373495358435e-13), (0.13840232285838283, 7.363043577087051e-13),
    (0.14518200984457508, -7.718001336828099e-14), (0.15191604202664166, -7.996871607743758e-13),
    (0.15860503017574956, 8.890223439724663e-13), (0.16524957289584563, -5.384682618788232e-13),
    (0.17185025692742784, -7.686134224018169e-13), (0.17840765747314435, -3.2605717931058157e-13),
    (0.18492233849428885, -2.7685884310448306e-13), (0.1913948530000198, -3.903387893794952e-13),
    (0.1978257433293038, 6.160755775588723e-13), (0.20421554142922105, -5.30156516006026e-13),
    (0.21056476910780475, -4.55112422774782e-13), (0.21687393830143264, -8.182853292737783e-13),
    (0.22314355131493357, -7.238189921749681e-13), (0.22937410106533207, -4.86240001538379e-13),
    (0.23556607131286, -9.30945949519689e-14), (0.24171993688651128, 6.338907368997553e-13),
    (0.24783616390413954, 4.4171755371315547e-13), (0.25391520998164196, -6.785208495970588e-13),
    (0.25995752443668607, 2.3999540484211735e-13), (0.2659635484978935, -7.555569400283742e-13),
    (0.27193371548310097, 5.407904186145515e-13), (0.2778684510030871, 3.692037508208009e-13),
    (0.28376817313073843, -9.3834172236637e-14), (0.28963329258294834, 9.43339818951269e-14),
    (0.29546421289342106, 4.148131870425857e-13), (0.3012613305781997, -3.7923164802093147e-14),
    (0.3070250352957373, -8.25463138725004e-13), (0.31275571000333, 5.668653582900739e-13),
    (0.318453731119007, -4.723727821986367e-13), (0.32411946865431673, -1.0475750058776541e-13),
    (0.32975328637257917, -1.1118671389559323e-13), (0.33535554192167183, -5.339989292003297e-13),
    (0.3409265869704541, 1.3912841212197566e-13), (0.3464667673470103, -8.017372713972018e-13),
    (0.35197642315688427, 2.9391859187648e-13), (0.3574558889213222, 4.815896111723205e-13),
    (0.3629054936900502, -6.817539406325327e-13), (0.36832556115950865, -8.009990055432491e-13),
    (0.3737164097929053, 6.787566823158706e-13), (0.37907835293481185, 1.5761203773969435e-13),
    (0.3844116989112081, -8.760375990774874e-13), (0.38971675114044046, -4.152515806343612e-13),
    (0.3949938082405424, 3.2655698896907146e-13), (0.40024316412745975, -4.4704265010452445e-13),
    (0.4054651081078191, 3.452764795203977e-13), (0.4106599249844294, 8.390050778518307e-13),
    (0.4158278951435932, 1.1776978751369214e-13), (0.4209692946442374, -1.0774341461609579e-13),
    (0.42608439531068143, 2.186334329321591e-13), (0.43117346481813, 2.413263949133313e-13),
    (0.4362367667745275, 3.90574622098307e-13), (0.44127456080423144, 6.437879097373207e-13),
    (0.44628710262804816, 3.713514191959202e-13), (0.45127464413963025, -1.7166921336082432e-13),
    (0.4562374334818742, -2.8658285157914353e-13), (0.4611757151214988, 6.713692791384601e-13),
    (0.46608972992544295, -8.437281040871276e-13), (0.4709797152190731, -2.821014384618127e-13),
    (0.4758459048698569, 1.0701931762114255e-13), (0.4806885293455707, 1.8119346366441111e-13),
    (0.4855078157816024, 9.840465278232627e-14), (0.49030398804461583, 5.780031989454028e-13),
    (0.49507726679803454, -1.8302857356041668e-13), (0.4998278695566114, -1.620740015674495e-13),
    (0.5045560107519123, 4.83033149495532e-13), (0.5092619017905236, -7.156055317238212e-13),
    (0.5139457511013461, 8.882123951857185e-13), (0.5186077642083546, -3.0900580513238243e-13),
    (0.5232481437651586, -6.10765519728515e-13), (0.5278670896204858, 3.565996966334783e-13),
    (0.532464798869114, 3.5782396591276384e-13), (0.5370414658973459, -4.622608700154458e-13),
    (0.5415972824321216, 6.227976291722515e-13), (0.5461324375974073, 7.283894727206574e-13),
    (0.5506471179523942, 2.680964661521167e-13), (0.5551415075406112, -1.0960825046059278e-13),
    (0.5596157879353996, 2.3119493838005378e-14), (0.5640701382853877, -5.846905800529924e-13),
    (0.5685047353526897, -2.1037482511444942e-14), (0.5729197535620187, -2.332318294558741e-13),
    (0.5773153650352469, -4.2333694288141915e-13), (0.5816917396350618, -4.3933937969737843e-13),
    (0.5860490450031648, 4.1341647073835564e-13), (0.590387446602108, 6.841763641591467e-14),
    (0.5947071077462169, 4.758553400443064e-13), (0.5990081896452466, 8.367967867475769e-13),
    (0.6032908514389419, -8.576373464665864e-13), (0.6075552502243227, 2.1913281229340092e-13),
    (0.6118015411066153, -6.224284253643115e-13), (0.6160298772156239, -1.098359432543843e-13),
    (0.6202404097512044, 6.531043137763365e-13), (0.6244332880123693, -4.758019902171077e-13),
    (0.6286086594227527, -3.785425126545704e-13), (0.6327666695706284, 4.0939233218678666e-13),
    (0.636907462236195, 8.742438391485829e-13), (0.6410311794206791, 2.521818845684288e-13),
    (0.6451379613736208, -3.6081313604225574e-14), (0.649227946625615, -5.05185559242809e-13),
    (0.6533012720119586, 7.869940332335532e-13), (0.6573580727090302, -6.702087696194906e-13),
    (0.6613984822452039, 1.6108575753932459e-13), (0.6654226325445052, 5.852718843625151e-13),
    (0.6694306539429817, -3.5246757297904794e-13), (0.6734226752123504, -1.8372084495629058e-13),
    (0.6773988235909201, 8.860668981349492e-13), (0.6813592248072382, 6.64862680714687e-13),
    (0.6853040030982811, 6.383161517064652e-13), (0.6892332812385575, 2.5144230728376075e-13),
    (0.6931471805601177, -1.7239444525614835e-13),
]


def _tlog():
    """Tabelle ``t_log_Float64`` aus Julias ``base/special/log.jl`` (N = 39)."""
    return _TLOG


def _tlog_rechnen():
    """Die Tabelle ``_TLOG`` neu berechnen (wie bis 1.6.3; zur Prüfung des Literals)."""
    with localcontext() as ctx:
        ctx.prec = 80
        sn = Decimal(2) ** 39
        tab = []
        for j in range(129):
            lb = (Decimal(1) + Decimal(j) / Decimal(128)).ln()
            hi = (sn * lb).to_integral_value(rounding="ROUND_HALF_EVEN") / sn
            tab.append((float(hi), float(lb - hi)))
    return tab


def _jl_log10(x) -> float:
    """Julia ``log10(x)`` (``Base.Math._log``, Tang-Verfahren; nicht libm, das an 10^k-Grenzen abweicht)."""
    x = float(x)
    mhi, mlo = 0.4342944819032518, 1.098319650216765e-17
    if x > 0.0:
        if x == math.inf:
            return x
        if 0.9394130628134757 < x < 1.0644944589178595:
            f = x - 1.0
            g = 1.0 / (2.0 + f)
            u = 2.0 * f * g
            v = u * u
            q = u * v * (0.08333333333333179 + v * (0.012500000003771751 + v * (0.0022321399879194482
                                                                                 + v * 0.0004348877777076146)))
            return math.fma(mhi, u, math.fma(mlo, u, mhi * math.fma(math.fma(-u, f, 2 * (f - u)), g, q)))
        xu = _f2u(x)
        m = (xu >> 52) & 0x7FF
        if m == 0:
            x *= 1.8014398509481984e16
            xu = _f2u(x)
            m = ((xu >> 52) & 0x7FF) - 54
        m -= 1023
        y = _u2f((xu & 0x000FFFFFFFFFFFFF) | 0x3FF0000000000000)
        mf = float(m)
        F = (y + 3.5184372088832e13) - 3.5184372088832e13
        f = y - F
        hi, lo = _tlog()[int(128.0 * F) - 128]
        l_hi = mf * 0.6931471805601177 + hi
        l_lo = mf * -1.7239444525614835e-13 + lo
        u = (2.0 * f) / (y + F)
        v = u * u
        q = u * v * (0.08333333333303913 + v * 0.012500053168098584)
        return math.fma(mhi, l_hi, math.fma(mhi, (u + (q + l_lo)), mlo * l_hi))
    if x == 0.0:
        return -math.inf
    if math.isnan(x):
        return math.nan
    raise ValueError("log10 was called with a negative real argument but will only return a complex result "
                     "if called with a complex argument. Try log10(Complex(x)).")


def _rint(v) -> float:
    """Julia ``round(v)`` (RoundNearest, Gleichstand zur geraden Zahl; Vorzeichen der Null bleibt)."""
    v = float(v)
    if not math.isfinite(v):
        return v
    return math.copysign(float(round(v)), v)


def _jl_ceil(v) -> float:
    """Julia ``ceil(v)`` für Float64 (``ceil(-0.5) = -0.0``; Python ``math.ceil`` liefert ``0``)."""
    v = float(v)
    return math.copysign(float(math.ceil(v)), v) if math.isfinite(v) else v


def _jl_round(x, digits=0) -> float:
    """Julia ``round(x; digits)`` für Float64: ``round(x * 10^d) / 10^d`` (``Base._round_digits``).

    Daher z. B. ``round(2.675; digits = 2) = 2.68`` (Python ``round`` gibt ``2.67``); nicht endliche
    ``x`` bleiben, sehr große ``digits`` über ``10^(d/2)`` wie Julias ``_round_invstepsqrt``.
    """
    fx = float(x)
    if not math.isfinite(fx):
        return fx
    if digits >= 0:
        inv = _jl_pow_int(10.0, digits)
        if math.isfinite(inv):
            y = _rint(fx * inv) / inv
        else:
            s = _jl_pow(10.0, digits / 2)
            y = _rint((fx * s) * s) / s / s
        return y if math.isfinite(y) else fx
    step = _jl_pow_int(10.0, -digits)
    y = _rint(fx / step) * step
    if not math.isfinite(y):
        return 0.0 if fx > 0 else (-0.0 if fx < 0 else fx)
    return y


def _jl_round_sig(x, sig) -> float:
    """Julia ``round(x; sigdigits)``: ``hidigit`` mit Julias ``log10`` (``_jl_log10``), dann ``_jl_round``."""
    x = float(x)
    if not math.isfinite(x):
        return x
    h = 0 if x == 0 else 1 + math.floor(_jl_log10(abs(x)))
    return _jl_round(x, sig - h)


def _jl_mod(a, y) -> float:
    """Julia ``mod(a, y)`` für Float64 (Ergebnis mit dem Vorzeichen von ``y``); gebraucht von ``_jl_str``."""
    r = math.fmod(a, y)
    if r == 0:
        return math.copysign(0.0, y)
    return r if (r > 0) == (y > 0) else r + y


def _jl_str(v) -> str:
    """Julia ``string(v)`` für Bool, Ganzzahlen und Float64 (kürzeste Darstellung wie ``Base.Ryu``).

    Ganzzahlen ohne ``.0`` (``70``), Float64 mit ``.0`` (``360.0``), Exponent ab 1e6 und unter 1e-4
    in Julias Form (``1.0e6``, ``1.0e-5``), ``NaN``/``Inf``/``-Inf``, ``-0.0``.
    """
    if isinstance(v, (bool, np.bool_)):
        return "true" if v else "false"
    if isinstance(v, (int, np.integer)):
        return str(int(v))
    x = float(v)
    if math.isnan(x):
        return "NaN"
    if math.isinf(x):
        return "Inf" if x > 0 else "-Inf"
    if x == 0:
        return "-0.0" if math.copysign(1.0, x) < 0 else "0.0"
    mant, _, ex = repr(abs(x)).partition("e")
    ip, _, fp = mant.partition(".")
    if fp == "0":
        fp = ""
    digits = (ip + fp).lstrip("0")
    nexp = (int(ex) if ex else 0) - len(fp)
    stripped = digits.rstrip("0")
    nexp += len(digits) - len(stripped)
    digits = stripped
    olength = len(digits)
    pt = nexp + olength
    sign = "-" if x < 0 else ""
    if -4 < pt <= 6 and not (pt >= olength and abs(_jl_mod(x + 0.05, float(10 ** (pt - olength))) - 0.05) > 0.05):
        if pt <= 0:
            return sign + "0." + "0" * (-pt) + digits
        if pt >= olength:
            return sign + digits + "0" * nexp + ".0"
        return sign + digits[:pt] + "." + digits[pt:]
    return sign + digits[0] + "." + (digits[1:] or "0") + "e" + str(pt - 1)


def _jl_fmt(fmt: str, v) -> str:
    """Julia ``@sprintf(fmt, v)`` für ein Zahlenformat ohne Breite (``NaN``/``Inf``/``-Inf`` wie Julia)."""
    v = float(v)
    if math.isfinite(v):
        return fmt % v
    return "NaN" if math.isnan(v) else ("Inf" if v > 0 else "-Inf")


def _jl_min(a, b) -> float:
    """Julia ``min`` für Float64 (NaN gewinnt, ``-0.0 < 0.0``; Python ``min`` hängt von der Reihenfolge ab)."""
    a, b = float(a), float(b)
    if a != a or b != b:
        return math.nan
    if a == b:
        return a if math.copysign(1.0, a) < 0 else b
    return a if a < b else b


def _jl_max(a, b) -> float:
    """Julia ``max`` für Float64 (NaN gewinnt, ``-0.0 < 0.0``)."""
    a, b = float(a), float(b)
    if a != a or b != b:
        return math.nan
    if a == b:
        return b if math.copysign(1.0, a) < 0 else a
    return a if a > b else b


def _jl_minimum(v) -> float:
    """Julia ``minimum`` (NaN gewinnt, ``-0.0`` vor ``0.0``); leer → Fehler wie Julia."""
    a = np.asarray(v, dtype=np.float64).ravel()
    if a.size == 0:
        raise ValueError("reducing over an empty collection is not allowed; consider supplying `init` to the reducer")
    if np.isnan(a).any():
        return math.nan
    m = float(a.min())
    if m == 0 and bool(np.any((a == 0) & np.signbit(a))):
        return -0.0
    return m


def _jl_maximum(v) -> float:
    """Julia ``maximum`` (NaN gewinnt, ``0.0`` vor ``-0.0``); leer → Fehler wie Julia."""
    a = np.asarray(v, dtype=np.float64).ravel()
    if a.size == 0:
        raise ValueError("reducing over an empty collection is not allowed; consider supplying `init` to the reducer")
    if np.isnan(a).any():
        return math.nan
    m = float(a.max())
    if m == 0 and bool(np.any((a == 0) & ~np.signbit(a))):
        return 0.0
    return m


# Gleitkommabereiche `collect(start:step:stop)` (Julia `base/twiceprecision.jl`)

def _jl_rat(x) -> tuple[int, int]:
    """Julia ``Base.rat``: Kettenbruch-Näherung ``(Zähler, Nenner)`` bis 2^24 (Start von ``floatrange``)."""
    y = x
    a = d = 1
    b = c = 0
    while abs(y) <= _M24:
        f = int(y)
        y -= f
        a, c = f * a + c, a
        b, d = f * b + d, b
        if max(abs(a), abs(b)) > _M24:
            return c, d
        if b != 0 and float(a) / float(b) == x:
            break
        y = 1.0 / y if y != 0 else math.copysign(math.inf, y)
    return a, b


def _canon2(big: float, little: float) -> tuple[float, float]:
    """Julia ``Base.canonicalize2`` (TwicePrecision)."""
    h = big + little
    return h, (big - h) + little


def _add12(x: float, y: float) -> tuple[float, float]:
    """Julia ``Base.add12`` (TwicePrecision)."""
    if abs(y) > abs(x):
        x, y = y, x
    return _canon2(x, y)


def _truncbits(x: float, nb: int) -> float:
    """Julia ``Base.truncbits``: die unteren ``nb`` Bits der Mantisse löschen."""
    return x if nb <= 0 else _u2f(_f2u(x) & ((_U64 << nb) & _U64))


def _tp_int(i: int) -> tuple[float, float]:
    """``TwicePrecision{Float64}(i)`` einer Ganzzahl."""
    hi = _truncbits(float(i), 27)
    return _canon2(hi, float(i - int(hi)))


def _tp_div(x, y) -> tuple[float, float]:
    """Division zweier ``TwicePrecision``-Werte (Julia ``/``)."""
    hi = x[0] / y[0]
    uh, ul = _two_mul(hi, y[0])
    if not math.isfinite(uh):
        ul = uh
    if hi == 0 or not math.isfinite(hi):
        return (hi, hi)
    return _canon2(hi, ((((x[0] - uh) - ul) + x[1]) - hi * y[1]) / y[0])


def _tp_ratio(n: int, d: int, nb=None) -> tuple[float, float]:
    """``TwicePrecision{Float64}((n, d))``, optional mit ``nb`` gekappten Bits (``twiceprecision(…, nb)``)."""
    v = _tp_div(_tp_int(n), (float(d), 0.0))
    if nb is None:
        return v
    hi = _truncbits(v[0], nb)
    return (hi, (v[0] - hi) + v[1])


def _tdiv(a: int, b: int) -> int:
    """Julias ``div`` für Ganzzahlen (Richtung null)."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b > 0) else -q


def _isbetween(a, x, b) -> bool:
    return a <= x <= b or b <= x <= a


def _srl_values(ref, step, length: int, offset: int) -> list[float]:
    """Elemente einer ``StepRangeLen`` mit TwicePrecision-Bezug ``ref`` und Schritt ``step``."""
    out = []
    for i in range(1, length + 1):
        u = i - offset
        shi, slo = u * step[0], u * step[1]
        xhi, xlo = _add12(ref[0], shi)
        out.append(xhi + (xlo + (slo + ref[1])))
    return out


def _floatrange(start_n: int, step_n: int, length: int, den: int) -> list[float]:
    """Julia ``Base.floatrange(start_n, step_n, len, den)``."""
    if length < 2 or step_n == 0:
        return _srl_values(_tp_ratio(start_n, den), _tp_ratio(step_n, den, 0), length, 1)
    imin = int(min(max(_rint(-start_n / step_n + 1), 1), length))
    ref_n = start_n + (imin - 1) * step_n
    nb = min(27, int(max(imin - 1, length - imin) - 1).bit_length() + 1)
    return _srl_values(_tp_ratio(ref_n, den), _tp_ratio(step_n, den, nb), length, imin)


def _jl_range(start, step, stop) -> list[float]:
    """Werte von Julias ``collect(start:step:stop)`` für Float64 (Bereich mit doppelter Genauigkeit).

    Z. B. ``collect(0.0:0.1:1.0)[4] == 0.3`` (naiv ``3 * 0.1 = 0.30000000000000004``).
    """
    start, step, stop = float(start), float(step), float(stop)
    if step == 0:
        raise ValueError("range step cannot be zero")
    step_n, step_d = _jl_rat(step)
    if step_d != 0 and step_n / step_d == step:
        start_n, start_d = _jl_rat(start)
        stop_n, stop_d = _jl_rat(stop)
        if start_d != 0 and stop_d != 0 and start_n / start_d == start and stop_n / stop_d == stop:
            den = _wrap64(start_d * _tdiv(step_d, math.gcd(start_d, step_d)))
            if den != 0 and abs(start * den) <= _M53 and abs(step * den) <= _M53 and \
                    den % start_d == 0 and den % step_d == 0:
                start_n = _wrap64(start_n * _tdiv(den, start_d))
                step_n = _wrap64(step_n * _tdiv(den, step_d))
                num = _wrap64(_wrap64(_wrap64(den * stop_n) - _wrap64(stop_d * start_n)) + _wrap64(step_n * stop_d))
                dd = _wrap64(step_n * stop_d)
                length = max(0, _tdiv(num, dd)) if dd != 0 else 0
                if _isbetween(start, start + (length - 1) * step, stop + step / 2) and \
                        not _isbetween(start, start + length * step, stop):
                    return _floatrange(start_n, step_n, length, den)
    lf = (stop - start) / step
    if lf < 0:
        length = 0
    elif lf == 0:
        length = 1
    else:
        length = int(_rint(lf)) + 1
        stop2 = start + (length - 1) * step
        length -= int(start < stop < stop2) + int(start > stop > stop2)
    return _srl_values((start, 0.0), (step, 0.0), length, 1)


def _jl_isequal(a, b) -> bool:
    """Julia ``isequal`` für Zahlen, Texte und ``nothing`` (NaN gleich NaN, ``-0.0`` ungleich ``0.0``)."""
    if a is None or b is None:
        return a is None and b is None
    if isinstance(a, str) or isinstance(b, str):
        return isinstance(a, str) and isinstance(b, str) and a == b
    fa, fb = float(a), float(b)
    if fa != fa or fb != fb:
        return fa != fa and fb != fb
    return fa == fb and math.copysign(1.0, fa) == math.copysign(1.0, fb)


def _jl_unique(vals) -> list:
    """Julia ``unique`` (Vergleich mit ``isequal``), Reihenfolge des ersten Auftretens."""
    out = []
    for v in vals:
        if not any(_jl_isequal(v, o) for o in out):
            out.append(v)
    return out


def _jl_sort_levels(vals) -> list:
    """``sort(unique(v); alg = MergeSort, lt = RStats.r_isless)``: Texte nach R's Kollation, Zahlen wie ``isless``.

    Reihenfolge der Stufen in Julias Grafiken (Achsen/Legenden aus ``unique``-Werten).
    """
    from ._r._collate import collate_key

    def key(v):
        if isinstance(v, str):
            return (0, collate_key(v))
        if v is None:
            return (2, 0)
        f = float(v)
        return (1, (1, 0.0, 0) if f != f else (0, f, 0 if math.copysign(1.0, f) < 0 else 1))
    return sorted(_jl_unique(vals), key=key)
