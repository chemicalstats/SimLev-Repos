# Referenzfälle für den Fonds-Wrapper (wrapper.R, Etappe 6.5c): wrapper_config, asset_config(wrapper = ),
# wrapper_nav (Anteilswert mit täglicher Verwaltungsgebühr und Performancegebühr über der High-Water-Mark),
# simulation() mit Wrapper-Assets (Zertifikat, Investmentfonds mit Vorabpauschale, Kirchensteuer, Sparplan,
# gemischtes Depot, Splits, details), Aufrufer (bootstrap_study, param_search, sensitivity_grid,
# planning_lumpsum_vs_dca, withdrawal_simulation), Fehler, Hinweise und Druck.
#
# Aufruf aus der Repo-Wurzel:
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript golden/modules/gen_wrapper.R
source("golden/modules/ref_tools.R"); ref_init("wrapper")

# ── Daten ───────────────────────────────────────────────────────────────────
set.seed(11); n <- 640
d <- data.frame(date = seq.Date(as.Date("2019-11-04"), by = "day", length.out = n))
d$A <- 100 * cumprod(1 + rnorm(n, 4e-4, 0.011)); d$B <- 50 * cumprod(1 + rnorm(n, 1e-4, 0.004))
d$C <- 80 * cumprod(1 + rnorm(n, 2e-4, 0.006))
d$buy <- c(FALSE, diff(d$A) > 0); d$sell <- !d$buy
d$ev <- seq_len(n) %% 90 == 0
dw <- d[!format(d$date, "%u") %in% c("6", "7"), ]; rownames(dw) <- NULL           # nur Werktage
dn <- d; dn[c(40:42, 300), c("A", "B")] <- NA; dn$A[200:204] <- NA                 # NA-Tage
dg <- d; dg$B[1:30] <- NA                                                          # gestaffelter innerer Start
dl <- d; dl[1:12, c("A", "B")] <- NA                                               # Anteilswert beginnt später
dsp <- d; dsp$A <- 100 * cumprod(1 + rnorm(n, 2.5e-3, 0.01))                       # Split auf innerer Spalte
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
case <- function(id, r, p, j, inputs = I, print = NA, note = NULL)
  ref_case(id, paste0(R0, r), paste0(P0, p), inputs, print = print, note = note, jl = paste0(J0, j))

# Meldungen (message) als Ergebnis: Texte ohne abschließenden Zeilenumbruch
MR <- function(expr) sprintf("m <- character(0); invisible(withCallingHandlers(%s, message = function(e) { m <<- c(m, sub('\\n$', '', conditionMessage(e))); invokeRestart('muffleMessage') })); m", expr)
MP <- function(expr) sprintf("import io, contextlib\nbuf = io.StringIO()\nwith contextlib.redirect_stderr(buf):\n    _x = %s\nresult = buf.getvalue().splitlines()", expr)
MJ <- function(expr) sprintf('result = mktemp() do path, io\n    redirect_stderr(io) do\n        %s\n    end\n    flush(io)\n    String.(split(chomp(read(path, String)), "\\n"))\nend', expr)

# ── wrapper_nav ─────────────────────────────────────────────────────────────
case("nav_cost0", "wrapper_nav(d, w0)", "result = wrapper_nav(d, w0)", "result = SL.wrapper_nav(d, w0)", note = "Kosten 0: nav = gross")
case("nav_fee", "wrapper_nav(d, wf)", "result = wrapper_nav(d, wf)", "result = SL.wrapper_nav(d, wf)", note = "nur Verwaltungsgebühr")
case("nav_perf", "wrapper_nav(d, wp)", "result = wrapper_nav(d, wp)", "result = SL.wrapper_nav(d, wp)", note = "nur Performancegebühr")
case("nav_both", "wrapper_nav(d, wb)", "result = wrapper_nav(d, wb)", "result = SL.wrapper_nav(d, wb)", note = "beides, inneres Umschichten je Quartal")
case("nav_hand", "wrapper_nav(dh, wrapper_config(inner, costs = funds_costs(1, 20)))",
     "result = wrapper_nav(dh, wrapper_config(inner, costs=funds_costs(fee=1, performance_fee=20)))",
     "result = SL.wrapper_nav(dh, SL.wrapper_config(inner; costs = SL.funds_costs(1, 20)))",
     note = "Handbeispiel: Schaltjahr 2020, Jahreswechsel, Lücken über Wochenenden und Monate")
case("nav_weekdays", "wrapper_nav(dw, wb)", "result = wrapper_nav(dw, wb)", "result = SL.wrapper_nav(dw, wb)", note = "Wochenenden: Gebühr über die Kalendertage")
case("nav_pct_fee", "wrapper_nav(d, wrapper_config(inner, rebalance = rebalance_plan(), order_fee = list(percent = 0.1)))",
     "result = wrapper_nav(d, wrapper_config(inner, rebalance=rebalance_plan(), order_fee={'percent': 0.1}))",
     'result = SL.wrapper_nav(d, SL.wrapper_config(inner; rebalance = SL.rebalance_plan(), order_fee = (percent = 0.1,)))')
case("nav_fixed_fee", "wrapper_nav(d, wrapper_config(inner, rebalance = rebalance_plan(), costs = funds_costs(0.5, 5), order_fee = 5, volume = 1e5))",
     "result = wrapper_nav(d, wrapper_config(inner, rebalance=rebalance_plan(), costs=funds_costs(fee=0.5, performance_fee=5), order_fee=5, volume=1e5))",
     'result = SL.wrapper_nav(d, SL.wrapper_config(inner; rebalance = SL.rebalance_plan(), costs = SL.funds_costs(0.5, 5), order_fee = 5, volume = 1e5))')
case("nav_minmax", "wrapper_nav(d, wrapper_config(inner, rebalance = rebalance_plan(), order_fee = list(percent = 0.05, min = 2, max = 4), volume = 2e4))",
     "result = wrapper_nav(d, wrapper_config(inner, rebalance=rebalance_plan(), order_fee={'percent': 0.05, 'min': 2, 'max': 4}, volume=2e4))",
     'result = SL.wrapper_nav(d, SL.wrapper_config(inner; rebalance = SL.rebalance_plan(), order_fee = (percent = 0.05, min = 2, max = 4), volume = 2e4))')
