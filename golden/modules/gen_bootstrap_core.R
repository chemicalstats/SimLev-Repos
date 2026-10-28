# Referenzfälle für die Bootstrap-Kerne (r/src/bootstrap_core.cpp, .garch_filter,
# MS-GARCH-Filter .ms_garch_filter aus r/src/ms_garch.c).
source("golden/modules/ref_tools.R"); ref_init("bootstrap_core")
set.seed(100)
X <- cbind(1 + rnorm(300, 4e-4, 0.011), 1 + rnorm(300, 2e-4, 0.006), 1 + rnorm(300, 0, 0.02))
reg <- sample(1:3, 300, TRUE)
tr <- matrix(c(.9, .05, .05, .1, .8, .1, .2, .2, .6), 3, byrow = TRUE)
P <- "from simlev import _bootstrap_core as C\n"
J <- function(code) paste0("const C = SimLev.BootstrapCore\nconst RNG = SimLev.RRng\n", code)
I <- list(X = X, reg = reg, tr = tr)
ref_case("iid", "set.seed(1); SimLev:::.boot_idx_iid(300L, 500L)", paste0(P, "simlev._r.rng.set_seed(1); result = C.boot_idx_iid(300, 500)"),
     jl = J('RNG.set_seed(1); result = C.boot_idx_iid(300, 500)'))
ref_case("block", "set.seed(2); list(SimLev:::.boot_idx_block(300L, 500L, 20L, FALSE), SimLev:::.boot_idx_block(300L, 77L, 13L, TRUE))",
         paste0(P, "simlev._r.rng.set_seed(2); result = [C.boot_idx_block(300, 500, 20, False), C.boot_idx_block(300, 77, 13, True)]"),
     jl = J('RNG.set_seed(2); result = [C.boot_idx_block(300, 500, 20, false), C.boot_idx_block(300, 77, 13, true)]'))
ref_case("block_err", "SimLev:::.boot_idx_block(10L, 5L, 20L, FALSE)", paste0(P, "result = C.boot_idx_block(10, 5, 20, False)"),
     jl = J('result = C.boot_idx_block(10, 5, 20, false)'))
ref_case("stat", "set.seed(3); list(SimLev:::.boot_idx_stationary(300L, 1000L, 15.5), SimLev:::.boot_idx_stationary(50L, 30L, 1))",
         paste0(P, "simlev._r.rng.set_seed(3); result = [C.boot_idx_stationary(300, 1000, 15.5), C.boot_idx_stationary(50, 30, 1)]"),
     jl = J('RNG.set_seed(3); result = [C.boot_idx_stationary(300, 1000, 15.5), C.boot_idx_stationary(50, 30, 1)]'))
ref_case("stat_lec", "set.seed(3, kind = \"L'Ecuyer-CMRG\"); x <- SimLev:::.boot_idx_stationary(300L, 400L, 22); RNGkind('Mersenne-Twister'); x",
         paste0(P, "simlev._r.rng.set_seed(3, kind=\"L'Ecuyer-CMRG\"); result = C.boot_idx_stationary(300, 400, 22); simlev._r.rng.rng_kind('Mersenne-Twister')"),
     jl = J("RNG.set_seed(3; kind = \"L'Ecuyer-CMRG\"); result = C.boot_idx_stationary(300, 400, 22); RNG.rng_kind(\"Mersenne-Twister\")"))
ref_case("regime", "set.seed(4); SimLev:::.boot_idx_regime(reg, tr, 400L)", paste0(P, "simlev._r.rng.set_seed(4); result = C.boot_idx_regime(reg, tr, 400)"), inputs = I,
     jl = J('RNG.set_seed(4); result = C.boot_idx_regime(reg, tr, 400)'))
ref_case("regime_empty", "set.seed(4); r2 <- reg; r2[r2 == 2] <- 1L; SimLev:::.boot_idx_regime(r2, tr, 200L)",
         paste0(P, "simlev._r.rng.set_seed(4); r2 = np.where(reg == 2, 1, reg); result = C.boot_idx_regime(r2, tr, 200)"), inputs = I,
     jl = J('RNG.set_seed(4); r2 = ifelse.(reg .== 2, 1, reg); result = C.boot_idx_regime(r2, tr, 200)'))
ref_case("tails", "set.seed(5); SimLev:::.boot_idx_tails(500L, 0.05, 0.07, 11:280, 1:10, 281:300)",
         paste0(P, "simlev._r.rng.set_seed(5); result = C.boot_idx_tails(500, 0.05, 0.07, np.arange(11, 281), np.arange(1, 11), np.arange(281, 301))"),
     jl = J('RNG.set_seed(5); result = C.boot_idx_tails(500, 0.05, 0.07, 11:280, 1:10, 281:300)'))
