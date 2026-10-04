create table if not exists public.account_role_mappings (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.accounting_companies(id) on delete cascade,
  role_key text not null,
  account_id uuid not null references public.chart_of_accounts(id),
  effective_from date not null default current_date,
  effective_to date,
  active boolean not null default true,
  unique(company_id,role_key,effective_from)
);

create table if not exists public.posting_rule_versions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.accounting_companies(id) on delete cascade,
  source_type text not null,
  version integer not null default 1,
  effective_from date not null,
  effective_to date,
  active boolean not null default true,
  rule jsonb not null default '{}'::jsonb,
  unique(company_id,source_type,version)
);

alter table public.account_role_mappings enable row level security;
alter table public.posting_rule_versions enable row level security;

create policy account_roles_member_all on public.account_role_mappings for all to authenticated using (public.is_accounting_member(company_id)) with check (public.is_accounting_member(company_id));
create policy posting_rules_member_all on public.posting_rule_versions for all to authenticated using (public.is_accounting_member(company_id)) with check (public.is_accounting_member(company_id));

create or replace function public.ingest_accounting_event(
  p_company uuid,
  p_source_type text,
  p_source_id uuid,
  p_occurred_at timestamptz,
  p_idempotency_key text,
  p_payload jsonb
) returns uuid
language plpgsql security invoker set search_path=public
as $$
declare v_id uuid;
begin
  if not public.is_accounting_member(p_company) then raise exception 'Empresa não autorizada'; end if;
  insert into public.accounting_events(company_id,source_type,source_id,occurred_at,idempotency_key,payload)
  values(p_company,p_source_type,p_source_id,p_occurred_at,p_idempotency_key,p_payload)
  on conflict(company_id,idempotency_key) do update set payload=excluded.payload
  returning id into v_id;
  return v_id;
end $$;

revoke all on function public.ingest_accounting_event(uuid,text,uuid,timestamptz,text,jsonb) from public,anon;
grant execute on function public.ingest_accounting_event(uuid,text,uuid,timestamptz,text,jsonb) to authenticated;

create or replace function public.resolve_account_role(p_company uuid,p_role text,p_date date)
returns uuid language sql stable security invoker set search_path=public as $$
  select account_id from public.account_role_mappings
  where company_id=p_company and role_key=p_role and active
    and p_date >= effective_from and (effective_to is null or p_date <= effective_to)
  order by effective_from desc limit 1
$$;

create or replace function public.process_accounting_event(p_event uuid)
returns uuid
language plpgsql security invoker set search_path=public
as $$
declare
  e public.accounting_events;
  v_date date;
  v_entry uuid;
  v_net numeric(18,2);
  v_tax numeric(18,2);
  v_total numeric(18,2);
  v_debit_role text;
  v_credit_role text;
  v_debit_account uuid;
  v_credit_account uuid;
  v_tax_account uuid;
  v_lines jsonb;
begin
  select * into e from public.accounting_events where id=p_event;
  if not found then raise exception 'Evento não encontrado'; end if;
  if not public.is_accounting_member(e.company_id) then raise exception 'Empresa não autorizada'; end if;
  if e.status='posted' then return (select id from public.journal_entries where source_event_id=e.id limit 1); end if;

  v_date=(e.occurred_at at time zone 'Africa/Maputo')::date;
  v_net=coalesce((e.payload->>'net_amount')::numeric,0);
  v_tax=coalesce((e.payload->>'tax_amount')::numeric,0);
  v_total=coalesce((e.payload->>'total_amount')::numeric,v_net+v_tax);

  if v_net <= 0 or v_total <= 0 then
    update public.accounting_events set status='needs_review',review_reason='Valores da operação incompletos ou inválidos' where id=e.id;
    return null;
  end if;

  if e.source_type='sales_invoice' then
    v_debit_role='accounts_receivable'; v_credit_role='revenue'; v_tax_account=public.resolve_account_role(e.company_id,'output_tax',v_date);
  elsif e.source_type='purchase_invoice' then
    v_debit_role='expense'; v_credit_role='accounts_payable'; v_tax_account=public.resolve_account_role(e.company_id,'input_tax',v_date);
  elsif e.source_type in ('customer_receipt','cash_receipt') then
    v_debit_role='cash_or_bank'; v_credit_role='accounts_receivable';
  elsif e.source_type in ('supplier_payment','cash_payment') then
    v_debit_role='accounts_payable'; v_credit_role='cash_or_bank';
  else
    update public.accounting_events set status='needs_review',review_reason='Tipo de operação ainda não possui regra automática' where id=e.id;
    return null;
  end if;

  v_debit_account=public.resolve_account_role(e.company_id,v_debit_role,v_date);
  v_credit_account=public.resolve_account_role(e.company_id,v_credit_role,v_date);

  if v_debit_account is null or v_credit_account is null then
    update public.accounting_events set status='needs_review',review_reason='Falta configurar contas automáticas para esta operação' where id=e.id;
    return null;
  end if;

  if e.source_type in ('sales_invoice','purchase_invoice') and v_tax > 0 and v_tax_account is null then
    update public.accounting_events set status='needs_review',review_reason='Falta configurar a conta fiscal' where id=e.id;
    return null;
  end if;

  if e.source_type in ('sales_invoice','purchase_invoice') and v_tax > 0 then
    if e.source_type='sales_invoice' then
      v_lines=jsonb_build_array(
        jsonb_build_object('account_id',v_debit_account,'line_no',1,'debit',v_total,'credit',0,'description','Valor a receber'),
        jsonb_build_object('account_id',v_credit_account,'line_no',2,'debit',0,'credit',v_net,'description','Rendimento'),
        jsonb_build_object('account_id',v_tax_account,'line_no',3,'debit',0,'credit',v_tax,'description','Imposto sobre vendas')
      );
    else
      v_lines=jsonb_build_array(
        jsonb_build_object('account_id',v_debit_account,'line_no',1,'debit',v_net,'credit',0,'description','Gasto/aquisição'),
        jsonb_build_object('account_id',v_tax_account,'line_no',2,'debit',v_tax,'credit',0,'description','Imposto dedutível'),
        jsonb_build_object('account_id',v_credit_account,'line_no',3,'debit',0,'credit',v_total,'description','Valor a pagar')
      );
    end if;
  else
    v_lines=jsonb_build_array(
      jsonb_build_object('account_id',v_debit_account,'line_no',1,'debit',v_total,'credit',0),
      jsonb_build_object('account_id',v_credit_account,'line_no',2,'debit',0,'credit',v_total)
    );
  end if;

  v_entry=public.post_journal_entry(e.company_id,v_date,coalesce(e.payload->>'description',e.source_type),e.id,v_lines);
  return v_entry;
end $$;

revoke all on function public.process_accounting_event(uuid) from public,anon;
grant execute on function public.process_accounting_event(uuid) to authenticated;
