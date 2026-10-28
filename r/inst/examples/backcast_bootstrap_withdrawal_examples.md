# Backcast, Bootstrap-Studien und Entnahmephase: Arbeitsablauf

Diese Sammlung zeigt, wie die Projekt-Skripte `02 Funds Data` und
`06 Bootstraps` mit den neuen Paketfunktionen aussehen und wie die
Entnahmephase an gespeicherte Simulationsergebnisse anschließt. Spaltennamen
folgen den Skripten (`eu_ndtr_l2`, `eu_rate`, `amundi_l2_eu_in_eu`, …).

Alle Zinsen, Kosten und Raten folgen der **Prozent-Konvention** des Pakets
(`ter = 0.5` heißt 0,5 % p. a., `rate = 4` heißt 4 %).

---

## 1. Backcast eines Produkts

### 1.1 Gehebelter ETF auf einen bereits gehebelten Index (Skript 02)

Der Amundi MSCI USA Leveraged Daily bildet den Index *MSCI USA Leveraged 2x
Daily Net TR in EUR* ab. Der Hebel steckt also schon im Index, daher
`leverage = 1`. Die TER wechselte am 10.10.2023 von 0,35 % auf 0,50 %.

```r
library(SimLev)

fit <- backcast_fit(
  msci_full_data,
  product = "amundi_l2_eu_in_eu",
  index   = "eu_ndtr_l2",
  ter     = c("2010-02-24" = 0.35, "2023-10-10" = 0.50),
  leverage = 1,
  accrual = "geometric",          # wie im Skript: (TER + 1)^(1/Tage) - 1
  method  = "grid", grid = seq(-1, 1, by = 0.001)   # Gittersuche wie im Skript
)
fit                 # Parameter, Tracking Error/Difference, Out-of-Sample-Test
plot(fit)           # Pfadabweichung 1 - Sim/Produkt und Verlustkurve

bc <- backcast(fit, rebase = 100)   # Rueckrechnung vor 2010 + echte Kurse danach
plot(bc)
```

`fit$params$drag` ist die gefittete Restabweichung in Prozent p. a.,
`fit$drag_per_day` dieselbe Zahl in der Einheit des Skripts (Prozent je
Kalendertag; das Skript fand 0,0002).

Hinweis: Die Prozentmetriken von `search_metrics` im Skript waren konstant,
weil `x / (x + 1e-8)` immer ungefähr 1 ergibt. `fit$grid_metrics` verwendet
stattdessen die relative Abweichung `1 - Sim/Produkt`.

### 1.2 Hebel aus einem ungehebelten Index plus Tagesgeld (MSCI-Formel)

```r
fit2 <- backcast_fit(
  eu_msci_model,
  product  = "eu_ndtr_l2",        # offizielle Hebelindexreihe ab 2012
  index    = "eu_ndtr_l1",
  leverage = 2,
  rate     = "eu_rate",           # ESTR/EONIA/FIBOR in Prozent p. a.
  fit      = c("drag", "spread"), # Restabweichung und Finanzierungsspread
  objective = "hybrid"            # taeglicher Tracking Error + kumulierte Abweichung
)
```

Short-Produkte erhalten über `(1 - L) * Zins` automatisch den Zinsertrag auf
Kapital und Leerverkaufserlös (`L = -1` ergibt `-R + 2 * Zins`).

### 1.3 Proxy-Rückrechnung eines Index (Skript 01, GAM-Ersatz)

```r
fit3 <- backcast_fit(us_msci_data, product = "us_price", index = "us_sp500",
                     model = "spline", fit = "drag")
us_price_long <- backcast(fit3)
```

### 1.4 Asynchrone Schlusskurse

Xetra schließt um 17:30 Uhr, der US-Index erst um 22:00 Uhr. Dämpfen lässt
sich das mit Renditen über mehrere Tage (`objective = "return", horizon = 5`)
oder mit einer automatischen Lag-Suche (`lag = "auto"`). Wenn verfügbar, ist
die NAV-Reihe die bessere Wahl als der Börsenkurs.

---

## 2. Bootstrap-Studie (Skript 06)

