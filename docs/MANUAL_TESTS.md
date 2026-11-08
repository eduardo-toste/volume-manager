# Roteiros de teste manual

Roteiros curtos para as pausas em que só o usuário pode validar (app real, áudio de verdade, aparência).

## M4 — ⏸2: popover do mixer

Antes de começar: `scripts/build-app.sh` (só constrói). Abra `build/Volume.app` com duplo clique. Na primeira vez que você mexer num app, o macOS vai pedir a permissão "Gravação de Áudio do Sistema" — pode permitir. Toque música em algum app para os testes.

### 1. Abrir e olhar
1. Clique no ícone de alto-falante na barra de menus. O painel deve abrir de imediato (sem demora perceptível).
2. Confira de cima para baixo: título "Volume" e botão `•••`; cartão "Saída" com o nome do dispositivo atual; seção "Aplicativos" com "N reproduzindo"; rodapé com "Ajustes de Som…", "Ajustes do Volume…" e "Sair".
3. Atenção: o cartão "Saída" deve mostrar o **nome do dispositivo** (ex.: "Alto-falantes do MacBook"). Se mostrar só "Saída" e o ícone, anote — é um defeito conhecido do QA.
4. Não deve existir "Mostrar na barra de menus" nem atalhos globais em lugar nenhum.
5. Feche com Esc. Abra de novo.

### 2. Mexer nos volumes (com música tocando)
1. Arraste o controle de um app: só o som **desse** app muda; os outros ficam iguais. O valor ("72%") acompanha.
2. Clique no botão de alto-falante redondo da linha: o app fica mudo, o valor vira "Silenciado", o nome e o controle ficam esmaecidos, o botão fica vermelho. Clique de novo: volta ao volume anterior.
3. Deixe um app em 100%, sem mudo, na saída padrão: o som deve ser o original (sem tap).
4. Arraste o controle geral do cartão "Saída": muda o volume do Mac todo. Clique no alto-falante pequeno à esquerda: silencia/dessilencia o Mac. O ícone da barra muda conforme o volume (0, 1, 2, 3 ondas).
5. Ouça com atenção: não deve haver estalo ao arrastar nem ao silenciar.

### 2b. Permissão, primeira ação e reabrir (novo)
1. Antes de mexer em qualquer app, abrir o painel NÃO deve mostrar o pedido de permissão do macOS. O pedido só aparece quando você mexe no volume, no mudo ou na saída de um app tocando pela primeira vez. Permita.
2. Depois de permitir, o volume daquele app deve passar a mudar (a primeira ação grava a marca "permissão confirmada").
3. Deixe um app com volume baixo, com música tocando, e escolha "Sair". Abra o Volume de novo com a música ainda tocando: o volume baixo deve voltar **sozinho**, sem você mexer em nada e sem novo pedido de permissão.
4. Abra o Volume com o app lembrado parado (sem tocar): nada acontece até ele tocar. Ao tocar, o volume lembrado é aplicado.
5. Se o pedido de permissão aparecer **sozinho** ao abrir o Volume (sem você ter mexido em nada), anote — não deveria.

### 3. Saída por app
1. Clique no nome ou ícone de um app: abre "SAÍDA DESTE APP" com "Padrão do sistema (…)" e os dispositivos; o atual tem ✓.
2. Clique noutra linha: a primeira fecha (só uma aberta por vez).
3. Escolha outro dispositivo (ex.: fones): o som desse app vai para lá e a linha mostra o rótulo azul com o nome. Volte para "Padrão do sistema".
4. Clique em "Saída" e escolha outro dispositivo: muda a saída padrão do Mac.

### 4. Teclado e rolagem
1. Passe o ponteiro sobre um controle e role o mouse/trackpad: o volume muda pelo passo de Ajustes (padrão 5%) e a lista não rola.
2. Clique numa linha e use ← → (ou ↑ ↓): o volume muda. Espaço silencia/dessilencia a linha. Esc fecha.
3. Para usar Tab entre as linhas, ligue em Ajustes do Sistema › Teclado › "Navegação por teclado".
4. ⌘, abre uma janelinha provisória ("Os Ajustes… chegam na próxima etapa") — é esperado até a M5. ⌘Q sai.

### 5. Restaurar e sair
1. Baixe o volume de dois apps. Menu `•••` › "Restaurar áudio original": todos voltam a 100% na hora e o som segue normal.
2. Baixe um app de novo e escolha "Sair": o som desse app deve voltar ao normal e o ícone sair da barra, em menos de 2 segundos. Clicar várias vezes em Sair não deve causar nada estranho.
3. Abra o app, baixe um app, e force o encerramento (Monitor de Atividade): o som volta ao normal sozinho.

### 6. Sem permissão (opcional, mexe em Ajustes do Sistema)
1. Em Ajustes do Sistema › Privacidade e Segurança › Gravação de Áudio do Sistema, desligue o "Volume" com um app tocando e baixe o volume dele.
2. O app deve voltar ao som normal; a linha desse app, se aparecer, mostra só o aviso "Não foi possível controlar este app". O painel mostra "O Volume precisa de acesso…" com "Permitir…" (o cartão "Saída" continua funcionando).
3. Ligue a permissão de novo e reabra o painel: o aviso some sozinho e o app volta a ser controlável sem reiniciar.

### 7. Claro e escuro, acessibilidade
1. Repita 1 e 2 em Aparência Clara e Escura (Ajustes do Sistema › Aparência). Texto legível, nada fixo em cor errada.
2. Ligue "Reduzir transparência" e "Reduzir movimento" (Acessibilidade › Vídeo): o painel fica opaco e a linha abre sem animação.
3. VoiceOver (⌘F5): cada linha deve ser lida como "Spotify, volume 72 por cento, saída …"; o controle ajusta com Ctrl+Opt+↑/↓.

### 8. Matriz de apps (SPEC 4.1) — uma linha por app, nome e ícone corretos (nunca "Helper")
Para cada app, toque áudio, baixe o volume, silencie e volte:

| App | Aparece 1 linha? | Volume muda só ele? | Mudo ok? | Ao fechar o Volume o som volta? |
|---|---|---|---|---|
| Safari (vídeo/YouTube) | | | | |
| Chrome | | | | |
| Spotify | | | | |
| Discord | | | | |
| Zoom | | | | |
| Música | | | | |

### 9. Orçamentos (SPEC 12.4) — o QA não pôde medir sem abrir o app
- CPU ocioso: com o painel fechado e nenhum app ajustado, no Terminal: `top -l 5 -pid $(pgrep -x Volume) -stats cpu,mem` — esperado ~0% de CPU e memória < 60 MB.
- CPU com um app ajustado: mesmo comando; esperado < 1% de um núcleo (Apple Silicon).
- Abertura do painel: grave a tela (⇧⌘5) abrindo o painel e conte os quadros até o primeiro desenho; esperado < 100 ms (cerca de 6 quadros a 60 fps). Se a abertura parecer lenta a olho, avise.
- Medição prévia do QA (só montar a visão com dados falsos, sem áudio): cerca de 70 ms para criar e desenhar o painel completo.

Ao terminar, avise se algo falhou ou pareceu estranho (em especial os itens 1.3 e 2.5).
