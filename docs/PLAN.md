# Volume Manager — Plano de implementação (MVP)

> Base: `docs/SPEC.md` (requisitos) e `design/VolumeManager.figcraft` (visual).
> Ambiente verificado: macOS 27.2, Swift 6.4 (Command Line Tools), **sem Xcode**. Disponíveis: `swift build/test`, `swift format`, Swift Testing, `llvm-cov`. XCTest **não** está disponível → usar só Swift Testing.

## 1. Como o trabalho é dividido

Três papéis:

| Papel | Quem | Responsabilidade |
|---|---|---|
| **Orquestrador** | Claude (sessão principal) | Abre cada etapa, passa o contexto aos agentes, resolve impasses, faz commit/merge e reporta a você. |
| **Agente Dev** | subagente | Implementa a etapa seguindo a SPEC (§12 regras técnicas), escreve os testes unitários do que criou, roda `scripts/check.sh` e entrega um **relatório de entrega**. |
| **Agente QA** | subagente (independente do Dev) | Lê a SPEC e o código, escreve testes **adicionais** de borda/aceite, roda `check.sh` e a cobertura, revisa o código contra o §12 **incluindo o checklist de segurança §12.9.7 (bloqueante)** e emite **PASS** ou **FAIL** com lista de problemas. Não corrige código de produção. |
| **Agente de Segurança** | subagente (independente de Dev e QA) | Atua na etapa M7.5: auditoria completa do código e dos scripts contra o §12.9 (modelo de ameaças). Classifica achados em Crítico/Alto/Médio/Baixo; Crítico e Alto bloqueiam o release. Também revisa pontualmente o thread de áudio ao fim da M2. |

### Ciclo de cada etapa
```
Orquestrador cria branch etapa/Mx-nome
      │
      ▼
  Agente Dev ──► relatório de entrega (o que fez, como testar, limitações)
      │
      ▼
  Agente QA ──► PASS ──► Orquestrador: commit + merge na main + resumo pra você
      │
      └── FAIL (lista numerada) ──► Agente Dev corrige ──► Agente QA reavalia
                                    (máx. 3 voltas; depois o orquestrador intervém ou te consulta)
```

### Regras para os agentes
- Uma etapa por vez, em sequência (mesma pasta de trabalho; nada em paralelo).
- Dev **não** marca etapa como pronta sem `scripts/check.sh` verde.
- QA **não** altera `Sources/`; só `Tests/`, `docs/MANUAL_TESTS.md` e relatórios.
- Qualquer desvio da SPEC precisa ser justificado no relatório; mudanças de requisito só com sua aprovação.
- Commits pequenos e descritivos dentro do branch; merge na `main` só após PASS.

- **Segurança é bloqueante**: um FAIL de segurança do QA tem a mesma força de um teste quebrado.

### Pontos de verificação com você (⏸)
Algumas coisas os agentes não conseguem validar sozinhos (ouvir o som, aprovar permissões do macOS, olhar a UI real). Nesses pontos eu paro e te peço um teste rápido guiado:
- **⏸0** fim da M0.5 — prova de viabilidade: ouvir o volume de apps reais mudando via `vmctl` (antes de construir o resto).
- **⏸1** fim da M2 — núcleo de áudio completo (rota, vigia, restaurar).
- **⏸2** fim da M4 — olhar o popover real (claro/escuro).
- **⏸3** fim da M6 — fluxo completo (boas-vindas, login, ajustes).
- **⏸4** fim da M8 — aceite final e instalação pelo DMG.

## 2. Etapas

### M0.5 — Prova de viabilidade (spike) · ⏸0
Objetivo: provar **antes de tudo** que os riscos técnicos 1 e 2 (taps e agrupamento) estão sob controle. Código descartável/reaproveitável, num diretório `spike/` (pacote SwiftPM separado).

**Dev**
- `vmctl` mínimo: listar processos de áudio (PID, bundle ID, caminho, processo responsável, tocando?), agrupar por app (§4.1), criar tap + aggregate + IOProc com ganho para um app, mudo, trocar saída, destruir tudo.
- Basear-se no código de exemplo da Apple para process taps e em projetos abertos conhecidos (ex.: AudioCap) — sem copiar código de licença incompatível.
- Medir: latência percebida, estalos ao mudar volume, CPU por tap (`top`/`ps`), memória.

**QA**
- Matriz de apps (§4.1): para cada app disponível na máquina, registrar se agrupou certo e se o tap foi criado sem erro. Relatório `spike/REPORT.md` com números e problemas.
- Revisão rápida de segurança do IOProc (sem alocação/lock/log).