```r
cfg <- bootstrap_config(
  indices = c(us = "us_index_l1_return", eu = "eu_index_l1_return"),
  regime_index = "us",
  aux   = c(rate = "eu_rate"),                 # Tagesgeld mitziehen
  letfs = list(list(base = "eu", leverage = 2, finance = "rate", expense = 0.5))
)

# Signale bekommen den Pfad als data.frame mit den Spalten us, eu, eu_l2, rate;
# TTR::SMA() aus dem separat zu installierenden Paket TTR (keine Abhängigkeit
# von SimLev; install.packages("TTR"))
sma_eur <- function(df, n = 310) {
  s <- TTR::SMA(df$eu, n = n)
  list(buy = df$eu >= s, sell = df$eu < s)
}
sma_usd <- function(df, n = 430) {
  s <- TTR::SMA(df$us, n = n)
  list(buy = df$us >= s, sell = df$us < s)
}

letf_bnh <- create_strategy(letf = asset_config("etf", "bnh", partial_exemption = 30))
letf_sma <- create_strategy(letf = asset_config("etf", "signal", partial_exemption = 30,
                                                signal_buy = "buy", signal_sell = "sell"))
dca <- list(dca_mode = TRUE, dca_value = 1000, dca_span = 1, dca_unit = "month")

strategies <- list(
  bh_ls      = list(strategy = letf_bnh, map = c(letf = "eu_l2")),
  bh_dca     = list(strategy = letf_bnh, map = c(letf = "eu_l2"), args = dca),
  sma_eur_ls = list(strategy = letf_sma, map = c(letf = "eu_l2"), signal = sma_eur),
  sma_usd_ls = list(strategy = letf_sma, map = c(letf = "eu_l2"), signal = sma_usd)
)

study <- bootstrap_study(
  msci_data, cfg, method = "stationary", n = 100000,
  params = list(L = 250), strategies = strategies,
  start = "1975-01-01", burn_in = 731,     # wie keep_dates ab 1977
  sim_args = list(start_value = 1000),
  benchmark = "bh_ls", cores = parallel::detectCores() - 2,
  chunk_size = 250, chunk_dir = "./03 Results Data/08 Strategy Bootstrap Analysis/Chunks",
  seed = 42, keep_returns = "year"              # fuer die Entnahmephase
)

summary(study)                                   # Verteilungen + gepaarter Vergleich
bootstrap_probability(study,
  ttwror = ttwror >= 0.1313580,
  maxdd  = max_drawdown <= 0.9451193,
  joint  = ttwror >= 0.1313580 & max_drawdown <= 0.9451193)
```

Hinweise zu den Kennzahlen: Für die Strategie mit Sparplan (`bh_dca`) ist
`cagr` die geldgewichtete Rendite (XIRR) und `max_drawdown` wird
auf dem zeitgewichteten Wertindex gemessen; `summary()` beschriftet die
CAGR entsprechend. Für den Vergleich von Strategien mit und ohne Sparplan
eignet sich `ttwror`. Das ursprüngliche Projektskript übergab zusätzlich
`funds_fee = 1, bonus_fee = 5`. Diese Kosten gehören zum Fondsmodus
und blieben dort ohne ihn ohne Wirkung. Sie sind deshalb oben weggelassen; das
Ergebnis ist dasselbe. Für eine Studie mit Fondskosten
`sim_args = list(funds = funds_costs(fee = 1, performance_fee = 5))` angeben.

Die Pfade werden nach der Auswertung verworfen. Der Speicherbedarf hängt daher
nicht von `n` ab, anders als bei der Zwischenspeicherung von 100.000 Pfaden im
Skript. Ein abgebrochener Lauf wird mit gleichem `seed` und `chunk_dir` dort
fortgesetzt, wo er stand. Pfad *i* ist für jede Kernzahl identisch und
identisch zu `bootstrap(..., seed = 42)$paths[[i]]`.

Hinweise zur Methodik:

- Trendfolge-Signale brauchen Blöcke, die mindestens so lang wie der
  Signal-Vorlauf sind. Daher die Ergebnisse über mehrere Blocklängen
  vergleichen, z. B. mit `ess = TRUE, ess_grid = list(L = c(20, 60, 250, 500))`.
- `bootstrap_block_length(log(returns), "abs")` schätzt die Blocklänge nach
  Politis & White aus dem Volatilitäts-Clustering.
- `method = "raw"` und `"wild"` zerstören die Zeitabhängigkeit. Sie dienen als
  Nullmodell, nicht als realistische Pfade.
- GARCH-Verfahren ziehen die Residuen aller Reihen vom selben historischen Tag
  (Filtered Historical Simulation). So bleibt die Korrelation zwischen
  Index und Wechselkurs erhalten.

Alle Verfahren nacheinander, wie in der Hauptschleife des Skripts:

```r
methods <- list(raw = list(), stationary = list(L = 250), block = list(block_length = 250),
                circular = list(block_length = 250), regime = list(n_regimes = 3, vol_window = 60),
                evt = list(tail_prob = 0.05), garch = list(), gjr_garch = list())
studies <- lapply(names(methods), function(m)
  bootstrap_study(msci_data, cfg, m, n = 10000, params = methods[[m]], strategies = strategies,
                  start = "1975-01-01", burn_in = 731, benchmark = "bh_ls", seed = 42,
                  cores = 8))
names(studies) <- names(methods)
do.call(rbind, lapply(names(studies), function(m)
  cbind(method = m, bootstrap_probability(studies[[m]], joint = ttwror >= 0.13 & max_drawdown <= 0.95))))
```

---

## 3. Entnahmephase

Die Entnahmephase ist bewusst von `simulation()` getrennt. Jedes Ergebnis
lässt sich speichern und später als Renditequelle verwenden.

