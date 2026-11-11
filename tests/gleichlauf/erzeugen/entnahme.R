# tests/gleichlauf/erzeugen/entnahme.R – Bereich entnahme als Szenarien und Tabellen (seit 1.4.2; bis 1.4.1 Einzelfälle je Modul und Funktion).
# Entnahmephase: Regeln und Horizonte, withdrawal_simulation (Regeln, Inflation, Horizont, Einkommen, Steuer),
# Kohorten, Pfade aus dem Bootstrap, höchste und perfekte Entnahmerate, FIFO-Übernahme der Lots, Eingabeprüfungen.
#   gleichlauf  Szenarien: je Szenario ein Aufruf bzw. eine kurze Aufrufkette, die mehrere Ergebnisse zugleich prüft
#               (Teile; Name = bisherige Fallkennung). Feld note: "prüft: …"
#   fehler      je Funktion eine Tabelle "Eingabe -> Meldung" (jede Zeile ein eigener Aufruf)
#   ausgabe     print()/summary() als Tabelle
# Herkunft der Erwartung: R. Daten und Hilfen wie in tests/werkzeuge/breite/entnahme.R (Breitenprüfung mit allen bisherigen Fällen).
# Aufruf (Repo-Wurzel): LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript tests/gleichlauf/erzeugen/entnahme.R
# Ausgabe tests/{gleichlauf,fehler,ausgabe}/faelle/entnahme.jsonl.gz (Format: ref_tools.R, Szenarien: szenario_tools.R).
source("tests/gleichlauf/erzeugen/ref_tools.R"); source("tests/gleichlauf/erzeugen/szenario_tools.R")
ref_bereich("entnahme")
EIN <- list()   # Eingaben je bisherigem Fall (Momentaufnahme an der Stelle, an der der Fall im alten Generator stand)

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul withdrawal
# ════════════════════════════════════════════════════════════════════════════════════════════════════
P <- "from simlev.bootstrap import *\nfrom simlev.withdrawal import *\nimport simlev.withdrawal as W\nimport simlev._withdrawal_core as WC\n"
JP <- "using SimLev.Bootstrap, SimLev.Withdrawal\nconst B = SimLev.Bootstrap\nconst W = SimLev.Withdrawal\nconst WC = SimLev.WithdrawalCore\n"
# ── Daten ───────────────────────────────────────────────────────────────────
set.seed(1); R <- matrix(exp(rnorm(30 * 12, 0.05, 0.15)), 30)
set.seed(2); Rm <- matrix(exp(rnorm(120 * 4, 0.05 / 12, 0.15 / sqrt(12))), 120)
set.seed(3); Rq <- matrix(exp(rnorm(42 * 3, 0.0125, 0.08)), 42)
set.seed(4); m <- data.frame(date = seq.Date(as.Date("1990-01-31") + 1, by = "month", length.out = 240) - 1)
m$depot <- 100 * cumprod(exp(rnorm(240, 0.005, 0.04))); m$cpi <- 100 * 1.02^((0:239) / 12)
m$infl <- 2 + sin((1:240) / 20); m$cape <- 15 + 10 * abs(sin((1:240) / 30)); m$br <- 1 + (1:240) / 100
set.seed(5); dd <- data.frame(date = seq.Date(as.Date("2001-01-01"), as.Date("2006-12-31"), by = "day"))
dd$px <- 100 * cumprod(1 + rnorm(nrow(dd), 2.5e-4, 0.01)); dd$cpi <- 100 * 1.02^(as.numeric(dd$date - dd$date[1]) / 365.25)
I <- list(R = R, Rm = Rm, Rq = Rq, m = m, dd = dd)
# ── withdrawal_rule ─────────────────────────────────────────────────────────
types <- c("constant", "percent", "vanguard", "guyton_klinger", "floor_ceiling", "clyatt", "ratchet", "endowment",
           "one_over_n", "vpw", "abw", "cape", "sensible", "hebeler")
for (t in types) EIN[[paste0("withdrawal/", paste0("rule_", t))]] <- list()
EIN[["withdrawal/rule_bounds_min"]] <- list()
EIN[["withdrawal/rule_pfx"]] <- list()
EIN[["withdrawal/rule_warn_rate"]] <- list()
EIN[["withdrawal/rule_warn_frac2"]] <- list()
RE <- list(
  rate120 = c("withdrawal_rule('constant', rate = 120)", "withdrawal_rule(type='constant', rate=120)",
    'withdrawal_rule("constant"; rate = 120)'),
  ratevec = c("withdrawal_rule('constant', rate = c(4, 5))", "withdrawal_rule(type='constant', rate=[4, 5])",
    'withdrawal_rule("constant"; rate = [4, 5])'),
  ratena = c("withdrawal_rule('constant', rate = NA)", "withdrawal_rule(type='constant', rate=simlev._r.fmt.NA_REAL)",
    'withdrawal_rule("constant"; rate = SL.NA)'),
  ratechr = c("withdrawal_rule('constant', rate = '4')", "withdrawal_rule(type='constant', rate='4')",
    'withdrawal_rule("constant"; rate = "4")'),
  smooth = c("withdrawal_rule('endowment', smoothing = NA)", "withdrawal_rule(type='endowment', smoothing=simlev._r.fmt.NA_REAL)",
    'withdrawal_rule("endowment"; smoothing = SL.NA)'),
  vpwage = c("withdrawal_rule('vpw', age = 70, max_age = 65)", "withdrawal_rule(type='vpw', age=70, max_age=65)",
    'withdrawal_rule("vpw"; age = 70, max_age = 65)'),
  minmax = c("withdrawal_rule('constant', min_real = 5e4, max_real = 1e4)", "withdrawal_rule(type='constant', min_real=5e4, max_real=1e4)",
    'withdrawal_rule("constant"; min_real = 5e4, max_real = 1e4)'),
  floor95 = c("withdrawal_rule('clyatt', floor95 = 150)", "withdrawal_rule(type='clyatt', floor95=150)",
    'withdrawal_rule("clyatt"; floor95 = 150)'),
  cut = c("withdrawal_rule('guyton_klinger', cut = 150)", "withdrawal_rule(type='guyton_klinger', cut=150)",
    'withdrawal_rule("guyton_klinger"; cut = 150)'),
  icap = c("withdrawal_rule('guyton_klinger', inflation_cap = -5)", "withdrawal_rule(type='guyton_klinger', inflation_cap=-5)",
    'withdrawal_rule("guyton_klinger"; inflation_cap = -5)'),
  skip = c("withdrawal_rule('guyton_klinger', skip_inflation = 'ja')", "withdrawal_rule(type='guyton_klinger', skip_inflation='ja')",
    'withdrawal_rule("guyton_klinger"; skip_inflation = "ja")'),
  skipna = c("withdrawal_rule('guyton_klinger', skip_inflation = c(TRUE, FALSE))", "withdrawal_rule(type='guyton_klinger', skip_inflation=[True, False])",
    'withdrawal_rule("guyton_klinger"; skip_inflation = [true, false])'),
  gap = c("withdrawal_rule('ratchet', ratchet_gap = -1)", "withdrawal_rule(type='ratchet', ratchet_gap=-1)",
    'withdrawal_rule("ratchet"; ratchet_gap = -1)'),
  maxrate = c("withdrawal_rule('vpw', max_rate = 0)", "withdrawal_rule(type='vpw', max_rate=0)",
    'withdrawal_rule("vpw"; max_rate = 0)'),
  floor = c("withdrawal_rule('vanguard', floor = 120)", "withdrawal_rule(type='vanguard', floor=120)",
    'withdrawal_rule("vanguard"; floor = 120)'),
  ceil = c("withdrawal_rule('vanguard', ceiling = Inf)", "withdrawal_rule(type='vanguard', ceiling=np.inf)",
    'withdrawal_rule("vanguard"; ceiling = Inf)'),
  fv = c("withdrawal_rule('abw', fv = -1)", "withdrawal_rule(type='abw', fv=-1)",
    'withdrawal_rule("abw"; fv = -1)'),
  expret = c("withdrawal_rule('abw', exp_return = -100)", "withdrawal_rule(type='abw', exp_return=-100)",
    'withdrawal_rule("abw"; exp_return = -100)'),
  type = c("withdrawal_rule('foo')", "withdrawal_rule(type='foo')",
    'withdrawal_rule("foo")'),
  unused = c("withdrawal_rule('one_over_n', horizon = 30)", "withdrawal_rule(type='one_over_n', horizon=30)",
    'withdrawal_rule("one_over_n"; horizon = 30)'),
  maxreal = c("withdrawal_rule('constant', max_real = -1)", "withdrawal_rule(type='constant', max_real=-1)",
    'withdrawal_rule("constant"; max_real = -1)'))
for (k in names(RE)) EIN[[paste0("withdrawal/", paste0("rule_err_", k))]] <- list()
EIN[["withdrawal/ppy_err"]] <- list()
dts1 <- c("2000-01-31", "2000-01-15", "2000-02-29", "2001-03-31")
for (s in dts1) for (f in c("year", "quarter", "month")) {
    EIN[[paste0("withdrawal/", sprintf("anniv_%s_%s", gsub("-", "", s), f))]] <- list()
}
EIN[["withdrawal/period_ends"]] <- list()
CE <- list(
  cols = c("withdrawal_cohorts(m, price = 'x')", "withdrawal_cohorts(m, price='x')",
    'withdrawal_cohorts(m; price = "x")'),
  gap = c("withdrawal_cohorts(m[-50, ], price = 'depot', years = 10, step = 'year')", "withdrawal_cohorts(m.drop(index=49), price='depot', years=10, step='year')",
    'withdrawal_cohorts(SL.rows(m, setdiff(1:240, 50)); price = "depot", years = 10, step = "year")'),
  annual = c("withdrawal_cohorts(m[seq(1, 240, 12), ], price = 'depot', years = 5)", "withdrawal_cohorts(m.iloc[::12], price='depot', years=5)",
    'withdrawal_cohorts(SL.rows(m, 1:12:240); price = "depot", years = 5)'),
  years = c("withdrawal_cohorts(m, price = 'depot', years = 2.5)", "withdrawal_cohorts(m, price='depot', years=2.5)",
    'withdrawal_cohorts(m; price = "depot", years = 2.5)'),
  years0 = c("withdrawal_cohorts(m, price = 'depot', years = 0)", "withdrawal_cohorts(m, price='depot', years=0)",
    'withdrawal_cohorts(m; price = "depot", years = 0)'),
  yearsvec = c("withdrawal_cohorts(m, price = 'depot', years = c(1, 2))", "withdrawal_cohorts(m, price='depot', years=[1, 2])",
    'withdrawal_cohorts(m; price = "depot", years = [1, 2])'),
  short = c("withdrawal_cohorts(m, price = 'depot', years = 30)", "withdrawal_cohorts(m, price='depot', years=30)",
    'withdrawal_cohorts(m; price = "depot", years = 30)'),
  ratebad = c("x <- m; x$infl[30] <- -150; withdrawal_cohorts(x, price = 'depot', inflation = 'infl', inflation_type = 'rate_pa', years = 1)",
              "x = m.copy(); x.loc[29, 'infl'] = -150; withdrawal_cohorts(x, price='depot', inflation='infl', inflation_type='rate_pa', years=1)",
    '(x = copy(m); x.infl[30] = -150; withdrawal_cohorts(x; price = "depot", inflation = "infl", inflation_type = "rate_pa", years = 1))'),
  freq = c("withdrawal_cohorts(m, price = 'depot', frequency = 'week')", "withdrawal_cohorts(m, price='depot', frequency='week')",
    'withdrawal_cohorts(m; price = "depot", frequency = "week")'))
for (k in names(CE)) EIN[[paste0("withdrawal/", paste0("coh_err_", k))]] <- I
PE <- list(med = c("withdrawal_perfect_rate(c(0.05, 0.02, -0.1))", "withdrawal_perfect_rate([0.05, 0.02, -0.1])",
    'withdrawal_perfect_rate([0.05, 0.02, -0.1])'),
           na = c("withdrawal_perfect_rate(c(1.05, NA))", "withdrawal_perfect_rate([1.05, simlev._r.fmt.NA_REAL])",
    'withdrawal_perfect_rate([1.05, SL.NA])'),
           neg = c("withdrawal_perfect_rate(c(1.05, 1.1, -0.2))", "withdrawal_perfect_rate([1.05, 1.1, -0.2])",
    'withdrawal_perfect_rate([1.05, 1.1, -0.2])'),
           leg = c("withdrawal_perfect_rate(c(1.05, 1.02), legacy = -1)", "withdrawal_perfect_rate([1.05, 1.02], legacy=-1)",
    'withdrawal_perfect_rate([1.05, 1.02]; legacy = -1)'),
           legv = c("withdrawal_perfect_rate(c(1.05, 1.02), legacy = c(1, 2))", "withdrawal_perfect_rate([1.05, 1.02], legacy=[1, 2])",
    'withdrawal_perfect_rate([1.05, 1.02]; legacy = [1, 2])'),
           inf = c("withdrawal_perfect_rate(c(1.05, Inf))", "withdrawal_perfect_rate([1.05, np.inf])",
    'withdrawal_perfect_rate([1.05, Inf])'))
for (k in names(PE)) EIN[[paste0("withdrawal/", paste0("pwr_err_", k))]] <- list()
for (t in setdiff(types, "cape")) EIN[[paste0("withdrawal/", paste0("ws_", t))]] <- I
EIN[["withdrawal/ws_income1"]] <- list()
# seit 1.1.0: Kirchensteuer und Günstigerprüfung in der Entnahme (Satz wie simulation(), .tax_rates)
TXA <- "withdrawal_simulation(R[, 1:4], withdrawal_rule('guyton_klinger', rate = 5), start_value = 5e5, inflation = 2, cost_basis = 60, base_rate = 2.5, tax = tax_profile(%s))"
TXP <- "withdrawal_simulation(R[:, :4], rule=withdrawal_rule(type='guyton_klinger', rate=5), start_value=5e5, inflation=2, cost_basis=60, base_rate=2.5, tax=simlev.tax_profile(%s))"
TXJ <- 'withdrawal_simulation(R[:, 1:4], withdrawal_rule("guyton_klinger"; rate = 5); start_value = 5e5, inflation = 2, cost_basis = 60, base_rate = 2.5, tax = SL.tax_profile(; %s))'
TXC <- list(
  church = c("church_tax = 9", "church_tax=9", "church_tax = 9"),
  church8 = c("church_tax = 8, sparer_pauschbetrag = 2000", "church_tax=8, sparer_pauschbetrag=2000", "church_tax = 8, sparer_pauschbetrag = 2000"),
  gp_yes = c("guenstigerpruefung = TRUE, income = income_rate(20)", "guenstigerpruefung=True, income=simlev.income_rate(20)",
             "guenstigerpruefung = true, income = SL.income_rate(20)"),
  gp_church_soli = c("church_tax = 8, guenstigerpruefung = TRUE, income = income_rate(24, soli_rate = 5.5)",
                     "church_tax=8, guenstigerpruefung=True, income=simlev.income_rate(24, soli_rate=5.5)",
                     "church_tax = 8, guenstigerpruefung = true, income = SL.income_rate(24; soli_rate = 5.5)"),
  gp_no = c("guenstigerpruefung = TRUE, income = income_rate(42)", "guenstigerpruefung=True, income=simlev.income_rate(42)",
            "guenstigerpruefung = true, income = SL.income_rate(42)"),
  gp_church_no = c("church_tax = 9, guenstigerpruefung = TRUE, income = income_rate(26)", "church_tax=9, guenstigerpruefung=True, income=simlev.income_rate(26)",
                   "church_tax = 9, guenstigerpruefung = true, income = SL.income_rate(26)"),
  gp_nomr = c("church_tax = 9, guenstigerpruefung = TRUE", "church_tax=9, guenstigerpruefung=True", "church_tax = 9, guenstigerpruefung = true"),
  mr_only = c("income = income_rate(20)", "income=simlev.income_rate(20)", "income = SL.income_rate(20)"),
  rate_gp = c("rate = 30, guenstigerpruefung = TRUE, income = income_rate(28)", "rate=30, guenstigerpruefung=True, income=simlev.income_rate(28)",
              "rate = 30, guenstigerpruefung = true, income = SL.income_rate(28)"))
for (k in names(TXC)) EIN[[paste0("withdrawal/", paste0("ws_tax_", k))]] <- I
# Tarifweg (seit 1.3.0) T1 (income_tariff()) in der Entnahme: Veranlagung je Planjahr und Pfad im Kern, Saldo mit der ersten
# Entnahme des Folgejahres; zvE nominal je Planjahr (Zahl, Vektor ohne Namen, benannt nur mit SimLevResult)
TTC <- list(
  num = c("guenstigerpruefung = TRUE, income = income_tariff(30000)", "guenstigerpruefung=True, income=simlev.income_tariff(30000)",
          "guenstigerpruefung = true, income = SL.income_tariff(30000)"),
  vec = c("church_tax = 9, guenstigerpruefung = TRUE, income = income_tariff(c(rep(6000, 10), rep(40000, 10), rep(90000, 10)))",
          "church_tax=9, guenstigerpruefung=True, income=simlev.income_tariff([6000] * 10 + [40000] * 10 + [90000] * 10)",
          "church_tax = 9, guenstigerpruefung = true, income = SL.income_tariff(vcat(fill(6000.0, 10), fill(40000.0, 10), fill(90000.0, 10)))"),
  church = c("church_tax = 9, income = income_tariff(50000)", "church_tax=9, income=simlev.income_tariff(50000)",
             "church_tax = 9, income = SL.income_tariff(50000)"),
  church8_gp = c("church_tax = 8, guenstigerpruefung = TRUE, income = income_tariff(12000)",
                 "church_tax=8, guenstigerpruefung=True, income=simlev.income_tariff(12000)",
                 "church_tax = 8, guenstigerpruefung = true, income = SL.income_tariff(12000)"),
  gp_yes = c("guenstigerpruefung = TRUE, income = income_tariff(4000)", "guenstigerpruefung=True, income=simlev.income_tariff(4000)",
             "guenstigerpruefung = true, income = SL.income_tariff(4000)"),
  gp_no = c("guenstigerpruefung = TRUE, income = income_tariff(150000)", "guenstigerpruefung=True, income=simlev.income_tariff(150000)",
            "guenstigerpruefung = true, income = SL.income_tariff(150000)"),
  nogp = c("income = income_tariff(30000)", "income=simlev.income_tariff(30000)", "income = SL.income_tariff(30000)"),
  own = c("church_tax = 9, guenstigerpruefung = TRUE, income = income_tariff(25000, tariff = tax_tariff())",
          "church_tax=9, guenstigerpruefung=True, income=simlev.income_tariff(25000, tariff=simlev.tax_tariff())",
          "church_tax = 9, guenstigerpruefung = true, income = SL.income_tariff(25000; tariff = SL.tax_tariff())"))