**⏸0 Você**: com música/vídeo tocando, rodar os comandos `vmctl` que eu passar e dizer se o volume mudou só no app certo, sem estalo ou atraso. O macOS pedirá permissão de áudio para o Terminal — aprovar uma vez.

**Decisão**: se OK → segue para M0 com a abordagem validada. Se não → ajustamos a abordagem (e, se preciso, a SPEC) antes de investir no resto.

---

### M0 — Fundação do projeto
**Dev**
- `Package.swift` com os módulos da SPEC §12.1: `VolumeCore`, `VolumeAudio`, `VolumeSystem`, `VolumeUI`, executável `VolumeManager`, executável de desenvolvimento `vmctl` (ver M2), e alvos de teste. `platforms: [.macOS(.v15)]`, Swift 6, concorrência estrita, zero dependências externas.
- `Resources/`: `Info.plist` (`LSUIElement`, `LSMinimumSystemVersion 15.0`, bundle ID `com.volumemanager.app`, `NSAudioCaptureUsageDescription`), entitlements, `Localizable.xcstrings`, `Version` (versão em um só lugar).
- `.swift-format`, `.gitignore`.
- `scripts/check.sh` (lint de formatação + build sem avisos + `swift test` + `security-check.sh`), `scripts/build-app.sh` (release build → monta `Volume Manager.app` sem `vmctl` → Hardened Runtime → assina com `VOLUME_SIGN_IDENTITY` ou ad-hoc).
- `scripts/security-check.sh` com todas as verificações da SPEC §12.9.7 desde o primeiro dia.
- Entitlements de release mínimos (nenhuma exceção proibida). Zero dependências (o security-check falha se houver alguma).
- App mínimo: ícone de alto-falante na barra de menus abrindo um popover vazio “Volume”.
- Reaproveitar o que foi validado no spike (M0.5).

**QA**
- `check.sh` verde do zero (clone limpo).
- `build-app.sh` gera `Volume Manager.app`; `codesign --verify --strict` ok; Hardened Runtime ativo; Info.plist contém as chaves; app abre sem ícone no Dock (verificar via `lsappinfo`/processo).
- Regras de dependência entre módulos: `VolumeCore` não importa CoreAudio/AppKit/SwiftUI; `VolumeUI` não importa `VolumeAudio`/`VolumeSystem` (teste/script que inspeciona os `import`).
- **Segurança**: `security-check.sh` passa e **também falha quando deveria** (QA injeta temporariamente um entitlement proibido e um `URLSession` num branch de teste e confirma que o script pega — depois descarta).

**Pronto quando**: app vazio roda na barra de menus; pipeline local e CI verdes.

---

### M1 — Domínio (`VolumeCore`)
**Dev**
- Modelos: `AudioProcessInfo`, `AudioApp` (grupo de processos), `OutputDevice` (id, **UID**, nome, tipo, tem volume?), `AppAudioState` (volume, mudo, rota), `DesiredAppAudio`.
- Protocolos de serviço: `AudioSystem`, `AppAudioController`, `PreferencesStore`, `LoginItemService`, `PermissionService`, `AppInfoProvider`, `Clock` injetável.
- `ProcessGrouping`: agrupa auxiliares sob o app dono na ordem da SPEC §4.1 (caminho do executável → processo responsável → prefixo de bundle ID), usando dados fornecidos pelo serviço. Nomes/caminhos tratados como não confiáveis (limite de tamanho, texto puro — §12.9.4).
- `SafetyPolicy`: modo seguro (2 encerramentos anormais em < 1 min) e “restaurar áudio original” no nível do domínio (§4.6).
- `VolumeCurve`: slider 0–1 → ganho perceptual; 0→0, 1→1, monotônica.
- `RoutingPolicy`: rota efetiva (dispositivo salvo se presente, senão padrão), restauração ao reconectar.
- `MixerStore` (`@Observable`, `@MainActor`): lista ordenada (tocando primeiro, depois nome), contador “N reproduzindo”, intenções `setVolume/toggleMute/route/setMasterVolume/setDefaultOutput`, atraso de 5 s para remover apps que pararam, regra “sem tap em 100%/sem mudo/saída padrão”, cálculo do **estado desejado** enviado ao `AppAudioController`.
- `SettingsModel`: todas as preferências da SPEC §3.3 com padrões corretos; persistência com debounce de 500 ms; lembrar/esquecer volume por bundle ID; **validação de tudo que é lido** (valor inválido → padrão seguro).
- Testes unitários do que foi criado.

