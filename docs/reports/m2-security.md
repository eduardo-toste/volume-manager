## Etapa M2 — Segurança (revisão pontual: thread de áudio, ciclo de vida de taps, dados de outros processos)
Resultado: **PASS** — nenhum achado Crítico ou Alto. 2 Médios e 8 Baixos, nenhum bloqueante.

Escopo revisado linha a linha: `Sources/VolumeAudio/*`, `Sources/vmctl/*`, `scripts/make-vmctl-app.sh`, `Sources/CSystemShims/*`, e em VolumeCore/VolumeSystem: `ProcessGrouping`, `AppPath`, `TextSanitizer`, `AudioAccessProbe`, `AudioPermissionService`, `WorkspaceAppInfoProvider`, `ControlledApp`. O QA (`m2-qa.md`) já cobriu tempo real, qualidade e falha-aberta; esta revisão não repete esse trabalho.

Como verificar:
```
scripts/check.sh                                                     # verde
swift test --filter SecurityM2                                       # 9 testes
swift test --sanitize=address --filter "SecurityM2|RenderTests|GainKernelTests|QAM2|ControllerTests|LogicTests"   # 107 ok
swift test --sanitize=thread  --filter "SecurityM2|QAM2|ControllerTests"                                           # 70 ok
VOLUME_AUDIO_TESTS=1 swift test --sanitize=address --filter HardwareTests                                          # 10 ok (só afplay -v 0 próprio)
```
Verificações: check.sh ✓ · security-check ✓ (fonte e bundle) · ASan ✓ · TSan ✓ · cobertura não medida por mim (QA: 93,5 % em VolumeAudio)

Arquivos criados: `Tests/VolumeAudioTests/SecurityM2Tests.swift` e este relatório. Nenhuma alteração em `Sources/` nem em scripts. Nada foi instalado nem baixado. `vmctl probe-permission` e `master <valor>` não foram executados, e nenhum app do usuário recebeu tap.

---

### 1. Provas executadas

| Prova | Resultado |
|---|---|
| `render` com fuzz (3000 casos): buffers de **tamanho exato em bytes** (0–67 B, ímpares), `mData` nulo, canais 0–3 divergentes, 0–4 buffers, offset `Int.min/Int.max/±1…`, sob **ASan** | nenhum acesso fora dos buffers declarados |
| `SignalProbeState.scan` (2000 casos, tamanhos ímpares) sob ASan; palavra parcial final nunca lida; `-0.0` não conta como sinal | ok |
| Tempestade de 200 `reconcile` (criar, atualizar, mudar de dispositivo, remover) contra 40 `restoreAll` concorrentes, sob **TSan** | sem corrida; no fim, 0 taps vivos, `killList` vazio |
| `KillList.stopAll` de 200 threads enquanto handles são adicionados, sob TSan | todos param; nada fica registrado |
| **Hardware, ASan**: 15 ciclos com tap real (afplay -v 0 próprio, ganho 0): IOProc rodando, `stop()` em 8 threads + `KillList.stopAll` simultâneos, depois a última referência é solta | sem use-after-free, sem aggregate restante |
| `vmctl set pid:<afplay próprio>` ativo (87 040 frames) enquanto **outro processo** conta os dispositivos | 5 → 5 → 5: aggregate e tap privados não aparecem para outros processos |
| App bundle `Evil.app` (cópia de `afplay`, assinatura ad hoc) com `CFBundleIdentifier` = `com.evil.x ESC]0;PWNED BEL ESC[2J`, tocando silêncio | o HAL repassa o bundle ID **cru**; o domínio o descarta; o `vmctl processes` o imprime cru (B-1) |
| Função `weak_import` ausente acessada pelo mesmo padrão de `WorkspaceAppInfoProvider` (programa no scratchpad) | o opcional fica **não nulo** e a chamada cai com SIGSEGV (M-1) |

