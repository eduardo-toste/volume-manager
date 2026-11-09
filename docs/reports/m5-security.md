## Etapa M5 — Segurança
Resultado: ENTREGUE — veredito **LIBERA** (nenhum achado Crítico, Alto ou Médio)

O que foi feito: auditoria do diff `git diff main` no branch `etapa/m5` (mudanças não commitadas): `LoginItemModel`, `WelcomeModel`, `MixerStore.requestAccess/recordUserCheck`, `AppDelegate` + `main.swift` (substituem o `@main App` SwiftUI), `AppWindows`, `SettingsContext`, `SettingsView`, `WelcomeView`, `WorkspaceAppInfoProvider.displayName(forBundleID:)`, `Composition` e os testes novos. Comparei com a SPEC §3.3, §3.4, §5, §8, §12.9 e com as decisões S4-M1/S41-M1 do `docs/PROGRESS.md`. Também inspecionei o bundle `build/Volume Manager.app`, que foi gerado depois da última mudança em `Sources/`/`Resources/`. Fiz uma medição em `/tmp/m5sec` (fora do repositório) do custo de `urlForApplication` com 1000 bundle IDs falsos. Nenhum código de produção foi alterado.

Como verificar:
- `git diff main --stat`
- `scripts/security-check.sh --app`
- `codesign -d --entitlements - "build/Volume Manager.app"`; `codesign -dv "build/Volume Manager.app"`; `plutil -p "build/Volume Manager.app/Contents/Info.plist"`
- `swift test --filter "WelcomeAndLoginItemTests"`
- `grep -rn "http\|URL(string" Sources | grep -v ^Sources/vmctl`

Verificações: check.sh não rodado inteiro por esta auditoria (só a suíte nova `WelcomeAndLoginItemTests`, 12/12 ✓) · security-check `--app` ✓ · cobertura não medida aqui

### Pontos conferidos sem problema

1. **Permissão (S4-M1 / S41-M1).**
   - `WelcomeModel.init` (`Sources/VolumeCore/WelcomeModel.swift:34-43`) só lê `permission.status`. Ao abrir, a janela não chama nenhuma verificação nem o pedido do sistema.
   - `allow()` (`WelcomeModel.swift:48-61`) só roda pelo botão "Permitir…" (`Sources/VolumeUI/WelcomeView.swift:1056-1061`). Ou seja, o pedido do sistema só aparece por ação do usuário.
   - `requestAccess()` (`Sources/VolumeCore/MixerStore.swift:384-388`) passa pela mesma contabilidade de `confirmAccessIfNeeded`, já fatorada em `recordUserCheck` (`MixerStore.swift:392-399`):
     - `.granted` grava a marca e chama `retryAll`;
     - `.denied` só apaga a marca se não for `silenceDenial`;
     - `.notDetermined`/`nil` não grava nada.
   - Nenhum tap é criado sem `verify()` == granted: o probe usa taps não mudos, privados e com duração limitada, sem mudança desde a M4.
   - Não há permissão nova: Info.plist só tem `NSAudioCaptureUsageDescription`, e não há entitlements.
   - "Negada" leva a `openPrivacySettings()`, que usa a URL fixa já auditada.
2. **Concorrência de verificações.** `PermissionMonitor.refresh` (`Sources/VolumeCore/PermissionMonitor.swift:41`) só deixa rodar uma verificação por vez (`isRefreshing`). A segunda recebe `nil`, e `recordUserCheck(nil)` não grava nada. Os dois casos foram analisados:
   - `accessTask` em curso + "Permitir…": a janela mostra "inconclusiva" (ver B-1) e a marca fica com o resultado da verificação que realmente rodou.
   - "Permitir…" em curso + ajuste de slider: o `accessTask` termina na hora, com `nil`. O `retryAll()` da verificação da janela cria os taps quando o resultado é granted.
   - Em nenhum caso a marca é gravada ou apagada por uma verificação que não rodou. `silenceDenial` continua impedindo que um "negada" ambíguo apague a marca.
