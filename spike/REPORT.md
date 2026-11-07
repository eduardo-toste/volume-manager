# M0.5 — Relatório do spike (Dev)

Ambiente: macOS 27.2, Swift 6.4 (CLT, sem Xcode), saída padrão = AirPods Pro (24 kHz, perfil de chamada). Build debug e release sem avisos de código; 8 testes Swift Testing passam.

## O que funcionou
- **Listagem** via `kAudioHardwarePropertyProcessObjectList`: 35 processos de áudio nesta máquina, com PID, bundle ID, caminho (`proc_pidpath`), `IsRunningOutput` e dono resolvido.
- **Tap + aggregate privado + IOProc com ganho** (`CATapDescription(stereoMixdownOfProcesses:)`, `.mutedWhenTapped`, `isPrivate`): funcionou **no primeiro teste, sem prompt de permissão** (o terminal já tinha a permissão). `afplay` (pid alvo) com volume 0.5: ~24000 frames/s processados, CPU do vmctl ~2,6 % em build **debug** (release deve ser bem menor; medir no ⏸0).
- **Mudo** (`--mute`) e **encerramento por SIGINT**: IOProc/aggregate/tap destruídos em ordem; nenhum aggregate sobrando.
- **stress-taps 20** (metade das iterações com IO iniciado): 0 falhas, dispositivos antes=7 depois=7, **0 vazamentos**.
- Watchdog implementado (sem frames por 2 s com o app ainda tocando => destrói o tap); **não foi possível provocar a falha** aqui, então o caminho está só implementado, não exercitado.
- Não testado por mim (precisa de ouvido humano): estalos, latência percebida, troca de saída (`--device`), apps Safari/Chrome/Zoom/Música (não estavam abertos).

## Política de testes silenciosos e qualidade de áudio (regra do usuário)
- Testes iniciais usaram `afplay` audível por poucos segundos (antes da regra). Depois da regra: nenhum áudio audível; testes usam `afplay -v 0` (processo segue com `IsRunningOutput = true`). O `vmctl` imprime agora `tap format` e `output format` no `set`.
- **IOProc**: só `saída = entrada * ganho` em Float32, mesmo nº de canais e mesma disposição; sem conversão de formato nem reamostragem no nosso código. Com ganho 1.0 (alvo e atual) a multiplicação por 1.0f é exata: saída bit-a-bit igual à entrada. Se os canais/buffers não batem, o IOProc zera (nunca converte) — a M2 deve recusar o tap nesse caso.
- **Formatos medidos nesta máquina**: tap = 48000 Hz, 2 ch, 32-bit float, interleaved (LPCM). Saída (AirPods Pro, perfil de chamada) = 24000 Hz, 2 ch, 32-bit float, interleaved.
- **Ponto de conversão detectado**: quando a taxa do tap difere da do dispositivo de saída (48 kHz -> 24 kHz aqui), o aggregate device roda na taxa da saída e o Core Audio reamostra o tap (compensação de drift/SRC do HAL), fora do nosso controle. Com saídas a 48 kHz (alto-falantes do Mac, LG) não era esperado haver conversão, mas **não foi medido** (não mudei o dispositivo padrão). Mitigação a avaliar na M2: criar o tap com a taxa/formato do dispositivo-alvo quando possível, e validar por teste a bit-exatidão com saída de mesma taxa.
- Ponto em aberto: sem Xcode não há teste automatizado de bit-exatidão ponta a ponta; a M2 deve ter teste unitário do kernel de cópia com ganho 1.0 (entrada == saída).

## Saída real (resumida)
`vmctl devices`:
```
ID  DEFAULT SW-VOL RATE   UID                                   NAME
90  no      no     48000  1E6DF976-0000-0000-0221-010380502278  LG ULTRAWIDE
105 yes     yes    24000  AC-07-75-D9-E8-39:output              Eduardo’s AirPods Pro
73  no      yes    48000  BuiltInSpeakerDevice                  MacBook Air Speakers
```
`vmctl master` => 0.750 (somente leitura; nada foi alterado).

`vmctl processes` (visão agrupada, sem daemons de sistema):
```
[idle]    Control Center <com.apple.controlcenter>  pids: 1101,32584
[idle]    Siri <com.apple.Siri>  pids: 1517
[idle]    Brave Browser <com.brave.Browser>  pids: 22964,22966,22936
[idle]    WhatsApp <net.whatsapp.WhatsApp>  pids: 82829,60122
[idle]    Spotify <com.spotify.client>  pids: 60891
[PLAYING] Discord <com.hnc.Discord>  pids: 89661,89662,89647,89663
[idle]    Octo <dev.marujo.octo>  pids: 89774   (WebKit.GPU resolvido por processo responsável)
[idle]    FluidVoice <com.FluidApp.app>  pids: 90251
```

