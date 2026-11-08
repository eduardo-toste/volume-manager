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

## M4.1 — reteste do ⏸2

Antes: `scripts/build-app.sh`, feche o Volume que estiver aberto e abra `build/Volume.app` de novo. Só confira o que mudou.

1. **Textos com acento**: abra o painel. Deve estar escrito "Saída", "Aplicativos", "Não foi possível controlar este app" (nada de "SaÃ­da").
2. **Rodapé**: "Ajustes do Volume…" e "Sair" sem "⌘," nem "⌘Q" escritos. Com o painel aberto, ⌘, ainda abre os Ajustes e ⌘Q ainda sai.
3. **Volume geral rápido**: arraste o controle largo do cartão "Saída" de ponta a ponta, bem rápido, várias vezes. Ele deve acompanhar o dedo sem travar nem voltar sozinho. Solte no meio: o valor onde você soltou é o que fica (confira em Ajustes do Sistema › Som).
4. **Volume de um app rápido**: mesma coisa num app tocando; o som muda sem engasgar e fica no último valor.
5. **Sem anel azul**: clique numa linha: aparece só o fundo suave, sem anel azul. Com "Navegação por teclado" ligada, Tab percorre cartão e linhas com o mesmo fundo suave; setas ajustam e Espaço silencia.
6. **Aparência**: o painel tem cantos arredondados e transparência como o módulo "Som" da Central de Controle (compare lado a lado, claro e escuro). Controles largos em forma de cápsula, com o alto-falante dentro. O alto-falante do cartão muda conforme o volume e fica vermelho no mudo; clicar nele silencia.
7. **Posição do painel**: abra e feche várias vezes, com 1, 3 e 6 apps tocando. O painel deve abrir colado na barra de menus, sem pular depois de aparecer.
8. **Painel alto**: com 5 apps ou menos, abra a saída de um app (clique no nome) e veja se o painel continua inteiro dentro da tela. Anote se passar da borda de baixo.
9. **Play com o painel aberto**: com o painel aberto e nenhum app tocando, dê play num app. A linha deve aparecer sozinha em até ~1 s. Repita com **outro app já tocando** e um segundo app que estava aberto e pausado: anote se a linha do segundo demora ou só aparece ao reabrir o painel (limitação conhecida).
10. **Spotify com AirPods**: com a permissão já concedida, deixe o Spotify tocando nos AirPods e baixe o volume dele: deve mudar. Se aparecer "Não foi possível controlar este app", anote e mande o texto de: `log show --last 2m --predicate 'subsystem == "com.volumemanager.app"' --info`.
11. **Permissão no lançamento**: com o Volume fechado, abra-o sem mexer em nada. Se aparecer sozinho o pedido de permissão, anote (o orquestrador diz que vem do sistema, não do app).
12. **VoiceOver** (⌘F5): o controle geral e o de cada app são lidos com nome e porcentagem e ajustam com Ctrl+Opt+↑/↓; o botão de mudo do cartão continua sendo lido como botão.
13. **Estalo ao baixar o Spotify** (use fones ou volume geral baixo; ouça com atenção):
    a. Feche o Volume e abra de novo. Deixe o Spotify tocando com o controle dele em 100% (sem ter mexido antes). Arraste o controle do Spotify de 100% para cerca de 10% de uma vez. Este é o **primeiro movimento** (o Volume ainda não estava controlando o Spotify). Anote: estalou? (sim/não)
    b. Agora, com o Spotify já controlado, faça mudanças grandes: arraste de 80% para 10%, depois de 10% para 80%, e repita 2 vezes. Anote: estalou? Em qual direção (descendo, subindo)?
    c. Resultado esperado: nenhum estalo em (a) nem em (b). Se houver, diga em qual das duas (a ou b) apareceu. Ajuda dizer se foi no começo da música/trecho alto ou também em trechos calmos.
14. **Painel e lista**: com 5 apps ou menos, abrir a saída de um app não deve passar da borda da tela (a lista passa a rolar). Dar play num app com outro já tocando e o painel aberto: se não aparecer sozinho, feche e abra o painel; a linha deve aparecer ao abrir.
15. **Visual igual ao design** (claro e escuro; abra `design/reference/popover-light.png` e `popover-dark.png` ao lado):
    a. Transparência: o painel deixa ver o fundo borrado atrás (mude a janela/papel de parede atrás e veja o painel mudar de tom). Os **cantos são bem arredondados** e **não aparece nenhum retângulo ou borda quadrada** em volta, nem sombra quadrada.
    b. Cartão "Saída" com fundo claro translúcido, ícone azul redondo, nome do dispositivo em negrito e `›`. Controle de volume com trilho fino, parte azul até o valor e **botão branco em forma de pílula**; alto-falante pequeno à esquerda (clique silencia) e maior à direita.
    c. Linhas dos apps: ícone, nome, porcentagem à direita, controle embaixo do nome e botão redondo de mudo à direita. Uma linha silenciada fica com o controle cinza e o botão vermelho. Anote a diferença que você achar: no design o botão de mudo mostra um alto-falante com "×"; no app é o alto-falante com uma barra.
    d. Linha expandida (clique no nome): "SAÍDA DESTE APP" com a lista e ✓ no atual, num bloco com fundo suave, como em `popover-app-output-*.png`.
    e. Ligue "Reduzir transparência" (Acessibilidade › Vídeo): o painel fica opaco, sem quebrar o visual.
