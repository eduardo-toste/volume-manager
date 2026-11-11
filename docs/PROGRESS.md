# Volume Manager — Progresso

> Atualizado em 2026-11-10: **M5.2 e M5.3 integradas.** Antes da M6: experimento de revogação (condição da Segurança) e decisão S53-B2 — ver item 0. **M5 (Ajustes, Boas-vindas e ícones) concluída e integrada na `main`** — QA PASS + Segurança LIBERA (2 voltas). Falta o teste manual do usuário (`docs/MANUAL_TESTS.md`, seção M5). **Próxima sessão: M6.**

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
| M4.1b Pendências curtas da M4.1 (S41R-M1, S41R-B1, vigia 5 s + "nenhum app", rampa na troca de formato, testes estabilizados) | ✅ QA PASS (2 rodadas, `docs/reports/m4.1b-qa.md`) + Segurança LIBERA (reavaliação, `docs/reports/m4.1-security.md` §M4.1b) | branch `etapa/m4.1b` |
| M4.2 Nome exibido “Volume Manager” (bundle ID mantido) | ✅ QA PASS (`docs/reports/m4.2-qa.md`) | branch `etapa/m4.2-nome` |
| M4.3 Testes que travavam/falhavam sob carga (`eventually` com prazo real, sem resultado descartado, `.timeLimit` nas suítes) | ✅ QA PASS (`docs/reports/m4.3-qa.md`) | branch `etapa/m4.3-testes` |
| M5 Ajustes, Boas-vindas e ícones (app AppKit puro: `main.swift` + `AppDelegate`; ícone do app “Mesa de som”; glifo fixo “Três faders” na barra) | ✅ QA PASS + Segurança LIBERA (2 voltas, `docs/reports/m5-*.md`); teste manual do usuário pendente (`docs/MANUAL_TESTS.md` M5) | branch `etapa/m5` |
| M5.1 Correções do teste manual da M5 (Boas-vindas na frente com `orderFrontRegardless`; “Permitir…” mostra o pedido do macOS no clique — escuta curta de processo ocioso só por ação do usuário; texto neutro do inconclusivo) | ✅ QA PASS + Segurança LIBERA (`docs/reports/m5.1-qa.md`, `m5-security.md` §M5.1) + teste manual do usuário (pedido apareceu no clique) | branch `etapa/m5.1` |
| M5.2 Rodapé do popover (sem `•••`; Restaurar áudio original e Sobre no rodapé, decisão do usuário) | ✅ QA PASS (`docs/reports/m5.2-qa.md`); conferência visual do usuário pendente | branch `etapa/m5.2-rodape` |
| M5.3 Estabilidade (bug do Discord: vigia de silêncio 120 s com contagem única; aviso de permissão só se não concedida; lista só com apps reproduzindo ou em chamada, sai em 3 s, ao vivo; menu Opções no rodapé; sem anel de foco) | ✅ QA PASS (`docs/reports/m5.3-qa.md`, `m5.3-ui-qa.md`) + Segurança LIBERA **condicionado ao experimento revoke-exp** (`docs/reports/m5.3-security.md`); teste manual do usuário pendente | branch `etapa/m5.3-estabilidade` |
| M6 Robustez · M7 Distribuição · M7.5 Auditoria · M8 Aceite | ⏳ | — |

Tudo está na `main` (a M2 foi integrada após QA + Segurança LIBERA; o ⏸1 de ouvido ainda vai validar a reescrita). Nada foi enviado ao GitHub (sem `push`). A próxima etapa começa num branch novo a partir da `main`.

## Próxima sessão — ordem sugerida