**QA**
- Dublês: `FakeAudioSystem`, `SpyAppAudioController`, `InMemoryPreferencesStore`, `FakeClock`, etc. (em `Tests/VolumeCoreTests/Support`).
- Casos obrigatórios da SPEC §12.8 + eventos fora de ordem (processo some antes de começar a tocar, dispositivo removido durante rota, etc.).
- **Segurança**: preferências corrompidas (volume -5, 999, NaN, string gigante, tipos errados) nunca deixam app mudo nem quebram; nomes de processo enormes/com caracteres de controle são truncados e exibidos como texto puro; PID reutilizado não é confundido com o app antigo.
- Cobertura `VolumeCore` ≥ 85% (`swift test --enable-code-coverage` + `llvm-cov report`).

**Pronto quando**: domínio completo e testado sem nenhum código de Core Audio.

---

### M2 — Áudio real (`VolumeAudio`) + `vmctl` · ⏸1
**Dev**
- Wrapper Core Audio: leitura/escrita de propriedades com `AudioError` tipado; listeners convertidos em `AsyncStream`; tudo isolado em `actor`.
- `CoreAudioSystem`: dispositivos de saída (nome, UID, transporte, suporte a volume), saída padrão (ler/definir), volume/mudo geral, lista de processos de áudio + `IsRunningOutput` + PID/bundle, eventos de mudança. Sem polling.
- `CoreAudioAppController`: por app, `CATapDescription` (PIDs do grupo, `mutedWhenTapped`) + aggregate device privado (tap + saída alvo) + IOProc copiando com ganho; ganho/mudo em `Atomic` com rampa ~20 ms; reconciliação **idempotente** do estado desejado; destruição completa (RAII) e no encerramento.
- Recuperação: troca de dispositivo padrão, dispositivo removido, reinício do `coreaudiod`.
- **Falhar abrindo** (§4.6): vigia por tap (contador atômico do IOProc verificado só enquanto há taps), destruição automática de tap parado, “restaurar tudo”, sem novas tentativas em laço.
- Revalidar PID + bundle ID + caminho antes de criar cada tap; checar capacidade de buffers antes de copiar.
- `vmctl` (ferramenta de terminal para desenvolvimento/testes): `vmctl devices`, `vmctl processes`, `vmctl master [valor]`, `vmctl set <bundleID|pid> --volume 0.3 [--mute] [--device UID]`, `vmctl restore`, `vmctl stress-taps 100`.

**QA**
- `VolumeAudioTests` (integração, marcados para pular se não houver dispositivo de áudio): listar dispositivos; criar/destruir tap+aggregate 100× sem sobrar dispositivos (`vmctl devices` antes/depois) nem crescimento de memória.
- Revisão do IOProc contra §12.2 (nada de alocação/lock/log no thread de áudio).
- Teste com `afplay` tocando um arquivo + `vmctl set` (verifica criação de tap sem erro; volume audível fica para o ⏸1).
- Matar o processo com `kill -9` com taps ativos → nenhum aggregate device sobra e o áudio original volta.

**Agente de Segurança (revisão pontual)**: thread de áudio (limites de buffer, alocação, condições de corrida entre reconciliação e IOProc), ciclo de vida de taps e dados de outros processos. Achados Crítico/Alto voltam para o Dev antes do PASS.

**⏸1 Você**: com uma música tocando, rodar os comandos `vmctl` que eu te passo e confirmar que só aquele app abaixa/silencia/troca de saída, e que `vmctl restore` e Forçar Encerramento devolvem o som normal.

**Pronto quando**: volume, mudo e rota por app funcionam de verdade pelo `vmctl`, com falha segura.

---

### M3 — Serviços do sistema (`VolumeSystem`)
**Dev**
- `UserDefaultsPreferencesStore`, `SMAppLoginItemService` (status real, `.requiresApproval`, abrir Itens de Início), `AudioPermissionService` (estado, pedido via tap de teste, abrir Privacidade), `WorkspaceAppInfoProvider` (nome, ícone em cache por bundle ID, app em primeiro plano, responsible PID/app pai para o agrupamento).

**QA**
- Testes com `UserDefaults(suiteName:)` isolado; cache de ícones; mapeamento de status do login item; resolução de app pai com processos reais conhecidos (Safari/WebKit se disponíveis, senão pular).

**Pronto quando**: todos os protocolos da M1 têm implementação real.

---

