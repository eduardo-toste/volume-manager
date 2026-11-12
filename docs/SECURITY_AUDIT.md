# Auditoria de segurança independente — M7.5

Data: 2026-11-12 · Branch `etapa/m7.5` (base `a0847ab`) · Auditor: Agente de Segurança (não escreveu o código)

Escopo: `Sources/` inteiro (IOProc, `VolumeAudio`, `VolumeCore`, `VolumeSystem`, `VolumeUI`, composição, `vmctl`), `scripts/` (build, release, check, security-check, DMG, vmctl-app), `Package.swift`, `Resources/` (entitlements, Info.plist, xcstrings, Version), binário `build/Volume Manager.app`, relatórios anteriores `docs/reports/*-security.md`. Referência: SPEC §4.6, §4.7, §12.8.1, §12.9 e `CLAUDE.md`.

Não alterei código de produção. Arquivos novos: os 3 testes listados no fim e este relatório.

---

## Veredito: **LIBERA**

Não encontrei nenhum achado Crítico nem Alto. São **2 Médios**, os dois de processo/verificação, sem exposição no app de hoje. Há também **3 Baixos** e **6 Informativos**. As 4 pendências da etapa estão fechadas (§1).

| ID | Grav. | Resumo |
|---|---|---|
| S75-M1 | Médio | O método "sinal ≠ 0 dentro de tap `mutedWhenTapped` sem saída física" (SPEC §12.8.1, regra 14) é inseguro. Foi o que causou o som no revoke-exp. |
| S75-M2 | Médio | A checagem de entitlements do `security-check.sh` usa lista negra incompleta. Ela aprova uma exceção de Hardened Runtime e o entitlement de microfone. |
| S75-B1 | Baixo | O release compila arquivos ignorados pelo git dentro de `Sources/`, que o `git status` não mostra. |
| S75-B2 | Baixo | Superfície desnecessária: `pidStillMatches` e `responsibleAppPath` não têm nenhum chamador. |
| S75-B3 | Baixo | `release.sh` não confere a assinatura da tag (SPEC §12.9.6). |
| S75-I1…I6 | Info | Origem das consultas TCC, logs, `_dlsym` do compiler-rt, prova de `kill -9`, Volume Manager aberto durante os testes, leitura das preferências. |

---

## 1. Pendências da etapa

### 1.1 Por que o tom do revoke-exp foi ouvido (só leitura de código, logs e documentação; nenhum sinal gerado)

**Conclusão: o `mutedWhenTapped` funcionou. Quem tocou o tom no fone foi o próprio Volume Manager, que estava aberto e fez o que a SPEC §4.2 manda: pôs tap no processo que tocava e reemitiu o áudio dele com ganho 1 na saída física.**

Evidência (`/usr/bin/log show`, 2026-11-11, `coreaudiod` e subsistema `com.volumemanager.app`):

```
19:53:57.444 HALS_Device::Activate: activating device 6724: com.volumemanager.vmexp.A.CD65…      ← aggregate do experimento (só tap)
19:53:57.557 HALS_Client::AddMuter: Process afplay (6700) muted by vmexp-A (6722) for all devices ← mudo do experimento OK
19:53:57.715 VolumeManager[59546] [com.volumemanager.app:audio] tap plan: create                  ← o app aberto (PID 59546)
19:53:57.722 HALS_Device::Activate: activating device 6730: com.volumemanager.agg.CDB12998-…
19:53:57.737 IOWorkLoopInit: 6735 AC-07-75-D9-E8-39:output (com.volumemanager.agg.CDB12998-…)  ← saída = fone
19:53:57.738 HALS_Client::AddMuter: Process afplay (6700) muted by Volume tap (6728)             ← "Volume tap" = CoreAudioTapSession.swift:86
19:53:57.741 HALS_Client::AddMuter: Process com.volumemanager.vmctl-exp (6701) muted by Volume tap (6728)
19:54:21.705 IOWorkLoopDeinit: … vmexp.A …                                                       ← fim (source_ended 24,41 s no log do experimento)
```

