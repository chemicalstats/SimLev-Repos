# Referenzfälle für regimes.R (+ Kern .hmm_forward_backward aus research_core.cpp).
source("golden/modules/ref_tools.R"); ref_init("regimes")
P <- "from simlev import _dependence_core as C\nfrom simlev import regimes as RG\n"
J <- 'C = SL.DependenceCore\nRG = SL.Regimes\n'

# ── Kerne und Hilfen ─────────────────────────────────────────────────────
set.seed(6); Tn <- 200; K <- 3
B <- matrix(runif(Tn * K, 0.1, 1), Tn); A <- matrix(runif(K * K), K); A <- A / rowSums(A); p0 <- rep(1 / K, K)
ref_case("fb_core", "list(SimLev:::.hmm_forward_backward(B, A, p0), SimLev:::.hmm_forward_backward(B[1:5, 1:2], diag(2), c(0.3, 0.7)), SimLev:::.hmm_forward_backward(B[1, , drop = FALSE], A, p0))",
         paste0(P, "result = [C.hmm_forward_backward(B, A, p0), C.hmm_forward_backward(B[:5, :2], np.eye(2), [0.3, 0.7]), C.hmm_forward_backward(B[:1], A, p0)]"),
         inputs = list(B = B, A = A, p0 = p0),
         jl = paste0(J, "result = [C.hmm_forward_backward(B, A, p0), C.hmm_forward_backward(B[1:5, 1:2], [1.0 0; 0 1], [0.3, 0.7]), C.hmm_forward_backward(B[1:1, :], A, p0)]"))
set.seed(2); Xl <- matrix(rnorm(60), 20); mu <- c(0.1, -0.2, 0.05); S <- crossprod(matrix(rnorm(9), 3)) + diag(3)
ref_case("ldmvn", "list(SimLev:::.ldmvn(Xl, mu, S), SimLev:::.ldmvn(Xl[, 1, drop = FALSE], 0.3, matrix(2)))",
         paste0(P, "result = [RG._ldmvn(Xl, mu, S), RG._ldmvn(Xl[:, :1], [0.3], np.array([[2.]]))]"), inputs = list(Xl = Xl, mu = mu, S = S),
         jl = paste0(J, "result = [RG._ldmvn(Xl, mu, S), RG._ldmvn(Xl[:, 1:1], [0.3], fill(2.0, 1, 1))]"))
ref_case("ldmvn_err", "SimLev:::.ldmvn(Xl[, 1:2], c(0, 0), matrix(c(1, 2, 2, 1), 2))",
         paste0(P, "result = RG._ldmvn(Xl[:, :2], [0, 0], np.array([[1., 2], [2, 1]]))"), inputs = list(Xl = Xl),
         jl = paste0(J, "result = RG._ldmvn(Xl[:, 1:2], [0, 0], [1.0 2; 2 1])"))
set.seed(3); VI <- list()
for (k in 2:4) {
  lB <- matrix(round(rnorm(200 * k), 1), 200, k)
  A <- matrix(runif(k * k), k); A[1, k] <- 0; A <- A / rowSums(A)
  VI[[paste0("lB", k)]] <- lB; VI[[paste0("A", k)]] <- A
}
VI$lBn <- VI$lB3; VI$lBn[50, 2] <- NaN; VI$lBn[60, ] <- NA
ref_case("viterbi", "list(SimLev:::.hmm_viterbi(lB2, log(A2), log(rep(1/2, 2))), SimLev:::.hmm_viterbi(lB3, log(A3), log(rep(1/3, 3))), SimLev:::.hmm_viterbi(lB4, log(A4), log(rep(1/4, 4))),
  SimLev:::.hmm_viterbi(lB3, matrix(0, 3, 3), c(-Inf, 0, 0)), SimLev:::.hmm_viterbi(lBn, log(A3), log(rep(1/3, 3))))",
         paste0(P, "L = simlev._r.libm.log\nresult = [RG._hmm_viterbi(lB2, L(A2), L(np.full(2, 1/2))), RG._hmm_viterbi(lB3, L(A3), L(np.full(3, 1/3))), RG._hmm_viterbi(lB4, L(A4), L(np.full(4, 1/4))),\n  RG._hmm_viterbi(lB3, np.zeros((3, 3)), [-np.inf, 0, 0]), RG._hmm_viterbi(lBn, L(A3), L(np.full(3, 1/3)))]"),
         inputs = VI,
         jl = paste0(J, "L(x) = SL.RLibm.log.(x)\nresult = [RG._hmm_viterbi(lB2, L(A2), L(fill(1/2, 2))), RG._hmm_viterbi(lB3, L(A3), L(fill(1/3, 3))), RG._hmm_viterbi(lB4, L(A4), L(fill(1/4, 4))),\n  RG._hmm_viterbi(lB3, zeros(3, 3), [-Inf, 0, 0]), RG._hmm_viterbi(lBn, L(A3), L(fill(1/3, 3)))]"))

