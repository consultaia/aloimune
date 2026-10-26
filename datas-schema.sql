-- ==========================================================================
-- DATAS E EVENTOS — calendário de datas importantes da clínica (datas.html)
-- As datas padrão (Dia do Médico, perda gestacional, campanhas...) ficam no
-- arquivo datas-comemorativas.js; aqui ficam só:
--   • clinica_datas          datas/eventos cadastrados pela clínica
--   • clinica_datas_ajustes  data padrão ocultada ou com outro aviso
--   • clinica_datas_plano    plano de cada data em cada ano (situação + ideias)
-- Pode rodar de novo sem problema. Usa acomp_papel() (acompanhamento-schema.sql).
-- ==========================================================================

create or replace function public.acomp_papel() returns text
language sql stable security definer set search_path = public as $$
  select papel from public.perfis where id = auth.uid()
$$;

create table if not exists public.clinica_datas (
  id           uuid primary key default gen_random_uuid(),
  titulo       text not null,
  data         date not null,
  anual        boolean not null default true,     -- repete todo ano no mesmo dia
  categoria    text not null default 'clinica',
  antecedencia int,                               -- avisar quantos dias antes (vazio = padrão da categoria)
  descricao    text,
  criado_por   uuid default auth.uid(),
  criado_em    timestamptz not null default now()
);

create table if not exists public.clinica_datas_ajustes (
  chave        text primary key,                  -- 'p:medico'
  oculta       boolean not null default false,
  antecedencia int,
  atualizado_em timestamptz not null default now()
);

create table if not exists public.clinica_datas_plano (
  chave        text not null,                     -- 'p:medico' ou 'c:<id da clinica_datas>'
  ano          int  not null,
  status       text not null default 'planejar' check (status in ('planejar','producao','pronto','publicado','nao_vamos')),
  notas        text,
  atualizado_em timestamptz not null default now(),
  atualizado_por uuid default auth.uid(),
  primary key (chave, ano)
);

alter table public.clinica_datas         enable row level security;
alter table public.clinica_datas_ajustes enable row level security;
alter table public.clinica_datas_plano   enable row level security;

do $$
declare t text;
begin
  foreach t in array array['clinica_datas','clinica_datas_ajustes','clinica_datas_plano'] loop
    execute format('drop policy if exists datas_ler on public.%I', t);
    execute format('drop policy if exists datas_gravar on public.%I', t);
    -- toda a equipe logada vê; quem não é quiosque pode cadastrar e planejar
    execute format($p$create policy datas_ler on public.%I for select to authenticated
      using ( public.acomp_papel() in ('gestor','auditoria','recepcionista','medico','funcionario') )$p$, t);
    execute format($p$create policy datas_gravar on public.%I for all to authenticated
      using ( public.acomp_papel() in ('gestor','recepcionista','medico','funcionario') )
      with check ( public.acomp_papel() in ('gestor','recepcionista','medico','funcionario') )$p$, t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
  end loop;
end $$;
