# tests/gleichlauf/erzeugen/wrapper.R – Bereich wrapper als Szenarien und Tabellen (seit 1.4.2; bis 1.4.1 Einzelfälle je Modul und Funktion).
# Fonds-Wrapper: wrapper_nav (Anteilswert mit Verwaltungs- und Performancegebühr), Wrapper-Assets in simulation() und
# in den Aufrufern, Bausteine und Strategie-Werkzeuge, Eingabeprüfungen.
#   gleichlauf  Szenarien: je Szenario ein Aufruf bzw. eine kurze Aufrufkette, die mehrere Ergebnisse zugleich prüft
#               (Teile; Name = bisherige Fallkennung). Feld note: "prüft: …"
#   fehler      je Funktion eine Tabelle "Eingabe -> Meldung" (jede Zeile ein eigener Aufruf)
#   ausgabe     print()/summary() als Tabelle
# Herkunft der Erwartung: R. Daten und Hilfen wie in tests/werkzeuge/breite/wrapper.R (Breitenprüfung mit allen bisherigen Fällen).
# Aufruf (Repo-Wurzel): LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript tests/gleichlauf/erzeugen/wrapper.R
# Ausgabe tests/{gleichlauf,fehler,ausgabe}/faelle/wrapper.jsonl.gz (Format: ref_tools.R, Szenarien: szenario_tools.R).
source("tests/gleichlauf/erzeugen/ref_tools.R"); source("tests/gleichlauf/erzeugen/szenario_tools.R")
ref_bereich("wrapper")
EIN <- list()   # Eingaben je bisherigem Fall (Momentaufnahme an der Stelle, an der der Fall im alten Generator stand)

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul wrapper
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# ── Daten ───────────────────────────────────────────────────────────────────
set.seed(11); n <- 400   # bis 1.4.1 640 Tage (kürzester Ausschnitt mit voller Abdeckung)
d <- data.frame(date = seq.Date(as.Date("2019-11-04"), by = "day", length.out = n))
d$A <- 100 * cumprod(1 + rnorm(n, 4e-4, 0.011)); d$B <- 50 * cumprod(1 + rnorm(n, 1e-4, 0.004))
d$C <- 80 * cumprod(1 + rnorm(n, 2e-4, 0.006))
d$buy <- c(FALSE, diff(d$A) > 0); d$sell <- !d$buy
d$ev <- seq_len(n) %% 90 == 0
dw <- d[!format(d$date, "%u") %in% c("6", "7"), ]; rownames(dw) <- NULL           # nur Werktage
dn <- d; dn[c(40:42, 300), c("A", "B")] <- NA; dn$A[200:204] <- NA                 # NA-Tage
dg <- d; dg$B[1:30] <- NA                                                          # gestaffelter innerer Start
dl <- d; dl[1:12, c("A", "B")] <- NA                                               # Anteilswert beginnt später
dsp <- d[1:200, ]; dsp$A <- 100 * cumprod(1 + rnorm(200, 2.5e-3, 0.01))                     # Split auf innerer Spalte
dh <- data.frame(date = as.Date(c("2020-02-27", "2020-02-28", "2020-03-02", "2020-12-30", "2020-12-31",
                                  "2021-01-04", "2021-06-30", "2021-12-31", "2022-01-03")),
                 A = c(100, 101, 103, 110, 112, 111, 95, 120, 121), B = c(50, 50.5, 50.2, 51, 51.5, 51.2, 52, 53, 53.1))
d1 <- d[1, ]
du <- d[c(5:300, 1:4), ]; rownames(du) <- NULL                                    # unsortiert
dz <- d; dz$Z <- 1                                                                 # Spaltenkollision
I <- list(d = d, dw = dw, dn = dn, dg = dg, dl = dl, dsp = dsp, dh = dh, d1 = d1, du = du, dz = dz)
# ── gemeinsame Objekte je Sprache ───────────────────────────────────────────
R0 <- paste0(
  "inner <- create_strategy(A = asset_config('etf', 'bnh', 0.6), B = asset_config('etf', 'bnh', 0.4))\n",
  "w0 <- wrapper_config(inner, costs = funds_costs(0, 0))\n",
  "wf <- wrapper_config(inner, costs = funds_costs(0.95, 0))\n",
  "wp <- wrapper_config(inner, costs = funds_costs(0, 10))\n",
  "wb <- wrapper_config(inner, rebalance = rebalance_plan(unit = 'quarter'), costs = funds_costs(0.95, 10))\n")
P0 <- paste0(
  "from simlev import create_strategy, asset_config, wrapper_config, wrapper_nav, funds_costs, rebalance_plan, sim_costs, dca_plan, tax_profile, split_rule, harvest_rule\n",
  "inner = create_strategy(A=asset_config(asset_class='etf', trading='bnh', share=0.6), B=asset_config(asset_class='etf', trading='bnh', share=0.4))\n",
  "w0 = wrapper_config(inner, costs=funds_costs(fee=0, performance_fee=0))\n",
  "wf = wrapper_config(inner, costs=funds_costs(fee=0.95, performance_fee=0))\n",
  "wp = wrapper_config(inner, costs=funds_costs(fee=0, performance_fee=10))\n",
  "wb = wrapper_config(inner, rebalance=rebalance_plan(unit='quarter'), costs=funds_costs(fee=0.95, performance_fee=10))\n")
J0 <- paste0(
  'inner = SL.create_strategy("A" => SL.asset_config("etf", "bnh", 0.6), "B" => SL.asset_config("etf", "bnh", 0.4))\n',
  'w0 = SL.wrapper_config(inner; costs = SL.funds_costs(0, 0))\n',
  'wf = SL.wrapper_config(inner; costs = SL.funds_costs(0.95, 0))\n',
  'wp = SL.wrapper_config(inner; costs = SL.funds_costs(0, 10))\n',
  'wb = SL.wrapper_config(inner; rebalance = SL.rebalance_plan(; unit = "quarter"), costs = SL.funds_costs(0.95, 10))\n')
