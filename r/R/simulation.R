# =============================================================================
# SimLev - Paket zur Portfolio-Simulation
# =============================================================================
#
# @author ChemicalStats von der Mauerstrasse
# @version 2.3.0
# @license GPL-3
#
# @description
# Simuliert die Wertentwicklung eines Portfolios nach deutschen Steuerregeln, u. a.:
# - Abgeltungsteuer (pauschale Steuer auf Kapitalertraege, § 20 EStG)
# - Vorabpauschale (jaehrliche Vorabbesteuerung von Fonds, § 18 InvStG)
# - Teilfreistellung (teilweise Steuerfreiheit von Fondsertraegen, § 20 InvStG)
# - § 23 EStG (private Veraeusserungsgeschaefte, lieferbare ETN/ETC)
# - Sparer-Pauschbetrag (Freibetrag, § 20 Abs. 9 EStG)
# - Guenstigerpruefung (§ 32d Abs. 6 EStG) - optional
#
# @section Steuerregime:
# Das Paket unterscheidet drei Steuerregime:
#
# \describe{
#   \item{investment_fund}{
#     ETFs und Investmentfonds nach InvStG.
#     - Teilfreistellung: 30 % bei Aktienfonds, 15 % bei Mischfonds
#       (je Asset als \code{partial_exemption} in Prozent, z. B. 30)
#     - Vorabpauschale: jaehrliche Vorabbesteuerung auf Basis des Basiszinses
#     - Einstandskosten nach FIFO
#   }
#   \item{capital_gains}{
#     Normale Besteuerung von Kapitalertraegen nach § 20 EStG.
#     - Keine Teilfreistellung
#     - Keine Vorabpauschale
#     - Einstandskosten nach FIFO
#     - Verwendet fuer: ETN (nicht lieferbar), Zertifikate
#   }
#   \item{private_sale}{
#     Private Veraeusserungsgeschaefte nach § 23 EStG.
#     - Haltefrist: steuerfrei nach mehr als 1 Jahr
#     - Freigrenze: 1.000 EUR je Jahr (seit 2024)
#     - Es gilt der persoenliche Einkommensteuersatz (nicht die Abgeltungsteuer)
#     - Eigener Verlusttopf (nur mit § 23-Gewinnen verrechenbar)
#     - Verwendet fuer: lieferbare ETN/ETC (physische Lieferung)
#   }
# }
#
# @section Guenstigerpruefung (I3):
# Bei \code{use_guenstigerpruefung = TRUE} wird statt der Abgeltungsteuer (\code{tax_rate},
# Standard 26,375 %, mit Kirchensteuer nach § 32d Abs. 1) der persoenliche Steuersatz angewandt,
# wenn die Belastung einschliesslich Zuschlagsteuern niedriger ist (§ 32d Abs. 6 Satz 1 EStG).
#
# Formel (intern, Saetze nach Division durch 100 als Anteil):
# \code{personal = marginal_tax_rate * (soli_factor + church_tax / 100)} mit soli_factor =
# 1 + soli_rate_income_tax bei \code{include_soli_on_income_tax = TRUE}, sonst 1;
# \code{effective_rate = personal}, wenn \code{personal < tax_rate}, sonst \code{tax_rate}.
#
# @section Tarifweg (taxable_income, tax_tariff):
# Mit \code{taxable_income} (zvE je Kalenderjahr ohne die Ertraege der Simulation) rechnet die Engine
# mit dem Einkommensteuertarif aus einer Datei (tax_tariff(), § 32a Abs. 1 EStG, Soli §§ 3, 4
# SolZG; mitgeliefert ab VZ 2026, Einzelveranlagung). § 23: ESt-Zuwachs T(zvE + G23) - T(zvE),
# Soli-Zuwachs exakt, KiSt church_tax Prozent des ESt-Zuwachses. Guenstigerpruefung: unterjaehrig
# Abgeltungsteuer, im Jahresabschluss Vergleich der Gesamtbelastung mit und ohne Tarif fuer K,
# Abrechnung (Nachzahlung/Erstattung) am Abrechnungstag. Kirchensteuer als Sonderausgabe im
# Zahlungsjahr (§ 10 Abs. 1 Nr. 4, Abs. 4b Satz 2/3, § 11 EStG): Saldo des KiSt-Bescheids des Vorjahres
# (Zahlung abziehbar, Erstattung verrechnet bzw. hinzugerechnet), bei guenstigerer Tarifbesteuerung
# auch die im Jahr auf K einbehaltene KiSt. Hilfsfunktionen: .tariff_base(), .tariff_full(),
# .tariff_diff(), .tariff_close(), .tariff_book().
#
# @section Berechnung der Vorabpauschale (M1, M3, M4, T-1):
# Die Vorabpauschale wird je am 31.12. gehaltenem Lot berechnet als (§ 18 Abs. 1-2 InvStG):
# \deqn{VP = max(0, min(Basisertrag, Wertzuwachs)) x Monatsfaktor}
# mit:
# \itemize{
#   \item Basisertrag = Bestand x Kurs zu Jahresbeginn x Basiszins x 0,7
#   \item Wertzuwachs = Bestand x (Kurs am 31.12. - Kurs zu Jahresbeginn)
# }
# Bezug ist fuer jedes Lot der erste im Jahr festgesetzte Kurs (erster nicht aufgefuellter Tag; auch bei Kauf im laufenden
# Jahr; der Kaufkurs spielt keine Rolle). Monatsfaktor = 1 bei Erwerb vor dem
# Jahr, sonst (13 - Kaufmonat) / 12 (Zwoelftelung nach dem Deckel, T-1).
# Basiszins vom ersten Handelstag des Jahres (§ 18 Abs. 4). Zufluss und Steuer
# am ersten Handelstag des Folgejahres mit dessen Toepfen (§ 18 Abs. 3).
#
# Besonderheiten:
# \itemize{
#   \item M1: Ein negativer Basiszins ergibt VP = 0 (nicht negativ).
#   \item M3: Eigene Funktion .calculate_vorabpauschale_tax(). Die VP wird mit dem
#     allgemeinen § 20-Verlusttopf verrechnet (vor dem Sparer-Pauschbetrag, R-2),
#     erzeugt aber selbst keinen Verlust.
#   \item M4: Nur Lots, die zum Jahresende noch gehalten werden, zaehlen.
# }
#
# @section Verlustbehandlung nach § 23 EStG (M2):
# Verluste aus privaten Veraeusserungsgeschaeften (Haltedauer bis 1 Jahr) werden
# getrennt gefuehrt:
# \itemize{
#   \item Verluste werden NICHT sofort bei jedem Verkauf verrechnet
#   \item Jahresabrechnung in \code{.handle_year_change()}
#   \item Verlustvortrag nur mit kuenftigen § 23-Gewinnen verrechenbar
#   \item Jahressaldo unter 1.000 EUR (Freigrenze) ist steuerfrei, der Vortrag bleibt
#   \item Ab Erreichen ist der GESAMTE Saldo abzueglich Verlustvortrag steuerpflichtig
#     (nicht nur der Mehrbetrag; BFH IX R 27/04)
# }
#
# @changelog
# 2.1.0 (2025-02-05):
#   - I3: Guenstigerpruefung (§ 32d Abs. 6 EStG) ergaenzt
#   - M1: Behandlung negativer Basiszinsen bei der Vorabpauschale korrigiert
#   - M2: Zeitpunkt der § 23-Verlustverrechnung korrigiert (Jahresende, nicht je Verkauf)
#   - M3: Eigene Funktion .calculate_vorabpauschale_tax() ohne Verlustverrechnung
#     (inzwischen geaendert: Verrechnung mit dem § 20-Verlusttopf, R-2)
#   - M4: Vorabpauschale nur fuer Lots, die zum Jahresende gehalten werden
#   - effective_tax_rate fuer die Guenstigerpruefung durchgaengig ergaenzt
#   - Ausfuehrliche Dokumentation ergaenzt
#
# 2.0.0 (2025-01-26):
#   - Unterstuetzung fuer ETN/Zertifikate ergaenzt (Parameter tax_regime)
#   - Sparer-Pauschbetrag eingebunden
#   - Getrennte Verlusttoepfe fuer § 20 und § 23 EStG
#   - marginal_tax_rate fuer den persoenlichen Einkommensteuersatz ergaenzt
#
# 1.x.x (frueher):
#   - Erste Version mit ETF-Unterstuetzung
# =============================================================================

