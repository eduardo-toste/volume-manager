# Volume Manager — Progresso

> Atualizado em 2026-11-07, ao pausar após a M4 (⏸2 pendente com o usuário). Leia junto com `CLAUDE.md`, `docs/SPEC.md` e `docs/PLAN.md`.

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
| ⏸2 Teste do app real (roteiro em `docs/MANUAL_TESTS.md`, seção M4) | ⏳ com o usuário | — |
| M5 Ajustes/Boas-vindas · M6 Robustez · M7 Distribuição · M7.5 Auditoria · M8 Aceite | ⏳ | — |

Tudo está na `main` (a M2 foi integrada após QA + Segurança LIBERA; o ⏸1 de ouvido ainda vai validar a reescrita). Nada foi enviado ao GitHub (sem `push`). A próxima etapa começa num branch novo a partir da `main`.

## Próxima sessão — ordem sugerida

1. **⏸2 — teste do app real com o usuário** (`scripts/build-app.sh`, abrir `build/Volume.app`; roteiro em `docs/MANUAL_TESTS.md`, seção M4). Pontos que só o app real valida: nome do dispositivo no card "Saída" (item 1.3), Esc fecha o popover, vidro duplicado no macOS 26, reverificação ao abrir o popover, ⌘, abrindo a janela provisória num app sem Dock, Sair < 2 s, fundo da linha expandida (sutil), CPU ocioso e abertura do popover (§12.4), matriz de apps §4.1. Corrigir o que o ⏸2 apontar numa M4.1 antes da M5.
2. **M5 — Ajustes e Boas-vindas**: substituir a cena `Settings` provisória (`Sources/VolumeManager/VolumeManagerApp.swift`); o "Permitir…" das Boas-vindas é a ação do usuário que dispara o pedido de permissão e grava a marca `audioPermissionConfirmed`.
3. **Pendências para a M6 (Robustez)**:
   - S21-B1/S21-B2 (`docs/reports/m2.1-security.md`): conferir a identidade (UID do aggregate, UUID do tap) antes de destruir; cobre também o reinício do coreaudiod no meio de `makeSession`.
   - QA M4 rodada 3, problema 1: a marca `audioPermissionConfirmed` pode ficar velha (permissão zerada no macOS ou app reassinado com outro certificado) e o pedido do sistema aparecer ao reabrir sem ação do usuário. Mitigação sugerida: auto-verificar só se a marca existir e a última sessão terminou limpa.
4. Opcional (usuário): rodar a suíte de hardware (`VOLUME_AUDIO_TESTS=1`) pelo bundle `vmctl-dev.app`.

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
- **Permissão (M4, S4-M1)**: nenhum tap de usuário sem `verify()` == granted nesta sessão. Sem a marca persistida `audioPermissionConfirmed`, só ação do usuário dispara a verificação (o pedido do sistema nunca aparece sozinho); com a marca e um app lembrado tocando, verifica sozinho ao iniciar e reaplica os lembrados (§14.7). Negada e "Restaurar áudio original" apagam a marca.
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