# Meldungen (message) als Ergebnis: Texte ohne abschließenden Zeilenumbruch
MR <- function(expr) sprintf("m <- character(0); invisible(withCallingHandlers(%s, message = function(e) { m <<- c(m, sub('\\n$', '', conditionMessage(e))); invokeRestart('muffleMessage') })); m", expr)
MP <- function(expr) sprintf("import io, contextlib\nbuf = io.StringIO()\nwith contextlib.redirect_stderr(buf):\n    _x = %s\nresult = buf.getvalue().splitlines()", expr)
MJ <- function(expr) sprintf('result = mktemp() do path, io\n    redirect_stderr(io) do\n        %s\n    end\n    flush(io)\n    String.(split(chomp(read(path, String)), "\\n"))\nend', expr)
# ── Aufrufer ────────────────────────────────────────────────────────────────
BS_R <- "cfg <- bootstrap_config(c(A = 'A', B = 'B'), input = 'prices'); strats <- list(wrap = create_strategy(Z = asset_config('certificate', spread = 0.2, wrapper = wb)), direct = inner)\n"
BS_P <- "cfg = simlev.bootstrap_config({'A': 'A', 'B': 'B'}, input='prices'); strats = {'wrap': create_strategy(Z=asset_config(asset_class='certificate', spread=0.2, wrapper=wb)), 'direct': inner}\n"
BS_J <- 'cfg = SL.bootstrap_config((A = "A", B = "B"); input = "prices"); strats = (wrap = SL.create_strategy("Z" => SL.asset_config("certificate"; spread = 0.2, wrapper = wb)), direct = inner)\n'
# ── Auswahl aus SimLevWrapperNav: gewöhnliche Tabelle ohne Klasse und Attribute ──
# Ergebnis je Fall: Klasse, Attribut inner fehlt, Attribut wrapper fehlt, die Auswahl selbst
SK_R <- "x <- wrapper_nav(d, wb); K <- function(s) list(class(s), is.null(attr(s, 'inner')), is.null(attr(s, 'wrapper')), s)\n"
SK_P <- paste0("import pandas as pd\nx = wrapper_nav(d, wb)\n",
               "def K(s):\n    return [['data.frame'] if type(s) is pd.DataFrame else list(getattr(s, 'r_class', None) or [type(s).__name__]), ",
               "'inner' not in s.attrs, 'wrapper' not in s.attrs, s]\n")
SK_J <- paste0("x = SL.wrapper_nav(d, wb)\n",
               'K(s) = [isempty(SL.r_class(s)) ? ["data.frame"] : SL.r_class(s), !haskey(SL.attrs(s), "inner"), !haskey(SL.attrs(s), "wrapper"), s]\n')
# ── Exporte ohne eigenen Fall (rebalance_trigger, strategy_remove_asset, summary einer Strategie);
#    bis 1.4.0 nur in den Testdateien der Sprachen geprüft ───────────────────────
TR <- list(tdf = data.frame(target_leverage = c(NA, 1, 1.05, 1.2, 1.15, 1.4, NA, 1),
                            sigma_ewma = c(NA, NA, 0.1, 0.13, 0.1, 0.2, 0.2, 0.15)))

# Vorspann je Szenario bzw. Tabellenzeile (gemeinsame Objekte des Moduls)
VOR <- list(r = r"(inner <- create_strategy(A = asset_config('etf', 'bnh', 0.6), B = asset_config('etf', 'bnh', 0.4))
w0 <- wrapper_config(inner, costs = funds_costs(0, 0))
wf <- wrapper_config(inner, costs = funds_costs(0.95, 0))
wp <- wrapper_config(inner, costs = funds_costs(0, 10))
wb <- wrapper_config(inner, rebalance = rebalance_plan(unit = 'quarter'), costs = funds_costs(0.95, 10)))",
            py = r"(from simlev import create_strategy, asset_config, wrapper_config, wrapper_nav, funds_costs, rebalance_plan, sim_costs, dca_plan, tax_profile, split_rule, harvest_rule
inner = create_strategy(A=asset_config(asset_class='etf', trading='bnh', share=0.6), B=asset_config(asset_class='etf', trading='bnh', share=0.4))
w0 = wrapper_config(inner, costs=funds_costs(fee=0, performance_fee=0))
wf = wrapper_config(inner, costs=funds_costs(fee=0.95, performance_fee=0))
wp = wrapper_config(inner, costs=funds_costs(fee=0, performance_fee=10))
wb = wrapper_config(inner, rebalance=rebalance_plan(unit='quarter'), costs=funds_costs(fee=0.95, performance_fee=10)))",
            jl = r"(inner = SL.create_strategy("A" => SL.asset_config("etf", "bnh", 0.6), "B" => SL.asset_config("etf", "bnh", 0.4))
w0 = SL.wrapper_config(inner; costs = SL.funds_costs(0, 0))
wf = SL.wrapper_config(inner; costs = SL.funds_costs(0.95, 0))
wp = SL.wrapper_config(inner; costs = SL.funds_costs(0, 10))
wb = SL.wrapper_config(inner; rebalance = SL.rebalance_plan(; unit = "quarter"), costs = SL.funds_costs(0.95, 10)))")

