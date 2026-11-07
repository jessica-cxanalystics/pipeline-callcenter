
import random
from pathlib import Path

import numpy as np
import pandas as pd

SEED = 42
random.seed(SEED)
np.random.seed(SEED)

PASTA = Path(__file__).parent
DATA_INICIO = pd.Timestamp("2026-01-01")
N_DIAS = 90
N_ATENDIMENTOS = 6000
N_CASOS_VENDA = 900

CANAIS = ["WHATSAPP RECEPTIVO", "WHATSAPP ATIVO", "RECEPTIVO VOZ", "ATIVO VOZ"]
PESO_CANAIS = [0.35, 0.20, 0.30, 0.15]

# status_1, status_2, localizacao, produtivo, cpc
TABULACAO = [
    ("Venda", "Venda realizada", "SIM", "SIM", "SIM"),
    ("Venda", "Cliente pediu orçamento", "SIM", "SIM", "SIM"),
    ("Contato", "Cliente solicitou retorno", "SIM", "SIM", "SIM"),
    ("Contato", "Dúvidas sobre instalação", "SIM", "SIM", "SIM"),
    ("Contato", "Cliente não quis conhecer", "SIM", "NAO", "SIM"),
    ("Sem contato", "Cliente não respondeu", "NAO", "NAO", "NAO"),
    ("Sem contato", "Cliente parou de responder", "NAO", "NAO", "NAO"),
    ("Sem contato", "Número inválido", "NAO", "NAO", "NAO"),
    ("Suporte", "Transferência para o SAC", "SIM", "NAO", "SIM"),
    ("Suporte", "Reclamação", "SIM", "SIM", "SIM"),
    # combinações de tags já cadastradas (strings concatenadas)
    ("Contato", "Cliente solicitou retorno, Dúvidas sobre instalação", "SIM", "SIM", "SIM"),
    ("Sem contato", "Cliente não respondeu, Cliente parou de responder", "NAO", "NAO", "NAO"),
    ("Suporte", "Reclamação, Transferência para o SAC", "SIM", "SIM", "SIM"),
]

# tags que existem no atendimento mas NÃO estão cadastradas na tabulação
TAGS_ORFAS = ["suporte_solutions", "campanha_aceite", "financeiro_solutions", "{{etiqueta_transferencia}}"]

# subcanal -> probabilidade de cancelamento
SUBCANAIS = {
    "WhatsApp_receptivo": 0.15,
    "WhatsApp_BOT": 0.22,
    "WhatsApp_ativo": 0.28,
    "Voz_receptiva": 0.15,
    "Voz_ativa": 0.28,
}
MOTIVOS_CANCELAMENTO = [
    "Cliente desistiu",
    "Reprovado na análise de crédito",
    "Endereço fora da área de cobertura",
    "Cadastro duplicado",
    "Sem resposta do cliente",
]


def gerar_tabulacao():
    df = pd.DataFrame(
        TABULACAO, columns=["STATUS_1", "STATUS_2", "LOCALIZACAO", "PRODUTIVO", "CPC"]
    )
    df.to_csv(PASTA / "tabulacao.csv", index=False, encoding="utf-8-sig")
    return df


def gerar_atendimentos():
    validas = [t[1] for t in TABULACAO if "," not in t[1]]
    linhas = []
    for i in range(1, N_ATENDIMENTOS + 1):
        canal = random.choices(CANAIS, PESO_CANAIS)[0]
        momento = DATA_INICIO + pd.Timedelta(
            days=random.randint(0, N_DIAS - 1),
            hours=random.randint(8, 20),
            minutes=random.randint(0, 59),
        )
        qtd_tags = random.choices([1, 2, 3], [0.6, 0.3, 0.1])[0]
        tags = ", ".join(random.sample(validas, qtd_tags))

        # falhas plantadas nas tags
        sorteio = random.random()
        if sorteio < 0.08:
            tags = None                       # sem tag
        elif sorteio < 0.12:
            tags = random.choice(TAGS_ORFAS)  # tag sem cadastro
        elif sorteio < 0.15:
            tags = f"  {tags} "               # espaços extras

        # falha plantada na data: 2% em outro formato
        data_txt = momento.strftime("%Y-%m-%d %H:%M:%S")
        if random.random() < 0.02:
            data_txt = momento.strftime("%d/%m/%Y %H:%M")

        linhas.append({
            "id_atendimento": f"AT-{i:06d}",
            "data_hora": data_txt,
            "canal": canal,
            "tags": tags,
            "agente": f"Agente_{random.randint(1, 25):02d}",
            "duracao_seg": int(np.clip(np.random.lognormal(5.6, 0.5), 30, 2400)),
        })

    df = pd.DataFrame(linhas)
    # falha plantada: 3% de linhas duplicadas
    duplicadas = df.sample(frac=0.03, random_state=SEED)
    df = pd.concat([df, duplicadas]).sample(frac=1, random_state=SEED).reset_index(drop=True)
    df.to_csv(PASTA / "atendimentos.csv", index=False, encoding="utf-8-sig")
    return df


def gerar_vendas():
    linhas = []
    for i in range(1, N_CASOS_VENDA + 1):
        subcanal = random.choice(list(SUBCANAIS))
        data = DATA_INICIO + pd.Timedelta(days=random.randint(0, N_DIAS - 1))
        if random.random() < SUBCANAIS[subcanal]:
            status = "Cancelado"
            motivo = random.choice(MOTIVOS_CANCELAMENTO)
        else:
            status = random.choice(["Em execução", "Executado com Sucesso"])
            motivo = None
        # cada caso pode ter de 1 a 3 itens (usado depois com ROW_NUMBER no SQL)
        for item in range(1, random.randint(1, 3) + 1):
            linhas.append({
                "numero_caso": f"CASO-{i:06d}",
                "numero_item": item,
                "data_criacao": data.strftime("%Y-%m-%d"),
                "subcanal": subcanal,
                "status": status,
                "motivo_cancelamento": motivo,
            })
    df = pd.DataFrame(linhas)
    df.to_csv(PASTA / "vendas.csv", index=False, encoding="utf-8-sig")
    return df


if __name__ == "__main__":
    tab = gerar_tabulacao()
    atend = gerar_atendimentos()
    vendas = gerar_vendas()
    print(f"tabulacao.csv    -> {len(tab)} linhas")
    print(f"atendimentos.csv -> {len(atend)} linhas")
    print(f"vendas.csv       -> {len(vendas)} linhas")