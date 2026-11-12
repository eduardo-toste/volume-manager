# Política de segurança

## Reportar uma vulnerabilidade
**Não abra uma issue pública** para falhas de segurança. Use um destes canais privados no GitHub:

1. **Security Advisories** (preferido): na página do repositório,
   <https://github.com/eduardo-toste/volume-manager>, aba **Security › Report a vulnerability**.
2. Se isso não estiver disponível, abra uma issue pedindo apenas um contato privado, **sem detalhes
   técnicos** na issue; os detalhes seguem depois por canal privado.

Inclua: versão do app (Ajustes › Sobre), versão do macOS, passos para reproduzir e o impacto que
você enxerga. Não envie amostras de áudio nem dados pessoais.

## O que o projeto considera falha de segurança
Qualquer coisa que permita gravar, copiar ou enviar áudio; fazer conexões de rede; herdar a
permissão de áudio do app por código externo; distribuir um app que não seja o do
mantenedor (confira o SHA-256 do download); ou adulterar o download. Modelo de ameaças completo: `docs/SPEC.md` §12.9.

## Versões suportadas
Apenas a versão mais recente publicada em
<https://github.com/eduardo-toste/volume-manager/releases>.

## Download seguro
Baixe **somente** do repositório oficial acima e confira o SHA-256 (veja o `README.md`).
