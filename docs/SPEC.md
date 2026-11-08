# Volume Manager — Especificação (v1)

> Fonte do design: `design/VolumeManager.figcraft` (FigCraft). Este documento descreve **o que** o app faz e **como deve se comportar**. O plano de implementação (ordem das tarefas, divisão entre agentes) fica em um documento separado.

## 1. Visão geral

**Volume** (nome exibido; projeto `VolumeManager`) é um mixer de volume por aplicativo para macOS, no espírito do Mixer de Volume do Windows, mas com aparência e comportamento de um app feito pela própria Apple.

- Vive **só na barra de menus** (sem ícone no Dock).
- **Abre automaticamente** quando o Mac liga (login item, ligado por padrão).
- **Segue o tema do sistema** (Claro/Escuro) e a cor de destaque do sistema. Não existe opção de tema no app.
- Permite: ajustar o volume de cada app, silenciar cada app, escolher a **saída de áudio de cada app** (ex.: Spotify no AirPods, resto no alto-falante), e controlar o volume/saída geral.

### Fora do escopo da v1
- Aumentar volume acima de 100% (boost), equalizador, efeitos.
- Controle de **entrada** (microfone) por app.
- Distribuição pela Mac App Store e Apple Developer Program (v1 é distribuída pelo GitHub Releases, sem notarização — ver §13).
- **Atualizações automáticas** (Sparkle/appcast). Fica para depois do MVP; a v1 é atualizada baixando a nova versão manualmente. O projeto já deve nascer preparado (§13.4).
- Localização além de **pt-BR** (strings devem ficar em `Localizable.xcstrings` para facilitar depois; inglês é desejável mas não obrigatório).

## 2. Plataforma e tecnologias

| Item | Decisão |
|---|---|
| Sistema mínimo | **macOS 15 (Sequoia)** — tem Core Audio process taps (base do volume por app), `@Observable` e `Synchronization.Atomic` (atômicos nativos do Swift para o thread de áudio, sem código C). Cobre Sequoia, Tahoe e posteriores. Decisão do usuário (M0.5). |
| Liquid Glass | Usado no **macOS 26+** (`glassEffect`, materiais novos). No 15.x, cai automaticamente para os materiais translúcidos nativos da época (`.regularMaterial`/`NSVisualEffectView`), de modo que o app parece nativo **em cada versão**. Ver §12.6. |
| Linguagem / UI | Swift 6 (modo de linguagem 6, concorrência estrita), **SwiftUI** (AppKit só onde o SwiftUI não alcança). |
| Barra de menus | `MenuBarExtra` com `.menuBarExtraStyle(.window)`. |
| Áudio | **Core Audio**: Process Taps (`CATapDescription`, `AudioHardwareCreateProcessTap`) + Aggregate Devices + IOProc. |
| Login item | `SMAppService.mainApp` (ServiceManagement). |
| Atalhos globais | **Nenhum** (decisão do usuário, 2026-11-07): o app é um gerenciador de volume e não registra atalhos globais. **Zero dependências externas.** |
| Persistência | `UserDefaults` (preferências e volumes lembrados por bundle ID). |
| Build | **Swift Package Manager** (`Package.swift`) + script `scripts/build-app.sh` que monta e assina o `.app`. Compila e testa só com as Command Line Tools; o Xcode abre o `Package.swift` diretamente quando instalado. Ver §12.7. |
| Testes | **Swift Testing** (`swift test`). |
| Identificação | Nome exibido **Volume** · bundle ID **`com.volumemanager.app`** · produto `VolumeManager`. |
| Info.plist | `LSUIElement = YES`, `LSMinimumSystemVersion = 15.0`, `NSAudioCaptureUsageDescription` com texto em pt-BR. |
| Assinatura | Hardened Runtime ligado; App Sandbox **desligado** na v1 (ver §10). **Sem Apple Developer Program**: assinatura com certificado próprio estável (§13.2). |

## 3. Telas

Todas existem em Claro e Escuro no design. Usar **controles e materiais nativos** (Slider, Toggle, Picker, `.glassEffect`/materiais do sistema, SF Symbols, SF Pro) sempre que eles reproduzirem o design; quando um controle nativo não reproduzir o design (ex.: o slider), usar um componente próprio pequeno e acessível. **O popover segue o design do FigCraft à risca** (decisão do usuário em 2026-11-08, após o ⏸2): layout, hierarquia, espaçamentos, tamanhos, cores, cantos e translucidez como em `design/VolumeManager.figcraft` (imagens de referência em `design/reference/`). Exceções já decididas: sem atalhos globais, sem “Mostrar na barra de menus” e sem “⌘,”/“⌘Q” escritos no rodapé.

### 3.1 Item da barra de menus
- Ícone SF Symbol de alto-falante. Com estilo “Alto-falante”, reflete o volume geral: `speaker.slash.fill` (mudo/0%), `speaker.wave.1.fill` (≤33%), `speaker.wave.2.fill` (≤66%), `speaker.wave.3.fill` (>66%).
- Clique abre/fecha o popover. Fica destacado enquanto o popover está aberto. O popover é uma **janela própria sem moldura** (`NSStatusItem` + painel transparente), presa ao ícone, para reproduzir exatamente os cantos e a translucidez do design — a janela padrão do `MenuBarExtra` desenha fundo e cantos próprios por trás (decisão do usuário em 2026-11-08). Fecha ao clicar fora, com Esc ou ao clicar de novo no ícone; não usa monitor global de eventos nem pede permissão nova.

### 3.2 Popover do mixer (largura ~320pt)
De cima para baixo:

1. **Cabeçalho** — título “Volume” e botão `•••` (menu com: Ajustes do Volume…, **Restaurar áudio original**, Sobre o Volume, Sair). “Restaurar áudio original” destrói todos os taps na hora e volta todos os apps a 100%/saída padrão, sem fechar o app (botão de pânico; ver §4.6).
2. **Card “Saída principal”**
   - Ícone do dispositivo + rótulo “Saída” + nome do dispositivo de saída padrão do sistema + chevron `›`.
   - Clicar abre a lista de dispositivos de saída; escolher um muda a **saída padrão do sistema**.
   - Slider do **volume geral** (volume do dispositivo padrão), com ícones de alto-falante mínimo/máximo nas pontas. Clicar no ícone mínimo = silenciar/dessilenciar o dispositivo.
   - Se o dispositivo não tem controle de volume por software (ex.: alguns DACs USB/HDMI), o slider fica desabilitado com dica “Este dispositivo não permite ajustar o volume”.
