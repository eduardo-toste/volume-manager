## Etapa M6 — Segurança
Resultado: **ENTREGUE — LIBERA, com uma condição.** A condição é a prova de hardware que o QA já está fazendo: a UID lida de volta tem de ser igual à de criação, tanto para o tap `mutedWhenTapped` quanto para o aggregate. Não há achado Crítico nem Alto. Encontrei 1 Médio e 5 Baixos. Se a prova do QA falhar, o S6-M1 sobe para **Crítico** e o veredito passa a **BLOQUEIA**.

Escopo: `git diff` do branch `etapa/m6` (mudanças não commitadas), com `TapPipeline`, `CoreAudioTapSession`, `SystemAudioAccessProbe`, `TapEngine`, `CoreAudioAppController`, `PermissionMonitor`, `SafetyPolicy`, `MixerStore` (gate da marca), `Composition` e `SessionLifecycleObserver`. Também li `KillList`, `PropertyListener.cancel`, `AudioProperty.string` e os testes alterados.

Como verificar:
```
swift test --filter "VolumeCoreTests.SecurityM6Tests|VolumeCoreTests.PermissionMonitorTests|VolumeCoreTests.SafetyPolicyTests"   # 26 testes ok
swift test --filter "SecurityM6|PermissionMonitor|SafetyPolicy|ControllerReconcile|SecurityM21|M21Tests|SessionLifecycle"     # 46 testes ok (VolumeAudio)
scripts/security-check.sh                                                                                                      # OK
```
Não rodei o app nem a suíte de hardware, que fica com o QA. Não toquei som, não criei tap e não iniciei processo de áudio. Não instalei nem baixei nada.

Arquivos criados: `Tests/VolumeCoreTests/SecurityM6Tests.swift` (3 provas adversariais sobre os waiters do `PermissionMonitor`) e este relatório. Não alterei `Sources/` nem `scripts/`.

---

### 1. Situação dos achados anteriores

| Achado | Situação | Evidência |
|---|---|---|
| **M-2** (IDs velhos depois de reiniciar o `coreaudiod`) | **Fechado.** Antes de qualquer `Destroy`/`Stop`, o objeto é consultado: `kAudioDevicePropertyDeviceUID` no aggregate e `kAudioTapPropertyUID` no tap (`TapPipeline.swift:94-118`). Um ID morto não responde; um ID reaproveitado responde com outra UID. Nos dois casos o objeto fica intocado. Um aggregate público do usuário ou de outra conta tem UID diferente de `aggregateUIDPrefix + UUID()` e nunca é destruído. | `M21Tests` (`isOurs`), `HardwareTests.swift:135-136` |
| **S21-B1** (tap órfão criado depois do reinício e antes do evento) | **Fechado.** `.serviceRestarted` agora chama `destroy` → `stop()` em todas as entradas (`CoreAudioAppController.swift:358-365`). Um tap vivo e nosso é destruído; um morto ou alheio é deixado. Mesmo que o servidor novo dê ao nosso tap novo o ID numérico do antigo, a UUID é outra e ele fica. | `SecurityM21Tests.aTapBuiltAfterTheRestartButBeforeTheEventIsStoppedNotOrphaned` (o `withKnownIssue` saiu) |
| **S21-B2** (`restoreAll`, crossfade e limpeza parcial com IDs mortos) | **Fechado.** Os três caminhos passam pelo mesmo `teardown()` com conferência de identidade. A comparação de `serviceGeneration` no crossfade saiu, e era ela a janela (`CoreAudioAppController.swift:231-238`). | idem |
| **S21-B4** (remoção de listener com ID velho) | **Igual, aceito.** `stop()` ainda chama `AudioObjectRemovePropertyListenerBlock` com o ID do dispositivo de antes do reinício (`CoreAudioTapSession.swift:49`, `PropertyListener.swift:44-54`). O efeito continua desprezível. Saiu junto com o `abandon()` o comentário que explicava isso (ver S6-B4). | — |
| **S53-A1** (variante "revogação zera só taps novos", risco aceito) | **Não piora, no máximo melhora.** Ao acordar, `systemResumed` recria todos os taps. Se a variante for real, nenhum tap antigo fica entregando sinal e zerando a contagem global, então o vigia de silêncio detecta a revogação no prazo da §4.6. Não reabro o assunto. | `CoreAudioAppController.swift:372-375` |