3. **Login item.**
   - `LoginItemModel.init`/`refresh` só leem `SMAppService.mainApp.status` (`Sources/VolumeCore/LoginItemModel.swift:18-34`).
   - Só duas ações registram:
     - "Começar" (`WelcomeModel.start()`, `WelcomeModel.swift:65-69`), com o toggle ligado;
     - o toggle de Ajustes (`Sources/VolumeUI/SettingsView.swift:728-730`).
   - Fechar a janela de Boas-vindas não registra nada.
   - Falhas viram `lastChangeFailed`, e a tela mostra o estado real (`LoginItemModel.swift:37-45`).
   - `SMAppLoginItemService.setEnabled` não faz nada quando o item já está no estado pedido (`Sources/VolumeSystem/SMAppLoginItemService.swift:68-81`).
   - Os testes usam só fakes (`FakeLoginItemService` e `QuietLoginItem`, em `Tests/VolumeUITests/SettingsSnapshotTests.swift:12-18`). `SMAppLoginItemService()` só é instanciado em `Sources/VolumeManager/Composition.swift:45`, e `Composition()` não aparece em `Tests/`.
4. **Ciclo de vida / "nunca deixar mudo".**
   - O ⌘Q do menu principal novo vai para `composition.quit()` (`Sources/VolumeManager/AppDelegate.swift:39,55`). É o mesmo caminho do popover: `restoreAll()` com limite de 2 s, depois flush, `markCleanExit` e `terminate` (`Composition.swift:146-166`).
   - Isso melhora a situação anterior: o menu padrão do `@main App` SwiftUI ligava ⌘Q direto a `NSApp.terminate(_:)`, sem passar por `restoreAll`.
   - Os outros caminhos de término não mudaram:
     - logout, desligar ou um Apple Event "quit" chamam `terminate` direto, sem `applicationShouldTerminate`, e `SessionLifecycleObserver` faz flush e marca saída limpa;
     - travamento e Forçar Encerramento contam com taps e aggregate devices ligados ao processo e privados (`kAudioAggregateDeviceIsPrivateKey: true`, `Sources/VolumeAudio/CoreAudioTapSession.swift:179`), que somem com ele.
   - Reabrir o app só abre os Ajustes (`AppDelegate.swift:20-25`).
5. **URLs e dados não confiáveis.**
   - O único link novo é constante: `https://github.com/eduardo-toste/volume-manager/releases`, aberto via `NSWorkspace.open` (`Composition.swift:123-127`). Abre no navegador do usuário, o app não faz conexão, e isso segue §12.9.2/§13.4.
   - Não há outra URL em `Sources/` (fora `vmctl`) nem em `Localizable.xcstrings`.
   - `displayName(forBundleID:)` (`Sources/VolumeSystem/WorkspaceAppInfoProvider.swift:97-105`):
     - sanitiza a chave;
     - procura o app por LaunchServices;
     - reutiliza `appName(atAppPath:)`, que valida o caminho e passa o nome por `TextSanitizer.clean` (até 200 caracteres).
   - Os bundle IDs lembrados chegam das preferências já filtrados por `ProcessGrouping.validBundleID`: só ASCII `[A-Za-z0-9._-]` e tamanho limitado (`Sources/VolumeCore/SettingsModel.swift:136-147`). O total também é limitado (`maxRememberedApps` = 1000).
   - Na tela, tudo aparece como `Text(verbatim:)` com `lineLimit(1)` (`SettingsView.swift:796-800`). Não há interpretação, markup nem URL.
   - Versão e build vêm do Info.plist do próprio app.
   - `onboardingCompleted` e `launchAtLogin` passam por `PreferenceValidation.bool`. Um `defaults write` malicioso consegue no máximo esconder a janela de Boas-vindas, e o toggle de login sempre mostra o estado real do `SMAppService`.
6. **Bundle / build.**
   - Não há entitlements: a assinatura não tem nenhum.
   - As flags são `adhoc,runtime`, ou seja, Hardened Runtime sem exceções.
   - O Info.plist não muda além do esperado (`LSUIElement`, `NSPrincipalClass`, a usage description de áudio).
   - O diff não toca em `scripts/`, `Package.swift`, entitlements nem Info.plist de origem, e não adiciona dependências.
   - `security-check.sh --app` termina OK: análise estática de `Sources/`, segredos, dependências (zero), Resources e bundle.
   - Não há `print(`, force unwrap, `try!` nem `as!` no código novo.

### Achados

**Crítico:** nenhum. **Alto:** nenhum. **Médio:** nenhum.

**Baixo**

