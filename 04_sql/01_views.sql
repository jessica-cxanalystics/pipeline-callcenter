USE CallCenterPortfolio;
GO

-- 1. Tabulação com uma linha por STATUS_2
CREATE OR ALTER VIEW dbo.vw_tabulacao AS
SELECT
    LTRIM(RTRIM(STATUS_2)) AS STATUS_2,
    MAX(STATUS_1)          AS STATUS_1,
    MAX(LOCALIZACAO)       AS LOCALIZACAO,
    MAX(PRODUTIVO)         AS PRODUTIVO,
    MAX(CPC)               AS CPC
FROM dbo.stg_tabulacao
GROUP BY LTRIM(RTRIM(STATUS_2));
GO

-- 2. Atendimentos limpos: sem duplicados, datas padronizadas, tags sem espaços
CREATE OR ALTER VIEW dbo.vw_atendimentos_limpo AS
WITH Numerada AS (
    SELECT
        id_atendimento,
        CASE
            WHEN data_hora LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]%'
                THEN TRY_CONVERT(DATETIME, data_hora, 120)   -- aaaa-mm-dd hh:mi:ss
            WHEN data_hora LIKE '[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9]%'
                THEN TRY_CONVERT(DATETIME, data_hora, 103)   -- dd/mm/aaaa hh:mi
        END AS data_hora,
        canal,
        NULLIF(LTRIM(RTRIM(tags)), '') AS tags,
        agente,
        TRY_CONVERT(INT, duracao_seg) AS duracao_seg,
        ROW_NUMBER() OVER (PARTITION BY id_atendimento ORDER BY (SELECT NULL)) AS rn
    FROM dbo.stg_atendimentos
)
SELECT id_atendimento, data_hora, canal, tags, agente, duracao_seg
FROM Numerada
WHERE rn = 1;
GO

-- 3. Regra de dia útil + classificação pela tabulação (match completo, depois primeira tag)
CREATE OR ALTER VIEW dbo.vw_atendimentos_classificado AS
WITH Base AS (
    SELECT
        a.*,
        -- atendimentos a partir das 20h contam no dia seguinte
        CASE WHEN DATEPART(HOUR, a.data_hora) >= 20
             THEN DATEADD(DAY, 1, CAST(a.data_hora AS DATE))
             ELSE CAST(a.data_hora AS DATE) END AS data_pre,
        LTRIM(RTRIM(LEFT(a.tags, CHARINDEX(',', a.tags + ',') - 1))) AS primeira_tag
    FROM dbo.vw_atendimentos_limpo a
),
DiaUtil AS (
    SELECT
        b.*,
        -- sábado vai para segunda, domingo vai para segunda (independe do DATEFIRST)
        CASE ((DATEPART(WEEKDAY, b.data_pre) + @@DATEFIRST - 2) % 7) + 1
            WHEN 6 THEN DATEADD(DAY, 2, b.data_pre)
            WHEN 7 THEN DATEADD(DAY, 1, b.data_pre)
            ELSE b.data_pre
        END AS data_ref
    FROM Base b
)
SELECT
    d.id_atendimento,
    d.data_ref,
    d.canal,
    d.tags,
    d.duracao_seg,
    COALESCE(tf.STATUS_1,    tp.STATUS_1)    AS status_1,
    COALESCE(tf.STATUS_2,    tp.STATUS_2)    AS status_2,
    COALESCE(tf.LOCALIZACAO, tp.LOCALIZACAO) AS localizacao,
    COALESCE(tf.PRODUTIVO,   tp.PRODUTIVO)   AS produtivo,
    COALESCE(tf.CPC,         tp.CPC)         AS cpc,
    CASE
        WHEN d.tags IS NULL          THEN N'Sem tag'
        WHEN tf.STATUS_2 IS NOT NULL THEN N'Match completo'
        WHEN tp.STATUS_2 IS NOT NULL THEN N'Match primeira tag'
        ELSE N'Sem match'
    END AS tipo_match