### 2. Pontos pedidos

**2.1 Regra 9 (nunca mudo).** A conferência *falha fechada*: quando há dúvida, o objeto **não** é destruído. Isso é o oposto do "na dúvida, destruir o tap" da regra 9, mas tem motivo, porque destruir às cegas reabriria o M-2. Os caminhos que deixam um tap `mutedWhenTapped` vivo:
- (a) A leitura de `kAudioTapPropertyUID` lança erro num servidor vivo, ou devolve um texto diferente de `description.uuid.uuidString`.
- (b) A UID do aggregate confere e a do tap não. Pela ordem aggregate → tap, o aggregate (o consumidor) é destruído primeiro e o tap continua silenciando o app sem ninguém tocar o som dele. É a pior combinação.
- (c) No `catch` de `CoreAudioTapSession.start` (`:118-123`), o tap já foi criado e o aggregate não. Se a leitura do tap falhar, ele fica vivo **fora da kill list**. Nem `restoreAll` nem "Restaurar áudio original" o alcançam, só sair do Volume.

Sobre o raciocínio da igualdade: a mesma string `description.uuid.uuidString` é passada em `kAudioSubTapUIDKey` (`CoreAudioTapSession.swift:95,156`), e o aggregate só se liga ao tap se o servidor reconhecer o tap por essa string. Isso é uma evidência forte de que `kAudioTapPropertyUID` devolve o mesmo valor. A diferença de maiúsculas e minúsculas já está coberta (`caseInsensitiveCompare`), e o texto lido é limitado a 1024 caracteres (`AudioProperty.swift:97`). Uma lacuna: `HardwareTests.swift:118-136` prova a igualdade só com um tap `.unmuted`. O QA deve repetir a prova com `.mutedWhenTapped`, dentro das regras da §12.8.1, ou ao menos ler a UID do tap real criado por `CoreAudioTapSession`.

Pior caso se a prova falhar, ou seja, se a leitura falhar sempre: todo tap fica vivo depois de qualquer destruição. Todo app que já foi controlado fica **mudo** até o Volume encerrar, e o botão de pânico não resolve. Isso é Crítico. Recomendação de fallback em S6-M1.

**2.2 Identidade.** Para destruir um objeto alheio, outra pessoa teria de conhecer a UUID aleatória do nosso aggregate privado, que nenhum outro cliente lista, e ainda acertar o ID numérico velho. Mesmo assim ela só faria o Volume destruir o próprio aggregate dela. Não há impacto entre apps nem entre usuários. A comparação de string vazia devolve `false` (`TapPipeline.swift:80-83`), o lado conservador.

**2.3 IOProc.** `tapIOProc`, `RealtimeTapState`, `GainKernel` e `signalProbeIOProc` não mudaram (nenhum aparece no diff). A conferência de identidade, o `report` e o `passRetained` rodam fora do thread de áudio, em `stop()`/`deinit`/`catch`. Use-after-free: quando algum objeto é deixado, `teardown(keeping:)` retém o estado para sempre (`TapPipeline.swift:125-127`), então um IOProc que ainda esteja rodando só lê memória válida. Vazamento: cerca de 100 B por tap, uma vez por reinício do `coreaudiod`, como na M2.1. `teardown` é idempotente sob corrida entre `KillList.stopAll` e `destroy` do ator: o `Mutex` entrega os recursos a um único chamador, e o segundo recebe `Resources()` vazio e `true`. Resta uma janela anterior, sem regressão: S6-B2.

**2.4 `CheckedContinuation` (`PermissionMonitor.swift:45-61`).** Todo caminho entre `isRefreshing = true` e o laço de `resume` é síncrono ou é um `await` que não lança, então todo waiter é retomado. A lista é trocada por `[]` antes do laço, então cada waiter é retomado só uma vez. Um waiter não entra depois do laço, porque `isRefreshing` já é `false` e tudo roda no MainActor. Cancelamento: o waiter não acorda antes do fim, mas termina quando a verificação em curso termina, que tem duração limitada (cerca de 500 ms de escuta). Uma verificação cortada por cancelamento entrega `.notDetermined`, nunca `.denied`, aos waiters (S53R-B1 mantido). Comprovado em `SecurityM6Tests`: 8 waiters, waiter cancelado, verificação cancelada. Há um único vazamento possível: se `service.request` nunca voltar, os waiters ficam pendurados. Isso já acontecia com o chamador original, então não é regressão.