3. **Seção “Aplicativos”** + contador à direita (“N reproduzindo”).
4. **Lista de apps** (um por linha), ordenada: tocando agora primeiro, depois por nome.
   - Ícone do app (ícone real via `NSRunningApplication`/`NSWorkspace`), nome, valor à direita (“72%” ou “Silenciado”).
   - Slider de volume do app (0–100%).
   - Botão de mudo circular à direita. Silenciado: ícone `speaker.slash.fill` vermelho, fundo vermelho translúcido, nome e slider esmaecidos (o slider mantém o valor anterior).
   - **Rota por app**: se o app está numa saída diferente da padrão, mostra embaixo do nome um rótulo em cor de destaque “🔈 AirPods Pro ⌄”.
   - **Expandir linha** (clique no nome/ícone ou no rótulo de rota): mostra “SAÍDA DESTE APP” com a lista de dispositivos; o atual tem ✓. Primeira opção: “Padrão do sistema (‹nome›)”. Só uma linha expandida por vez.
   - Hover: fundo levemente destacado na linha.
   - Lista rola se passar de ~6 apps; o popover não cresce além de ~70% da altura da tela.
5. **Rodapé** (estilo item de menu): “Ajustes de Som…” (abre Ajustes do Sistema › Som), “Ajustes do Volume…”, “Sair”. ⌘, e ⌘Q funcionam com o popover aberto, mas **não aparecem escritos** (decisão do usuário em 2026-11-08, como na Central de Controle).

**Estados especiais do popover**
- **Sem permissão de áudio**: no lugar da lista de apps, um aviso “O Volume precisa de acesso ao áudio do sistema para ajustar cada app” + botão “Permitir…” (ver §5). O card de saída principal continua funcionando.
- **Nenhum app tocando**: texto secundário “Nenhum app está reproduzindo áudio” (respeitando a opção “Mostrar apps sem áudio”).

### 3.3 Janela de Ajustes
Janela padrão estilo Ajustes do Sistema: barra lateral de vidro + conteúdo em grupos (`Form` com `.formStyle(.grouped)`). Abre com ⌘, ou pelo popover. Uma instância só.

Barra lateral: **Geral, Aplicativos, Dispositivos, Sobre** (campo “Buscar” filtra itens da barra lateral; pode ser omitido na v1 se custoso).

- **Geral** (como no design)
  - Abrir ao iniciar sessão — toggle, **padrão ligado**. Subtítulo: “O Volume abre sozinho na barra de menus quando você liga o Mac”. Reflete o estado real de `SMAppService` (se o usuário desligar em Ajustes do Sistema › Itens de Início, o toggle mostra desligado). Se o sistema exigir aprovação (`.requiresApproval`), mostrar dica com botão para abrir Itens de Início.
  - (Sem opção para esconder o ícone: o ícone na barra de menus é a única porta de entrada do mixer e fica **sempre visível**. Decisão do usuário, 2026-11-07.)
  - Ícone da barra de menus — pop-up: “Alto-falante” (dinâmico, §3.1) ou “Controles” (`slider.horizontal.3`, fixo).
  - **Volume**: Lembrar o volume de cada app (padrão ligado; subtítulo “Restaura o nível quando o app voltar a tocar”); Mostrar apps sem áudio (padrão desligado); Incremento do volume (1%, 5%, 10%; padrão 5%).
- **Aplicativos**: lista de apps lembrados (ícone, nome, volume salvo, saída salva) com botão “Esquecer” por app e “Esquecer todos”.
- **Dispositivos**: lista de saídas disponíveis (nome, tipo, padrão ✓). Ação: definir como padrão. (Somente leitura + ação; sem configuração extra na v1.)
- **Sobre**: ícone, nome, versão e build, link do repositório.

### 3.4 Boas-vindas (primeiro uso)
Janela 480×600, só botão fechar ativo. Aparece **apenas na primeira execução** (ou se a permissão de áudio ainda não foi decidida).

- Ícone do app, “Bem-vindo ao Volume”, subtítulo.
- 3 destaques: Volume de cada app · Saída por app · Igual ao sistema.
- Grupo:
  - Abrir ao iniciar sessão — toggle **já ligado**; ao clicar em “Começar” com ele ligado, registra o login item.
  - Acesso ao áudio do sistema — botão “Permitir…” que dispara o pedido de permissão; após concedida, vira ✓ “Permitido”.
- Botão “Começar” (cor de destaque, largura total): fecha a janela e abre o popover uma vez para mostrar onde o app vive.

## 4. Comportamento de áudio

### 4.1 Descoberta de apps
- Listar processos de áudio via `kAudioHardwarePropertyProcessObjectList` e, para cada um, `kAudioProcessPropertyPID`, `kAudioProcessPropertyBundleID`, `kAudioProcessPropertyIsRunningOutput`.
- Ouvir mudanças (`AudioObjectAddPropertyListenerBlock`) da lista de processos e de `IsRunningOutput` — **sem polling**.
- **Agrupar por app**: processos auxiliares (ex.: `com.apple.WebKit.GPU`, “Google Chrome Helper”, “Discord Helper”) devem aparecer sob o app dono. Estratégia, em ordem:
  1. **Caminho do executável** (`proc_pidpath`, API pública): se o executável está dentro de `…/X.app/Contents/…`, o dono é o `.app` mais externo (resolve Chrome, Edge, Brave e todos os apps Electron).
  2. **Processo responsável** registrado pelo sistema (o mesmo que o Monitor de Atividade usa) — resolve serviços compartilhados como o WebKit do Safari. Usa a função não documentada `responsibility_get_pid_responsible_for_pid`, **somente** via o alvo C `CSystemShims` com declaração `__attribute__((weak_import))`. Decisão do usuário (M0.5). **Risco aceito (decisão do usuário em 2026-11-07, achado M-1):** em Swift não há checagem de nulo confiável para um símbolo `weak_import` sem `dlsym` (proibido); se um macOS futuro remover a função, o app cai ao listar processos (o som original volta, §4.6). Mitigação: o roteiro de release (M7) confirma que o símbolo existe no macOS mínimo e no atual antes de publicar.
  3. Fallback: prefixo do bundle ID.
  Uma linha = um app, sempre com **nome e ícone do app real** (nunca “Helper”); o tap cobre **todos** os processos do grupo. Matriz de validação obrigatória: Safari, Chrome, Spotify, Discord, Zoom, Música, vídeo no YouTube.
