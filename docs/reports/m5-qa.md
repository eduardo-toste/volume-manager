## Etapa M5 — QA
Resultado: PASS (com 1 pendência obrigatória, item 1: a SPEC mudou durante a etapa e o seletor de ícone da barra ainda existe)

O que foi feito: li CLAUDE.md, SPEC §3.3/3.4/§8/§12.1-12.3/§12.9, PLAN M5, o código novo e o diff, os snapshots e o .app gerado. Rodei check.sh --app e security-check do zero. Escrevi `Tests/VolumeCoreTests/QAM5Tests.swift` (7 testes de borda) e a seção M5 em `docs/MANUAL_TESTS.md`. Não abri o app real.

Como verificar: `scripts/check.sh --app` · `scripts/security-check.sh` · `swift test --filter QAM5Tests`

Verificações: check.sh --app ✓ (zero avisos de build; 1 known issue antigo em SecurityM21Tests.swift:33, não é da M5) · security-check (incl. bundle) ✓ · cobertura: sem regressão apontada pelo check.sh
Bundle conferido: Info.plist com LSUIElement=true, CFBundleDevelopmentRegion pt-BR, NSAudioCaptureUsageDescription em pt-BR, versão 1.0.0/1; `Resources/pt-BR.lproj/Localizable.strings` presente (87 linhas) e sem chave faltando para os textos de Ajustes/Boas-vindas/menu (só símbolos SF aparecem como "ausentes" no meu grep, o que é esperado); entitlements sem exceção de Hardened Runtime; assinatura válida.

Aceite
- Ajustes, instância única, ⌘, e itens do popover, foco na frente: OK (AppWindows.swift:21-26, bringToFront; AppDelegate.swift:36-45). Nunca verificado ao vivo, está no roteiro manual.
- Geral reflete SMAppService real, relido ao abrir e ao ativar, `.requiresApproval` com dica e botão: OK (SettingsView.swift:53-56, 106-120; LoginItemModel).
- Aplicativos (Esquecer/todos/vazio), Dispositivos (✓/Definir como padrão), Sobre: OK. Dado de outro processo: nome via TextSanitizer (WorkspaceAppInfoProvider.swift:97-105), bundle IDs lembrados validados ao carregar (SettingsModel.swift:141).
- Boas-vindas 480×600, só fechar, "Permitir…" reutiliza o caminho S4-M1 (MixerStore.recordUserCheck só grava a marca em granted; denial da guarda de silêncio nunca grava), "Começar" registra só com toggle ligado e grava a flag: OK.
- ⌘Q do menu passa por `composition.quit` (restoreAll, depois terminate, teto de 2 s): OK. Reabrir → Ajustes (`applicationShouldHandleReopen`): OK.
- Nada fora da SPEC em rede, dependências, permissões, entitlements; nenhum `print`, force unwrap ou `Process(`. A única URL nova é a de Releases (abre no navegador; o app não usa rede).
- Desvios do Dev: AppKit puro (aceito; é necessário para trazer Ajustes à frente a partir do painel, e a cena SwiftUI de Ajustes não faz isso para app sem Dock; a SPEC §12.1 ainda cita `VolumeManagerApp`, atualizar o texto); Boas-vindas até `onboardingCompleted` (aceito); textos extras inconclusivo/negado (aceitos, pequenos e úteis); Buscar omitido (a SPEC permite); URL de Releases pendente de confirmação do usuário (apenas registrado).

Problemas / desvios da SPEC (numerados)
1. [ALTA, bloqueante para fechar a M5 se a mudança de SPEC valer já] SPEC §3.3 foi alterada (decisão do usuário em 2026-11-09, ainda não commitada): "Sem opção 'Ícone da barra de menus': o ícone é próprio e fixo". `Sources/VolumeUI/SettingsView.swift:111-115` ainda tem o Picker (`settings.icon`, `MenuBarIconStyle`), e o PLAN M5 e os snapshots `settings-general-*.png` o incluem. O Dev entregou conforme o briefing anterior, então não é culpa dele. Esperado: remover o Picker e as strings `settings.icon*`, regenerar os snapshots de Geral, e (se for esta etapa) remover `MenuBarIconStyle` do SettingsModel/MenuBarController; senão, o orquestrador registra que isso entra na etapa de ícones.
2. [BAIXA] `Tests/VolumeCoreTests/WelcomeAndLoginItemTests.swift` `closingTheWindowWithoutStartChangesNothing` (~linha 48) é vazio na prática: não chama nada, só checa o estado inicial. A garantia real (fechar pelo X não grava nada) está em AppWindows.swift:35-44, onde só `onStart` chama `model.start()`; vale só pelo roteiro manual M5.1-2. Alternativa: apagar o teste ou cobrir via UI.
3. [BAIXA] `WelcomeModel.allow()` (WelcomeModel.swift:47-60): depois de `.denied`, o botão só abre Ajustes do Sistema e nunca relê a permissão; se o usuário conceder lá, a linha fica "negado" até reabrir a janela. Não deixa ninguém sem som e "Começar" continua funcionando. Aceitável na v1.
4. [BAIXA, proporcionalidade] `LoginItemModel.refresh()` grava `settings.launchAtLogin` (LoginItemModel.swift:35-37), um espelho persistido do estado do sistema que nenhum código lê (só gravado em SettingsModel.swift:151). É estado duplicado sem uso; alternativa: remover a escrita e a chave. Não bloqueia.
5. [INFO] Snapshots: o item selecionado da barra lateral aparece como retângulo preto e o botão "Começar" sai cinza; é artefato de renderizar fora de uma janela (já aceito), mas significa que a seleção da barra lateral e o botão de destaque só podem ser conferidos no roteiro manual (M5.1-1, M5.2-2). Layout, grupos, ícone, três destaques e estados vazio/aprovação estão coerentes com o design.
6. [INFO] Proporcionalidade: LoginItemModel, WelcomeModel, SettingsContext (espelha PopoverContext), RememberedRow (testado, 1 uso real), AppWindows (necessário para foco) e AppIconTile (2 usos: Sobre e Boas-vindas) têm uso real hoje. O parâmetro `pane:` de `SettingsView.init` só serve aos snapshots; trivial. Nenhum item reprova.

