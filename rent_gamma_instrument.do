*==============================================================================
* rent_gamma_instrument.do
*
* Rent-based sensitivity instrument in the spirit of Guren, McKay, Nakamura &
* Steinsson (2021, REStud), built from IPUMS USA ACS 1-year microdata on metros
* defined as fixed sets of 2010-2020 consistent PUMAs (CPUMA1020).
*
* Steps
*   1. Assign each CPUMA1020 to one MET2013 metro: the metro holding the largest
*      share of the CPUMA's households, pooled over all years. A metro is then
*      the same set of CPUMAs in every year, across the 2012 and 2022 PUMA
*      redraws. Coverage diagnostics are saved relative to MET2013.
*   2. Metro-year rent index: fixed-weight average of log median real gross rent
*      for 1-, 2- and 3-bedroom units. Weights are the metro's renter shares by
*      bedrooms, pooled over years, so changes in the bedroom mix do not move it.
*   3. Leave-out regional rent cycle, in annual changes (P_lo) and in log
*      levels (L_lo), excluding the metro itself.
*   4. Sensitivity gamma_m from  p_mt = phi_m + gamma_m * P_lo_mt + nu_mt :
*        gamma_full  all years
*        gamma_lo    for each target year t, estimated without the years
*                    |year - t| <= buffer (Guren et al.'s leave-out window)
*   5. Instruments: Z_lvl = gamma_lo * L_lo, Z_chg = gamma_lo * P_lo
*      (and *_full versions using gamma_full).
*   6. Metro-year first stage with metro and division-by-year fixed effects,
*      standard errors clustered by metro.
*
* IPUMS USA extract
*   Samples:   ACS 1-year, 2012-2024 (CPUMA1020 starts in 2012)
*   Variables: YEAR SERIAL PERNUM HHWT GQ STATEFIP MET2013 CPUMA1020
*              RELATE OWNERSHP RENTGRS BEDROOMS MOVEDIN CPI99
*   Only PERNUM==1 records are read, so the extract can be large.
*
* Requires: reghdfe and ftools  (ssc install ftools; ssc install reghdfe)
*
* Outputs (in `outdir')
*   cpuma1020_to_met2013.dta       CPUMA -> metro crosswalk (reuse it to assign
*                                  individuals to metros in the outcome data)
*   metro_coverage.dta             omission/commission relative to MET2013
*   metro_division.dta             metro -> Census division and region
*   rent_instrument_metro_year.dta metro-year panel: lnR, p, L_lo, P_lo,
*                                  gamma_lo, gamma_full, Z_lvl, Z_chg, ...
*==============================================================================

version 16
clear all
set more off

*------------------------------------------------------------------------------
* Settings
*------------------------------------------------------------------------------
local extract     "usa_extract.dta"   // IPUMS USA extract (.dta)
local outdir      "rent_gamma_out"
local firstyear   2012                // CPUMA1020 is available from 2012
local use2020     0       // 1 = keep 2020 (experimental weights)
local minshare    0.50    // min share of a CPUMA's households in its metro
local maxmismatch 0.15    // drop metros with omission+commission above this (. = keep all)
local movers      0       // 1 = households that moved in within 12 months only
local mincell     30      // min unweighted households per metro-year-bedroom cell
local cyclevel    region  // geography of the leave-out cycle: region or division
local cyclewt     0       // 1 = weight the cycle by renter households; 0 = equal
local buffer      1       // gamma_lo drops years with |year - target| <= buffer
local minobs      6       // min annual changes to estimate a metro's gamma

capture mkdir "`outdir'"
if !inlist("`cyclevel'", "region", "division") {
    di as error "cyclevel must be region or division"
    exit 198
}

*------------------------------------------------------------------------------
* 0. Load household-head records
*------------------------------------------------------------------------------
use year serial pernum hhwt gq statefip met2013 cpuma1020 relate ownershp ///
    rentgrs bedrooms movedin cpi99 if pernum == 1 using "`extract'", clear
keep if year >= `firstyear'
if `use2020' == 0 {
    drop if year == 2020
}

*------------------------------------------------------------------------------
* 1. CPUMA1020 -> MET2013 crosswalk (pooled over years, household weights)
*------------------------------------------------------------------------------
preserve
    keep if inlist(gq, 1, 2, 5)
    collapse (sum) hh = hhwt, by(cpuma1020 met2013)
    bysort cpuma1020: egen double tot = total(hh)
    gen double cpuma_share = hh / tot
    bysort cpuma1020 (cpuma_share): keep if _n == _N   // largest share
    gen long metro = met2013 if met2013 > 0 & cpuma_share >= `minshare'
    keep cpuma1020 metro cpuma_share
    save "`outdir'/cpuma1020_to_met2013.dta", replace
restore
merge m:1 cpuma1020 using "`outdir'/cpuma1020_to_met2013.dta", nogen

* Coverage relative to MET2013.
*   omission:   share of a MET2013 metro's households in CPUMAs assigned elsewhere
*   commission: share of households assigned to the metro that MET2013 puts elsewhere
tempfile om
preserve
    keep if inlist(gq, 1, 2, 5) & met2013 > 0
    gen byte omitted = (metro != met2013)
    collapse (mean) omission = omitted [pw = hhwt], by(met2013)
    rename met2013 metro
    save `om'
restore
preserve
    keep if inlist(gq, 1, 2, 5) & metro < .
    gen byte added = (met2013 != metro)
    collapse (mean) commission = added [pw = hhwt], by(metro)
    merge 1:1 metro using `om', nogen keep(master match)
    gen double mismatch = omission + commission
    save "`outdir'/metro_coverage.dta", replace
    di as txt _n "Coverage of CPUMA-based metros relative to MET2013:"
    summarize omission commission mismatch, detail
restore

*------------------------------------------------------------------------------
* 2. Census division and region of each metro (largest share of households)
*------------------------------------------------------------------------------
gen byte division = .
replace division = 1 if inlist(statefip, 9, 23, 25, 33, 44, 50)            // New England
replace division = 2 if inlist(statefip, 34, 36, 42)                        // Middle Atlantic
replace division = 3 if inlist(statefip, 17, 18, 26, 39, 55)                // East North Central
replace division = 4 if inlist(statefip, 19, 20, 27, 29, 31, 38, 46)        // West North Central
replace division = 5 if inlist(statefip, 10, 11, 12, 13, 24, 37, 45, 51, 54) // South Atlantic
replace division = 6 if inlist(statefip, 1, 21, 28, 47)                     // East South Central
replace division = 7 if inlist(statefip, 5, 22, 40, 48)                     // West South Central
replace division = 8 if inlist(statefip, 4, 8, 16, 30, 32, 35, 49, 56)      // Mountain
replace division = 9 if inlist(statefip, 2, 6, 15, 41, 53)                  // Pacific

preserve
    keep if inlist(gq, 1, 2, 5) & metro < . & division < .
    collapse (sum) hh = hhwt, by(metro division)
    bysort metro (hh): keep if _n == _N
    gen byte region = cond(division <= 2, 1, cond(division <= 4, 2, cond(division <= 7, 3, 4)))
    keep metro division region
    save "`outdir'/metro_division.dta", replace
restore
drop division

*------------------------------------------------------------------------------
* 3. Renter households paying cash rent, 1-3 bedrooms
*------------------------------------------------------------------------------
keep if metro < . & relate == 1 & inlist(gq, 1, 2, 5)
keep if ownershp == 2 & rentgrs > 0 & rentgrs < .     // RENTGRS = 0 is N/A
gen byte br = bedrooms - 1                             // IPUMS code = bedrooms + 1
keep if inrange(br, 1, 3)
if `movers' == 1 {
    keep if movedin == 1                               // moved in <= 12 months ago
}
gen double rent_real = rentgrs * cpi99                 // 1999 dollars (CPI-U)
gen byte one = 1
gen double hhw = hhwt

* Fixed bedroom weights: metro renter shares, pooled over years
tempfile wts
preserve
    collapse (sum) hh = hhw, by(metro br)
    bysort metro: egen double tot = total(hh)
    gen double w_br = hh / tot
    keep metro br w_br
    save `wts'
restore

* Weighted median rent by metro-year-bedroom
collapse (median) med = rent_real (rawsum) n = one hh = hhw [pw = hhwt], ///
    by(metro year br)
merge m:1 metro br using `wts', nogen keep(match)

gen double lmed = ln(med) if n >= `mincell'
bysort metro year: egen byte ncell = count(lmed)
gen double wl = w_br * lmed
collapse (sum) lnR = wl renters = hh (max) ncell, by(metro year)
replace lnR = . if ncell < 3                           // all three cells required
drop ncell

* Balanced panel: metros with the index in every year
quietly levelsof year, local(yrs)
local nyrs : word count `yrs'
bysort metro: egen int nyr = count(lnR)
keep if nyr == `nyrs'
drop nyr

merge m:1 metro using "`outdir'/metro_division.dta", nogen keep(match)
merge m:1 metro using "`outdir'/metro_coverage.dta", nogen keep(master match) ///
    keepusing(mismatch)
if `maxmismatch' < . {
    drop if mismatch > `maxmismatch' & mismatch < .
}

