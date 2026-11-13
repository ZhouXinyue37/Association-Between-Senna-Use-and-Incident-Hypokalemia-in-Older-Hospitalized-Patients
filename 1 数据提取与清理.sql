-- 创建研究专用schema
CREATE SCHEMA IF NOT EXISTS senna_study;

-- 设置搜索路径
SET search_path TO senna_study, mimiciv_hosp, mimiciv_icu, public;

-- ============================================================
-- 模块1：基础人群 — 年龄≥65岁的住院患者
-- ============================================================
DROP TABLE IF EXISTS senna_study.cohort_base CASCADE;

CREATE TABLE senna_study.cohort_base AS
SELECT
    p.subject_id,
    a.hadm_id,
    p.gender,
    p.anchor_age AS age,
    a.admittime,
    a.dischtime,
    a.deathtime,
    a.hospital_expire_flag,
    -- 年龄分组
    CASE
        WHEN p.anchor_age BETWEEN 65 AND 74 THEN '65-74'
        WHEN p.anchor_age BETWEEN 75 AND 84 THEN '75-84'
        WHEN p.anchor_age >= 85 THEN '85+'
    END AS age_group
FROM mimiciv_hosp.patients p
INNER JOIN mimiciv_hosp.admissions a
    ON p.subject_id = a.subject_id
WHERE p.anchor_age >= 65
    -- 排除没有出院时间的记录（仍在院）
    AND a.dischtime IS NOT NULL;

-- ============================================================
-- 模块2：番泻叶暴露 — 提取首次番泻叶医嘱时间（index_time）
-- 检索关键词：senna, sennoside, senokot（大小写不敏感）
-- ============================================================
DROP TABLE IF EXISTS senna_study.senna_exposure CASCADE;

CREATE TABLE senna_study.senna_exposure AS
SELECT
    subject_id,
    hadm_id,
    MIN(starttime) AS index_time,
    COUNT(*) AS senna_order_count,
    -- 首次用药的剂量信息（用于后续剂量-反应分析）
    MIN(dose_val_rx) AS first_dose,
    MIN(dose_unit_rx) AS first_dose_unit,
    MIN(route) AS first_route
FROM mimiciv_hosp.prescriptions
WHERE (
        LOWER(drug) LIKE '%senna%'
     OR LOWER(drug) LIKE '%sennoside%'
     OR LOWER(drug) LIKE '%senokot%'
     OR LOWER(formulary_drug_cd) LIKE '%senna%'
     OR LOWER(formulary_drug_cd) LIKE '%senn%'
      )
    AND drug_type = 'MAIN'
    AND starttime IS NOT NULL
GROUP BY subject_id, hadm_id;

-- ============================================================
-- 模块3：确定index_time / landmark_time
-- 暴露组：首次番泻叶医嘱时间
-- 非暴露组：入院后48小时（landmark time）
-- ============================================================
DROP TABLE IF EXISTS senna_study.cohort_index CASCADE;

CREATE TABLE senna_study.cohort_index AS
SELECT
    cb.subject_id,
    cb.hadm_id,
    cb.gender,
    cb.age,
    cb.age_group,
    cb.admittime,
    cb.dischtime,
    cb.deathtime,
    cb.hospital_expire_flag,
    -- 暴露标志
    CASE WHEN se.hadm_id IS NOT NULL THEN 1 ELSE 0 END AS senna_exposed,
    -- 指数时间/对齐点
    COALESCE(se.index_time, cb.admittime + INTERVAL '48 hour') AS index_time,
    -- 记录对齐类型
    CASE
        WHEN se.hadm_id IS NOT NULL THEN 'senna_first_order'
        ELSE 'landmark_48h'
    END AS alignment_type,
    se.senna_order_count,
    se.first_dose,
    se.first_dose_unit,
    se.first_route
FROM senna_study.cohort_base cb
LEFT JOIN senna_study.senna_exposure se
    ON cb.subject_id = se.subject_id
   AND cb.hadm_id = se.hadm_id;

-- ============================================================
-- 模块4：提取所有血钾检测记录
-- itemid: 50971 = Potassium (血清钾，生化)
--       50822 = Potassium, Whole Blood (全血钾，血气)
--       52452 = Potassium, Whole Blood (v3.1新增)
-- ============================================================
DROP TABLE IF EXISTS senna_study.potassium_labs CASCADE;

CREATE TABLE senna_study.potassium_labs AS
SELECT
    le.subject_id,
    le.hadm_id,
    le.charttime,
    le.valuenum AS potassium,
    le.valueuom AS potassium_unit,
    le.itemid
FROM mimiciv_hosp.labevents le
WHERE le.itemid IN (50971, 50822, 52452)
    AND le.valuenum IS NOT NULL
    AND le.valuenum > 0
    -- 排除超出极端生理范围的值
    AND le.valuenum BETWEEN 1.0 AND 10.0;

-- ============================================================
-- 模块5：基线血钾 — index_time之前最近一次血钾值
-- 用于：(a) 排除index前已有低钾者 (b) 作为协变量
-- ============================================================
DROP TABLE IF EXISTS senna_study.baseline_k CASCADE;

CREATE TABLE senna_study.baseline_k AS
SELECT DISTINCT ON (ci.hadm_id)
    ci.subject_id,
    ci.hadm_id,
    pl.charttime AS baseline_k_charttime,
    pl.potassium AS baseline_k
FROM senna_study.cohort_index ci
INNER JOIN senna_study.potassium_labs pl
    ON ci.hadm_id = pl.hadm_id
   AND pl.charttime <= ci.index_time
ORDER BY ci.hadm_id, pl.charttime DESC;  -- 取index_time之前最近一次

-- ============================================================
-- 模块6：排除index_time/landmark前已有低钾（<3.5 mmol/L）者
-- ============================================================
DROP TABLE IF EXISTS senna_study.exclude_pre_low CASCADE;

CREATE TABLE senna_study.exclude_pre_low AS
SELECT DISTINCT ci.hadm_id
FROM senna_study.cohort_index ci
INNER JOIN senna_study.potassium_labs pl
    ON ci.hadm_id = pl.hadm_id
   AND pl.charttime <= ci.index_time
   AND pl.potassium < 3.5;

