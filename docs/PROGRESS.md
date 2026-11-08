# Volume Manager — Progresso

> Atualizado em 2026-11-07, ao pausar após a M2. Leia junto com `CLAUDE.md`, `docs/SPEC.md` e `docs/PLAN.md`.

## Onde estamos

| Etapa | Status | Commit |
|---|---|---|
| Design (FigCraft) | ✅ fechado | `0729242` |
| SPEC + PLAN | ✅ aprovados | `0729242`… |
| Ambiente de agentes (`CLAUDE.md`, `.claude/`) | ✅ | `efc84c5`, `55a516b` |
| M0.5 Prova de viabilidade (spike) | ✅ + ⏸0 aprovado de ouvido | `7e21553`, `7962f29` |
| M0 Fundação | ✅ | `0a904bc` |
| M1 Domínio (`VolumeCore`) | ✅ | `450ad83` |
| M3 Serviços (`VolumeSystem`) | ✅ | `3357524` |
| M2 Áudio real (`VolumeAudio`, `vmctl`) | ✅ QA + Segurança (LIBERA) | `5bcedbf` |
| **⏸1 Teste de ouvido da M2** | ⏳ pendente (usuário) | — |
| M4 Popover · M5 Ajustes/Boas-vindas · M6 Robustez · M7 Distribuição · M7.5 Auditoria · M8 Aceite | ⏳ | — |

Tudo está na `main` (a M2 foi integrada após QA + Segurança LIBERA; o ⏸1 de ouvido ainda vai validar a reescrita). Nada foi enviado ao GitHub (sem `push`). A próxima etapa começa num branch novo a partir da `main`.

## Próxima sessão — ordem sugerida

1. **⏸1 com o usuário** (teste de ouvido da M2, com música real):
   ```
   cd /Users/eduardotoste/Documents/projects/volume-manager
   scripts/make-vmctl-app.sh
   OUT=$PWD/build/vmctl-dev.out
   run() { rm -f "$OUT"; open -W --stdout "$OUT" --stderr "$OUT" build/vmctl-dev.app --args "$@"; cat "$OUT"; }
   run processes
   run probe-permission            # o macOS pede a permissão para "vmctl-dev" — permitir
   run set com.spotify.client --volume 0.7 --duration 20
   run set com.spotify.client --mute --duration 10
   run set com.spotify.client --volume 0.7 --device BuiltInSpeakerDevice --duration 15
   ```
   Observar: só o app alvo muda, sem estalo, sem atraso, qualidade igual; **se os AirPods mudam para modo chamada/ligam o microfone** ao serem usados no aggregate; calibração da curva (70% soa natural?).
2. **M2.1 — correções da revisão de segurança** (`docs/reports/m2-security.md`), Dev → QA:
   - **M-1 (Médio)**: a checagem de nulo do `weak_import` em `WorkspaceAppInfoProvider.swift:74-77` não funciona (cai com SIGSEGV se o símbolo sumir). **Decisão pendente do usuário** — recomendação do orquestrador: permitir em `CSystemShims` uma função `static inline` de uma linha que testa o símbolo (`&responsibility_get_pid_responsible_for_pid != NULL`) e ajustar SPEC §12.9.2 / security-check para aceitar exatamente isso.
   - **M-2 (Médio)**: após reinício do coreaudiod, o teardown pode destruir objetos com IDs reaproveitados — esquecer os recursos antigos sem destruir (ou conferir o UID antes).
   - Baixos a corrigir: B-1 (sanitizar saída do `vmctl processes`; `AppPath` aceitar C1/bidi), B-2 (UID de dispositivo sanitizado/ambíguo), B-4 (converter PID em objeto uma vez só), B-5 (probe sem tap global), B-8 (`verify()` não depender do texto do erro). B-3, B-6, B-7: registrar/aceitar.
   - **Remover os atalhos do código** (decisão do usuário: sem atalhos globais): apagar o protocolo `HotkeyService` (`Sources/VolumeCore/HotkeyService.swift`) e o `FakeHotkeyService` dos testes; no `scripts/security-check.sh`, exigir **zero** dependências (remover a exceção da `KeyboardShortcuts`) e ajustar os testes de política correspondentes.
3. **M4 — Popover** (Xcode já instalado e selecionado; macros do SwiftUI disponíveis). Lembretes da M2: confirmar a permissão com `verify()` antes de mostrar "sem permissão" (o vigia de silêncio também dispara com silêncio digital legítimo); ligar `CoreAudioAppController.failures()` ao domínio e chamar `retryAll()` quando a permissão for concedida; chamar `markCleanExit` via `SessionLifecycleObserver`.

## Decisões tomadas (resumo)
- macOS mínimo **15**; atômicos com `Synchronization.Atomic`.
- API privada `responsibility_get_pid_responsible_for_pid` só via `weak_import` em `CSystemShims` (ver M-1).
- Bundle ID `com.volumemanager.app`, nome exibido "Volume"; distribuição pelo GitHub Releases, sem conta Apple, certificado próprio; sem atualização automática no MVP.
- Pânico ("Restaurar áudio original") = lousa limpa total (zera estados + esquece lembrados).
- ZWJ/ZWNJ preservados só entre caracteres visíveis.
- Vigia de silêncio fica como na SPEC; a UI confirma com `verify()`.
- `_withUnsafeGuaranteedRef` mantido; inspeção do desmontado entra no roteiro de release (M7).
- Testes nunca produzem som, nunca tocam apps do usuário, nunca usam preferências reais; áudio real só via bundle `vmctl-dev.app`/`vmctl-test.app`.
- **Sem atalhos globais** (⌥⌘V/⌥⌘M removidos) e **zero dependências externas** — decisão do usuário em 2026-11-07. O design no FigCraft ainda mostra a seção de atalhos e o item “Atalhos” na barra lateral dos Ajustes: **a SPEC prevalece** (não implementar).
- **Regra 16**: nada é instalado ou baixado por Claude/agentes — o usuário instala tudo.

## Pendências do usuário
- ⏸1 (acima).
- Decidir M-1 (acima).
- Ao final do projeto: remover em Ajustes › Privacidade › Gravação de Tela e Áudio do Sistema as permissões de `vmctl-test` e `vmctl-dev`.

## Modelos dos agentes
Dev e QA: Sonnet · Segurança: Opus · tarefas mecânicas/documentação: Haiku. Escalar para Opus só se o Sonnet travar.