#' @title Portfolio-Simulation
#'
#' @description
#' Fuehrt eine Portfolio-Simulation (Backtest) mit mehreren Handelsstrategien,
#' Sparplaenen (DCA), Rebalancing und deutscher Steuerberechnung einschliesslich
#' Guenstigerpruefung durch. Massgebliche Beschreibung aller Argumente:
#' Hilfeseite \code{?simulation} (man/simulation.Rd).
#'
#' @param data data.frame mit taeglichen Marktdaten und den Spalten:
#'   \describe{
#'     \item{date}{Datum (Klasse Date); fehlende Kalendertage werden per LOCF aufgefuellt}
#'     \item{[Asset-Namen]}{Kursspalte (Niveaus, keine Renditen) je Asset der Strategie}
#'     \item{[Signalspalten]}{Optional: logische Kauf-/Verkaufssignale}
#'     \item{[Basiszins-Spalte]}{Optional: Basiszins in Prozent, wenn base_rate_flex = TRUE}
#'   }
#'
#' @param strategy Benannte Liste von Asset-Konfigurationen (idealerweise aus
#'   create_strategy()/asset_config()). Je Asset:
#'   \describe{
#'     \item{asset_class}{Zeichenkette: "etf", "etn", "etc", "certificate" (veraltet: "etn_standard", "etn_deliverable")}
#'     \item{trading}{Zeichenkette: "bnh" (Buy-and-Hold) oder "signal" (signalgesteuert)}
#'     \item{share}{Zahl: Zielgewicht als Anteil (0-1); die Summe ueber alle Assets muss 1 ergeben (keine Normierung, sonst Fehler)}
#'     \item{spread}{Zahl: voller Bid-Ask-Spread in Prozent (z. B. 0.1 = 0,1 \%); je Seite wird der halbe Spread angewandt}
#'     \item{partial_exemption}{Zahl: Teilfreistellung in Prozent (30 bei Aktien-ETFs, 15 bei Mischfonds, 0 sonst)}
#'     \item{start}{Date: Ab wann das Asset handelbar ist (optional); am Starttag wird
#'       immer auf die Zielgewichte umgeschichtet, auch ohne balance_mode}
#'     \item{tax_regime}{Zeichenkette: "investment_fund", "capital_gains" oder "private_sale" (optional, sonst aus asset_class und deliverable abgeleitet)}
#'     \item{signal_buy}{Zeichenkette: Spaltenname der Kaufsignale (Pflicht bei trading = "signal")}
#'     \item{signal_sell}{Zeichenkette: Spaltenname der Verkaufssignale (Pflicht bei trading = "signal")}
#'   }
#'
#' @param start_value Zahl. Anfangskapital in EUR. Standard: 10000.
#'
#' @param tax_mode Zeichenkette. Besteuerungsmodus:
#'   \describe{
#'     \item{"none"}{Keine Steuerberechnung (Standard)}
#'     \item{"person"}{Persoenliche Besteuerung (Abgeltungsteuer/§ 23) mit FIFO-Buchfuehrung}
#'   }
#'
#' @param tax_rate Zahl. Kapitalertragsteuersatz einschliesslich Soli in Prozent.
#'   Standard: 26.375 (25 \% + 5,5 \% Solidaritaetszuschlag = 26,375 \%).
#'   Zulaessig 0 bis 100. Wird bei \code{church_tax > 0} ueberschrieben; bei
#'   \code{use_guenstigerpruefung = TRUE} ggf. durch den persoenlichen Satz ersetzt.
#'
#' @param marginal_tax_rate Zahl oder NULL. Persoenlicher Grenzsteuersatz in Prozent
#'   (z. B. 42 = 42 \%; zulaessig 0 bis 50). Benoetigt fuer:
#'   \itemize{
#'     \item Besteuerung nach § 23 EStG (private_sale)
#'     \item Guenstigerpruefung (bei use_guenstigerpruefung = TRUE)
#'   }
#'   Beispielwerte: 14 (Eingangssatz), 24 (haeufig), 42 (Spitzensatz), 45 (Reichensteuer).
#'   NULL: bei steuerpflichtigen § 23-Gewinnen werden 42 \% mit Warnung angesetzt.
#'
#' @param use_guenstigerpruefung Logisch. Guenstigerpruefung (§ 32d Abs. 6 EStG) anwenden?
#'   Bei TRUE wird statt der Abgeltungsteuer der persoenliche Steuersatz verwendet, wenn die
#'   Belastung einschliesslich Zuschlagsteuern niedriger ist: marginal_tax_rate x (1 + Soli-Satz
#'   + Kirchensteuersatz) < effektiver Abgeltungsteuersatz (§ 32d Abs. 6 Satz 1 EStG; keine
#'   starre 25-\%-Schwelle). Standard: FALSE.
#'
#' @param sparer_pauschbetrag Zahl. Jaehrlicher Sparer-Pauschbetrag in EUR.
#'   Standard: 1000 (Einzelperson seit 2023). Bei Zusammenveranlagung 2000.
#'
#' @param use_sparer_pauschbetrag Logisch. Sparer-Pauschbetrag anwenden? Standard: TRUE.
#'
#' @param private_sale_threshold Zahl. Jaehrliche Freigrenze nach § 23 EStG in EUR
#'   (fuer alle Jahre gleich). Standard: 1000 (seit 2024). Ein Jahressaldo unter dieser
#'   Grenze ist steuerfrei (Verlustvortrag unveraendert).
#'   HINWEIS: Freigrenze (kein Freibetrag) - ab Erreichen (genau 1000 eingeschlossen) ist
#'   der GESAMTE Saldo abzueglich Verlustvortrag steuerpflichtig.
#'
#' @param include_soli_on_income_tax Logisch. Solidaritaetszuschlag auf die
#'   Einkommensteuer (§ 23 EStG, Guenstigerpruefung) erheben?
#'   Standard: FALSE. Seit 2021 zahlen wegen der Soli-Freigrenze die meisten
#'   Steuerpflichtigen keinen Soli auf die Einkommensteuer. TRUE fuer hohe Einkommen.
#'
#' @param soli_rate_income_tax Zahl. Soli-Satz in Prozent
#'   (Standard: 5.5 = 5,5 \%). Nur wirksam bei include_soli_on_income_tax = TRUE.
#'   Hinweis: Der Abgeltungsteuersatz (tax_rate = 26.375) enthaelt den Soli bereits.
#'
#' @param base_rate Zahl oder NULL. Fester jaehrlicher Basiszins fuer die
#'   Vorabpauschale in Prozent, z. B. 2.29 fuer 2,29 \% (Wert 2024).
#'   NULL = 0 (keine Vorabpauschale), sofern nicht base_rate_flex = TRUE.
#'
#' @param base_rate_flex Logisch. Zeitvariablen Basiszins aus einer Datenspalte verwenden? Standard: FALSE.
#'
#' @param base_rate_data Zeichenkette. Name der Spalte in data mit dem Basiszins (in Prozent;
#'   NA wird zu 0). Massgeblich ist je Jahr der Wert vom ersten Handelstag (§ 18 Abs. 4 InvStG).
#'   Pflicht bei base_rate_flex = TRUE. Standard: NULL.
#'
#' @return Objekt der Klasse "SimLevResult" (Liste), u. a. mit:
#'   \describe{
#'     \item{worth}{Zahlenvektor der taeglichen Portfoliowerte in EUR}
#'     \item{cagr}{Jaehrliche Wachstumsrate (CAGR) als Anteil (0.05 = 5 \%)}
#'     \item{ttwror}{Annualisierte zeitgewichtete Rendite (TTWROR) als Anteil}
#'     \item{drawdowns}{Vektor der taeglichen Drawdowns als positiver Anteil (0.2 = 20 \% unter Hoechststand)}
#'     \item{statistics}{Liste von Kennzahlen (mean, sd, Sharpe, Sortino, Schiefe, Kurtosis usw.)}
#'     \item{buys}{Benannter Vektor: mittlere Anzahl Kaeufe je Jahr und Asset}
#'     \item{sells}{Benannter Vektor: mittlere Anzahl Verkaeufe je Jahr und Asset}
#'     \item{report}{Taeglicher Bericht je Asset}
#'     \item{tax_report}{Steuerzusammenfassung (Betraege in EUR) mit:
#'       \itemize{
#'         \item total_taxes_paid: insgesamt gezahlte Steuern
#'         \item loss_carryforward_capital: verbleibender Verlustvortrag nach § 20 EStG
#'         \item loss_carryforward_private: verbleibender Verlustvortrag nach § 23 EStG
#'         \item sparer_pauschbetrag_annual: jaehrlicher Sparer-Pauschbetrag
#'         \item sparer_pauschbetrag_used: insgesamt genutzter Sparer-Pauschbetrag
#'         \item sparer_pauschbetrag_tax_saved: geschaetzte Steuerersparnis durch den Sparer-Pauschbetrag
#'       }
#'     }
#'   }
#'   Vollstaendige Liste der Komponenten: siehe den zweiten roxygen-Block vor
#'   \code{simulation()} und man/simulation.Rd.
#'
#' @examples
#' \dontrun{
#' # Einfache ETF-Simulation mit deutschen Steuerregeln
#' result <- simulation(
#'   data = market_data,
#'   strategy = list(
#'     MSCI_World = list(
#'       asset_class = "etf",
#'       trading = "bnh",
#'       share = 0.7,
#'       spread = 0.1,
#'       partial_exemption = 30   # 30 Prozent Teilfreistellung fuer Aktien-ETF
#'     ),
#'     Bonds = list(
#'       asset_class = "etf",
#'       trading = "bnh",
#'       share = 0.3,
#'       spread = 0.1,
#'       partial_exemption = 0    # Keine Teilfreistellung fuer Renten-ETF
#'     )
#'   ),
#'   start_value = 50000,
#'   tax = tax_profile(sparer_pauschbetrag = 2000,  # Zusammenveranlagung
#'                     base_rate = 2.29)            # Basiszins 2024 in Prozent
#' )
#'
#' # Mit Guenstigerpruefung fuer Anleger mit niedrigem Einkommen
#' result <- simulation(
#'   data = market_data,
#'   strategy = my_strategy,
#'   tax = tax_profile(income = income_rate(20),     # persoenlicher Satz 20 Prozent
#'                     guenstigerpruefung = TRUE)    # persoenlicher Satz, wenn die Belastung niedriger ist
#' )
#'
#' # Mit lieferbarem ETN (§ 23 EStG)
#' result <- simulation(
#'   data = market_data,
#'   strategy = list(
#'     Gold_ETC = list(
#'       asset_class = "etn_deliverable",
#'       trading = "bnh",
#'       share = 1.0,
#'       spread = 0.2,
#'       partial_exemption = 0
#'     )
#'   ),
#'   tax = tax_profile(income = income_rate(35),     # fuer § 23 benoetigt (Prozent)
#'                     private_sale_threshold = 1000)
#' )
#' }
#'
#' @seealso
#' \itemize{
#'   \item \code{\link{asset_config}}, \code{\link{create_strategy}} zum Aufbau der Strategie
#'   \item \code{\link{rebalance_trigger}} fuer ereignisbasiertes Rebalancing
#'   \item \code{\link{result_analysis}}, \code{\link{withdrawal_paths}} zur Weiterverarbeitung des Ergebnisses
#'   \item Interne Steuerfunktionen: .calculate_paragraph_20_tax(), .calculate_vorabpauschale_tax(),
#'     .calculate_private_sale_tax(), .handle_year_change()
#' }
#'