0. **Pendências da M5.3 (2026-11-10) — fazer ANTES da M6.**
   - **Experimento revoke-exp (condição da Segurança)**: pronto em `scratchpad/revoke-exp/` da sessão de 2026-11-10 (bundle `vmexp.app`, id `com.volumemanager.vmctl-exp`, sinal inaudível dentro de tap `mutedWhenTapped` com aggregate sem saída física). O usuário desliga o item **vmctl-exp** em Ajustes › Privacidade › Gravação de Áudio do Sistema ~1 min após o início, espera 2 min e religa. Se o scratchpad sumir, pedir a um Dev para recriar (relatório na conversa: tap A contínuo + tap B novo a cada 60 s, log a cada 250 ms). **Se os taps antigos continuarem com sinal enquanto os novos recebem só zeros → Alto, BLOQUEIA** (o sinal dos antigos zera a contagem global e o app novo fica mudo sem prazo).
   - **S53-B2 (decisão do usuário)**: com a marca gravada e a permissão revogada de fato, o app volta ao som normal mas os sliders param de funcionar sem aviso. Mostrar "Permitir…" nesse caso ou deixar? O resultado do experimento ajuda a decidir.
   - **Teste manual do usuário (M5.3)**: chamada real do Discord com silêncios longos (sem engasgo, sem "sem permissão", Discord fica na lista); app que para sai sozinho em ~3 s (popover aberto e fechado); "Permitir…" não aparece com a permissão dada; menu Opções; nenhum contorno azul ao clicar.
   - Abertos e aceitos: S41-B3, S41b-B3; Informativos da M5.3 (releitura completa a cada 1 s com o popover aberto; apps com microfone em uso sem chamada, ex.: ditado, aparecem na lista).

1. **Resolvido em 2026-11-09 (M4.3)**: o "teste intermitente" e os `swiftpm-testing-helper` presos tinham a mesma causa — `eventually` desistia por contagem de `Task.yield()` sob carga, e resultados descartados antes de `clock.advance` + `await task.value` deixavam o processo esperando para sempre. Se um `check.sh` parar de novo, conferir `pgrep -fl swiftpm-testing-helper` (o `.timeLimit` de 1 min deve transformar qualquer espera eterna em falha).
   - **Retestes manuais do usuário (sem pressa; o usuário avisa se notar algo)**: trocar saída/taxa nos Ajustes de Som com um app abaixo de 100% (sem estalo nem pico); pausar um app (não deve aparecer "sem permissão"); navegador silencioso como único app "tocando" por > 2 min (painel não fica preso em "sem permissão"). Ainda não confirmados da M4.1: log "tap and aggregate destroyed" ~15 s após pausar (S41-M2), estalinho no início da reprodução.
   - Experimento de revogação da permissão: **dispensado pelo usuário em 2026-11-09**; adotado o caminho seguro (vigia 5 s, "nenhum app" quando nada toca, reverificação ao voltar a tocar, orçamento de 3 verificações automáticas por episódio).
   - Abertos e aceitos por ora: S41b-B3 (Informativo, pico ≤ 40 ms em ganho 1 se o número de canais mudar durante a rampa, `RealtimeTapState.swift:109-118`); QA M4.1b problema 2 (Baixo, novo "negada" do vigia reinicia o orçamento); na abertura com a marca ligada e o TCC zerado, a sonda automática pode mostrar o pedido (risco já existente da M4.1).

2. **Teste manual da M5 (usuário)**: roteiro em `docs/MANUAL_TESTS.md` (M5, M5.4) — Boas-vindas, “Permitir…” com algo tocando, “Começar”, ⌘, com o popover, reabrir pelo Finder, toggle × Itens de Início, ícone “Três faders” na barra clara/escura, ícone do app no Finder. Abertos e aceitos: Boas-vindas aparece até “Começar” (não distingue “permissão não decidida” sem sondar); I-5 (linha “Permitido” não volta a “negada” — só visual); chaves órfãs `menuBarIconStyle`/`launchAtLogin` no UserDefaults.

3. **M6 — Ciclo de vida e robustez** (ver PLAN e pendências abaixo).

