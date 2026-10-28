"""Asset-Konfiguration und Strategie-Objekte (Port von ``asset_config.R`` und ``strategy.R``).

R-Objekte mit Klasse werden als :class:`simlev._r.rlist.RList` abgebildet
(``x["share"]`` und ``x.share`` gleichwertig); ``print()`` bzw. ``str(x)``
liefern die Ausgabe der R-``print``-Methode.
"""
from __future__ import annotations

import datetime as _dt
import warnings
from typing import Any, Iterable, Mapping

import numpy as np

from ._r.rlist import RList
from ._r.rformat import r_deparse, r_format1, r_sprintf
from ._r.rnum import r_sum

__all__ = [
    "AssetConfig",
    "Strategy",
    "asset_config",
    "create_strategy",
    "strategy_validate",
    "strategy_add_asset",
    "strategy_update_asset",
    "strategy_remove_asset",
]

_ASSET_CLASSES = ("etf", "etn", "etc", "certificate", "etn_standard", "etn_deliverable")
_ACTION_TYPES = ("bnh", "signal")
_VALID_REGIMES = ("investment_fund", "capital_gains", "private_sale")
_FIELDS = ("asset_class", "trading", "share", "spread", "partial_exemption",
           "deliverable", "start", "tax_regime", "signal_buy", "signal_sell", "wrapper")


def _pmatch(value: str, choices: tuple) -> int | None:
    if value in choices:
        return choices.index(value)
    if not value:
        return None
    hits = [i for i, c in enumerate(choices) if c.startswith(value)]
    return hits[0] if len(hits) == 1 else None


def _match_arg(value: Any, choices: Iterable[str], argname: str = "arg") -> str:
    """Nachbildung von R's ``match.arg`` (inkl. eindeutiger Präfixe und R-Meldungen)."""
    choices = tuple(choices)
    if value is None:
        return choices[0]
    if isinstance(value, (list, tuple)):
        if tuple(value) == choices:
            return choices[0]
        if not all(isinstance(v, str) for v in value):
            raise ValueError("'arg' must be NULL or a character vector")
        if len(value) > 1:
            raise ValueError("'arg' must be of length 1")
        if len(value) == 0:
            value = ""
        else:
            value = value[0]
    if not isinstance(value, str):
        raise ValueError("'arg' must be NULL or a character vector")
    i = _pmatch(value, choices)
    if i is None:
        chs = [c for c in dict.fromkeys(choices) if c]
        raise ValueError(("'arg' should be %s" if len(chs) == 1 else "'arg' should be one of %s")
                         % ", ".join("“%s”" % c for c in chs))
    return choices[i]


def _is_num1(x: Any) -> bool:
    return isinstance(x, (int, float, np.integer, np.floating)) and not isinstance(x, (bool, np.bool_)) \
        and x == x


def _to_date(x: Any) -> _dt.date | None:
    from .engine import _as_date
    z = _as_date(x)
    if z is None:
        return None
    return _dt.date(1970, 1, 1) + _dt.timedelta(days=int(z))


# Meldung von asset_config() für wrapper mit trading = "signal" (strategy_from_weights() erkennt sie und nennt das Asset)
_AC_MSG_WRAPPER_SIGNAL = ("asset_config: mit wrapper ist nur trading = \"bnh\" möglich (keine Signale auf den Anteilswert; "
                          "Signale gehen in der inneren Strategie).")


def _is_wrapper(x: Any) -> bool:
    """``inherits(x, "SimLevWrapperConfig")`` (Fonds-Wrapper aus :func:`simlev.wrapper_config`)."""
    return "SimLevWrapperConfig" in (getattr(x, "r_class", None) or ())


def _cls_all(x: Any) -> str:
    """``paste(class(x), collapse = "/")`` für Meldungen."""
    rc = getattr(x, "r_class", None)
    if isinstance(rc, tuple) and rc:
        return "/".join(rc)
    if x is None:
        return "NULL"
    if isinstance(x, Mapping) or isinstance(x, (list, tuple)):
        return "list"
    return _r_class(x)


def _fmt15(x: Any) -> str:
    """``format(x, digits = 15)`` (R: ``.blk_fmt``)."""
    return r_format1(float(x), digits=15)


def _strategy_columns(strategy: Mapping[str, Any]) -> list:
    """Kursspalten einer Strategie (R: ``.strategy_columns``, ``wrapper.R``): je Asset sein Name, für
    Wrapper-Assets die Spalten der inneren Strategie; Reihenfolge wie in der Strategie, ohne Doppelte."""
    cols: list = []
    for nm, a in strategy.items():
        w = a.get("wrapper") if isinstance(a, Mapping) else None
        for c in (_strategy_columns(w["strategy"]) if _is_wrapper(w) else [str(nm)]):
            if c not in cols:
                cols.append(c)
    return cols


