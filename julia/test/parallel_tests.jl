# RParallel.par_lapply (Etappe 5): Fork-Semantik von mclapply, mit Threads.@spawn,
# wenn Julia mit mehreren Threads läuft (`julia -t 2`), sonst nacheinander. Die
# Ergebnisse der Aufrufer prüfen die Referenzfälle mit cores = 2; hier stehen
# Zufallszustand, Ausgabereihenfolge, Warnungen, Fehler und Thread-Sicherheit.
using Test

@testset "RParallel.par_lapply (Threads: $(Threads.nthreads()))" begin
    P = SimLev.RParallel
    R = SimLev.RRng
    R.set_seed(1); s0 = R.get_random_seed()
    a = P.par_lapply(1:4, i -> R.runif(1)[1], 2)
    @test length(unique(a)) == 1 && R.get_random_seed() == s0
    R.set_seed(1); b = P.par_lapply(1:4, i -> R.runif(1)[1], 1)
    @test b[1] == a[1] && length(unique(b)) == 4
    R.set_seed(3); c = P.par_lapply(1:3, i -> R.runif(1)[1], 1.5)    # as.integer(1.5) = 1 -> lapply
    @test length(unique(c)) == 3
    @test P.par_lapply(Int[], identity, 2) == Any[]

    # rgamma/rpois mit eigenem statischem Zustand je Aufgabe; gleich wie nacheinander
    R.set_seed(5); g2 = P.par_lapply(1:4, i -> (R.rgamma(3, 0.7), R.rpois(3, 2.5), R.rnorm(2)), 3)
    R.set_seed(5); g1 = P._sequential(collect(1:4), i -> (R.rgamma(3, 0.7), R.rpois(3, 2.5), R.rnorm(2)))
    @test g2 == g1

    # Ausgaben in Elementreihenfolge, Warnungen verworfen, suppress_messages je Aufgabe
    f(i) = (i == 1 && sleep(0.2); println(P.r_stdout(), "out ", i); SimLev.DataPrep.message("err $i"); @warn "w$i"; 10i)
    out = Pipe(); err = Pipe()
    res = redirect_stdout(out) do
        redirect_stderr(err) do
            P.par_lapply(1:4, f, 2)
        end
    end
    close(out.in); close(err.in)
    @test res == Any[10, 20, 30, 40]
    @test read(out, String) == join(["out $i\n" for i in 1:4])
    @test read(err, String) == join(["err $i\n" for i in 1:4])
    quiet = Pipe()
    redirect_stderr(quiet) do
        P.par_lapply(1:3, i -> P.suppress_messages(() -> SimLev.DataPrep.message("still $i")), 2)
        SimLev.DataPrep.message("laut")
    end
    close(quiet.in)
    @test read(quiet, String) == "laut\n"

    # erster Fehler in Elementreihenfolge, Ausgaben davor erscheinen
    g(i) = (println(P.r_stdout(), "g ", i); i in (3, 5) && error("kaputt $i"); i)
    out = Pipe()
    e = redirect_stdout(out) do
        try
            P.par_lapply(1:6, g, 2); nothing
        catch ex
            ex
        end
    end
    close(out.in)
    @test e isa ErrorException && e.msg == "kaputt 3"
    @test read(out, String) == "g 1\ng 2\ng 3\n"

    # verschachtelt: innere Elemente starten mit dem Zustand des äußeren
    R.set_seed(7)
    nest = P.par_lapply(1:2, i -> P.par_lapply(1:2, j -> R.runif(1)[1], 2), 2)
    @test length(unique(vcat(nest...))) == 1

    # Thread-Sicherheit: Kollation, Formatieren, Zufall, Engine gleichzeitig
    xs = ["b", "A", "a", "B", "ä", "c"]
    w = P.par_lapply(1:8, i -> (SimLev.RStats.order(xs), SimLev.RFmt.sprintf("%.3f", i / 7),
                                (R.set_seed(i); R.rnorm(50))), 2)
    @test all(x -> x[1] == w[1][1], w)
    @test [x[2] for x in w] == [SimLev.RFmt.sprintf("%.3f", i / 7) for i in 1:8]
    @test [x[3] for x in w] == [(R.set_seed(i); R.rnorm(50)) for i in 1:8]
end
