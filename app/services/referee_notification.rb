# Eine Stelle für die Mails, die einen Schiedsrichter über Änderungen an seinen
# eigenen Daten unterrichten (Lizenz, Zusatzqualifikationen).
#
# Warum gebündelt: Die Auslöser liegen inzwischen an drei Orten — Schiri-Maske
# (referees#update), Kursimport-Submit und LV-Freigabe. Ohne gemeinsame Stelle
# driften die Bedingungen auseinander, und genau die sind hier die eigentliche
# Logik: kein Versand ohne Adresse und keiner an Gäste (Aushilfen ohne
# Zuständigkeit im Verband, meist aus dem Ausland).
#
# Wie bei RefereeAccountCreator gilt: Ein Fehlschlag beim Versand darf den
# Vorgang nicht umwerfen. Die Lizenz ist geschrieben, die Qualifikation steht —
# eine nicht zugestellte Mail wird nachgeholt, ein 500er mitten im Submit
# hinterlässt einen halb angewendeten Import. Anders als dort geht der Fehler
# aber zusätzlich an Sentry: Was hier durchfällt, sind Programmierfehler
# (umbenannte Mailer-Action, nicht serialisierbares Argument) und die legen die
# Benachrichtigung dauerhaft und lautlos still.
#
# `deliver_later` heißt in Produktion „eingereiht", nicht „zugestellt": Der
# ActiveJob-Default ist `:async`, ein Threadpool im Prozess ohne Persistenz. Ein
# Deploy mitten in einer Tranche verwirft die noch offenen Mails. Der Betroffene
# kommt über „Passwort vergessen" bzw. die nächste Änderung trotzdem an die
# Information.
module RefereeNotification
  # Rückgabewerte, damit der Aufrufer die vier Fälle auseinanderhalten kann.
  # `false` hätte für „nichts zu melden", „nicht erreichbar" und „Versand
  # fehlgeschlagen" gestanden — und genau diese Unterscheidung ist die Frage, die
  # ein Importeur nach einem Kurs mit vierzig Zeilen hat.
  SENT = :sent
  UNREACHABLE = :unreachable
  NOTHING = :nothing
  FAILED = :failed

  # Erreichbar heißt: Adresse hinterlegt und kein Gast.
  def self.reachable?(referee)
    referee.present? && referee.email.present? && !referee.guest?
  end

  # Lizenznummer, Lizenzstufe oder Gültigkeit haben sich geändert.
  #
  # `first_license`: Der Schiedsrichter trug vorher keine Lizenzstufe — die Mail
  # meldet dann eine erteilte, keine aktualisierte Lizenz (siehe die Vorlage).
  def self.license_update(referee, first_license: false)
    deliver(referee, 'Lizenzmail') do
      RefereeMailer.license_notification(referee, first_license: first_license)
    end
  end

  # `changes` ist die Liste der ergänzten oder geänderten Zusatzqualifikationen,
  # siehe RefereeQualificationDiff.
  def self.qualification_update(referee, changes)
    return NOTHING if changes.blank?

    deliver(referee, 'Qualifikationsmail') do
      RefereeMailer.qualification_notification(referee, changes)
    end
  end

  def self.deliver(referee, label)
    return UNREACHABLE unless reachable?(referee)

    # deliver_later wirft nicht, wenn das Einreihen abgebrochen wird (
    # ActiveJob::EnqueueError, throw(:abort) in einem before_enqueue) — es gibt
    # dann false zurück. Ohne diese Prüfung würde der Aufrufer eine Mail zählen,
    # die nie in der Warteschlange stand.
    yield.deliver_later ? SENT : FAILED
  rescue StandardError => e
    Rails.logger.error("RefereeNotification: #{label} für Referee #{referee.id} " \
                       "fehlgeschlagen: #{e.class}: #{e.message}")
    Sentry.capture_exception(e) if defined?(Sentry)
    FAILED
  end
  private_class_method :deliver
end
