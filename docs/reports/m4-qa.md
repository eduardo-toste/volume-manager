## Etapa M4 — QA
Resultado: PASS após a Rodada 3 (rodada 1 foi FAIL por 1 achado Major)

O que foi feito:
- Li o diff (`Sources/VolumeUI`, `Sources/VolumeManager`, `PermissionMonitor`, `retry/retryAll`, `failedAppIDs`) contra SPEC §3, §4.6, §5, §6, §7, §8, §12.4, §12.9.
- Testes novos (só em `Tests/`):
  - `Tests/VolumeUITests/SnapshotTests.swift`: renderiza popover completo, linhas (normal, silenciada, expandida com rota, com falha), card de saída, sem permissão, nenhum app, modo seguro e ícone da barra, em claro e escuro, só com fakes (NSHostingView em janela fora da tela, nunca exibida; nada de áudio, nada de app real). Também mede a montagem da view. Para regravar os PNGs: `VM_WRITE_SNAPSHOTS=1 swift test --filter SnapshotTests`.
  - `Tests/VolumeSystemTests/QAM4PermissionFlowTests.swift`: `PermissionMonitor` sobre o `AudioPermissionService` real com probe falso (negada não é apagada por `.indeterminate`; `.indeterminate` nunca vira negada; concessão posterior chama `onGranted` uma vez; checagens simultâneas).
- 22 PNGs em `Tests/Snapshots/*.png`.
- Roteiro do ⏸2 em `docs/MANUAL_TESTS.md` (seção M4), incluindo matriz §4.1, claro/escuro, acessibilidade e medições §12.4.

Como verificar: `swift build`; `swift test`; `swift format lint --strict -r Sources Tests`; `scripts/check.sh`; `scripts/check.sh --app`; ver `Tests/Snapshots/`.

Verificações: check.sh ✓ · check.sh --app ✓ (só constrói) · security-check ✓ · lint estrito ✓ · swift test ✓ (cobertura: não medida nesta rodada; sem queda esperada, só foram adicionados testes)

### Verificação por item
1. View-model/estado: coberto (RowPresentation: "72%" com arredondamento e clamp, passo do Incremento sem deriva; MixerStoreTests: ordenação, contador, uma linha expandida, modo seguro; ControlFailureTests). "Silenciado" é um texto de UI (`row.muted`), visto no snapshot.
2. Permissão: ok. "Sem permissão" só vem de `verify()` (`PermissionMonitor.recheckAfterSilence/refresh`); `refresh()` não faz nada fora de `.denied`, então abrir o popover não dispara o pedido do sistema; `.indeterminate` mantém o último estado (confirmado de ponta a ponta); `retryAll()` roda só na transição negada→concedida. `markCleanExit` via `SessionLifecycleObserver` (power off/terminate) e também no Sair. Sair: `restoreAll()` → `flush` → `markCleanExit` → `terminate`. "Restaurar áudio original" = lousa limpa (zera estados, falhas e lembrados; `restoreAll` imediato). Nenhum caminho deixa app mudo: falhas viram "Não foi possível controlar este app" e o app toca normal.
3. Snapshots: gerados e lidos (ver divergências abaixo). Limitação: `Text(..., bundle: .main)` não acha o `.xcstrings` dentro do processo de teste, então os PNGs mostram as chaves (`popover.title`) em vez do texto pt-BR. Os textos foram conferidos direto no catálogo (todas as chaves usadas existem, todas com pt-BR, 32 chaves). Também o vidro/material não é desenhado fora de uma janela real (fundo plano) — a aparência de vidro só dá para validar no ⏸2.
4. Teclado/a11y: `NSEvent.addLocalMonitorForEvents(.scrollWheel)` só vê eventos do próprio app, não pede Monitoramento de Entrada nem outra permissão; filtra por janela e por limites da view e devolve o evento quando não consome; removido em `deinit`. `.onKeyPress` (setas e Espaço) só age com a linha focada. Esc via `onExitCommand`. Rótulos VoiceOver presentes (linha, slider com `accessibilityValue` e ação de ajuste, botões de mudo, card de saída). Tab entre linhas depende de "Navegação por teclado" do macOS (anotado no roteiro). Reduzir movimento respeitado (sem animação/transição).
5. Orçamentos: sem abrir o app. Montar + desenhar o popover completo com fakes: ~270 ms no total, dos quais 200 ms são espera fixa do teste, ou seja ~65 ms de montagem/desenho (teste com limite folgado de 1 s). Procedimento de CPU/abertura/memória no roteiro (item 9).
6. Escopo: nada fora da SPEC (sem rede, dependências, permissões extras; sem atalhos nem "Mostrar na barra de menus"). `#available` só em `Styling.swift`. `VolumeCore` sem AppKit/SwiftUI. UI sem strings soltas (os `Text(verbatim:)` são dados do sistema, "⌘Q" e porcentagem). Cena `Settings` provisória: aceitável como ponte até a M5 (é uma janelinha com um texto, sem lógica), desde que a M5 a substitua; se o usuário abrir antes, vê a mensagem — está no roteiro.
7. Proporcionalidade: ver itens 5 a 8 abaixo (todos baixos).

