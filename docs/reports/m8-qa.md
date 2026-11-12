## Etapa M8 — QA (aceite final)
Resultado: PASS nos critérios automáticos; 11 critérios dependem do usuário (⏸4) e 2 têm ressalva de cobertura automática. Nenhum bloqueante.

O que foi feito: rodei tudo do zero no commit c80e70f (branch etapa/m8, árvore limpa), medi cobertura, li o Volume Manager já aberto (somente leitura), conferi o §14 critério a critério e escrevi a seção M8/⏸4 em `docs/MANUAL_TESTS.md`. Nenhuma alteração em `Sources/`, nenhum som, nenhum acesso à rede, nenhum commit/tag.
Como verificar: `scripts/check.sh` · `scripts/check.sh --app` · `swift test --enable-code-coverage` + `xcrun llvm-cov report <vmctlTests.xctest>/Contents/MacOS/vmctlTests -instr-profile=.build/out/Products/Debug/codecov/default.profdata Sources/VolumeCore`.
Verificações: check.sh ✓ (182 testes, 36 suites, build sem avisos, lint) · check.sh --app ✓ · security-check ✓ (fonte + bundle) · cobertura VolumeCore 96,72% regiões / 99,29% linhas (meta ≥ 85%).

### Critérios do §14
| # | Resultado | Evidência |
|---|---|---|
| 1 Boas-vindas / SMAppService | MANUAL (usuário, ⏸4) | Lógica coberta em `WelcomeModel`/`LoginItemModel` (100% linhas); abrir o app real e conferir Itens de Início é manual (MANUAL_TESTS B.3). |
| 2 Reinício → barra sem janela | MANUAL | C.14. |
| 3 Claro/Escuro ao vivo | MANUAL | C.8 (snapshots existem, troca de tema real não). |
| 4 Volume/mudo por app, sem estalo/recriação | Parcial: AUTOMÁTICO ✓ lógica (kernel: ganho exato, rampa sem degraus, ganho 1 bit a bit — `GainKernelTests`, `docs/reports/m2-qa.md`; "volume não recria tap" em MixerStore/controller); ouvir = MANUAL | C.5. |
| 5 Rota por app / desconexão / reconexão | AUTOMÁTICO ✓ fallback de rota (`RoutingPolicy` 100%, testes do MixerStore); hardware real = MANUAL | C.6. |
| 6 Teclas de volume | MANUAL | C.7. |
| 7 Lembrar volume (72%/rota) | AUTOMÁTICO ✓ `MixerStore`/`RememberedApp`/`PreferenceValidation`; app real = MANUAL | C.9. |
| 8 Permissão negada → aviso → conceder | AUTOMÁTICO ✓ lógica (`PermissionMonitor`, `SecurityM41`, m4.1/m5.3 reports); fluxo real = MANUAL | C.10, B.3. |
| 9 Sem atalho global; Tab/setas/Espaço/Esc; ⌘, / ⌘Q | AUTOMÁTICO ✓ parcial: nenhum `RegisterEventHotKey`/monitor global/CGEventTap em `Sources/`; só `.keyboardShortcut` locais (`MenuBarPopover.swift:171,215`, `WelcomeView.swift:46`). Teclado real = MANUAL | C.7. |
| 10 Sair restaura áudio | AUTOMÁTICO ✓ `QA M2: fail open`, shutdown no MixerStore; ouvir = MANUAL | C.12. |
| 11 Testes de núcleo, cobertura ≥ 85% | AUTOMÁTICO ✓ 96,72%/99,29% (MixerStore 99,5% linhas, ProcessGrouping 97,6%, PreferencesStore/PreferenceValidation 100%, RoutingPolicy 100%) | comando acima. |
| 12 check.sh passa | AUTOMÁTICO ✓ rodado agora (também `--app`). |
| 13 macOS 15+ / 26+ | MANUAL (macOS 27 só no host; macOS 15 precisa de outro Mac/VM) | D. |
| 14 Orçamentos §12.4 | Parcial: AUTOMÁTICO leitura (abaixo); resto MANUAL | MANUAL_TESTS A. |
| 15 Falhar abrindo | AUTOMÁTICO ✓ vigia, Restaurar, modo seguro, SIGTERM (testes `QA M2: fail open`, M6 reports); Forçar Encerramento real = MANUAL | C.11, C.13; D (M6 5–8). |
| 16 security-check | AUTOMÁTICO ✓ rodado agora (fonte e `--app`: análise estática, segredos, dependências zero, entitlements, bundle). |
| 17 Auditoria sem Crítico/Alto | AUTOMÁTICO ✓ documental: `docs/SECURITY_AUDIT.md` veredito LIBERA (reverificação M7.5 e M7.6: sem Crítico/Alto; abertos só S75R-B1/B2, Baixos de texto). Não refeito. |
| 18 Matriz de apps | MANUAL | B.4 (tabela). |
| 19 Qualidade de áudio | Parcial: AUTOMÁTICO ✓ ganho exato, ganho 1 bit a bit (NaN, -0, subnormal), rampa, formato preservado no kernel (`GainKernelTests`, m0.5/m2-qa); sem diferença na escuta = MANUAL. Ressalvas 1 e 2 abaixo. | C.16. |
| 20 Testes não produzem som | AUTOMÁTICO ✓ por construção: suíte de hardware pulada por padrão (tag `.audioHardware`, `VOLUME_AUDIO_TESTS`), `SilentPlayer` só zero, regra 14/§12.8.1 (S75-M1 fechado); nada audível nas execuções de hoje (nenhum teste de hardware rodado). |