O Volume Manager PID 59546 (aberto desde 2026-11-10 22:03) juntou o `afplay` do experimento e o `vmctl-exp` num só app, porque o processo responsável do `afplay` é o `vmexp.app`. Depois criou um tap com aggregate cuja saída é o fone, e o IOProc copiou `amostra × 1` do tap para a saída. O tom de −50 dBFS que o experimento capturou (maxAbs 0,003010 em `real/log.csv`) chegou ao fone por esse caminho.

**Por que o método é inseguro.** "`mutedWhenTapped` + aggregate sem saída física" só garante duas coisas: o processo-fonte não toca direto no hardware enquanto *este* tap é lido, e *o nosso* IOProc não escreve em lugar nenhum. Não garante nada sobre outros leitores. Taps privados de outros processos são invisíveis, então não dá para verificar antes que não existe nenhum. São três as formas de vazar, todas fora do controle do teste:
1. Qualquer outro tap-mixer aberto reemite a fonte: o próprio Volume Manager (que põe tap em **todo** app que toca), uma build deixada aberta pelo QA ou pelo usuário, ou apps de terceiros.
2. Pelo cabeçalho `CATapDescription.h`, o mudo vale só "for the duration of the read activity on the tap". Antes de a leitura começar e depois que ela para, a fonte toca no hardware. O próprio experimento destruía os taps antes de matar o `afplay` (`cleanup()`, `vmexp.swift:172-176`), o que abria uma janela audível no fim de toda rodada.
3. Uma falha de criação, um reinício do `coreaudiod` ou uma permissão negada também soltam a fonte. Com `.muted` é igual, porque o mudo continua sendo um controle só, no servidor.

**Efeito no app: nenhum.** O aggregate do app sempre tem a saída física como subdispositivo principal (`CoreAudioTapSession.swift:155-173`). Um aggregate sem saída é recusado antes do IO, porque `FormatPolicy.validate` exige `outputShape` não vazio (`StreamLayout.swift:79-82`). O log mostra o mudo do app aplicado "for all devices", e os testes de ouvido ⏸0/⏸1 confirmaram que em 0% o app fica em silêncio. A sonda de permissão usa `.unmuted` (`SystemAudioAccessProbe.swift:81,131`) e não altera o som. A reemissão que vimos aqui é o comportamento especificado.

**SPEC §12.8.1 (2º item) e `CLAUDE.md` regra 14 precisam de correção.** Ver S75-M1. Eu recomendo e não altero.

### 1.2 Consultas do `tccd` a `kTCCServiceListenEvent` e `kTCCServiceMicrophone`

**Conclusão: são *preflights* (consultas sem pedido) feitos por frameworks da Apple quando o app é aberto, não no clique. O próprio `tccd` registra que, com Hardened Runtime e sem o entitlement, o pedido de microfone é impossível. Isso não vira pedido de permissão enquanto os entitlements continuarem vazios. Esse guarda está em S75-M2.**

Evidência (PID 84220, aberto em 2026-11-11 23:16:06):

| Hora | Serviço | Quem pergunta | Origem provável |
|---|---|---|---|
| 06.318 | `ListenEvent`, `preflight=yes`, authValue=1 | o próprio app, logo antes de `[com.apple.SkyLight] server port …` | AppKit/SkyLight ao conectar no WindowServer (`NSApplication.shared`) |
| 06.323 / 06.328 | `ListenEvent`, `preflight=yes` | WindowServer, em nome do app | idem |
| 06.357 | `Microphone`, `preflight=yes` | o app, logo depois de `HALSystem.cpp:135 Enabling HAL Voice Isolation support` | inicialização do cliente HAL do CoreAudio na primeira chamada de áudio |
| 06.359 | `Microphone`, `preflight=yes` | `coreaudiod` (uid 202), em nome do app | registro do cliente no servidor |
| — | `tccd`: "Prompting policy for hardened runtime; service: kTCCServiceMicrophone requires entitlement com.apple.security.device.audio-input but it is missing" | — | é o bloqueio que impede o pedido |