16. **Apps que já estavam tocando antes de abrir o Volume**: toque música em 2 apps, **depois** abra o Volume, clique no ícone da barra. Os dois apps devem aparecer na lista na hora, sem você mexer em nada. Se faltar algum, diga qual e se ele estava tocando antes ou começou depois.
17. **Altura**: com 1, 2, 4 e 6 apps tocando o painel cresce junto, sem barra de rolagem; com 7 ou mais, a lista passa a rolar e o painel para de crescer (nunca passa de ~70% da altura da tela). O painel não deve "pular" depois de abrir.
18. **Painel novo (janela própria)**: o painel agora abre ao clicar no ícone, colado sob a barra de menus. Confira:
    a. Clicar no ícone abre; clicar de novo no ícone fecha (não reabre sozinho). Esc fecha. Clicar fora (na área de trabalho, em outra janela ou em outro ícone da barra) fecha.
    b. Abrir o painel **não** deve trazer as janelas de outros apps para frente nem tirar o app da frente de onde estava (o nome do app ativo no menu da esquerda não muda).
    c. Os menus do painel (`•••` e "Saída") abrem e escolher uma opção funciona sem o painel sumir antes da hora; ⌘, abre os Ajustes e ⌘Q sai.
    d. Com 2 telas, o painel abre na tela do ícone clicado. Perto da borda direita, ele não passa da tela.
    e. O ícone da barra muda conforme o volume geral e o estilo escolhido, e fica destacado enquanto o painel está aberto.
19. **Estalo, de novo (13)**: depois da correção das paradas de áudio, repita 13a/13b e também: arraste um app passando várias vezes por 100% (de 80% a 100% e de volta). Não deve estalar. Depois de ficar 2 segundos em 100%, o app volta ao som original (sem controle).
20. **Log** (para mandar se ainda estalar), logo depois do teste:
    `/usr/bin/log show --last 10m --info --predicate 'subsystem == "com.volumemanager.app"'`
    No log, ao mexer só no volume de um app já controlado, **não** devem aparecer várias linhas "tap and aggregate created" / "destroyed" seguidas. Anote o horário aproximado de cada estalo para comparar.
21. **Restaurar e Sair com o app em 100%**: baixe um app, volte a 100% e, antes de passar 2 segundos, use "Restaurar áudio original" ou "Sair": o som continua normal e nada fica mudo.
22. **Sempre controlado (Rodada 5)**: agora todo app que está tocando é controlado, mesmo em 100%. Confira, ouvindo com atenção:
    a. Mudanças de volume (arrastar, passar por 100%, silenciar e voltar, trocar a saída do app): **zero estalos**. Esse é o objetivo.
    b. Pode haver um estalinho **só no instante em que um app começa a tocar** (quando o Volume passa a controlá-lo). Anote se ouvir, e com quais apps.
    c. Pausar e dar play dentro de ~15 segundos não deve causar nada. Depois de ~15 s parado, o app deixa de ser controlado sozinho.
    d. **Som idêntico em 100%**: com o app em 100%, o som não deve mudar de timbre nem de volume em relação a antes de abrir o Volume.
    e. **Vídeo**: veja um vídeo (YouTube/Safari) com fones Bluetooth e com o alto-falante: a imagem e a fala continuam sincronizadas (sem atraso perceptível) e o som não falha.
    f. **Navegador silencioso**: abra uma aba com vídeo pausado/mudo (ou um site que mantém áudio aberto em silêncio) como único áudio e abra o painel. O painel **não** deve passar a dizer "sem permissão". Se disser, anote (limitação conhecida); tocar música de verdade e reabrir o painel deve resolver.
    g. **Restaurar áudio original** (menu `•••`): todos voltam ao som normal na hora, nenhum app fica mudo, e nenhum app é controlado de novo até você mexer em um volume.
    h. **Revogar permissão com o Volume aberto** (opcional): com 2 apps tocando, desligue o "Volume" em Ajustes do Sistema › Privacidade e Segurança › Gravação de Áudio do Sistema. Em poucos segundos os apps devem voltar a tocar normalmente (nunca ficar mudos) e o painel mostrar "sem permissão".
    i. **Apps com saída especial** (HDMI/monitor, interface multicanal): se aparecer "Não foi possível controlar este app" num app que você nem mexeu, anote — o som deve continuar normal.