def _strategy_wrappers(strategy: Mapping[str, Any]) -> list:
    """Namen der Wrapper-Assets einer Strategie (R: ``.strategy_wrappers``)."""
    return [str(nm) for nm, a in strategy.items() if isinstance(a, Mapping) and a.get("wrapper") is not None]


def _wrapper_assets_text(strategy: Mapping[str, Any]) -> str:
    """``.wrapper_assets_text``: ``"A 60 %, B 40 %"``."""
    return ", ".join("%s %s %%" % (nm, _fmt15(100 * a["share"])) for nm, a in strategy.items())


class AssetConfig(RList):
    """Validierte Konfiguration eines Assets (R-Klasse ``asset_config``)."""

    r_class = ("asset_config", "list")

    def format(self) -> str:
        lines = ["Asset-Konfiguration", "-------------------",
                 "  Klasse:       %s" % self["asset_class"],
                 "  Aktion:       %s" % self["trading"],
                 r_sprintf("  Anteil:       %.1f%%", self["share"] * 100),
                 "  Steuerregime: %s" % self["tax_regime"]]
        if self["asset_class"] == "etf":
            lines.append(r_sprintf("  Teilfrei.:    %.0f%%", self["partial_exemption"]))
        if self["asset_class"] in ("etn", "etc"):
            lines.append("  Lieferbar:    %s" % ("TRUE" if self["deliverable"] else "FALSE"))
        w = self.get("wrapper")
        if _is_wrapper(w):
            lines.append("  Wrapper:      %s; Fondskosten %s %% p. a., Performancegebühr %s %%"
                         % (_wrapper_assets_text(w["strategy"]), _fmt15(w["costs"]["fee"]),
                            _fmt15(w["costs"]["performance_fee"])))
        return "\n".join(lines)

    def print(self) -> "AssetConfig":
        print(self.format())
        return self

    def summary(self) -> "AssetConfig":
        """``summary.asset_config``: wie ``print``."""
        return self.print()