Outras consultas encontradas: `AppleEvents` (preflight do `appleeventsd` ao abrir o app, também bloqueado: "requires entitlement com.apple.security.automation.apple-events but it is missing") e `Accessibility`. A de Acessibilidade é o AppKit conferindo se o **cliente** de acessibilidade é confiável (`accessing=com.FluidApp.app`, o app de ditado do usuário). Não é o Volume Manager pedindo algo para si.

Contagem em 5 dias, em todas as mensagens `AUTHREQ_CTX` que citam o app: a única solicitação real (`preflight=no`) é `kTCCServiceAudioCapture` (282 ocorrências). Todo o resto é preflight: ListenEvent 31, Microphone 14, ScreenCapture 160 (WindowServer), AudioCapture 7, Accessibility 2 e outras.

Nenhuma API do app causa isso. O código não usa monitor global de eventos, `CGEvent`, `IOHID`, AVFoundation de entrada nem `AXIsProcessTrusted`. O único monitor é `NSEvent.addLocalMonitorForEvents(.scrollWheel)` (`VolumeInput.swift:62`), que não exige permissão.

### 1.3 Logs `.notice` de ciclo de vida

**Fechado (S41-B3).** Os logs de ciclo de vida foram rebaixados para `.info` na M7 (`55fdd17`), e `.info` não é persistido por padrão. Restam dois `.notice` (`TapPipeline.swift:130,144`), só no caminho anormal "objeto deixado, identidade não confirmada", e eles levam apenas o ID numérico do objeto. Revisei toda interpolação de log em `Sources/` fora do `vmctl`. Nenhuma leva nome, bundle ID, caminho, PID ou nome de dispositivo. Os `error`/`warning` levam só `OSStatus`, seletor de quatro caracteres, ID numérico ou um enum (`AudioError.swift:38-40`, `AudioProperty.swift:45,127-132`). O texto de `AudioError.context` nunca contém dado de outro processo. A UID de dispositivo aparece só em `vmctl`, que não vai no app.

### 1.4 Achados anteriores

| Achado | Situação | Evidência |
|---|---|---|
| S21-B1 (tap órfão depois do reinício do `coreaudiod`) | **Fechado.** `.serviceRestarted` destrói todas as entradas, conferindo a identidade. | `CoreAudioAppController.swift:358-366` |
| S21-B2 (`restoreAll`/crossfade com IDs mortos) | **Fechado.** Há um único `teardown()` com `resolve` (ID → UID → tradução por UID). | `TapPipeline.swift:91-150` |
| S6-M1 (falhar fechado deixava tap mudo vivo) | **Fechado.** O objeto é traduzido pela UID (`TranslateUIDToDevice`/`ToTap`) e destruído. Se ficar algo, gera `notice` e o estado é retido. | `TapPipeline.swift:95-98,111-148,153-171`; HardwareTests M6 |
| S41-B3 (logs `.notice` persistidos) | **Fechado.** | §1.3 |
| S41b-B3 (pico ≤ 40 ms em ganho 1 se o número de canais mudar na rampa) | **Aceito, não mudou.** É falha aberta (cópia sem alteração e kill switch). | `RealtimeTapState.swift:109-118` |
| S53-B2 (marca velha + negação real esconde o aviso) | **Aceito pelo usuário, não piorou.** Com certificado estável (M7), a marca velha só aparece num reset do TCC ou numa revogação, não a cada build. | `MixerStore.swift` (gate da marca) |
| Revogação que zera só taps novos | **Risco aceito, não piorou.** O som do revoke-exp **não** tinha relação com a revogação (§1.1). Essa variante não pode ser testada com segurança sem sinal audível. O `systemResumed` (M6) ainda recria todos os taps ao acordar. | `CoreAudioAppController.swift:372-375` |
| M-1 (`weak_import` sem checagem de nulo) | **Aceito.** O binário importa `weak external _responsibility_get_pid_responsible_for_pid`, e `RELEASE.md §4` confere o símbolo. | `nm -m` do bundle |

---

