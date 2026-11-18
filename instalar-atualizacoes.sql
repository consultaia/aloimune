-- ==========================================================================
-- INSTALAR ATUALIZAÇÕES — tudo o que a plataforma passou a usar nas últimas
-- versões, num arquivo só. Pode rodar quantas vezes quiser: o que já existe
-- não é apagado nem duplicado. Depois rode verificar-banco.sql para conferir.
-- Inclui: acompanhamento-schema.sql, datas-schema.sql, carga-mensal.sql,
--         auditoria-fix.sql, realizados-schema.sql, ponto-tratados.sql,
--         forms-jornada.sql
-- ==========================================================================

-- ######## acompanhamento-schema.sql ########
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
--
-- Integração com o Google Forms: veja o fim deste arquivo e
-- google-forms-acompanhamento.gs (script para colar no formulário).
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
  values (new.id, coalesce(auth.uid(), new.criado_por), coalesce(public.acomp_nome(), new.criado_por_nome), 'criou');
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

-- ============================================================================
-- INTEGRAÇÃO COM O GOOGLE FORMS
-- Cada resposta enviada no Forms vira um acompanhamento aqui (situação vinda do
-- formulário, ou "Pendente"). O script do Forms chama acomp_receber_forms() com
-- uma senha secreta; sem a senha certa nada é gravado.
-- Para ver a senha (cole no script do Forms):
--   select valor from public.clinica_integracoes where chave = 'acomp_forms_segredo';
-- Para trocar a senha:
--   update public.clinica_integracoes set valor = replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')
--   where chave = 'acomp_forms_segredo';
-- ============================================================================

alter table public.clinica_acompanhamentos add column if not exists forms_resposta_id text;  -- evita duplicar a mesma resposta
create unique index if not exists clinica_acomp_forms_idx on public.clinica_acompanhamentos (forms_resposta_id);

-- guarda segredos de integração; RLS ligado e sem nenhuma policy = ninguém lê pela API
create table if not exists public.clinica_integracoes (
  chave     text primary key,
  valor     text not null,
  criado_em timestamptz not null default now()
);
alter table public.clinica_integracoes enable row level security;
revoke all on public.clinica_integracoes from anon, authenticated;
insert into public.clinica_integracoes (chave, valor)
  values ('acomp_forms_segredo', replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''))
on conflict (chave) do nothing;

