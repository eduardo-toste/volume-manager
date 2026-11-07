# M3 — Serviços do sistema — Relatório QA

**Veredito: FAIL** (1 bug de severidade média/baixa em validação de entrada; 1 achado de higiene de testes; demais itens PASS). Nenhum risco crítico/alto de segurança, nenhuma alteração de estado do sistema, nenhuma violação de arquitetura.

## Verificações executadas
- `rm -rf .build && scripts/check.sh`: verde (format lint, build sem warnings, 236 testes Core + 2 Audio + VolumeSystem, security-check OK) antes dos meus testes. Com `QAM3Tests.swift` adicionado, a suíte roda 3x com resultado idêntico (apenas a falha intencional abaixo; sem flaky).
- Cobertura (llvm-cov, só VolumeSystemTests, inclui meus testes): AudioPermissionService 95,2% linhas; LRUCache 100%; SessionLifecycleObserver 100%; UserDefaultsPreferencesStore 100%; WorkspaceAppInfoProvider 96,6%; SMAppLoginItemService 68,1%; SystemAudioAccessProbe 0% (por desenho: só roda com `--audio`).
  Código sem teste: `MainAppServiceController` (wrapper real de `SMAppService`; correto não testar, registraria o login item real) e os `init()` públicos que usam singletons reais. Sem lacuna relevante.

## Arquitetura (PASS)
- VolumeSystem não importa CoreAudio/SwiftUI/VolumeAudio (grep). Probe real em `Sources/VolumeAudio/SystemAudioAccessProbe.swift`; protocolo em `VolumeCore/AudioAccessProbe.swift`. Injeção por inicializador em todos os serviços. `Package.swift`: apenas `VolumeSystemTests` ganhou dependência de VolumeAudio (teste `--audio`); nenhuma dependência externa nova.
- Concorrência: nenhum `@unchecked`/`nonisolated(unsafe)` em `Sources/VolumeSystem` (os `@unchecked Sendable` existem só em fakes de teste, justificados por NSLock). `AudioPermissionService` é actor; `WorkspaceAppInfoProvider` usa `Mutex` corretamente; `SessionLifecycleObserver` é `@MainActor`.
- Sem mixer Core Audio, UI nem dependência nova. HotkeyService adiado (aceito).

## Segurança §12.9
- **SystemAudioAccessProbe (PASS)**: único `AudioHardwareCreateProcessTap`; sem IOProc, aggregate, leitura de amostras, arquivo ou laço; `isPrivate = true`, `muteBehavior = .unmuted`; o tap é destruído imediatamente no único caminho em que foi criado (no caminho de erro nada foi criado; não há `return`/`throw` entre criar e destruir). Nenhum som, nenhum estado persistente.
  - Recomendação (Baixa): o tap é GLOBAL (`monoGlobalTapButExcludeProcesses: []`), que captura conceitualmente todo o áudio do sistema durante milissegundos. Um tap de processo único (`CATapDescription(monoMixdownOfProcesses: [<AudioObjectID do próprio Volume>])`, ou de um processo vazio/excluindo tudo) exigiria a mesma permissão e seria menos invasivo/mais fácil de justificar na auditoria. Verificar na M6 (com hardware) que o prompt/estado se comporta igual. Não bloqueante. Também: `probe()` é síncrono e bloqueia a thread do actor enquanto o prompt do sistema está aberto; chamar `request()` de um contexto que não bloqueie a UI (já é actor, ok).