## 2. Achados

### S75-M1 · Médio · O método de "sinal audível isolado" do §12.8.1 / regra 14 não isola

- **Evidência**: §1.1, com as linhas de log de 2026-11-11 entre 19:53:57 e 19:54:21. SPEC §12.8.1, 2º item: "Sinais de teste não-silenciosos só podem existir dentro de um tap com `mutedWhenTapped` cujo aggregate não tem saída física … nunca chega aos alto-falantes". `CLAUDE.md` regra 14 repete a autorização.
- **Impacto**: o usuário ouviu um som de teste na própria máquina, o que viola a regra 14 e a sua intenção. O texto ainda autoriza o método para agentes futuros. Basta um tap-mixer aberto (o próprio Volume Manager, no caso), uma ordem errada de teardown ou uma falha do servidor para o sinal chegar ao fone. A memória do orquestrador registra "nunca repetir", mas a SPEC e o `CLAUDE.md`, que mandam, continuam dizendo que é seguro. Não há impacto no app distribuído.
- **Recomendação** (para o orquestrador ou o usuário; eu não altero):
  1. §12.8.1: trocar o 2º item por "**Somente silêncio digital (todas as amostras = 0)**. Nenhum teste ou experimento gera sinal ≠ 0, nem dentro de tap. O mudo de um tap vale só enquanto ele é lido e não impede que outro cliente (outro tap-mixer, inclusive o próprio Volume Manager) reemita a fonte." Remover também "ou sinal com ganho 0", que é ambíguo.
  2. `CLAUDE.md` regra 14: tirar a exceção "ou sinais só dentro de tap `mutedWhenTapped` com aggregate sem saída física (SPEC §12.8.1)".
  3. §12.8.2 (testes de qualidade com sinal conhecido): esses testes só podem existir sobre buffers em memória, como já fazem `GainKernelTests` e `RenderTests` com seno sintético, nunca pelo HAL.

### S75-M2 · Médio · A checagem de entitlements é lista negra e deixa passar exceção de HR e acesso a recursos

- **Evidência**: `scripts/security-check.sh:181-194` procura só 6 chaves. A SPEC §12.9.2 tem a mesma lista e não inclui `com.apple.security.cs.disable-executable-page-protection`, que também é exceção de Hardened Runtime. Os entitlements de acesso a recurso também passam: `device.audio-input`, `device.camera`, `automation.apple-events`, `personal-information.*`. Reprodução, sobre uma cópia do bundle no scratchpad, apagada logo depois e nunca executada:
  ```
  codesign --force --options runtime --entitlements bad.entitlements --sign - Probe.app
  #   bad.entitlements = cs.disable-executable-page-protection + device.audio-input + automation.apple-events
  VOLUME_APP=…/Probe.app scripts/security-check.sh --app   →  "ok: bundle checks … security-check: OK", exit 0
  ```
- **Impacto**: hoje nenhum, porque `Resources/VolumeManager.entitlements` é `<dict/>` e o binário assinado também (`codesign -d --entitlements -`). Mas esse é o único guarda automático das regras 5 e 6, e o `release.sh:114` confia nele para o artefato publicado. Uma regressão (`device.audio-input` + `NSMicrophoneUsageDescription`, ou relaxar a proteção de páginas) passaria verde. É exatamente o controle que hoje impede que os preflights de §1.2 virem pedido.
- **Recomendação** (Dev, cerca de 5 linhas): trocar a lista negra por lista branca. O entitlements assinado e o de `Resources/` têm de ser **dicionário vazio** (por exemplo `plutil -extract` ou `PlistBuddy -c Print` sem chaves). Acrescentar `cs.disable-executable-page-protection` à lista do §12.9.2. Deixei `Tests/VolumeCoreTests/SecurityM75PolicyTests.swift`, que já exige isso do arquivo-fonte. A checagem do binário assinado continua sendo do `security-check.sh`.

### S75-B1 · Baixo · O release pode assinar código que não está na tag

