cd "C:\Users\ivang\Desktop\Paper III Rent and Cohabitation"
local extract     "usa_00584.dta"   // IPUMS USA extract (.dta)
local outdir      "rent_gamma_out"
local xw_msa      "MSA2013_PUMA2020_crosswalk.xlsx"  // Census: 2013 MSA x 2020 PUMA populations
local xw_cpuma    "cpuma0010_summary_1.xlsx"         // IPUMS: 2020 PUMAs in each cpuma0010
local firstyear   2005                // cpuma0010 is available from 2012
local use2020     0       // 1 = keep 2020 (experimental weights)
local minshare    0.9    // min share of a CPUMA in its metro: households (step 1), 2020 population (step 1b)
local addmsa      0       // 1 = add 2013 MSAs that MET2013 does not identify (steps 0a and 1b)
local maxmismatch .       // drop metros with omission+commission above this (. = keep all)
local movers      0       // 1 = households that moved in within 12 months only
local mincell     60     // min unweighted households per metro-year-bedroom cell
local cyclevel    division  // geography of the leave-out cycle: region or division
local cyclewt     0       // 1 = weight the cycle by renter households; 0 = equal weighting for all metros
local buffer      1       // gamma_lo drops years with |year - target| <= buffer
local minobs      6       // min annual changes to estimate a metro's gamma

* 2SLS (steps 8-9)
local extract_p1   "usa_00597.dta"   // 2018, 19, 21 person records with: year perwt gq age marst sploc
                                //   cpuma0010 migrate1d migplac1 migpuma1
                                //   migrate1d_sp migplac1_sp migpuma1_sp
local extract_p2   "usa_00596.dta"   // 2015-17 person records with: year perwt gq age marst sploc
local extract_p3   "usa_00595.dta"   // 2012-14 person records with: year perwt gq age marst sploc	
local extract_p4   "usa_00594.dta"   // 2009-11 person records with: year perwt gq age marst sploc	
local extract_p5   "usa_00593.dta"   // 2006-08 person records with: year perwt gq age marst sploc								
local agecuts     18 25 35 45   // age groups 18-24, 25-34, 35-44
local exposure    avg     // avg = mean of years t-1 and t (move-ins reported in year t
                          //   happened in the 12 months before the interview); cur = year t
local vintfe      0       // 1 = metro x MIGPUMA-vintage FE (MIGPUMA boundaries change in 2012)

capture mkdir "`outdir'"
if !inlist("`cyclevel'", "region", "division") {
    di as error "cyclevel must be region or division"
    exit 198
}
if !inlist("`exposure'", "avg", "cur") {
    di as error "exposure must be avg or cur"
    exit 198
}