def asset_config(
    *,
    asset_class: str | Iterable[str] = _ASSET_CLASSES,
    trading: str | Iterable[str] = _ACTION_TYPES,
    share: float = 1.0,
    spread: float = 0.0,
    partial_exemption: float = 0.0,
    deliverable: bool = False,
    start: Any = None,
    tax_regime: str | None = None,
    signal_buy: str | None = None,
    signal_sell: str | None = None,
    wrapper: Any = None,
) -> AssetConfig:
    """Asset-Konfiguration erstellen und prüfen (R: ``asset_config()``).

    Raten in Prozent: ``spread=0.1`` = 0,1 % voller Bid-Ask-Spread (Standard 0: ohne Spread; wer
    Spreads abbilden will, gibt sie an), ``partial_exemption=30`` = 30 % Teilfreistellung; ``share`` ist ein Anteil in (0, 1]. ``start`` (Datum oder
    ``"JJJJ-MM-TT"``) wird als ``datetime.date`` gespeichert.

    ``wrapper``: ``None`` oder ein Objekt aus :func:`simlev.wrapper_config` (Etappe 6.5c). Das Asset ist dann
    ein Fonds-Wrapper: sein Name ist keine Kursspalte, die Kurse sind der Anteilswert der inneren Strategie
    (:func:`simlev.wrapper_nav`); nur mit ``trading="bnh"``. Das Feld ``wrapper`` gibt es nur mit Wrapper.
    """
    asset_class = _match_arg(asset_class, _ASSET_CLASSES, "asset_class")
    trading = _match_arg(trading, _ACTION_TYPES, "trading")
    if asset_class == "etn_standard":
        warnings.warn("asset_config: asset_class = \"etn_standard\" ist veraltet; stattdessen asset_class = \"etn\" mit "
                      "deliverable = FALSE verwenden.", stacklevel=2)
        asset_class = "etn"
        deliverable = False
    elif asset_class == "etn_deliverable":
        warnings.warn("asset_config: asset_class = \"etn_deliverable\" ist veraltet; stattdessen asset_class = \"etn\" mit "
                      "deliverable = TRUE verwenden.", stacklevel=2)
        asset_class = "etn"
        deliverable = True
    for x, arg in ((share, "share"), (spread, "spread"), (partial_exemption, "partial_exemption")):
        if not _is_num1(x):
            raise ValueError("asset_config: %s muss eine einzelne Zahl sein, nicht %s." % (arg, r_deparse(x)))
    if share <= 0 or share > 1:
        raise ValueError("asset_config: share muss ein Anteil größer 0 und höchstens 1 sein (z. B. 0.6 für "
                         "60 %%), nicht %s%s." % (r_format1(share),
                                                  ("; für %s %% share = %s angeben"
                                                   % (r_format1(share), r_format1(share / 100)))
                                                  if 1 < share <= 100 else ""))
    if spread < 0:
        raise ValueError("asset_config: spread muss >= 0 sein (voller Spread in Prozent, z. B. 0.1 für 0,1 %%), "
                         "nicht %s." % r_format1(spread))
    if partial_exemption < 0 or partial_exemption > 100:
        raise ValueError("asset_config: partial_exemption muss zwischen 0 und 100 liegen (Teilfreistellung in Prozent, z. B. 30 "
                         "für 30 %%), nicht %s." % r_format1(partial_exemption))
    if 0 < partial_exemption < 1:
        warnings.warn("asset_config: partial_exemption = %s wird als %s %% Teilfreistellung gelesen (Prozent-Konvention); "
                      "gemeint war vermutlich %s." % (r_format1(partial_exemption), r_format1(partial_exemption),
                                                     r_format1(partial_exemption * 100)), stacklevel=2)
    if start is not None:
        st = _to_date(start) if not isinstance(start, (list, tuple)) or len(start) == 1 else None
        if st is None:
            raise ValueError("asset_config: start = %s ist kein Datum (erwartet Date oder \"JJJJ-MM-TT\")."
                             % r_deparse(start))
        start = st
    if trading == "signal" and (signal_buy is None or signal_sell is None):
        raise ValueError("asset_config: bei trading = \"signal\" müssen signal_buy und signal_sell angegeben werden "
                         "(Namen der Signalspalten in data).")
    if wrapper is not None:   # Fonds-Wrapper (Etappe 6.5c): keine Signale auf den Anteilswert (E5)
        if not _is_wrapper(wrapper):
            raise ValueError("asset_config: wrapper muss NULL oder ein Objekt aus wrapper_config() sein, nicht %s."
                             % _cls_all(wrapper))
        if trading == "signal":
            raise ValueError(_AC_MSG_WRAPPER_SIGNAL)
    if tax_regime is None:
        tax_regime = {"etf": "investment_fund",
                      "etn": "private_sale" if deliverable else "capital_gains",
                      "etc": "private_sale" if deliverable else "capital_gains",
                      "certificate": "capital_gains"}[asset_class]
    elif tax_regime not in _VALID_REGIMES:
        raise ValueError("asset_config: tax_regime = %s ist ungültig; erlaubt sind %s (oder NULL: aus asset_class "
                         "abgeleitet)." % (r_deparse(tax_regime), ", ".join(_VALID_REGIMES)))
    cfg = AssetConfig()
    for k, v in (("asset_class", asset_class), ("trading", trading), ("share", share),
                 ("spread", spread), ("partial_exemption", partial_exemption), ("deliverable", deliverable),
                 ("start", start), ("tax_regime", tax_regime), ("signal_buy", signal_buy),
                 ("signal_sell", signal_sell)):
        cfg[k] = v
    if wrapper is not None:   # nur mit Wrapper ein Feld (sonst Objekt wie bisher)
        cfg["wrapper"] = wrapper
    return cfg


def _call_asset_config(m: Mapping[str, Any]) -> AssetConfig:
    """``do.call(asset_config, <Liste>)`` (unbekannte Felder sind ein Fehler wie in R)."""
    unknown = [k for k in m if k not in _FIELDS]
    if unknown:
        raise ValueError("unused argument%s (%s)" % ("s" if len(unknown) > 1 else "",
                                                     ", ".join("%s = %s" % (k, r_deparse(m[k])) for k in unknown)))
    return asset_config(**{k: v for k, v in m.items()})