- **B-1 — "Permitir…" mostra "inconclusiva" quando já existe uma verificação em curso.**
  - Evidência: `WelcomeModel.swift:59` mapeia `nil` (a verificação não rodou porque `PermissionMonitor.refresh` estava ocupado, `PermissionMonitor.swift:41`) para `.inconclusive`. O comentário de `MixerStore.requestAccess` (`MixerStore.swift:381-383`) documenta esse `nil`, mas a UI o trata como "não deu para concluir".
  - Impacto: só de UI. A marca não é afetada e nenhum tap é criado. O usuário pode ver "inconclusiva" enquanto a verificação disparada por um slider termina com granted, e um segundo clique roda outro probe de ~500 ms sem necessidade. A segurança não piora.
  - Recomendação (opcional): tratar `nil` como "ainda verificando". Por exemplo, a janela pode reler `permission.status` depois de `await` e mostrar `.allowed` quando ele for `.granted`. Não precisa de tipo novo.

**Informativo**

- **I-1 — Superfície pequena e proporcional.**
  - Tipos novos: `LoginItemModel`, `WelcomeModel`, `SettingsContext` (injeção) e `AppWindows` (janelas AppKit trazidas para a frente num app sem Dock). Cada um tem um uso real hoje.
  - `RememberedRow.rows` roda a cada `body` do painel Aplicativos, sem cache. Medi 1000 bundle IDs inexistentes por `urlForApplication`: cerca de 12 ms (`/tmp/m5sec`). Mesmo no limite de 1000 entradas plantadas via `defaults write`, não há DoS relevante. Não precisa mudar.
- **I-2 — "negada" na janela de Boas-vindas com `silenceDenial` ativo não apaga a marca.**
  - Evidência: `MixerStore.swift:397`. É a regra herdada de `confirmAccessIfNeeded` e segue S41-M1, já que o estado ambíguo do vigia de silêncio prevalece.
  - Na prática a janela só aparece na primeira execução, quando ainda não há marca. Fica registrado só para rastreio.
- **I-3 — SPEC §3.4 diz que as Boas-vindas aparecem também "se a permissão de áudio ainda não foi decidida".**
  - A implementação mostra a janela só enquanto `onboardingCompleted == false` (`Composition.swift:106-112`).
  - Do lado da segurança isso é conservador: a janela aparece menos e não pede nada sozinha. Cabe ao QA ou ao orquestrador decidir se é um desvio funcional.
- **I-4 — Término sem `applicationShouldTerminate`.**
  - Logout, desligar ou um "quit" via Apple Event não passam por `restoreAll()`, como já acontecia na M4.
  - Isso é aceitável, porque os taps e aggregate devices são privados e ligados ao processo (§8: travamento e Forçar Encerramento também devolvem o áudio).

Problemas / desvios da SPEC: nenhum de segurança. I-3 é uma observação funcional para o QA (`Sources/VolumeManager/Composition.swift:107`).

Precisa do usuário: nada para a segurança. Os critérios manuais da PLAN (Boas-vindas real, prompt do sistema e `SMAppService.mainApp.status == .enabled` depois de "Começar") ficam para o QA ou o usuário: esta auditoria não abriu o app real nem registrou login item.

**Veredito: LIBERA.**

---

## Etapa M5 (volta 2) — Segurança
Resultado: PASS (veredito abaixo)

O que foi feito: reauditoria de `git diff main` + `git status` no branch `etapa/m5`, sem commit, cobrindo os quatro pontos alterados desde a volta 1. O app real não foi aberto e nenhum som foi tocado.

Como verificar:
- `scripts/build-app.sh && scripts/security-check.sh --app`
- `scripts/check.sh`
- `codesign -d --entitlements - --verbose=2 "build/Volume Manager.app"`
- `/usr/libexec/PlistBuddy -c Print "build/Volume Manager.app/Contents/Info.plist"`

Verificações: check.sh ✓ (158 testes; o único "known issue" é o já registrado em `SecurityM21Tests.swift:33`) · security-check --app ✓ · cobertura: mínimo aplicado pelo check.sh, sem alteração.

### Pontos revisados