# ── regime_hmm ───────────────────────────────────────────────────────────
set.seed(1); n <- 4 * 365
d <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = n))
vol <- rep(rep(c(0.006, 0.02), c(300, 150)), length.out = n)
d$aktien <- 100 * exp(cumsum(rnorm(n, 2e-4, vol)))
d$anleihen <- 100 * exp(cumsum(rnorm(n, 1e-4, vol / 3)))
d$aktien[c(20, 21, 500)] <- NA
H <- list(d = d)
ref_case("hmm_week", "regime_hmm(d, 'aktien', k = 2)", paste0(P, "result = RG.regime_hmm(d, 'aktien', k=2)"), inputs = H,
         jl = paste0(J, 'result = RG.regime_hmm(d, "aktien"; k = 2)'))
ref_case("hmm_week2", "regime_hmm(d, c('aktien', 'anleihen'), k = 2L, n_start = 3, seed = 5, max_iter = 40L, tol = 1e-5)",
         paste0(P, "result = RG.regime_hmm(d, ['aktien', 'anleihen'], k=2, n_start=3, seed=5, max_iter=40, tol=1e-5)"), inputs = H,
         jl = paste0(J, 'result = RG.regime_hmm(d, ["aktien", "anleihen"]; k = 2, n_start = 3, seed = 5, max_iter = 40, tol = 1e-5)'))
ref_case("hmm_seednull", "set.seed(9); x <- regime_hmm(d, 'anleihen', k = 3, n_start = 2, seed = NULL, max_iter = 30); list(x, runif(2))",
         paste0(P, "simlev._r.rng.set_seed(9); x = RG.regime_hmm(d, 'anleihen', k=3, n_start=2, seed=None, max_iter=30); result = [x, simlev._r.rng.runif(2)]"), inputs = H,
         jl = paste0(J, 'SL.RRng.set_seed(9); x = RG.regime_hmm(d, "anleihen"; k = 3, n_start = 2, seed = nothing, max_iter = 30); result = [x, SL.RRng.runif(2)]'))
# Review 7 (B7-05): bekannte Referenzwerte
set.seed(11); n <- 4 * 365
d7 <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = n))
vol <- rep(rep(c(0.006, 0.02), c(300, 120)), length.out = n)
d7$a <- 100 * exp(cumsum(rnorm(n, 2e-4, vol))); d7$b <- 100 * exp(cumsum(rnorm(n, 1e-4, vol / 2)))
ref_case("hmm_day3", "regime_hmm(d7, c('a', 'b'), k = 3, frequency = 'day', n_start = 2)",
         paste0(P, "result = RG.regime_hmm(d7, ['a', 'b'], k=3, frequency='day', n_start=2)"), inputs = list(d7 = d7),
         jl = paste0(J, 'result = RG.regime_hmm(d7, ["a", "b"]; k = 3, frequency = "day", n_start = 2)'))
ref_case("hmm_month", "regime_hmm(d7, 'a', k = 2, frequency = 'month', seed = 1)",
         paste0(P, "result = RG.regime_hmm(d7, 'a', k=2, frequency='month', seed=1)"), inputs = list(d7 = d7),
         jl = paste0(J, 'result = RG.regime_hmm(d7, "a"; k = 2, frequency = "month", seed = 1)'))
ref_case("hmm_err_k1", "regime_hmm(d, 'aktien', k = 1)", paste0(P, "result = RG.regime_hmm(d, 'aktien', k=1)"), inputs = list(d = d[1:10, ]),
         jl = paste0(J, 'result = RG.regime_hmm(d, "aktien"; k = 1)'))
ref_case("hmm_err_k2", "regime_hmm(d, 'aktien', k = 2.5)", paste0(P, "result = RG.regime_hmm(d, 'aktien', k=2.5)"), inputs = list(d = d[1:10, ]),
         jl = paste0(J, 'result = RG.regime_hmm(d, "aktien"; k = 2.5)'))
ref_case("hmm_err_k3", "regime_hmm(d, 'aktien', k = c(2, 3))", paste0(P, "result = RG.regime_hmm(d, 'aktien', k=[2, 3])"), inputs = list(d = d[1:10, ]),
         jl = paste0(J, 'result = RG.regime_hmm(d, "aktien"; k = [2, 3])'))
