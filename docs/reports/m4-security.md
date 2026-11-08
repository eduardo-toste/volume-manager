## Etapa M4 — Segurança
Resultado: **PASS** (LIBERA). Não há achado Crítico nem Alto. Encontrei 1 Médio e 5 Baixos.

Escopo: `git diff main` e os arquivos não rastreados da M4: `Sources/VolumeUI/*`, `Sources/VolumeManager/{Composition,VolumeManagerApp}.swift`, `Sources/VolumeCore/{PermissionMonitor,MixerStore,AppAudioController}.swift` e `Resources/Localizable.xcstrings`. Para conferir a integração, também li `AudioPermissionService`, `SystemAudioAccessProbe`, `CoreAudioAppController` (apply, reconcile, fail, restoreAll), `KillList`, `WorkspaceAppInfoProvider`, `TextSanitizer`, `OutputDevice`, `DeviceCatalog.outputDevices` e `SessionLifecycleObserver`.

Não abri o `build/Volume.app`. Não criei nenhum tap, não toquei nenhum som e não iniciei nenhum processo de áudio. Não instalei nem baixei nada. Não alterei `Sources/`, `scripts/` nem `Resources/`. O único arquivo criado é este relatório.

### Como verificar
```
scripts/check.sh --app        # lint estrito, build sem avisos, swift test, build-app, security-check --app → OK
plutil -p build/Volume.app/Contents/Info.plist | grep -i usage   # só NSAudioCaptureUsageDescription
codesign -d --entitlements - build/Volume.app                    # [Dict] vazio
codesign -dv build/Volume.app 2>&1 | grep flags                  # flags=0x10002(adhoc,runtime)
strings build/Volume.app/Contents/MacOS/VolumeManager | grep -i "http\|systempreferences"   # só as 2 URLs fixas
grep -rn "addGlobalMonitor\|CGEvent\|AXIsProcess\|IOHID" Sources                            # vazio
```

---

### 1. Pontos pedidos

