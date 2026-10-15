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
  start_value    = 10000,
  spread         = NULL,
  details        = FALSE,
  liquidate      = FALSE,
  dca_mode       = FALSE,
  dca_value      = NULL,
  dca_span       = NULL,
  dca_days       = NULL,
  dca_unit       = c("month", "quarter", "year"),
  dca_anchor     = c("start", "end"),
  dca_start      = NULL,
  dca_skip       = FALSE,
  balance_mode   = FALSE,
  balance_span   = NULL,
  balance_days   = NULL,
  balance_unit   = c("month", "quarter", "year"),
  balance_anchor = c("start", "end"),
  balance_start  = NULL,
  balance_skip   = FALSE,
  balance_dca    = FALSE,
  balance_thresh = NULL,
  balance_thresh_type = c("absolute", "relative"),
  tax_mode       = c("none", "person", "funds"),
  tax_rate       = 26.375,
  marginal_tax_rate          = NULL,
  use_guenstigerpruefung     = FALSE,
  private_sale_threshold     = 1000,
  sparer_pauschbetrag        = 1000,
  use_sparer_pauschbetrag    = TRUE,
  include_soli_on_income_tax = FALSE,
  soli_rate_income_tax       = 5.5,
  base_rate      = NULL,
  base_rate_flex = FALSE,
  base_rate_data = NULL,
  funds_fee      = 0.95,
  bonus_fee      = 5,
  fractions      = TRUE,
  risk_free      = 0,
  split_mode     = FALSE,
  split_thresh   = NULL,
  event_col      = NULL,
  event_mode     = c("additional", "replace"),
  event_weight   = NULL,
  church_tax     = 0,
  order_fee      = NULL,
  dca_fee        = NULL,
  harvest_mode   = FALSE,
  harvest_day    = "12-15",
  harvest_loss_pot = TRUE,
  taxable_income = NULL,
  tax_tariff     = NULL
)
}
\arguments{
  \item{data}{
    \code{data.frame} mit täglichen Marktdaten. Pflichtfelder: \code{date}
    (Klasse \code{Date}, aufsteigend) und je eine Kursspalte pro Asset (Niveaus,
    keine Renditen; Name muss mit dem Asset-Namen in \code{strategy}
    übereinstimmen). Optionale Spalten: Basiszins in Prozent (Name in
    \code{base_rate_data}), logische Signalspalten (für
    \code{action_type = "signal"}), Risk-Free-Reihe in Prozent p.a. (Name in
    \code{risk_free}), logische Trigger- und numerische Gewichtsspalten für
    \code{event_col}/\code{event_weight}.
    Fehlende Kalendertage werden automatisch per LOCF aufgefüllt (logische
    Spalten mit \code{FALSE}); aufgefüllte Tage werden in \code{filled}
    markiert und aus Risikometriken ausgeschlossen. Trägt \code{data} das
    Attribut \code{filled} aus \code{\link{align_series}}, gelten Tage, an
    denen keines der Strategie-Assets einen echten Kurs hat, ebenso als
    aufgefüllt (kein Handel, nicht in den Risikometriken). Passt die
    Zeilenzahl des Attributs nicht zu \code{data} (z. B. nach einer
    Zeilenauswahl der \code{align_series()}-Ausgabe), wird es mit Warnung
    ignoriert; den Zeitraum daher mit \code{align_series(..., start =, end =)}
    wählen.

    Eingabeprüfung: \code{date} als Text im Format \code{"JJJJ-MM-TT"} (oder
    Faktor) wird mit Hinweis in \code{Date} umgewandelt; unsortierte Zeilen
    werden mit Hinweis aufsteigend sortiert; doppelte Daten und doppelte
    Spaltennamen führen zu einem Fehler. Kurse müssen positiv sein (\code{<= 0} oder unendlich: Fehler).
    Einzelne fehlende Kurse (\code{NA}) werden mit Hinweis per LOCF gefüllt;
    sind in einer Zeile alle Kurse \code{NA}, gilt der Tag als aufgefüllt.
    Hat ein Asset erst ab einem späteren Tag Kurse (führende \code{NA}, etwa
    aus \code{align_series(range = "all")}), wird es wie mit
    \code{asset_start} = erster Kurstag behandelt. Mindestens ein Asset muss
    am ersten Tag handelbar sein. Andere data.frame-Klassen (z. B. tibble)
    werden in einen \code{data.frame} umgewandelt.
  }
  \item{strategy}{
    Benannte Liste von Asset-Konfigurationen, idealerweise erzeugt mit
    \code{\link{create_strategy}} und \code{\link{asset_config}}. Direkte
    Listen-Übergabe ist ebenfalls möglich (Backward-Kompatibilität).
    Die Zielgewichte \code{asset_share} (Anteile, 0--1) müssen sich auf
    exakt 1 summieren (Toleranz 1e-6); sie werden nicht normiert, sonst
    bricht die Funktion mit Fehler ab. Asset-Namen müssen eindeutig sein.
    Assets mit späterem \code{asset_start} erhalten ab dem Start ihr volles
    Zielgewicht (das Startkapital verteilt sich bis dahin auf die übrigen
    Assets); am Starttag wird immer auf die Zielgewichte umgeschichtet
    (Verkauf der übrigen Assets, Kauf des neuen; mit Steuern, Spreads und
    Gebühren wie bei jedem Rebalancing), auch ohne \code{balance_mode}; ein
    zusätzlicher Handelsblock (z. B. Kauf aus einer Sparrate vor der
    Umschichtung) läuft an diesem Tag nicht. Mit
    \code{balance_mode = TRUE} gilt danach der normale Rhythmus. Liegt
    \code{asset_start} nach dem letzten Datentag, bricht die Funktion mit
    Fehler ab (das Asset wäre nie handelbar).
  }
  \item{start_value}{
    Numerisch. Anfangskapital in EUR. Standard: \code{10000}.
  }
  \item{tax_mode}{
    Besteuerungsmodus: \code{"none"} (keine Steuer), \code{"person"}
    (persönliche Steuer nach §§ 18–20 InvStG und § 23 EStG) oder
    \code{"funds"} (pauschale Fondsbesteuerung: jährliche Kosten
    \code{funds_fee}/\code{bonus_fee} am 31.12. und anteilig am letzten
    Simulationstag; bei \code{liquidate = TRUE} Steuer \code{tax_rate} auf
    den Gesamtgewinn = Endwert minus \code{start_value} minus Sparplan-
    Einzahlungen, unabhängig vom Datum des letzten Tages; sie wird in
    \code{tax_report$total_taxes_paid} ausgewiesen). Standard: \code{"none"}.
  }
  \item{tax_rate}{
    Numerisch. Kapitalertragsteuersatz inkl. Solidaritätszuschlag
    \strong{in Prozent} (z. B. \code{26.375} = 25 \% KapESt + 5,5 \% Soli),
    zulässig 0 bis 100. Werte zwischen 0 und 1 (vermutlich ein Anteil, z. B.
    \code{0.26375}) werden mit Warnung als Prozent gelesen. Wird bei
    \code{church_tax > 0} überschrieben. Standard: \code{26.375}.
  }
  \item{marginal_tax_rate}{
    Numerisch oder \code{NULL}. Persönlicher Grenzsteuersatz für § 23 EStG
    und die Günstigerprüfung \strong{in Prozent} (z. B. \code{42} = 42 \%),
    zulässig 0 bis 50. Nur relevant bei \code{tax_mode = "person"}.
    \code{NULL} (Standard): Sind \code{"private_sale"}-Assets vorhanden, wird
    bei \code{tax_mode = "person"} gewarnt; sind § 23-Gewinne steuerpflichtig (Freigrenze erreicht), werden 42 \% angesetzt.
    Mit \code{taxable_income} wirkt \code{marginal_tax_rate} nicht (Warnung,
    wenn angegeben); dann gilt der Tarif aus \code{tax_tariff}.
    Die § 23-Steuer (Satz mal (1 + Soli-Satz + Kirchensteuersatz), siehe
    \code{include_soli_on_income_tax} und \code{church_tax}) entsteht mit dem
    Jahresabschluss und wird am Abrechnungstag der Vorabpauschale (erster
    Handelstag des Folgejahres, ohne Handelstag im Folgejahr der 1.1.; ohne
    weiteren Tag der letzte Simulationstag) aus dem Depot gezahlt: aus dem
    Cash der Assets mit steuerpflichtigem Jahressaldo, sonst per Zwangsverkauf
    wie bei der Vorabpauschale.
    Eine einzelne Zahl (sonst Fehler); Werte zwischen 0 und 1 (vermutlich Anteil) werden mit Warnung als Prozent gelesen.
  }
  \item{use_guenstigerpruefung}{
    Logisch. Günstigerprüfung nach § 32d Abs. 6 EStG anwenden? Bei
    \code{TRUE} wird statt \code{tax_rate} der persönliche Satz
    (ggf. mit Soli, siehe \code{include_soli_on_income_tax}, und
    Kirchensteuer, siehe \code{church_tax}) für § 20-Erträge und die
    Vorabpauschale verwendet, wenn die Belastung einschließlich
    Zuschlagsteuern niedriger ist (§ 32d Abs. 6 Satz 1 EStG):
    \code{marginal_tax_rate} x (1 + Soli-Satz + Kirchensteuersatz) kleiner
    als der effektive Abgeltungsteuersatz (\code{tax_rate}, bei
    \code{church_tax > 0} nach § 32d Abs. 1). Es gibt keine starre
    25-\%-Schwelle; z. B. 24,9 \% mit Soli und 9 \% KiSt (28,51 \%)
    bleibt bei der Abgeltungsteuer (27,99 \%). Derselbe Satz gilt für die
    Steuerschätzung von Verkäufen. Mit \code{taxable_income} wird stattdessen
    unterjährig die Abgeltungsteuer einbehalten (auch in der Steuerschätzung
    von Verkäufen) und im Jahresabschluss mit dem Tarif verglichen (Abschnitt
    \dQuote{Einkommensteuertarif}); die Differenz wird erstattet.
    Standard: \code{FALSE}.
    Nur \code{TRUE} oder \code{FALSE} (sonst Fehler).
  }
  \item{sparer_pauschbetrag}{
    Numerisch. Jährlicher Sparer-Pauschbetrag in EUR (Freibetrag; \code{2000}
    bei Zusammenveranlagung). Genutzt wird höchstens der positive Jahressaldo
    der Kapitalerträge nach Verlustverrechnung (§ 20 Abs. 9 Satz 4, § 43a
    Abs. 3 EStG): Ein späterer Verlust im selben Jahr erstattet zuerst die
    Steuer auf versteuerte Erträge, gibt dann den genutzten Pauschbetrag frei,
    erst der Rest geht in den Verlustvortrag (Abrechnung zum Jahreswechsel).
    Verrechnet wird wie bei Banken Verlusttopf vor Pauschbetrag; ein
    Verlustvortrag aus dem Vorjahr bleibt genutzt, soweit der Jahressaldo
    reicht. Je Jahr gilt mit Erträgen \eqn{E} (einschließlich
    Vorabpauschale des Zuflussjahres), Verlusten \eqn{L} des Jahres und
    Vortrag \eqn{V} zu Jahresbeginn: genutzter Vortrag
    \eqn{V_g = \min(V, \max(0, E - L))}, genutzter Pauschbetrag
    \eqn{P_g = \min(SPB, \max(0, E - L - V_g))}, versteuert
    \eqn{\max(0, E - L - V_g - P_g)}. Beispiel: Vortrag 1000, Gewinn 3000,
    danach Verlust 500 ergibt 500 versteuert (Erstattung der Steuer auf 500)
    und Verlusttopf 0.
    Standard: \code{1000}.
    Eine einzelne endliche Zahl \code{>= 0} (sonst Fehler).
  }
  \item{use_sparer_pauschbetrag}{
    Logisch. Sparer-Pauschbetrag anwenden? Standard: \code{TRUE}.
    Nur \code{TRUE} oder \code{FALSE} (sonst Fehler).
  }
  \item{private_sale_threshold}{
    Numerisch. Jährliche Freigrenze nach § 23 Abs. 3 Satz 5 EStG in EUR, für
    alle Jahre gleich (aktuelle Rechtslage). Geprüft wird der Jahressaldo
    \eqn{s} (Gewinne minus Verluste des Jahres): \eqn{s < 0} geht in den
    Verlustvortrag; \eqn{0 \le s <} Freigrenze ist steuerfrei, der Vortrag
    bleibt unverändert; ab Erreichen der Freigrenze (genau 1000 ist
    steuerpflichtig) ist \eqn{s} abzüglich Verlustvortrag steuerpflichtig,
    auch wenn der Rest danach unter der Freigrenze liegt (BFH IX R 27/04).
    Haltefrist kalendergenau; bei Kauf am 29.02. endet sie am 28.02. des
    Folgejahres (§ 188 Abs. 3 BGB). Standard: \code{1000}.
    Eine einzelne endliche Zahl \code{>= 0} (sonst Fehler, auch bei Text wie \code{"1000"}).
  }
  \item{include_soli_on_income_tax}{
    Logisch. Solidaritätszuschlag auf Einkommensteuer (§ 23-Pfad) erheben?
    Mit \code{taxable_income} ohne Wirkung (der Soli folgt dann exakt der
    Tarifdatei mit Freigrenze und Milderungszone; Warnung, wenn angegeben).
    Standard: \code{FALSE}.
    Nur \code{TRUE} oder \code{FALSE} (sonst Fehler).
  }
  \item{soli_rate_income_tax}{
    Numerisch. Soli-Satz \strong{in Prozent} (\code{5.5} = 5,5 \%).
    Mit \code{taxable_income} ohne Wirkung (Warnung, wenn angegeben).
    Standard: \code{5.5}.
  }
  \item{taxable_income}{
    \code{NULL} (Standard), eine Zahl, ein nach Kalenderjahren benannter
    Zahlenvektor (z. B. \code{c("2024" = 50000, "2025" = 52000)}) oder ein
    \code{data.frame} mit den Spalten \code{year} und \code{taxable_income}
    (oder genau zwei Spalten Jahr, Betrag). Zu versteuerndes Einkommen (zvE) in
    EUR je Kalenderjahr \strong{ohne} die Kapitalerträge und § 23-Gewinne
    dieser Simulation; eine Zahl gilt für alle Jahre. Fehlt ein
    Kalenderjahr der Simulation, bricht die Funktion mit Fehler ab; nicht
    endliche Werte, unbenannte Vektoren mit mehreren Werten und Namen, die keine
    Jahre sind, ebenso. Wirkt nur mit \code{tax_mode = "person"} (sonst
    Warnung). Mit Angabe rechnet die Engine mit dem Einkommensteuertarif aus
    \code{tax_tariff} (Abschnitt \dQuote{Einkommensteuertarif}); ohne Angabe
    bleibt alles wie bisher (\code{marginal_tax_rate}).
  }
  \item{tax_tariff}{
    \code{NULL} (Standard: mitgelieferte Datei
    \code{system.file("extdata", "steuertarif.csv", package = "SimLev")},
    Rechtslage ab VZ 2026), ein Dateipfad oder ein Objekt aus
    \code{\link{read_tax_tariff}}. Künftige Tarife werden durch Austausch der
    Datei bzw. Angabe einer eigenen Datei übernommen. Nur mit
    \code{taxable_income} wirksam (sonst Warnung).
  }
  \item{base_rate}{
    Numerisch oder \code{NULL}. Fester jährlicher Basiszins für die
    Vorabpauschale \strong{in Prozent} (z. B. \code{2.55} = 2,55 \%).
    Wird durch \code{base_rate_flex} übersteuert. \code{NULL} (Standard) =
    Basiszins 0, also keine Vorabpauschale.
    Eine einzelne endliche Zahl oder \code{NULL} (Vektor, Text, \code{NA}: Fehler; negativ erlaubt und wie 0 behandelt); Werte zwischen 0 und 0,05 (vermutlich Anteil, z. B. \code{0.0229}) werden mit Warnung als Prozent gelesen (historische Basiszinsen unter 1 \%, z. B. 0,07 \% für 2020, warnen nicht).
  }
  \item{base_rate_flex}{
    Logisch. Dynamischen Basiszins aus einer Datenspalte verwenden?
    Standard: \code{FALSE}.
  }
  \item{base_rate_data}{
    Character oder \code{NULL}. Name der Spalte in \code{data} mit täglichen
    Basiszinswerten (annualisiert, \strong{in Prozent}; \code{NA} wird zu 0,
    unabhängig von der Datenform: auch bei Handelstagsdaten, deren fehlende
    Kalendertage per LOCF aufgefüllt werden, wird ein \code{NA} nicht mit dem
    Vortageswert gefüllt).
    Für die Vorabpauschale eines Jahres zählt der Wert vom ersten Handelstag
    des Jahres (§ 18 Abs. 4 InvStG), nicht der vom 31.12.
    Pflicht bei \code{base_rate_flex = TRUE}, sonst Fehler.
    Liegt der Median der Spalte (ohne \code{NA} und 0) über 0 und unter
    0,05 (vermutlich Anteile), wird wie bei \code{base_rate} gewarnt und in
    Prozent gelesen.
    Standard: \code{NULL}.
  }
  \item{dca_mode}{
    Logisch. DCA-Sparplan aktivieren? Standard: \code{FALSE}.
  }
  \item{dca_value}{
    Numerisch oder \code{NULL}. Betrag pro DCA-Einzahlung in EUR; Pflicht
    bei \code{dca_mode = TRUE}: eine einzelne endliche Zahl \code{> 0}
    (Vektor, \code{NA} oder Text: Fehler). Standard: \code{NULL}.
    Ohne \code{dca_mode = TRUE} wirkungslos (Warnung).
  }
  \item{dca_span}{
    Numerisch oder \code{NULL}. Abstand zwischen Einzahlungen in Perioden
    von \code{dca_unit} (z. B. \code{3} mit \code{"month"} = alle drei
    Monate); Pflicht bei \code{dca_mode = TRUE}: eine einzelne ganze Zahl
    \code{>= 1} (sonst Fehler).
    Standard: \code{NULL}.
  }
  \item{dca_unit}{
    Character. Einheit des DCA-Abstands: \code{"month"} (Standard),
    \code{"quarter"} oder \code{"year"}. Perioden beginnen am Monatsersten
    des Startmonats (\code{dca_start} bzw. erster Datentag), bei
    \code{"year"} am 1. Januar; Quartale sind daher nicht zwingend
    Kalenderquartale.
  }
  \item{dca_days}{
    Integer-Vektor oder \code{NULL}. Tag(e) innerhalb jeder Periode (1--31):
    bei \code{"month"} Tag des Monats, bei \code{"quarter"} Tag im ersten
    Monat der Periode, bei \code{"year"} Tag im Januar; mit
    \code{dca_anchor = "end"} rückwärts vom Periodenende gezählt
    (1 = letzter Tag). Nicht existierende Tage entfallen (z. B. Tag 31 im
    April, bei \code{"end"} Tag 31 vom Ende im Februar). Werte außerhalb von
    1--31 oder nicht ganzzahlig: Fehler; doppelte Tage ergeben nur einen
    Termin (Warnung). Fallen bei Handelstagsdaten mehrere
    Termine auf denselben Handelstag (Verschiebung von Wochenenden), wird je
    Termin eine Rate eingezahlt.
    \code{NULL} (Standard) = erster Tag der Periode.
  }
  \item{dca_anchor}{
    Character. Bezugspunkt für \code{dca_days}: \code{"start"} (Standard,
    ab Periodenbeginn) oder \code{"end"} (ab Periodenende). Ohne
    \code{dca_days} wirkungslos.
  }
  \item{balance_mode}{
    Logisch. Periodisches Rebalancing aktivieren? Mit \code{TRUE} wird am
    ersten Simulationstag (und am Starttag später startender Assets) nur
    über das Rebalancing gekauft (Erstkauf nach Zielgewichten); ein
    zusätzlicher Handelsblock mit anschließender Umschichtung von Resten
    (Zusatzorders, Spread, Gebühren) entfällt. Standard: \code{FALSE}.
  }
  \item{balance_span}{
    Numerisch oder \code{NULL}. Rebalancing-Intervall in Perioden von
    \code{balance_unit}. Standard: \code{NULL} (= 1).
  }
  \item{balance_unit}{
    Character. Einheit des Rebalancing-Intervalls: \code{"month"}
    (Standard), \code{"quarter"} oder \code{"year"}; Periodenlogik wie bei
    \code{dca_unit}.
  }
  \item{balance_thresh}{
    Numerisch oder \code{NULL}. Minimale Gewichtsabweichung \strong{in
    Prozent} (z. B. \code{5} = 5 Prozentpunkte, siehe
    \code{balance_thresh_type}) für einen Rebalancing-Trade; geprüft wird die
    größte Abweichung über alle aktiven Assets.
    \code{NULL} = an jedem Termin rebalancieren. Gewichte, Abweichung und
    Depotwert werden an jedem Rebalancing-Tag (Termin, Band, Ereignis,
    \code{balance_dca}, Aktivierung) zum Tageskurs vor dem Handel bestimmt
    (nach Sparrate und Signal-Ein-/Ausstieg des Tages), gehandelt wird zum
    selben Kurs; ohne Kosten liegt das Ist-Gewicht danach genau am Ziel.
    Werte unter 0,2 (vermutlich Anteil, z. B. \code{0.05} für 5 Prozentpunkte)
    werden mit Warnung als Prozent gelesen; ein Band von z. B. \code{0.5}
    Prozentpunkten warnt nicht. Ohne
    \code{balance_mode} und \code{event_col} wirkungslos (Warnung).
  }
  \item{liquidate}{
    Logisch. Portfolio am letzten Simulationstag vollständig liquidieren
    (inkl. Steuerabrechnung)? Übersteigt die Ordergebühr den Erlös einer
    Position, bleibt sie mit Warnung stehen. Am Liquidationstag finden kein
    Rebalancing und keine Sparrate statt, auch wenn ein Termin von einem
    aufgefüllten Tag dorthin verschoben wurde. Standard: \code{FALSE}.
  }
  \item{event_col}{
    Character oder \code{NULL}. Name einer logischen Spalte in \code{data},
    die ereignisbasiertes Rebalancing auslöst (siehe
    \code{\link{compute_rebal_trigger}}). Standard: \code{NULL}.
  }
  \item{event_mode}{
    Character. \code{"additional"} (zusätzlich zum periodischen Rebalancing)
    oder \code{"replace"} (ersetzt es). Standard: \code{"additional"}.
    Ohne \code{event_col} wirkungslos (Warnung, wenn angegeben).
  }
  \item{event_weight}{
    Benannter Character-Vektor oder benannte Liste oder \code{NULL}: je
    Asset-Name der Name einer numerischen Spalte in \code{data} mit dem
    Zielgewicht. Wirkt nur an Tagen, an denen \code{event_col} \code{TRUE}
    ist; die Werte werden auf Summe 1 normiert und nur verwendet, wenn alle
    aktiven Assets einen endlichen Wert haben und die Summe positiv ist
    (fehlt ein Asset, gelten mit Warnung an Event-Tagen die
    Strategie-Gewichte). Unbenannte Angaben, unbekannte Asset-Namen,
    fehlende Spalten und negative Gewichte führen zu einem Fehler.
    \code{NULL} = Strategie-Gewichte.
  }
  \item{church_tax}{
    Kirchensteuersatz in Prozent (\code{8} oder \code{9}; Standard \code{0}).
    Setzt den Abgeltungsteuersatz nach § 32d Abs. 1 EStG
    (25 \% / (1 + 0,25 k) zuzüglich Solidaritätszuschlag und
    Kirchensteuer), z. B. 27,99 \% bei 9 \%; überschreibt \code{tax_rate}.
    Auf die Einkommensteuer (§ 23-Steuer mit \code{marginal_tax_rate},
    persönlicher Satz der Günstigerprüfung) wird die Kirchensteuer als
    \code{church_tax} Prozent der Einkommensteuer aufgeschlagen
    (z. B. 42 \% x 1,09 = 45,78 \% ohne Soli); den Sonderausgabenabzug der
    Kirchensteuer bei der Einkommensteuer bildet das Modell auf diesem Weg nicht
    ab. Mit \code{taxable_income} ist die Kirchensteuer \code{church_tax}
    Prozent der Einkommensteuer (nicht gerundet) und wird als Sonderausgabe
    im Jahr ihrer Zahlung berücksichtigt (Abschnitt \dQuote{Einkommensteuertarif}).
    Zulässig ist eine Zahl von 0 bis 100; Werte zwischen 0 und 1 (Anteil
    statt Prozent) und über 9 werden mit Warnung angenommen.
  }
  \item{order_fee}{
    Ordergebühr: \code{NULL} (keine, Standard), eine Zahl (feste Gebühr in
    EUR je Order) oder \code{list(fixed, percent, min, max)} mit
    \code{fixed}, \code{min}, \code{max} in EUR und \code{percent} in Prozent
    des Ordervolumens, z. B.
    \code{list(fixed = 4.9, percent = 0.25, max = 59)}. Die Gebühr erhöht beim
    Kauf den Einstandskurs (Anschaffungsnebenkosten) und mindert beim Verkauf
    den Erlös (Veräußerungskosten); steuerlich wirkt sie damit
    gewinnmindernd. Zusätzlich zum Spread je Asset. Unbekannte Listenfelder
    (z. B. \code{fix} statt \code{fixed}) führen zu einem Fehler. Bei
    Zwangsverkäufen für die Vorabpauschale und die § 23-Steuer wird so viel
    verkauft, dass Steuer und Gebühr gedeckt sind.
  }
  \item{dca_fee}{
    Gebühr für die Sparplankäufe (Format wie \code{order_fee}): Käufe von
    Buy-and-Hold-Assets an Sparplantagen. Rebalancing-Verkäufe und
    -Käufe, Signal-Trades, Steuer-Zwangsverkäufe und die Liquidation am
    selben Tag kosten \code{order_fee}. Ist der erste Simulationstag ein
    Sparplantag, wird das Startkapital mit \code{order_fee} und nur die
    Sparrate mit \code{dca_fee} angelegt (zwei Orders); fällt ein Sparplantermin auf einen
    Rebalancing-Tag, wird die Rate im Rebalancing mit angelegt. Standard:
    wie \code{order_fee}. Viele Broker führen Sparpläne kostenlos aus
    (\code{dca_fee = 0}).
  }
  \item{harvest_mode}{
    Logisch. \code{TRUE}: Einmal je Jahr (\code{harvest_day}) werden bei
    Fonds und § 20-Produkten Gewinne bis zum noch freien Sparer-Pauschbetrag
    (und, mit \code{harvest_loss_pot}, bis zur Höhe des Verlusttopfs)
    realisiert und sofort wieder angelegt („Freibetrag ausschöpfen“). Das hebt
    den Einstandskurs steuerfrei an und senkt die spätere Steuer; Spread und
    Gebühren fallen für Verkauf und Kauf an. Nur mit \code{tax_mode = "person"}
    (sonst Warnung, ohne Wirkung).
  }
  \item{harvest_day}{
    Termin als \code{"MM-TT"} (Standard \code{"12-15"}); es wird der erste
    Handelstag ab diesem Datum genutzt, vor dem 31.12.
  }
  \item{harvest_loss_pot}{
    Logisch. Auch den Verlusttopf durch realisierte Gewinne nutzen
    (Standard \code{TRUE}).
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
  \item{split_mode}{
    Logisch. Automatische Behandlung von Aktiensplits aktivieren?
    Standard: \code{FALSE}.
  }
  \item{split_thresh}{
    Numerischer Vektor der Länge 2 \code{c(untere, obere)} oder \code{NULL}.
    Kursschwellen in Preiseinheiten der Kursreihe: Steigt der Kurs über die
    obere Schwelle, folgt ein Split (Verhältnis Kurs/100), fällt er unter die
    untere, eine Zusammenlegung (100/Kurs); der Kurs wird jeweils auf 100
    gesetzt. Bestand, Lots und die gesamte Kurshistorie (auch der
    Jahresanfangskurs für die Vorabpauschale) werden umgerechnet.
    Nur mit \code{split_mode = TRUE}; \code{NULL} = keine Splits. Erwartet
    wird \code{untere < 100 < obere}; sonst Warnung, da nach dem ersten Split
    (Kurs 100) an jedem folgenden Tag ein weiterer Split ausgelöst wird.
    Kein Zahlenvektor der Länge 2: Fehler. Hat ein Asset am Split-Tag keinen
    Bestand (späterer Start, Signal-Asset in Cash), wird seine Kursreihe
    trotzdem umgerechnet; spätere Käufe erfolgen daher zu Kursen innerhalb der
    Schwellen.
  }
  \item{balance_thresh_type}{
    \code{"absolute"} (Standard): \code{balance_thresh} sind Prozentpunkte
    des Gewichts (5 = Ziel 40 \% darf 35--45 \% sein). \code{"relative"}:
    Prozent des Zielgewichts (25 = Ziel 40 \% darf 30--50 \% sein), wie die
    relativen Bänder bei testfol.io. Geprüft wird an den Kalenderterminen
    des Rebalancings.
  }
  \item{funds_fee}{
    Numerisch. Jährliche Fondskostenquote (TER-äquivalent) \strong{in Prozent}
    (z. B. \code{0.95} = 0,95 \% p.a.), konsistent mit der paketweiten
    Prozent-Konvention. Täglich auf den Wert jedes Assets abgegrenzt
    (linearer Tagessatz \code{funds_fee / 100} geteilt durch die Kalendertage
    des Jahres, 365 bzw. 366: ein volles Jahr kostet genau \code{funds_fee}
    Prozent, ein Rumpfjahr nur anteilige Kosten); wirkt nur bei
    \code{tax_mode = "funds"} (ausdrücklich angegeben bei anderem
    \code{tax_mode}: Warnung); belastet am 31.12. und anteilig am letzten
    Simulationstag. Reicht das Cash eines Assets nicht, werden dafür Anteile
    verkauft (interne Kostenentnahme zum Tageskurs, ohne Ordergebühr und
    ohne Spread). Endet \code{data}
    mit \code{liquidate = TRUE} auf einem aufgefüllten Tag, werden die
    anteiligen Kosten am letzten Handelstag vor der Liquidation belastet
    (Kosten vor Steuer). Zulässig 0 bis 100 (sonst, auch bei \code{NA},
    Fehler). Standard: \code{0.95}.
  }
  \item{bonus_fee}{
    Numerisch. Jährliche Performancegebühr \strong{in Prozent} des
    Wertzuwachses über dem bisherigen Höchststand (z. B. \code{5} = 5 \%,
    Prozent-Konvention, High-Watermark ab \code{start_value}, erhöht um
    Sparplan-Einzahlungen, damit Einzahlungen nicht als Wertzuwachs zählen;
    nach einer Belastung gilt der Wert \strong{nach} Abzug der Gebühren als
    neuer Höchststand, die Marke sinkt nie);
    wirkt nur bei \code{tax_mode = "funds"} (ausdrücklich angegeben bei
    anderem \code{tax_mode}: Warnung); zulässig 0 bis 100 (sonst
    Fehler). Standard: \code{5}.
  }
  \item{spread}{
    Numerisch oder \code{NULL}. Wird nicht ausgewertet (nur aus
    Kompatibilitätsgründen vorhanden; ein Wert ungleich \code{NULL} löst eine
    Warnung aus); maßgeblich ist allein \code{asset_spread} je Asset (siehe
    \code{\link{asset_config}}). Standard: \code{NULL}.
  }
  \item{dca_start}{
    Date (oder \code{"JJJJ-MM-TT"}) oder \code{NULL}. Bezugsdatum des
    DCA-Terminplans: Die Perioden beginnen am Monatsersten dieses Datums (bei
    \code{"year"} am 1. Januar); Termine vor dem ersten Datentag entfallen.
    Liegt das Datum nach dem letzten Datentag, bricht die Funktion mit Fehler
    ab. \code{NULL} (Standard) = erster Tag von \code{data}.
  }
  \item{dca_skip}{
    Logisch. DCA-Termin am ersten Simulationstag auslassen? (Termine an
    anderen Tagen bleiben.) Standard: \code{FALSE}.
  }
  \item{balance_days}{
    Integer-Vektor oder \code{NULL}. Tag(e) innerhalb jeder Periode für
    das Rebalancing, Bedeutung wie \code{dca_days} (bezogen auf
    \code{balance_unit} und \code{balance_anchor}).
  }
  \item{balance_anchor}{
    Character. Bezugspunkt für \code{balance_days}: \code{"start"}
    (Standard) oder \code{"end"}, wie \code{dca_anchor}.
  }
  \item{balance_start}{
    Date (oder \code{"JJJJ-MM-TT"}) oder \code{NULL}. Bezugsdatum des
    Rebalancing-Terminplans, wie \code{dca_start}.
  }
  \item{balance_skip}{
    Logisch. Rebalancing-Termin am ersten Simulationstag auslassen?
    Standard: \code{FALSE}.
  }
  \item{balance_dca}{
    Logisch. \code{FALSE} (Standard): Jede DCA-Rate wird fix nach den
    \strong{Strategie-Gewichten} (\code{asset_share}) verteilt, renormiert
    über die aktiven Assets — 70:30 bleibt 70:30, unabhängig von der
    Depot-Drift. \code{TRUE}: Die Rate wirkt als Mini-Rebalancing — sie
    füllt zuerst die Wert-Defizite zu den Strategie-Zielen; ein Rest wird
    nach Strategie-Gewichten verteilt.
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
      (Sparplan, \code{dca_mode = TRUE}); eine Einzahlung am Starttag steckt
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
          (Sortino/Price, wie \code{\link{deep_analysis}}); \code{NA} ohne
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
      Nur bei \code{tax_mode = "person"}: \code{next_year}, der Steuerzustand
      des Jahres nach dem letzten Datentag (für eine Fortsetzung, z. B. in
      \code{\link{withdrawal_simulation}}): genau das, was die Engine diesem
      Jahr schon zugerechnet hat; endet die Simulation am 31.12., ist das die
      dort festgesetzte Vorabpauschale (Zufluss im Folgejahr, verrechnet mit
      Verlusttopf und Sparer-Pauschbetrag dieses Jahres; ein Zwangsverkauf für
      ihre Steuer am letzten Tag gehört zum Vorjahr), sonst nichts
      (Verbrauch 0). Liste mit \code{year}, \code{sparer_pauschbetrag_used}
      und \code{sparer_pauschbetrag_remaining} (EUR; ohne
      \code{use_sparer_pauschbetrag} 0), \code{loss_carryforward_capital}
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
      bei Günstigerprüfung; \code{NA} ohne \code{use_guenstigerpruefung}),
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
      die Spalten \code{tariff_*} ohne \code{use_guenstigerpruefung} bewusst
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
      Nur bei \code{tax_mode = "person"} gefüllt (sonst \code{NULL}): benannte Liste
      je Asset mit \code{lots} (\code{data.frame} der am letzten Tag gehaltenen
      Lots in FIFO-Reihenfolge: \code{date} Kaufdatum, \code{units}
      verbleibende Stück, \code{price} Anschaffungskurs je Stück wie in der
      FIFO-Gewinnrechnung, d. h. Briefkurs einschließlich anteiliger
      Ordergebühr, nach Splits umgerechnet, \code{vp} bereits versteuerte,
      bei Verkauf nach § 19 InvStG anzurechnende Vorabpauschale dieser Stück in
      EUR), \code{regime} (\code{"investment_fund"}, \code{"capital_gains"}
      oder \code{"private_sale"}), \code{asset_bonus} (Teilfreistellung in
      Prozent), \code{cash} (Geldbestand des Assets am Ende in EUR),
      \code{asset_spread} (voller Bid-Ask-Spread in Prozent wie in
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
    \item{\code{harvest_days}}{Nur bei \code{harvest_mode = TRUE}: Date-Vektor
      der Termine der Gewinnrealisierung.}
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
  MSCI = asset_config("etf", action_type = "bnh",
                      asset_share = 0.7, asset_spread = 0.1, asset_bonus = 30),
  BOND = asset_config("etf", action_type = "bnh",
                      asset_share = 0.3, asset_spread = 0.1, asset_bonus = 0)
)

# Einfacher Lauf ohne Steuer
result <- simulation(data, strategy, start_value = 10000)
print(result)

# Mit Besteuerung, jährlichem Rebalancing und Risk-Free-Rate
result_tax <- simulation(
  data, strategy,
  start_value  = 10000,
  tax_mode     = "person",
  tax_rate     = 26.375,
  balance_mode = TRUE,
  balance_unit = "year",
  liquidate    = TRUE,
  risk_free    = 2
)
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
  Mit \code{taxable_income} (zvE \eqn{z_t} des Jahres \eqn{t} ohne die
  Erträge der Simulation) rechnet die Engine mit dem Tarif der Datei
  \code{tax_tariff} (\code{\link{read_tax_tariff}}). Rechtsgrundlagen
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
      \code{tax_rate}).
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
    \item § 32d Abs. 6 Satz 1 EStG (\code{use_guenstigerpruefung = TRUE}):
      unterjährig wird die Abgeltungsteuer wie bei einer Bank einbehalten
      (auch die Steuerschätzung beim Umschichten rechnet mit
      \code{tax_rate}). Im Jahresabschluss ist \eqn{K} die Bemessungsgrundlage,
      auf die im Jahr per Saldo Abgeltungsteuer erhoben wurde (Kapitaleinkünfte
      nach § 20 nach Teilfreistellung, Vorabpauschale des Zuflussjahres,
      Verlustverrechnung und Sparer-Pauschbetrag), \eqn{A_t} = \eqn{K} mal
      \code{tax_rate} die darauf einbehaltene Abgeltungsteuer mit Soli und
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
  einen Wert hat (eine Zahl für alle Jahre oder das Jahr angegeben). \code{marginal_tax_rate},
  \code{include_soli_on_income_tax} und \code{soli_rate_income_tax} wirken auf
  diesem Weg nicht. Ohne \code{taxable_income} bleibt alles unverändert.
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

  Außerhalb von Rebalancing-Tagen gilt (unabhängig von \code{balance_mode}):
  Ein Signal-Asset mit offener Position legt neues Geld (Sparraten, Restcash,
  Umverteilungen, Erstattungen) sofort an wie Buy-and-Hold, außer am Tag
  eines Verkaufssignals; das Signal steuert nur Ein- und Ausstieg. Ohne
  Bestand wartet das Geld als Cash auf das Kaufsignal.
}
\section{Ereignisbasiertes Rebalancing}{
  Zusammenspiel der Argumente:
  \describe{
    \item{\code{event_col}}{
      Character oder \code{NULL}. Name einer logischen Spalte in \code{data},
      die ereignisbasiertes Rebalancing auslöst (\code{TRUE} = Rebalancing-Tag).
      Erzeugt mit \code{\link{compute_rebal_trigger}}.
    }
    \item{\code{event_mode}}{
      \code{"additional"} (zusätzlich zu periodischem Rebalancing) oder
      \code{"replace"} (ersetzt periodisches Rebalancing).
    }
    \item{\code{event_weight}}{
      Benannter Vektor/Liste oder \code{NULL}: je Asset der Name einer Spalte
      mit dem Zielgewicht an Event-Tagen (siehe Argument \code{event_weight}).
    }
  }
}
\seealso{
  \code{\link{asset_config}}, \code{\link{create_strategy}},
  \code{\link{compute_rebal_trigger}}, \code{\link{plot.SimLevResult}},
  \code{\link{read_tax_tariff}},
  \code{\link{plot_interactive}}; Weiterverarbeitung des Ergebnisses mit
  \code{\link{deep_analysis}} und \code{\link{withdrawal_paths}}
}