**2.5 Sinais (`Composition.swift:89-95`).** O handler é um `DispatchSource` na fila principal, e não um handler assíncrono de sinal: é seguro chamar qualquer código dali. `SIG_IGN` antes do source é o padrão documentado. O app não cria filhos (`Process(` é proibido), então a herança de `SIG_IGN` não afeta nada. `quit` é idempotente (`isQuitting`) e tem um teto de 2 s. SIGKILL, travamento e Forçar Encerramento continuam devolvendo o som, porque o processo morre e o servidor descarta os taps. Ressalva menor: S6-B3.

**2.6 `systemResumed` (`CoreAudioAppController.swift:372-381`).** Só reaplica `lastDesired`. Esse valor vem do último `reconcile` do `MixerStore`, que manda `[]` enquanto `permission.status != .granted` (`MixerStore.swift:660`). A permissão é a desta sessão, porque o `PermissionMonitor` começa `.notDetermined`. Depois de um `restoreAll`, a geração muda e `lastDesired` vira `nil` (`finishRestore`), então acordar não desfaz um pânico nem a saída. Isso está provado por `ControllerTests.resumeWithoutTapsOrAfterARestoreCreatesNothing`. `systemResumed` não chama `PermissionMonitor` nem a sonda. Ele não gera, por si, um pedido do TCC além do que qualquer reaplicação já gerava (`.serviceRestarted`, `.deviceFormatChanged`). Se a permissão for reiniciada com o app aberto, criar o tap pode mostrar o pedido. É a mesma classe e o mesmo risco aceito de antes. S4-M1 mantido.

**2.7 `previousSessionEndedCleanly`.** É lido por `PreferenceValidation.bool`. Um `defaults write … cleanExit -bool true` só religa a verificação automática, que é o comportamento normal, então não há ganho para quem já é o mesmo usuário. Um valor inválido vira `false`, o lado seguro.

**2.8 Proporcionalidade.** A mudança é proporcional e reduz a superfície: `abandon()`/`forget()` e a comparação de geração saíram, e restou um único caminho de destruição. `teardown(keeping:)` e `isOurs` têm uso real e teste. O array de dois `DispatchSourceSignal` e a lista de waiters são o mínimo necessário.

### 3. Achados

#### Médio

**S6-M1: falhar fechado na identidade pode deixar um tap `mutedWhenTapped` vivo num servidor vivo (regra 9).**
- Evidência: `TapPipeline.swift:94-118`. O ramo `else { allOurs = false }` não destrói nada e não registra nada. O aggregate é destruído antes de o tap ser conferido (`:106` antes de `:111-118`). No `catch` de `CoreAudioTapSession.swift:118-123`, o tap fica fora da kill list. Caminhos (a), (b) e (c) em 2.1.
- Impacto: se a leitura da UID do tap falhar, ou não conferir, enquanto o servidor está vivo, o app fica mudo até o Volume encerrar, e "Restaurar áudio original" não o recupera. Com a igualdade provada no hardware, só sobra um erro transitório de `AudioObjectGetPropertyData` sobre um objeto nosso e vivo: improvável, mas não demonstrado impossível. Sem a prova, a falha seria sistemática e o achado seria **Crítico**.
- Recomendação (fallback simples, que não reabre o M-2): quando o tap não conferir, procurar **pela identidade** e não pelo ID. Isso é `kAudioHardwarePropertyTranslateUIDToTap` no objeto do sistema com a UUID guardada. Se voltar um ID diferente de `unknown`, destruir **esse** ID, que é nosso por definição: a UUID é nossa, e um tap morto não traduz. Fazer o mesmo para o aggregate com `kAudioHardwarePropertyTranslateUIDToDevice`. Fica em torno de 10 linhas no próprio `teardown`, sem tipo novo. Junto com isso, ver S6-B1.

#### Baixo

**S6-B1: um objeto deixado vivo não deixa rastro.**
- Evidência: `TapPipeline.swift:107-109, 116-118` não têm log.
- Impacto: um mudo preso em campo, ou um vazamento depois de reinício, fica invisível no `log show`, e nem o QA nem o usuário conseguem diagnosticar.
- Recomendação: `AudioLog.logger.error("teardown: <tap|aggregate> left alone (identity not confirmed)", privacy: .public)`. Fica fora do IOProc e não leva dado de terceiros.