- Excluir: o próprio Volume e processos de sistema sem app visível (ex.: `coreaudiod`, sons do sistema) — sons do sistema seguem só o volume geral.
- “Tocando” = algum processo do grupo com `IsRunningOutput = true`. Com “Mostrar apps sem áudio” desligado, apps que pararam de tocar somem da lista após **5 s** (evita piscar entre faixas).

### 4.2 Volume e mudo por app
- Para cada app da lista (§4.1) **enquanto ele reproduz áudio**, criar um **process tap** (`CATapDescription` com os PIDs do grupo, `muteBehavior = .mutedWhenTapped`) e um **aggregate device** privado que contém o tap como entrada e o dispositivo de saída alvo como saída. Um IOProc copia o áudio do tap para a saída multiplicando pelo ganho.
- **Sempre controlar** (decisão do usuário em 2026-11-08, para estalo zero): o tap do app existe enquanto ele reproduz, **inclusive em 100%** — em 100% sem mudo o ganho é exatamente 1 (amostras copiadas bit a bit, §4.7), então o som é idêntico ao original. Assim nunca há troca entre o caminho nativo e o tap durante uma mudança de volume. O tap é criado quando o app começa a reproduzir (`IsRunningOutput`) e removido algum tempo depois que ele para (para não religar entre faixas). Sem permissão confirmada (§4.6), nenhum tap. Se o Volume fechar ou travar, o macOS devolve o som original.
- Ganho: curva perceptual (ex.: `gain = v²` ou dB), não linear pura; mudanças de ganho com **rampa** de ~20 ms para não estalar.
- Mudo = ganho 0 mantendo o valor do slider.
- Se o Volume fechar ou travar, os taps morrem junto e o áudio original volta sozinho — comportamento esperado e seguro.

### 4.6 Princípio “falhar abrindo” (nunca quebrar o áudio do usuário)
O pior resultado aceitável de qualquer falha é **“o app volta ao som normal”** — nunca “o app ficou mudo” ou “o som parou”.
- **Vigia (watchdog)**: para cada tap ativo, um contador atômico incrementado pelo IOProc é verificado periodicamente fora do thread de áudio **somente enquanto houver taps ativos**. Se o áudio parar de fluir enquanto o app de origem ainda está tocando (ou o IOProc reportar erro), o tap é destruído — o macOS devolve o som original do app — e a linha mostra “Não foi possível controlar este app”. Nova tentativa só por ação do usuário.
- **Restaurar áudio original** (menu `•••`, §3.2): destrói todos os taps imediatamente.
- **Modo seguro**: se o app encerrar de forma anormal 2 vezes seguidas em menos de 1 minuto após iniciar, a próxima inicialização **não reaplica** volumes/rotas lembrados e mostra um aviso discreto no popover. Volta ao normal após uma sessão estável.
- Falha ao criar tap ou aggregate device → não tenta de novo em laço; deixa o app no som original.
- **Tap silencioso por falta de permissão (descoberto no ⏸0)**: sem a permissão “Gravação de Áudio do Sistema”, o macOS **não retorna erro** — o tap é criado, o app original é silenciado e o tap entrega **somente zeros**. O vigia de frames não detecta isso. Regras:
  - **Antes** de criar qualquer tap de usuário, a permissão precisa ter sido confirmada por uma verificação de sinal (tap de teste sobre um processo que esteja tocando: se só chegar silêncio digital absoluto por ~500 ms enquanto o processo reporta `IsRunningOutput`, considerar **negada**).
  - **Durante** o uso, um **vigia de silêncio**: o IOProc registra (atômico, sem alocação) se recebeu alguma amostra ≠ 0. Se por **2 s seguidos** só chegar zero absoluto enquanto o app reporta `IsRunningOutput = true`, o tap é destruído (som original volta), e o app passa ao estado “sem permissão” (§3.2/§5). Isso é uma checagem de segurança binária (zero ou não), não análise de conteúdo: nada é guardado (§12.9.3).
  - Ferramentas sem `Info.plist` (CLI) nunca recebem o pedido de permissão; testes com áudio real usam um bundle `.app` com `NSAudioCaptureUsageDescription`.

### 4.7 Qualidade de áudio (requisito central)
O áudio de um app controlado pelo Volume deve soar **exatamente como soaria sem o Volume**, só que no volume escolhido. Nenhuma perda de qualidade é aceitável.
- **Transparência**: o processamento é **apenas** multiplicar cada amostra pelo ganho, em Float32. Proibido: compressão, limitador, equalização, dither, normalização, mixagem de canais, qualquer efeito.
- **Em ganho 1.0 a saída é idêntica bit a bit à entrada** (e, na saída padrão sem mudo, nem há tap — §4.2).
- **Formato preservado**: mesma taxa de amostragem, mesmo número e ordem de canais (estéreo, 5.1, espacial quando o dispositivo suportar), sem conversão para formatos de menor resolução.
- **Sem reamostragem** quando a saída é o mesmo dispositivo que o app usaria. Quando o app é roteado para outro dispositivo com taxa diferente, a conversão é feita **uma única vez**, pelo conversor de alta qualidade do próprio Core Audio (qualidade máxima), com compensação de drift ativada no subdispositivo de saída do aggregate.
- **Sem cortes, estalos ou falhas**: zero *overloads*/buffers perdidos em uso normal; mudanças de ganho com rampa (§4.2); trocar de saída sem estalo audível (rampa para 0 → troca → rampa de volta).
- **Sem clipping introduzido**: ganho ≤ 1.0 nunca aumenta o nível.
- **Latência**: dentro do orçamento do §12.4 (≤ 20 ms), imperceptível para vídeo e chamadas.
- Mudanças de formato do dispositivo (ex.: usuário troca a taxa no Configuração de Áudio e MIDI, fone Bluetooth muda de perfil) → o tap/aggregate é reconstruído no novo formato, nunca toca no formato errado.

