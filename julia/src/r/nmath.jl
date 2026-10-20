# RNmath – Verteilungsfunktionen aus R's nmath (R 4.3.3), bitgleich portiert
#
# Jede Funktion ist ein 1:1-Port des C-Codes aus src/nmath/ (inklusive aller
# Verzweigungen, Konstanten und Warnungen). Die öffentlichen Funktionen
# tragen die R-Namen und -Argumente (`lower.tail` → `lower_tail`, `log.p` →
# `log_p`) und wenden den skalaren Kern elementweise mit R-Recycling an (wie
# `math2_1`/`math3_2` in stats/src/distn.c bzw. `math1` in arithmetic.c):
#
# - Skalar rein → Skalar raus; sonst Array in der Form des ersten längsten
#   Arguments (`RVector` behält Namen, `NamedMat` dimnames, Matrix die Form).
# - NA in einem Argument ergibt NA, NaN ergibt NaN, ohne Warnung
#   (`lgamma`/`gamma`: das Argument selbst).
# - Entsteht sonst ein NaN, folgt am Ende die R-Warnung "NaNs produced".
#
# Skalare Kerne mit C-Signatur (Float64, Flags als Bool): `dnorm4`, `pnorm5`,
# `pnorm_both`, `qnorm5`, `dt_`, `pt_`, `qt_`, `pbeta_`, `lbeta_`, `beta_`,
# `plogis_`, `qlogis_`, `dlogis_`, `pgamma_`, `qgamma_`, `dgamma_`, `pchisq_`,
# `qchisq_`, `dchisq_`, `pf_`, `bratio` (toms708). Interne Hilfen:
# `stirlerr`, `bd0`, `ebd0`, `lgammacor`, `chebyshev_eval`, `chebyshev_init`,
# `log1pmx`, `lgamma1p`, `logspace_add`, `logspace_sub`, `logspace_sum`,
# `dpois_raw`, `lgammafn`, `lgammafn_sign`, `gammafn`, `sinpi`, `cospi`,
# `tanpi`, `log1pexp`, `log1mexp`, `pgamma_raw`, `pbeta_raw`, `qchisq_appr`,
# `fmax2`, `fmin2`, `fsign`, `imax2`, `imin2`, `R_forceint`, `R_pow`, `R_pow_di`.
#
# Vorlage: python/simlev/_r/nmath.py, _toms708.py, _cmath.py.
# Nicht portiert: nicht-zentrale Verteilungen (`ncp`).
module RNmath

import ..SimLev
using ..SimLev: NA, isna_strict, RVector, NamedMat
using Printf: Printf

include("_cmath.jl")
include("_toms708.jl")

const R_MSG_NA = "NaNs produced"

_warn_precision(s) = ml_warning("full precision may not have been achieved in '$s'")
_warn_range(s) = ml_warning("value out of range in '$s'")
_warn_underflow(s) = ml_warning("underflow occurred in '$s'")

# ══ Chebyshev, lgammacor, stirlerr, bd0 ═══════════════════════════════════

function _chebyshev_init(dos, nos::Int, eta::Float64)
    nos < 1 && return 0
    err = 0.0
    i = 0
    for ii in 1:nos
        i = nos - ii
        err += abs(dos[i+1])
        err > eta && return i
    end
    return i
end

function _chebyshev_eval(x::Float64, a, n::Int)
    (n < 1 || n > 1000) && return NaN
    (x < -1.1 || x > 1.1) && return NaN
    twox = x * 2
    b2 = b1 = 0.0
    b0 = 0.0
    @inbounds for i in 1:n
        b2 = b1
        b1 = b0
        b0 = twox * b1 - b2 + a[n-i+1]
    end
    return (b0 - b2) * 0.5
end