#' @param start_value Zahl. Anfangskapital in EUR.
#'   Standard: 10000.
#'
#' @param spread Zahl oder NULL. Wird nicht ausgewertet (Warnung, wenn nicht NULL);
#'   massgeblich ist der Spread je Asset (spread). Standard: NULL.
#'
#' @param details Logisch. Ausfuehrliches Transaktions- und Steuerprotokoll auf der
#'   Konsole ausgeben. Standard: FALSE.
#'
#' @param liquidate Logisch. Alle Positionen am letzten Tag verkaufen (inkl. Steuer).
#'   Standard: FALSE.
#'
#' @section DCA-Parameter:
#' @param dca_mode Logisch. Sparplan (Dollar-Cost Averaging) aktivieren. Standard: FALSE.
#' @param dca_value Zahl. Betrag je Sparplan-Termin in EUR; Pflicht bei dca_mode = TRUE (einzelne endliche Zahl > 0).
#' @param dca_span Ganzzahl. Anzahl Perioden (dca_unit) zwischen zwei Terminen; Pflicht bei dca_mode = TRUE (einzelne ganze Zahl >= 1).
#' @param dca_days Ganzzahl(en) oder NULL. Tag(e) innerhalb der Periode: bei "month" Tag des Monats,
#'   bei "quarter" Tag im ersten Monat des Quartals, bei "year" Tag im Januar (jeweils 1-31);
#'   mit dca_anchor = "end" vom Periodenende rueckwaerts gezaehlt (1 = letzter Tag).
#'   NULL = erster Tag der Periode. Doppelte Tage ergeben nur einen Termin (Warnung).
#' @param dca_unit Zeichenkette. Periodeneinheit: "month" (Standard), "quarter" oder "year".
#' @param dca_anchor Zeichenkette. dca_days ab "start" (Standard) oder "end" der Periode zaehlen.
#' @param dca_start Date oder NULL. Bezugsdatum: der Terminplan beginnt am Monatsersten
#'   (bei "year": am 1. Januar) dieses Datums. NULL = erster Tag der Daten.
#' @param dca_skip Logisch. Sparplan-Termin am ersten Simulationstag auslassen. Standard: FALSE.
#' @param balance_dca Logisch. FALSE (Standard): Rate fix nach Strategie-Gewichten verteilen.
#'   TRUE: Rate fuellt zuerst die Wert-Defizite untergewichteter Assets, ein Rest geht nach Strategie-Gewichten.
#'
#' @section Rebalancing-Parameter:
#' @param balance_mode Logisch. Periodisches Rebalancing aktivieren. Standard: FALSE.
#' @param balance_span Ganzzahl oder NULL. Anzahl Perioden zwischen zwei Rebalancing-Terminen (NULL = 1).
#' @param balance_days Ganzzahl(en) oder NULL. Tag(e) innerhalb der Periode, wie dca_days.
#' @param balance_unit Zeichenkette. Periodeneinheit: "month" (Standard), "quarter" oder "year".
#' @param balance_anchor Zeichenkette. balance_days ab "start" (Standard) oder "end" der Periode zaehlen.
#' @param balance_start Date oder NULL. Bezugsdatum des Terminplans, wie dca_start.
#' @param balance_skip Logisch. Rebalancing am ersten Simulationstag auslassen. Standard: FALSE.
#' @param balance_thresh Zahl oder NULL. Toleranzband in Prozent: Rebalanciert wird nur, wenn
#'   ein Asset um mehr als diesen Wert vom Ziel abweicht (z. B. 5 = 5 Prozentpunkte bei
#'   balance_thresh_type = "absolute"). NULL = an jedem Termin rebalancieren.
#' @param balance_thresh_type Zeichenkette. "absolute" (Standard): balance_thresh in
#'   Prozentpunkten des Gewichts; "relative": in Prozent des Zielgewichts.
#'
#' @section Steuer-Parameter:
#' @param tax_mode Zeichenkette. Besteuerungsmodus:
#'   \describe{
#'     \item{"none"}{Keine Steuerberechnung (Standard)}
#'     \item{"person"}{Persoenliche Besteuerung (Abgeltungsteuer, § 23 EStG) mit FIFO-Buchfuehrung}
#'   }
#' @param tax_rate Zahl. Steuersatz in Prozent (Standard: 26.375 = 25 % + 5,5 % Soli).
#' @param base_rate Zahl oder NULL. Basiszins fuer die Vorabpauschale in Prozent (2.29 = 2,29 %).
#' @param base_rate_flex Logisch. Zeitvariablen Basiszins aus den Daten verwenden.
#' @param base_rate_data Zeichenkette. Spaltenname des Basiszinses (in Prozent).
#'
#' @section Weitere Parameter:
#' @param risk_free Zahl oder Zeichenkette. Annualisierte risikolose Rendite in
#'   Prozent (z. B. 3 = 3 % p. a.), wie im uebrigen Paket. Entweder eine einzelne
#'   Zahl ODER der Name einer Spalte in \code{data} mit einer taeglichen
#'   annualisierten Rate in Prozent (z. B. SOFR). Jede Tagesrate wird in ihr
#'   Tagesaequivalent umgerechnet und von der Tagesrendite abgezogen; Sharpe und
#'   Sortino werden auf den Ueberschussrenditen berechnet. Per LOCF aufgefuellte
#'   Tage werden durchgaengig ausgeschlossen. Standard: 0 (NULL wie 0).
#' @param fractions Logisch. Bruchteile von Anteilen erlauben. Standard: TRUE.
#' @param split_mode Logisch. Automatische Splits aktivieren. Standard: FALSE
#' @param split_thresh Zahlenvektor der Laenge 2: c(untere, obere) Kursschwelle in
#'   Preiseinheiten der Kursreihe. Ueber der oberen Schwelle folgt ein Split, unter der
#'   unteren eine Zusammenlegung, jeweils auf einen Kurs von 100. Erwartet wird
#'   untere < 100 < obere; sonst Warnung (taegliche Splits).
#'
#' @param marginal_tax_rate Zahl oder NULL. Persoenlicher Grenzsteuersatz in Prozent fuer
#'   die Besteuerung nach § 23 EStG und die Guenstigerpruefung (zulaessig 0 bis 50).
#'   Benoetigt bei lieferbaren ETN/ETC. Uebliche Werte: 14 (Eingangssatz), 42 (Spitzensatz),
#'   45 (Reichensteuer). Standard: NULL (bei Bedarf werden 42 % mit Warnung angesetzt).
#'   Hinweis: Der Soli wird ueber include_soli_on_income_tax / soli_rate_income_tax gesteuert.
#'
#' @param private_sale_threshold Zahl. Jaehrliche Freigrenze nach § 23 EStG in EUR
#'   (aktuelle Rechtslage fuer alle Jahre). ERREICHT der Jahressaldo der privaten
#'   Veraeusserungen diesen Betrag, ist der GESAMTE Saldo abzueglich Verlustvortrag
#'   steuerpflichtig; darunter steuerfrei, der Vortrag bleibt dann unveraendert.
#'   Standard: 1000 (seit 2024, vorher 600).
#'
#' @param sparer_pauschbetrag Zahl. Jaehrlicher Freibetrag (Sparer-Pauschbetrag) in EUR
#'   fuer Kapitalertraege nach § 20 EStG. Anders als bei der Freigrenze wird nur der
#'   Betrag DARUEBER besteuert. Standard: 1000 (Einzelperson), 2000 bei Zusammenveranlagung.
#'
#' @param use_sparer_pauschbetrag Logisch. Sparer-Pauschbetrag anwenden?
#'   FALSE simuliert ohne Freibetrag (z. B. zum Vergleich).
#'   Standard: TRUE.
#'
#' @param taxable_income NULL, Zahl, nach Jahr benannter Zahlenvektor oder data.frame (year,
#'   taxable_income). Zu versteuerndes Einkommen in EUR je Kalenderjahr OHNE die Kapitalertraege und
#'   § 23-Gewinne dieser Simulation (eine Zahl gilt fuer alle Jahre; fehlt ein Simulationsjahr: Fehler).
#'   Mit Angabe (nur tax_mode = "person") gilt der Einkommensteuertarif aus tax_tariff: § 23-Steuer =
#'   T(zvE + G23) - T(zvE) plus Soli-Zuwachs S(T(zvE + G23)) - S(T(zvE)) plus KiSt (church_tax Prozent
#'   des ESt-Zuwachses); Guenstigerpruefung (use_guenstigerpruefung = TRUE) im Jahresabschluss mit
#'   Abrechnung; Kirchensteuer der Simulation als Sonderausgabe im Zahlungsjahr (Erstattungen verrechnet bzw.
#'   hinzugerechnet; bei guenstigerer Tarifbesteuerung auch die auf K einbehaltene KiSt).
#'   marginal_tax_rate, include_soli_on_income_tax und soli_rate_income_tax wirken dann nicht (Warnung,
#'   wenn angegeben). NULL (Standard): bisheriger Weg mit marginal_tax_rate.
#' @param tax_tariff NULL (mitgelieferte Datei extdata/steuertarif.csv, ab VZ 2026), Dateipfad oder
#'   Objekt aus \code{\link{tax_tariff}()}. Nur mit taxable_income wirksam (sonst Warnung).
#' @return Objekt der Klasse "SimLevResult" (Liste) mit:
#'   \describe{
#'     \item{dates}{Date-Vektor der Simulationstage (Kalendertage)}
#'     \item{filled}{Logischer Vektor: TRUE = per LOCF aufgefuellter Tag}
#'     \item{worth}{Zahlenvektor der taeglichen Portfoliowerte (Depotwert inkl. Einzahlungen) in EUR}
#'     \item{twr_index}{Zeitgewichteter Wertindex (Start = 1) aus den um Einzahlungen bereinigten
#'       Tagesrenditen, wie fuer ttwror. An Tagen ohne Zahlung r = (W_t - W_{t-1}) / W_{t-1}.
#'       An Tagen mit Zahlung F (zum Schlusskurs angelegt) wird zum Zeitpunkt der Zahlung bewertet:
#'       V_pre = Vortagesbestand zum heutigen Schlusskurs plus Vortages-Cash,
#'       1 + r = (V_pre / W_{t-1}) * W_t / (V_pre + F). Ohne Kosten ist r die Kursrendite;
#'       Kaufkosten der Einzahlung belasten das Kapital nach der Zahlung}
#'     \item{invested}{start_value plus kumulierte Einzahlungen (Sparplan, auch am Starttag) je Tag
#'       in EUR, brutto vor Kaufkosten}
#'     \item{external_flows}{Logisch. TRUE, wenn nach dem Starttag Einzahlungen (Sparplan) erfolgten}
#'     \item{cagr}{Jaehrliche Wachstumsrate (CAGR) als Anteil; mit Einzahlungen die geldgewichtete
#'       Jahresrendite (interner Zinsfuss/XIRR aus Startbetrag start_value plus Rate am Starttag
#'       (brutto), datierten Einzahlungen und Endwert, Kalendertage / 365.25; NA mit Warnung, wenn
#'       es keine Loesung gibt). Ohne Einzahlungen nach dem Starttag:
#'       (Endwert / Depotwert am Starttag)^(1 / Jahre) - 1.}
#'     \item{ttwror}{Zeitgewichtete Rendite (TTWROR, annualisiert) als Anteil}
#'     \item{drawdowns}{Zahlenvektor der taeglichen Drawdowns als positiver Anteil; mit Einzahlungen
#'       auf twr_index statt auf dem Depotwert (ebenso max_drawdown, average_drawdown, ulcer_index,
#'       longest_drawdown, avg_recovery_time)}
#'     \item{statistics}{Liste mit mean, sd, cv, risk_free (Prozent), skewness, kurtosis, lpm, hpm,
#'       sharpe, sortino, calmar, omega, gain_to_pain, serenity, martin_ratio, max_drawdown,
#'       average_drawdown, ulcer_index, longest_drawdown, avg_recovery_time. Mit Einzahlungen
#'       beruhen die Renditekennzahlen auf den bereinigten Tagesrenditen, und calmar, serenity und
#'       martin_ratio verwenden ttwror statt cagr, damit Zaehler und Nenner zeitgewichtet sind.}
#'     \item{buys}{Benannter Vektor: mittlere Anzahl Kaeufe je Jahr und Asset}
#'     \item{sells}{Benannter Vektor: mittlere Anzahl Verkaeufe je Jahr und Asset}
#'     \item{report}{Liste je Asset mit den Tagesvektoren worth, money, flows, total, share}
#'     \item{tax_report}{Steuerzusammenfassung (siehe man/simulation.Rd)}
#'     \item{fees_paid}{Nur mit order_fee/dca_fee: Summe der Ordergebuehren in EUR}
#'     \item{harvest_days}{Nur mit harvest_mode = TRUE: Termine der Gewinnrealisierung}
#'     \item{undefined_metrics}{data.frame(metric, reason, detail): je NA-Kennzahl (cagr, ttwror,
#'       statistics) Ursache als Code (negative_end_value, no_irr_solution, too_short,
#'       zero_start_value, nonpositive_twr_index, zero_volatility, zero_mean_return,
#'       no_negative_returns, no_drawdown, no_recovery, not_finite) und deutscher Klartext; 0 Zeilen,
#'       wenn alles definiert ist}
#'     \item{open_lots}{Nur tax_mode = "person": je Asset list(lots = data.frame(date, units, price, vp),
#'       regime, partial_exemption, cash, spread (Prozent), order_fee (wie uebergeben oder NULL)) der am
#'       letzten Tag gehaltenen Lots (siehe man/simulation.Rd)}
#'   }
#'
#' @examples
#' # Einfache Buy-and-Hold-Simulation
#' data <- data.frame(
#'   date = seq.Date(as.Date("2020-01-01"), as.Date("2022-12-31"), by = "day"),
#'   ETF = 100 * exp(cumsum(rnorm(1096, 0.0003, 0.015)))
#' )
#'
#' strategy <- list(
#'   ETF = list(
#'     asset_class = "etf",
#'     trading = "bnh",
#'     share = 1.0,
#'     spread = 0.1,
#'     partial_exemption = 0
#'   )
#' )
#'
#' result <- simulation(
#'   data = data,
#'   strategy = strategy,
#'   start_value = 10000
#' )
#'
#' print(result$cagr)
#'
#' @seealso
#' \code{\link{create_strategy}} und \code{\link{asset_config}} zum Aufbau der Strategie,
#' \code{\link{print.SimLevResult}} zur Ausgabe der Ergebnisse,
#' \code{\link{plot.SimLevResult}} zur grafischen Darstellung,
#' \code{\link{result_analysis}} zur weiteren Auswertung
#'
#' @export
#' @useDynLib SimLev, .registration = TRUE, .fixes = "C_"
#' @import stats graphics grDevices
#' @importFrom utils head tail modifyList
#' @importFrom methods hasArg
#' @noRd