for (k in names(TTC)) EIN[[paste0("withdrawal/", paste0("ws_tt_", k))]] <- I
TT2 <- list(
  # Erstattung über der Monatsentnahme (Rest ins Depot), Entnahme am Periodenende
  refund_month = c("withdrawal_simulation(Rm, withdrawal_rule('percent', rate = 5), frequency = 'month', start_value = 3e5, timing = 'end', base_rate = 2.5, cost_basis = 40, inflation = 1, tax = tax_profile(church_tax = 9, guenstigerpruefung = TRUE, income = income_tariff(2000)))",
                   "withdrawal_simulation(Rm, rule=withdrawal_rule(type='percent', rate=5), frequency='month', start_value=3e5, timing='end', base_rate=2.5, cost_basis=40, inflation=1, tax=simlev.tax_profile(church_tax=9, guenstigerpruefung=True, income=simlev.income_tariff(2000)))",
                   'withdrawal_simulation(Rm, withdrawal_rule("percent"; rate = 5); frequency = "month", start_value = 3e5, timing = "end", base_rate = 2.5, cost_basis = 40, inflation = 1, tax = SL.tax_profile(; church_tax = 9, guenstigerpruefung = true, income = SL.income_tariff(2000)))'),
  # Quartale mit Rumpfjahr (42 Quartale = 11 Planjahre), Vektor je Planjahr
  quarter = c("withdrawal_simulation(Rq, withdrawal_rule('vanguard', rate = 5), frequency = 'quarter', start_value = 4e5, base_rate = 2, cost_basis = 50, tax = tax_profile(church_tax = 8, guenstigerpruefung = TRUE, income = income_tariff(seq(3000, 23000, by = 2000))))",
              "withdrawal_simulation(Rq, rule=withdrawal_rule(type='vanguard', rate=5), frequency='quarter', start_value=4e5, base_rate=2, cost_basis=50, tax=simlev.tax_profile(church_tax=8, guenstigerpruefung=True, income=simlev.income_tariff(list(range(3000, 23001, 2000)))))",
              'withdrawal_simulation(Rq, withdrawal_rule("vanguard"; rate = 5); frequency = "quarter", start_value = 4e5, base_rate = 2, cost_basis = 50, tax = SL.tax_profile(; church_tax = 8, guenstigerpruefung = true, income = SL.income_tariff(collect(3000.0:2000.0:23000.0))))'),
  # letztes Jahr: Vektor (kein zvE für das Folgejahr) und Zahl (Folgejahr veranlagt)
  last_vec = c("withdrawal_simulation(R[1:3, 1:4], withdrawal_rule('percent', rate = 6), start_value = 4e5, base_rate = 3, cost_basis = 30, tax = tax_profile(church_tax = 9, guenstigerpruefung = TRUE, income = income_tariff(c(5000, 5000, 5000))))",
               "withdrawal_simulation(R[:3, :4], rule=withdrawal_rule(type='percent', rate=6), start_value=4e5, base_rate=3, cost_basis=30, tax=simlev.tax_profile(church_tax=9, guenstigerpruefung=True, income=simlev.income_tariff([5000, 5000, 5000])))",
               'withdrawal_simulation(R[1:3, 1:4], withdrawal_rule("percent"; rate = 6); start_value = 4e5, base_rate = 3, cost_basis = 30, tax = SL.tax_profile(; church_tax = 9, guenstigerpruefung = true, income = SL.income_tariff([5000.0, 5000.0, 5000.0])))'),
  last_num = c("withdrawal_simulation(R[1:3, 1:4], withdrawal_rule('percent', rate = 6), start_value = 4e5, base_rate = 3, cost_basis = 30, tax = tax_profile(church_tax = 9, guenstigerpruefung = TRUE, income = income_tariff(5000)))",
               "withdrawal_simulation(R[:3, :4], rule=withdrawal_rule(type='percent', rate=6), start_value=4e5, base_rate=3, cost_basis=30, tax=simlev.tax_profile(church_tax=9, guenstigerpruefung=True, income=simlev.income_tariff(5000)))",
               'withdrawal_simulation(R[1:3, 1:4], withdrawal_rule("percent"; rate = 6); start_value = 4e5, base_rate = 3, cost_basis = 30, tax = SL.tax_profile(; church_tax = 9, guenstigerpruefung = true, income = SL.income_tariff(5000)))'),
  # Horizont (probehalber Abrechnung je Jahresende)
  hz = c("withdrawal_simulation(Rm, withdrawal_rule('percent', rate = 5), frequency = 'month', base_rate = 2.5, cost_basis = 60, horizon = withdrawal_horizon('uniform', min = 3, max = 9, seed = 7), keep_paths = 2, tax = tax_profile(church_tax = 8, guenstigerpruefung = TRUE, income = income_tariff(7000)))",
         "withdrawal_simulation(Rm, rule=withdrawal_rule(type='percent', rate=5), frequency='month', base_rate=2.5, cost_basis=60, horizon=withdrawal_horizon(type='uniform', min=3, max=9, seed=7), keep_paths=2, tax=simlev.tax_profile(church_tax=8, guenstigerpruefung=True, income=simlev.income_tariff(7000)))",
         'withdrawal_simulation(Rm, withdrawal_rule("percent"; rate = 5); frequency = "month", base_rate = 2.5, cost_basis = 60, horizon = withdrawal_horizon("uniform"; min = 3, max = 9, seed = 7), keep_paths = 2, tax = SL.tax_profile(; church_tax = 8, guenstigerpruefung = true, income = SL.income_tariff(7000)))'),
  # Liquidation: Verzehrregel leert das Depot planmäßig; Erschöpfung bei hoher Rate
  plan = c("withdrawal_simulation(R[1:8, 1:4], withdrawal_rule('one_over_n'), start_value = 5e5, cost_basis = 50, tax = tax_profile(church_tax = 9, guenstigerpruefung = TRUE, income = income_tariff(10000)))",
           "withdrawal_simulation(R[:8, :4], rule=withdrawal_rule(type='one_over_n'), start_value=5e5, cost_basis=50, tax=simlev.tax_profile(church_tax=9, guenstigerpruefung=True, income=simlev.income_tariff(10000)))",
           'withdrawal_simulation(R[1:8, 1:4], withdrawal_rule("one_over_n"); start_value = 5e5, cost_basis = 50, tax = SL.tax_profile(; church_tax = 9, guenstigerpruefung = true, income = SL.income_tariff(10000)))'),
  deplete = c("withdrawal_simulation(R[, 1:4], withdrawal_rule('constant', rate = 12), inflation = 2, cost_basis = 50, tax = tax_profile(church_tax = 8, guenstigerpruefung = TRUE, income = income_tariff(20000)))",
              "withdrawal_simulation(R[:, :4], rule=withdrawal_rule(type='constant', rate=12), inflation=2, cost_basis=50, tax=simlev.tax_profile(church_tax=8, guenstigerpruefung=True, income=simlev.income_tariff(20000)))",
              'withdrawal_simulation(R[:, 1:4], withdrawal_rule("constant"; rate = 12); inflation = 2, cost_basis = 50, tax = SL.tax_profile(; church_tax = 8, guenstigerpruefung = true, income = SL.income_tariff(20000)))'),
  # Einkommen zählt nicht zum zvE (Entscheidung 3)
  income = c("withdrawal_simulation(R[, 1:4], withdrawal_rule('constant', rate = 5), inflation = 2, cost_basis = 50, income = list(start = 3, amount = 12000), tax = tax_profile(guenstigerpruefung = TRUE, income = income_tariff(9000)))",
             "withdrawal_simulation(R[:, :4], rule=withdrawal_rule(type='constant', rate=5), inflation=2, cost_basis=50, income={'start': 3, 'amount': 12000}, tax=simlev.tax_profile(guenstigerpruefung=True, income=simlev.income_tariff(9000)))",
             'withdrawal_simulation(R[:, 1:4], withdrawal_rule("constant"; rate = 5); inflation = 2, cost_basis = 50, income = [Dict("start" => 3, "amount" => 12000)], tax = SL.tax_profile(; guenstigerpruefung = true, income = SL.income_tariff(9000)))'),
  # historische Kohorten (keine Kalenderzuordnung: Zahl)
  coh = c("withdrawal_simulation(withdrawal_cohorts(m, price = 'depot', inflation = 2, years = 5, step = 'year'), withdrawal_rule('percent', rate = 6), tax = tax_profile(guenstigerpruefung = TRUE, income = income_tariff(9000)))",
          "withdrawal_simulation(withdrawal_cohorts(m, price='depot', inflation=2, years=5, step='year'), rule=withdrawal_rule(type='percent', rate=6), tax=simlev.tax_profile(guenstigerpruefung=True, income=simlev.income_tariff(9000)))",
          'withdrawal_simulation(withdrawal_cohorts(m; price = "depot", inflation = 2, years = 5, step = "year"), withdrawal_rule("percent"; rate = 6); tax = SL.tax_profile(; guenstigerpruefung = true, income = SL.income_tariff(9000)))'))
for (k in names(TT2)) EIN[[paste0("withdrawal/", paste0("ws_tt_", k))]] <- I
TTE <- list(
  len = c("withdrawal_simulation(R[, 1:2], tax = tax_profile(income = income_tariff(c(1e4, 2e4, 3e4))))",
          "withdrawal_simulation(R[:, :2], tax=simlev.tax_profile(income=simlev.income_tariff([1e4, 2e4, 3e4])))",
          'withdrawal_simulation(R[:, 1:2]; tax = SL.tax_profile(; income = SL.income_tariff([1e4, 2e4, 3e4])))'),
  named = c("withdrawal_simulation(R[, 1:2], tax = tax_profile(income = income_tariff(c('2030' = 1e4, '2031' = 2e4))))",
            "withdrawal_simulation(R[:, :2], tax=simlev.tax_profile(income=simlev.income_tariff({'2030': 1e4, '2031': 2e4})))",
            'withdrawal_simulation(R[:, 1:2]; tax = SL.tax_profile(; income = SL.income_tariff(["2030" => 1e4, "2031" => 2e4])))'),
  df = c("withdrawal_simulation(R[, 1:2], tax = tax_profile(income = income_tariff(data.frame(year = 2030:2031, taxable_income = 1e4))))",
         "withdrawal_simulation(R[:, :2], tax=simlev.tax_profile(income=simlev.income_tariff(pd.DataFrame({'year': [2030, 2031], 'taxable_income': [1e4, 1e4]}))))",
         'withdrawal_simulation(R[:, 1:2]; tax = SL.tax_profile(; income = SL.income_tariff(SL.RFrame("year" => [2030, 2031], "taxable_income" => [1e4, 1e4]))))'),
  sim_plan = c("simulation(data.frame(date = as.Date('2020-01-01') + 0:30, ETF = 100 + 0:30), create_strategy(ETF = asset_config('etf', 'bnh')), tax = tax_profile(income = income_tariff(c(1e4, 2e4))))",
               "simlev.simulation(pd.DataFrame({'date': pd.date_range('2020-01-01', periods=31), 'ETF': 100.0 + np.arange(31)}), simlev.create_strategy(ETF=simlev.asset_config(asset_class='etf', trading='bnh')), tax=simlev.tax_profile(income=simlev.income_tariff([1e4, 2e4])))",
               'SL.simulation(SL.RFrame("date" => Date(2020, 1, 1) .+ Day.(0:30), "ETF" => 100.0 .+ (0:30)), SL.create_strategy(ETF = SL.asset_config("etf", "bnh")); tax = SL.tax_profile(; income = SL.income_tariff([1e4, 2e4])))'))
for (k in names(TTE)) EIN[[paste0("withdrawal/", paste0("ws_tt_err_", k))]] <- I
# seit 1.1.0: keep_paths als Anzahl (TRUE = alle, FALSE/0 = keine, k = die ersten k Spalten)
KP <- list(k2 = c("2", "2", "2"), k100 = c("100", "100", "100"), k0 = c("0", "0", "0"), k1f = c("1.0", "1.0", "1.0"),
           true = c("TRUE", "True", "true"))
for (k in names(KP)) EIN[[paste0("withdrawal/", paste0("ws_keep_", k))]] <- I
# Grafik mit k < n: R zeichnet (Titel und Medianlinien aus der Aufzeichnung), Python/Julia liefern data des SimLevPlot
PL_R <- paste0("{ws <- withdrawal_simulation(R, withdrawal_rule('percent'), inflation = 2, keep_paths = 2); ",
  "grDevices::pdf(NULL); grDevices::dev.control('enable'); plot(ws); rp <- grDevices::recordPlot(); grDevices::dev.off(); dl <- rp[[1]]; ",
  "nm <- vapply(dl, function(e) { f <- e[[2]][[1]]; if (is.list(f) && is.character(f$name)) f$name else '' }, ''); ",
  "ti <- unlist(lapply(dl[nm == 'C_title'], function(e) e[[2]][[2]])); ",
  "ln <- Filter(function(v) is.null(v$xlab), lapply(dl[nm == 'C_plotXY'], function(e) e[[2]][[2]])); pr <- c(0.05, 0.25, 0.5, 0.75, 0.95); ",
  "tab <- function(M, w, x0) { Q <- apply(M, 1, function(r) SimLev:::.wquantile(r, w, pr)); d <- data.frame(year = x0 + seq_len(nrow(M)) - 1L); ",
  "for (i in seq_along(pr)) d[[sprintf('q%02.0f', 100 * pr[i])]] <- Q[i, ]; d }; ",
  "list(wealth = tab(ws$wealth, ws$weights[1:2], 0L), spending = tab(ws$spending, ws$weights, 1L), title = ti[1], ",
  "mid_wealth = ln[[1]]$y, mid_spending = ln[[2]]$y, ncol = ncol(ws$wealth))}")
# Fehler und Warnungen
WE <- list(
  rule = c("withdrawal_simulation(R, list())", "withdrawal_simulation(R, rule={})",
    'withdrawal_simulation(R, (;))'),
  taxcls = c("withdrawal_simulation(R, tax = 'person')", "withdrawal_simulation(R, tax='person')",
    'withdrawal_simulation(R; tax = "person")'),
  taxinc = c("withdrawal_simulation(R, tax = tax_profile(base_rate = 2, income = income_rate(42), harvest = harvest_rule(), private_sale_threshold = 600))",
    "withdrawal_simulation(R, tax=simlev.tax_profile(base_rate=2, income=simlev.income_rate(42), harvest=simlev.harvest_rule(), private_sale_threshold=600))",
    'withdrawal_simulation(R; tax = SL.tax_profile(; base_rate = 2, income = SL.income_rate(42), harvest = SL.harvest_rule(), private_sale_threshold = 600))'),
  taxrate = c("withdrawal_simulation(R, tax = tax_profile(rate = -5))", "withdrawal_simulation(R, tax=simlev.tax_profile(rate=-5))",
    'withdrawal_simulation(R; tax = SL.tax_profile(; rate = -5))'),
  bonus = c("withdrawal_simulation(R, tax = tax_profile(), partial_exemption = 130)", "withdrawal_simulation(R, tax=simlev.tax_profile(), partial_exemption=130)",
    'withdrawal_simulation(R; tax = SL.tax_profile(), partial_exemption = 130)'),
  cb = c("withdrawal_simulation(R, tax = tax_profile(), cost_basis = -10)", "withdrawal_simulation(R, tax=simlev.tax_profile(), cost_basis=-10)",
    'withdrawal_simulation(R; tax = SL.tax_profile(), cost_basis = -10)'),
  spb = c("withdrawal_simulation(R, tax = tax_profile(sparer_pauschbetrag = c(1000, 2000)))", "withdrawal_simulation(R, tax=simlev.tax_profile(sparer_pauschbetrag=[1000, 2000]))",
    'withdrawal_simulation(R; tax = SL.tax_profile(; sparer_pauschbetrag = [1000, 2000]))'),
  lc = c("withdrawal_simulation(R, loss_carryforward = NA)", "withdrawal_simulation(R, loss_carryforward=simlev._r.fmt.NA_REAL)",
    'withdrawal_simulation(R; loss_carryforward = SL.NA)'),
  gamma = c("withdrawal_simulation(R, gamma = -1)", "withdrawal_simulation(R, gamma=-1)",
    'withdrawal_simulation(R; gamma = -1)'),
  sale = c("withdrawal_simulation(R, sale_cost = 100)", "withdrawal_simulation(R, sale_cost=100)",
    'withdrawal_simulation(R; sale_cost = 100)'),
  keep = c("withdrawal_simulation(R, keep_paths = NA)", "withdrawal_simulation(R, keep_paths=simlev._r.fmt.NA_REAL)",
    'withdrawal_simulation(R; keep_paths = SL.NA)'),
  keepneg = c("withdrawal_simulation(R, keep_paths = -1)", "withdrawal_simulation(R, keep_paths=-1)",
    'withdrawal_simulation(R; keep_paths = -1)'),
  keepfrac = c("withdrawal_simulation(R, keep_paths = 1.5)", "withdrawal_simulation(R, keep_paths=1.5)",
    'withdrawal_simulation(R; keep_paths = 1.5)'),
  keepchr = c("withdrawal_simulation(R, keep_paths = 'a')", "withdrawal_simulation(R, keep_paths='a')",
    'withdrawal_simulation(R; keep_paths = "a")'),
  keepvec = c("withdrawal_simulation(R, keep_paths = c(1, 2))", "withdrawal_simulation(R, keep_paths=[1, 2])",
    'withdrawal_simulation(R; keep_paths = [1, 2])'),
  vp = c("withdrawal_simulation(R, vorabpauschale = 'ja')", "withdrawal_simulation(R, vorabpauschale='ja')",
    'withdrawal_simulation(R; vorabpauschale = "ja")'),
  infl = c("withdrawal_simulation(R, inflation = -100)", "withdrawal_simulation(R, inflation=-100)",
    'withdrawal_simulation(R; inflation = -100)'),
  inflmat = c("withdrawal_simulation(R, inflation = matrix(1.02, 30, 1))", "withdrawal_simulation(R, inflation=np.full((30, 1), 1.02))",
    'withdrawal_simulation(R; inflation = fill(1.02, 30, 1))'),
  inflchr = c("withdrawal_simulation(R, inflation = 'cpi')", "withdrawal_simulation(R, inflation='cpi')",
    'withdrawal_simulation(R; inflation = "cpi")'),
  hz0 = c("withdrawal_simulation(R, horizon = 0)", "withdrawal_simulation(R, horizon=0)",
    'withdrawal_simulation(R; horizon = 0)'),
  hzvec = c("withdrawal_simulation(R, horizon = c(5, 6))", "withdrawal_simulation(R, horizon=[5, 6])",
    'withdrawal_simulation(R; horizon = [5, 6])'),
  years = c("withdrawal_simulation(R, years = -1)", "withdrawal_simulation(R, years=-1)",
    'withdrawal_simulation(R; years = -1)'),
  yearsq = c("withdrawal_simulation(Rq, frequency = 'quarter', years = 2.6)", "withdrawal_simulation(Rq, frequency='quarter', years=2.6)",
    'withdrawal_simulation(Rq; frequency = "quarter", years = 2.6)'),
  br = c("withdrawal_simulation(R, base_rate = 'x')", "withdrawal_simulation(R, base_rate='x')",
    'withdrawal_simulation(R; base_rate = "x")'),
  brmat = c("withdrawal_simulation(R, tax = tax_profile(), base_rate = matrix(2.5, 1, 1))", "withdrawal_simulation(R, tax=simlev.tax_profile(), base_rate=np.full((1, 1), 2.5))",
    'withdrawal_simulation(R; tax = SL.tax_profile(), base_rate = fill(2.5, 1, 1))'),
  income = c("withdrawal_simulation(R, income = list(list(start = 5, end = 3, amount = 10000)))", "withdrawal_simulation(R, income=[{'start': 5, 'end': 3, 'amount': 10000}])",
    'withdrawal_simulation(R; income = [Dict("start" => 5, "end" => 3, "amount" => 10000)])'),
  income2 = c("withdrawal_simulation(R, income = list(list(start = 5)))", "withdrawal_simulation(R, income=[{'start': 5}])",
    'withdrawal_simulation(R; income = [Dict("start" => 5)])'),
  sv = c("withdrawal_simulation(R, start_value = -800)", "withdrawal_simulation(R, start_value=-800)",
    'withdrawal_simulation(R; start_value = -800)'),
  svchr = c("withdrawal_simulation(R, start_value = '1e5')", "withdrawal_simulation(R, start_value='1e5')",
    'withdrawal_simulation(R; start_value = "1e5")'),
  svvec = c("withdrawal_simulation(R, start_value = c(1, 2))", "withdrawal_simulation(R, start_value=[1, 2])",
    'withdrawal_simulation(R; start_value = [1, 2])'),
  neg = c("withdrawal_simulation(R - 1)", "withdrawal_simulation(R - 1)",
    'withdrawal_simulation(R .- 1)'),
  cape = c("withdrawal_simulation(R, withdrawal_rule('cape'))", "withdrawal_simulation(R, rule=withdrawal_rule(type='cape'))",
    'withdrawal_simulation(R, withdrawal_rule("cape"))'),
  na = c("x <- R; x[3, 2] <- NA; withdrawal_simulation(x)", "x = R.copy(); x[2, 1] = simlev._r.fmt.NA_REAL; withdrawal_simulation(x)",
    '(x = copy(R); x[3, 2] = SL.NA; withdrawal_simulation(x))'),
  timing = c("withdrawal_simulation(R, timing = 'mid')", "withdrawal_simulation(R, timing='mid')",
    'withdrawal_simulation(R; timing = "mid")'),
  wpdim = c("withdrawal_simulation(structure(list(returns = R, inflation = matrix(1, 3, 3), frequency = 'year'), class = 'withdrawal_paths'))",
            "withdrawal_simulation(W.WithdrawalPaths([('returns', R), ('inflation', np.ones((3, 3))), ('frequency', 'year')]))",
    'withdrawal_simulation(SL.RList("returns" => R, "inflation" => ones(3, 3), "frequency" => "year"; class = "withdrawal_paths"))'),
  empty = c("withdrawal_simulation(structure(list(returns = matrix(1, 0, 2), inflation = matrix(1, 0, 2), frequency = 'year'), class = 'withdrawal_paths'))",
            "withdrawal_simulation(W.WithdrawalPaths([('returns', np.ones((0, 2))), ('inflation', np.ones((0, 2))), ('frequency', 'year')]))",
    'withdrawal_simulation(SL.RList("returns" => ones(0, 2), "inflation" => ones(0, 2), "frequency" => "year"; class = "withdrawal_paths"))'))
for (k in names(WE)) EIN[[paste0("withdrawal/", paste0("ws_err_", k))]] <- I
WW <- list(
  taxrate = c("withdrawal_simulation(R[, 1:2], tax = tax_profile(rate = 0.26375))", "withdrawal_simulation(R[:, :2], tax=simlev.tax_profile(rate=0.26375))",
    'withdrawal_simulation(R[:, 1:2]; tax = SL.tax_profile(; rate = 0.26375))'),
  bonus = c("withdrawal_simulation(R[, 1:2], tax = tax_profile(), partial_exemption = 0.3, cost_basis = 0.5)", "withdrawal_simulation(R[:, :2], tax=simlev.tax_profile(), partial_exemption=0.3, cost_basis=0.5)",
    'withdrawal_simulation(R[:, 1:2]; tax = SL.tax_profile(), partial_exemption = 0.3, cost_basis = 0.5)'),
  infl = c("withdrawal_simulation(R[, 1:2], inflation = 0.02)", "withdrawal_simulation(R[:, :2], inflation=0.02)",
    'withdrawal_simulation(R[:, 1:2]; inflation = 0.02)'),
  br = c("withdrawal_simulation(R[, 1:2], tax = tax_profile(), base_rate = 0.032)", "withdrawal_simulation(R[:, :2], tax=simlev.tax_profile(), base_rate=0.032)",
    'withdrawal_simulation(R[:, 1:2]; tax = SL.tax_profile(), base_rate = 0.032)'),
  hz = c("withdrawal_simulation(R[1:10, 1:3], horizon = withdrawal_horizon('uniform', min = 8, max = 14))", "withdrawal_simulation(R[:10, :3], horizon=withdrawal_horizon(type='uniform', min=8, max=14))",
    'withdrawal_simulation(R[1:10, 1:3]; horizon = withdrawal_horizon("uniform"; min = 8, max = 14))'))
for (k in names(WW)) EIN[[paste0("withdrawal/", paste0("ws_warn_", k))]] <- I
EIN[["withdrawal/mr_na"]] <- list()
EIN[["withdrawal/mr_upper"]] <- list()
ME <- list(succ95 = c("withdrawal_max_rate(R, success = 95)", "withdrawal_max_rate(R, success=95)",
    'withdrawal_max_rate(R; success = 95)'),
           succ0 = c("withdrawal_max_rate(R, success = 0)", "withdrawal_max_rate(R, success=0)",
    'withdrawal_max_rate(R; success = 0)'),
           succ200 = c("withdrawal_max_rate(R, success = 200)", "withdrawal_max_rate(R, success=200)",
    'withdrawal_max_rate(R; success = 200)'),
           lu = c("withdrawal_max_rate(R, lower = 10, upper = 2)", "withdrawal_max_rate(R, lower=10, upper=2)",
    'withdrawal_max_rate(R; lower = 10, upper = 2)'),
           up = c("withdrawal_max_rate(R, upper = 150)", "withdrawal_max_rate(R, upper=150)",
    'withdrawal_max_rate(R; upper = 150)'),
           tol = c("withdrawal_max_rate(R, tol = 0)", "withdrawal_max_rate(R, tol=0)",
    'withdrawal_max_rate(R; tol = 0)'),
           rule = c("withdrawal_max_rate(R, withdrawal_rule('vpw'))", "withdrawal_max_rate(R, rule=withdrawal_rule(type='vpw'))",
    'withdrawal_max_rate(R, withdrawal_rule("vpw"))'),
           rule2 = c("withdrawal_max_rate(R, 1)", "withdrawal_max_rate(R, rule=1)",
    'withdrawal_max_rate(R, 1)'))