case("nav_event", "wrapper_nav(d, wrapper_config(inner, rebalance = rebalance_plan(event_col = 'ev', event_mode = 'replace')))",
     "result = wrapper_nav(d, wrapper_config(inner, rebalance=rebalance_plan(event_col='ev', event_mode='replace')))",
     'result = SL.wrapper_nav(d, SL.wrapper_config(inner; rebalance = SL.rebalance_plan(; event_col = "ev", event_mode = "replace")))')
case("nav_signal", "wrapper_nav(d, wrapper_config(create_strategy(A = asset_config('etf', 'signal', 0.5, signal_buy = 'buy', signal_sell = 'sell'), B = asset_config('etf', 'bnh', 0.5)), costs = funds_costs(0.8, 15)))",
     "result = wrapper_nav(d, wrapper_config(create_strategy(A=asset_config(asset_class='etf', trading='signal', share=0.5, signal_buy='buy', signal_sell='sell'), B=asset_config(asset_class='etf', trading='bnh', share=0.5)), costs=funds_costs(fee=0.8, performance_fee=15)))",
     'result = SL.wrapper_nav(d, SL.wrapper_config(SL.create_strategy("A" => SL.asset_config("etf", "signal", 0.5; signal_buy = "buy", signal_sell = "sell"), "B" => SL.asset_config("etf", "bnh", 0.5)); costs = SL.funds_costs(0.8, 15)))',
     note = "innere Signale")
case("nav_staggered", "wrapper_nav(dg, wb)", "result = wrapper_nav(dg, wb)", "result = SL.wrapper_nav(dg, wb)", note = "gestaffelter innerer Start")
case("nav_na_days", "wrapper_nav(dn, wb)", "result = wrapper_nav(dn, wb)", "result = SL.wrapper_nav(dn, wb)", note = "NA-Tage: ohne inneren Kurs kein Anteilswert")
case("nav_split", "wrapper_nav(dsp, wb, splits = split_rule(c(50, 150)))", "result = wrapper_nav(dsp, wb, splits=split_rule([50, 150]))",
     'result = SL.wrapper_nav(dsp, wb; splits = SL.split_rule([50, 150]))', note = "Split auf innerer Spalte")
case("nav_one_day", "wrapper_nav(d1, wb)", "result = wrapper_nav(d1, wb)", "result = SL.wrapper_nav(d1, wb)", note = "ein einziger Tag")
case("nav_two_days", "wrapper_nav(dh[5:6, ], wb)", "result = wrapper_nav(dh.iloc[4:6].reset_index(drop=True), wb)",
     "result = SL.wrapper_nav(SL.rows(dh, 5:6), wb)", note = "Jahreswechsel am vorletzten Tag: Festschreibung")
case("nav_unsorted", "wrapper_nav(du, wf)", "result = wrapper_nav(du, wf)", "result = SL.wrapper_nav(du, wf)")
case("nav_inner_spread", "wrapper_nav(d, suppressMessages(wrapper_config(create_strategy(A = asset_config('etf', 'bnh', 0.6, spread = 0.4), B = asset_config('etf', 'bnh', 0.4, spread = 0.2)), rebalance = rebalance_plan())))",
     "result = wrapper_nav(d, wrapper_config(create_strategy(A=asset_config(asset_class='etf', trading='bnh', share=0.6, spread=0.4), B=asset_config(asset_class='etf', trading='bnh', share=0.4, spread=0.2)), rebalance=rebalance_plan()))",
     'result = SL.wrapper_nav(d, SL.wrapper_config(SL.create_strategy("A" => SL.asset_config("etf", "bnh", 0.6; spread = 0.4), "B" => SL.asset_config("etf", "bnh", 0.4; spread = 0.2)); rebalance = SL.rebalance_plan()))',
     note = "innerer Spread gilt")
case("nav_inner_result", "x <- attr(wrapper_nav(d, wb), 'inner'); list(x$worth[c(1, 100, 640)], x$report$A$worth[c(1, 300)])",
     "x = wrapper_nav(d, wb).attrs['inner']; result = [x.worth[[0, 99, 639]], x.report['A']['worth'][[0, 299]]]",
     'x = SL.attrs(SL.wrapper_nav(d, wb))["inner"]; result = [x.worth[[1, 100, 640]], x.report["A"]["worth"][[1, 300]]]',
     note = "Attribut inner: inneres Ergebnis")

# ── simulation() mit Wrapper-Assets ─────────────────────────────────────────
case("sim_cert", "simulation(d, create_strategy(Z = asset_config('certificate', wrapper = wb)))",
     "result = simlev.simulation(d, create_strategy(Z=asset_config(asset_class='certificate', wrapper=wb)))",
     'result = SL.simulation(d, SL.create_strategy("Z" => SL.asset_config("certificate"; wrapper = wb)))')
case("sim_plausible", "r1 <- simulation(d, create_strategy(Z = asset_config('certificate', wrapper = w0))); r2 <- simulation(d, inner); c(tail(r1$worth, 1), tail(r2$worth, 1))",
     "r1 = simlev.simulation(d, create_strategy(Z=asset_config(asset_class='certificate', wrapper=w0))); r2 = simlev.simulation(d, inner); result = [r1.worth[-1], r2.worth[-1]]",
     'r1 = SL.simulation(d, SL.create_strategy("Z" => SL.asset_config("certificate"; wrapper = w0))); r2 = SL.simulation(d, inner); result = [r1.worth[end], r2.worth[end]]',
     note = "Plausibilität: Kosten und Spreads 0, ohne Steuern = innere Strategie")
case("sim_cert_tax", "simulation(d, create_strategy(Z = asset_config('certificate', spread = 0.3, wrapper = wb)), tax = tax_profile(sparer_pauschbetrag = 100), liquidate = TRUE)",
     "result = simlev.simulation(d, create_strategy(Z=asset_config(asset_class='certificate', spread=0.3, wrapper=wb)), tax=tax_profile(sparer_pauschbetrag=100), liquidate=True)",
     'result = SL.simulation(d, SL.create_strategy("Z" => SL.asset_config("certificate"; spread = 0.3, wrapper = wb)); tax = SL.tax_profile(; sparer_pauschbetrag = 100), liquidate = true)',
     note = "Zertifikat: Kapitalforderung, Steuer erst beim Verkauf")
