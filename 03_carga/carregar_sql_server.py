"""
carregar_sql_server.py
Carrega os CSVs fictícios em tabelas de staging (stg_*) no SQL Server.
Tudo entra como texto; o tratamento acontece depois, em SQL.
"""
import os
from pathlib import Path

import pandas as pd
import pyodbc

SERVIDOR = os.getenv("SQL_SERVER", r"localhost\SQLEXPRESS01")
BANCO = os.getenv("SQL_DATABASE", "CallCenterPortfolio")
PASTA_DADOS = Path(__file__).parent.parent / "dados_ficticios"

ARQUIVOS = {
    "stg_atendimentos": "atendimentos.csv",
    "stg_tabulacao": "tabulacao.csv",
    "stg_vendas": "vendas.csv",
}


def escolher_driver():
    drivers = [d for d in pyodbc.drivers() if d.startswith("ODBC Driver") and "SQL Server" in d]
    if not drivers:
        raise SystemExit(
            "Nenhum 'ODBC Driver for SQL Server' encontrado. "
            "Instale o 'ODBC Driver 18 for SQL Server' (site da Microsoft) e rode de novo."
        )
    return sorted(drivers)[-1]


def conectar():
    cadeia = (
        f"DRIVER={{{escolher_driver()}}};SERVER={SERVIDOR};DATABASE={BANCO};"
        "Trusted_Connection=yes;TrustServerCertificate=yes;"
    )
    return pyodbc.connect(cadeia)


def carregar(cursor, tabela, arquivo):
    df = pd.read_csv(PASTA_DADOS / arquivo, dtype=str, encoding="utf-8-sig")
    df = df.astype(object).where(df.notna(), None)

    colunas = list(df.columns)
    cursor.execute(f"IF OBJECT_ID('dbo.{tabela}', 'U') IS NOT NULL DROP TABLE dbo.{tabela}")
    definicao = ", ".join(f"[{c}] NVARCHAR(500) NULL" for c in colunas)
    cursor.execute(f"CREATE TABLE dbo.{tabela} ({definicao})")

    marcadores = ", ".join("?" for _ in colunas)
    lista_colunas = ", ".join(f"[{c}]" for c in colunas)
    cursor.fast_executemany = True
    cursor.executemany(
        f"INSERT INTO dbo.{tabela} ({lista_colunas}) VALUES ({marcadores})",
        df.values.tolist(),
    )
    print(f"{tabela:<18} -> {len(df)} linhas carregadas")


if __name__ == "__main__":
    with conectar() as conexao:
        cursor = conexao.cursor()
        for tabela, arquivo in ARQUIVOS.items():
            carregar(cursor, tabela, arquivo)
        conexao.commit()
    print("Carga concluída.")