### 3.1 Aus einem gespeicherten Simulationslauf

```r
res <- simulation(eu_data, create_strategy(eu_l2 = asset_config("etf", "bnh", partial_exemption = 30)),
                  start_value = 1e5)
saveRDS(res, "lauf_letf.rds")

res <- readRDS("lauf_letf.rds")
head(result_index(res))      # zeitgewichteter Wertindex (ohne Ein-/Auszahlungen)

# Historische Kohorten ueber den Verlauf des Ergebnisses (30 Jahre, monatliche Starts)
wd <- withdrawal_simulation(res, withdrawal_rule("guyton_klinger", rate = 5),
                            years = 30, inflation = 2, start_value = 1e6,
                            tax = tax_profile(), partial_exemption = 30)
wd
plot(wd)
```

### 3.2 Anspar- und Entnahmephase verbinden

Wird `start_value` als Ansparergebnis übergeben, gilt dessen Endwert als
Startvermögen (ein Endwert ≤ 0 ist ein Fehler). Ohne Angabe von
`cost_basis` gilt:

- Wurde die Ansparphase mit `tax = tax_profile()` gerechnet (Element
  `open_lots`) und rechnet die Entnahmephase ebenfalls mit
  `tax = tax_profile()`, übernimmt sie die offenen Lots und verkauft je
  Asset die ältesten zuerst (FIFO, wie die Engine). Nicht ausdrücklich
  angegebene `partial_exemption`, `loss_carryforward` (allgemeiner Verlusttopf),
  `sale_cost` (halber Spread) und der im ersten Planjahr schon verbrauchte
  Sparer-Pauschbetrag werden aus dem Ergebnis übernommen, ohne gehaltene
  Fonds auch `vorabpauschale = FALSE`. Ein Hinweis nennt die Werte, das
  Ergebnis führt sie unter `adopted`.
- Hält das Ergebnis am letzten Tag nur noch Cash (z. B. mit
  `liquidate = TRUE`), gilt 100 %; alle Gewinne sind schon versteuert.
- Sonst die Näherung (Startkapital brutto + Einzahlungen) / Endwert mit
  Durchschnittskosten, bei `tax = tax_profile()` in der Entnahmephase mit
  Warnung. Sie behandelt bereits versteuerte Gewinne wie stille Reserven.

Kirchensteuer und Einkommensteuertarif der Ansparphase übernimmt die
Entnahmephase nicht (fester Satz `tax_rate`; weitere Grenzen in
`?withdrawal_simulation`). Im Beispiel unten ist die Ansparphase ohne
`tax = tax_profile()` gerechnet, es gilt also die Näherung (mit Warnung).

```r
anspar <- simulation(eu_data, strat, start_value = 1e4, dca = dca_plan(500, 1, unit = "month"))
wd <- withdrawal_simulation(res, withdrawal_rule("vanguard", rate = 4),
                            start_value = anspar, years = 30, inflation = 2,
                            tax = tax_profile())
```

### 3.3 Auf den Pfaden einer Bootstrap-Studie

```r
wd_bh  <- withdrawal_simulation(study, withdrawal_rule("constant", rate = 4),
                                strategy = "bh_ls", inflation = 2, years = 30)
wd_sma <- withdrawal_simulation(study, withdrawal_rule("constant", rate = 4),
                                strategy = "sma_eur_ls", inflation = 2, years = 30)
c(bh = summary(wd_bh)$success_rate, sma = summary(wd_sma)$success_rate)
```

Mit `keep_aux = "cpi"` in `bootstrap_study()` (bei einer CPI-Zusatzreihe in
`aux`) wird die Inflation pfadweise mitgebootstrappt:
`withdrawal_simulation(study, ..., inflation = "cpi")`. Am besten
kennzeichnet `aux_type` in `bootstrap_config()` die Art der Reihe, z. B.
`aux = c(rate = "eu_rate", cpi = "eu_cpi"), aux_type = c(cpi = "level")`
für einen Preisindex (ohne Angabe gilt eine `keep_aux`-Reihe weiter als
Niveau); eine Inflationsrate in Prozent p. a. wäre `aux_type = c(cpi = "rate")`.

### 3.4 Sichere Entnahmerate und Regelvergleich

```r
co <- withdrawal_cohorts(bc, price = "value", inflation = 2, years = 30)
summary(withdrawal_simulation(co, withdrawal_rule("constant", rate = 4)))$swr   # historische SWR
withdrawal_max_rate(co, withdrawal_rule("guyton_klinger"), success = 0.95)

rules <- c("constant", "vanguard", "guyton_klinger", "floor_ceiling", "endowment", "vpw")
sapply(rules, function(r) {
  s <- summary(withdrawal_simulation(co, withdrawal_rule(r, rate = 4.5)))
  c(Erfolg = s$success_rate, Sicherheitsaequivalent = s$ce_spending[3], Endvermoegen = s$terminal_real[3])
})
```