### 2. Confirmações (sem achado)
- **Memória no IOProc**: limites em bytes (`count = min(capacity, available)/(4·canais)`, resto zerado), índice de entrada `index &+ offset` com checagem de faixa, aritmética de `buffer()` correta (cabeçalho de 8 B, passo de 16 B), sem overflow em Int de 64 bits. O IOProc só lê a lista do HAL e nunca a guarda.
- **Tempo de vida do estado**: `RealtimeTapState`/`SignalProbeState` vão como ponteiro não retido. Quem os possui (`CoreAudioTapSession`, ou `withExtendedLifetime` nos caminhos de erro e no `verify()`) os mantém vivos até `teardown()` voltar, e `teardown()` para e destrói o IOProc antes de destruir o aggregate e o tap. Todo `stop()` é feito por alguém que tem referência forte, então o `deinit` só pode rodar depois. Prova com ASan acima.
- **Corridas**: não há `@unchecked Sendable` nem `nonisolated(unsafe)`. O estado compartilhado usa `Atomic`/`Mutex`. A ordem `generation.advance → stopAll` e `killList.add → checar generation` não deixa tap fora da kill list (raciocínio de happens-before conferido). Os blocos dos listeners só fazem `hub.yield` e não guardam sessão nem estado.
- **Privacidade**: nenhuma amostra sai do ciclo do IOProc. O kernel e o `scan` só fazem OR de bits para responder "houve ≠ 0". O `verify()` usa tap `.unmuted` + `isPrivate`, aggregate privado sem saída, até 16 processos, ~500 ms, e guarda só um `Bool`. Os logs têm só textos fixos, seletores, IDs de objeto e `OSStatus` (o `.public` é adequado). Nenhum nome, bundle ID, PID ou UID vai para o log.
- **Aggregates/taps**: sempre `isPrivate`, UID `com.volumemanager.agg.` + UUID aleatório (não previsível e não visível a outros processos). Morrem com o processo (QA: `kill -9`).
- **API privada**: usada só para leitura; o resultado é validado (`> 0`, `≠ pid`). Mas veja M-1 sobre a checagem de nulo.
- **vmctl**: argumentos estritos (QA: 25 casos hostis). `restore` só sinaliza executáveis que terminam em `/vmctl-dev.app/Contents/MacOS/vmctl` ou o próprio binário, e `kill` sem sudo só alcança processos do mesmo usuário, então não serve para matar processos arbitrários. `build-app.sh` copia só `VolumeManager`, e `security-check --app` falha se houver `vmctl*` no bundle (verde). `make-vmctl-app.sh` só escreve em `build/`, usa bundle ID próprio e assinatura ad hoc.

### 3. Achados

#### Médio

**M-1 — A checagem de nulo da função `weak_import` não funciona.**
Evidência: `Sources/VolumeSystem/WorkspaceAppInfoProvider.swift:74-77` (`let function: ((pid_t) -> pid_t)? = responsibility_get_pid_responsible_for_pid`). Reprodução no scratchpad (`weak/main.swift`): com um símbolo `weak_import` ausente, o Swift embrulha a função num closure, o opcional nunca fica `nil` e a chamada cai com **SIGSEGV** (exit 139, em `-Onone` e em `-O`). Com `@convention(c)` o resultado muda conforme a otimização (`-O` diz "non-nil" mas pula o `if let`), então também não é confiável.
Impacto: se um macOS futuro remover o símbolo, o Volume cai sempre que lista processos. Isso derruba a promessa da SPEC 12.9.2 ("weak_import para o app carregar mesmo sem o símbolo"). É disponibilidade, não confidencialidade: o som original volta. Hoje o símbolo existe (testado).
Recomendação: decisão do orquestrador. Hoje não há forma Swift garantida sem `dlsym` (proibido). Opções: (a) permitir no header uma checagem `static inline` de 1 linha (`return &responsibility_get_pid_responsible_for_pid != NULL;`), o que exige ajuste da regra "header sem lógica"; (b) aceitar o risco e incluir no roteiro de release um teste que confirme o símbolo na versão mínima e na atual.