case("sim_fund_vp", "simulation(d, create_strategy(Z = asset_config('certificate', tax_regime = 'investment_fund', partial_exemption = 30, wrapper = wb)), tax = tax_profile(sparer_pauschbetrag = 0, base_rate = 2.29))",
     "result = simlev.simulation(d, create_strategy(Z=asset_config(asset_class='certificate', tax_regime='investment_fund', partial_exemption=30, wrapper=wb)), tax=tax_profile(sparer_pauschbetrag=0, base_rate=2.29))",
     'result = SL.simulation(d, SL.create_strategy("Z" => SL.asset_config("certificate"; tax_regime = "investment_fund", partial_exemption = 30, wrapper = wb)); tax = SL.tax_profile(; sparer_pauschbetrag = 0, base_rate = 2.29))',
     note = "Investmentfonds mit Teilfreistellung und Vorabpauschale")
case("sim_church", "simulation(d, create_strategy(Z = asset_config('etf', partial_exemption = 30, wrapper = wb)), tax = tax_profile(church_tax = 8, sparer_pauschbetrag = 200, base_rate = 1.5), liquidate = TRUE)",
     "result = simlev.simulation(d, create_strategy(Z=asset_config(asset_class='etf', partial_exemption=30, wrapper=wb)), tax=tax_profile(church_tax=8, sparer_pauschbetrag=200, base_rate=1.5), liquidate=True)",
     'result = SL.simulation(d, SL.create_strategy("Z" => SL.asset_config("etf"; partial_exemption = 30, wrapper = wb)); tax = SL.tax_profile(; church_tax = 8, sparer_pauschbetrag = 200, base_rate = 1.5), liquidate = true)',
     note = "Kirchensteuer")
case("sim_dca", "simulation(d, create_strategy(Z = asset_config('etf', spread = 0.5, partial_exemption = 30, wrapper = wb)), start_value = 2000, dca = dca_plan(150, 1, days = 15), costs = sim_costs(order_fee = list(fixed = 1, percent = 0.25), dca_fee = 0.5), tax = tax_profile())",
     "result = simlev.simulation(d, create_strategy(Z=asset_config(asset_class='etf', spread=0.5, partial_exemption=30, wrapper=wb)), start_value=2000, dca=dca_plan(150, 1, days=15), costs=sim_costs(order_fee={'fixed': 1, 'percent': 0.25}, dca_fee=0.5), tax=tax_profile())",
     'result = SL.simulation(d, SL.create_strategy("Z" => SL.asset_config("etf"; spread = 0.5, partial_exemption = 30, wrapper = wb)); start_value = 2000, dca = SL.dca_plan(150, 1; days = 15), costs = SL.sim_costs(; order_fee = (fixed = 1, percent = 0.25), dca_fee = 0.5), tax = SL.tax_profile())',
     note = "Sparplan mit dca_fee, äußerer Spread")
case("sim_mixed", "simulation(d, create_strategy(Z = asset_config('certificate', share = 0.7, spread = 0.2, wrapper = wb), C = asset_config('etf', 'bnh', 0.3, spread = 0.1, partial_exemption = 30)), rebalance = rebalance_plan(unit = 'year', thresh = 1), tax = tax_profile())",
     "result = simlev.simulation(d, create_strategy(Z=asset_config(asset_class='certificate', share=0.7, spread=0.2, wrapper=wb), C=asset_config(asset_class='etf', trading='bnh', share=0.3, spread=0.1, partial_exemption=30)), rebalance=rebalance_plan(unit='year', thresh=1), tax=tax_profile())",
     'result = SL.simulation(d, SL.create_strategy("Z" => SL.asset_config("certificate"; share = 0.7, spread = 0.2, wrapper = wb), "C" => SL.asset_config("etf", "bnh", 0.3; spread = 0.1, partial_exemption = 30)); rebalance = SL.rebalance_plan(; unit = "year", thresh = 1), tax = SL.tax_profile())',
     note = "gemischtes Depot mit äußerem Umschichten")
case("sim_two_wrappers", "w2 <- wrapper_config(create_strategy(C = asset_config('etf', 'bnh', 0.5), B = asset_config('etf', 'bnh', 0.5)), costs = funds_costs(0.2, 0)); simulation(d, create_strategy(Z = asset_config('certificate', share = 0.5, wrapper = wb), Y = asset_config('etf', 'bnh', 0.5, partial_exemption = 15, wrapper = w2)), rebalance = rebalance_plan(unit = 'quarter'), tax = tax_profile(base_rate = 1))",
     "w2 = wrapper_config(create_strategy(C=asset_config(asset_class='etf', trading='bnh', share=0.5), B=asset_config(asset_class='etf', trading='bnh', share=0.5)), costs=funds_costs(fee=0.2, performance_fee=0)); result = simlev.simulation(d, create_strategy(Z=asset_config(asset_class='certificate', share=0.5, wrapper=wb), Y=asset_config(asset_class='etf', trading='bnh', share=0.5, partial_exemption=15, wrapper=w2)), rebalance=rebalance_plan(unit='quarter'), tax=tax_profile(base_rate=1))",
     'w2 = SL.wrapper_config(SL.create_strategy("C" => SL.asset_config("etf", "bnh", 0.5), "B" => SL.asset_config("etf", "bnh", 0.5)); costs = SL.funds_costs(0.2, 0)); result = SL.simulation(d, SL.create_strategy("Z" => SL.asset_config("certificate"; share = 0.5, wrapper = wb), "Y" => SL.asset_config("etf", "bnh", 0.5; partial_exemption = 15, wrapper = w2)); rebalance = SL.rebalance_plan(; unit = "quarter"), tax = SL.tax_profile(; base_rate = 1))')
case("sim_liquidate", "simulation(dw, create_strategy(Z = asset_config('certificate', spread = 0.4, wrapper = wb)), costs = sim_costs(order_fee = 2), tax = tax_profile(sparer_pauschbetrag = 0), liquidate = TRUE)",
     "result = simlev.simulation(dw, create_strategy(Z=asset_config(asset_class='certificate', spread=0.4, wrapper=wb)), costs=sim_costs(order_fee=2), tax=tax_profile(sparer_pauschbetrag=0), liquidate=True)",
     'result = SL.simulation(dw, SL.create_strategy("Z" => SL.asset_config("certificate"; spread = 0.4, wrapper = wb)); costs = SL.sim_costs(; order_fee = 2), tax = SL.tax_profile(; sparer_pauschbetrag = 0), liquidate = true)',
     note = "Werktagsdaten, liquidate = TRUE")
