更改合并用药数：从医嘱数目更改成药物种类数

SELECT
    aw.hadm_id,
    aw.drug_count AS 当前医嘱条目数,
    COUNT(DISTINCT LOWER(p.drug)) AS 新的药物种类数
FROM senna_study.analysis_wide_first aw
LEFT JOIN mimiciv_hosp.prescriptions p
    ON aw.hadm_id = p.hadm_id
GROUP BY aw.hadm_id, aw.drug_count
LIMIT 20;

SELECT
    COUNT(*) AS 总行数,
    COUNT(formulary_drug_cd) AS 有formulary_drug_cd,
    COUNT(gsn) AS 有gsn,
    COUNT(ndc) AS 有ndc
FROM mimiciv_hosp.prescriptions;

-- 重新计算 drug_count，仅限口服给药途径
UPDATE senna_study.analysis_wide_first aw
SET drug_count = COALESCE(sub.new_drug_count, 0)
FROM (
    SELECT 
        subject_id,
        hadm_id, 
        -- 提取药物有效成分（第一个单词），去重
        COUNT(DISTINCT LOWER(SPLIT_PART(drug, ' ', 1))) AS new_drug_count
    FROM mimiciv_hosp.prescriptions
    WHERE drug IS NOT NULL 
      AND drug != ''
      -- 只保留口服相关的给药途径
      AND route IN ('PO', 'PO/NG', 'NG', 'PO/PR', 'PO/OG')
      -- 排除口服液/冲洗液等载体
      AND LOWER(drug) NOT LIKE '%sodium chloride%'
      AND LOWER(drug) NOT LIKE '%dextrose%'
      AND LOWER(drug) NOT LIKE '%sterile water%'
    GROUP BY subject_id, hadm_id
) sub
WHERE aw.subject_id = sub.subject_id 
  AND aw.hadm_id = sub.hadm_id;

-- 匹配不上的（没用过口服药）设为 0
UPDATE senna_study.analysis_wide_first
SET drug_count = 0
WHERE drug_count IS NULL;

SELECT
    '药物种类数' AS 变量,
    COUNT(*) AS n,
    ROUND(AVG(drug_count)::numeric, 1) AS 均值,
    ROUND(MIN(drug_count)::numeric, 0) AS 最小值,
    ROUND(MAX(drug_count)::numeric, 0) AS 最大值,
    SUM(polypharmacy) AS 多重用药人数
FROM senna_study.analysis_wide_first;

ALTER TABLE senna_study.analysis_wide_first
ADD COLUMN IF NOT EXISTS drug_count_no_laxatives INT;

UPDATE senna_study.analysis_wide_first aw
SET drug_count_no_laxatives = COALESCE(sub.new_drug_count, 0)
FROM (
    SELECT 
        subject_id,
        hadm_id, 
        COUNT(DISTINCT LOWER(SPLIT_PART(drug, ' ', 1))) AS new_drug_count
    FROM mimiciv_hosp.prescriptions
    WHERE drug IS NOT NULL 
      AND drug != ''
      -- 只统计口服给药途径（与之前 drug_count 的定义保持一致）
      AND route IN ('PO', 'PO/NG', 'NG', 'PO/PR', 'PO/OG')
      -- 排除静脉输液载体液
      AND LOWER(drug) NOT LIKE '%sodium chloride%'
      AND LOWER(drug) NOT LIKE '%dextrose%'
      AND LOWER(drug) NOT LIKE '%sterile water%'
      -- 排除所有泻药（番泻叶及其他泻药）
      AND LOWER(drug) NOT LIKE '%senna%'
      AND LOWER(drug) NOT LIKE '%sennoside%'
      AND LOWER(drug) NOT LIKE '%senokot%'
      AND LOWER(drug) NOT LIKE '%lactulose%'
      AND LOWER(drug) NOT LIKE '%polyethylene glycol%'
      AND LOWER(drug) NOT LIKE '%peg%'
      AND LOWER(drug) NOT LIKE '%bisacodyl%'
      AND LOWER(drug) NOT LIKE '%docusate%'
    GROUP BY subject_id, hadm_id
) sub
WHERE aw.subject_id = sub.subject_id 
  AND aw.hadm_id = sub.hadm_id;

UPDATE senna_study.analysis_wide_first
SET drug_count_no_laxatives = 0
WHERE drug_count_no_laxatives IS NULL;

SELECT
    '排除泻药后的药物种类数' AS 变量,
    COUNT(*) AS n,
    ROUND(AVG(drug_count_no_laxatives)::numeric, 1) AS 均值,
    ROUND(MIN(drug_count_no_laxatives)::numeric, 0) AS 最小值,
    ROUND(MAX(drug_count_no_laxatives)::numeric, 0) AS 最大值
FROM senna_study.analysis_wide_first;

-- 同时看看两列的差值是否合理（排除泻药后应该更少）
SELECT
    ROUND(AVG(drug_count)::numeric, 1) AS 原药物种类数均值,
    ROUND(AVG(drug_count_no_laxatives)::numeric, 1) AS 排除泻药后均值,
    ROUND(AVG(drug_count - drug_count_no_laxatives)::numeric, 1) AS 平均减少的种类数
FROM senna_study.analysis_wide_first;