### 4.3 Saída por app
- Escolher um dispositivo para um app recria o aggregate device daquele app com a nova saída.
- Se o dispositivo some (AirPods desconectou): o app volta para a **saída padrão** e a preferência fica guardada; quando o dispositivo reaparecer, a rota salva é restaurada.

### 4.4 Volume e saída geral
- Volume geral = volume do dispositivo de saída padrão (`kAudioHardwareServiceDeviceProperty_VirtualMainVolume` / `kAudioDevicePropertyVolumeScalar`), e mudo via `kAudioDevicePropertyMute`.
- Ouvir mudanças externas (teclas de volume, Central de Controle) e refletir no slider em tempo real.
- Escolher saída no card muda `kAudioHardwarePropertyDefaultOutputDevice`.

### 4.5 Lembrar volume
- Com “Lembrar o volume de cada app” ligado: salvar `{bundleID: {volume, muted, outputDeviceUID?}}` ao mudar; aplicar quando o app voltar a tocar. Saída salva por **UID** do dispositivo (estável), não por ID numérico.
- Desligado: todo app começa em 100%, sem mudo, na saída padrão.

## 5. Permissão de áudio
- Process taps exigem consentimento do usuário (TCC, “Gravação de Áudio do Sistema”). O pedido é disparado na primeira criação de tap; o botão “Permitir…” das boas-vindas cria um tap de teste para disparar o pedido.
- Texto do `NSAudioCaptureUsageDescription`: “O Volume usa o áudio do sistema para ajustar o volume de cada app. Nada é gravado ou enviado.”
- Negada: estado especial do popover (§3.2) com botão que abre Ajustes do Sistema › Privacidade e Segurança na seção correspondente. Detectar a concessão posterior sem reiniciar o app (re-tentar ao abrir o popover).

## 6. Interação por teclado
- **Sem atalhos globais** (fora do escopo por decisão do usuário). Apenas as teclas padrão do macOS dentro do app, necessárias para acessibilidade:
- Sliders: setas ←/→ e rolagem do trackpad/mouse ajustam pelo **Incremento do volume**.
- No popover: Tab/Setas navegam; Espaço alterna mudo da linha focada; Esc fecha. ⌘, abre Ajustes, ⌘Q sai.

## 7. Aparência
- **Tema = sistema**, sempre. Nenhuma cor fixa de fundo/texto: usar cores semânticas (`.primary`, `.secondary`, `Color.accentColor`), materiais e Liquid Glass do sistema.
- Cor de destaque = a do sistema (o azul do design é só a cor padrão).
- Respeitar Acessibilidade: Reduzir transparência (materiais ficam opacos automaticamente), Aumentar contraste, Reduzir movimento (sem animações de expandir), VoiceOver (cada linha: “Spotify, volume 72 por cento, saída AirPods Pro”; slider com `accessibilityValue`), Tamanho do texto do sistema.

## 8. Ciclo de vida
- Primeira execução → Boas-vindas. Depois disso, o app inicia direto na barra de menus.
- Login item **registrado por padrão** na primeira execução (via “Começar”, com o toggle ligado).
- Reabrir o app (duplo clique no Finder com ele já rodando) → abre os Ajustes.
- Sair: destrói todos os taps/aggregate devices antes de encerrar.
- **Fechar o app (Sair, ⌘Q, Forçar Encerramento ou travamento) sempre devolve o áudio de todos os apps ao comportamento padrão do macOS.** Apenas as mudanças feitas em configurações do próprio sistema (volume geral e saída padrão escolhidos pelo card “Saída principal”) permanecem, como aconteceria se tivessem sido feitas pela Central de Controle.
- Dormir/acordar e troca de usuário: reconstruir taps ao acordar se necessário.

## 9. Requisitos não funcionais
- CPU ocioso (popover fechado, sem taps): ~0%. Com taps ativos: < 3% de um núcleo por app em um Mac Apple Silicon.
- Latência adicional com tap: ≤ 20 ms (buffer pequeno no IOProc).
- Memória: < 60 MB.
- Sem rede, sem telemetria.
- Nenhuma alocação/lock no thread de áudio (IOProc em tempo real: ganho lido de variável atômica).

## 10. Decisões e riscos em aberto
1. **Sandbox**: process taps + aggregate devices em app com sandbox não estão confirmados para todos os casos. v1 sem sandbox; reavaliar se quiser App Store.
2. **Agrupamento de processos auxiliares** (Safari/Chrome/Electron) é a parte mais frágil; precisa de testes manuais com esses apps.
3. **Dispositivos sem volume por software**: volume geral desabilitado; o volume por app continua funcionando (é feito no nosso ganho).
4. **Apps que já usam saída exclusiva/hog mode** (ex.: alguns players de áudio “bit-perfect”) podem não ser controláveis — mostrar a linha desabilitada com dica.
5. **API privada de processo responsável**: usada só para agrupar serviços compartilhados (WebKit), com ligação fraca e fallback (§4.1, §12.9.2). Se um macOS futuro remover a função, o app continua funcionando e só esse agrupamento cai para heurística.

## 11. Glossário
- **Process tap**: objeto do Core Audio que captura (e opcionalmente silencia) a saída de um ou mais processos.
- **Aggregate device**: dispositivo virtual privado que junta o tap (entrada) e uma saída física; é onde aplicamos o ganho.
- **App de áudio**: grupo de processos (app principal + auxiliares) tratado como uma linha no mixer.

## 12. Especificação técnica

O código deve ser **bem arquitetado, legível, performático e confiável** — no nível de um app que a Apple publicaria. As regras abaixo são requisitos, não sugestões; o agente de testes verifica as que forem verificáveis.

### 12.1 Arquitetura

Camadas com dependência em **um sentido só** (de cima para baixo):

