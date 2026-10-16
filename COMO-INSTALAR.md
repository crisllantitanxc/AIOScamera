# AIOScamera — como instalar no iPhone (sem Mac)

## 1. Compilar no GitHub (uma vez, ~10 min)
1. Crie uma conta grátis em github.com.
2. Clique em **New repository**, dê o nome `AIOScamera`, deixe **Public** (assim a compilação no Mac da nuvem é grátis e ilimitada) e crie.
3. Na página do repositório, clique em **uploading an existing file** e arraste **todo o conteúdo** desta pasta (incluindo a pasta `.github`). Clique em **Commit changes**.
   - No Windows a pasta `.github` pode ficar oculta: no Explorador, ative *Exibir > Itens ocultos* antes de arrastar.
4. Abra a aba **Actions**. A compilação "Gerar IPA" começa sozinha (se pedir, clique em *I understand… enable*). Leva uns 5–8 minutos.
5. Quando ficar verde, clique nela e baixe **AIOScamera-ipa** em *Artifacts*. Dentro do zip está o `AIOScamera.ipa`.
   - Se ficar vermelho, copie o erro e me mande que eu corrijo.

## 2. Instalar pelo Windows
1. Instale o **iTunes** e o **iCloud** baixados do site da Apple (não use a versão da Microsoft Store).
2. Instale o **Sideloadly** (sideloadly.io).
3. Conecte o iPhone no PC pelo cabo e toque em *Confiar*.
4. Abra o Sideloadly, arraste o `AIOScamera.ipa`, digite seu Apple ID e clique em **Start**.
5. No iPhone:
   - **Ajustes > Privacidade e Segurança > Modo de Desenvolvedor** → ativar e reiniciar.
   - **Ajustes > Geral > VPN e Gerenciamento de Dispositivo** → toque no seu Apple ID → *Confiar*.

## 3. A cada 7 dias
Com Apple ID grátis o app expira em 7 dias. É só abrir o Sideloadly e repetir o passo 4 com o mesmo `.ipa` (seus dados do scout continuam no iPhone).

## O que tem no app
- **Medidor**: Kelvin, tint e EV ao vivo pela câmera do iPhone. Converte para a Sony a6700: WB em Kelvin + G-M, ISO pelo ISO base do perfil (S-Log3 800, S-Cinetone 100) e o ND necessário. Toque na imagem para medir um ponto (spot).
- **Visor**: o quadro exato da a6700 com a lente escolhida (crop APS-C e 4K120), proporção de entrega (16:9, 2.39, 4:5, 9:16…) e foto do quadro para o scout.
- **Sol**: sol e caminho dele em realidade aumentada, mapa do dia, golden hour e blue hour.
- **Scout**: locações com GPS, medições, fotos do visor, horários do sol e notas, exportando PDF.
- **Ferramentas**: detector de flicker (teste de obturador para rede 60 Hz), gelatinas CTO/CTB, profundidade de campo e calibração com a sua a6700.

## Calibrar (recomendado, 2 minutos)
Ferramentas > Câmera e calibração. Faça um WB personalizado num papel branco na a6700, meça o mesmo papel no Medidor e ajuste o offset até bater.