- **proc_pidpath (PASS)**: buffer 4096 bytes (4*MAXPATHLEN), `length > 0`, `<= capacity`, UTF-8 validado (`String(validating:)`), PID <= 0 rejeitado, `Int32.min/-1/0/Int32.max/99999999` testados, resultado canonicalizado (<=1024 bytes, sem controles). Processo morto: `executablePath` e `pidStillMatches` passam a falhar (teste com `/bin/sleep` real, encerrado). PID com outro executável é rejeitado por caminho. Comparação é lexical e case-sensitive (mais estrita, falha fechada). Nota: o TOCTOU residual (PID reutilizado por processo com o MESMO executável) é inerente e coberto por "PID + bundle ID + caminho" no chamador (M4/M6).
- **Strings hostis (PASS)**: `.app` falso com Info.plist hostil (bidi, controles, 10 KB, bundle ID gigante, tipos não-String, nome só invisível com fallback ao nome do arquivo) → sempre sanitizado e limitado a 200; caminhos com controle, relativos ou >1024 bytes rejeitados; arquivo temporário apagado ao fim de cada teste. `icon(forBundleID:)` com IDs gigantes/invisíveis devolve nil. Observação (Baixa): o ID é sanitizado antes da busca, então `com.apple.finder` + U+202E acha o mesmo ícone do Finder (inofensivo).
- **Preferências**: NaN/inf (inclusive aninhados, Float, NSDecimalNumber.notANumber), NSNull, URL, NSAttributedString, chaves não-String (inclusive aninhadas), profundidade 5, chaves vazias/enormes: nada gravado, sem crash; limite de profundidade exato (4 aceita, 5 rejeita). Testes só usam suítes isoladas; `.standard` não é escrito (verificado com marcador).
- URLs: só `privacySettingsURL` (constante) e `SMAppService.openSystemSettingsLoginItems()`; nenhuma URL montada de dados variáveis. Sem rede, sem `Process` nem `print` em `Sources/VolumeSystem`; `security-check.sh` OK; nenhuma permissão extra.
- LRU: limite 200 respeitado sob 8 tarefas concorrentes via `Mutex` (teste), capacidade <=0 vira 1.

## Login item (PASS)
Mapeamento dos 4 estados, erros tipados com código (`registrationFailed(code:)`/`unregistrationFailed(code:)`), status inalterado após falha, idempotência (enable em `.enabled`/`.requiresApproval` não registra; disable em `.notRegistered`/`.notFound` não desregistra), `status()`/`openLoginItemsSettings()` nunca mutam. Registro só em `setEnabled(true)`. Observação: com `.notFound` e `enabled == true` ele tenta `register()`, que falhará com erro tipado (aceitável).

## SessionLifecycleObserver (PASS)
Dispara em willPowerOff (centro do workspace) e willTerminate (centro do app); eventos no centro errado ignorados; `stop()` idempotente e remove observadores; sem ciclo de retenção (closure usa `[weak self]`; teste confirma liberação). Observação (Baixa): sem `deinit`, se o dono esquecer `stop()` os blocos permanecem registrados nos centros (inócuos, `weak self`), apenas vazamento de pequenos blocos. Os dois eventos podem ambos disparar na mesma saída: `onCleanExit` precisa ser idempotente (`markCleanExit` é).

## Problemas
1. **Média/Baixa — `UserDefaultsPreferencesStore.isValid(key:)` limita `key.count` (clusters de grafemas), não bytes.** `Sources/VolumeSystem/UserDefaultsPreferencesStore.swift` (`isValid`). Uma chave de 1 "caractere" com 50 000 combining marks (~100 KB) é aceita e gravada. Esperado: limitar também `key.utf8.count` (ex.: <= 4*maxKeyLength). Teste que falha de propósito: `QA M3: preferences hostile input / keyLimitIsBoundedInBytesNotOnlyCharacters` em `Tests/VolumeSystemTests/QAM3Tests.swift`. (As chaves reais do app são constantes; o risco é baixo, mas o contrato do store diz rejeitar chaves enormes.)
2. **Baixa (higiene de testes) — vazamento de arquivos de preferências.** `removePersistentDomain(forName:)` deixa um `.plist` vazio (42 bytes) em `~/Library/Preferences/` por execução: hoje há 64 (`com.volumemanager.tests.*` do Dev e `com.volumemanager.qa.*` meus; nenhum de domínio real `com.volumemanager.app`). Inofensivo (vazio), mas polui o diretório do usuário a cada `check.sh`. Sugestão: após `removePersistentDomain`, remover o arquivo da suíte, ou usar um `UserDefaults` volátil. Eu não os apaguei (a remoção em `~/Library` foi bloqueada pelo ambiente); limpar com `rm ~/Library/Preferences/com.volumemanager.{tests,qa}.*.plist`.