simulation <- function(data, strategy, start_value = 10000,
                       costs = sim_costs(), dca = NULL, rebalance = NULL, splits = NULL,
                       tax = NULL,
                       risk_free = 0, fractions = TRUE, liquidate = FALSE, details = FALSE) {
  # Etappe 6.3: Bausteine pruefen und in die Argumente der Engine uebersetzen (.sim_from_blocks); die Engine
  # (.simulation_flat) rechnet unveraendert. Bedingungen tragen den Aufruf von simulation().
  sim_call <- sys.call()
  flat <- .sim_from_blocks(costs, dca, rebalance, splits, tax)
  args <- c(if (!missing(data)) list(data = data), if (!missing(strategy)) list(strategy = strategy),
            list(start_value = start_value, risk_free = risk_free, fractions = fractions, liquidate = liquidate,
                 details = details),
            flat, list(.blocks = TRUE, .call = sim_call))
  do.call(.simulation_flat, args, quote = TRUE)   # quote: .call ist ein Aufruf und darf nicht ausgewertet werden
}

#' Engine von simulation() mit den internen (flachen) Argumenten
#'
#' Zweck: die Rechnung von simulation(); simulation() ruft sie mit den aus den Bausteinen uebersetzten Werten
#' auf (.blocks = TRUE: die Bausteine haben ihre Argumente schon geprueft, Meldungen nennen die Bausteine).
#' Die Aufrufer mit sim_args (bootstrap_study, param_search, sensitivity_*, planning_lumpsum_vs_dca,
#' tactical_simulation) gehen seit Etappe 6.4 ueber simulation() (.sim_args_set, .sim_call in sim_blocks.R).
#' @keywords internal
#' @noRd
.simulation_flat <- function(
    data,
    strategy,
    start_value = 10000,
    spread = NULL,
    details = FALSE,
    liquidate = FALSE,
    # DCA
    dca_mode = FALSE,
    dca_value = NULL,
    dca_span = NULL,
    dca_days = NULL,
    dca_unit = c("month", "quarter", "year"),
    dca_anchor = c("start", "end"),
    dca_start = NULL,
    dca_skip = FALSE,
    # Rebalancing
    balance_mode = FALSE,
    balance_span = NULL,
    balance_days = NULL,
    balance_unit = c("month", "quarter", "year"),
    balance_anchor = c("start", "end"),
    balance_start = NULL,
    balance_skip = FALSE,
    balance_dca = FALSE,
    balance_thresh = NULL,
    balance_thresh_type = c("absolute", "relative"),
    # =========================================
    # STEUERN (mit I3: Günstigerprüfung)
    # =========================================
    tax_mode = c("none", "person"),
    tax_rate = 26.375,
    marginal_tax_rate = NULL,
    use_guenstigerpruefung = FALSE,  # <-- NEU: I3
    private_sale_threshold = 1000,
    sparer_pauschbetrag = 1000,
    use_sparer_pauschbetrag = TRUE,
    include_soli_on_income_tax = FALSE,  # F4: Default FALSE (Soli-Freigrenze greift bei den meisten Steuerpflichtigen)
    soli_rate_income_tax = 5.5,          # F4: Soli-Satz in Prozent (5.5 = 5,5 %), nur relevant wenn include_soli_on_income_tax = TRUE
    # Basiszins
    base_rate = NULL,
    base_rate_flex = FALSE,
    base_rate_data = NULL,
    # Sonstiges
    fractions = TRUE,
    risk_free = 0,                # A-4: Risk-Free-Jahresrate in Prozent (3 = 3 %) ODER Spaltenname in data
    split_mode = FALSE,
    split_thresh = NULL,
    # === Ereignisbasiertes Rebalancing (vorberechnete Trigger-Spalte) ===
    event_col = NULL,                       # Name der TRUE/FALSE-Spalte in 'data'; NULL => rein datumsgetrieben
    event_mode = c("additional", "replace"), # 'additional' = zusaetzlich (OR) zum Kalender; 'replace' = ersetzt ihn
    event_weight = NULL,                    # benannter Vektor Asset->Spaltenname mit Ziel-Gewicht je Event-Tag (optional)
    # === Deutsche Praxis (alle Standardwerte = bisheriges Verhalten) ===
    church_tax = 0,                         # Kirchensteuersatz in Prozent (8 oder 9); passt tax_rate an
    order_fee = NULL,                       # Ordergebuehr: Zahl (fix, EUR) oder list(fixed, percent, min, max)
    dca_fee = NULL,                         # Gebuehr fuer Kaeufe an Sparplantagen (Standard: order_fee)
    harvest_mode = FALSE,                   # jaehrlich Gewinne bis zum Freibetrag realisieren und wieder kaufen
    harvest_day = "12-15",                  # Termin (MM-TT, naechster Handelstag)
    harvest_loss_pot = TRUE,                # Verlusttopf zusaetzlich zum Freibetrag nutzen
    # === Einkommensteuertarif (Datei) statt marginal_tax_rate ===
    taxable_income = NULL,                  # zvE je Kalenderjahr OHNE die Ertraege dieser Simulation (EUR)
    tax_tariff = NULL,                      # NULL = mitgelieferte Tarifdatei, Dateipfad oder tax_tariff()-Objekt
    .blocks = FALSE,                        # TRUE: Aufruf aus simulation() mit Bausteinen
    .call = NULL                            # Aufruf fuer Bedingungen (aus simulation())
) {
  # Ablauf in Phasen (interne Funktionen, Uebersicht in sim_validate.R). Fehler und Warnungen, die
  # direkt in einer Phase entstehen, tragen wie bisher den Aufruf von simulation() (.sim_restore_call).
  sim_call <- if (is.null(.call)) sys.call() else .call
  # Mit Bausteinen gilt kein Argument als einzeln angegeben (die Bausteine pruefen das Zusammenspiel selbst)
  given <- if (.blocks) c(tax_rate = FALSE, marginal_tax_rate = FALSE, include_soli_on_income_tax = FALSE,
                          soli_rate_income_tax = FALSE, event_mode = FALSE)
           else c(tax_rate = !missing(tax_rate), marginal_tax_rate = !missing(marginal_tax_rate),
                  include_soli_on_income_tax = !missing(include_soli_on_income_tax),
                  soli_rate_income_tax = !missing(soli_rate_income_tax), event_mode = !missing(event_mode))
  withCallingHandlers({
    # 1. Eingabepruefung, Steuer- und Gebuehreneinstellungen
    cfg <- .sim_check_inputs(
      data = data, strategy = strategy, start_value = start_value, spread = spread, details = details,
      dca_mode = dca_mode, dca_value = dca_value, dca_span = dca_span, dca_days = dca_days,
      balance_mode = balance_mode, balance_days = balance_days, balance_thresh = balance_thresh,
      balance_thresh_type = balance_thresh_type, tax_mode = tax_mode, tax_rate = tax_rate,
      marginal_tax_rate = marginal_tax_rate, use_guenstigerpruefung = use_guenstigerpruefung,
      private_sale_threshold = private_sale_threshold, sparer_pauschbetrag = sparer_pauschbetrag,
      use_sparer_pauschbetrag = use_sparer_pauschbetrag, include_soli_on_income_tax = include_soli_on_income_tax,
      soli_rate_income_tax = soli_rate_income_tax, base_rate = base_rate,
      fractions = fractions, risk_free = risk_free, split_mode = split_mode,
      split_thresh = split_thresh, event_col = event_col, church_tax = church_tax, order_fee = order_fee,
      dca_fee = dca_fee, harvest_mode = harvest_mode, harvest_day = harvest_day,
      taxable_income = taxable_income, tariff = tax_tariff, given = given, blocks = .blocks)
    # Ordergebuehren laufen ueber .fee_env an perform_trade_buy/sell; beim Verlassen zuruecksetzen
    if (cfg$fees_on) on.exit({ .fee_env$current <- NULL }, add = TRUE)

    # 2. Daten, Zentralstruktur sim_mem, Termine und Flags
    prep <- .sim_prepare_data(cfg$data, cfg$pre_filled, base_rate_flex, base_rate_data, blocks = .blocks)
    sim_mem <- .sim_build_state(prep$data, cfg$strategy, cfg$start_value, prep$start_date, prep$stopp_date,
                                cfg$sparer_pauschbetrag, cfg$use_sparer_pauschbetrag, cfg$base_rate,
                                base_rate_flex, base_rate_data, blocks = .blocks)
    .sim_check_layout(sim_mem)   # C7-11: vor dem ersten C++-Aufruf
    cal <- .sim_build_calendar(
      data = prep$data, sim_mem = sim_mem, strategy = cfg$strategy, start_date = prep$start_date,
      stopp_date = prep$stopp_date, liquidate = liquidate, dca_mode = cfg$dca_mode, dca_span = dca_span,
      dca_unit = dca_unit, dca_days = cfg$dca_days, dca_value = cfg$dca_value, dca_anchor = dca_anchor,
      dca_start = dca_start, dca_skip = dca_skip, balance_mode = cfg$balance_mode, balance_span = balance_span,
      balance_unit = balance_unit, balance_days = cfg$balance_days, balance_anchor = balance_anchor,
      balance_start = balance_start, balance_skip = balance_skip, event_col = cfg$event_col,
      event_mode = event_mode, event_weight = event_weight, split_mode = cfg$split_mode,
      split_thresh = split_thresh, blocks = .blocks, no_split = cfg$no_split)
    data <- cal$data
    fl <- cal$flags
    if (!is.null(cfg$event_col)) event_weight <- cal$event_weight
    init <- .sim_init_weights(sim_mem, fl$flag_assets, fl$flag_date, cfg$start_value)
    sim_mem <- init$sim_mem
    fl$initial_assets <- init$initial_assets
    fl <- .sim_build_schedule(sim_mem, fl, data, cfg$tax_mode, cfg$harvest_mode, harvest_day)

    # 3.-5. Helfer, Tagesschleife, Abschluss des letzten Jahres
    act <- .sim_make_actions(cfg, fl, details)
    sim_mem <- .sim_run_days(sim_mem, fl, cfg, act, data, cfg$strategy, liquidate, event_weight, split_thresh,
                             balance_dca, harvest_loss_pot, details)
    sim_mem <- .sim_close_years(sim_mem, fl, cfg, act, prep$stopp_date, details)

    # 6. Auswertung und Ergebnisobjekt
    sim_mem <- .sim_compact_trades(sim_mem, fl$flag_assets)
    ret <- .sim_returns(sim_mem, fl$flag_date, fl$flag_assets, fl$flag_filled, prep$start_date,
                        prep$stopp_date, cfg$start_value, act$tax_unpaid())
    risk <- .sim_risk_stats(ret, cfg$risk_free, data)
    undef <- .sim_undefined_metrics(ret, risk, sim_mem, fl$flag_assets)
    .sim_result(sim_mem, fl, cfg, ret, risk, undef)
  },
  warning = function(w) .sim_restore_call(w, sim_call),
  error = function(e) .sim_restore_call(e, sim_call))
}



