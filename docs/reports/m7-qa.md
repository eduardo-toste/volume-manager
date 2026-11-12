## Etapa M7 — QA
Resultado: PASS (com itens pendentes do certificado e do usuário, listados abaixo)

O que foi feito: QA independente da distribuição (commit 96006f0, branch etapa/m7), sem alterar `Sources/`, sem abrir o app, sem som, sem rede.
- `scripts/check.sh` do zero: 180 testes verdes, lint, `security-check` e checks do bundle OK.
- `release.sh`, recusas (todas confirmadas, exit 1, sem alterar o repo): sem argumento; versão inválida (`1.0`, `1.0.0; ls`); sem `VOLUME_SIGN_IDENTITY`; `VOLUME_SIGN_IDENTITY=-` fora do modo de teste; sem tag `v1.0.0`; tag `v2.0.0` com `Resources/Version`=1.0.0; tag `v0.9.0` fora do HEAD; árvore suja (arquivo rastreado modificado e arquivo não rastreado), testado numa cópia no scratchpad.
- `VOLUME_RELEASE_UNSIGNED_TEST=1 scripts/release.sh 1.0.0` com tag local temporária: OK. Gerou `dist/Volume-Manager-1.0.0-UNSIGNED-TEST.{dmg,zip}` e `SHA256SUMS`. `dist/` é ignorado pelo git (`git check-ignore dist`).
- DMG montado (somente leitura, `-nobrowse`, scratchpad): contém `Volume Manager.app`, atalho `Applications -> /Applications` e `.background/background.png` (1200x800); `hdiutil verify` VALID; `shasum -a 256 -c SHA256SUMS` OK; Info.plist 1.0.0 / build 1 = `Resources/Version`; `codesign --verify --strict --deep` OK, `flags=0x10002(adhoc,runtime)`, entitlements vazios (`[Dict]`); `VOLUME_APP=<app do DMG> scripts/security-check.sh --app` OK; zip sem `vmctl`; binário arm64. Adulterar 1 byte do DMG faz o `shasum -c` falhar (rc=1); `--ignore-missing` do README funciona (OK com só o DMG presente).
- Imagem `docs/images/install-dmg.png` e fundo gerado batem com a instrução da SPEC §13.1 (seta, "Arraste o Volume Manager para Aplicativos", "Na primeira vez: ... Abrir Mesmo Assim").
- Revisão estática: `build-app.sh` usa `VOLUME_SIGN_IDENTITY` (padrão `-` só dev), `--options runtime`, entitlements do repo, recusa requisito com `cdhash` quando a identidade é real e exige `identifier "com.volumemanager.app" and ...`; sem rede/instalação/download nos scripts; `release.sh` não faz upload. Com ad hoc, `codesign -d -r-` mostra `cdhash H"..."` (esperado, documentado nos scripts e em SIGNING.md).
- README/SIGNING/RELEASE/SECURITY contra SPEC §13.3: passo a passo, "Abrir Mesmo Assim", `xattr -dr com.apple.quarantine "/Applications/Volume Manager.app"`, conferência de SHA-256, requisitos macOS 15+, atualização; nomes `Volume-Manager-<versão>.dmg/.zip` e `SHA256SUMS` batem com o que o `release.sh` gera. "Ver versões no GitHub" existe em `Sources/VolumeManager/Composition.swift:151`.
- Risco M-1 (macOS atual, 27): `dyld_info -exports /usr/lib/system/libquarantine.dylib | grep responsibility_get_pid_responsible_for_pid` retorna `0x00000898 _responsibility_get_pid_responsible_for_pid`; `nm -m` no binário mostra `(undefined) weak external _responsibility_get_pid_responsible_for_pid (from libSystem)`, exatamente o esperado. O símbolo não está em `libsystem_kernel` (0 ocorrências), como o RELEASE.md já diz.

Como verificar: `scripts/check.sh`; `git tag v1.0.0 && VOLUME_RELEASE_UNSIGNED_TEST=1 scripts/release.sh 1.0.0` (depois `git tag -d v1.0.0; rm -rf dist`); `hdiutil attach -readonly -nobrowse -mountpoint <dir> dist/*.dmg`.

Verificações: check.sh ✓ · security-check ✓ (fonte e `--app` no app de dentro do DMG) · cobertura: não aplicável (M7 não muda código Swift)

Problemas / desvios da SPEC (nenhum bloqueante):
1. Baixa: SPEC §13.1 e PLAN M7 dizem `Volume-<versão>.dmg`; o script gera `Volume-Manager-<versão>.dmg` (README, RELEASE.md e SECURITY coerentes entre si). Sugestão: ajustar a SPEC/PLAN (ou o nome) na M8; sem impacto funcional.
2. Baixa: build publicado é só arm64 (README declara); a SPEC §12 cita meta de CPU para Intel. Decisão do usuário a confirmar; sem mudança de código necessária.
3. Informativa: `hdiutil attach -mountpoint` imprime aviso de depreciação (`diskutil image attach`); funciona hoje. Observar em macOS futuros.
4. Proporcionalidade: sem código morto nem abstração desnecessária nos scripts; `make-dmg-background.swift` tem um só uso, mas é pedido pela SPEC (fundo com instrução visual). OK.
5. Sem alteração em Tests/ (a M7 é só scripts/docs; as recusas foram verificadas por execução e não há como testá-las em Swift sem duplicar o script).

Pendente do certificado / do usuário (não são FAIL):
- Requisito designado estável entre duas builds assinadas com o mesmo certificado (esperado `identifier "com.volumemanager.app" and certificate leaf = H"..."`; o `build-app.sh` já recusa `cdhash` quando há identidade real).
- Release assinado de verdade (`VOLUME_SIGN_IDENTITY="<cert>" scripts/release.sh 1.0.0`) e a tag assinada `git tag -s` (SPEC §12.9.6).
- Layout do Finder do DMG (osascript: fundo, posições, `.DS_Store`): só roda fora do modo de teste; pode pedir permissão do Terminal para controlar o Finder. Conferir a janela ao abrir o DMG real.
- Passo manual (⏸4): app abre a partir do DMG instalado numa pasta de teste; versão no Ajustes › Sobre = 1.0.0; fluxo "Abrir Mesmo Assim" (QA NÃO abriu o app).
- Risco M-1 no macOS 15 (`dyld_info -exports` numa máquina/VM com macOS 15).
- Conferir a conta GitHub: 2FA e proteção da `main` (§12.9.6); SHA-256 conferido como usuário após o upload.

Estado final: `git status` limpo exceto este relatório; tag `v1.0.0` removida (nenhuma tag local); nenhum volume montado; `dist/` removido (e ignorado pelo git).