egen byte _tag = tag(metro)
quietly count if _tag
di as txt _n "Metros in the balanced panel: " as res r(N) as txt "; years: `yrs'"
drop _tag

*------------------------------------------------------------------------------
* 4. Annual changes and leave-out regional cycles
*------------------------------------------------------------------------------
xtset metro year
gen double p = lnR - L.lnR             // missing in the first year and after gaps
bysort metro: egen double mbar = mean(lnR)
gen double lnR_dm = lnR - mbar         // demeaned log level
drop mbar

if `cyclewt' == 1 {
    bysort metro: egen double cw = mean(renters)
}
else {
    gen double cw = 1
}

* Leave-out weighted mean over the other metros in the same cycle area and year
foreach v in p lnR_dm {
    gen double _wx = cw * `v'
    gen double _w  = cw * (`v' < .)
    bysort `cyclevel' year: egen double _S = total(_wx)
    bysort `cyclevel' year: egen double _W = total(_w)
    gen double lo_`v' = (_S - cond(`v' < ., _wx, 0)) / (_W - _w) if (_W - _w) > 0
    drop _wx _w _S _W
}
rename lo_p      P_lo
rename lo_lnR_dm L_lo
sort metro year

*------------------------------------------------------------------------------
* 5. Sensitivities
*------------------------------------------------------------------------------
* Full sample
tempfile gfull
preserve
    keep if p < . & P_lo < .
    statsby gamma_full = _b[P_lo] se_full = _se[P_lo] n_full = e(N), ///
        by(metro) clear nodots: regress p P_lo
    replace gamma_full = . if n_full < `minobs'
    save `gfull'