*------------------------------------------------------------------------------
* 0a. Census crosswalk: share of each cpuma0010's 2020 population in each
*     2013 MSA. Runs before the extract loads, so a problem with either
*     spreadsheet stops the do-file early.
*------------------------------------------------------------------------------
if `addmsa' == 1 {
    * IPUMS summary: one row per cpuma0010, with its 2020 PUMAs as a list of
    * 7-digit GEOIDs (state FIPS + PUMA) separated by "-"
    import excel using "`xw_cpuma'", sheet("cpuma0010_summary") cellrange(A2) clear
    keep A E H
    rename (A E H) (cpuma0010 puma_list cpop)
    confirm numeric variable cpuma0010 cpop
    confirm string variable puma_list
    isid cpuma0010
    label var cpop "2020 population of the CPUMA's 2020 PUMAs"
    save "`outdir'/cpuma0010_pop.dta", replace

    * One row per cpuma0010 x 2020 PUMA
    split puma_list, parse("-") generate(geoid)
    drop puma_list cpop
    reshape long geoid, i(cpuma0010) j(k)
    drop if geoid == ""
    drop k
    assert strlen(geoid) == 7
    isid geoid                          // each 2020 PUMA is in exactly one CPUMA
    tempfile cpuma_puma
    save `cpuma_puma'

    * Census crosswalk: one row per 2013 MSA x 2020 PUMA intersection
    import excel using "`xw_msa'", sheet("MSA2013_PUMA2020_crosswalk") cellrange(A2) clear
    keep A B C E I
    rename (A B C E I) (msa_code msa_title stfips puma pop_x)
    confirm string variable msa_code stfips puma
    confirm numeric variable pop_x
    assert strlen(msa_code) == 5 & strlen(stfips) == 2 & strlen(puma) == 5
    gen long msa = real(msa_code)
    gen str7 geoid = stfips + puma
    merge m:1 geoid using `cpuma_puma'
    assert _merge != 1                  // every crosswalk PUMA belongs to a CPUMA
    keep if _merge == 3                 // _merge == 2: PUMAs entirely outside 2013 MSAs
    drop _merge

    * Value label with the 2013 MSA titles, saved for step 1b
    preserve
        keep msa msa_title
        duplicates drop
        isid msa
        capture label drop msa2013
        forvalues i = 1/`=_N' {
            local c = msa[`i']
            local t = msa_title[`i']
            label define msa2013 `c' `"`t'"', add
        }
        label save msa2013 using "`outdir'/msa2013_labels.do", replace
    restore

    * Share of each CPUMA's 2020 population inside each MSA
    collapse (sum) pop_x, by(cpuma0010 msa)
    merge m:1 cpuma0010 using "`outdir'/cpuma0010_pop.dta", keepusing(cpop) ///
        assert(match using) keep(match) nogen
    gen double share_x = pop_x / cpop
    assert share_x > 0 & share_x <= 1
    label var pop_x   "2020 population of the CPUMA inside the 2013 MSA"
    label var share_x "Share of the CPUMA's 2020 population inside the 2013 MSA"
    save "`outdir'/cpuma0010_msa2013_census.dta", replace
}

*------------------------------------------------------------------------------
* 0b. Load household-head records
*------------------------------------------------------------------------------
use year serial hhwt gq stateicp met2013 cpuma0010  ownershp ///
    rentgrs bedrooms  cpi99  using "`extract'", clear
keep if year >= `firstyear'
if `use2020' == 0 {
    drop if year == 2020
}

*------------------------------------------------------------------------------
* 1. cpuma0010 -> MET2013 crosswalk (pooled over years, household weights)
*------------------------------------------------------------------------------
preserve
    keep if inlist(gq, 1, 2, 5)
    collapse (sum) hh = hhwt, by(cpuma0010 met2013)
    bysort cpuma0010: egen double tot = total(hh)
    gen double cpuma_share = hh / tot
    bysort cpuma0010 (cpuma_share): keep if _n == _N   // largest share
    gen long metro = met2013 if met2013 > 0 & cpuma_share >= `minshare'
    gen byte src = 1 if metro < .
    keep cpuma0010 metro cpuma_share src
    save "`outdir'/cpuma0010_to_met2013.dta", replace
restore

