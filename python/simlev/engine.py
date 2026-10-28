"""Backtest-Engine (Port von ``simulation()`` aus SimLev 0.5.0): Einstieg ``simulation()``.

Die Struktur folgt den Phasen des R-Pakets (``simulation.R``, ``sim_base.R``, ``sim_validate.R``,
``sim_prepare.R``, ``sim_actions.R``, ``sim_loop.R``, ``sim_evaluate.R``) und der Julia-Engine
(``engine.jl``, ``sim_phases.jl``, ``sim_loop.jl``, ``sim_evaluate.jl``), damit die
Implementierungen Zeile für Zeile vergleichbar bleiben und bitgleich rechnen:

1. ``_sim_check_inputs``   Eingabeprüfung, Steuer- und Gebühreneinstellungen
2. ``_sim_prepare_data``   Kalenderraster, LOCF; ``_sim_build_state`` (``sim_mem``);
   ``_sim_build_calendar`` (Termine und Flags); ``_sim_init_weights``; ``_sim_build_schedule``
3. ``_Actions``            Zahlungs- und Abrechnungshelfer
4. ``_sim_run_days``       Tagesschleife mit den Tagesschritten ``_sim_day_*``
5. ``_sim_close_years``    Abschluss des letzten Jahres
6. ``_sim_returns``, ``_sim_risk_stats``, ``_sim_undefined_metrics``, ``_sim_result``

Module: ``engine.py`` (dieser Einstieg), ``_sim_base.py`` (Hilfen, Handels- und Steuerfunktionen,
Kennzahlen), ``_sim_phases.py`` (Phasen 1 und 2), ``_sim_loop.py`` (Phasen 3 bis 5),
``_sim_evaluate.py`` (Phase 6). Die öffentlichen Helfer (``calculate_skewness`` …) und die von
anderen Modulen genutzten internen Namen (``_as_date``, ``_r_class_name``) bietet dieses Modul
weiter an.

Der Simulationszustand ``sim`` ist ein ``dict`` mit den Teilen ``assets``, ``status``,
``market``, ``trades``, ``report`` und ``totals`` wie ``sim_mem`` in R. Tagesindizes
(``time``) sind wie in R 1-basiert.
"""
from __future__ import annotations

from typing import Any, Mapping, Sequence

from . import _sim_base as _base
from ._sim_base import (
    _Default,
    _FEE,
    _num_vec,
    _unwrap,
    _apply_spread,
    calculate_dates_flags,
    calculate_kurtosis,
    calculate_partials,
    calculate_skewness,
    xirr_rate,
)
from ._sim_phases import (
    _sim_build_calendar,
    _sim_build_schedule,
    _sim_build_state,
    _sim_check_inputs,
    _sim_init_weights,
    _sim_prepare_data,
)
from ._sim_loop import _Actions, _sim_close_years, _sim_run_days
from . import _sim_blocks as _blocks
from ._sim_evaluate import (
    _sim_compact_trades,
    _sim_result,
    _sim_returns,
    _sim_risk_stats,
    _sim_undefined_metrics,
)

__all__ = ["simulation", "_simulation_flat", "calculate_skewness", "calculate_kurtosis", "calculate_partials",
           "calculate_dates_flags", "xirr_rate", "_apply_spread"]

# Wiederausgabe interner Namen, die andere Module über ``engine`` nutzen
# (``config.py``: ``_as_date``, ``dashboard.py``: ``_r_class_name``)
_as_date = _base._as_date
_r_class_name = _base._r_class_name
# deep_analysis.py holt ``_xirr_rate`` über ``_ext("engine", "_xirr_rate")``
_xirr_rate = _base._xirr_rate


# ═══════════════════════════════════════════════════════════════════════════
# Hauptfunktion
# ═══════════════════════════════════════════════════════════════════════════

class _CostsDefault:
    """Standard ``costs = sim_costs()`` (wird im Rumpf angelegt; Text wie in R)."""

    __slots__ = ()

    def __repr__(self) -> str:
        return "sim_costs()"