1. **Permissão (B-1).**
   - `WelcomeModel.allow()` (`Sources/VolumeCore/WelcomeModel.swift:48-66`) só roda pelo botão "Permitir…" (`Sources/VolumeUI/WelcomeView.swift:102`). Com `nil`, chama `refreshAccess()` e só mostra "inconclusiva" se nada foi concluído. **B-1 resolvido.**
   - `refreshAccess()` (`WelcomeModel.swift:70-76`) só lê `permission.status` (`PermissionMonitor.swift:11`, propriedade armazenada) e muda apenas `access`, um estado de UI. Não chama `permission.refresh`, `store.requestAccess` nem o serviço.
   - O único gatilho automático é `NSApplication.didBecomeActive` (`WelcomeView.swift:52-55`), e ele não verifica nem pede nada.
   - `audioPermissionConfirmed` continua sendo escrito só em `MixerStore.swift:105,395,397`, caminhos da M4 que não mudaram. Nem `refreshAccess` nem o ramo `nil` de `allow()` tocam nele.
   - Não há outro caminho novo que verifique a permissão. `MenuBarController.swift:84` (`refresh(onlyIfDenied: true)` ao abrir o popover) é da M4 e depende de ação do usuário.
2. **Build / ícone** (`scripts/build-app.sh:41,44-54`).
   - Usa só ferramentas do sistema: `sips`, `iconutil` e `/usr/libexec/PlistBuddy`. Nada é baixado nem instalado.
   - Os caminhos são fixos e relativos à raiz do repositório (`cd "$(dirname "$0")/.."`). As variáveis são citadas, e os laços usam só inteiros literais.
   - O temporário `build/AppIcon.iconset` é removido antes e depois. Confirmei que não sobra depois do build.
   - `PlistBuddy Add` falha (por `set -e`) se a chave já existir, o que encerra o build em vez de corrigir em silêncio.
   - `Resources/AppIcon-1024.png` é um PNG 1024×1024 RGBA com os chunks IHDR, sRGB, IDAT e IEND. Não tem metadados (tEXt, iTXt, eXIf), então não vaza caminho nem dado.
   - O bundle tem flags `adhoc,runtime` e nenhum entitlement. O Info.plist só ganhou `CFBundleIconFile = AppIcon`, e `Contents/Resources` tem só `AppIcon.icns` e `pt-BR.lproj`.
   - O diff não toca em `security-check.sh`, `check.sh`, `Package.swift`, `Resources/Info.plist` nem nos entitlements. A exclusão de `*.icns` na varredura de texto (`security-check.sh:151`) já existia e não foi relaxada.
3. **Remoções.**
   - `MenuBarIconStyle`, `SettingsModel.menuBarIconStyle` e `SettingsModel.launchAtLogin` saíram de `Key`, `load()` e `save()`. `grep` não encontra mais nada que leia `menuBarIconStyle` ou a chave `launchAtLogin`.
   - As chaves antigas ficam órfãs no UserDefaults e nunca são lidas, então um `defaults write` nelas não tem efeito.
   - `WelcomeModel.launchAtLogin` é estado em memória, começa em `true` e não é persistido.
   - `LoginItemModel` tem só `init(service:)` (`LoginItemModel.swift:16-19`), que lê o estado real do sistema e não registra nada. O registro só acontece em `start()` ("Começar") ou pelo toggle. Nada novo lê dado não validado.
4. **Ícone da barra** (`MenuBarController.swift:95-117`).
   - É desenhado com `NSBezierPath` em uma `NSImage` template de 18×18, com coordenadas constantes. Não carrega recurso, arquivo nem dado externo.

### Achados

**Crítico:** nenhum. **Alto:** nenhum. **Médio:** nenhum. **Baixo:** nenhum novo. B-1 fechado.

**Informativo**
- **I-5 — `refreshAccess()` não rebaixa "Permitido".**
  - Evidência: `WelcomeModel.swift:73`, `case .denied: break`. Se o monitor passar de granted para denied (só depois de uma verificação explícita), a linha continua mostrando "Permitido".
  - Impacto: só de UI. A decisão sobre taps usa `permission.status` e a marca, nunca `WelcomeModel.access`. Na prática a janela só aparece na primeira execução.
  - Não precisa mudar.
- I-1 a I-4 da volta 1 continuam válidos e não mudaram.

Problemas / desvios da SPEC: nenhum de segurança.

Precisa do usuário: nada para a segurança. A conferência visual do ícone e da janela real fica com o QA ou o usuário.

**Veredito (volta 2): LIBERA.**

---

## Etapa M5.1 — Segurança
Resultado: LIBERA COM RESSALVAS (só Baixo/Informativo; nada bloqueia)

Esta avaliação substitui a anterior, que cobria a versão com "Permitido pela marca" (revertida).