for (k in names(ME)) EIN[[paste0("withdrawal/", paste0("mr_err_", k))]] <- I
# ── withdrawal_horizon ──────────────────────────────────────────────────────────
HM <- list(fixed = c("withdrawal_horizon('fixed', years = 30)", "withdrawal_horizon(type='fixed', years=30)",
    'withdrawal_horizon("fixed"; years = 30)'),
           uniform = c("withdrawal_horizon('uniform', min = 20, max = 30)", "withdrawal_horizon(type='uniform', min=20, max=30)",
    'withdrawal_horizon("uniform"; min = 20, max = 30)'),
           uniform_frac = c("withdrawal_horizon('uniform', min = 2.5, max = 6)", "withdrawal_horizon(type='uniform', min=2.5, max=6)",
    'withdrawal_horizon("uniform"; min = 2.5, max = 6)'),
           discrete = c("withdrawal_horizon('discrete', years = c(25, 30, 35, 40), prob = c(0.3, 0.4, 0.2, 0.1))", "withdrawal_horizon(type='discrete', years=[25, 30, 35, 40], prob=[0.3, 0.4, 0.2, 0.1])",
    'withdrawal_horizon("discrete"; years = [25, 30, 35, 40], prob = [0.3, 0.4, 0.2, 0.1])'),
           discrete1 = c("withdrawal_horizon('discrete', years = 30, prob = 1)", "withdrawal_horizon(type='discrete', years=30, prob=1)",
    'withdrawal_horizon("discrete"; years = 30, prob = 1)'),
           normal = c("withdrawal_horizon('normal', mean = 25, sd = 6, min = 10, max = 35, seed = 7)", "withdrawal_horizon(type='normal', mean=25, sd=6, min=10, max=35, seed=7)",
    'withdrawal_horizon("normal"; mean = 25, sd = 6, min = 10, max = 35, seed = 7)'),
           tri = c("withdrawal_horizon('triangular', min = 10, mode = 25, max = 35)", "withdrawal_horizon(type='triangular', min=10, mode=25, max=35)",
    'withdrawal_horizon("triangular"; min = 10, mode = 25, max = 35)'),
           tri0 = c("withdrawal_horizon('triangular', min = 30, mode = 30, max = 30)", "withdrawal_horizon(type='triangular', min=30, mode=30, max=30)",
    'withdrawal_horizon("triangular"; min = 30, mode = 30, max = 30)'),
           sample = c("withdrawal_horizon('sample', years = c(3.7, 12, 30))", "withdrawal_horizon(type='sample', years=[3.7, 12, 30])",
    'withdrawal_horizon("sample"; years = [3.7, 12, 30])'),
           small = c("withdrawal_horizon('normal', mean = 1, sd = 3, min = 0.2, max = 3)", "withdrawal_horizon(type='normal', mean=1, sd=3, min=0.2, max=3)",
    'withdrawal_horizon("normal"; mean = 1, sd = 3, min = 0.2, max = 3)'))
for (k in names(HM)) EIN[[paste0("withdrawal/", paste0("hz_", k))]] <- list()
for (k in c("uniform", "discrete", "normal", "tri", "sample", "small")) EIN[[paste0("withdrawal/", paste0("hz_draw_", k))]] <- list()
EIN[["withdrawal/hz_draw_walker"]] <- list()
HE <- list(miss = c("withdrawal_horizon('uniform', min = 3)", "withdrawal_horizon(type='uniform', min=3)",
    'withdrawal_horizon("uniform"; min = 3)'),
           y0 = c("withdrawal_horizon('fixed', years = 0)", "withdrawal_horizon(type='fixed', years=0)",
    'withdrawal_horizon("fixed"; years = 0)'),
           min0 = c("withdrawal_horizon('uniform', min = 0, max = 30)", "withdrawal_horizon(type='uniform', min=0, max=30)",
    'withdrawal_horizon("uniform"; min = 0, max = 30)'),
           disc_neg = c("withdrawal_horizon('discrete', years = c(20, -1), prob = c(1, 1))", "withdrawal_horizon(type='discrete', years=[20, -1], prob=[1, 1])",
    'withdrawal_horizon("discrete"; years = [20, -1], prob = [1, 1])'),
           disc_len = c("withdrawal_horizon('discrete', years = c(20, 30), prob = 1)", "withdrawal_horizon(type='discrete', years=[20, 30], prob=1)",
    'withdrawal_horizon("discrete"; years = [20, 30], prob = 1)'),
           disc_p = c("withdrawal_horizon('discrete', years = c(20, 30), prob = c(0, 0))", "withdrawal_horizon(type='discrete', years=[20, 30], prob=[0, 0])",
    'withdrawal_horizon("discrete"; years = [20, 30], prob = [0, 0])'),
           vec = c("withdrawal_horizon('fixed', years = c(20, 30))", "withdrawal_horizon(type='fixed', years=[20, 30])",
    'withdrawal_horizon("fixed"; years = [20, 30])'),
           inf = c("withdrawal_horizon('uniform', min = 1, max = Inf)", "withdrawal_horizon(type='uniform', min=1, max=np.inf)",
    'withdrawal_horizon("uniform"; min = 1, max = Inf)'),
           minmax = c("withdrawal_horizon('uniform', min = 30, max = 20)", "withdrawal_horizon(type='uniform', min=30, max=20)",
    'withdrawal_horizon("uniform"; min = 30, max = 20)'),
           mode = c("withdrawal_horizon('triangular', min = 20, mode = 50, max = 30)", "withdrawal_horizon(type='triangular', min=20, mode=50, max=30)",
    'withdrawal_horizon("triangular"; min = 20, mode = 50, max = 30)'),
           sd = c("withdrawal_horizon('normal', mean = 20, sd = -1, min = 1, max = 30)", "withdrawal_horizon(type='normal', mean=20, sd=-1, min=1, max=30)",
    'withdrawal_horizon("normal"; mean = 20, sd = -1, min = 1, max = 30)'),
           type = c("withdrawal_horizon('weibull')", "withdrawal_horizon(type='weibull')",
    'withdrawal_horizon("weibull")'),
           chr = c("withdrawal_horizon('fixed', years = 'x')", "withdrawal_horizon(type='fixed', years='x')",
    'withdrawal_horizon("fixed"; years = "x")'))
for (k in names(HE)) EIN[[paste0("withdrawal/", paste0("hz_err_", k))]] <- list()
EIN[["withdrawal/fee_set"]] <- list()
# ── simulation-basierte Teile ──────────────────────────────────────────────
set.seed(4); dsim <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = 1500))
dsim$ETF <- 100 * cumprod(1 + rnorm(1500, 3e-4, 0.01))
Is <- c(I, list(dsim = dsim))
SIM_R <- "st <- create_strategy(ETF = asset_config('etf', 'bnh', spread = 0))\nr1 <- simulation(dsim, st, start_value = 1000)\nr2 <- simulation(dsim, st, start_value = 1000, dca = dca_plan(value = 500, span = 1))\n"
SIM_J <- 'st = create_strategy(ETF = asset_config("etf", "bnh", spread = 0))
r1 = simulation(dsim, st; start_value = 1000)
r2 = simulation(dsim, st, start_value = 1000, dca = dca_plan(value = 500, span = 1))
'
SIM_P <- "st = simlev.create_strategy(ETF=simlev.asset_config(asset_class='etf', trading='bnh', spread=0))\nr1 = simlev.simulation(dsim, st, start_value=1000)\nr2 = simlev.simulation(dsim, st, start_value=1000, dca=simlev.dca_plan(value=500, span=1))\n"
EIN[["withdrawal/ri_err"]] <- list()
TAX_R <- "rt <- simulation(dsim, create_strategy(ETF = asset_config('etf', 'bnh', spread = 0.2, partial_exemption = 30)), start_value = 1e5, tax = tax_profile(base_rate = 2))\n"
TAX_J <- 'rt = simulation(dsim, create_strategy(ETF = asset_config("etf", "bnh", spread = 0.2, partial_exemption = 30)), start_value = 1e5, tax = tax_profile(base_rate = 2))\n'
TAX_P <- "rt = simlev.simulation(dsim, simlev.create_strategy(ETF=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.2, partial_exemption=30)), start_value=1e5, tax=simlev.tax_profile(base_rate=2))\n"
# Tarifweg (seit 1.3.0) mit Lots aus der Ansparphase; nach Kalenderjahren benannt (Planjahr 1 = tax_report$next_year$year)
TTS <- list(
  named = c("y1 <- rt$tax_report$next_year$year; withdrawal_simulation(R[, 1:3], withdrawal_rule('percent', rate = 5), start_value = rt, tax = tax_profile(church_tax = 8, guenstigerpruefung = TRUE, income = income_tariff(setNames(20000 - 500 * (0:30), y1 + 0:30))))",
            "y1 = rt['tax_report']['next_year']['year']\nws = withdrawal_simulation(R[:, :3], rule=withdrawal_rule(type='percent', rate=5), start_value=rt, tax=simlev.tax_profile(church_tax=8, guenstigerpruefung=True, income=simlev.income_tariff({str(y1 + i): 20000.0 - 500 * i for i in range(31)})))",
            'y1 = Int(rt["tax_report"]["next_year"]["year"])\nws = withdrawal_simulation(R[:, 1:3], withdrawal_rule("percent"; rate = 5); start_value = rt, tax = SL.tax_profile(; church_tax = 8, guenstigerpruefung = true, income = SL.income_tariff([string(y1 + i) => 20000.0 - 500 * i for i in 0:30])))'),
  df = c("y1 <- rt$tax_report$next_year$year; withdrawal_simulation(R[, 1:3], withdrawal_rule('percent', rate = 5), start_value = rt, tax = tax_profile(guenstigerpruefung = TRUE, income = income_tariff(data.frame(year = y1 + 0:29, taxable_income = 9000))))",
         "y1 = rt['tax_report']['next_year']['year']\nws = withdrawal_simulation(R[:, :3], rule=withdrawal_rule(type='percent', rate=5), start_value=rt, tax=simlev.tax_profile(guenstigerpruefung=True, income=simlev.income_tariff(pd.DataFrame({'year': [y1 + i for i in range(30)], 'taxable_income': [9000.0] * 30}))))",
         'y1 = Int(rt["tax_report"]["next_year"]["year"])\nws = withdrawal_simulation(R[:, 1:3], withdrawal_rule("percent"; rate = 5); start_value = rt, tax = SL.tax_profile(; guenstigerpruefung = true, income = SL.income_tariff(SL.RFrame("year" => collect(y1:(y1 + 29)), "taxable_income" => fill(9000.0, 30)))))'),
  num = c("withdrawal_simulation(R[, 1:3], withdrawal_rule('percent', rate = 5), start_value = rt, tax = tax_profile(church_tax = 9, income = income_tariff(60000)))",
          "ws = withdrawal_simulation(R[:, :3], rule=withdrawal_rule(type='percent', rate=5), start_value=rt, tax=simlev.tax_profile(church_tax=9, income=simlev.income_tariff(60000)))",
          'ws = withdrawal_simulation(R[:, 1:3], withdrawal_rule("percent"; rate = 5); start_value = rt, tax = SL.tax_profile(; church_tax = 9, income = SL.income_tariff(60000)))'))
