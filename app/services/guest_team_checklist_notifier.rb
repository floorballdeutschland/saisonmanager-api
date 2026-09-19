# frozen_string_literal: true

# Benachrichtigt die Gastmannschaften eines Spiels, sobald der Ausrichter den
# Spielbericht abgeschlossen hat: Damit stehen seine Antworten im
# Spieltagsbericht fest, und die Gastmannschaft kann den Spieltag bestätigen
# oder als nicht ordnungsgemäß melden (Portal „Meine Auswärtsspieltage").
#
# Diese Mail fehlte. Der Ausrichter bekam seine Bestätigung mit Einspruchs-Link
# (GameMailer#checklist_confirmation), das Gespann den Portal-Hinweis
# (#checklist_referee_portal_notice) – für die Gastmannschaften war überhaupt kein
# Versand vorgesehen. Sie mussten von selbst ins Portal schauen, während ihr
# Bestätigungsfenster ablief. Beim FD-Pokalspiel am 13.09.2026 (Berliner TSC gegen
# UHC Elster) hatte der Ausrichter „Die Einladung zum Spiel ist dem Gastteam
# zugegangen" mit Ja beantwortet, obwohl er keine Einladung verschickt hatte;
# Elster erfuhr davon nichts und fand den Spieltag am Mittwoch automatisch
# bestätigt vor.
#
# Gastmannschaft ist – wie im Portal, siehe TeamGameDayConfirmationsController –
# jede Mannschaft des Spiels, die nicht zum Ausrichterverein gehört. Beide Seiten
# müssen diese Frage gleich beantworten, sonst bekommt jemand eine Mail zu einem
# Spieltag, den er im Portal nicht vorfindet.
class GuestTeamChecklistNotifier
  def initialize(game)
    @game = game
    @game_day = game.game_day
  end

  # Verschickt je Gastmannschaft eine Mail und liefert deren Anzahl.
  #
  # Der Versandzeitpunkt wird am Spieltag festgehalten, weil das
  # Bestätigungsfenster daran hängt (GameDay#team_confirmation_deadline).
  # Gestempelt wird VOR dem Versand: Die Mail nennt die Frist, und das muss
  # dieselbe sein, die der Server anschließend prüft.
  #
  # Kein Idempotenz-Riegel über den Zeitstempel: Ein Spieltag kann mehrere Spiele
  # mit unterschiedlichen Gastmannschaften haben (Turnierspieltag), die alle
  # einzeln abgeschlossen werden. Ein Riegel würde alle Mannschaften außer der
  # ersten wieder stumm übergehen. Mehrfache Abschlüsse desselben Spiels schicken
  # deshalb mehrfach – wie beim Portal-Hinweis an die Schiris.
  def notify
    return 0 if @game_day.nil?

    items = checklist_items
    return 0 if items.empty?

    answers = answers_for(items)
    return 0 if answers.empty?

    verteiler = recipients_by_team
    return 0 if verteiler.empty?

    # Frist BERECHNEN, dann festschreiben: Ein unlesbares Spieltagsdatum wirft
    # hier, und dann ist nichts gestempelt und nichts verschickt. In der anderen
    # Reihenfolge haette es die Frist um 48 Stunden verschoben, ohne dass eine
    # einzige Mail rausgegangen waere.
    jetzt = Time.current
    deadline = @game_day.team_confirmation_deadline(jetzt)
    @game_day.update_column(:team_confirmation_notified_at, jetzt)

    verteiler.sum { |team, emails| deliver(team, emails, answers, deadline) }
  end

  private

  def checklist_items
    @game.state_association&.checklist_items.to_a
  end

  # Die Antworten des Ausrichters, mit dem Fragetext AUS DER CHECKLISTE DES
  # VERBANDS.
  #
  # Nicht aus den gespeicherten Antworten: `GamesController#set_checklist_answers`
  # uebernimmt `question` ungeprueft aus dem Request. Diese Mail geht an die
  # Gegenseite, ein Ausrichter koennte darin sonst beliebigen Text ueber den
  # Absender des Saisonmanagers an den Gastverein schicken. Der Einspruchsweg
  # liest den Text aus demselben Grund aus der Datenbank
  # (`_normalized_veto_answers`).
  #
  # Fragen ohne Antwort fallen heraus: Legt ein Verband eine Frage nach dem
  # Abschluss eines Spielberichts an, gibt es zu ihr keine Angabe des
  # Ausrichters, und eine leere Zeile in der Mail waere eine Behauptung.
  def answers_for(items)
    gegeben = (@game.checklist_answers || []).index_by { |a| a['item_id'].to_i }

    items.filter_map do |item|
      antwort = gegeben[item.id]
      next if antwort.nil?

      { 'item_id' => item.id, 'question' => item.question, 'answer' => antwort['answer'] }
    end
  end

  def guest_teams
    [@game.home_team, @game.guest_team].compact.uniq.reject { |team| team.club_id == @game_day.club_id }
  end

  # Mannschaft => Adressen, ohne die Mannschaften, für die keine Adresse
  # auflösbar ist. Deren Fehlen gehört ins Log: Für die Mannschaft läuft die
  # Frist trotzdem, und ohne Spur wäre später nicht zu unterscheiden, ob die Mail
  # nie verschickt wurde oder im Postfach des Vereins verloren ging.
  def recipients_by_team
    guest_teams.each_with_object({}) do |team, result|
      emails = recipients(team)
      if emails.empty?
        Rails.logger.info(
          "Spieltagsbestätigung: keine Adresse für Gastmannschaft #{team.id} " \
          "(Spiel #{@game.id}, Verein #{team.club_id.inspect})"
        )
        next
      end

      result[team] = emails
    end
  end

  # Vereinspost und Teammanager zusammen: Die Bestätigung ist eine Pflicht des
  # Vereins, deshalb geht sie an dessen Verteiler (Kontaktadresse plus die nicht
  # abgewählten Vereinsmanager). Die Teammanager stehen zusätzlich drin, weil sie
  # den Spieltag miterlebt haben – sie können Info-Mails allerdings abbestellen
  # (receive_info_mails), die Vereinspost kann das nicht.
  def recipients(team)
    (team.club&.notification_emails.to_a + User.team_managers(team.id).map(&:email))
      .map { |mail| mail.to_s.strip }
      .reject(&:blank?)
      .uniq
  end

  # Ein fehlgeschlagener Versand darf weder die übrigen Mannschaften mitreißen
  # noch den bereits gespeicherten Spielbericht zum Serverfehler machen.
  def deliver(team, emails, answers, deadline)
    GameMailer.checklist_guest_team_notice(@game, team, emails, answers, deadline).deliver_later
    1
  rescue StandardError => e
    Rails.logger.warn(
      "Spieltagsbestätigung an Gastmannschaft #{team.id} fehlgeschlagen " \
      "(Spiel #{@game.id}): #{e.class}: #{e.message}"
    )
    Sentry.capture_exception(e) if defined?(Sentry)
    0
  end
end