-- ============================================================
-- 模块7：主要结局 — index_time之后首次血钾 < 3.5 mmol/L
-- ============================================================
DROP TABLE IF EXISTS senna_study.post_index_low CASCADE;

CREATE TABLE senna_study.post_index_low AS
SELECT DISTINCT ON (ci.hadm_id)
    ci.hadm_id,
    pl.charttime AS event_time,
    pl.potassium AS event_k_value
FROM senna_study.cohort_index ci
INNER JOIN senna_study.potassium_labs pl
    ON ci.hadm_id = pl.hadm_id
   AND pl.charttime > ci.index_time
   AND pl.potassium < 3.5
WHERE ci.hadm_id NOT IN (SELECT hadm_id FROM senna_study.exclude_pre_low)
ORDER BY ci.hadm_id, pl.charttime ASC;  -- 取首次事件

-- ============================================================
-- 模块8：48-72小时限定窗结局
-- 仅统计index_time+48h之后、index_time+72h之内的事件
-- ============================================================
DROP TABLE IF EXISTS senna_study.window_48_72 CASCADE;

CREATE TABLE senna_study.window_48_72 AS
SELECT DISTINCT ON (ci.hadm_id)
    ci.hadm_id,
    pl.charttime AS window_event_time,
    pl.potassium AS window_event_k
FROM senna_study.cohort_index ci
INNER JOIN senna_study.potassium_labs pl
    ON ci.hadm_id = pl.hadm_id
   AND pl.charttime > (ci.index_time + INTERVAL '48 hour')
   AND pl.charttime <= (ci.index_time + INTERVAL '72 hour')
   AND pl.potassium < 3.5
WHERE ci.hadm_id NOT IN (SELECT hadm_id FROM senna_study.exclude_pre_low)
ORDER BY ci.hadm_id, pl.charttime ASC;

-- ============================================================
-- 模块9：时间依赖视角描述性分析
-- 统计：低钾前已使用番泻叶 vs 低钾后才首次使用番泻叶
-- ============================================================
DROP TABLE IF EXISTS senna_study.temporal_direction CASCADE;

CREATE TABLE senna_study.temporal_direction AS
SELECT
    ci.subject_id,
    ci.hadm_id,
    ci.senna_exposed,
    ci.index_time,
    pil.event_time AS low_k_time,
    CASE
        -- 暴露组：低钾事件发生在首次番泻叶之后 → 前向
        WHEN ci.senna_exposed = 1 AND pil.event_time IS NOT NULL
             AND pil.event_time > ci.index_time THEN 'forward'
        -- 暴露组：低钾事件在index_time之前（被排除者，但保留标记）
        WHEN ci.senna_exposed = 1 AND pil.event_time IS NOT NULL
             AND pil.event_time <= ci.index_time THEN 'reverse_possible'
        -- 暴露组：无低钾事件
        WHEN ci.senna_exposed = 1 AND pil.event_time IS NULL THEN 'no_event'
        -- 非暴露组
        ELSE 'unexposed'
    END AS temporal_category
FROM senna_study.cohort_index ci
LEFT JOIN senna_study.post_index_low pil
    ON ci.hadm_id = pil.hadm_id
WHERE ci.hadm_id NOT IN (SELECT hadm_id FROM senna_study.exclude_pre_low);

-- ============================================================
-- 模块10：最终分析集 — 合并所有变量
-- 排除：index前已有低钾、index后无血钾检测
-- ============================================================
DROP TABLE IF EXISTS senna_study.analysis_final CASCADE;

CREATE TABLE senna_study.analysis_final AS
SELECT
    ci.subject_id,
    ci.hadm_id,
    -- 人口学
    ci.gender,
    ci.age,
    ci.age_group,
    -- 暴露
    ci.senna_exposed,
    ci.index_time,
    ci.alignment_type,
    ci.senna_order_count,
    ci.first_dose,
    ci.first_dose_unit,
    -- 基线实验室
    bk.baseline_k,
    bk.baseline_k_charttime,
    -- 主要结局
    CASE WHEN pil.event_time IS NOT NULL THEN 1 ELSE 0 END AS hypokalemia_event,
    pil.event_time AS hypokalemia_time,
    pil.event_k_value AS hypokalemia_k_value,
    -- 48-72h限定窗结局
    CASE WHEN w72.window_event_time IS NOT NULL THEN 1 ELSE 0 END AS hypokalemia_48_72h,
    w72.window_event_time,
    -- 随访时间（从index_time到事件/出院/死亡）
    EXTRACT(EPOCH FROM (
        COALESCE(pil.event_time, ci.dischtime, ci.deathtime)
        - ci.index_time
    )) / 3600.0 AS followup_hours,
    -- 住院信息
    ci.admittime,
    ci.dischtime,
    ci.deathtime,
    ci.hospital_expire_flag,
    -- 时间方向分类
    td.temporal_category
FROM senna_study.cohort_index ci
-- 排除index前已有低钾
INNER JOIN senna_study.baseline_k bk
    ON ci.hadm_id = bk.hadm_id
LEFT JOIN senna_study.post_index_low pil
    ON ci.hadm_id = pil.hadm_id
LEFT JOIN senna_study.window_48_72 w72
    ON ci.hadm_id = w72.hadm_id
LEFT JOIN senna_study.temporal_direction td
    ON ci.hadm_id = td.hadm_id
WHERE ci.hadm_id NOT IN (SELECT hadm_id FROM senna_study.exclude_pre_low)
    -- 必须有基线血钾
    AND bk.baseline_k IS NOT NULL
    -- 排除index后无任何血钾检测者
    AND EXISTS (
        SELECT 1 FROM senna_study.potassium_labs pl2
        WHERE pl2.hadm_id = ci.hadm_id
          AND pl2.charttime > ci.index_time
    );

-- ============================================================
-- 模块11：快速验证
-- ============================================================

-- 11.1 队列规模
SELECT
    COUNT(*) AS total_n,
    SUM(senna_exposed) AS exposed_n,
    SUM(CASE WHEN senna_exposed = 0 THEN 1 ELSE 0 END) AS unexposed_n
FROM senna_study.analysis_final;