case("sim_details", "simulation(d[1:120, ], create_strategy(Z = asset_config('certificate', share = 0.8, wrapper = wb), C = asset_config('etf', 'bnh', 0.2)), rebalance = rebalance_plan(), details = TRUE)",
     "result = simlev.simulation(d.iloc[:120], create_strategy(Z=asset_config(asset_class='certificate', share=0.8, wrapper=wb), C=asset_config(asset_class='etf', trading='bnh', share=0.2)), rebalance=rebalance_plan(), details=True)",
     'result = SL.simulation(SL.rows(d, 1:120), SL.create_strategy("Z" => SL.asset_config("certificate"; share = 0.8, wrapper = wb), "C" => SL.asset_config("etf", "bnh", 0.2)); rebalance = SL.rebalance_plan(), details = true)',
     note = "details = TRUE: result$wrappers und Protokoll")
case("sim_late", "simulation(dl, create_strategy(Z = asset_config('certificate', share = 0.5, wrapper = wb), C = asset_config('etf', 'bnh', 0.5)))",
     "result = simlev.simulation(dl, create_strategy(Z=asset_config(asset_class='certificate', share=0.5, wrapper=wb), C=asset_config(asset_class='etf', trading='bnh', share=0.5)))",
     'result = SL.simulation(dl, SL.create_strategy("Z" => SL.asset_config("certificate"; share = 0.5, wrapper = wb), "C" => SL.asset_config("etf", "bnh", 0.5)))',
     note = "Anteilswert beginnt später: wie ein später startendes Asset")
case("sim_late_msg", MR("simulation(dl, create_strategy(Z = asset_config('certificate', share = 0.5, wrapper = wb), C = asset_config('etf', 'bnh', 0.5)))"),
     MP("simlev.simulation(dl, create_strategy(Z=asset_config(asset_class='certificate', share=0.5, wrapper=wb), C=asset_config(asset_class='etf', trading='bnh', share=0.5)))"),
     MJ('SL.simulation(dl, SL.create_strategy("Z" => SL.asset_config("certificate"; share = 0.5, wrapper = wb), "C" => SL.asset_config("etf", "bnh", 0.5)))'))
case("sim_na_msg", MR("simulation(dn, create_strategy(Z = asset_config('certificate', wrapper = wb)))"),
     MP("simlev.simulation(dn, create_strategy(Z=asset_config(asset_class='certificate', wrapper=wb)))"),
     MJ('SL.simulation(dn, SL.create_strategy("Z" => SL.asset_config("certificate"; wrapper = wb)))'),
     note = "Meldungen: innere Rechnung mit Präfix, NAV-Lücken per LOCF")
case("sim_splits", "simulation(dsp, create_strategy(Z = asset_config('certificate', share = 0.5, wrapper = wb), A = asset_config('etf', 'bnh', 0.5)), splits = split_rule(c(50, 150)), fractions = FALSE, tax = tax_profile())",
     "result = simlev.simulation(dsp, create_strategy(Z=asset_config(asset_class='certificate', share=0.5, wrapper=wb), A=asset_config(asset_class='etf', trading='bnh', share=0.5)), splits=split_rule([50, 150]), fractions=False, tax=tax_profile())",
     'result = SL.simulation(dsp, SL.create_strategy("Z" => SL.asset_config("certificate"; share = 0.5, wrapper = wb), "A" => SL.asset_config("etf", "bnh", 0.5)); splits = SL.split_rule([50, 150]), fractions = false, tax = SL.tax_profile())',
     note = "Splits innen und für das direkte Asset A, nicht für den Anteilswert")
case("sim_harvest", "simulation(d, create_strategy(Z = asset_config('etf', partial_exemption = 30, wrapper = wb)), tax = tax_profile(harvest = harvest_rule()))",
     "result = simlev.simulation(d, create_strategy(Z=asset_config(asset_class='etf', partial_exemption=30, wrapper=wb)), tax=tax_profile(harvest=harvest_rule()))",
     'result = SL.simulation(d, SL.create_strategy("Z" => SL.asset_config("etf"; partial_exemption = 30, wrapper = wb)); tax = SL.tax_profile(; harvest = SL.harvest_rule()))')
case("sim_list_strategy", "simulation(d, list(Z = list(asset_class = 'certificate', trading = 'bnh', share = 1, wrapper = wf)))",
     "result = simlev.simulation(d, {'Z': {'asset_class': 'certificate', 'trading': 'bnh', 'share': 1, 'wrapper': wf}})",
     'result = SL.simulation(d, RList("Z" => RList("asset_class" => "certificate", "trading" => "bnh", "share" => 1, "wrapper" => wf)))',
     note = "Strategie als einfache Liste")
case("sim_one_day", "simulation(d1, create_strategy(Z = asset_config('certificate', wrapper = wb)))",
     "result = simlev.simulation(d1, create_strategy(Z=asset_config(asset_class='certificate', wrapper=wb)))",
     'result = SL.simulation(d1, SL.create_strategy("Z" => SL.asset_config("certificate"; wrapper = wb)))',
     note = "ein Tag: Warnungen der inneren Rechnung mit Präfix")