```
App (composição)        VolumeManagerApp, AppDelegate, Composition root
  │
UI (SwiftUI)            MenuBarPopover, AppRowView, OutputPicker, SettingsWindow, OnboardingWindow
  │  lê estado / envia intenções
Domínio (VolumeCore)    MixerStore, DeviceStore, SettingsModel, ProcessGrouping, RoutingPolicy, VolumeCurve
  │  depende só de protocolos
Serviços (protocolos)   AudioSystem, AppAudioController, LoginItemService, PermissionService,
                        PreferencesStore, AppInfoProvider
  │
Infra (implementações)  CoreAudio*, SMAppService*, UserDefaults*, NSWorkspace*
```

- **Separação em módulos SwiftPM** (fronteira imposta pelo compilador):
  - `VolumeCore` — domínio + protocolos de serviço. **Não importa** CoreAudio, AppKit nem SwiftUI (só Foundation/Observation). 100% testável com dublês.
  - `VolumeAudio` — implementações Core Audio (`AudioSystem`, `AppAudioController`). Depende de `VolumeCore`.
  - `VolumeSystem` — login item, permissão, preferências, info de apps (AppKit/ServiceManagement). Depende de `VolumeCore`.
  - `VolumeUI` — views SwiftUI. Depende de `VolumeCore` (nunca de `VolumeAudio`/`VolumeSystem`).
  - `VolumeManager` (executável) — **composition root**: cria as implementações reais e injeta no domínio. Único lugar que conhece todos os módulos.
- **Fluxo de dados unidirecional**: a UI lê estado `@Observable` e chama métodos de intenção (`setVolume(_:for:)`, `toggleMute(_:)`, `route(_:to:)`); nunca altera estado diretamente nem fala com serviços.
- **Injeção de dependência por inicializador**. Sem singletons globais (exceto o que o sistema já impõe, como `NSWorkspace.shared`, encapsulado atrás de protocolo).
- **Fonte única da verdade**: o estado de cada app (volume, mudo, rota) vive no `MixerStore`; persistência e áudio reagem a ele.
- **Reconciliação declarativa no áudio**: o domínio calcula o “estado desejado” por app (ganho, mudo, dispositivo); o `AppAudioController` reconcilia (cria/atualiza/destrói taps) de forma **idempotente**. Isso evita estados inconsistentes quando eventos chegam fora de ordem.

### 12.2 Concorrência
- Swift 6 com **concorrência estrita** (`-strict-concurrency=complete`, zero avisos).
- Estado de UI e domínio isolados em `@MainActor`.
- Wrappers de Core Audio isolados em um `actor` (ou executor serial dedicado); callbacks de listeners do Core Audio entram numa fila própria e são encaminhados ao domínio via `AsyncStream`.
- **Thread de áudio em tempo real (IOProc)**: proibido alocar memória, usar locks, `async`, Objective-C/Swift dinâmico, logs ou qualquer chamada que bloqueie. Parâmetros (ganho alvo, mudo) lidos de atômicos (`Synchronization.Atomic`) escritos pelo actor.
- Nada de `DispatchQueue.main.sync`, `sleep` ou espera ocupada.

### 12.3 Qualidade de código
- Estilo: **swift-format** com configuração do repositório (`.swift-format`); o build de CI falha com violações.
- Nomes seguindo as *Swift API Design Guidelines*; código e identificadores em **inglês**, textos de UI em pt-BR via `Localizable.xcstrings`.
- Arquivos coesos (alvo < 300 linhas); funções curtas; um tipo principal por arquivo.
- Proibido: `try!`, `as!`, force unwrap (`!`) fora de testes, `print` (usar `os.Logger` com subsistema `com.volumemanager.app` e categorias por módulo), código morto/comentado, `TODO` sem issue.
- **Erros tipados**: chamadas Core Audio retornam `OSStatus` → convertido em `AudioError` com contexto (qual propriedade/objeto). Nunca ignorar `OSStatus` silenciosamente.
- **Gestão de recursos**: todo tap, aggregate device, IOProc e listener criado tem dono claro e é destruído no `deinit`/shutdown (RAII). Teste de vazamento: criar/destruir 100 vezes sem sobras (§12.8).
- APIs públicas dos módulos documentadas com comentários `///`.
- **Zero dependências externas** (só frameworks da Apple); qualquer dependência nova exige aprovação do usuário e alteração desta SPEC.

### 12.4 Performance (orçamentos)
| Métrica | Orçamento |
|---|---|
| CPU com popover fechado e nenhum tap | ~0% (sem timers nem polling; tudo por eventos) |
| CPU por app com tap ativo | < 1% de um núcleo (Apple Silicon), < 3% (Intel) |
| Latência extra por tap | ≤ 20 ms |
| Memória residente | < 60 MB |
| Abrir o popover | primeiro quadro em < 100 ms |
| Arrastar slider | 60 fps; atualização de ganho aplicada em < 30 ms |
| Inicialização (login) até ícone na barra | < 1 s |

Regras que garantem os orçamentos:
- **Tap em 100% com ganho exatamente 1** (cópia bit a bit) e sem IO quando o app não reproduz (§4.2).
- Escritas em `UserDefaults` com *debounce* (~500 ms) durante arraste de slider.
- Ícones de apps carregados uma vez e em cache (por bundle ID), redimensionados para 30 pt.
- Views da lista com identidade estável (`id` = chave do app) para evitar redesenho total.
- Recriação de aggregate device só quando a **saída** muda; mudanças de volume/mudo só mexem no atômico.

### 12.5 Robustez e funcionamento
- **Reinício do `coreaudiod`**, troca de dispositivo padrão, conectar/desconectar fones, dormir/acordar: o app se recupera sozinho reconciliando o estado desejado.
- Falha ao criar tap de um app → aquela linha mostra estado de erro discreto (“Não foi possível controlar este app”) e o resto continua funcionando; erro registrado no `Logger`.
- Encerramento (normal ou sinal) destrói taps; se o processo morrer, o macOS restaura o áudio original (comportamento do sistema).
- Nenhuma ação do usuário pode deixar um app **sem som de forma permanente** (ex.: mudo preso). Ao iniciar, o app só aplica mudo lembrado se “Lembrar o volume” estiver ligado.

