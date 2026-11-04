-- Carga horária mensal no cadastro do RH (colaboradores.carga_mensal).
-- Vazio = a pessoa usa a carga semanal (carga_horaria). Pode rodar de novo sem problema.
alter table public.colaboradores add column if not exists carga_mensal numeric;

-- traz o que já tinha sido marcado como h/mês na Escala (escala_estado.dados.cargaMensal)
update public.colaboradores c
   set carga_mensal = (e.dados->'cargaMensal'->>c.id::text)::numeric
  from public.escala_estado e
 where e.id = 1
   and c.carga_mensal is null
   and e.dados->'cargaMensal' ? c.id::text;
