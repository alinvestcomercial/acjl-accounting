# Arquitectura

ACJL Management continua como sistema operacional. ACJL Accounting é o sistema contabilístico.

Fluxo: Management -> eventos/documentos -> Accounting ingestion -> classificação -> lançamento -> razão -> relatórios.

Regras: eventos idempotentes; Accounting não altera documentos originais; lançamentos publicados são imutáveis e corrigidos por estorno; períodos fechados bloqueiam lançamentos; regras fiscais possuem vigência e referência legal.