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