Testes adicionais (QAM5Tests): recusa do sistema ao registrar não prende o usuário na Boas-vindas; duplo clique em Começar; flag de onboarding corrompida (string, número, array, dict, NaN) vira "mostrar Boas-vindas", sem crash; dois "Permitir…" sobrepostos pedem uma vez só; negação real limpa marca antiga e nunca silencia áudio; Começar não toca a marca de permissão; `requiresApproval` → `enabled` relido. Todos passam. (Um teste meu sobre `.notFound` falhou só por limitação do fake, que marca `.enabled` ao registrar; removido, sem bug de produção.)

Precisa do usuário: seguir `docs/MANUAL_TESTS.md` seção M5 (Boas-vindas, "Permitir…" com algo tocando, Começar, ⌘, com popover, reabrir pelo Finder, toggle vs. Itens de Início, claro/escuro); confirmar a URL de Releases; decidir o item 1.

---

## Volta 2 — QA (reteste proporcional)

Resultado: PASS

Verificado:
1. Problema 1 (ícone configurável): grep em Sources/Tests/Resources por `MenuBarIconStyle`, `settings.icon`, estilo dinâmico, `AppIconTile`: zero sobras. Snapshots `settings-general-*` sem o pop-up (conferido visualmente o claro).
2. Problemas 2, 3, 4 e B-1: teste vazio removido; `WelcomeModel.refreshAccess()` (WelcomeModel.swift:70) relê o status do monitor sem verificar, chamado em `didBecomeActive` (WelcomeView.swift:52-54); `allow()` com `nil` chama `refreshAccess()`; `SettingsModel.launchAtLogin` removido (o `launchAtLogin` restante é só o toggle da Boas-vindas, esperado). `refreshAfterApprovalGrantedElsewhereFollowsTheSystem` cobre o caso.
3. `MenuBarController.makeIcon()` (MenuBarController.swift:95-117): 3 trilhos 1.5 pt, pontas redondas, y 2→16 em x 4.5/9/13.5; puxadores 5×3 raio 1.3 em (2,10), (6.5,4), (11,8); template; 18×18; rótulo de acessibilidade = nome do app. Novo `MenuBarIconTests` (Tests/VolumeUITests/MenuBarPlacementTests.swift) confere template/tamanho/rótulo e pixels (trilhos, puxadores, cantos vazios). Renderização ampliada conferida visualmente: três faders, puxadores nas alturas esperadas.
4. `scripts/build-app.sh`: `AppIcon.icns` via `sips` + `iconutil` apenas (linhas 44-54), iconset temporário removido, `CFBundleIconFile=AppIcon` no Info.plist e `AppIcon.icns` em `Contents/Resources` do app gerado. Sobre/Boas-vindas usam `AppIconView` (SettingsView.swift:270,301; WelcomeView.swift:15); snapshots `settings-about-*` mostram o ícone novo "Mesa de som".
5. `scripts/check.sh --app` verde (inclui security-check --app), zero avisos; 158 testes + os 2 novos passam. Único "known issue" é o `withKnownIssue` antigo da M2.1 (SecurityM21Tests.swift:32), já aceito.
6. `docs/MANUAL_TESTS.md`: item de pop-up de ícone removido; nova seção M5.4 (ícone "Três faders" na barra clara/escura, tamanho, alinhamento, destaque com popover aberto, diferente do alto-falante do sistema; ícone do app no Finder/Sobre/Boas-vindas, cache de ícones).

Problemas: nenhum bloqueante. [INFO] Snapshots seguem mostrando chaves de string e seleção preta (artefato fora de janela, já aceito na volta 1).
Proporcionalidade: nada de novo a reprovar; `AppIconView` tem 2 usos reais.
Precisa do usuário: roteiro manual M5 e M5.4 (ver o ícone na barra real).
