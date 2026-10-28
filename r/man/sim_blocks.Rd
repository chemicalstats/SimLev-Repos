\encoding{UTF-8}
\name{sim_blocks}
\alias{sim_blocks}
\alias{sim_costs}
\alias{dca_plan}
\alias{rebalance_plan}
\alias{split_rule}
\alias{tax_profile}
\alias{income_rate}
\alias{income_tariff}
\alias{harvest_rule}
\alias{funds_costs}
\alias{print.SimLevSimCosts}
\alias{print.SimLevDcaPlan}
\alias{print.SimLevRebalancePlan}
\alias{print.SimLevSplitRule}
\alias{print.SimLevTaxProfile}
\alias{print.SimLevIncomeRate}
\alias{print.SimLevIncomeTariff}
\alias{print.SimLevHarvestRule}
\alias{print.SimLevFundsCosts}
\title{Bausteine für simulation(): Kosten, Sparplan, Rebalancing, Splits, Steuern; Fondskosten}
\description{
Die Einstellungen von \code{\link{simulation}} werden als Bausteine übergeben:
\code{costs = sim_costs()}, \code{dca = dca_plan()}, \code{rebalance = rebalance_plan()},
\code{splits = split_rule()}, \code{tax = tax_profile()} (mit \code{income = income_rate()} oder
\code{income_tariff()} und \code{harvest = harvest_rule()}).
\code{NULL} heißt aus (kein Sparplan, kein Rebalancing, keine Splits, keine Steuern). Jeder Baustein prüft seine Argumente beim Anlegen (deutsche Fehlermeldungen und
Warnungen) und druckt eine kurze Zusammenfassung. \code{simulation()} prüft nur noch das
Zusammenspiel mit den Daten (z. B. ob die Spalte \code{event_col} in \code{data} steht oder ob
\code{start} im Datenzeitraum liegt). Die Rechnung der Engine ist dieselbe wie mit den früheren Einzelargumenten.

\code{funds_costs()} ist der Kostenbaustein des Fonds-Wrappers
(\code{\link{wrapper_config}(costs = funds_costs())}); \code{simulation()} nimmt ihn nicht an.
}
\usage{
sim_costs(order_fee = NULL, dca_fee = NULL)

dca_plan(value, span, days = NULL, unit = c("month", "quarter", "year"),
         anchor = c("start", "end"), start = NULL, skip = FALSE, fill_deficits = FALSE)

rebalance_plan(span = NULL, days = NULL, unit = c("month", "quarter", "year"),
               anchor = c("start", "end"), start = NULL, skip = FALSE, thresh = NULL,
               thresh_type = c("absolute", "relative"), event_col = NULL,
               event_mode = c("additional", "replace"), event_weight = NULL)

split_rule(thresh)

tax_profile(rate = 26.375, church_tax = 0, sparer_pauschbetrag = 1000,
            private_sale_threshold = 1000, base_rate = NULL, guenstigerpruefung = FALSE,
            income = NULL, harvest = NULL)

income_rate(marginal_rate, soli_rate = 0)

income_tariff(taxable_income, tariff = NULL)

harvest_rule(day = "12-15", loss_pot = TRUE)

funds_costs(fee = 0.95, performance_fee = 5)

\method{print}{SimLevSimCosts}(x, ...)
\method{print}{SimLevDcaPlan}(x, ...)
\method{print}{SimLevRebalancePlan}(x, ...)
\method{print}{SimLevSplitRule}(x, ...)
\method{print}{SimLevTaxProfile}(x, ...)
\method{print}{SimLevIncomeRate}(x, ...)
\method{print}{SimLevIncomeTariff}(x, ...)
\method{print}{SimLevHarvestRule}(x, ...)
\method{print}{SimLevFundsCosts}(x, ...)
}
\arguments{
  \item{order_fee}{
    \code{sim_costs}: Ordergebühr: \code{NULL} (keine, Standard), eine Zahl (feste Gebühr in
    EUR je Order) oder \code{list(fixed, percent, min, max)} mit \code{fixed}, \code{min},
    \code{max} in EUR und \code{percent} in Prozent des Ordervolumens, z. B.
    \code{list(fixed = 4.9, percent = 0.25, max = 59)}. Die Gebühr erhöht beim Kauf den
    Einstandskurs (Anschaffungsnebenkosten) und mindert beim Verkauf den Erlös
    (Veräußerungskosten); steuerlich wirkt sie damit gewinnmindernd. Zusätzlich zum Spread je
    Asset (\code{spread} in \code{\link{asset_config}}; einen Spread für die ganze Simulation
    gibt es nicht). Unbekannte Listenfelder (z. B. \code{fix} statt \code{fixed}) und negative
    Gebühren führen zu einem Fehler. Bei Zwangsverkäufen für die Vorabpauschale und die
    § 23-Steuer wird so viel verkauft, dass Steuer und Gebühr gedeckt sind.
  }
  \item{dca_fee}{
    \code{sim_costs}: Gebühr für die Sparplankäufe (Format wie \code{order_fee}): Käufe von
    Buy-and-Hold-Assets an Sparplantagen. Rebalancing-Verkäufe und -Käufe, Signal-Trades,
    Steuer-Zwangsverkäufe und die Liquidation am selben Tag kosten \code{order_fee}. Ist der
    erste Simulationstag ein Sparplantag, wird das Startkapital mit \code{order_fee} und nur die
    Sparrate mit \code{dca_fee} angelegt (zwei Orders); fällt ein Sparplantermin auf einen
    Rebalancing-Tag, wird die Rate im Rebalancing mit angelegt. Standard (\code{NULL}): wie
    \code{order_fee}. Viele Broker führen Sparpläne kostenlos aus (\code{dca_fee = 0}).
  }
  \item{value}{
    \code{dca_plan}: Betrag je Sparplan-Termin in EUR; Pflicht, eine einzelne endliche Zahl
    \code{> 0} (Vektor, \code{NA} oder Text: Fehler).
  }
  \item{span}{
    \code{dca_plan}: Abstand zwischen zwei Terminen in Perioden von \code{unit} (z. B.
    \code{3} mit \code{"month"} = alle drei Monate); Pflicht, eine einzelne ganze Zahl
    \code{>= 1} (sonst Fehler). \code{rebalance_plan}: Rebalancing-Intervall in Perioden von
    \code{unit}; \code{NULL} (Standard) = 1.
  }
  \item{days}{
    Integer-Vektor oder \code{NULL}. Tag(e) innerhalb jeder Periode (1--31): bei
    \code{"month"} Tag des Monats, bei \code{"quarter"} Tag im ersten Monat der Periode, bei
    \code{"year"} Tag im Januar; mit \code{anchor = "end"} rückwärts vom Periodenende gezählt
    (1 = letzter Tag). Nicht existierende Tage entfallen (z. B. Tag 31 im April, bei
    \code{"end"} Tag 31 vom Ende im Februar). Werte außerhalb von 1--31 oder nicht ganzzahlig:
    Fehler; doppelte Tage ergeben nur einen Termin (Warnung, der Baustein enthält jeden Tag
    einmal). Fallen bei Handelstagsdaten mehrere Sparplantermine auf denselben Handelstag
    (Verschiebung von Wochenenden), wird je Termin eine Rate eingezahlt. \code{NULL}
    (Standard) = erster Tag der Periode.
  }
  \item{unit}{
    Einheit des Abstands: \code{"month"} (Standard), \code{"quarter"} oder \code{"year"}.
    Perioden beginnen am Monatsersten des Startmonats (\code{start} bzw. erster Datentag), bei
    \code{"year"} am 1. Januar; Quartale sind daher nicht zwingend Kalenderquartale.
  }
  \item{anchor}{
    Bezugspunkt für \code{days}: \code{"start"} (Standard, ab Periodenbeginn) oder
    \code{"end"} (ab Periodenende). Ohne \code{days} wirkungslos.
  }
  \item{start}{
    Date (oder \code{"JJJJ-MM-TT"}) oder \code{NULL}. Bezugsdatum des Terminplans: Die
    Perioden beginnen am Monatsersten dieses Datums (bei \code{"year"} am 1. Januar); Termine
    vor dem ersten Datentag entfallen. Kein Datum: Fehler beim Anlegen; liegt das Datum nach
    dem letzten Datentag, bricht \code{simulation()} mit Fehler ab. \code{NULL} (Standard) =
    erster Tag von \code{data}.
  }
  \item{skip}{
    Logisch. \code{dca_plan}: Sparplan-Termin am ersten Simulationstag auslassen (Termine an
    anderen Tagen bleiben). \code{rebalance_plan}: Rebalancing-Termin am ersten
    Simulationstag auslassen. Mit \code{event_col} und \code{event_mode = "replace"}
    (Rebalancing nur an Ereignistagen) heißt \code{skip = TRUE}: am ersten Tag nicht
    umschichten, das Startkapital wird wie ohne Rebalancing angelegt; mit \code{skip = FALSE}
    wird am ersten Tag (und am Starttag später startender Assets) über das Rebalancing nach
    Zielgewichten gekauft. Standard: \code{FALSE}.
  }
  \item{fill_deficits}{
    \code{dca_plan}: \code{FALSE} (Standard): Jede Rate wird fix nach den
    \strong{Strategie-Gewichten} (\code{share}) verteilt, renormiert über die aktiven Assets
    — 70:30 bleibt 70:30, unabhängig von der Depot-Drift. \code{TRUE}: Die Rate wirkt als
    Mini-Rebalancing — sie füllt zuerst die Wert-Defizite zu den Strategie-Zielen; ein Rest
    wird nach Strategie-Gewichten verteilt.
  }
  \item{thresh}{
    \code{rebalance_plan}: Minimale Gewichtsabweichung \strong{in Prozent} (z. B. \code{5}
    = 5 Prozentpunkte, siehe \code{thresh_type}) für einen Rebalancing-Trade; geprüft wird die
    größte Abweichung über alle aktiven Assets. \code{NULL} (Standard) = an jedem Termin
    rebalancieren. Gewichte, Abweichung und Depotwert werden an jedem Rebalancing-Tag zum
    Tageskurs vor dem Handel bestimmt (nach Sparrate und Signal-Ein-/Ausstieg des Tages),
    gehandelt wird zum selben Kurs. Werte unter 0,2 (vermutlich Anteil, z. B. \code{0.05} für
    5 Prozentpunkte) werden mit Warnung als Prozent gelesen.
    \code{split_rule}: Numerischer Vektor der Länge 2 \code{c(untere, obere)}: Kursschwellen in
    Preiseinheiten der Kursreihe. Steigt der Kurs über die obere Schwelle, folgt ein Split
    (Verhältnis Kurs/100), fällt er unter die untere, eine Zusammenlegung (100/Kurs); der Kurs
    wird jeweils auf 100 gesetzt. Bestand, Lots und die gesamte Kurshistorie (auch der
    Jahresanfangskurs für die Vorabpauschale) werden umgerechnet. Erwartet wird
    \code{untere < 100 < obere}; sonst Warnung, da nach dem ersten Split (Kurs 100) an jedem
    folgenden Tag ein weiterer Split ausgelöst wird. Kein Zahlenvektor der Länge 2: Fehler.
    Hat ein Asset am Split-Tag keinen Bestand, wird seine Kursreihe trotzdem umgerechnet.
  }
  \item{thresh_type}{
    \code{"absolute"} (Standard): \code{thresh} sind Prozentpunkte des Gewichts (5 = Ziel
    40 \% darf 35--45 \% sein). \code{"relative"}: Prozent des Zielgewichts (25 = Ziel 40 \%
    darf 30--50 \% sein).
  }
  \item{event_col}{
    Character oder \code{NULL}. Name einer logischen Spalte in \code{data}, die
    ereignisbasiertes Rebalancing auslöst (siehe \code{\link{rebalance_trigger}}); fehlt die
    Spalte, bricht \code{simulation()} mit Fehler ab. Kein Rebalancing am ersten Tag und (mit
    \code{liquidate}) am Liquidationstag. Standard: \code{NULL}.
  }
  \item{event_mode}{
    \code{"additional"} (Standard: zusätzlich zu den Terminen) oder \code{"replace"} (nur an
    Ereignistagen, die Termine entfallen; siehe \code{skip}). Ohne \code{event_col} wirkungslos
    (Warnung, wenn angegeben).
  }
  \item{event_weight}{
    Benannter Character-Vektor oder benannte Liste oder \code{NULL}: je Asset-Name der Name
    einer numerischen Spalte in \code{data} mit dem Zielgewicht. Wirkt nur an Tagen, an denen
    \code{event_col} \code{TRUE} ist; die Werte werden auf Summe 1 normiert und nur verwendet,
    wenn alle aktiven Assets einen endlichen Wert haben und die Summe positiv ist (fehlt ein
    Asset, gelten mit Warnung an Event-Tagen die Strategie-Gewichte). Unbenannte Angaben,
    unbekannte Asset-Namen, fehlende Spalten und negative Gewichte führen in
    \code{simulation()} zu einem Fehler. \code{NULL} = Strategie-Gewichte. Ohne
    \code{event_col} wirkungslos (Warnung).
  }
  \item{rate}{
    \code{tax_profile}: Kapitalertragsteuersatz inkl. Solidaritätszuschlag \strong{in
    Prozent} (z. B. \code{26.375} = 25 \% KapESt + 5,5 \% Soli), zulässig 0 bis 100. Werte
    zwischen 0 und 1 (vermutlich ein Anteil) werden mit Warnung als Prozent gelesen. Gilt nur
    ohne Kirchensteuer: \code{rate} zusammen mit \code{church_tax > 0} ergibt einen Fehler.
    Standard: \code{26.375}.
  }
  \item{church_tax}{
    \code{tax_profile}: Kirchensteuersatz in Prozent (\code{8} oder \code{9}; Standard
    \code{0}). Setzt den Abgeltungsteuersatz nach § 32d Abs. 1 EStG (25 \% / (1 + 0,25 k)
    zuzüglich Solidaritätszuschlag und Kirchensteuer), z. B. 27,99 \% bei 9 \%. Auf die
    Einkommensteuer (§ 23-Steuer mit \code{income_rate()}, persönlicher Satz der
    Günstigerprüfung) wird die Kirchensteuer als \code{church_tax} Prozent der
    Einkommensteuer aufgeschlagen. Mit \code{income_tariff()} ist die Kirchensteuer
    \code{church_tax} Prozent der Einkommensteuer und wird als Sonderausgabe im Jahr ihrer
    Zahlung berücksichtigt. Zulässig ist eine Zahl von 0 bis 100; Werte zwischen 0 und 1
    (Anteil statt Prozent) und über 9 werden mit Warnung angenommen.
  }
  \item{sparer_pauschbetrag}{
    \code{tax_profile}: Jährlicher Sparer-Pauschbetrag in EUR (Freibetrag; \code{2000} bei
    Zusammenveranlagung); \code{0} heißt ohne Pauschbetrag. Genutzt wird höchstens der
    positive Jahressaldo der Kapitalerträge nach Verlustverrechnung (§ 20 Abs. 9 Satz 4,
    § 43a Abs. 3 EStG), Verlusttopf vor Pauschbetrag (siehe \code{\link{simulation}}).
    Eine einzelne endliche Zahl \code{>= 0} (sonst Fehler). Standard: \code{1000}.
  }
  \item{private_sale_threshold}{
    \code{tax_profile}: Jährliche Freigrenze nach § 23 Abs. 3 Satz 5 EStG in EUR, für alle
    Jahre gleich. Ab Erreichen der Freigrenze ist der Jahressaldo abzüglich Verlustvortrag
    steuerpflichtig (BFH IX R 27/04), darunter steuerfrei. Eine einzelne endliche Zahl
    \code{>= 0} (sonst Fehler). Standard: \code{1000}.
  }
  \item{base_rate}{
    \code{tax_profile}: Basiszins für die Vorabpauschale: \code{NULL} (Standard: keine
    Vorabpauschale), eine Zahl \strong{in Prozent} (z. B. \code{2.55} = 2,55 \%; negativ
    erlaubt und wie 0 behandelt) oder der Name einer Spalte in \code{data} mit täglichen
    Basiszinswerten in Prozent (wie \code{risk_free}; \code{NA} wird zu 0, für ein Jahr zählt
    der Wert vom ersten Handelstag, § 18 Abs. 4 InvStG). Zahlen zwischen 0 und 0,05
    (vermutlich Anteil) werden mit Warnung als Prozent gelesen, für eine Spalte gilt dieselbe
    Schwelle für den Median; fehlt die Spalte, bricht \code{simulation()} mit Fehler ab.
  }
  \item{guenstigerpruefung}{
    \code{tax_profile}: Günstigerprüfung nach § 32d Abs. 6 EStG anwenden? Mit
    \code{income_rate()} wird statt \code{rate} der persönliche Satz (mit Soli und
    Kirchensteuer) verwendet, wenn die Belastung einschließlich Zuschlagsteuern niedriger ist;
    ohne Grenzsteuersatz warnt \code{simulation()} und rechnet mit der Abgeltungsteuer. Mit
    \code{income_tariff()} wird unterjährig die Abgeltungsteuer einbehalten und im
    Jahresabschluss mit dem Tarif verglichen; die Differenz wird erstattet. Standard:
    \code{FALSE}.
  }
  \item{income}{
    \code{tax_profile}: Einkommen für § 23 EStG und die Günstigerprüfung: \code{NULL}
    (Standard; sind § 23-Gewinne steuerpflichtig, werden 42 \% angesetzt, mit Warnung in
    \code{simulation()}), \code{income_rate()} (fester Grenzsteuersatz) oder
    \code{income_tariff()} (Einkommensteuertarif); beide Wege schließen sich aus.
  }
  \item{harvest}{
    \code{tax_profile}: \code{NULL} (Standard) oder \code{harvest_rule()}: Einmal je Jahr
    werden bei Fonds und § 20-Produkten Gewinne bis zum noch freien Sparer-Pauschbetrag (und
    mit \code{loss_pot} bis zur Höhe des Verlusttopfs) realisiert und sofort wieder angelegt
    („Freibetrag ausschöpfen“); Spread und Gebühren fallen für Verkauf und Kauf an.
  }
  \item{marginal_rate}{
    \code{income_rate}: Persönlicher Grenzsteuersatz \strong{in Prozent} (z. B. \code{42}),
    zulässig 0 bis 50; Pflicht. Werte zwischen 0 und 1 (vermutlich Anteil) werden mit Warnung
    als Prozent gelesen. Die § 23-Steuer (Satz mal (1 + Soli-Satz + Kirchensteuersatz))
    entsteht mit dem Jahresabschluss und wird am Abrechnungstag der Vorabpauschale aus dem
    Depot gezahlt.
  }
  \item{soli_rate}{
    \code{income_rate}: Solidaritätszuschlag auf die Einkommensteuer \strong{in Prozent}
    (z. B. \code{5.5}); \code{0} (Standard) heißt ohne Soli (seit 2021 zahlen wegen der
    Freigrenze die meisten Steuerpflichtigen keinen Soli auf die Einkommensteuer). Eine
    einzelne endliche Zahl \code{>= 0}.
  }
  \item{taxable_income}{
    \code{income_tariff}: Zu versteuerndes Einkommen (zvE) in EUR je Kalenderjahr
    \strong{ohne} die Kapitalerträge und § 23-Gewinne der Simulation; Pflicht. Eine Zahl (gilt
    für alle Jahre), ein nach Kalenderjahren benannter Zahlenvektor (z. B.
    \code{c("2024" = 50000, "2025" = 52000)}) oder ein \code{data.frame} mit den Spalten
    \code{year} und \code{taxable_income} (oder genau zwei Spalten Jahr, Betrag). Fehlt ein
    Kalenderjahr der Simulation, bricht \code{simulation()} mit Fehler ab. Die Engine rechnet
    dann mit dem Einkommensteuertarif (Abschnitt \dQuote{Einkommensteuertarif} in
    \code{\link{simulation}}).
  }
  \item{tariff}{
    \code{income_tariff}: \code{NULL} (Standard: mitgelieferte Datei
    \code{system.file("extdata", "steuertarif.csv", package = "SimLev")}, Rechtslage ab VZ
    2026), ein Dateipfad (wird beim Anlegen mit \code{\link{tax_tariff}} gelesen) oder ein
    Objekt aus \code{\link{tax_tariff}}.
  }
  \item{day}{
    \code{harvest_rule}: Termin als \code{"MM-TT"} (Standard \code{"12-15"}); genutzt wird
    der erste Handelstag ab diesem Datum, vor dem 31.12. (sonst Fehler).
  }
  \item{loss_pot}{
    \code{harvest_rule}: Auch den Verlusttopf durch realisierte Gewinne nutzen? Standard
    \code{TRUE}.
  }
  \item{fee}{
    \code{funds_costs}: Jährliche Verwaltungsgebühr (Fondskostenquote) \strong{in Prozent}
    (z. B. \code{0.95}), im Wrapper täglich je Kalendertag vom Anteilswert abgezogen.
    Zulässig 0 bis 100 (sonst Fehler). Standard: \code{0.95}.
  }
  \item{performance_fee}{
    \code{funds_costs}: Performancegebühr \strong{in Prozent} des Wertzuwachses des
    Anteilswerts über dem Höchststand (High-Water-Mark über die ganze Laufzeit); im Wrapper
    täglich abgegrenzt und am letzten Datentag jedes Kalenderjahres festgeschrieben.
    Zulässig 0 bis 100 (sonst Fehler). Standard: \code{5}.
  }
  \item{x}{Ein Baustein.}
  \item{...}{Weitere Argumente (ignoriert).}
}
\value{
  Ein Baustein: Liste mit den Argumenten (nach der Prüfung; \code{unit}, \code{anchor},
  \code{thresh_type} und \code{event_mode} aufgelöst, \code{days} ohne doppelte Tage,
  \code{tariff} aus einem Dateipfad gelesen) und der Klasse \code{SimLevSimCosts},
  \code{SimLevDcaPlan}, \code{SimLevRebalancePlan}, \code{SimLevSplitRule},
  \code{SimLevTaxProfile}, \code{SimLevIncomeRate}, \code{SimLevIncomeTariff},
  \code{SimLevHarvestRule} bzw. \code{SimLevFundsCosts}. Die \code{print}-Methoden geben
  \code{x} unsichtbar zurück.
}
\section{Übersetzung in die Engine}{
  \code{simulation()} übersetzt die Bausteine am Anfang in die internen Werte der Engine:
  \code{dca_plan()} schaltet den Sparplan ein, \code{rebalance_plan()} das Rebalancing
  (auch am ersten Simulationstag und am Starttag später startender Assets wird dann über das
  Rebalancing gekauft); nur mit \code{event_col}, \code{event_mode = "replace"} und
  \code{skip = TRUE} wird ausschließlich an Ereignistagen umgeschichtet.
  \code{tax = tax_profile()} steht für die persönliche Besteuerung.
}
\section{Fondskosten}{
  \code{funds_costs(fee, performance_fee)} ist der Kostenbaustein des Fonds-Wrappers:
  \code{\link{wrapper_config}(strategy, costs = funds_costs(...))}. Die Rechnung
  (Verwaltungsgebühr je Kalendertag, Performancegebühr gegen die High-Water-Mark) steht
  in \code{\link{wrapper_nav}}. \code{print()} zeigt die Überschrift
  \dQuote{Fondskosten (funds_costs)}. Der frühere Fondsmodus
  \code{simulation(funds = funds_costs())} ist entfernt; \code{simulation(funds = )} ergibt
  den Fehler für ein unbekanntes Argument.
}
\examples{
dca_plan(200, 1)
rebalance_plan(unit = "quarter", thresh = 5)
tax_profile(church_tax = 9, base_rate = 2.29, income = income_rate(42), harvest = harvest_rule())
sim_costs(order_fee = list(fixed = 1, percent = 0.25, min = 2, max = 20), dca_fee = 0)

d <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 730),
                A = 100 * 1.0003^(0:729), B = 50 * 1.0001^(0:729))
s <- create_strategy(A = asset_config("etf", "bnh", 0.6, partial_exemption = 30),
                     B = asset_config("etf", "bnh", 0.4))
r <- simulation(d, s, dca = dca_plan(100, 1), rebalance = rebalance_plan(unit = "year"),
                tax = tax_profile(base_rate = 2.29), liquidate = TRUE)
r$tax_report$total_taxes_paid
}
\seealso{
  \code{\link{simulation}}, \code{\link{asset_config}}, \code{\link{rebalance_trigger}},
  \code{\link{tax_tariff}}, \code{\link{wrapper_config}}
}