ref_init("wrapper", gruppe = "gleichlauf")
SZ("fondsanteil_kalender_und_reihenfolge", "wrapper_nav: Gebühren über die Kalendertage bei Kursen nur an Werktagen (Verwaltungs- und Performancegebühr, inneres Umschichten je Quartal); unsortierte Daten", vor = VOR, teile = list(
  nav_weekdays = teil(
    r"(wrapper_nav(dw, wb))",
    r"(result = wrapper_nav(dw, wb))",
    r"(result = SL.wrapper_nav(dw, wb))", druck = TRUE, inp = ein("wrapper/nav_weekdays", c("dw"))),
  nav_unsorted = teil(
    r"(wrapper_nav(du, wf))",
    r"(result = wrapper_nav(du, wf))",
    r"(result = SL.wrapper_nav(du, wf))", druck = TRUE, inp = ein("wrapper/nav_unsorted", c("du")))))
SZ("wrapper_in_simulation", "simulation() mit Wrapper-Assets: details-Protokoll (result$wrappers); ein Lauf mit Splits innen und beim direkten Asset (nicht beim Anteilswert), ganzen Stücken und Basiszins 0 in jeder dritten Zeile (NA seit 1.6.4 Fehler, Tabelle simulation)", vor = VOR, teile = list(
  sim_details = teil(
    r"(simulation(d[1:120, ], create_strategy(Z = asset_config('certificate', share = 0.8, wrapper = wb), C = asset_config('etf', 'bnh', 0.2)), rebalance = rebalance_plan(), details = TRUE))",
    r"(result = simlev.simulation(d.iloc[:120], create_strategy(Z=asset_config(asset_class='certificate', share=0.8, wrapper=wb), C=asset_config(asset_class='etf', trading='bnh', share=0.2)), rebalance=rebalance_plan(), details=True))",
    r"(result = SL.simulation(SL.rows(d, 1:120), SL.create_strategy("Z" => SL.asset_config("certificate"; share = 0.8, wrapper = wb), "C" => SL.asset_config("etf", "bnh", 0.2)); rebalance = SL.rebalance_plan(), details = true))", druck = TRUE, inp = ein("wrapper/sim_details", c("d"))),
  sim_splits_br0 = teil(
    r"(x <- dsp; x$br <- ifelse(seq_len(nrow(x)) %% 3 == 0, 0, 2.5); simulation(x, create_strategy(Z = asset_config('certificate', share = 0.5, wrapper = wb), A = asset_config('etf', 'bnh', 0.3), C = asset_config('etf', 'bnh', 0.2)), splits = split_rule(c(50, 150)), fractions = FALSE, tax = tax_profile(base_rate = 'br')))",
    r"(x = dsp.copy(); x['br'] = [0.0 if (i + 1) % 3 == 0 else 2.5 for i in range(len(x))]; result = simlev.simulation(x, create_strategy(Z=asset_config(asset_class='certificate', share=0.5, wrapper=wb), A=asset_config(asset_class='etf', trading='bnh', share=0.3), C=asset_config(asset_class='etf', trading='bnh', share=0.2)), splits=split_rule([50, 150]), fractions=False, tax=tax_profile(base_rate='br')))",
    r"(x = copy(dsp); x["br"] = [i % 3 == 0 ? 0.0 : 2.5 for i in 1:SL.nrow(x)]; result = SL.simulation(x, SL.create_strategy("Z" => SL.asset_config("certificate"; share = 0.5, wrapper = wb), "A" => SL.asset_config("etf", "bnh", 0.3), "C" => SL.asset_config("etf", "bnh", 0.2)); splits = SL.split_rule([50, 150]), fractions = false, tax = SL.tax_profile(; base_rate = "br")))", druck = TRUE, inp = ein("wrapper/sim_splits", c("dsp")))))
SZ("wrapper_in_aufrufern", "offene Bestände des Wrapper-Assets in die Entnahme, param_search mit Builder, der den Wrapper baut, Einmalanlage gegen Sparplan mit dem Anteilswert als Kurs", vor = VOR, teile = list(
  wd_lots = teil(
    r"(r <- simulation(d, create_strategy(Z = asset_config('certificate', spread = 0.2, wrapper = wb)), tax = tax_profile()); ws <- withdrawal_simulation(wrapper_nav(d, wb), withdrawal_rule('constant', rate = 4), years = 1, frequency = 'quarter', start_value = r, tax = tax_profile()); list(r$open_lots, ws$paths))",
    r"(r = simlev.simulation(d, create_strategy(Z=asset_config(asset_class='certificate', spread=0.2, wrapper=wb)), tax=tax_profile()); ws = simlev.withdrawal_simulation(wrapper_nav(d, wb), rule=simlev.withdrawal_rule(type='constant', rate=4), years=1, frequency='quarter', start_value=r, tax=tax_profile()); result = [r.open_lots, ws['paths']])",
    r"(r = SL.simulation(d, SL.create_strategy("Z" => SL.asset_config("certificate"; spread = 0.2, wrapper = wb)); tax = SL.tax_profile()); ws = SL.withdrawal_simulation(SL.wrapper_nav(d, wb), SL.withdrawal_rule("constant"; rate = 4); years = 1, frequency = "quarter", start_value = r, tax = SL.tax_profile()); result = [r.open_lots, ws["paths"]])", inp = ein("wrapper/wd_lots", c("d"))),
  ps_builder = teil(
    r"(b <- function(p) list(strategy = create_strategy(Z = asset_config('certificate', wrapper = wrapper_config(inner, costs = funds_costs(fee = p$fee, performance_fee = p$pf))))); ps <- param_search(d, b, param_space(fee = c(0, 0.5, 1.5), pf = c(0, 20)), objective = 'cagr'); ps$results$elapsed <- 0; ps$elapsed <- 0; ps$results)",
    r"(def b(p):
    return {'strategy': create_strategy(Z=asset_config(asset_class='certificate', wrapper=wrapper_config(inner, costs=funds_costs(fee=p['fee'], performance_fee=p['pf']))))}
ps = simlev.param_search(d, b, simlev.param_space(fee=[0.0, 0.5, 1.5], pf=[0.0, 20.0]), objective='cagr'); ps['results']['elapsed'] = 0.0; result = ps['results'])",
    r"(b(p) = RList("strategy" => SL.create_strategy("Z" => SL.asset_config("certificate"; wrapper = SL.wrapper_config(inner; costs = SL.funds_costs(; fee = p["fee"], performance_fee = p["pf"]))))); ps = SL.param_search(d, b, SL.param_space(fee = [0.0, 0.5, 1.5], pf = [0.0, 20.0]); objective = "cagr"); ps["results"]["elapsed"] = 0.0; result = ps["results"])", inp = ein("wrapper/ps_builder", c("d"))),
  pl_lumpsum = teil(
    r"(planning_lumpsum_vs_dca(d, create_strategy(Z = asset_config('certificate', share = 0.6, wrapper = wb), C = asset_config('etf', 'bnh', 0.4)), amount = 1200, months = 4, horizon = 1, step = 3))",
    r"(result = simlev.planning_lumpsum_vs_dca(d, create_strategy(Z=asset_config(asset_class='certificate', share=0.6, wrapper=wb), C=asset_config(asset_class='etf', trading='bnh', share=0.4)), amount=1200, months=4, horizon=1, step=3))",
    r"(result = SL.planning_lumpsum_vs_dca(d, SL.create_strategy("Z" => SL.asset_config("certificate"; share = 0.6, wrapper = wb), "C" => SL.asset_config("etf", "bnh", 0.4)); amount = 1200, months = 4, horizon = 1, step = 3))", druck = TRUE, inp = ein("wrapper/pl_lumpsum", c("d")))))
