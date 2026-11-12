# Volume Manager — regras do projeto

Mixer de volume por app para macOS (barra de menus, SwiftUI, Core Audio process taps).
Prioridades, nesta ordem: **segurança → nunca quebrar o áudio do usuário → qualidade de áudio idêntica à nativa (SPEC §4.7) → funcionar bem → fluidez/facilidade de uso → visual nativo.**

## Fontes da verdade (ler antes de qualquer tarefa)
- `docs/SPEC.md` — o que o app faz e as regras técnicas (§12) e de segurança (§12.9). **A SPEC manda.**
- `docs/PLAN.md` — etapas, papéis e critérios de cada etapa.
- `design/VolumeManager.figcraft` — referência visual (não é para recriar pixel a pixel; usar controles nativos).

## Ambiente
- macOS 27, **Xcode 27.2 instalado e selecionado** (Swift 6.4.2; macros do SwiftUI disponíveis). Testes com **Swift Testing**. Sem CI: tudo é verificado localmente.
- Comandos: `swift build`, `swift test`, `swift format lint -r .`, `scripts/check.sh` (portão de qualidade), `scripts/build-app.sh`.

## NUNCA (regras absolutas — violar = etapa reprovada)
1. **Não mudar requisitos.** Nada de recursos, telas, opções ou dependências fora da SPEC. Desvio necessário → parar e relatar ao orquestrador.
2. **Zero dependências externas**: não adicionar nenhum pacote (só frameworks da Apple). Atalhos globais estão fora do escopo.
3. **Nada de rede** em `Sources/`: `URLSession`, `Network.framework`, sockets, analytics, telemetria, “verificar atualização”.
4. **Áudio nunca persiste**: proibido gravar/copiar amostras para arquivo, histórico, análise ou transcrição.
5. **Nenhuma permissão extra**: só áudio do sistema. Proibido pedir Acessibilidade, Monitoramento de Entrada, Microfone, Gravação de Tela, etc.
6. **Nenhuma exceção de Hardened Runtime** nos entitlements de release (lista em SPEC §12.9.2).
7. **Thread de áudio (IOProc)**: sem alocação, locks, `async`, logs, Objective-C dinâmico ou chamadas bloqueantes.
8. **Proibido em `Sources/`**: `try!`, `as!`, force unwrap, `print(` (exceto `Sources/vmctl`), `dlopen`, `Process(`, `system(`, `popen`, `NSAppleScript`, código comentado, `TODO` sem justificativa.
9. **Nunca deixar um app mudo/sem som** por falha: na dúvida, destruir o tap (som original volta). Ver SPEC §4.6.
10. **Git**: não fazer `push`, não trocar de branch, não fazer merge/rebase/reset, não reescrever histórico. Commits só no branch da etapa atual, e só se o orquestrador pedir.
11. **Sistema**: não usar `sudo`, não rodar `tccutil`, não matar `coreaudiod`, não alterar preferências do sistema fora dos testes previstos.
16. **Nada de instalar ou baixar** (decisão do usuário): proibido instalar programas, ferramentas, runtimes ou pacotes (brew, pip, npm, gem, cargo, mas, softwareupdate, instaladores .pkg/.dmg) e proibido baixar qualquer coisa da internet (curl, wget, git clone, `swift package resolve/update` ou adicionar dependências que façam o SwiftPM baixar código). Se algo precisar ser instalado ou baixado, **pare e peça ao orquestrador**, que pede ao usuário — **o usuário instala, sempre**.
12. **Segredos**: nenhum certificado, chave, `.p12`, token ou senha no repositório.
13. **Não enfraquecer verificações**: não desligar testes, não relaxar `security-check.sh`, não baixar cobertura mínima, não adicionar exceções ao lint para “passar”.
14. **Nenhum som audível** em testes ou experimentos: o usuário trabalha nesta máquina. Usar silêncio digital / `afplay -v 0`, ou sinais só dentro de tap `mutedWhenTapped` com aggregate sem saída física (SPEC §12.8.1). Não alterar volume geral, mudo ou dispositivo padrão. Encerrar todo processo de áudio iniciado.
15. **Não degradar o áudio**: o processamento é só `amostra × ganho` em Float32; sem efeitos, sem conversão de formato, sem reamostragem desnecessária (SPEC §4.7).

## SEMPRE
- Código e identificadores em inglês; textos de UI em pt-BR via `Localizable.xcstrings`.
- Dependências por protocolo + injeção por inicializador; `VolumeCore` sem CoreAudio/AppKit/SwiftUI.
- Swift 6 com concorrência estrita e zero avisos.
- Dados de outros processos (nome, bundle ID, caminho, PID) são **não confiáveis**: texto puro, tamanho limitado, PID revalidado.
- `scripts/check.sh` verde antes de entregar.
- **Sem overengineering** (decisão do usuário): a solução mais simples que cumpre a SPEC. Nada de protocolo, tipo, camada, arquivo ou opção nova sem uso real **hoje**; nada de generalizar para um segundo caso que não existe. Toda abstração nova é justificada em uma linha no relatório. Simplificar **nunca** corta verificação de segurança nem o “nunca deixar mudo” — a ordem de prioridades acima prevalece. QA, Segurança e o orquestrador julgam a proporcionalidade de cada entrega.
- Relatório de entrega no formato abaixo.

## Papéis (detalhes em `.claude/agents/`)
| Papel | Pode alterar | Não pode |
|---|---|---|
| Dev | `Sources/`, `Tests/` (testes do que criou), `Package.swift`, `Resources/`, `scripts/` | mudar SPEC/PLAN, enfraquecer verificações |
| QA | `Tests/`, `docs/MANUAL_TESTS.md`, relatórios em `docs/reports/` | `Sources/`, scripts de verificação para relaxar regras |
| Segurança | `docs/SECURITY_AUDIT.md`, `docs/reports/` | qualquer código de produção |

## Formato do relatório de entrega (Dev, QA e Segurança)
```
## Etapa <id> — <papel>
Resultado: PASS | FAIL | ENTREGUE
O que foi feito: …
Como verificar: comandos exatos
Verificações: check.sh ✓/✗ · security-check ✓/✗ · cobertura X%
Problemas / desvios da SPEC: … (numerados, com arquivo:linha)
Precisa do usuário: … (ex.: aprovar permissão, ouvir áudio)
```
