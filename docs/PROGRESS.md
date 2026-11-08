# Volume Manager — Progresso

> Atualizado em 2026-11-08: M4.1 concluída e integrada na `main` (⏸2 aprovado pelo usuário). Próxima: pendências curtas abaixo e depois a M5.

## Onde estamos

| Etapa | Status | Commit |
|---|---|---|
| Design (FigCraft) | ✅ fechado | `0729242` |
| SPEC + PLAN | ✅ aprovados | `0729242`… |
| Ambiente de agentes (`CLAUDE.md`, `.claude/`) | ✅ | `efc84c5`, `55a516b` |
| M0.5 Prova de viabilidade (spike) | ✅ + ⏸0 aprovado de ouvido | `7e21553`, `7962f29` |
| M0 Fundação | ✅ | `0a904bc` |
| M1 Domínio (`VolumeCore`) | ✅ | `450ad83` |
| M3 Serviços (`VolumeSystem`) | ✅ | `3357524` |
| M2 Áudio real (`VolumeAudio`, `vmctl`) | ✅ QA + Segurança (LIBERA) | `5bcedbf` |
| ⏸1 Teste de ouvido da M2 | ✅ aprovado (2026-11-07): só o app alvo muda, sem estalo, qualidade igual; AirPods ficaram em 48 kHz (sem modo ligação) | — |
| M2.1 Correções da revisão de segurança | ✅ QA PASS + Segurança LIBERA (`docs/reports/m2.1-*.md`) | `51a3262` |
| M4 Popover do mixer (`VolumeUI`) | ✅ QA PASS (3 rodadas) + Segurança LIBERA (`docs/reports/m4-*.md`) | branch `etapa/m4` |
| ⏸2 Teste do app real (roteiro em `docs/MANUAL_TESTS.md`, seção M4) | ❌ reprovado (2026-11-08, manhã) → ✅ aprovado após a M4.1 (2026-11-08, tarde) | — |
| M4.1 Correções do ⏸2 (design do FigCraft à risca, painel próprio, sempre controlar, estalo zero) | ✅ QA PASS (6 rodadas) + Segurança LIBERA (reavaliação) + ⏸2 aprovado | branch `etapa/m4.1` |
| M5 Ajustes/Boas-vindas · M6 Robustez · M7 Distribuição · M7.5 Auditoria · M8 Aceite | ⏳ | — |

Tudo está na `main` (a M2 foi integrada após QA + Segurança LIBERA; o ⏸1 de ouvido ainda vai validar a reescrita). Nada foi enviado ao GitHub (sem `push`). A próxima etapa começa num branch novo a partir da `main`.

## Próxima sessão — ordem sugerida

1. **Pendências curtas da M4.1** (uma rodada Dev → QA, antes da M5):
   - **S41R-M1 (Médio, `docs/reports/m4.1-security.md`, Reavaliação)**: o "concedida" guardado por 30 s (`recentGrant`) responde também a um silêncio novo; após revogar a permissão com o Volume aberto, um app pode ficar mudo até ~30 s. Correção: usar o resultado guardado só para reverificar um silêncio já verificado, nunca para o primeiro silêncio depois de sinal.
   - **S41R-B1 (Baixo)**: no estado negado, a reverificação a cada 30 s pode mostrar o pedido do TCC sem ação do usuário se a permissão for zerada (§5).
   - **Teste intermitente**: `swift test` falhou 1 vez em 5 execuções em 2026-11-08 (provavelmente sob carga, com outros agentes testando em paralelo); identificar e estabilizar (só no teste, sem afrouxar).
   - Itens do reteste não confirmados explicitamente pelo usuário: pausa → log "tap and aggregate destroyed" ~15 s depois (S41-M2), navegador silencioso sem "sem permissão", estalinho no início da reprodução.
   - QA M4.1 rodada 6, problema 1 (Média): "sem permissão" falso com navegador silencioso como único áudio (falha aberta; aceito pela SPEC §4.6, sumirá na reverificação com som real).
2. **M5 — Ajustes e Boas-vindas**: substituir a cena `Settings` provisória; seguir o design do FigCraft à risca também nessas telas; "Permitir…" das Boas-vindas é a ação do usuário que dispara o pedido de permissão e grava a marca. Com o painel próprio (`MenuBarController`), conferir que ⌘, / "Ajustes do Volume…" abrem a janela (risco relatado pelo Dev na rodada 4).

### Pendências para a M6 (Robustez)
- **Antes do release (M7)**: rebaixar os logs `.notice` de ciclo de vida de tap (criado/destruído/plano/sondas) para `.debug`/`.info` — hoje persistidos para diagnosticar o reteste (S41-B3, `docs/reports/m4.1-security.md`).
- S21-B1/S21-B2 (`docs/reports/m2.1-security.md`): conferir a identidade (UID do aggregate, UUID do tap) antes de destruir; cobre também o reinício do coreaudiod no meio de `makeSession`.
- Marca `audioPermissionConfirmed` velha (permissão zerada no macOS ou app reassinado): auto-verificar só se a marca existir e a última sessão terminou limpa.
- Opcional (usuário): suíte de hardware (`VOLUME_AUDIO_TESTS=1`) pelo `vmctl-dev.app`.