### Performance (§12.4) — leitura do app já aberto
Processo PID 84220, `build/Volume Manager.app` v1.0.0 build 1, início 2026-11-11 23:16:06 (build de dev, não o do DMG), medido em 2026-11-12 01:11, sem áudio tocando.
- CPU ocioso: 0,0% (`ps`, 6 amostras; `top -l 3 -s 5`). Orçamento ~0%: ok.
- Memória: `phys_footprint` 41 MB (pico 47 MB); `top` 41 MB: ok (< 60 MB). RSS do `ps` = 106 MB (inclui páginas compartilhadas de frameworks) — se o critério fosse RSS, estouraria; registrei a distinção.
- Aggregates `com.volumemanager.agg.`: 0 visíveis em `system_profiler` (aggregate privado pode não aparecer; confirmar pelo log com música tocando). Não executei `vmctl-dev.app` (o build existente é de 7/nov, antigo).
- Sockets de rede do processo: 0.
- Não medidos (MANUAL): CPU com tap, abertura do popover (< 100 ms; medição prévia M4: ~70 ms com dados falsos), slider 60 fps, início < 1 s, latência.
- Atenção: `check.sh --app` (pedido) reconstruiu `build/Volume Manager.app`, o mesmo caminho do processo aberto. O processo continua com o binário antigo em memória; o arquivo no disco agora é o novo build (mesma versão, cdhash diferente). Reabrir esse app exigirá "Permitir…" de novo (build ad hoc). Não o fechei nem reabri.

### Ressalvas
1. Latência ≤ 20 ms (§12.8.2, critério 19): não existe teste nem código que leia o tamanho de buffer/latência do aggregate (grep por latency/latência/BufferFrameSize em `Sources/` e `Tests/` sem resultados). Fica só como derivação do desenho (sem buffer extra) e escuta/sincronia labial no roteiro (A.5). Gravidade: Baixa.
2. "10 minutos de sinal sem buffer perdido" (§12.8.2): sem teste automático equivalente de 10 min no kernel; há teste de continuidade da rampa (`Gain ramp continuity`) e os testes de 10 min de silêncio do vigia (`SecurityM41`). Baixa.
3. Critério 14 pede Instruments/Activity Monitor: usei `ps`/`top`/`footprint`; números com tap ativo dependem do usuário.
4. Número de memória depende da métrica (footprint 41 MB × RSS 106 MB).
5. Esta máquina não valida macOS 15 (critério 13).

### Riscos conhecidos e aceitos (SPEC §10 e PROGRESS)
Sandbox desligado em v1; agrupamento de processos auxiliares (mitigado, matriz manual); dispositivos sem volume por software; apps com hog mode; API privada de processo responsável com `weak_import` e M-1 aceito (símbolo conferido em RELEASE.md §4); S41b-B3 (pico ≤ 40 ms se o número de canais mudar durante a rampa); novo "negada" do vigia reinicia o orçamento (Baixo); Boas-vindas até "Começar"; I-5; chaves órfãs no UserDefaults; B-3, B-6, B-7, S21-B3; build ad hoc/sem certificado: "Abrir Mesmo Assim" e novo "Permitir…" a cada versão (decisão do usuário, SPEC §13.2); S75R-B1/B2 (texto). Pendências do ⏸3 e M5.3 listadas no roteiro D.

### Proporcionalidade
Nenhuma alteração de código nesta etapa; só documentação (`docs/MANUAL_TESTS.md`, este relatório). Nada fora da SPEC introduzido; sem novas dependências, rede ou permissões (security-check ✓).

Problemas / desvios da SPEC: nenhum bloqueante (ver Ressalvas 1–5).
Precisa do usuário (⏸4): seguir a seção "M8 / ⏸4" de `docs/MANUAL_TESTS.md` (A medições com tap, B instalação pelo DMG e matriz de apps, C uso: volume/mudo/rota/teclas/tema/restaurar/forçar encerramento/reiniciar sessão/aviso "Permitir…" após atualizar, D pendentes de M4.1/M5.3/M6/macOS 15) e usar por um dia. Limpeza antes da tag (Snapshots, reports, PROGRESS) segue pendente na M8 conforme PLAN.
