-- ------------------------------------------------------------------
-- Title: Simplified Acute Physiology Score (SAPS)
-- MIMIC version: MIMIC-III v1.4
-- Originally written by: Alistair Johnson
-- Contact: aewj [at] mit [dot] edu
-- ------------------------------------------------------------------

-- This query extracts the simplified acute physiology score.
-- This score is a measure of patient severity of illness.
-- The score is calculated on the first day of each ICU patients' stay.
-- The score is calculated for *all* ICU patients, with the assumption that the user will subselect appropriate ICUSTAY_IDs.
-- For example, the score is calculated for neonates, but it is likely inappropriate to actually use the score values for these patients.

-- Reference for SAPS:
--    Jean-Roger Le Gall, Philippe Loirat, Annick Alperovitch, Paul Glaser, Claude Granthil, 
--    Daniel Mathieu, Philippe Mercier, Remi Thomas, and Daniel Villers.
--    "A simplified acute physiology score for ICU patients."
--    Critical care medicine 12, no. 11 (1984): 975-977.

-- Variables used in SAPS:
--  Age, GCS
--  VITALS: Heart rate, systolic blood pressure, temperature, respiration rate
--  FLAGS: ventilation/cpap
--  IO: urine output
--  LABS: blood urea nitrogen, hematocrit, WBC, glucose, potassium, sodium, HCO3

-- The following views are required to run this query:
--  1) uofirstday - generated by urine-output-first-day.sql
--  2) ventfirstday - generated by ventilated-first-day.sql
--  3) vitalsfirstday - generated by vitals-first-day.sql
--  4) gcsfirstday - generated by gcs-first-day.sql
--  5) labsfirstday - generated by labs-first-day.sql

DROP MATERIALIZED VIEW IF EXISTS SAPS;

