## Etapa M0 — QA
Resultado (volta 0): **FAIL**; ver "Reavaliação 1" abaixo (PASS) (nenhum problema no produto M0 em si; falha por "verificação que não falha quando deveria": itens 1-3 abaixo, todos corrigíveis em `scripts/` / `.swift-format` em minutos)

### O que foi feito
- Do zero (`rm -rf .build build`): `scripts/check.sh` OK (lint estrito, build, 31 testes, security-check), `scripts/build-app.sh` OK, `scripts/security-check.sh --app` OK. Sem avisos além do filtro `ld: search path`.
- `build/Volume.app`: `codesign --verify --strict --deep` OK; `flags=0x10002(adhoc,runtime)`; entitlements vazios (nenhuma chave proibida); Info.plist: Volume, `com.volumemanager.app`, `LSUIElement`, `LSMinimumSystemVersion 15.0`, só `NSAudioCaptureUsageDescription`, versão 1.0.0/1; só `Contents/MacOS/VolumeManager` (sem `vmctl`, sem Frameworks/dylib); `otool -L` só `/System` e `/usr/lib`. App aberto 5 s: `lsappinfo` mostra `type="UIElement"` (sem Dock); encerrado, `pgrep` vazio. Nenhum áudio tocado.
- Injeção temporária e reversão (arquivos salvos no scratchpad antes; para o bundle, só cópias) de ~110 violações no `security-check.sh` e no teste de arquitetura. Árvore verificada idêntica (git status + shasum de 27 arquivos) após cada bloco.
- Revisão de código (§12.3), CI (§12.9.6) e escopo.
- Testes adicionais: `Tests/VolumeCoreTests/RepositoryPolicyTests.swift` (13 testes: Info.plist, entitlements, catálogo, workflow por SHA/permissions/sem `pull_request_target`/sem secrets, manifesto sem dependência extra e `VolumeUI` sem `VolumeAudio`/`VolumeSystem`, sem `try!/as!/print/force unwrap/Network/TODO/código comentado` em `Sources/`, C só em `CSystemShims`, build-app nunca toca `vmctl`). Passam; mutação confirmou que falham quando a regra é violada. Passam no lint estrito.

### Como verificar
```
rm -rf .build build && scripts/check.sh && scripts/build-app.sh && scripts/security-check.sh --app
open -g build/Volume.app; lsappinfo list | grep -A6 volumemanager   # type="UIElement"
```

### security-check: PEGOU (exit 1) em
URLSession, NWConnection, `import Network`, `socket(`, CFSocket, dlopen, dlsym, NSAppleScript, `Process(`, `system(`, `Darwin.system(`, popen, AudioFileCreate, ExtAudioFile, AVAudioRecorder, AVAudioFile, `print(` (Core e VolumeUI; vmctl permitido corretamente), `try!`, `as!`, `@_silgen_name`, Logger sem privacy (linha única e multilinha; com privacy passa), `.c/.h/.m` fora de CSystemShims (Core, Audio, Tests, scripts), declaração extra no header do shim, dependência diferente, `from:` (não exata), 2 dependências em linhas separadas, `.package(path:)`, Package.resolved com pin sem dependência, KeyboardShortcuts sem Package.resolved, os 6 entitlements proibidos (fonte e bundle assinado), sem Hardened Runtime, bundle adulterado, `vmctl` em MacOS/ e Resources/, dylib/Frameworks, NSMicrophone/NSCamera UsageDescription (fonte e bundle), ausência de NSAudioCaptureUsageDescription, lib fora do sistema (`otool`), bundle inexistente com `--app`, chave privada/token em texto, `.p12`.
Teste de arquitetura PEGOU: `VolumeCore` importando AppKit/CoreAudio/SwiftUI (também `@testable`, `import struct`, `Darwin.POSIX`, `;` na mesma linha), `VolumeUI` importando VolumeAudio/VolumeSystem/CoreAudio, `VolumeAudio`→VolumeUI, `VolumeSystem`→VolumeAudio.