| Ponto | Situação | Evidência |
|---|---|---|
| Monitor `NSEvent` | **OK.** É só `addLocalMonitorForEvents(matching: .scrollWheel)`, que vê apenas eventos já entregues ao próprio app e não exige Monitoramento de Entrada nem Acessibilidade. Não existe monitor global, `CGEventTap` ou `IOHID` em `Sources/`. O monitor é removido ao sair da janela e no `isolated deinit`. A closure captura `[weak self]`, então não há ciclo de retenção. Antes de consumir um evento, confere a janela e os limites da view. `MainActor.assumeIsolated` é correto, porque o AppKit chama monitores locais na thread principal. | `VolumeInput.swift:57-80` |
| URLs abertas | **OK.** São duas, as duas literais e fixas: Som (`Composition.swift:79`) e Privacidade › Gravação de Áudio do Sistema (`AudioPermissionService.swift:16-17`). Nenhuma recebe dado externo e não há `Link(` nem URL montada a partir de dados. As duas aparecem no binário e nenhuma URL `http` aparece. Não há rede. | `strings` no binário |
| Dados de outros processos na UI | **OK.** Nomes de app passam por `TextSanitizer`, que limita a 200 caracteres e remove Cc, Cf, bidi, tags e BOM (`ProcessGrouping.swift:120-124`). Nomes e UIDs de dispositivo são sanitizados no `OutputDevice.init` (`OutputDevice.swift:38-39`). Toda exibição usa `Text(verbatim:)`, ou `Label(String, …)`/`accessibilityLabel(String)`, que não interpretam Markdown. Os nomes entram em `String(format:)` só como argumento, nunca como formato: os formatos `%1$@ … %2$lld` vêm do catálogo. `lineLimit(1)` impede um nome gigante de deformar o popover. O próprio Volume é excluído por PID e por bundle ID. O ícone vem de `NSWorkspace.icon(forFile:)`, que lê recursos e não carrega nem executa código do outro app, com cache LRU de 200. Restos: S4-B3 e S4-B4. | ver achados |
| Fluxo de permissão | **OK no que a M4 promete, com uma lacuna da SPEC (S4-M1).** Abrir o popover só verifica quando o estado já é `.denied` (`PermissionMonitor.swift:32`). Nesse caso a escolha já foi feita, então o sistema não mostra pedido. "Sem permissão" só aparece depois de `verify()` (`service.request()` → `probe.verify()`). `.indeterminate` mantém o último estado (`AudioPermissionService.swift:43`). `onGranted` → `retryAll` só roda na transição negada→concedida (`PermissionMonitor.swift:37`). "Permitir…" só abre os Ajustes. As verificações usam taps `.unmuted`, que não mudam o que o usuário ouve. | `PermissionMonitor.swift`, `MenuBarPopover.swift:43-46,143` |
| §4.6: Sair, Restaurar, falhas | **OK.** No Sair a ordem é `restoreAll` → `flush` → `markCleanExit` → `terminate`, e `isQuitting` ignora cliques repetidos (`Composition.swift:89-102`). `restoreAll` é `nonisolated`: chama `killList.stopAll()` **antes** de qualquer `await`, então os taps são destruídos mesmo se o ator estiver ocupado. "Restaurar áudio original" zera estados e falhas e chama `restoreAll` direto, sem passar pela fila (`MixerStore.swift:171-179`). Uma falha destrói o tap (som original) e registra o app sem laço; nova tentativa só por ação do usuário (`MixerStore.swift:192-195`) ou por concessão. Se `restoreAll` travar, ninguém fica mudo, mas o app não sai pelo menu: S4-B1. | ver S4-B1 |
| Concorrência estrita | **OK.** Não há `@unchecked Sendable` nem `nonisolated(unsafe)` novos. `PermissionMonitor`, `Composition`, `PopoverContext` e `AppDelegate` são `@MainActor`. As `Task` do `Composition` herdam o MainActor. `static var isQuitting` fica isolado ao MainActor. `restoreAll` roda fora da main (tools 6.0, sem `NonisolatedNonsendingByDefault`), então um HAL lento não congela a UI. Zero avisos. | `scripts/check.sh` |
| Entitlements, Info.plist, bundle | **OK.** O arquivo de entitlements é um `<dict/>` vazio, sem nenhuma exceção de Hardened Runtime. O runtime está ligado (`flags=0x10002(adhoc,runtime)`). O Info.plist tem só a chave de uso `NSAudioCaptureUsageDescription`, com o texto da SPEC §5, e `LSUIElement`. O bundle contém o executável, `pt-BR.lproj/Localizable.strings` e a assinatura, sem `vmctl` nem dylibs. `otool -L` lista só bibliotecas do sistema. | comandos acima |

---

### 2. Achados

#### Médio

**S4-M1: nenhum tap de usuário espera a confirmação da permissão (SPEC §4.6: "Antes de criar qualquer tap de usuário, a permissão precisa ter sido confirmada por uma verificação de sinal").**
- Evidência: o `MixerStore` não recebe nem consulta a permissão (`Composition.swift:33-36`), e o `CoreAudioAppController.apply/reconcile` também não (`CoreAudioAppController.swift:127-172`). O `PermissionMonitor` começa em `.notDetermined` (`PermissionMonitor.swift:11`) e só fica sabendo de uma negação **depois** que um tap de usuário passou 2 s em silêncio (`Composition.swift:64-70` ← `watchdogTick` `.silent`, `CoreAudioAppController.swift:307`). Não existe chamada a `verify()` antes do primeiro `reconcile`.
- Impacto: o pior caso continua sendo fail-open, mas passa por um mudo curto.
  - **Permissão negada ou revogada:** cada app com volume, mudo ou rota lembrados que começa a tocar recebe um tap `mutedWhenTapped` que entrega só zeros. O app fica **mudo por ~2 s** até o vigia destruir o tap. Isso se repete a cada inicialização, para cada app, e de novo depois de um reinício do `coreaudiod` (`failed.removeAll()`, `CoreAudioAppController.swift:324`).
  - **Permissão ainda não decidida** (nunca respondida, ou zerada pelo usuário): o pedido do TCC aparece **ao iniciar, sem ação do usuário**, se houver estado lembrado. O app fica mudo enquanto o pedido está na tela, até o vigia agir. A SPEC §5 prevê o pedido "na primeira criação de tap", mas pensado como resultado de uma ação: Boas-vindas na M5 ou mexer num slider.
  - O mudo é limitado (≤ ~2 s por app, sem laço) e o som volta sozinho. Por isso fica em Médio e não em Alto. Mas a SPEC trata essa verificação como o controle principal e o vigia de silêncio como rede de segurança, e hoje só a rede de segurança existe.