# ── Aufrufer ────────────────────────────────────────────────────────────────
BS_R <- "cfg <- bootstrap_config(c(A = 'A', B = 'B'), input = 'prices'); strats <- list(wrap = create_strategy(Z = asset_config('certificate', spread = 0.2, wrapper = wb)), direct = inner)\n"
BS_P <- "cfg = simlev.bootstrap_config({'A': 'A', 'B': 'B'}, input='prices'); strats = {'wrap': create_strategy(Z=asset_config(asset_class='certificate', spread=0.2, wrapper=wb)), 'direct': inner}\n"
BS_J <- 'cfg = SL.bootstrap_config((A = "A", B = "B"); input = "prices"); strats = (wrap = SL.create_strategy("Z" => SL.asset_config("certificate"; spread = 0.2, wrapper = wb)), direct = inner)\n'
case("bs_cores1", paste0(BS_R, "st <- bootstrap_study(d, cfg, 'stationary', n = 3, params = list(L = 30), path_length = 300, seed = 5, progress = FALSE, strategies = strats, benchmark = 'direct', cores = 1); st$elapsed <- 0; st"),
     paste0(BS_P, "st = simlev.bootstrap_study(d, cfg, 'stationary', n=3, params={'L': 30}, path_length=300, seed=5, progress=False, strategies=strats, benchmark='direct', cores=1); st['elapsed'] = 0; result = st"),
     paste0(BS_J, 'st = SL.bootstrap_study(d, cfg, "stationary"; n = 3, params = (L = 30,), path_length = 300, seed = 5, progress = false, strategies = strats, benchmark = "direct", cores = 1); st["elapsed"] = 0; result = st'),
     note = "Bootstrap zieht die inneren Spalten; der Anteilswert wird je Pfad neu gerechnet")
case("bs_cores2", paste0(BS_R, "st <- bootstrap_study(d, cfg, 'stationary', n = 3, params = list(L = 30), path_length = 300, seed = 5, progress = FALSE, strategies = strats, benchmark = 'direct', cores = 2); st$elapsed <- 0; st"),
     paste0(BS_P, "st = simlev.bootstrap_study(d, cfg, 'stationary', n=3, params={'L': 30}, path_length=300, seed=5, progress=False, strategies=strats, benchmark='direct', cores=2); st['elapsed'] = 0; result = st"),
     paste0(BS_J, 'st = SL.bootstrap_study(d, cfg, "stationary"; n = 3, params = (L = 30,), path_length = 300, seed = 5, progress = false, strategies = strats, benchmark = "direct", cores = 2); st["elapsed"] = 0; result = st'))
case("ps_builder", "b <- function(p) list(strategy = create_strategy(Z = asset_config('certificate', wrapper = wrapper_config(inner, costs = funds_costs(fee = p$fee, performance_fee = p$pf))))); ps <- param_search(d, b, param_space(fee = c(0, 0.5, 1.5), pf = c(0, 20)), objective = 'cagr'); ps$results$elapsed <- 0; ps$elapsed <- 0; ps$results",
     "def b(p):\n    return {'strategy': create_strategy(Z=asset_config(asset_class='certificate', wrapper=wrapper_config(inner, costs=funds_costs(fee=p['fee'], performance_fee=p['pf']))))}\nps = simlev.param_search(d, b, simlev.param_space(fee=[0.0, 0.5, 1.5], pf=[0.0, 20.0]), objective='cagr'); ps['results']['elapsed'] = 0.0; result = ps['results']",
     'b(p) = RList("strategy" => SL.create_strategy("Z" => SL.asset_config("certificate"; wrapper = SL.wrapper_config(inner; costs = SL.funds_costs(; fee = p["fee"], performance_fee = p["pf"]))))); ps = SL.param_search(d, b, SL.param_space(fee = [0.0, 0.5, 1.5], pf = [0.0, 20.0]); objective = "cagr"); ps["results"]["elapsed"] = 0.0; result = ps["results"]',
     note = "param_search: builder baut den Wrapper")
case("sg_grid", "sensitivity_grid(d, create_strategy(Z = asset_config('etf', partial_exemption = 30, wrapper = wb)), list(start_value = c(1000, 5000), tax.base_rate = c(0, 2)), sim_args = list(tax = tax_profile()))",
     "result = simlev.sensitivity_grid(d, create_strategy(Z=asset_config(asset_class='etf', partial_exemption=30, wrapper=wb)), {'start_value': [1000.0, 5000.0], 'tax.base_rate': [0.0, 2.0]}, sim_args={'tax': tax_profile()})",
     'result = SL.sensitivity_grid(d, SL.create_strategy("Z" => SL.asset_config("etf"; partial_exemption = 30, wrapper = wb)), RList("start_value" => [1000.0, 5000.0], "tax.base_rate" => [0.0, 2.0]); sim_args = RList("tax" => SL.tax_profile()))')
case("pl_lumpsum", "planning_lumpsum_vs_dca(d, create_strategy(Z = asset_config('certificate', share = 0.6, wrapper = wb), C = asset_config('etf', 'bnh', 0.4)), amount = 1200, months = 4, horizon = 1, step = 3)",
     "result = simlev.planning_lumpsum_vs_dca(d, create_strategy(Z=asset_config(asset_class='certificate', share=0.6, wrapper=wb), C=asset_config(asset_class='etf', trading='bnh', share=0.4)), amount=1200, months=4, horizon=1, step=3)",
     'result = SL.planning_lumpsum_vs_dca(d, SL.create_strategy("Z" => SL.asset_config("certificate"; share = 0.6, wrapper = wb), "C" => SL.asset_config("etf", "bnh", 0.4)); amount = 1200, months = 4, horizon = 1, step = 3)',
     note = "Kurs des Wrappers = Anteilswert im Fenster")
case("wd_nav", "ws <- withdrawal_simulation(wrapper_nav(d, wb), withdrawal_rule('percent', rate = 4), years = 1, frequency = 'quarter', start_value = 1e5); ws$paths",
     "ws = simlev.withdrawal_simulation(wrapper_nav(d, wb), rule=simlev.withdrawal_rule(type='percent', rate=4), years=1, frequency='quarter', start_value=1e5); result = ws['paths']",
     'ws = SL.withdrawal_simulation(SL.wrapper_nav(d, wb), SL.withdrawal_rule("percent"; rate = 4); years = 1, frequency = "quarter", start_value = 1e5); result = ws["paths"]',
     note = "SimLevWrapperNav als Renditequelle")