- **Evidência**: `release.sh:30` aceita a árvore se `git status --porcelain` vier vazio. Esse comando não mostra arquivos ignorados. O `.gitignore` ignora `build/`, `dist/` e `*.app` em qualquer nível, e o SwiftPM compila todo `.swift` debaixo de `Sources/<alvo>/`:
  ```
  git check-ignore -v --no-index Sources/VolumeCore/build/Injected.swift   →  .gitignore:4:build/
  ```
- **Impacto**: um arquivo esquecido ou plantado (por exemplo `Sources/VolumeCore/build/X.swift`) entraria no binário assinado sem estar no commit da tag. A estática do `security-check` ainda o veria (`find Sources`), mas o release deixaria de ser reprodutível a partir da tag. Plantar exige escrita local, o que já é comprometimento.
- **Recomendação**: no `release.sh`, falhar se `git status --porcelain --ignored -- Sources Resources Package.swift scripts` não vier vazio. A alternativa mais forte é compilar de um `git worktree add "$WORK/src" "$TAG"`.

### S75-B2 · Baixo · Superfície desnecessária: duas APIs públicas sem uso

- **Evidência**: `WorkspaceAppInfoProvider.swift:39-44` (`pidStillMatches`) e `:61-66` (`responsibleAppPath`). `grep -rn` em `Sources` e `Tests` acha só as definições.
- **Impacto**: código morto aumenta o que precisa ser auditado. O comentário de `pidStillMatches` diz que ela protege contra reuso de PID, o que pode levar um revisor a acreditar num controle que não está ligado. O controle real é `CoreAudioTapEngine.confirmedProcesses` (`CoreAudioTapEngine.swift:31-39`).
- **Recomendação**: apagar as duas funções.

### S75-B3 · Baixo · A tag de release não tem a assinatura conferida

- **Evidência**: `release.sh:32-33` exige que a tag exista e aponte para o HEAD, mas não executa `git verify-tag`. A SPEC §12.9.6 pede "tags de release assinadas".
- **Impacto**: um release poderia sair de uma tag leve ou não assinada sem aviso. Isso enfraquece a rastreabilidade do canal oficial.
- **Recomendação**: `git verify-tag "$TAG" || die "tag $TAG is not signed"`. Se o usuário não assina tags, registrar isso no §12.9.6 em vez de deixar o requisito sem verificação.

### Informativos

- **S75-I1 (TCC)**: §1.2. Nada a fazer além de S75-M2.
- **S75-I2 (`_dlsym` no binário)**: `dyld_info -imports` lista `_dlsym`. O código-fonte não o usa. Ele vem do `__isPlatformVersionAtLeast` do compiler-rt (gerado por `#available`), que resolve nomes **fixos** do CoreFoundation (`kCFAllocatorNull`, `CFDataCreateWithBytesNoCopy`, `CFPropertyListCreateWithData`, …) para ler a versão do sistema. Isso não é carregamento de código nem caminho variável, e cumpre o §12.9.2. Recomendação: registrar isso como linha de base esperada no `RELEASE.md`, para quem inspecionar o binário.
- **S75-I3 (`kill -9` em momentos variados)**: foram 4 rodadas de `vmctl-dev.app set pid:N` (sem recompilar) sobre um `afplay -v 0` de WAV todo zero iniciado por mim, com SIGKILL em +0,05 s, +0,3 s, +1,0 s e +2,5 s. O log do `coreaudiod` mostra o servidor desmontando o aggregate `com.volumemanager.agg.*` do cliente morto **5 ms** depois do kill (`unregister_meta_device`) e devolvendo o som da fonte em **9 ms** (`RemoveMuter … unmuted`). Em +0,05 s o processo morreu antes de criar qualquer objeto. Em +0,3 s o aggregate já existia e o IO ainda não, e ele foi desmontado sem mudo pendente. Em todas as rodadas sobraram 0 processos `vmctl`. A rodada de controle seguinte criou tap e recebeu ~48 k quadros/s, então o servidor ficou saudável. Ao fim: 0 `afplay`, 0 `vmctl`.
- **S75-I4 (Volume Manager aberto durante os testes)**: o `build/Volume Manager.app` PID 84220, aberto em 2026-11-11 23:16 e não por mim, está rodando. Ele pôs tap no meu `afplay` silencioso e no `vmctl-dev`. Também agrupou o `afplay` com um `com.apple.WebKit.GPU` do usuário, pelo processo responsável em comum. Como tudo era silêncio digital, nada foi audível. É o mesmo mecanismo do §1.1: qualquer teste de hardware com o app aberto é lido duas vezes, e um sinal ≠ 0 seria reemitido. Não abri nem fechei o app.
- **S75-I5 (preferências)**: `SettingsModel.loadRememberedApps` ordena o dicionário inteiro antes de aplicar o limite de 1000 (`SettingsModel.swift:122-131`). Um processo do mesmo usuário pode atrasar a abertura gravando milhões de chaves, mas esse processo já controla o domínio inteiro. A validação de tipos está correta também para os tipos reais que o `defaults write` grava, como mostram os testes novos: `-int 1` não vira booleano, `-float 1e300` não vira contador e containers de tipo errado são ignorados.
- **S75-I6 (texto desatualizado)**: `scripts/check.sh:6` diz "CI runs these steps", mas o projeto não tem CI. É só documentação.