#' Anzahl Tage mit Singular/Plural (R9-03): "1 Tag", "n Tage"
#' @keywords internal
#' @noRd
.n_tage <- function(n) {
  s <- if (is.character(n)) n else sprintf("%d", as.integer(n))   # Text: bereits formatiert (z. B. "%.0f")
  if (identical(s, "1")) "1 Tag" else paste(s, "Tage")
}

#' Text fuer eine nicht definierte Kennzahl (B): "nicht definiert (<Ursache>)" aus undefined_metrics
#' @keywords internal
#' @noRd
.undef_text <- function(x, metric) {
  um <- x$undefined_metrics
  d <- if (is.data.frame(um) && metric %in% um$metric) um$detail[match(metric, um$metric)] else NA_character_
  if (is.na(d)) "nicht definiert" else sprintf("nicht definiert (%s)", d)
}

#' SimLev-Ergebnisse ausgeben
#'
#' Gibt Performance-, Risiko-, Kennzahlen- und Verteilungswerte sowie (falls
#' Steuern gezahlt wurden) eine Steuerzusammenfassung auf der Konsole aus.
#'
#' @param x Ein Objekt der Klasse SimLevResult
#' @param ... Weitere Argumente (ignoriert)
#'
#' @return x, unsichtbar
#' @export
#' @noRd
print.SimLevResult <- function(x, ...) {
  s <- x$statistics
  cat("\n")
  cat("\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n")
  cat("                 SimLev Simulationsergebnisse                 \n")
  cat("\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n\n")
  
  cat("  Wertentwicklung\n")
  cat("  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\n")
  ext <- isTRUE(x$external_flows)   # Sparplan: CAGR geldgewichtet, Drawdowns zeitgewichtet
  # B: nicht definierte Kennzahl mit Ursache statt "NA"
  pct <- function(v, metric, suffix = "") if (is.na(v)) .undef_text(x, metric) else sprintf("%+.2f%%%s", v * 100, suffix)
  if (ext) {
    cat(sprintf("  CAGR:             %s\n", pct(x$cagr, "cagr", " (geldgewichtet, XIRR)")))
    cat(sprintf("  TTWROR:           %s\n", pct(x$ttwror, "ttwror", " (zeitgewichtet)")))
  } else {
    cat(sprintf("  CAGR:             %s\n", pct(x$cagr, "cagr")))
    cat(sprintf("  TTWROR:           %s\n", pct(x$ttwror, "ttwror")))
  }
  cat(sprintf("  Endwert:          %.2f EUR\n", tail(x$worth, 1)))
  if (ext) cat(sprintf("  Eingezahlt:       %.2f EUR (Start + Sparraten)\n", tail(x$invested, 1)))
  cat("\n")

  cat(if (ext) "  Risiko (zeitgewichtet, ohne Einzahlungseffekte)\n" else "  Risiko\n")
  cat("  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\n")
  cat(sprintf("  Max. Drawdown:    %.2f%%\n", s$max_drawdown * 100))
  cat(sprintf("  Mittl. Drawdown:  %.2f%%\n", s$average_drawdown * 100))
  cat(sprintf("  Ulcer Index:      %.4f\n", s$ulcer_index))
  cat(sprintf("  L\u00e4ngster DD:      %s\n", .n_tage(s$longest_drawdown)))
  cat(sprintf("  Mittl. Erholung:  %s\n",   # R9-03: ohne Wert nur "\u2013"
              if (is.na(s$avg_recovery_time)) "\u2013" else .n_tage(sprintf("%.0f", s$avg_recovery_time))))
  cat("\n")

  cat("  Kennzahlen\n")
  cat("  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\n")
  fmt_ratio <- function(val) if (is.na(val)) "\u2013" else sprintf("%+.3f", val)
  cat(sprintf("  Sharpe:           %s\n", fmt_ratio(s$sharpe)))
  cat(sprintf("  Sortino:          %s\n", fmt_ratio(s$sortino)))
  cat(sprintf("  Calmar:           %s\n", fmt_ratio(s$calmar)))
  cat(sprintf("  Omega:            %s\n", fmt_ratio(s$omega)))
  cat(sprintf("  Gain/Pain:        %s\n", fmt_ratio(s$gain_to_pain)))
  cat(sprintf("  Serenity:         %s\n", fmt_ratio(s$serenity)))
  cat(sprintf("  Martin Ratio:     %s\n", fmt_ratio(s$martin_ratio)))
  if (ext) cat("  (Calmar, Serenity, Martin mit TTWROR)\n")
  cat("\n")

  cat("  Verteilung\n")
  cat("  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\n")
  cat(sprintf("  Mittel je Tag:    %+.4f%%\n", s$mean * 100))
  cat(sprintf("  Std.-Abw. je Tag: %.4f%%\n", s$sd * 100))
  num3 <- function(v, metric) if (is.na(v)) .undef_text(x, metric) else sprintf("%.3f", v)
  cat(sprintf("  Schiefe:          %s\n", num3(s$skewness, "skewness")))
  cat(sprintf("  W\u00f6lbung:          %s\n", num3(s$kurtosis, "kurtosis")))
  cat("\n")
  
  if (!is.null(x$tax_report) && x$tax_report$total_taxes_paid > 0) {
    cat("  Steuern\n")
    cat("  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\n")
    cat(sprintf("  Gezahlte Steuern: %.2f EUR\n", x$tax_report$total_taxes_paid))
    cat(sprintf("  Verlustvortrag:   %.2f EUR (\u00a7 20) / %.2f EUR (\u00a7 23)\n", 
                x$tax_report$loss_carryforward_capital,
                x$tax_report$loss_carryforward_private))
    if (isTRUE(x$tax_report$open_tax_debt > 0))
      cat(sprintf("  Steuerschuld:     %.2f EUR (offen, nicht gedeckt)\n", x$tax_report$open_tax_debt))
    
    if (x$tax_report$sparer_pauschbetrag_annual > 0) {
      cat(sprintf("  SPB genutzt:      %.2f EUR (Ersparnis: %.2f EUR)\n",
                  x$tax_report$sparer_pauschbetrag_used,
                  x$tax_report$sparer_pauschbetrag_tax_saved))
    }
    cat("\n")
  }

  cat("\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n")
  
  invisible(x)
}