case("wd_lots", "r <- simulation(d, create_strategy(Z = asset_config('certificate', spread = 0.2, wrapper = wb)), tax = tax_profile()); ws <- withdrawal_simulation(wrapper_nav(d, wb), withdrawal_rule('constant', rate = 4), years = 1, frequency = 'quarter', start_value = r, tax = tax_profile()); list(r$open_lots, ws$paths)",
     "r = simlev.simulation(d, create_strategy(Z=asset_config(asset_class='certificate', spread=0.2, wrapper=wb)), tax=tax_profile()); ws = simlev.withdrawal_simulation(wrapper_nav(d, wb), rule=simlev.withdrawal_rule(type='constant', rate=4), years=1, frequency='quarter', start_value=r, tax=tax_profile()); result = [r.open_lots, ws['paths']]",
     'r = SL.simulation(d, SL.create_strategy("Z" => SL.asset_config("certificate"; spread = 0.2, wrapper = wb)); tax = SL.tax_profile()); ws = SL.withdrawal_simulation(SL.wrapper_nav(d, wb), SL.withdrawal_rule("constant"; rate = 4); years = 1, frequency = "quarter", start_value = r, tax = SL.tax_profile()); result = [r.open_lots, ws["paths"]]',
     note = "offene Bestände des Wrapper-Assets in die Entnahme")
case("st_validate", "strategy_validate(create_strategy(Z = asset_config('certificate', wrapper = wrapper_config(create_strategy(A = asset_config('etf', 'signal', signal_buy = 'buy', signal_sell = 'sell'))))), d)",
     "result = simlev.strategy_validate(create_strategy(Z=asset_config(asset_class='certificate', wrapper=wrapper_config(create_strategy(A=asset_config(asset_class='etf', trading='signal', signal_buy='buy', signal_sell='sell'))))), data=d)",
     'result = SL.strategy_validate(SL.create_strategy("Z" => SL.asset_config("certificate"; wrapper = SL.wrapper_config(SL.create_strategy("A" => SL.asset_config("etf", "signal"; signal_buy = "buy", signal_sell = "sell"))))), d)')
case("st_update", "st <- strategy_update_asset(create_strategy(Z = asset_config('etf', wrapper = wb)), 'Z', asset_class = 'certificate', spread = 0.5); list(st$Z$tax_regime, st$Z$spread, !is.null(st$Z$wrapper))",
     "st = simlev.strategy_update_asset(create_strategy(Z=asset_config(asset_class='etf', wrapper=wb)), 'Z', asset_class='certificate', spread=0.5); result = [st['Z']['tax_regime'], st['Z']['spread'], st['Z'].get('wrapper') is not None]",
     'st = SL.strategy_update_asset(SL.create_strategy("Z" => SL.asset_config("etf"; wrapper = wb)), "Z"; asset_class = "certificate", spread = 0.5); result = [st["Z"]["tax_regime"], st["Z"]["spread"], haskey(st["Z"], "wrapper")]')
case("st_update_add", "st <- strategy_update_asset(create_strategy(A = asset_config()), 'A', wrapper = wf); st2 <- strategy_update_asset(st, 'A', wrapper = NULL); list(names(st$A), names(st2$A))",
     "st = simlev.strategy_update_asset(create_strategy(A=asset_config()), 'A', wrapper=wf); st2 = simlev.strategy_update_asset(st, 'A', wrapper=None); result = [list(st['A'].keys()), list(st2['A'].keys())]",
     'st = SL.strategy_update_asset(SL.create_strategy("A" => SL.asset_config()), "A"; wrapper = wf); st2 = SL.strategy_update_asset(st, "A"; wrapper = nothing); result = [collect(keys(st["A"])), collect(keys(st2["A"]))]',
     note = "Wrapper hinzufügen und entfernen")
case("st_add", "strategy_add_asset(create_strategy(C = asset_config('etf', 'bnh', 0.5)), 'Z', asset_config('certificate', share = 0.5, wrapper = wb))",
     "result = simlev.strategy_add_asset(create_strategy(C=asset_config(asset_class='etf', trading='bnh', share=0.5)), 'Z', asset_config(asset_class='certificate', share=0.5, wrapper=wb))",
     'result = SL.strategy_add_asset(SL.create_strategy("C" => SL.asset_config("etf", "bnh", 0.5)), "Z", SL.asset_config("certificate"; share = 0.5, wrapper = wb))')

# ── Fehler und Hinweise ─────────────────────────────────────────────────────
case("err_nested", "wrapper_config(create_strategy(Z = asset_config(wrapper = wb)))", "result = wrapper_config(create_strategy(Z=asset_config(wrapper=wb)))",
     'result = SL.wrapper_config(SL.create_strategy("Z" => SL.asset_config(; wrapper = wb)))')
case("err_signal", "asset_config('etf', 'signal', signal_buy = 'buy', signal_sell = 'sell', wrapper = wb)",
     "result = asset_config(asset_class='etf', trading='signal', signal_buy='buy', signal_sell='sell', wrapper=wb)",
     'result = SL.asset_config("etf", "signal"; signal_buy = "buy", signal_sell = "sell", wrapper = wb)')
case("err_signal_list", "simulation(d, list(Z = list(asset_class = 'etf', trading = 'signal', share = 1, signal_buy = 'buy', signal_sell = 'sell', wrapper = wb)))",
     "result = simlev.simulation(d, {'Z': {'asset_class': 'etf', 'trading': 'signal', 'share': 1, 'signal_buy': 'buy', 'signal_sell': 'sell', 'wrapper': wb}})",
     'result = SL.simulation(d, RList("Z" => RList("asset_class" => "etf", "trading" => "signal", "share" => 1, "signal_buy" => "buy", "signal_sell" => "sell", "wrapper" => wb)))')
case("err_wrapper_class", "asset_config(wrapper = list(strategy = inner))", "result = asset_config(wrapper={'strategy': inner})",
     'result = SL.asset_config(; wrapper = RList("strategy" => inner))')
case("err_collision", "simulation(dz, create_strategy(Z = asset_config(wrapper = wb)))", "result = simlev.simulation(dz, create_strategy(Z=asset_config(wrapper=wb)))",
     'result = SL.simulation(dz, SL.create_strategy("Z" => SL.asset_config(; wrapper = wb)))')
case("err_collision_validate", "strategy_validate(create_strategy(Z = asset_config(wrapper = wb)), dz)", "result = simlev.strategy_validate(create_strategy(Z=asset_config(wrapper=wb)), data=dz)",
     'result = SL.strategy_validate(SL.create_strategy("Z" => SL.asset_config(; wrapper = wb)), dz)')