ref_case("hmm_err_k4", "regime_hmm(d, 'aktien', k = '2')", paste0(P, "result = RG.regime_hmm(d, 'aktien', k='2')"), inputs = list(d = d[1:10, ]),
         jl = paste0(J, 'result = RG.regime_hmm(d, "aktien"; k = "2")'))
ref_case("hmm_err_few", "regime_hmm(d, 'aktien', k = 3)", paste0(P, "result = RG.regime_hmm(d, 'aktien', k=3)"), inputs = list(d = d[1:900, ]),
         jl = paste0(J, 'result = RG.regime_hmm(d, "aktien"; k = 3)'))
df <- d[1:400, ]; df$flat <- 100
ref_case("hmm_err_flat", "regime_hmm(df, c('aktien', 'flat'), frequency = 'day')", paste0(P, "result = RG.regime_hmm(df, ['aktien', 'flat'], frequency='day')"), inputs = list(df = df),
         jl = paste0(J, 'result = RG.regime_hmm(df, ["aktien", "flat"]; frequency = "day")'))
ref_case("hmm_err_freq", "regime_hmm(d, 'aktien', frequency = 'quarter')", paste0(P, "result = RG.regime_hmm(d, 'aktien', frequency='quarter')"), inputs = list(d = d[1:10, ]),
         jl = paste0(J, 'result = RG.regime_hmm(d, "aktien"; frequency = "quarter")'))

# ── regime_states ────────────────────────────────────────────────────────
PH <- paste0(P, "hmm = RG.regime_hmm(d, 'aktien', k=2)\n")
JH <- paste0(J, 'hmm = RG.regime_hmm(d, "aktien"; k = 2)\n')
dq <- seq.Date(as.Date("2009-12-01"), as.Date("2014-03-01"), by = "week")
ref_case("states", "hmm <- regime_hmm(d, 'aktien', k = 2); list(regime_states(hmm, d), regime_states(hmm, dq, output = 'probability'),
  regime_states(hmm, dq, lag = 0L), regime_states(hmm, dq, output = 'probability', state_prob = 1, lag = 7), regime_states(hmm, c(dq[1:3], NA)))",
         paste0(PH, "result = [RG.regime_states(hmm, d), RG.regime_states(hmm, dq, output='probability'), RG.regime_states(hmm, dq, lag=0),\n  RG.regime_states(hmm, dq, output='probability', state_prob=1, lag=7), RG.regime_states(hmm, np.r_[dq[:3], np.datetime64('NaT', 'D')])]"),
         inputs = list(d = d, dq = dq),
         jl = paste0(JH, 'result = [RG.regime_states(hmm, d), RG.regime_states(hmm, dq; output = "probability"), RG.regime_states(hmm, dq; lag = 0),\n  RG.regime_states(hmm, dq; output = "probability", state_prob = 1, lag = 7), RG.regime_states(hmm, vcat(Union{Missing,Date}[dq[1:3]...], [missing]))]'))
ref_case("states_smoothed", "hmm <- regime_hmm(d, 'aktien', k = 2); list(regime_states(hmm, dq, 'smoothed'), regime_states(hmm, format(dq), 'smoothed', 'probability'))",
         paste0(PH, "result = [RG.regime_states(hmm, dq, 'smoothed'), RG.regime_states(hmm, [str(v) for v in dq], 'smoothed', 'probability')]"),
         inputs = list(d = d, dq = dq),
         jl = paste0(JH, 'result = [RG.regime_states(hmm, dq; type = "smoothed"), RG.regime_states(hmm, Dates.format.(dq, "yyyy-mm-dd"); type = "smoothed", output = "probability")]'))
ref_case("states_viterbi", "hmm <- regime_hmm(d, 'aktien', k = 2); regime_states(hmm, data.frame(date = dq), 'viterbi')",
         paste0(PH, "result = RG.regime_states(hmm, pd.DataFrame({'date': dq}), 'viterbi')"), inputs = list(d = d, dq = dq),
         jl = paste0(JH, 'result = RG.regime_states(hmm, SL.RFrame("date" => dq); type = "viterbi")'))
ref_case("states_err", "hmm <- regime_hmm(d, 'aktien', k = 2); regime_states(hmm, dq, 'viterbi', 'probability')",
         paste0(PH, "result = RG.regime_states(hmm, dq, 'viterbi', 'probability')"), inputs = list(d = d, dq = dq),
         jl = paste0(JH, 'result = RG.regime_states(hmm, dq; type = "viterbi", output = "probability")'))
ref_done()
