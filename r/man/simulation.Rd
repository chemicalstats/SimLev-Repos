\encoding{UTF-8}
\name{simulation}
\alias{simulation}
\title{Portfolio-Backtest-Simulation}
\description{
Backtestet eine oder mehrere Asset-Strategien auf historischen oder
synthetischen Preisreihen. Die Engine verarbeitet jede Preisreihe so, wie
sie übergeben wird – Hebelung, Dividenden und Finanzierungskosten sind
Bestandteil der Inputreihe und werden nicht intern berechnet.

Die Simulation unterstützt Buy-and-Hold (\code{"bnh"}), signalgesteuerte
Strategien (\code{"signal"}), DCA-Sparpläne, periodisches Rebalancing,
ereignisbasiertes Rebalancing sowie die Deutsche Investmentbesteuerung
(§§ 18–20 InvStG, § 23 EStG).
}
\usage{
simulation(
  data,
  strategy,
  start_value = 10000,
  costs       = sim_costs(),
  dca         = NULL,
  rebalance   = NULL,
  splits      = NULL,
  tax         = NULL,
  risk_free   = 0,
  fractions   = TRUE,
  liquidate   = FALSE,
  details     = FALSE
)
}
\arguments{
  \item{data}{
    \code{data.frame} mit täglichen Marktdaten. Pflichtfelder: \code{date}
    (Klasse \code{Date}, aufsteigend) und je eine Kursspalte pro Asset (Niveaus,
    keine Renditen; Name muss mit dem Asset-Namen in \code{strategy}
    übereinstimmen; für Fonds-Wrapper die Spalten der inneren Strategie, siehe Abschnitt
    \dQuote{Fonds-Wrapper}). Optionale Spalten: Basiszins in Prozent (Spaltenname in
    \code{tax_profile(base_rate = )}), logische Signalspalten (für
    \code{trading = "signal"}), Risk-Free-Reihe in Prozent p.a. (Name in
    \code{risk_free}), logische Trigger- und numerische Gewichtsspalten für
    \code{rebalance_plan(event_col, event_weight)}.
    Fehlende Kalendertage werden automatisch per LOCF aufgefüllt (logische
    Spalten mit \code{FALSE}); aufgefüllte Tage werden in \code{filled}
    markiert und aus Risikometriken ausgeschlossen. Trägt \code{data} das
    Attribut \code{filled} aus \code{\link{series_align}}, gelten Tage, an
    denen keines der Strategie-Assets einen echten Kurs hat, ebenso als
    aufgefüllt (kein Handel, nicht in den Risikometriken). Passt die
    Zeilenzahl des Attributs nicht zu \code{data} (z. B. nach einer
    Zeilenauswahl der \code{series_align()}-Ausgabe), wird es mit Warnung
    ignoriert; den Zeitraum daher mit \code{series_align(..., start =, end =)}
    wählen.

    Eingabeprüfung: \code{date} als Text im Format \code{"JJJJ-MM-TT"} (oder
    Faktor) wird mit Hinweis in \code{Date} umgewandelt; unsortierte Zeilen
    werden mit Hinweis aufsteigend sortiert; doppelte Daten und doppelte
    Spaltennamen führen zu einem Fehler. Kurse müssen positiv sein (\code{<= 0} oder unendlich: Fehler).
    Einzelne fehlende Kurse (\code{NA}) werden mit Hinweis per LOCF gefüllt;
    sind in einer Zeile alle Kurse \code{NA}, gilt der Tag als aufgefüllt.
    Hat ein Asset erst ab einem späteren Tag Kurse (führende \code{NA}, etwa
    aus \code{series_align(range = "all")}), wird es wie mit
    \code{start} = erster Kurstag behandelt. Mindestens ein Asset muss
    am ersten Tag handelbar sein. Andere data.frame-Klassen (z. B. tibble)
    werden in einen \code{data.frame} umgewandelt.
  }
  \item{strategy}{
    Benannte Liste von Asset-Konfigurationen, idealerweise erzeugt mit
    \code{\link{create_strategy}} und \code{\link{asset_config}}. Direkte
    Listen-Übergabe ist ebenfalls möglich (Backward-Kompatibilität).
    Die Zielgewichte \code{share} (Anteile, 0--1) müssen sich auf
    exakt 1 summieren (Toleranz 1e-6); sie werden nicht normiert, sonst
    bricht die Funktion mit Fehler ab. Asset-Namen müssen eindeutig sein.
    Assets mit späterem \code{start} erhalten ab dem Start ihr volles
    Zielgewicht (das Startkapital verteilt sich bis dahin auf die übrigen
    Assets); am Starttag wird immer auf die Zielgewichte umgeschichtet
    (Verkauf der übrigen Assets, Kauf des neuen; mit Steuern, Spreads und
    Gebühren wie bei jedem Rebalancing), auch ohne \code{rebalance}; ein
    zusätzlicher Handelsblock (z. B. Kauf aus einer Sparrate vor der
    Umschichtung) läuft an diesem Tag nicht. Mit
    \code{rebalance = rebalance_plan()} gilt danach der normale Rhythmus. Liegt
    \code{start} nach dem letzten Datentag, bricht die Funktion mit
    Fehler ab (das Asset wäre nie handelbar).
  }
  \item{start_value}{
    Numerisch. Anfangskapital in EUR. Standard: \code{10000}.
  }
  \item{costs}{
    Kosten: \code{\link{sim_costs}(order_fee, dca_fee)} (Ordergebühren, Gebühren der
    Sparplankäufe) oder \code{NULL} (keine Kosten). Standard: \code{sim_costs()} (keine
    Gebühren). Der Bid-Ask-Spread gilt je Asset (\code{spread} in \code{\link{asset_config}}).
  }
  \item{dca}{
    Sparplan: \code{\link{dca_plan}(value, span, days, unit, anchor, start, skip,
    fill_deficits)} oder \code{NULL} (Standard: kein Sparplan).
  }
  \item{rebalance}{
    Rebalancing: \code{\link{rebalance_plan}(span, days, unit, anchor, start, skip, thresh,
    thresh_type, event_col, event_mode, event_weight)} oder \code{NULL} (Standard: kein
    Rebalancing). Mit Rebalancing wird am ersten Simulationstag (und am Starttag später
    startender Assets) nur über das Rebalancing gekauft (Erstkauf nach Zielgewichten); ein
    zusätzlicher Handelsblock mit anschließender Umschichtung von Resten entfällt.
  }
  \item{splits}{
    Automatische Splits: \code{\link{split_rule}(thresh = c(untere, obere))} oder
    \code{NULL} (Standard: keine Splits).
  }
  \item{tax}{
    Persönliche Besteuerung (§§ 18--20 InvStG, § 23 EStG) mit FIFO-Buchführung:
    \code{\link{tax_profile}(rate, church_tax, sparer_pauschbetrag, private_sale_threshold,
    base_rate, guenstigerpruefung, income, harvest)} oder \code{NULL} (Standard: keine
    Steuern).
  }
  \item{risk_free}{
    Numerisch oder Character. Annualisierte risikolose Rendite
    \strong{in Prozent} (z. B. \code{3} = 3 \% p.a.) oder Name einer
    Spalte in \code{data} mit einer täglichen, annualisierten Zeitreihe in
    Prozent (z. B. SOFR als \code{5.31}). \code{NULL} und \code{0} sind
    äquivalent. Jede Tagesrate wird in ihr Tagesäquivalent umgerechnet und
    von der jeweiligen Tagesrendite abgezogen; Sharpe und Sortino werden auf
    den Überschussrenditen berechnet. LOCF-aufgefüllte Tage werden konsistent
    ausgeschlossen. Standard: \code{0}.
    Zahlen über 0 und unter 0,05 (vermutlich Anteil, z. B. \code{0.02} für
    2 \%) werden mit Warnung als Prozent gelesen; kleine echte Prozentsätze
    wie \code{0.25} (Geldmarkt 2016--2019) warnen nicht. Für eine Spalte gilt
    dieselbe Schwelle für den Median ihrer Werte (ohne \code{NA} und 0).
  }
  \item{fractions}{
    Logisch. Bruchteile von Anteilen erlauben? Bei \code{FALSE} werden bei
    einem Split entstehende Bruchteile einmalig zum Kurs des Split-Tages
    verkauft (Spitzenausgleich, ohne Spread und Gebühr; steuerlich ein
    Verkauf nach FIFO). Zwangsverkäufe für eine Steuerzahlung (Vorabpauschale,
    § 23) verkaufen die aufgerundete Stückzahl und bei verbleibendem
    Fehlbetrag ein weiteres Stück; ein Überschuss bleibt als Cash. Reicht ein
    Asset nicht, zahlen die übrigen Assets; ein dann noch offener Betrag
    bleibt als negativer Geldbestand (mit Warnung) stehen und wird nie still
    gestrichen. Standard: \code{TRUE}.
    Nur \code{TRUE} oder \code{FALSE} (sonst Fehler).
  }
  \item{liquidate}{
    Logisch. Portfolio am letzten Simulationstag vollständig liquidieren
    (inkl. Steuerabrechnung)? Übersteigt die Ordergebühr den Erlös einer
    Position, bleibt sie mit Warnung stehen. Am Liquidationstag finden kein
    Rebalancing und keine Sparrate statt, auch wenn ein Termin von einem
    aufgefüllten Tag dorthin verschoben wurde. Standard: \code{FALSE}.
  }
  \item{details}{
    Logisch. Detaillierte Steuer-/Trade-Ausgaben auf der Konsole?
    Standard: \code{FALSE}.
  }
}
\value{
  Liste der Klasse \code{"SimLevResult"} mit:
  \describe{
    \item{\code{dates}}{
      Date-Vektor. Tägliche Simulationsdaten (Kalendertage inkl. aufgefüllter
      Tage).
    }
    \item{\code{filled}}{
      Logischer Vektor (gleiche Länge wie \code{dates}). \code{TRUE} = dieser
      Tag wurde per LOCF aufgefüllt (kein echter Handelstag). Aufgefüllte Tage
      werden aus allen renditebasierten Risikometriken ausgeschlossen.
    }
    \item{\code{worth}}{
      Numerischer Vektor. Tägliche Portfoliowerte (Depotwert einschließlich
      Einzahlungen) in EUR.
    }
    \item{\code{twr_index}}{
      Numerischer Vektor. Zeitgewichteter Wertindex (Start = 1), verkettet aus
      den um Einzahlungen bereinigten Tagesrenditen wie für \code{ttwror}: an
      Tagen ohne Einzahlung \eqn{(W_t - W_{t-1}) / W_{t-1}}. An Tagen mit
      Einzahlung \eqn{F_t} (angelegt zum Schlusskurs) wird zum Zeitpunkt der
      Zahlung bewertet (echte zeitgewichtete Rendite):
      \eqn{V^{pre}_t} = Vortagesbestand zum heutigen Schlusskurs plus
      Vortages-Cash, Tagesfaktor
      \eqn{(V^{pre}_t / W_{t-1}) \cdot W_t / (V^{pre}_t + F_t)}. Ohne Kosten
      entspricht die Tagesrendite damit der Kursrendite; Kaufkosten der
      Einzahlung (Spread, Gebühr) und alles, was am selben Tag danach
      geschieht, belasten das Kapital nach der Zahlung.
    }
    \item{\code{invested}}{
      Numerischer Vektor. \code{start_value} plus kumulierte Einzahlungen
      (Sparplan, einschließlich einer Rate am Starttag) je Tag in EUR, brutto
      (vor Kaufkosten).
    }
    \item{\code{external_flows}}{
      Logisch. \code{TRUE}, wenn nach dem Starttag Einzahlungen erfolgten
      (Sparplan, \code{dca = dca_plan()}); eine Einzahlung am Starttag steckt
      im Startwert.
    }
    \item{\code{cagr}}{
      Numerisch. Compound Annual Growth Rate (annualisierte Gesamtrendite)
      als Anteil (\code{0.05} = 5 \% p.a.; Jahre = Kalendertage / 365,25).
      Mit Einzahlungen (\code{external_flows = TRUE}) die geldgewichtete
      Jahresrendite: interner Zinsfuß (XIRR) aus Startbetrag, datierten
      Einzahlungen und Endwert, \eqn{S (1+r)^T + \sum_i F_i (1+r)^{T - t_i} = W_n}
      mit Startbetrag \eqn{S} = \code{start_value} plus Rate am Starttag
      (brutto, wie die übrigen Einzahlungen) und \eqn{t_i} = Kalendertage seit
      Start / 365,25 (Nullstelle nach Brent; auch bei Beinahe-Totalverlust
      mit Rendite nahe -100 \%); ohne Einzahlungen nach dem Starttag
      \eqn{(W_n / W_1)^{1/T} - 1}. Gibt es keine Lösung, ist \code{cagr = NA}
      (mit Warnung). Ist der Endwert negativ (nicht gedeckte Steuerschuld, Verlust
      über 100 \%), sind \code{cagr} und \code{ttwror} nicht definiert: \code{NA}
      mit Warnung (nicht -1, das den Verlust untertreiben würde); der Endwert bleibt
      unverändert (nicht auf 0 begrenzt). Bei einem Einzeltag (Laufzeit 0 Jahre)
      sind \code{cagr} und \code{ttwror} ebenfalls \code{NA} (mit Warnung). Die
      Ursache steht in \code{undefined_metrics}. Die zeitgewichtete
      Rendite steht in \code{ttwror}.
    }
    \item{\code{ttwror}}{
      Numerisch. True Time-Weighted Rate of Return (um DCA-Zuflüsse
      bereinigt, annualisiert) als Anteil; verkettete Tagesrenditen wie
      \code{twr_index} (Bewertung zum Zahlungszeitpunkt). Ohne Zuflüsse unverändert
      \eqn{(W_t - W_{t-1}) / W_{t-1}}.
    }
    \item{\code{drawdowns}}{
      Numerischer Vektor. Tägliche Drawdowns vom jeweiligen Höchststand
      als positiver Anteil (\code{0.2} = 20 \% unter dem Höchststand;
      0 = neuer Höchststand). Ohne Einzahlungen auf dem Depotwert, mit
      Einzahlungen auf \code{twr_index} (zeitgewichtet), damit Einzahlungen
      keinen Drawdown verdecken; das gilt ebenso für \code{max_drawdown},
      \code{average_drawdown}, \code{ulcer_index}, \code{longest_drawdown}
      und \code{avg_recovery_time}. Fällt der Index durch eine Tagesrendite
      von -100 \% oder weniger auf 0 oder darunter (Kaufkosten einer großen
      Einzahlung auf ein fast leeres Depot), werden die Drawdowns auf 1
      begrenzt (mit Warnung). Ebenso werden Drawdowns allgemein auf
      [0, 1] begrenzt, wenn der Depotwert negativ wird (Steuerschuld; mit Warnung).
    }
    \item{\code{statistics}}{
      Benannte Liste mit Risiko- und Renditekennzahlen. Grundlage sind die
      Tagesrenditen der echten Handelstage (ohne LOCF-Tage); bei Zuflüssen
      (DCA) die um Zuflüsse bereinigten Renditen (\code{mean}, \code{sd},
      \code{sharpe}, \code{sortino}, \code{omega}, \code{gain_to_pain} usw.).
      Annualisiert wird mit der tatsächlichen Zahl der Beobachtungen je Jahr.
      Mit Einzahlungen verwenden \code{calmar}, \code{serenity} und
      \code{martin_ratio} statt \code{cagr} die zeitgewichtete Jahresrendite
      \code{ttwror}, damit Zähler und (zeitgewichteter) Drawdown-Nenner
      zusammenpassen. Renditen, Drawdowns und Ulcer Index als Anteil:
      \describe{
        \item{\code{mean}}{Mittlere tägliche Rendite (Handelstage).}
        \item{\code{sd}}{Tägliche Portfoliovolatilität (Handelstage).}
        \item{\code{cv}}{Variationskoeffizient \code{|sd / mean|}.}
        \item{\code{risk_free}}{Effektiv genutzte mittlere Risk-Free-Rate (annualisiert, in Prozent).}
        \item{\code{skewness}}{Schiefe der Tagesrenditen.}
        \item{\code{kurtosis}}{Überschuss-Kurtosis der Tagesrenditen.}
        \item{\code{lpm}, \code{hpm}}{Unteres bzw. oberes partielles Moment
          1. Ordnung der Tagesrenditen (Schwelle 0).}
        \item{\code{sharpe}}{Annualisierte Sharpe Ratio auf Überschussrenditen.}
        \item{\code{sortino}}{Annualisierte Sortino Ratio auf Überschussrenditen
          \eqn{e_i}: \eqn{\bar e \cdot P / (D \sqrt{P})} mit \eqn{P}
          Beobachtungen je Jahr und Downside-Abweichung über alle
          Beobachtungen \eqn{D = \sqrt{\mathrm{mean}(\min(e_i, 0)^2)}}
          (Sortino/Price, wie \code{\link{result_analysis}}); \code{NA} ohne
          negative Überschussrendite.}
        \item{\code{calmar}}{Calmar Ratio (CAGR / Max Drawdown; mit Einzahlungen TTWROR / Max Drawdown).}
        \item{\code{omega}}{Omega Ratio (Schwelle 0).}
        \item{\code{gain_to_pain}}{Summe der Renditen / Summe der Verluste (Betrag).}
        \item{\code{serenity}}{CAGR / (Ulcer Index * Max Drawdown); mit Einzahlungen TTWROR im Zähler.}
        \item{\code{martin_ratio}}{CAGR / Ulcer Index; mit Einzahlungen TTWROR / Ulcer Index.}
        \item{\code{max_drawdown}}{Maximaler Drawdown (positiver Anteil).}
        \item{\code{average_drawdown}}{Mittlerer Drawdown über alle Tage unter dem Höchststand.}
        \item{\code{ulcer_index}}{Ulcer Index (Wurzel des mittleren quadrierten Drawdowns).}
        \item{\code{longest_drawdown}}{Längste Phase unter dem Höchststand in Kalendertagen.}
        \item{\code{avg_recovery_time}}{Mittlere Erholungsdauer in Kalendertagen
          (\code{NA}, wenn keine abgeschlossene Erholung).}
      }
    }
    \item{\code{report}}{
      Benannte Liste je Asset mit täglichen Vektoren: \code{worth}
      (Kurswert in EUR), \code{money} (Cash in EUR), \code{flows}
      (DCA-Zufluss des Tages in EUR), \code{total} (\code{worth + money}),
      \code{share} (Ist-Gewicht als Anteil).
    }
    \item{\code{tax_report}}{
      Steuerzusammenfassung (Beträge in EUR): \code{total_taxes_paid}
      (gezahlte Steuern abzüglich Erstattungen; ein Fließkommarest unter 1e-9 EUR
      nach einer Erstattung im Jahresabschluss wird 0),
      \code{loss_carryforward_capital} (§ 20 EStG-Verlustvortrag),
      \code{loss_carryforward_private} (§ 23 EStG-Verlustvortrag),
      \code{sparer_pauschbetrag_annual} (jährlicher Pauschbetrag),
      \code{sparer_pauschbetrag_used} (insgesamt genutzt),
      \code{sparer_pauschbetrag_tax_saved} (genutzter Pauschbetrag mal
      effektivem Steuersatz), \code{open_tax_debt} (am Ende offene, nicht
      gedeckte Steuerschuld: Summe der negativen Geldbestände am letzten Tag,
      wenn eine Steuerzahlung nicht gedeckt werden konnte; sonst 0).
      Nur mit \code{tax = tax_profile()}: \code{next_year}, der Steuerzustand
      des Jahres nach dem letzten Datentag (für eine Fortsetzung, z. B. in
      \code{\link{withdrawal_simulation}}): genau das, was die Engine diesem
      Jahr schon zugerechnet hat; endet die Simulation am 31.12., ist das die
      dort festgesetzte Vorabpauschale (Zufluss im Folgejahr, verrechnet mit
      Verlusttopf und Sparer-Pauschbetrag dieses Jahres; ein Zwangsverkauf für
      ihre Steuer am letzten Tag gehört zum Vorjahr), sonst nichts
      (Verbrauch 0). Liste mit \code{year}, \code{sparer_pauschbetrag_used}
      und \code{sparer_pauschbetrag_remaining} (EUR; mit
      \code{sparer_pauschbetrag = 0} 0), \code{loss_carryforward_capital}
      (§ 20-Verlusttopf danach), \code{loss_carryforward_private}
      (§ 23-Verlustvortrag), \code{capital_income_taxed} (im Jahr mit
      Abgeltungsteuer belastete Bemessungsgrundlage), \code{loss_capital_added},
      \code{loss_capital_used}, \code{loss_capital_start} (im Jahr entstandene
      bzw. genutzte § 20-Verluste, Topf zu Jahresbeginn; Grundlage der
      Jahresend-Erstattung), \code{private_sale_net} (§ 23-Jahressaldo, hier 0);
      mit \code{taxable_income} zusätzlich \code{church_tax_settlement}
      (Kirchensteuer-Bescheid des letzten Jahres, am letzten Tag gezahlt
      (> 0) bzw. erstattet (< 0); Sonderausgabe dieses Jahres) und
      \code{tariff_assessed} (logisch: das Jahr wurde wegen einer
      nachlaufenden Vorabpauschale bereits veranlagt).
      Nur mit \code{taxable_income}: \code{tariff_years}, ein
      \code{data.frame} mit einer Zeile je abgeschlossenem Kalenderjahr (EUR):
      \code{year}, \code{taxable_income} (vorgegebenes zvE \eqn{z_t}),
      \code{church_tax_paid_deductible} (im Jahr gezahlte, abziehbare
      Kirchensteuer aus der Simulation: Nachzahlung aus dem Kirchensteuer-Bescheid
      des Vorjahres und, wenn die Günstigerprüfung günstiger ist, die im Jahr auf
      \eqn{K} einbehaltene Kirchensteuer), \code{church_tax_refunded} (im Jahr
      erstattete Kirchensteuer aus dem Bescheid des Vorjahres),
      \code{church_tax_net_deduction} (Saldo; negativ = Hinzurechnung),
      \code{taxable_income_net} (\eqn{z_t} minus Saldo, Basis der
      Veranlagung), \code{deduction_effect} (Änderung der tariflichen Belastung
      F des übrigen Einkommens durch den Saldo: negativ = Ersparnis),
      \code{gain_p23} (steuerpflichtiger § 23-Gewinn G23 nach Freigrenze und
      Verlustvortrag), \code{income_tax_p23}, \code{soli_p23},
      \code{church_tax_p23}, \code{tax_p23} (§ 23-Anteil: ESt-, Soli-,
      KiSt-Zuwachs und Summe), \code{capital_income} (K), \code{abgeltung_burden}
      (per Saldo auf K erhobene Abgeltungsteuer mit Soli/KiSt),
      \code{church_tax_withheld_k} (darin enthaltene Kirchensteuer),
      \code{tariff_income_tax_k}, \code{tariff_soli_k},
      \code{tariff_church_tax_k}, \code{tariff_burden} (Tarifbelastung von K
      bei Günstigerprüfung; \code{NA} ohne \code{guenstigerpruefung}),
      \code{burden_without_gp}, \code{burden_with_gp} (Gesamtbelastung durch die
      Simulation ohne bzw. mit Günstigerprüfung, siehe Abschnitt
      \dQuote{Einkommensteuertarif}; \code{NA}, wenn keine Prüfung),
      \code{guenstiger} (logisch: Tarif für K günstiger), \code{settlement}
      (Abrechnung des Jahres am Abrechnungstag: positiv Nachzahlung, negativ
      Erstattung), \code{refund} (Erstattung = \eqn{\max(0, -}\code{settlement}\eqn{)}),
      \code{church_tax_settlement_next_year} (Saldo des Kirchensteuer-Bescheids:
      positiv Zahlung, negativ Erstattung im Folgejahr). Die Spalten
      \code{church_tax_deduction} und \code{church_tax_deductible_next_year}
      der vorigen Fassung sind durch \code{church_tax_net_deduction} bzw.
      \code{church_tax_settlement_next_year} ersetzt; \code{refund} enthält jetzt
      die saldierte Erstattung des Jahres (Günstigerprüfung, § 23-Nachzahlung und
      Sonderausgaben-Wirkung zusammen).
    }
    \item{\code{undefined_metrics}}{
      \code{data.frame(metric, reason, detail)} mit einer Zeile je Kennzahl,
      die \code{NA} ist (\code{cagr}, \code{ttwror}, Felder von
      \code{statistics} sowie \code{buys} und \code{sells}, je eine Zeile für
      den ganzen Vektor); 0 Zeilen mit denselben Spalten, wenn alles definiert
      ist. Abgrenzung: Die übrigen Ergebniselemente werden nicht \code{NA}:
      \code{worth}, \code{invested}, \code{report} (\code{share} = 0, wenn der
      Depotwert nicht positiv ist), \code{twr_index} (nicht endliche
      Tagesfaktoren zählen als 1) und \code{drawdowns} (0 ohne positiven
      Höchststand) sind immer endlich. In \code{tax_report$tariff_years} sind
      die Spalten \code{tariff_*} ohne \code{guenstigerpruefung} bewusst
      \code{NA} (nicht gerechnet); sie stehen nicht in
      \code{undefined_metrics}. \code{detail} ist ein deutscher Klartext mit Beträgen, z. B.
      \dQuote{Endwert -800.00 EUR negativ: offene Steuerschuld 800.00 EUR}.
      \code{reason}:
      \describe{
        \item{\code{negative_end_value}}{Endwert negativ (nicht gedeckte
          Steuerschuld): \code{cagr}, \code{ttwror}.}
        \item{\code{no_irr_solution}}{mit Einzahlungen kein interner Zinsfuß
          (z. B. Einzahlung am letzten Tag größer als der Endwert): \code{cagr}.}
        \item{\code{too_short}}{Einzeltag (Laufzeit 0 Jahre: \code{cagr},
          \code{ttwror}, \code{buys}, \code{sells}, \code{avg_recovery_time} und
          alle Renditekennzahlen) bzw. zu wenige Tagesrenditen (Schiefe ab 3,
          Kurtosis ab 4, Sharpe ab 2).}
        \item{\code{zero_start_value}}{Depotwert am Starttag nicht positiv
          (\code{cagr}; wegen \code{start_value > 0} praktisch nicht erreichbar).}
        \item{\code{nonpositive_twr_index}}{zeitgewichteter Wertindex fällt auf 0
          oder darunter (Tagesrendite unter -100 \%): \code{ttwror}.}
        \item{\code{zero_volatility}}{Standardabweichung der Tagesrenditen 0:
          \code{skewness}, \code{kurtosis}, \code{sharpe}.}
        \item{\code{zero_mean_return}}{mittlere Tagesrendite 0: \code{cv}.}
        \item{\code{no_negative_returns}}{keine negativen (Überschuss-)Renditen:
          \code{sortino}, \code{omega}, \code{gain_to_pain}.}
        \item{\code{no_drawdown}}{kein Drawdown: \code{calmar}, \code{serenity},
          \code{martin_ratio}. Ist die Jahresrendite (\code{cagr}, mit
          Einzahlungen \code{ttwror}) nicht definiert, erben diese drei deren
          Ursache.}
        \item{\code{no_recovery}}{keine abgeschlossene Erholung:
          \code{avg_recovery_time}.}
        \item{\code{not_finite}}{Auffangcode für sonstige nicht endliche Werte.}
      }
      \code{print()} und \code{summary()} zeigen eine nicht definierte
      \code{cagr} bzw. \code{ttwror} (und in \code{print()} Schiefe und
      Kurtosis) als \dQuote{nicht definiert (<detail>)} statt \code{NA};
      Kennzahlen, die schon bisher als \dQuote{–} erscheinen, bleiben so.
    }
    \item{\code{open_lots}}{
      Nur mit \code{tax = tax_profile()} gefüllt (sonst \code{NULL}): benannte Liste
      je Asset mit \code{lots} (\code{data.frame} der am letzten Tag gehaltenen
      Lots in FIFO-Reihenfolge: \code{date} Kaufdatum, \code{units}
      verbleibende Stück, \code{price} Anschaffungskurs je Stück wie in der
      FIFO-Gewinnrechnung, d. h. Briefkurs einschließlich anteiliger
      Ordergebühr, nach Splits umgerechnet, \code{vp} bereits versteuerte,
      bei Verkauf nach § 19 InvStG anzurechnende Vorabpauschale dieser Stück in
      EUR), \code{regime} (\code{"investment_fund"}, \code{"capital_gains"}
      oder \code{"private_sale"}), \code{partial_exemption} (Teilfreistellung in
      Prozent), \code{cash} (Geldbestand des Assets am Ende in EUR),
      \code{spread} (voller Bid-Ask-Spread in Prozent wie in
      \code{\link{asset_config}}) und \code{order_fee} (das Argument
      \code{order_fee} wie übergeben, \code{NULL} = keine Ordergebühr), damit
      Verkaufskosten in späteren Rechnungen übernommen werden können.
      Ein Verkauf zum Verkaufskurs \eqn{P} (Kurs mal \eqn{1 -} halber Spread,
      abzüglich Ordergebühr je Stück) verbraucht die Lots in Zeilenreihenfolge;
      aus Lot \eqn{i} werden \eqn{s_i \le units_i} Stück verkauft. Die Engine
      rechnet: Gewinn \eqn{G = \sum_i s_i (P - price_i)}; Fonds
      (\code{investment_fund}): steuerpflichtig
      \eqn{(G - \sum_i vp_i s_i / units_i) (1 - asset\_bonus / 100)}, danach
      Verlusttopf, Sparer-Pauschbetrag und Abgeltungsteuer (§ 20 EStG);
      \code{capital_gains}: steuerpflichtig \eqn{G} (ohne Teilfreistellung und
      Vorabpauschale), weiter wie bei Fonds; \code{private_sale} (§ 23 EStG):
      je Lot \eqn{s_i (P - price_i)}, in den Jahressaldo (Freigrenze,
      Verlustvortrag) nur, wenn der Verkaufstag nicht nach demselben
      Kalendertag des Folgejahres liegt (Kauf am 29.02.: 28.02.), sonst
      steuerfrei (Gewinne und Verluste).
    }
    \item{\code{buys}}{Benannter Vektor. Mittlere Anzahl Käufe je Jahr und Asset
      (Einzeltag, Laufzeit 0 Jahre: \code{NA}, siehe \code{undefined_metrics}).}
    \item{\code{sells}}{Benannter Vektor. Mittlere Anzahl Verkäufe je Jahr und Asset
      (Einzeltag: \code{NA}).}
    \item{\code{fees_paid}}{Nur wenn \code{order_fee} oder \code{dca_fee}
      eine Gebühr ungleich 0 festlegt: Summe der gezahlten Ordergebühren in EUR.}
    \item{\code{harvest_days}}{Nur mit \code{tax_profile(harvest = harvest_rule())}: Date-Vektor
      der Termine der Gewinnrealisierung.}
    \item{\code{wrappers}}{Nur mit \code{details = TRUE} und Fonds-Wrapper-Assets
      (\code{asset_config(wrapper = )}): benannte Liste je Wrapper-Asset mit dem
      \code{SimLevWrapperNav} aus \code{\link{wrapper_nav}} (Anteilswert, Brutto, Gebühren,
      High-Water-Mark, inneres Ergebnis als Attribut \code{inner}). Ohne \code{details}
      gibt es das Feld nicht.}
  }
}
\examples{
set.seed(42)
n <- 756  # 3 Jahre Handelstage
data <- data.frame(
  date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = n),
  MSCI = 100 * cumprod(1 + rnorm(n, 4e-4, 0.012)),
  BOND =  50 * cumprod(1 + rnorm(n, 1e-4, 0.004))
)