class Strategy(RList):
    """Geordnete Sammlung benannter :class:`AssetConfig`-Objekte (R-Klasse ``strategy``)."""

    r_class = ("strategy", "list")

    def format(self) -> str:
        lines = ["Anlagestrategie (%d %s)" % (len(self), "Asset" if len(self) == 1 else "Assets"),
                 "================================", ""]
        for name, asset in self.items():
            lines.append("%s:" % name)
            w = asset.get("wrapper")
            lines.append(r_sprintf("  Klasse: %s | Anteil: %.0f%% | Steuer: %s%s", asset["asset_class"],
                                   asset["share"] * 100, asset["tax_regime"],
                                   (" | Wrapper: %s" % ", ".join(w["strategy"].keys())) if _is_wrapper(w) else ""))
        return "\n".join(lines)

    def print(self) -> "Strategy":
        print(self.format())
        return self

    def summary_text(self) -> str:
        """Text von ``summary.strategy``."""
        out = ["Strategie-Übersicht: %d %s" % (len(self), "Asset" if len(self) == 1 else "Assets"), ""]
        total_share = r_sum([a["share"] for a in self.values()])
        out.append(r_sprintf("Gesamtgewicht: %.1f%%", total_share * 100))
        if abs(total_share - 1) > 0.001:
            out.append("  (Hinweis: Summe ist nicht 100%)")
        out.append("")
        out.append("Nach Steuerregime:")
        regimes = [a["tax_regime"] for a in self.values()]
        for r in dict.fromkeys(regimes):
            n = sum(1 for x in regimes if x == r)
            out.append("  %s: %d %s" % (r, n, "Asset" if n == 1 else "Assets"))
        return "\n".join(out)

    def summary(self) -> "Strategy":
        """``summary.strategy``: druckt die Übersicht und gibt die Strategie zurück."""
        print(self.summary_text())
        return self


def create_strategy(*args: Any, assets: Mapping[str, Any] | None = None, **named: Any) -> Strategy:
    """Strategie aus benannten Asset-Konfigurationen erstellen (R: ``create_strategy()``).

    Beispiel::

        create_strategy(WORLD=asset_config("etf", share=0.7, partial_exemption=30),
                        BONDS=asset_config("etf", share=0.3))

    Alternativ ein ``dict`` über ``assets=``. Einfache ``dict``-Angaben werden mit
    :func:`asset_config` geprüft; die Gewichte werden nicht normiert.
    """
    n_dots = len(args) + len(named)
    if assets is not None and n_dots > 0:
        raise ValueError("create_strategy: Assets entweder über ... oder über assets angeben, nicht beides.")
    dots: list = [(None, a) for a in args] + list(named.items())
    if assets is not None:
        if not isinstance(assets, Mapping):
            raise ValueError("create_strategy: assets muss eine benannte Liste sein (Name = Kursspalte in data), nicht %s."
                             % ("eine unbenannte Liste" if isinstance(assets, (list, tuple)) else type(assets).__name__))
        dots = list(assets.items())
    if not dots:
        raise ValueError("create_strategy: mindestens eine Asset-Konfiguration angeben, z. B. create_strategy(ETF = "
                         "asset_config(\"etf\")).")
    if any(k is None or str(k) == "" for k, _ in dots):
        raise ValueError("create_strategy: alle Assets müssen benannt sein (Name = Kursspalte in data), z. B. "
                         "create_strategy(ETF = asset_config(\"etf\")).")
    out = Strategy()
    for name, cfg in dots:
        name = str(name)
        if isinstance(cfg, AssetConfig):
            out[name] = cfg
        elif isinstance(cfg, Mapping):
            out[name] = _call_asset_config(cfg)
        else:
            raise ValueError("create_strategy: Asset '%s' muss ein asset_config()-Objekt oder eine Liste sein, nicht %s."
                             % (name, _r_class(cfg)))
    return out


def _r_class(x: Any) -> str:
    if x is None:
        return "NULL"
    if isinstance(x, bool):
        return "logical"
    if isinstance(x, (int, float)):
        return "numeric"
    if isinstance(x, str):
        return "character"
    if isinstance(x, RList) and x.r_class:
        return x.r_class[0]
    if isinstance(x, Mapping):
        return "list"
    return type(x).__name__