### Problemas
1. **ALTO (verificação não falha)** `scripts/security-check.sh` (contagem de dependências, `grep -cE '\.package\('`): conta LINHAS. Duas dependências na mesma linha de `Package.swift` contam como 1; com KeyboardShortcuts exata + outra na mesma linha e `Package.resolved` só com KeyboardShortcuts, o script sai 0 (reproduzido). Esperado: contar ocorrências (`grep -o`) ou parsear `swift package dump-package`.
2. **MÉDIO (verificação não falha)** Force unwrap (`x!`) é proibido pela §12.3 e CLAUDE.md regra 8, mas nenhum mecanismo o barra: `.swift-format` tem `NeverForceUnwrap: false` e `NeverUseForceTry: false`, e o script não procura. Injetei `Optional(1)!` e `check` passa. Esperado: ligar `NeverForceUnwrap`/`NeverUseForceTry` (ou regra no script). (Meu `sourcesHaveNoForceUnwrap` cobre o estado atual, mas é heurístico.)
3. **MÉDIO (evasões triviais)** `print (` com espaço, `try !`, `as !`, `debugPrint`, `NSLog`, `Logger` em variável com outro nome (`log.info("\(n)")`) ou `os.Logger(...).info(...)` passam. Esperado: padrões com `\s*` e detecção de Logger independente do nome da variável (§12.9.7 itens 3 e 8).
4. **MÉDIO (cobertura de CI)** `check.sh` (e portanto o CI) roda `security-check.sh` SEM `--app` e sem bundle: as verificações de binário (itens 1, 2, 5, 6 do §12.9.7) são apenas puladas com `warn`. O CI não executa `build-app.sh`. Esperado: CI rodar `build-app.sh` + `security-check.sh --app` (ou `check.sh` construir o app).
5. **BAIXO** A checagem de `weak_import` no header do shim usa `grep -q weak_import`, satisfeita pelo comentário `/// ... weak_import`; remover o atributo mantendo o comentário passa (reproduzido). Idem: `.c` adicionado dentro de `CSystemShims` não é barrado (shim sem lógica só é garantido por convenção). Esperado: grep em `__attribute__((weak_import))` fora de comentários; proibir `.c` com conteúdo além do vazio.
6. **BAIXO (§12.3)** APIs públicas sem `///`: `Sources/VolumeCore/AppVersion.swift:3-5,7,15,28,30` (major/minor/patch, inits, description, `<`) e `Sources/VolumeUI/MenuBarPopover.swift:5,7`. Não adicionei teste para não quebrar o portão; o Dev deve documentar.
7. **INFO** Os testes imprimem `Target Platform: arm64e-apple-macos14.0` (runner do Swift Testing); o pacote declara `.macOS(.v15)` e o app tem `LSMinimumSystemVersion 15.0`. Sem impacto. `swiftLanguageModes: [.v6]` e `-warnings-as-errors` só em release (debug protegido pelo `run_strict`).

### Conferido sem problemas
- CI: `permissions: contents: read`, checkout fixado por SHA `d23441a…` (confere com a tag `v6.1.0` via `git ls-remote`), `persist-credentials: false`, sem secrets, sem `pull_request_target`.
- §12.3 em `Sources/`: sem `try!`/`as!`/force unwrap/`print` (exceto vmctl)/TODO/código comentado; nomes e arquivos < 300 linhas.
- Escopo: nenhuma lógica de áudio/mixer, nenhuma rede, nenhuma permissão extra, nenhuma dependência (KeyboardShortcuts removida, decisão registrada). `CSystemShims` só com `weak_import` de `responsibility_get_pid_responsible_for_pid` e `shims.c` só com comentário. `vmctl` é um stub de uso; não vai no bundle.
- Higiene: `.gitignore` cobre build/segredos; nenhum segredo no repositório.

Verificações: check.sh ✓ · security-check ✓ (mas ver problemas 1-5) · cobertura: n/a (VolumeCore só tem modelos de M0)
Precisa do usuário: nada. Estado final: árvore igual à inicial (exceto `Tests/VolumeCoreTests/RepositoryPolicyTests.swift` e este relatório); `build/` e `.build/` regenerados (ignorados pelo git); nenhum processo do app rodando.

---

## Reavaliação 1 (volta 1/3)
Resultado: **PASS**

Do zero (`rm -rf .build build && scripts/check.sh --app`): lint estrito, build, 32 testes, security-check, build-app e `security-check --app` verdes; sem avisos além do filtro `ld`. Injeções feitas com backup e revertidas (hash de 27 arquivos idêntico; só mudou meu teste). Nenhum áudio, nenhum processo restante.

Status dos problemas anteriores
1. Dependências: CORRIGIDO. Duas na mesma linha, em linhas separadas, só a outra, `from:`, `.package(path:)`, lista indireta via variável, manifesto quebrado: todos saem 1; KeyboardShortcuts exata + Package.resolved correto passa (esperado).
2. Force unwrap/try/IUO: CORRIGIDO. `swift format lint --strict` falha em `x!`, `(b)!.c`, `try!`, `as!`, `Int!` e `[Int]!` em `Sources/`. (Em `Tests/` o lint não barra `!`, o que a §12.3 permite.)
3. Evasões: CORRIGIDO para `print (`, `print(` multilinha, `try !`, `as !`, `debugPrint`, `NSLog`, `dump(`, Logger com qualquer nome (`log`, `audioLog`, `os.Logger(...)`, `.log(level:)`), multilinha com privacy parcial; com privacy completa passa.
4. `check.sh --app` e CI: CORRIGIDO. `--app` roda build-app + security-check --app; o CI roda `check.sh`, `build-app.sh` e `security-check.sh --app`. Bundle: entitlement `allow-jit`, sem Hardened Runtime, `vmctl`, UsageDescription extra: todos saem 1; bundle original passa.
5. Shim C: CORRIGIDO. Remover `__attribute__((weak_import))` mantendo o comentário falha; lógica no header e função em `shims.c` falham.
6. Docs `///`: CORRIGIDO (nenhuma API pública sem doc). Adicionei `publicDeclarationsAreDocumented` em `RepositoryPolicyTests` (14 testes ali); removendo um `///` o teste falha.

Novas evasões remanescentes (BAIXO, não bloqueantes: exigem escrita deliberada e o lint/revisão ainda as pegam em parte)
- `Swift.print("x")`, `let f = print` (referência sem parêntese) e `(try)!` passam (o padrão exclui `.` antes de `print`). Recomendo permitir o prefixo `Swift.` no regex.
- `fputs`/`FileHandle.standardOutput.write`, `posix_spawn`, `NSTask`, `NSURLConnection`, `import CFNetwork`/CFStream não estão na lista do §12.9.7; sugiro incluí-los na lista proibida (rede/execução externa) numa próxima rodada.
