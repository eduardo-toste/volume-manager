## Etapa M6 — QA
Resultado: PASS
O que foi feito:
- Rodei `scripts/check.sh --audio` do zero (verde; 178 testes, suíte de hardware incluída) e `scripts/security-check.sh` (OK). Nenhum afplay sobrou (`pgrep -x afplay` vazio).
- Prioridade 1 (mudo preso) provada no hardware, em `Tests/VolumeAudioTests/HardwareTests.swift`:
  - `createAndDestroyTapAndAggregate100TimesLeavesNothing` agora também confere a lista de taps do sistema (`kAudioHardwarePropertyTapList`) antes/depois, com espera (`tapCountSettles`): 100 ciclos, zero taps sobrando.
  - Novo `teardownRecognisesItsOwnTapAndAggregate`: cria tap + aggregate reais (no `afplay -v 0` do teste, `.unmuted`, saída embutida), lê `kAudioTapPropertyUID` e `kAudioDevicePropertyDeviceUID` e confirma que são iguais ao UUID/UID de criação (`isOurs`), `teardown()` devolve `true` (e de novo `true` na segunda chamada), devices e taps voltam à contagem inicial.
  - Conclusão: `kAudioTapPropertyUID` devolve o mesmo texto de `CATapDescription.uuid.uuidString`; o tap é destruído.
- Testes alterados (`abandonado, 0 stops` -> `1 stop`, `overlappingChecksRunOneProbe`, remoção de `pipelineAbandonLeavesTheRealObjectAlive`, `withKnownIssue` do S21-B1 virou `#expect`): legítimos, não enfraquecem. O comportamento mudou de propósito (stop com checagem de identidade em vez de abandonar) e as asserções novas são mais fortes (S21-B1 agora é prova real). `pipelineAbandon...` testava uma função removida; `isOurs` e teardown vazio o substituem. Hardware cobre o caso real.
- `docs/MANUAL_TESTS.md`: seção "M6 (⏸3)" com 9 passos (dormir/acordar, Restaurar+dormir, troca de usuário, AirPods, Forçar Encerramento/kill -9, reabrir, 2 travamentos -> modo seguro, SIGTERM, reiniciar sessão).
Revisão:
- `systemResumed`: destrói todos os taps e reaplica `lastDesired` só se a geração ainda vale; após `restoreAll` (pânico) não recria (teste); não toca em `failed` (não reintenta; teste); não deixa tap órfão (stop de cada um + killList refeita; teste conta 4 criados, 2 vivos).
- SIGTERM/SIGINT: `signal(n, SIG_IGN)` + `DispatchSource.makeSignalSource(queue: .main)`, guardado em `terminationSignals` (fonte não é liberada); chama o mesmo `quit` (restoreAll, depois flush + markCleanExit + terminate, com limite de 2 s). Correto. Não testável sem rodar o app real (coberto no passo 8 do roteiro manual).
- Segurança §12.9: nenhuma rede, dependência, permissão ou entitlement novos; identidade checada antes de destruir; `teardown(keeping:)` retém o estado (poucos bytes) se algo não foi reconhecido, evitando use-after-free do IOProc.
- Desvio 3 (sessão limpa = só `cleanExit`): concordo. É o lado seguro: o custo é que, após crash/Forçar Encerramento, a primeira reaplicação dos volumes lembrados espera uma ação do usuário (nunca o pedido do sistema sozinho). Incluir `stable` não provaria que a permissão ainda vale (o caso de re-assinatura tem sessão estável). Aceito.
- Proporcionalidade: ok. Removeu `abandon()`/`forget()` (código a menos); `onResume` e `waiters` têm uso real; `teardown(keeping:)` substitui 4 repetições. Sem abstração especulativa.
Observações (não bloqueantes):
1. Acordar e `sessionDidBecomeActive` podem disparar juntos: reconstrução dupla, inofensiva.
2. Se a reconstrução ao acordar falhar (dispositivo ainda não pronto), o app fica com o som original e marcado como falho até ação do usuário. Seguro (regra 9), possível incômodo; verificar no passo 1 do roteiro.
3. Uma execução inicial de `check.sh --audio` ficou pendurada junto com outro `swift-test` rodando em paralelo (outro agente, filtro SecurityM6); sem relação com o código; a nova execução isolada passou.
Como verificar: `scripts/check.sh --audio`; `scripts/security-check.sh`; `VOLUME_AUDIO_TESTS=1 swift test --filter HardwareTests`
Verificações: check.sh ✓ (--audio) · security-check ✓ · cobertura: não medida separadamente (check.sh verde)
Problemas / desvios da SPEC: nenhum bloqueante.
Precisa do usuário: seguir "M6 (⏸3)" em `docs/MANUAL_TESTS.md` (sono, troca de usuário, AirPods, kill -9, SIGTERM, reiniciar sessão).
