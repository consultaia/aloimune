-- ==========================================================================
-- O QUE A PACIENTE REALIZOU — registros manuais do Histórico da paciente
-- (procedimentos, exames, etapas do tratamento). Fica separado de
-- "atendimentos" para não gerar valor a faturar no Financeiro.
-- Pode rodar de novo sem problema.
-- ==========================================================================
create table if not exists public.clinica_realizados (
  id           uuid primary key default gen_random_uuid(),
  paciente_id  uuid not null references public.clinica_pacientes(id) on delete cascade,
  data         date not null default current_date,
  procedimento text not null,            -- ex.: "USG", "Reforço de Intralipid", "1ª etapa do tratamento"
  profissional text,
  obs          text,                     -- observação administrativa (nada clínico)
  criado_por   uuid default auth.uid(),
  criado_em    timestamptz not null default now()
);
create index if not exists clinica_realizados_pac_idx on public.clinica_realizados (paciente_id, data);

alter table public.clinica_realizados enable row level security;
drop policy if exists realizados_ler    on public.clinica_realizados;
drop policy if exists realizados_gravar on public.clinica_realizados;
create policy realizados_ler on public.clinica_realizados for select to authenticated
  using ( public.clinica_papel_atual() in ('gestor','auditoria','recepcionista','medico') );
create policy realizados_gravar on public.clinica_realizados for all to authenticated
  using ( public.clinica_papel_atual() in ('gestor','recepcionista','medico') )
  with check ( public.clinica_papel_atual() in ('gestor','recepcionista','medico') );
grant select, insert, update, delete on public.clinica_realizados to authenticated;

-- mesma auditoria das outras tabelas de pacientes (quem incluiu/apagou e quando)
drop trigger if exists tg_aud_realizados on public.clinica_realizados;
create trigger tg_aud_realizados after insert or update or delete on public.clinica_realizados
  for each row execute function public.clinica_tg_auditar();