for (k in names(TTS)) EIN[[paste0("withdrawal/", paste0("ws_tt_sv_", k))]] <- Is
# Bootstrap-Pfade und Studien
set.seed(21); nb <- 1100
db <- data.frame(us = 100 * cumprod(c(1, 1 + rnorm(nb, 3e-4, 0.01))), cpi = 100 * 1.02^((0:nb) / 365), infl = 2, zins = 2 + sin((0:nb) / 40))
Ib <- c(Is, list(db = db))
BR_R <- "cfg <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices', aux_type = c(infl = 'rate', cpi = 'level'))
cfg0 <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices')
b <- bootstrap(db, cfg, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
b0 <- bootstrap(db, cfg0, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)\n"
BR_J <- 'cfg = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices", aux_type = (infl = "rate", cpi = "level"))
cfg0 = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices")
b = bootstrap(db, cfg, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
b0 = bootstrap(db, cfg0, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
'
BR_P <- "cfg = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices', aux_type={'infl': 'rate', 'cpi': 'level'})
cfg0 = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices')
b = bootstrap(db, cfg, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
b0 = bootstrap(db, cfg0, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)\n"
WP <- list(
  plain = c("withdrawal_paths(b, column = 'us')", "withdrawal_paths(b, column='us')",
    'withdrawal_paths(b; column = "us")'),
  num = c("withdrawal_paths(b, column = 'us', inflation = 2, frequency = 'quarter', start = '2001-01-31')", "withdrawal_paths(b, column='us', inflation=2, frequency='quarter', start='2001-01-31')",
    'withdrawal_paths(b; column = "us", inflation = 2, frequency = "quarter", start = "2001-01-31")'),
  rate_attr = c("withdrawal_paths(b, column = 'us', inflation = 'infl')", "withdrawal_paths(b, column='us', inflation='infl')",
    'withdrawal_paths(b; column = "us", inflation = "infl")'),
  level_attr = c("withdrawal_paths(b, column = 'us', inflation = 'cpi', frequency = 'month')", "withdrawal_paths(b, column='us', inflation='cpi', frequency='month')",
    'withdrawal_paths(b; column = "us", inflation = "cpi", frequency = "month")'),
  level_aux = c("withdrawal_paths(b0, column = 'us', inflation = 'zins')", "withdrawal_paths(b0, column='us', inflation='zins')",
    'withdrawal_paths(b0; column = "us", inflation = "zins")'),
  rate_pa = c("withdrawal_paths(b0, column = 'us', inflation = 'zins', inflation_type = 'rate_pa')", "withdrawal_paths(b0, column='us', inflation='zins', inflation_type='rate_pa')",
    'withdrawal_paths(b0; column = "us", inflation = "zins", inflation_type = "rate_pa")'),
  cape = c("withdrawal_paths(b, column = 'us', cape = 'zins', frequency = 'quarter')", "withdrawal_paths(b, column='us', cape='zins', frequency='quarter')",
    'withdrawal_paths(b; column = "us", cape = "zins", frequency = "quarter")'),
  cape1 = c("withdrawal_paths(b, column = 'us', cape = 'zins', dates = seq.Date(as.Date('2003-02-28'), by = 'day', length.out = 1101))", "withdrawal_paths(b, column='us', cape='zins', dates=np.datetime64('2003-02-28') + np.arange(1101))",
    'withdrawal_paths(b; column = "us", cape = "zins", dates = Date(2003, 2, 28) .+ Day.(0:1100))'),
  td = c("x <- seq.Date(as.Date('2001-01-01'), by = 'day', length.out = 2000); x <- x[!format(x, '%u') %in% c('6', '7')][1:1101]; withdrawal_paths(b, column = 'us', inflation = 'infl', dates = x)",
         "x = np.datetime64('2001-01-01') + np.arange(2000); x = x[(x.astype(int) + 3) % 7 < 5][:1101]; result = withdrawal_paths(b, column='us', inflation='infl', dates=x)",
    'x = Date(2001, 1, 1) .+ Day.(0:1999); x = x[Dates.dayofweek.(x) .< 6][1:1101]; result = withdrawal_paths(b; column = "us", inflation = "infl", dates = x)'),
  e_col = c("withdrawal_paths(b)", "withdrawal_paths(b)",
    'withdrawal_paths(b)'),
  e_colname = c("withdrawal_paths(b, column = 'x')", "withdrawal_paths(b, column='x')",
    'withdrawal_paths(b; column = "x")'),
  e_dates = c("withdrawal_paths(b, column = 'us', dates = as.Date('2001-01-01') + 0:5)", "withdrawal_paths(b, column='us', dates=np.datetime64('2001-01-01') + np.arange(6))",
    'withdrawal_paths(b; column = "us", dates = Date(2001, 1, 1) .+ Day.(0:5))'),
  e_unsorted = c("withdrawal_paths(b, column = 'us', dates = rev(as.Date('2001-01-01') + 0:1100))", "withdrawal_paths(b, column='us', dates=(np.datetime64('2001-01-01') + np.arange(1101))[::-1])",
    'withdrawal_paths(b; column = "us", dates = reverse(Date(2001, 1, 1) .+ Day.(0:1100)))'),
  e_short = c("b3 <- bootstrap(db, cfg, 'raw', n = 1, seed = 1, progress = FALSE, path_length = 200); withdrawal_paths(b3, column = 'us')", "b3 = bootstrap(db, cfg, method='raw', n=1, seed=1, progress=False, path_length=200); result = withdrawal_paths(b3, column='us')",
    'b3 = bootstrap(db, cfg, "raw"; n = 1, seed = 1, progress = false, path_length = 200); result = withdrawal_paths(b3; column = "us")'),
  e_dup = c("withdrawal_paths(b, column = 'us', dates = as.Date('2001-01-01') + (0:1100) %/% 3)", "withdrawal_paths(b, column='us', dates=np.datetime64('2001-01-01') + np.arange(1101) // 3)",
    'withdrawal_paths(b; column = "us", dates = Date(2001, 1, 1) .+ Day.((0:1100) .÷ 3))'),
  e_infl_col = c("withdrawal_paths(b, column = 'us', inflation = 'cp')", "withdrawal_paths(b, column='us', inflation='cp')",
    'withdrawal_paths(b; column = "us", inflation = "cp")'),
  e_mismatch = c("withdrawal_paths(b, column = 'us', inflation = 'infl', inflation_type = 'level')", "withdrawal_paths(b, column='us', inflation='infl', inflation_type='level')",
    'withdrawal_paths(b; column = "us", inflation = "infl", inflation_type = "level")'),
  e_mismatch2 = c("withdrawal_paths(b, column = 'us', inflation = 'cpi', inflation_type = 'rate_pa')", "withdrawal_paths(b, column='us', inflation='cpi', inflation_type='rate_pa')",
    'withdrawal_paths(b; column = "us", inflation = "cpi", inflation_type = "rate_pa")'),
  e_infl_vec = c("withdrawal_paths(b, column = 'us', inflation = c(1, 2))", "withdrawal_paths(b, column='us', inflation=[1, 2])",
    'withdrawal_paths(b; column = "us", inflation = [1, 2])'),
  e_noattr = c("b0$paths <- lapply(b0$paths, function(p) { attr(p, 'aux_level') <- NULL; p }); withdrawal_paths(b0, column = 'us', inflation = 'zins')",
               "[p.attrs.pop('aux_level') for p in b0['paths']]; result = withdrawal_paths(b0, column='us', inflation='zins')",
    'for p in b0["paths"]; delete!(p.attrs, "aux_level"); end; result = withdrawal_paths(b0; column = "us", inflation = "zins")'),
  wild_noattr = c("b0$paths <- lapply(b0$paths, function(p) { attr(p, 'aux_level') <- NULL; p }); b0$method <- 'wild'; withdrawal_paths(b0, column = 'us', inflation = 'zins')",
                  "[p.attrs.pop('aux_level') for p in b0['paths']]; b0['method'] = 'wild'; result = withdrawal_paths(b0, column='us', inflation='zins')",
    'for p in b0["paths"]; delete!(p.attrs, "aux_level"); end; b0["method"] = "wild"; result = withdrawal_paths(b0; column = "us", inflation = "zins")'),
  e_class = c("withdrawal_paths(list(1, 2))", "withdrawal_paths([1, 2])",
    'withdrawal_paths([1, 2])'))
for (k in names(WP)) EIN[[paste0("withdrawal/", paste0("wp_", k))]] <- Ib
ST_R <- paste0(BR_R, "st <- bootstrap_study(db, cfg, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE, keep_returns = 'year', keep_aux = c('infl', 'zins', 'cpi'), strategies = list(bnh = create_strategy(us = asset_config('etf', 'bnh', spread = 0.1)), half = create_strategy(us = asset_config('etf', 'bnh', share = 0.5, spread = 0.1))))\n")
ST_J <- paste0(BR_J, 'st = bootstrap_study(db, cfg, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false, keep_returns = "year", keep_aux = ["infl", "zins", "cpi"], strategies = (bnh = create_strategy(us = asset_config("etf", "bnh", spread = 0.1)), half = create_strategy(us = asset_config("etf", "bnh", share = 0.5, spread = 0.1))))\n')
ST_P <- paste0(BR_P, "st = bootstrap_study(db, cfg, 'stationary', n=3, params={'L': 60}, seed=4, progress=False, keep_returns='year', keep_aux=['infl', 'zins', 'cpi'], strategies={'bnh': simlev.create_strategy(us=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1)), 'half': simlev.create_strategy(us=simlev.asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1))})\n")
SW <- list(
  default = c("withdrawal_paths(st)", "withdrawal_paths(st)",
    'withdrawal_paths(st)'),
  strat = c("withdrawal_paths(st, strategy = 'half', inflation = 2)", "withdrawal_paths(st, strategy='half', inflation=2)",
    'withdrawal_paths(st; strategy = "half", inflation = 2)'),
  aux_rate = c("withdrawal_paths(st, inflation = 'infl')", "withdrawal_paths(st, inflation='infl')",
    'withdrawal_paths(st; inflation = "infl")'),
  aux_level = c("withdrawal_paths(st, inflation = 'zins', inflation_type = 'level')", "withdrawal_paths(st, inflation='zins', inflation_type='level')",
    'withdrawal_paths(st; inflation = "zins", inflation_type = "level")'),
  aux_cpi = c("withdrawal_paths(st, inflation = 'cpi')", "withdrawal_paths(st, inflation='cpi')",
    'withdrawal_paths(st; inflation = "cpi")'),
  e_rate_pa = c("withdrawal_paths(st, inflation = 'zins', inflation_type = 'rate_pa')", "withdrawal_paths(st, inflation='zins', inflation_type='rate_pa')",
    'withdrawal_paths(st; inflation = "zins", inflation_type = "rate_pa")'),
  e_mismatch = c("withdrawal_paths(st, inflation = 'infl', inflation_type = 'level')", "withdrawal_paths(st, inflation='infl', inflation_type='level')",
    'withdrawal_paths(st; inflation = "infl", inflation_type = "level")'),
  e_strat = c("withdrawal_paths(st, strategy = 'x')", "withdrawal_paths(st, strategy='x')",
    'withdrawal_paths(st; strategy = "x")'),
  e_aux = c("withdrawal_paths(st, inflation = 'foo')", "withdrawal_paths(st, inflation='foo')",
    'withdrawal_paths(st; inflation = "foo")'),
  ws = c("{ws <- withdrawal_simulation(st, withdrawal_rule('constant'), strategy = 'half', inflation = 'infl'); ws$elapsed <- 0; ws}", "withdrawal_simulation(st, rule=withdrawal_rule(type='constant'), strategy='half', inflation='infl'); result['elapsed'] = 0",
    '(ws = withdrawal_simulation(st, withdrawal_rule("constant"); strategy = "half", inflation = "infl"); ws["elapsed"] = 0; ws)'))
for (k in names(SW)) EIN[[paste0("withdrawal/", paste0("wps_", k))]] <- Ib
# ── FIFO-Lots und Übernahme aus einer Ansparphase ──────────────────────────
dfi <- data.frame(date = seq.Date(as.Date("2018-01-01"), as.Date("2019-12-31"), by = "day"))
tt <- as.numeric(dfi$date - dfi$date[1]) / 365.25
dfi$A <- 100 * (1 - 0.3 * sin(3 * tt)); dfi$N <- 100 * 1.03^tt; dfi$C <- dfi$N
dfi$ev <- dfi$date %in% as.Date(c("2018-01-01", "2018-07-01", "2019-03-01")); dfi$wA <- c(1, 0.2, 0.6)[pmax(1, cumsum(dfi$ev))]; dfi$wN <- 1 - dfi$wA
If <- c(I, list(dfi = dfi))
FI_R <- function(a2 = "asset_config('etf', 'bnh', share = 0.5, spread = 0.2, partial_exemption = 15)", extra = "", tax = "")
  sprintf("st <- create_strategy(A = asset_config('etf', 'bnh', share = 0.5, spread = 0.2, partial_exemption = 15), N = %s)\nr <- suppressWarnings(simulation(dfi, st, start_value = 1e5, rebalance = rebalance_plan(event_col = 'ev', event_mode = 'replace', skip = TRUE, event_weight = c(A = 'wA', N = 'wN')), tax = tax_profile(base_rate = 1%s)%s))\n", a2, tax, extra)
FI_J <- function(a2 = 'asset_config("etf", "bnh", share = 0.5, spread = 0.2, partial_exemption = 15)', extra = "", tax = "")
  sprintf('st = create_strategy(A = asset_config("etf", "bnh", share = 0.5, spread = 0.2, partial_exemption = 15), N = %s)\nr = B._quiet(() -> simulation(dfi, st; start_value = 1e5, rebalance = rebalance_plan(; event_col = "ev", event_mode = "replace", skip = true, event_weight = (A = "wA", N = "wN")), tax = tax_profile(; base_rate = 1%s)%s))\n', a2, tax, extra)
FI_P <- function(a2 = "simlev.asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.2, partial_exemption=15)", extra = "", tax = "")
  sprintf("import warnings as _w\nst = simlev.create_strategy(A=simlev.asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.2, partial_exemption=15), N=%s)\nwith _w.catch_warnings():\n    _w.simplefilter('ignore')\n    r = simlev.simulation(dfi, st, start_value=1e5, rebalance=simlev.rebalance_plan(event_col='ev', event_mode='replace', skip=True, event_weight={'A': 'wA', 'N': 'wN'}), tax=simlev.tax_profile(base_rate=1%s)%s)\n", a2, tax, extra)

# Vorspann je Szenario bzw. Tabellenzeile (gemeinsame Objekte des Moduls)
VOR <- list(r = r"()",
            py = r"(from simlev.bootstrap import *
from simlev.withdrawal import *
import simlev.withdrawal as W
import simlev._withdrawal_core as WC)",
            jl = r"(using SimLev.Bootstrap, SimLev.Withdrawal
const B = SimLev.Bootstrap
const W = SimLev.Withdrawal
const WC = SimLev.WithdrawalCore)")

ref_init("withdrawal", gruppe = "gleichlauf")
SZ("regeln_voreinstellungen", "withdrawal_rule mit den Voreinstellungen aller Regeln (vanguard, floor_ceiling, clyatt, ratchet, vpw, abw, cape, sensible, hebeler, guy) und percent mit Untergrenze, je Ergebnis und Druck", vor = VOR, teile = list(
  rule_vanguard = teil(
    r"(withdrawal_rule('vanguard'))",
    r"(result = withdrawal_rule(type='vanguard'))",
    r"(result = withdrawal_rule("vanguard"))", druck = TRUE, inp = ein("withdrawal/rule_vanguard", c())),
  rule_floor_ceiling = teil(
    r"(withdrawal_rule('floor_ceiling'))",
    r"(result = withdrawal_rule(type='floor_ceiling'))",
    r"(result = withdrawal_rule("floor_ceiling"))", druck = TRUE, inp = ein("withdrawal/rule_floor_ceiling", c())),
  rule_clyatt = teil(
    r"(withdrawal_rule('clyatt'))",
    r"(result = withdrawal_rule(type='clyatt'))",
    r"(result = withdrawal_rule("clyatt"))", druck = TRUE, inp = ein("withdrawal/rule_clyatt", c())),
  rule_ratchet = teil(
    r"(withdrawal_rule('ratchet'))",
    r"(result = withdrawal_rule(type='ratchet'))",
    r"(result = withdrawal_rule("ratchet"))", druck = TRUE, inp = ein("withdrawal/rule_ratchet", c())),
  rule_vpw = teil(
    r"(withdrawal_rule('vpw'))",
    r"(result = withdrawal_rule(type='vpw'))",
    r"(result = withdrawal_rule("vpw"))", druck = TRUE, inp = ein("withdrawal/rule_vpw", c())),
  rule_abw = teil(
    r"(withdrawal_rule('abw'))",
    r"(result = withdrawal_rule(type='abw'))",
    r"(result = withdrawal_rule("abw"))", druck = TRUE, inp = ein("withdrawal/rule_abw", c())),
  rule_cape = teil(
    r"(withdrawal_rule('cape'))",
    r"(result = withdrawal_rule(type='cape'))",
    r"(result = withdrawal_rule("cape"))", druck = TRUE, inp = ein("withdrawal/rule_cape", c())),
  rule_sensible = teil(
    r"(withdrawal_rule('sensible'))",
    r"(result = withdrawal_rule(type='sensible'))",
    r"(result = withdrawal_rule("sensible"))", druck = TRUE, inp = ein("withdrawal/rule_sensible", c())),
  rule_hebeler = teil(
    r"(withdrawal_rule('hebeler'))",
    r"(result = withdrawal_rule(type='hebeler'))",
    r"(result = withdrawal_rule("hebeler"))", druck = TRUE, inp = ein("withdrawal/rule_hebeler", c())),
  rule_bounds_min = teil(
    r"(withdrawal_rule('percent', min_real = 2e4))",
    r"(result = withdrawal_rule(type='percent', min_real=2e4))",
    r"(result = withdrawal_rule("percent"; min_real = 2e4))", druck = TRUE, inp = ein("withdrawal/rule_bounds_min", c())),
  rule_pfx = teil(
    r"(withdrawal_rule('guy'))",
    r"(result = withdrawal_rule(type='guy'))",
    r"(result = withdrawal_rule("guy"))", druck = TRUE, inp = ein("withdrawal/rule_pfx", c()))))
SZ("interne_hilfen", ".period_ends (Monats- und Jahresenden) und .wd_fee_set (Gebührensätze)", vor = VOR, teile = list(
  period_ends = teil(
    r"(x <- seq.Date(as.Date('2000-12-20'), by = 'day', length.out = 200); list(SimLev:::.period_ends(x, 'month'), SimLev:::.period_ends(x, 'quarter'), SimLev:::.period_ends(x, 'year')))",
    r"(x = np.datetime64('2000-12-20') + np.arange(200); result = [W._period_ends(x, 'month'), W._period_ends(x, 'quarter'), W._period_ends(x, 'year')])",
    r"(x = Date(2000, 12, 20) .+ Day.(0:199); result = [W._period_ends(x, "month"), W._period_ends(x, "quarter"), W._period_ends(x, "year")])", inp = ein("withdrawal/period_ends", c())),
  fee_set = teil(
    r"(c(SimLev:::.wd_fee_set(NULL), SimLev:::.wd_fee_set(1), SimLev:::.wd_fee_set(0), SimLev:::.wd_fee_set(list(fixed = 0, percent = 0, min = 0, max = Inf)), SimLev:::.wd_fee_set(list(fixed = 0, percent = 0.1)), SimLev:::.wd_fee_set('a'), SimLev:::.wd_fee_set(list(max = 5))))",
    r"(result = [W._wd_fee_set(None), W._wd_fee_set(1), W._wd_fee_set(0), W._wd_fee_set({'fixed': 0, 'percent': 0, 'min': 0, 'max': np.inf}), W._wd_fee_set({'fixed': 0, 'percent': 0.1}), W._wd_fee_set('a'), W._wd_fee_set({'max': 5})])",
    r"(result = [W._wd_fee_set(nothing), W._wd_fee_set(1), W._wd_fee_set(0), W._wd_fee_set((fixed = 0, percent = 0, min = 0, max = Inf)), W._wd_fee_set((fixed = 0, percent = 0.1)), W._wd_fee_set("a"), W._wd_fee_set((max = 5,))])", inp = ein("withdrawal/fee_set", c()))))
SZ("horizonte", "withdrawal_horizon dreieckig (auch entartet), Stichprobe, normal mit engen Grenzen und Walker-Ziehung", vor = VOR, teile = list(
  hz_tri = teil(
    r"(withdrawal_horizon('triangular', min = 10, mode = 25, max = 35))",
    r"(result = withdrawal_horizon(type='triangular', min=10, mode=25, max=35))",
    r"(result = withdrawal_horizon("triangular"; min = 10, mode = 25, max = 35))", druck = TRUE, inp = ein("withdrawal/hz_tri", c())),
  hz_tri0 = teil(
    r"(withdrawal_horizon('triangular', min = 30, mode = 30, max = 30))",
    r"(result = withdrawal_horizon(type='triangular', min=30, mode=30, max=30))",
    r"(result = withdrawal_horizon("triangular"; min = 30, mode = 30, max = 30))", druck = TRUE, inp = ein("withdrawal/hz_tri0", c())),
  hz_sample = teil(
    r"(withdrawal_horizon('sample', years = c(4, 12, 30)))",
    r"(result = withdrawal_horizon(type='sample', years=[4, 12, 30]))",
    r"(result = withdrawal_horizon("sample"; years = [4, 12, 30]))", druck = TRUE, inp = ein("withdrawal/hz_sample", c())),
  hz_small = teil(
    r"(withdrawal_horizon('normal', mean = 1, sd = 3, min = 1, max = 3))",
    r"(result = withdrawal_horizon(type='normal', mean=1, sd=3, min=1, max=3))",
    r"(result = withdrawal_horizon("normal"; mean = 1, sd = 3, min = 1, max = 3))", druck = TRUE, inp = ein("withdrawal/hz_small", c())),
  hz_draw_walker = teil(
    r"(SimLev:::.draw_horizon(withdrawal_horizon('discrete', years = 1:100, prob = (1:100)^2), 50))",
    r"(result = W._draw_horizon(withdrawal_horizon(type='discrete', years=np.arange(1, 101), prob=np.arange(1, 101) ** 2.0), 50))",
    r"(result = W._draw_horizon(withdrawal_horizon("discrete"; years = 1:100, prob = Float64.(1:100) .* (1:100)), 50))", inp = ein("withdrawal/hz_draw_walker", c()))))
SZ("simulation_regeln_und_risikoaversion", "withdrawal_simulation mit constant, ratchet, percent (gamma 1, Pfade behalten) und sensible (gamma 0), Grafikdaten mit zwei behaltenen Pfaden", vor = VOR, teile = list(
  ws_constant = teil(
    r"(ws <- withdrawal_simulation(R, withdrawal_rule('constant'), inflation = 2, start_value = 5e5); ws$elapsed <- 0; ws)",
    r"(ws = withdrawal_simulation(R, rule=withdrawal_rule(type='constant'), inflation=2, start_value=5e5); ws['elapsed'] = 0; result = ws)",
    r"(ws = withdrawal_simulation(R, withdrawal_rule("constant"); inflation = 2, start_value = 5e5); ws["elapsed"] = 0; result = ws)", druck = TRUE, inp = ein("withdrawal/ws_constant", c("R"))),
  ws_ratchet = teil(
    r"(ws <- withdrawal_simulation(R, withdrawal_rule('ratchet'), inflation = 2, start_value = 5e5); ws$elapsed <- 0; ws)",
    r"(ws = withdrawal_simulation(R, rule=withdrawal_rule(type='ratchet'), inflation=2, start_value=5e5); ws['elapsed'] = 0; result = ws)",
    r"(ws = withdrawal_simulation(R, withdrawal_rule("ratchet"); inflation = 2, start_value = 5e5); ws["elapsed"] = 0; result = ws)", druck = TRUE, inp = ein("withdrawal/ws_ratchet", c("R"))),
  ws_gamma1 = teil(
    r"(ws <- withdrawal_simulation(R, withdrawal_rule('percent'), inflation = 2, gamma = 1, keep_paths = FALSE); ws$elapsed <- 0; ws)",
    r"(ws = withdrawal_simulation(R, rule=withdrawal_rule(type='percent'), inflation=2, gamma=1, keep_paths=False); ws['elapsed'] = 0; result = ws)",
    r"(ws = withdrawal_simulation(R, withdrawal_rule("percent"); inflation = 2, gamma = 1, keep_paths = false); ws["elapsed"] = 0; result = ws)", druck = TRUE, inp = ein("withdrawal/ws_gamma1", c("R"))),
  ws_gamma0 = teil(
    r"(ws <- withdrawal_simulation(R, withdrawal_rule('sensible'), inflation = 2, gamma = 0); ws$elapsed <- 0; ws)",
    r"(ws = withdrawal_simulation(R, rule=withdrawal_rule(type='sensible'), inflation=2, gamma=0); ws['elapsed'] = 0; result = ws)",
    r"(ws = withdrawal_simulation(R, withdrawal_rule("sensible"); inflation = 2, gamma = 0); ws["elapsed"] = 0; result = ws)", druck = TRUE, inp = ein("withdrawal/ws_gamma0", c("R"))),
  ws_plot_keep2 = teil(
    r"({ws <- withdrawal_simulation(R, withdrawal_rule('percent'), inflation = 2, keep_paths = 2); grDevices::pdf(NULL); grDevices::dev.control('enable'); plot(ws); rp <- grDevices::recordPlot(); grDevices::dev.off(); dl <- rp[[1]]; nm <- vapply(dl, function(e) { f <- e[[2]][[1]]; if (is.list(f) && is.character(f$name)) f$name else '' }, ''); ti <- unlist(lapply(dl[nm == 'C_title'], function(e) e[[2]][[2]])); ln <- Filter(function(v) is.null(v$xlab), lapply(dl[nm == 'C_plotXY'], function(e) e[[2]][[2]])); pr <- c(0.05, 0.25, 0.5, 0.75, 0.95); tab <- function(M, w, x0) { Q <- apply(M, 1, function(r) SimLev:::.wquantile(r, w, pr)); d <- data.frame(year = x0 + seq_len(nrow(M)) - 1L); for (i in seq_along(pr)) d[[sprintf('q%02.0f', 100 * pr[i])]] <- Q[i, ]; d }; list(wealth = tab(ws$wealth, ws$weights[1:2], 0L), spending = tab(ws$spending, ws$weights, 1L), title = ti[1], mid_wealth = ln[[1]]$y, mid_spending = ln[[2]]$y, ncol = ncol(ws$wealth))})",
    r"(ws = withdrawal_simulation(R, rule=withdrawal_rule(type='percent'), inflation=2, keep_paths=2); p = ws.plot(); d = p.data; result = {'wealth': d['wealth'], 'spending': d['spending'], 'title': d['wealth'].attrs['title'], 'mid_wealth': d['wealth']['q50'].to_numpy() / 1000, 'mid_spending': d['spending']['q50'].to_numpy() / 1000, 'ncol': ws['wealth'].shape[1]})",
    r"(ws = withdrawal_simulation(R, withdrawal_rule("percent"); inflation = 2, keep_paths = 2); p = SL.r_plot(ws; file = nothing); d = p.data; result = SL.RList("wealth" => d["wealth"], "spending" => d["spending"], "title" => SL.attrs(d["wealth"])["title"], "mid_wealth" => d["wealth"]["q50"] ./ 1000, "mid_spending" => d["spending"]["q50"] ./ 1000, "ncol" => size(ws["wealth"], 2)))", inp = ein("withdrawal/ws_plot_keep2", c("R")))))
SZ("simulation_frequenz_inflation_horizont", "withdrawal_simulation monatlich mit CAPE-Kohorten, Inflation als Matrix bzw. NULL, fester und zufälliger Horizont (monatlich mit Steuer)", vor = VOR, teile = list(
  ws_cape_month = teil(
    r"(ws <- withdrawal_simulation(withdrawal_cohorts(m[1:120, ], price = 'depot', years = 4, step = 'year', frequency = 'month', cape = 'cape', base_rate = 'br'), withdrawal_rule('cape', cape_b = 1), tax = tax_profile()); ws$elapsed <- 0; ws)",
    r"(ws = withdrawal_simulation(withdrawal_cohorts(m.iloc[:120], price='depot', years=4, step='year', frequency='month', cape='cape', base_rate='br'), rule=withdrawal_rule(type='cape', cape_b=1), tax=simlev.tax_profile()); ws['elapsed'] = 0; result = ws)",
    r"(ws = withdrawal_simulation(withdrawal_cohorts(SL.rows(m, 1:120); price = "depot", years = 4, step = "year", frequency = "month", cape = "cape", base_rate = "br"), withdrawal_rule("cape"; cape_b = 1); tax = SL.tax_profile()); ws["elapsed"] = 0; result = ws)", druck = TRUE, inp = ein("withdrawal/ws_cape_month", c("m"))),
  ws_infl_mat = teil(
    r"(ws <- withdrawal_simulation(Rm[1:24, ], withdrawal_rule('clyatt'), frequency = 'month', inflation = matrix(1 + (1:96) / 1e4, 24, 4)); ws$elapsed <- 0; ws)",
    r"(ws = withdrawal_simulation(Rm[:24], rule=withdrawal_rule(type='clyatt'), frequency='month', inflation=(1 + np.arange(1, 97) / 1e4).reshape((24, 4), order='F')); ws['elapsed'] = 0; result = ws)",
    r"(ws = withdrawal_simulation(Rm[1:24, :], withdrawal_rule("clyatt"); frequency = "month", inflation = reshape(1 .+ (1:96) ./ 1e4, 24, 4)); ws["elapsed"] = 0; result = ws)", druck = TRUE, inp = ein("withdrawal/ws_infl_mat", c("Rm"))),
  ws_infl_null = teil(
    r"(ws <- withdrawal_simulation(R[, 1:2], withdrawal_rule('floor_ceiling'), inflation = NULL); ws$elapsed <- 0; ws)",
    r"(ws = withdrawal_simulation(R[:, :2], rule=withdrawal_rule(type='floor_ceiling'), inflation=None); ws['elapsed'] = 0; result = ws)",
    r"(ws = withdrawal_simulation(R[:, 1:2], withdrawal_rule("floor_ceiling"); inflation = nothing); ws["elapsed"] = 0; result = ws)", druck = TRUE, inp = ein("withdrawal/ws_infl_null", c("R"))),
  ws_hz_fixed = teil(
    r"(ws <- withdrawal_simulation(R, withdrawal_rule('hebeler'), horizon = 20); ws$elapsed <- 0; ws)",
    r"(ws = withdrawal_simulation(R, rule=withdrawal_rule(type='hebeler'), horizon=20); ws['elapsed'] = 0; result = ws)",
    r"(ws = withdrawal_simulation(R, withdrawal_rule("hebeler"); horizon = 20); ws["elapsed"] = 0; result = ws)", druck = TRUE, inp = ein("withdrawal/ws_hz_fixed", c("R"))),
  ws_hz_month = teil(
    r"(ws <- withdrawal_simulation(Rm, withdrawal_rule('percent', rate = 5), frequency = 'month', tax = tax_profile(), base_rate = 2.5, cost_basis = 60, horizon = withdrawal_horizon('uniform', min = 3, max = 9), keep_paths = FALSE); ws$elapsed <- 0; ws)",
    r"(ws = withdrawal_simulation(Rm, rule=withdrawal_rule(type='percent', rate=5), frequency='month', tax=simlev.tax_profile(), base_rate=2.5, cost_basis=60, horizon=withdrawal_horizon(type='uniform', min=3, max=9), keep_paths=False); ws['elapsed'] = 0; result = ws)",
    r"(ws = withdrawal_simulation(Rm, withdrawal_rule("percent"; rate = 5); frequency = "month", tax = SL.tax_profile(), base_rate = 2.5, cost_basis = 60, horizon = withdrawal_horizon("uniform"; min = 3, max = 9), keep_paths = false); ws["elapsed"] = 0; result = ws)", druck = TRUE, inp = ein("withdrawal/ws_hz_month", c("Rm")))))
SZ("simulation_mit_einkommen_und_steuer", "Einkommen in einzelnen Jahren; Kette simulation() (einmal gerechnet) -> withdrawal_simulation bzw. result_index (Index alter Form); Startwert mit Steuertabelle (Günstigerprüfung), monatliche Steuer mit Erstattung", vor = VOR,
  gemein = teil(
    r"(st <- create_strategy(ETF = asset_config('etf', 'bnh', spread = 0))
r1 <- simulation(dsim, st, start_value = 1000)
r2 <- simulation(dsim, st, start_value = 1000, dca = dca_plan(value = 500, span = 1)))",
    r"(st = simlev.create_strategy(ETF=simlev.asset_config(asset_class='etf', trading='bnh', spread=0))
r1 = simlev.simulation(dsim, st, start_value=1000)
r2 = simlev.simulation(dsim, st, start_value=1000, dca=simlev.dca_plan(value=500, span=1)))",
    r"(st = create_strategy(ETF = asset_config("etf", "bnh", spread = 0))
r1 = simulation(dsim, st; start_value = 1000)
r2 = simulation(dsim, st, start_value = 1000, dca = dca_plan(value = 500, span = 1)))"),
  teile = list(
  ws_income1 = teil(
    r"(ws <- withdrawal_simulation(matrix(1, 10, 1), withdrawal_rule('constant', rate = 4), start_value = 1e6, income = list(start = 3, end = 5, amount = 10000)); ws$elapsed <- 0; ws)",
    r"(ws = withdrawal_simulation(np.ones((10, 1)), rule=withdrawal_rule(type='constant', rate=4), start_value=1e6, income={'start': 3, 'end': 5, 'amount': 10000}); ws['elapsed'] = 0; result = ws)",
    r"(ws = withdrawal_simulation(ones(10, 1), withdrawal_rule("constant"; rate = 4); start_value = 1e6, income = Dict("start" => 3, "end" => 5, "amount" => 10000)); ws["elapsed"] = 0; result = ws)", druck = TRUE, inp = ein("withdrawal/ws_income1", c())),
  ws_result = teil(
    r"(ws <- withdrawal_simulation(r1, withdrawal_rule('constant', rate = 4), years = 2, inflation = 2); ws$elapsed <- 0; ws)",
    r"(ws = withdrawal_simulation(r1, rule=withdrawal_rule(type='constant', rate=4), years=2, inflation=2); ws['elapsed'] = 0; result = ws)",
    r"(ws = withdrawal_simulation(r1, withdrawal_rule("constant"; rate = 4); years = 2, inflation = 2); ws["elapsed"] = 0; result = ws)", druck = TRUE, inp = ein("withdrawal/ws_result", c("dsim"))),
  ri_old = teil(
    r"(r2$twr_index <- NULL; result_index(r2))",
    r"(r2.twr_index = None; result = result_index(r2))",
    r"(delete!(r2.data, "twr_index"); result = result_index(r2))", inp = ein("withdrawal/ri_old", c("dsim"))),
  ws_tt_sv_df = teil(
    r"(ws <- {rt <- simulation(dsim, create_strategy(ETF = asset_config('etf', 'bnh', spread = 0.2, partial_exemption = 30)), start_value = 1e5, tax = tax_profile(base_rate = 2))
y1 <- rt$tax_report$next_year$year; withdrawal_simulation(R[, 1:3], withdrawal_rule('percent', rate = 5), start_value = rt, tax = tax_profile(guenstigerpruefung = TRUE, income = income_tariff(data.frame(year = y1 + 0:29, taxable_income = 9000))))}; ws$elapsed <- 0; ws)",
    r"(ws = None
rt = simlev.simulation(dsim, simlev.create_strategy(ETF=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.2, partial_exemption=30)), start_value=1e5, tax=simlev.tax_profile(base_rate=2))
y1 = rt['tax_report']['next_year']['year']
ws = withdrawal_simulation(R[:, :3], rule=withdrawal_rule(type='percent', rate=5), start_value=rt, tax=simlev.tax_profile(guenstigerpruefung=True, income=simlev.income_tariff(pd.DataFrame({'year': [y1 + i for i in range(30)], 'taxable_income': [9000.0] * 30})))); ws['elapsed'] = 0; result = ws)",
    r"(ws = nothing