create or replace function public.acomp_receber_forms(segredo text, dados jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id     uuid;
  v_pid    uuid;
  v_uid    uuid;
  v_nome   text;
  v_email  text := lower(nullif(trim(dados->>'email'), ''));
  v_pac    text := nullif(trim(regexp_replace(coalesce(dados->>'paciente', ''), '\s+', ' ', 'g')), '');
  v_resp   text := nullif(trim(regexp_replace(coalesce(dados->>'responsavel', ''), '\s+', ' ', 'g')), '');
  v_sit    text := coalesce(nullif(dados->>'situacao', ''), 'pendente');
  v_passos text[];
  v_rid    text := nullif(dados->>'resposta_id', '');
begin
  if segredo is null or not exists (select 1 from public.clinica_integracoes
                                    where chave = 'acomp_forms_segredo' and valor = segredo) then
    raise exception 'senha da integração inválida' using errcode = '28000';
  end if;
  if v_pac is null then raise exception 'resposta sem o nome da paciente'; end if;

  -- a mesma resposta reenviada não duplica
  if v_rid is not null then
    select id into v_id from public.clinica_acompanhamentos where forms_resposta_id = v_rid;
    if v_id is not null then return jsonb_build_object('ok', true, 'id', v_id, 'repetida', true); end if;
  end if;

  select coalesce(array_agg(distinct p), '{}') into v_passos
    from jsonb_array_elements_text(case when jsonb_typeof(dados->'passos') = 'array' then dados->'passos' else '[]'::jsonb end) p
   where p = any (array['etapa1','etapa2','etapa3','consulta','retorno','usg',
                        'reforco_crossmatch','reforco_intralipid','vacina','exames_pre','outro']);
  if v_sit not in ('pendente','em_andamento','concluido') then v_sit := 'pendente'; end if;

  -- quem respondeu (se o Forms coleta e-mail e a pessoa tem login na plataforma)
  if v_email is not null then
    select u.id, coalesce(nullif(pf.nome, ''), u.email) into v_uid, v_nome
      from auth.users u left join public.perfis pf on pf.id = u.id
     where lower(u.email) = v_email limit 1;
  end if;
  -- liga ao cadastro de pacientes pelo nome, se o módulo Pacientes existir
  if to_regclass('public.clinica_pacientes') is not null then
    execute 'select id from public.clinica_pacientes where lower(trim(nome)) = lower($1) limit 1' into v_pid using v_pac;
  end if;

  insert into public.clinica_acompanhamentos
    (paciente, paciente_id, telefone, data_consulta, proximos_passos, proximo_passo_outro, prazo, responsavel,
     situacao, observacoes, criado_por, criado_por_nome, criado_em, forms_resposta_id)
  values
    (v_pac, v_pid, nullif(trim(dados->>'telefone'), ''),
     case when dados->>'data_consulta' ~ '^\d{4}-\d{2}-\d{2}$' then (dados->>'data_consulta')::date end,
     v_passos,
     case when 'outro' = any (v_passos) then nullif(trim(dados->>'outro'), '') end,
     case when dados->>'prazo' ~ '^\d{4}-\d{2}-\d{2}$' then (dados->>'prazo')::date end,
     v_resp, v_sit, nullif(trim(dados->>'observacoes'), ''),
     v_uid, coalesce(v_nome, v_email, 'Equipe') || ' · via Forms',
     coalesce(case when dados->>'enviado_em' ~ '^\d{4}-\d{2}-\d{2}T' then (dados->>'enviado_em')::timestamptz end, now()),
     v_rid)
  returning id into v_id;

  if v_resp is not null then
    insert into public.clinica_acompanhamento_responsaveis (nome) values (v_resp) on conflict do nothing;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

revoke all on function public.acomp_receber_forms(text, jsonb) from public;
grant execute on function public.acomp_receber_forms(text, jsonb) to anon, authenticated;

-- ######## datas-schema.sql ########
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

-- ######## carga-mensal.sql ########
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

-- ######## auditoria-fix.sql ########
-- Auditoria de pacientes: a mesma função serve pacientes, evoluções e procedimentos realizados.
-- Lê o registro como JSON para não quebrar em tabelas sem a coluna paciente_id
-- (antes dava "record old has no field paciente_id" ao salvar paciente).
create or replace function public.clinica_tg_auditar()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  reg jsonb;
  rid text;
begin
  reg := case when TG_OP = 'DELETE' then to_jsonb(OLD) else to_jsonb(NEW) end;
  rid := coalesce(reg->>'id', '');
  insert into public.clinica_auditoria (usuario_id, papel, acao, tabela, registro_id, detalhe)
  values (auth.uid(), public.clinica_papel_atual(), lower(TG_OP), TG_TABLE_NAME, rid,
          case when TG_TABLE_NAME = 'clinica_evolucoes'
               then 'paciente=' || coalesce(reg->>'paciente_id', '') end);
  if TG_OP = 'DELETE' then return OLD; end if;
  return NEW;
end $function$;

-- ######## realizados-schema.sql ########
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

-- ######## ponto-tratados.sql ########
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

-- ######## forms-jornada.sql ########
-- ==========================================================================
-- FORMS → JORNADA DA PACIENTE
-- Cada acompanhamento pós-consulta (do Google Forms ou digitado na plataforma):
--   1. é ligado à paciente certa: primeiro pelo telefone, depois pelo nome sem
--      acento/maiúsculas/espaços; se não achar e houver telefone ou nome
--      completo, cria o cadastro da paciente ("veio do Forms");
--   2. cada próximo passo vira uma pendência da paciente, com o prazo do Forms;
--      concluir o acompanhamento conclui as pendências, e concluir todas as
--      pendências conclui o acompanhamento.
-- Também liga e gera as pendências dos acompanhamentos que já existem.
-- Pode rodar de novo sem problema. Precisa de acompanhamento-schema.sql antes.
-- ==========================================================================

alter table public.clinica_pendencias add column if not exists acompanhamento_id uuid;
create index if not exists clinica_pend_acomp_idx on public.clinica_pendencias (acompanhamento_id);

-- nome sem acento, minúsculo, espaços simples
create or replace function public.acomp_norm(t text) returns text
language sql immutable as $$
  select trim(regexp_replace(translate(lower(coalesce(t,'')),
    'áàâãäéèêëíìîïóòôõöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn'), '\s+', ' ', 'g'))
$$;
-- últimos 8 dígitos do telefone (ignora 55, DDD, 9 extra e pontuação)
create or replace function public.acomp_tel(t text) returns text
language sql immutable as $$
  select nullif(right(regexp_replace(coalesce(t,''), '\D', '', 'g'), 8), '')
$$;

-- etapa da jornada que o próximo passo sugere
create or replace function public.acomp_etapa_sugerida(passos text[]) returns text
language sql immutable as $$
  select case
    when passos && array['etapa1','etapa2','etapa3','reforco_crossmatch','reforco_intralipid','vacina'] then 'tratamento'
    when passos && array['exames_pre','usg'] then 'aguardando_resultados'
    when passos && array['retorno'] then 'retorno'
    when passos && array['consulta'] then 'investigacao'
    else null end
$$;

-- acha (ou cria) a paciente do acompanhamento
create or replace function public.acomp_vincular_paciente(p_nome text, p_tel text, p_passos text[]) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_n int; v_tel text := public.acomp_tel(p_tel); v_nome text := public.acomp_norm(p_nome);
begin
  if v_nome = '' and v_tel is null then return null; end if;
  -- 1) telefone (se mais de uma paciente no mesmo telefone, desempata pelo nome)
  if v_tel is not null and length(v_tel) = 8 then
    select count(*) into v_n from clinica_pacientes where coalesce(ativo,true) and public.acomp_tel(telefone) = v_tel;
    if v_n = 1 then
      select id into v_id from clinica_pacientes where coalesce(ativo,true) and public.acomp_tel(telefone) = v_tel;
      return v_id;
    elsif v_n > 1 then
      select id into v_id from clinica_pacientes
       where coalesce(ativo,true) and public.acomp_tel(telefone) = v_tel
         and (public.acomp_norm(nome) = v_nome or split_part(public.acomp_norm(nome),' ',1) = split_part(v_nome,' ',1))
       order by (public.acomp_norm(nome) = v_nome) desc limit 1;
      if v_id is not null then return v_id; end if;
    end if;
  end if;
  -- 2) nome igual (sem acento/maiúsculas/espaços), se for único
  if v_nome <> '' then
    select count(*) into v_n from clinica_pacientes where coalesce(ativo,true) and public.acomp_norm(nome) = v_nome;
    if v_n = 1 then
      select id into v_id from clinica_pacientes where coalesce(ativo,true) and public.acomp_norm(nome) = v_nome;
      return v_id;
    elsif v_n > 1 then
      return null;   -- duas pacientes com o mesmo nome: a equipe vincula na mão
    end if;
  end if;
  -- 3) não achou: cria o cadastro, se houver telefone ou nome completo (evita duplicar por "Ana")
  if v_tel is null and position(' ' in v_nome) = 0 then return null; end if;
  insert into clinica_pacientes (nome, telefone, etapa, obs_adm)
  values (trim(regexp_replace(p_nome, '\s+', ' ', 'g')), nullif(trim(p_tel), ''),
          coalesce(public.acomp_etapa_sugerida(p_passos), 'investigacao'),
          'Cadastro criado automaticamente pelo acompanhamento pós-consulta (Forms). Confira os dados.')
  returning id into v_id;
  return v_id;
