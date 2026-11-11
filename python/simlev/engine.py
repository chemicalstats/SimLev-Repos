"""Backtest-Engine (R: ``simulation()`` aus SimLev 0.5.0): Einstieg ``simulation()``.

Die Struktur folgt den Phasen des R-Pakets (``simulation.R``, ``sim_base.R``, ``sim_validate.R``,
``sim_prepare.R``, ``sim_engine.R``, ``sim_evaluate.R``) und der Julia-Engine (``engine.jl``,
``sim_phases.jl``, ``sim_engine.jl``, ``sim_evaluate.jl``), damit die Implementierungen Zeile für Zeile
vergleichbar bleiben und bitgleich rechnen:

1. ``_sim_check_inputs``   Eingabeprüfung, Steuer- und Gebühreneinstellungen
2. ``_sim_prepare_data``   Kalenderraster, LOCF; ``_sim_build_state`` (``sim_mem``);
   ``_sim_build_calendar`` (Angaben der Termine, Ereignis-Spalte, Prüfungen)
3.-5. ``_sim_engine_run``  Termine, Tages-Flags und Startgewichte (``core/prepare_core_impl.h``),
   Tagesschleife und Abschluss des letzten Jahres im gemeinsamen C++-Kern (``core/engine_core_impl.h``)
6. ``_sim_evaluate`` (Kern ``core/evaluate_core_impl.h``), ``_sim_result``

Module: ``engine.py`` (dieser Einstieg), ``_sim_base.py`` (Hilfen und Kennzahlen), ``_sim_phases.py``
(Phasen 1 und 2), ``_sim_engine.py`` (Phasen 3 bis 5), ``_sim_evaluate.py`` (Phase 6). Die öffentlichen Helfer (``calculate_skewness`` …) und die von
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
    _num_vec,
    calculate_dates_flags,
    calculate_kurtosis,
    calculate_skewness,
    xirr_rate,
)
from ._sim_phases import (
    _sim_build_calendar,
    _sim_build_state,
    _sim_check_inputs,
    _sim_prepare_data,
)
from ._sim_engine import _sim_engine_run
from . import _sim_blocks as _blocks
from ._pruefen import chk_scalar
from ._sim_evaluate import (
    _sim_compact_trades,
    _sim_evaluate,
    _sim_result,
)

__all__ = ["simulation", "_simulation_flat", "calculate_skewness", "calculate_kurtosis", "calculate_dates_flags",
           "xirr_rate"]

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
    risk_free: float | str | None = 0,
    fractions: bool = True,
    liquidate: bool = False,
    details: bool = False,
):
    """Portfolio-Simulation (Backtest) mit Bausteinen (Anhang C).

    Backtestet eine oder mehrere Asset-Strategien auf historischen oder synthetischen Preisreihen. Die Engine
    verarbeitet jede Preisreihe so, wie sie übergeben wird – Hebelung, Dividenden und Finanzierungskosten sind
    Bestandteil der Inputreihe und werden nicht intern berechnet.

    Die Simulation unterstützt Buy-and-Hold (``"bnh"``), signalgesteuerte Strategien (``"signal"``),
    DCA-Sparpläne, periodisches Rebalancing, ereignisbasiertes Rebalancing sowie die Deutsche
    Investmentbesteuerung (§§ 18–20 InvStG, § 23 EStG).

    Args:
        data: ``data.frame`` (``pandas.DataFrame``; nur Tabellen, ein ``dict`` von Spalten vorher mit
            ``pandas.DataFrame()`` umwandeln) mit täglichen Marktdaten. Pflichtfelder: ``date`` (Klasse ``Date``,
            aufsteigend) und je eine Kursspalte pro Asset (Niveaus, keine Renditen; Name muss mit dem Asset-Namen in ``strategy``
            übereinstimmen; für Fonds-Wrapper die Spalten der inneren Strategie, siehe Abschnitt „Fonds-Wrapper“).
            Optionale Spalten: Basiszins in Prozent (Spaltenname in ``tax_profile(base_rate = )``), Signalspalten
            (für ``trading = "signal"``; ``True``/``False`` oder ``0``/``1``, NA erlaubt, andere Zahlen sind ein
            Fehler), Risk-Free-Reihe in Prozent p.a. (Name in ``risk_free``), logische Trigger- und numerische Gewichtsspalten für ``rebalance_plan(event_col, event_weight)``.
            Fehlende Kalendertage werden automatisch per LOCF aufgefüllt (logische Spalten mit ``False``);
            aufgefüllte Tage werden in ``filled`` markiert und aus Risikometriken ausgeschlossen. Trägt ``data``
            das Attribut ``filled`` aus ``series_align``, gelten Tage, an denen keines der Strategie-Assets einen
            echten Kurs hat, ebenso als aufgefüllt (kein Handel, nicht in den Risikometriken). Passt die
            Zeilenzahl des Attributs nicht zu ``data`` (z. B. nach einer Zeilenauswahl der
            ``series_align()``-Ausgabe), wird es mit Warnung ignoriert; den Zeitraum daher mit ``series_align(...,
            start =, end =)`` wählen.
            Seit 1.6.4 darf ``date`` keine Kategorie sein (vorher still in Text umgewandelt).

            Eingabeprüfung: ``date`` als Text im Format ``"JJJJ-MM-TT"`` (oder Faktor) wird mit Hinweis in
            ``Date`` umgewandelt; unsortierte Zeilen werden mit Hinweis aufsteigend sortiert; doppelte Daten und
            doppelte Spaltennamen führen zu einem Fehler. Kurse müssen positiv sein (``<= 0`` oder unendlich:
            Fehler) und seit 1.6.4 zwischen 1e-100 und 1e100 liegen (sonst Fehler). Einzelne fehlende Kurse (``NA``) werden mit Hinweis per LOCF gefüllt; sind in einer Zeile
            alle Kurse ``NA``, gilt der Tag als aufgefüllt. Hat ein Asset erst ab einem späteren Tag Kurse
            (führende ``NA``, etwa aus ``series_align(range = "all")``), wird es wie mit ``start`` = erster
            Kurstag behandelt. Mindestens ein Asset muss am ersten Tag handelbar sein. Andere DataFrame-Klassen
            (z. B. tibble) werden in einen ``data.frame`` umgewandelt.
        strategy: Benannte Liste von Asset-Konfigurationen, idealerweise erzeugt mit ``create_strategy`` und
            ``asset_config``. Direkte Listen-Übergabe ist ebenfalls möglich (Backward-Kompatibilität). Die
            Zielgewichte ``share`` (Anteile, 0--1) müssen sich auf exakt 1 summieren (Toleranz 1e-6); sie werden
            nicht normiert, sonst bricht die Funktion mit Fehler ab. Asset-Namen müssen eindeutig sein. Assets mit
            späterem ``start`` erhalten ab dem Start ihr volles Zielgewicht (das Startkapital verteilt sich bis
            dahin auf die übrigen Assets); am Starttag wird immer auf die Zielgewichte umgeschichtet (Verkauf der
            übrigen Assets, Kauf des neuen; mit Steuern, Spreads und Gebühren wie bei jedem Rebalancing), auch
            ohne ``rebalance``; ein zusätzlicher Handelsblock (z. B. Kauf aus einer Sparrate vor der Umschichtung)
            läuft an diesem Tag nicht. Mit ``rebalance = rebalance_plan()`` gilt danach der normale Rhythmus.
            Liegt ``start`` nach dem letzten Datentag, bricht die Funktion mit Fehler ab (das Asset wäre nie
            handelbar).
        start_value: Numerisch. Anfangskapital in EUR. Standard: ``10000``.
        costs: Kosten: ``sim_costs(order_fee, dca_fee)`` (Ordergebühren, Gebühren der Sparplankäufe) oder ``None``
            (keine Kosten). Standard: ``sim_costs()`` (keine Gebühren). Der Bid-Ask-Spread gilt je Asset
            (``spread`` in ``asset_config``).
        dca: Sparplan: ``dca_plan(value, span, days, unit, anchor, start, skip, fill_deficits)`` oder ``None``
            (Standard: kein Sparplan).
        rebalance: Rebalancing: ``rebalance_plan(span, days, unit, anchor, start, skip, thresh, thresh_type,
            event_col, event_mode, event_weight)`` oder ``None`` (Standard: kein Rebalancing). Mit Rebalancing
            wird am ersten Simulationstag (und am Starttag später startender Assets) nur über das Rebalancing
            gekauft (Erstkauf nach Zielgewichten); ein zusätzlicher Handelsblock mit anschließender Umschichtung
            von Resten entfällt.
        splits: Automatische Splits: ``split_rule(thresh = [untere, obere])`` oder ``None`` (Standard: keine
            Splits).
        tax: Persönliche Besteuerung (§§ 18--20 InvStG, § 23 EStG) mit FIFO-Buchführung: ``tax_profile(rate,
            church_tax, sparer_pauschbetrag, private_sale_threshold, base_rate, guenstigerpruefung, income,
            harvest)`` oder ``None`` (Standard: keine Steuern).
        risk_free: Numerisch oder Character. Annualisierte risikolose Rendite **in Prozent** (z. B. ``3`` = 3 %
            p.a.) oder Name einer Spalte in ``data`` mit einer täglichen, annualisierten Zeitreihe in Prozent (z.
            B. SOFR als ``5.31``; nur Zahlenspalten, Text-, logische und Kategorie-Spalten sind ein Fehler).
            ``None`` und ``0`` sind äquivalent. Jede Tagesrate wird in ihr Tagesäquivalent
            umgerechnet und von der jeweiligen Tagesrendite abgezogen; Sharpe und Sortino werden auf den
            Überschussrenditen berechnet. LOCF-aufgefüllte Tage werden konsistent ausgeschlossen. Standard: ``0``.
            Zahlen über 0 und unter 0,05 (vermutlich Anteil, z. B. ``0.02`` für 2 %) werden mit Warnung als
            Prozent gelesen; kleine echte Prozentsätze wie ``0.25`` (Geldmarkt 2016--2019) warnen nicht. Für eine
            Spalte gilt dieselbe Schwelle für den Median ihrer Werte (ohne ``NA`` und 0).
        fractions: Logisch. Bruchteile von Anteilen erlauben? Bei ``False`` werden bei einem Split entstehende
            Bruchteile einmalig zum Kurs des Split-Tages verkauft (Spitzenausgleich, ohne Spread und Gebühr;
            steuerlich ein Verkauf nach FIFO). Zwangsverkäufe für eine Steuerzahlung (Vorabpauschale, § 23)
            verkaufen die aufgerundete Stückzahl und bei verbleibendem Fehlbetrag ein weiteres Stück; ein
            Überschuss bleibt als Cash. Reicht ein Asset nicht, zahlen die übrigen Assets; ein dann noch offener
            Betrag bleibt als negativer Geldbestand (mit Warnung) stehen und wird nie still gestrichen. Standard:
            ``True``. Nur ``True`` oder ``False`` (sonst Fehler).
        liquidate: Logisch. Portfolio am letzten Simulationstag vollständig liquidieren (inkl. Steuerabrechnung)?
            Übersteigt die Ordergebühr den Erlös einer Position, bleibt sie mit Warnung stehen. Am Liquidationstag
            finden kein Rebalancing und keine Sparrate statt, auch wenn ein Termin von einem aufgefüllten Tag
            dorthin verschoben wurde. Standard: ``False``.
        details: Logisch. Detaillierte Steuer-/Trade-Ausgaben auf der Konsole? Standard: ``False``.

    Returns:
        Liste der Klasse ``"SimLevResult"`` mit:

        - ``dates``: Date-Vektor. Tägliche Simulationsdaten (Kalendertage inkl. aufgefüllter Tage).
        - ``filled``: Logischer Vektor (gleiche Länge wie ``dates``). ``True`` = dieser Tag wurde per LOCF
          aufgefüllt (kein echter Handelstag). Aufgefüllte Tage werden aus allen renditebasierten Risikometriken
          ausgeschlossen.
        - ``worth``: Numerischer Vektor. Tägliche Portfoliowerte (Depotwert einschließlich Einzahlungen) in EUR.
        - ``twr_index``: Numerischer Vektor. Zeitgewichteter Wertindex (Start = 1), verkettet aus den um
          Einzahlungen bereinigten Tagesrenditen wie für ``ttwror``: an Tagen ohne Einzahlung (W_t - W_t-1) /
          W_t-1. An Tagen mit Einzahlung F_t (angelegt zum Schlusskurs) wird zum Zeitpunkt der Zahlung bewertet
          (echte zeitgewichtete Rendite): V^pre_t = Vortagesbestand zum heutigen Schlusskurs plus Vortages-Cash,
          Tagesfaktor (V^pre_t / W_t-1) · W_t / (V^pre_t + F_t). Ohne Kosten entspricht die Tagesrendite damit der
          Kursrendite; Kaufkosten der Einzahlung (Spread, Gebühr) und alles, was am selben Tag danach geschieht,
          belasten das Kapital nach der Zahlung.
        - ``invested``: Numerischer Vektor. ``start_value`` plus kumulierte Einzahlungen (Sparplan, einschließlich
          einer Rate am Starttag) je Tag in EUR, brutto (vor Kaufkosten).
        - ``external_flows``: Logisch. ``True``, wenn nach dem Starttag Einzahlungen erfolgten (Sparplan, ``dca =
          dca_plan()``); eine Einzahlung am Starttag steckt im Startwert.
        - ``cagr``: Numerisch. Compound Annual Growth Rate (annualisierte Gesamtrendite) als Anteil (``0.05`` = 5
          % p.a.; Jahre = Kalendertage / 365,25). Mit Einzahlungen (``external_flows = True``) die geldgewichtete
          Jahresrendite: interner Zinsfuß (XIRR) aus Startbetrag, datierten Einzahlungen und Endwert, S (1+r)^T +
          Σ_i F_i (1+r)^T - t_i = W_n mit Startbetrag S = ``start_value`` plus Rate am Starttag (brutto, wie die
          übrigen Einzahlungen) und t_i = Kalendertage seit Start / 365,25 (Nullstelle nach Brent; auch bei
          Beinahe-Totalverlust mit Rendite nahe -100 %); ohne Einzahlungen nach dem Starttag (W_n / W_1)^1/T - 1.
          Gibt es keine Lösung, ist ``cagr = NA`` (mit Warnung). Ist der Endwert negativ (nicht gedeckte
          Steuerschuld, Verlust über 100 %), sind ``cagr`` und ``ttwror`` nicht definiert: ``NA`` mit Warnung
          (nicht -1, das den Verlust untertreiben würde); der Endwert bleibt unverändert (nicht auf 0 begrenzt).
          Bei einem Einzeltag (Laufzeit 0 Jahre) sind ``cagr`` und ``ttwror`` ebenfalls ``NA`` (mit Warnung). Die
          Ursache steht in ``undefined_metrics``. Die zeitgewichtete Rendite steht in ``ttwror``.
        - ``ttwror``: Numerisch. True Time-Weighted Rate of Return (um DCA-Zuflüsse bereinigt, annualisiert) als
          Anteil; verkettete Tagesrenditen wie ``twr_index`` (Bewertung zum Zahlungszeitpunkt). Ohne Zuflüsse
          unverändert (W_t - W_t-1) / W_t-1.
        - ``drawdowns``: Numerischer Vektor. Tägliche Drawdowns vom jeweiligen Höchststand als positiver Anteil
          (``0.2`` = 20 % unter dem Höchststand; 0 = neuer Höchststand). Ohne Einzahlungen auf dem Depotwert, mit
          Einzahlungen auf ``twr_index`` (zeitgewichtet), damit Einzahlungen keinen Drawdown verdecken; das gilt
          ebenso für ``max_drawdown``, ``average_drawdown``, ``ulcer_index``, ``longest_drawdown`` und
          ``avg_recovery_time``. Fällt der Index durch eine Tagesrendite von -100 % oder weniger auf 0 oder
          darunter (Kaufkosten einer großen Einzahlung auf ein fast leeres Depot), werden die Drawdowns auf 1
          begrenzt (mit Warnung). Ebenso werden Drawdowns allgemein auf [0, 1] begrenzt, wenn der Depotwert
          negativ wird (Steuerschuld; mit Warnung).
        - ``statistics``: Benannte Liste mit Risiko- und Renditekennzahlen. Grundlage sind die Tagesrenditen der
          echten Handelstage (ohne LOCF-Tage); bei Zuflüssen (DCA) die um Zuflüsse bereinigten Renditen (``mean``,
          ``sd``, ``sharpe``, ``sortino``, ``omega``, ``gain_to_pain`` usw.). Annualisiert wird mit der
          tatsächlichen Zahl der Beobachtungen je Jahr. Mit Einzahlungen verwenden ``calmar``, ``serenity`` und
          ``martin_ratio`` statt ``cagr`` die zeitgewichtete Jahresrendite ``ttwror``, damit Zähler und
          (zeitgewichteter) Drawdown-Nenner zusammenpassen. Renditen, Drawdowns und Ulcer Index als Anteil:

        - ``mean``: Mittlere tägliche Rendite (Handelstage). - ``sd``: Tägliche Portfoliovolatilität
          (Handelstage). - ``cv``: Variationskoeffizient ``|sd / mean|``. - ``risk_free``: Effektiv genutzte
          mittlere Risk-Free-Rate (annualisiert, in Prozent). - ``skewness``: Schiefe der Tagesrenditen. -
          ``kurtosis``: Überschuss-Kurtosis der Tagesrenditen. - ``lpm``, ``hpm``: Unteres bzw. oberes partielles
          Moment 1. Ordnung der Tagesrenditen (Schwelle 0). - ``sharpe``: Annualisierte Sharpe Ratio auf
          Überschussrenditen. - ``sortino``: Annualisierte Sortino Ratio auf Überschussrenditen e_i: bar e · P /
          (D √(P)) mit P Beobachtungen je Jahr und Downside-Abweichung über alle Beobachtungen D = √(mean(min(e_i,
          0)^2)) (Sortino/Price, wie ``result_analysis``); ``NA`` ohne negative Überschussrendite. - ``calmar``:
          Calmar Ratio (CAGR / Max Drawdown; mit Einzahlungen TTWROR / Max Drawdown). - ``omega``: Omega Ratio
          (Schwelle 0). - ``gain_to_pain``: Summe der Renditen / Summe der Verluste (Betrag). - ``serenity``: CAGR
          / (Ulcer Index * Max Drawdown); mit Einzahlungen TTWROR im Zähler. - ``martin_ratio``: CAGR / Ulcer
          Index; mit Einzahlungen TTWROR / Ulcer Index. - ``max_drawdown``: Maximaler Drawdown (positiver Anteil).
          - ``average_drawdown``: Mittlerer Drawdown über alle Tage unter dem Höchststand. - ``ulcer_index``:
          Ulcer Index (Wurzel des mittleren quadrierten Drawdowns). - ``longest_drawdown``: Längste Phase unter
          dem Höchststand in Kalendertagen. - ``avg_recovery_time``: Mittlere Erholungsdauer in Kalendertagen
          (``NA``, wenn keine abgeschlossene Erholung).
        - ``report``: Benannte Liste je Asset mit täglichen Vektoren: ``worth`` (Kurswert in EUR), ``money`` (Cash
          in EUR), ``flows`` (DCA-Zufluss des Tages in EUR), ``total`` (``worth + money``), ``share`` (Ist-Gewicht
          als Anteil).
        - ``tax_report``: Steuerzusammenfassung (Beträge in EUR): ``total_taxes_paid`` (gezahlte Steuern abzüglich
          Erstattungen; ein Fließkommarest unter 1e-9 EUR nach einer Erstattung im Jahresabschluss wird 0),
          ``loss_carryforward_capital`` (§ 20 EStG-Verlustvortrag), ``loss_carryforward_private`` (§ 23
          EStG-Verlustvortrag), ``sparer_pauschbetrag_annual`` (jährlicher Pauschbetrag),
          ``sparer_pauschbetrag_used`` (insgesamt genutzt), ``sparer_pauschbetrag_tax_saved`` (genutzter
          Pauschbetrag mal effektivem Steuersatz), ``open_tax_debt`` (am Ende offene, nicht gedeckte Steuerschuld:
          Summe der negativen Geldbestände am letzten Tag, wenn eine Steuerzahlung nicht gedeckt werden konnte;
          sonst 0). Nur mit ``tax = tax_profile()``: ``next_year``, der Steuerzustand des Jahres nach dem letzten
          Datentag (für eine Fortsetzung, z. B. in ``withdrawal_simulation``): genau das, was die Engine diesem
          Jahr schon zugerechnet hat; endet die Simulation am 31.12., ist das die dort festgesetzte Vorabpauschale
          (Zufluss im Folgejahr, verrechnet mit Verlusttopf und Sparer-Pauschbetrag dieses Jahres; ein
          Zwangsverkauf für ihre Steuer am letzten Tag gehört zum Vorjahr), sonst nichts (Verbrauch 0). Liste mit
          ``year``, ``sparer_pauschbetrag_used`` und ``sparer_pauschbetrag_remaining`` (EUR; mit
          ``sparer_pauschbetrag = 0`` 0), ``loss_carryforward_capital`` (§ 20-Verlusttopf danach),
          ``loss_carryforward_private`` (§ 23-Verlustvortrag), ``capital_income_taxed`` (im Jahr mit
          Abgeltungsteuer belastete Bemessungsgrundlage), ``loss_capital_added``, ``loss_capital_used``,
          ``loss_capital_start`` (im Jahr entstandene bzw. genutzte § 20-Verluste, Topf zu Jahresbeginn; Grundlage
          der Jahresend-Erstattung), ``private_sale_net`` (§ 23-Jahressaldo, hier 0); mit ``taxable_income``
          zusätzlich ``church_tax_settlement`` (Kirchensteuer-Bescheid des letzten Jahres, am letzten Tag gezahlt
          (> 0) bzw. erstattet (< 0); Sonderausgabe dieses Jahres) und ``tariff_assessed`` (logisch: das Jahr
          wurde wegen einer nachlaufenden Vorabpauschale bereits veranlagt). Nur mit ``taxable_income``:
          ``tariff_years``, ein ``data.frame`` mit einer Zeile je abgeschlossenem Kalenderjahr (EUR): ``year``,
          ``taxable_income`` (vorgegebenes zvE z_t), ``church_tax_paid_deductible`` (im Jahr gezahlte, abziehbare
          Kirchensteuer aus der Simulation: Nachzahlung aus dem Kirchensteuer-Bescheid des Vorjahres und, wenn die
          Günstigerprüfung günstiger ist, die im Jahr auf K einbehaltene Kirchensteuer), ``church_tax_refunded``
          (im Jahr erstattete Kirchensteuer aus dem Bescheid des Vorjahres), ``church_tax_net_deduction`` (Saldo;
          negativ = Hinzurechnung), ``taxable_income_net`` (z_t minus Saldo, Basis der Veranlagung),
          ``deduction_effect`` (Änderung der tariflichen Belastung F des übrigen Einkommens durch den Saldo:
          negativ = Ersparnis), ``gain_p23`` (steuerpflichtiger § 23-Gewinn G23 nach Freigrenze und
          Verlustvortrag), ``income_tax_p23``, ``soli_p23``, ``church_tax_p23``, ``tax_p23`` (§ 23-Anteil: ESt-,
          Soli-, KiSt-Zuwachs und Summe), ``capital_income`` (K), ``abgeltung_burden`` (per Saldo auf K erhobene
          Abgeltungsteuer mit Soli/KiSt), ``church_tax_withheld_k`` (darin enthaltene Kirchensteuer),
          ``tariff_income_tax_k``, ``tariff_soli_k``, ``tariff_church_tax_k``, ``tariff_burden`` (Tarifbelastung
          von K bei Günstigerprüfung; ``NA`` ohne ``guenstigerpruefung``), ``burden_without_gp``,
          ``burden_with_gp`` (Gesamtbelastung durch die Simulation ohne bzw. mit Günstigerprüfung, siehe Abschnitt
          „Einkommensteuertarif“; ``NA``, wenn keine Prüfung), ``guenstiger`` (logisch: Tarif für K günstiger),
          ``settlement`` (Abrechnung des Jahres am Abrechnungstag: positiv Nachzahlung, negativ Erstattung),
          ``refund`` (Erstattung = max(0, -``settlement``)), ``church_tax_settlement_next_year`` (Saldo des
          Kirchensteuer-Bescheids: positiv Zahlung, negativ Erstattung im Folgejahr). Die Spalten
          ``church_tax_deduction`` und ``church_tax_deductible_next_year`` der vorigen Fassung sind durch
          ``church_tax_net_deduction`` bzw. ``church_tax_settlement_next_year`` ersetzt; ``refund`` enthält jetzt
          die saldierte Erstattung des Jahres (Günstigerprüfung, § 23-Nachzahlung und Sonderausgaben-Wirkung
          zusammen).
        - ``undefined_metrics``: ``data.frame(metric, reason, detail)`` mit einer Zeile je Kennzahl, die ``NA``
          ist (``cagr``, ``ttwror``, Felder von ``statistics`` sowie ``buys`` und ``sells``, je eine Zeile für den
          ganzen Vektor); 0 Zeilen mit denselben Spalten, wenn alles definiert ist. Abgrenzung: Die übrigen
          Ergebniselemente werden nicht ``NA``: ``worth``, ``invested``, ``report`` (``share`` = 0, wenn der
          Depotwert nicht positiv ist), ``twr_index`` (nicht endliche Tagesfaktoren zählen als 1) und
          ``drawdowns`` (0 ohne positiven Höchststand) sind immer endlich. In ``tax_report["tariff_years"]`` sind
          die Spalten ``tariff_*`` ohne ``guenstigerpruefung`` bewusst ``NA`` (nicht gerechnet); sie stehen nicht
          in ``undefined_metrics``. ``detail`` ist ein deutscher Klartext mit Beträgen, z. B. „Endwert -800.00 EUR
          negativ: offene Steuerschuld 800.00 EUR“. ``reason``:

        - ``negative_end_value``: Endwert negativ (nicht gedeckte Steuerschuld): ``cagr``, ``ttwror``. -
          ``no_irr_solution``: mit Einzahlungen kein interner Zinsfuß (z. B. Einzahlung am letzten Tag größer als
          der Endwert): ``cagr``. - ``too_short``: Einzeltag (Laufzeit 0 Jahre: ``cagr``, ``ttwror``, ``buys``,
          ``sells``, ``avg_recovery_time`` und alle Renditekennzahlen) bzw. zu wenige Tagesrenditen (Schiefe ab 3,
          Kurtosis ab 4, Sharpe ab 2). - ``zero_start_value``: Depotwert am Starttag nicht positiv (``cagr``;
          wegen ``start_value > 0`` praktisch nicht erreichbar). - ``nonpositive_twr_index``: zeitgewichteter
          Wertindex fällt auf 0 oder darunter (Tagesrendite unter -100 %): ``ttwror``. - ``zero_volatility``:
          Standardabweichung der Tagesrenditen 0: ``skewness``, ``kurtosis``, ``sharpe``. - ``zero_mean_return``:
          mittlere Tagesrendite 0: ``cv``. - ``no_negative_returns``: keine negativen (Überschuss-)Renditen:
          ``sortino``, ``omega``, ``gain_to_pain``. - ``no_drawdown``: kein Drawdown: ``calmar``, ``serenity``,
          ``martin_ratio``. Ist die Jahresrendite (``cagr``, mit Einzahlungen ``ttwror``) nicht definiert, erben
          diese drei deren Ursache. - ``no_recovery``: keine abgeschlossene Erholung: ``avg_recovery_time``. -
          ``not_finite``: Auffangcode für sonstige nicht endliche Werte.

        ``print()`` und ``summary()`` zeigen eine nicht definierte ``cagr`` bzw. ``ttwror`` (und in ``print()``
        Schiefe und Kurtosis) als „nicht definiert (<detail>)“ statt ``NA``; Kennzahlen, die schon bisher als „–“
        erscheinen, bleiben so.
        - ``open_lots``: Nur mit ``tax = tax_profile()`` gefüllt (sonst ``None``): benannte Liste je Asset mit
          ``lots`` (``data.frame`` der am letzten Tag gehaltenen Lots in FIFO-Reihenfolge: ``date`` Kaufdatum,
          ``units`` verbleibende Stück, ``price`` Anschaffungskurs je Stück wie in der FIFO-Gewinnrechnung, d. h.
          Briefkurs einschließlich anteiliger Ordergebühr, nach Splits umgerechnet, ``vp`` bereits versteuerte,
          bei Verkauf nach § 19 InvStG anzurechnende Vorabpauschale dieser Stück in EUR), ``regime``
          (``"investment_fund"``, ``"capital_gains"`` oder ``"private_sale"``), ``partial_exemption``
          (Teilfreistellung in Prozent), ``cash`` (Geldbestand des Assets am Ende in EUR), ``spread`` (voller
          Bid-Ask-Spread in Prozent wie in ``asset_config``) und ``order_fee`` (das Argument ``order_fee`` wie
          übergeben, ``None`` = keine Ordergebühr), damit Verkaufskosten in späteren Rechnungen übernommen werden
          können. Ein Verkauf zum Verkaufskurs P (Kurs mal 1 - halber Spread, abzüglich Ordergebühr je Stück)
          verbraucht die Lots in Zeilenreihenfolge; aus Lot i werden s_i ≤ units_i Stück verkauft. Die Engine
          rechnet: Gewinn G = Σ_i s_i (P - price_i); Fonds (``investment_fund``): steuerpflichtig (G - Σ_i vp_i
          s_i / units_i) (1 - asset\\_bonus / 100), danach Verlusttopf, Sparer-Pauschbetrag und Abgeltungsteuer (§
          20 EStG); ``capital_gains``: steuerpflichtig G (ohne Teilfreistellung und Vorabpauschale), weiter wie
          bei Fonds; ``private_sale`` (§ 23 EStG): je Lot s_i (P - price_i), in den Jahressaldo (Freigrenze,
          Verlustvortrag) nur, wenn der Verkaufstag nicht nach demselben Kalendertag des Folgejahres liegt (Kauf
          am 29.02.: 28.02.), sonst steuerfrei (Gewinne und Verluste).
        - ``buys``: Benannter Vektor. Mittlere Anzahl Käufe je Jahr und Asset (Einzeltag, Laufzeit 0 Jahre:
          ``NA``, siehe ``undefined_metrics``).
        - ``sells``: Benannter Vektor. Mittlere Anzahl Verkäufe je Jahr und Asset (Einzeltag: ``NA``).
        - ``fees_paid``: Nur wenn ``order_fee`` oder ``dca_fee`` eine Gebühr ungleich 0 festlegt: Summe der
          gezahlten Ordergebühren in EUR.
        - ``harvest_days``: Nur mit ``tax_profile(harvest = harvest_rule())``: Date-Vektor der Termine der
          Gewinnrealisierung.
        - ``wrappers``: Nur mit ``details = True`` und Fonds-Wrapper-Assets (``asset_config(wrapper = )``):
          benannte Liste je Wrapper-Asset mit dem ``SimLevWrapperNav`` aus ``wrapper_nav`` (Anteilswert, Brutto,
          Gebühren, High-Water-Mark, inneres Ergebnis als Attribut ``inner``). Ohne ``details`` gibt es das Feld
          nicht.

    Terminverschiebung an aufgefüllten Tagen:
        Geplante Ereignisse (DCA, periodisches Rebalancing, Splits, Liquidation, Asset-Starts), die auf einen per
        LOCF aufgefüllten Tag (Wochenende/Feiertag) fallen, werden automatisch auf den **nächsten echten
        Handelstag** verschoben. Würde die Verschiebung den Monat verlassen (Monatsende), wird das Ereignis
        stattdessen auf den **vorherigen** echten Handelstag **vorgezogen**. Die **Festsetzung** der
        Vorabpauschale bleibt kalendarisch am 31.12. (maßgeblich ist der letzte Rücknahmepreis des Jahres, per
        LOCF): je am 31.12. gehaltenem Lot VP = Bestand x max(0, min(P_Anfang x 0,7 x Basiszins, P_Ende -
        P_Anfang)) x f mit P_Anfang = erster im Kalenderjahr festgesetzter Kurs (Kurs des ersten nicht
        aufgefüllten Tages des Jahres bzw. der Simulation; § 18 Abs. 1 Satz 3 InvStG: ein aufgefüllter 1.1. trägt
        nur den Vorjahresschluss und zählt nicht), P_Ende = letzter Kurs des Jahres und f = 1 bei Erwerb vor dem
        Jahr, sonst (13 - Erwerbsmonat)/12 (§ 18 Abs. 1-2 InvStG; Ausschüttungen gibt es im Modell nicht). Die
        Lot-Werte mindern später den Veräußerungsgewinn (§ 19 InvStG). **Zufluss und Steuer** folgen gemäß § 18
        Abs. 3 InvStG am ersten Handelstag des Folgejahres, nach dem Jahresabschluss und vor allen Trades dieses
        Tages, zu dessen Kursen (Cash-Abzug bzw. Zwangsverkauf): Teilfreistellung, Verlusttopf,
        Sparer-Pauschbetrag und Günstigerprüfung des **Zuflussjahres**; die Vorabpauschale ist Kapitalertrag
        dieses Jahres. Hat das Folgejahr in den Daten keinen Handelstag (alle Tage aufgefüllt), wird am 1.1. des
        Folgejahres mit dessen Töpfen abgerechnet. Zwangsverkäufe schätzen die Steuer wie der Verkauf selbst (§
        19-Anrechnung der Lot-Vorabpauschale, Teilfreistellung, Verlusttopf, freier Sparer-Pauschbetrag,
        effektiver Satz); ebenso Umschichtungen (Rebalancing, Asset-Aktivierung), so dass kein Rückkauf desselben
        Assets am selben Tag nötig ist. Am selben Tag wird danach die § 23-Steuer des Vorjahres gezahlt. Enthält
        die Simulation keinen weiteren Tag, wird so gerechnet, als begänne das Folgejahr (Jahresabschluss,
        Pauschbetrag voll), und die Steuer am letzten Simulationstag belastet; ein Zwangsverkauf dafür findet an
        diesem Tag statt und gehört mit seinem Gewinn (Sparer-Pauschbetrag, Verlusttopf) zum Jahr des letzten
        Datentags, die Vorabpauschale selbst zum Folgejahr (eine Differenz zur endgültigen Steuer, z. B. wenn der
        Verkaufsgewinn den Verlustvortrag mindert, wird ausgeglichen). Fließen mehrere Vorabpauschalen am selben
        Tag zu, werden sie gemeinsam mit Verlusttopf und Sparer-Pauschbetrag verrechnet; Steuer und Pauschbetrag
        werden anteilig nach der Vorabpauschale nach Teilfreistellung auf die Assets verteilt (unabhängig von
        ihrer Reihenfolge in ``strategy``). Eine § 20-Erstattung aus diesem letzten Jahresabschluss (Verlust nach
        versteuerten Gewinnen im selben Jahr) wird dem Cash gutgeschrieben und ist im Endwert enthalten, auch ohne
        offene Vorabpauschale oder § 23-Steuer. Die Vorabpauschale wird wie in der Bankpraxis mit dem allgemeinen
        § 20-Verlusttopf verrechnet (vor dem Sparer-Pauschbetrag); die T-2-Jahresenderstattung erfasst damit auch
        VP-Steuer bei später im Zuflussjahr realisierten Verlusten.

    Einkommensteuertarif (taxable_income):
        Mit ``tax_profile(income = income_tariff(taxable_income))`` (zvE z_t des Jahres t ohne die Erträge der
        Simulation) rechnet die Engine mit dem Tarif der Datei ``tax_tariff`` (``tax_tariff``). Rechtsgrundlagen
        (Fassung ab VZ 2026, mitgelieferte Datei):

        - § 32a Abs. 1 EStG: zvE auf volle Euro abrunden; bis 12 348 EUR: 0; 12 349 bis 17 799: (914,51 y + 1400)
          y; 17 800 bis 69 878: (173,10 z + 2397) z + 1034,87; 69 879 bis 277 825: 0,42 x - 11 135,63; ab 277 826:
          0,45 x - 19 470,38 mit y = (x - 12 348) / 10 000, z = (x - 17 799) / 10 000; Steuerbetrag auf volle Euro
          abrunden (T(x)). Nur Einzelveranlagung (Grundtarif), kein Splitting.
        - §§ 3 Abs. 3, 4 SolZG: Soli 5,5 % der Einkommensteuer, nur wenn diese 20 350 EUR übersteigt (Freigrenze,
          Einzelveranlagung), höchstens 11,9 % des Mehrbetrags (Milderungszone); Bruchteile eines Cents bleiben
          außer Ansatz (S(E)). Auf die Abgeltungsteuer weiterhin 5,5 % (in ``tax_profile(rate)``).
        - Veranlagung je Jahr: tarifliche Belastung F(x) = T(x) + S(T(x)) + k T(x) (k = ``church_tax`` / 100,
          Kirchensteuer nicht gerundet). Die Simulation trägt den Unterschied zur Belastung des vorgegebenen zvE
          ohne Simulation, F(...) - F(z_t); damit gehört auch die Wirkung ihrer Kirchensteuer-Sonderausgaben auf
          das übrige Einkommen zur Simulation.
        - § 23 EStG: steuerpflichtiger Gewinn G23 (nach Freigrenze und Verlustvortrag) erhöht das zvE: ohne
          Günstigerprüfung X_0 = F(z_t - N_t + G23) - F(z_t) + A_t mit A_t = Abgeltungsbelastung auf K (siehe
          unten) und N_t = Saldo der im Jahr gezahlten/erstatteten Kirchensteuer aus dem Vorjahresbescheid.
        - § 32d Abs. 6 Satz 1 EStG (``tax_profile(guenstigerpruefung = True)``): unterjährig wird die
          Abgeltungsteuer wie bei einer Bank einbehalten (auch die Steuerschätzung beim Umschichten rechnet mit
          ``tax_profile(rate)``). Im Jahresabschluss ist K die Bemessungsgrundlage, auf die im Jahr per Saldo
          Abgeltungsteuer erhoben wurde (Kapitaleinkünfte nach § 20 nach Teilfreistellung, Vorabpauschale des
          Zuflussjahres, Verlustverrechnung und Sparer-Pauschbetrag), A_t = K mal ``tax_profile(rate)`` die darauf
          einbehaltene Abgeltungsteuer mit Soli und Kirchensteuer, darin die Kirchensteuer C_t = K x 0,25 / (1 +
          0,25 k) x k. Verglichen wird die Gesamtbelastung: mit Günstigerprüfung X_1 = F(z_t - N_t - C_t + G23 +
          K) - F(z_t) (die einbehaltene Kirchensteuer C_t ist dann im Jahr der Zahlung Sonderausgabe), ohne X_0
          wie oben. Günstiger, wenn X_1 < X_0. Abrechnung am Abrechnungstag des Folgejahres (wie die übrigen
          Jahresabschluss-Buchungen; ohne weiteren Tag am letzten Simulationstag): ``settlement`` = X - A_t mit X
          = X_1 bzw. X_0; positiv als Nachzahlung aus dem Depot (wie die § 23-Steuer), negativ als Erstattung in
          den Geldbestand; in ``total_taxes_paid`` saldiert. K ≤ 0: keine Prüfung (Verluste aus Kapitalvermögen
          sind nicht mit anderen Einkünften verrechenbar).
        - Kirchensteuer als Sonderausgabe (§ 10 Abs. 1 Nr. 4, § 11 EStG: Jahr der Zahlung): Der
          Kirchensteuer-Bescheid eines Jahres (Kirchensteuer auf den ESt-Unterschied abzüglich der angerechneten
          C_t, wenn die Günstigerprüfung günstiger ist) wird am Abrechnungstag im Folgejahr gezahlt (Sonderausgabe
          des Folgejahres) bzw. erstattet. Erstattungen werden mit den im Erstattungsjahr gezahlten Kirchensteuern
          aus der Simulation verrechnet (einschließlich C dieses Jahres bei Günstigerprüfung); ein Überhang wird
          dem Einkommen hinzugerechnet (§ 10 Abs. 4b Satz 2 und 3 EStG): N_t = gezahlt minus erstattet. Die
          Kirchensteuer als Zuschlag zur Kapitalertragsteuer ist nach § 10 Abs. 1 Nr. 4, 2. Halbsatz nicht
          abziehbar; dass der Abzug erhalten bleibt, wenn die Kapitalerträge per Günstigerprüfung tariflich
          besteuert werden, beruht auf der Darstellung der Rechtslage in der Fachliteratur (Haufe), nicht auf
          einem Urteil. Die Kirchensteuer auf die § 23-ESt eines Jahres wird erst mit ihrer Zahlung im Folgejahr
          abgezogen; im selben Jahr wirkt nur die Kirchensteuer aus dem Vorjahresbescheid und (bei
          Günstigerprüfung) C_t.

        Vereinfachungen: Die Datei gilt für alle Simulationsjahre (aktuelle Rechtslage auf alle Jahre projiziert,
        wie im übrigen Paket). Die Kirchensteuer wird nicht gerundet (Landesrecht unterschiedlich);
        Kinderfreibeträge für ihre Bemessungsgrundlage (§ 51a EStG) bildet das Modell nicht ab. Je Jahr gibt es
        einen Kirchensteuer-Bescheid; Nachzahlung und Erstattung daraus werden saldiert. Vorauszahlungen und ein
        Verlustrücktrag (§ 10d EStG) kommen im Modell nicht vor. Das Jahr nach dem letzten Simulationsjahr wird
        nicht veranlagt: Zahlungen und Erstattungen aus dem letzten Bescheid (am letzten Simulationstag) wirken
        sich nicht mehr als Sonderausgabe aus. Ausnahme: Fließt nach dem letzten Jahresabschluss noch eine
        Vorabpauschale zu (Simulation endet am 31.12.), wird dieses Folgejahr mit Günstigerprüfung veranlagt, wenn
        ``taxable_income`` dafür einen Wert hat (eine Zahl für alle Jahre oder das Jahr angegeben). Ein
        Grenzsteuersatz (``income_rate()``) schließt diesen Weg aus. Ohne ``taxable_income`` bleibt alles
        unverändert. Die Jahreswerte stehen in ``tax_report["tariff_years"]``; ``details = True`` gibt die
        Tarifrechnung je Jahr aus.

    print und summary:
        ``summary()`` liefert unter anderem ``total_return_twr`` (zeitgewichtete Gesamtrendite: mit Einzahlungen
        letzter Wert von ``twr_index`` minus 1, sonst Endwert / Depotwert am Starttag - 1), ``return_on_invested``
        = (Endwert - Eingezahlt) / Eingezahlt mit Eingezahlt = letzter Wert von ``invested`` (brutto) und
        ``total_return`` als gleichwertigen Alias für ``total_return_twr`` (ältere Skripte). Mit Einzahlungen
        zeigt die Ausgabe beide Werte („Gesamtrendite (zeitgewichtet)“ und „Gewinn je eingezahltem EUR“ mit
        Endwert und Eingezahlt); ohne Einzahlungen ist die Ausgabe unverändert. Nicht definierte Kennzahlen
        erscheinen als „nicht definiert (Ursache)“ (siehe ``undefined_metrics``); eine offene Steuerschuld zeigt
        ``print()`` im Steuerteil.

    Signalbewusstes Rebalancing (Cash-Reserve-Modell):
        Die Rebalancing-Prozedur prüft die Signallogik eigenständig; der reguläre Signal-Trade-Block läuft an
        Rebalancing-Tagen nicht (keine Doppelorders). Signal-aktive und signal-inaktive Assets werden nach ihrem
        **Zielgewicht gleichbehandelt**: Ein signalbedingt nicht investiertes (aber aktiviertes) Signal-Asset hält
        sein Zielgewicht als **eigene Cash-Position** (jedes Asset besitzt ein eigenes Cash-Konto). Da
        Ist-Gewichte total-basiert sind (Kurswert + Cash), zählt die Reserve als Positionsgewicht; das Rebalancing
        gleicht sie über reine **Cash-Transfers** mit dem Pool aus — der Pool wird also genau um den Betrag der
        inaktiven Assets reduziert, bevor der Rest investiert wird. Für Signal-Assets gilt am Rebalancing-Tag:

        - Position vorhanden + Verkaufssignal: vollständiger Signal-Exit; der Erlös wird zur Cash-Reserve des
          Assets.
        - Keine Position + Kaufsignal: Signal-Entry aus der eigenen Cash-Reserve; danach normale Teilnahme am
          Gewichts-Rebalancing.
        - Keine Position + kein Kaufsignal: die Cash-Reserve wird auf das Zielgewicht getrimmt (Auffüllen aus dem
          Pool bzw. Abschöpfen in den Pool), es findet aber **kein Aktienkauf** statt.
        - Andernfalls nimmt das Asset normal am Gewichts-Rebalancing teil.

        Verbleibendes Cash der übrigen Assets (z. B. DCA-Zuflüsse am selben Tag) wird noch am Rebalancing-Tag
        reinvestiert; die Cash-Reserven signalbedingt wartender Signal-Assets bleiben davon unberührt.

        Außerhalb von Rebalancing-Tagen gilt (unabhängig von ``rebalance``): Ein Signal-Asset mit offener Position
        legt neues Geld (Sparraten, Restcash, Umverteilungen, Erstattungen) sofort an wie Buy-and-Hold, außer am
        Tag eines Verkaufssignals; das Signal steuert nur Ein- und Ausstieg. Ohne Bestand wartet das Geld als Cash
        auf das Kaufsignal.

    Fonds-Wrapper:
        Ein Asset mit ``asset_config(wrapper = wrapper_config(...))`` ist ein Zertifikat bzw. Fonds über eine
        innere Strategie. Vor der Engine rechnet ``simulation()`` je Wrapper-Asset den Anteilswert mit
        ``wrapper_nav`` aus den inneren Spalten von ``data`` und hängt ihn als Kursspalte mit dem Asset-Namen an
        (vor dem Beginn und an Tagen ohne inneren Kurs ``NA``). Danach ist das Asset ein gewöhnliches Asset ohne
        ``wrapper``: Spread, Order- und Sparplangebühren, Steuern (nach ``asset_class`` bzw. ``tax_regime``:
        Zertifikat = Kapitalforderung, ``tax_regime = "investment_fund"`` mit Teilfreistellung und
        Vorabpauschale), Kirchensteuer, Pauschbetrag, Verlusttöpfe, ``harvest`` und ``open_lots`` gelten wie für
        jedes Einzelpapier.

        - Der Asset-Name ist keine Kursspalte; eine Spalte gleichen Namens in ``data`` ist ein Fehler. Gebraucht
          werden die Kursspalten (und Signal- bzw. Ereignisspalten) der inneren Strategie.
        - ``splits`` gelten für die inneren Spalten; der Anteilswert selbst splittet nicht.
        - Beginnen die inneren Kurse nach dem ersten Tag von ``data``, beginnt der Anteilswert später; das Asset
          wird dann wie jedes später startende Asset behandelt (Hinweis „hat erst ab ... Kurse“). Ist der Wrapper
          das einzige Asset, ist das der Fehler „In der ersten Zeile von 'data' fehlen alle Kurse“.
        - Meldungen der inneren Rechnung erscheinen als „Hinweis: Wrapper '<Name>' (innere Rechnung): ...“,
          Warnungen und Fehler als „simulation: Wrapper '<Name>' (innere Rechnung): ...“.
        - Wrapper-Assets handeln nur mit ``trading = "bnh"`` (Signale gehen in der inneren Strategie).
        - Aufrufer mit vielen Läufen (``bootstrap_study``, ``param_search``, ``sensitivity_grid``,
          ``planning_lumpsum_vs_dca`` u. a.) rechnen den Anteilswert je Lauf neu; Bootstrap-Pfade ziehen die
          inneren Spalten.

        Mit ``details = True`` enthält das Ergebnis ``wrappers`` (siehe oben).

    Ereignisbasiertes Rebalancing:
        Zusammenspiel der Argumente von ``rebalance_plan``:

        - ``event_col``: Character oder ``None``. Name einer logischen Spalte in ``data``, die ereignisbasiertes
          Rebalancing auslöst (``True`` = Rebalancing-Tag). Erzeugt mit ``rebalance_trigger``.
        - ``event_mode``: ``"additional"`` (zusätzlich zu periodischem Rebalancing) oder ``"replace"`` (ersetzt
          periodisches Rebalancing).
        - ``event_weight``: Benannter Vektor/Liste oder ``None``: je Asset der Name einer Spalte mit dem
          Zielgewicht an Event-Tagen (siehe ``rebalance_plan``).

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 756
        d = pd.DataFrame({"date": pd.date_range("2020-01-01", periods=n)})
        d["MSCI"] = 100 * np.cumprod(1 + rng.normal(4e-4, 0.012, n))
        d["BOND"] = 50 * np.cumprod(1 + rng.normal(1e-4, 0.004, n))
        st = simlev.create_strategy(MSCI=simlev.asset_config(asset_class="etf", share=0.7, spread=0.1, partial_exemption=30),
                                    BOND=simlev.asset_config(asset_class="etf", share=0.3, spread=0.1))
        res = simlev.simulation(d, st, start_value=10000, rebalance=simlev.rebalance_plan(unit="year"),
                                tax=simlev.tax_profile(rate=26.375), liquidate=True, risk_free=2)
        print(res["cagr"], res["tax_report"]["total_taxes_paid"])
    """
    # seit 1.6.4 Vektoren der Länge 1 wie Einzelwerte (Entscheidung 4; R: c(TRUE) ist TRUE)
    start_value, risk_free, fractions, liquidate, details = (
        chk_scalar(v) for v in (start_value, risk_free, fractions, liquidate, details))
    if isinstance(costs, _CostsDefault):
        costs = _blocks.sim_costs()
    flat = _blocks._sim_from_blocks(costs, dca, rebalance, splits, tax)
    return _simulation_flat(data, strategy, start_value=start_value, risk_free=risk_free, fractions=fractions,
                            liquidate=liquidate, details=details, **flat)


def _simulation_flat(
    data: Any,
    strategy: Mapping[str, Mapping[str, Any]],
    start_value: float = 10000,
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
    tax_mode: str | Sequence[str] = ("none", "person"),
    tax_rate: float = 26.375,
    marginal_tax_rate: float | None = None,
    use_guenstigerpruefung: bool = False,
    private_sale_threshold: float = 1000,
    sparer_pauschbetrag: float = 1000,
    use_sparer_pauschbetrag: bool = True,
    include_soli_on_income_tax: bool = False,
    soli_rate_income_tax: float = 5.5,
    # Basiszins
    base_rate: float | None = None,
    base_rate_flex: bool = False,
    base_rate_data: str | None = None,
    # Sonstiges
    fractions: bool = True,
    risk_free: float | str | None = 0,
    split_mode: bool = False,
    split_thresh: Sequence[float] | None = None,
    # Ereignisbasiertes Rebalancing
    event_col: str | None = None,
    event_mode: str | Sequence[str] = ("additional", "replace"),
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
):
    """Engine von ``simulation()`` mit den internen (flachen) Argumenten (R: ``.simulation_flat``).

    ``simulation()`` ruft sie mit den aus den Bausteinen übersetzten Werten auf (einziger Aufrufer; der flache
    Weg ohne Bausteine mit eigenen Prüfungen ist entfallen). Die Aufrufer mit ``sim_args`` gehen seit 0.9.0
    über ``simulation()`` (``_sim_blocks._sim_args_set``).

    Interne flache Fassung von ``simulation()`` (R: ``.simulation_flat``; die Bausteine von ``simulation()`` werden
    vorher in diese Argumente übersetzt). Alle Raten und Schwellen werden **in Prozent** angegeben (``tax_rate=26.375``, ``balance_thresh=5``,
    ``risk_free=2`` …). Argumente und Voreinstellungen entsprechen 1:1 denen in R; ``None``
    steht für ``NULL``, ``True``/``False`` für ``TRUE``/``FALSE``, Folgen für ``c(...)``,
    ``dict`` für benannte Listen/Vektoren und ``pandas.DataFrame`` für ``data.frame``.

    Dazu gehören ``order_fee``, ``dca_fee`` (Zahl in EUR oder ``dict(fixed=, percent=, min=, max=)``),
    ``church_tax`` (Prozent), ``harvest_mode``, ``harvest_day`` (``"MM-TT"``), ``harvest_loss_pot``,
    ``taxable_income`` (Zahl, ``dict`` Jahr -> zvE, ``pandas.Series`` oder ``DataFrame(year, taxable_income)``) und
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
    cfg = _sim_check_inputs(
        data=data, strategy=strategy, start_value=start_value, details=details,
        dca_mode=dca_mode, dca_value=dca_value, dca_days=dca_days, balance_mode=balance_mode,
        balance_days=balance_days, balance_thresh=balance_thresh, balance_thresh_type=balance_thresh_type,
        tax_mode=tax_mode, tax_rate=tax_rate, marginal_tax_rate=marginal_tax_rate,
        use_guenstigerpruefung=use_guenstigerpruefung, private_sale_threshold=private_sale_threshold,
        sparer_pauschbetrag=sparer_pauschbetrag, use_sparer_pauschbetrag=use_sparer_pauschbetrag,
        include_soli_on_income_tax=include_soli_on_income_tax, soli_rate_income_tax=soli_rate_income_tax,
        base_rate=base_rate, fractions=fractions, risk_free=risk_free,
        split_mode=split_mode, split_thresh=split_thresh, event_col=event_col, church_tax=church_tax,
        order_fee=order_fee, dca_fee=dca_fee, harvest_mode=harvest_mode,
        taxable_income=taxable_income, tariff=tax_tariff, liquidate=liquidate)
    if split_thresh is not None:
        split_thresh = _num_vec(split_thresh)
    prep = _sim_prepare_data(cfg["data"], cfg["pre_filled"], base_rate_flex, base_rate_data)
    sim = _sim_build_state(prep["data"], cfg["strategy"], prep["start_date"],
                           prep["stopp_date"], cfg["sparer_pauschbetrag"], cfg["use_sparer_pauschbetrag"],
                           cfg["base_rate"], base_rate_flex, base_rate_data)
    cal = _sim_build_calendar(prep["data"], sim, cfg["strategy"], prep["start_date"], prep["stopp_date"],
                              cfg["dca_mode"], dca_span, dca_unit, cfg["dca_days"], cfg["dca_value"],
                              dca_anchor, dca_start, dca_skip, cfg["balance_mode"], balance_span, balance_unit,
                              cfg["balance_days"], balance_anchor, balance_start, balance_skip, cfg["event_col"],
                              event_mode, event_weight)
    fr = cal["data"]
    fl = cal["flags"]
    if cfg["event_col"] is not None:
        event_weight = cal["event_weight"]
    # 3.-5. Termine, Flags, Startgewichte, Tagesschleife und Abschluss des letzten Jahres im
    # C++-Kern (_sim_engine.py)
    sim, tax_unpaid = _sim_engine_run(sim, fl, cfg, fr, event_weight, split_thresh, balance_dca, harvest_loss_pot,
                                      liquidate, prep["stopp_date"], bool(details), harvest_day)
    trades = _sim_compact_trades(sim, fl["flag_assets"])
    # 6. Auswertung im C++-Kern (_sim_evaluate.py) und Ergebnisobjekt
    ev = _sim_evaluate(sim, trades, fl, cfg, fr, prep["start_date"], prep["stopp_date"], tax_unpaid)
    return _sim_result(sim, trades, fl, cfg, ev["r"], ev["rs"], ev["um"])


# R rechnet mit NA (signalisierendes NaN) ohne Gleitkomma-Warnungen; numpy meldete sonst
# "invalid value encountered" bei jeder Rechnung mit NA.
from ._r.base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__)
