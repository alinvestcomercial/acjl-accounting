-- ACJL Accounting: double-entry posting engine
-- PostgreSQL/Supabase. Designed to run in the accounting database only.

create or replace function public.validate_journal_entry(p_entry_id uuid)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_debit numeric(18,2);
  v_credit numeric(18,2);
  v_company uuid;
  v_status text;
  v_lines integer;
begin
  select company_id,status into v_company,v_status from public.journal_entries where id=p_entry_id for update;
  if v_company is null then raise exception 'Lançamento não encontrado'; end if;
  if v_status <> 'draft' then raise exception 'Apenas lançamentos em rascunho podem ser validados'; end if;

  select count(*),coalesce(sum(debit),0),coalesce(sum(credit),0)
    into v_lines,v_debit,v_credit
  from public.journal_lines where journal_entry_id=p_entry_id;

  if v_lines < 2 then raise exception 'Um lançamento deve possuir pelo menos duas linhas'; end if;
  if round(v_debit,2) <> round(v_credit,2) then raise exception 'Lançamento desequilibrado: débito=% crédito=%',v_debit,v_credit; end if;
  if v_debit <= 0 then raise exception 'O valor contabilístico deve ser superior a zero'; end if;

  if exists (
    select 1 from public.journal_lines l
    left join public.chart_of_accounts a on a.id=l.account_id
    where l.journal_entry_id=p_entry_id and (a.id is null or a.company_id<>v_company or not a.active)
  ) then raise exception 'Conta inválida ou pertencente a outra empresa'; end if;

  update public.journal_entries set status='posted' where id=p_entry_id;
end $$;

create or replace function public.post_accounting_event(
  p_company_id uuid,
  p_source_type text,
  p_source_id uuid,
  p_event_version integer,
  p_occurred_at timestamptz,
  p_idempotency_key text,
  p_payload jsonb
)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_event uuid;
begin
  insert into public.accounting_events(company_id,source_type,source_id,event_version,occurred_at,idempotency_key,payload,status)
  values(p_company_id,p_source_type,p_source_id,p_event_version,p_occurred_at,p_idempotency_key,p_payload,'received')
  on conflict(company_id,idempotency_key) do update
    set payload=excluded.payload,event_version=excluded.event_version,occurred_at=excluded.occurred_at
  returning id into v_event;
  return v_event;
end $$;

create or replace function public.create_draft_entry(
  p_company_id uuid,
  p_entry_date date,
  p_description text,
  p_source_event_id uuid default null
)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare v_id uuid;
begin
  if not exists(select 1 from public.accounting_companies where id=p_company_id) then
    raise exception 'Empresa contabilística não encontrada';
  end if;
  if exists(select 1 from public.fiscal_periods where company_id=p_company_id and p_entry_date between starts_on and ends_on and status<>'open') then
    raise exception 'O período contabilístico está fechado ou bloqueado';
  end if;
  insert into public.journal_entries(company_id,entry_date,description,source_event_id,status)
  values(p_company_id,p_entry_date,p_description,p_source_event_id,'draft')
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.add_journal_line(
  p_entry_id uuid,
  p_account_id uuid,
  p_debit numeric,
  p_credit numeric,
  p_description text default null,
  p_tax_rule_id uuid default null
)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare v_id uuid; v_company uuid; v_next integer;
begin
  select company_id into v_company from public.journal_entries where id=p_entry_id and status='draft' for update;
  if v_company is null then raise exception 'Lançamento inexistente ou já publicado'; end if;
  if not exists(select 1 from public.chart_of_accounts where id=p_account_id and company_id=v_company and active) then
    raise exception 'Conta inválida';
  end if;
  if (p_debit > 0 and p_credit > 0) or (p_debit <= 0 and p_credit <= 0) then
    raise exception 'Cada linha deve conter débito ou crédito, mas não ambos';
  end if;
  select coalesce(max(line_no),0)+1 into v_next from public.journal_lines where journal_entry_id=p_entry_id;
  insert into public.journal_lines(journal_entry_id,account_id,line_no,debit,credit,description,tax_rule_id)
  values(p_entry_id,p_account_id,v_next,p_debit,p_credit,p_description,p_tax_rule_id)
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.post_invoice_event(p_event_id uuid)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  e public.accounting_events%rowtype;
  v_entry uuid;
  v_receivable uuid;
  v_revenue uuid;
  v_output_tax uuid;
  v_net numeric(18,2);
  v_tax numeric(18,2);
  v_total numeric(18,2);