rt = simulation(dsim, create_strategy(ETF = asset_config("etf", "bnh", spread = 0.2, partial_exemption = 30)), start_value = 1e5, tax = tax_profile(base_rate = 2))
y1 = Int(rt["tax_report"]["next_year"]["year"])
ws = withdrawal_simulation(R[:, 1:3], withdrawal_rule("percent"; rate = 5); start_value = rt, tax = SL.tax_profile(; guenstigerpruefung = true, income = SL.income_tariff(SL.RFrame("year" => collect(y1:(y1 + 29)), "taxable_income" => fill(9000.0, 30))))); ws["elapsed"] = 0; result = ws)", druck = TRUE, inp = ein("withdrawal/ws_tt_sv_df", c("R", "dsim"))),
  ws_tt_refund_month = teil(
    r"(ws <- withdrawal_simulation(Rm, withdrawal_rule('percent', rate = 5), frequency = 'month', start_value = 3e5, timing = 'end', base_rate = 2.5, cost_basis = 40, inflation = 1, tax = tax_profile(church_tax = 9, guenstigerpruefung = TRUE, income = income_tariff(2000))); ws$elapsed <- 0; ws)",
    r"(ws = withdrawal_simulation(Rm, rule=withdrawal_rule(type='percent', rate=5), frequency='month', start_value=3e5, timing='end', base_rate=2.5, cost_basis=40, inflation=1, tax=simlev.tax_profile(church_tax=9, guenstigerpruefung=True, income=simlev.income_tariff(2000))); ws['elapsed'] = 0; result = ws)",
    r"(ws = withdrawal_simulation(Rm, withdrawal_rule("percent"; rate = 5); frequency = "month", start_value = 3e5, timing = "end", base_rate = 2.5, cost_basis = 40, inflation = 1, tax = SL.tax_profile(; church_tax = 9, guenstigerpruefung = true, income = SL.income_tariff(2000))); ws["elapsed"] = 0; result = ws)", druck = TRUE, inp = ein("withdrawal/ws_tt_refund_month", c("Rm")))))
SZ("hoechste_entnahmerate", "withdrawal_max_rate mit Tarif, ohne Lösung (NA) und an der oberen Grenze", vor = VOR, teile = list(
  mr_tariff = teil(
    r"(r <- withdrawal_max_rate(R[, 1:6], withdrawal_rule('constant'), success = 1, lower = 1, upper = 10, tol = 0.05, inflation = 2, cost_basis = 50, tax = tax_profile(church_tax = 9, guenstigerpruefung = TRUE, income = income_tariff(8000))); list(as.numeric(r), attr(r, 'success')))",
    r"(r = withdrawal_max_rate(R[:, :6], rule=withdrawal_rule(type='constant'), success=1, lower=1, upper=10, tol=0.05, inflation=2, cost_basis=50, tax=simlev.tax_profile(church_tax=9, guenstigerpruefung=True, income=simlev.income_tariff(8000))); result = [float(r), r.success])",
    r"(r = withdrawal_max_rate(R[:, 1:6], withdrawal_rule("constant"); success = 1, lower = 1, upper = 10, tol = 0.05, inflation = 2, cost_basis = 50, tax = SL.tax_profile(; church_tax = 9, guenstigerpruefung = true, income = SL.income_tariff(8000))); result = [r[1], SL.attrs(r)["success"]])", inp = ein("withdrawal/mr_tariff", c("R"))),
  mr_na = teil(
    r"(r <- withdrawal_max_rate(matrix(0.5, 10, 3), success = 0.9, lower = 15); list(as.numeric(r), attr(r, 'success')))",
    r"(r = withdrawal_max_rate(np.full((10, 3), 0.5), success=0.9, lower=15); result = [float(r), r.success])",
    r"(r = withdrawal_max_rate(fill(0.5, 10, 3); success = 0.9, lower = 15); result = [r[1], SL.attrs(r)["success"]])", inp = ein("withdrawal/mr_na", c())),
  mr_upper = teil(
    r"(r <- withdrawal_max_rate(matrix(1.5, 10, 3), success = 0.9); list(as.numeric(r), attr(r, 'success')))",
    r"(r = withdrawal_max_rate(np.full((10, 3), 1.5), success=0.9); result = [float(r), r.success])",
    r"(r = withdrawal_max_rate(fill(1.5, 10, 3); success = 0.9); result = [r[1], SL.attrs(r)["success"]])", inp = ein("withdrawal/mr_upper", c()))))
SZ("pfade_und_kohorten_aus_bootstrap", "Kette bootstrap() (Hilfsreihen als Niveau bzw. Rate, einmal gerechnet) -> withdrawal_paths mit CPI-Niveau, CAPE, Werktagen, wild ohne Attribut bzw. bootstrap_data -> withdrawal_cohorts; withdrawal_perfect_rate", vor = VOR,
  gemein = teil(
    r"(cfg <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices', aux_type = c(infl = 'rate', cpi = 'level'))
cfg0 <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices')
b <- bootstrap(db, cfg, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
b0 <- bootstrap(db, cfg0, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE))",
    r"(cfg = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices', aux_type={'infl': 'rate', 'cpi': 'level'})
cfg0 = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices')
b = bootstrap(db, cfg, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
b0 = bootstrap(db, cfg0, method='stationary', n=3, params={'L': 60}, seed=4, progress=False))",
    r"(cfg = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices", aux_type = (infl = "rate", cpi = "level"))
cfg0 = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices")
b = bootstrap(db, cfg, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
b0 = bootstrap(db, cfg0, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false))"),
  teile = list(
  wp_level_attr = teil(
    r"(withdrawal_paths(b, column = 'us', inflation = 'cpi', frequency = 'month'))",
    r"(result = withdrawal_paths(b, column='us', inflation='cpi', frequency='month'))",
    r"(result = withdrawal_paths(b; column = "us", inflation = "cpi", frequency = "month"))", inp = ein("withdrawal/wp_level_attr", c("db"))),
  wp_cape1 = teil(
    r"(withdrawal_paths(b, column = 'us', cape = 'zins', dates = seq.Date(as.Date('2003-02-28'), by = 'day', length.out = 1101)))",
    r"(result = withdrawal_paths(b, column='us', cape='zins', dates=np.datetime64('2003-02-28') + np.arange(1101)))",
    r"(result = withdrawal_paths(b; column = "us", cape = "zins", dates = Date(2003, 2, 28) .+ Day.(0:1100)))", inp = ein("withdrawal/wp_cape1", c("db"))),
  wp_td = teil(
    r"(x <- seq.Date(as.Date('2001-01-01'), by = 'day', length.out = 2000); x <- x[!format(x, '%u') %in% c('6', '7')][1:1101]; withdrawal_paths(b, column = 'us', inflation = 'infl', dates = x))",
    r"(x = np.datetime64('2001-01-01') + np.arange(2000); x = x[(x.astype(int) + 3) % 7 < 5][:1101]; result = withdrawal_paths(b, column='us', inflation='infl', dates=x))",
    r"(x = Date(2001, 1, 1) .+ Day.(0:1999); x = x[Dates.dayofweek.(x) .< 6][1:1101]; result = withdrawal_paths(b; column = "us", inflation = "infl", dates = x))", inp = ein("withdrawal/wp_td", c("db"))),
  wp_wild_noattr = teil(
    r"(b0$paths <- lapply(b0$paths, function(p) { attr(p, 'aux_level') <- NULL; p }); b0$method <- 'wild'; withdrawal_paths(b0, column = 'us', inflation = 'zins'))",
    r"([p.attrs.pop('aux_level') for p in b0['paths']]; b0['method'] = 'wild'; result = withdrawal_paths(b0, column='us', inflation='zins'))",
    r"(for p in b0["paths"]; delete!(p.attrs, "aux_level"); end; b0["method"] = "wild"; result = withdrawal_paths(b0; column = "us", inflation = "zins"))", inp = ein("withdrawal/wp_wild_noattr", c("db"))),
  coh_bd_attr_ok = teil(
    r"(x <- bootstrap_data(b, 2); withdrawal_cohorts(x, price = 'us', inflation = 'infl', years = 1, inflation_type = 'rate_pa', step = 'year'))",
    r"(x = bootstrap_data(b, i=2); result = withdrawal_cohorts(x, price='us', inflation='infl', years=1, inflation_type='rate_pa', step='year'))",
    r"(x = bootstrap_data(b, 2); result = withdrawal_cohorts(x; price = "us", inflation = "infl", years = 1, inflation_type = "rate_pa", step = "year"))", inp = ein("withdrawal/coh_bd_attr_ok", c("db"))),
  pwr_wp = teil(
    r"(withdrawal_perfect_rate(withdrawal_cohorts(m, price = 'depot', inflation = 'cpi', years = 3, step = 'year', frequency = 'month')))",
    r"(result = withdrawal_perfect_rate(withdrawal_cohorts(m, price='depot', inflation='cpi', years=3, step='year', frequency='month')))",
    r"(result = withdrawal_perfect_rate(withdrawal_cohorts(m; price = "depot", inflation = "cpi", years = 3, step = "year", frequency = "month")))", inp = ein("withdrawal/pwr_wp", c("m")))))
SZ("fifo_aus_der_ansparphase", "Lots der Ansparphase in die Entnahme (FIFO): Sparerpauschbetrag im Folgejahr und Liquidation", vor = VOR, teile = list(
  fifo_ny_spb = teil(
    r"(ws <- {r <- simulation(dfi, create_strategy(C = asset_config('etf', 'bnh', spread = 0, partial_exemption = 30)), start_value = 1e5, tax = tax_profile(base_rate = 3.2)); withdrawal_simulation(matrix(1.1, 3, 1), withdrawal_rule('constant', rate = 4), start_value = r, tax = tax_profile(sparer_pauschbetrag = 2000), base_rate = 3.2)}; ws$elapsed <- 0; ws)",
    r"(ws = None
r = simlev.simulation(dfi, simlev.create_strategy(C=simlev.asset_config(asset_class='etf', trading='bnh', spread=0, partial_exemption=30)), start_value=1e5, tax=simlev.tax_profile(base_rate=3.2)); ws = withdrawal_simulation(np.full((3, 1), 1.1), rule=withdrawal_rule(type='constant', rate=4), start_value=r, tax=simlev.tax_profile(sparer_pauschbetrag=2000), base_rate=3.2); ws['elapsed'] = 0; result = ws)",
    r"(ws = nothing
r = simulation(dfi, create_strategy(C = asset_config("etf", "bnh", spread = 0, partial_exemption = 30)), start_value = 1e5, tax = tax_profile(base_rate = 3.2)); ws = withdrawal_simulation(fill(1.1, 3, 1), withdrawal_rule("constant"; rate = 4); start_value = r, tax = SL.tax_profile(; sparer_pauschbetrag = 2000), base_rate = 3.2); ws["elapsed"] = 0; result = ws)", druck = TRUE, inp = ein("withdrawal/fifo_ny_spb", c("dfi"))),
  fifo_liquidate = teil(
    r"(ws <- {r <- simulation(dfi, create_strategy(C = asset_config('etf', 'bnh', spread = 0, partial_exemption = 30)), start_value = 1e5, tax = tax_profile(base_rate = 3.2), liquidate = TRUE); withdrawal_simulation(matrix(1.05, 3, 1), start_value = r, tax = tax_profile())}; ws$elapsed <- 0; ws)",
    r"(ws = None
r = simlev.simulation(dfi, simlev.create_strategy(C=simlev.asset_config(asset_class='etf', trading='bnh', spread=0, partial_exemption=30)), start_value=1e5, tax=simlev.tax_profile(base_rate=3.2), liquidate=True); ws = withdrawal_simulation(np.full((3, 1), 1.05), start_value=r, tax=simlev.tax_profile()); ws['elapsed'] = 0; result = ws)",
    r"(ws = nothing
r = simulation(dfi, create_strategy(C = asset_config("etf", "bnh", spread = 0, partial_exemption = 30)), start_value = 1e5, tax = tax_profile(base_rate = 3.2), liquidate = true); ws = withdrawal_simulation(fill(1.05, 3, 1); start_value = r, tax = SL.tax_profile()); ws["elapsed"] = 0; result = ws)", druck = TRUE, inp = ein("withdrawal/fifo_liquidate", c("dfi")))))
ref_done()

ref_init("withdrawal", gruppe = "fehler")
TB("withdrawal_rule", "Meldungen und Warnungen von withdrawal_rule je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("rule_warn_rate",
    r"(withdrawal_rule('constant', rate = 0.04))",
    r"(result = withdrawal_rule(type='constant', rate=0.04))",
    r"(result = withdrawal_rule("constant"; rate = 0.04))", print = TRUE, inp = ein("withdrawal/rule_warn_rate", c())),
  zeile("rule_warn_frac2",
    r"(withdrawal_rule('endowment', smoothing = 0.1, extra = 0.15, cut = 0))",
    r"(result = withdrawal_rule(type='endowment', smoothing=0.1, extra=0.15, cut=0))",
    r"(result = withdrawal_rule("endowment"; smoothing = 0.1, extra = 0.15, cut = 0))", print = TRUE, inp = ein("withdrawal/rule_warn_frac2", c())),
  zeile("rule_err_rate120",
    r"(withdrawal_rule('constant', rate = 120))",
    r"(result = withdrawal_rule(type='constant', rate=120))",
    r"(result = withdrawal_rule("constant"; rate = 120))", inp = ein("withdrawal/rule_err_rate120", c())),
  zeile("rule_err_vpwage",
    r"(withdrawal_rule('vpw', age = 70, max_age = 65))",
    r"(result = withdrawal_rule(type='vpw', age=70, max_age=65))",
    r"(result = withdrawal_rule("vpw"; age = 70, max_age = 65))", inp = ein("withdrawal/rule_err_vpwage", c())),
  zeile("rule_err_minmax",
    r"(withdrawal_rule('constant', min_real = 5e4, max_real = 1e4))",
    r"(result = withdrawal_rule(type='constant', min_real=5e4, max_real=1e4))",
    r"(result = withdrawal_rule("constant"; min_real = 5e4, max_real = 1e4))", inp = ein("withdrawal/rule_err_minmax", c())),
  zeile("rule_err_skip",
    r"(withdrawal_rule('guyton_klinger', skip_inflation = 'ja'))",
    r"(result = withdrawal_rule(type='guyton_klinger', skip_inflation='ja'))",
    r"(result = withdrawal_rule("guyton_klinger"; skip_inflation = "ja"))", inp = ein("withdrawal/rule_err_skip", c())),
  zeile("rule_err_maxrate",
    r"(withdrawal_rule('vpw', max_rate = 0))",
    r"(result = withdrawal_rule(type='vpw', max_rate=0))",
    r"(result = withdrawal_rule("vpw"; max_rate = 0))", inp = ein("withdrawal/rule_err_maxrate", c())),
  zeile("rule_err_fv",
    r"(withdrawal_rule('abw', fv = -1))",
    r"(result = withdrawal_rule(type='abw', fv=-1))",
    r"(result = withdrawal_rule("abw"; fv = -1))", inp = ein("withdrawal/rule_err_fv", c())),
  zeile("rule_err_unused",
    r"(withdrawal_rule('one_over_n', horizon = 30))",
    r"(result = withdrawal_rule(type='one_over_n', horizon=30))",
    r"(result = withdrawal_rule("one_over_n"; horizon = 30))", inp = ein("withdrawal/rule_err_unused", c())),
  zeile("core_err_infl",
    r"(SimLev:::.wd_simulate(R, matrix(1, 30, 1), matrix(0, 30, 0), matrix(2.5, 30, 12), 1L, 1L, SimLev:::.wd_param_vector(withdrawal_rule('constant')), TRUE, 1e6, rep(0, 30), FALSE, 0.26375, 0.3, 1000, TRUE, 0, 1, 0, TRUE))",
    r"(result = WC.wd_simulate(R, np.ones((30, 1)), np.zeros((30, 0)), np.full((30, 12), 2.5), 1, 1, W._wd_param_vector(withdrawal_rule(type='constant')), True, 1e6, np.zeros(30), False, 0.26375, 0.3, 1000, True, 0, 1, 0, True))",
    r"(result = WC.wd_simulate(R, ones(30, 1), zeros(30, 0), fill(2.5, 30, 12), 1, 1, W._wd_param_vector(withdrawal_rule("constant")), true, 1e6, zeros(30), false, 0.26375, 0.3, 1000, true, 0, 1, 0, true))", inp = ein("withdrawal/core_err_infl", c("R"))),
  zeile("core_err_lots",
    r"(SimLev:::.wd_simulate(R, R, matrix(0, 30, 0), R, 1L, 1L, SimLev:::.wd_param_vector(withdrawal_rule('constant')), TRUE, 1e6, 0, TRUE, 0.26375, 0.3, 1000, TRUE, 0, 1, 0, TRUE, c(1, 0), c(1, 1), c(0, 0), c(0L, 1L)))",
    r"(result = WC.wd_simulate(R, R, np.zeros((30, 0)), R, 1, 1, W._wd_param_vector(withdrawal_rule(type='constant')), True, 1e6, [0.0], True, 0.26375, 0.3, 1000, True, 0, 1, 0, True, [1, 0], [1, 1], [0, 0], [0, 1]))",
    r"(result = WC.wd_simulate(R, R, zeros(30, 0), R, 1, 1, W._wd_param_vector(withdrawal_rule("constant")), true, 1e6, [0.0], true, 0.26375, 0.3, 1000, true, 0, 1, 0, true, [1, 0], [1, 1], [0, 0], [0, 1]))", inp = ein("withdrawal/core_err_lots", c("R")))))
TB(".wd_ppy", "Meldungen und Warnungen von .wd_ppy je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("ppy_err",
    r"(SimLev:::.wd_ppy('week'))",
    r"(result = W._wd_ppy('week'))",
    r"(result = W._wd_ppy("week"))", inp = ein("withdrawal/ppy_err", c()))))
TB("withdrawal_cohorts", "Meldungen und Warnungen von withdrawal_cohorts je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("coh_err_cols",
    r"(withdrawal_cohorts(m, price = 'x'))",
    r"(result = withdrawal_cohorts(m, price='x'))",
    r"(result = withdrawal_cohorts(m; price = "x"))", inp = ein("withdrawal/coh_err_cols", c("m"))),
  zeile("coh_err_gap",
    r"(withdrawal_cohorts(m[-50, ], price = 'depot', years = 10, step = 'year'))",
    r"(result = withdrawal_cohorts(m.drop(index=49), price='depot', years=10, step='year'))",
    r"(result = withdrawal_cohorts(SL.rows(m, setdiff(1:240, 50)); price = "depot", years = 10, step = "year"))", inp = ein("withdrawal/coh_err_gap", c("m"))),
  zeile("coh_err_years0",
    r"(withdrawal_cohorts(m, price = 'depot', years = 0))",
    r"(result = withdrawal_cohorts(m, price='depot', years=0))",
    r"(result = withdrawal_cohorts(m; price = "depot", years = 0))", inp = ein("withdrawal/coh_err_years0", c("m"))),
  zeile("coh_err_short",
    r"(withdrawal_cohorts(m, price = 'depot', years = 30))",
    r"(result = withdrawal_cohorts(m, price='depot', years=30))",
    r"(result = withdrawal_cohorts(m; price = "depot", years = 30))", inp = ein("withdrawal/coh_err_short", c("m"))),
  zeile("coh_err_ratebad",
    r"(x <- m; x$infl[30] <- -150; withdrawal_cohorts(x, price = 'depot', inflation = 'infl', inflation_type = 'rate_pa', years = 1))",
    r"(result = x = m.copy(); x.loc[29, 'infl'] = -150; withdrawal_cohorts(x, price='depot', inflation='infl', inflation_type='rate_pa', years=1))",
    r"(result = (x = copy(m); x.infl[30] = -150; withdrawal_cohorts(x; price = "depot", inflation = "infl", inflation_type = "rate_pa", years = 1)))", inp = ein("withdrawal/coh_err_ratebad", c("m"))),
  zeile("coh_result_err",
    r"(st <- create_strategy(ETF = asset_config('etf', 'bnh', spread = 0))
r1 <- simulation(dsim, st, start_value = 1000)
r2 <- simulation(dsim, st, start_value = 1000, dca = dca_plan(value = 500, span = 1))
withdrawal_cohorts(r2, years = 2, inflation = 'cpi'))",
    r"(st = simlev.create_strategy(ETF=simlev.asset_config(asset_class='etf', trading='bnh', spread=0))
r1 = simlev.simulation(dsim, st, start_value=1000)
r2 = simlev.simulation(dsim, st, start_value=1000, dca=simlev.dca_plan(value=500, span=1))
result = withdrawal_cohorts(r2, years=2, inflation='cpi'))",
    r"(st = create_strategy(ETF = asset_config("etf", "bnh", spread = 0))