*------------------------------------------------------------------------------
* 1b. Add 2013 MSAs that MET2013 does not identify.
*     A CPUMA left unassigned in step 1 goes to the 2013 MSA holding the
*     largest share of its 2020 population, if that share is at least
*     `minshare' and step 1 gave the MSA no CPUMA.
*------------------------------------------------------------------------------
if `addmsa' == 1 {
    preserve
        * Metros that received at least one CPUMA in step 1
        use metro if metro < . using "`outdir'/cpuma0010_to_met2013.dta", clear
        duplicates drop
        rename metro msa
        gen byte in_met = 1
        tempfile met_set
        save `met_set'

        * Largest 2013 MSA share of each CPUMA's 2020 population
        use "`outdir'/cpuma0010_msa2013_census.dta", clear
        bysort cpuma0010 (share_x): keep if _n == _N
        merge m:1 msa using `met_set', keep(master match) nogen
        replace in_met = 0 if in_met == .
        keep cpuma0010 msa share_x in_met
        rename (msa share_x) (msa_census share_census)

        * Assign CPUMAs that step 1 left unassigned
        merge 1:1 cpuma0010 using "`outdir'/cpuma0010_to_met2013.dta", ///
            keep(using match) nogen
        gen byte add = metro == . & in_met == 0 & ///
            share_census >= `minshare' & share_census < .
        replace metro = msa_census if add
        replace src   = 2          if add

        run "`outdir'/msa2013_labels.do"
        label values metro msa_census msa2013
        label define src 1 "MET2013 households" 2 "Census MSA crosswalk", replace
        label values src src
        label var src          "Source of the metro assignment"
        label var msa_census   "2013 MSA with the largest share of the CPUMA's 2020 population"
        label var share_census "Share of the CPUMA's 2020 population in msa_census"

        quietly count if add
        local n_add = r(N)
        egen byte _t = tag(metro) if add
        quietly count if _t == 1
        di as txt _n "Step 1b: " as res `n_add' as txt " CPUMAs assigned to " ///
            as res r(N) as txt " MSAs that MET2013 does not identify"
        drop _t
        tab metro if add

        * Not assigned: most of the CPUMA's population is in an MSA that
        * step 1 already built from other CPUMAs
        quietly count if metro == . & in_met == 1 & ///
            share_census >= `minshare' & share_census < .
        if r(N) > 0 {
            di as txt _n "Left unassigned: mostly inside an MSA already in MET2013"
            list cpuma0010 msa_census share_census cpuma_share if metro == . & ///
                in_met == 1 & share_census >= `minshare' & share_census < ., noobs
        }

        keep cpuma0010 metro src cpuma_share msa_census share_census
        save "`outdir'/cpuma0010_to_met2013.dta", replace

        * Coverage of every metro relative to its 2013 MSA, in 2020 population
        *   omission_c:   share of the MSA's population in CPUMAs assigned elsewhere
        *   commission_c: share of the metro's assigned population outside the MSA
        keep if metro < .
        merge 1:1 cpuma0010 using "`outdir'/cpuma0010_pop.dta", keepusing(cpop) ///
            assert(match using) keep(match) nogen
        collapse (sum) apop = cpop (max) src, by(metro)
        tempfile apop
        save `apop'

        use "`outdir'/cpuma0010_msa2013_census.dta", clear
        merge m:1 cpuma0010 using "`outdir'/cpuma0010_to_met2013.dta", ///
            keepusing(metro) keep(master match) nogen
        gen double hit = pop_x * (metro == msa)
        collapse (sum) inside = hit mpop = pop_x, by(msa)
        rename msa metro
        merge 1:1 metro using `apop', keep(using match) nogen
        gen double omission_c      = 1 - inside / mpop
        gen double commission_c    = 1 - inside / apop
        gen double mismatch_census = omission_c + commission_c
        keep metro src omission_c commission_c mismatch_census
        save "`outdir'/metro_coverage_census0010.dta", replace
    restore
}

merge m:1 cpuma0010 using "`outdir'/cpuma0010_to_met2013.dta", nogen ///
    keepusing(metro src)