### 12.6 Compatibilidade de versões (macOS 15+)
- Uma camada de estilos (`VolumeUI/Styling`) centraliza as diferenças: `GlassBackground`, `CardBackground`, `RowHighlight`. Dentro deles, `if #available(macOS 26, *)` escolhe Liquid Glass; senão, materiais nativos (`.regularMaterial`, `.thinMaterial`). **Nenhum `#available` espalhado pelas views.**
- Ajustes: no 26+ usam a barra lateral de vidro; no 15 usam `NavigationSplitView` padrão — em ambos, `Form(.grouped)`.
- Testar visualmente em pelo menos **macOS 15 e 26** (máquina virtual serve) antes de cada release.

### 12.7 Estrutura do repositório e build
```
volume-manager/
├── Package.swift                 # módulos do §12.1 + testes; platforms: .macOS(.v15)
├── Sources/
│   ├── VolumeCore/  VolumeAudio/  VolumeSystem/  VolumeUI/
│   └── VolumeManager/            # @main, composition root
├── Tests/
│   ├── VolumeCoreTests/          # domínio com dublês (maior parte dos testes)
│   ├── VolumeAudioTests/         # testes de integração Core Audio (marcados, podem pular em CI sem áudio)
│   └── VolumeSystemTests/
├── Resources/                    # Info.plist, Assets (ícone), Localizable.xcstrings, entitlements
├── scripts/
│   ├── build-app.sh              # swift build -c release → monta VolumeManager.app → codesign
│   └── check.sh                  # swift-format lint + swift build + swift test (o “CI” local)
├── design/VolumeManager.figcraft
└── docs/SPEC.md, docs/PLAN.md
```
- `scripts/check.sh` é o portão de qualidade: precisa passar antes de qualquer entrega de tarefa.
- Configurações de compilação: avisos tratados como erros no release (`-warnings-as-errors`), otimização `-O` no release.

### 12.8 Estratégia de testes
- **Pirâmide**: maioria em `VolumeCoreTests` (rápidos, sem hardware); poucos testes de integração Core Audio; verificação manual guiada para o que depende de hardware/permissões.
- Dublês: `FakeAudioSystem` (emite processos/dispositivos sob comando), `SpyAppAudioController` (registra o estado desejado recebido), `InMemoryPreferencesStore`, `FakeLoginItemService`, `FakeClock` (para debounce e o atraso de 5 s de §4.1).
- Cobertura mínima: **≥ 85% de linhas em `VolumeCore`**.
- Casos obrigatórios: agrupamento de processos (Safari/WebKit, Chrome Helper, Electron), regra “tap enquanto reproduz, ganho 1 em 100%”, fallback e restauração de rota, lembrar/esquecer volume, debounce de persistência, contador “N reproduzindo”, curva de volume (0, 1, monotônica), atraso de 5 s para remover apps.
- Integração (`VolumeAudioTests`): criar/destruir tap e aggregate device 100× sem vazamento; listar dispositivos; ler/escrever volume geral num dispositivo nulo/virtual quando disponível.
- **Roteiro manual** (`docs/MANUAL_TESTS.md`, escrito pelo agente de testes) cobrindo os critérios do §14 que exigem hardware.
- Casos obrigatórios do §4.6: vigia destrói tap parado, “Restaurar áudio original” limpa tudo, modo seguro após 2 encerramentos anormais.

#### 12.8.1 Testes isolados — nenhum som audível
Testes automáticos **nunca** podem produzir som audível nem alterar o estado de áudio da máquina do usuário.
- Processos de teste tocam **silêncio digital** ou sinal com ganho 0 (ex.: utilitário de teste próprio `test-tone` em `Tests/Support`, ou `afplay -v 0`). Proibido tocar sons do sistema/arquivos em volume audível.
- Sinais de teste não-silenciosos só podem existir **dentro** de um tap com `mutedWhenTapped` cujo aggregate **não tem saída física** (aggregate só com o tap) — o sinal é analisado em memória e nunca chega aos alto-falantes. O processo de teste começa em silêncio e só gera o sinal depois que o tap está ativo.
- Proibido nos testes: alterar volume geral, mudo geral ou dispositivo padrão do sistema; criar dispositivos que permaneçam após o teste.
- Testes que dependem de hardware de áudio ficam marcados (tag `.audioHardware`) e são pulados por padrão em `check.sh`; rodam com `scripts/check.sh --audio`.

#### 12.8.2 Testes de qualidade de áudio (§4.7)
Com o arranjo isolado acima (sinal conhecido → tap → nosso processamento → buffer em memória):
- **Teste nulo**: em ganho 1.0, saída − entrada = 0 exatamente (bit a bit) para seno, ruído branco e silêncio.
- **Ganho exato**: em ganho g, cada amostra = entrada × g (tolerância de 1 ULP de Float32 após a rampa).
- **Formato**: taxa, canais e ordem de canais da saída iguais aos da entrada (testar 44.1/48/96 kHz e mono/estéreo quando disponíveis).
- **Continuidade**: 10 minutos de sinal sem buffer perdido, sem descontinuidade de fase e sem *overload* reportado.
- **Rampa**: mudança de ganho sem degraus (derivada limitada) — sem estalo.
- **Latência**: medida pelo atraso entre sinal gerado e sinal recebido, ≤ 20 ms.
- Essas análises de sinal existem **somente** no código de teste; o app nunca analisa áudio (§12.9.3).

### 12.9 Segurança e privacidade

O app recebe uma permissão poderosa (acesso ao áudio do sistema). Segurança é **requisito bloqueante**: nenhuma etapa é aprovada com item de segurança pendente.