case("err_inner_missing", "simulation(d[c('date', 'A')], create_strategy(Z = asset_config(wrapper = wb)))",
     "result = simlev.simulation(d[['date', 'A']], create_strategy(Z=asset_config(wrapper=wb)))",
     'result = SL.simulation(SL.RFrame("date" => d.date, "A" => d.A), SL.create_strategy("Z" => SL.asset_config(; wrapper = wb)))')
case("err_inner_all_na", "x <- d; x$A <- NA_real_; x$B <- NA_real_; wrapper_nav(x, wb)", "x = d.copy(); x['A'] = np.nan; x['B'] = np.nan; result = wrapper_nav(x, wb)",
     'x = copy(d); x["A"] = fill(SL.NA, SL.nrow(x)); x["B"] = fill(SL.NA, SL.nrow(x)); result = SL.wrapper_nav(x, wb)')
case("err_late_only", "simulation(dl, create_strategy(Z = asset_config('certificate', wrapper = wb)))",
     "result = simlev.simulation(dl, create_strategy(Z=asset_config(asset_class='certificate', wrapper=wb)))",
     'result = SL.simulation(dl, SL.create_strategy("Z" => SL.asset_config("certificate"; wrapper = wb)))',
     note = "nur der Wrapper, Anteilswert beginnt nach dem ersten Tag: bestehender Fehler")
case("err_volume_fixed", "wrapper_config(inner, order_fee = 1)", "result = wrapper_config(inner, order_fee=1)", 'result = SL.wrapper_config(inner; order_fee = 1)')
case("err_volume_min", "wrapper_config(inner, order_fee = list(percent = 0.1, min = 1))", "result = wrapper_config(inner, order_fee={'percent': 0.1, 'min': 1})",
     'result = SL.wrapper_config(inner; order_fee = (percent = 0.1, min = 1))')
case("err_volume_max", "wrapper_config(inner, order_fee = list(percent = 0.1, max = 10))", "result = wrapper_config(inner, order_fee={'percent': 0.1, 'max': 10})",
     'result = SL.wrapper_config(inner; order_fee = (percent = 0.1, max = 10))')
case("err_volume_bad", "wrapper_config(inner, volume = c(1, 2))", "result = wrapper_config(inner, volume=[1.0, 2.0])", 'result = SL.wrapper_config(inner; volume = [1.0, 2.0])')
case("err_costs", "wrapper_config(inner, costs = sim_costs())", "result = wrapper_config(inner, costs=sim_costs())", 'result = SL.wrapper_config(inner; costs = SL.sim_costs())')
case("err_rebalance", "wrapper_config(inner, rebalance = dca_plan(100, 1))", "result = wrapper_config(inner, rebalance=dca_plan(100, 1))",
     'result = SL.wrapper_config(inner; rebalance = SL.dca_plan(100, 1))')
case("err_strategy", "wrapper_config('A')", "result = wrapper_config('A')", 'result = SL.wrapper_config("A")')
case("err_share", "wrapper_config(create_strategy(A = asset_config('etf', 'bnh', 0.6), B = asset_config('etf', 'bnh', 0.3)))",
     "result = wrapper_config(create_strategy(A=asset_config(asset_class='etf', trading='bnh', share=0.6), B=asset_config(asset_class='etf', trading='bnh', share=0.3)))",
     'result = SL.wrapper_config(SL.create_strategy("A" => SL.asset_config("etf", "bnh", 0.6), "B" => SL.asset_config("etf", "bnh", 0.3)))')
case("err_nav_wrapper", "wrapper_nav(d, inner)", "result = wrapper_nav(d, inner)", 'result = SL.wrapper_nav(d, inner)')
case("err_nav_splits", "wrapper_nav(d, wb, splits = c(50, 150))", "result = wrapper_nav(d, wb, splits=np.array([50.0, 150.0]))", 'result = SL.wrapper_nav(d, wb; splits = [50.0, 150.0])')
case("hint_spread", MR("wrapper_config(create_strategy(A = asset_config('etf', 'bnh', 0.6, spread = 0.15), B = asset_config('etf', 'bnh', 0.4)))"),
     MP("wrapper_config(create_strategy(A=asset_config(asset_class='etf', trading='bnh', share=0.6, spread=0.15), B=asset_config(asset_class='etf', trading='bnh', share=0.4)))"),
     MJ('SL.wrapper_config(SL.create_strategy("A" => SL.asset_config("etf", "bnh", 0.6; spread = 0.15), "B" => SL.asset_config("etf", "bnh", 0.4)))'),
     note = "Hinweis bei innerem Spread > 0")
# ── Druck ───────────────────────────────────────────────────────────────────
case("pr_config", "wb", "result = wb", "result = wb")
case("pr_config_full", "wrapper_config(list(A = asset_config('etf', 'bnh', 0.25), B = list(asset_class = 'etc', share = 0.75)), rebalance = rebalance_plan(span = 6, days = 3, anchor = 'end'), costs = funds_costs(1.25, 12.5), order_fee = list(fixed = 2.5, percent = 0.05, min = 4), volume = 2.5e6)",
     "result = wrapper_config({'A': asset_config(asset_class='etf', trading='bnh', share=0.25), 'B': {'asset_class': 'etc', 'share': 0.75}}, rebalance=rebalance_plan(span=6, days=3, anchor='end'), costs=funds_costs(fee=1.25, performance_fee=12.5), order_fee={'fixed': 2.5, 'percent': 0.05, 'min': 4}, volume=2.5e6)",
     'result = SL.wrapper_config(RList("A" => SL.asset_config("etf", "bnh", 0.25), "B" => RList("asset_class" => "etc", "share" => 0.75)); rebalance = SL.rebalance_plan(; span = 6, days = 3, anchor = "end"), costs = SL.funds_costs(1.25, 12.5), order_fee = (fixed = 2.5, percent = 0.05, min = 4), volume = 2.5e6)',
     note = "Liste statt create_strategy, alle Felder")
case("pr_config_event", "wrapper_config(inner, rebalance = rebalance_plan(event_col = 'ev', event_mode = 'replace'))",
     "result = wrapper_config(inner, rebalance=rebalance_plan(event_col='ev', event_mode='replace'))",
     'result = SL.wrapper_config(inner; rebalance = SL.rebalance_plan(; event_col = "ev", event_mode = "replace"))')