restore
merge m:1 metro using `gfull', nogen

* Leave-out window around each target year
tempfile glo
local have_lo 0
quietly levelsof year, local(targets)
foreach tau of local targets {
    preserve
        quietly keep if abs(year - `tau') > `buffer' & p < . & P_lo < .
        bysort metro: gen int _nm = _N
        quietly keep if _nm >= `minobs'
        if _N > 0 {
            quietly statsby gamma_lo = _b[P_lo] n_lo = e(N), ///
                by(metro) clear nodots: regress p P_lo
            gen int year = `tau'
            if `have_lo' == 1 {
                append using `glo'
            }
            quietly save `glo', replace
            local have_lo 1
        }
    restore
}
if `have_lo' == 1 {
    merge 1:1 metro year using `glo', nogen keep(master match)
}
else {
    di as error "No leave-out gamma estimated: lower buffer or minobs."
    gen double gamma_lo = .
    gen int n_lo = .
}

*------------------------------------------------------------------------------
* 6. Instruments and output
*------------------------------------------------------------------------------
gen double Z_lvl      = gamma_lo   * L_lo
gen double Z_chg      = gamma_lo   * P_lo
gen double Z_lvl_full = gamma_full * L_lo
gen double Z_chg_full = gamma_full * P_lo

label var lnR        "Log real rent index (fixed-weight 1-3BR medians)"
label var p          "Annual change in lnR"
label var L_lo       "Leave-out regional log rent level (demeaned)"
label var P_lo       "Leave-out regional annual rent change"
label var gamma_lo   "Sensitivity, leave-out window around year"
label var gamma_full "Sensitivity, all years"
label var Z_lvl      "gamma_lo x L_lo"
label var Z_chg      "gamma_lo x P_lo"

sort metro year
order metro year division region lnR p L_lo P_lo gamma_lo gamma_full ///
    Z_lvl Z_chg Z_lvl_full Z_chg_full
save "`outdir'/rent_instrument_metro_year.dta", replace

preserve
    collapse (first) gamma_full (mean) gamma_lo_mean = gamma_lo, by(metro)
    di as txt _n "Sensitivities across metros:"
    summarize gamma_full gamma_lo_mean, detail
    correlate gamma_full gamma_lo_mean
restore

*------------------------------------------------------------------------------
* 7. First stage at the metro-year level
*------------------------------------------------------------------------------
foreach z in Z_lvl Z_lvl_full {
    reghdfe lnR `z', absorb(metro division#year) vce(cluster metro)
    di as txt "First-stage F, `z': " as res %9.1f (_b[`z'] / _se[`z'])^2
}
foreach z in Z_chg Z_chg_full {
    reghdfe p `z', absorb(metro division#year) vce(cluster metro)
    di as txt "First-stage F, `z': " as res %9.1f (_b[`z'] / _se[`z'])^2
}
