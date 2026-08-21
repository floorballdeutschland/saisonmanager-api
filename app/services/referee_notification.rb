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
# hinterlässt einen halb angewendeten Import.
#
# `deliver_later` heißt in Produktion „eingereiht", nicht „zugestellt": Der
# ActiveJob-Default ist `:async`, ein Threadpool im Prozess ohne Persistenz. Ein
# Deploy mitten in einer Tranche verwirft die noch offenen Mails.
module RefereeNotification
  # Erreichbar heißt: Adresse hinterlegt und kein Gast.
  def self.reachable?(referee)
    referee.present? && referee.email.present? && !referee.guest?
  end

  # Lizenznummer, Lizenzstufe oder Gültigkeit haben sich geändert.
  def self.license_update(referee)
    deliver(referee, 'Lizenzmail') { RefereeMailer.license_notification(referee) }
  end

  # `changes` ist die Liste der ergänzten oder geänderten Zusatzqualifikationen,
  # siehe RefereeQualificationDiff.
  def self.qualification_update(referee, changes)
    return false if changes.blank?

    deliver(referee, 'Qualifikationsmail') do
      RefereeMailer.qualification_notification(referee, changes)
    end
  end

  def self.deliver(referee, label)
    return false unless reachable?(referee)

    yield.deliver_later
    true
  rescue StandardError => e
    Rails.logger.warn("RefereeNotification: #{label} für Referee #{referee.id} fehlgeschlagen: #{e.message}")
    false
  end
  private_class_method :deliver
end