O que foi feito: revisão do `git diff main` no branch `etapa/m5.1`: `SystemAudioAccessProbe.swift` (escuta curta também sem nada tocando, `listen(to:)` extraída), `WelcomeModel.swift` (revertido o "Permitido pela marca"), `AppDelegate.swift`, `AppWindows.swift`, `Localizable.xcstrings`, `WelcomeAndLoginItemTests.swift` e o novo `Tests/VolumeAudioTests/AccessProbeIdleTests.swift`. Levantei todos os chamadores de `verify()` e `permission.refresh`. Nenhum código alterado. O app real não foi aberto e nenhum som foi tocado.

Como verificar: `git diff main` · `scripts/check.sh` · `scripts/security-check.sh --app` (bundle de 16:29, mais novo que todas as fontes alteradas)

Verificações: check.sh ✓ (159 testes, 31 suítes) · security-check --app ✓ (análise estática, segredos, dependências zero, entitlements/Info.plist, bundle) · cobertura: portão do check.sh ✓

### Regra S4-M1 (o pedido nunca aparece sozinho): chamadores de `verify()`
Cadeia: `PermissionMonitor.refresh` (`PermissionMonitor.swift:40-49`, uma por vez via `isRefreshing`) → `AudioPermissionService.request()` (`AudioPermissionService.swift:34`) → `SystemAudioAccessProbe.verify()` (`SystemAudioAccessProbe.swift:108-114`). `verify()` lê a lista de "tocando" **na hora** (`:109`, `ProcessCatalog.playingObjectIDs`, o mesmo critério `IsRunningOutput` que alimenta `groups.isPlaying`). Se a lista vier vazia, agora escuta `testTarget()` com tap, aggregate e IO (`:112-113`), e esse caminho **pode mostrar o pedido** quando o TCC está "não decidido".

| # | Caminho | Disparo | Garante "tocando" na decisão? | Pode chegar a `verify()` com a lista vazia? |
|---|---|---|---|---|
| 1 | Início com a marca: `reconcile` → `confirmAccessIfNeeded` (`MixerStore.swift:516-520` → `:371-379`, refresh em `:375`) | automático, exige `audioPermissionConfirmed` | sim (`desired.contains { isPlaying }`, `:517`) | **sim, por corrida**: entre a decisão (`groups`, que só muda com o evento de processos) e a leitura em `:109` há criação de `Task`, salto para o actor e, se outra verificação estiver em curso, espera. Se o app parou nesse meio-tempo, a escuta vai para um alvo ocioso. |
| 2 | Vigia de silêncio: `Composition.swift:90` → `checkSilentTap` (`MixerStore.swift:170-183`, refresh em `:172`) | automático, sem orçamento | só no evento (o controlador viu `IsRunningOutput`); os eventos vêm em fila (`Composition.swift:86-91`), então pode haver atraso | **sim, por corrida** (o app pausa logo depois dos 5 s de silêncio, cenário típico). Só existe com tap vivo, ou seja, com `status == .granted` nesta sessão. |
| 3 | Reverificação periódica após "negada" do vigia: `recheckWhileDenied` (`MixerStore.swift:199-211`) → `runAutomaticCheck` (`:215-221`, refresh em `:220`) | automático, orçamento de 3 (`:217`) | sim (`groups.contains(where: \.isPlaying)`, `:207`) | **sim, por corrida** |
| 4 | Reverificação quando um som volta: `updateGraceTimers` (`MixerStore.swift:444-446`) → `runAutomaticCheck` | automático, mesmo orçamento | sim (som novo começou) | **sim, por corrida** |
| 5 | Abrir o popover: `MenuBarController.swift:84`, `refresh(onlyIfDenied: true)` | gesto do usuário, só com `status == .denied` (`PermissionMonitor.swift:41`) | **não**: não olha se algo toca | **sim, sem corrida**: com `.denied` e nada tocando, antes era tap sem IO (sem pedido) e agora é escuta. |
| 6 | Ajustar um app: `update` → `defer confirmAccessIfNeeded` (`MixerStore.swift:355`) | ação do usuário | — | sim; permitido (ação do usuário) |
| 7 | "Permitir…" das Boas-vindas: `WelcomeView.swift:102` → `WelcomeModel.allow()` (`WelcomeModel.swift:56`) → `MixerStore.requestAccess` (`:384-388`) | ação do usuário | — | sim; é o objetivo da mudança (SPEC §3.4) |
| 8 | `vmctl probe-permission` (`Sources/vmctl/ReadCommands.swift:57`) | comando do usuário no terminal | — | sim; permitido. A mensagem de `.indeterminate` (`:64`) continua correta. |
| — | Testes (`candidates`) | — | — | nunca toca processos do usuário (`SystemAudioAccessProbe.swift:112`, `candidates == nil`); provado por `AccessProbeIdleTests` |