- Recomendação ao Dev: a composição deve **bloquear a criação de taps** enquanto `permission.status != .granted`. O `MixerStore` publica o estado normalmente, mas o `desired` enviado ao controlador sai vazio até haver concessão confirmada.
  - Na inicialização, rodar `verify()` (tap `.unmuted`, não silencia nada) só se a permissão já tiver sido decidida e houver estado lembrado a aplicar.
  - Com `.notDetermined`, o pedido deve vir só de ação do usuário: "Permitir…" das Boas-vindas (M5) ou a primeira mudança num slider, que roda `verify()` antes do tap.
  - Se o orquestrador preferir deixar isso para a M5, junto com as Boas-vindas, registrar como pendência obrigatória antes do release.

#### Baixo

**S4-B1: o Sair espera `restoreAll()` sem limite de tempo.**
- Evidência: `Composition.swift:97-101`. `restoreAll` aguarda `finishRestore` no ator do controlador. Se o ator estiver preso numa chamada síncrona do Core Audio (`makeSession` com o `coreaudiod` travado), ou se o próprio `killList.stopAll()` bloquear no HAL, o `terminate` nunca chega. Como `isQuitting` ignora os cliques seguintes, Sair e ⌘Q param de funcionar.
- Impacto: ninguém fica mudo, porque os taps morrem com o processo (§4.2, §8). O usuário teria de usar Forçar Encerramento, e essa saída conta como anormal para o modo seguro.
- Recomendação: disputar `restoreAll()` contra um prazo de ~2 s e chamar `terminate` em qualquer caso. Encerrar o processo é sempre seguro.

**S4-B2: uma linha com falha continua mostrando o estado pedido ("Silenciado", "30%", botão vermelho) enquanto o app toca no volume original.**
- Evidência: `AppRowView.swift:73-77` (rótulo de falha) junto com `:90-116` (valor e botão de mudo vêm de `row.state`, não do efeito real).
- Impacto: o rótulo laranja aparece, mas o "Silenciado" em vermelho pode levar o usuário a achar que um app está mudo quando está audível, por exemplo numa chamada. Não vaza dados e não deixa ninguém mudo.
- Recomendação: na linha com falha, mostrar o valor esmaecido ou neutro (por exemplo "100%") e não usar o vermelho de mudo.

**S4-B3: o ícone é resolvido pelo bundle ID via LaunchServices, e não pelo caminho do app do grupo.**
- Evidência: `WorkspaceAppInfoProvider.swift:122-131` (`urlForApplication(withBundleIdentifier:)` → `icon(forFile:)`).
- Impacto: um processo que declara o bundle ID de outro app (Info.plist próprio, sem assinatura) aparece com o ícone **real** daquele app. Como o agrupamento também é por bundle ID, ele ainda divide a linha com o app verdadeiro. Isso é falsificação visual dentro do próprio popover: o processo não ganha nenhum privilégio, só tem o próprio áudio afetado pelo tap. Ícones não carregam código de terceiros. Mesma classe do B-3, que já foi aceito.
- Recomendação: aceitar. Opcional: buscar o ícone pelo caminho do `.app` do grupo, que é o que de fato está rodando.