const _ALGMCS = (
    0.16663894804518634, -1.384948176067564e-05, 9.81082564692473e-09,
    -1.809129475572494e-11, 6.221098041892606e-14, -3.399615005417722e-16,
    2.683181998482699e-18, -2.868042435334643e-20, 3.9628370610464347e-22,
    -6.831888753985767e-24, 1.4292273559424982e-25, -3.5475981581010704e-27,
    1.025680058010471e-28, -3.401102254316749e-30, 1.276642195630063e-31,
)
const _SFERR_HALVES = (
    0.0, 0.15342640972002736, 0.08106146679532726,
    0.05481412105191765, 0.0413406959554093, 0.03316287351993629,
    0.02767792568499834, 0.023746163656297496, 0.020790672103765093,
    0.018488450532673187, 0.016644691189821193, 0.015134973221917378,
    0.013876128823070748, 0.012810465242920227, 0.01189670994589177,
    0.011104559758206917, 0.010411265261972096, 0.009799416126158804,
    0.009255462182712733, 0.008768700134139386, 0.00833056343336287,
    0.00793411456431402, 0.007573675487951841, 0.007244554301320383,
    0.00694284010720953, 0.006665247032707682, 0.006408994188004207,
    0.006171712263039458, 0.0059513701127588475, 0.0057462165130101155,
    0.005554733551962801,
)
const _GAMCS = (
    0.00857119559098933, 0.004415381324841007, 0.05685043681599363,
    -0.00421983539641856, 0.0013268081812124603, -0.00018930245297988805,
    3.606925327441245e-05, -6.056761904460864e-06, 1.0558295463022833e-06,
    -1.811967365542384e-07, 3.117724964715322e-08, -5.354219639019687e-09,
    9.193275519859589e-10, -1.5779412802883398e-10, 2.7079806229349544e-11,
    -4.64681865382573e-12, 7.97335019200742e-13, -1.368078209830916e-13,
    2.3473194865638007e-14, -4.027432614949067e-15, 6.910051747372101e-16,
    -1.185584500221993e-16, 2.034148542496374e-17, -3.490054341717406e-18,
    5.987993856485306e-19, -1.027378057872228e-19, 1.7627028160605298e-20,
    -3.024320653735306e-21, 5.188914660218398e-22, -8.902770842456576e-23,
    1.5274740684933426e-23, -2.620731256187363e-24, 4.496464047830539e-25,
    -7.714712731336878e-26, 1.323635453126044e-26, -2.2709994129429287e-27,
    3.8964189980039913e-28, -6.685198115125953e-29, 1.1469986631400244e-29,
    -1.9679385863451348e-30, 3.376448816585338e-31, -5.793070335782136e-32,
)
const _LG1P_COEFFS = (
    0.3224670334241132, 0.0673523010531981, 0.020580808427784546,
    0.007385551028673986, 0.0028905103307415234, 0.001192753911703261,
    0.0005096695247430425, 0.00022315475845357939, 9.945751278180853e-05,
    4.492623673813314e-05, 2.050721277567069e-05, 9.439488275268397e-06,
    4.374866789907488e-06, 2.039215753801366e-06, 9.55141213040742e-07,
    4.492469198764566e-07, 2.1207184805554665e-07, 1.0043224823968099e-07,
    4.7698101693639804e-08, 2.2711094608943164e-08, 1.0838659214896955e-08,
    5.183475041970047e-09, 2.4836745438024785e-09, 1.1921401405860912e-09,
    5.731367241678862e-10, 2.7595228851242334e-10, 1.330476437424449e-10,
    6.4229645638381e-11, 3.1044247747322276e-11, 1.5021384080754142e-11,
    7.275974480239079e-12, 3.527742476575915e-12, 1.711991790559618e-12,
    8.315385841420285e-13, 4.04220052528944e-13, 1.9664756310966165e-13,
    9.573630387838556e-14, 4.6640760264283744e-14, 2.2737369600659724e-14,
    1.1091399470834522e-14,
)
const _BD0_SCALE = (
    (0.6931471824645996, -1.9046542121259336e-09, -8.78318373858934e-17, 3.061840738529369e-24),
    (0.6853040456771851, -4.2578264469739224e-08, -1.1723105396588968e-15, 6.20339263720161e-23),
    (0.6773988008499146, 2.274189014883632e-08, 1.4411920431605914e-15, 7.046384546650164e-23),
    (0.6699305772781372, -4.8293856025338755e-08, -8.664795531738382e-16, 7.049557660755325e-24),
    (0.6624060869216919, -4.791602492559832e-08, -2.161508226230938e-15, 7.092968360825275e-23),
    (0.6548244953155518, 6.237715233226027e-09, 1.1806699607549086e-16, 6.660323533535123e-25),
    (0.6471850872039795, -4.220866856030625e-08, -1.3817589176253094e-15, -1.1159932395766606e-23),
    (0.6400018930435181, -4.979170142860312e-08, 4.887013763907625e-16, 1.6847465694533583e-23),
    (0.6327667236328125, -5.406177194799966e-08, -2.7224545250006775e-15, -2.9070780223955397e-23),
    (0.6249561309814453, 3.285935434860221e-08, 1.201672936775467e-16, -8.668233185091897e-24),
    (0.6181373596191406, -6.406189467789147e-11, 3.550580962335878e-18, -3.623679406748965e-25),
    (0.6107416152954102, 4.229853800552519e-08, 1.548143293520366e-15, -5.446353118719766e-23),
    (0.6032907962799072, 5.515817491641428e-08, 2.1193636784238266e-15, 1.247109826410663e-22),
    (0.5963221788406372, 3.28135385530004e-09, -1.4033469816541837e-16, 5.544061982643074e-24),
    (0.5893045663833618, 4.307998580088679e-08, -3.2446651600595306e-15, -2.569782398567476e-23),
    (0.5822374820709229, -3.983067387025585e-08, 2.9387905513776885e-15, 1.6124430498687833e-22),
    (0.5751199722290039, 2.242384056216906e-09, -2.204516403537114e-17, 4.078543753751354e-25),
    (0.5685046911239624, 4.422870603093543e-08, 2.7879957109977287e-16, -9.741708794029408e-24),
    (0.5618454217910767, 2.147161382026752e-08, 1.3374919170106156e-15, -2.326922260336506e-23),
    (0.554580807685852, 4.57783499996367e-09, 2.633145912141026e-16, 2.070995903387998e-23),
    (0.5478278398513794, -7.667999568639061e-09, 6.199095327775322e-16, 6.341979011056023e-24),
    (0.5410289764404297, -3.7302321231891256e-08, -3.3801781496424835e-15, 1.4469198371142414e-22),
    (0.5347557067871094, 4.382891916066001e-08, -8.601820749692393e-16, -8.775950563978016e-24),
    (0.5278670787811279, 1.0839714903454478e-08, -4.480281248130319e-16, 3.8840996084516777e-23),
    (0.5215104818344116, 4.2031594205127476e-08, 1.211009992711288e-15, -2.3206744819671555e-23),
    (0.5145297050476074, -1.2322940889930578e-08, 2.820084495413274e-16, 1.880026562185923e-23),
    (0.5080875158309937, -1.2297126872340414e-08, -4.295835588700959e-16, -1.8036626177499945e-23),
    (0.5016034841537476, 5.9145378372704727e-08, 1.2728561033550608e-15, -5.824094430019416e-23),
    (0.4950772523880005, 1.4409851090135817e-08, -6.381910184083422e-17, -3.500509376717118e-25),
    (0.48910707235336304, 2.745798610703787e-08, -1.4470418644525664e-15, 4.211866896949939e-23),
    (0.4824984669685364, 1.762245460668055e-08, 4.128675224747099e-16, 2.6082691866392177e-23),
    (0.4764525294303894, -1.2470243504481004e-08, -9.162193924794196e-17, 3.765782542240376e-24),
    (0.469759464263916, -5.450353945946063e-09, -4.304846960468561e-16, 2.074710343707083e-25),
    (0.46363574266433716, -1.7013046527125653e-09, 7.601622738878589e-18, -2.0415879231895994e-25),
    (0.4574742913246155, 6.943684516258486e-10, -2.5461310777374286e-17, 5.5412533419976475e-25),
    (0.4512746334075928, 1.0731865174307131e-08, 6.374000219845047e-16, 3.901547318408994e-23),
    (0.44503629207611084, 2.8650656958006948e-08, -9.155352545558342e-16, -4.7365878254772817e-23),
    (0.43938833475112915, 2.6186132373595683e-08, 1.3619601577579505e-15, -5.2672794844240613e-23),
    (0.4330751895904541, 1.9065733880552216e-08, 1.014319201479946e-15, 1.0145670737413337e-22),
    (0.42735910415649414, -1.141359362577532e-08, 1.3242044582274781e-16, -1.0240055893684678e-23),
    (0.42096930742263794, -1.2778508917676845e-08, 6.143525731270704e-16, 1.419242178938019e-23),
    (0.4151833653450012, -7.767916088141646e-09, 5.955443124124071e-16, 2.732668133771502e-23),
    (0.4093637466430664, 1.8807551072086426e-09, 1.9153331349462894e-16, -5.6208063158075e-24),
    (0.40351009368896484, -2.0416603518924603e-08, -2.93405013148838e-16, 1.894346911970581e-24),
    (0.39762192964553833, 1.0016001361634608e-09, 2.2863242352463633e-17, 9.458133611770764e-25),
    (0.3916988968849182, 1.545909711353488e-08, 1.0962823446210085e-15, 3.108302239821126e-23),
    (0.3864043951034546, -2.076412375373593e-09, 1.5073464810114547e-16, 7.412449454375094e-24),
    (0.38041436672210693, -8.244395388601333e-09, 1.4866224964678982e-16, -3.927292740683968e-24),
    (0.3743882179260254, 9.158529934438775e-09, 5.656919067358501e-16, 3.4213474905617904e-23),
    (0.36900103092193604, -2.2253590969967263e-08, 6.231405399548338e-16, -2.1564751355837555e-23),
    (0.36358463764190674, -2.6778728567933285e-08, -9.943908455716573e-16, -4.704929732945495e-24),
    (0.35745590925216675, -2.033036139437172e-08, -1.5794492077344114e-15, 6.318678032068057e-23),
    (0.3519763946533203, 2.850385882879891e-08, -9.566434575519799e-16, -6.409595040255684e-24),
    (0.3464667797088623, -1.236265312343221e-08, -6.003368248279719e-16, -2.860901497105794e-24),
    (0.3409265875816345, -6.110413286464222e-10, 1.7467136243918857e-17, 1.9962587429804357e-25),
    (0.3353555202484131, 2.167272583619706e-08, -1.0918773497788125e-15, -3.047574780704126e-23),
    (0.33045530319213867, -1.608884048209802e-08, -3.833435008838916e-16, -7.683741875124221e-24),
    (0.3248254060745239, 2.801670362373443e-08, -2.0725720961098414e-16, 1.3160777896524739e-23),
    (0.3191636800765991, 2.6222629401218e-08, -1.3995222573204161e-15, 8.599883909680833e-23),
    (0.31418323516845703, 2.6826626253750874e-08, -9.792556373536439e-16, 2.2954960929108544e-23),
    (0.3084607720375061, 1.368350943664609e-08, 5.591995050742643e-16, -1.1938701403427125e-23),
    (0.3034266233444214, -8.629042369534545e-09, -5.222554219259392e-16, 3.228770766379237e-23),
    (0.2983669638633728, 8.688424202318856e-09, 2.764116793423446e-16, -1.0171858868428321e-23),
    (0.29255300760269165, -4.91631446664087e-09, 2.562284723960507e-16, -2.6341575505102177e-23),
    (0.28743791580200195, -1.3782395669181824e-08, 7.29039351877645e-16, -4.431977943282236e-24),
    (0.28229647874832153, 2.3770866164340987e-08, 6.449228392264254e-16, 3.417536976845211e-23),
    (0.27712851762771606, 1.4733029018998423e-08, 6.793364114448283e-16, 3.593898034032222e-24),
    (0.27193373441696167, -1.8933320689029642e-08, 7.77939410955583e-16, 2.591972424742619e-23),
    (0.2667117714881897, 1.4300387263244119e-11, -7.458876800955772e-19, 4.247418782257993e-26),
    (0.2622140049934387, 7.802219315067305e-09, 5.022431038767539e-16, -2.4063174816868367e-23),
    (0.25694090127944946, 2.9618050234603288e-08, 7.279528203645545e-16, 2.638556081145549e-23),
    (0.2516399025917053, -6.44787778725231e-09, 4.122028133693521e-16, 7.427559296153698e-24),
    (0.2470736801624298, -1.9981829524340355e-09, -1.0909757890855787e-16, 6.236552089808213e-24),
    (0.24171993136405945, 5.523085988556886e-09, -2.686547633696265e-16, -2.764495989170092e-24),
    (0.23710808157920837, 1.0085374313462125e-08, -4.775626813761317e-16, 2.330620598032363e-23),
    (0.231700599193573, -1.3946383603524737e-08, 1.0970921279709183e-17, 3.229909378627549e-25),
    (0.22704219818115234, -6.451284839670279e-09, -4.2529947798112047e-16, -1.0260254677162862e-23),
    (0.2223619818687439, 1.4110645096820917e-08, 6.025568981827254e-16, 1.9385180739531644e-23),
    (0.21765980124473572, -8.286782815503102e-09, 5.232363919579781e-16, 5.078443538654066e-23),
    (0.21214580535888672, -8.254218641923217e-09, 3.255553133321774e-16, 1.571430013634162e-23),
    (0.20739519596099854, -1.6149279691290985e-09, 2.1131592679643073e-17, 1.4275617427027514e-24),
    (0.20262190699577332, 8.597639933327628e-09, -3.3804619056798137e-16, 2.5623235609364303e-24),
    (0.19782572984695435, 1.348296585490516e-08, -3.2024568730231384e-16, -2.5712252251631252e-23),
    (0.1930064558982849, 9.956859781112826e-10, 9.001674563844606e-17, -3.754797654135173e-24),
    (0.1889725625514984, 4.2415360113068346e-09, 3.8086815297465933e-16, -2.1147402916208568e-23),
    (0.18411031365394592, 6.931054841174955e-09, -3.4784858522920016e-16, 2.4665943434547742e-23),
    (0.17922431230545044, 5.0739235035734964e-09, 3.2221329189922637e-16, -1.0379009008973928e-23),
    (0.17431432008743286, 3.794385250444066e-09, 3.190066898587176e-16, 2.0292714723890484e-23),
    (0.17020416259765625, 3.4223344158590407e-09, -1.8846416901959178e-16, 1.1415315069779235e-23),
    (0.16524958610534668, -1.3210039284672348e-08, -2.3213954359040806e-16, 3.043054213286757e-24),
    (0.1602703034877777, 6.007922159767531e-09, -7.521047737154288e-17, -1.2649106048711768e-25),
    (0.15610191226005554, -1.2301535790015805e-08, 3.0175617567361414e-16, -8.633806506327147e-24),
    (0.15191605687141418, -1.4845571882915465e-08, -3.265830289949929e-16, -1.5268151962784823e-23),
    (0.14686977863311768, -4.6748995785605985e-09, -4.294291341758996e-16, 1.328295982896899e-23),
    (0.142645001411438, 9.186472027522541e-09, -8.049373155998929e-16, 1.437998766909278e-23),
    (0.1384023129940033, 9.86511672351753e-09, -8.837306496940929e-16, 7.295324909194215e-24),
    (0.1332872211933136, 9.990350768873668e-10, 3.316946610734358e-17, 2.7351440526086287e-24),
    (0.129004567861557, -7.46120853989396e-09, -6.212113165383437e-16, 1.855187264989731e-24),
    (0.12470348179340363, -3.2924463155836747e-09, -7.404120132741752e-17, 1.3246955625609024e-24),
    (0.12038381397724152, 3.3791991427278845e-09, 1.6214981996371606e-16, -6.00070673940474e-24),
    (0.11604541540145874, 3.5638392237302696e-10, -7.354219635108878e-18, 7.794312440645008e-26),
    (0.11168810725212097, 3.136765958089427e-09, -8.994406293238225e-19, -7.920937558182207e-26),
    (0.10731174051761627, -4.728527791542092e-09, -4.2976339455270984e-16, 5.351143287258107e-24),
    (0.10291612148284912, 2.8332007850906393e-09, 4.925742757234052e-17, 2.794436810397303e-24),
    (0.09850110113620758, 4.970725164810119e-09, 4.130512756847049e-16, 6.313449560595865e-25),
    (0.09406651556491852, -6.525850970717784e-09, -1.3492816627243298e-16, -9.079650179574527e-24),
    (0.08961215615272522, 2.5369617517867482e-09, 1.6110664594961319e-16, -5.189504504486964e-24),
    (0.08603434264659882, -5.304795713811927e-09, 5.127575488441481e-17, 1.463615545692133e-24),
    (0.08154398202896118, 2.0112156384755053e-09, 8.065769331577608e-17, -3.0150319017810437e-24),
    (0.07703337073326111, 5.7495661565099e-09, -2.503851097302985e-16, -1.846143093040508e-23),
    (0.07250232994556427, 1.177662634077592e-09, -3.525476857925506e-17, 1.3164077898906505e-24),
    (0.0688626617193222, -7.043545302565235e-09, 2.49712406751501e-16, 1.0686882487619963e-23),
    (0.06429435312747955, -2.422082090447475e-09, -2.0555896149129847e-16, 8.602907613530545e-24),
    (0.0606246218085289, 7.905943261166115e-12, -8.270443345471096e-19, -2.3533820836754142e-26),
    (0.056018441915512085, -5.139745296034448e-10, -3.811651571366802e-17, 1.9072195442219776e-24),
    (0.052318163216114044, -3.5574325707443677e-09, 9.191155834145393e-17, -5.321463973420977e-24),
    (0.04767347127199173, -1.8026349302147082e-09, 1.0329634289704177e-16, -2.2283569301283993e-24),
    (0.04394212365150452, -1.795005699634089e-09, -5.3817402974104447e-17, -1.3996196977941442e-24),
    (0.040196798741817474, 3.8451930528538014e-10, -2.4485452721520977e-17, -7.386769024377949e-26),
    (0.0354953333735466, -3.5901653872016936e-10, -2.073207767866976e-17, -2.412097216555168e-26),
    (0.0317181795835495, 6.87235046648027e-10, -6.430478093749473e-18, 1.3508692031871337e-25),
    (0.02792670577764511, 7.568773385813188e-10, -4.22031585165944e-17, 2.534760563692782e-24),
    (0.02412080392241478, -1.1255707477175747e-09, 4.89700584100947e-17, 1.4172214525647275e-24),
    (0.01934296265244484, 1.9068610579431322e-10, -1.0635946218849709e-17, -5.300489542457734e-25),
    (0.015504186972975731, -4.3701048335620385e-10, 6.61106154763715e-18, 2.5398086818405174e-25),
    (0.01165061630308628, 9.168890091615367e-10, -1.5848697818454755e-17, -1.350491609984469e-24),
    (0.007782140746712685, -3.046577434773212e-10, 7.793435996762285e-18, 4.660100148208369e-25),
    (0.0038986406289041042, -2.1324678134426733e-10, 1.2541658163801307e-19, 8.745035431740123e-27),
    (0.0, 0.0, 0.0, 0.0),
)

function _lgammacor(x::Float64)
    nalgm = 5
    xbig = 94906265.62425156
    xmax = 3.745194030963158e306
    if x < 10
        return NaN
    elseif x >= xmax
        _warn_underflow("lgammacor")
    elseif x < xbig
        tmp = 10 / x
        return _chebyshev_eval(tmp * tmp * 2 - 1, _ALGMCS, nalgm) / x
    end
    return 1 / (x * 12)
end

const _S0 = 0.083333333333333333333
const _S1 = 0.00277777777777777777778
const _S2 = 0.00079365079365079365079365
const _S3 = 0.000595238095238095238095238
const _S4 = 0.0008417508417508417508417508

function _stirlerr(n::Float64)
    if n <= 15.0
        nn = n + n
        if nn == c_int(nn)
            k = c_int(nn)
            k < 0 && return NaN     # in C undefiniert; R ruft stirlerr nur mit n >= 0 auf
            return _SFERR_HALVES[k+1]
        end
        return _lgammafn(n + 1.0) - (n + 0.5) * clog(n) + n - M_LN_SQRT_2PI
    end
    nn = n * n
    n > 500 && return (_S0 - _S1 / nn) / n
    n > 80 && return (_S0 - (_S1 - _S2 / nn) / nn) / n
    n > 35 && return (_S0 - (_S1 - (_S2 - _S3 / nn) / nn) / nn) / n
    return (_S0 - (_S1 - (_S2 - (_S3 - _S4 / nn) / nn) / nn) / nn) / n
end

