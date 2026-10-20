"""Einkommensteuertarif und Solidaritätszuschlag als Datei (Port von ``tax_tariff.R``).

* :func:`read_tax_tariff` liest und prüft eine Tarifdatei (Standard: mitgelieferte
  ``simlev/data/steuertarif.csv``, ab VZ 2026, wie ``inst/extdata/steuertarif.csv`` in R).
* ``tariff_income_tax`` (R: ``.tariff_income_tax``) – tarifliche Einkommensteuer
  (§ 32a Abs. 1 EStG, Rundung auf volle Euro).
* ``tariff_soli`` (R: ``.tariff_soli``) – Solidaritätszuschlag auf die ESt (§§ 3, 4 SolZG).

Verwendet von ``simulation(taxable_income =, tax_tariff =)``.
"""
from __future__ import annotations

import math
import os
import re
import warnings
from typing import Any

import pandas as pd

from ._rnum import NA_REAL, r_format1, r_round, r_signif, r_sprintf

__all__ = ["SimLevTaxTariff", "read_tax_tariff", "default_tariff_file"]

_NUM_RE = re.compile(r"^\s*[-+]?((\d+\.?\d*|\.\d+)([eE][-+]?\d+)?|0[xX][0-9a-fA-F]+|Inf|inf|NaN|NA)\s*$")


def default_tariff_file() -> str:
    """Pfad der mitgelieferten Tarifdatei (R: ``system.file("extdata", "steuertarif.csv")``)."""
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "steuertarif.csv")


def _as_numeric(s: Any) -> float:
    """``as.numeric()`` für eine Zeichenkette (NA bei ungültigem Text)."""
    if s is None:
        return NA_REAL
    s = str(s)
    if not _NUM_RE.match(s):
        return NA_REAL
    t = s.strip()
    if t == "NA":
        return NA_REAL
    if t == "NaN":
        return math.nan
    if t.lstrip("+-").lower().startswith("0x"):
        sign = -1.0 if t.startswith("-") else 1.0
        return sign * float(int(t.lstrip("+-"), 16))
    if t.lstrip("+-") in ("Inf", "inf"):
        return -math.inf if t.startswith("-") else math.inf
    return float(t)


def _split_csv_line(line: str) -> list[str]:
    """Felder einer CSV-Zeile (Komma, Anführungszeichen wie ``read.csv``)."""
    out, cur, q = [], [], False
    i = 0
    while i < len(line):
        ch = line[i]
        if q:
            if ch == '"':
                if i + 1 < len(line) and line[i + 1] == '"':
                    cur.append('"')
                    i += 1
                else:
                    q = False
            else:
                cur.append(ch)
        elif ch == '"':
            q = True
        elif ch == ",":
            out.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
        i += 1
    out.append("".join(cur))
    return [x.strip() for x in out]


class SimLevTaxTariff:
    """Einkommensteuertarif (R-Klasse ``SimLevTaxTariff``).

    Felder wie in R: ``zones`` (``pandas.DataFrame`` mit ab, bezug, teiler, a, b, c),
    ``soli`` (``dict`` freigrenze, satz, milderung; Sätze in Prozent), ``geltung`` (Text oder
    ``None``) und ``file`` (Pfad).
    """

    def __init__(self, zones: pd.DataFrame, soli: dict, geltung: str | None, file: str):
        self.zones = zones
        self.soli = soli
        self.geltung = geltung
        self.file = file

    def __getitem__(self, key: str) -> Any:
        return getattr(self, key)

    def keys(self) -> list[str]:
        return ["zones", "soli", "geltung", "file"]

    def format(self) -> str:
        """Druckausgabe wie ``print.SimLevTaxTariff``."""
        out = ["Einkommensteuertarif (SimLev)",
               "  Geltung: %s" % ("(keine Angabe in der Datei)" if self.geltung is None else self.geltung),
               "  Datei:   %s" % self.file,
               "  Zonen (x = zvE in EUR, auf volle Euro abgerundet; Steuer (a*u + b)*u + c, u = (x - bezug)/teiler):"]
        z = self.zones
        ab = [float(v) for v in z["ab"]]
        hi = [v - 1 for v in ab[1:]] + [math.inf]
        for k in range(len(ab)):
            out.append(r_sprintf("    %10s - %-10s  bezug %9s  teiler %6s  a %8s  b %8s  c %10s",
                                 r_format1(ab[k], big_mark=" "),
                                 r_format1(hi[k], big_mark=" ") if math.isfinite(hi[k]) else "",
                                 r_format1(float(z["bezug"].iloc[k])), r_format1(float(z["teiler"].iloc[k])),
                                 r_format1(float(z["a"].iloc[k])), r_format1(float(z["b"].iloc[k])),
                                 r_format1(float(z["c"].iloc[k]))))
        out.append(r_sprintf("  Soli: %s %% der ESt, wenn die ESt %s EUR übersteigt (Freigrenze); "
                             "höchstens %s %% des Mehrbetrags",
                             r_format1(self.soli["satz"]),
                             r_format1(self.soli["freigrenze"], big_mark=" ", scientific=False),
                             r_format1(self.soli["milderung"])))
        return "\n".join(out)

    def __repr__(self) -> str:
        return self.format()

    __str__ = __repr__

    def print(self) -> "SimLevTaxTariff":
        print(self.format())
        return self