---

## 3. Revisão por área (sem achado novo)

- **IOProc** (`CoreAudioTapSession.swift:8-14`, `RealtimeTapState.swift:79-141`, `GainKernel.swift:34-66`, `SignalProbeState.swift:11-30`): não aloca, não usa lock, log, `async` nem ARC (`_withUnsafeGuaranteedRef` e atômicos `relaxed`). Toda leitura e escrita fica limitada por `min(capacity, available) / (4 × canais)`. Uma contagem de canais diferente ou igual a 0 copia sem alteração e levanta o kill switch. Um buffer de entrada ausente zera e levanta o kill switch. O ganho é saneado (NaN vira 1, faixa [0, 1]). Uma contagem de canais de até `UInt32.max` não estoura nem sai do buffer (teste novo, também sob ASan).
- **Corridas no ciclo de vida**: `KillList.stopAll` concorrente com `destroy` do ator. O `Mutex` do `TapPipeline` entrega os recursos a um único chamador, e o segundo recebe `Resources()` vazio. Na reentrância do ator durante o crossfade (`clock.sleep`), o antigo continua na kill list e é parado depois. Com `restoreAll` no meio de `makeSession`, a geração é conferida logo depois do `killList.add`. Num objeto deixado vivo, o estado é retido para sempre (`teardown(keeping:)`) e não há use-after-free.
- **Dispositivo desconectado no meio da reconciliação**: um aggregate sem saída é recusado por `FormatPolicy.validate` antes do IO. Depois do IO, sem buffers de saída o contador de quadros não avança (`RealtimeTapState.swift:132-135`), o vigia detecta o travamento em 2 s e destrói o tap, e o som original volta. Isso está coberto por `ControllerTests` (`unplugging…`, `missingDevice…`, `everyCreationFailure…`).
- **Dados de outros processos**: `TextSanitizer` (≤ 4096 escalares inspecionados, ≤ 200 caracteres), `AppPath.canonicalize` (léxico, sem tocar no disco, sem Cc/Cf), `validBundleID` (ASCII DNS reverso, ≤ 200), strings do HAL cortadas em 1024. A UI usa `Text(verbatim:)` e `String(format:)` com o formato sempre nosso (`AppRowView.swift:55,137`, `RowPresentation.swift:23-31`), então não há Markdown nem formato vindo de terceiros. Reuso de PID: o objeto do HAL é resolvido uma vez, a identidade é conferida e o PID do objeto é relido (`CoreAudioTapEngine.swift:31-39`).
- **Preferências**: validação na leitura (`PreferenceValidation`, `RememberedApp(validating:)`), escrita só de property list simples com profundidade ≤ 4 (`UserDefaultsPreferencesStore.swift:72-86`). O contador do modo seguro é limitado a [0, 100].
- **Rede, gravação, permissões**: zero rede (os únicos links abertos são URLs fixas por `NSWorkspace.open`, `Composition.swift:150-161`). Nenhuma amostra é gravada (a sonda guarda só um booleano). O Info.plist tem só `NSAudioCaptureUsageDescription` e nenhum URL scheme, Services ou AppleScript (teste novo).
- **Binário e cadeia de suprimentos**: flags `0x10002(adhoc,runtime)` neste build de desenvolvimento, entitlements `<dict/>`, só bibliotecas de `/System` e `/usr/lib`, sem DWARF, `vmctl` fora do bundle. `Package.swift` sem dependências e sem `Package.resolved`; `.build/checkouts` e `.build/artifacts` vazios. Os scripts não fazem rede (o `release.sh` só imprime a URL de upload).

