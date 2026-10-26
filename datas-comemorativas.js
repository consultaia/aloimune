/* ==========================================================================
   DATAS IMPORTANTES — lista padrão ligada ao perfil da Aloimune (imunologia
   da reprodução, gestação, perda gestacional, fertilidade) + cálculo das
   datas móveis. Usado por datas.html e pela home da plataforma.
   Cada data: k (chave), t (título), c (categoria), e uma destas:
     d:"DD/MM"  dia fixo | m:mês (campanha do mês inteiro) | movel:"..."
   obs = observação que aparece embaixo do título.
   ========================================================================== */
(function(){
  const CATEGORIAS = [
    ["gestacao",  "Gestação e fertilidade"],
    ["profissao", "Profissões"],
    ["saude",     "Saúde"],
    ["campanha",  "Campanhas do mês"],
    ["comercial", "Datas comerciais"],
    ["clinica",   "Da clínica"],
  ];
  // quantos dias antes a plataforma começa a avisar (dá para mudar em cada data)
  const ANTECEDENCIA = { gestacao:20, profissao:15, saude:15, campanha:30, comercial:30, clinica:30 };

  const LISTA = [
    // gestação, fertilidade e perda gestacional
    { k:"perda-gestacional", t:"Dia Mundial de Conscientização sobre a Perda Gestacional e Neonatal", d:"15/10", c:"gestacao", obs:"Onda de Luz: velas acesas às 19h" },
    { k:"mes-perda-gestacional", t:"Outubro — mês de conscientização sobre a perda gestacional e neonatal", m:10, c:"gestacao", obs:"Data internacional" },
    { k:"bebe-arco-iris", t:"Dia do Bebê Arco-Íris", d:"22/08", c:"gestacao", obs:"Bebê que chega depois de uma perda gestacional — data internacional, não oficial" },
    { k:"gestante", t:"Dia da Gestante", d:"15/08", c:"gestacao", obs:"Semana Nacional de Cuidados com Gestantes e Mães (Lei 15.221/2025)" },
    { k:"maes", t:"Dia das Mães", movel:"maes", c:"gestacao", obs:"2º domingo de maio" },
    { k:"pais", t:"Dia dos Pais", movel:"pais", c:"gestacao", obs:"2º domingo de agosto" },
    { k:"fertilidade", t:"Dia Mundial da Fertilidade", d:"04/06", c:"gestacao", obs:"Comemorado principalmente na Espanha e na América Latina" },
    { k:"embriologista", t:"Dia Mundial do Embriologista", d:"25/07", c:"gestacao", obs:"Nascimento de Louise Brown, o 1º bebê de FIV (1978)" },
    { k:"prematuridade", t:"Dia Mundial da Prematuridade", d:"17/11", c:"gestacao" },
    { k:"mortalidade-materna", t:"Dia Internacional de Luta pela Saúde da Mulher e Dia Nacional de Redução da Mortalidade Materna", d:"28/05", c:"gestacao" },
    { k:"mulher", t:"Dia Internacional da Mulher", d:"08/03", c:"gestacao" },
    // profissões
    { k:"medico", t:"Dia do Médico", d:"18/10", c:"profissao" },
    { k:"gineco-obstetra", t:"Dia do Ginecologista e Obstetra", d:"30/10", c:"profissao", obs:"Fundação da Febrasgo (1959)" },
    { k:"obstetra", t:"Dia do Obstetra", d:"12/04", c:"profissao", obs:"Data popular, sem lei federal" },
    { k:"ultrassonografista", t:"Dia Nacional do Médico Ultrassonografista", d:"21/08", c:"profissao", obs:"Lei 14.964/2024" },
    { k:"enfermeiro", t:"Dia do Enfermeiro", d:"12/05", c:"profissao" },
    { k:"tec-enfermagem", t:"Dia do Técnico e Auxiliar de Enfermagem", d:"20/05", c:"profissao" },
    { k:"biomedico", t:"Dia do Biomédico", d:"20/11", c:"profissao" },
    { k:"psicologo", t:"Dia do Psicólogo", d:"27/08", c:"profissao" },
    { k:"nutricionista", t:"Dia do Nutricionista", d:"31/08", c:"profissao" },
    { k:"farmaceutico", t:"Dia do Farmacêutico", d:"20/01", c:"profissao" },
    { k:"fisioterapeuta", t:"Dia do Fisioterapeuta", d:"13/10", c:"profissao" },
    { k:"secretaria", t:"Dia da Secretária", d:"30/09", c:"profissao", obs:"Bom momento para homenagear a recepção" },
    { k:"professor", t:"Dia do Professor", d:"15/10", c:"profissao" },
    // saúde
    { k:"imunologia", t:"Dia Internacional da Imunologia", d:"29/04", c:"saude" },
    { k:"imunizacao", t:"Dia Nacional da Imunização", d:"09/06", c:"saude" },
    { k:"trombose", t:"Dia Mundial da Trombose", d:"13/10", c:"saude", obs:"Gancho para falar de trombofilia e gestação" },
    { k:"saude-mundial", t:"Dia Mundial da Saúde", d:"07/04", c:"saude" },
    { k:"saude-nacional", t:"Dia Nacional da Saúde", d:"05/08", c:"saude" },
    { k:"seguranca-paciente", t:"Dia Mundial da Segurança do Paciente", d:"17/09", c:"saude" },
    // campanhas do mês
    { k:"janeiro-branco", t:"Janeiro Branco — saúde mental", m:1, c:"campanha" },
    { k:"marco-amarelo", t:"Março Amarelo — endometriose", m:3, c:"campanha" },
    { k:"marco-lilas", t:"Março Lilás — câncer do colo do útero", m:3, c:"campanha" },
    { k:"agosto-dourado", t:"Agosto Dourado — aleitamento materno", m:8, c:"campanha" },
    { k:"setembro-amarelo", t:"Setembro Amarelo — prevenção do suicídio", m:9, c:"campanha" },
    { k:"outubro-rosa", t:"Outubro Rosa — câncer de mama", m:10, c:"campanha" },
    { k:"novembro-azul", t:"Novembro Azul — saúde do homem", m:11, c:"campanha", obs:"Gancho para fertilidade masculina" },
    { k:"novembro-roxo", t:"Novembro Roxo — prematuridade", m:11, c:"campanha" },
    { k:"dezembro-vermelho", t:"Dezembro Vermelho — HIV e ISTs", m:12, c:"campanha" },
    // datas comerciais
    { k:"ano-novo", t:"Ano Novo", d:"01/01", c:"comercial" },
    { k:"carnaval", t:"Carnaval", movel:"carnaval", c:"comercial" },
    { k:"pascoa", t:"Páscoa", movel:"pascoa", c:"comercial" },
    { k:"namorados", t:"Dia dos Namorados", d:"12/06", c:"comercial" },
    { k:"cliente", t:"Dia do Cliente", d:"15/09", c:"comercial" },
    { k:"criancas", t:"Dia das Crianças", d:"12/10", c:"comercial" },
    { k:"black-friday", t:"Black Friday", movel:"blackfriday", c:"comercial" },
    { k:"natal", t:"Natal", d:"25/12", c:"comercial" },
  ];

  const p2 = (n) => String(n).padStart(2, "0");
  const iso = (y, m, d) => y + "-" + p2(m) + "-" + p2(d);
  const ultimoDia = (y, m) => new Date(y, m, 0).getDate();
  // domingo de Páscoa (algoritmo de Meeus/Jones/Butcher)
  function pascoa(y){
    const a=y%19, b=Math.floor(y/100), c=y%100, d=Math.floor(b/4), e=b%4, f=Math.floor((b+8)/25), g=Math.floor((b-f+1)/3),
      h=(19*a+b-d-g+15)%30, i=Math.floor(c/4), k=c%4, l=(32+2*e+2*i-h-k)%7, m=Math.floor((a+11*h-22*l)/451),
      mes=Math.floor((h+l-7*m+114)/31), dia=((h+l-7*m+114)%31)+1;
    return new Date(y, mes-1, dia);
  }
  // n-ésimo dia da semana (0=domingo) do mês
  function nesimo(y, m, semana, n){ const p=new Date(y, m-1, 1); const off=(semana-p.getDay()+7)%7; return new Date(y, m-1, 1+off+7*(n-1)); }
  const isoDe = (dt) => iso(dt.getFullYear(), dt.getMonth()+1, dt.getDate());
  function movel(tipo, y){
    if(tipo==="pascoa") return isoDe(pascoa(y));
    if(tipo==="carnaval"){ const p=pascoa(y); return isoDe(new Date(y, p.getMonth(), p.getDate()-47)); } // terça de Carnaval
    if(tipo==="maes") return isoDe(nesimo(y, 5, 0, 2));
    if(tipo==="pais") return isoDe(nesimo(y, 8, 0, 2));
    if(tipo==="blackfriday"){ const q=nesimo(y, 11, 4, 4); return isoDe(new Date(y, 10, q.getDate()+1)); }
    return null;
  }

  // todas as datas padrão de um ano: [{ chave, titulo, data, fim, categoria, obs, antecedencia, padrao:true }]
  function padraoDoAno(y){
    return LISTA.map(x => {
      let data, fim=null;
      if(x.d){ const [dd, mm]=x.d.split("/").map(Number); data=iso(y, mm, dd); }
      else if(x.m){ data=iso(y, x.m, 1); fim=iso(y, x.m, ultimoDia(y, x.m)); }
      else data=movel(x.movel, y);
      return { chave:"p:"+x.k, titulo:x.t, data, fim, categoria:x.c, obs:x.obs||"", antecedencia:ANTECEDENCIA[x.c]||15, padrao:true };
    });
  }
  // datas cadastradas pela clínica: anual repete o dia/mês todo ano
  function cadastradasDoAno(y, lista){
    const r=[];
    (lista||[]).forEach(e => {
      if(!e.data) return;
      const [ay, am, ad] = e.data.split("-").map(Number);
      if(!e.anual && ay!==y) return;
      if(e.anual && ay>y) return;
      const dia = Math.min(ad, ultimoDia(y, am)); // 29/02 em ano não bissexto vira 28/02
      r.push({ chave:"c:"+e.id, id:e.id, titulo:e.titulo, data:iso(y, am, dia), fim:null, categoria:e.categoria||"clinica",
        obs:e.descricao||"", antecedencia:e.antecedencia==null ? (ANTECEDENCIA[e.categoria]||30) : Number(e.antecedencia),
        padrao:false, anual:!!e.anual, desde:ay });
    });
    return r;
  }
  // ajustes: { "p:medico": { oculta:true, antecedencia:20 } }
  function doAno(y, cadastradas, ajustes){
    ajustes = ajustes || {};
    return [...padraoDoAno(y), ...cadastradasDoAno(y, cadastradas)].map(e => {
      const a = ajustes[e.chave];
      return a ? { ...e, oculta:!!a.oculta, antecedencia: a.antecedencia==null ? e.antecedencia : Number(a.antecedencia) } : e;
    }).sort((a, b) => a.data.localeCompare(b.data) || a.titulo.localeCompare(b.titulo));
  }
  // dias entre hoje e a data (campanha do mês em andamento = 0)
  function diasAte(e, hojeIso){
    const t = (s) => new Date(s+"T12:00:00").getTime();
    if(e.fim && hojeIso>=e.data && hojeIso<=e.fim) return 0;
    return Math.round((t(e.data)-t(hojeIso))/864e5);
  }
  // próximas datas (inclui o ano seguinte para o fim de ano)
  function proximas(hojeIso, nDias, cadastradas, ajustes){
    const y = Number(hojeIso.slice(0, 4));
    return [...doAno(y, cadastradas, ajustes), ...doAno(y+1, cadastradas, ajustes)]
      .filter(e => !e.oculta)
      .map(e => ({ ...e, dias:diasAte(e, hojeIso) }))
      .filter(e => (e.fim ? e.fim>=hojeIso : e.dias>=0) && e.dias<=nDias)
      .sort((a, b) => a.dias-b.dias || a.titulo.localeCompare(b.titulo));
  }

  window.DATAS_CLINICA = { CATEGORIAS, ANTECEDENCIA, LISTA, doAno, proximas, diasAte, movel };
})();
