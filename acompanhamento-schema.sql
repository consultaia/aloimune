-- ============================================================================
-- ACOMPANHAMENTO PÓS-CONSULTA (substitui o Google Forms "ALOIMUNE |
-- ACOMPANHAMENTO PÓS-CONSULTA").
-- Rode no Supabase (SQL Editor), no mesmo projeto dos outros módulos.
-- Pode rodar de novo sem problema (idempotente).
--
-- Quem faz o quê (garantido pelo banco, RLS):
--   • gestor ................ vê, cria, edita e arquiva todos
--   • auditoria ............. vê todos (só leitura)
--   • recepcionista / medico  vê, cria e edita todos
--   • funcionario ........... cria e vê/edita só os que ele mesmo registrou
--   • toda alteração fica em clinica_acompanhamentos_historico (quem, quando, o quê)
--   • a lista de nomes da caixa "Responsável pelo contato" fica em
--     clinica_acompanhamento_responsaveis (a equipe coloca e tira nomes)
--
-- Atualização (out/2026): "próximo passo" passou a aceitar vários. Quem já tinha
-- rodado a versão anterior só precisa rodar este arquivo de novo — os dados de
-- proximo_passo são copiados para proximos_passos automaticamente.
-- ============================================================================

create table if not exists public.clinica_acompanhamentos (
  id                   uuid primary key default gen_random_uuid(),
  criado_em            timestamptz not null default now(),
  criado_por           uuid default auth.uid(),
  criado_por_nome      text,
  atualizado_em        timestamptz not null default now(),
  atualizado_por       uuid,
  paciente_id          uuid,                 -- liga a clinica_pacientes quando a paciente já está cadastrada
  paciente             text not null,
  telefone             text,
  data_consulta        date,
  proximos_passos      text[] not null default '{}',   -- vários: {etapa1, usg, ...}
  proximo_passo_outro  text,
  prazo                date,                 -- prazo para acompanhamento
  responsavel          text,                 -- responsável pelo contato
  situacao             text not null default 'pendente'
                       check (situacao in ('pendente','em_andamento','concluido')),
  concluido_em         timestamptz,
  observacoes          text,
  ativo                boolean not null default true
);

-- migração da versão com um único próximo passo
alter table public.clinica_acompanhamentos add column if not exists proximos_passos text[] not null default '{}';
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'clinica_acompanhamentos' and column_name = 'proximo_passo') then
    drop trigger if exists acomp_carimbo on public.clinica_acompanhamentos;   -- recriado abaixo; evita poluir o histórico
    update public.clinica_acompanhamentos
       set proximos_passos = array[proximo_passo]
     where proximo_passo is not null and cardinality(proximos_passos) = 0;
    alter table public.clinica_acompanhamentos drop column proximo_passo;
  end if;
end $$;

alter table public.clinica_acompanhamentos drop constraint if exists clinica_acomp_passos_check;
alter table public.clinica_acompanhamentos add constraint clinica_acomp_passos_check
  check (proximos_passos <@ array['etapa1','etapa2','etapa3','consulta','retorno','usg',
                                  'reforco_crossmatch','reforco_intralipid','vacina','exames_pre','outro']::text[]);

create index if not exists clinica_acomp_situacao_idx on public.clinica_acompanhamentos (situacao, prazo) where ativo;
create index if not exists clinica_acomp_paciente_idx on public.clinica_acompanhamentos (paciente_id);
create index if not exists clinica_acomp_criado_idx   on public.clinica_acompanhamentos (criado_por);

create table if not exists public.clinica_acompanhamentos_historico (
  id               bigserial primary key,
  acompanhamento_id uuid not null references public.clinica_acompanhamentos(id) on delete cascade,
  quando           timestamptz not null default now(),
  quem             uuid default auth.uid(),
  quem_nome        text,
  acao             text not null,     -- 'criou' | 'editou'
  campos           jsonb              -- { "situacao": ["pendente","concluido"], ... }  (antes, depois)
);
create index if not exists clinica_acomp_hist_idx on public.clinica_acompanhamentos_historico (acompanhamento_id, quando desc);

-- nomes que aparecem na caixa "Responsável pelo contato"
create table if not exists public.clinica_acompanhamento_responsaveis (
  nome      text primary key,
  criado_em timestamptz not null default now()
);
insert into public.clinica_acompanhamento_responsaveis (nome)
  select distinct trim(responsavel) from public.clinica_acompanhamentos
  where coalesce(trim(responsavel), '') <> ''
on conflict do nothing;

-- papel e nome de quem está logado (lidos de perfis sem esbarrar no RLS de perfis)
create or replace function public.acomp_papel() returns text
language sql stable security definer set search_path = public as $$
  select papel from public.perfis where id = auth.uid()
$$;

create or replace function public.acomp_nome() returns text
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(p.nome,''), u.email)
  from auth.users u left join public.perfis p on p.id = u.id
  where u.id = auth.uid()
$$;

-- carimbos de autoria, data de conclusão e histórico
create or replace function public.acomp_carimbo() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  dif jsonb := '{}';
  k text;