end $$;

-- antes de gravar: liga à paciente
create or replace function public.acomp_tg_vincular() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.paciente_id is null and coalesce(new.ativo, true) then
    new.paciente_id := public.acomp_vincular_paciente(new.paciente, new.telefone, new.proximos_passos);
  end if;
  return new;
end $$;
drop trigger if exists acomp_vincular on public.clinica_acompanhamentos;
create trigger acomp_vincular before insert or update of paciente, telefone, paciente_id on public.clinica_acompanhamentos
  for each row execute function public.acomp_tg_vincular();

-- depois de gravar: próximos passos ↔ pendências da paciente
create or replace function public.acomp_sync_pendencias(a public.clinica_acompanhamentos) returns void
language plpgsql security definer set search_path = public as $$
declare
  p text;
  nomes jsonb := '{"etapa1":"1ª etapa do tratamento","etapa2":"2ª etapa do tratamento","etapa3":"3ª etapa do tratamento",
    "consulta":"Consulta","retorno":"Retorno","usg":"USG","reforco_crossmatch":"Reforço de Crossmatch",
    "reforco_intralipid":"Reforço de Intralipid","vacina":"Vacina","exames_pre":"Exames pré-tratamento","outro":"Outro"}';
  desc_ text; tipo_ text;
begin
  if a.paciente_id is null then return; end if;
  -- acompanhamento apagado/inativo: cancela o que estava aberto
  if not coalesce(a.ativo, true) then
    update clinica_pendencias set status = 'cancelada', concluida_em = now()
     where acompanhamento_id = a.id and status = 'aberta';
    return;
  end if;
  -- concluído: conclui as pendências abertas
  if a.situacao = 'concluido' then
    update clinica_pendencias set status = 'concluida', concluida_em = coalesce(a.concluido_em, now())
     where acompanhamento_id = a.id and status = 'aberta';
    return;
  end if;
  -- aberto: uma pendência por próximo passo (mesma paciente e prazo do acompanhamento)
  foreach p in array coalesce(a.proximos_passos, '{}') loop
    desc_ := 'Pós-consulta: ' || case when p = 'outro' and a.proximo_passo_outro is not null then a.proximo_passo_outro else coalesce(nomes->>p, p) end;
    tipo_ := case when p in ('retorno','consulta') then 'retorno' when p in ('exames_pre','usg') then 'exame_solicitado' else 'outro' end;
    if exists (select 1 from clinica_pendencias where acompanhamento_id = a.id and descricao = desc_) then
      update clinica_pendencias set paciente_id = a.paciente_id, vencimento = a.prazo,
             status = case when status = 'concluida' and a.situacao <> 'concluido' then 'aberta' else status end,
             concluida_em = case when status = 'concluida' and a.situacao <> 'concluido' then null else concluida_em end
       where acompanhamento_id = a.id and descricao = desc_;
    else
      insert into clinica_pendencias (paciente_id, tipo, descricao, vencimento, status, acompanhamento_id)
      values (a.paciente_id, tipo_, desc_, a.prazo, 'aberta', a.id);
    end if;
  end loop;
  -- passos que saíram do acompanhamento: cancela a pendência aberta
  update clinica_pendencias set status = 'cancelada', concluida_em = now()
   where acompanhamento_id = a.id and status = 'aberta'
     and descricao not in (select 'Pós-consulta: ' || case when x = 'outro' and a.proximo_passo_outro is not null then a.proximo_passo_outro else coalesce(nomes->>x, x) end
                             from unnest(coalesce(a.proximos_passos, '{}')) x);