function _bd0(x::Float64, np_::Float64)
    (!isfinite(x) || !isfinite(np_) || np_ == 0.0) && return NaN
    if abs(x - np_) < 0.1 * (x + np_)
        v = (x - np_) / (x + np_)
        s = (x - np_) * v
        abs(s) < DBL_MIN && return s
        ej = 2 * x * v
        v *= v
        for j in 1:999
            ej *= v
            s_ = s
            s += ej / ((j << 1) + 1)
            s == s_ && return s
        end
        ml_warning("bd0($(_g(x)), $(_g(np_))): T.series failed to converge in 1000 it.; s=$(_g(s)), ej/(2j+1)=$(_g(ej / ((1000 << 1) + 1)))")
    end
    return x * clog(x / np_) + np_ - x
end

function _ebd0(x::Float64, M::Float64)
    Sb = 10
    S = 1024.0
    N = 128
    yl = yh = 0.0
    x == M && return yh, yl
    x == 0 && return M, yl
    M == 0 && return INF, yl
    M / x == INF && return M, yl
    r, e = Base.frexp(M / x)
    M_LN2 * Float64(-e) > 1.0 + DBL_MAX / x && return INF, yl
    i = c_int(floor((r - 0.5) * (2 * N) + 0.5))
    f = floor(S / (0.5 + i / (2.0 * N)) + 0.5)
    fg = cldexp(f, -(e + Sb))
    fg == INF && return fg, yl
    (0 <= i <= N) || return NaN, yl      # nur bei NaN-Argumenten (in C undefiniert)
    @inline add1(d, yh, yl) = (d1 = floor(d + 0.5); d2 = d - d1; (yh + d1, yl + d2))
    yh, yl = add1(-x * _log1pmx((M * fg - x) / x), yh, yl)
    fg == 1 && return yh, yl
    sc_i = _BD0_SCALE[i+1]
    sc_0 = _BD0_SCALE[1]
    for j in 1:4
        yh, yl = add1(x * sc_i[j], yh, yl)
        yh, yl = add1(-x * sc_0[j] * e, yh, yl)
        isfinite(yh) || return INF, 0.0
    end
    yh, yl = add1(M, yh, yl)
    yh, yl = add1(-M * fg, yh, yl)
    return yh, yl
end

const _M_SQRT_2PI = 2.50662827463100050241576528481104525301
const _X_LRG = 2.86111748575702815380240589208115399625e+307

function _dpois_raw(x::Float64, lam::Float64, give_log::Bool)
    if lam == 0
        x == 0 && return give_log ? 0.0 : 1.0
        return give_log ? NINF : 0.0
    end
    isfinite(lam) || return give_log ? NINF : 0.0
    x < 0 && return give_log ? NINF : 0.0
    x <= lam * DBL_MIN && return give_log ? -lam : cexp(-lam)
    if lam < x * DBL_MIN
        isfinite(x) || return give_log ? NINF : 0.0
        v = -lam + x * clog(lam) - _lgammafn(x + 1)
        return give_log ? v : cexp(v)
    end
    yh, yl = _ebd0(x, lam)
    yl += _stirlerr(x)
    Lrg_x = x >= _X_LRG
    r = Lrg_x ? _M_SQRT_2PI * csqrt(x) : M_2PI * x
    give_log && return -yl - yh - (Lrg_x ? clog(r) : 0.5 * clog(r))
    return cexp(-yl) * cexp(-yh) / (Lrg_x ? r : csqrt(r))
end

function _dpois(x::Float64, lam::Float64, give_log::Bool)
    (isnan(x) || isnan(lam)) && return x + lam
    lam < 0 && return NaN
    if R_nonint(x)
        ml_warning("non-integer x = $(_f(x))")
        return give_log ? NINF : 0.0
    end
    (x < 0 || !isfinite(x)) && return give_log ? NINF : 0.0
    x = R_forceint(x)
    return _dpois_raw(x, lam, give_log)
end

"Binomialdichte für reelle `x`, `n` (R's `dbinom_raw`)."
function _dbinom_raw(x::Float64, n::Float64, p::Float64, q::Float64, give_log::Bool)
    p == 0 && return x == 0 ? _D1(give_log) : _D0(give_log)
    q == 0 && return x == n ? _D1(give_log) : _D0(give_log)
    if x == 0
        n == 0 && return _D1(give_log)
        lc = p < 0.1 ? -_bd0(n, n * q) - n * p : n * clog(q)
        return give_log ? lc : cexp(lc)
    end
    if x == n
        lc = q < 0.1 ? -_bd0(n, n * p) - n * q : n * clog(p)
        return give_log ? lc : cexp(lc)
    end
    (x < 0 || x > n) && return _D0(give_log)
    lc = _stirlerr(n) - _stirlerr(x) - _stirlerr(n - x) - _bd0(x, n * p) - _bd0(n - x, n * q)
    lf = M_LN_2PI + clog(x) + clog1p(-x / n)
    return give_log ? lc - 0.5 * lf : cexp(lc - 0.5 * lf)
end

function _dbinom(x::Float64, n::Float64, p::Float64, give_log::Bool)
    (isnan(x) || isnan(n) || isnan(p)) && return x + n + p
    (p < 0 || p > 1 || n < 0 || R_nonint(n)) && return NaN
    if R_nonint(x)
        ml_warning("non-integer x = $(_f(x))")
        return _D0(give_log)
    end
    (x < 0 || !isfinite(x)) && return _D0(give_log)
    n = R_forceint(n)
    x = R_forceint(x)
    return _dbinom_raw(x, n, p, 1 - p, give_log)
end

# ══ gamma, lgamma, beta ════════════════════════════════════════════════════

function _sinpi(x::Float64)
    isnan(x) && return x
    isfinite(x) || return NaN
    x = cfmod(x, 2.0)
    if x <= -1
        x += 2.0
    elseif x > 1.0
        x -= 2.0
    end
    (x == 0.0 || x == 1.0) && return 0.0
    x == 0.5 && return 1.0
    x == -0.5 && return -1.0
    return csin(M_PI * x)
end

function _cospi(x::Float64)
    isnan(x) && return x
    isfinite(x) || return NaN
    x = cfmod(abs(x), 2.0)
    cfmod(x, 1.0) == 0.5 && return 0.0
    x == 1.0 && return -1.0
    x == 0.0 && return 1.0
    return ccos(M_PI * x)
end

"R's `Rtanpi` (glibc 2.39 hat kein `tanpi`)."
function _tanpi(x::Float64)
    isnan(x) && return x
    isfinite(x) || return NaN
    x = cfmod(x, 1.0)
    if x <= -0.5
        x += 1
    elseif x > 0.5
        x -= 1
    end
    x == 0.0 && return 0.0
    x == 0.5 && return NaN
    x == 0.25 && return 1.0
    x == -0.25 && return -1.0
    return ctan(M_PI * x)
end

const _G_NGAM = 22
const _G_XMIN = -170.5674972726612
const _G_XMAX = 171.61447887182298
const _G_XSML = 2.2474362225598545e-308
const _G_DXREL = 1.490116119384765696e-8

"Gammafunktion (R's `gammafn`)."
function _gammafn(x::Float64)
    isnan(x) && return x
    (x == 0 || (x < 0 && (!isfinite(x) || x == floor(x)))) && return NaN
    y = abs(x)
    if y <= 10
        n = c_int(x)
        x < 0 && (n -= 1)
        y = x - n
        n -= 1
        value = _chebyshev_eval(y * 2 - 1, _GAMCS, _G_NGAM) + 0.9375
        n == 0 && return value
        if n < 0
            (x < -0.5 && abs(x - c_int(x - 0.5) / x) < _G_DXREL) && _warn_precision("gammafn")
            if y < _G_XSML
                _warn_range("gammafn")
                return x > 0 ? INF : NINF
            end
            n = -n
            for i in 0:n-1
                value /= (x + i)
            end
            return value
        else
            for i in 1:n
                value *= (y + i)
            end
            return value
        end
    else
        x > _G_XMAX && return INF
        x < _G_XMIN && return 0.0
        if y <= 50 && y == c_int(y)
            value = 1.0
            for i in 2:c_int(y)-1
                value *= i
            end
        else
            # (2*y == (int)2*y) ist in C immer wahr ((int)2 * y)
            value = cexp((y - 0.5) * clog(y) - y + M_LN_SQRT_2PI + _stirlerr(y))
        end
        x > 0 && return value
        abs((x - c_int(x - 0.5)) / x) < _G_DXREL && _warn_precision("gammafn")
        sinpiy = _sinpi(y)
        if sinpiy == 0
            _warn_range("gammafn")
            return INF
        end
        return -M_PI / (y * sinpiy * value)
    end
end

const _LG_XMAX = 2.5327372760800758e+305
const _LG_DXREL = 1.490116119384765625e-8

"`(lgamma(x), sign(gamma(x)))` wie R's `lgammafn_sign`."
function _lgammafn_sign(x::Float64)
    sgn = 1
    isnan(x) && return x, sgn
    (x < 0 && cfmod(floor(-x), 2.0) == 0) && (sgn = -1)
    (x <= 0 && x == ctrunc(x)) && return INF, sgn
    y = abs(x)
    y < 1e-306 && return -clog(y), sgn
    y <= 10 && return clog(abs(_gammafn(x))), sgn
    y > _LG_XMAX && return INF, sgn
    if x > 0
        if x > 1e17
            return x * (clog(x) - 1.0), sgn
        elseif x > 4934720.0
            return M_LN_SQRT_2PI + (x - 0.5) * clog(x) - x, sgn
        else
            return M_LN_SQRT_2PI + (x - 0.5) * clog(x) - x + _lgammacor(x), sgn
        end
    end
    sinpiy = abs(_sinpi(y))
    if sinpiy == 0
        ml_warning(" ** should NEVER happen! *** [lgamma.c: Neg.int, y=$(_g(y))]")
        return NaN, sgn
    end
    ans = M_LN_SQRT_PId2 + (x - 0.5) * clog(y) - x - clog(sinpiy) - _lgammacor(y)
    abs((x - ctrunc(x - 0.5)) * ans / x) < _LG_DXREL && _warn_precision("lgamma")
    return ans, sgn
end

"`log|Gamma(x)|` (R's `lgammafn`, nicht C-`lgamma`)."
function _lgammafn(x::Float64)
    isnan(x) && return x
    (x <= 0 && x == ctrunc(x)) && return INF
    y = abs(x)
    y < 1e-306 && return -clog(y)
    y <= 10 && return clog(abs(_gammafn(x)))
    y > _LG_XMAX && return INF
    if x > 0
        if x > 1e17
            return x * (clog(x) - 1.0)
        elseif x > 4934720.0
            return M_LN_SQRT_2PI + (x - 0.5) * clog(x) - x
        else
            return M_LN_SQRT_2PI + (x - 0.5) * clog(x) - x + _lgammacor(x)
        end
    end
    return _lgammafn_sign(x)[1]
end

"`log(beta(a, b))` (R's `lbeta`)."
function lbeta_(a::Float64, b::Float64)
    (isnan(a) || isnan(b)) && return a + b
    p = q = a
    b < p && (p = b)
    b > q && (q = b)
    if p < 0
        return NaN
    elseif p == 0
        return INF
    elseif !isfinite(q)
        return NINF
    end
    if p >= 10
        corr = _lgammacor(p) + _lgammacor(q) - _lgammacor(p + q)
        return clog(q) * -0.5 + M_LN_SQRT_2PI + corr + (p - 0.5) * clog(p / (p + q)) + q * clog1p(-p / (p + q))
    elseif q >= 10
        corr = _lgammacor(q) - _lgammacor(p + q)
        return _lgammafn(p) + corr + p - p * clog(p + q) + (q - 0.5) * clog1p(-p / (p + q))
    else
        if p < 1e-306
            return clgamma(p) + (clgamma(q) - clgamma(p + q))
        else
            return clog(_gammafn(p) * (_gammafn(q) / _gammafn(p + q)))
        end
    end
end

"Betafunktion (R's `beta`)."
function beta_(a::Float64, b::Float64)
    xmax = 171.61447887182298
    (isnan(a) || isnan(b)) && return a + b
    if a < 0 || b < 0
        return NaN
    elseif a == 0 || b == 0
        return INF
    elseif !isfinite(a) || !isfinite(b)
        return 0.0
    end
    if a + b < xmax
        return (1 / _gammafn(a + b)) * _gammafn(a) * _gammafn(b)
    else
        return cexp(lbeta_(a, b))
    end