strategy <- create_strategy(
  MSCI = asset_config("etf", trading = "bnh",
                      share = 0.7, spread = 0.1, partial_exemption = 30),
  BOND = asset_config("etf", trading = "bnh",
                      share = 0.3, spread = 0.1, partial_exemption = 0)
)

# Einfacher Lauf ohne Steuer
result <- simulation(data, strategy, start_value = 10000)
print(result)

# Mit Besteuerung, jährlichem Rebalancing und Risk-Free-Rate
result_tax <- simulation(data, strategy, start_value = 10000,
                         rebalance = rebalance_plan(unit = "year"),
                         tax = tax_profile(rate = 26.375), liquidate = TRUE, risk_free = 2)
summary(result_tax)
}
\section{Terminverschiebung an aufgefüllten Tagen}{
  Geplante Ereignisse (DCA, periodisches Rebalancing, Splits, Liquidation,
  Asset-Starts), die auf einen per LOCF aufgefüllten Tag (Wochenende/Feiertag)
  fallen, werden automatisch auf den \strong{nächsten echten Handelstag}
  verschoben. Würde die Verschiebung den Monat verlassen (Monatsende), wird
  das Ereignis stattdessen auf den \strong{vorherigen} echten Handelstag
  \strong{vorgezogen}. Die \strong{Festsetzung} der Vorabpauschale bleibt
  kalendarisch am 31.12. (maßgeblich ist der letzte Rücknahmepreis des
  Jahres, per LOCF): je am 31.12. gehaltenem Lot
  \deqn{VP = Bestand \times \max(0, \min(P_{Anfang} \times 0{,}7 \times
  Basiszins, P_{Ende} - P_{Anfang})) \times f}{VP = Bestand x max(0, min(P_Anfang x 0,7 x Basiszins, P_Ende - P_Anfang)) x f}
  mit \eqn{P_{Anfang}}{P_Anfang} = erster im Kalenderjahr festgesetzter Kurs
  (Kurs des ersten nicht aufgefüllten Tages des Jahres bzw. der Simulation;
  § 18 Abs. 1 Satz 3 InvStG: ein aufgefüllter 1.1. trägt nur den
  Vorjahresschluss und zählt nicht), \eqn{P_{Ende}}{P_Ende} = letzter Kurs des
  Jahres und \eqn{f = 1} bei Erwerb vor dem Jahr, sonst
  \eqn{(13 - Erwerbsmonat)/12} (§ 18 Abs. 1-2 InvStG; Ausschüttungen gibt
  es im Modell nicht). Die Lot-Werte mindern später den Veräußerungsgewinn
  (§ 19 InvStG). \strong{Zufluss und Steuer} folgen gemäß § 18 Abs. 3
  InvStG am ersten Handelstag des Folgejahres, nach dem Jahresabschluss und
  vor allen Trades dieses Tages, zu dessen Kursen (Cash-Abzug bzw.
  Zwangsverkauf): Teilfreistellung, Verlusttopf, Sparer-Pauschbetrag und
  Günstigerprüfung des \strong{Zuflussjahres}; die Vorabpauschale ist
  Kapitalertrag dieses Jahres. Hat das Folgejahr in den Daten keinen
  Handelstag (alle Tage aufgefüllt), wird am 1.1. des Folgejahres mit dessen
  Töpfen abgerechnet. Zwangsverkäufe schätzen die Steuer wie der Verkauf
  selbst (§ 19-Anrechnung der Lot-Vorabpauschale, Teilfreistellung,
  Verlusttopf, freier Sparer-Pauschbetrag, effektiver Satz); ebenso
  Umschichtungen (Rebalancing, Asset-Aktivierung), so dass kein Rückkauf
  desselben Assets am selben Tag nötig ist. Am selben Tag wird danach die
  § 23-Steuer des Vorjahres gezahlt. Enthält die Simulation keinen weiteren
  Tag, wird so gerechnet, als begänne das Folgejahr (Jahresabschluss,
  Pauschbetrag voll), und die Steuer am letzten Simulationstag belastet; ein
  Zwangsverkauf dafür findet an diesem Tag statt und gehört mit seinem
  Gewinn (Sparer-Pauschbetrag, Verlusttopf) zum Jahr des letzten Datentags,
  die Vorabpauschale selbst zum Folgejahr (eine Differenz zur endgültigen
  Steuer, z. B. wenn der Verkaufsgewinn den Verlustvortrag mindert, wird
  ausgeglichen). Fließen mehrere Vorabpauschalen am selben Tag zu, werden sie
  gemeinsam mit Verlusttopf und Sparer-Pauschbetrag verrechnet; Steuer und
  Pauschbetrag werden anteilig nach der Vorabpauschale nach
  Teilfreistellung auf die Assets verteilt (unabhängig von ihrer
  Reihenfolge in \code{strategy}). Eine
  § 20-Erstattung aus diesem letzten Jahresabschluss (Verlust nach versteuerten
  Gewinnen im selben Jahr) wird dem Cash gutgeschrieben und ist im Endwert
  enthalten, auch ohne offene Vorabpauschale oder § 23-Steuer. Die
  Vorabpauschale wird wie in der Bankpraxis mit dem allgemeinen
  § 20-Verlusttopf verrechnet (vor dem Sparer-Pauschbetrag); die
  T-2-Jahresenderstattung erfasst damit auch VP-Steuer bei später im
  Zuflussjahr realisierten Verlusten.
}
\section{Einkommensteuertarif (taxable_income)}{
  Mit \code{tax_profile(income = income_tariff(taxable_income))} (zvE \eqn{z_t} des Jahres \eqn{t} ohne die
  Erträge der Simulation) rechnet die Engine mit dem Tarif der Datei
  \code{tax_tariff} (\code{\link{tax_tariff}}). Rechtsgrundlagen
  (Fassung ab VZ 2026, mitgelieferte Datei):
  \itemize{
    \item § 32a Abs. 1 EStG: zvE auf volle Euro abrunden; bis 12 348 EUR: 0;
      12 349 bis 17 799: (914,51 y + 1400) y; 17 800 bis 69 878:
      (173,10 z + 2397) z + 1034,87; 69 879 bis 277 825:
      0,42 x - 11 135,63; ab 277 826: 0,45 x - 19 470,38
      mit y = (x - 12 348) / 10 000, z = (x - 17 799) / 10 000;
      Steuerbetrag auf volle Euro abrunden (\eqn{T(x)}). Nur Einzelveranlagung
      (Grundtarif), kein Splitting.
    \item §§ 3 Abs. 3, 4 SolZG: Soli 5,5 \% der Einkommensteuer, nur wenn diese
      20 350 EUR übersteigt (Freigrenze, Einzelveranlagung), höchstens 11,9 \%
      des Mehrbetrags (Milderungszone); Bruchteile eines Cents bleiben außer
      Ansatz (\eqn{S(E)}). Auf die Abgeltungsteuer weiterhin 5,5 \% (in
      \code{tax_profile(rate)}).
    \item Veranlagung je Jahr: tarifliche Belastung
      \eqn{F(x) = T(x) + S(T(x)) + k T(x)} (\eqn{k} = \code{church_tax} / 100,
      Kirchensteuer nicht gerundet). Die Simulation trägt den Unterschied zur
      Belastung des vorgegebenen zvE ohne Simulation, F(...) - \eqn{F(z_t)};
      damit gehört auch die Wirkung ihrer Kirchensteuer-Sonderausgaben auf das
      übrige Einkommen zur Simulation.
    \item § 23 EStG: steuerpflichtiger Gewinn \eqn{G23} (nach Freigrenze und
      Verlustvortrag) erhöht das zvE: ohne Günstigerprüfung
      \eqn{X_0 = F(z_t - N_t + G23) - F(z_t) + A_t} mit \eqn{A_t} =
      Abgeltungsbelastung auf \eqn{K} (siehe unten) und \eqn{N_t} = Saldo der im
      Jahr gezahlten/erstatteten Kirchensteuer aus dem Vorjahresbescheid.
    \item § 32d Abs. 6 Satz 1 EStG (\code{tax_profile(guenstigerpruefung = TRUE)}):
      unterjährig wird die Abgeltungsteuer wie bei einer Bank einbehalten
      (auch die Steuerschätzung beim Umschichten rechnet mit
      \code{tax_profile(rate)}). Im Jahresabschluss ist \eqn{K} die Bemessungsgrundlage,
      auf die im Jahr per Saldo Abgeltungsteuer erhoben wurde (Kapitaleinkünfte
      nach § 20 nach Teilfreistellung, Vorabpauschale des Zuflussjahres,
      Verlustverrechnung und Sparer-Pauschbetrag), \eqn{A_t} = \eqn{K} mal
      \code{tax_profile(rate)} die darauf einbehaltene Abgeltungsteuer mit Soli und
      Kirchensteuer, darin die Kirchensteuer \eqn{C_t} = K x 0,25 / (1 +
      0,25 k) x k. Verglichen wird die Gesamtbelastung: mit
      Günstigerprüfung \eqn{X_1 = F(z_t - N_t - C_t + G23 + K) - F(z_t)}
      (die einbehaltene Kirchensteuer \eqn{C_t} ist dann im Jahr der Zahlung
      Sonderausgabe), ohne \eqn{X_0} wie oben. Günstiger, wenn \eqn{X_1 < X_0}.
      Abrechnung am Abrechnungstag des Folgejahres (wie die übrigen
      Jahresabschluss-Buchungen; ohne weiteren Tag am letzten Simulationstag):
      \code{settlement} \eqn{= X - A_t} mit \eqn{X = X_1} bzw. \eqn{X_0};
      positiv als Nachzahlung aus dem Depot (wie die § 23-Steuer), negativ als
      Erstattung in den Geldbestand; in \code{total_taxes_paid} saldiert.
      \eqn{K \le 0}: keine Prüfung (Verluste aus Kapitalvermögen sind nicht mit
      anderen Einkünften verrechenbar).
    \item Kirchensteuer als Sonderausgabe (§ 10 Abs. 1 Nr. 4, § 11 EStG:
      Jahr der Zahlung): Der Kirchensteuer-Bescheid eines Jahres (Kirchensteuer
      auf den ESt-Unterschied abzüglich der angerechneten \eqn{C_t}, wenn die
      Günstigerprüfung günstiger ist) wird am Abrechnungstag im Folgejahr
      gezahlt (Sonderausgabe des Folgejahres) bzw. erstattet. Erstattungen
      werden mit den im Erstattungsjahr gezahlten Kirchensteuern aus der
      Simulation verrechnet (einschließlich \eqn{C} dieses Jahres bei
      Günstigerprüfung); ein Überhang wird dem Einkommen hinzugerechnet
      (§ 10 Abs. 4b Satz 2 und 3 EStG): \eqn{N_t} = gezahlt minus erstattet.
      Die Kirchensteuer als Zuschlag zur Kapitalertragsteuer ist nach § 10
      Abs. 1 Nr. 4, 2. Halbsatz nicht abziehbar; dass der Abzug erhalten
      bleibt, wenn die Kapitalerträge per Günstigerprüfung tariflich besteuert
      werden, beruht auf der Darstellung der Rechtslage in der Fachliteratur
      (Haufe), nicht auf einem Urteil. Die Kirchensteuer auf die § 23-ESt eines
      Jahres wird erst mit ihrer Zahlung im Folgejahr abgezogen; im selben Jahr
      wirkt nur die Kirchensteuer aus dem Vorjahresbescheid und (bei
      Günstigerprüfung) \eqn{C_t}.
  }
  Vereinfachungen: Die Datei gilt für alle Simulationsjahre (aktuelle
  Rechtslage auf alle Jahre projiziert, wie im übrigen Paket). Die
  Kirchensteuer wird nicht gerundet (Landesrecht unterschiedlich);
  Kinderfreibeträge für ihre Bemessungsgrundlage (§ 51a EStG) bildet das
  Modell nicht ab. Je Jahr gibt es einen Kirchensteuer-Bescheid; Nachzahlung
  und Erstattung daraus werden saldiert. Vorauszahlungen und ein
  Verlustrücktrag (§ 10d EStG) kommen im Modell nicht vor. Das Jahr nach dem
  letzten Simulationsjahr wird nicht veranlagt: Zahlungen und Erstattungen
  aus dem letzten Bescheid (am letzten Simulationstag) wirken sich nicht mehr
  als Sonderausgabe aus. Ausnahme: Fließt nach dem letzten Jahresabschluss
  noch eine Vorabpauschale zu (Simulation endet am 31.12.), wird dieses
  Folgejahr mit Günstigerprüfung veranlagt, wenn \code{taxable_income} dafür
  einen Wert hat (eine Zahl für alle Jahre oder das Jahr angegeben). Ein Grenzsteuersatz (\code{income_rate()}) schließt diesen Weg aus. Ohne \code{taxable_income} bleibt alles unverändert.
  Die Jahreswerte stehen in \code{tax_report$tariff_years}; \code{details =
  TRUE} gibt die Tarifrechnung je Jahr aus.
}
\section{print und summary}{
  \code{summary()} liefert unter anderem \code{total_return_twr}
  (zeitgewichtete Gesamtrendite: mit Einzahlungen letzter Wert von
  \code{twr_index} minus 1, sonst Endwert / Depotwert am Starttag - 1),
  \code{return_on_invested} = (Endwert - Eingezahlt) / Eingezahlt mit
  Eingezahlt = letzter Wert von \code{invested} (brutto) und
  \code{total_return} als gleichwertigen Alias für \code{total_return_twr}
  (ältere Skripte). Mit Einzahlungen zeigt die Ausgabe beide Werte
  (\dQuote{Gesamtrendite (zeitgewichtet)} und \dQuote{Gewinn je eingezahltem
  EUR} mit Endwert und Eingezahlt); ohne Einzahlungen ist die Ausgabe
  unverändert. Nicht definierte Kennzahlen erscheinen als
  \dQuote{nicht definiert (Ursache)} (siehe \code{undefined_metrics}); eine
  offene Steuerschuld zeigt \code{print()} im Steuerteil.
}
\section{Signalbewusstes Rebalancing (Cash-Reserve-Modell)}{
  Die Rebalancing-Prozedur prüft die Signallogik eigenständig; der reguläre
  Signal-Trade-Block läuft an Rebalancing-Tagen nicht (keine Doppelorders).
  Signal-aktive und signal-inaktive Assets werden nach ihrem
  \strong{Zielgewicht gleichbehandelt}: Ein signalbedingt nicht investiertes (aber aktiviertes) Signal-Asset hält sein
  Zielgewicht als \strong{eigene Cash-Position} (jedes Asset besitzt ein
  eigenes Cash-Konto). Da Ist-Gewichte total-basiert sind (Kurswert + Cash),
  zählt die Reserve als Positionsgewicht; das Rebalancing gleicht sie über
  reine \strong{Cash-Transfers} mit dem Pool aus — der Pool wird also genau
  um den Betrag der inaktiven Assets reduziert, bevor der Rest investiert
  wird. Für Signal-Assets gilt am Rebalancing-Tag:
  \itemize{
    \item Position vorhanden + Verkaufssignal: vollständiger Signal-Exit;
      der Erlös wird zur Cash-Reserve des Assets.
    \item Keine Position + Kaufsignal: Signal-Entry aus der eigenen
      Cash-Reserve; danach normale Teilnahme am Gewichts-Rebalancing.
    \item Keine Position + kein Kaufsignal: die Cash-Reserve wird auf das
      Zielgewicht getrimmt (Auffüllen aus dem Pool bzw. Abschöpfen in den
      Pool), es findet aber \strong{kein Aktienkauf} statt.
    \item Andernfalls nimmt das Asset normal am Gewichts-Rebalancing teil.
  }
  Verbleibendes Cash der übrigen Assets (z. B. DCA-Zuflüsse am selben Tag)
  wird noch am Rebalancing-Tag reinvestiert; die Cash-Reserven signalbedingt wartender
  Signal-Assets bleiben davon unberührt.

  Außerhalb von Rebalancing-Tagen gilt (unabhängig von \code{rebalance}):
  Ein Signal-Asset mit offener Position legt neues Geld (Sparraten, Restcash,
  Umverteilungen, Erstattungen) sofort an wie Buy-and-Hold, außer am Tag
  eines Verkaufssignals; das Signal steuert nur Ein- und Ausstieg. Ohne
  Bestand wartet das Geld als Cash auf das Kaufsignal.
}
\section{Fonds-Wrapper}{
  Ein Asset mit \code{asset_config(wrapper = \link{wrapper_config}(...))} ist ein Zertifikat
  bzw. Fonds über eine innere Strategie. Vor der Engine rechnet \code{simulation()} je
  Wrapper-Asset den Anteilswert mit \code{\link{wrapper_nav}} aus den inneren Spalten von
  \code{data} und hängt ihn als Kursspalte mit dem Asset-Namen an (vor dem Beginn und an
  Tagen ohne inneren Kurs \code{NA}). Danach ist das Asset ein gewöhnliches Asset ohne
  \code{wrapper}: Spread, Order- und Sparplangebühren, Steuern (nach \code{asset_class}
  bzw. \code{tax_regime}: Zertifikat = Kapitalforderung, \code{tax_regime =
  "investment_fund"} mit Teilfreistellung und Vorabpauschale), Kirchensteuer, Pauschbetrag,
  Verlusttöpfe, \code{harvest} und \code{open_lots} gelten wie für jedes Einzelpapier.
  \itemize{
    \item Der Asset-Name ist keine Kursspalte; eine Spalte gleichen Namens in \code{data}
      ist ein Fehler. Gebraucht werden die Kursspalten (und Signal- bzw. Ereignisspalten)
      der inneren Strategie.
    \item \code{splits} gelten für die inneren Spalten; der Anteilswert selbst splittet nicht.
    \item Beginnen die inneren Kurse nach dem ersten Tag von \code{data}, beginnt der
      Anteilswert später; das Asset wird dann wie jedes später startende Asset behandelt
      (Hinweis \dQuote{hat erst ab ... Kurse}). Ist der Wrapper das einzige Asset, ist das
      der Fehler \dQuote{In der ersten Zeile von 'data' fehlen alle Kurse}.
    \item Meldungen der inneren Rechnung erscheinen als \dQuote{Hinweis: Wrapper '<Name>'
      (innere Rechnung): ...}, Warnungen und Fehler als \dQuote{simulation: Wrapper
      '<Name>' (innere Rechnung): ...}.
    \item Wrapper-Assets handeln nur mit \code{trading = "bnh"} (Signale gehen in der
      inneren Strategie).
    \item Aufrufer mit vielen Läufen (\code{\link{bootstrap_study}},
      \code{\link{param_search}}, \code{\link{sensitivity_grid}},
      \code{\link{planning_lumpsum_vs_dca}} u. a.) rechnen den Anteilswert je Lauf neu;
      Bootstrap-Pfade ziehen die inneren Spalten.
  }
  Mit \code{details = TRUE} enthält das Ergebnis \code{wrappers} (siehe oben).
}
\section{Ereignisbasiertes Rebalancing}{
  Zusammenspiel der Argumente von \code{\link{rebalance_plan}}:
  \describe{
    \item{\code{event_col}}{
      Character oder \code{NULL}. Name einer logischen Spalte in \code{data},
      die ereignisbasiertes Rebalancing auslöst (\code{TRUE} = Rebalancing-Tag).
      Erzeugt mit \code{\link{rebalance_trigger}}.
    }
    \item{\code{event_mode}}{
      \code{"additional"} (zusätzlich zu periodischem Rebalancing) oder
      \code{"replace"} (ersetzt periodisches Rebalancing).
    }
    \item{\code{event_weight}}{
      Benannter Vektor/Liste oder \code{NULL}: je Asset der Name einer Spalte
      mit dem Zielgewicht an Event-Tagen (siehe \code{\link{rebalance_plan}}).
    }
  }
}
\seealso{
  \code{\link{sim_blocks}} (Bausteine), \code{\link{asset_config}}, \code{\link{create_strategy}},
  \code{\link{rebalance_trigger}}, \code{\link{plot.SimLevResult}},
  \code{\link{tax_tariff}}, \code{\link{wrapper_config}}; Weiterverarbeitung des Ergebnisses mit
  \code{\link{result_analysis}} und \code{\link{withdrawal_paths}}
}
