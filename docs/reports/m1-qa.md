## Etapa M1 — QA
Resultado: FAIL

O que foi feito: revisão independente de `Sources/VolumeCore` e `Tests/VolumeCoreTests`; `check.sh` do zero; cobertura medida; suíte rodada 5x; 73 casos de teste adicionais em `Tests/VolumeCoreTests/QAM1Tests.swift` (segurança do TextSanitizer, agrupamento hostil, SettingsModel, SafetyPolicy, regras do MixerStore, eventos fora de ordem). os demais passam; 8 funções de teste (nomeadas abaixo) expõem bugs e ficam falhando no repositório de propósito.

Como verificar:
```
rm -rf .build && scripts/check.sh                      # verde só sem QAM1Tests; com QAM1Tests os 8 abaixo falham
swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing --filter QAM1
```

Verificações:
- check.sh do zero (antes dos meus testes): ✓ (147 testes, 0 avisos, security-check ok). Com QAM1Tests: ✗ (8 falhas intencionais).
- Cobertura VolumeCore medida por mim (llvm-cov em `Sources/VolumeCore`): 99,33% de linhas (confere com o Dev). ✓ ≥ 85%.
- Estabilidade: suíte rodada 5x, resultados idênticos todas as vezes; os 147 testes do Dev sempre passam e minhas 8 falhas são determinísticas. Nenhum teste instável (flaky). ✓
- Arquitetura ✓: `VolumeCore` importa só Foundation e Observation (ArchitectureTests + grep); injeção por inicializador; sem singletons; `@MainActor` em MixerStore/SettingsModel/SafetyPolicy/OrderedWork e nos protocolos de Preferences/Hotkey; zero ocorrências de `@unchecked Sendable`, `nonisolated(unsafe)` ou `@preconcurrency` em Sources/Tests; os fakes usam `Mutex`.
- Escopo ✓: nada de Core Audio/AppKit/UI/rede; Package.swift sem dependências novas (KeyboardShortcuts adiada, documentado).
- Nenhum som produzido; nenhum arquivo de `Sources/` ou script alterado.

### Problemas (todos reproduzidos por teste em `Tests/VolumeCoreTests/QAM1Tests.swift`)

1. **[Média/Segurança §12.9.4] TextSanitizer deixa passar caracteres invisíveis** — `Sources/VolumeCore/TextSanitizer.swift:46-55` (`isRemoved`). Não são removidos: U+00AD, U+2061–2064, U+206A–206F, U+FFF9–FFFB, U+180E e os caracteres de tag U+E0001/E0020–E007F (permitem esconder texto invisível em nomes de app: "ASCII smuggling"). Teste: `otherInvisibleFormatCharactersAreRemoved(value:)` (19 casos) e `asciiSmugglingWithTagCharactersLeavesNothingInvisible`. Esperado: removidos (categoria Cf, exceto os que a regra decidir manter).
2. **[Média] `restoreOriginalAudio` não reseta apps ausentes da lista** — `Sources/VolumeCore/MixerStore.swift:144-152`. Só percorre `groups`; app silenciado/baixado que saiu da lista de processos mantém `states[id]` e volta mudo após o botão de pânico (risco de mudo acidental, §4.6). Teste: `panicAlsoResetsAppsThatAreTemporarilyAbsent`. Esperado: zerar todos os `states` (e a memória correspondente), não só os listados. (Os lembrados de apps nunca vistos na sessão continuam sendo aplicados; o orquestrador aceitou a regra só para os listados — vale reavaliar.)
3. **[Média] Pânico fica na fila atrás de um `reconcile` travado** — `MixerStore.swift:150` + `OrderedWork.swift`. `restoreAll` entra no mesmo `controllerWork` serial; se `reconcile` bloquear (coreaudiod lento), "Restaurar áudio original" não executa "imediatamente" (§4.6). Teste: `restoreIsNotQueuedBehindAHangingReconcile`. Esperado: `restoreAll` não esperar o `reconcile` pendente (o controller deve cancelá-lo/precedê-lo).
4. **[Baixa] Reenvio desnecessário ao pausar/retomar** — `AppAudioState.swift:22-38` / `MixerStore.swift:257`: `DesiredAppAudio` contém o `AudioApp` inteiro (inclui `isPlaying` e `name`), então play/pause de app com tap reenvia `reconcile` sem mudar ganho/mudo/dispositivo/PIDs. Inofensivo (controller é idempotente) mas viola "mesmo estado não reenvia". Teste: `playPauseOfATappedAppDoesNotResendTheDesiredState`.
5. **[Baixa] Volume não é excluído por caminho se o plist ilegível** — `ProcessGrouping.swift:114-120`: a exclusão do próprio app depende só de bundle ID; se `bundleID(atAppPath:)` devolver `nil` e o processo não tiver bundle ID, `/Applications/Volume.app/...` aparece na lista. Teste: `volumeIsExcludedByPathEvenWhenItsPlistIsUnreadable`.
6. **[Baixa] ZWJ/ZWNJ removidos quebram emoji compostos e escritas persa/índicas** — `TextSanitizer.swift:49`. `👨‍👩‍👧` vira três emojis. Teste: `zeroWidthJoinerEmojiSequencesSurvive`. Esperado: preservar U+200D/U+200C entre caracteres visíveis (decisão do orquestrador; pode-se aceitar e rebaixar o teste).
7. **[Baixa] `toggleExpanded` aceita ID inexistente** — `MixerStore.swift:138-140`: `expandedAppID` fica com "fantasma" até o próximo rebuild. Teste: `expandingAnUnknownAppIsIgnored`.

