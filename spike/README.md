# spike — vmctl (M0.5, prova de viabilidade)

Pacote SwiftPM separado, descartável/reaproveitável. Zero dependências externas. macOS 14.2+, Swift 6.

## Compilar e testar
```
cd spike
swift build
swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```
(O `-plugin-path` é necessário só porque, com Command Line Tools sem Xcode, o plugin de macros do Swift Testing não é achado sozinho.)
Binário: `.build/debug/vmctl` (ou `swift run vmctl …`). Os avisos `ld: warning: search path … not found` vêm do toolchain (CLT), não do código.

## Comandos
```
vmctl processes                      # processos de áudio + dono resolvido + visão agrupada
vmctl devices                        # saídas: ID, UID, nome, padrão, volume por software
vmctl master [0..1]                  # lê (ou define) o volume do dispositivo padrão
vmctl set <bundleID> --volume 0.3 [--mute] [--device <UID>] [--duration 30]
vmctl stress-taps <n> [--app <bundleID>]
```
Alvos de teste: `<bundleID>` do dono do app (ex.: `com.spotify.client`, `com.apple.Safari`, `com.google.Chrome`, `com.hnc.Discord`)
ou `pid:<N>` (só no spike, para tons de teste como `afplay`).

## Roteiro para o ⏸0 (com música/vídeo tocando)
1. Toque algo (Spotify, vídeo no Safari/Chrome/YouTube). Em outro terminal, na pasta `spike`:
2. `.build/debug/vmctl processes` — confira que a visão agrupada mostra o app como `[PLAYING]` e use o bundle ID mostrado.
3. `.build/debug/vmctl set com.spotify.client --volume 0.3 --duration 20` — só o Spotify deve baixar; outros apps seguem iguais.
4. `.build/debug/vmctl set com.apple.Safari --volume 1 --mute --duration 15` — só o Safari fica mudo (inclui o WebKit GPU).
5. `.build/debug/vmctl set com.google.Chrome --volume 0.5 --device BuiltInSpeakerDevice --duration 15` — troca de saída só desse app (use um UID de `vmctl devices`).
6. `.build/debug/vmctl stress-taps 30` — deve terminar com `PASS: no leaked aggregate devices`.
Na primeira criação de tap o macOS pode pedir permissão de "Gravação de Áudio do Sistema" para o Terminal: aprovar uma vez.
Ouça: mudou só no app certo? Estalo ao iniciar/parar? Atraso perceptível?

## Como restaurar o som
- O tap vive só enquanto o `vmctl set` roda: fim do `--duration` ou **Ctrl+C** (SIGINT/SIGTERM destroem IOProc, aggregate e tap, nessa ordem) devolvem o som original.
- Se o processo morrer de qualquer forma, o macOS destrói o tap e o som volta sozinho.
- Watchdog: sem frames por 2 s com o app ainda tocando, o tap é destruído e o som original volta (com aviso).
- O volume geral do sistema só muda com `vmctl master <valor>` (anote o valor antes: `vmctl master`).
