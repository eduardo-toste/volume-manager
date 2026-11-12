# Roteiro de release

Pré-requisitos: branch `main` com tudo integrado e `scripts/check.sh --app` verde. Nada aqui usa
rede; o upload é manual. A v1 sai **sem certificado** (assinatura ad hoc, SPEC §13.2): não exporte
`VOLUME_SIGN_IDENTITY`. O certificado é opcional e futuro: veja `docs/SIGNING.md`.

## 1. Preparar a versão
1. Em `Resources/Version`: `VERSION=<x.y.z>` e `BUILD=<inteiro maior que o anterior>`.
2. Commit (`Release x.y.z`). Árvore limpa.
3. Tag **anotada** no commit atual: `git tag -a v<x.y.z> -m "Volume Manager <x.y.z>"` (SPEC
   §12.9.6; o `release.sh` recusa tag leve ou fora do HEAD).

## 2. Gerar os artefatos
```
scripts/release.sh <x.y.z>
```
Sem `VOLUME_SIGN_IDENTITY` o script assina ad hoc e avisa no terminal. O script recusa rodar com
mudanças não commitadas, sem uma tag anotada apontando para o HEAD ou se a versão não for a de
`Resources/Version`. Ele gera em `dist/`:
`Volume-Manager-<x.y.z>.dmg`, `Volume-Manager-<x.y.z>.zip` e `SHA256SUMS`, e já roda
`scripts/security-check.sh --app` contra o `.app` de dentro do DMG montado.
Na primeira vez o macOS pode pedir que o Terminal controle o Finder (layout da janela do DMG):
permita e rode de novo.

## 3. Conferências manuais
```
codesign -d -r- "build/Volume Manager.app"            # ad hoc: o requisito mostra cdhash (esperado na v1)
codesign -dv --verbose=4 "build/Volume Manager.app" 2>&1 | grep -E "flags|Authority|TeamIdentifier"
                                                      # flags=0x10000(runtime)
codesign -d --entitlements - "build/Volume Manager.app"   # vazio: nenhum entitlement
(cd dist && shasum -a 256 -c SHA256SUMS)
hdiutil verify dist/Volume-Manager-<x.y.z>.dmg
```
- **Nenhum entitlement** (SPEC §12.9.2): `security-check.sh --app` já falha se o app assinado tiver
  qualquer chave de entitlement. Confirme também a olho que a saída de
  `codesign -d --entitlements -` está vazia.
- Abra o DMG: janela com fundo "Arraste o Volume Manager para Aplicativos", ícone do app à
  esquerda, atalho Aplicativos à direita. Instale numa pasta de teste e abra.
- A versão em Ajustes › Sobre = `<x.y.z>`.
- **Permissão a cada versão**: instale a nova sobre a antiga; o app deve mostrar o aviso com
  "Permitir…" (a marca da versão anterior é descartada). Com certificado (opcional), o requisito
  designado é estável e o macOS mantém a permissão; o aviso ainda aparece uma vez por versão (a
  marca do app é ligada ao build) e se resolve no clique, sem novo pedido do sistema.

## 4. Risco M-1: `responsibility_get_pid_responsible_for_pid`
É a única API privada (SPEC §4.1, §12.9.2), ligada com `weak_import`. Confirme no macOS atual:
```
dyld_info -exports /usr/lib/system/libquarantine.dylib | grep responsibility_get_pid_responsible_for_pid
nm -m "build/Volume Manager.app/Contents/MacOS/VolumeManager" | grep responsibility_get_pid
# esperado: (undefined) weak external _responsibility_get_pid_responsible_for_pid (from libSystem)
```
(A função mora em `libquarantine`, reexportada pela `libSystem`; ela não está em
`libsystem_kernel`.) **Passo manual no macOS mínimo (15)**: numa máquina/VM com macOS 15, rode o
mesmo `dyld_info -exports` e abra o app com um app WebKit tocando; se o símbolo faltar o app segue
funcionando, só o agrupamento volta para a heurística. Registre o resultado nas notas do release.

## 5. Inspeção do `_withUnsafeGuaranteedRef` (thread de áudio)
Decisão registrada: o IOProc usa `Unmanaged...._withUnsafeGuaranteedRef` (sem retain/release).
Confirme no desmontado do binário **sem strip** (`swift build -c release` gera
`.build/release/VolumeManager`):
```
otool -tV .build/release/VolumeManager > /tmp/dis.txt     # (use a pasta temporária que preferir)
grep -n 'tapIOProc.*To:$' /tmp/dis.txt                    # início do IOProc
```
O corpo do IOProc deve ter um único `bl` para `RealtimeTapState...render...` e nenhum
`swift_retain`/`swift_release`/`swift_allocObject`/`objc_`/`malloc`. Depois liste as chamadas do
`render` (as linhas entre o rótulo `...RealtimeTapStateC6render5input6output...tF:` e o próximo
rótulo): só devem aparecer `bzero`/`memmove` (resultado de 2026-11-11, build da M7). O mesmo vale
para `SignalProbeState.scan`.

## 6. Publicar (manual)
1. Em <https://github.com/eduardo-toste/volume-manager/releases> crie a Release da tag
   `v<x.y.z>`.
2. Suba `dist/Volume-Manager-<x.y.z>.dmg`, `dist/Volume-Manager-<x.y.z>.zip` e `dist/SHA256SUMS`.
3. Cole o conteúdo de `SHA256SUMS` nas notas. Escreva o que mudou e avise que a
   permissão de áudio será pedida de novo (assinatura ad hoc).
4. Baixe o DMG da própria página e confira o SHA-256 como um usuário.