* Coverage relative to MET2013 (household weights).
*   omission:   share of a MET2013 metro's households in CPUMAs assigned elsewhere
*   commission: share of households assigned to the metro that MET2013 puts elsewhere
* MET2013 never identifies the metros added in step 1b, so theirs come from
* the census crosswalk (2020 population) instead.
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
    collapse (mean) commission = added (max) src [pw = hhwt], by(metro)
    merge 1:1 metro using `om', nogen keep(master match)
    gen double mismatch = omission + commission
    if `addmsa' == 1 {
        merge 1:1 metro using "`outdir'/metro_coverage_census0010.dta", nogen ///
            keep(master match) keepusing(omission_c commission_c mismatch_census)
        replace omission   = omission_c      if src == 2
        replace commission = commission_c    if src == 2
        replace mismatch   = mismatch_census if src == 2
        drop omission_c commission_c
    }
    save "`outdir'/metro_coverage0010.dta", replace
    di as txt _n "Coverage of CPUMA-based metros:"
    summarize omission commission mismatch, detail
    if `addmsa' == 1 {
        di as txt _n "Mismatch by source (src 1: vs MET2013 households;" ///
            " src 2 and mismatch_census: vs 2013 MSA, 2020 population):"
        tabstat mismatch mismatch_census, by(src) stat(n mean p50 p90 max) format(%6.3f)
    }
restore

*------------------------------------------------------------------------------
* 2. Census division and region of each metro (largest share of households)
*------------------------------------------------------------------------------
* Census division from STATEICP (ICPSR state codes)
gen byte division = .
replace division = 1 if inlist(stateicp, 1, 2, 3, 4, 5, 6)                    // New England: CT ME MA NH RI VT
replace division = 2 if inlist(stateicp, 12, 13, 14)                          // Middle Atlantic: NJ NY PA
replace division = 3 if inlist(stateicp, 21, 22, 23, 24, 25)                  // East North Central: IL IN MI OH WI
replace division = 4 if inlist(stateicp, 31, 32, 33, 34, 35, 36, 37)          // West North Central: IA KS MN MO NE ND SD
replace division = 5 if inlist(stateicp, 11, 40, 43, 44, 47, 48, 52, 56, 98)  // South Atlantic: DE VA FL GA NC SC MD WV DC
replace division = 6 if inlist(stateicp, 41, 46, 51, 54)                      // East South Central: AL MS KY TN
replace division = 7 if inlist(stateicp, 42, 45, 49, 53)                      // West South Central: AR LA TX OK
replace division = 8 if inlist(stateicp, 61, 62, 63, 64, 65, 66, 67, 68)      // Mountain: AZ CO ID MT NV NM UT WY
replace division = 9 if inlist(stateicp, 71, 72, 73, 81, 82)                  // Pacific: CA OR WA AK HI

label define division 1 "New England" 2 "Middle Atlantic" 3 "East North Central" ///
    4 "West North Central" 5 "South Atlantic" 6 "East South Central"            ///
    7 "West South Central" 8 "Mountain" 9 "Pacific", replace
label values division division

* Every state and DC should be assigned (83 = Puerto Rico; 96/97/99 = not a state)
assert division < . if !inlist(stateicp, 83, 96, 97, 99)

preserve
    keep if inlist(gq, 1, 2, 5) & metro < . & division < .
    collapse (sum) hh = hhwt, by(metro division)
    bysort metro (hh): keep if _n == _N
    gen byte region = cond(division <= 2, 1, cond(division <= 4, 2, cond(division <= 7, 3, 4)))
    keep metro division region
    save "`outdir'/metro_division0010.dta", replace
restore
drop division

*------------------------------------------------------------------------------
* 3. Renter households paying cash rent, 1-3 bedrooms
*------------------------------------------------------------------------------
keep if metro < . & inlist(gq, 1, 2, 5)
keep if ownershp == 2 & rentgrs > 0 & rentgrs < .     // RENTGRS = 0 is N/A
gen byte br = bedrooms - 1                             // IPUMS code = bedrooms + 1
keep if inrange(br, 1, 3)
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

merge m:1 metro using "`outdir'/metro_division0010.dta", nogen keep(match)
merge m:1 metro using "`outdir'/metro_coverage0010.dta", nogen keep(master match) ///
    keepusing(mismatch src)
if `maxmismatch' < . {
    drop if mismatch > `maxmismatch' & mismatch < .
}

egen byte _tag = tag(metro)
quietly count if _tag
di as txt _n "Metros in the balanced panel: " as res r(N) as txt "; years: `yrs'"
tab src if _tag
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