FROM DiaUtil d
LEFT JOIN dbo.vw_tabulacao tf ON d.tags         = tf.STATUS_2
LEFT JOIN dbo.vw_tabulacao tp ON d.primeira_tag = tp.STATUS_2;
GO

-- 4. Fato de atendimentos: dia x canal x status
CREATE OR ALTER VIEW dbo.vw_fato_atendimento AS
WITH Rotulado AS (
    SELECT
        data_ref AS data,
        canal,
        ISNULL(status_1, N'Não classificado') AS status_1,
        CASE
            WHEN status_2 IS NOT NULL    THEN status_2
            WHEN tipo_match = N'Sem tag' THEN N'Sem tag'
            ELSE N'Sem cadastro na tabulação'
        END AS status_2,
        localizacao, produtivo, cpc, duracao_seg
    FROM dbo.vw_atendimentos_classificado
)
SELECT
    data, canal, status_1, status_2,
    COUNT(*) AS volume,
    SUM(CASE WHEN localizacao = N'SIM' THEN 1 ELSE 0 END) AS localizacao,
    SUM(CASE WHEN produtivo   = N'SIM' THEN 1 ELSE 0 END) AS produtivo,
    SUM(CASE WHEN produtivo   = N'SIM' THEN 0 ELSE 1 END) AS improdutivo,
    SUM(CASE WHEN cpc         = N'SIM' THEN 1 ELSE 0 END) AS cpc,
    SUM(duracao_seg)                                      AS duracao_total_seg
FROM Rotulado
GROUP BY data, canal, status_1, status_2;
GO

-- 5. Fato de vendas: dia x canal (um registro por caso, pegando o último item)
CREATE OR ALTER VIEW dbo.vw_fato_vendas AS
WITH Ultimo_Item AS (
    SELECT
        numero_caso,
        TRY_CONVERT(DATE, data_criacao, 23) AS data,
        subcanal,
        status,
        ROW_NUMBER() OVER (
            PARTITION BY numero_caso
            ORDER BY TRY_CONVERT(INT, numero_item) DESC
        ) AS rn
    FROM dbo.stg_vendas
),
Mapeado AS (
    SELECT
        data,
        CASE subcanal
            WHEN N'WhatsApp_receptivo' THEN N'WHATSAPP RECEPTIVO'
            WHEN N'WhatsApp_BOT'       THEN N'WHATSAPP RECEPTIVO'
            WHEN N'WhatsApp_ativo'     THEN N'WHATSAPP ATIVO'
            WHEN N'Voz_receptiva'      THEN N'RECEPTIVO VOZ'
            WHEN N'Voz_ativa'          THEN N'ATIVO VOZ'
            ELSE N'OUTROS'
        END AS canal,
        status
    FROM Ultimo_Item
    WHERE rn = 1
)
SELECT
    data, canal,
    SUM(CASE WHEN status <> N'Cancelado' THEN 1 ELSE 0 END)                                AS vendas_gerais,
    SUM(CASE WHEN status IN (N'Em execução', N'Executado com Sucesso') THEN 1 ELSE 0 END) AS vendas_efetivadas,
    SUM(CASE WHEN status = N'Cancelado' THEN 1 ELSE 0 END)                                 AS vendas_canceladas
FROM Mapeado
GROUP BY data, canal;
GO