-- 11.2 主要结局发生率
SELECT
    senna_exposed,
    COUNT(*) AS n,
    SUM(hypokalemia_event) AS events,
    ROUND(100.0 * SUM(hypokalemia_event) / COUNT(*), 2) AS event_rate_pct
FROM senna_study.analysis_final
GROUP BY senna_exposed;

-- 11.3 48-72h限定窗结局
SELECT
    senna_exposed,
    COUNT(*) AS n,
    SUM(hypokalemia_48_72h) AS events_48_72h,
    ROUND(100.0 * SUM(hypokalemia_48_72h) / COUNT(*), 2) AS event_rate_pct
FROM senna_study.analysis_final
GROUP BY senna_exposed;

-- 11.4 时间方向分类分布
SELECT
    temporal_category,
    COUNT(*) AS n
FROM senna_study.analysis_final
GROUP BY temporal_category
ORDER BY n DESC;

-- 11.5 指数时间分布（暴露组）
SELECT
    ROUND(AVG(EXTRACT(EPOCH FROM (index_time - admittime)) / 86400.0), 2) AS mean_days_to_senna,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (index_time - admittime)) / 86400.0) AS p25_days,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (index_time - admittime)) / 86400.0) AS median_days,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (index_time - admittime)) / 86400.0) AS p75_days
FROM senna_study.analysis_final
WHERE senna_exposed = 1;

-- ============================================================
-- 模块12：合并症（CHF、CKD、DM）— 基于diagnoses_icd
-- ICD-9 和 ICD-10 编码需分别处理
-- ============================================================
DROP TABLE IF EXISTS senna_study.comorbidities CASCADE;

CREATE TABLE senna_study.comorbidities AS
SELECT
    subject_id,
    hadm_id,
    -- 心力衰竭
    MAX(CASE
        WHEN (icd_version = 9 AND icd_code LIKE '428%')
          OR (icd_version = 10 AND icd_code LIKE 'I50%')
        THEN 1 ELSE 0 END) AS chf,
    -- 慢性肾病
    MAX(CASE
        WHEN (icd_version = 9 AND icd_code LIKE '585%')
          OR (icd_version = 10 AND icd_code LIKE 'N18%')
        THEN 1 ELSE 0 END) AS ckd,
    -- 糖尿病
    MAX(CASE
        WHEN (icd_version = 9 AND icd_code LIKE '250%')
          OR (icd_version = 10 AND (icd_code LIKE 'E10%' OR icd_code LIKE 'E11%'
              OR icd_code LIKE 'E12%' OR icd_code LIKE 'E13%' OR icd_code LIKE 'E14%'))
        THEN 1 ELSE 0 END) AS dm
FROM mimiciv_hosp.diagnoses_icd
WHERE icd_code IS NOT NULL
GROUP BY subject_id, hadm_id;

-- ============================================================
-- 模块13：合并用药 — 基于prescriptions表
-- 利尿剂、ACEI/ARB、地高辛、胰岛素、他汀类、抗凝药
-- ============================================================
DROP TABLE IF EXISTS senna_study.medications CASCADE;

CREATE TABLE senna_study.medications AS
SELECT
    subject_id,
    hadm_id,
    -- 利尿剂
    MAX(CASE WHEN LOWER(drug) LIKE '%furosemide%'
              OR LOWER(drug) LIKE '%bumetanide%'
              OR LOWER(drug) LIKE '%torsemide%'
              OR LOWER(drug) LIKE '%hydrochlorothiazide%'
              OR LOWER(drug) LIKE '%metolazone%'
              OR LOWER(drug) LIKE '%spironolactone%'
              OR LOWER(drug) LIKE '%eplerenone%'
         THEN 1 ELSE 0 END) AS diuretic,
    -- ACEI/ARB
    MAX(CASE WHEN LOWER(drug) LIKE '%lisinopril%'
              OR LOWER(drug) LIKE '%enalapril%'
              OR LOWER(drug) LIKE '%ramipril%'
              OR LOWER(drug) LIKE '%losartan%'
              OR LOWER(drug) LIKE '%valsartan%'
              OR LOWER(drug) LIKE '%candesartan%'
              OR LOWER(drug) LIKE '%irbesartan%'
         THEN 1 ELSE 0 END) AS acei_arb,
    -- 地高辛
    MAX(CASE WHEN LOWER(drug) LIKE '%digoxin%' THEN 1 ELSE 0 END) AS digoxin,
    -- 胰岛素
    MAX(CASE WHEN LOWER(drug) LIKE '%insulin%' THEN 1 ELSE 0 END) AS insulin,
    -- 他汀类
    MAX(CASE WHEN LOWER(drug) LIKE '%atorvastatin%'
              OR LOWER(drug) LIKE '%simvastatin%'
              OR LOWER(drug) LIKE '%rosuvastatin%'
              OR LOWER(drug) LIKE '%pravastatin%'
              OR LOWER(drug) LIKE '%lovastatin%'
         THEN 1 ELSE 0 END) AS statin,
    -- 抗凝药
    MAX(CASE WHEN LOWER(drug) LIKE '%heparin%'
              OR LOWER(drug) LIKE '%enoxaparin%'
              OR LOWER(drug) LIKE '%warfarin%'
              OR LOWER(drug) LIKE '%apixaban%'
              OR LOWER(drug) LIKE '%rivaroxaban%'
         THEN 1 ELSE 0 END) AS anticoagulant,
    -- 合并用药总数（唯一药物计数）
    COUNT(DISTINCT LOWER(drug)) AS drug_count
FROM mimiciv_hosp.prescriptions
WHERE drug IS NOT NULL
GROUP BY subject_id, hadm_id;

-- ============================================================
-- 模块14：最终分析宽表 — 合并所有协变量
-- ============================================================
DROP TABLE IF EXISTS senna_study.analysis_wide CASCADE;

CREATE TABLE senna_study.analysis_wide AS
SELECT
    af.*,
    cm.chf,
    cm.ckd,
    cm.dm,
    med.diuretic,
    med.acei_arb,
    med.digoxin,
    med.insulin,
    med.statin,
    med.anticoagulant,
    med.drug_count,
    -- 多重用药标志（≥5种）
    CASE WHEN med.drug_count >= 5 THEN 1 ELSE 0 END AS polypharmacy