### Pendências para a M6 (Robustez)
- **Build ad hoc perde a permissão a cada rebuild** (o TCC usa o cdhash): a marca `audioPermissionConfirmed` fica velha. Resolvido de fato com certificado próprio estável (M7); a pendência da marca velha abaixo cobre o resto.
- Clique em “Permitir…” durante a verificação automática do início pode mostrar o texto inconclusivo em vez de “Permitido” (só visual; `PermissionMonitor.refresh` devolve `nil` sem aguardar a verificação em curso).
- **Para a M7.5**: no clique em “Permitir…”, o `tccd` registrou consultas do próprio app a `kTCCServiceListenEvent` e `kTCCServiceMicrophone` (authValue=1, sem pedido na tela; hardened runtime sem esses entitlements). Conferir a origem (framework) e que nunca vira pedido.
- **Antes do release (M7)**: rebaixar os logs `.notice` de ciclo de vida de tap (criado/destruído/plano/sondas) para `.debug`/`.info` — hoje persistidos para diagnosticar o reteste (S41-B3, `docs/reports/m4.1-security.md`).
- S21-B1/S21-B2 (`docs/reports/m2.1-security.md`): conferir a identidade (UID do aggregate, UUID do tap) antes de destruir; cobre também o reinício do coreaudiod no meio de `makeSession`.
- Marca `audioPermissionConfirmed` velha (permissão zerada no macOS ou app reassinado): auto-verificar só se a marca existir e a última sessão terminou limpa.
- Opcional (usuário): suíte de hardware (`VOLUME_AUDIO_TESTS=1`) pelo `vmctl-dev.app`.

## Decisões tomadas (resumo)
- macOS mínimo **15**; atômicos com `Synchronization.Atomic`.
- API privada `responsibility_get_pid_responsible_for_pid` só via `weak_import` em `CSystemShims` (ver M-1).
- Bundle ID `com.volumemanager.app`, nome exibido "Volume Manager" (renomeado em 2026-11-09, decisão do usuário; bundle ID mantido para não perder a permissão); distribuição pelo GitHub Releases, sem conta Apple, certificado próprio; sem atualização automática no MVP.
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
- **Ícone da barra de menus próprio e fixo** (decisão do usuário em 2026-11-09): diferente do alto-falante do volume do macOS, para distinguir os dois apps na barra; sai o pop-up “Ícone da barra de menus” (Alto-falante/Controles) e o ícone dinâmico. Escolhidos pelo usuário na página “Ícones” do FigCraft (2026-11-09): ícone do app **A — Mesa de som** (frame 1255; `Resources/AppIcon-1024.png`) e glifo da barra **1 — Três faders** (frame 2041).
- **Link do Sobre** (confirmado pelo usuário em 2026-11-09): `https://github.com/eduardo-toste/volume-manager/releases`.
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
   - **Dev** (subagente Sonnet, papel em `.claude/agents/volume-dev.md`) implementa. O prompt traz critérios de aceite fechados, os arquivos/seções exatos a ler e limite para investigações sem resultado;
   - **o orquestrador revisa o diff e roda `scripts/check.sh` antes de chamar QA/Segurança**; problema claro volta direto ao Dev (economiza uma volta inteira de revisão);
   - **QA** (Sonnet, `.claude/agents/volume-qa.md`) e **Segurança** (Opus, `.claude/agents/volume-security.md`, nas etapas de áudio/permissão e na M7.5) rodam **em paralelo**. Em FAIL, devolver ao mesmo Dev a lista de problemas dos dois numa volta só, no máximo 3 voltas;
   - **reteste proporcional** (decisão do usuário em 2026-11-09): após uma correção, reverifica só quem apontou o problema; a Segurança reentra também se a correção mexer em permissão, thread de áudio ou criação/destruição de tap. Etapas grandes, de áudio novo e a M7.5 têm sempre as duas revisões completas;
   - o orquestrador roda `scripts/check.sh` ele mesmo antes de commitar;
   - commit no branch, `git merge --ff-only` na `main`, atualizar este arquivo.
4. Os prompts dos agentes devem repetir as regras críticas: nenhum som audível, nunca fazer tap em apps do usuário (só `afplay -v 0` próprio), nada de instalar ou baixar, sem commit/branch/push pelos agentes.
5. **Push: só o usuário faz** (`git push` é bloqueado em `.claude/settings.json`). Ao fim, passar o comando `! git -C <repo> push origin main`.
6. Testes com áudio real: usar `scripts/make-vmctl-app.sh` e `open -W --stdout … build/vmctl-dev.app --args …`. O usuário já concedeu a permissão ao `vmctl-dev`. Ferramentas de terminal sem `Info.plist` recebem só silêncio.
7. Decisões que mudam requisitos: perguntar ao usuário e então atualizar SPEC, PLAN e este arquivo.