-- 6. Resumo diário: calendário x canais, sem duplicar valores
CREATE OR ALTER VIEW dbo.vw_resumo_diario AS
WITH Limites AS (
    SELECT MIN(data_ref) AS dt_min, MAX(data_ref) AS dt_max
    FROM dbo.vw_atendimentos_classificado
),
Numeros AS (
    SELECT TOP (1000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
),
Calendario AS (
    SELECT DATEADD(DAY, n.n, l.dt_min) AS data
    FROM Limites l
    JOIN Numeros n ON DATEADD(DAY, n.n, l.dt_min) <= l.dt_max
),
Canais AS (
    SELECT canal
    FROM (VALUES (N'WHATSAPP RECEPTIVO'), (N'WHATSAPP ATIVO'),
                 (N'RECEPTIVO VOZ'),      (N'ATIVO VOZ')) v(canal)
),
Atend AS (
    SELECT
        data, canal,
        SUM(volume)            AS volume,
        SUM(localizacao)       AS localizacao,
        SUM(produtivo)         AS produtivo,
        SUM(improdutivo)       AS improdutivo,
        SUM(cpc)               AS cpc,
        SUM(duracao_total_seg) AS duracao_total_seg
    FROM dbo.vw_fato_atendimento
    GROUP BY data, canal
)
SELECT
    c.data,
    FORMAT(c.data, 'MM-yyyy')         AS mes_ano,
    FORMAT(c.data, 'dddd', 'pt-BR')   AS dia_semana,
    k.canal,
    ISNULL(a.volume, 0)               AS volume,
    ISNULL(a.localizacao, 0)          AS localizacao,
    ISNULL(a.produtivo, 0)            AS produtivo,
    ISNULL(a.improdutivo, 0)          AS improdutivo,
    ISNULL(a.cpc, 0)                  AS cpc,
    CAST(a.duracao_total_seg * 1.0 / NULLIF(a.volume, 0) AS DECIMAL(10,1)) AS aht_seg,
    ISNULL(v.vendas_gerais, 0)        AS vendas_gerais,
    ISNULL(v.vendas_efetivadas, 0)    AS vendas_efetivadas,
    ISNULL(v.vendas_canceladas, 0)    AS vendas_canceladas,
    CAST(ISNULL(v.vendas_canceladas, 0) * 1.0
         / NULLIF(ISNULL(v.vendas_gerais, 0) + ISNULL(v.vendas_canceladas, 0), 0)
         AS DECIMAL(5,4))             AS taxa_cancelamento
FROM Calendario c
CROSS JOIN Canais k
LEFT JOIN Atend a                ON a.data = c.data AND a.canal = k.canal
LEFT JOIN dbo.vw_fato_vendas v   ON v.data = c.data AND v.canal = k.canal;
GO

-- 7. Cancelamentos por motivo: dia x canal x motivo
CREATE OR ALTER VIEW dbo.vw_cancelamentos AS
WITH Ultimo_Item AS (
    SELECT
        numero_caso,
        TRY_CONVERT(DATE, data_criacao, 23) AS data,
        subcanal,
        status,
        motivo_cancelamento,
        ROW_NUMBER() OVER (
            PARTITION BY numero_caso
            ORDER BY TRY_CONVERT(INT, numero_item) DESC
        ) AS rn
    FROM dbo.stg_vendas
)
SELECT
    data,
    CASE subcanal
        WHEN N'WhatsApp_receptivo' THEN N'WHATSAPP RECEPTIVO'
        WHEN N'WhatsApp_BOT'       THEN N'WHATSAPP RECEPTIVO'
        WHEN N'WhatsApp_ativo'     THEN N'WHATSAPP ATIVO'
        WHEN N'Voz_receptiva'      THEN N'RECEPTIVO VOZ'
        WHEN N'Voz_ativa'          THEN N'ATIVO VOZ'
        ELSE N'OUTROS'
    END AS canal,
    ISNULL(motivo_cancelamento, N'Não informado') AS motivo,
    COUNT(*) AS cancelamentos
FROM Ultimo_Item
WHERE rn = 1 AND status = N'Cancelado'
GROUP BY
    data,
    CASE subcanal
        WHEN N'WhatsApp_receptivo' THEN N'WHATSAPP RECEPTIVO'
        WHEN N'WhatsApp_BOT'       THEN N'WHATSAPP RECEPTIVO'
        WHEN N'WhatsApp_ativo'     THEN N'WHATSAPP ATIVO'
        WHEN N'Voz_receptiva'      THEN N'RECEPTIVO VOZ'
        WHEN N'Voz_ativa'          THEN N'ATIVO VOZ'
        ELSE N'OUTROS'
    END,
    ISNULL(motivo_cancelamento, N'Não informado');
GO