## Análise do agrupamento (SPEC 4.1)
| Caso | Resolvido por | Resultado |
|---|---|---|
| Brave (2 helpers + principal) | caminho (`…/Helpers/Brave Browser Helper.app` -> `.app` mais externo) | correto, 1 linha |
| Discord (Helper, Helper (Renderer), principal) — o que estava tocando era o Renderer | caminho | correto; `PLAYING` vem do helper, e o tap cobre os 4 PIDs |
| WhatsApp (+ `.appex` em PlugIns) | caminho | correto |
| Control Center / Siri (XPC services) | caminho | correto |
| `com.apple.WebKit.GPU` (pid 89774, caminho em `/System/Volumes/Preboot/Cryptexes/…`) | **processo responsável** (`resp=89761` => Octo.app) | correto — era o caso que só o passo 2 resolve |
| `com.apple.WebKit.GPU` (pid 68459), responsável é `WebThumbnailExtension.appex` (não `.app`) | prefixo de bundle (`com.apple.WebKit`) | **errado/sem dono**: cai no fallback; é processo de sistema |
| Daemons (`audiomxd`, `mediaremoted`, `coreaudiod`…) | prefixo | agrupados por prefixo, mas o spike os **exclui** da visão agrupada por caminho em `/System/` ou `/usr/` |
| `afplay` (CLI sem bundle ID) | nenhum | sem dono; por isso o spike aceita `pid:<N>` como alvo (só para teste) |

Safari, Chrome, Zoom, Música e YouTube **não estavam abertos**: validar no ⏸0 (a matriz obrigatória fica pendente para eles). Em especial: confirmar que o WebKit GPU do Safari resolve para `Safari.app` via responsável.

### API privada
O passo 2 usa `responsibility_get_pid_responsible_for_pid` (símbolo de libSystem, **sem** API pública equivalente). Foi declarado com `@_silgen_name` e linkado em tempo de build (nada de `dlopen`/`dlsym`). Funcionou nesta versão (macOS 27.2). **Riscos**: símbolo não documentado, pode mudar/sumir em qualquer versão do macOS e falha de link/crash se removido; é motivo de atenção na revisão de segurança/notarização (não é rejeição automática, mas é API não pública). Mitigação sugerida: a M2 deve (a) tratar o passo 2 como opcional — se o símbolo faltar não há como detectar sem `dlsym`, então decidir por **aceitar o risco de link** ou **remover o passo 2** e resolver WebKit só por heurística, e (b) manter o resultado “sem dono” como fail-open (processo ignorado, som original intacto). **Decisão para o orquestrador/usuário.**

## Desvios e descobertas importantes
1. **`Synchronization.Atomic` exige macOS 15**, mas a SPEC fixa macOS 14.2 (e §12.2 manda usar `Atomic`). No spike usei um alvo C mínimo (`Sources/CAtomics`, `__atomic_*` relaxed em inteiros alinhados). Sugestão para a SPEC: alvo C interno minúsculo (sem dependência externa) **ou** subir o mínimo para macOS 15. `scripts/security-check.sh` precisa permitir esse alvo.
2. **Swift Testing sob CLT** exige `swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`. O `scripts/check.sh` da M0 deve incluir isso.
3. Avisos `ld: warning: search path '/Library/Developer/CommandLineTools/Developer/…' not found` vêm do toolchain; `check.sh` não deve tratá-los como avisos do projeto (filtrar).
4. A saída padrão atual (AirPods em 24 kHz) mostra que o sample rate varia por dispositivo: a rampa de 20 ms é calculada pelo rate do dispositivo de saída.
5. IOProc: assume Float32 e mesmo nº de canais entre entrada (stereo mixdown) e saída; se diferirem, escreve silêncio nesse buffer (**cenário a tratar na M2**: saídas multicanal/mono => converter ou falhar abrindo destruindo o tap). Como silêncio equivale a “app mudo”, a M2 deve detectar o formato na criação (`kAudioTapPropertyFormat` / streams da saída) e recusar o tap em vez de mutar.
6. Um tap por grupo exige reconstruir se um novo processo auxiliar surgir (PIDs fixos na criação): a M2 precisa ouvir a lista de processos e recriar o tap do grupo.
7. O PID é revalidado (PID + caminho) logo antes de criar o tap; `afplay` em laço muda de PID a cada som, por isso os testes usaram um `afplay -t` longo.

## Recomendação para a M2
Abordagem validada: **seguir**. Taps por processo-grupo, aggregate privado, IOProc simples e destruição ordenada funcionam e não vazam. Antes/em paralelo: decidir o item de API privada e o item de `Atomic`/macOS 15; no ⏸0 validar por ouvido (estalo, atraso, app certo) e a matriz Safari/Chrome/Zoom/Música/YouTube; medir CPU em release com `top -pid`/`ps`.