end

# ══ Normalverteilung ══════════════════════════════════════════════════════

const _DNORM_BIG = 2 * Base.sqrt(DBL_MAX)
const _DNORM_UFL = Base.sqrt(-2 * M_LN2 * (DBL_MIN_EXP + 1 - DBL_MANT_DIG))

function dnorm4(x::Float64, mu::Float64, sigma::Float64, give_log::Bool)
    (isnan(x) || isnan(mu) || isnan(sigma)) && return x + mu + sigma
    sigma < 0 && return NaN
    isfinite(sigma) || return give_log ? NINF : 0.0
    (!isfinite(x) && mu == x) && return NaN
    sigma == 0 && return (x == mu) ? INF : (give_log ? NINF : 0.0)
    x = (x - mu) / sigma
    isfinite(x) || return give_log ? NINF : 0.0
    x = abs(x)
    x >= _DNORM_BIG && return give_log ? NINF : 0.0
    give_log && return -(M_LN_SQRT_2PI + 0.5 * x * x + clog(sigma))
    x < 5 && return M_1_SQRT_2PI * cexp(-0.5 * x * x) / sigma
    x > _DNORM_UFL && return 0.0
    x1 = cldexp(R_forceint(cldexp(x, 16)), -16)
    x2 = x - x1
    return M_1_SQRT_2PI / sigma * (cexp(-0.5 * x1 * x1) * cexp((-0.5 * x2 - x1) * x2))
end

function pnorm5(x::Float64, mu::Float64, sigma::Float64, lower_tail::Bool, log_p::Bool)
    (isnan(x) || isnan(mu) || isnan(sigma)) && return x + mu + sigma
    (!isfinite(x) && mu == x) && return NaN
    if sigma <= 0
        sigma < 0 && return NaN
        return x < mu ? _DT0(lower_tail, log_p) : _DT1(lower_tail, log_p)
    end
    p = (x - mu) / sigma
    isfinite(p) || return x < mu ? _DT0(lower_tail, log_p) : _DT1(lower_tail, log_p)
    cum, ccum = pnorm_both(p, lower_tail ? 0 : 1, log_p)
    return lower_tail ? cum : ccum
end

const _PN_A = (2.2352520354606839287, 161.02823106855587881, 1067.6894854603709582,
               18154.981253343561249, 0.065682337918207449113)
const _PN_B = (47.20258190468824187, 976.09855173777669322, 10260.932208618978205,
               45507.789335026729956)
const _PN_C = (0.39894151208813466764, 8.8831497943883759412, 93.506656132177855979,
               597.27027639480026226, 2494.5375852903726711, 6848.1904505362823326,
               11602.651437647350124, 9842.7148383839780218, 1.0765576773720192317e-8)
const _PN_D = (22.266688044328115691, 235.38790178262499861, 1519.377599407554805,
               6485.558298266760755, 18615.571640885098091, 34900.952721145977266,
               38912.003286093271411, 19685.429676859990727)
const _PN_P = (0.21589853405795699, 0.1274011611602473639, 0.022235277870649807,
               0.001421619193227893466, 2.9112874951168792e-5, 0.02307344176494017303)
const _PN_Q = (1.28426009614491121, 0.468238212480865118, 0.0659881378689285515,
               0.00378239633202758244, 7.29751555083966205e-5)
const _PN_EPS = DBL_EPSILON * 0.5

"`(cum, ccum)` wie R's `pnorm_both` (`i_tail` 0/1/2 = unten/oben/beide)."
function pnorm_both(x::Float64, i_tail::Integer, log_p::Bool)
    cum = ccum = NaN
    isnan(x) && return x, x
    lower = i_tail != 1
    upper = i_tail != 0
    y = abs(x)
    local temp::Float64, X::Float64
    if y <= 0.67448975
        if y > _PN_EPS
            a = _PN_A; b = _PN_B
            xsq = x * x
            xnum = a[5] * xsq
            xden = xsq
            for i in 1:3
                xnum = (xnum + a[i]) * xsq
                xden = (xden + b[i]) * xsq
            end
        else
            xnum = xden = 0.0
        end
        temp = x * (xnum + _PN_A[4]) / (xden + _PN_B[4])
        lower && (cum = 0.5 + temp)
        upper && (ccum = 0.5 - temp)
        if log_p
            lower && (cum = clog(cum))
            upper && (ccum = clog(ccum))
        end
        return cum, ccum
    elseif y <= M_SQRT_32
        c = _PN_C; d = _PN_D
        xnum = c[9] * y
        xden = y
        for i in 1:7
            xnum = (xnum + c[i]) * y
            xden = (xden + d[i]) * y
        end
        temp = (xnum + c[8]) / (xden + d[8])
        X = y
    elseif (log_p && y < 1e170) || (lower && -37.5193 < x < 8.2924) || (upper && -8.2924 < x < 37.5193)
        p = _PN_P; q = _PN_Q
        xsq = 1.0 / (x * x)
        xnum = p[6] * xsq
        xden = xsq
        for i in 1:4
            xnum = (xnum + p[i]) * xsq
            xden = (xden + q[i]) * xsq
        end
        temp = xsq * (xnum + p[5]) / (xden + q[5])
        temp = (M_1_SQRT_2PI - temp) / y
        X = x
    else
        if x > 0
            return _D1(log_p), _D0(log_p)
        end
        return _D0(log_p), _D1(log_p)
    end

    # do_del(X)
    xsq = trunc(X * 16.0) * 0.0625
    dl = (X - xsq) * (X + xsq)
    if log_p
        cum = (-xsq * (xsq * 0.5)) - dl * 0.5 + clog(temp)
        if (lower && x > 0.0) || (upper && x <= 0.0)
            ccum = clog1p(-cexp(-xsq * (xsq * 0.5)) * cexp(-(dl * 0.5)) * temp)
        end
    else
        cum = cexp(-xsq * (xsq * 0.5)) * cexp(-(dl * 0.5)) * temp
        ccum = 1.0 - cum
    end
    # swap_tail
    if x > 0.0
        temp = cum
        lower && (cum = ccum)
        ccum = temp
    end
    return cum, ccum
end

function qnorm5(p::Float64, mu::Float64, sigma::Float64, lower_tail::Bool, log_p::Bool)
    (isnan(p) || isnan(mu) || isnan(sigma)) && return p + mu + sigma
    # R_Q_P01_boundaries(p, ML_NEGINF, ML_POSINF)
    if log_p
        p > 0 && return NaN
        p == 0 && return lower_tail ? INF : NINF
        p == NINF && return lower_tail ? NINF : INF
    else
        (p < 0 || p > 1) && return NaN
        p == 0 && return lower_tail ? NINF : INF
        p == 1 && return lower_tail ? INF : NINF
    end
    sigma < 0 && return NaN
    sigma == 0 && return mu

    p_ = log_p ? (lower_tail ? cexp(p) : -cexpm1(p)) : (lower_tail ? p : (0.5 - p + 0.5))
    q = p_ - 0.5
    local val::Float64
    if abs(q) <= 0.425
        r = 0.180625 - q * q
        val = q * (((((((r * 2509.0809287301226727 +
                         33430.575583588128105) * r + 67265.770927008700853) * r +
                       45921.953931549871457) * r + 13731.693765509461125) * r +
                     1971.5909503065514427) * r + 133.14166789178437745) * r +
                   3.387132872796366608) /
              (((((((r * 5226.495278852854561 +
                     28729.085735721942674) * r + 39307.89580009271061) * r +
                   21213.794301586595867) * r + 5394.1960214247511077) * r +
                 687.1870074920579083) * r + 42.313330701600911252) * r + 1.0)
    else
        if log_p && ((lower_tail && q <= 0) || (!lower_tail && q > 0))
            lp = p
        else
            if q > 0
                arg = log_p ? (lower_tail ? -cexpm1(p) : cexp(p)) : (lower_tail ? (0.5 - p + 0.5) : p)
            else
                arg = p_
            end
            lp = clog(arg)
        end
        r = csqrt(-lp)
        if r <= 5.0
            r += -1.6
            val = (((((((r * 7.7454501427834140764e-4 +
                         0.0227238449892691845833) * r + 0.24178072517745061177) *
                       r + 1.27045825245236838258) * r +
                      3.64784832476320460504) * r + 5.7694972214606914055) *
                    r + 4.6303378461565452959) * r +
                   1.42343711074968357734) /
                  (((((((r *
                         1.05075007164441684324e-9 + 5.475938084995344946e-4) *
                        r + 0.0151986665636164571966) * r +
                       0.14810397642748007459) * r + 0.68976733498510000455) *
                     r + 1.6763848301838038494) * r +
                    2.05319162663775882187) * r + 1.0)
        elseif r <= 27
            r += -5.0
            val = (((((((r * 2.01033439929228813265e-7 +
                         2.71155556874348757815e-5) * r +
                        0.0012426609473880784386) * r + 0.026532189526576123093) *
                      r + 0.29656057182850489123) * r +
                     1.7848265399172913358) * r + 5.4637849111641143699) *
                   r + 6.6579046435011037772) /
                  (((((((r *
                         2.04426310338993978564e-15 + 1.4215117583164458887e-7) *
                        r + 1.8463183175100546818e-5) * r +
                       7.868691311456132591e-4) * r + 0.0148753612908506148525)
                     * r + 0.13692988092273580531) * r +
                    0.59983220655588793769) * r + 1.0)
        else
            if r >= 6.4e8
                val = r * M_SQRT2
            else
                s2 = -(2.0 * lp)
                x2 = s2 - clog(M_2PI * s2)
                if r < 36000.0
                    x2 = s2 - clog(M_2PI * x2) - 2.0 / (2.0 + x2)
                    if r < 840.0
                        x2 = s2 - clog(M_2PI * x2) + 2 * clog1p(-(1 - 1 / (4 + x2)) / (2.0 + x2))
                        if r < 109.0
                            x2 = s2 - clog(M_2PI * x2) +
                                 2 * clog1p(-(1 - (1 - 5 / (6 + x2)) / (4.0 + x2)) / (2.0 + x2))
                            if r < 55.0
                                x2 = s2 - clog(M_2PI * x2) +
                                     2 * clog1p(-(1 - (1 - (5 - 9 / (8.0 + x2)) / (6.0 + x2)) / (4.0 + x2)) / (2.0 + x2))
                            end
                        end
                    end
                end
                val = csqrt(x2)
            end
        end
        q < 0.0 && (val = -val)
    end
    return mu + sigma * val
end

# ══ t-Verteilung ══════════════════════════════════════════════════════════

function dt_(x::Float64, n::Float64, give_log::Bool)
    (isnan(x) || isnan(n)) && return x + n
    n <= 0 && return NaN
    isfinite(x) || return give_log ? NINF : 0.0
    isfinite(n) || return dnorm4(x, 0.0, 1.0, give_log)

    t = -_bd0(n / 2.0, (n + 1) / 2.0) + _stirlerr((n + 1) / 2.0) - _stirlerr(n / 2.0)
    x2n = x * x / n
    ax = 0.0
    lrg_x2n = x2n > 1.0 / DBL_EPSILON
    if lrg_x2n
        ax = abs(x)
        l_x2n = clog(ax) - clog(n) / 2.0
        u = n * l_x2n
    elseif x2n > 0.2
        l_x2n = clog(1 + x2n) / 2.0
        u = n * l_x2n
    else
        l_x2n = clog1p(x2n) / 2.0
        u = -_bd0(n / 2.0, (n + x * x) / 2.0) + x * x / 2.0
    end
    give_log && return t - u - (M_LN_SQRT_2PI + l_x2n)
    I_sqrt_ = lrg_x2n ? (csqrt(n) / ax) : cexp(-l_x2n)
    return cexp(t - u) * M_1_SQRT_2PI * I_sqrt_
end