### Observações (sem teste falhando; sem ação obrigatória)
- Uma linha some imediatamente quando o processo sai da lista (`MixerStoreTests.appThatLeavesTheProcessListLeavesImmediately`), sem a janela de 5 s; volume/mudo em memória são mantidos ao voltar. Se o Core Audio remover o processo ao parar de tocar, a linha piscará; validar no M2.
- Sem saída padrão conhecida, apps com volume/mudo ficam sem tap (tocam no volume original enquanto a UI mostra o ajuste): falha aberta, coerente com §4.6, coberto por `unknownDefaultOutputLeavesAppsUntouchedInsteadOfGuessing`.
- Rota escolhida igual à saída padrão atual vira escolha explícita: se o padrão mudar depois, o app continua no dispositivo antigo (`routeToTheCurrentDefaultThenDefaultMovesKeepsExplicitChoice` documenta).
- Dois "encerramentos" por desligar/reiniciar o Mac nos primeiros 60 s contam como anormais (sem `markCleanExit`); o app precisa chamar `markCleanExit` também no encerramento de sessão (integração, M4).
- CLI sem `.app` e sem bundle ID (ex.: mpv em /opt/homebrew/bin) nunca aparece na lista.

### Resultados dos pontos exigidos (sem falhas)
Regra "sem tap" exata (99% ⇒ tap; 100%+mudo ⇒ tap; rota ≠ padrão ⇒ tap; rota = padrão ⇒ sem tap), idempotência (mesmo estado não reenvia; novo PID e troca de saída padrão reenviam), preferências corrompidas (-5, 999, NaN, string, tipos errados, UID gigante, 5000 registros ⇒ 1000) nunca silenciam, modo seguro com mudo lembrado não aplica e preserva a memória, restaurar durante debounce não deixa nada gravado, app reaparecido após restaurar volta a 100%, dispositivo removido durante rota cai para o padrão sem mudar e volta ao reconectar, PID reutilizado não herda estado, dois apps com o mesmo nome ficam separados, agrupamento hostil (`..`, ".app" aninhado, caminho relativo/com controle, bundle IDs de 100 KB/unicode/bidi, sem bundle e sem caminho, o próprio Volume e helpers) correto, debounce de 500 ms = 1 escrita, flush grava e cancela, limite de 1000, padrões da SPEC §3.3, ordenação/contador/`expandedAppID`, sanitizer com 10 MB (<1 s), UID de 10 MB nas preferências (<1 s), emoji/Unicode legítimos (exceto ZWJ) preservados.

Precisa do usuário: decidir o item 6 (ZWJ) e a abrangência do item 2.

---

## Reavaliação 1
Resultado: **PASS**

Verificações (do zero, `rm -rf .build`): `scripts/check.sh` verde (lint estrito, 0 avisos, 236 testes, security-check ok), incluindo os 8 testes que antes falhavam e 16 testes novos de reavaliação (`Tests/VolumeCoreTests/QAM1Round2Tests.swift`). Suíte rodada 5x: idêntica e verde (sem instabilidade). Cobertura própria de `Sources/VolumeCore`: 99,39% de linhas. Arquitetura: só Foundation, Observation e Synchronization (o `EpochCounter` novo); zero `@unchecked Sendable`/`nonisolated(unsafe)`/`@preconcurrency`.

Itens anteriores, todos corrigidos e confirmados pelos testes originais:
1. Sanitizer: agora remove toda categoria Cc/Cf (mais U+180E, tags E0000–E007F, FFF9–FFFB). Teste por varredura de todos os escalares Unicode: nenhum Cc/Cf sobrevive, exceto ZWNJ/ZWJ (tab/LF/CR viram espaço).
2. Pânico = lousa limpa: zera estados de todos os apps (inclusive ausentes) e chama `forgetAll`; app nunca visto com mudo lembrado volta a 100%.
3. Pânico não espera `reconcile` travado: `restoreAll` roda numa Task própria; `reconcile` já na fila é descartado por época.
4. Play/pause, mudança de nome e transições de ociosidade não reenviam; novo PID reenvia.
5. Volume excluído por bundle ID, por PID próprio (inclusive como processo responsável) e por caminho `Volume.app` sem plist. PID próprio não esconde os outros processos do mesmo app.
6. ZWJ/ZWNJ preservados só entre dois escalares visíveis, um por vez; nunca no início/fim; inundação de 5 milhões de repetições fica limitada e rápida (< 1 s).
7. `toggleExpanded` ignora ID inexistente.

Mudança do Dev em `bidiAndZeroWidthAreRemoved` (tirou U+200C/U+200D da lista hostil): legítima, pois esses dois agora são preservados por decisão do orquestrador; o caso é coberto por `TextSanitizerTests.joinersSurviveOnlyBetweenVisibleCharacters` (início, fim, espaço, repetidos, mistos com bidi, 300 repetições) e pelos meus `zeroWidthJoinerEmojiSequencesSurvive` e `joinerEdgeCases`/`joinerFloodIsBoundedFastAndNeverEndsWithAJoiner`/`neverTwoJoinersInARow`.

Ordens de eventos maliciosas testadas após o pânico (nenhum tap velho reaplicado): reconciles enfileirados descartados, último chamado = `reconcile([])`; mudanças após o pânico chegam depois do `restoreAll`; 6 pânicos seguidos e pânico sem apps; troca de saída padrão e novos PIDs durante/depois do pânico não ressuscitam estado.

Observações residuais (sem bloqueio): (a) um `reconcile` que já estava em execução no controller não é cancelado pelo domínio; no M2 o controller deve tornar `restoreAll` prioritário e abortar/desfazer esse trabalho em andamento (o domínio em seguida envia `reconcile([])`, que corrige o estado). (b) Qualquer app sem bundle ID chamado "Volume.app" é ocultado (efeito colateral da exclusão por caminho; inofensivo).