**M-2 — `teardown` usa IDs de objeto velhos depois de o `coreaudiod` reiniciar.**
Evidência: `CoreAudioAppController.swift:304-309` (`.serviceRestarted` → `destroy` em todas as entradas) → `TapPipeline.swift:71-82` (`AudioDeviceStop`/`DestroyIOProcID`/`AudioHardwareDestroyAggregateDevice`/`AudioHardwareDestroyProcessTap` com os IDs guardados). Depois de um reinício, os IDs do servidor são renumerados.
Impacto (teórico, não reproduzido porque reiniciar o coreaudiod é proibido): se o ID antigo do aggregate ou do tap tiver sido reaproveitado, o Volume pode **destruir um aggregate público do usuário** (por exemplo um criado no Configuração de Áudio e MIDI) ou um tap público de outro app. Isso é perda de configuração ou som de terceiros, sem vazamento de dados.
Recomendação: em `.serviceRestarted`, esquecer os recursos sem chamar `Destroy` (o servidor já os perdeu). Ou guardar o UID do aggregate e só destruir se `TranslateUIDToDevice(uid) == id`, e para o tap conferir `kAudioTapPropertyUID`/UUID antes.

#### Baixo

**B-1 — `vmctl processes` imprime o bundle ID cru do HAL, o que permite injetar escapes no terminal.** Reproduzido (seção 1): `ProcessCatalog.swift:85-90` não sanitiza (é dado "não confiável", e o domínio o descarta corretamente em `ProcessGrouping.validBundleID`), mas `Sources/vmctl/ReadCommands.swift:26-29` imprime `bundleID` e `executablePath` direto. Impacto: um processo local pode mandar sequências OSC/CSI para o terminal do desenvolvedor (título, limpar tela, OSC 52 de área de transferência, conforme o terminal). Só ferramenta de dev. Além disso, `AppPath.canonicalize` só rejeita < 0x20 e 0x7F, então passam C1 (U+0080–U+009F) e bidi (U+202E) no caminho e na chave `path:` (que é impressa por `vmctl processes`). Recomendação: passar tudo por `TextSanitizer.clean` antes de imprimir no vmctl, e fazer `AppPath` rejeitar também C1 e categorias `Cf`.

**B-2 — `DeviceCatalog.deviceID(forUID:)` aceita casamento pelo UID sanitizado e pega o primeiro.** `DeviceCatalog.swift:74-79`: `raw == uid || TextSanitizer.clean(raw) == uid` dentro de `first {}`. Um dispositivo cujo UID só difere por caracteres invisíveis (um aggregate público criado por outro processo, por exemplo) pode ser escolhido antes do verdadeiro, e a rota do app vai para ele. Isso não captura áudio: aggregates não se aninham e capturar exigiria driver instalado pelo admin. Além disso, `signature(forUID:)` (`:101-109`) passa o UID **sanitizado** como `MainSubDevice` (`CoreAudioTapSession.swift:163-168`), então um dispositivo com UID longo (> 200 caracteres) ou com espaços repetidos nunca é controlável (falha-aberta, mas é bug). Recomendação: procurar primeiro o casamento exato, guardar o UID cru internamente, e marcar ou recusar UIDs duplicados após a sanitização.

**B-3 — Bundle ID declarado pelo próprio processo decide o grupo.** `ProcessGrouping.swift:92-94, 127-133`. Testes `claimingAnotherBundleIDJoinsThatGroup` e `claimingVolumesBundleIDHidesAProcess`: um processo sem `.app` que declara `com.vendor.Player.x` entra no grupo (e no tap) do Player; um que declara `com.volumemanager.app.*` some do mixer. Impacto: nenhum ganho de privilégio (o processo já toca o que quer); o mixer controla ou exibe o processo errado. Recomendação: documentar; numa etapa futura, preferir a identidade de assinatura (Team ID/requisito designado) quando houver.