**S6-B2: falha de `AudioDeviceStop`, `DestroyIOProcID` ou `DestroyAggregateDevice` não retém o estado (janela anterior à M6).**
- Evidência: `TapPipeline.swift:100-106` só repassa o `OSStatus` para `report`, e `allOurs` continua `true`. Depois disso, `CoreAudioTapSession` libera `state`.
- Impacto: em teoria, se o stop falhar e o IO continuar, o IOProc acessa memória já liberada. Na prática, `DestroyAggregateDevice` para o IO. Não é regressão.
- Recomendação: no ramo do aggregate, `allOurs = false` quando qualquer status for diferente de `noErr`. Com isso o mecanismo `keeping:` já existente cobre o caso. É uma linha.

**S6-B3: com `SIG_IGN`, um app travado na fila principal deixa de morrer por SIGTERM.**
- Evidência: `Composition.swift:90-92`. O handler roda em `.main`. Se a fila principal estiver travada, o sinal é engolido.
- Impacto: um `kill <pid>` (sem `-9`) num Volume travado não devolve mais o som. Forçar Encerramento (SIGKILL) e a escalada do `launchd` ao desligar continuam funcionando.
- Recomendação (opcional): criar o source numa fila de fundo. No primeiro sinal, `DispatchQueue.main.async { quit() }`. No segundo, `signal(n, SIG_DFL); raise(n)`.

**S6-B4: o comentário que explicava o S21-B4 sumiu com o `abandon()`.**
- Evidência: `CoreAudioTapSession.swift:48-51` agora cancela listeners com ID possivelmente velho, sem nota.
- Recomendação: uma linha dizendo que a remoção mexe só na tabela de blocos do próprio processo e é inofensiva com ID morto.

**S6-B5: o cabeçalho de `TapPipeline` ficou desatualizado.**
- Evidência: `TapPipeline.swift:5-10` diz "Whatever was created is destroyed". Agora isso só vale quando a identidade confere.
- Recomendação: ajustar o texto.

#### Observação (não é achado de segurança, vai para o QA)
- Uma falha transitória de criação logo depois de acordar (Bluetooth ainda não pronto) trava o app em "falhou" até uma ação do usuário (`systemResumed` não chama `retryAll`, `CoreAudioAppController.swift:370-375`). Isso falha aberto, então a regra 9 está ok, mas o QA deve avaliar a usabilidade.

### 4. Problemas / desvios da SPEC
1. S6-M1: a regra 9 / §4.6 depende da igualdade de UID que ainda não foi provada para tap `mutedWhenTapped` (`TapPipeline.swift:94-118`; `HardwareTests.swift:118-136` usa só `.unmuted`).
2. Nenhum outro desvio. Rede, gravação, permissões extras, entitlements e dependências não mudaram (`security-check.sh` OK).

### 5. Precisa do usuário / orquestrador
- QA: provar no hardware, para o tap `mutedWhenTapped` e para o aggregate de produção, que a UID lida de volta confere. Isso já está em andamento; usar silêncio digital e aggregate sem saída física (§12.8.1). **Se falhar → BLOQUEIA.**
- Dev, não bloqueante mas recomendado antes da M7.5: S6-M1 (fallback por `TranslateUIDToTap`/`ToDevice`), S6-B1 e S6-B2 (cerca de 15 linhas no total). S6-B3 a S6-B5 são opcionais.

### Verificações
check.sh: não rodei completo (o QA roda) · security-check ✓ · testes de segurança desta revisão ✓ (26 + 46) · cobertura: não medida nesta revisão.

## Veredito: **LIBERA**, condicionado à prova de hardware do QA sobre a UID (S6-M1)
Não há Crítico nem Alto. Se a prova de hardware mostrar que a UID do tap ou do aggregate não confere, ou que a leitura falha, o S6-M1 vira **Crítico** e o veredito passa a **BLOQUEIA**.

---

## Reavaliação (reteste proporcional, 2026-11-11)
Resultado: **ENTREGUE — LIBERA (final, sem condição).**

