# frozen_string_literal: true

# Verschickt die Lizenzlisten zu den anstehenden Ansetzungen, je Empfänger eine
# Mail mit allen seinen Spielen des Fensters.
#
# Warum getrennt von der Ansetzungsmail: Die Lizenzliste hing bis #549 an der
# Ansetzungsmail, und ihr Link war 72 Stunden gültig. Angesetzt wird aber oft
# Wochen im Voraus, und der Link war dann längst abgelaufen, wenn er gebraucht
# wurde. Umgekehrt darf die Liste auch nicht wochenlang offen stehen: Sie zeigt
# Namen und Geburtsdaten aller lizenzierten Spieler beider Mannschaften.
#
# Deshalb kommt sie kurz vor dem Spiel und mit spielbezogener Gültigkeit
# (LicenseListLink): ein Lauf pro Woche in der Nacht Donnerstag → Freitag, der
# alle Spiele der kommenden sieben Tage abdeckt (Freitag bis Donnerstag). So
# bekommt jedes Spiel (auch ein Nachholspiel unter der Woche) genau eine Mail,
# mit einem Vorlauf von einem bis sieben Tagen.
#
# Idempotent über referee_assignments.license_lists_notified_at. Kurzfristig
# veröffentlichte Ansetzungen, die der Wochenlauf nicht mehr erwischt, bekommen
# die Liste direkt in der Ansetzungsmail (Admin::RefereeAssignmentsController#publish,
# Bedingung: `window_covers?`) und werden dort ebenso markiert.
class RefereeLicenseListNotifier
  # Kalender des Spielbetriebs, nicht der der Anwendung: Der Cron läuft um 0 Uhr
  # deutscher Zeit, also um 22 bzw. 23 Uhr UTC des Vortags. Mit `Date.current`
  # (UTC) läge das Fenster einen Tag zu früh und ließe den Donnerstag ausfallen.
  ZONE = ActiveSupport::TimeZone['Europe/Berlin'].freeze

  # Sieben Tage einschließlich des Lauftags: Freitag 0 Uhr deckt Freitag bis
  # einschließlich Donnerstag ab, der nächste Lauf setzt lückenlos fort.
  WINDOW_DAYS = 7

  def self.today
    ZONE.today
  end

  def self.window(from: today)
    from..(from + WINDOW_DAYS - 1)
  end

  # True, wenn ein Spiel an diesem Datum im aktuellen Fenster liegt, also so nah
  # ist, dass keine weitere Wochenmail mehr davorliegt.
  def self.window_covers?(date, from: today)
    date.present? && window(from:).cover?(date)
  end

  # `assignments` engt den Lauf ein, etwa auf eine einzelne Ansetzung nach einer
  # kurzfristigen Umbesetzung. Das Fenster gilt trotzdem: Liegt das Spiel noch
  # weit weg, schickt der nächste Wochenlauf die Listen.
  def initialize(from: self.class.today, assignments: RefereeAssignment.all)
    @window = self.class.window(from: from)
    @scope = assignments
  end

  # Gibt { mails:, assignments:, failures: } zurück. Für eine Vorschau ohne Versand
  # und ohne Markierung: each_bundle direkt aufrufen (siehe DRY_RUN im Rake-Task).
  #
  # Ein Fehler je Mail darf den Lauf nicht abbrechen: `raise_delivery_errors` ist
  # in Produktion aktiv, ein einziger abgewiesener Empfänger würde sonst aus `run`
  # herausfliegen, bevor irgendetwas markiert ist. Die schon verschickten Mails
  # käme ein Wiederholungslauf dann doppelt, und jedes Spiel, das bis zum nächsten
  # Freitag aus dem Fenster fällt, bekäme nie eine Liste. Gleiches Vorgehen wie im
  # RefereeFeedbackNotifier: loggen, an Sentry melden, weitermachen.
  def run(deliver_now: true)
    sent_ids = Set.new
    failed_ids = Set.new
    mails = 0
    failures = 0

    each_bundle do |recipient, entries|
      ids = entries.map { |entry| entry[:assignment_id] }

      if deliver(recipient, entries, deliver_now: deliver_now)
        mails += 1
        sent_ids.merge(ids)
      else
        failures += 1
        failed_ids.merge(ids)
      end
    end

    # Eine Ansetzung wird nur markiert, wenn JEDE Mail zu ihr durchging. Sonst
    # bekäme der zweite Schiedsrichter eines Gespanns nie eine Liste, weil die
    # Ansetzung wegen der Mail an den ersten schon als erledigt gilt. Eine
    # doppelte Liste ist das kleinere Übel als keine.
    to_mark = sent_ids - failed_ids
    RefereeAssignment.where(id: to_mark.to_a).update_all(license_lists_notified_at: Time.current) if to_mark.any?

    { mails: mails, assignments: to_mark.size, failures: failures }
  end

  # Empfänger mit ihren Spielen des Fensters, aufsteigend nach Anpfiff.
  def each_bundle
    collect.each_value do |bundle|
      entries = bundle[:entries].sort_by { |entry| [entry[:date], entry[:game].start_time.to_s] }
      yield bundle[:recipient], entries
    end
  end

  private

  # True bei erfolgreichem Versand bzw. Einreihen, false bei einem Fehler.
  def deliver(recipient, entries, deliver_now:)
    mail = RefereeMailer.license_lists_notification(recipient, entries)
    deliver_now ? mail.deliver_now : mail.deliver_later
    true
  rescue StandardError => e
    Rails.logger.warn(
      "Lizenzlisten-Mail fehlgeschlagen – Schiedsrichter #{recipient.id} " \
      "(#{entries.size} Spiel(e)): #{e.class}: #{e.message}"
    )
    Sentry.capture_exception(e) if defined?(Sentry)
    false
  end

  # { referee_id => { recipient:, entries: [...] } }
  def collect
    per_recipient = {}

    pending_assignments.each do |assignment|
      link = LicenseListLink.new(assignment.game)
      next unless link.available?

      date = assignment.game.game_date
      next unless date && @window.cover?(date)

      url = link.url
      expires_at = link.expires_at

      recipients_for(assignment).each do |recipient, role|
        bundle = (per_recipient[recipient.id] ||= { recipient: recipient, entries: [] })
        bundle[:entries] << {
          assignment_id: assignment.id,
          game: assignment.game,
          date: date,
          role: role,
          url: url,
          expires_at: expires_at
        }
      end
    end

    per_recipient
  end

  # Vorfilter in SQL, die endgültige Prüfung läuft in Ruby (`Game#game_date`).
  #
  # Bewusst ein TEXTvergleich und kein TO_DATE: `game_days.date` ist eine
  # Textspalte, und im Altbestand steht dort auch ein unmöglicher, aber
  # formgerechter Wert wie „2026-02-30". Der passiert jeden Formatfilter, lässt
  # TO_DATE aber mit „date/time field value out of range" werfen und riss so schon
  # einmal eine ganze Übersicht in einen Serverfehler
  # (game_day_secretary_links_controller). Hier wäre es schlimmer: Weil
  # `license_lists_notified_at` neu ist und überall NULL steht, läuft die Prüfung
  # über den gesamten Altbestand und nicht nur über die aktuelle Woche. Ein
  # einziger solcher Spieltag hätte den Versand komplett verhindert.
  #
  # Im ISO-Format sortiert Text richtig, der Vergleich ist also gleichwertig.
  # Abweichend formatierte Altwerte fallen entweder heraus oder werden in Ruby
  # von `Date.parse` abgefangen.
  def pending_assignments
    @scope.published
          .where(license_lists_notified_at: nil)
          .joins(game: { game_day: :league })
          .includes(:referee1, :referee2, :coach,
                    game: [:home_team, :guest_team, { game_day: %i[arena league] }])
          .where('game_days.date BETWEEN ? AND ?', @window.first.to_s, @window.last.to_s)
  end

  # Der angesetzte Verein (club_assignment) stellt seine Schiedsrichter selbst;
  # es gibt dort keine persönlichen Adressen. Ein Coach kann trotzdem angesetzt
  # sein und bekommt seine Liste.
  def recipients_for(assignment)
    pairs = assignment.referees.map { |referee| [referee, :referee] }
    pairs << [assignment.coach, :coach] if assignment.coach.present?
    # uniq: Ist derselbe Mensch als Schiri UND Coach eingetragen, gehört das Spiel
    # trotzdem nur einmal in seine Mail.
    pairs.uniq { |recipient, _role| recipient.id }
         .select { |recipient, _role| recipient.email.present? }
  end
end