### Divergências snapshot × design (relevantes, sem pixel a pixel)
- D1 (ver item 1): card "Saída" sem o nome do dispositivo nem o chevron `›` (design mostra ícone em círculo azul, "Saída" pequeno e o nome em destaque).
- D2: no design o slider do app fica alinhado à coluna do nome (recuado, depois do ícone); na implementação ocupa a largura toda sob o ícone. Menor.
- D3: no design a linha expandida/hover tem fundo cinza arredondado envolvendo a lista de saídas; na implementação só o hover tem destaque (a linha expandida não). Menor.
- D4: no design as saídas do app estão recuadas alinhadas ao nome; na implementação ficam na margem esquerda. Menor.
- D5: vidro/cartão não aparece nos PNGs (limitação da renderização fora da tela), confirmar no ⏸2.
- Corretos: ordenação (tocando primeiro, depois nome), "72%", "Silenciado" em vermelho com slider esmaecido, rótulo de rota em azul, falha em laranja, rodapé com ⌘, e ⌘Q, estados sem permissão e vazio, contador "N reproduzindo".
- Itens do design que NÃO existem de propósito (SPEC prevalece): atalhos e "Mostrar na barra de menus".

### Problemas / desvios da SPEC
1. **Major** — `Sources/VolumeUI/OutputCard.swift:32-51`: o `Menu` com `.menuStyle(.borderlessButton)` achata o rótulo. No snapshot o card mostra só o ícone e o texto "Saída"; o **nome do dispositivo e o chevron somem** (SPEC §3.2: ícone + rótulo "Saída" + nome do dispositivo + `›`). É comportamento conhecido de Menu no macOS e provavelmente se repete no app real. Esperado: o nome visível. Alternativa simples: um `Button` com o HStack atual que abre um `.popover`/lista, ou um `Picker` de estilo menu com o nome como título; confirmar no ⏸2 (item 1.3 do roteiro).
2. **Baixa** — `Sources/VolumeManager/Composition.swift:88-97`: `Sair` aguarda `restoreAll()` sem limite de tempo; se travasse, o app não sairia. Cliques repetidos criam várias `Task`. Aceitável (taps morrem com o processo); sugestão: ignorar cliques repetidos.
3. **Baixa** — `Sources/VolumeUI/OutputCard.swift:76-78`: `.help(Text(verbatim: ""))` quando há controle de volume; mais simples aplicar o `.help` só quando não há controle.
4. **Baixa (proporcionalidade)** — `Sources/VolumeCore/PermissionMonitor.swift:30-44`: `refresh()` e `recheckAfterSilence()` repetem o mesmo bloco; um único método com parâmetro `onlyIfDenied` bastaria.
5. **Baixa (proporcionalidade)** — `Sources/VolumeUI/MenuBarPopover.swift:157-177` (`MenuItemRow`): duplica o botão em dois ramos por causa do `keyboardShortcut` opcional; `shortcut` só tem 2 usos reais, poderia ser dois itens diretos.
6. **Baixa** — `Sources/VolumeUI/VolumeInput.swift:47-67`: um monitor `NSEvent` por slider (até ~8 ao mesmo tempo, um por linha visível mais o card). Funciona; um único monitor no popover seria mais simples e barato. Não bloqueia.
7. **Informativo** — `Sources/VolumeManager/VolumeManagerApp.swift:18-22`: cena `Settings` provisória; substituir na M5. Sem teste automático (fora do que dá para testar sem abrir o app).
8. **Informativo** — o popover nunca dispara o pedido de permissão sozinho (correto); no primeiro uso o pedido aparece ao criar o primeiro tap (ou nas Boas-vindas da M5).

Precisa do usuário: ⏸2 — seguir `docs/MANUAL_TESTS.md` (seção M4): abrir o app real, mexer nos sliders com música, claro/escuro, matriz de apps, e medir CPU/abertura. Dar atenção ao item 1.3 (nome do dispositivo no card).

