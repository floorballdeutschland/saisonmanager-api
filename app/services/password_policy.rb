# frozen_string_literal: true

# Regeln für selbst gewählte Passwörter, an einer Stelle.
#
# Gilt überall dort, wo ein Mensch ein Passwort setzt: „Mein Konto" (Passwort
# ändern) und die Seite hinter dem Zurücksetzen-Link. Nicht betroffen sind die
# zufälligen Initialpasswörter, die beim Anlegen eines Kontos erzeugt werden und
# nie getippt werden; sie werden über den Zurücksetzen-Link ersetzt und laufen
# dann durch diese Prüfung.
#
# Das Frontend spiegelt REQUIREMENTS als Live-Prüfliste unter den
# Passwortfeldern, damit die Anforderungen vor dem Absenden sichtbar sind und
# nicht erst als Fehlermeldung danach.
class PasswordPolicy
  MIN_LENGTH = 12

  REQUIREMENTS = "Das Passwort muss mindestens #{MIN_LENGTH} Zeichen lang sein und mindestens " \
                 'einen Großbuchstaben sowie eine Ziffer enthalten.'.freeze

  def self.satisfied?(password)
    password = password.to_s

    password.length >= MIN_LENGTH && password.match?(/[[:upper:]]/) && password.match?(/\d/)
  end

  # nil, wenn das Passwort passt, sonst die fertige Meldung für die Antwort.
  def self.error_for(password)
    REQUIREMENTS unless satisfied?(password)
  end
end