SZ("wrapper_konfiguration", "wrapper_config mit Liste statt Strategie und allen Feldern, mit Ereignis-Umschichtung, asset_config mit Wrapper (Ergebnis und Druck), Hinweis bei innerem Spread", vor = VOR, teile = list(
  pr_config_full = teil(
    r"(wrapper_config(list(A = asset_config('etf', 'bnh', 0.25), B = list(asset_class = 'etc', share = 0.75)), rebalance = rebalance_plan(span = 6, days = 3, anchor = 'end'), costs = funds_costs(1.25, 12.5), order_fee = list(fixed = 2.5, percent = 0.05, min = 4), volume = 2.5e6))",
    r"(result = wrapper_config({'A': asset_config(asset_class='etf', trading='bnh', share=0.25), 'B': {'asset_class': 'etc', 'share': 0.75}}, rebalance=rebalance_plan(span=6, days=3, anchor='end'), costs=funds_costs(fee=1.25, performance_fee=12.5), order_fee={'fixed': 2.5, 'percent': 0.05, 'min': 4}, volume=2.5e6))",
    r"(result = SL.wrapper_config(RList("A" => SL.asset_config("etf", "bnh", 0.25), "B" => RList("asset_class" => "etc", "share" => 0.75)); rebalance = SL.rebalance_plan(; span = 6, days = 3, anchor = "end"), costs = SL.funds_costs(1.25, 12.5), order_fee = (fixed = 2.5, percent = 0.05, min = 4), volume = 2.5e6))", druck = TRUE, inp = ein("wrapper/pr_config_full", c())),
  pr_config_event = teil(
    r"(wrapper_config(inner, rebalance = rebalance_plan(event_col = 'ev', event_mode = 'replace')))",
    r"(result = wrapper_config(inner, rebalance=rebalance_plan(event_col='ev', event_mode='replace')))",
    r"(result = SL.wrapper_config(inner; rebalance = SL.rebalance_plan(; event_col = "ev", event_mode = "replace")))", druck = TRUE, inp = ein("wrapper/pr_config_event", c())),
  pr_asset = teil(
    r"(asset_config('certificate', share = 0.5, spread = 0.3, wrapper = wb))",
    r"(result = asset_config(asset_class='certificate', share=0.5, spread=0.3, wrapper=wb))",
    r"(result = SL.asset_config("certificate"; share = 0.5, spread = 0.3, wrapper = wb))", druck = TRUE, inp = ein("wrapper/pr_asset", c())),
  hint_spread = teil(
    r"(m <- character(0); invisible(withCallingHandlers(wrapper_config(create_strategy(A = asset_config('etf', 'bnh', 0.6, spread = 0.15), B = asset_config('etf', 'bnh', 0.4))), message = function(e) { m <<- c(m, sub('\n$', '', conditionMessage(e))); invokeRestart('muffleMessage') })); m)",
    r"(import io, contextlib
buf = io.StringIO()
with contextlib.redirect_stderr(buf):
    _x = wrapper_config(create_strategy(A=asset_config(asset_class='etf', trading='bnh', share=0.6, spread=0.15), B=asset_config(asset_class='etf', trading='bnh', share=0.4)))
result = buf.getvalue().splitlines())",
    r"(result = mktemp() do path, io
    redirect_stderr(io) do
        SL.wrapper_config(SL.create_strategy("A" => SL.asset_config("etf", "bnh", 0.6; spread = 0.15), "B" => SL.asset_config("etf", "bnh", 0.4)))
    end
    flush(io)
    String.(split(chomp(read(path, String)), "\n"))
end)", inp = ein("wrapper/hint_spread", c()))))
SZ("strategie_mit_wrapper_bearbeiten", "Kette strategy_add_asset (Wrapper mit Signal-Asset innen) -> strategy_update_asset (Anlageklasse und Spread) -> strategy_validate mit Daten; Ergebnis und Druck der Strategie", vor = VOR, teile = list(
  st_add_update_validate = teil(
    r"(st <- strategy_add_asset(create_strategy(C = asset_config('etf', 'bnh', 0.5)), 'Z', asset_config('etf', share = 0.5, wrapper = wrapper_config(create_strategy(A = asset_config('etf', 'signal', signal_buy = 'buy', signal_sell = 'sell'))))); st <- strategy_update_asset(st, 'Z', asset_class = 'certificate', spread = 0.5); strategy_validate(st, d); st)",
    r"(st = simlev.strategy_add_asset(create_strategy(C=asset_config(asset_class='etf', trading='bnh', share=0.5)), 'Z', asset_config(asset_class='etf', share=0.5, wrapper=wrapper_config(create_strategy(A=asset_config(asset_class='etf', trading='signal', signal_buy='buy', signal_sell='sell'))))); st = simlev.strategy_update_asset(st, 'Z', asset_class='certificate', spread=0.5); simlev.strategy_validate(st, data=d); result = st)",
    r"(st = SL.strategy_add_asset(SL.create_strategy("C" => SL.asset_config("etf", "bnh", 0.5)), "Z", SL.asset_config("etf"; share = 0.5, wrapper = SL.wrapper_config(SL.create_strategy("A" => SL.asset_config("etf", "signal"; signal_buy = "buy", signal_sell = "sell"))))); st = SL.strategy_update_asset(st, "Z"; asset_class = "certificate", spread = 0.5); SL.strategy_validate(st, d); result = st)", druck = TRUE, inp = ein("wrapper/st_validate", c("d")))))
SZ("umschicht_ausloeser", "rebalance_trigger combined aus abs_leverage (Referenz = erster nicht fehlender Wert, NA löst nicht aus), rel_leverage und vol_band", vor = VOR, teile = list(
  trig_combined = teil(
    r"(rebalance_trigger(tdf, 'combined', triggers = list(list(type = 'abs_leverage', threshold = 10), list(type = 'rel_leverage', threshold = 10), list(type = 'vol_band', threshold = 20)), out_col = 't'))",
    r"(result = simlev.rebalance_trigger(tdf, 'combined', triggers=[{'type': 'abs_leverage', 'threshold': 10}, {'type': 'rel_leverage', 'threshold': 10}, {'type': 'vol_band', 'threshold': 20}], out_col='t'))",
    r"(result = SL.rebalance_trigger(tdf, "combined"; triggers = [Dict("type" => "abs_leverage", "threshold" => 10), Dict("type" => "rel_leverage", "threshold" => 10), Dict("type" => "vol_band", "threshold" => 20)], out_col = "t"))", inp = ein("wrapper/trig_combined", c("tdf")))))
ref_done()

ref_init("wrapper", gruppe = "fehler")
TB("wrapper_nav", "Meldungen und Warnungen von wrapper_nav je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("nav_one_day",
    r"(wrapper_nav(d1, wb))",
    r"(result = wrapper_nav(d1, wb))",
    r"(result = SL.wrapper_nav(d1, wb))", print = TRUE, inp = ein("wrapper/nav_one_day", c("d1"))),
  zeile("err_inner_all_na",
    r"(x <- d; x$A <- NA_real_; x$B <- NA_real_; wrapper_nav(x, wb))",
    r"(x = d.copy(); x['A'] = np.nan; x['B'] = np.nan; result = wrapper_nav(x, wb))",
    r"(x = copy(d); x["A"] = fill(SL.NA, SL.nrow(x)); x["B"] = fill(SL.NA, SL.nrow(x)); result = SL.wrapper_nav(x, wb))", inp = ein("wrapper/err_inner_all_na", c("d"))),
  zeile("err_nav_wrapper",
    r"(wrapper_nav(d, inner))",
    r"(result = wrapper_nav(d, inner))",
    r"(result = SL.wrapper_nav(d, inner))", inp = ein("wrapper/err_nav_wrapper", c("d"))),
  zeile("err_nav_splits",
    r"(wrapper_nav(d, wb, splits = c(50, 150)))",
    r"(result = wrapper_nav(d, wb, splits=np.array([50.0, 150.0])))",
    r"(result = SL.wrapper_nav(d, wb; splits = [50.0, 150.0]))", inp = ein("wrapper/err_nav_splits", c("d"))),
  zeile("wd_sub_err",
    r"(x <- wrapper_nav(d, wb); withdrawal_simulation(x[200:400, ], withdrawal_rule('percent', rate = 4), years = 1, frequency = 'quarter'))",
    r"(x = wrapper_nav(d, wb); result = simlev.withdrawal_simulation(x.iloc[199:400], rule=simlev.withdrawal_rule(type='percent', rate=4), years=1, frequency='quarter'))",
    r"(x = SL.wrapper_nav(d, wb); result = SL.withdrawal_simulation(SL.rows(x, 200:400), SL.withdrawal_rule("percent"; rate = 4); years = 1, frequency = "quarter"))", inp = ein("wrapper/wd_sub_err", c("d")))))