function pt_(x::Float64, n::Float64, lower_tail::Bool, log_p::Bool)
    (isnan(x) || isnan(n)) && return x + n
    n <= 0.0 && return NaN
    isfinite(x) || return x < 0 ? _DT0(lower_tail, log_p) : _DT1(lower_tail, log_p)
    isfinite(n) || return pnorm5(x, 0.0, 1.0, lower_tail, log_p)

    nx = 1 + (x / n) * x
    if nx > 1e100
        lval = -0.5 * n * (2 * clog(abs(x)) - clog(n)) - lbeta_(0.5 * n, 0.5) - clog(0.5 * n)
        val = log_p ? lval : cexp(lval)
    else
        val = n > x * x ? pbeta_(x * x / (n + x * x), 0.5, n / 2.0, false, log_p) :
                          pbeta_(1.0 / nx, n / 2.0, 0.5, true, log_p)
    end
    x <= 0.0 && (lower_tail = !lower_tail)
    if log_p
        return lower_tail ? clog1p(-0.5 * cexp(val)) : val - M_LN2
    else
        val /= 2.0
        return !lower_tail ? val : (0.5 - val + 0.5)
    end
end

function qt_(p::Float64, ndf::Float64, lower_tail::Bool, log_p::Bool)
    eps = 1.0e-12
    (isnan(p) || isnan(ndf)) && return p + ndf
    # R_Q_P01_boundaries(p, ML_NEGINF, ML_POSINF)
    if log_p
        p > 0 && return NaN
        p == 0 && return lower_tail ? INF : NINF
        p == NINF && return lower_tail ? NINF : INF
    else
        (p < 0 || p > 1) && return NaN
        p == 0 && return lower_tail ? NINF : INF
        p == 1 && return lower_tail ? INF : NINF
    end
    ndf <= 0 && return NaN

    if ndf < 1
        accu = 1e-13
        Eps = 1e-11
        iter_ = 0
        # p = R_DT_qIv(p)
        p = log_p ? (lower_tail ? cexp(p) : -cexpm1(p)) : (lower_tail ? p : (0.5 - p + 0.5))
        p > 1 - DBL_EPSILON && return INF
        pp = fmin2(1 - DBL_EPSILON, p * (1 + Eps))
        ux = 1.0
        while ux < DBL_MAX && pt_(ux, ndf, true, false) < pp
            ux *= 2
        end
        pp = p * (1 - Eps)
        lx = -1.0
        while lx > -DBL_MAX && pt_(lx, ndf, true, false) > pp
            lx *= 2
        end
        while true
            nx = 0.5 * (lx + ux)
            if pt_(nx, ndf, true, false) > p
                ux = nx
            else
                lx = nx
            end
            (ux - lx) / abs(nx) > accu || break
            iter_ += 1
            iter_ < 1000 || break
        end
        iter_ >= 1000 && _warn_precision("qt")
        return 0.5 * (lx + ux)
    end

    ndf > 1e20 && return qnorm5(p, 0.0, 1.0, lower_tail, log_p)

    P = log_p ? cexp(p) : p   # R_D_qIv(p)

    neg = (!lower_tail || P < 0.5) && (lower_tail || P > 0.5)
    is_neg_lower = (lower_tail == neg)
    if neg
        P = 2 * (log_p ? (lower_tail ? P : -cexpm1(p)) : (lower_tail ? p : (0.5 - p + 0.5)))
    else
        P = 2 * (log_p ? (lower_tail ? -cexpm1(p) : P) : (lower_tail ? (0.5 - p + 0.5) : p))
    end

    local q::Float64
    if abs(ndf - 2) < eps
        if P > DBL_MIN
            if 3 * P < DBL_EPSILON
                q = 1 / csqrt(P)
            elseif P > 0.9
                q = (1 - P) * csqrt(2 / (P * (2 - P)))
            else
                q = csqrt(2 / (P * (2 - P)) - 2)
            end
        else
            if log_p
                q = is_neg_lower ? (cexp(-p / 2) / M_SQRT2) : 1 / csqrt(-cexpm1(p))
            else
                q = INF
            end
        end
    elseif ndf < 1 + eps
        if P == 1.0
            q = 0.0
        elseif P > 0
            q = 1 / _tanpi(P / 2.0)
        else
            if log_p
                q = is_neg_lower ? (M_1_PI * cexp(-p)) : -1.0 / (M_PI * cexpm1(p))
            else
                q = INF
            end
        end
    else
        x = 0.0
        log_P2 = 0.0
        a = 1 / (ndf - 0.5)
        b = 48 / (a * a)
        c = ((20700 * a / b - 98) * a - 16) * a + 96.36
        d = ((94.5 / (b + c) - 3) / b + 1) * csqrt(a * M_PI_2) * ndf
        P_ok1 = P > DBL_MIN || !log_p
        P_ok = P_ok1
        y = 0.0
        if P_ok1
            y = cpow(d * P, 2.0 / ndf)
            P_ok = (y >= DBL_EPSILON)
        end
        if !P_ok
            if is_neg_lower
                log_P2 = log_p ? p : clog(p)                    # R_D_log(p)
            else
                log_P2 = log_p ? R_Log1_Exp(p) : clog1p(-p)     # R_D_LExp(p)
            end
            x = (clog(d) + M_LN2 + log_P2) / ndf
            y = cexp(2 * x)
        end

        if (ndf < 2.1 && P > 0.5) || y > 0.05 + a
            if P_ok
                x = qnorm5(0.5 * P, 0.0, 1.0, true, false)
            else
                x = qnorm5(log_P2, 0.0, 1.0, lower_tail, true)
            end
            y = x * x
            ndf < 5 && (c += 0.3 * (ndf - 4.5) * (x + 0.6))
            c = (((0.05 * d * x - 5) * x - 7) * x - 2) * x + b + c
            y = (((((0.4 * y + 6.3) * y + 36) * y + 94.5) / c - y - 3) / b + 1) * x
            y = cexpm1(a * y * y)
            q = csqrt(ndf * y)
        elseif !P_ok && x < -M_LN2 * DBL_MANT_DIG
            q = csqrt(ndf) * cexp(-x)
        else
            inner = (ndf + 6) / (ndf * y) - 0.089 * d - 0.822
            y = ((1 / (inner * (ndf + 2) * 3) + 0.5 / (ndf + 4)) * y - 1) * (ndf + 1) / (ndf + 2) + 1 / y
            q = csqrt(ndf * y)
        end

        if P_ok1
            M = abs(Base.sqrt(DBL_MAX / 2.0) - ndf)
            it = 0
            while true
                it += 1
                it - 1 < 10 || break
                y = dt_(q, ndf, false)
                y > 0 || break
                x = (pt_(q, ndf, false, false) - P / 2) / y
                isfinite(x) || break
                abs(x) > 1e-14 * abs(q) || break
                F = abs(q) < M ? (q * (ndf + 1) / (2 * (q * q + ndf))) : ((ndf + 1) / (2 * (q + ndf / q)))
                del_q = x * (1.0 + x * F)
                if isfinite(del_q) && isfinite(q + del_q)
                    q += del_q
                elseif isfinite(x) && isfinite(q + x)
                    q += x
                else
                    break
                end
            end
        end
    end
    return neg ? -q : q
end

# ══ Beta ══════════════════════════════════════════════════════════════════

function _pbeta_raw(x::Float64, a::Float64, b::Float64, lower_tail::Bool, log_p::Bool)
    x >= 1 && return _DT1(lower_tail, log_p)
    if a == 0 || b == 0 || !isfinite(a) || !isfinite(b)
        (a == 0 && b == 0) && return log_p ? -M_LN2 : 0.5
        (a == 0 || a / b == 0) && return _DT1(lower_tail, log_p)
        (b == 0 || b / a == 0) && return _DT0(lower_tail, log_p)
        x < 0.5 && return _DT0(lower_tail, log_p)
        return _DT1(lower_tail, log_p)
    end
    x <= 0 && return _DT0(lower_tail, log_p)
    x1 = 0.5 - x + 0.5
    w, wc, ierr = bratio(a, b, x, x1, log_p)
    if ierr != 0 && ierr != 11 && ierr != 14
        ml_warning("pbeta_raw($(_g(x)), a=$(_g(a)), b=$(_g(b)), lower=$(Int(lower_tail)), log=$(Int(log_p))) -> bratio() gave error code $ierr")
    end
    return lower_tail ? w : wc
end

function pbeta_(x::Float64, a::Float64, b::Float64, lower_tail::Bool, log_p::Bool)
    (isnan(x) || isnan(a) || isnan(b)) && return x + a + b
    (a < 0 || b < 0) && return NaN
    return _pbeta_raw(x, a, b, lower_tail, log_p)
end

# ══ Logistische Verteilung ════════════════════════════════════════════════

"`log(1 + exp(x))` ohne Überlauf (R's `log1pexp`)."
function _log1pexp(x::Float64)
    x <= 18.0 && return clog1p(cexp(x))
    x > 33.3 && return x
    return x + cexp(-x)
end

_log1mexp(x::Float64) = R_Log1_Exp(-x)

function plogis_(x::Float64, location::Float64, scale::Float64, lower_tail::Bool, log_p::Bool)
    (isnan(x) || isnan(location) || isnan(scale)) && return x + location + scale
    scale <= 0.0 && return NaN
    x = (x - location) / scale
    isnan(x) && return NaN
    isfinite(x) || return x > 0 ? _DT1(lower_tail, log_p) : _DT0(lower_tail, log_p)
    log_p && return -_log1pexp(lower_tail ? -x : x)
    return 1 / (1 + cexp(lower_tail ? -x : x))
end

function qlogis_(p::Float64, location::Float64, scale::Float64, lower_tail::Bool, log_p::Bool)
    (isnan(p) || isnan(location) || isnan(scale)) && return p + location + scale
    if log_p
        p > 0 && return NaN
        p == 0 && return lower_tail ? INF : NINF
        p == NINF && return lower_tail ? NINF : INF
    else
        (p < 0 || p > 1) && return NaN
        p == 0 && return lower_tail ? NINF : INF
        p == 1 && return lower_tail ? INF : NINF
    end
    scale < 0.0 && return NaN
    scale == 0.0 && return location
    if log_p
        p = lower_tail ? p - R_Log1_Exp(p) : R_Log1_Exp(p) - p
    else
        p = clog(lower_tail ? (p / (1.0 - p)) : ((1.0 - p) / p))
    end
    return location + scale * p
end

function dlogis_(x::Float64, location::Float64, scale::Float64, give_log::Bool)
    (isnan(x) || isnan(location) || isnan(scale)) && return x + location + scale
    scale <= 0.0 && return NaN
    x = abs((x - location) / scale)
    e = cexp(-x)
    f = 1.0 + e
    return give_log ? -(x + clog(scale * f * f)) : e / (scale * f * f)
end

# ══ Gamma-Verteilung (pgamma.c, dgamma.c, qgamma.c) ═══════════════════════

const _SCALEFACTOR = 1.157920892373162e+77   # 2^256
const _M_CUTOFF = M_LN2 * 1024 / DBL_EPSILON

function logcf(x::Float64, i::Float64, d::Float64, eps::Float64)
    c1 = 2 * d
    c2 = i + d
    c4 = c2 + d
    a1 = c2
    b1 = i * (c2 - i * x)
    b2 = d * d * x
    a2 = c4 * c2 - b2
    b2 = c4 * b1 - i * b2
    sf = _SCALEFACTOR
    while abs(a2 * b1 - a1 * b2) > abs(eps * b1 * b2)
        c3 = c2 * c2 * x
        c2 += d
        c4 += d
        a1 = c4 * a2 - c3 * a1
        b1 = c4 * b2 - c3 * b1

        c3 = c1 * c1 * x
        c1 += d
        c4 += d
        a2 = c4 * a1 - c3 * a2
        b2 = c4 * b1 - c3 * b2

        if abs(b2) > sf
            a1 /= sf; b1 /= sf; a2 /= sf; b2 /= sf
        elseif abs(b2) < 1 / sf
            a1 *= sf; b1 *= sf; a2 *= sf; b2 *= sf
        end
    end
    return a2 / b2
end

"`log(1+x) - x`, genau auch für kleine `x` (R's `log1pmx`)."
function _log1pmx(x::Float64)
    minLog1Value = -0.79149064
    if x > 1 || x < minLog1Value
        return clog1p(x) - x
    else
        r = x / (2 + x)
        y = r * r
        if abs(x) < 1e-2
            two = 2.0
            return r * ((((two / 9 * y + two / 7) * y + two / 5) * y + two / 3) * y - x)
        else
            tol_logcf = 1e-14
            return r * (2 * y * logcf(y, 3.0, 2.0, tol_logcf) - x)
        end
    end
end