---

## Etapa M7.5 — Segurança
Resultado: **ENTREGUE — LIBERA**

O que foi feito:
- Auditoria completa de `Sources/`, `scripts/`, `Package.swift`, `Resources/` e do bundle gerado, contra o §12.9 e o modelo de ameaças.
- Fechamento das 4 pendências da etapa:
  - revoke-exp explicado pelos logs: o tom foi reemitido pelo Volume Manager aberto (PID 59546);
  - consultas TCC identificadas como preflights do AppKit/SkyLight e do HAL, que o Hardened Runtime impede de virar pedido;
  - logs `.notice` fechados;
  - situação dos achados anteriores conferida.
- Prova de `kill -9` com áudio real em silêncio digital.
- Prova de que o `security-check.sh` aceita entitlements proibidos.
- Testes adversariais novos:
  - `Tests/VolumeCoreTests/SecurityM75PreferencesTests.swift`: preferências com os tipos reais do `defaults write`, decodificadas de plist, em memória; o domínio real não foi tocado.
  - `Tests/VolumeCoreTests/SecurityM75PolicyTests.swift`: entitlements vazio e Info.plist sem canais de entrada.
  - `Tests/VolumeAudioTests/SecurityM75RenderTests.swift`: `render` com contagens de canais hostis.

Como verificar:
```
swift test --filter SecurityM75                                    # 9 testes (22 casos parametrizados no render)
swift test --sanitize=address --filter "SecurityM75RenderTests|SecurityM2MemoryTests"
scripts/check.sh                                                   # verde
git check-ignore -v --no-index Sources/VolumeCore/build/X.swift    # S75-B1
/usr/bin/log show --start "2026-11-11 19:53:57" --end "2026-11-11 19:53:59" --style compact \
  --predicate 'process == "coreaudiod" AND (eventMessage CONTAINS "Muter" OR eventMessage CONTAINS "Activate")'   # §1.1
```

Verificações: check.sh ✓ · security-check ✓ · cobertura: não medida nesta etapa · ASan nos testes de render ✓

Problemas / desvios da SPEC:
1. S75-M1: SPEC §12.8.1 (2º item) e `CLAUDE.md` regra 14 autorizam um método que não isola o som. Correção recomendada em §2.
2. S75-M2: `scripts/security-check.sh:181-194` e SPEC §12.9.2 usam lista negra incompleta (falta `cs.disable-executable-page-protection` e os entitlements de recurso).
3. S75-B1: `scripts/release.sh:30` ignora arquivos ignorados pelo git em `Sources/`.
4. S75-B2: `Sources/VolumeSystem/WorkspaceAppInfoProvider.swift:39-44,61-66` é código morto.
5. S75-B3: `scripts/release.sh:32-33` não confere a assinatura da tag (§12.9.6).

Precisa do usuário:
- Decidir a correção do §12.8.1 e da regra 14 (S75-M1). Recomendo proibir qualquer sinal ≠ 0.
- Decidir se o Dev corrige S75-M2 e os Baixos antes da M8. Nenhum bloqueia.
- O Volume Manager.app de `build/` (PID 84220, aberto em 2026-11-11 23:16) continua rodando. Ele não foi aberto por mim e eu não o fechei.