_SIM_COSTS = _CostsDefault()


def simulation(
    data: Any,
    strategy: Mapping[str, Mapping[str, Any]],
    *,
    start_value: float = 10000,
    costs: Any = _SIM_COSTS,
    dca: Any = None,
    rebalance: Any = None,
    splits: Any = None,
    tax: Any = None,
    funds: Any = None,
    risk_free: float | str | None = 0,
    fractions: bool = True,
    liquidate: bool = False,
    details: bool = False,
):
    """Portfolio-Simulation (Backtest) mit Bausteinen (Etappe 6.3, Anhang C).

    Bitgleiche Portierung von ``simulation()`` aus dem R-Paket SimLev 0.5.0. Die Einstellungen kommen als
    Bausteine: ``costs = sim_costs()`` (Standard), ``dca = dca_plan()``, ``rebalance = rebalance_plan()``,
    ``splits = split_rule()``, ``tax = tax_profile()`` (mit ``income = income_rate()`` oder
    ``income_tariff()`` und ``harvest = harvest_rule()``) und ``funds = funds_costs()``; ``None`` heißt aus.
    ``funds`` zusammen mit ``tax`` ist der Fondsmodus mit eigenen Steuern (Satz bzw. Kirchensteuer aus
    ``tax_profile()``). Die Bausteine werden mit ``_sim_from_blocks`` in die
    internen Werte übersetzt; die Engine (``_simulation_flat``) rechnet unverändert.

    Rückgabe: :class:`simlev.SimLevResult` mit den Elementen wie in R.
    """
    if isinstance(costs, _CostsDefault):
        costs = _blocks.sim_costs()
    flat = _blocks._sim_from_blocks(costs, dca, rebalance, splits, tax, funds)
    return _simulation_flat(data, strategy, start_value=start_value, risk_free=risk_free, fractions=fractions,
                            liquidate=liquidate, details=details, _blocks=True, **flat)