TB("wrapper_config", "Meldungen und Warnungen von wrapper_config je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("err_nested",
    r"(wrapper_config(create_strategy(Z = asset_config(wrapper = wb))))",
    r"(result = wrapper_config(create_strategy(Z=asset_config(wrapper=wb))))",
    r"(result = SL.wrapper_config(SL.create_strategy("Z" => SL.asset_config(; wrapper = wb))))", inp = ein("wrapper/err_nested", c())),
  zeile("err_volume_fixed",
    r"(wrapper_config(inner, order_fee = 1))",
    r"(result = wrapper_config(inner, order_fee=1))",
    r"(result = SL.wrapper_config(inner; order_fee = 1))", inp = ein("wrapper/err_volume_fixed", c())),
  zeile("err_volume_bad",
    r"(wrapper_config(inner, volume = c(1, 2)))",
    r"(result = wrapper_config(inner, volume=[1.0, 2.0]))",
    r"(result = SL.wrapper_config(inner; volume = [1.0, 2.0]))", inp = ein("wrapper/err_volume_bad", c())),
  zeile("err_costs",
    r"(wrapper_config(inner, costs = sim_costs()))",
    r"(result = wrapper_config(inner, costs=sim_costs()))",
    r"(result = SL.wrapper_config(inner; costs = SL.sim_costs()))", inp = ein("wrapper/err_costs", c())),
  zeile("err_rebalance",
    r"(wrapper_config(inner, rebalance = dca_plan(100, 1)))",
    r"(result = wrapper_config(inner, rebalance=dca_plan(100, 1)))",
    r"(result = SL.wrapper_config(inner; rebalance = SL.dca_plan(100, 1)))", inp = ein("wrapper/err_rebalance", c())),
  zeile("err_strategy",
    r"(wrapper_config('A'))",
    r"(result = wrapper_config('A'))",
    r"(result = SL.wrapper_config("A"))", inp = ein("wrapper/err_strategy", c())),
  zeile("err_share",
    r"(wrapper_config(create_strategy(A = asset_config('etf', 'bnh', 0.6), B = asset_config('etf', 'bnh', 0.3))))",
    r"(result = wrapper_config(create_strategy(A=asset_config(asset_class='etf', trading='bnh', share=0.6), B=asset_config(asset_class='etf', trading='bnh', share=0.3))))",
    r"(result = SL.wrapper_config(SL.create_strategy("A" => SL.asset_config("etf", "bnh", 0.6), "B" => SL.asset_config("etf", "bnh", 0.3))))", inp = ein("wrapper/err_share", c()))))