begin
  if tg_op = 'INSERT' then
    new.criado_por      := coalesce(auth.uid(), new.criado_por);
    new.criado_por_nome := coalesce(public.acomp_nome(), new.criado_por_nome);
    new.atualizado_em   := now();
    new.atualizado_por  := auth.uid();
    new.concluido_em    := case when new.situacao = 'concluido' then now() end;
    return new;
  end if;
  -- UPDATE: autoria original não pode ser trocada
  new.criado_por      := old.criado_por;
  new.criado_por_nome := old.criado_por_nome;
  new.criado_em       := old.criado_em;
  new.atualizado_em   := now();
  new.atualizado_por  := auth.uid();
  if new.situacao = 'concluido' and old.situacao <> 'concluido' then new.concluido_em := now();
  elsif new.situacao <> 'concluido' then new.concluido_em := null;
  else new.concluido_em := old.concluido_em; end if;
  for k in select jsonb_object_keys(to_jsonb(new)) loop
    if k not in ('atualizado_em','atualizado_por','concluido_em')
       and (to_jsonb(new) -> k) is distinct from (to_jsonb(old) -> k) then
      dif := dif || jsonb_build_object(k, jsonb_build_array(to_jsonb(old) -> k, to_jsonb(new) -> k));
    end if;
  end loop;
  if dif <> '{}' then
    insert into public.clinica_acompanhamentos_historico (acompanhamento_id, quem, quem_nome, acao, campos)
    values (new.id, auth.uid(), public.acomp_nome(), 'editou', dif);
  end if;
  return new;
end $$;

create or replace function public.acomp_criado() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.clinica_acompanhamentos_historico (acompanhamento_id, quem, quem_nome, acao)
  values (new.id, auth.uid(), public.acomp_nome(), 'criou');
  return new;
end $$;

drop trigger if exists acomp_carimbo on public.clinica_acompanhamentos;
create trigger acomp_carimbo before insert or update on public.clinica_acompanhamentos
  for each row execute function public.acomp_carimbo();

drop trigger if exists acomp_criado on public.clinica_acompanhamentos;
create trigger acomp_criado after insert on public.clinica_acompanhamentos
  for each row execute function public.acomp_criado();

-- ---------------------------------------------------------------- RLS
alter table public.clinica_acompanhamentos           enable row level security;
alter table public.clinica_acompanhamentos_historico enable row level security;
alter table public.clinica_acompanhamento_responsaveis enable row level security;

drop policy if exists acomp_ler      on public.clinica_acompanhamentos;
drop policy if exists acomp_criar    on public.clinica_acompanhamentos;
drop policy if exists acomp_editar   on public.clinica_acompanhamentos;
drop policy if exists acomp_apagar   on public.clinica_acompanhamentos;
drop policy if exists acomp_hist_ler on public.clinica_acompanhamentos_historico;
drop policy if exists acomp_resp_ler    on public.clinica_acompanhamento_responsaveis;
drop policy if exists acomp_resp_criar  on public.clinica_acompanhamento_responsaveis;
drop policy if exists acomp_resp_apagar on public.clinica_acompanhamento_responsaveis;

create policy acomp_ler on public.clinica_acompanhamentos for select to authenticated
  using ( public.acomp_papel() in ('gestor','auditoria','recepcionista','medico')
          or (public.acomp_papel() = 'funcionario' and criado_por = auth.uid()) );

create policy acomp_criar on public.clinica_acompanhamentos for insert to authenticated
  with check ( public.acomp_papel() in ('gestor','recepcionista','medico','funcionario') );

create policy acomp_editar on public.clinica_acompanhamentos for update to authenticated
  using ( public.acomp_papel() in ('gestor','recepcionista','medico')
          or (public.acomp_papel() = 'funcionario' and criado_por = auth.uid()) )
  with check ( public.acomp_papel() in ('gestor','recepcionista','medico')
          or (public.acomp_papel() = 'funcionario' and criado_por = auth.uid()) );

create policy acomp_apagar on public.clinica_acompanhamentos for delete to authenticated
  using ( public.acomp_papel() = 'gestor' );

create policy acomp_hist_ler on public.clinica_acompanhamentos_historico for select to authenticated
  using ( exists (select 1 from public.clinica_acompanhamentos a
                  where a.id = clinica_acompanhamentos_historico.acompanhamento_id) );  -- herda o RLS do acompanhamento

create policy acomp_resp_ler on public.clinica_acompanhamento_responsaveis for select to authenticated
  using ( public.acomp_papel() in ('gestor','auditoria','recepcionista','medico','funcionario') );
create policy acomp_resp_criar on public.clinica_acompanhamento_responsaveis for insert to authenticated
  with check ( public.acomp_papel() in ('gestor','recepcionista','medico','funcionario') );
create policy acomp_resp_apagar on public.clinica_acompanhamento_responsaveis for delete to authenticated
  using ( public.acomp_papel() in ('gestor','recepcionista','medico','funcionario') );

grant select, insert, update, delete on public.clinica_acompanhamentos to authenticated;
grant select, insert, delete on public.clinica_acompanhamento_responsaveis to authenticated;
grant select on public.clinica_acompanhamentos_historico to authenticated;