Conclusão: **sim, os caminhos automáticos 1 a 4 podem chegar à escuta ociosa por corrida, e o 5 chega sem corrida.** Mas isso **não cria cenário novo de pedido sem ação do usuário**. Os motivos:
- O pedido só aparece com o TCC "não decidido". Nos caminhos 1 a 4, a mesma condição de partida (marca velha, ou TCC zerado com o app aberto) **sem** a corrida já cai na escuta dos apps tocando (`listen(to: playing)`, que já existia na `main`), e essa escuta também usa tap, aggregate e IO e também mostra o pedido. A corrida só troca o alvo da escuta, não cria a condição. É o risco já aceito em `docs/PROGRESS.md:35` ("na abertura com a marca ligada e o TCC zerado, a sonda automática pode mostrar o pedido") e em S41R-B1 / S41b-B1 (`m4.1-security.md:191,247`).
- O orçamento de 3 (`MixerStore.swift:217`) continua limitando 3 e 4. O caminho 2 só existe com permissão já concedida nesta sessão.
- Sem a marca, nenhum caminho automático (1, 3, 4) roda: 1 exige `audioPermissionConfirmed` (`:516`), e 3 e 4 exigem `silenceDenial`, que só nasce de um tap vivo, ou seja, de permissão concedida. A frase da regra "sem a marca, só ação do usuário dispara a verificação" continua valendo.

### Outros pontos verificados
- **IOProc** (`SignalProbeState.swift:11-30`, sem mudança): só lê, faz OR de bits num `UInt32` local e grava num `Atomic<Bool>` relaxado. Não aloca, não usa lock, não faz log, não usa `async` nem Objective-C. Os limites vêm de `mNumberBuffers` e de `mDataByteSize / 4`. O ponteiro `client` é mantido vivo por `withExtendedLifetime(state)` até o `teardown()` (`SystemAudioAccessProbe.swift:140,145`).
- **Teardown em todos os caminhos**: falha em qualquer etapa → `teardown()` (`:139-140`). Caminho normal: `try? await clock.sleep` (`:144`) também retorna se a `Task` for cancelada, e o `teardown()` (`:145`) roda sempre. `TapPipeline.teardown()` (`TapPipeline.swift:75-92`) para o IO, destrói o IOProc, o aggregate e o tap, nessa ordem. Não sobra aggregate.
- **Nenhum som / nunca mudo**: o tap é `.unmuted` e privado (`:125-126`), sobre `monoMixdownOfProcesses` de alvos específicos, **nunca global**. O aggregate é privado, só com a lista de taps, sem subdispositivo de saída (`:128-136`), então não produz som. O processo ocioso escutado continua tocando nativo.
- **Nada gravado**: só o bit "viu amostra ≠ 0" (SPEC §12.9.3).
- **Dados de outros processos**: o alvo vem de `catalog.objectIDs()` filtrado por PID ≠ o nosso (`:62`). O único dado usado é o `AudioObjectID`; nome, bundle ID e caminho não são lidos. Um processo que some entre a escolha e o tap dá `.indeterminate` (`verdictAfterFailure` + `exist`, `:95-102,142`), nunca `.denied`. Escutar um alvo ocioso dá `sawSignal == false` e `stillPlaying == false`, ou seja, `.indeterminate` (`:11-14`): um alvo ocioso nunca vira "negada".
- **Concorrência**: `AudioPermissionService` é actor e reentrante durante o `sleep`, mas o `isRefreshing` do `PermissionMonitor` (MainActor) impede duas escutas do app ao mesmo tempo.
- **`WelcomeModel`** (`WelcomeModel.swift:63`): o revert fecha o S51-B1 anterior. Só `.granted` desta sessão mostra "Permitido", e a marca não é lida nem gravada pela janela. Os testes novos (`WelcomeAndLoginItemTests.swift:96-116`) provam que, com a marca `true`, um inconclusivo continua inconclusivo e não grava nada.
- **`AppDelegate`/`AppWindows`**: `Task { @MainActor }` com `menuBar` fraco e sem ciclo. `orderFrontRegardless()` é API pública, chamada só quando o próprio app abre a janela. Não muda `level` nem `collectionBehavior`.
- **Entitlements, Info.plist, rede, dependências, segredos**: sem mudança. O security-check --app passou.

