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