FROM senna_study.analysis_final af
LEFT JOIN senna_study.comorbidities cm
    ON af.subject_id = cm.subject_id AND af.hadm_id = cm.hadm_id
LEFT JOIN senna_study.medications med
    ON af.subject_id = med.subject_id AND af.hadm_id = med.hadm_id;

-- ============================================================
-- 模块15：导出最终分析集
-- ============================================================

-- 15.1 最终队列规模与结局汇总
SELECT
    '总队列' AS 指标, COUNT(*)::text AS 值 FROM senna_study.analysis_wide
UNION ALL
SELECT '番泻叶暴露组', COUNT(*)::text FROM senna_study.analysis_wide WHERE senna_exposed = 1
UNION ALL
SELECT '非暴露组', COUNT(*)::text FROM senna_study.analysis_wide WHERE senna_exposed = 0
UNION ALL
SELECT '主要结局事件数', SUM(hypokalemia_event)::text FROM senna_study.analysis_wide
UNION ALL
SELECT '48-72h窗事件数', SUM(hypokalemia_48_72h)::text FROM senna_study.analysis_wide
UNION ALL
SELECT '前向暴露(低钾前用药)', COUNT(*)::text FROM senna_study.analysis_wide
    WHERE temporal_category = 'forward'
UNION ALL
SELECT '反向可能(低钾后用药)', COUNT(*)::text FROM senna_study.analysis_wide
    WHERE temporal_category = 'reverse_possible';

-- 15.2 导出CSV（在psql中执行）
-- \copy (SELECT * FROM senna_study.analysis_wide) TO '/path/to/senna_analysis.csv' WITH CSV HEADER;

-- ============================================================
-- 补充：时间依赖Cox的长格式数据
-- 每位患者按暴露状态转换分为1-2行
-- ============================================================
DROP TABLE IF EXISTS senna_study.surv_long CASCADE;

CREATE TABLE senna_study.surv_long AS
-- 第一段：从index_time到首次番泻叶（仅暴露组）
SELECT
    aw.subject_id, aw.hadm_id,
    aw.index_time AS t_start,
    COALESCE(se.index_time, aw.dischtime) AS t_stop,
    0 AS senna_status,
    aw.hypokalemia_event, aw.hypokalemia_time,
    aw.baseline_k, aw.diuretic, aw.chf, aw.age, aw.gender
FROM senna_study.analysis_wide aw
LEFT JOIN senna_study.senna_exposure se
    ON aw.hadm_id = se.hadm_id
WHERE aw.senna_exposed = 1

UNION ALL

-- 第二段：从首次番泻叶到事件/出院（暴露组）
SELECT
    aw.subject_id, aw.hadm_id,
    se.index_time AS t_start,
    COALESCE(aw.hypokalemia_time, aw.dischtime, aw.deathtime) AS t_stop,
    1 AS senna_status,
    aw.hypokalemia_event, aw.hypokalemia_time,
    aw.baseline_k, aw.diuretic, aw.chf, aw.age, aw.gender
FROM senna_study.analysis_wide aw
INNER JOIN senna_study.senna_exposure se
    ON aw.hadm_id = se.hadm_id
WHERE aw.senna_exposed = 1

UNION ALL

-- 非暴露组：单行，从index_time到事件/出院
SELECT
    aw.subject_id, aw.hadm_id,
    aw.index_time AS t_start,
    COALESCE(aw.hypokalemia_time, aw.dischtime, aw.deathtime) AS t_stop,
    0 AS senna_status,
    aw.hypokalemia_event, aw.hypokalemia_time,
    aw.baseline_k, aw.diuretic, aw.chf, aw.age, aw.gender
FROM senna_study.analysis_wide aw
WHERE aw.senna_exposed = 0;

检查重复患者
-- 检查是否有同一个 hadm_id 出现多次
SELECT 
    hadm_id, 
    COUNT(*) AS 重复次数
FROM senna_study.analysis_wide
GROUP BY hadm_id
HAVING COUNT(*) > 1
ORDER BY 重复次数 DESC;

-- 统计同一患者多次住院的情况
SELECT 
    subject_id, 
    COUNT(DISTINCT hadm_id) AS 住院次数,
    STRING_AGG(hadm_id::text, ', ' ORDER BY admittime) AS 住院号列表
FROM senna_study.analysis_wide
GROUP BY subject_id
HAVING COUNT(DISTINCT hadm_id) > 1
ORDER BY 住院次数 DESC;

SELECT 
    COUNT(DISTINCT subject_id) AS 总患者数,
    COUNT(hadm_id) AS 总住院次,
    COUNT(hadm_id) - COUNT(DISTINCT subject_id) AS 重复住院次,
    COUNT(DISTINCT CASE WHEN 住院次数 > 1 THEN subject_id END) AS 多次住院患者数
FROM (
    SELECT subject_id, hadm_id, COUNT(*) OVER (PARTITION BY subject_id) AS 住院次数
    FROM senna_study.analysis_wide
) t;

-- 仅保留每位患者的首次住院
DROP TABLE IF EXISTS senna_study.analysis_wide_first CASCADE;
CREATE TABLE senna_study.analysis_wide_first AS
SELECT DISTINCT ON (subject_id) *
FROM senna_study.analysis_wide
ORDER BY subject_id, admittime ASC;

-- 检查关键变量的缺失情况
SELECT 
    COUNT(*) AS 总行数,
    COUNT(baseline_k) AS 基线血钾_有记录,
    ROUND(100.0 * (COUNT(*) - COUNT(baseline_k)) / COUNT(*), 2) AS 基线血钾_缺失率_pct,
    COUNT(baseline_egfr) AS eGFR_有记录,
    ROUND(100.0 * (COUNT(*) - COUNT(baseline_egfr)) / COUNT(*), 2) AS eGFR_缺失率_pct,
    COUNT(chf) AS CHF_有记录,
    COUNT(diuretic) AS 利尿剂_有记录,
    COUNT(drug_count) AS 合并用药数_有记录
FROM senna_study.analysis_wide;

