# Assinatura do Volume Manager (certificado próprio)

> **Opcional.** A v1 sai com assinatura ad hoc, sem certificado (SPEC §13.2): cada versão pede a
> permissão de áudio de novo. Este guia continua válido para quando você quiser um certificado e
> manter a permissão entre versões.

O app não usa conta de desenvolvedor da Apple. Em vez disso, o mantenedor cria **um certificado
autoassinado de assinatura de código** no próprio Mac e assina os releases localmente (SPEC §13.2,
§12.9.5). Isto é feito **por você, à mão**; os scripts e agentes nunca criam certificado nem mexem
no Acesso às Chaves.

## Por que isto importa
O macOS guarda a permissão de áudio ligada à **identidade de assinatura** do app (o *designated
requirement*). Com assinatura ad hoc, a identidade muda a cada build e a permissão é esquecida a
cada versão. Com o mesmo certificado em todos os builds, a identidade é a mesma e a permissão é
mantida ao atualizar.
Obs.: a marca do app é ligada ao build (`CFBundleVersion`), então o aviso “Permitir…” ainda aparece uma vez por versão e se resolve no clique, sem novo pedido do sistema.

## 1. Criar o certificado
1. Abra **Acesso às Chaves** (Keychain Access).
2. Menu **Acesso às Chaves › Assistente de Certificado › Criar um Certificado…**
3. Nome: `Volume Self-Signed` (ou outro; anote exatamente).
4. Tipo de identidade: **Autoassinado**. Tipo de certificado: **Assinatura de Código**.
5. Marque **Permitir substituir os padrões** e avance até o fim se quiser prazo longo: em
   *Período de validade* use, por exemplo, 3650 dias (10 anos). Um certificado vencido não invalida
   builds já assinados, mas você precisaria de um novo para assinar, e **um novo certificado muda a
   identidade** (ver "Se o certificado mudar").
6. Mantenha o chaveiro **login** como destino e conclua.

## 2. Achar o nome para `VOLUME_SIGN_IDENTITY`
```
security find-identity -p codesigning
```
Autoassinados podem aparecer como "não confiáveis" nesta listagem; o `codesign` ainda assina com
eles. Use o **nome entre aspas** (ex.: `Volume Self-Signed`) ou o hash SHA-1 de 40 caracteres:
```
export VOLUME_SIGN_IDENTITY="Volume Self-Signed"
scripts/build-app.sh
```
Na primeira assinatura o macOS pode pedir a senha do chaveiro para a chave: use "Permitir"
(não "Sempre permitir" se preferir ser perguntado a cada vez).

## 3. Conferir a identidade estável
```
codesign -d -r- "build/Volume Manager.app"
```
Deve mostrar `designated => identifier "com.volumemanager.app" and certificate leaf = H"…"`. Esse
requisito é o mesmo em qualquer build assinado com o mesmo certificado (o `build-app.sh` recusa a
build se aparecer `cdhash`, que é o sinal de assinatura ad hoc). Anote o valor do hash do
certificado: ele é a identidade do app.

## Avisos
- **Nunca exporte a chave privada** (`.p12`, `.pem`, `.key`) para dentro do repositório, do
  GitHub, de CI, de nuvem sem criptografia ou de mensagens. O `.gitignore` e o `security-check.sh`
  bloqueiam esses arquivos, mas a proteção real é você não os criar. Regra 12 do projeto.
- **Backup**: se quiser backup, exporte a chave só para um `.p12` com senha forte, guardado
  **offline** (pen drive criptografado, gerenciador de senhas). Sem backup, perder o Mac = perder a
  identidade. Esse arquivo fica fora de qualquer pasta do projeto.
- Quem tiver a chave privada pode assinar um app falso que **herda a permissão de áudio** dos
  usuários. Trate-a como uma senha.
- **Se o certificado mudar** (perdido, vencido, recriado): o app assinado com o novo certificado
  tem outra identidade; o macOS trata como outro app e a permissão de áudio deve ser concedida de
  novo por todos os usuários (e as marcas de permissão salvas ficam velhas). Evite trocar; se for
  inevitável, avise nas notas do release.
- Sem `VOLUME_SIGN_IDENTITY` (ou com `-`), o release sai ad hoc e o `release.sh` avisa.
