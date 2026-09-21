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
      stufe, emails = recipients(team)
      if emails.empty?
        Rails.logger.info(
          "Spieltagsbestätigung: keine Adresse für Gastmannschaft #{team.id} " \
          "(Spiel #{@game.id}, Verein #{team.club_id.inspect})"
        )
        next
      end

      # Welche Stufe gezogen hat, gehört ins Log: Von außen ist der Verteiler
      # nicht mehr abzulesen, und die häufigste Rückfrage („warum hat der
      # Verein nichts bekommen?") wäre sonst nur über einen Datenbankabzug zu
      # beantworten.
      Rails.logger.info(
        "Spieltagsbestätigung: #{stufe} für Gastmannschaft #{team.id} " \
        "(Spiel #{@game.id}, #{emails.size} Adresse(n))"
      )
      result[team] = emails
    end
  end

  # Eine Kaskade, kein Sammelverteiler: Die Mail geht an die Stufe, die dem
  # Spieltag am nächsten steht, und erst wenn die leer ist an die nächste.
  #
  #   1. die Teammanager DIESER Mannschaft
  #   2. sonst die Vereinsmanager des Vereins (Vereinspost ohne Kontaktadresse)
  #   3. sonst die Kontaktadresse des Vereins
  #
  # Vorher gingen Vereinspost und Teammanager gemeinsam raus. Für einen Verein
  # mit vielen Mannschaften heißt das, dass der Vereinsvorstand jede Bestätigung
  # jeder Mannschaft mitliest, während die Mail tatsächlich an eine einzige
  # Person gerichtet ist – die, die den Spieltag verantwortet.
  #
  # Dass die Stufen sich gegenseitig ausschließen, ist der Punkt der Änderung.
  # Eine Stufe gilt als leer, wenn sie keine zustellbare Adresse liefert, nicht
  # wenn es die Rolle nicht gibt: Ein Teammanager, der Info-Mails abbestellt hat
  # (`receive_info_mails`), lässt die Mail damit an die Vereinsmanager
  # weiterfallen. Das ist gewollt – die Bestätigung ist eine Pflicht des
  # Vereins, sie darf nicht dadurch verschwinden, dass niemand sie lesen will.
  #
  # Geprüft wird auf Zustellbarkeit, nicht auf Befülltheit: `users.email` hat
  # keinerlei Formatvalidierung (anders als `clubs.contact_email`), und ein
  # Teammanager, der den Verein verlassen hat, steht oft mit einem längst
  # gelöschten Postfach weiter an der Mannschaft. Ohne die Prüfung besetzte so
  # ein toter Eintrag die erste Stufe, die Mail bounct, und beide Auffangnetze
  # bleiben ungenutzt, während die Bestätigungsfrist weiterläuft.
  # Liefert die gezogene Stufe und ihre Adressen. Die Stufe kommt aus der
  # Ermittlung selbst und wird nicht nachträglich rekonstruiert -- ein zweiter
  # Durchlauf kostete eine weitere Abfrage über die Vereinsmanager.
  def recipients(team)
    club = team.club

    if (emails = deliverable(User.team_managers(team.id).map(&:email))).any?
      ['Teammanager', emails]
    elsif (emails = deliverable(vereinsmanager_emails(club))).any?
      ['Vereinsmanager', emails]
    else
      ['Vereinskontaktadresse', deliverable([club&.contact_email])]
    end
  end

  # Die Vereinsmanager der Vereinspost, ohne die, die Info-Mails abbestellt
  # haben (`receive_info_mails`).
  #
  # Die übrige Vereinspost kennt diese Abwahl bewusst nicht: An
  # `Club#notification_emails` hängen Transfers, Spielverlegungen, Freigaben und
  # die Erinnerung an den Spielberichtsbogen -- Vorgänge, die ein Verein
  # mitbekommen muss, ob er mag oder nicht. Für diese eine Mail gilt die Abwahl
  # dagegen schon auf Stufe 1 (`User.team_managers` filtert danach), und sie auf
  # Stufe 2 zu übergehen kehrte den Schalter ins Gegenteil: Ein Vereinsmanager,
  # der sich eine Mannschaft zugeordnet und Info-Mails abbestellt hat, fiel aus
  # Stufe 1 heraus, bekam die Mail über Stufe 2 trotzdem -- und zog dabei den
  # ganzen restlichen Vorstand mit hinein, der vorher nichts davon sah.
  def vereinsmanager_emails(club)
    club&.notify_managers.to_a.select(&:receive_info_mails).filter_map { |user| user.email.presence }
  end

  # Zerlegt wird, was der Mail-Versand ohnehin zerlegt, statt es zu verwerfen:
  # Ein Feld mit zwei durch Semikolon oder Komma getrennten Adressen und ein
  # Feld mit Anzeigename (`Max Muster <max@verein.de>`) werden vom Mail-Gem in
  # echte Empfänger aufgelöst, bis in den SMTP-Umschlag. Beides steht im
  # Bestand -- auf der Produktion trägt mindestens ein Verein zwei Adressen mit
  # Semikolon in der Kontaktadresse (siehe Club::EMAIL_FORMAT). Eine reine
  # Formatprüfung auf das ganze Feld hätte genau diese Vereine aus der letzten
  # Stufe der Kaskade geworfen, also aus dem Auffangnetz -- und ohne
  # Empfänger gibt es weder Mail noch Fristverlängerung.
  #
  # Der Kommentar an `Club#reachable_for_requests?` behauptet das Gegenteil
  # („geht als EINE Adresse heraus und erreicht niemanden"). Das ist gemessen
  # falsch; die Stelle gehört nicht zu diesem Weg und bleibt hier unangetastet.
  def deliverable(emails)
    emails.flat_map { |mail| mail.to_s.split(/[;,]/) }
          .map { |mail| mail[/<([^>]+)>/, 1] || mail }
          .map(&:strip)
          .select { |mail| mail.match?(Club::EMAIL_FORMAT) }
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
