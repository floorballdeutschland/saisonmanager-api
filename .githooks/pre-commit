#!/bin/sh
# Sucht mit gitleaks (https://github.com/gitleaks/gitleaks) in den gestagten
# Änderungen nach Geheimnissen. Regeln: .gitleaks.toml, geprüfte Altfunde:
# .gitleaksignore. Die CI prüft zusätzlich die ganze Historie.
#
# Ohne installiertes gitleaks wird nur gewarnt, damit niemand blockiert ist:
#   brew install gitleaks
# Ein Fehlalarm lässt sich einmalig mit `git commit --no-verify` umgehen;
# dauerhaft gehört er als enge Allowlist in .gitleaks.toml.

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "gitleaks nicht installiert, Geheimnis-Prüfung übersprungen (brew install gitleaks)" >&2
  exit 0
fi

exec gitleaks git --pre-commit --staged --redact --no-banner --verbose