"`log(gamma(a+1))`, genau auch für kleine `a` (R's `lgamma1p`)."
function _lgamma1p(a::Float64)
    abs(a) >= 0.5 && return _lgammafn(a + 1)
    eulers_const = 0.5772156649015328606065120900824024
    N = 40
    c = 0.2273736845824652515226821577978691e-12
    tol_logcf = 1e-14
    lgam = c * logcf(-a / 2, Float64(N + 2), 1.0, tol_logcf)
    for i in N-1:-1:0
        lgam = _LG1P_COEFFS[i+1] - a * lgam
    end
    return (a * lgam - eulers_const) * a - _log1pmx(a)
end

"""
    logspace_sum(logx)

`log(sum(exp(logx)))`. Hinweis: R rechnet hier mit `expl`/`logl` (long
double); diese sind nicht nachgebildet (Summe in F80 der double-`exp`) –
nicht bitgleich garantiert. Wird in SimLev nicht verwendet.
"""
function logspace_sum(logx)
    n = length(logx)
    n == 0 && return NINF
    n == 1 && return Float64(logx[1])
    n == 2 && return _logspace_add(Float64(logx[1]), Float64(logx[2]))
    Mx = Float64(logx[1])
    for i in 2:n
        Mx < logx[i] && (Mx = Float64(logx[i]))
    end
    s = SimLev.F80(0.0)
    for i in 1:n
        s = s + SimLev.F80(cexp(Float64(logx[i]) - Mx))
    end
    return Mx + clog(Float64(s))
end

function _dpois_wrap(x_plus_1::Float64, lam::Float64, give_log::Bool)
    isfinite(lam) || return give_log ? NINF : 0.0
    x_plus_1 > 1 && return _dpois_raw(x_plus_1 - 1, lam, give_log)
    if lam > abs(x_plus_1 - 1) * _M_CUTOFF
        v = -lam - _lgammafn(x_plus_1)
        return give_log ? v : cexp(v)
    else
        d = _dpois_raw(x_plus_1, lam, give_log)
        return give_log ? d + clog(x_plus_1 / lam) : d * (x_plus_1 / lam)
    end
end

function _pgamma_smallx(x::Float64, alph::Float64, lower_tail::Bool, log_p::Bool)
    sum_ = 0.0
    c = alph
    n = 0.0
    while true
        n += 1
        c *= -x / n
        term = c / (alph + n)
        sum_ += term
        abs(term) > DBL_EPSILON * abs(sum_) || break
    end
    if lower_tail
        f1 = log_p ? clog1p(sum_) : 1 + sum_
        if alph > 1
            f2 = _dpois_raw(alph, x, log_p)
            f2 = log_p ? f2 + x : f2 * cexp(x)
        elseif log_p
            f2 = alph * clog(x) - _lgamma1p(alph)
        else
            f2 = cpow(x, alph) / cexp(_lgamma1p(alph))
        end
        return log_p ? f1 + f2 : f1 * f2
    else
        lf2 = alph * clog(x) - _lgamma1p(alph)
        if log_p
            return R_Log1_Exp(clog1p(sum_) + lf2)
        else
            f1m1 = sum_
            f2m1 = cexpm1(lf2)
            return -(f1m1 + f2m1 + f1m1 * f2m1)
        end
    end
end

function _pd_upper_series(x::Float64, y::Float64, log_p::Bool)
    term = x / y
    sum_ = term
    while true
        y += 1
        term *= x / y
        sum_ += term
        term > sum_ * DBL_EPSILON || break
    end
    return log_p ? clog(sum_) : sum_
end

function _pd_lower_cf(y::Float64, d::Float64)
    f = 0.0
    max_it = 200000
    sf = _SCALEFACTOR
    y == 0 && return 0.0
    f0 = y / d
    abs(y - 1) < abs(d) * DBL_EPSILON && return f0
    f0 > 1.0 && (f0 = 1.0)
    c2 = y
    c4 = d
    a1 = 0.0
    b1 = 1.0
    a2 = y
    b2 = d
    while b2 > sf
        a1 /= sf; b1 /= sf; a2 /= sf; b2 /= sf
    end
    i = 0.0
    of = -1.0
    while i < max_it
        i += 1
        c2 -= 1
        c3 = i * c2
        c4 += 2
        a1 = c4 * a2 + c3 * a1
        b1 = c4 * b2 + c3 * b1

        i += 1
        c2 -= 1
        c3 = i * c2
        c4 += 2
        a2 = c4 * a1 + c3 * a2
        b2 = c4 * b1 + c3 * b2

        if b2 > sf
            a1 /= sf; b1 /= sf; a2 /= sf; b2 /= sf
        end
        if b2 != 0
            f = a2 / b2
            abs(f - of) <= DBL_EPSILON * fmax2(f0, abs(f)) && return f
            of = f
        end
    end
    ml_warning(" ** NON-convergence in pgamma()'s pd_lower_cf() f= $(_g(f)).")
    return f
end

function _pd_lower_series(lam::Float64, y::Float64)
    term = 1.0
    sum_ = 0.0
    while y >= 1 && term > sum_ * DBL_EPSILON
        term *= y / lam
        sum_ += term
        y -= 1
    end
    if y != floor(y)
        f = _pd_lower_cf(y, lam + 1 - y)
        sum_ += term * f
    end
    return sum_
end

function _dpnorm(x::Float64, lower_tail::Bool, lp::Float64)
    if x < 0
        x = -x
        lower_tail = !lower_tail
    end
    if x > 10 && !lower_tail
        term = 1 / x
        sum_ = term
        x2 = x * x
        i = 1.0
        while true
            term *= -i / x2
            sum_ += term
            i += 2
            abs(term) > DBL_EPSILON * sum_ || break
        end
        return 1 / sum_
    else
        d = dnorm4(x, 0.0, 1.0, false)
        return d / cexp(lp)
    end
end

const _PPA_A = (-1e99, 2 / 3.0, -4 / 135.0, 8 / 2835.0, 16 / 8505.0, -8992 / 12629925.0,
                -334144 / 492567075.0, 698752 / 1477701225.0)
const _PPA_B = (-1e99, 1 / 12.0, 1 / 288.0, -139 / 51840.0, -571 / 2488320.0, 163879 / 209018880.0,
                5246819 / 75246796800.0, -534703531 / 902961561600.0)

function _ppois_asymp(x::Float64, lam::Float64, lower_tail::Bool, log_p::Bool)
    coefs_a = _PPA_A
    coefs_b = _PPA_B
    dfm = lam - x
    pt__ = -_log1pmx(dfm / x)
    s2pt = csqrt(2 * x * pt__)
    dfm < 0 && (s2pt = -s2pt)

    res12 = 0.0
    res1_ig = res1_term = csqrt(x)
    res2_ig = res2_term = s2pt
    for i in 1:7
        res12 += res1_ig * coefs_a[i+1]
        res12 += res2_ig * coefs_b[i+1]
        res1_term *= pt__ / i
        res2_term *= 2 * pt__ / (2 * i + 1)
        res1_ig = res1_ig / x + res1_term
        res2_ig = res2_ig / x + res2_term
    end
    elfb = x
    elfb_term = 1.0
    for i in 1:7
        elfb += elfb_term * coefs_b[i+1]
        elfb_term = elfb_term / x
    end
    lower_tail || (elfb = -elfb)
    f = res12 / elfb
    np_ = pnorm5(s2pt, 0.0, 1.0, !lower_tail, log_p)
    if log_p
        n_d_over_p = _dpnorm(s2pt, !lower_tail, np_)
        return np_ + clog1p(f * n_d_over_p)
    else
        nd = dnorm4(s2pt, 0.0, 1.0, log_p)
        return np_ + f * nd
    end
end

"Regularisierte unvollständige Gammafunktion (R's `pgamma_raw`)."
function _pgamma_raw(x::Float64, alph::Float64, lower_tail::Bool, log_p::Bool)
    # R_P_bounds_01(x, 0., ML_POSINF)
    x <= 0.0 && return _DT0(lower_tail, log_p)
    x >= INF && return _DT1(lower_tail, log_p)
    local res::Float64
    if x < 1
        res = _pgamma_smallx(x, alph, lower_tail, log_p)
    elseif x <= alph - 1 && x < 0.8 * (alph + 50)
        sum_ = _pd_upper_series(x, alph, log_p)
        d = _dpois_wrap(alph, x, log_p)
        if !lower_tail
            res = log_p ? R_Log1_Exp(d + sum_) : 1 - d * sum_
        else
            res = log_p ? sum_ + d : sum_ * d
        end
    elseif alph - 1 < x && alph < 0.8 * (x + 50)
        d = _dpois_wrap(alph, x, log_p)
        if alph < 1
            if x * DBL_EPSILON > 1 - alph
                sum_ = log_p ? 0.0 : 1.0
            else
                f = _pd_lower_cf(alph, x - (alph - 1)) * x / alph
                sum_ = log_p ? clog(f) : f
            end
        else
            sum_ = _pd_lower_series(x, alph - 1)
            sum_ = log_p ? clog1p(sum_) : 1 + sum_
        end
        if !lower_tail
            res = log_p ? sum_ + d : sum_ * d
        else
            res = log_p ? R_Log1_Exp(d + sum_) : 1 - d * sum_
        end
    else
        res = _ppois_asymp(alph - 1, x, !lower_tail, log_p)
    end
    (!log_p && res < DBL_MIN / DBL_EPSILON) && return cexp(_pgamma_raw(x, alph, lower_tail, true))
    return res
end

function pgamma_(x::Float64, alph::Float64, scale::Float64, lower_tail::Bool, log_p::Bool)
    (isnan(x) || isnan(alph) || isnan(scale)) && return x + alph + scale
    (alph < 0.0 || scale <= 0.0) && return NaN
    x /= scale
    isnan(x) && return x
    if alph == 0.0
        return x <= 0 ? _DT0(lower_tail, log_p) : _DT1(lower_tail, log_p)
    end
    return _pgamma_raw(x, alph, lower_tail, log_p)
end

function dgamma_(x::Float64, shape::Float64, scale::Float64, give_log::Bool)
    (isnan(x) || isnan(shape) || isnan(scale)) && return x + shape + scale
    (shape < 0 || scale <= 0) && return NaN
    x < 0 && return give_log ? NINF : 0.0
    shape == 0 && return x == 0 ? INF : (give_log ? NINF : 0.0)
    if x == 0
        shape < 1 && return INF
        shape > 1 && return give_log ? NINF : 0.0
        return give_log ? -clog(scale) : 1 / scale
    end
    if shape < 1
        pr = _dpois_raw(shape, x / scale, give_log)
        if give_log
            return pr + (isfinite(shape / x) ? clog(shape / x) : clog(shape) - clog(x))
        end
        return pr * shape / x
    end
    pr = _dpois_raw(shape - 1, x / scale, give_log)
    return give_log ? pr - clog(scale) : pr / scale
end

@inline _R_DT_log(p::Float64, lower_tail::Bool, log_p::Bool) =
    lower_tail ? (log_p ? p : clog(p)) : (log_p ? R_Log1_Exp(p) : clog1p(-p))
@inline _R_DT_Clog(p::Float64, lower_tail::Bool, log_p::Bool) =
    lower_tail ? (log_p ? R_Log1_Exp(p) : clog1p(-p)) : (log_p ? p : clog(p))

"Startwert für qgamma (AS 91; R's `qchisq_appr`)."
function _qchisq_appr(p::Float64, nu::Float64, g::Float64, lower_tail::Bool, log_p::Bool, tol::Float64)
    C7 = 4.67
    C8 = 6.66
    C9 = 6.73
    C10 = 13.32
    (isnan(p) || isnan(nu)) && return p + nu
    ((log_p && p > 0) || (!log_p && (p < 0 || p > 1))) && return NaN
    nu <= 0 && return NaN

    alpha = 0.5 * nu
    c = alpha - 1
    p1 = _R_DT_log(p, lower_tail, log_p)
    local ch::Float64
    if nu < (-1.24) * p1
        lgam1pa = (alpha < 0.5) ? _lgamma1p(alpha) : (clog(alpha) + g)
        ch = cexp((lgam1pa + p1) / alpha + M_LN2)
    elseif nu > 0.32
        x = qnorm5(p, 0.0, 1.0, lower_tail, log_p)
        p1 = 2.0 / (9 * nu)
        ch = nu * cpow(x * csqrt(p1) + 1 - p1, 3.0)
        if ch > 2.2 * nu + 6
            ch = -2 * (_R_DT_Clog(p, lower_tail, log_p) - c * clog(0.5 * ch) + g)
        end
    else
        ch = 0.4
        a = _R_DT_Clog(p, lower_tail, log_p) + g + c * M_LN2
        while true
            q = ch
            p1 = 1.0 / (1 + ch * (C7 + ch))
            p2 = ch * (C9 + ch * (C8 + ch))
            t = -0.5 + (C7 + 2 * ch) * p1 - (C9 + ch * (C10 + 3 * ch)) / p2
            ch -= (1 - cexp(a + 0.5 * ch) * p2 * p1) / t
            abs(q - ch) > tol * abs(ch) || break
        end
    end
    return ch