#' Zusammenfassung von SimLev-Ergebnissen
#'
#' @param object Ein Objekt der Klasse SimLevResult
#' @param ... Weitere Argumente (ignoriert)
#'
#' @return Liste der Klasse summary.SimLevResult mit Kennzahlen (sichtbar; die Ausgabe uebernimmt
#'   print.summary.SimLevResult, C7-06); Renditen und
#'   Drawdowns als Anteil, invested in EUR:
#'   \describe{
#'     \item{total_return_twr}{zeitgewichtete Gesamtrendite: mit Einzahlungen (Sparplan) letzter Wert
#'       von twr_index minus 1, sonst Endwert / Depotwert am Starttag - 1}
#'     \item{return_on_invested}{Gewinn je eingezahltem EUR: (Endwert - Eingezahlt) / Eingezahlt mit
#'       Eingezahlt = letzter Wert von invested (Startwert plus Einzahlungen, brutto)}
#'     \item{total_return}{gleichwertiger Alias fuer total_return_twr (aeltere Skripte)}
#'     \item{cagr, ttwror}{wie im Ergebnis (mit Einzahlungen cagr geldgewichtet); NA mit Ursache
#'       in undefined_metrics}
#'   }
#'   Die Ausgabe zeigt mit Einzahlungen beide Gesamtrenditen; nicht definierte Kennzahlen als
#'   "nicht definiert (Ursache)".
#' @export
#' @noRd
summary.SimLevResult <- function(object, ...) {
  n_days <- length(object$worth)
  s <- object$statistics
  ext <- isTRUE(object$external_flows)   # Sparplan: Gesamtrendite zeitgewichtet, CAGR geldgewichtet
  
  summary_list <- list(
    n_days = n_days,
    n_years = round(n_days / 365.25, 2),
    start_value = object$worth[1],         # Depotwert am Starttag (nach Kaufkosten, mit Rate des Starttags)
    # R9-04: Startkapital (Argument start_value) = eingezahlt am Starttag ohne die Sparrate des Starttags
    start_capital = if (!is.null(object$invested))
      object$invested[1] - sum(vapply(object$report, function(r) r[["flows"]][1], numeric(1)), na.rm = TRUE) else NA_real_,
    end_value = tail(object$worth, 1),
    total_return_twr = if (ext) tail(object$twr_index, 1) / object$twr_index[1] - 1 else (tail(object$worth, 1) / object$worth[1]) - 1,
    return_on_invested = NA_real_,
    total_return = NA_real_,             # Alias fuer total_return_twr (unten gesetzt)
    invested = if (!is.null(object$invested)) tail(object$invested, 1) else object$worth[1],
    cagr = object$cagr,
    ttwror = object$ttwror,
    # Alle Metriken direkt aus statistics übernehmen (nicht neu berechnen)
    sharpe = s$sharpe,
    sortino = s$sortino,
    calmar = s$calmar,
    omega = s$omega,
    gain_to_pain = s$gain_to_pain,
    serenity = s$serenity,
    martin_ratio = s$martin_ratio,
    max_drawdown = s$max_drawdown,
    average_drawdown = s$average_drawdown,
    ulcer_index = s$ulcer_index,
    longest_drawdown = s$longest_drawdown,
    avg_recovery_time = s$avg_recovery_time,
    statistics = s,
    tax_report = object$tax_report,
    undefined_metrics = object$undefined_metrics,
    external_flows = ext
  )
  summary_list$total_return <- summary_list$total_return_twr
  summary_list$return_on_invested <- (summary_list$end_value - summary_list$invested) / summary_list$invested
  
  class(summary_list) <- "summary.SimLevResult"
  # C7-06: summary() druckt nicht mehr selbst; die Ausgabe uebernimmt print.summary.SimLevResult
  # (Konsole: summary(x) zeigt die Zusammenfassung wie bisher, s <- summary(x) bleibt still)
  summary_list
}

