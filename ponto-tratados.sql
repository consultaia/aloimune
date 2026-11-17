-- ==========================================================================
-- PONTO — dias já tratados (conferidos) no Espelho.
-- Um dia de um funcionário marcado como tratado sai de "A tratar" e vai para
-- "Tratados". Pode rodar de novo sem problema.
-- ==========================================================================
create or replace function public.acomp_papel() returns text
language sql stable security definer set search_path = public as $$
  select papel from public.perfis where id = auth.uid()
$$;

create table if not exists public.ponto_tratados (
  colaborador_id text not null,
  dia            date not null,
  tratado_por    uuid default auth.uid(),
  tratado_em     timestamptz not null default now(),
  primary key (colaborador_id, dia)
);

alter table public.ponto_tratados enable row level security;
drop policy if exists ponto_tratados_ler    on public.ponto_tratados;
drop policy if exists ponto_tratados_gravar on public.ponto_tratados;
create policy ponto_tratados_ler on public.ponto_tratados for select to authenticated
  using ( public.acomp_papel() in ('gestor','auditoria') );
create policy ponto_tratados_gravar on public.ponto_tratados for all to authenticated
  using ( public.acomp_papel() = 'gestor' ) with check ( public.acomp_papel() = 'gestor' );
grant select, insert, delete on public.ponto_tratados to authenticated;
