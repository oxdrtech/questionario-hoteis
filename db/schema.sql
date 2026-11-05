-- Banco: capitacao_hoteis
-- Rode este arquivo uma vez, conectado ao banco capitacao_hoteis.
-- Pode rodar de novo sem problema: nada é apagado.

-- =========================================================
-- LEADS: hotéis captados pelo n8n (capitacao-hoteis.json)
-- =========================================================
CREATE TABLE IF NOT EXISTS leads (
  place_id        TEXT PRIMARY KEY,         -- id do Google Maps; é o "lead" que vai no link da entrevista
  nome            TEXT NOT NULL,
  cidade          TEXT,
  uf              CHAR(2),
  endereco        TEXT,
  telefone        TEXT,
  whatsapp        TEXT,
  site            TEXT,
  nota            NUMERIC(2,1),
  avaliacoes      INTEGER,
  maps            TEXT,
  score           SMALLINT NOT NULL DEFAULT 0,
  motivos         TEXT,
  link_entrevista TEXT,
  status          TEXT NOT NULL DEFAULT 'Novo',  -- Novo, Contatado, Entrevistado, Descartado...
  temperatura     TEXT,
  proximo_passo   TEXT,
  data_retorno    DATE,
  capturado_em    TIMESTAMPTZ NOT NULL DEFAULT now(),
  atualizado_em   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS leads_status_idx ON leads (status);
CREATE INDEX IF NOT EXISTS leads_cidade_idx ON leads (uf, cidade);
CREATE INDEX IF NOT EXISTS leads_score_idx  ON leads (score DESC);

-- =========================================================
-- ENTREVISTAS: respostas do questionário (index.html)
-- =========================================================
CREATE TABLE IF NOT EXISTS entrevistas (
  id             BIGSERIAL PRIMARY KEY,
  place_id       TEXT REFERENCES leads(place_id) ON DELETE SET NULL, -- preenchido se o id_lead existir em leads
  entrevista_em  TIMESTAMPTZ NOT NULL,     -- hora em que o formulário foi salvo no aparelho

  -- Etapa 1: sobre a hospedagem
  id_lead        TEXT,                     -- valor que veio no formulário (place_id quando vem do link)
  origem         TEXT,
  nome_hotel     TEXT NOT NULL,
  nome_pessoa    TEXT,
  cargo          TEXT,
  cidade         TEXT,
  tipo           TEXT,
  quartos        TEXT,

  -- Etapa 2: reservas e canais
  canais         TEXT[],
  pct_ota        TEXT,
  comissao_mes   TEXT,
  reserva_direta TEXT,

  -- Etapa 3: atendimento e operação
  whats_horas    TEXT,
  whats_fora     TEXT,
  controle       TEXT,
  sistema_nome   TEXT,
  overbooking    TEXT,
  preco          TEXT,

  -- Etapa 4: pagamento, burocracia e equipe
  sinal          TEXT,
  noshow         TEXT,
  burocracia     TEXT[],
  equipe         TEXT[],
  avaliacoes     TEXT,

  -- Etapa 5: dores (1 a 5)
  dor_comissao    SMALLINT CHECK (dor_comissao    BETWEEN 1 AND 5),
  dor_whatsapp    SMALLINT CHECK (dor_whatsapp    BETWEEN 1 AND 5),
  dor_overbooking SMALLINT CHECK (dor_overbooking BETWEEN 1 AND 5),
  dor_preco       SMALLINT CHECK (dor_preco       BETWEEN 1 AND 5),
  dor_pagamento   SMALLINT CHECK (dor_pagamento   BETWEEN 1 AND 5),
  dor_burocracia  SMALLINT CHECK (dor_burocracia  BETWEEN 1 AND 5),
  dor_equipe      SMALLINT CHECK (dor_equipe      BETWEEN 1 AND 5),
  dor_avaliacoes  SMALLINT CHECK (dor_avaliacoes  BETWEEN 1 AND 5),
  dores_fortes   TEXT,
  varinha        TEXT,
  investe        TEXT,
  conversa       TEXT,
  contato        TEXT,

  -- Notas do entrevistador por etapa
  notas_1        TEXT,
  notas_2        TEXT,
  notas_3        TEXT,
  notas_4        TEXT,
  notas_5        TEXT,

  -- Etapa 6: fechamento
  temperatura    TEXT,
  decisor        TEXT,
  proximo_passo  TEXT,
  data_retorno   DATE,
  frase_chave    TEXT,
  obs            TEXT,

  dados_brutos   JSONB NOT NULL,           -- JSON original enviado pelo formulário
  recebido_em    TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- O formulário reenvia se a internet cair; isso impede gravar a mesma entrevista duas vezes
  UNIQUE (entrevista_em, nome_hotel)
);
CREATE INDEX IF NOT EXISTS entrevistas_place_idx ON entrevistas (place_id);
CREATE INDEX IF NOT EXISTS entrevistas_retorno_idx ON entrevistas (data_retorno) WHERE data_retorno IS NOT NULL;

-- =========================================================
-- Usada pela captação: SELECT * FROM salvar_leads($1::jsonb);
-- Recebe a lista de leads do nó "Normalizar e pontuar", grava só os
-- novos e devolve os que entraram agora.
-- =========================================================
CREATE OR REPLACE FUNCTION salvar_leads(lista JSONB)
RETURNS TABLE (place_id TEXT, nome TEXT, cidade TEXT, uf CHAR(2), telefone TEXT, whatsapp TEXT,
               score SMALLINT, motivos TEXT, link_entrevista TEXT)
LANGUAGE sql AS $$
  INSERT INTO leads AS l (place_id, nome, cidade, uf, endereco, telefone, whatsapp, site, nota,
                          avaliacoes, maps, score, motivos, link_entrevista, status, capturado_em)
  SELECT x->>'place_id', x->>'nome',
         NULLIF(x->>'cidade',''), NULLIF(x->>'uf',''), NULLIF(x->>'endereco',''),
         NULLIF(x->>'telefone',''), NULLIF(x->>'whatsapp',''), NULLIF(x->>'site',''),
         NULLIF(x->>'nota','')::NUMERIC, NULLIF(x->>'avaliacoes','')::INTEGER,
         NULLIF(x->>'maps',''), COALESCE(NULLIF(x->>'score','')::SMALLINT, 0),
         NULLIF(x->>'motivos',''), NULLIF(x->>'link_entrevista',''),
         COALESCE(NULLIF(x->>'status',''), 'Novo'),
         COALESCE(NULLIF(x->>'capturado_em','')::TIMESTAMPTZ, now())
  FROM jsonb_array_elements(lista) AS x
  WHERE COALESCE(x->>'place_id','') <> ''
  ON CONFLICT ON CONSTRAINT leads_pkey DO NOTHING
  RETURNING l.place_id, l.nome, l.cidade, l.uf, l.telefone, l.whatsapp, l.score, l.motivos, l.link_entrevista;
$$;

-- =========================================================
-- Usada pelo webhook do questionário: SELECT salvar_entrevista($1::jsonb);
-- Grava a entrevista e atualiza o lead (status, temperatura, próximo passo).
-- =========================================================
CREATE OR REPLACE FUNCTION salvar_entrevista(j JSONB) RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
  novo_id BIGINT;
  v_place TEXT;
BEGIN
  SELECT l.place_id INTO v_place FROM leads l WHERE l.place_id = NULLIF(j->>'id_lead','');

  INSERT INTO entrevistas (
    place_id, entrevista_em, id_lead, origem, nome_hotel, nome_pessoa, cargo, cidade, tipo, quartos,
    canais, pct_ota, comissao_mes, reserva_direta,
    whats_horas, whats_fora, controle, sistema_nome, overbooking, preco,
    sinal, noshow, burocracia, equipe, avaliacoes,
    dor_comissao, dor_whatsapp, dor_overbooking, dor_preco, dor_pagamento, dor_burocracia, dor_equipe, dor_avaliacoes,
    dores_fortes, varinha, investe, conversa, contato,
    notas_1, notas_2, notas_3, notas_4, notas_5,
    temperatura, decisor, proximo_passo, data_retorno, frase_chave, obs,
    dados_brutos
  ) VALUES (
    v_place,
    COALESCE(NULLIF(j->>'entrevista_em','')::TIMESTAMPTZ, now()),
    NULLIF(j->>'id_lead',''), NULLIF(j->>'origem',''), j->>'nome_hotel', NULLIF(j->>'nome_pessoa',''),
    NULLIF(j->>'cargo',''), NULLIF(j->>'cidade',''), NULLIF(j->>'tipo',''), NULLIF(j->>'quartos',''),
    NULLIF(string_to_array(j->>'canais', '; '), '{}'),
    NULLIF(j->>'pct_ota',''), NULLIF(j->>'comissao_mes',''), NULLIF(j->>'reserva_direta',''),
    NULLIF(j->>'whats_horas',''), NULLIF(j->>'whats_fora',''), NULLIF(j->>'controle',''),
    NULLIF(j->>'sistema_nome',''), NULLIF(j->>'overbooking',''), NULLIF(j->>'preco',''),
    NULLIF(j->>'sinal',''), NULLIF(j->>'noshow',''),
    NULLIF(string_to_array(j->>'burocracia', '; '), '{}'),
    NULLIF(string_to_array(j->>'equipe', '; '), '{}'),
    NULLIF(j->>'avaliacoes',''),
    NULLIF(j->>'dor_comissao','')::SMALLINT,    NULLIF(j->>'dor_whatsapp','')::SMALLINT,
    NULLIF(j->>'dor_overbooking','')::SMALLINT, NULLIF(j->>'dor_preco','')::SMALLINT,
    NULLIF(j->>'dor_pagamento','')::SMALLINT,   NULLIF(j->>'dor_burocracia','')::SMALLINT,
    NULLIF(j->>'dor_equipe','')::SMALLINT,      NULLIF(j->>'dor_avaliacoes','')::SMALLINT,
    NULLIF(j->>'dores_fortes',''), NULLIF(j->>'varinha',''), NULLIF(j->>'investe',''),
    NULLIF(j->>'conversa',''), NULLIF(j->>'contato',''),
    NULLIF(j->>'notas_1',''), NULLIF(j->>'notas_2',''), NULLIF(j->>'notas_3',''),
    NULLIF(j->>'notas_4',''), NULLIF(j->>'notas_5',''),
    NULLIF(j->>'temperatura',''), NULLIF(j->>'decisor',''), NULLIF(j->>'proximo_passo',''),
    NULLIF(j->>'data_retorno','')::DATE, NULLIF(j->>'frase_chave',''), NULLIF(j->>'obs',''),
    j
  )
  ON CONFLICT (entrevista_em, nome_hotel) DO NOTHING
  RETURNING id INTO novo_id;

  -- Atualiza o lead com o resultado da entrevista (só na primeira gravação)
  IF v_place IS NOT NULL AND novo_id IS NOT NULL THEN
    UPDATE leads SET
      status        = CASE WHEN j->>'proximo_passo' = 'Sem interesse' THEN 'Descartado' ELSE 'Entrevistado' END,
      temperatura   = COALESCE(NULLIF(j->>'temperatura',''), temperatura),
      proximo_passo = COALESCE(NULLIF(j->>'proximo_passo',''), proximo_passo),
      data_retorno  = COALESCE(NULLIF(j->>'data_retorno','')::DATE, data_retorno),
      atualizado_em = now()
    WHERE place_id = v_place;
  END IF;

  RETURN novo_id; -- NULL se era reenvio de uma entrevista já gravada
END $$;