def strategy_validate(strategy: Strategy, *, data: Any = None) -> bool:
    """Strategie (und optional die Spalten von ``data``) prüfen; ``True`` oder Fehler."""
    if not isinstance(strategy, Strategy):
        raise ValueError("strategy_validate: strategy muss ein Objekt der Klasse \"strategy\" sein (aus create_strategy()), "
                         "nicht %s." % _r_class(strategy))
    for name, a in strategy.items():
        if not isinstance(a, AssetConfig):
            raise ValueError("strategy_validate: Asset '%s' ist kein asset_config()-Objekt (Klasse %s)."
                             % (name, _r_class(a)))
    if data is not None:
        cols = [str(c) for c in (data.columns if hasattr(data, "columns") else data.keys())]
        # Fonds-Wrapper: der Asset-Name ist keine Kursspalte, geprüft werden die Spalten der inneren Strategie
        coll = [w for w in _strategy_wrappers(strategy) if w in cols]
        if coll:
            raise ValueError("strategy_validate: Asset '%s' ist ein Fonds-Wrapper (asset_config(wrapper = )); data darf "
                             "keine Spalte gleichen Namens enthalten (der Anteilswert wird aus den inneren Spalten "
                             "gerechnet)." % coll[0])
        missing = [n for n in _strategy_columns(strategy) if n not in cols]
        if missing:
            raise ValueError("strategy_validate: Kursspalte(n) %s fehlen in data (je Asset eine Spalte gleichen Namens; "
                             "vorhanden: %s)." % (", ".join("'%s'" % m for m in missing), ", ".join(cols)))
        for name, a in strategy.items():
            if _is_wrapper(a.get("wrapper")):   # innere Signale
                strategy_validate(a["wrapper"]["strategy"], data=data)
                continue
            if a["trading"] == "signal":
                if a["signal_buy"] not in cols:
                    raise ValueError("strategy_validate: signal_buy-Spalte '%s' fehlt in data (Asset '%s')."
                                     % (a["signal_buy"], name))
                if a["signal_sell"] not in cols:
                    raise ValueError("strategy_validate: signal_sell-Spalte '%s' fehlt in data (Asset '%s')."
                                     % (a["signal_sell"], name))
    return True


def strategy_add_asset(strategy: Strategy, name: str, asset: AssetConfig) -> Strategy:
    """Asset hinzufügen bzw. ersetzen (gibt eine neue Strategie zurück)."""
    if not isinstance(strategy, Strategy):
        raise ValueError("strategy_add_asset: strategy muss ein Objekt der Klasse \"strategy\" sein (aus create_strategy()), nicht %s."
                         % _r_class(strategy))
    if not isinstance(asset, AssetConfig):
        raise ValueError("strategy_add_asset: asset muss ein asset_config()-Objekt sein, nicht %s." % _r_class(asset))
    out = Strategy(strategy)
    out[name] = asset
    return out


def strategy_update_asset(strategy: Strategy, name: str, **updates: Any) -> Strategy:
    """Felder eines Assets ändern und mit :func:`asset_config` neu prüfen.

    Ändert sich ``asset_class`` oder ``deliverable`` ohne Angabe von ``tax_regime``, wird ein
    bisher automatisch abgeleitetes Steuerregime neu abgeleitet (explizite Werte bleiben).
    """
    if not isinstance(strategy, Strategy):
        raise ValueError("strategy_update_asset: strategy muss ein Objekt der Klasse \"strategy\" sein (aus create_strategy()), "
                         "nicht %s." % _r_class(strategy))
    if name not in strategy:
        raise ValueError("strategy_update_asset: Asset '%s' ist nicht in der Strategie (vorhanden: %s)."
                         % (name, ", ".join(strategy.keys())))
    asset = dict(strategy[name])
    if any(k in updates for k in ("asset_class", "deliverable")) and "tax_regime" not in updates:
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                tmp = dict(asset)
                tmp["tax_regime"] = None
                derived = _call_asset_config(tmp)["tax_regime"]
        except Exception:  # noqa: BLE001
            derived = None
        if derived == asset.get("tax_regime"):
            asset["tax_regime"] = None
    for param, value in updates.items():
        if param not in asset and param != "wrapper":   # wrapper: Feld nur bei Wrapper-Assets vorhanden
            warnings.warn("strategy_update_asset: unbekannter Parameter '%s' wird ignoriert (möglich: %s)."
                          % (param, ", ".join(asset.keys())), stacklevel=2)
            continue
        asset[param] = value
    out = Strategy(strategy)
    out[name] = _call_asset_config(asset)
    return out


def strategy_remove_asset(strategy: Strategy, name: str) -> Strategy:
    """Asset entfernen (Warnung, wenn die Strategie danach leer ist)."""
    if not isinstance(strategy, Strategy):
        raise ValueError("strategy_remove_asset: strategy muss ein Objekt der Klasse \"strategy\" sein (aus create_strategy()), "
                         "nicht %s." % _r_class(strategy))
    if name not in strategy:
        raise ValueError("strategy_remove_asset: Asset '%s' ist nicht in der Strategie (vorhanden: %s)."
                         % (name, ", ".join(strategy.keys())))
    out = Strategy(strategy)
    del out[name]
    if not out:
        warnings.warn("strategy_remove_asset: Nach dem Entfernen von '%s' enthält die Strategie keine Assets mehr." % name,
                      stacklevel=2)
    return out