end $$;

create or replace function public.acomp_tg_pendencias() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if pg_trigger_depth() > 2 then return new; end if;   -- evita laço com a sincronização de volta
  perform public.acomp_sync_pendencias(new);
  return new;
end $$;
drop trigger if exists acomp_pendencias on public.clinica_acompanhamentos;
create trigger acomp_pendencias after insert or update on public.clinica_acompanhamentos
  for each row execute function public.acomp_tg_pendencias();

-- pendência concluída na tela de Pacientes: se todas daquele acompanhamento fecharam, conclui o acompanhamento
create or replace function public.acomp_tg_pend_volta() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if pg_trigger_depth() > 1 or new.acompanhamento_id is null or new.status = 'aberta' then return new; end if;
  if not exists (select 1 from clinica_pendencias where acompanhamento_id = new.acompanhamento_id and status = 'aberta') then
    update clinica_acompanhamentos set situacao = 'concluido'
     where id = new.acompanhamento_id and situacao <> 'concluido'
       and exists (select 1 from clinica_pendencias where acompanhamento_id = new.acompanhamento_id and status = 'concluida');
  end if;
  return new;
end $$;
drop trigger if exists acomp_pend_volta on public.clinica_pendencias;
create trigger acomp_pend_volta after update of status on public.clinica_pendencias
  for each row execute function public.acomp_tg_pend_volta();

-- acompanhamentos que já existem: liga à paciente e gera as pendências dos que estão em aberto
update public.clinica_acompanhamentos set paciente_id = null
 where paciente_id is null and coalesce(ativo, true);   -- dispara a ligação (gatilho "before update of paciente_id")
do $$
declare a public.clinica_acompanhamentos;
begin
  for a in select * from public.clinica_acompanhamentos where paciente_id is not null and coalesce(ativo,true) and situacao <> 'concluido' loop
    perform public.acomp_sync_pendencias(a);
  end loop;
end $$;

notify pgrst, 'reload schema';