### M4 — Popover do mixer (`VolumeUI`) · ⏸2
**Dev**
- `Styling`: `GlassBackground`, `CardBackground`, `RowHighlight` com `#available(macOS 26)` → Liquid Glass, senão materiais (único lugar com `#available`).
- Ícone da barra dinâmico (alto-falante 0/1/2/3 ondas ou “Controles”).
- Popover conforme design: cabeçalho (só título; o `•••` foi removido em 2026-11-09), card Saída principal (lista de saídas, slider geral, mudo), seção Aplicativos, `AppRowView` (ícone, nome, %, slider, mudo, rótulo de rota), linha expandida “SAÍDA DESTE APP” (uma por vez), rodapé (“Opções” — menu com Ajustes de Som…, Ajustes do Volume… ⌘,, Restaurar áudio original, Sobre o Volume Manager — e Sair ⌘Q; decisão do usuário em 2026-11-10), estados “sem permissão” e “nenhum app”.
- Teclado (setas/rolagem com incremento, Espaço, Esc, Tab) e acessibilidade (VoiceOver, Reduzir transparência/movimento).
- Composition root conecta tudo: app funcional pela barra de menus.

**QA**
- Testes de view-model/estado da UI (formatação “72%”/“Silenciado”, ordenação, uma linha expandida).
- **Snapshots** com `ImageRenderer` das views em claro e escuro com dados de exemplo (`Tests/Snapshots/*.png`), comparados visualmente com o design (o agente QA lê as imagens e lista divergências relevantes).
- Medir abertura do popover e CPU ocioso (orçamentos §12.4).

**⏸2 Você**: abrir o app real, mexer nos sliders com música tocando, alternar claro/escuro.

**Pronto quando**: o mixer é usável no dia a dia.

---

### M5 — Ajustes e Boas-vindas
**Dev**
- Janela de Ajustes (uma instância, ⌘,): Geral (todas as opções), Aplicativos (lembrados, esquecer), Dispositivos (lista, definir padrão), Sobre (versão/build, link de Releases). Barra lateral de vidro no 26+, `NavigationSplitView` padrão no 15.
- Boas-vindas na primeira execução: destaques, toggle “Abrir ao iniciar sessão” ligado, “Permitir…” → ✓, “Começar” registra login item e abre o popover.
- Reabrir o app já em execução → abre Ajustes. O ícone da barra de menus é sempre visível (sem opção para escondê-lo).
- Ícones (decisão do usuário em 2026-11-09): ícone da barra de menus **próprio e fixo**, diferente do alto-falante do macOS (remove o pop-up “Ícone da barra de menus” e o estilo dinâmico); ícone do app. Ambos escolhidos pelo usuário na página “Ícones” do FigCraft.

**QA**
- Testes de fluxo de primeira execução (flag persistida, registro do login item via fake).
- Snapshots claro/escuro de Ajustes e Boas-vindas vs. design.

**Pronto quando**: todas as telas do design existem e funcionam.

---

### M6 — Ciclo de vida e robustez · ⏸3
**Dev**
- Lembrar volume ponta a ponta (aplica quando o app volta a tocar).
- Dormir/acordar, troca de usuário, reinício do `coreaudiod`, desconectar/reconectar fone: reconciliação automática.
- Encerramento limpo (todos os taps destruídos); garantia de nenhum “mudo preso”.
- Modo seguro ponta a ponta (detecção de encerramentos anormais na inicialização, aviso no popover).

**QA**
- Testes de domínio para cada cenário com eventos simulados no `FakeAudioSystem`.
- Forçar Encerramento / `kill -9` do app real com apps modificados → todos voltam ao som original; reabrir após 2 travamentos simulados → modo seguro ativo.
- Escreve `docs/MANUAL_TESTS.md`: roteiro passo a passo de todos os critérios da SPEC §14 que dependem de hardware.

**⏸3 Você**: seguir o roteiro manual (boas-vindas → reiniciar sessão → app abre sozinho → AirPods).

---

### M7 — Distribuição
**Dev**
- `build-app.sh` com certificado próprio (`VOLUME_SIGN_IDENTITY`) + instruções para criar o certificado no Acesso às Chaves (`docs/SIGNING.md`).
- `scripts/release.sh <versão>`: recusa rodar com mudanças não commitadas ou sem tag; build release, assina **localmente**, gera `Volume-<versão>.dmg` (via `hdiutil`, com atalho para Aplicativos e **fundo com instrução visual**), `.zip` e `SHA256SUMS`.
- Ícone do app (a partir do design).
- `README.md`: o que é, prints, requisitos, instalação com “Abrir Mesmo Assim”/`xattr`, **como conferir o SHA-256**, “baixe só daqui”, como atualizar, como compilar, privacidade (“sem rede, nada é gravado”).
- `SECURITY.md`: como reportar vulnerabilidades.
- Roteiro de release: confirmar que `responsibility_get_pid_responsible_for_pid` existe no macOS mínimo (15) e no atual (ex.: `nm -gU /usr/lib/system/libsystem_kernel.dylib` ou `dyld_info -exports` no shared cache; risco M-1 aceito pelo usuário, SPEC §4.1).