**B-4 — Janela de PID reutilizado entre a revalidação e a criação do tap.** `CoreAudioTapEngine.swift:29-38`: `confirmedPIDs` resolve PID → objeto (`ProcessCatalog.swift:117`), e depois `makeSession` resolve PID → objeto **de novo**. Se o PID morrer e for reaproveitado nesse intervalo (microssegundos, e no macOS é preciso dar a volta de ~99 999 PIDs), o tap cobre outro processo: ele fica com o volume ou a rota do app, e nada é guardado. Na prática não dá para explorar. Recomendação: confirmar pelo próprio `AudioObjectID` e passar esse objeto ao tap, ou reler `kAudioProcessPropertyPID` e o caminho do objeto depois de criar o tap.

**B-5 — `probe()` usa tap global quando não há outro processo de áudio, contrariando o próprio comentário.** `SystemAudioAccessProbe.swift:19-21` ("never a global tap") contra `:60-62` (`monoGlobalTapButExcludeProcesses: []`). É `.unmuted`, `isPrivate`, sem aggregate nem IOProc, e destruído na hora: nenhum dado flui. Recomendação: corrigir o comentário ou nesse caso retornar sem criar tap.

**B-6 — Um segundo `stop()` concorrente volta antes do teardown acabar.** `TapPipeline.swift:66-70`: quem chega depois encontra os recursos já tomados e retorna na hora, enquanto o primeiro ainda está em `AudioDeviceStop`. Então `restoreAll()` pode voltar alguns ms antes de o tap sumir de fato. Não é use-after-free (a prova com ASan cobre). Recomendação, opcional: um estado "terminando" em que quem chega depois espera, se a UI precisar da garantia "ao voltar, acabou".

**B-7 — `Unmanaged._withUnsafeGuaranteedRef`** (`CoreAudioTapSession.swift:10`, `SignalProbeState.swift:28`): concordo com o QA. Está correto hoje, mas é API com sublinhado. Manter, com a verificação do desmontado no roteiro de release, ou migrar para memória bruta própria.

**B-8 — A decisão de segurança do `verify()` depende do texto do erro.** `SystemAudioAccessProbe.swift:104`: `error.context.hasPrefix("create process tap")` decide entre `.denied` e `.indeterminate`. Se a mensagem mudar, o resultado muda calado. Recomendação: um erro tipado por etapa no `TapPipeline`.

#### Informação
- `build/vmctl-dev.app` pode receber a permissão de áudio do sistema (assinatura ad hoc, o TCC liga ao cdhash, então recompilar invalida). Recomendo remover a permissão em Ajustes depois de cada uso no ⏸1.
- O `EventHub` de mudanças de ambiente usa buffer ilimitado, e uma rajada de eventos de formato aumenta a memória. Risco baixo; trocar por `.bufferingNewest(n)` como no `CoreAudioSystem`.

### Problemas / desvios da SPEC
1. M-1: §12.9.2 ("weak_import para o app carregar sem o símbolo") não é garantido pelo código atual (`WorkspaceAppInfoProvider.swift:74-77`).
2. B-1/B-2/B-3: §12.9.4 é cumprido no domínio, mas o vmctl e o `DeviceCatalog` usam texto não sanitizado ou casamento ambíguo.
3. M-2: §4.6 está ok (falha-aberta), mas há risco a terceiros no teardown após reinício do coreaudiod.

### Precisa do usuário / orquestrador
- Decidir M-1: (a) permitir uma linha de checagem no header `CSystemShims`, ou (b) aceitar o risco com um teste no roteiro de release.
- Ao Dev, não bloqueantes: M-2, B-1, B-2, B-4, B-5, B-8.

### Estado final
`pgrep -fl "afplay|vmctl"` vazio. `vmctl devices`: 5 dispositivos, igual ao início, e nenhum aggregate `com.volumemanager.agg.` restante. Os processos `afplay` e `Evil.app` que iniciei foram encerrados. Os arquivos temporários ficam só no scratchpad.

## Veredito: **LIBERA**
Nenhum achado Crítico ou Alto. Os Médios M-1 e M-2 devem entrar no plano antes do release (auditoria §12.9.8).