r1 = simulation(dsim, st; start_value = 1000)
r2 = simulation(dsim, st, start_value = 1000, dca = dca_plan(value = 500, span = 1))
result = withdrawal_cohorts(r2; years = 2, inflation = "cpi"))", inp = ein("withdrawal/coh_result_err", c("dsim")))))
TB("withdrawal_perfect_rate", "Meldungen und Warnungen von withdrawal_perfect_rate je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("pwr_err_med",
    r"(withdrawal_perfect_rate(c(0.05, 0.02, -0.1)))",
    r"(result = withdrawal_perfect_rate([0.05, 0.02, -0.1]))",
    r"(result = withdrawal_perfect_rate([0.05, 0.02, -0.1]))", inp = ein("withdrawal/pwr_err_med", c())),
  zeile("pwr_err_neg",
    r"(withdrawal_perfect_rate(c(1.05, 1.1, -0.2)))",
    r"(result = withdrawal_perfect_rate([1.05, 1.1, -0.2]))",
    r"(result = withdrawal_perfect_rate([1.05, 1.1, -0.2]))", inp = ein("withdrawal/pwr_err_neg", c())),
  zeile("pwr_err_legv",
    r"(withdrawal_perfect_rate(c(1.05, 1.02), legacy = c(1, 2)))",
    r"(result = withdrawal_perfect_rate([1.05, 1.02], legacy=[1, 2]))",
    r"(result = withdrawal_perfect_rate([1.05, 1.02]; legacy = [1, 2]))", inp = ein("withdrawal/pwr_err_legv", c())),
  zeile("pwr_err_inf",
    r"(withdrawal_perfect_rate(c(1.05, Inf)))",
    r"(result = withdrawal_perfect_rate([1.05, np.inf]))",
    r"(result = withdrawal_perfect_rate([1.05, Inf]))", inp = ein("withdrawal/pwr_err_inf", c()))))
TB("withdrawal_simulation", "Meldungen und Warnungen von withdrawal_simulation je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("ws_err_wrapper_infl",   # seit 1.6.4 (K43 RS B3, Meldung mit Funktionsnamen, Entscheidung 155)
    r"(dw <- data.frame(date = seq.Date(as.Date('2019-11-04'), by = 'day', length.out = 400), A = 100 * cumprod(1 + sin(1:400) / 100), B = 50 * cumprod(1 + cos(1:400) / 200))
inner <- create_strategy(A = asset_config('etf', 'bnh', 0.6), B = asset_config('etf', 'bnh', 0.4))
x <- wrapper_nav(dw, wrapper_config(inner, costs = funds_costs(0, 0))); withdrawal_simulation(x, inflation = 'x'))",
    r"(dw = pd.DataFrame({'date': pd.date_range('2019-11-04', periods=400), 'A': 100 * np.cumprod(1 + np.sin(np.arange(1, 401)) / 100), 'B': 50 * np.cumprod(1 + np.cos(np.arange(1, 401)) / 200)})
inner = simlev.create_strategy(A=simlev.asset_config(asset_class='etf', trading='bnh', share=0.6), B=simlev.asset_config(asset_class='etf', trading='bnh', share=0.4))
x = simlev.wrapper_nav(dw, simlev.wrapper_config(inner, costs=simlev.funds_costs(fee=0, performance_fee=0)))
result = withdrawal_simulation(x, inflation='x'))",
    r"(dw = RFrame("date" => collect(Date(2019, 11, 4):Day(1):(Date(2019, 11, 4) + Day(399))), "A" => 100 .* cumprod(1 .+ sin.(1:400) ./ 100), "B" => 50 .* cumprod(1 .+ cos.(1:400) ./ 200))
inner = create_strategy("A" => asset_config("etf", "bnh", 0.6), "B" => asset_config("etf", "bnh", 0.4))
x = wrapper_nav(dw, wrapper_config(inner; costs = funds_costs(0, 0))); result = withdrawal_simulation(x; inflation = "x"))", inp = list()),
  zeile("ws_err_kohorte_na",   # seit 1.6.4 (K43 RS B3, Meldung mit Funktionsnamen, Entscheidung 155)
    r"(dc <- data.frame(date = seq.Date(as.Date('2015-01-01'), by = 'month', length.out = 40), p = 100 * cumprod(1 + sin(1:40) / 50))
x <- withdrawal_cohorts(dc, price = 'p', years = 1, inflation = 2); x$inflation[1, 1] <- NA; withdrawal_simulation(x))",
    r"(dc = pd.DataFrame({'date': pd.date_range('2015-01-01', periods=40, freq='MS'), 'p': 100 * np.cumprod(1 + np.sin(np.arange(1, 41)) / 50)})
x = withdrawal_cohorts(dc, price='p', years=1, inflation=2); x['inflation'][0, 0] = simlev._r.base.NA_REAL
result = withdrawal_simulation(x))",
    r"(dc = RFrame("date" => [Date(2015, 1, 1) + Month(k) for k in 0:39], "p" => 100 .* cumprod(1 .+ sin.(1:40) ./ 50))
x = withdrawal_cohorts(dc; price = "p", years = 1, inflation = 2); x["inflation"][1, 1] = SimLev.NA
result = withdrawal_simulation(x))", inp = list()),
  zeile("ws_quarter_trunc",
    r"(ws <- withdrawal_simulation(Rq, withdrawal_rule('endowment', rate = 4), frequency = 'quarter', inflation = 2); ws$elapsed <- 0; ws)",
    r"(ws = withdrawal_simulation(Rq, rule=withdrawal_rule(type='endowment', rate=4), frequency='quarter', inflation=2); ws['elapsed'] = 0; result = ws)",
    r"(ws = withdrawal_simulation(Rq, withdrawal_rule("endowment"; rate = 4); frequency = "quarter", inflation = 2); ws["elapsed"] = 0; result = ws)", print = TRUE, inp = ein("withdrawal/ws_quarter_trunc", c("Rq"))),
  zeile("ws_years_q",
    r"(ws <- withdrawal_simulation(Rq, withdrawal_rule('constant'), frequency = 'quarter', years = 2.75, tax = tax_profile(), base_rate = matrix(2, 42, 3)); ws$elapsed <- 0; ws)",
    r"(ws = withdrawal_simulation(Rq, rule=withdrawal_rule(type='constant'), frequency='quarter', years=2.75, tax=simlev.tax_profile(), base_rate=np.full((42, 3), 2.0)); ws['elapsed'] = 0; result = ws)",
    r"(ws = withdrawal_simulation(Rq, withdrawal_rule("constant"); frequency = "quarter", years = 2.75, tax = SL.tax_profile(), base_rate = fill(2.0, 42, 3)); ws["elapsed"] = 0; result = ws)", print = TRUE, inp = ein("withdrawal/ws_years_q", c("Rq"))),
  zeile("ws_short_month",
    r"(ws <- withdrawal_simulation(Rm[1:7, ], withdrawal_rule('constant'), frequency = 'month'); ws$elapsed <- 0; ws)",
    r"(ws = withdrawal_simulation(Rm[:7], rule=withdrawal_rule(type='constant'), frequency='month'); ws['elapsed'] = 0; result = ws)",
    r"(ws = withdrawal_simulation(Rm[1:7, :], withdrawal_rule("constant"); frequency = "month"); ws["elapsed"] = 0; result = ws)", print = TRUE, inp = ein("withdrawal/ws_short_month", c("Rm"))),
  zeile("ws_hz_disc",
    r"(ws <- withdrawal_simulation(R, withdrawal_rule('constant', rate = 5), inflation = 2, horizon = withdrawal_horizon('discrete', years = c(10, 20, 35), prob = c(1, 2, 1)), tax = tax_profile(), cost_basis = 60); ws$elapsed <- 0; ws)",
    r"(ws = withdrawal_simulation(R, rule=withdrawal_rule(type='constant', rate=5), inflation=2, horizon=withdrawal_horizon(type='discrete', years=[10, 20, 35], prob=[1, 2, 1]), tax=simlev.tax_profile(), cost_basis=60); ws['elapsed'] = 0; result = ws)",
    r"(ws = withdrawal_simulation(R, withdrawal_rule("constant"; rate = 5); inflation = 2, horizon = withdrawal_horizon("discrete"; years = [10, 20, 35], prob = [1, 2, 1]), tax = SL.tax_profile(), cost_basis = 60); ws["elapsed"] = 0; result = ws)", print = TRUE, inp = ein("withdrawal/ws_hz_disc", c("R"))),
  zeile("ws_tt_quarter",
    r"(ws <- withdrawal_simulation(Rq, withdrawal_rule('vanguard', rate = 5), frequency = 'quarter', start_value = 4e5, base_rate = 2, cost_basis = 50, tax = tax_profile(church_tax = 8, guenstigerpruefung = TRUE, income = income_tariff(seq(3000, 23000, by = 2000)))); ws$elapsed <- 0; ws)",
    r"(ws = withdrawal_simulation(Rq, rule=withdrawal_rule(type='vanguard', rate=5), frequency='quarter', start_value=4e5, base_rate=2, cost_basis=50, tax=simlev.tax_profile(church_tax=8, guenstigerpruefung=True, income=simlev.income_tariff(list(range(3000, 23001, 2000))))); ws['elapsed'] = 0; result = ws)",
    r"(ws = withdrawal_simulation(Rq, withdrawal_rule("vanguard"; rate = 5); frequency = "quarter", start_value = 4e5, base_rate = 2, cost_basis = 50, tax = SL.tax_profile(; church_tax = 8, guenstigerpruefung = true, income = SL.income_tariff(collect(3000.0:2000.0:23000.0)))); ws["elapsed"] = 0; result = ws)", print = TRUE, inp = ein("withdrawal/ws_tt_quarter", c("Rq"))),
  zeile("ws_tt_err_len",
    r"(withdrawal_simulation(R[, 1:2], tax = tax_profile(income = income_tariff(c(1e4, 2e4, 3e4)))))",
    r"(result = withdrawal_simulation(R[:, :2], tax=simlev.tax_profile(income=simlev.income_tariff([1e4, 2e4, 3e4]))))",
    r"(result = withdrawal_simulation(R[:, 1:2]; tax = SL.tax_profile(; income = SL.income_tariff([1e4, 2e4, 3e4]))))", inp = ein("withdrawal/ws_tt_err_len", c("R"))),
  zeile("ws_tt_err_named",
    r"(withdrawal_simulation(R[, 1:2], tax = tax_profile(income = income_tariff(c('2030' = 1e4, '2031' = 2e4)))))",
    r"(result = withdrawal_simulation(R[:, :2], tax=simlev.tax_profile(income=simlev.income_tariff({'2030': 1e4, '2031': 2e4}))))",
    r"(result = withdrawal_simulation(R[:, 1:2]; tax = SL.tax_profile(; income = SL.income_tariff(["2030" => 1e4, "2031" => 2e4]))))", inp = ein("withdrawal/ws_tt_err_named", c("R"))),
  zeile("ws_err_rule",
    r"(withdrawal_simulation(R, list()))",
    r"(result = withdrawal_simulation(R, rule={}))",
    r"(result = withdrawal_simulation(R, (;)))", inp = ein("withdrawal/ws_err_rule", c("R"))),
  zeile("ws_err_taxcls",
    r"(withdrawal_simulation(R, tax = 'person'))",
    r"(result = withdrawal_simulation(R, tax='person'))",
    r"(result = withdrawal_simulation(R; tax = "person"))", inp = ein("withdrawal/ws_err_taxcls", c("R"))),
  zeile("ws_err_taxinc",
    r"(withdrawal_simulation(R, tax = tax_profile(base_rate = 2, income = income_rate(42), harvest = harvest_rule(), private_sale_threshold = 600)))",
    r"(result = withdrawal_simulation(R, tax=simlev.tax_profile(base_rate=2, income=simlev.income_rate(42), harvest=simlev.harvest_rule(), private_sale_threshold=600)))",
    r"(result = withdrawal_simulation(R; tax = SL.tax_profile(; base_rate = 2, income = SL.income_rate(42), harvest = SL.harvest_rule(), private_sale_threshold = 600)))", inp = ein("withdrawal/ws_err_taxinc", c("R"))),
  zeile("ws_err_gamma",
    r"(withdrawal_simulation(R, gamma = -1))",
    r"(result = withdrawal_simulation(R, gamma=-1))",
    r"(result = withdrawal_simulation(R; gamma = -1))", inp = ein("withdrawal/ws_err_gamma", c("R"))),
  zeile("ws_err_vp",
    r"(withdrawal_simulation(R, vorabpauschale = 'ja'))",
    r"(result = withdrawal_simulation(R, vorabpauschale='ja'))",
    r"(result = withdrawal_simulation(R; vorabpauschale = "ja"))", inp = ein("withdrawal/ws_err_vp", c("R"))),
  zeile("ws_err_inflmat",
    r"(withdrawal_simulation(R, inflation = matrix(1.02, 30, 1)))",
    r"(result = withdrawal_simulation(R, inflation=np.full((30, 1), 1.02)))",
    r"(result = withdrawal_simulation(R; inflation = fill(1.02, 30, 1)))", inp = ein("withdrawal/ws_err_inflmat", c("R"))),
  zeile("ws_err_inflchr",
    r"(withdrawal_simulation(R, inflation = 'cpi'))",
    r"(result = withdrawal_simulation(R, inflation='cpi'))",
    r"(result = withdrawal_simulation(R; inflation = "cpi"))", inp = ein("withdrawal/ws_err_inflchr", c("R"))),
  zeile("ws_err_hz0",
    r"(withdrawal_simulation(R, horizon = 0))",
    r"(result = withdrawal_simulation(R, horizon=0))",
    r"(result = withdrawal_simulation(R; horizon = 0))", inp = ein("withdrawal/ws_err_hz0", c("R"))),
  zeile("ws_err_years",
    r"(withdrawal_simulation(R, years = -1))",
    r"(result = withdrawal_simulation(R, years=-1))",
    r"(result = withdrawal_simulation(R; years = -1))", inp = ein("withdrawal/ws_err_years", c("R"))),
  zeile("ws_err_yearsq",
    r"(withdrawal_simulation(Rq, frequency = 'quarter', years = 2.6))",
    r"(result = withdrawal_simulation(Rq, frequency='quarter', years=2.6))",
    r"(result = withdrawal_simulation(Rq; frequency = "quarter", years = 2.6))", inp = ein("withdrawal/ws_err_yearsq", c("Rq"))),
  zeile("ws_err_br",
    r"(withdrawal_simulation(R, base_rate = 'x'))",
    r"(result = withdrawal_simulation(R, base_rate='x'))",
    r"(result = withdrawal_simulation(R; base_rate = "x"))", inp = ein("withdrawal/ws_err_br", c("R"))),
  zeile("ws_err_brmat",
    r"(withdrawal_simulation(R, tax = tax_profile(), base_rate = matrix(2.5, 1, 1)))",
    r"(result = withdrawal_simulation(R, tax=simlev.tax_profile(), base_rate=np.full((1, 1), 2.5)))",
    r"(result = withdrawal_simulation(R; tax = SL.tax_profile(), base_rate = fill(2.5, 1, 1)))", inp = ein("withdrawal/ws_err_brmat", c("R"))),
  zeile("ws_err_income",
    r"(withdrawal_simulation(R, income = list(list(start = 5, end = 3, amount = 10000))))",
    r"(result = withdrawal_simulation(R, income=[{'start': 5, 'end': 3, 'amount': 10000}]))",
    r"(result = withdrawal_simulation(R; income = [Dict("start" => 5, "end" => 3, "amount" => 10000)]))", inp = ein("withdrawal/ws_err_income", c("R"))),
  zeile("ws_err_income2",
    r"(withdrawal_simulation(R, income = list(list(start = 5))))",
    r"(result = withdrawal_simulation(R, income=[{'start': 5}]))",
    r"(result = withdrawal_simulation(R; income = [Dict("start" => 5)]))", inp = ein("withdrawal/ws_err_income2", c("R"))),
  zeile("ws_err_sv",
    r"(withdrawal_simulation(R, start_value = -800))",
    r"(result = withdrawal_simulation(R, start_value=-800))",
    r"(result = withdrawal_simulation(R; start_value = -800))", inp = ein("withdrawal/ws_err_sv", c("R"))),
  zeile("ws_err_neg",
    r"(withdrawal_simulation(R - 1))",
    r"(result = withdrawal_simulation(R - 1))",
    r"(result = withdrawal_simulation(R .- 1))", inp = ein("withdrawal/ws_err_neg", c("R"))),
  zeile("ws_err_cape",
    r"(withdrawal_simulation(R, withdrawal_rule('cape')))",
    r"(result = withdrawal_simulation(R, rule=withdrawal_rule(type='cape')))",
    r"(result = withdrawal_simulation(R, withdrawal_rule("cape")))", inp = ein("withdrawal/ws_err_cape", c("R"))),
  zeile("ws_err_na",
    r"(x <- R; x[3, 2] <- NA; withdrawal_simulation(x))",
    r"(result = x = R.copy(); x[2, 1] = simlev._r.fmt.NA_REAL; withdrawal_simulation(x))",
    r"(result = (x = copy(R); x[3, 2] = SL.NA; withdrawal_simulation(x)))", inp = ein("withdrawal/ws_err_na", c("R"))),
  zeile("ws_err_wpdim",
    r"(withdrawal_simulation(structure(list(returns = R, inflation = matrix(1, 3, 3), frequency = 'year'), class = 'withdrawal_paths')))",
    r"(result = withdrawal_simulation(W.WithdrawalPaths([('returns', R), ('inflation', np.ones((3, 3))), ('frequency', 'year')])))",
    r"(result = withdrawal_simulation(SL.RList("returns" => R, "inflation" => ones(3, 3), "frequency" => "year"; class = "withdrawal_paths")))", inp = ein("withdrawal/ws_err_wpdim", c("R"))),
  zeile("ws_result_err",
    r"(st <- create_strategy(ETF = asset_config('etf', 'bnh', spread = 0))
r1 <- simulation(dsim, st, start_value = 1000)
r2 <- simulation(dsim, st, start_value = 1000, dca = dca_plan(value = 500, span = 1))
withdrawal_simulation(r1, inflation = 'x'))",
    r"(st = simlev.create_strategy(ETF=simlev.asset_config(asset_class='etf', trading='bnh', spread=0))
r1 = simlev.simulation(dsim, st, start_value=1000)
r2 = simlev.simulation(dsim, st, start_value=1000, dca=simlev.dca_plan(value=500, span=1))
result = withdrawal_simulation(r1, inflation='x'))",
    r"(st = create_strategy(ETF = asset_config("etf", "bnh", spread = 0))
r1 = simulation(dsim, st; start_value = 1000)
r2 = simulation(dsim, st, start_value = 1000, dca = dca_plan(value = 500, span = 1))
result = withdrawal_simulation(r1; inflation = "x"))", inp = ein("withdrawal/ws_result_err", c("dsim"))),
  zeile("ws_sv_result_cb",
    r"(ws <- {rt <- simulation(dsim, create_strategy(ETF = asset_config('etf', 'bnh', spread = 0.2, partial_exemption = 30)), start_value = 1e5, tax = tax_profile(base_rate = 2))
withdrawal_simulation(R[, 1:3], withdrawal_rule('percent', rate = 5), start_value = rt, tax = tax_profile(), cost_basis = 55, partial_exemption = 15)}; ws$elapsed <- 0; ws)",
    r"(ws = None
rt = simlev.simulation(dsim, simlev.create_strategy(ETF=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.2, partial_exemption=30)), start_value=1e5, tax=simlev.tax_profile(base_rate=2))
ws = withdrawal_simulation(R[:, :3], rule=withdrawal_rule(type='percent', rate=5), start_value=rt, tax=simlev.tax_profile(), cost_basis=55, partial_exemption=15); ws['elapsed'] = 0; result = ws)",
    r"(ws = nothing
rt = simulation(dsim, create_strategy(ETF = asset_config("etf", "bnh", spread = 0.2, partial_exemption = 30)), start_value = 1e5, tax = tax_profile(base_rate = 2))
ws = withdrawal_simulation(R[:, 1:3], withdrawal_rule("percent"; rate = 5); start_value = rt, tax = SL.tax_profile(), cost_basis = 55, partial_exemption = 15); ws["elapsed"] = 0; result = ws)", print = TRUE, inp = ein("withdrawal/ws_sv_result_cb", c("R", "dsim"))),
  zeile("ws_tt_err_svmiss",
    r"(rt <- simulation(dsim, create_strategy(ETF = asset_config('etf', 'bnh', spread = 0.2, partial_exemption = 30)), start_value = 1e5, tax = tax_profile(base_rate = 2))
y1 <- rt$tax_report$next_year$year; withdrawal_simulation(R[, 1:3], start_value = rt, tax = tax_profile(income = income_tariff(setNames(c(1e4, 1e4), y1 + c(0, 2))))))",
    r"(rt = simlev.simulation(dsim, simlev.create_strategy(ETF=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.2, partial_exemption=30)), start_value=1e5, tax=simlev.tax_profile(base_rate=2))
y1 = rt['tax_report']['next_year']['year']
result = withdrawal_simulation(R[:, :3], start_value=rt, tax=simlev.tax_profile(income=simlev.income_tariff({str(y1): 1e4, str(y1 + 2): 1e4}))))",
    r"(rt = simulation(dsim, create_strategy(ETF = asset_config("etf", "bnh", spread = 0.2, partial_exemption = 30)), start_value = 1e5, tax = tax_profile(base_rate = 2))
y1 = Int(rt["tax_report"]["next_year"]["year"])
result = withdrawal_simulation(R[:, 1:3]; start_value = rt, tax = SL.tax_profile(; income = SL.income_tariff([string(y1) => 1e4, string(y1 + 2) => 1e4]))))", inp = ein("withdrawal/ws_tt_err_svmiss", c("R", "dsim"))),
  zeile("ws_sv_result_none",
    r"(ws <- {st <- create_strategy(ETF = asset_config('etf', 'bnh', spread = 0))
r1 <- simulation(dsim, st, start_value = 1000)
r2 <- simulation(dsim, st, start_value = 1000, dca = dca_plan(value = 500, span = 1))
withdrawal_simulation(R[, 1:3], withdrawal_rule('percent', rate = 5), start_value = r2, tax = tax_profile())}; ws$elapsed <- 0; ws)",
    r"(ws = None
st = simlev.create_strategy(ETF=simlev.asset_config(asset_class='etf', trading='bnh', spread=0))
r1 = simlev.simulation(dsim, st, start_value=1000)
r2 = simlev.simulation(dsim, st, start_value=1000, dca=simlev.dca_plan(value=500, span=1))
ws = withdrawal_simulation(R[:, :3], rule=withdrawal_rule(type='percent', rate=5), start_value=r2, tax=simlev.tax_profile()); ws['elapsed'] = 0; result = ws)",
    r"(ws = nothing