### Achados
**Crítico:** nenhum. **Alto:** nenhum. **Médio:** nenhum.

**Baixo**
- **S51-B1 — a escuta ociosa também vale para os caminhos automáticos e para o popover "negado".**
  - Evidência: `SystemAudioAccessProbe.swift:110-113` não sabe quem chamou. Os caminhos 1 a 4 da tabela chegam lá por corrida (`MixerStore.swift:375,172,220` depois das decisões em `:517,207,444`). O caminho 5 (`MenuBarController.swift:84`) chega sem corrida quando nada toca.
  - Impacto: com o TCC "não decidido" (marca velha depois de rebuild ad hoc ou de reset do TCC), o pedido do sistema pode aparecer sem um clique em "Permitir…". Não é cenário novo nos caminhos 1 a 4: com a mesma condição e o app ainda tocando, a escuta da `main` já mostrava o pedido (risco aceito, `PROGRESS.md:35`). No caminho 5 o cenário é novo, mas exige três coisas ao mesmo tempo: "negada" nesta sessão, TCC zerado depois, e o próprio usuário abrir o popover, o que é um gesto dele na tela "sem permissão". Nada disso põe o áudio em risco: o tap é unmuted, nada é gravado e nenhum tap de usuário nasce sem `.granted`. Em release com Developer ID o TCC usa o requisito designado, então rebuilds não zeram a permissão. O caso do teste do usuário é exclusivo de builds ad hoc.
  - Recomendação (opcional, a mais simples que fecha a regra ao pé da letra): passar um `Bool` só pela cadeia que já existe, sem tipo novo. Por exemplo, `verify(idleTargetAllowed:)` → `request(…)` → `refresh(onlyIfDenied:, userAction:)`, com `true` apenas em `MixerStore.requestAccess` (`MixerStore.swift:385`) e em `update` → `confirmAccessIfNeeded` (`:355`, ação do usuário). Os outros caminhos ficam com o comportamento da `main` (tap sem IO, sem pedido). Se o orquestrador preferir não adicionar o parâmetro agora, aceitar e registrar junto do risco já aceito em `PROGRESS.md:35` e da pendência da marca velha da M6 (`PROGRESS.md:44`).
- **S51-B2 — o texto inconclusivo promete uma verificação automática que não existe sem a marca.**
  - Evidência: `Localizable.xcstrings:689`, "O Volume Manager confirma o acesso sozinho assim que algum app tocar som.". Depois de um "Permitir…" inconclusivo a marca continua `false` (`MixerStore.swift:392-400` só a grava com `.granted`), e a auto-verificação ao tocar exige a marca (`MixerStore.swift:516`). Na prática a confirmação só vem quando o usuário ajustar um app (`:355`).
  - Impacto: só de texto, sem risco de áudio. O risco é de processo: alguém "consertar" o texto tornando a verificação automática sem a marca, e isso violaria a regra S4-M1.
  - Recomendação: trocar o texto por algo fiel, como "Pedido enviado ao macOS. O acesso é confirmado quando você ajustar um app que esteja tocando.", **sem** mudar o comportamento.

**Informativo**
- **S51-I1** — `orderFrontRegardless()` põe a janela à frente de outros apps mesmo sem ativação. É o comportamento pedido e não é persistente.
- **S51-I2** — o teste novo cobre só o ramo do seam (`candidates` vazio). A escuta ociosa real (alvo ≠ nosso PID) não tem teste automatizado, e de propósito: ela tocaria em processos do usuário. Fica para a verificação manual do usuário.
- I-5 (`refreshAccess` não rebaixa "Permitido") continua válido e não mudou.

Problemas / desvios da SPEC: nenhum de segurança. A mudança cumpre a SPEC §3.4 (o clique dispara o pedido). S51-B1 é uma leitura estrita da regra S4-M1 de `PROGRESS.md:62`, dentro de um risco já aceito.

Precisa do usuário: decidir (via orquestrador) se o S51-B1 é corrigido agora com o parâmetro proposto ou se é aceito junto do `PROGRESS.md:35`. Teste manual do "Permitir…" sem nada tocando (já feito pelo usuário, conforme os logs do `tccd`).

