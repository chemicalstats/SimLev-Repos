# Referenzfälle für simlev._r.rng (Zufallszahlen wie R).
source("golden/modules/ref_tools.R"); ref_init("r_rng")
P <- "from simlev._r import rng as R\n"
J <- "R = SL.RRng\n"
ref_case("runif", "set.seed(42); c(runif(2000), runif(5, -3, 7), runif(3, 2, 2))",
         paste0(P, "R.set_seed(42); result = np.concatenate([R.runif(2000), R.runif(5, -3, 7), R.runif(3, 2, 2)])"),
  jl = paste0(J, r"---(R.set_seed(42); result = vcat(R.runif(2000), R.runif(5, -3, 7), R.runif(3, 2, 2)))---"))
ref_case("rnorm", "set.seed(1); c(rnorm(3000, 2, 3), rnorm(4, c(0, 1), c(1, 0)))",
         paste0(P, "R.set_seed(1); result = np.concatenate([R.rnorm(3000, 2, 3), R.rnorm(4, [0, 1], [1, 0])])"),
  jl = paste0(J, r"---(R.set_seed(1); result = vcat(R.rnorm(3000, 2, 3), R.rnorm(4, [0, 1], [1, 0])))---"))
ref_case("rexp", "set.seed(7); rexp(1000, 2)", paste0(P, "R.set_seed(7); result = R.rexp(1000, 2)"),
  jl = paste0(J, r"---(R.set_seed(7); result = R.rexp(1000, 2))---"))
ref_case("rgamma", "set.seed(3); c(rgamma(500, 0.3), rgamma(500, 2.5), rgamma(300, 7), rgamma(300, 50, 2))",
         paste0(P, "R.set_seed(3); result = np.concatenate([R.rgamma(500, 0.3), R.rgamma(500, 2.5), R.rgamma(300, 7), R.rgamma(300, 50, 2)])"),
  jl = paste0(J, r"---(R.set_seed(3); result = vcat(R.rgamma(500, 0.3), R.rgamma(500, 2.5), R.rgamma(300, 7), R.rgamma(300, 50, 2)))---"))
ref_case("rchisq", "set.seed(4); c(rchisq(1000, 5.5), rchisq(10, 0.5))",
         paste0(P, "R.set_seed(4); result = np.concatenate([R.rchisq(1000, 5.5), R.rchisq(10, 0.5)])"),
  jl = paste0(J, r"---(R.set_seed(4); result = vcat(R.rchisq(1000, 5.5), R.rchisq(10, 0.5)))---"))
ref_case("rt", "set.seed(5); c(rt(500, 3), rt(500, 0.7), rt(100, Inf))",
         paste0(P, "R.set_seed(5); result = np.concatenate([R.rt(500, 3), R.rt(500, 0.7), R.rt(100, np.inf)])"),
  jl = paste0(J, r"---(R.set_seed(5); result = vcat(R.rt(500, 3), R.rt(500, 0.7), R.rt(100, Inf)))---"))
ref_case("rpois", "set.seed(6); c(rpois(500, 0.5), rpois(500, 4), rpois(500, 15), rpois(500, 300))",
         paste0(P, "R.set_seed(6); result = np.concatenate([R.rpois(500, 0.5), R.rpois(500, 4), R.rpois(500, 15), R.rpois(500, 300)])"),
  jl = paste0(J, r"---(R.set_seed(6); result = vcat(R.rpois(500, 0.5), R.rpois(500, 4), R.rpois(500, 15), R.rpois(500, 300)))---"))
ref_case("rgeom", "set.seed(8); c(rgeom(500, 0.05), rgeom(500, 0.5), rgeom(10, 1), rgeom(20, 1/30))",
         paste0(P, "R.set_seed(8); result = np.concatenate([R.rgeom(500, 0.05), R.rgeom(500, 0.5), R.rgeom(10, 1), R.rgeom(20, 1/30)])"),
  jl = paste0(J, r"---(R.set_seed(8); result = vcat(R.rgeom(500, 0.05), R.rgeom(500, 0.5), R.rgeom(10, 1), R.rgeom(20, 1/30)))---"))
ref_case("sample", "set.seed(9); list(sample.int(100), sample.int(10, 50, TRUE), sample.int(.Machine$integer.max, 1L),
  sample.int(5, 20, TRUE, prob = c(.1,.2,.3,.2,.2)), sample.int(5, 3, prob = c(.1,.2,.3,.2,.2)),
  sample.int(300, 50, TRUE, prob = (1:300)^0.5), sample.int(1e6, 5), sample.int(3, 1L, prob = c(0.2, 0.5, 0.3)))",
  paste0(P, "R.set_seed(9); result = [R.sample_int(100), R.sample_int(10, 50, True), R.sample_int(2147483647, 1),
  R.sample_int(5, 20, True, prob=[.1,.2,.3,.2,.2]), R.sample_int(5, 3, prob=[.1,.2,.3,.2,.2]),
  R.sample_int(300, 50, True, prob=np.arange(1, 301) ** 0.5), R.sample_int(1e6, 5), R.sample_int(3, 1, prob=[0.2, 0.5, 0.3])]"),
  jl = paste0(J, r"---(R.set_seed(9); result = Any[R.sample_int(100), R.sample_int(10, 50, true), R.sample_int(2147483647, 1),
  R.sample_int(5, 20, true; prob = [.1, .2, .3, .2, .2]), R.sample_int(5, 3; prob = [.1, .2, .3, .2, .2]),
  R.sample_int(300, 50, true; prob = SL.RLibm.pow(collect(1:300), 0.5)), R.sample_int(1e6, 5), R.sample_int(3, 1; prob = [0.2, 0.5, 0.3])])---"))