-- 连续变量分布
SELECT
    '年龄' AS 变量, COUNT(*) AS n, ROUND(AVG(age)::numeric, 1) AS 均值,
    ROUND(MIN(age)::numeric, 1) AS 最小值, ROUND(MAX(age)::numeric, 1) AS 最大值,
    ROUND(STDDEV(age)::numeric, 1) AS 标准差
FROM senna_study.analysis_wide
UNION ALL
SELECT
    '基线血钾', COUNT(baseline_k), ROUND(AVG(baseline_k)::numeric, 2),
    ROUND(MIN(baseline_k)::numeric, 2), ROUND(MAX(baseline_k)::numeric, 2),
    ROUND(STDDEV(baseline_k)::numeric, 2)
FROM senna_study.analysis_wide
UNION ALL
SELECT
    'eGFR', COUNT(baseline_egfr), ROUND(AVG(baseline_egfr)::numeric, 1),
    ROUND(MIN(baseline_egfr)::numeric, 1), ROUND(MAX(baseline_egfr)::numeric, 1),
    ROUND(STDDEV(baseline_egfr)::numeric, 1)
FROM senna_study.analysis_wide;

-- 分类变量分布
SELECT '性别' AS 变量, gender AS 分类, COUNT(*) AS 例数
FROM senna_study.analysis_wide GROUP BY gender
UNION ALL
SELECT '暴露组', senna_exposed::text, COUNT(*)
FROM senna_study.analysis_wide GROUP BY senna_exposed
UNION ALL
SELECT '低钾结局', hypokalemia_event::text, COUNT(*)
FROM senna_study.analysis_wide GROUP BY hypokalemia_event
UNION ALL
SELECT '心力衰竭', chf::text, COUNT(*)
FROM senna_study.analysis_wide GROUP BY chf
UNION ALL
SELECT '慢性肾病', ckd::text, COUNT(*)
FROM senna_study.analysis_wide GROUP BY ckd
ORDER BY 变量, 分类;

SELECT 
    column_name AS 列名, 
    data_type AS 数据类型, 
    is_nullable AS 是否可空
FROM information_schema.columns
WHERE table_schema = 'senna_study' 
  AND table_name = 'analysis_wide'
ORDER BY ordinal_position;

缺失数据处理（插补成0）
SELECT
    COUNT(*) AS 总行数,
    -- NULL 缺失
    SUM(CASE WHEN senna_exposed IS NULL THEN 1 ELSE 0 END) AS 暴露_NULL,
    SUM(CASE WHEN hypokalemia_event IS NULL THEN 1 ELSE 0 END) AS 结局_NULL,
    SUM(CASE WHEN baseline_k IS NULL THEN 1 ELSE 0 END) AS 基线血钾_NULL,
    SUM(CASE WHEN baseline_egfr IS NULL THEN 1 ELSE 0 END) AS eGFR_NULL,
    SUM(CASE WHEN chf IS NULL THEN 1 ELSE 0 END) AS CHF_NULL,
    SUM(CASE WHEN diuretic IS NULL THEN 1 ELSE 0 END) AS 利尿剂_NULL,
    -- 空字符串缺失（针对文本型变量）
    SUM(CASE WHEN gender = '' THEN 1 ELSE 0 END) AS 性别_空字符串
FROM senna_study.analysis_wide_first;   -- 改成你的表名

SELECT
    ROUND(100.0 * SUM(CASE WHEN baseline_k IS NULL THEN 1 ELSE 0 END) / COUNT(*), 2) AS 基线血钾_缺失率_pct,
    ROUND(100.0 * SUM(CASE WHEN baseline_egfr IS NULL THEN 1 ELSE 0 END) / COUNT(*), 2) AS eGFR_缺失率_pct,
    ROUND(100.0 * SUM(CASE WHEN chf IS NULL THEN 1 ELSE 0 END) / COUNT(*), 2) AS CHF_缺失率_pct,
    ROUND(100.0 * SUM(CASE WHEN diuretic IS NULL THEN 1 ELSE 0 END) / COUNT(*), 2) AS 利尿剂_缺失率_pct
FROM senna_study.analysis_wide_first;

UPDATE senna_study.analysis_wide_first
SET chf = COALESCE(chf, 0),
    ckd = COALESCE(ckd, 0),
    dm = COALESCE(dm, 0),
    diuretic = COALESCE(diuretic, 0),
    acei_arb = COALESCE(acei_arb, 0),
    digoxin = COALESCE(digoxin, 0),
    insulin = COALESCE(insulin, 0),
    statin = COALESCE(statin, 0),
    anticoagulant = COALESCE(anticoagulant, 0)
WHERE chf IS NULL OR ckd IS NULL OR dm IS NULL
   OR diuretic IS NULL OR acei_arb IS NULL OR digoxin IS NULL
   OR insulin IS NULL OR statin IS NULL OR anticoagulant IS NULL;

SELECT
    SUM(CASE WHEN chf IS NULL THEN 1 ELSE 0 END) AS CHF_剩余NULL,
    SUM(CASE WHEN diuretic IS NULL THEN 1 ELSE 0 END) AS 利尿剂_剩余NULL,
    SUM(CASE WHEN baseline_k IS NULL THEN 1 ELSE 0 END) AS 血钾_剩余NULL,
    SUM(CASE WHEN hypokalemia_event IS NULL THEN 1 ELSE 0 END) AS 结局_剩余NULL
FROM senna_study.analysis_wide_first;

删除合并用药数缺失的患者（51例）
SELECT * FROM senna_study.analysis_wide_first
WHERE drug_count IS NULL;
DELETE FROM senna_study.analysis_wide_first
WHERE drug_count IS NULL;

最后检查，患者是否重复，协变量是否有缺失
SELECT
    COUNT(*) AS 总行数,
    COUNT(DISTINCT subject_id) AS 唯一患者数,
    COUNT(DISTINCT hadm_id) AS 唯一住院数
FROM senna_study.analysis_wide_first;

-- 检查重复患者
SELECT subject_id, COUNT(*) AS 出现次数
FROM senna_study.analysis_wide_first
GROUP BY subject_id
HAVING COUNT(*) > 1
ORDER BY 出现次数 DESC;

