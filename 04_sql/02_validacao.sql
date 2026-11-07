USE CallCenterPortfolio;
GO

-- A) Quanto da base foi classificado pela tabulação
SELECT
    tipo_match,
    COUNT(*) AS qtd,
    CAST(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER () AS DECIMAL(5,2)) AS percentual
FROM dbo.vw_atendimentos_classificado
GROUP BY tipo_match
ORDER BY qtd DESC;

-- B) Os volumes fecham entre as camadas?
SELECT
    (SELECT COUNT(*)    FROM dbo.stg_atendimentos)        AS bruto,
    (SELECT COUNT(*)    FROM dbo.vw_atendimentos_limpo)   AS limpo,
    (SELECT SUM(volume) FROM dbo.vw_fato_atendimento)     AS fato_atendimento,
    (SELECT SUM(volume) FROM dbo.vw_resumo_diario)        AS resumo_diario;

-- C) Alguma data não foi convertida?
SELECT COUNT(*) AS datas_nulas
FROM dbo.vw_atendimentos_limpo
WHERE data_hora IS NULL;

-- D) Vendas: casos distintos x total nas views
SELECT
    (SELECT COUNT(DISTINCT numero_caso) FROM dbo.stg_vendas)                    AS casos_distintos,
    (SELECT SUM(vendas_gerais + vendas_canceladas) FROM dbo.vw_fato_vendas)     AS casos_na_view,
    (SELECT SUM(vendas_gerais + vendas_canceladas) FROM dbo.vw_resumo_diario)   AS casos_no_resumo;

-- E) Tags que ainda ficaram sem cadastro
SELECT TOP 10 tags, COUNT(*) AS qtd
FROM dbo.vw_atendimentos_classificado
WHERE tipo_match = N'Sem match'
GROUP BY tags
ORDER BY qtd DESC;

-- F) Amostra do resumo diário
SELECT TOP 20 *
FROM dbo.vw_resumo_diario
ORDER BY data, canal;