**QA**
- DMG monta, contém app assinado e atalho; app abre a partir do DMG em pasta temporária; versão exibida no Sobre bate com a do release; `SHA256SUMS` confere.
- Verifica que permissões são mantidas entre duas builds assinadas com o mesmo certificado (designated requirement estável via `codesign -d -r-`).
- `security-check.sh` rodado contra o `.app` **de dentro do DMG** (o artefato que o usuário recebe).

---

### M7.5 — Auditoria de segurança independente
**Agente de Segurança** (não participou do código)
- Revisão completa de `Sources/`, `scripts/`, `Package.swift`, entitlements, Info.plist e CI contra a SPEC §12.9 e o modelo de ameaças.
- Foco: thread de áudio, dados de outros processos, ciclo de vida de taps (vazamento/condições de corrida), validação de preferências, assinatura/release, cadeia de suprimentos.
- Testes adversariais: preferências maliciosas via `defaults write`, processo com nome/bundle enorme ou com caracteres especiais, PID reutilizado, desconexão de dispositivo no meio da reconciliação, `kill -9` em momentos variados.
- Relatório `docs/SECURITY_AUDIT.md` com achados (Crítico/Alto/Médio/Baixo), evidência e recomendação.

**Dev** corrige; **Agente de Segurança** reverifica. **Crítico e Alto bloqueiam o release**; Médio/Baixo viram decisão sua (corrigir agora ou registrar).

---

### M8 — Aceite final · ⏸4
**QA**
- Percorre os 18 critérios da SPEC §14 (automáticos + resultado do roteiro manual), incluindo segurança (§12.9.7 e auditoria sem Crítico/Alto), mede os orçamentos de performance e registra números em `docs/MANUAL_TESTS.md`.
- Relatório final: o que passou, o que ficou com ressalva, riscos conhecidos (§10).

**⏸4 Você**: instalar pelo DMG como um usuário qualquer e usar por um dia.

**Limpeza antes da tag** (decisão do usuário em 2026-11-11): remover do repositório o que só serve ao desenvolvimento até a publicação — `Tests/Snapshots/` (PNGs de conferência visual; os testes de snapshot continuam), `docs/reports/` e `docs/PROGRESS.md` — e ajustar as referências a eles (testes, PLAN, `CLAUDE.md`, agentes). `CLAUDE.md`, `.claude/` e `design/` ficam. Depois da publicação, o desenvolvimento segue a partir do projeto pronto.

**Resultado**: tag `v1.0.0` e primeira Release no GitHub (upload manual).

## 3. Riscos e como o plano lida com eles
| Risco | Mitigação no plano |
|---|---|
| Core Audio taps se comportarem diferente do esperado | Spike M0.5 antes de tudo + ⏸0; “falhar abrindo” garante que falha = som original. |
| Agrupar processos auxiliares (Safari/Chrome/Electron) | Caminho do executável + processo responsável; matriz de apps no spike, na M3 e no aceite. |
| Permissão de áudio para agentes no terminal | Primeira aprovação feita por você no ⏸0. |
| Vulnerabilidades de segurança | `security-check.sh` bloqueante em toda etapa, revisão de segurança na M2, auditoria independente na M7.5. |
| Sem Xcode: sem Instruments/UI tests | Medições com `ps`/`top`/`footprint`; snapshots via `ImageRenderer`; verificação visual no ⏸2. **Recomendado instalar o Xcode (gratuito) antes da M4.** |
| Teste em macOS 15 | Fica no roteiro manual (VM gratuita com UTM/VirtualBuddy ou outro Mac); a camada `Styling` isola as diferenças. |

## 4. Estimativa de tamanho
| Etapa | Tamanho relativo |
|---|---|
| M0.5 Spike | P |
| M0 Fundação | P |
| M1 Domínio | M |
| M2 Áudio real | **G** (maior risco técnico) |
| M3 Serviços | P |
| M4 Popover | M |
| M5 Ajustes/Boas-vindas | M |
| M6 Robustez | M |
| M7 Distribuição | P |
| M7.5 Auditoria de segurança | M |
| M8 Aceite | P |