TB("simulation", "Meldungen und Warnungen von simulation je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("err_br_na",   # seit 1.6.4 Fehler (Entscheidungen 17, 42; bis 1.6.3 Teil sim_splits_br_na von wrapper_in_simulation, NA zählte als 0)
    r"(x <- dsp; x$br <- ifelse(seq_len(nrow(x)) %% 3 == 0, NA, 2.5); simulation(x, create_strategy(Z = asset_config('certificate', share = 0.5, wrapper = wb), A = asset_config('etf', 'bnh', 0.3), C = asset_config('etf', 'bnh', 0.2)), splits = split_rule(c(50, 150)), fractions = FALSE, tax = tax_profile(base_rate = 'br')))",
    r"(x = dsp.copy(); x['br'] = [np.nan if (i + 1) % 3 == 0 else 2.5 for i in range(len(x))]; result = simlev.simulation(x, create_strategy(Z=asset_config(asset_class='certificate', share=0.5, wrapper=wb), A=asset_config(asset_class='etf', trading='bnh', share=0.3), C=asset_config(asset_class='etf', trading='bnh', share=0.2)), splits=split_rule([50, 150]), fractions=False, tax=tax_profile(base_rate='br')))",
    r"(x = copy(dsp); x["br"] = [i % 3 == 0 ? SL.NA : 2.5 for i in 1:SL.nrow(x)]; result = SL.simulation(x, SL.create_strategy("Z" => SL.asset_config("certificate"; share = 0.5, wrapper = wb), "A" => SL.asset_config("etf", "bnh", 0.3), "C" => SL.asset_config("etf", "bnh", 0.2)); splits = SL.split_rule([50, 150]), fractions = false, tax = SL.tax_profile(; base_rate = "br")))", inp = ein("wrapper/sim_splits", c("dsp"))),
  zeile("err_signal_list",
    r"(simulation(d, list(Z = list(asset_class = 'etf', trading = 'signal', share = 1, signal_buy = 'buy', signal_sell = 'sell', wrapper = wb))))",
    r"(result = simlev.simulation(d, {'Z': {'asset_class': 'etf', 'trading': 'signal', 'share': 1, 'signal_buy': 'buy', 'signal_sell': 'sell', 'wrapper': wb}}))",
    r"(result = SL.simulation(d, RList("Z" => RList("asset_class" => "etf", "trading" => "signal", "share" => 1, "signal_buy" => "buy", "signal_sell" => "sell", "wrapper" => wb))))", inp = ein("wrapper/err_signal_list", c("d"))),
  zeile("err_collision",
    r"(simulation(dz, create_strategy(Z = asset_config(wrapper = wb))))",
    r"(result = simlev.simulation(dz, create_strategy(Z=asset_config(wrapper=wb))))",
    r"(result = SL.simulation(dz, SL.create_strategy("Z" => SL.asset_config(; wrapper = wb))))", inp = ein("wrapper/err_collision", c("dz"))),
  zeile("err_late_only",
    r"(simulation(dl, create_strategy(Z = asset_config('certificate', wrapper = wb))))",
    r"(result = simlev.simulation(dl, create_strategy(Z=asset_config(asset_class='certificate', wrapper=wb))))",
    r"(result = SL.simulation(dl, SL.create_strategy("Z" => SL.asset_config("certificate"; wrapper = wb))))", inp = ein("wrapper/err_late_only", c("dl"))),
  zeile("sim_err_list_class",
    r"(simulation(d, list(A = list(asset_class = 'fonds', trading = 'bnh', share = 1))))",
    r"(result = simlev.simulation(d, {'A': {'asset_class': 'fonds', 'trading': 'bnh', 'share': 1}}))",
    r"(result = SL.simulation(d, Dict("A" => Dict("asset_class" => "fonds", "trading" => "bnh", "share" => 1))))", inp = ein("wrapper/sim_err_list_class", c("d"))),
  zeile("sim_err_list_share_pct",   # Hinweis bei 1 < share <= 100 (Entscheidung 12; seit 1.6.4, K43 KE)
    r"(simulation(d, list(A = list(asset_class = 'etf', trading = 'bnh', share = 60))))",
    r"(result = simlev.simulation(d, {'A': {'asset_class': 'etf', 'trading': 'bnh', 'share': 60}}))",
    r"(result = SL.simulation(d, Dict("A" => Dict("asset_class" => "etf", "trading" => "bnh", "share" => 60))))", inp = ein("wrapper/sim_err_list_class", c("d"))),
  zeile("sim_err_list_regime",
    r"(simulation(d, list(A = list(asset_class = 'etf', trading = 'bnh', share = 1, tax_regime = 'none'))))",
    r"(result = simlev.simulation(d, {'A': {'asset_class': 'etf', 'trading': 'bnh', 'share': 1, 'tax_regime': 'none'}}))",
    r"(result = SL.simulation(d, Dict("A" => Dict("asset_class" => "etf", "trading" => "bnh", "share" => 1, "tax_regime" => "none"))))", inp = ein("wrapper/sim_err_list_regime", c("d"))),
  zeile("sim_err_list_trading",
    r"(simulation(d, list(A = list(asset_class = 'etf', trading = 'hold', share = 1))))",
    r"(result = simlev.simulation(d, {'A': {'asset_class': 'etf', 'trading': 'hold', 'share': 1}}))",
    r"(result = SL.simulation(d, Dict("A" => Dict("asset_class" => "etf", "trading" => "hold", "share" => 1))))", inp = ein("wrapper/sim_err_list_trading", c("d"))),
  zeile("sim_err_rf_col",
    r"(simulation(d, create_strategy(A = asset_config()), risk_free = 'rf'))",
    r"(result = simlev.simulation(d, create_strategy(A=asset_config()), risk_free='rf'))",
    r"(result = SL.simulation(d, SL.create_strategy("A" => SL.asset_config()); risk_free = "rf"))", inp = ein("wrapper/sim_err_rf_col", c("d"))),
  zeile("sim_rf_col_frac",
    r"(x <- d; x$rf <- 0.01; simulation(x, create_strategy(A = asset_config()), risk_free = 'rf')$statistics)",
    r"(x = d.copy(); x['rf'] = 0.01; result = simlev.simulation(x, create_strategy(A=asset_config()), risk_free='rf')['statistics'])",
    r"(x = copy(d); x["rf"] = fill(0.01, SL.nrow(x)); result = SL.simulation(x, SL.create_strategy("A" => SL.asset_config()); risk_free = "rf")["statistics"])", inp = ein("wrapper/sim_rf_col_frac", c("d")))))