-- 检查重复住院号
SELECT hadm_id, COUNT(*) AS 出现次数
FROM senna_study.analysis_wide_first
GROUP BY hadm_id
HAVING COUNT(*) > 1
ORDER BY 出现次数 DESC;

SELECT
    COUNT(*) AS 总行数,
    SUM(CASE WHEN senna_exposed IS NULL THEN 1 ELSE 0 END) AS 暴露缺失,
    SUM(CASE WHEN hypokalemia_event IS NULL THEN 1 ELSE 0 END) AS 结局缺失,
    SUM(CASE WHEN age IS NULL THEN 1 ELSE 0 END) AS 年龄缺失,
    SUM(CASE WHEN gender IS NULL OR gender = '' THEN 1 ELSE 0 END) AS 性别缺失,
    SUM(CASE WHEN baseline_k IS NULL THEN 1 ELSE 0 END) AS 基线血钾缺失,
    SUM(CASE WHEN baseline_egfr IS NULL THEN 1 ELSE 0 END) AS eGFR缺失,
    SUM(CASE WHEN chf IS NULL THEN 1 ELSE 0 END) AS CHF缺失,
    SUM(CASE WHEN ckd IS NULL THEN 1 ELSE 0 END) AS CKD缺失,
    SUM(CASE WHEN dm IS NULL THEN 1 ELSE 0 END) AS DM缺失,
    SUM(CASE WHEN diuretic IS NULL THEN 1 ELSE 0 END) AS 利尿剂缺失,
    SUM(CASE WHEN acei_arb IS NULL THEN 1 ELSE 0 END) AS ACEI_ARB缺失,
    SUM(CASE WHEN digoxin IS NULL THEN 1 ELSE 0 END) AS 地高辛缺失,
    SUM(CASE WHEN insulin IS NULL THEN 1 ELSE 0 END) AS 胰岛素缺失,
    SUM(CASE WHEN statin IS NULL THEN 1 ELSE 0 END) AS 他汀缺失,
    SUM(CASE WHEN anticoagulant IS NULL THEN 1 ELSE 0 END) AS 抗凝缺失,
    SUM(CASE WHEN drug_count IS NULL THEN 1 ELSE 0 END) AS 合并用药数缺失,
    SUM(CASE WHEN polypharmacy IS NULL THEN 1 ELSE 0 END) AS 多重用药缺失
FROM senna_study.analysis_wide_first;

继续添加协变量
-- 创建肌酐检验表
DROP TABLE IF EXISTS senna_study.creatinine_labs CASCADE;
CREATE TABLE senna_study.creatinine_labs AS
SELECT
    le.subject_id,
    le.hadm_id,
    le.charttime,
    le.valuenum AS creatinine
FROM mimiciv_hosp.labevents le
WHERE le.itemid = 50912
  AND le.valuenum IS NOT NULL
  AND le.valuenum > 0
  AND le.valuenum < 50;

-- 计算 eGFR（需要年龄、性别，从分析表取）
DROP TABLE IF EXISTS senna_study.egfr_calculated CASCADE;
CREATE TABLE senna_study.egfr_calculated AS
SELECT
    cl.subject_id,
    cl.hadm_id,
    cl.charttime,
    cl.creatinine,
    aw.age,
    aw.gender,
    -- 注意这里：在 CASE WHEN 表达式外部加了 ::numeric
    ROUND(
        (
            CASE
                WHEN aw.gender = 'F' THEN
                    142 * POWER(LEAST(cl.creatinine / 0.7, 1), -0.241)
                        * POWER(GREATEST(cl.creatinine / 0.7, 1), -1.200)
                        * POWER(0.9938, aw.age) * 1.012
                WHEN aw.gender = 'M' THEN
                    142 * POWER(LEAST(cl.creatinine / 0.9, 1), -0.302)
                        * POWER(GREATEST(cl.creatinine / 0.9, 1), -1.200)
                        * POWER(0.9938, aw.age)
                ELSE NULL
            END
        )::numeric, 2
    ) AS egfr
FROM senna_study.creatinine_labs cl
INNER JOIN senna_study.analysis_wide_first aw
    ON cl.hadm_id = aw.hadm_id;

-- 取基线 eGFR
DROP TABLE IF EXISTS senna_study.baseline_egfr CASCADE;
CREATE TABLE senna_study.baseline_egfr AS
SELECT DISTINCT ON (aw.hadm_id)
    aw.hadm_id,
    ec.charttime AS baseline_egfr_charttime,
    ec.egfr AS baseline_egfr,
    ec.creatinine AS baseline_creatinine
FROM senna_study.analysis_wide_first aw
INNER JOIN senna_study.egfr_calculated ec
    ON aw.hadm_id = ec.hadm_id
   AND ec.charttime <= aw.index_time
ORDER BY aw.hadm_id, ec.charttime DESC;

-- 添加列并更新
ALTER TABLE senna_study.analysis_wide_first
ADD COLUMN IF NOT EXISTS baseline_egfr NUMERIC,
ADD COLUMN IF NOT EXISTS baseline_egfr_charttime TIMESTAMP,
ADD COLUMN IF NOT EXISTS baseline_creatinine NUMERIC;

UPDATE senna_study.analysis_wide_first aw
SET baseline_egfr = be.baseline_egfr,
    baseline_egfr_charttime = be.baseline_egfr_charttime,
    baseline_creatinine = be.baseline_creatinine
FROM senna_study.baseline_egfr be
WHERE aw.hadm_id = be.hadm_id;

-- 创建其他泻药标志
DROP TABLE IF EXISTS senna_study.other_laxatives CASCADE;
CREATE TABLE senna_study.other_laxatives AS
SELECT
    subject_id,
    hadm_id,
    MAX(CASE WHEN LOWER(drug) LIKE '%lactulose%' THEN 1 ELSE 0 END) AS lactulose,
    MAX(CASE WHEN LOWER(drug) LIKE '%polyethylene glycol%' OR LOWER(drug) LIKE '%peg%' THEN 1 ELSE 0 END) AS peg,
    MAX(CASE WHEN LOWER(drug) LIKE '%bisacodyl%' THEN 1 ELSE 0 END) AS bisacodyl,
    MAX(CASE WHEN LOWER(drug) LIKE '%docusate%' THEN 1 ELSE 0 END) AS docusate,
    MAX(CASE WHEN LOWER(drug) LIKE '%lactulose%'
              OR LOWER(drug) LIKE '%polyethylene glycol%'
              OR LOWER(drug) LIKE '%peg%'
              OR LOWER(drug) LIKE '%bisacodyl%'
              OR LOWER(drug) LIKE '%docusate%'
         THEN 1 ELSE 0 END) AS any_other_laxative