#' Zusammenfassung von SimLev-Ergebnissen ausgeben
#'
#' @param x Ein Objekt der Klasse summary.SimLevResult (aus summary())
#' @param ... Weitere Argumente (ignoriert)
#' @return x, unsichtbar
#' @export
#' @noRd
print.summary.SimLevResult <- function(x, ...) {
  summary_list <- x; object <- x; s <- x$statistics; n_days <- x$n_days
  ext <- isTRUE(x$external_flows)
  # Eigene kompakte Ausgabe
  cat("\n")
  cat("\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n")
  cat("                    SimLev Zusammenfassung                    \n")
  cat("\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n\n")
  
  cat(sprintf("  Zeitraum:         %s (%.1f Jahre)\n", .n_tage(n_days), summary_list$n_years))
  # R9-04: Startkapital (start_value) und Depotwert am Starttag (nach Kaufkosten, ggf. mit Sparrate) getrennt
  if (!is.null(summary_list$start_capital) && !is.na(summary_list$start_capital))
    cat(sprintf("  Startkapital:     %.2f EUR\n", summary_list$start_capital))
  cat(sprintf("  Depotwert Starttag: %.2f EUR\n", summary_list$start_value))
  cat(sprintf("  Ende:             %.2f EUR\n", summary_list$end_value))
  pct <- function(v, metric, suffix = "") if (is.na(v)) .undef_text(object, metric) else sprintf("%+.2f%%%s", v * 100, suffix)
  if (ext) {
    cat(sprintf("  Eingezahlt:       %.2f EUR (Start + Sparraten)\n", summary_list$invested))
    cat(sprintf("  Gesamtrendite (zeitgewichtet): %+.2f %%\n", summary_list$total_return_twr * 100))
    cat(sprintf("  Gewinn je eingezahltem EUR:    %+.2f %% (Endwert %.2f EUR / Eingezahlt %.2f EUR - 1)\n",
                summary_list$return_on_invested * 100, summary_list$end_value, summary_list$invested))
    cat(sprintf("  CAGR:             %s\n", pct(summary_list$cagr, "cagr", " (geldgewichtet, XIRR)")))
    cat(sprintf("  TTWROR:           %s\n", pct(summary_list$ttwror, "ttwror", " (zeitgewichtet)")))
  } else {
    cat(sprintf("  Gesamtrendite:    %+.2f%%\n", summary_list$total_return * 100))
    cat(sprintf("  CAGR:             %s\n", pct(summary_list$cagr, "cagr")))
    cat(sprintf("  TTWROR:           %s\n", pct(summary_list$ttwror, "ttwror")))
  }
  cat("\n")
  
  fmt <- function(val, pct = FALSE) {
    if (is.na(val)) return("\u2013")
    if (pct) sprintf("%.2f%%", val * 100) else sprintf("%.3f", val)
  }
  
  metrics <- data.frame(
    Metrik = c("Sharpe", "Sortino", "Calmar", "Omega", "Gain/Pain", 
               "Serenity", "Martin", "Max. DD", "Mittl. DD", "Ulcer", 
               "L\u00e4ngster DD", "Mittl. Erholung"),
    Wert = c(
      fmt(s$sharpe), fmt(s$sortino), fmt(s$calmar), fmt(s$omega),
      fmt(s$gain_to_pain), fmt(s$serenity), fmt(s$martin_ratio),
      fmt(s$max_drawdown, TRUE), fmt(s$average_drawdown, TRUE), fmt(s$ulcer_index),
      sprintf("%d d", s$longest_drawdown),
      if (is.na(s$avg_recovery_time)) "\u2013" else sprintf("%.0f d", s$avg_recovery_time)
    ),
    stringsAsFactors = FALSE
  )
  
  for (i in seq_len(nrow(metrics))) {
    cat(sprintf("  %s %s\n", format(metrics$Metrik[i], width = 16), metrics$Wert[i]))   # Breite in Zeichen (Umlaute)
  }
  if (ext) cat("  (Drawdowns zeitgewichtet; Calmar, Serenity, Martin mit TTWROR)\n")

  cat("\n\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n")
  
  invisible(x)
}


