# Vela Mac (`vela-macd`)

Kleiner Begleiter für den eigenen Mac. Er bleibt im lokalen Netz: Bonjour `_vela._tcp`, HTTP und ein kleines WebSocket auf Port 8741. Kein Cloud-Relay.

## Start

```bash
cd MacCompanion
swift build -c release
cp .build/release/vela-macd /usr/local/bin/vela-macd
./.build/release/vela-macd
```

Der 6-stellige Kopplungscode steht im Terminal und in
`~/Library/Application Support/VelaMac/pairing-code.txt`.
In Vela unter **Einstellungen › Mac-Verbindung** den Mac wählen und den Code eingeben.
Danach gilt ein gemeinsames Token. Jede Anfrage trägt Zeitstempel und HMAC-SHA256
(`X-Vela-Timestamp`, `X-Vela-Signature`). `--repair` verwirft das Token und zeigt einen neuen Code.

Autostart: `LaunchAgents/de.barczewski.vela.macd.plist` nach `~/Library/LaunchAgents/` kopieren und
`launchctl load` ausführen. Der Pfad in der plist muss auf das Binary zeigen.

## Berechtigungen (macOS)

| Fähigkeit | Systemdialog |
|---|---|
| Apps öffnen, Lautstärke, Medien, laufende Apps | keine extra Freigabe |
| Kurzbefehle, erlaubte AppleScripts | Automation (System Events / Kurzbefehle) |
| Tastatureingabe | Bedienungshilfen |
| Bildschirmfoto | Bildschirmaufnahme |
| Zwischenablage | keine, aber in Vela als heikle Aktion bestätigt |

AppleScripts laufen nur nach Namen aus `~/Library/Application Support/VelaMac/scripts/<Name>.scpt`.
Es wird kein Skripttext vom iPhone angenommen. Heikle Aktionen (URL, Skript, Kurzbefehl, Tippen, Screenshot, Zwischenablage) führt das iPhone erst nach einer Rückfrage aus, und nur wenn die Berechtigung auf dem Mac an ist.

Standard an: App öffnen, Lautstärke, Medien, laufende Apps. Der Rest ist aus, bis er in den Einstellungen eingeschaltet wird.