FROM mimiciv_hosp.prescriptions
WHERE drug IS NOT NULL
GROUP BY subject_id, hadm_id;

-- 合并到分析表
ALTER TABLE senna_study.analysis_wide_first
ADD COLUMN IF NOT EXISTS lactulose INT,
ADD COLUMN IF NOT EXISTS peg INT,
ADD COLUMN IF NOT EXISTS bisacodyl INT,
ADD COLUMN IF NOT EXISTS docusate INT,
ADD COLUMN IF NOT EXISTS any_other_laxative INT;

UPDATE senna_study.analysis_wide_first aw
SET lactulose = ol.lactulose,
    peg = ol.peg,
    bisacodyl = ol.bisacodyl,
    docusate = ol.docusate,
    any_other_laxative = ol.any_other_laxative
FROM senna_study.other_laxatives ol
WHERE aw.hadm_id = ol.hadm_id;

-- 没有记录视为未使用，填0
UPDATE senna_study.analysis_wide_first
SET lactulose = COALESCE(lactulose, 0),
    peg = COALESCE(peg, 0),
    bisacodyl = COALESCE(bisacodyl, 0),
    docusate = COALESCE(docusate, 0),
    any_other_laxative = COALESCE(any_other_laxative, 0);

DROP TABLE IF EXISTS senna_study.potassium_supplement CASCADE;
CREATE TABLE senna_study.potassium_supplement AS
SELECT
    subject_id,
    hadm_id,
    MAX(CASE WHEN LOWER(drug) LIKE '%potassium%'
              OR LOWER(drug) LIKE '%kcl%'
              OR LOWER(drug) LIKE '%klor%'
         THEN 1 ELSE 0 END) AS potassium_supplement
FROM mimiciv_hosp.prescriptions
WHERE drug IS NOT NULL
GROUP BY subject_id, hadm_id;

ALTER TABLE senna_study.analysis_wide_first
ADD COLUMN IF NOT EXISTS potassium_supplement INT;

UPDATE senna_study.analysis_wide_first aw
SET potassium_supplement = ps.potassium_supplement
FROM senna_study.potassium_supplement ps
WHERE aw.hadm_id = ps.hadm_id;

UPDATE senna_study.analysis_wide_first
SET potassium_supplement = COALESCE(potassium_supplement, 0);

DROP TABLE IF EXISTS senna_study.ppi CASCADE;
CREATE TABLE senna_study.ppi AS
SELECT
    subject_id,
    hadm_id,
    MAX(CASE WHEN LOWER(drug) LIKE '%omeprazole%'
              OR LOWER(drug) LIKE '%pantoprazole%'
              OR LOWER(drug) LIKE '%esomeprazole%'
              OR LOWER(drug) LIKE '%lansoprazole%'
              OR LOWER(drug) LIKE '%rabeprazole%'
         THEN 1 ELSE 0 END) AS ppi
FROM mimiciv_hosp.prescriptions
WHERE drug IS NOT NULL
GROUP BY subject_id, hadm_id;

ALTER TABLE senna_study.analysis_wide_first
ADD COLUMN IF NOT EXISTS ppi INT;

UPDATE senna_study.analysis_wide_first aw
SET ppi = p.ppi
FROM senna_study.ppi p
WHERE aw.hadm_id = p.hadm_id;

UPDATE senna_study.analysis_wide_first
SET ppi = COALESCE(ppi, 0);

DROP TABLE IF EXISTS senna_study.other_k_drugs CASCADE;
CREATE TABLE senna_study.other_k_drugs AS
SELECT
    subject_id,
    hadm_id,
    MAX(CASE WHEN LOWER(drug) LIKE '%albuterol%'
              OR LOWER(drug) LIKE '%salbutamol%'
              OR LOWER(drug) LIKE '%levalbuterol%'
              OR LOWER(drug) LIKE '%formoterol%'
         THEN 1 ELSE 0 END) AS beta2_agonist,
    MAX(CASE WHEN LOWER(drug) LIKE '%prednisone%'
              OR LOWER(drug) LIKE '%prednisolone%'
              OR LOWER(drug) LIKE '%methylprednisolone%'
              OR LOWER(drug) LIKE '%dexamethasone%'
              OR LOWER(drug) LIKE '%hydrocortisone%'
         THEN 1 ELSE 0 END) AS corticosteroid,
    MAX(CASE WHEN LOWER(drug) LIKE '%amphotericin%' THEN 1 ELSE 0 END) AS amphotericin_b
FROM mimiciv_hosp.prescriptions
WHERE drug IS NOT NULL
GROUP BY subject_id, hadm_id;

ALTER TABLE senna_study.analysis_wide_first
ADD COLUMN IF NOT EXISTS beta2_agonist INT,
ADD COLUMN IF NOT EXISTS corticosteroid INT,
ADD COLUMN IF NOT EXISTS amphotericin_b INT;

UPDATE senna_study.analysis_wide_first aw
SET beta2_agonist = okd.beta2_agonist,
    corticosteroid = okd.corticosteroid,
    amphotericin_b = okd.amphotericin_b
FROM senna_study.other_k_drugs okd
WHERE aw.hadm_id = okd.hadm_id;

UPDATE senna_study.analysis_wide_first
SET beta2_agonist = COALESCE(beta2_agonist, 0),
    corticosteroid = COALESCE(corticosteroid, 0),
    amphotericin_b = COALESCE(amphotericin_b, 0);