st = create_strategy(ETF = asset_config("etf", "bnh", spread = 0))
r1 = simulation(dsim, st; start_value = 1000)
r2 = simulation(dsim, st, start_value = 1000, dca = dca_plan(value = 500, span = 1))
ws = withdrawal_simulation(R[:, 1:3], withdrawal_rule("percent"; rate = 5); start_value = r2, tax = SL.tax_profile()); ws["elapsed"] = 0; result = ws)", print = TRUE, inp = ein("withdrawal/ws_sv_result_none", c("R", "dsim"))),
  zeile("wps_ws",
    r"(cfg <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices', aux_type = c(infl = 'rate', cpi = 'level'))
cfg0 <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices')
b <- bootstrap(db, cfg, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
b0 <- bootstrap(db, cfg0, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
st <- bootstrap_study(db, cfg, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE, keep_returns = 'year', keep_aux = c('infl', 'zins', 'cpi'), strategies = list(bnh = create_strategy(us = asset_config('etf', 'bnh', spread = 0.1)), half = create_strategy(us = asset_config('etf', 'bnh', share = 0.5, spread = 0.1))))
{ws <- withdrawal_simulation(st, withdrawal_rule('constant'), strategy = 'half', inflation = 'infl'); ws$elapsed <- 0; ws})",
    r"(cfg = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices', aux_type={'infl': 'rate', 'cpi': 'level'})
cfg0 = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices')
b = bootstrap(db, cfg, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
b0 = bootstrap(db, cfg0, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
st = bootstrap_study(db, cfg, 'stationary', n=3, params={'L': 60}, seed=4, progress=False, keep_returns='year', keep_aux=['infl', 'zins', 'cpi'], strategies={'bnh': simlev.create_strategy(us=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1)), 'half': simlev.create_strategy(us=simlev.asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1))})
result = withdrawal_simulation(st, rule=withdrawal_rule(type='constant'), strategy='half', inflation='infl'); result['elapsed'] = 0)",
    r"(cfg = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices", aux_type = (infl = "rate", cpi = "level"))
cfg0 = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices")
b = bootstrap(db, cfg, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
b0 = bootstrap(db, cfg0, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
st = bootstrap_study(db, cfg, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false, keep_returns = "year", keep_aux = ["infl", "zins", "cpi"], strategies = (bnh = create_strategy(us = asset_config("etf", "bnh", spread = 0.1)), half = create_strategy(us = asset_config("etf", "bnh", share = 0.5, spread = 0.1))))
result = (ws = withdrawal_simulation(st, withdrawal_rule("constant"); strategy = "half", inflation = "infl"); ws["elapsed"] = 0; ws))", inp = ein("withdrawal/wps_ws", c("db"))),
  zeile("fifo_spreads",
    r"(ws <- {st <- create_strategy(A = asset_config('etf', 'bnh', share = 0.5, spread = 0.2, partial_exemption = 15), N = asset_config('etf', 'bnh', share = 0.5, spread = 0.2, partial_exemption = 15))
r <- suppressWarnings(simulation(dfi, st, start_value = 1e5, rebalance = rebalance_plan(event_col = 'ev', event_mode = 'replace', skip = TRUE, event_weight = c(A = 'wA', N = 'wN')), tax = tax_profile(base_rate = 1)))
r$open_lots$N$spread <- 0.5; withdrawal_simulation(matrix(1.02, 3, 1), start_value = r, tax = tax_profile())}; ws$elapsed <- 0; ws)",
    r"(ws = None
import warnings as _w
st = simlev.create_strategy(A=simlev.asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.2, partial_exemption=15), N=simlev.asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.2, partial_exemption=15))
with _w.catch_warnings():
    _w.simplefilter('ignore')
    r = simlev.simulation(dfi, st, start_value=1e5, rebalance=simlev.rebalance_plan(event_col='ev', event_mode='replace', skip=True, event_weight={'A': 'wA', 'N': 'wN'}), tax=simlev.tax_profile(base_rate=1))
r['open_lots']['N']['spread'] = 0.5; ws = withdrawal_simulation(np.full((3, 1), 1.02), start_value=r, tax=simlev.tax_profile()); ws['elapsed'] = 0; result = ws)",
    r"(ws = nothing
st = create_strategy(A = asset_config("etf", "bnh", share = 0.5, spread = 0.2, partial_exemption = 15), N = asset_config("etf", "bnh", share = 0.5, spread = 0.2, partial_exemption = 15))
r = B._quiet(() -> simulation(dfi, st; start_value = 1e5, rebalance = rebalance_plan(; event_col = "ev", event_mode = "replace", skip = true, event_weight = (A = "wA", N = "wN")), tax = tax_profile(; base_rate = 1)))
r["open_lots"]["N"]["spread"] = 0.5; ws = withdrawal_simulation(fill(1.02, 3, 1); start_value = r, tax = SL.tax_profile()); ws["elapsed"] = 0; result = ws)", print = TRUE, inp = ein("withdrawal/fifo_spreads", c("dfi"))),
  zeile("fifo_fee",
    r"(ws <- {st <- create_strategy(A = asset_config('etf', 'bnh', share = 0.5, spread = 0.2, partial_exemption = 15), N = asset_config('etf', 'bnh', share = 0.5, spread = 0.2, partial_exemption = 15))
r <- suppressWarnings(simulation(dfi, st, start_value = 1e5, rebalance = rebalance_plan(event_col = 'ev', event_mode = 'replace', skip = TRUE, event_weight = c(A = 'wA', N = 'wN')), tax = tax_profile(base_rate = 1), costs = sim_costs(order_fee = 1)))
withdrawal_simulation(matrix(1.02, 3, 1), start_value = r, tax = tax_profile())}; ws$elapsed <- 0; ws)",
    r"(ws = None
import warnings as _w
st = simlev.create_strategy(A=simlev.asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.2, partial_exemption=15), N=simlev.asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.2, partial_exemption=15))
with _w.catch_warnings():
    _w.simplefilter('ignore')
    r = simlev.simulation(dfi, st, start_value=1e5, rebalance=simlev.rebalance_plan(event_col='ev', event_mode='replace', skip=True, event_weight={'A': 'wA', 'N': 'wN'}), tax=simlev.tax_profile(base_rate=1), costs=simlev.sim_costs(order_fee=1))
ws = withdrawal_simulation(np.full((3, 1), 1.02), start_value=r, tax=simlev.tax_profile()); ws['elapsed'] = 0; result = ws)",
    r"(ws = nothing
st = create_strategy(A = asset_config("etf", "bnh", share = 0.5, spread = 0.2, partial_exemption = 15), N = asset_config("etf", "bnh", share = 0.5, spread = 0.2, partial_exemption = 15))
r = B._quiet(() -> simulation(dfi, st; start_value = 1e5, rebalance = rebalance_plan(; event_col = "ev", event_mode = "replace", skip = true, event_weight = (A = "wA", N = "wN")), tax = tax_profile(; base_rate = 1), costs = sim_costs(; order_fee = 1)))
ws = withdrawal_simulation(fill(1.02, 3, 1); start_value = r, tax = SL.tax_profile()); ws["elapsed"] = 0; result = ws)", print = TRUE, inp = ein("withdrawal/fifo_fee", c("dfi"))),
  zeile("fifo_private",
    r"(ws <- {st <- create_strategy(A = asset_config('etf', 'bnh', share = 0.5, spread = 0.2, partial_exemption = 15), N = asset_config('etc', 'bnh', share = 0.5, spread = 0.2, deliverable = TRUE))
r <- suppressWarnings(simulation(dfi, st, start_value = 1e5, rebalance = rebalance_plan(event_col = 'ev', event_mode = 'replace', skip = TRUE, event_weight = c(A = 'wA', N = 'wN')), tax = tax_profile(base_rate = 1, income = income_rate(42))))
withdrawal_simulation(matrix(1.02, 3, 1), start_value = r, tax = tax_profile())}; ws$elapsed <- 0; ws)",
    r"(ws = None
import warnings as _w
st = simlev.create_strategy(A=simlev.asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.2, partial_exemption=15), N=simlev.asset_config(asset_class='etc', trading='bnh', share=0.5, spread=0.2, deliverable=True))
with _w.catch_warnings():
    _w.simplefilter('ignore')
    r = simlev.simulation(dfi, st, start_value=1e5, rebalance=simlev.rebalance_plan(event_col='ev', event_mode='replace', skip=True, event_weight={'A': 'wA', 'N': 'wN'}), tax=simlev.tax_profile(base_rate=1, income=simlev.income_rate(42)))
ws = withdrawal_simulation(np.full((3, 1), 1.02), start_value=r, tax=simlev.tax_profile()); ws['elapsed'] = 0; result = ws)",
    r"(ws = nothing
st = create_strategy(A = asset_config("etf", "bnh", share = 0.5, spread = 0.2, partial_exemption = 15), N = asset_config("etc", "bnh", share = 0.5, spread = 0.2, deliverable = true))
r = B._quiet(() -> simulation(dfi, st; start_value = 1e5, rebalance = rebalance_plan(; event_col = "ev", event_mode = "replace", skip = true, event_weight = (A = "wA", N = "wN")), tax = tax_profile(; base_rate = 1, income = income_rate(42))))
ws = withdrawal_simulation(fill(1.02, 3, 1); start_value = r, tax = SL.tax_profile()); ws["elapsed"] = 0; result = ws)", print = TRUE, inp = ein("withdrawal/fifo_private", c("dfi")))))
TB("withdrawal_max_rate", "Meldungen und Warnungen von withdrawal_max_rate je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("mr_warn_once",
    r"(r <- withdrawal_max_rate(R[, 1:4], success = 0.5, tol = 0.5, inflation = 0.02); as.numeric(r))",
    r"(r = withdrawal_max_rate(R[:, :4], success=0.5, tol=0.5, inflation=0.02); result = float(r))",
    r"(r = withdrawal_max_rate(R[:, 1:4]; success = 0.5, tol = 0.5, inflation = 0.02); result = r[1])", inp = ein("withdrawal/mr_warn_once", c("R"))),
  zeile("mr_err_succ95",
    r"(withdrawal_max_rate(R, success = 95))",
    r"(result = withdrawal_max_rate(R, success=95))",
    r"(result = withdrawal_max_rate(R; success = 95))", inp = ein("withdrawal/mr_err_succ95", c("R"))),
  zeile("mr_err_up",
    r"(withdrawal_max_rate(R, upper = 150))",
    r"(result = withdrawal_max_rate(R, upper=150))",
    r"(result = withdrawal_max_rate(R; upper = 150))", inp = ein("withdrawal/mr_err_up", c("R"))),
  zeile("mr_err_tol",
    r"(withdrawal_max_rate(R, tol = 0))",
    r"(result = withdrawal_max_rate(R, tol=0))",
    r"(result = withdrawal_max_rate(R; tol = 0))", inp = ein("withdrawal/mr_err_tol", c("R"))),
  zeile("mr_err_rule",
    r"(withdrawal_max_rate(R, withdrawal_rule('vpw')))",
    r"(result = withdrawal_max_rate(R, rule=withdrawal_rule(type='vpw')))",
    r"(result = withdrawal_max_rate(R, withdrawal_rule("vpw")))", inp = ein("withdrawal/mr_err_rule", c("R"))),
  zeile("mr_err_rule2",
    r"(withdrawal_max_rate(R, 1))",
    r"(result = withdrawal_max_rate(R, rule=1))",
    r"(result = withdrawal_max_rate(R, 1))", inp = ein("withdrawal/mr_err_rule2", c("R")))))
TB("withdrawal_horizon", "Meldungen und Warnungen von withdrawal_horizon je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("hz_err_years_max",   # seit 1.6.4 Fehler (Entscheidung 46: höchstens 100 Jahre; bis 1.6.3 Teil hz_draw_walker von horizonte mit 1:250)
    r"(SimLev:::.draw_horizon(withdrawal_horizon('discrete', years = 1:250, prob = (1:250)^2), 50))",
    r"(result = W._draw_horizon(withdrawal_horizon(type='discrete', years=np.arange(1, 251), prob=np.arange(1, 251) ** 2.0), 50))",
    r"(result = W._draw_horizon(withdrawal_horizon("discrete"; years = 1:250, prob = Float64.(1:250) .* (1:250)), 50))", inp = ein("withdrawal/hz_draw_walker", c())),
  zeile("hz_err_min_frac",   # seit 1.6.4 Fehler (Entscheidungen 19, 47; bis 1.6.3 Teil hz_small von horizonte mit min = 0.2)
    r"(withdrawal_horizon('normal', mean = 1, sd = 3, min = 0.2, max = 3))",
    r"(result = withdrawal_horizon(type='normal', mean=1, sd=3, min=0.2, max=3))",
    r"(result = withdrawal_horizon("normal"; mean = 1, sd = 3, min = 0.2, max = 3))", inp = ein("withdrawal/hz_small", c())),
  zeile("hz_err_sample_frac",   # seit 1.6.4 Fehler (Entscheidungen 19, 47; bis 1.6.3 Teil hz_sample von horizonte)
    r"(withdrawal_horizon('sample', years = c(3.7, 12, 30)))",
    r"(result = withdrawal_horizon(type='sample', years=[3.7, 12, 30]))",
    r"(result = withdrawal_horizon("sample"; years = [3.7, 12, 30]))", inp = ein("withdrawal/hz_sample", c())),
  zeile("hz_err_miss",
    r"(withdrawal_horizon('uniform', min = 3))",
    r"(result = withdrawal_horizon(type='uniform', min=3))",
    r"(result = withdrawal_horizon("uniform"; min = 3))", inp = ein("withdrawal/hz_err_miss", c())),
  zeile("hz_err_y0",
    r"(withdrawal_horizon('fixed', years = 0))",
    r"(result = withdrawal_horizon(type='fixed', years=0))",
    r"(result = withdrawal_horizon("fixed"; years = 0))", inp = ein("withdrawal/hz_err_y0", c())),
  zeile("hz_err_disc_len",
    r"(withdrawal_horizon('discrete', years = c(20, 30), prob = 1))",
    r"(result = withdrawal_horizon(type='discrete', years=[20, 30], prob=1))",
    r"(result = withdrawal_horizon("discrete"; years = [20, 30], prob = 1))", inp = ein("withdrawal/hz_err_disc_len", c())),
  zeile("hz_err_minmax",
    r"(withdrawal_horizon('uniform', min = 30, max = 20))",
    r"(result = withdrawal_horizon(type='uniform', min=30, max=20))",
    r"(result = withdrawal_horizon("uniform"; min = 30, max = 20))", inp = ein("withdrawal/hz_err_minmax", c())),
  zeile("hz_err_mode",
    r"(withdrawal_horizon('triangular', min = 20, mode = 50, max = 30))",
    r"(result = withdrawal_horizon(type='triangular', min=20, mode=50, max=30))",
    r"(result = withdrawal_horizon("triangular"; min = 20, mode = 50, max = 30))", inp = ein("withdrawal/hz_err_mode", c())),
  zeile("hz_err_sd",
    r"(withdrawal_horizon('normal', mean = 20, sd = -1, min = 1, max = 30))",
    r"(result = withdrawal_horizon(type='normal', mean=20, sd=-1, min=1, max=30))",
    r"(result = withdrawal_horizon("normal"; mean = 20, sd = -1, min = 1, max = 30))", inp = ein("withdrawal/hz_err_sd", c())),
  zeile("hz_err_chr",
    r"(withdrawal_horizon('fixed', years = 'x'))",
    r"(result = withdrawal_horizon(type='fixed', years='x'))",
    r"(result = withdrawal_horizon("fixed"; years = "x"))", inp = ein("withdrawal/hz_err_chr", c()))))
TB("result_index", "Meldungen und Warnungen von result_index je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("ri_err",
    r"(result_index(list()))",
    r"(result = result_index([]))",
    r"(result = result_index((;)))", inp = ein("withdrawal/ri_err", c()))))
TB("withdrawal_paths", "Meldungen und Warnungen von withdrawal_paths je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("wp_list_err",
    r"(st <- create_strategy(ETF = asset_config('etf', 'bnh', spread = 0))
r1 <- simulation(dsim, st, start_value = 1000)
r2 <- simulation(dsim, st, start_value = 1000, dca = dca_plan(value = 500, span = 1))
withdrawal_paths(list(r1, r2), inflation = 'cpi'))",
    r"(st = simlev.create_strategy(ETF=simlev.asset_config(asset_class='etf', trading='bnh', spread=0))
r1 = simlev.simulation(dsim, st, start_value=1000)
r2 = simlev.simulation(dsim, st, start_value=1000, dca=simlev.dca_plan(value=500, span=1))
result = withdrawal_paths([r1, r2], inflation='cpi'))",
    r"(st = create_strategy(ETF = asset_config("etf", "bnh", spread = 0))