## Decisões tomadas (resumo)
- macOS mínimo **15**; atômicos com `Synchronization.Atomic`.
- API privada `responsibility_get_pid_responsible_for_pid` só via `weak_import` em `CSystemShims` (ver M-1).
- Bundle ID `com.volumemanager.app`, nome exibido "Volume"; distribuição pelo GitHub Releases, sem conta Apple, certificado próprio; sem atualização automática no MVP.
- Pânico ("Restaurar áudio original") = lousa limpa total (zera estados + esquece lembrados).
- ZWJ/ZWNJ preservados só entre caracteres visíveis.
- Vigia de silêncio fica como na SPEC; a UI confirma com `verify()`.
- `_withUnsafeGuaranteedRef` mantido; inspeção do desmontado entra no roteiro de release (M7).
- Testes nunca produzem som, nunca tocam apps do usuário, nunca usam preferências reais; áudio real só via bundle `vmctl-dev.app`/`vmctl-test.app`.
- **Sem atalhos globais** (⌥⌘V/⌥⌘M removidos) e **zero dependências externas** — decisão do usuário em 2026-11-07. O design no FigCraft ainda mostra a seção de atalhos e o item “Atalhos” na barra lateral dos Ajustes: **a SPEC prevalece** (não implementar).
- **Ícone da barra de menus sempre visível**: a opção “Mostrar na barra de menus” foi removida (decisão do usuário em 2026-11-07); o design ainda a mostra — a SPEC prevalece.
- **Sem CI** (decisão do usuário em 2026-11-07): `.github/workflows` removido; verificações só locais com `scripts/check.sh`.
- **M-1 = risco aceito** (decisão do usuário em 2026-11-07): sem checagem de nulo do `weak_import`; o roteiro de release (M7) confirma o símbolo no macOS mínimo e no atual (SPEC §4.1, PLAN M7).
- **Aceitos sem mudança**: B-3 (bundle ID declarado decide o grupo), B-6 (segundo `stop()` concorrente volta antes do teardown), B-7 (`_withUnsafeGuaranteedRef`), S21-B3 (casamento exato de UID vence o sanitizado), retenção de ~100 B por tap a cada reinício do coreaudiod no `abandon()`.
- **Sem overengineering** (decisão do usuário em 2026-11-07): regra no `CLAUDE.md` e nos três agentes; Dev lista "Abstrações novas"; QA/Segurança julgam proporcionalidade; o orquestrador revisa o diff antes de commitar.
- **Permissão (M4, S4-M1)**: nenhum tap de usuário sem `verify()` == granted nesta sessão. Sem a marca persistida `audioPermissionConfirmed`, só ação do usuário dispara a verificação (o pedido do sistema nunca aparece sozinho); com a marca e um app lembrado tocando, verifica sozinho ao iniciar e reaplica os lembrados (§14.7). Só um "negada" confirmado por ação do usuário apaga a marca; o "negada" do vigia de silêncio (ambíguo) e "Restaurar áudio original" não a apagam (Restaurar continua zerando estados e esquecendo lembrados, e suspende os taps até a próxima ação do usuário) — M4.1, S41-M1.
- **Aceitos sem mudança (M4)**: S4-B3 (ícone buscado pelo bundle ID declarado — só visual); monitor de rolagem `NSEvent` local por slider; snapshots de teste mostram chaves em vez de pt-BR (o app real está correto).
- **Regra 16**: nada é instalado ou baixado por Claude/agentes — o usuário instala tudo.

## Pendências do usuário
- Ao final do projeto: remover em Ajustes › Privacidade › Gravação de Tela e Áudio do Sistema as permissões de `vmctl-test` e `vmctl-dev`.

## Modelos dos agentes
Dev e QA: Sonnet · Segurança: Opus · tarefas mecânicas/documentação: Haiku. Escalar para Opus só se o Sonnet travar.

## Como retomar (para o orquestrador)
1. Falar com o usuário **sempre em português (pt-BR)**, com um resumo curto ao fim de cada etapa.
2. Ler este arquivo, `CLAUDE.md`, a etapa em `docs/PLAN.md` e os relatórios em `docs/reports/`.
3. Fluxo de cada etapa:
   - criar o branch `etapa/<id>` a partir da `main`;
   - **Dev** (subagente Sonnet, papel em `.claude/agents/volume-dev.md`) implementa;
   - **QA** (Sonnet, `.claude/agents/volume-qa.md`) verifica de forma independente e dá PASS/FAIL. Em FAIL, devolver ao mesmo Dev a lista de problemas, no máximo 3 voltas;
   - **Segurança** (Opus, `.claude/agents/volume-security.md`) nas etapas de áudio e na M7.5;
   - o orquestrador roda `scripts/check.sh` ele mesmo antes de commitar;
   - commit no branch, `git merge --ff-only` na `main`, atualizar este arquivo.
4. Os prompts dos agentes devem repetir as regras críticas: nenhum som audível, nunca fazer tap em apps do usuário (só `afplay -v 0` próprio), nada de instalar ou baixar, sem commit/branch/push pelos agentes.
5. **Push: só o usuário faz** (`git push` é bloqueado em `.claude/settings.json`). Ao fim, passar o comando `! git -C <repo> push origin main`.
6. Testes com áudio real: usar `scripts/make-vmctl-app.sh` e `open -W --stdout … build/vmctl-dev.app --args …`. O usuário já concedeu a permissão ao `vmctl-dev`. Ferramentas de terminal sem `Info.plist` recebem só silêncio.
7. Decisões que mudam requisitos: perguntar ao usuário e então atualizar SPEC, PLAN e este arquivo.