DROP TABLE IF EXISTS senna_study.diarrhea_vomiting CASCADE;
CREATE TABLE senna_study.diarrhea_vomiting AS
SELECT
    subject_id,
    hadm_id,
    MAX(CASE WHEN icd_code LIKE '787.91%' OR icd_code LIKE 'R19.7%'  -- 腹泻
              OR icd_code LIKE '787.03%' OR icd_code LIKE 'R11%'    -- 呕吐
         THEN 1 ELSE 0 END) AS diarrhea_vomiting
FROM mimiciv_hosp.diagnoses_icd
WHERE icd_code IS NOT NULL
GROUP BY subject_id, hadm_id;

ALTER TABLE senna_study.analysis_wide_first
ADD COLUMN IF NOT EXISTS diarrhea_vomiting INT;

UPDATE senna_study.analysis_wide_first aw
SET diarrhea_vomiting = dv.diarrhea_vomiting
FROM senna_study.diarrhea_vomiting dv
WHERE aw.hadm_id = dv.hadm_id;

UPDATE senna_study.analysis_wide_first
SET diarrhea_vomiting = COALESCE(diarrhea_vomiting, 0);

DROP TABLE IF EXISTS senna_study.senna_dose CASCADE;
CREATE TABLE senna_study.senna_dose AS
SELECT
    subject_id,
    hadm_id,
    -- 累积剂量（假设剂量单位一致，若不一致需先转换）
    SUM(CASE WHEN dose_val_rx ~ '^[0-9]+\.?[0-9]*$'
             THEN dose_val_rx::NUMERIC ELSE 0 END) AS senna_total_dose,
    -- 用药天数（首末次时间差）
    EXTRACT(EPOCH FROM (MAX(starttime) - MIN(starttime))) / 86400.0 AS senna_days,
    -- 给药次数
    COUNT(*) AS senna_order_count,
    -- 首次用药时间（已作为index_time，这里再次确认）
    MIN(starttime) AS senna_first_time
FROM mimiciv_hosp.prescriptions
WHERE (LOWER(drug) LIKE '%senna%'
    OR LOWER(drug) LIKE '%sennoside%'
    OR LOWER(drug) LIKE '%senokot%')
  AND drug_type = 'MAIN'
  AND starttime IS NOT NULL
GROUP BY subject_id, hadm_id;

ALTER TABLE senna_study.analysis_wide_first
ADD COLUMN IF NOT EXISTS senna_total_dose NUMERIC,
ADD COLUMN IF NOT EXISTS senna_days NUMERIC,
ADD COLUMN IF NOT EXISTS senna_order_count INT;

UPDATE senna_study.analysis_wide_first aw
SET senna_total_dose = sd.senna_total_dose,
    senna_days = sd.senna_days,
    senna_order_count = sd.senna_order_count
FROM senna_study.senna_dose sd
WHERE aw.hadm_id = sd.hadm_id;

-- 非暴露组这些变量应为0
UPDATE senna_study.analysis_wide_first
SET senna_total_dose = COALESCE(senna_total_dose, 0),
    senna_days = COALESCE(senna_days, 0),
    senna_order_count = COALESCE(senna_order_count, 0)
WHERE senna_exposed = 0;

再次检查缺失
SELECT
    COUNT(*) AS 总行数,
    SUM(CASE WHEN baseline_egfr IS NULL THEN 1 ELSE 0 END) AS eGFR缺失,
    SUM(CASE WHEN any_other_laxative IS NULL THEN 1 ELSE 0 END) AS 其他泻药缺失,
    SUM(CASE WHEN potassium_supplement IS NULL THEN 1 ELSE 0 END) AS 补钾缺失,
    SUM(CASE WHEN ppi IS NULL THEN 1 ELSE 0 END) AS PPI缺失,
    SUM(CASE WHEN beta2_agonist IS NULL THEN 1 ELSE 0 END) AS β2激动剂缺失,
    SUM(CASE WHEN corticosteroid IS NULL THEN 1 ELSE 0 END) AS 激素缺失,
    SUM(CASE WHEN diarrhea_vomiting IS NULL THEN 1 ELSE 0 END) AS 腹泻呕吐缺失,
    SUM(CASE WHEN senna_total_dose IS NULL THEN 1 ELSE 0 END) AS 番泻叶累积剂量缺失
FROM senna_study.analysis_wide_first;

解决egfr缺失（597）
DELETE FROM senna_study.analysis_wide_first
WHERE baseline_egfr IS NULL;
SELECT
    SUM(CASE WHEN any_other_laxative IS NULL THEN 1 ELSE 0 END) AS 其他泻药缺失,
    SUM(CASE WHEN potassium_supplement IS NULL THEN 1 ELSE 0 END) AS 补钾缺失,
    SUM(CASE WHEN ppi IS NULL THEN 1 ELSE 0 END) AS PPI缺失,
    SUM(CASE WHEN diarrhea_vomiting IS NULL THEN 1 ELSE 0 END) AS 腹泻呕吐缺失
FROM senna_study.analysis_wide_first;

UPDATE senna_study.analysis_wide_first
SET any_other_laxative = COALESCE(any_other_laxative, 0),
    potassium_supplement = COALESCE(potassium_supplement, 0),
    ppi = COALESCE(ppi, 0),
    diarrhea_vomiting = COALESCE(diarrhea_vomiting, 0);

SELECT
    COUNT(*) AS 最终总行数,
    COUNT(DISTINCT hadm_id) AS 唯一住院数,
    SUM(CASE WHEN senna_exposed IS NULL THEN 1 ELSE 0 END) AS 暴露缺失,
    SUM(CASE WHEN hypokalemia_event IS NULL THEN 1 ELSE 0 END) AS 结局缺失,
    SUM(CASE WHEN baseline_k IS NULL THEN 1 ELSE 0 END) AS 血钾缺失,
    SUM(CASE WHEN baseline_egfr IS NULL THEN 1 ELSE 0 END) AS eGFR缺失,
    SUM(CASE WHEN any_other_laxative IS NULL THEN 1 ELSE 0 END) AS 其他泻药缺失,
    SUM(CASE WHEN potassium_supplement IS NULL THEN 1 ELSE 0 END) AS 补钾缺失,
    SUM(CASE WHEN ppi IS NULL THEN 1 ELSE 0 END) AS PPI缺失
FROM senna_study.analysis_wide_first;