def read_tax_tariff(file: str | None = None) -> SimLevTaxTariff:
    """Einkommensteuertarif (§ 32a Abs. 1 EStG) und Soli (§§ 3, 4 SolZG) aus einer CSV-Datei lesen.

    ``file=None`` liest die mitgelieferte Datei (Rechtslage ab VZ 2026, Einzelveranlagung).
    Format und Prüfungen wie ``read_tax_tariff()`` im R-Paket (Komma als Trennzeichen, Punkt
    als Dezimalzeichen, Zeilen mit ``#`` sind Kommentare; Spalten ``art, ab, bezug, teiler,
    a, b, c``).
    """
    if file is None:
        file = default_tariff_file()
        if not os.path.exists(file):
            raise ValueError("read_tax_tariff: Die mitgelieferte Datei extdata/steuertarif.csv wurde nicht gefunden "
                             "(Paket unvollständig installiert?).")
    if not isinstance(file, (str, os.PathLike)):
        raise ValueError("read_tax_tariff: 'file' muss ein einzelner Dateipfad (Zeichenkette) oder NULL sein.")
    file = os.fspath(file)
    if not os.path.exists(file):
        raise ValueError("read_tax_tariff: Datei '%s' nicht gefunden." % file)
    with open(file, encoding="utf-8") as fh:
        raw = fh.read().splitlines()
    gl = [ln for ln in raw if re.match(r"^#\s*Geltung\s*:", ln)]
    geltung = re.sub(r"^#\s*Geltung\s*:", "", gl[0]).strip() if gl else None
    body = [re.sub(r"#.*$", "", ln).strip() for ln in raw]
    body = [ln for ln in body if ln]
    if body:
        nf = [ln.count(",") + 1 for ln in body]
        if nf[0] == 1:
            raise ValueError(
                "read_tax_tariff: In '%s' wurde nur eine Spalte gelesen (Kopfzeile '%s'). Erwartet wird Komma als "
                "Trennzeichen%s und Punkt als Dezimalzeichen, z. B. 'zone,69879,0,1,0,0.42,-11135.63'."
                % (file, body[0], " (die Datei verwendet offenbar Semikolon, z. B. aus deutschem Excel)"
                   if ";" in body[0] else ""))
        for i in range(1, len(nf)):
            if nf[i] != nf[0]:
                raise ValueError(
                    "read_tax_tariff: In '%s' hat die Zeile '%s' %d Felder, die Kopfzeile %d. Dezimalzeichen ist der "
                    "Punkt (0.42, nicht 0,42); Komma nur als Trennzeichen." % (file, body[i], nf[i], nf[0]))
    if not body:
        raise ValueError("read_tax_tariff: Datei '%s' ist keine lesbare CSV-Datei (no lines available in input)." % file)
    header = _split_csv_line(body[0])
    rows = [_split_csv_line(ln) for ln in body[1:]]
    d = {h: [r[j] if j < len(r) else "" for r in rows] for j, h in enumerate(header)}
    need = ["art", "ab", "bezug", "teiler", "a", "b", "c"]
    miss = [c for c in need if c not in d]
    if miss:
        raise ValueError("read_tax_tariff: In '%s' fehlen die Spalten %s (erwartet: %s)."
                         % (file, ", ".join(miss), ",".join(need)))
    art = [a.lower() for a in d["art"]]
    bad = [i for i, a in enumerate(art) if a not in ("zone", "soli")]
    if bad:
        raise ValueError("read_tax_tariff: Datenzeile %d hat art = '%s'; erlaubt sind \"zone\" und \"soli\"."
                         % (bad[0] + 1, d["art"][bad[0]]))

    def num(col: str, rws: list[int]) -> list[float]:
        v = [_as_numeric(d[col][i]) for i in rws]
        nb = [k for k, x in enumerate(v) if not math.isfinite(x)]
        if nb:
            i = rws[nb[0]]
            raise ValueError("read_tax_tariff: Spalte '%s' in Datenzeile %d (art = %s) ist nicht numerisch bzw. "
                             "nicht endlich ('%s')." % (col, i + 1, art[i], d[col][i]))
        return v

    zr = [i for i, a in enumerate(art) if a == "zone"]
    sr = [i for i, a in enumerate(art) if a == "soli"]
    if not zr:
        raise ValueError("read_tax_tariff: Die Datei enthält keine Tarifzone (art = \"zone\").")
    if len(sr) != 1:
        raise ValueError("read_tax_tariff: Es muss genau eine soli-Zeile geben (gefunden: %d)." % len(sr))
    zd = {c: num(c, zr) for c in ("ab", "bezug", "teiler", "a", "b", "c")}
    z = pd.DataFrame(zd)
    ab = zd["ab"]
    if ab[0] != 0:
        raise ValueError("read_tax_tariff: Die erste Zone muss bei ab = 0 beginnen (ist %s)." % r_format1(ab[0]))
    for k in range(len(ab) - 1):
        if ab[k + 1] - ab[k] <= 0:
            raise ValueError("read_tax_tariff: Die Zonen müssen streng aufsteigend sein (Zone %d ab %s folgt auf "
                             "ab %s)." % (k + 2, r_format1(ab[k + 1]), r_format1(ab[k])))
    for k, t in enumerate(zd["teiler"]):
        if t <= 0:
            raise ValueError("read_tax_tariff: teiler muss > 0 sein (Zone ab %s)." % r_format1(ab[k]))
    soli = {"freigrenze": num("ab", sr)[0], "satz": num("a", sr)[0], "milderung": num("b", sr)[0]}
    if soli["freigrenze"] < 0:
        raise ValueError("read_tax_tariff: Die Soli-Freigrenze (ab) darf nicht negativ sein.")
    for s in ("satz", "milderung"):
        if soli[s] < 0 or soli[s] > 100:
            raise ValueError("read_tax_tariff: Soli-%s muss zwischen 0 und 100 Prozent liegen (ist %s)."
                             % ("Zuschlagsatz (a)" if s == "satz" else "Milderungssatz (b)", r_format1(soli[s])))
    out = SimLevTaxTariff(z, soli, geltung, os.path.realpath(os.path.abspath(file)))

    def f(j: int, x: float) -> float:
        u = (x - zd["bezug"][j]) / zd["teiler"][j]
        return (zd["a"][j] * u + zd["b"][j]) * u + zd["c"][j]

    unit_hint = ("Einheiten prüfen: bei linearen Zonen (a = 0, bezug = 0, teiler = 1) ist b der Grenzsteuersatz "
                 "als Anteil (0.42 für 42 %, nicht 42), die Soli-Sätze dagegen in Prozent (5.5); "
                 "ab, bezug, c in EUR")
    nz = len(ab)
    for k in range(nz):
        x_hi = ab[k + 1] - 1 if k < nz - 1 else max(ab[k], 1e7)
        xs = [ab[k]]
        x2 = max(ab[k], x_hi)
        if x2 != ab[k]:
            xs.append(x2)
        for x in xs:
            u = (x - zd["bezug"][k]) / zd["teiler"][k]
            m = (2 * zd["a"][k] * u + zd["b"][k]) / zd["teiler"][k]
            if not math.isfinite(m) or m < -1e-12 or m > 1 + 1e-12:
                raise ValueError(
                    "read_tax_tariff: Zone ab %s EUR (Datenzeile %d): Grenzsteuersatz %s bei x = %s EUR liegt nicht "
                    "zwischen 0 und 1 (0 bis 100 %%). %s." % (r_format1(ab[k], scientific=False), zr[k] + 1,
                                                             r_format1(r_signif(m, 6)),
                                                             r_format1(x, scientific=False), unit_hint))
            if f(k, x) > x + 1e-9:
                raise ValueError(
                    r_sprintf("read_tax_tariff: Zone ab %s EUR (Datenzeile %d): Steuer %.2f EUR bei x = %s EUR "
                              "übersteigt das Einkommen. %s.", r_format1(ab[k], scientific=False), zr[k] + 1,
                              f(k, x), r_format1(x, scientific=False), unit_hint))
    for k in range(1, nz):
        jump = f(k, ab[k]) - f(k - 1, ab[k])
        if abs(jump) > 1:
            warnings.warn(r_sprintf("read_tax_tariff: Der Tarif springt an der Zonengrenze %s EUR um %.2f EUR "
                                    "(vorige Zone %.2f, neue Zone %.2f EUR); Tarifdatei prüfen.",
                                    r_format1(ab[k], scientific=False), jump, f(k - 1, ab[k]), f(k, ab[k])),
                          stacklevel=2)
    return out


def tariff_income_tax(tariff: SimLevTaxTariff, zve: float) -> float:
    """Tarifliche Einkommensteuer T(x) in vollen EUR (R: ``.tariff_income_tax``)."""
    z = tariff.zones
    ab = z["ab"].to_numpy()
    x = max(0.0, math.floor(zve + 1e-9))
    k = max(i for i in range(len(ab)) if ab[i] <= x)
    u = (x - float(z["bezug"].iloc[k])) / float(z["teiler"].iloc[k])
    v = (float(z["a"].iloc[k]) * u + float(z["b"].iloc[k])) * u + float(z["c"].iloc[k])
    return max(0.0, float(math.floor(r_round(v, 6))))


def tariff_soli(tariff: SimLevTaxTariff, est: float) -> float:
    """Solidaritätszuschlag S(E) auf die ESt (R: ``.tariff_soli``)."""
    s = tariff.soli
    if not est > s["freigrenze"]:
        return 0.0
    v = min(s["satz"] / 100 * est, s["milderung"] / 100 * (est - s["freigrenze"]))
    return float(math.floor(r_round(v * 100, 6))) / 100