ref_case("lecuyer", "set.seed(10, kind = \"L'Ecuyer-CMRG\"); u <- runif(500); z <- rnorm(500); s <- .Random.seed
  out <- list(u = u, z = z, seed = s, nxt = parallel::nextRNGStream(s), sub = parallel::nextRNGSubStream(s))
  RNGkind('Mersenne-Twister'); out$after <- runif(5); out$kind <- RNGkind(); out$seed_after <- .Random.seed[1:5]; out",
  paste0(P, "R.set_seed(10, kind=\"L'Ecuyer-CMRG\"); u = R.runif(500); z = R.rnorm(500); s = R.get_random_seed()
result = dict(u=u, z=z, seed=s, nxt=R.next_rng_stream(s), sub=R.next_rng_substream(s))
R.rng_kind('Mersenne-Twister'); result['after'] = R.runif(5); result['kind'] = list(R.rng_kind()); result['seed_after'] = R.get_random_seed()[:5]"),
  jl = paste0(J, r"---(R.set_seed(10; kind = "L'Ecuyer-CMRG"); u = R.runif(500); z = R.rnorm(500); s = R.get_random_seed()
result = SL.RList("u" => u, "z" => z, "seed" => s, "nxt" => R.next_rng_stream(s), "sub" => R.next_rng_substream(s))
R.rng_kind("Mersenne-Twister"); result["after"] = R.runif(5); result["kind"] = R.rng_kind(); result["seed_after"] = R.get_random_seed()[1:5])---"))
ref_case("state", "set.seed(11); x <- runif(3); s <- .Random.seed; y <- runif(700); assign('.Random.seed', s, envir = globalenv()); list(s, y, runif(700))",
  paste0(P, "R.set_seed(11); x = R.runif(3); s = R.get_random_seed(); y = R.runif(700); R.set_random_seed(s); result = [s, y, R.runif(700)]"),
  jl = paste0(J, r"---(R.set_seed(11); x = R.runif(3); s = R.get_random_seed(); y = R.runif(700); R.set_random_seed(s); result = Any[s, y, R.runif(700)])---"))
ref_case("rounding", "suppressWarnings(set.seed(12, sample.kind = 'Rounding')); x <- sample.int(1000, 10); set.seed(1, sample.kind = 'Rejection'); x",
  paste0(P, "import warnings\nwith warnings.catch_warnings():\n    warnings.simplefilter('ignore'); R.set_seed(12, sample_kind='Rounding')\nresult = R.sample_int(1000, 10); R.set_seed(1, sample_kind='Rejection')"),
  jl = paste0(J, r"---(using Logging
Logging.with_logger(Logging.NullLogger()) do
    R.set_seed(12; sample_kind = "Rounding")
end
result = R.sample_int(1000, 10); R.set_seed(1; sample_kind = "Rejection"))---"))
ref_case("nawarn", "set.seed(2); rnorm(3, 0, c(1, -1, 1))", paste0(P, "R.set_seed(2); result = R.rnorm(3, 0, [1, -1, 1])"),
  jl = paste0(J, r"---(R.set_seed(2); result = R.rnorm(3, 0, [1, -1, 1]))---"))
# set.seed: asInteger des Startwerts (Abschneiden, außerhalb des int-Bereichs NA mit Warnung)
for (sv in list(c("seed_hi_ok", "2147483647.9"), c("seed_lo_ok", "-2147483647.9"), c("seed_hi", "2^31"),
                c("seed_hi_frac", "2^31 + 0.5"), c("seed_lo", "-2^31"), c("seed_inf", "Inf"), c("seed_na", "NA_real_")))
  ref_case(sv[1], sprintf("set.seed(%s); runif(2)", sv[2]),
           paste0(P, sprintf("R.set_seed(%s); result = R.runif(2)",
                             switch(sv[2], "2^31" = "2.0**31", "2^31 + 0.5" = "2.0**31 + 0.5", "-2^31" = "-2.0**31",
                                    "Inf" = "math.inf", "NA_real_" = "simlev._r.fmt.NA_REAL", sv[2]))),
           jl = paste0(J, sprintf("R.set_seed(%s); result = R.runif(2)",
                                  switch(sv[2], "2^31" = "2.0^31", "2^31 + 0.5" = "2.0^31 + 0.5", "-2^31" = "-2.0^31",
                                         "Inf" = "Inf", "NA_real_" = "SL.NA", sv[2]))))
ref_done()
