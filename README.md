<div align="center">

<img src="Resources/AppIcon-1024.png" width="96" alt="Ícone do Volume Manager">

# Volume Manager

**Um volume para cada app no seu Mac, direto na barra de menus.**

Abaixe o navegador sem mexer no Spotify, silencie só o Discord ou mande cada app para uma saída diferente.

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-000000?logo=apple&logoColor=white)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-1f6feb)
![Grátis](https://img.shields.io/badge/pre%C3%A7o-gr%C3%A1tis-2ea44f)
![Sem rede](https://img.shields.io/badge/rede-nenhuma-2ea44f)

### [⬇&nbsp; Baixar o Volume Manager](https://github.com/eduardo-toste/volume-manager/releases/latest)

<img src="docs/images/hero.png" alt="Popover do Volume Manager nos modos Claro e Escuro, com Discord silenciado, Música a 55%, Safari a 35% nos AirPods Pro e Spotify a 72%" width="760">

</div>

## Instalar

<img src="docs/images/install-dmg.png" alt="Janela do DMG: arraste o Volume Manager para Aplicativos" width="360" align="right">

1. **Baixe** o `Volume-Manager-<versão>.dmg` na página de [Releases](https://github.com/eduardo-toste/volume-manager/releases/latest).
2. **Abra o DMG** e arraste o **Volume Manager** para **Aplicativos**.
3. **Abra o app.** Na primeira vez o macOS bloqueia, porque o app não é assinado com uma conta da Apple. Vá em **Ajustes do Sistema › Privacidade e Segurança**, role até o aviso do Volume Manager e clique em **Abrir Mesmo Assim**.
4. **Clique em Permitir…** na janela de boas-vindas e aceite o pedido de áudio do macOS. Pronto: o ícone de três faders aparece na barra de menus.

<br clear="right">

## Usar

<table>
<tr>
<td width="50%" align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/popover-routing-dark.png">
  <img src="docs/images/popover-routing-light.png" alt="Linha do Safari aberta com a lista de saídas: Padrão do sistema, Alto-falantes e AirPods Pro" width="260">
</picture>
<br><sub><b>Clique no nome de um app</b> para mandar o som dele para outra saída.</sub>
</td>
<td width="50%" align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/welcome-dark.png">
  <img src="docs/images/welcome-light.png" alt="Janela de boas-vindas com o botão Permitir" width="300">
</picture>
<br><sub><b>No primeiro uso</b>, as boas-vindas pedem a permissão de áudio.</sub>
</td>
</tr>
</table>

| Quero… | Faça assim |
|---|---|
| Ajustar o volume de um app | Clique no ícone da barra de menus e arraste o slider do app |
| Silenciar um app | Clique no alto-falante à direita do app |
| Mudar a saída de um app | Clique no nome do app e escolha o dispositivo |
| Voltar tudo ao normal | **Opções › Restaurar áudio original** |
| Abrir os Ajustes / sair | **⌘,** / **⌘Q** com o mixer aberto |

Só aparecem os apps que estão tocando som. Volume, mudo e saída de cada app ficam salvos e voltam quando ele tocar de novo.

## Perguntas frequentes

<details>
<summary><b>É seguro? O app coleta alguma coisa?</b></summary>

Não. O app não usa a internet (nem para procurar atualizações), não tem telemetria e não grava áudio:
o som só passa pela memória, multiplicado pelo volume. A única permissão é a de áudio do sistema.
O processamento é só `amostra × ganho`, então a qualidade é idêntica à original. Detalhes em
[SECURITY.md](SECURITY.md).
</details>

<details>
<summary><b>Por que o macOS pediu a permissão de novo depois de atualizar?</b></summary>

As versões não são assinadas com uma conta da Apple, então o macOS trata cada versão nova como um
app novo. Clique em **Permitir…** no aviso do app e aceite. Para atualizar, baixe o DMG novo e
substitua o app em Aplicativos.
</details>

<details>
<summary><b>Um app ficou sem som. E agora?</b></summary>

Use **Opções › Restaurar áudio original**, ou simplesmente feche o Volume Manager: ao fechar (ou se
ele travar), o macOS devolve o som de todos os apps ao normal na hora.
</details>

<details>
<summary><b>Como confiro se o arquivo baixado é o original?</b></summary>

Baixe também o `SHA256SUMS` da mesma Release, deixe na mesma pasta do DMG e rode no Terminal:

```sh
shasum -a 256 -c SHA256SUMS --ignore-missing
```

Tem que aparecer `OK`. Se não aparecer, apague o arquivo e não abra.
</details>

<details>
<summary><b>O botão "Abrir Mesmo Assim" não aparece</b></summary>

Tente abrir o app uma vez antes: o botão só aparece em Privacidade e Segurança depois do primeiro
bloqueio. Como alternativa, só se você baixou daqui e conferiu o SHA-256, rode no Terminal (isso
remove a marca de quarentena deste app):

```sh
xattr -dr com.apple.quarantine "/Applications/Volume Manager.app"
```
</details>

<details>
<summary><b>Como desinstalo?</b></summary>

Saia do app (**⌘Q** com o mixer aberto) e arraste o **Volume Manager** de Aplicativos para o Lixo.
Para apagar também os volumes salvos, rode `defaults delete com.volumemanager.app` no Terminal.
</details>

## Para desenvolvedores

<details>
<summary><b>Como funciona, compilar e documentação</b></summary>

<br>

Para cada app que está tocando, o Volume Manager cria um **process tap** do Core Audio
(`CATapDescription` com `mutedWhenTapped`) e um **aggregate device** privado com o tap na entrada e a
saída escolhida na saída. Um IOProc de tempo real copia o áudio multiplicando pelo ganho, sem
alocação, sem locks e sem logs. Se algo falhar, o tap é destruído e o som original volta.

Precisa do Xcode (Swift 6) no macOS 15+. Zero dependências externas.

```sh
swift build                 # compila
swift test                  # testes (Swift Testing)
scripts/check.sh            # formatação, build sem avisos, testes e segurança
scripts/build-app.sh        # gera build/Volume Manager.app
```

```
Sources/
├── VolumeCore     domínio puro: estado do mixer, preferências, políticas
├── VolumeAudio    process taps, aggregate devices e IOProc (Core Audio)
├── VolumeSystem   permissão, login item, preferências, informações dos apps
├── VolumeUI       popover, Ajustes e Boas-vindas (SwiftUI + AppKit)
├── VolumeManager  ponto de composição do app
└── vmctl          ferramenta de linha de comando para desenvolvimento
```

| Documento | Conteúdo |
|---|---|
| [docs/SPEC.md](docs/SPEC.md) | Especificação: telas, áudio, regras técnicas e de segurança |
| [docs/PLAN.md](docs/PLAN.md) | Etapas e critérios de aceite |
| [docs/RELEASE.md](docs/RELEASE.md) · [docs/SIGNING.md](docs/SIGNING.md) | Gerar, assinar e publicar um release |
| [SECURITY.md](SECURITY.md) | Política de segurança e como reportar vulnerabilidades |
</details>