#### 12.9.1 Modelo de ameaças
| Ativo | Ameaça | Controle |
|---|---|---|
| Permissão de áudio concedida ao Volume | Código malicioso injetado no Volume herdar o acesso | Hardened Runtime sem exceções (§12.9.2) |
| Identidade de assinatura | Chave privada vazada → app falso assinado como Volume herda a permissão | Chave só na máquina do mantenedor (§12.9.5) |
| Áudio do usuário (chamadas, música) | Ser gravado, guardado ou enviado | Áudio só em memória, sem rede, sem disco (§12.9.3) |
| Integridade do download | DMG adulterado redistribuído | SHA-256 publicado, canal oficial único (§13) |
| Áudio do usuário (disponibilidade) | Bug deixar app mudo/sem som | Falhar abrindo (§4.6) |
| Preferências | Valores corrompidos/editados por outro processo | Validação na leitura (§12.9.4) |
| Código-fonte/dependências | Dependência ou action comprometida | Versões fixadas, revisão (§12.9.6) |

#### 12.9.2 Endurecimento do binário (release)
- Hardened Runtime **ligado**.
- Entitlements de release: **nenhuma exceção** de runtime. Proibidos: `com.apple.security.cs.disable-library-validation`, `com.apple.security.cs.allow-dyld-environment-variables`, `com.apple.security.cs.allow-unsigned-executable-memory`, `com.apple.security.cs.allow-jit`, `com.apple.security.get-task-allow`, `com.apple.security.cs.debugger`.
- Nenhum framework/dylib carregado de fora do bundle (exceto do sistema); nenhum carregamento dinâmico de código (`dlopen` de caminho variável, plugins, scripts).
- **Única API privada permitida**: `responsibility_get_pid_responsible_for_pid` (consulta somente-leitura sobre PIDs), declarada `weak_import` no alvo C `CSystemShims` (um único header, sem lógica). Proibido: `@_silgen_name`, `dlsym`, qualquer outra API privada. `CSystemShims` é o **único** código C permitido no projeto.
- Sem `NSAppleScript`/`Process` executando comandos externos a partir de dados variáveis. Abrir Ajustes do Sistema apenas por URLs fixas no código.
- Símbolos de depuração fora do binário de release; nenhuma flag/variável de ambiente que altere comportamento em release.

#### 12.9.3 Privacidade e dados
- **Sem rede**: o app não faz nenhuma conexão (nem para verificar atualização no MVP). Nenhum uso de `URLSession`, `Network.framework` ou sockets em `Sources/` (exceto abrir links no navegador via `NSWorkspace.open`, que é o navegador do usuário).
- **Áudio nunca persiste**: o IOProc só copia entrada → saída com ganho. Proibido escrever amostras em arquivo, buffer circular de histórico, análise/transcrição ou qualquer cópia fora do ciclo do IOProc.
- **Sem telemetria/analytics**, sem identificadores de usuário/máquina.
- Dados guardados: apenas preferências e, por app, `{bundleID, volume, mudo, UID de saída}` em `UserDefaults`. “Esquecer todos” apaga tudo. Nada de histórico de uso.
- **Logs**: `os.Logger` com nomes de apps, bundle IDs, PIDs e nomes de dispositivos marcados `privacy: .private`. Nunca logar conteúdo de áudio.
- Permissões pedidas: **somente** áudio do sistema. Proibido pedir Acessibilidade, Monitoramento de Entrada, Microfone, Gravação de Tela, Contatos, Localização, etc.

#### 12.9.4 Entradas e validação
- Toda informação vinda de outros processos (nome, bundle ID, caminho, PID) é tratada como **não confiável**: exibida como texto puro, com tamanho limitado (ex.: 200 caracteres), sem interpretação (nada de formatação/markup/URL a partir dela).
- PIDs revalidados antes de criar tap (o processo pode ter morrido e o PID ter sido reutilizado): confirmar que PID + bundle ID + caminho ainda batem.
- Preferências lidas de `UserDefaults` validadas: volume ∈ [0, 1], booleanos válidos, UID de dispositivo como string limitada; valor inválido → padrão seguro (100%, sem mudo, saída padrão) + log.
- Todo `OSStatus` verificado; tamanhos de buffer do Core Audio verificados antes de copiar (sem confiar em contagens de frames sem checar capacidade).

#### 12.9.5 Assinatura e chaves
- A chave privada do certificado próprio fica **somente no Acesso às Chaves do mantenedor** (com backup criptografado offline). **Nunca** no repositório, no CI ou em secrets do GitHub.
- Releases são compilados e assinados **localmente** (`scripts/release.sh`).
- `scripts/release.sh` recusa assinar se houver mudanças não commitadas ou se a tag não existir.
- Requisito designado (`codesign -d -r-`) estável entre versões e documentado em `docs/SIGNING.md`.

#### 12.9.6 Cadeia de suprimentos
- Dependências: **nenhuma**. `Package.swift` sem `dependencies` e sem `Package.resolved`.
- **Sem CI** (decisão do usuário, 2026-11-07): o repositório não tem `.github/workflows`; as verificações rodam localmente com `scripts/check.sh` antes de cada commit/merge. Um teste de política impede que um workflow seja adicionado.
- Repositório: 2FA na conta, proteção da branch `main`, tags de release assinadas.
- Ferramentas de desenvolvimento (`vmctl`) **não** são incluídas no `Volume.app` nem no DMG.

#### 12.9.7 Verificações de segurança (executadas pelo QA a cada etapa; bloqueantes)
Script `scripts/security-check.sh`, chamado pelo `check.sh` (as verificações de binário rodam no `.app` gerado):
1. Entitlements do `.app` de release não contêm nenhuma chave proibida (§12.9.2) — `codesign -d --entitlements -`.
2. Hardened Runtime ativo (`codesign -dv` mostra `flags=0x10000(runtime)`); assinatura válida (`codesign --verify --strict --deep`).
3. Busca estática em `Sources/` por APIs proibidas: `URLSession`, `NWConnection`, `socket(`, `CFSocket`, `dlopen`, `NSAppleScript`, `Process(`, `system(`, `popen`, `AudioFileCreate`, `ExtAudioFile`, `AVAudioRecorder`, `AVAudioFile`, `print(`, `try!`, `as!`, `@_silgen_name`, `dlsym`; e qualquer arquivo `.c`/`.h`/`.m` fora de `Sources/CSystemShims` (única exceção de `print(`: `Sources/vmctl`, que é ferramenta de terminal e não vai no app).
4. Busca por segredos no repositório (chaves privadas, `.p12`, tokens).
5. `vmctl` ausente do bundle; nenhum dylib/framework de terceiros fora do esperado em `Contents/`.
6. `Info.plist` contém só a descrição de uso de áudio (nenhuma outra `NS*UsageDescription`).
7. Dependências: `Package.swift` declara zero dependências e não existe `Package.resolved` com pins.
8. Logs: busca por `Logger` com interpolação sem `privacy:` em dados de apps/dispositivos.