end

function qgamma_(p::Float64, alpha::Float64, scale::Float64, lower_tail::Bool, log_p::Bool)
    EPS1 = 1e-2
    EPS2 = 5e-7
    EPS_N = 1e-15
    MAXIT = 1000
    pMIN = 1e-100
    pMAX = (1 - 1e-14)
    i420 = 1.0 / 420.0
    i2520 = 1.0 / 2520.0
    i5040 = 1.0 / 5040

    max_it_Newton = 1

    (isnan(p) || isnan(alpha) || isnan(scale)) && return p + alpha + scale
    # R_Q_P01_boundaries(p, 0., ML_POSINF)
    if log_p
        p > 0 && return NaN
        p == 0 && return lower_tail ? INF : 0.0
        p == NINF && return lower_tail ? 0.0 : INF
    else
        (p < 0 || p > 1) && return NaN
        p == 0 && return lower_tail ? 0.0 : INF
        p == 1 && return lower_tail ? INF : 0.0
    end

    (alpha < 0 || scale <= 0) && return NaN
    alpha == 0 && return 0.0
    alpha < 1e-10 && (max_it_Newton = 7)

    p_ = log_p ? (lower_tail ? cexp(p) : -cexpm1(p)) : (lower_tail ? p : (0.5 - p + 0.5))

    g = _lgammafn(alpha)

    # Phase I
    ch = _qchisq_appr(p, 2 * alpha, g, lower_tail, log_p, EPS1)
    goto_end = false
    if !isfinite(ch)
        max_it_Newton = 0
        goto_end = true
    elseif ch < EPS2
        max_it_Newton = 20
        goto_end = true
    elseif p_ > pMAX || p_ < pMIN
        max_it_Newton = 20
        goto_end = true
    end

    if !goto_end
        # Phase II
        c = alpha - 1
        s6 = (120 + c * (346 + 127 * c)) * i5040
        ch0 = ch
        for i in 1:MAXIT
            q = ch
            p1 = 0.5 * ch
            p2 = p_ - _pgamma_raw(p1, alpha, true, false)
            if !isfinite(p2) || ch <= 0
                ch = ch0
                max_it_Newton = 27
                break
            end
            t = p2 * cexp(alpha * M_LN2 + g + p1 - c * clog(ch))
            b = t / ch
            a = 0.5 * t - b * c
            s1 = (210 + a * (140 + a * (105 + a * (84 + a * (70 + 60 * a))))) * i420
            s2 = (420 + a * (735 + a * (966 + a * (1141 + 1278 * a)))) * i2520
            s3 = (210 + a * (462 + a * (707 + 932 * a))) * i2520
            s4 = (252 + a * (672 + 1182 * a) + c * (294 + a * (889 + 1740 * a))) * i5040
            s5 = (84 + 2264 * a + c * (1175 + 606 * a)) * i2520

            ch += t * (1 + 0.5 * t * s1 - b * c * (s1 - b * (s2 - b * (s3 - b * (s4 - b * (s5 - b * s6))))))
            abs(q - ch) < EPS2 * ch && break
            if abs(q - ch) > 0.1 * ch
                ch = ch < q ? 0.9 * q : 1.1 * q
            end
        end
    end

    # END:
    x = 0.5 * scale * ch
    if max_it_Newton != 0
        if !log_p
            p = clog(p)
            log_p = true
        end
        if x == 0
            _1_p = 1.0 + 1e-7
            _1_m = 1.0 - 1e-7
            x = DBL_MIN
            p_ = pgamma_(x, alpha, scale, lower_tail, log_p)
            ((lower_tail && p_ > p * _1_p) || (!lower_tail && p_ < p * _1_m)) && return 0.0
        else
            p_ = pgamma_(x, alpha, scale, lower_tail, log_p)
        end
        p_ == NINF && return 0.0
        for i in 1:max_it_Newton
            p1 = p_ - p
            abs(p1) < abs(EPS_N * p) && break
            g = dgamma_(x, alpha, scale, log_p)
            g == (log_p ? NINF : 0.0) && break
            t = log_p ? p1 * cexp(p_ - g) : p1 / g
            t = lower_tail ? x - t : x + t
            p_ = pgamma_(t, alpha, scale, lower_tail, log_p)
            (abs(p_ - p) > abs(p1) || (i > 1 && abs(p_ - p) == abs(p1))) && break
            x = t
        end
    end
    return x
end

pchisq_(x::Float64, df::Float64, lower_tail::Bool, log_p::Bool) = pgamma_(x, df / 2.0, 2.0, lower_tail, log_p)
qchisq_(p::Float64, df::Float64, lower_tail::Bool, log_p::Bool) = qgamma_(p, 0.5 * df, 2.0, lower_tail, log_p)
dchisq_(x::Float64, df::Float64, give_log::Bool) = dgamma_(x, df / 2.0, 2.0, give_log)

function pf_(x::Float64, df1::Float64, df2::Float64, lower_tail::Bool, log_p::Bool)
    (isnan(x) || isnan(df1) || isnan(df2)) && return x + df2 + df1
    (df1 <= 0.0 || df2 <= 0.0) && return NaN
    x <= 0.0 && return _DT0(lower_tail, log_p)
    x >= INF && return _DT1(lower_tail, log_p)
    if df2 == INF
        if df1 == INF
            x < 1.0 && return _DT0(lower_tail, log_p)
            x == 1.0 && return log_p ? -M_LN2 : 0.5
            x > 1.0 && return _DT1(lower_tail, log_p)
        end
        return pchisq_(x * df1, df1, lower_tail, log_p)
    end
    df1 == INF && return pchisq_(df2 / x, df2, !lower_tail, log_p)
    if df1 * x > df2
        x = pbeta_(df2 / (df2 + df1 * x), df2 / 2.0, df1 / 2.0, !lower_tail, log_p)
    else
        x = pbeta_(df1 * x / (df2 + df1 * x), df1 / 2.0, df2 / 2.0, lower_tail, log_p)
    end
    return !isnan(x) ? x : NaN
end

# Fallbacks: beliebige reelle Argumente, Flags als Bool/Integer
_b(x::Bool) = x
_b(x::Integer) = x != 0
for f in (:pnorm5, :qnorm5, :plogis_, :qlogis_, :pgamma_, :qgamma_, :pbeta_, :pf_, :_pbeta_raw)
    @eval $f(x::Real, a::Real, b::Real, lt, lp) = $f(Float64(x), Float64(a), Float64(b), _b(lt), _b(lp))
end
for f in (:dnorm4, :dlogis_, :dgamma_)
    @eval $f(x::Real, a::Real, b::Real, lg) = $f(Float64(x), Float64(a), Float64(b), _b(lg))
end
for f in (:pt_, :qt_, :pchisq_, :qchisq_, :_pgamma_raw)
    @eval $f(x::Real, a::Real, lt, lp) = $f(Float64(x), Float64(a), _b(lt), _b(lp))
end
for f in (:dt_, :dchisq_, :_dpois, :_dpois_raw)
    @eval $f(x::Real, a::Real, lg) = $f(Float64(x), Float64(a), _b(lg))
end
for f in (:lbeta_, :beta_)
    @eval $f(x::Real, a::Real) = $f(Float64(x), Float64(a))
end
pnorm_both(x::Real, i_tail::Integer, log_p) = pnorm_both(Float64(x), i_tail, _b(log_p))
bratio(a::Real, b::Real, x::Real, y::Real, log_p) = bratio(Float64(a), Float64(b), Float64(x), Float64(y), _b(log_p))

# ══ Vektorisierung wie stats/src/distn.c ═════════════════════════════════

_fl(v) = v === missing ? NA : Float64(v)
_argvals(x::Real) = Float64[x]
_argvals(::Missing) = Float64[NA]
_argvals(x::RVector) = Float64[_fl(v) for v in x.values]
_argvals(x::NamedMat) = Float64[_fl(v) for v in vec(x.data)]
_argvals(x::AbstractArray) = Float64[_fl(v) for v in vec(x)]
_argvals(x::Tuple) = Float64[_fl(v) for v in x]
_isscal(x) = x isa Real || x isa Missing

"Ergebnis in die Form/Attribute von `x` bringen (SHALLOW_DUPLICATE_ATTRIB)."
function _like(out::Vector{Float64}, x)
    x isa RVector && return RVector(out; names = x.names, attrs = x.attrs)
    x isa NamedMat && return NamedMat(reshape(out, size(x.data)); rownames = x.rownames, colnames = x.colnames, attrs = x.attrs)
    (x isa AbstractArray && ndims(x) > 1) && return reshape(out, size(x))
    return out
end

@inline _na_or_nan(vals...) = any(isna_strict, vals) ? NA : NaN

"`f(a)` elementweise wie R's `math1` (NA/NaN rein → Argument raus)."
function _vec1(f::F, x) where {F}
    if _isscal(x)
        a = _fl(x)
        isnan(a) && return a
        y = f(a)
        isnan(y) && @warn R_MSG_NA
        return y
    end
    v = _argvals(x)
    out = similar(v)
    naflag = false
    @inbounds for i in eachindex(v)
        a = v[i]
        if isnan(a)
            out[i] = a
            continue
        end
        y = f(a)
        isnan(y) && (naflag = true)
        out[i] = y
    end
    naflag && @warn R_MSG_NA
    return _like(out, x)
end

"`f(a, b)` elementweise mit Recycling wie R's `math2_*`."
function _vec2(f::F, x, y) where {F}
    if _isscal(x) && _isscal(y)
        a = _fl(x); b = _fl(y)
        (isnan(a) || isnan(b)) && return _na_or_nan(a, b)
        r = f(a, b)
        isnan(r) && @warn R_MSG_NA
        return r
    end
    va = _argvals(x); vb = _argvals(y)
    na, nb = length(va), length(vb)
    (na == 0 || nb == 0) && return Float64[]
    n = max(na, nb)
    out = Vector{Float64}(undef, n)
    naflag = false
    @inbounds for i in 1:n
        a = va[(i-1)%na+1]; b = vb[(i-1)%nb+1]
        if isnan(a) || isnan(b)
            out[i] = _na_or_nan(a, b)
            continue
        end
        r = f(a, b)
        isnan(r) && (naflag = true)
        out[i] = r
    end
    naflag && @warn R_MSG_NA
    return _like(out, n == na ? x : y)
end

"`f(a, b, c)` elementweise mit Recycling wie R's `math3_*`."
function _vec3(f::F, x, y, z) where {F}
    if _isscal(x) && _isscal(y) && _isscal(z)
        a = _fl(x); b = _fl(y); c = _fl(z)
        (isnan(a) || isnan(b) || isnan(c)) && return _na_or_nan(a, b, c)
        r = f(a, b, c)
        isnan(r) && @warn R_MSG_NA
        return r
    end
    va = _argvals(x); vb = _argvals(y); vc = _argvals(z)
    na, nb, nc = length(va), length(vb), length(vc)
    (na == 0 || nb == 0 || nc == 0) && return Float64[]
    n = max(na, nb, nc)
    out = Vector{Float64}(undef, n)
    naflag = false
    @inbounds for i in 1:n
        a = va[(i-1)%na+1]; b = vb[(i-1)%nb+1]; c = vc[(i-1)%nc+1]
        if isnan(a) || isnan(b) || isnan(c)
            out[i] = _na_or_nan(a, b, c)
            continue
        end
        r = f(a, b, c)
        isnan(r) && (naflag = true)
        out[i] = r
    end
    naflag && @warn R_MSG_NA
    return _like(out, n == na ? x : n == nb ? y : z)
end

_no_ncp(ncp) = ncp === nothing || error("nicht-zentrale Verteilungen (ncp) sind nicht portiert")

# ── öffentliche Funktionen (R-Signaturen) ──────────────────────────────────