case("pr_asset", "asset_config('certificate', share = 0.5, spread = 0.3, wrapper = wb)", "result = asset_config(asset_class='certificate', share=0.5, spread=0.3, wrapper=wb)",
     'result = SL.asset_config("certificate"; share = 0.5, spread = 0.3, wrapper = wb)')
case("pr_strategy", "create_strategy(Z = asset_config('certificate', share = 0.5, wrapper = wb), C = asset_config('etf', 'bnh', 0.5))",
     "result = create_strategy(Z=asset_config(asset_class='certificate', share=0.5, wrapper=wb), C=asset_config(asset_class='etf', trading='bnh', share=0.5))",
     'result = SL.create_strategy("Z" => SL.asset_config("certificate"; share = 0.5, wrapper = wb), "C" => SL.asset_config("etf", "bnh", 0.5))')

# ── Auswahl aus SimLevWrapperNav (Etappe 8.0): gewöhnliche Tabelle ohne Klasse und Attribute ──
# Ergebnis je Fall: Klasse, Attribut inner fehlt, Attribut wrapper fehlt, die Auswahl selbst
SK_R <- "x <- wrapper_nav(d, wb); K <- function(s) list(class(s), is.null(attr(s, 'inner')), is.null(attr(s, 'wrapper')), s)\n"
SK_P <- paste0("import pandas as pd\nx = wrapper_nav(d, wb)\n",
               "def K(s):\n    return [['data.frame'] if type(s) is pd.DataFrame else list(getattr(s, 'r_class', None) or [type(s).__name__]), ",
               "'inner' not in s.attrs, 'wrapper' not in s.attrs, s]\n")
SK_J <- paste0("x = SL.wrapper_nav(d, wb)\n",
               'K(s) = [isempty(SL.r_class(s)) ? ["data.frame"] : SL.r_class(s), !haskey(SL.attrs(s), "inner"), !haskey(SL.attrs(s), "wrapper"), s]\n')
case("sub_rows", paste0(SK_R, "K(x[1:5, ])"), paste0(SK_P, "result = K(x.iloc[0:5])"), paste0(SK_J, "result = K(SL.rows(x, 1:5))"),
     note = "Zeilenauswahl: data.frame ohne Klasse SimLevWrapperNav und ohne Attribute")
case("sub_cols", paste0(SK_R, "K(x[c('date', 'nav', 'hwm')])"), paste0(SK_P, "result = K(x[['date', 'nav', 'hwm']])"),
     paste0(SK_J, 'result = K(SL.RFrame("date" => x.date, "nav" => x.nav, "hwm" => x.hwm))'),
     note = "Spaltenauswahl (Julia: keine Spaltenauswahl, neue Tabelle)")
case("sub_head", paste0(SK_R, "K(head(x, 3))"), paste0(SK_P, "result = K(x.head(3))"), paste0(SK_J, "result = K(SL.rows(x, 1:3))"))
case("sub_subset", paste0(SK_R, "K(subset(x, nav > 101))"), paste0(SK_P, "result = K(x[x['nav'] > 101])"),
     paste0(SK_J, "result = K(SL.rows(x, x.nav .> 101))"), note = "Auswahl mit Bedingung")
case("sub_all", paste0(SK_R, "K(x[])"), paste0(SK_P, "result = K(x[:])"), paste0(SK_J, "result = K(SL.rows(x, 1:SL.nrow(x)))"),
     note = "Auswahl aller Zeilen")
case("sub_whole", "x <- wrapper_nav(d, wb); list(class(x), names(attr(x, 'inner')$report), class(attr(x, 'wrapper')))",
     "x = wrapper_nav(d, wb); result = [list(x.r_class), list(x.attrs['inner']['report'].keys()), list(x.attrs['wrapper'].r_class)]",
     'x = SL.wrapper_nav(d, wb); result = [SL.r_class(x), collect(keys(SL.attrs(x)["inner"]["report"])), SL.r_class(SL.attrs(x)["wrapper"])]',
     note = "das ganze Objekt behält Klasse und Attribute")
case("wd_sub_err", "x <- wrapper_nav(d, wb); withdrawal_simulation(x[200:640, ], withdrawal_rule('percent', rate = 4), years = 1, frequency = 'quarter')",
     "x = wrapper_nav(d, wb); result = simlev.withdrawal_simulation(x.iloc[199:640], rule=simlev.withdrawal_rule(type='percent', rate=4), years=1, frequency='quarter')",
     'x = SL.wrapper_nav(d, wb); result = SL.withdrawal_simulation(SL.rows(x, 200:640), SL.withdrawal_rule("percent"; rate = 4); years = 1, frequency = "quarter")',
     note = "Ausschnitt ist keine Renditequelle: klarer Fehler")
case("wd_sub_cohorts", "x <- wrapper_nav(d, wb); ws <- withdrawal_simulation(withdrawal_cohorts(x[200:640, ], price = 'nav', inflation = 2, years = 1, frequency = 'quarter'), withdrawal_rule('percent', rate = 4), start_value = 1e5); ws$paths",
     "x = wrapper_nav(d, wb); ws = simlev.withdrawal_simulation(simlev.withdrawal_cohorts(x.iloc[199:640], price='nav', inflation=2, years=1, frequency='quarter'), rule=simlev.withdrawal_rule(type='percent', rate=4), start_value=1e5); result = ws['paths']",
     'x = SL.wrapper_nav(d, wb); ws = SL.withdrawal_simulation(SL.withdrawal_cohorts(SL.rows(x, 200:640); price = "nav", inflation = 2, years = 1, frequency = "quarter"), SL.withdrawal_rule("percent"; rate = 4); start_value = 1e5); result = ws["paths"]',
     note = "Ausschnitt über withdrawal_cohorts(price = 'nav')")
case("wd_df_err", "withdrawal_simulation(d[c('date', 'A')], withdrawal_rule('percent', rate = 4), years = 1)",
     "result = simlev.withdrawal_simulation(d[['date', 'A']], rule=simlev.withdrawal_rule(type='percent', rate=4), years=1)",
     'result = SL.withdrawal_simulation(SL.RFrame("date" => d.date, "A" => d.A), SL.withdrawal_rule("percent"; rate = 4); years = 1)',
     note = "gewöhnliche Kurstabelle: derselbe Fehler")
ref_done()
