/**************************************************************************
/* Preliminaries                                                         
**************************************************************************/

/* Output directory */
%let outdir=/scratch/duke/sec_13f/;
libname out "&outdir";

/* WRDS SEC Analytics Suite */
libname f13 '/wrds/sec/sasdata';

/* Modified based on the WRDS research note: 
   https://wrds-www.wharton.upenn.edu/documents/752/Research_Note_-Thomson_S34_Data_Issues_mldAsdi.pdf
   Note the transition from CRSP SIZ/FIZ to CIZ Format.
   I use stksecurityinfohdr instead of msenames, msf_v2 instead of msf.
   Rong Wang, June 2026
 */


/**************************************************************************
* Step 1. Load 13F holdings data and construct initial filing sample
*
* - Keep only filings after XML reporting became mandatory (2013Q2)
* - Match holdings to CRSP PERMNOs using 8-digit CUSIP
* - Use CRSP security information dates to avoid historical CUSIP reuse
* - Keep only positive holding positions
**************************************************************************/

proc sql;
    create table Fix1 as
    select distinct
        a.cik,
        a.rdate,
        a.fdate,
        a.fname,
        b.permno,
        a.cusip,
        a.value      as value  label="Holding Value",
        a.sshPrnamt  as shares label="Holding Shares",
        count(*)     as n13frecs label="Number of Records"

    from f13.WRDS_13F_Holdings as a

    inner join crsp.stksecurityinfohdr as b
        on substr(a.cusip,1,8) = b.cusip
       and a.rdate >= b.secinfostartdt
       and (missing(b.secinfoenddt)
            or a.rdate <= b.secinfoenddt)

    where missing(a.putCall)
      and not missing(a.cusip)
      and a.sshPrnamt > 0
      and a.rdate >= "30JUN2013"d

    group by a.fname;
quit;


/**************************************************************************
* Step 2. For each institution-quarter, identify the correct filing
*
* Multiple filings can exist for the same report date (rdate):
*   - Original filing
*   - Amendments
*   - Restatements
*
* Goal:
*   Select the best filing (FNAME) for each CIK-quarter.
**************************************************************************/

/*-----------------------------------------------------------------------
* Create one observation per filing
*-----------------------------------------------------------------------*/
proc sql;
    create table F13_dates as
    select distinct
        cik,
        rdate,
        fdate,
        fname,
        n13frecs
    from Fix1
    order by cik, rdate, fdate, fname;
quit;

/*-----------------------------------------------------------------------
* Add filing metadata from WRDS summary file
*-----------------------------------------------------------------------*/
proc sql;
    create table F13_dates as
    select
        a.*,
        b.reportType,
        b.amendmentType,
        b.confDeniedExpired,
        b.tableEntryTotal
    from F13_dates as a

    left join f13.WRDS_13F_Summary as b
        on a.fname = b.fname

    order by cik, rdate, fdate;
quit;

/*
amendmentType:
    RESTATEMENT vs NEW HOLDINGS

confDeniedExpired:
    Confidential treatment denied/expired flag

tableEntryTotal:
    Number of securities reported in filing
*/

/*-----------------------------------------------------------------------
* Separate quarters with one filing from quarters with multiple filings
*-----------------------------------------------------------------------*/
data f13_dates1
     f13_dates2;

    set F13_dates;
    by cik rdate;

    /* Fill missing tableEntryTotal if necessary */
    if tableEntryTotal <= 0 and n13frecs > 0 then
        tableEntryTotal = n13frecs;

    if first.rdate and last.rdate then
        output f13_dates1;
    else
        output f13_dates2;
run;

/*-----------------------------------------------------------------------
* For multiple filings:
*   - Remove amendments filed >30 days later
*   - Remove filings with substantially fewer records
*   - Remove confidential-treatment filings
*-----------------------------------------------------------------------*/
data f13_dates2;
    set f13_dates2;
    by cik rdate;

    if (fdate-lag(fdate) > 30
        or tableEntryTotal/lag(tableEntryTotal) < 0.5
        or upcase(confDeniedExpired) = "TRUE")
       and not first.rdate
    then delete;
run;

/*-----------------------------------------------------------------------
* Keep the most recent remaining filing
*-----------------------------------------------------------------------*/
data f13_dates2;
    set f13_dates2;
    by cik rdate fdate;

    if last.rdate;
run;

/*-----------------------------------------------------------------------
* Final list of valid filings
*-----------------------------------------------------------------------*/
data F13_dates;
    set f13_dates1
        f13_dates2;
        
    keep
        cik
        rdate
        fdate
        fname;
run;

/*-----------------------------------------------------------------------
* Housekeeping
*-----------------------------------------------------------------------*/
proc datasets library=work nolist;
    delete f13_dates1 f13_dates2;
quit;

/* Sanity check: one filing per CIK-quarter */
proc sort data=F13_dates nodupkey;
    by cik rdate;
run;

/*-----------------------------------------------------------------------
* Construct holdings dataset using selected filings
*-----------------------------------------------------------------------*/
proc sql;
    create table Fix2 as
    select
        a.cik,
        a.rdate,
        a.fdate,
        a.fname,
        a.n13frecs,
        a.permno,
        a.cusip,
        a.value,
        a.shares
    from Fix1 as a

    inner join F13_dates as b
        on a.fname = b.fname;
quit;