ref_case("wild", "set.seed(6); list(SimLev:::.boot_wild(X, 0L), SimLev:::.boot_wild(X, 1L), SimLev:::.boot_wild(X, 2L))",
         paste0(P, "simlev._r.rng.set_seed(6); result = [C.boot_wild(X, 0), C.boot_wild(X, 1), C.boot_wild(X, 2)]"), inputs = I,
     jl = J('RNG.set_seed(6); result = [C.boot_wild(X, 0), C.boot_wild(X, 1), C.boot_wild(X, 2)]'))
ref_case("reset", "set.seed(7); SimLev:::.boot_reset(X, 0.02)", paste0(P, "simlev._r.rng.set_seed(7); result = C.boot_reset(X, 0.02)"), inputs = I,
     jl = J('RNG.set_seed(7); result = C.boot_reset(X, 0.02)'))
ref_case("evt", "set.seed(8); SimLev:::.boot_evt(X, 0L, 400L, 0.05, 0.98, 0.006, 0.2, 1:15, 0.05, 1.02, 0.005, 0, 286:300, 16:285)",
         paste0(P, "simlev._r.rng.set_seed(8); result = C.boot_evt(X, 0, 400, 0.05, 0.98, 0.006, 0.2, np.arange(1, 16), 0.05, 1.02, 0.005, 0, np.arange(286, 301), np.arange(16, 286))"), inputs = I,
     jl = J('RNG.set_seed(8); result = C.boot_evt(X, 0, 400, 0.05, 0.98, 0.006, 0.2, 1:15, 0.05, 1.02, 0.005, 0, 286:300, 16:285)'))
Z <- matrix(rnorm(600), 300)
I$Z <- Z; I$zb <- rnorm(300)
ref_case("garch", "set.seed(9); SimLev:::.boot_garch(500L, 0L, 3L, 3e-4, 2e-6, 0.08, 0.9, 0.05, 1e-4, zb, 1:300, c(1L, 2L), c(1e-4, 0), c(1e-6, 3e-6), c(.05, .1), c(.9, .85), c(TRUE, FALSE), c(5e-5, 2e-4), Z)",
         paste0(P, "simlev._r.rng.set_seed(9); result = C.boot_garch(500, 0, 3, 3e-4, 2e-6, 0.08, 0.9, 0.05, 1e-4, zb, np.arange(1, 301), [1, 2], [1e-4, 0], [1e-6, 3e-6], [.05, .1], [.9, .85], [True, False], [5e-5, 2e-4], Z)"), inputs = I,
     jl = J('RNG.set_seed(9); result = C.boot_garch(500, 0, 3, 3e-4, 2e-6, 0.08, 0.9, 0.05, 1e-4, zb, 1:300, [1, 2], [1e-4, 0], [1e-6, 3e-6], [.05, .1], [.9, .85], [true, false], [5e-5, 2e-4], Z)'))
I$delta <- matrix(c(0, 0.5, -0.3, 0), 2)
ref_case("msgarch", "set.seed(10); SimLev:::.boot_ms_garch(400L, 0L, 3L, 2L, c(5e-4, -1e-3), c(1e-6, 5e-6), c(.05, .1), c(.9, .85), c(0, .1), c(0, .05), c(0, .1),
  matrix(c(.97, .05, .03, .95), 2), delta, c(1e-4, 4e-4), c(.6, .4), list(1:200, 201:300), zb, c(1L, 2L), c(1e-4, 0), c(1e-6, 3e-6), c(.05, .1), c(.9, .85), c(TRUE, FALSE), c(5e-5, 2e-4), Z)",
  paste0(P, "simlev._r.rng.set_seed(10); result = C.boot_ms_garch(400, 0, 3, 2, [5e-4, -1e-3], [1e-6, 5e-6], [.05, .1], [.9, .85], [0, .1], [0, .05], [0, .1],
  np.array([[.97, .03], [.05, .95]]), delta, [1e-4, 4e-4], [.6, .4], [np.arange(1, 201), np.arange(201, 301)], zb, [1, 2], [1e-4, 0], [1e-6, 3e-6], [.05, .1], [.9, .85], [True, False], [5e-5, 2e-4], Z)"), inputs = I,
     jl = J('RNG.set_seed(10); result = C.boot_ms_garch(400, 0, 3, 2, [5e-4, -1e-3], [1e-6, 5e-6], [.05, .1], [.9, .85], [0, .1], [0, .05], [0, .1],
  [.97 .03; .05 .95], delta, [1e-4, 4e-4], [.6, .4], [1:200, 201:300], zb, [1, 2], [1e-4, 0], [1e-6, 3e-6], [.05, .1], [.9, .85], [true, false], [5e-5, 2e-4], Z)'))