Escopo: as correções em `Sources/VolumeAudio/TapPipeline.swift`, `CoreAudioTapSession.swift` e `Sources/VolumeManager/Composition.swift`, mais os testes novos em `M21Tests.swift` e `HardwareTests.swift`. Não rodei áudio. A condição de hardware foi cumprida pelo orquestrador: `scripts/check.sh --audio` verde, e `HardwareTests` 11/11, incluindo `teardownRecognisesItsOwnTapAndAggregate` com `.mutedWhenTapped`. A UID lida bateu com a de criação no tap e no aggregate, e a tradução por UID devolveu o mesmo ID.

Como verificar:
```
swift test --filter "M21Tests|SecurityM21|SecurityM6|ControllerReconcile"   # 59 testes ok
scripts/security-check.sh                                                    # OK
swift format lint Sources/VolumeAudio/TapPipeline.swift Sources/VolumeManager/Composition.swift Sources/VolumeAudio/CoreAudioTapSession.swift   # limpo
```

| Achado | Situação | Evidência |
|---|---|---|
| **S6-M1** | **Fechado.** `TapPipeline.resolve` usa o ID guardado quando ele ainda responde com a UID de criação. Senão, pergunta ao servidor qual objeto tem aquela UID (`TranslateUIDToDevice`/`ToTap`) e destrói **esse**. Com isso, uma leitura que falha não deixa mais um tap nosso vivo, e um ID velho que agora pertence a outro objeto continua intocado. Depois de um reinício do servidor a UUID não existe mais, a tradução volta `unknown` e nada é tocado (o M-2 continua fechado). Pelo valor do resultado, `unknown` e falha da chamada dão o mesmo efeito: nada é tocado. A UID esperada vazia nunca é traduzida. O `qualifier` é passado do jeito certo: `CFString` com tamanho de ponteiro e vida garantida pelo `var` local. Para outro processo acertar a tradução, ele teria de conhecer nossa UUID aleatória e privada, e mesmo assim só faria o Volume destruir um objeto dele. | `TapPipeline.swift` (`resolve`, `translate`, `teardown`), `M21Tests.resolvePrefersTheIDThenTheUID`, `HardwareTests.teardownRecognisesItsOwnTapAndAggregate` |
| **S6-B1** | **Fechado.** Um objeto deixado vivo agora gera `notice`. O log leva só o ID numérico (`.public`), nenhum dado de terceiros, e roda fora do IOProc. | `TapPipeline.swift` (ramos `else`) |
| **S6-B2** | **Fechado.** `report` devolve `Bool`. Qualquer `OSStatus ≠ noErr` em `Stop`, `DestroyIOProcID`, `DestroyAggregateDevice` ou `DestroyProcessTap` deixa `allOurs = false`, e `teardown(keeping:)` então retém o estado. Se o aggregate for achado por tradução com outro ID, o `procID` antigo falha e o estado é retido: é o lado conservador. | idem |
| **S6-B3** | **Fechado.** O source roda em `.global()`, e o lock por sinal é `OSAllocatedUnfairLock`. No 1º sinal, `quit()` roda no MainActor. No 2º, `SIG_DFL` + `raise`: o processo morre e o sistema devolve o som. O handler não é assíncrono de sinal (é callback do libdispatch), então chamar `signal`/`raise` ali é seguro. SIGTERM seguido de SIGINT passa duas vezes por `quit`, que é idempotente (`isQuitting`). Efeito colateral aceitável: um 2º sinal durante a saída normal pula o `markCleanExit`. A próxima sessão então só não verifica a permissão sozinha, que é o lado seguro. | `Composition.swift` (`start`) |
| **S6-B4 / S6-B5** | **Fechados.** Comentários corrigidos. | `CoreAudioTapSession.swift` (`stop`), cabeçalho de `TapPipeline.swift` |

Revisei de novo os demais pontos: o IOProc continua inalterado, assim como os waiters do `PermissionMonitor`, o `systemResumed` (S4-M1) e o `previousSessionEndedCleanly`. Proporcionalidade: `resolve` é estático e recebe as leituras por closure para poder ser testado sem hardware. Foram cerca de 30 linhas para fechar um Médio e dois Baixos. É proporcional.

Achados novos: **nenhum.**

### Verificações (reavaliação)
check.sh `--audio` ✓ (orquestrador) · security-check ✓ · testes de segurança ✓ · lint ✓

### Problemas / desvios da SPEC
Nenhum.

## Veredito final: **LIBERA**
Não há achado Crítico, Alto nem Médio em aberto. Todos os achados da M6 estão fechados, e o S21-B4 continua aceito e documentado no código.