CREATE MATERIALIZED VIEW SAPS as
-- extract CPAP from the "Oxygen Delivery Device" fields
with cpap as
(
  select ie.icustay_id
    , max(case when value in ('CPAP Mask','Bipap Mask') then 1 else 0 end) as cpap
  from icustays ie
  inner join chartevents ce
    on ie.icustay_id = ce.icustay_id
    and ce.charttime between ie.intime and ie.intime + interval '1' day
  where itemid in
  (
    -- TODO: when metavision data import fixed, check the values in 226732 match the value clause below
    467, 469, 226732
  )
  and value in ('CPAP Mask','Bipap Mask')
  group by ie.icustay_id
)
, cohort as
(
select ie.subject_id, ie.hadm_id, ie.icustay_id
      , ie.intime
      , ie.outtime

      -- the casts ensure the result is numeric.. we could equally extract EPOCH from the interval
      -- however this code works in Oracle and Postgres
      , round( ( cast(ie.intime as date) - cast(pat.dob as date) ) / 365.242 , 2 ) as age
      , gcs.mingcs
      , vital.heartrate_max
      , vital.heartrate_min
      , vital.sysbp_max
      , vital.sysbp_min
      , vital.resprate_max
      , vital.resprate_min
      , vital.tempc_max
      , vital.tempc_min

      , coalesce(vital.glucose_max, labs.glucose_max) as glucose_max
      , coalesce(vital.glucose_min, labs.glucose_min) as glucose_min

      , labs.bun_max
      , labs.bun_min
      , labs.hematocrit_max
      , labs.hematocrit_min
      , labs.wbc_max
      , labs.wbc_min
      , labs.sodium_max
      , labs.sodium_min
      , labs.potassium_max
      , labs.potassium_min
      , labs.bicarbonate_max
      , labs.bicarbonate_min

      , vent.mechvent
      , uo.urineoutput

      , cp.cpap

from mimiciii.icustays ie
inner join mimiciii.admissions adm
  on ie.hadm_id = adm.hadm_id
inner join mimiciii.patients pat
  on ie.subject_id = pat.subject_id

-- join to above view to get CPAP
left join cpap cp
  on ie.icustay_id = cp.icustay_id

-- join to custom tables to get more data....
left join gcsfirstday gcs
  on ie.icustay_id = gcs.icustay_id
left join vitalsfirstday vital
  on ie.icustay_id = vital.icustay_id
left join uofirstday uo
  on ie.icustay_id = uo.icustay_id
left join ventfirstday vent
  on ie.icustay_id = vent.icustay_id
left join labsfirstday labs
  on ie.icustay_id = labs.icustay_id
)
, scorecomp as
(
select
  cohort.*
  -- Below code calculates the component scores needed for SAPS
  , case
      when age is null then null
      when age <= 45 then 0
      when age <= 55 then 1
      when age <= 65 then 2
      when age <= 75 then 3
      when age >  75 then 4
    end as age_score
  , case
      when heartrate_max is null then null
      when heartrate_max >= 180 then 4
      when heartrate_min < 40 then 4
      when heartrate_max >= 140 then 3
      when heartrate_min <= 54 then 3
      when heartrate_max >= 110 then 2
      when heartrate_min <= 69 then 2
      when heartrate_max >= 70 and heartrate_max <= 109
        and heartrate_min >= 70 and heartrate_min <= 109
      then 0
    end as hr_score
  , case
      when sysbp_min is null then null
      when sysbp_max >= 190 then 4
      when sysbp_min < 55 then 4
      when sysbp_max >= 150 then 2
      when sysbp_min <= 79 then 2
      when sysbp_max >= 80 and sysbp_max <= 149
        and sysbp_min >= 80 and sysbp_min <= 149
        then 0
    end as sysbp_score

  , case
      when tempc_max is null then null
      when tempc_max >= 41.0 then 4
      when tempc_min <  30.0 then 4
      when tempc_max >= 39.0 then 3
      when tempc_min <= 31.9  then 3
      when tempc_min <= 33.9  then 2
      when tempc_max >  38.4 then 1
      when tempc_min <  36.0  then 1
      when tempc_max >= 36.0 and tempc_max <= 38.4
       and tempc_min >= 36.0 and tempc_min <= 38.4
        then 0
    end as temp_score

  , case
      when resprate_min is null then null
      when resprate_max >= 50 then 4
      when resprate_min <  6 then 4
      when resprate_max >= 35 then 3
      when resprate_min <= 9 then 2
      when resprate_max >= 25 then 1
      when resprate_min <= 11 then 1
      when  resprate_max >= 12 and resprate_max <= 24
        and resprate_min >= 12 and resprate_min <= 24
          then 0
      end as resp_score

  , case
      when coalesce(mechvent,cpap) is null then null
      when cpap = 1 then 3
      when mechvent = 1 then 3
      else 0
    end as vent_score

  , case
      when UrineOutput is null then null
      when UrineOutput >  5000.0 then 2
      when UrineOutput >= 3500.0 then 1
      when UrineOutput >=  700.0 then 0
      when UrineOutput >=  500.0 then 2
      when UrineOutput >=  200.0 then 3
      when UrineOutput <   200.0 then 4
    end as uo_score

  , case
      when bun_max is null then null
      when bun_max >= 55.0 then 4
      when bun_max >= 36.0 then 3
      when bun_max >= 29.0 then 2
      when bun_max >= 7.50 then 1
      when bun_min < 3.5 then 1
      when  bun_max >= 3.5 and bun_max < 7.5
        and bun_min >= 3.5 and bun_min < 7.5
          then 0
    end as bun_score

  , case
      when hematocrit_max is null then null
      when hematocrit_max >= 60.0 then 4
      when hematocrit_min <  20.0 then 4
      when hematocrit_max >= 50.0 then 2
      when hematocrit_min < 30.0 then 2
      when hematocrit_max >= 46.0 then 1
      when  hematocrit_max >= 30.0 and hematocrit_max < 46.0
        and hematocrit_min >= 30.0 and hematocrit_min < 46.0
          then 0
      end as hematocrit_score

  , case
      when wbc_max is null then null
      when wbc_max >= 40.0 then 4
      when wbc_min <   1.0 then 4
      when wbc_max >= 20.0 then 2
      when wbc_min <   3.0 then 2
      when wbc_max >= 15.0 then 1
      when wbc_max >=  3.0 and wbc_max < 15.0
       and wbc_min >=  3.0 and wbc_min < 15.0
        then 0
    end as wbc_score

  , case
      when glucose_max is null then null
      when glucose_max >= 44.5 then 4
      when glucose_min <   1.6 then 4
      when glucose_max >= 27.8 then 3
      when glucose_min <   2.8 then 3
      when glucose_min <   3.9 then 2
      when glucose_max >= 14.0 then 1
      when glucose_max >=  3.9 and glucose_max < 14.0
       and glucose_min >=  3.9 and glucose_min < 14.0
        then 0
      end as glucose_score

  , case
      when potassium_max is null then null
      when potassium_max >= 7.0 then 4
      when potassium_min <  2.5 then 4
      when potassium_max >= 6.0 then 3
      when potassium_min <  3.0 then 2
      when potassium_max >= 5.5 then 1
      when potassium_min <  3.5 then 1
      when potassium_max >= 3.5 and potassium_max < 5.5
       and potassium_min >= 3.5 and potassium_min < 5.5
        then 0
      end as potassium_score

  , case
      when sodium_max is null then null
      when sodium_max >= 180 then 4
      when sodium_min  < 110 then 4
      when sodium_max >= 161 then 3
      when sodium_min  < 120 then 3
      when sodium_max >= 156 then 2
      when sodium_min  < 130 then 2
      when sodium_max >= 151 then 1
      when sodium_max >= 130 and sodium_max < 151
       and sodium_min >= 130 and sodium_min < 151
        then 0
      end as sodium_score

  , case
      when bicarbonate_max is null then null
      when bicarbonate_min <   5.0 then 4
      when bicarbonate_max >= 40.0 then 3
      when bicarbonate_min <  10.0 then 3
      when bicarbonate_max >= 30.0 then 1
      when bicarbonate_min <  20.0 then 1
      when bicarbonate_max >= 20.0 and bicarbonate_max < 30.0
       and bicarbonate_min >= 20.0 and bicarbonate_min < 30.0
          then 0
      end as bicarbonate_score

   , case
      when mingcs is null then null
        when mingcs <  3 then null -- erroneous value/on trach
        when mingcs =  3 then 4
        when mingcs <  7 then 3
        when mingcs < 10 then 2
        when mingcs < 13 then 1
        when mingcs >= 13
         and mingcs <= 15
          then 0
        end as gcs_score
from cohort
)
select ie.subject_id, ie.hadm_id, ie.icustay_id
-- coalesce statements impute normal score of zero if data element is missing
, coalesce(age_score,0)
+ coalesce(hr_score,0)
+ coalesce(sysbp_score,0)
+ coalesce(resp_score,0)
+ coalesce(temp_score,0)
+ coalesce(uo_score,0)
+ coalesce(vent_score,0)
+ coalesce(bun_score,0)
+ coalesce(hematocrit_score,0)
+ coalesce(wbc_score,0)
+ coalesce(glucose_score,0)
+ coalesce(potassium_score,0)
+ coalesce(sodium_score,0)
+ coalesce(bicarbonate_score,0)
+ coalesce(gcs_score,0)
  as SAPS
, age_score
, hr_score
, sysbp_score
, resp_score
, temp_score
, uo_score
, vent_score
, bun_score
, hematocrit_score
, wbc_score
, glucose_score
, potassium_score
, sodium_score
, bicarbonate_score
, gcs_score

from icustays ie
left join scorecomp s
  on ie.icustay_id = s.icustay_id
order by ie.icustay_id;