ref_case("helpers", "v <- SimLev:::.rolling_vol(X[, 1], 21L); th <- c(0, quantile(v, c(.33, .66)), Inf)
  list(v, SimLev:::.rolling_vol(X[1:5, 2], 10L), SimLev:::.assign_regimes(v, th), SimLev:::.estimate_trans_mat(reg, 3L, 0.1), SimLev:::.garch_filter(X[, 1] - 1, 1e-6, 0.07, 0.9, 0.04, 1e-4))",
  paste0(P, "v = C.rolling_vol(X[:, 0], 21); from simlev._r import stats as _st; th = [0, *_st.quantile(v, [.33, .66]), np.inf]
result = [v, C.rolling_vol(X[:5, 1], 10), C.assign_regimes(v, np.asarray(th, float)), C.estimate_trans_mat(reg, 3, 0.1), C.garch_filter(X[:, 0] - 1, 1e-6, 0.07, 0.9, 0.04, 1e-4)]"), inputs = I,
     jl = J('v = C.rolling_vol(X[:, 1], 21); th = vcat(0.0, SL.RStats.quantile(v, [.33, .66]), Inf)
result = [v, C.rolling_vol(X[1:5, 2], 10), C.assign_regimes(v, th), C.estimate_trans_mat(reg, 3, 0.1), C.garch_filter(X[:, 1] .- 1, 1e-6, 0.07, 0.9, 0.04, 1e-4)]'))
# MS-GARCH-Filter (src/ms_garch.c): Hamilton-Filter mit parallelen Varianzpfaden je Regime
set.seed(11); I$ym <- rnorm(60, 0, 0.01)
I$ym0 <- I$ym; I$ym0[20] <- 1   # Dichte 0 in allen Regimen ab t = 20: loglik = -Inf, filt/pred NaN
I$P2 <- matrix(c(.95, .05, .1, .9), 2, byrow = TRUE)
I$P3 <- matrix(c(.9, .05, .05, .1, .8, .1, .02, .08, .9), 3, byrow = TRUE)
MF <- list(
  msg_filter_K2_sgarch = c("ym, c(1e-6, 5e-6), c(.05, .1), c(.9, .8), c(0, 0), P2, c(2/3, 1/3), var(ym)",
                           "ym, [1e-6, 5e-6], [.05, .1], [.9, .8], [0, 0], P2, [2/3, 1/3], _st.var(ym)",
                           "ym, [1e-6, 5e-6], [.05, .1], [.9, .8], [0, 0], P2, [2/3, 1/3], SL.RStats.var(ym)"),
  msg_filter_K3_gjr = c("ym, c(1e-6, 3e-6, 1e-5), c(.03, .06, .1), c(.95, .9, .8), c(0, .04, .1), P3, c(.5, .3, .2), 1e-4",
                        "ym, [1e-6, 3e-6, 1e-5], [.03, .06, .1], [.95, .9, .8], [0, .04, .1], P3, [.5, .3, .2], 1e-4",
                        "ym, [1e-6, 3e-6, 1e-5], [.03, .06, .1], [.95, .9, .8], [0, .04, .1], P3, [.5, .3, .2], 1e-4"),
  msg_filter_neginf = c("ym0, c(1e-6, 5e-6), c(.05, .1), c(.9, .8), c(.02, .05), P2, c(.5, .5), 1e-4",
                        "ym0, [1e-6, 5e-6], [.05, .1], [.9, .8], [.02, .05], P2, [.5, .5], 1e-4",
                        "ym0, [1e-6, 5e-6], [.05, .1], [.9, .8], [.02, .05], P2, [.5, .5], 1e-4"),
  msg_filter_err_len = c("ym, c(1e-6, 5e-6), c(.05, .1), c(.9, .8), c(0, 0), P2, c(.5, .3, .2), 1e-4",
                         "ym, [1e-6, 5e-6], [.05, .1], [.9, .8], [0, 0], P2, [.5, .3, .2], 1e-4",
                         "ym, [1e-6, 5e-6], [.05, .1], [.9, .8], [0, 0], P2, [.5, .3, .2], 1e-4"))
for (k in names(MF)) {
  a <- MF[[k]]
  ref_case(k, sprintf("SimLev:::.ms_garch_filter(%s)", a[1]),
           paste0(P, "from simlev._r import stats as _st\n", sprintf("result = C.ms_garch_filter(%s)", a[2])), inputs = I[c("ym", "ym0", "P2", "P3")],
           jl = J(sprintf("result = C.ms_garch_filter(%s)", a[3])))
}
ref_done()
