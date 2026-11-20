# AI Usage

App de barra de menus do macOS que mostra o uso dos planos de IA:

- **◐ Claude**: % da sessão de 5h. O menu mostra Sessão (5h), Semana e, se houver, Opus e Sonnet, cada um com o horário em que reseta.
- **✦ Antigravity (Gemini)**: % do limite mais perto de acabar. O menu mostra cada grupo de modelos com Sessão (5h) e Semana.

Atualiza automaticamente a cada 5 min. O botão "↻ Atualizar agora" atualiza sem fechar o menu.

App nativo em Swift/AppKit, em um arquivo só. Não usa Xcode nem Electron.

## Build

```bash
bash build.sh
```

O script compila `main.swift`, monta `build/AI Usage.app` e instala o app em `/Applications`. Depois do build, feche o app (Sair) e abra de novo.

## De onde vêm os dados

| Serviço | Fonte | Autenticação |
|---|---|---|
| Claude | `GET https://api.anthropic.com/api/oauth/usage` (header `anthropic-beta: oauth-2025-04-20`) | Token OAuth do Claude Code, lido do Keychain (`Claude Code-credentials`) via `/usr/bin/security` |
| Antigravity | `POST http://127.0.0.1:<httpPort>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary` | `csrfToken` e porta lidos de `~/.gemini/antigravity/daemon/hub_*.json`, usando só o arquivo cujo `pid` está vivo |

As duas APIs são **internas e não documentadas** e podem mudar sem aviso. Os dados do Antigravity só aparecem com ele aberto.

Os tokens ficam só na memória. O app não os grava e não os envia para nenhum outro lugar.

## Estrutura

```
main.swift          # app inteiro (provedores Claude e Antigravity, barra de menus, tela USB)
Info.plist          # bundle "AI Usage", LSUIElement (sem ícone no Dock)
build.sh            # compila, empacota, assina ad-hoc e instala em /Applications
firmware/           # firmware da tela USB (PlatformIO + LVGL)
icon/
  make_icon.swift   # desenha o ícone (gera icon_1024.png)
  AppIcon.icns      # ícone usado pelo app
```

### Regerar o ícone

```bash
cd icon && swift make_icon.swift
mkdir AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s icon_1024.png --out AppIcon.iconset/icon_${s}x${s}.png
  sips -z $((s*2)) $((s*2)) icon_1024.png --out AppIcon.iconset/icon_${s}x${s}@2x.png
done
iconutil -c icns AppIcon.iconset -o AppIcon.icns && rm -rf AppIcon.iconset
cd .. && bash build.sh
```

## Tela USB (Waveshare ESP32-S3-Touch-LCD-7)

O app também envia o uso para uma tela touch de 7" ligada ao Mac por cabo USB. O firmware fica em `firmware/`.

### Gravar o firmware

1. Instale a extensão **PlatformIO IDE** no VS Code.
2. Abra a pasta `firmware/` no VS Code (*File → Open Folder*).
3. Ligue a placa pela porta **UART** com um cabo USB-C **de dados**.
4. Clique em *Upload* (→) na barra do PlatformIO, ou rode `pio run -t upload` na pasta `firmware/`.

Pela linha de comando, sem o VS Code, o equivalente é `pio run -t upload`.

### Uso

Deixe a placa ligada no Mac, em qualquer uma das duas portas, com o app AI Usage aberto. O app encontra a placa sozinho em até 2 s e reconecta se o cabo sair. Quando a placa está ligada, o menu mostra "Tela USB: conectada". O botão **Atualizar** da tela atualiza os dois serviços.

### Protocolo

É um objeto JSON por linha, a 115200 baud:

| Direção | Mensagem |
|---|---|
| Placa → Mac | `{"t":"hello"}` a cada 1 s até o Mac responder |
| Placa → Mac | `{"t":"press","id":"refresh"}` quando alguém toca num botão |
| Mac → Placa | `{"t":"usage","providers":[{"name","pct","err","busy","at","rows":[{"sec","label","pct","reset"}]}]}` |
| Mac → Placa | `{"t":"ping"}` a cada 2 s. Se a placa ficar 8 s sem receber nada, volta a mostrar "Aguardando o Mac..." |

O app testa as portas `/dev/cu.usbmodem*`, `cu.usbserial*` e `cu.wchusbserial*`. Uma porta que não responde `hello` em 6 s é ignorada até ser desconectada. Os textos chegam sem acentos porque as fontes da placa só têm ASCII.

Para testar sem a placa, use `AI_USAGE_SERIAL=/dev/ttysNNN` para apontar o app para um pty.