**Veredito (M5.1): LIBERA COM RESSALVAS** (S51-B1 e S51-B2 são Baixo; nenhum bloqueia).

### M5.1 — reavaliação de S51-B1/B2

Escopo: `git diff main` no branch `etapa/m5.1` (sem commit), só a correção de S51-B1 e S51-B2 e o ajuste do teste do QA. Código não alterado.

**(a) Nenhum caminho automático passa `true`, nem por padrão.**
- Padrões, todos `false`: `PermissionService.request()` → `request(userAction: false)` (`PermissionService.swift:22-26`); `PermissionMonitor.refresh(onlyIfDenied:userAction: Bool = false)` (`PermissionMonitor.swift:40`); `MixerStore.confirmAccessIfNeeded(userAction: Bool = false)` (`MixerStore.swift:371`). `AudioAccessProbe.verify(idleTargetAllowed:)` não tem padrão; a implementação padrão do protocolo ignora o valor e só usa `probe()` (`AudioAccessProbe.swift:33-35`).
- Caminhos automáticos, todos com o padrão: silêncio do tap `MixerStore.swift:172`; nova verificação depois de negada `:220`; auto-verificação ao tocar com a marca `:519` (`confirmAccessIfNeeded()` sem argumento); popover "negado" `MenuBarController.swift:84`.
- `false` no probe (`SystemAudioAccessProbe.swift:115-117`): mesmo `probe(target:)` da `main` (tap sem IO, sem aggregate). A única diferença é o `candidates == nil` em `:112`, que só vale para o seam de testes (`SystemAudioAccessProbe.swift:41-50`). Assim, um teste nunca chega a um processo do usuário.

**(b) `true` só nasce de ação do usuário.**
- `MixerStore.requestAccess()` (`MixerStore.swift:385`), chamado só por `WelcomeModel.allow()` (`WelcomeModel.swift:56`), o botão "Permitir…".
- `update` → `confirmAccessIfNeeded(userAction: true)` (`MixerStore.swift:355`). `update` é privado e só é chamado por `setVolume`, `toggleMute` e `route` (`:249,254,261`). Esses três só são chamados pela linha do app na UI (`AppRowView.swift:40,117,133,159,181,186`).
- `vmctl probe-permission` (`ReadCommands.swift:57`): ferramenta de linha de comando, rodada pelo usuário.
- Agrupamento: se uma verificação automática já está rodando, o `true` de um ajuste é descartado por `accessTask == nil` (`MixerStore.swift:372`). O erro vai para o lado seguro: no pior caso o estado continua inconclusivo.
- Testes: `onlyTheUsersClickMayListenToAnIdleProcess` e `adjustingAnAppIsAUserActionButTheAutomaticCheckAtStartIsNot` (`WelcomeAndLoginItemTests.swift`) registram `userActions` e provam `[false]` no automático e `[true]` no clique e no ajuste.

**(c) Nada mais mudou de comportamento.** Fora o parâmetro, o diff de `Sources/` é o mesmo da revisão M5.1 acima: `WelcomeModel.swift:63`, `AppDelegate.swift:15-19` e `AppWindows.swift:68` (S51-I1). S51-B2: `Localizable.xcstrings:689` agora diz "Pedido enviado ao macOS. O acesso é confirmado quando você ajustar um app que esteja tocando.". O texto é fiel a (b), e a regra da marca não mudou (`MixerStore.swift:516`). Ajuste do teste do QA (`QAM51WelcomeTests.swift:22`, `welcome.refreshAccess()`): ele simula a reativação da janela, um caminho real. O teste continua exigindo `.allowed`, só deixa de depender da ordem de agendamento. Não enfraquece nada de segurança. Rodei 15 vezes seguidas, 0 falhas.

**(d) Verificações.** `scripts/security-check.sh --app`: OK (análise estática, segredos, dependências zero, entitlements/Info.plist, bundle). `swift test --filter` em WelcomeAndLoginItemTests (16), QAM51WelcomeTests (1), AudioPermissionVerdictTests (3), QAM4PermissionFlowTests (4) e AccessProbeIdleTests (1): todos passaram.

S51-B1: **fechado**. S51-B2: **fechado**. Nenhum achado novo. Proporcionalidade: só um `Bool` pela cadeia que já existia, sem tipo novo, como recomendado.

**Veredito (reavaliação M5.1): LIBERA.**