**S4-B4: um dispositivo cujo nome só tem caracteres invisíveis aparece com rótulo vazio.**
- Evidência: `DeviceCatalog.swift:66,73` testa `name.isEmpty` **antes** da sanitização, que acontece só no `OutputDevice.init` (`OutputDevice.swift:39`). Um nome como `"\u{200B}"` vira `""`. Além disso, os fallbacks `"Output"` e `"App"` (`ProcessGrouping.swift:124`) são texto fixo em inglês, fora do `Localizable.xcstrings`.
- Impacto: só visual. Uma entrada em branco na lista de saídas, que um driver virtual poderia usar para se disfarçar.
- Recomendação: aplicar o fallback **depois** de sanitizar (dentro do `OutputDevice.init`, ou sanitizando antes do teste) e usar uma chave localizada.

**S4-B5: superfície desnecessária (regra contra overengineering).**
1. Um monitor `NSEvent` por slider (`VolumeInput.swift:57-65`), até ~8 ativos ao mesmo tempo, cada um chamado em toda rolagem do app. Um único monitor no popover bastaria. Isso já foi apontado pelo QA (item 6) e aceito; do ponto de vista de segurança está correto.
2. `NSWindow.didBecomeKeyNotification` de **qualquer** janela (`MenuBarPopover.swift:44-46`) dispara `refresh()`. Com a permissão negada, isso roda um `verify()`: tap `.unmuted` de até 16 processos por ~500 ms. Também acontece quando a janela que ganhou foco é a de Ajustes ou o painel Sobre. Filtrar pela janela do popover (`notification.object`).
3. `refresh(onlyIfDenied: Bool = true)` tem valor padrão, o que esconde que a outra variante verifica sempre e pode criar tap. Tornar o argumento obrigatório.
4. Anteriores à M4, sem chamador de produção: `PermissionService.currentStatus()` (`AudioPermissionService.swift:34`) e `WorkspaceAppInfoProvider.frontmostApplication()` (`:108`). Remover, ou justificar na M5.

#### Informação
- Continua aberta a observação 2 do QA na M2.1: sem processo tocando, `verify()` → `probe(target:) == false` por qualquer motivo (alvo que sumiu, por exemplo) dá `.denied` (`SystemAudioAccessProbe.swift:100-103`). Hoje isso só acontece em `refresh(onlyIfDenied: false)` depois de um silêncio, e a próxima abertura do popover corrige. A falha é para o lado seguro: a lista fica escondida, ninguém fica mudo.
- Uma falha `.deviceUnavailable` marca a linha como falha no store, mas o controlador não a guarda (`CoreAudioAppController.swift:150-153`) e tenta de novo no próximo `reconcile`. A linha pode continuar com "Não foi possível controlar" mesmo depois de voltar a funcionar. Isso é inconsistência de UI, sem risco.
- `onGranted` só roda em negada→concedida. Uma concessão vista a partir de `.notDetermined`, depois de um silêncio, não reexecuta `retryAll`. As linhas com falha tocam normalmente até uma ação do usuário, o que é fail-open.
- A cena `Settings` provisória não tem lógica e não aumenta a superfície.

### Problemas / desvios da SPEC
1. S4-M1: SPEC §4.6 ("Antes de criar qualquer tap de usuário, a permissão precisa ter sido confirmada…"). Não há essa verificação (`Composition.swift:33-39`, `CoreAudioAppController.swift:127-172`). Com a permissão negada ou ainda não decidida, apps ficam mudos por ~2 s, e o pedido do TCC pode aparecer na inicialização sem ação do usuário.
2. S4-B1: SPEC §8. O Sair pode não terminar se `restoreAll` travar (`Composition.swift:97-101`). O áudio volta de qualquer jeito com Forçar Encerramento.

### Precisa do usuário / orquestrador
- Decidir se o S4-M1 entra agora, numa M4.1, ou junto com as Boas-vindas na M5. Ele não bloqueia o ⏸2, mas tem de estar fechado antes do release.
- No ⏸2, com a permissão **concedida**, o S4-M1 não aparece. Para não sujeitar o usuário a mudos de 2 s, não fazer o ⏸2 com a permissão negada ou zerada.

## Veredito: **LIBERA**
Não há Crítico nem Alto. O S4-M1 é uma falha de controle previsto pela SPEC, com impacto limitado (mudo de ≤ 2 s que se resolve sozinho) e deve ser corrigido até a M5.