TB("asset_config", "Meldungen und Warnungen von asset_config je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("err_wrapper_class",
    r"(asset_config(wrapper = list(strategy = inner)))",
    r"(result = asset_config(wrapper={'strategy': inner}))",
    r"(result = SL.asset_config(; wrapper = RList("strategy" => inner)))", inp = ein("wrapper/err_wrapper_class", c())),
  zeile("cfg_etn_standard",
    r"(asset_config('etn_standard'))",
    r"(result = asset_config(asset_class='etn_standard'))",
    r"(result = SL.asset_config("etn_standard"))", print = TRUE, inp = ein("wrapper/cfg_etn_standard", c())),
  zeile("cfg_etn_deliverable",
    r"(asset_config('etn_deliverable'))",
    r"(result = asset_config(asset_class='etn_deliverable'))",
    r"(result = SL.asset_config("etn_deliverable"))", print = TRUE, inp = ein("wrapper/cfg_etn_deliverable", c())),
  zeile("cfg_err_share",
    r"(asset_config(share = 1.5))",
    r"(result = asset_config(share=1.5))",
    r"(result = SL.asset_config(; share = 1.5))", inp = ein("wrapper/cfg_err_share", c())),
  zeile("cfg_err_share_150",   # ohne Hinweis über 100 (Entscheidung 12; seit 1.6.4, K43 KE)
    r"(asset_config(share = 150))",
    r"(result = asset_config(share=150))",
    r"(result = SL.asset_config(; share = 150))", inp = ein("wrapper/cfg_err_share", c())),
  zeile("cfg_err_spread",
    r"(asset_config(spread = -1))",
    r"(result = asset_config(spread=-1))",
    r"(result = SL.asset_config(; spread = -1))", inp = ein("wrapper/cfg_err_spread", c())),
  zeile("cfg_err_signal",
    r"(asset_config('etf', 'signal'))",
    r"(result = asset_config(asset_class='etf', trading='signal'))",
    r"(result = SL.asset_config("etf", "signal"))", inp = ein("wrapper/cfg_err_signal", c())),
  zeile("cfg_err_regime",
    r"(asset_config(tax_regime = 'none'))",
    r"(result = asset_config(tax_regime='none'))",
    r"(result = SL.asset_config(; tax_regime = "none"))", inp = ein("wrapper/cfg_err_regime", c()))))