## Rodada 2
Resultado: PASS

Verificado de forma independente (snapshots regravados e lidos; `swift test`, lint estrito, `scripts/check.sh` e `scripts/check.sh --app` todos verdes):
1. Major (card "Saída"): corrigido. O snapshot agora mostra o ícone, "Saída", o nome do dispositivo ("Alto-falantes") e o chevron `›`. Confirmar de novo no ⏸2 (item 1.3 do roteiro), pois é onde o Menu real é desenhado.
2. Sair ignora cliques repetidos (`isQuitting`, `Composition.swift:89-96`): ok.
3. `.help` vazio removido; dica via overlay só sem controle de volume: ok.
4. `PermissionMonitor.refresh(onlyIfDenied:)` unificado: comportamento igual ao anterior (popover abre → só se negada; falha por silêncio → `onlyIfDenied: false`, `Composition.swift:68`). Meus testes e os do Dev passam com a nova chamada, incluindo "negada não é apagada por indeterminada".
5. `MenuItemRow` com um botão: ok (rodapé igual no snapshot).
6. Monitor `NSEvent` por slider mantido: aceito. Era achado Baixo, o código atual é correto (removido no `deinit`, filtra por janela e limites). Não bloqueia.
7. D2/D3/D4: aplicados (slider alinhado ao nome, saídas recuadas, fundo sutil na linha expandida); visual conforme o design.
8. Snapshots com chaves em vez de texto: aceito como limitação de teste; o catálogo foi conferido (32 chaves, todas com pt-BR) e o orquestrador confirmou o `pt-BR.lproj` do app.

Sem regressões encontradas. Pendente só o ⏸2 do usuário (`docs/MANUAL_TESTS.md`, seção M4).

## Rodada 3
Resultado: PASS

Verificado: `swift test` (276 testes de Swift Testing no maior alvo, tudo verde), lint estrito, `scripts/check.sh`, `scripts/check.sh --app`; snapshots regravados e lidos (card com nome e chevron; linha com falha mostra só o aviso).

- S4-M1 (nenhum tap sem confirmação): ok. `MixerStore.reconcile` só envia ao controlador `desired` quando `permission.status == .granted` (`MixerStore.swift:~330`); `retryAll`, reinício do coreaudiod e eventos de processos passam pelo mesmo `reconcile`, então não há outro caminho. O `PermissionMonitor` de produção nasce `.notDetermined` (`Composition.swift:33`). Só uma ação do usuário (`update`) chama a verificação sem a marca; adoção de volumes lembrados não chama. Testado: lembrado sem marca não pede nada nem cria tap; com marca e app lembrado tocando, verifica e reaplica sozinho (§14.7); app lembrado parado não verifica; negada apaga a marca e não cria tap; indeterminada não cria tap e fica pendente; pânico apaga a marca; `retryAll` negado não cria tap; mudo com permissão negada não muda nada.
- Marca malformada (`defaults write` com "yes", 1, 0, 2, "true", lista, dicionário, dados, 1.5): nunca vale `true` (só booleano real) e nunca dispara verificação. Testes novos em `Tests/VolumeCoreTests/QAM4Round3Tests.swift`.
- S4-B1 (Sair ≤ ~2 s, cliques repetidos, `didTerminate`): ok na leitura de `Composition.swift:89-117`; não testável sem abrir o app (roteiro atualizado).
- S4-B2, S4-B4, S4-B5: ok. Remoções de `currentStatus()`/`frontmostApplication()` retiraram só os testes dos próprios métodos removidos; os testes dos outros alvos só ganharam `grantedPermission()` (permissão já confirmada) onde o assunto não é permissão, sem afrouxar nenhuma expectativa.
- Observação 1 (Baixa, aceitável): a marca persistida pode ficar velha se o usuário zerar a permissão do Volume no macOS (ou o app for reassinado com outro certificado). Nesse caso, ao abrir com app lembrado tocando, a verificação automática pode fazer o macOS mostrar o pedido sem ação do usuário (§5). É raro e o pedido aparece com contexto; mitigação possível: só auto-verificar se a marca existir E a última sessão tiver terminado limpa. Não bloqueia.
- Observação 2 (informativa): a marca só é apagada pela verificação do store; negada detectada pelo vigia de silêncio (`Composition`) a mantém até o próximo lançamento, que então a apaga. Seguro.
- Roteiro ⏸2 atualizado: seção 2b (pedido só na primeira ação; reabrir reaplica sozinho; app lembrado parado), Sair < 2 s, linha com falha mostra só o aviso.
