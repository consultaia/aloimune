-- ============================================================================
-- TRIAGEM — fichas de triagem/acompanhamento (substitui o Google Forms)
-- Rode no Supabase (SQL Editor), no mesmo projeto dos outros módulos.
-- Pode rodar de novo sem problema (idempotente).
--
-- Quem faz o quê (garantido pelo banco, RLS):
--   • gestor ............ vê, cria, edita e arquiva todas as fichas
--   • auditoria ......... vê todas (só leitura)
--   • recepcionista/medico vê todas, cria fichas e edita todas
--   • funcionario ....... cria fichas e vê/edita só as que ele mesmo digitou
--   • toda alteração fica registrada em triagem_historico (quem, quando, o quê)
-- ============================================================================

create table if not exists public.triagem_fichas (
  id               uuid primary key default gen_random_uuid(),
  criado_em        timestamptz not null default now(),
  criado_por       uuid default auth.uid(),
  criado_por_nome  text,
  atualizado_em    timestamptz not null default now(),
  atualizado_por   uuid,
  campanha         text,                       -- ex.: "Mutirão Vitória da Conquista"
  data_triagem     date not null default current_date,
  nome             text not null,
  nascimento       date,
  raca_cor         text,
  prontuario       text,
  telefone         text,
  queixas          text[] not null default '{}',
  queixa_outra     text,
  comorbidades     text[] not null default '{}',
  comorbidade_outra text,
  peso             numeric(5,1),
  altura           numeric(3,2),
  imc              numeric(4,1),
  pa               text,                       -- pressão arterial, ex.: 120x80
  menarca          text,                       -- idade da primeira menstruação
  gestacoes        int,
  abortos          int,
  menopausa        text,
  exames           jsonb not null default '{}', -- { "hemoglobina": "13,6", "ecg": "Normal", ... }
  status           text not null default 'triada'
                   check (status in ('triada','aguardando_exames','apta','inapta','agendada','operada','alta','desistiu')),
  data_cirurgia    date,
  proximo_contato  date,                       -- data combinada para o próximo retorno/ligação
  observacoes      text,
  ativo            boolean not null default true
);

create index if not exists triagem_fichas_status_idx   on public.triagem_fichas (status) where ativo;
create index if not exists triagem_fichas_campanha_idx on public.triagem_fichas (campanha);
create index if not exists triagem_fichas_criado_idx   on public.triagem_fichas (criado_por);

create table if not exists public.triagem_historico (
  id        bigserial primary key,
  ficha_id  uuid not null references public.triagem_fichas(id) on delete cascade,
  quando    timestamptz not null default now(),
  quem      uuid default auth.uid(),
  quem_nome text,
  acao      text not null,      -- 'criou' | 'editou'
  campos    jsonb               -- { "status": ["triada","apta"], ... }  (antes, depois)
);
create index if not exists triagem_historico_ficha_idx on public.triagem_historico (ficha_id, quando desc);

-- papel de quem está logado (lido de perfis, sem esbarrar no RLS de perfis)
create or replace function public.triagem_papel() returns text
language sql stable security definer set search_path = public as $$
  select papel from public.perfis where id = auth.uid()
$$;

create or replace function public.triagem_nome() returns text
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(p.nome,''), u.email)
  from auth.users u left join public.perfis p on p.id = u.id
  where u.id = auth.uid()
$$;

-- carimbos de quem criou/alterou + histórico
create or replace function public.triagem_fichas_carimbo() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  dif jsonb := '{}';
  k text;
begin
  if tg_op = 'INSERT' then
    new.criado_por      := coalesce(auth.uid(), new.criado_por);
    new.criado_por_nome := coalesce(public.triagem_nome(), new.criado_por_nome);
    new.criado_em       := coalesce(new.criado_em, now());
    new.atualizado_em   := now();
    new.atualizado_por  := auth.uid();
    return new;
  end if;
  -- UPDATE: autoria original não pode ser trocada
  new.criado_por      := old.criado_por;
  new.criado_por_nome := old.criado_por_nome;
  new.criado_em       := old.criado_em;
  new.atualizado_em   := now();
  new.atualizado_por  := auth.uid();
  for k in select jsonb_object_keys(to_jsonb(new)) loop
    if k not in ('atualizado_em','atualizado_por')
       and (to_jsonb(new) -> k) is distinct from (to_jsonb(old) -> k) then
      dif := dif || jsonb_build_object(k, jsonb_build_array(to_jsonb(old) -> k, to_jsonb(new) -> k));
    end if;
  end loop;
  if dif <> '{}' then
    insert into public.triagem_historico (ficha_id, quem, quem_nome, acao, campos)
    values (new.id, auth.uid(), public.triagem_nome(), 'editou', dif);
  end if;
  return new;
end $$;

create or replace function public.triagem_fichas_criada() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.triagem_historico (ficha_id, quem, quem_nome, acao)
  values (new.id, auth.uid(), public.triagem_nome(), 'criou');
  return new;
end $$;

drop trigger if exists triagem_fichas_carimbo on public.triagem_fichas;
create trigger triagem_fichas_carimbo before insert or update on public.triagem_fichas
  for each row execute function public.triagem_fichas_carimbo();

drop trigger if exists triagem_fichas_criada on public.triagem_fichas;
create trigger triagem_fichas_criada after insert on public.triagem_fichas
  for each row execute function public.triagem_fichas_criada();

-- ---------------------------------------------------------------- RLS
alter table public.triagem_fichas    enable row level security;
alter table public.triagem_historico enable row level security;

drop policy if exists triagem_fichas_ler     on public.triagem_fichas;
drop policy if exists triagem_fichas_criar   on public.triagem_fichas;
drop policy if exists triagem_fichas_editar  on public.triagem_fichas;
drop policy if exists triagem_fichas_apagar  on public.triagem_fichas;
drop policy if exists triagem_historico_ler  on public.triagem_historico;

create policy triagem_fichas_ler on public.triagem_fichas for select to authenticated
  using ( public.triagem_papel() in ('gestor','auditoria','recepcionista','medico')
          or (public.triagem_papel() = 'funcionario' and criado_por = auth.uid()) );

create policy triagem_fichas_criar on public.triagem_fichas for insert to authenticated
  with check ( public.triagem_papel() in ('gestor','recepcionista','medico','funcionario') );

create policy triagem_fichas_editar on public.triagem_fichas for update to authenticated
  using ( public.triagem_papel() in ('gestor','recepcionista','medico')
          or (public.triagem_papel() = 'funcionario' and criado_por = auth.uid()) )
  with check ( public.triagem_papel() in ('gestor','recepcionista','medico')
          or (public.triagem_papel() = 'funcionario' and criado_por = auth.uid()) );

create policy triagem_fichas_apagar on public.triagem_fichas for delete to authenticated
  using ( public.triagem_papel() = 'gestor' );

create policy triagem_historico_ler on public.triagem_historico for select to authenticated
  using ( exists (select 1 from public.triagem_fichas f where f.id = triagem_historico.ficha_id) );  -- herda o RLS da ficha

grant select, insert, update, delete on public.triagem_fichas to authenticated;
grant select on public.triagem_historico to authenticated;