TB("strategy_validate", "Meldungen und Warnungen von strategy_validate je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("err_collision_validate",
    r"(strategy_validate(create_strategy(Z = asset_config(wrapper = wb)), dz))",
    r"(result = simlev.strategy_validate(create_strategy(Z=asset_config(wrapper=wb)), data=dz))",
    r"(result = SL.strategy_validate(SL.create_strategy("Z" => SL.asset_config(; wrapper = wb)), dz))", inp = ein("wrapper/err_collision_validate", c("dz"))),
  zeile("sv_err_class",
    r"(strategy_validate(list(A = asset_config())))",
    r"(result = simlev.strategy_validate({'A': asset_config()}))",
    r"(result = SL.strategy_validate(Dict("A" => SL.asset_config())))", inp = ein("wrapper/sv_err_class", c())),
  zeile("sv_err_col",
    r"(strategy_validate(create_strategy(X = asset_config()), d))",
    r"(result = simlev.strategy_validate(create_strategy(X=asset_config()), data=d))",
    r"(result = SL.strategy_validate(SL.create_strategy("X" => SL.asset_config()), d))", inp = ein("wrapper/sv_err_col", c("d"))),
  zeile("sv_err_signal_col",
    r"(strategy_validate(create_strategy(A = asset_config('etf', 'signal', signal_buy = 'kauf', signal_sell = 'sell')), d))",
    r"(result = simlev.strategy_validate(create_strategy(A=asset_config(asset_class='etf', trading='signal', signal_buy='kauf', signal_sell='sell')), data=d))",
    r"(result = SL.strategy_validate(SL.create_strategy("A" => SL.asset_config("etf", "signal"; signal_buy = "kauf", signal_sell = "sell")), d))", inp = ein("wrapper/sv_err_signal_col", c("d")))))
TB("rebalance_trigger", "Meldungen und Warnungen von rebalance_trigger je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("trig_err_col",
    r"(rebalance_trigger(tdf, 'vol_band', vol_col = 'vola'))",
    r"(result = simlev.rebalance_trigger(tdf, 'vol_band', vol_col='vola'))",
    r"(result = SL.rebalance_trigger(tdf, "vol_band"; vol_col = "vola"))", inp = ein("wrapper/trig_err_col", c("tdf")))))
TB("strategy_remove_asset", "Meldungen und Warnungen von strategy_remove_asset je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("st_remove_empty",
    r"(length(strategy_remove_asset(create_strategy(A = asset_config()), 'A')))",
    r"(result = len(simlev.strategy_remove_asset(create_strategy(A=asset_config()), 'A')))",
    r"(result = length(SL.strategy_remove_asset(SL.create_strategy("A" => SL.asset_config()), "A")))", inp = ein("wrapper/st_remove_empty", c())),
  zeile("st_remove_err",
    r"(strategy_remove_asset(create_strategy(A = asset_config()), 'X'))",
    r"(result = simlev.strategy_remove_asset(create_strategy(A=asset_config()), 'X'))",
    r"(result = SL.strategy_remove_asset(SL.create_strategy("A" => SL.asset_config()), "X"))", inp = ein("wrapper/st_remove_err", c()))))
TB("create_strategy", "Meldungen und Warnungen von create_strategy je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("st_err_both",
    r"(create_strategy(A = asset_config(), assets = list(B = asset_config())))",
    r"(result = create_strategy(A=asset_config(), assets={'B': asset_config()}))",
    r"(result = SL.create_strategy("A" => SL.asset_config(); assets = Dict("B" => SL.asset_config())))", inp = ein("wrapper/st_err_both", c())),
  zeile("st_err_empty",
    r"(create_strategy())",
    r"(result = create_strategy())",
    r"(result = SL.create_strategy())", inp = ein("wrapper/st_err_empty", c())),
  zeile("st_err_unnamed",
    r"(create_strategy(asset_config()))",
    r"(result = create_strategy(asset_config()))",
    r"(result = SL.create_strategy(SL.asset_config()))", inp = ein("wrapper/st_err_unnamed", c())),
  zeile("st_err_type",
    r"(create_strategy(A = 1))",
    r"(result = create_strategy(A=1))",
    r"(result = SL.create_strategy("A" => 1.0))", inp = ein("wrapper/st_err_type", c()))))
TB("strategy_update_asset", "Meldungen und Warnungen von strategy_update_asset je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("su_err_name",
    r"(strategy_update_asset(create_strategy(A = asset_config()), 'X', share = 1))",
    r"(result = simlev.strategy_update_asset(create_strategy(A=asset_config()), 'X', share=1))",
    r"(result = SL.strategy_update_asset(SL.create_strategy("A" => SL.asset_config()), "X"; share = 1))", inp = ein("wrapper/su_err_name", c())),
  zeile("su_warn_param",
    r"(strategy_update_asset(create_strategy(A = asset_config()), 'A', foo = 1))",
    r"(result = simlev.strategy_update_asset(create_strategy(A=asset_config()), 'A', foo=1))",
    r"(result = SL.strategy_update_asset(SL.create_strategy("A" => SL.asset_config()), "A"; foo = 1))", print = TRUE, inp = ein("wrapper/su_warn_param", c()))))
TB("tax_profile", "Meldungen und Warnungen von tax_profile je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("tp_church_frac",
    r"(tax_profile(church_tax = 0.09))",
    r"(result = tax_profile(church_tax=0.09))",
    r"(result = SL.tax_profile(; church_tax = 0.09))", print = TRUE, inp = ein("wrapper/tp_church_frac", c()))))
ref_done()

ref_init("wrapper", gruppe = "ausgabe")
TB("create_strategy", "Druckausgabe von create_strategy je Zeile", vor = VOR, zeilen = list(
  zeile("st_summary",
    r"(summary(create_strategy(A = asset_config('etf', share = 0.6), B = asset_config('etc', 'signal', 0.4, signal_buy = 'b', signal_sell = 's', spread = 0.1))); NULL)",
    r"(create_strategy(A=asset_config(asset_class='etf', share=0.6), B=asset_config(asset_class='etc', trading='signal', share=0.4, signal_buy='b', signal_sell='s', spread=0.1)).summary(); result = None)",
    r"(summary(SL.create_strategy("A" => SL.asset_config("etf"; share = 0.6), "B" => SL.asset_config("etc", "signal", 0.4; signal_buy = "b", signal_sell = "s", spread = 0.1))); result = nothing)", inp = ein("wrapper/st_summary", c()))))
ref_done()

ref_schreiben()