#### 12.9.8 Auditoria independente
Antes do primeiro release (etapa própria no plano), um **agente de segurança** independente — que não escreveu o código — revisa o código inteiro contra este §12.9 e o modelo de ameaças, com foco em: thread de áudio (memória/limites), tratamento de dados de outros processos, criação/destruição de taps (vazamentos, condições de corrida), entitlements e scripts de build/release. Achados classificados em Crítico/Alto/Médio/Baixo; **Crítico e Alto bloqueiam o release**.

## 13. Distribuição (MVP)

### 13.1 Canal
- **GitHub Releases**: cada versão publica `Volume-<versão>.dmg` e o `.zip` do app, junto com o arquivo `SHA256SUMS` (hash de cada artefato), também colado nas notas da Release.
- DMG com **instrução visual**: fundo da janela com seta “arraste para Aplicativos” e lembrete “Na primeira vez: Ajustes do Sistema › Privacidade e Segurança › Abrir Mesmo Assim”.
- Publicação **manual** no MVP: `scripts/release.sh <versão>` gera, assina e calcula os hashes **localmente**; o upload na Release é feito à mão. O GitHub oficial é o **único** canal de download divulgado.
- **Sem CI**: a qualidade é garantida localmente (`scripts/check.sh` e `scripts/check.sh --app`) antes de cada merge e de cada release.

### 13.2 Assinatura sem conta da Apple
- Não usar assinatura ad-hoc em releases: ela muda a identidade do app a cada build e o macOS esquece a permissão de áudio a cada versão.
- Usar um **certificado de assinatura de código próprio** (autoassinado, criado no Acesso às Chaves, ex.: “Volume Self-Signed”). O nome do certificado é parâmetro do `build-app.sh` (variável `VOLUME_SIGN_IDENTITY`); sem ela, o script cai para ad-hoc (uso em desenvolvimento).
- Hardened Runtime ligado; entitlements mínimos (nenhum além do necessário para áudio).

### 13.3 Instalação para quem baixa (README)
- Passo a passo com imagens: abrir o DMG → arrastar para Aplicativos → primeira abertura bloqueada → Ajustes do Sistema › Privacidade e Segurança › **Abrir Mesmo Assim** (só na primeira vez).
- Alternativa no Terminal: `xattr -dr com.apple.quarantine /Applications/Volume.app`.
- Requisitos: macOS 15+, permissão de áudio do sistema no primeiro uso.
- Para atualizar: baixar o novo DMG e substituir o app (permissões são mantidas graças ao §13.2).

### 13.4 Preparação para atualizações automáticas (futuro)
- Versionamento semântico: `CFBundleShortVersionString` = `MAJOR.MINOR.PATCH`, `CFBundleVersion` = número inteiro crescente; ambos definidos num só lugar (`Resources/Version.xcconfig` ou equivalente lido pelo `build-app.sh`).
- Tela **Sobre** já mostra versão e build e um link “Ver versões no GitHub” (abre a página de Releases).
- Nenhuma dependência de atualização no MVP; incluir Sparkle depois deve exigir apenas: dependência, chave EdDSA, item de menu e appcast.

## 14. Critérios de aceite (resumo, para o agente de testes)
1. Primeira execução mostra Boas-vindas; “Começar” com toggle ligado deixa `SMAppService.mainApp.status == .enabled`.
2. Após reiniciar o Mac/sessão, o app está na barra de menus sem abrir janela.
3. Trocar o sistema entre Claro/Escuro muda o app na hora, sem reiniciar.
4. Tocar áudio em 2 apps → ambos aparecem; baixar um para 30% muda só ele; mudo silencia só ele; mudanças de volume (inclusive passando por 100%) não estalam nem recriam o tap.
5. Mandar um app para outro dispositivo toca só ele lá; desconectar o dispositivo volta para o padrão; reconectar restaura.
6. Teclas de volume do teclado movem o slider geral em tempo real.
7. Com “Lembrar volume” ligado, fechar e reabrir o Spotify restaura 72%/rota.
8. Permissão negada → aviso no popover; conceder em Ajustes do Sistema → lista aparece ao reabrir o popover.
9. O app não registra nenhum atalho global; no popover, Tab/setas/Espaço/Esc funcionam e ⌘, / ⌘Q respondem.
10. Sair do Volume → todos os apps voltam ao áudio original.
11. Testes unitários cobrem `MixerStore`, `PreferencesStore`, agrupamento de processos e a lógica de fallback de rota, usando mocks (cobertura ≥ 85% em `VolumeCore`).
12. `scripts/check.sh` passa: formatação, build sem avisos (concorrência estrita) e todos os testes.
13. App roda no **macOS 15+** com materiais nativos e no **macOS 26+** com Liquid Glass.
14. Orçamentos de performance do §12.4 verificados com Instruments/Activity Monitor (registrar números no roteiro manual).
15. Princípio “falhar abrindo” (§4.6): vigia, “Restaurar áudio original” e modo seguro funcionam; Forçar Encerramento do Volume devolve o áudio original de todos os apps.
16. `scripts/security-check.sh` passa sem nenhum item (§12.9.7).
17. Auditoria independente de segurança (§12.9.8) sem achados Críticos ou Altos em aberto.
19. Qualidade de áudio (§4.7): testes de §12.8.2 passam (teste nulo bit a bit, ganho exato, formato preservado, 10 min sem falhas, latência ≤ 20 ms), e na escuta do usuário não há diferença perceptível em relação a não ter o app.
20. Nenhum teste automático produz som audível nem altera o áudio do sistema (§12.8.1).
18. Matriz de apps do §4.1 (Safari, Chrome, Spotify, Discord, Zoom, Música, YouTube): cada um aparece **uma vez**, com nome e ícone corretos, e responde ao volume.
