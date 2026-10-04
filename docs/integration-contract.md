# Contrato de integração

Cada evento vindo do Management deve conter: company_id, source_type, source_id, occurred_at, event_version, idempotency_key e payload.

Estados: received, classified, posted, needs_review, rejected.

O Accounting devolve o resultado contabilístico sem alterar silenciosamente o documento original.