* Weighted means over the metros in the same cycle area and year:
*   lo_  leaves out the metro itself; used to estimate gamma (step 5)
*   reg_ includes every metro, so it is identical within a cycle area-year;
*        used to build the instruments (step 6). The leave-out mean would put
*        each metro's own change into its instrument with a negative sign.
foreach v in p lnR_dm {
    gen double _wx = cw * `v'
    gen double _w  = cw * (`v' < .)
    bysort `cyclevel' year: egen double _S = total(_wx)
    bysort `cyclevel' year: egen double _W = total(_w)
    gen double lo_`v'  = (_S - cond(`v' < ., _wx, 0)) / (_W - _w) if (_W - _w) > 0
    gen double reg_`v' = _S / _W if _W > 0
    drop _wx _w _S _W
}
rename lo_p       P_lo
rename lo_lnR_dm  L_lo
rename reg_p      P_reg
rename reg_lnR_dm L_reg
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
gen double Z_lvl      = gamma_lo   * L_reg
gen double Z_chg      = gamma_lo   * P_reg
gen double Z_lvl_full = gamma_full * L_reg
gen double Z_chg_full = gamma_full * P_reg

label var lnR        "Log real rent index (fixed-weight 1-3BR medians)"
label var p          "Annual change in lnR"
label var L_lo       "Leave-out regional log rent level (demeaned)"
label var P_lo       "Leave-out regional annual rent change"
label var L_reg      "Regional log rent level (demeaned), all metros"
label var P_reg      "Regional annual rent change, all metros"
label var gamma_lo   "Sensitivity, leave-out window around year"
label var gamma_full "Sensitivity, all years"
label var Z_lvl      "gamma_lo x L_reg"
label var Z_chg      "gamma_lo x P_reg"
label define src 1 "MET2013 households" 2 "Census MSA crosswalk", replace
label values src src
label var src        "Source of the metro assignment"

sort metro year
order metro year src division region lnR p L_lo P_lo L_reg P_reg gamma_lo gamma_full ///
    Z_lvl Z_chg Z_lvl_full Z_chg_full
save "`outdir'/rent_instrument_metro_year0010.dta", replace

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

*------------------------------------------------------------------------------
* 8. Outcomes from ACS person records: people who started living with an
*    unmarried partner in the 12 months before the interview.
*    One row per metro x year x age group.
*------------------------------------------------------------------------------
local extract     "usa_00584.dta"   // IPUMS USA extract (.dta)
local outdir      "rent_gamma_out"
local xw_msa      "MSA2013_PUMA2020_crosswalk.xlsx"  // Census: 2013 MSA x 2020 PUMA populations
local xw_cpuma    "cpuma0010_summary_1.xlsx"         // IPUMS: 2020 PUMAs in each cpuma0010
local firstyear   2005                // cpuma0010 is available from 2012
local use2020     0       // 1 = keep 2020 (experimental weights)
local minshare    0.9    // min share of a CPUMA in its metro: households (step 1), 2020 population (step 1b)
local addmsa      0       // 1 = add 2013 MSAs that MET2013 does not identify (steps 0a and 1b)
local maxmismatch .       // drop metros with omission+commission above this (. = keep all)
local movers      0       // 1 = households that moved in within 12 months only
local mincell     60     // min unweighted households per metro-year-bedroom cell
local cyclevel    division  // geography of the leave-out cycle: region or division
local cyclewt     0       // 1 = weight the cycle by renter households; 0 = equal weighting for all metros
local buffer      1       // gamma_lo drops years with |year - target| <= buffer
local minobs      6       // min annual changes to estimate a metro's gamma

* 2SLS (steps 8-9)
local extract_p1   "usa_00597.dta"   // 2018, 19, 21 person records with: year perwt gq age marst sploc
                                //   cpuma0010 migrate1d migplac1 migpuma1
                                //   migrate1d_sp migplac1_sp migpuma1_sp
local extract_p2   "usa_00596.dta"   // 2015-17 person records with: year perwt gq age marst sploc
local extract_p3   "usa_00595.dta"   // 2012-14 person records with: year perwt gq age marst sploc	
local extract_p4   "usa_00594.dta"   // 2009-11 person records with: year perwt gq age marst sploc	
local extract_p5   "usa_00593.dta"   // 2006-08 person records with: year perwt gq age marst sploc								
local agecuts     18 25 35 45   // age groups 18-24, 25-34, 35-44
local exposure    avg     // avg = mean of years t-1 and t (move-ins reported in year t
                          //   happened in the 12 months before the interview); cur = year t
local vintfe      0       // 1 = metro x MIGPUMA-vintage FE (MIGPUMA boundaries change in 2012)
local nag    : word count `agecuts'
local agemin : word 1 of `agecuts'
local agemax : word `nag' of `agecuts'

use "`extract_p1'", clear 
keep if year >= `firstyear' & inlist(gq, 1, 2, 5) & age >= `agemin' & age < `agemax'  
append using "`extract_p2'"
keep if year >= `firstyear' & inlist(gq, 1, 2, 5) & age >= `agemin' & age < `agemax'  
append using "`extract_p3'"
keep if year >= `firstyear' & inlist(gq, 1, 2, 5) & age >= `agemin' & age < `agemax'  
append using "`extract_p4'"
keep if year >= `firstyear' & inlist(gq, 1, 2, 5) & age >= `agemin' & age < `agemax'  
append using "`extract_p5'"
keep if year >= `firstyear' & inlist(gq, 1, 2, 5) & age >= `agemin' & age < `agemax'  

if `use2020' == 0 {
    drop if year == 2020
}


merge m:1 cpuma0010 using "`outdir'/cpuma0010_to_met2013.dta", ///
    keepusing(metro) keep(match) nogen
drop if metro == .

* Unmarried partner present (SPLOC links the householder and an unmarried
* partner). A mover is anyone not in the same house a year ago.
gen byte cohab       = sploc > 0 & marst > 2
gen byte moved       = migrate1d    != 10
gen byte moved_sp    = migrate1d_sp != 10
gen byte diff_origin = migplac1 != migplac1_sp | migpuma1 != migpuma1_sp

gen byte new_one  = cohab & (moved + moved_sp == 1)           // one partner moved in
gen byte new_both = cohab & moved & moved_sp &  diff_origin   // both moved, from different places
gen byte amb      = cohab & moved & moved_sp & !diff_origin   // both moved, same MIGPUMA

* p: among couples where one partner moved in, the weighted share whose mover
* came from the stayer's own migration PUMA. MIGRATE1D 23 = moved within the
* state and within the PUMA (check with -label list-); 25 and 90 can't be placed.
* Pooled across years within each MIGPUMA vintage (2000-based before 2012).
gen byte vint = year >= 2012
gen byte same_origin = migrate1d_sp == 23 if new_one & !moved ///
    & !inlist(migrate1d_sp, 25, 90)
gen double _wx = perwt * same_origin
gen double _w  = perwt * (same_origin < .)
bysort metro vint: egen double _sx = total(_wx)
bysort metro vint: egen double _sw = total(_w)
gen double p_m = _sx / _sw if _sw > 0
drop _wx _w _sx _sw same_origin

* Metro x year x age-group cells. Each partner counts in their own age group.
gen byte agegrp = .
forvalues i = 1/`=`nag'-1' {
    local lo : word `i' of `agecuts'
    local hi : word `=`i'+1' of `agecuts'
    replace agegrp = `lo' if age >= `lo' & age < `hi'
}
gen double w_one  = perwt * new_one
gen double w_both = perwt * new_both
gen double w_amb  = perwt * amb
gen byte one = 1
collapse (sum) pop = perwt n_one = w_one n_both = w_both n_amb = w_amb ///
         nobs = one (mean) p_m, by(metro year vint agegrp)

gen double y_one   = 1000 * n_one / pop
gen double y_new   = 1000 * (n_one + n_both) / pop
gen double y_corr  = 1000 * (n_one + n_both / (1 - p_m)) / pop
gen double y_upper = 1000 * (n_one + n_both + n_amb) / pop

label var pop     "Weighted population of the cell"
label var nobs    "Unweighted people in the cell"
label var p_m     "Share of one-moved-in couples whose mover came from the stayer's MIGPUMA"
label var y_one   "Per 1,000: began living with a partner, one partner moved in"
label var y_new   "Per 1,000: y_one + both moved from different places"
label var y_corr  "Per 1,000: y_new with both-moved couples scaled by 1/(1-p)"
label var y_upper "Per 1,000: y_new + both moved from the same MIGPUMA"
save "`outdir'/cohab_outcomes_metro_year_age0010.dta", replace

*------------------------------------------------------------------------------
* 9. 2SLS: rent and new cohabiting couples
*    lvl: log rent level R_x,      instrument gamma_lo x regional level  (Z_x)
*    chg: annual rent change dR_x, instrument gamma_lo x regional change (dZ_x)
*    FE: metro (or metro x MIGPUMA vintage) and division x year, within each
*        age group; "all" pools the age groups with age-group-specific FE.
*    Cells weighted by population; SEs clustered by metro.
*------------------------------------------------------------------------------
capture which ivreghdfe
if _rc {
    di as error "ivreghdfe not found: ssc install ivreghdfe (also ivreg2, ranktest, ftools, reghdfe)"
    exit 199
}

* Rent exposure. Under "avg", the first year drops, and so does 2021 when
* use2020 = 0, because year t-1 is missing.
preserve
    use "`outdir'/rent_instrument_metro_year0010.dta", clear
    xtset metro year
    if "`exposure'" == "avg" {
        gen double R_x  = (lnR   + L.lnR)   / 2
        gen double Z_x  = (Z_lvl + L.Z_lvl) / 2
        gen double dR_x = (p     + L.p)     / 2
        gen double dZ_x = (Z_chg + L.Z_chg) / 2
    }
    else {
        gen double R_x  = lnR
        gen double Z_x  = Z_lvl
        gen double dR_x = p
        gen double dZ_x = Z_chg
    }
    keep metro year division R_x Z_x dR_x dZ_x
    tempfile inst
    save `inst'
restore
merge m:1 metro year using `inst', keep(match) nogen

local mfe metro
if `vintfe' == 1 local mfe metro#vint

tempname h
postfile `h' str8 outcome str6 sample str3 spec                      ///
    double(ymean b_ols se_ols b_rf se_rf b_iv se_iv F) long(N metros) ///
    using "`outdir'/cohab_2sls_results0010.dta", replace

quietly levelsof agegrp, local(groups)
foreach spec in lvl chg {
    if "`spec'" == "lvl" {
        local x R_x
        local z Z_x
    }
    else {
        local x dR_x
        local z dZ_x
    }
    foreach y in y_one y_new y_corr y_upper {
        foreach g in all `groups' {
            if "`g'" == "all" {
                local cond
                local fe  `mfe'#agegrp division#year#agegrp
                local lab "all"
            }
            else {
                local cond if agegrp == `g'
                local fe  `mfe' division#year
                local k   : list posof "`g'" in agecuts
                local hi  : word `=`k'+1' of `agecuts'
                local lab "`g'-`=`hi'-1'"
            }

            capture quietly ivreghdfe `y' (`x' = `z') `cond' [aw = pop], ///
                absorb(`fe') cluster(metro)
            if _rc {
                di as error "2SLS failed: `y', `lab', `spec' (rc = " _rc ")"
                continue
            }
            local b_iv  = _b[`x']
            local se_iv = _se[`x']
            local F     = e(widstat)              // Kleibergen-Paap Wald F
            local N     = e(N)

            tempvar s t
            gen byte `s' = e(sample)
            egen byte `t' = tag(metro) if `s'
            quietly count if `t' == 1
            local metros = r(N)
            quietly summarize `y' if `s' [aw = pop]
            local ymean = r(mean)

            quietly reghdfe `y' `x' if `s' [aw = pop], absorb(`fe') vce(cluster metro)
            local b_ols  = _b[`x']
            local se_ols = _se[`x']
            quietly reghdfe `y' `z' if `s' [aw = pop], absorb(`fe') vce(cluster metro)
            local b_rf  = _b[`z']
            local se_rf = _se[`z']

            post `h' ("`y'") ("`lab'") ("`spec'") (`ymean') (`b_ols') (`se_ols') ///
                (`b_rf') (`se_rf') (`b_iv') (`se_iv') (`F') (`N') (`metros')
            drop `s' `t'
        }
    }
}
postclose `h'

preserve
    use "`outdir'/cohab_2sls_results0010.dta", clear
    format ymean b_* se_* %9.3f
    format F %8.1f
    di as txt _n "Rent and new cohabitants per 1,000 (exposure: `exposure')"
    list outcome sample spec ymean b_ols b_iv se_iv b_rf F N metros, ///
        sepby(spec outcome) noobs abbreviate(8)
restore