begin
  select * into e from public.accounting_events where id=p_event_id for update;
  if e.id is null then raise exception 'Evento não encontrado'; end if;
  if e.status='posted' then return e.id; end if;
  if e.source_type not in ('sales_invoice','purchase_invoice') then raise exception 'Tipo de evento não suportado por este motor'; end if;

  v_net:=coalesce((e.payload->>'net_amount')::numeric,0);
  v_tax:=coalesce((e.payload->>'tax_amount')::numeric,0);
  v_total:=coalesce((e.payload->>'total_amount')::numeric,v_net+v_tax);
  if v_total<=0 then raise exception 'Documento sem valor contabilístico'; end if;

  select id into v_receivable from public.chart_of_accounts where company_id=e.company_id and system_key=case when e.source_type='sales_invoice' then 'trade_receivables' else 'trade_payables' end and active limit 1;
  select id into v_revenue from public.chart_of_accounts where company_id=e.company_id and system_key=case when e.source_type='sales_invoice' then 'sales_revenue' else 'purchases_expense' end and active limit 1;
  select id into v_output_tax from public.chart_of_accounts where company_id=e.company_id and system_key=case when e.source_type='sales_invoice' then 'vat_output' else 'vat_input' end and active limit 1;

  if v_receivable is null or v_revenue is null or v_output_tax is null then
    update public.accounting_events set status='needs_review' where id=e.id;
    raise exception 'Mapeamento contabilístico incompleto para o documento';
  end if;

  v_entry:=public.create_draft_entry(e.company_id,(e.occurred_at at time zone 'Africa/Maputo')::date,case when e.source_type='sales_invoice' then 'Venda ' else 'Compra ' end || coalesce(e.payload->>'document_number',e.source_id::text),e.id);

  if e.source_type='sales_invoice' then
    perform public.add_journal_line(v_entry,v_receivable,v_total,0,'Cliente');
    perform public.add_journal_line(v_entry,v_revenue,0,v_net,'Rendimento');
    if v_tax>0 then perform public.add_journal_line(v_entry,v_output_tax,0,v_tax,'IVA'); end if;
  else
    perform public.add_journal_line(v_entry,v_revenue,v_net,0,'Gasto/compra');
    if v_tax>0 then perform public.add_journal_line(v_entry,v_output_tax,v_tax,0,'IVA dedutível'); end if;
    perform public.add_journal_line(v_entry,v_receivable,0,v_total,'Fornecedor');
  end if;

  perform public.validate_journal_entry(v_entry);
  update public.accounting_events set status='posted' where id=e.id;
  return v_entry;
end $$;

revoke execute on function public.validate_journal_entry(uuid) from public,anon;
revoke execute on function public.post_accounting_event(uuid,text,uuid,integer,timestamptz,text,jsonb) from public,anon;
revoke execute on function public.create_draft_entry(uuid,date,text,uuid) from public,anon;
revoke execute on function public.add_journal_line(uuid,uuid,numeric,numeric,text,uuid) from public,anon;
revoke execute on function public.post_invoice_event(uuid) from public,anon;
grant execute on function public.validate_journal_entry(uuid) to authenticated;
grant execute on function public.post_accounting_event(uuid,text,uuid,integer,timestamptz,text,jsonb) to authenticated;
grant execute on function public.create_draft_entry(uuid,date,text,uuid) to authenticated;
grant execute on function public.add_journal_line(uuid,uuid,numeric,numeric,text,uuid) to authenticated;
grant execute on function public.post_invoice_event(uuid) to authenticated;