def _simulation_flat(
    data: Any,
    strategy: Mapping[str, Mapping[str, Any]],
    start_value: float = 10000,
    spread: float | None = None,
    details: bool = False,
    liquidate: bool = False,
    # DCA
    dca_mode: bool = False,
    dca_value: float | None = None,
    dca_span: float | None = None,
    dca_days: Any = None,
    dca_unit: str | Sequence[str] = ("month", "quarter", "year"),
    dca_anchor: str | Sequence[str] = ("start", "end"),
    dca_start: Any = None,
    dca_skip: bool = False,
    # Rebalancing
    balance_mode: bool = False,
    balance_span: float | None = None,
    balance_days: Any = None,
    balance_unit: str | Sequence[str] = ("month", "quarter", "year"),
    balance_anchor: str | Sequence[str] = ("start", "end"),
    balance_start: Any = None,
    balance_skip: bool = False,
    balance_dca: bool = False,
    balance_thresh: float | None = None,
    balance_thresh_type: str | Sequence[str] = ("absolute", "relative"),
    # Steuern
    tax_mode: str | Sequence[str] = ("none", "person", "funds"),
    tax_rate: float = _Default(26.375),
    marginal_tax_rate: float | None = _Default(None),
    use_guenstigerpruefung: bool = False,
    private_sale_threshold: float = 1000,
    sparer_pauschbetrag: float = 1000,
    use_sparer_pauschbetrag: bool = True,
    include_soli_on_income_tax: bool = _Default(False),
    soli_rate_income_tax: float = _Default(5.5),
    # Basiszins
    base_rate: float | None = None,
    base_rate_flex: bool = False,
    base_rate_data: str | None = None,
    # Fonds
    funds_fee: float = _Default(0.95),
    bonus_fee: float = _Default(5),
    # Sonstiges
    fractions: bool = True,
    risk_free: float | str | None = 0,
    split_mode: bool = False,
    split_thresh: Sequence[float] | None = None,
    # Ereignisbasiertes Rebalancing
    event_col: str | None = None,
    event_mode: str | Sequence[str] = _Default(("additional", "replace")),
    event_weight: Mapping[str, str] | None = None,
    # Deutsche Praxis
    church_tax: float | None = 0,
    order_fee: Any = None,
    dca_fee: Any = None,
    harvest_mode: bool = False,
    harvest_day: str = "12-15",
    harvest_loss_pot: bool = True,
    # Einkommensteuertarif
    taxable_income: Any = None,
    tax_tariff: Any = None,
    _blocks: bool = False,
):
    """Engine von ``simulation()`` mit den internen (flachen) Argumenten (R: ``.simulation_flat``).

    ``simulation()`` ruft sie mit den aus den Bausteinen übersetzten Werten auf (``_blocks=True``). Die
    Aufrufer mit ``sim_args`` gehen seit Etappe 6.4 über ``simulation()`` (``_sim_blocks._sim_args_set``).

    Bitgleiche Portierung der Rechnung von ``simulation()`` aus dem R-Paket SimLev 0.5.0. Alle Raten und
    Schwellen werden **in Prozent** angegeben (``tax_rate=26.375``, ``balance_thresh=5``,
    ``risk_free=2`` …). Argumente und Voreinstellungen entsprechen 1:1 denen in R; ``None``
    steht für ``NULL``, ``True``/``False`` für ``TRUE``/``FALSE``, Folgen für ``c(...)``,
    ``dict`` für benannte Listen/Vektoren und ``pandas.DataFrame`` für ``data.frame``.

    Neue Argumente in 0.5.0: ``order_fee``, ``dca_fee`` (Zahl in EUR oder
    ``dict(fixed=, percent=, min=, max=)``), ``church_tax`` (Prozent), ``harvest_mode``,
    ``harvest_day`` (``"MM-TT"``), ``harvest_loss_pot``, ``taxable_income`` (Zahl, ``dict``
    Jahr -> zvE, ``pandas.Series`` oder ``DataFrame(year, taxable_income)``) und
    ``tax_tariff`` (``None``, Dateipfad oder :func:`simlev.tax_tariff`-Objekt).

    Hinweise (R: ``message()``) gehen nach ``sys.stderr``, Warnungen sind
    ``warnings.warn``-Warnungen, Fehler ``ValueError`` (Texte wie in R). Die
    ``details``-Ausgabe geht nach ``sys.stdout``.

    Rückgabe: :class:`simlev.SimLevResult` mit den Elementen wie in R (``dates``,
    ``filled``, ``worth``, ``twr_index``, ``invested``, ``external_flows``, ``cagr``,
    ``ttwror``, ``drawdowns``, ``statistics``, ``buys``, ``sells``, ``report``,
    ``tax_report``, ``undefined_metrics``, ``open_lots``, ggf. ``fees_paid`` und
    ``harvest_days``).
    """
    given = {k: False for k in ("tax_rate", "marginal_tax_rate", "include_soli_on_income_tax", "soli_rate_income_tax",
                                "funds_fee", "bonus_fee", "event_mode")} if _blocks else {
        "tax_rate": not isinstance(tax_rate, _Default),
        "marginal_tax_rate": not isinstance(marginal_tax_rate, _Default),
        "include_soli_on_income_tax": not isinstance(include_soli_on_income_tax, _Default),
        "soli_rate_income_tax": not isinstance(soli_rate_income_tax, _Default),
        "funds_fee": not isinstance(funds_fee, _Default),
        "bonus_fee": not isinstance(bonus_fee, _Default),
        "event_mode": not isinstance(event_mode, _Default),
    }
    tax_rate, marginal_tax_rate = _unwrap(tax_rate), _unwrap(marginal_tax_rate)
    include_soli_on_income_tax, soli_rate_income_tax = _unwrap(include_soli_on_income_tax), _unwrap(soli_rate_income_tax)
    funds_fee, bonus_fee, event_mode = _unwrap(funds_fee), _unwrap(bonus_fee), _unwrap(event_mode)
    try:
        cfg = _sim_check_inputs(
            data=data, strategy=strategy, start_value=start_value, spread=spread, details=details,
            dca_mode=dca_mode, dca_value=dca_value, dca_span=dca_span, dca_days=dca_days, balance_mode=balance_mode,
            balance_days=balance_days, balance_thresh=balance_thresh, balance_thresh_type=balance_thresh_type,
            tax_mode=tax_mode, tax_rate=tax_rate, marginal_tax_rate=marginal_tax_rate,
            use_guenstigerpruefung=use_guenstigerpruefung, private_sale_threshold=private_sale_threshold,
            sparer_pauschbetrag=sparer_pauschbetrag, use_sparer_pauschbetrag=use_sparer_pauschbetrag,
            include_soli_on_income_tax=include_soli_on_income_tax, soli_rate_income_tax=soli_rate_income_tax,
            base_rate=base_rate, funds_fee=funds_fee, bonus_fee=bonus_fee, fractions=fractions, risk_free=risk_free,
            split_mode=split_mode, split_thresh=split_thresh, event_col=event_col, church_tax=church_tax,
            order_fee=order_fee, dca_fee=dca_fee, harvest_mode=harvest_mode, harvest_day=harvest_day,
            taxable_income=taxable_income, tariff=tax_tariff, given=given, blocks=_blocks)
        if split_thresh is not None:
            split_thresh = _num_vec(split_thresh)
        prep = _sim_prepare_data(cfg["data"], cfg["pre_filled"], base_rate_flex, base_rate_data, blocks=_blocks)
        sim = _sim_build_state(prep["data"], cfg["strategy"], cfg["start_value"], prep["start_date"],
                               prep["stopp_date"], cfg["sparer_pauschbetrag"], cfg["use_sparer_pauschbetrag"],
                               cfg["base_rate"], base_rate_flex, base_rate_data, blocks=_blocks)
        cal = _sim_build_calendar(prep["data"], sim, cfg["strategy"], prep["start_date"], prep["stopp_date"],
                                  liquidate, cfg["dca_mode"], dca_span, dca_unit, cfg["dca_days"], cfg["dca_value"],
                                  dca_anchor, dca_start, dca_skip, cfg["balance_mode"], balance_span, balance_unit,
                                  cfg["balance_days"], balance_anchor, balance_start, balance_skip, cfg["event_col"],
                                  event_mode, event_weight, cfg["split_mode"], split_thresh, blocks=_blocks)
        fr = cal["data"]
        fl = cal["flags"]
        if cfg["event_col"] is not None:
            event_weight = cal["event_weight"]
        init = _sim_init_weights(sim, fl["flag_assets"], fl["flag_date"], cfg["start_value"])
        sim = init["sim"]
        fl["initial_assets"] = init["initial_assets"]
        fl = _sim_build_schedule(sim, fl, prep["stopp_date"], cfg["tax_mode"], cfg["harvest_mode"], harvest_day)
        act = _Actions(cfg, fl, bool(details))
        sim = _sim_run_days(sim, fl, cfg, act, fr, cfg["strategy"], liquidate, event_weight, split_thresh,
                            funds_fee, bonus_fee, balance_dca, harvest_loss_pot, bool(details))
        sim = _sim_close_years(sim, fl, cfg, act, prep["stopp_date"], bool(details))
        trades = _sim_compact_trades(sim, fl["flag_assets"])
        ret = _sim_returns(sim, fl["flag_date"], fl["flag_assets"], fl["flag_filled"], prep["start_date"],
                           prep["stopp_date"], cfg["start_value"], act.tax_unpaid_total)
        risk = _sim_risk_stats(ret, cfg["risk_free"], fr)
        undef = _sim_undefined_metrics(ret, risk, trades, fl["flag_assets"])
        return _sim_result(sim, trades, fl, cfg, ret, risk, undef)
    finally:
        _FEE.current = None


# R rechnet mit NA (signalisierendes NaN) ohne Gleitkomma-Warnungen; numpy meldete sonst
# "invalid value encountered" bei jeder Rechnung mit NA.
from ._r.base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__)
