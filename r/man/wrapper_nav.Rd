\encoding{UTF-8}
\name{wrapper_nav}
\alias{wrapper_nav}
\alias{print.SimLevWrapperNav}
\alias{[.SimLevWrapperNav}
\title{Anteilswert (NAV) eines Fonds-Wrappers}
\description{
  Rechnet den täglichen Anteilswert eines Wrappers aus \code{\link{wrapper_config}}:
  innere Bruttorechnung mit \code{\link{simulation}}, dann Verwaltungsgebühr je
  Kalendertag und Performancegebühr gegen die High-Water-Mark. \code{simulation()}
  verwendet dieselbe Rechnung für Wrapper-Assets; \code{wrapper_nav()} dient für eigene
  Auswertungen und Grafiken, als Renditequelle für \code{\link{withdrawal_simulation}}
  (\code{x = wrapper_nav(...)}) und zur Prüfung.
}
\usage{
wrapper_nav(data, wrapper, splits = NULL)

\method{print}{SimLevWrapperNav}(x, ...)

\method{[}{SimLevWrapperNav}(x, ...)
}
\arguments{
  \item{data}{
    \code{data.frame} mit Spalte \code{date} und den Kursspalten (und ggf. Signal- und
    Ereignisspalten) der inneren Strategie. \code{date} wird wie in
    \code{simulation()} als Datum gelesen; unsortierte Zeilen werden nach Datum sortiert.
  }
  \item{wrapper}{Objekt aus \code{\link{wrapper_config}}.}
  \item{splits}{
    \code{NULL} oder Objekt aus \code{\link{split_rule}} für die inneren Spalten (in
    \code{simulation()} die \code{splits} des Aufrufs).
  }
  \item{x}{Ein \code{SimLevWrapperNav}.}
  \item{...}{Bei \code{print} ignoriert; bei \code{[} die Zeilen- und Spaltenauswahl
    wie in \code{[.data.frame} (\code{i}, \code{j}, \code{drop}).}
}
\details{
  \strong{1. Innere Bruttorechnung.}
  \code{simulation(d, strategy, start_value = S, costs = sim_costs(order_fee = order_fee),
  rebalance = rebalance, splits = splits, tax = NULL, fractions = TRUE)} mit
  \eqn{S} = \code{volume}, ohne \code{volume} \eqn{S = 100}. \code{d} ist \code{data} ab
  der ersten Zeile, in der mindestens eine innere Kursspalte einen Wert hat. NAV-Tage sind
  die Zeilen von \code{d}, die die innere Rechnung nicht als aufgefüllt führt; an Tagen, an
  denen alle inneren Kurse \code{NA} sind (oder die das Attribut \code{filled} als
  aufgefüllt kennzeichnet), gibt es keinen Anteilswert. \eqn{G_t} ist der Gesamtwert der
  inneren Rechnung am NAV-Tag \eqn{t}; vor dem ersten NAV-Tag gilt \eqn{G_0 = S}.
  Der Paketzustand der Ordergebühren wird gesichert und, auch bei Fehlern, wiederhergestellt.

  \strong{2. Verwaltungsgebühr täglich je Kalendertag.} Mit \eqn{U_0 = 100}:
  \deqn{a_t = U_{t-1} \cdot G_t / G_{t-1}, \quad f_t = a_t \cdot (fee / 100 \cdot \Delta d_t / D_t), \quad U_t = a_t - f_t.}
  \eqn{\Delta d_t} = Kalendertage seit dem vorigen NAV-Tag (am ersten NAV-Tag seit dem
  ersten Tag von \code{d}, in der Regel 0), \eqn{D_t} = 366 im Schaltjahr des Datums
  \eqn{t}, sonst 365. Ein Zeitraum über den Jahreswechsel zählt mit \eqn{D_t} des Jahres
  von \eqn{t}. Rechenfolge: \eqn{((fee / 100) \cdot \Delta d_t) / D_t}, dann mal \eqn{a_t}.

  \strong{3. Performancegebühr (High-Water-Mark über die ganze Laufzeit).} Mit \eqn{H = 100}:
  \deqn{A_t = pf / 100 \cdot \max(0, U_t - H), \quad NAV_t = U_t - A_t}{A_t = pf / 100 * max(0, U_t - H), NAV_t = U_t - A_t}
  mit \eqn{pf} = \code{performance_fee}.
  Am letzten NAV-Tag jedes Kalenderjahres wird festgeschrieben: \eqn{U_t := NAV_t}, danach
  \eqn{H := \max(H, U_t)}. Am letzten NAV-Tag insgesamt wird nicht festgeschrieben; die
  Abgrenzung steckt bereits im Anteilswert. Die Verwaltungsgebühr bemisst sich an
  \eqn{U} (vor der Abgrenzung).

  \strong{Näherungen.} Die Kosten werden auf die Bruttorechnung angewandt; feste
  Ordergebühren beziehen sich damit auf das Volumen ohne abgezogene Fondskosten.
  Einzahlungen der Anleger ändern das Fondsvolumen nicht. Eine Ordergebühr beim Start
  und ein innerer Spread senken schon den ersten Anteilswert (\eqn{100 \cdot G_1 / S}).

  \strong{Randfälle.} Ein einziger Datentag ergibt einen Anteilswert ohne Gebühr (die
  innere Rechnung warnt dann wie \code{simulation()} vor nicht definierten Kennzahlen).
  Sind alle inneren Kurse \code{NA}, fehlt eine innere Spalte oder ist \eqn{G_{t-1} \le 0}
  bzw. \eqn{G_t} nicht endlich und positiv, folgt ein Fehler. Meldungen der inneren Rechnung
  erscheinen als \dQuote{Hinweis: wrapper_nav (innere Rechnung): ...}, Warnungen und Fehler
  als \dQuote{wrapper_nav (innere Rechnung): ...}. Rechtliche Einordnung der
  Performancegebühr: siehe \code{\link{wrapper_config}}.
}
\value{
  Objekt der Klasse \code{c("SimLevWrapperNav", "data.frame")} mit einer Zeile je NAV-Tag:
  \describe{
    \item{date}{Datum.}
    \item{nav}{Anteilswert \eqn{NAV_t} (Start 100).}
    \item{gross}{Bruttowert \eqn{100 \cdot G_t / G_0} ohne Fondskosten.}
    \item{fee}{Verwaltungsgebühr des Tages je Anteil \eqn{f_t}.}
    \item{perf_fee}{Abgegrenzte (aufgelaufene, noch nicht festgeschriebene)
      Performancegebühr je Anteil \eqn{A_t} am Tag \eqn{t}.}
    \item{perf_paid}{Am Tag festgeschriebene Performancegebühr je Anteil (am letzten
      NAV-Tag eines Kalenderjahres \eqn{A_t}, sonst 0).}
    \item{hwm}{High-Water-Mark \eqn{H} nach dem Tag (nach einer Festschreibung).}
  }
  Attribute: \code{inner} (das innere \code{SimLevResult}) und \code{wrapper} (das
  \code{SimLevWrapperConfig}). \code{print} zeigt Zeitraum, Kosten p. a. und Endwert
  (mit Brutto) und liefert \code{x} unsichtbar zurück.

  \strong{Auswahl.} Jede Auswahl von Zeilen oder Spalten (\code{x[i, ]}, \code{x[j]},
  \code{x[i, j]}, \code{x[]}, \code{head()}, \code{tail()}, \code{subset()}) liefert einen
  gewöhnlichen \code{data.frame} ohne Klasse \code{SimLevWrapperNav} und ohne die Attribute
  \code{inner} und \code{wrapper}, weil das innere Ergebnis nicht mehr zum Ausschnitt passt
  (Python: \code{pandas.DataFrame} ohne \code{attrs}, Julia: \code{rows()} ohne Klasse und
  Attribute). Für \code{\link{withdrawal_simulation}} ist ein Ausschnitt keine Renditequelle
  mehr: \code{withdrawal_simulation(withdrawal_cohorts(x[i, ], price = "nav", inflation = 2))}.
}
\examples{
set.seed(1)
d <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 730))
d$Welt <- 100 * cumprod(1 + rnorm(730, 3e-4, 0.01))
d$Gold <- 50 * cumprod(1 + rnorm(730, 1e-4, 0.008))
w <- wrapper_config(create_strategy(Welt = asset_config("etf", share = 0.7),
                                    Gold = asset_config("etc", share = 0.3)),
                    costs = funds_costs(fee = 0.95, performance_fee = 10))
nv <- wrapper_nav(d, w)
nv
tail(nv$nav, 1) / tail(nv$gross, 1) - 1        # Kosten über die Laufzeit
ws <- withdrawal_simulation(nv, withdrawal_rule("percent", rate = 4), years = 1,
                            frequency = "quarter")
}
\seealso{
  \code{\link{wrapper_config}}, \code{\link{simulation}}, \code{\link{withdrawal_simulation}}
}