r1 = simulation(dsim, st; start_value = 1000)
r2 = simulation(dsim, st, start_value = 1000, dca = dca_plan(value = 500, span = 1))
result = withdrawal_paths([r1, r2]; inflation = "cpi"))", inp = ein("withdrawal/wp_list_err", c("dsim"))),
  zeile("wp_e_col",
    r"(cfg <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices', aux_type = c(infl = 'rate', cpi = 'level'))
cfg0 <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices')
b <- bootstrap(db, cfg, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
b0 <- bootstrap(db, cfg0, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
withdrawal_paths(b))",
    r"(cfg = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices', aux_type={'infl': 'rate', 'cpi': 'level'})
cfg0 = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices')
b = bootstrap(db, cfg, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
b0 = bootstrap(db, cfg0, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
result = withdrawal_paths(b))",
    r"(cfg = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices", aux_type = (infl = "rate", cpi = "level"))
cfg0 = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices")
b = bootstrap(db, cfg, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
b0 = bootstrap(db, cfg0, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
result = withdrawal_paths(b))", inp = ein("withdrawal/wp_e_col", c("db"))),
  zeile("wp_e_colname",
    r"(cfg <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices', aux_type = c(infl = 'rate', cpi = 'level'))
cfg0 <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices')
b <- bootstrap(db, cfg, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
b0 <- bootstrap(db, cfg0, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
withdrawal_paths(b, column = 'x'))",
    r"(cfg = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices', aux_type={'infl': 'rate', 'cpi': 'level'})
cfg0 = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices')
b = bootstrap(db, cfg, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
b0 = bootstrap(db, cfg0, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
result = withdrawal_paths(b, column='x'))",
    r"(cfg = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices", aux_type = (infl = "rate", cpi = "level"))
cfg0 = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices")
b = bootstrap(db, cfg, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
b0 = bootstrap(db, cfg0, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
result = withdrawal_paths(b; column = "x"))", inp = ein("withdrawal/wp_e_colname", c("db"))),
  zeile("wp_e_dates",
    r"(cfg <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices', aux_type = c(infl = 'rate', cpi = 'level'))
cfg0 <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices')
b <- bootstrap(db, cfg, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
b0 <- bootstrap(db, cfg0, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
withdrawal_paths(b, column = 'us', dates = as.Date('2001-01-01') + 0:5))",
    r"(cfg = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices', aux_type={'infl': 'rate', 'cpi': 'level'})
cfg0 = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices')
b = bootstrap(db, cfg, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
b0 = bootstrap(db, cfg0, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
result = withdrawal_paths(b, column='us', dates=np.datetime64('2001-01-01') + np.arange(6)))",
    r"(cfg = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices", aux_type = (infl = "rate", cpi = "level"))
cfg0 = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices")
b = bootstrap(db, cfg, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
b0 = bootstrap(db, cfg0, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
result = withdrawal_paths(b; column = "us", dates = Date(2001, 1, 1) .+ Day.(0:5)))", inp = ein("withdrawal/wp_e_dates", c("db"))),
  zeile("wp_e_dup",
    r"(cfg <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices', aux_type = c(infl = 'rate', cpi = 'level'))
cfg0 <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices')
b <- bootstrap(db, cfg, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
b0 <- bootstrap(db, cfg0, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
withdrawal_paths(b, column = 'us', dates = as.Date('2001-01-01') + (0:1100) %/% 3))",
    r"(cfg = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices', aux_type={'infl': 'rate', 'cpi': 'level'})
cfg0 = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices')
b = bootstrap(db, cfg, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
b0 = bootstrap(db, cfg0, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
result = withdrawal_paths(b, column='us', dates=np.datetime64('2001-01-01') + np.arange(1101) // 3))",
    r"(cfg = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices", aux_type = (infl = "rate", cpi = "level"))
cfg0 = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices")
b = bootstrap(db, cfg, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
b0 = bootstrap(db, cfg0, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
result = withdrawal_paths(b; column = "us", dates = Date(2001, 1, 1) .+ Day.((0:1100) .÷ 3)))", inp = ein("withdrawal/wp_e_dup", c("db"))),
  zeile("wp_e_infl_col",
    r"(cfg <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices', aux_type = c(infl = 'rate', cpi = 'level'))
cfg0 <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices')
b <- bootstrap(db, cfg, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
b0 <- bootstrap(db, cfg0, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
withdrawal_paths(b, column = 'us', inflation = 'cp'))",
    r"(cfg = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices', aux_type={'infl': 'rate', 'cpi': 'level'})
cfg0 = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices')
b = bootstrap(db, cfg, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
b0 = bootstrap(db, cfg0, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
result = withdrawal_paths(b, column='us', inflation='cp'))",
    r"(cfg = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices", aux_type = (infl = "rate", cpi = "level"))
cfg0 = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices")
b = bootstrap(db, cfg, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
b0 = bootstrap(db, cfg0, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
result = withdrawal_paths(b; column = "us", inflation = "cp"))", inp = ein("withdrawal/wp_e_infl_col", c("db"))),
  zeile("wp_e_mismatch",
    r"(cfg <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices', aux_type = c(infl = 'rate', cpi = 'level'))
cfg0 <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices')
b <- bootstrap(db, cfg, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
b0 <- bootstrap(db, cfg0, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
withdrawal_paths(b, column = 'us', inflation = 'infl', inflation_type = 'level'))",
    r"(cfg = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices', aux_type={'infl': 'rate', 'cpi': 'level'})
cfg0 = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices')
b = bootstrap(db, cfg, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
b0 = bootstrap(db, cfg0, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
result = withdrawal_paths(b, column='us', inflation='infl', inflation_type='level'))",
    r"(cfg = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices", aux_type = (infl = "rate", cpi = "level"))
cfg0 = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices")
b = bootstrap(db, cfg, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
b0 = bootstrap(db, cfg0, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
result = withdrawal_paths(b; column = "us", inflation = "infl", inflation_type = "level"))", inp = ein("withdrawal/wp_e_mismatch", c("db"))),
  zeile("wp_e_infl_vec",
    r"(cfg <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices', aux_type = c(infl = 'rate', cpi = 'level'))
cfg0 <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices')
b <- bootstrap(db, cfg, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
b0 <- bootstrap(db, cfg0, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
withdrawal_paths(b, column = 'us', inflation = c(1, 2)))",
    r"(cfg = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices', aux_type={'infl': 'rate', 'cpi': 'level'})
cfg0 = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices')
b = bootstrap(db, cfg, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
b0 = bootstrap(db, cfg0, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
result = withdrawal_paths(b, column='us', inflation=[1, 2]))",
    r"(cfg = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices", aux_type = (infl = "rate", cpi = "level"))
cfg0 = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices")
b = bootstrap(db, cfg, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
b0 = bootstrap(db, cfg0, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
result = withdrawal_paths(b; column = "us", inflation = [1, 2]))", inp = ein("withdrawal/wp_e_infl_vec", c("db"))),
  zeile("wp_e_noattr",
    r"(cfg <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices', aux_type = c(infl = 'rate', cpi = 'level'))
cfg0 <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices')
b <- bootstrap(db, cfg, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
b0 <- bootstrap(db, cfg0, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
b0$paths <- lapply(b0$paths, function(p) { attr(p, 'aux_level') <- NULL; p }); withdrawal_paths(b0, column = 'us', inflation = 'zins'))",
    r"(cfg = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices', aux_type={'infl': 'rate', 'cpi': 'level'})
cfg0 = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices')
b = bootstrap(db, cfg, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
b0 = bootstrap(db, cfg0, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
[p.attrs.pop('aux_level') for p in b0['paths']]; result = withdrawal_paths(b0, column='us', inflation='zins'))",
    r"(cfg = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices", aux_type = (infl = "rate", cpi = "level"))
cfg0 = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices")
b = bootstrap(db, cfg, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
b0 = bootstrap(db, cfg0, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
for p in b0["paths"]; delete!(p.attrs, "aux_level"); end; result = withdrawal_paths(b0; column = "us", inflation = "zins"))", inp = ein("withdrawal/wp_e_noattr", c("db"))),
  zeile("wp_e_class",
    r"(cfg <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices', aux_type = c(infl = 'rate', cpi = 'level'))
cfg0 <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices')
b <- bootstrap(db, cfg, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
b0 <- bootstrap(db, cfg0, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
withdrawal_paths(list(1, 2)))",
    r"(cfg = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices', aux_type={'infl': 'rate', 'cpi': 'level'})
cfg0 = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices')
b = bootstrap(db, cfg, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
b0 = bootstrap(db, cfg0, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
result = withdrawal_paths([1, 2]))",
    r"(cfg = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices", aux_type = (infl = "rate", cpi = "level"))
cfg0 = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices")
b = bootstrap(db, cfg, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
b0 = bootstrap(db, cfg0, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
result = withdrawal_paths([1, 2]))", inp = ein("withdrawal/wp_e_class", c("db"))),
  zeile("wps_strat",
    r"(cfg <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices', aux_type = c(infl = 'rate', cpi = 'level'))
cfg0 <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices')
b <- bootstrap(db, cfg, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
b0 <- bootstrap(db, cfg0, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
st <- bootstrap_study(db, cfg, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE, keep_returns = 'year', keep_aux = c('infl', 'zins', 'cpi'), strategies = list(bnh = create_strategy(us = asset_config('etf', 'bnh', spread = 0.1)), half = create_strategy(us = asset_config('etf', 'bnh', share = 0.5, spread = 0.1))))
withdrawal_paths(st, strategy = 'half', inflation = 2))",
    r"(cfg = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices', aux_type={'infl': 'rate', 'cpi': 'level'})
cfg0 = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices')
b = bootstrap(db, cfg, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
b0 = bootstrap(db, cfg0, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
st = bootstrap_study(db, cfg, 'stationary', n=3, params={'L': 60}, seed=4, progress=False, keep_returns='year', keep_aux=['infl', 'zins', 'cpi'], strategies={'bnh': simlev.create_strategy(us=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1)), 'half': simlev.create_strategy(us=simlev.asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1))})
result = withdrawal_paths(st, strategy='half', inflation=2))",
    r"(cfg = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices", aux_type = (infl = "rate", cpi = "level"))
cfg0 = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices")
b = bootstrap(db, cfg, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
b0 = bootstrap(db, cfg0, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
st = bootstrap_study(db, cfg, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false, keep_returns = "year", keep_aux = ["infl", "zins", "cpi"], strategies = (bnh = create_strategy(us = asset_config("etf", "bnh", spread = 0.1)), half = create_strategy(us = asset_config("etf", "bnh", share = 0.5, spread = 0.1))))
result = withdrawal_paths(st; strategy = "half", inflation = 2))", inp = ein("withdrawal/wps_strat", c("db"))),
  zeile("wps_e_rate_pa",
    r"(cfg <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices', aux_type = c(infl = 'rate', cpi = 'level'))
cfg0 <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices')
b <- bootstrap(db, cfg, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
b0 <- bootstrap(db, cfg0, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
st <- bootstrap_study(db, cfg, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE, keep_returns = 'year', keep_aux = c('infl', 'zins', 'cpi'), strategies = list(bnh = create_strategy(us = asset_config('etf', 'bnh', spread = 0.1)), half = create_strategy(us = asset_config('etf', 'bnh', share = 0.5, spread = 0.1))))
withdrawal_paths(st, inflation = 'zins', inflation_type = 'rate_pa'))",
    r"(cfg = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices', aux_type={'infl': 'rate', 'cpi': 'level'})
cfg0 = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices')
b = bootstrap(db, cfg, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
b0 = bootstrap(db, cfg0, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
st = bootstrap_study(db, cfg, 'stationary', n=3, params={'L': 60}, seed=4, progress=False, keep_returns='year', keep_aux=['infl', 'zins', 'cpi'], strategies={'bnh': simlev.create_strategy(us=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1)), 'half': simlev.create_strategy(us=simlev.asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1))})
result = withdrawal_paths(st, inflation='zins', inflation_type='rate_pa'))",
    r"(cfg = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices", aux_type = (infl = "rate", cpi = "level"))
cfg0 = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices")
b = bootstrap(db, cfg, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
b0 = bootstrap(db, cfg0, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
st = bootstrap_study(db, cfg, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false, keep_returns = "year", keep_aux = ["infl", "zins", "cpi"], strategies = (bnh = create_strategy(us = asset_config("etf", "bnh", spread = 0.1)), half = create_strategy(us = asset_config("etf", "bnh", share = 0.5, spread = 0.1))))
result = withdrawal_paths(st; inflation = "zins", inflation_type = "rate_pa"))", inp = ein("withdrawal/wps_e_rate_pa", c("db"))),
  zeile("wps_e_strat",
    r"(cfg <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices', aux_type = c(infl = 'rate', cpi = 'level'))
cfg0 <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices')
b <- bootstrap(db, cfg, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
b0 <- bootstrap(db, cfg0, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
st <- bootstrap_study(db, cfg, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE, keep_returns = 'year', keep_aux = c('infl', 'zins', 'cpi'), strategies = list(bnh = create_strategy(us = asset_config('etf', 'bnh', spread = 0.1)), half = create_strategy(us = asset_config('etf', 'bnh', share = 0.5, spread = 0.1))))
withdrawal_paths(st, strategy = 'x'))",
    r"(cfg = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices', aux_type={'infl': 'rate', 'cpi': 'level'})
cfg0 = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices')
b = bootstrap(db, cfg, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
b0 = bootstrap(db, cfg0, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
st = bootstrap_study(db, cfg, 'stationary', n=3, params={'L': 60}, seed=4, progress=False, keep_returns='year', keep_aux=['infl', 'zins', 'cpi'], strategies={'bnh': simlev.create_strategy(us=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1)), 'half': simlev.create_strategy(us=simlev.asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1))})
result = withdrawal_paths(st, strategy='x'))",
    r"(cfg = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices", aux_type = (infl = "rate", cpi = "level"))
cfg0 = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices")
b = bootstrap(db, cfg, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
b0 = bootstrap(db, cfg0, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
st = bootstrap_study(db, cfg, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false, keep_returns = "year", keep_aux = ["infl", "zins", "cpi"], strategies = (bnh = create_strategy(us = asset_config("etf", "bnh", spread = 0.1)), half = create_strategy(us = asset_config("etf", "bnh", share = 0.5, spread = 0.1))))
result = withdrawal_paths(st; strategy = "x"))", inp = ein("withdrawal/wps_e_strat", c("db"))),
  zeile("wps_e_aux",
    r"(cfg <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices', aux_type = c(infl = 'rate', cpi = 'level'))
cfg0 <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices')
b <- bootstrap(db, cfg, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
b0 <- bootstrap(db, cfg0, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
st <- bootstrap_study(db, cfg, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE, keep_returns = 'year', keep_aux = c('infl', 'zins', 'cpi'), strategies = list(bnh = create_strategy(us = asset_config('etf', 'bnh', spread = 0.1)), half = create_strategy(us = asset_config('etf', 'bnh', share = 0.5, spread = 0.1))))
withdrawal_paths(st, inflation = 'foo'))",
    r"(cfg = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices', aux_type={'infl': 'rate', 'cpi': 'level'})
cfg0 = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices')
b = bootstrap(db, cfg, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
b0 = bootstrap(db, cfg0, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
st = bootstrap_study(db, cfg, 'stationary', n=3, params={'L': 60}, seed=4, progress=False, keep_returns='year', keep_aux=['infl', 'zins', 'cpi'], strategies={'bnh': simlev.create_strategy(us=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1)), 'half': simlev.create_strategy(us=simlev.asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1))})
result = withdrawal_paths(st, inflation='foo'))",
    r"(cfg = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices", aux_type = (infl = "rate", cpi = "level"))
cfg0 = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices")
b = bootstrap(db, cfg, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
b0 = bootstrap(db, cfg0, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
st = bootstrap_study(db, cfg, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false, keep_returns = "year", keep_aux = ["infl", "zins", "cpi"], strategies = (bnh = create_strategy(us = asset_config("etf", "bnh", spread = 0.1)), half = create_strategy(us = asset_config("etf", "bnh", share = 0.5, spread = 0.1))))
result = withdrawal_paths(st; inflation = "foo"))", inp = ein("withdrawal/wps_e_aux", c("db")))))
TB("simulation", "Meldungen und Warnungen von simulation je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("wp_list_len",
    r"(st <- create_strategy(ETF = asset_config('etf', 'bnh', spread = 0))
r1 <- simulation(dsim, st, start_value = 1000)
r2 <- simulation(dsim, st, start_value = 1000, dca = dca_plan(value = 500, span = 1))
r3 <- simulation(dsim[1:800, ], st); withdrawal_paths(list(r1, r3)))",
    r"(st = simlev.create_strategy(ETF=simlev.asset_config(asset_class='etf', trading='bnh', spread=0))
r1 = simlev.simulation(dsim, st, start_value=1000)
r2 = simlev.simulation(dsim, st, start_value=1000, dca=simlev.dca_plan(value=500, span=1))
r3 = simlev.simulation(dsim.iloc[:800], st); result = withdrawal_paths([r1, r3]))",
    r"(st = create_strategy(ETF = asset_config("etf", "bnh", spread = 0))
r1 = simulation(dsim, st; start_value = 1000)
r2 = simulation(dsim, st, start_value = 1000, dca = dca_plan(value = 500, span = 1))
r3 = simulation(SL.rows(dsim, 1:800), st); result = withdrawal_paths([r1, r3]))", inp = ein("withdrawal/wp_list_len", c("dsim"))),
  zeile("wp_list_short",
    r"(st <- create_strategy(ETF = asset_config('etf', 'bnh', spread = 0))
r1 <- simulation(dsim, st, start_value = 1000)
r2 <- simulation(dsim, st, start_value = 1000, dca = dca_plan(value = 500, span = 1))
r3 <- simulation(dsim[1:300, ], st); withdrawal_paths(list(r3)))",
    r"(st = simlev.create_strategy(ETF=simlev.asset_config(asset_class='etf', trading='bnh', spread=0))
r1 = simlev.simulation(dsim, st, start_value=1000)
r2 = simlev.simulation(dsim, st, start_value=1000, dca=simlev.dca_plan(value=500, span=1))
r3 = simlev.simulation(dsim.iloc[:300], st); result = withdrawal_paths([r3]))",
    r"(st = create_strategy(ETF = asset_config("etf", "bnh", spread = 0))
r1 = simulation(dsim, st; start_value = 1000)
r2 = simulation(dsim, st, start_value = 1000, dca = dca_plan(value = 500, span = 1))
r3 = simulation(SL.rows(dsim, 1:300), st); result = withdrawal_paths([r3]))", inp = ein("withdrawal/wp_list_short", c("dsim"))),
  zeile("sv_negative",
    r"(r <- simulation(dfi, create_strategy(C = asset_config('etf', 'bnh', spread = 0.1)), start_value = 1e4); r$worth[length(r$worth)] <- -800; r$tax_report$open_tax_debt <- 800; withdrawal_simulation(matrix(1.03, 5, 1), start_value = r, tax = tax_profile()))",
    r"(r = simlev.simulation(dfi, simlev.create_strategy(C=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1)), start_value=1e4); w = np.array(r['worth'], dtype=float); w[-1] = -800; r['worth'] = w; r['tax_report']['open_tax_debt'] = 800.0; result = withdrawal_simulation(np.full((5, 1), 1.03), start_value=r, tax=simlev.tax_profile()))",
    r"(r = simulation(dfi, create_strategy(C = asset_config("etf", "bnh", spread = 0.1)); start_value = 1e4); r["worth"][end] = -800; r["tax_report"]["open_tax_debt"] = 800.0; result = withdrawal_simulation(fill(1.03, 5, 1); start_value = r, tax = SL.tax_profile()))", inp = ein("withdrawal/sv_negative", c("dfi"))),
  zeile("ws_src_taxed",
    r"(ws <- {r <- simulation(dfi, create_strategy(C = asset_config('etf', 'bnh', partial_exemption = 30, spread = 0.1)), start_value = 1e5, tax = tax_profile(base_rate = 3)); withdrawal_simulation(list(r, r), withdrawal_rule('percent'), tax = tax_profile(), inflation = 1)}; ws$elapsed <- 0; ws)",
    r"(ws = None
r = simlev.simulation(dfi, simlev.create_strategy(C=simlev.asset_config(asset_class='etf', trading='bnh', partial_exemption=30, spread=0.1)), start_value=1e5, tax=simlev.tax_profile(base_rate=3)); ws = withdrawal_simulation([r, r], rule=withdrawal_rule(type='percent'), tax=simlev.tax_profile(), inflation=1); ws['elapsed'] = 0; result = ws)",
    r"(ws = nothing
r = simulation(dfi, create_strategy(C = asset_config("etf", "bnh", partial_exemption = 30, spread = 0.1)), start_value = 1e5, tax = tax_profile(base_rate = 3)); ws = withdrawal_simulation([r, r], withdrawal_rule("percent"); tax = SL.tax_profile(), inflation = 1); ws["elapsed"] = 0; result = ws)", print = TRUE, inp = ein("withdrawal/ws_src_taxed", c("dfi")))))
TB("bootstrap", "Meldungen und Warnungen von bootstrap je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("wp_e_short",
    r"(cfg <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices', aux_type = c(infl = 'rate', cpi = 'level'))
cfg0 <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices')
b <- bootstrap(db, cfg, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
b0 <- bootstrap(db, cfg0, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
b3 <- bootstrap(db, cfg, 'raw', n = 1, seed = 1, progress = FALSE, path_length = 200); withdrawal_paths(b3, column = 'us'))",
    r"(cfg = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices', aux_type={'infl': 'rate', 'cpi': 'level'})
cfg0 = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices')
b = bootstrap(db, cfg, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
b0 = bootstrap(db, cfg0, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
b3 = bootstrap(db, cfg, method='raw', n=1, seed=1, progress=False, path_length=200); result = withdrawal_paths(b3, column='us'))",
    r"(cfg = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices", aux_type = (infl = "rate", cpi = "level"))
cfg0 = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices")
b = bootstrap(db, cfg, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
b0 = bootstrap(db, cfg0, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
b3 = bootstrap(db, cfg, "raw"; n = 1, seed = 1, progress = false, path_length = 200); result = withdrawal_paths(b3; column = "us"))", inp = ein("withdrawal/wp_e_short", c("db"))),
  zeile("wp_rate_neg",
    r"(d2 <- db; d2$infl <- -150; b2 <- bootstrap(d2, bootstrap_config(c(us = 'us'), aux = c(infl = 'infl'), input = 'prices', aux_type = c(infl = 'rate')), 'raw', n = 1, seed = 1, progress = FALSE); withdrawal_paths(b2, column = 'us', inflation = 'infl'))",
    r"(d2 = db.copy(); d2['infl'] = -150.0; b2 = bootstrap(d2, bootstrap_config({'us': 'us'}, aux={'infl': 'infl'}, input='prices', aux_type={'infl': 'rate'}), method='raw', n=1, seed=1, progress=False); result = withdrawal_paths(b2, column='us', inflation='infl'))",
    r"(d2 = copy(db); d2["infl"] = fill(-150.0, SL.nrow(d2)); b2 = bootstrap(d2, bootstrap_config((us = "us",), aux = (infl = "infl",), input = "prices", aux_type = (infl = "rate",)), "raw"; n = 1, seed = 1, progress = false); result = withdrawal_paths(b2; column = "us", inflation = "infl"))", inp = ein("withdrawal/wp_rate_neg", c("db"))),
  zeile("wp_level_neg",
    r"(d2 <- db; d2$zins <- d2$zins - 2.5; b2 <- bootstrap(d2, bootstrap_config(c(us = 'us'), aux = c(zins = 'zins'), input = 'prices'), 'raw', n = 1, seed = 1, progress = FALSE); withdrawal_paths(b2, column = 'us', inflation = 'zins'))",
    r"(d2 = db.copy(); d2['zins'] = d2['zins'] - 2.5; b2 = bootstrap(d2, bootstrap_config({'us': 'us'}, aux={'zins': 'zins'}, input='prices'), method='raw', n=1, seed=1, progress=False); result = withdrawal_paths(b2, column='us', inflation='zins'))",
    r"(d2 = copy(db); d2["zins"] = d2.zins .- 2.5; b2 = bootstrap(d2, bootstrap_config((us = "us",), aux = (zins = "zins",), input = "prices"), "raw"; n = 1, seed = 1, progress = false); result = withdrawal_paths(b2; column = "us", inflation = "zins"))", inp = ein("withdrawal/wp_level_neg", c("db")))))
TB("bootstrap_data", "Meldungen und Warnungen von bootstrap_data je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("coh_bd_attr_err",
    r"(cfg <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices', aux_type = c(infl = 'rate', cpi = 'level'))
cfg0 <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices')
b <- bootstrap(db, cfg, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
b0 <- bootstrap(db, cfg0, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
x <- bootstrap_data(b, 1); withdrawal_cohorts(x, price = 'us', inflation = 'infl', years = 1, inflation_type = 'level'))",
    r"(cfg = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices', aux_type={'infl': 'rate', 'cpi': 'level'})
cfg0 = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices')
b = bootstrap(db, cfg, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
b0 = bootstrap(db, cfg0, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
x = bootstrap_data(b, i=1); result = withdrawal_cohorts(x, price='us', inflation='infl', years=1, inflation_type='level'))",
    r"(cfg = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices", aux_type = (infl = "rate", cpi = "level"))
cfg0 = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices")
b = bootstrap(db, cfg, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
b0 = bootstrap(db, cfg0, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
x = bootstrap_data(b, 1); result = withdrawal_cohorts(x; price = "us", inflation = "infl", years = 1, inflation_type = "level"))", inp = ein("withdrawal/coh_bd_attr_err", c("db")))))
TB("bootstrap_study", "Meldungen und Warnungen von bootstrap_study je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("wps_noreturns",
    r"(st <- bootstrap_study(db, bootstrap_config(c(us = 'us'), input = 'prices'), 'raw', n = 2, path_length = 400, seed = 1, progress = FALSE, strategies = list(a = create_strategy(us = asset_config('etf', 'bnh', spread = 0.1)))); withdrawal_paths(st))",
    r"(st = bootstrap_study(db, bootstrap_config({'us': 'us'}, input='prices'), 'raw', n=2, path_length=400, seed=1, progress=False, strategies={'a': simlev.create_strategy(us=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1))}); result = withdrawal_paths(st))",
    r"(st = bootstrap_study(db, bootstrap_config((us = "us",), input = "prices"), "raw"; n = 2, path_length = 400, seed = 1, progress = false, strategies = (a = create_strategy(us = asset_config("etf", "bnh", spread = 0.1)),)); result = withdrawal_paths(st))", inp = ein("withdrawal/wps_noreturns", c("db"))),
  zeile("wps_neg_level",
    r"(d2 <- db; d2$zins <- d2$zins - 2.5; st <- suppressWarnings(bootstrap_study(d2, bootstrap_config(c(us = 'us'), aux = c(zins = 'zins'), input = 'prices'), 'stationary', n = 2, params = list(L = 50), seed = 1, progress = FALSE, keep_returns = 'year', keep_aux = 'zins', strategies = list(a = create_strategy(us = asset_config('etf', 'bnh', spread = 0.1))))); withdrawal_paths(st, inflation = 'zins'))",
    r"(d2 = db.copy(); d2['zins'] = d2['zins'] - 2.5
import warnings as _w
with _w.catch_warnings():
    _w.simplefilter('ignore')
    st = bootstrap_study(d2, bootstrap_config({'us': 'us'}, aux={'zins': 'zins'}, input='prices'), 'stationary', n=2, params={'L': 50}, seed=1, progress=False, keep_returns='year', keep_aux='zins', strategies={'a': simlev.create_strategy(us=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1))})
result = withdrawal_paths(st, inflation='zins'))",
    r"(d2 = copy(db); d2["zins"] = d2.zins .- 2.5; st = B._quiet(() -> bootstrap_study(d2, bootstrap_config((us = "us",), aux = (zins = "zins",), input = "prices"), "stationary"; n = 2, params = (L = 50,), seed = 1, progress = false, keep_returns = "year", keep_aux = "zins", strategies = (a = create_strategy(us = asset_config("etf", "bnh", spread = 0.1)),))); result = withdrawal_paths(st; inflation = "zins"))", inp = ein("withdrawal/wps_neg_level", c("db")))))
ref_done()

ref_schreiben()