/**************************************************************************
* Step 3. Merge with CRSP and calculate institutional ownership
*
* - Restrict to U.S. common stocks
* - Obtain quarter-end price and shares outstanding
* - Calculate market capitalization
* - Calculate institutional ownership percentage
**************************************************************************/

proc sql;
    create table Fix3 as
    select
        a.*,
        abs(b.mthprc) as prc,
        abs(b.mthprc) * b.shrout / 1000 as mktcap, /* $mil */
        case
            when b.shrout > 0
            then a.shares / (b.shrout * 1000)
        end as ownpct

    from Fix2 as a

    inner join crsp.msf_v2 as b
        on a.permno = b.permno
       and a.rdate  = b.mthcaldt

    where b.securitytype    = 'EQTY'
      and b.securitysubtype = 'COM'
      and b.sharetype       = 'NS'
      and b.usincflg        = 'Y'
      and b.issuertype in ('ACOR','CORP');
quit;

/*-----------------------------------------------------------------------
* Winsorize ownership percentages
* Aggregate BlackRock subsidiaries to parent CIK
*-----------------------------------------------------------------------*/
data Fix4;
    set Fix3;

    /* Roughly 300 observations per quarter exceed 50% ownership.
       Cap ownership at 50%. */
    if ownpct > 0.5 then ownpct = 0.5;

    /* Aggregate BlackRock subsidiaries to parent company
       (Ben-David et al., 2016) */
    if cik in
       ('0001003283',
        '0001006249',
        '0001085635',
        '0001086364',
        '0001305227',
        '0001364742')
    then cik = '0000913414';
run;

/*-----------------------------------------------------------------------
* Aggregate holdings to institution-quarter-stock level
*-----------------------------------------------------------------------*/
proc sql;
    create table Fix5 as
    select
        cik,
        rdate,
        permno,
        prc,
        mktcap,

        sum(value)  as value
            format=dollar12.2,

        sum(shares) as shares
            format=comma18.0,

        sum(ownpct) as ownpct
            format=percentn8.2

    from Fix4

    group by
        cik,
        rdate,
        permno;
quit;

/*-----------------------------------------------------------------------
* Sanity check: one observation per institution-quarter-stock
*-----------------------------------------------------------------------*/
proc sort data=Fix5 nodupkey;
    by cik rdate permno;
run;


/**************************************************************************
* Step 4. Add manager identifiers (MGRNO)
*
* - Link SEC CIKs to WRDS/Thomson manager identifiers, mgrno
* - Resolve multiple matches using WRDS link quality
* - Create synthetic negative MGRNOs when no link exists
**************************************************************************/

/*-----------------------------------------------------------------------
* One observation per manager-quarter
*-----------------------------------------------------------------------*/
proc sql;
    create table Link1 as
    select distinct
        cik,
        rdate
    from Fix5;
quit;

/*-----------------------------------------------------------------------
* Link CIK to WRDS manager identifiers
*-----------------------------------------------------------------------*/
proc sql;
    create table Link2 as
    select
        a.cik,
        a.rdate,
        b.mgrno,
        b.matchrate,
        b.flag
    from Link1 as a

    left join f13.WRDS_13F_Link as b
        on a.cik = b.cik

    order by
        mgrno,
        rdate,
        flag desc;
quit;

/*-----------------------------------------------------------------------
* Determine whether manager exists in Thomson 13F database
*-----------------------------------------------------------------------*/
proc sql;
    create table Link3 as
    select
        a.*,
        (b.mgrno is not null) as ins34
    from Link2 as a

    left join
    (
        select distinct
            mgrno
        from tfn.s34type1
        where fdate="30JUN2013"d
    ) as b

        on a.mgrno=b.mgrno

    order by
        mgrno,
        rdate,
        flag desc;
quit;

/*-----------------------------------------------------------------------
* If multiple MGRNOs map to one CIK-quarter,
* keep the highest-quality manager link.
*-----------------------------------------------------------------------*/
data Link3;
    set Link3;
    by mgrno rdate descending flag;

    if not missing(mgrno) and not first.rdate then
        delete;
run;

proc sort data=Link3;
    by
        cik
        rdate
        descending flag
        descending ins34
        descending matchrate;
run;

data Link4;
    set Link3;
    by cik rdate;

    if first.rdate;
run;

/*-----------------------------------------------------------------------
* Sanity check:
* one manager per CIK-quarter
*-----------------------------------------------------------------------*/
proc sort data=Link4 nodupkey;
    by cik rdate;
run;

/*-----------------------------------------------------------------------
* Merge manager identifiers back into holdings
*-----------------------------------------------------------------------*/
proc sql;
    create table Fix6 as
    select
        b.mgrno,
        a.*
    from Fix5 as a

    left join Link4 as b
        on a.cik   = b.cik
       and a.rdate = b.rdate;
quit;

/*-----------------------------------------------------------------------
* Create synthetic manager IDs for unmatched CIKs
*-----------------------------------------------------------------------*/
data F13_Holdings;
    set Fix6;

    if missing(mgrno) then
        mgrno = -input(cik,best12.);
run;

/*-----------------------------------------------------------------------
* Sanity check:
* one observation per manager-quarter-stock
*-----------------------------------------------------------------------*/
proc sort data=F13_Holdings nodupkey;
    by mgrno rdate permno;
run;


/**************************************************************************
* Step 5. Save data
**************************************************************************/
data out.WRDS_SEC_2013_2025;
    set F13_Holdings;
run;

/* END */