"Dichte der Normalverteilung (R `dnorm`)."
function dnorm(x, mean_ = 0.0, sd_ = 1.0; mean = mean_, sd = sd_, log::Bool = false)
    return _vec3((a, b, c) -> dnorm4(a, b, c, log), x, mean, sd)
end

"Verteilungsfunktion der Normalverteilung (R `pnorm`)."
function pnorm(q, mean_ = 0.0, sd_ = 1.0; mean = mean_, sd = sd_, lower_tail::Bool = true, log_p::Bool = false)
    if _isscal(mean) && _isscal(sd) && !_isscal(q)
        m = _fl(mean); s = _fl(sd)
        if !isnan(m) && !isnan(s)
            return _vec1n((a) -> pnorm5(a, m, s, lower_tail, log_p), q)
        end
    end
    return _vec3((a, b, c) -> pnorm5(a, b, c, lower_tail, log_p), q, mean, sd)
end

"Quantile der Normalverteilung (R `qnorm`)."
function qnorm(p, mean_ = 0.0, sd_ = 1.0; mean = mean_, sd = sd_, lower_tail::Bool = true, log_p::Bool = false)
    if _isscal(mean) && _isscal(sd) && !_isscal(p)
        m = _fl(mean); s = _fl(sd)
        if !isnan(m) && !isnan(s)
            return _vec1n((a) -> qnorm5(a, m, s, lower_tail, log_p), p)
        end
    end
    return _vec3((a, b, c) -> qnorm5(a, b, c, lower_tail, log_p), p, mean, sd)
end

# Schneller Pfad für einen langen Vektor mit skalaren (nicht-NaN) weiteren
# Argumenten: wie `math3_*`, NaN im Vektor → NA bzw. NaN.
function _vec1n(f::F, x) where {F}
    v = _argvals(x)
    out = similar(v)
    naflag = false
    @inbounds for i in eachindex(v)
        a = v[i]
        if isnan(a)
            out[i] = isna_strict(a) ? NA : NaN
            continue
        end
        r = f(a)
        isnan(r) && (naflag = true)
        out[i] = r
    end
    naflag && @warn R_MSG_NA
    return _like(out, x)
end

"Dichte der t-Verteilung (R `dt`, zentral)."
dt(x, df; ncp = nothing, log::Bool = false) = (_no_ncp(ncp); _vec2((a, b) -> dt_(a, b, log), x, df))
"Verteilungsfunktion der t-Verteilung (R `pt`, zentral)."
pt(q, df; ncp = nothing, lower_tail::Bool = true, log_p::Bool = false) =
    (_no_ncp(ncp); _vec2((a, b) -> pt_(a, b, lower_tail, log_p), q, df))
"Quantile der t-Verteilung (R `qt`, zentral)."
qt(p, df; ncp = nothing, lower_tail::Bool = true, log_p::Bool = false) =
    (_no_ncp(ncp); _vec2((a, b) -> qt_(a, b, lower_tail, log_p), p, df))
"Verteilungsfunktion der Betaverteilung (R `pbeta`, zentral)."
pbeta(q, shape1, shape2; ncp = nothing, lower_tail::Bool = true, log_p::Bool = false) =
    (_no_ncp(ncp); _vec3((a, b, c) -> pbeta_(a, b, c, lower_tail, log_p), q, shape1, shape2))
"`log|Gamma(x)|` (R `lgamma` = `lgammafn`)."
lgamma(x) = _vec1(_lgammafn, x)
"Gammafunktion (R `gamma` = `gammafn`)."
gamma(x) = _vec1(_gammafn, x)
"`log(beta(a, b))` (R `lbeta`)."
lbeta(a, b) = _vec2(lbeta_, a, b)
"Betafunktion (R `beta`)."
beta(a, b) = _vec2(beta_, a, b)

"Verteilungsfunktion der logistischen Verteilung (R `plogis`)."
plogis(q, location_ = 0.0, scale_ = 1.0; location = location_, scale = scale_, lower_tail::Bool = true, log_p::Bool = false) =
    _vec3((a, b, c) -> plogis_(a, b, c, lower_tail, log_p), q, location, scale)
"Quantile der logistischen Verteilung (R `qlogis`)."
qlogis(p, location_ = 0.0, scale_ = 1.0; location = location_, scale = scale_, lower_tail::Bool = true, log_p::Bool = false) =
    _vec3((a, b, c) -> qlogis_(a, b, c, lower_tail, log_p), p, location, scale)
"Dichte der logistischen Verteilung (R `dlogis`)."
dlogis(x, location_ = 0.0, scale_ = 1.0; location = location_, scale = scale_, log::Bool = false) =
    _vec3((a, b, c) -> dlogis_(a, b, c, log), x, location, scale)

function _rate_scale(rate, scale)
    if rate !== nothing && scale !== nothing
        r = _argvals(rate); s = _argvals(scale)
        n = max(length(r), length(s))
        ok = all(abs(r[mod1(i, length(r))] * s[mod1(i, length(s))] - 1) < 1e-15 for i in 1:n)
        ok || error("specify 'rate' or 'scale' but not both")
        @warn "specify 'rate' or 'scale' but not both"
        return scale
    end
    scale !== nothing && return scale
    rate === nothing && return 1.0
    _isscal(rate) && return 1.0 / _fl(rate)
    return _like(1.0 ./ _argvals(rate), rate)
end

"Verteilungsfunktion der Gammaverteilung (R `pgamma`)."
pgamma(q, shape, rate_ = nothing, scale_ = nothing; rate = rate_, scale = scale_, lower_tail::Bool = true, log_p::Bool = false) =
    _vec3((a, b, c) -> pgamma_(a, b, c, lower_tail, log_p), q, shape, _rate_scale(rate, scale))
"Quantile der Gammaverteilung (R `qgamma`)."
qgamma(p, shape, rate_ = nothing, scale_ = nothing; rate = rate_, scale = scale_, lower_tail::Bool = true, log_p::Bool = false) =
    _vec3((a, b, c) -> qgamma_(a, b, c, lower_tail, log_p), p, shape, _rate_scale(rate, scale))
"Dichte der Gammaverteilung (R `dgamma`)."
dgamma(x, shape, rate_ = nothing, scale_ = nothing; rate = rate_, scale = scale_, log::Bool = false) =
    _vec3((a, b, c) -> dgamma_(a, b, c, log), x, shape, _rate_scale(rate, scale))

"Verteilungsfunktion der Chi-Quadrat-Verteilung (R `pchisq`, zentral)."
pchisq(q, df; ncp = nothing, lower_tail::Bool = true, log_p::Bool = false) =
    (_no_ncp(ncp); _vec2((a, b) -> pchisq_(a, b, lower_tail, log_p), q, df))
"Quantile der Chi-Quadrat-Verteilung (R `qchisq`, zentral)."
qchisq(p, df; ncp = nothing, lower_tail::Bool = true, log_p::Bool = false) =
    (_no_ncp(ncp); _vec2((a, b) -> qchisq_(a, b, lower_tail, log_p), p, df))
"Dichte der Chi-Quadrat-Verteilung (R `dchisq`, zentral)."
dchisq(x, df; ncp = nothing, log::Bool = false) = (_no_ncp(ncp); _vec2((a, b) -> dchisq_(a, b, log), x, df))
"Verteilungsfunktion der F-Verteilung (R `pf`, zentral)."
pf(q, df1, df2; ncp = nothing, lower_tail::Bool = true, log_p::Bool = false) =
    (_no_ncp(ncp); _vec3((a, b, c) -> pf_(a, b, c, lower_tail, log_p), q, df1, df2))
"Binomialwahrscheinlichkeiten (R `dbinom`)."
dbinom(x, size, prob; log::Bool = false) = _vec3((a, b, c) -> _dbinom(a, b, c, log), x, size, prob)
"Poisson-Wahrscheinlichkeiten (R `dpois`)."
dpois(x, lambda; log::Bool = false) = _vec2((a, b) -> _dpois(a, b, log), x, lambda)

# Aliase mit C-Namen für andere Module
const dnorm_scalar = dnorm4
const pnorm_scalar = pnorm5
const qnorm_scalar = qnorm5
gammafn_scalar(x::Real) = _gammafn(Float64(x))

# ── skalare Hilfen (öffentlich) ─────────────────────────────────────────────
"`log(n!) - log(sqrt(2*pi*n)*(n/e)^n)` (R 4.3.3 `stirlerr`)."
stirlerr(n::Real) = _stirlerr(Float64(n))
"Abweichungsterm `x log(x/np) + np - x` (R's `bd0`)."
bd0(x::Real, np_::Real) = _bd0(Float64(x), Float64(np_))
"`x log(x/M) + M - x` als `(yh, yl)` (R's `ebd0`)."
ebd0(x::Real, M::Real) = _ebd0(Float64(x), Float64(M))
"Korrekturterm von `lgamma` für `x >= 10` (R's `lgammacor`)."
lgammacor(x::Real) = _lgammacor(Float64(x))
"Chebyshev-Reihe `a[1:n]` an der Stelle `x` (R's `chebyshev_eval`)."
chebyshev_eval(x::Real, a, n::Integer) = _chebyshev_eval(Float64(x), a, Int(n))
"Anzahl benötigter Chebyshev-Terme (R's `chebyshev_init`)."
chebyshev_init(dos, nos::Integer, eta::Real) = _chebyshev_init(dos, Int(nos), Float64(eta))
"`log(1+x) - x` (R's `log1pmx`)."
log1pmx(x::Real) = _log1pmx(Float64(x))
"`log(gamma(a+1))` (R's `lgamma1p`)."
lgamma1p(a::Real) = _lgamma1p(Float64(a))
"`log(exp(logx) + exp(logy))` (R's `logspace_add`)."
logspace_add(logx::Real, logy::Real) = _logspace_add(Float64(logx), Float64(logy))
"`log(exp(logx) - exp(logy))` (R's `logspace_sub`)."
logspace_sub(logx::Real, logy::Real) = _logspace_sub(Float64(logx), Float64(logy))
"Binomialdichte (R's `dbinom_raw`)."
dbinom_raw(x::Real, n::Real, p::Real, q::Real, give_log = false) = _dbinom_raw(Float64(x), Float64(n), Float64(p), Float64(q), _b(give_log))
"Poisson-Dichte für reelles `x` (R's `dpois_raw`)."
dpois_raw(x::Real, lam::Real, give_log = false) = _dpois_raw(Float64(x), Float64(lam), _b(give_log))
"`log|Gamma(x)|` skalar (R's `lgammafn`)."
lgammafn(x::Real) = _lgammafn(Float64(x))
"`(lgamma(x), Vorzeichen von Gamma(x))` (R's `lgammafn_sign`)."
lgammafn_sign(x::Real) = _lgammafn_sign(Float64(x))
"`Gamma(x)` skalar (R's `gammafn`)."
gammafn(x::Real) = _gammafn(Float64(x))
sinpi(x::Real) = _sinpi(Float64(x))
cospi(x::Real) = _cospi(Float64(x))
tanpi(x::Real) = _tanpi(Float64(x))
"`log(1 + exp(x))` (R's `log1pexp`)."
log1pexp(x::Real) = _log1pexp(Float64(x))
"`log(1 - exp(-x))` (R's `log1mexp`)."
log1mexp(x::Real) = _log1mexp(Float64(x))
pgamma_raw(x::Real, alph::Real, lower_tail = true, log_p = false) = _pgamma_raw(Float64(x), Float64(alph), _b(lower_tail), _b(log_p))
pbeta_raw(x::Real, a::Real, b::Real, lower_tail = true, log_p = false) = _pbeta_raw(Float64(x), Float64(a), Float64(b), _b(lower_tail), _b(log_p))
qchisq_appr(p::Real, nu::Real, g::Real, lower_tail, log_p, tol::Real) =
    _qchisq_appr(Float64(p), Float64(nu), Float64(g), _b(lower_tail), _b(log_p), Float64(tol))
fmax2(x::Real, y::Real) = fmax2(Float64(x), Float64(y))
fmin2(x::Real, y::Real) = fmin2(Float64(x), Float64(y))
fsign(x::Real, y::Real) = fsign(Float64(x), Float64(y))
R_forceint(x::Real) = R_forceint(Float64(x))
R_pow(x::Real, y::Real) = R_pow(Float64(x), Float64(y))
R_pow_di(x::Real, n::Integer) = R_pow_di(Float64(x), n)

end # module
