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

  def initialize(from: self.class.today)
    @window = self.class.window(from: from)
  end

  # Gibt { mails:, assignments: } zurück. Für eine Vorschau ohne Versand und ohne
  # Markierung: each_bundle direkt aufrufen (siehe DRY_RUN im Rake-Task).
  def run(deliver_now: true)
    notified_assignment_ids = Set.new
    mails = 0

    each_bundle do |recipient, entries|
      notified_assignment_ids.merge(entries.map { |entry| entry[:assignment_id] })

      mail = RefereeMailer.license_lists_notification(recipient, entries)
      deliver_now ? mail.deliver_now : mail.deliver_later
      mails += 1
    end

    if notified_assignment_ids.any?
      RefereeAssignment.where(id: notified_assignment_ids.to_a)
                       .update_all(license_lists_notified_at: Time.current)
    end

    { mails: mails, assignments: notified_assignment_ids.size }
  end

  # Empfänger mit ihren Spielen des Fensters, aufsteigend nach Anpfiff.
  def each_bundle
    collect.each_value do |bundle|
      entries = bundle[:entries].sort_by { |entry| [entry[:date], entry[:game].start_time.to_s] }
      yield bundle[:recipient], entries
    end
  end

  private

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

  # Vorfilter in SQL auf das Fenster; die endgültige Prüfung läuft in Ruby, weil
  # `game_days.date` eine Textspalte ist und ein unplausibler Eintrag hier
  # TO_DATE zum Stolpern bringen könnte.
  def pending_assignments
    RefereeAssignment.published
                     .where(license_lists_notified_at: nil)
                     .joins(game: { game_day: :league })
                     .includes(:referee1, :referee2, :coach,
                               game: [:home_team, :guest_team, { game_day: %i[arena league] }])
                     .where("game_days.date ~ '^\\d{4}-\\d{2}-\\d{2}$'")
                     .where("TO_DATE(game_days.date, 'YYYY-MM-DD') BETWEEN ? AND ?",
                            @window.first, @window.last)
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