## Testes adicionais
`Tests/VolumeSystemTests/QAM3Tests.swift` (33 testes em 7 suítes: PIDs/caminhos, bundles hostis, LRU concorrente, preferências hostis, login item, permissão, ciclo de vida). Falha intencional: apenas `keyLimitIsBoundedInBytesNotOnlyCharacters` (problema 1). Todos os demais passam.

## Confirmações
- Nenhum register/unregister real do login item; probe real e `--audio` não executados (sem prompt, sem som); nenhuma preferência real alterada (apenas suítes isoladas; `.standard` não escrito).
- Nenhum processo de teste restante (`sleep` filhos encerrados e verificados); diretórios temporários de `.app` falsos removidos (0 restantes). Resíduos: apenas os `.plist` vazios do item 2 e artefatos de `.build/`. Nenhum commit/branch alterado; `Sources/` e scripts intocados.

---

# Reavaliação 1 (volta 1/3)

**Veredito: FAIL** (somente o item de higiene abaixo; o bug de segurança foi corrigido).

## Verificado
- `rm -rf .build && scripts/check.sh`: verde (warnings zero, security-check OK). Suíte rodada mais 3x: 69 (VolumeSystem) + 236 (Core) + 2 (Audio) testes, sem falhas nem flaky.
- Problema 1 (chave em bytes): corrigido. `isValid` usa `key.utf8.count <= 200`; meu teste `keyLimitIsBoundedInBytesNotOnlyCharacters` agora passa, sem alterar a asserção. As mudanças no VolumeCore (`PreferenceValidation.string`: `utf8.count <= maxUIDLength * 4` além de `count`; `AppVersion`: `part.utf8.count <= 9`) são restritivas e coerentes; todos os testes da M1 continuam passando (sem regressão).
- QAM3Tests: os 33 testes seguem verificando o mesmo. A única mudança é o helper `withStore`, que agora usa `InMemoryPreferencesBackend` em vez de suíte real (o arquivo é não rastreado, então não há `git diff`; comparei o conteúdo). Ressalva menor: as asserções de hostilidade passam a exercitar a lógica do store sobre backend em memória, não o `UserDefaults` real; aceitável, pois o store só delega.
- Problema 3 (Baixa, deinit): `isolated deinit { stop() }` presente; teste de liberação sem `stop()` segue passando.
- Processos `sleep` e diretórios temporários de `.app` falsos: 0 restantes.

## Problema remanescente
**Baixa (higiene) — o vazamento de `.plist` em `~/Library/Preferences` NÃO foi eliminado.** `ls ~/Library/Preferences | grep -c volumemanager` subiu de 65 para 68 após o `check.sh` + 3 execuções, e em 3 execuções isoladas de `realUserDefaultsRoundTripAndCleanup` subiu em 2 de 3 (69 -> 70 -> 70). O teste remove o arquivo no `defer`, mas o `cfprefsd` o recria de forma assíncrona depois (corrida). Esperado: contagem estável. Sugestões ao Dev: eliminar o único teste com `UserDefaults` real (o backend em memória já cobre a lógica; a delegação do `UserDefaults` é trivial), ou fazer o cleanup resiliente (por exemplo, `defaults.synchronize()` + pequena espera/segunda remoção, ou limpar no fim da suíte). Resíduos: os arquivos vazios (42 bytes) `com.volumemanager.tests.*` e `com.volumemanager.qa.*`, nenhum do domínio real do app; remover com `rm ~/Library/Preferences/com.volumemanager.{tests,qa}.*.plist`.

Confirmações: nenhum login item real, probe/permissão, preferência real nem som; nenhum commit/branch alterado.
