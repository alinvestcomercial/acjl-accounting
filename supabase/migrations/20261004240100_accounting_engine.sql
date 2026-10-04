create extension if not exists pgcrypto;

create table if not exists public.accounting_companies (id uuid primary key default gen_random_uuid(), external_company_id uuid not null unique, accounting_framework text not null default 'pgc_nirf', tax_regime text, currency_code char(3) not null default 'MZN', fiscal_year_start smallint not null default 1 check(fiscal_year_start between 1 and 12), setup_status text not null default 'setup' check(setup_status in ('setup','ready','review')), created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table if not exists public.fiscal_periods (id uuid primary key default gen_random_uuid(), company_id uuid not null references public.accounting_companies(id) on delete cascade, period_year integer not null, starts_on date not null, ends_on date not null, status text not null default 'open' check(status in ('open','closed','locked')), unique(company_id,period_year));
create table if not exists public.chart_of_accounts (id uuid primary key default gen_random_uuid(), company_id uuid not null references public.accounting_companies(id) on delete cascade, code text not null, name text not null, parent_id uuid references public.chart_of_accounts(id), account_class smallint, account_type text not null check(account_type in ('asset','liability','equity','revenue','expense','tax','memo')), normal_balance text not null check(normal_balance in ('debit','credit')), system_key text, is_header boolean not null default false, active boolean not null default true, unique(company_id,code));
create table if not exists public.tax_rules (id uuid primary key default gen_random_uuid(), company_id uuid not null references public.accounting_companies(id) on delete cascade, code text not null, name text not null, tax_type text not null, rate numeric(12,6), effective_from date not null, effective_to date, legal_reference text, parameters jsonb not null default '{}'::jsonb, active boolean not null default true, unique(company_id,code,effective_from));
create table if not exists public.accounting_events (id uuid primary key default gen_random_uuid(), company_id uuid not null references public.accounting_companies(id) on delete cascade, source_type text not null, source_id uuid not null, event_version integer not null default 1, occurred_at timestamptz not null, idempotency_key text not null, payload jsonb not null default '{}'::jsonb, status text not null default 'received' check(status in ('received','classified','posted','needs_review','rejected')), created_at timestamptz not null default now(), unique(company_id,idempotency_key));
create table if not exists public.journal_entries (id uuid primary key default gen_random_uuid(), company_id uuid not null references public.accounting_companies(id) on delete cascade, entry_no bigint generated always as identity, entry_date date not null, description text not null, source_event_id uuid references public.accounting_events(id), status text not null default 'posted' check(status in ('draft','posted','reversed')), created_at timestamptz not null default now(), unique(company_id,entry_no));
create table if not exists public.journal_lines (id uuid primary key default gen_random_uuid(), journal_entry_id uuid not null references public.journal_entries(id) on delete cascade, account_id uuid not null references public.chart_of_accounts(id), line_no integer not null, debit numeric(18,2) not null default 0 check(debit>=0), credit numeric(18,2) not null default 0 check(credit>=0), tax_rule_id uuid references public.tax_rules(id), description text, check((debit>0 and credit=0) or (credit>0 and debit=0)), unique(journal_entry_id,line_no));
create index if not exists idx_events_company_status on public.accounting_events(company_id,status);
create index if not exists idx_journal_company_date on public.journal_entries(company_id,entry_date);
create index if not exists idx_journal_lines_entry on public.journal_lines(journal_entry_id);

-- Double-entry posting engine, immutable published entries, fiscal-period control and tenant isolation are added in the next migration.

alter table public.accounting_companies enable row level security;
alter table public.fiscal_periods enable row level security;
alter table public.chart_of_accounts enable row level security;
alter table public.tax_rules enable row level security;
alter table public.accounting_events enable row level security;
alter table public.journal_entries enable row level security;
alter table public.journal_lines enable row level security;

create table if not exists public.accounting_company_members (company_id uuid not null references public.accounting_companies(id) on delete cascade,user_id uuid not null references auth.users(id) on delete cascade,role text not null default 'accountant' check(role in ('owner','admin','accountant','reviewer','viewer')),created_at timestamptz not null default now(),primary key(company_id,user_id));
alter table public.accounting_company_members enable row level security;

create or replace function public.is_accounting_member(p_company uuid) returns boolean language sql stable security invoker set search_path=public as $$ select exists(select 1 from public.accounting_company_members m where m.company_id=p_company and m.user_id=auth.uid()); $$;

create policy accounting_company_member_select on public.accounting_companies for select to authenticated using (public.is_accounting_member(id));
create policy accounting_member_select on public.accounting_company_members for select to authenticated using (user_id=auth.uid());
create policy periods_member_all on public.fiscal_periods for all to authenticated using (public.is_accounting_member(company_id)) with check (public.is_accounting_member(company_id));
create policy coa_member_all on public.chart_of_accounts for all to authenticated using (public.is_accounting_member(company_id)) with check (public.is_accounting_member(company_id));
create policy tax_member_all on public.tax_rules for all to authenticated using (public.is_accounting_member(company_id)) with check (public.is_accounting_member(company_id));
create policy events_member_all on public.accounting_events for all to authenticated using (public.is_accounting_member(company_id)) with check (public.is_accounting_member(company_id));
create policy entries_member_select on public.journal_entries for select to authenticated using (public.is_accounting_member(company_id));
create policy lines_member_select on public.journal_lines for select to authenticated using (exists(select 1 from public.journal_entries e where e.id=journal_entry_id and public.is_accounting_member(e.company_id)));

create or replace function public.post_journal_entry(p_company uuid,p_entry_date date,p_description text,p_source_event uuid,p_lines jsonb) returns uuid language plpgsql security invoker set search_path=public as $$
declare v_entry uuid; v_debit numeric(18,2); v_credit numeric(18,2); v_status text;
begin
 if not public.is_accounting_member(p_company) then raise exception 'Empresa não autorizada'; end if;
 select status into v_status from public.fiscal_periods where company_id=p_company and p_entry_date between starts_on and ends_on limit 1;
 if v_status is null then raise exception 'Período contabilístico não configurado'; end if;\n  if v_status <> 'open' then raise exception 'Período contabilístico fechado ou bloqueado'; end if;
 if jsonb_array_length(p_lines)<2 then raise exception 'O lançamento deve possuir pelo menos duas linhas'; end if;
 select coalesce(sum((x->>'debit')::numeric),0),coalesce(sum((x->>'credit')::numeric),0) into v_debit,v_credit from jsonb_array_elements(p_lines) x;
 if v_debit<=0 or round(v_debit,2)<>round(v_credit,2) then raise exception 'Lançamento não balanceado'; end if;
 if exists(select 1 from jsonb_array_elements(p_lines) x where not exists(select 1 from public.chart_of_accounts a where a.id=(x->>'account_id')::uuid and a.company_id=p_company and a.active)) then raise exception 'Conta inválida para a empresa'; end if;
 insert into public.journal_entries(company_id,entry_date,description,source_event_id,status,created_by,posted_at) values(p_company,p_entry_date,p_description,p_source_event,'posted',auth.uid(),now()) returning id into v_entry;
 insert into public.journal_lines(journal_entry_id,account_id,line_no,debit,credit,tax_rule_id,description,dimensions) select v_entry,(x->>'account_id')::uuid,coalesce((x->>'line_no')::int,row_number() over()),coalesce((x->>'debit')::numeric,0),coalesce((x->>'credit')::numeric,0),nullif(x->>'tax_rule_id','')::uuid,nullif(x->>'description',''),coalesce(x->'dimensions','{}'::jsonb) from jsonb_array_elements(p_lines) x;
 if p_source_event is not null then update public.accounting_events set status='posted' where id=p_source_event and company_id=p_company; end if;
 return v_entry;
end $$;
revoke all on function public.post_journal_entry(uuid,date,text,uuid,jsonb) from public,anon;
grant execute on function public.post_journal_entry(uuid,date,text,uuid,jsonb) to authenticated;

create or replace function public.prevent_posted_journal_mutation() returns trigger language plpgsql security invoker set search_path=public as $$ begin if old.status='posted' then raise exception 'Lançamentos publicados são imutáveis; use estorno'; end if; return new; end $$;
drop trigger if exists trg_prevent_posted_entry_update on public.journal_entries;
create trigger trg_prevent_posted_entry_update before update or delete on public.journal_entries for each row execute function public.prevent_posted_journal_mutation();

create or replace view public.account_balances with (security_invoker=true) as select e.company_id,l.account_id,a.code,a.name,sum(l.debit-l.credit) as balance from public.journal_entries e join public.journal_lines l on l.journal_entry_id=e.id join public.chart_of_accounts a on a.id=l.account_id where e.status='posted' group by e.company_id,l.account_id,a.code,a.name;


create or replace function public.prevent_posted_line_mutation() returns trigger
language plpgsql security invoker set search_path=public
as $$
begin
  if exists(select 1 from public.journal_entries e where e.id=coalesce(old.journal_entry_id,new.journal_entry_id) and e.status='posted') then
    raise exception 'Linhas de lançamentos publicados são imutáveis; use estorno';
  end if;
  return coalesce(new,old);
end $$;

drop trigger if exists trg_prevent_posted_line_update on public.journal_lines;
create trigger trg_prevent_posted_line_update before update or delete on public.journal_lines
for each row execute function public.prevent_posted_line_mutation();

create or replace view public.trial_balance with (security_invoker=true) as
select e.company_id,a.id account_id,a.code,a.name,
       sum(l.debit) debit,sum(l.credit) credit,
       sum(l.debit-l.credit) balance
from public.journal_entries e
join public.journal_lines l on l.journal_entry_id=e.id
join public.chart_of_accounts a on a.id=l.account_id
where e.status='posted'
group by e.company_id,a.id,a.code,a.name;

create or replace view public.profit_and_loss with (security_invoker=true) as
select e.company_id,a.id account_id,a.code,a.name,a.account_type,
       sum(l.credit-l.debit) amount
from public.journal_entries e
join public.journal_lines l on l.journal_entry_id=e.id
join public.chart_of_accounts a on a.id=l.account_id
where e.status='posted' and a.account_type in ('revenue','expense','tax')
group by e.company_id,a.id,a.code,a.name,a.account_type;
