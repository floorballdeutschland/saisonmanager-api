class RefereeMailer < ApplicationMailer
  REPLY_TO = 'sr-ansetzungen@floorball.de'

  # `first_license`: Der Schiedsrichter trug vorher keine Lizenzstufe – meist eine
  # Neuanlage aus dem Kursimport. Die Vorlage meldet dann eine erteilte statt
  # einer aktualisierten Lizenz und behauptet nicht, die Lizenz sei „ab sofort
  # auch" über den QR-Code auf dem Schiedsrichterausweis prüfbar: Wer seine erste
  # Lizenz bekommt, hat noch keinen Ausweis in der Hand.
  def license_notification(referee, first_license: false)
    @referee = referee
    @first_license = first_license

    templated_mail(
      to: referee.email,
      subject: "Schiedsrichterlizenz #{first_license ? 'erteilt' : 'aktualisiert'} – " \
               "#{referee.vorname} #{referee.nachname}",
      default_reply_to: 'rsk@floorball.de',
      placeholders: {
        referee_name: "#{referee.vorname} #{referee.nachname}",
        first_name: referee.vorname
      }
    )
  end

  # `changes` kommt aus RefereeQualificationDiff: die ergänzten und geänderten
  # Zusatzqualifikationen dieses Speichervorgangs, nicht der komplette Bestand.
  #
  # Der Platzhalter qualification_names steht auch im Betreff zur Verfügung und
  # ist zugleich der Rettungsanker für einen in der Admin-UI gepflegten Body:
  # Ein gepflegter Body ersetzt das ERB-View komplett, die Liste unten fällt dann
  # weg — über den Platzhalter bleiben die Namen erreichbar.
  def qualification_notification(referee, changes)
    @referee = referee
    @changes = changes

    templated_mail(
      to: referee.email,
      subject: "Zusatzqualifikation aktualisiert – #{referee.vorname} #{referee.nachname}",
      default_reply_to: 'rsk@floorball.de',
      placeholders: {
        referee_name: "#{referee.vorname} #{referee.nachname}",
        first_name: referee.vorname,
        qualification_names: changes.map { |change| change[:name] }.join(', '),
        qualification_list: changes.map { |change| qualification_line(change) }.join(', ')
      }
    )
  end

  def tentative_assignment_notification(referee, date)
    @referee = referee
    @date = date
    # Explizites Format statt I18n.l, wie in den übrigen Mail-Vorlagen. Seit der
    # deutschen Locale (config/locales/de.yml) käme I18n.l zwar auf dasselbe
    # Ergebnis, aber das Format soll hier nicht an einer Locale-Einstellung
    # hängen. `date` ist immer ein Date, der Aufrufer weist ein nicht lesbares
    # Spieltagsdatum vorher ab.
    @date_label = date.strftime('%d.%m.%Y')

    templated_mail(
      to: referee.email,
      subject: "Vorläufige Ansetzung – #{@date_label}",
      default_reply_to: REPLY_TO,
      placeholders: { date: @date_label, first_name: referee.vorname }
    )
  end

  def published_assignment_notification(referee, game, partner, club_contact_email, coach: nil, license_list_url: nil, license_expires_at: nil)
    @referee = referee
    @game = game
    @partner = partner
    @coach = coach
    @club_contact_email = club_contact_email
    @license_list_url = license_list_url
    @license_expires_at = license_expires_at
    @referee_notes = visible_referee_notes(game, referee)

    templated_mail(
      to: referee.email,
      subject: "Ansetzung – #{game.game_day.date} #{game.home_team&.name} vs. #{game.guest_team&.name}",
      default_reply_to: REPLY_TO,
      placeholders: {
        first_name: referee.vorname,
        game_date: game.game_day.date,
        game_time: game.start_time.to_s,
        home_team: game.home_team&.name,
        guest_team: game.guest_team&.name,
        coach_name: coach ? "#{coach.vorname} #{coach.nachname}" : '',
        referee_notes: @referee_notes.to_s
      }
    )
  end

  # Ansetzungs-Mail an den Schiedsrichtercoach: gleiche Spieltag-Details und
  # Lizenzlisten wie für die Schiris, plus die Namen der angesetzten Schiris.
  def published_coach_notification(coach, game, official_names, club_contact_email, license_list_url: nil, license_expires_at: nil)
    @coach = coach
    @game = game
    @official_names = official_names
    @club_contact_email = club_contact_email
    @license_list_url = license_list_url
    @license_expires_at = license_expires_at
    @referee_notes = visible_referee_notes(game, coach)

    templated_mail(
      to: coach.email,
      subject: "Schiedsrichtercoach-Ansetzung – #{game.game_day.date} #{game.home_team&.name} vs. #{game.guest_team&.name}",
      default_reply_to: REPLY_TO,
      placeholders: {
        first_name: coach.vorname,
        game_date: game.game_day.date,
        game_time: game.start_time.to_s,
        home_team: game.home_team&.name,
        guest_team: game.guest_team&.name,
        officials: official_names.to_s,
        referee_notes: @referee_notes.to_s
      }
    )
  end

  # Eine veröffentlichte Ansetzung wurde umbesetzt. Geht an die alten *und* neuen
  # Schiris sowie den Coach – jede:r sieht die aktuelle Besetzung und damit, ob
  # sie/er noch angesetzt ist (eine Update-Mail statt Storno + Neu).
  def updated_assignment_notification(referee, game, official_names, coach)
    @referee = referee
    @game = game
    @official_names = official_names
    @coach = coach
    @referee_notes = visible_referee_notes(game, referee)

    templated_mail(
      to: referee.email,
      subject: "Ansetzung geändert – #{game.game_day.date} #{game.home_team&.name} vs. #{game.guest_team&.name}",
      default_reply_to: REPLY_TO,
      placeholders: {
        first_name: referee.vorname,
        game_date: game.game_day.date,
        game_time: game.start_time.to_s,
        home_team: game.home_team&.name,
        guest_team: game.guest_team&.name,
        officials: official_names.to_s,
        coach_name: coach ? "#{coach.vorname} #{coach.nachname}" : '',
        referee_notes: @referee_notes.to_s
      }
    )
  end

  def incident_report_reminder(referee1, referee2, game, deadline)
    @referee1 = referee1
    @referee2 = referee2
    @game = game
    @deadline = deadline
    @upload_url = game.url

    templated_mail(
      to: [referee1.email, referee2.email].compact,
      subject: "Spielnummer #{game.game_number} | 24h Zeit für Berichtsformular",
      default_reply_to: sbk_reply_to(game),
      placeholders: {
        first_name: "#{referee1.vorname} und #{referee2.vorname}",
        game_number: game.game_number,
        upload_url: @upload_url,
        deadline: deadline.strftime('%d.%m.%Y %H:%M')
      }
    )
  end

  def referee_report_to_vsk(vsk_email, uploader, game, report, referee1, referee2, game_url: nil, checklist_answers: [])
    @uploader = uploader
    @game = game
    @referee1 = referee1
    @referee2 = referee2
    @game_url = game_url
    @checklist_answers = checklist_answers
    @checklist_all_ok = checklist_answers.all? { |a| a['answer'] == true }
    @checklist_failed_items = checklist_answers.select { |a| a['answer'] == false }

    if report.file.attached?
      blob = report.file.blob
      attachments[blob.filename.to_s] = {
        mime_type: blob.content_type,
        content: blob.download
      }
    end

    templated_mail(
      to: vsk_email,
      subject: "Berichtsformular eingereicht – Spielnummer #{game.game_number}",
      default_reply_to: sbk_reply_to(game),
      placeholders: { game_number: game.game_number }
    )
  end

  # Neuer Antrag eines Schiris auf einen Vereins-Ausschluss – geht an das
  # Ansetzungs-Postfach des zuständigen Landesverbands (rsk_email, geerbt vom
  # übergeordneten Verband).
  def club_exclusion_requested(exclusion_request)
    @exclusion_request = exclusion_request
    @referee = exclusion_request.referee
    @club = exclusion_request.club
    recipient = rsk_reply_to(@referee)

    templated_mail(
      to: recipient,
      subject: "Antrag Vereins-Ausschluss – #{@referee.vorname} #{@referee.nachname}",
      default_reply_to: @referee.email.presence || recipient,
      placeholders: {
        referee_name: "#{@referee.vorname} #{@referee.nachname}",
        club_name: @club&.name.to_s,
        kind: exclusion_request.kind == 'add' ? 'Aufnahme' : 'Streichung'
      }
    )
  end

  # Entscheidung der Ansetzung über einen Antrag – geht an den Schiri.
  def club_exclusion_decision(exclusion_request)
    @exclusion_request = exclusion_request
    @referee = exclusion_request.referee
    @club = exclusion_request.club
    @approved = exclusion_request.status == 'approved'

    templated_mail(
      to: @referee.email,
      subject: "Vereins-Ausschluss #{@approved ? 'genehmigt' : 'abgelehnt'} – #{@club&.name}",
      default_reply_to: rsk_reply_to(@referee),
      placeholders: {
        referee_name: "#{@referee.vorname} #{@referee.nachname}",
        first_name: @referee.vorname,
        club_name: @club&.name.to_s,
        decision: @approved ? 'genehmigt' : 'abgelehnt'
      }
    )
  end

  private

  # Zusätzliche Spielinformationen des Ansetzers, aber nur für Empfänger:innen,
  # die zum Versandzeitpunkt tatsächlich angesetzt sind (Game#referee_notes_
  # visible_to?). Die Änderungs-Mail geht bewusst auch an Personen, die gerade
  # aus der Ansetzung genommen wurden – für die ist der Freitext nicht mehr
  # bestimmt.
  def visible_referee_notes(game, referee)
    game.referee_notes.presence if game.referee_notes_visible_to?(referee)
  end

  # „B-Coach (gültig bis 30.06.2027)" – damit ein in der Admin-UI gepflegter Body
  # nicht nur die Namen, sondern auch die Ablaufdaten wiedergeben kann.
  def qualification_line(change)
    return change[:name] if change[:valid_until].blank?

    "#{change[:name]} (gültig bis #{change[:valid_until].strftime('%d.%m.%Y')})"
  end

  # Ansetzungs-Postfach des Landesverbands, in dem der Schiri über seinen Verein
  # hängt; ohne eigenen Eintrag greift der übergeordnete Verband, zuletzt die
  # zentrale Adresse.
  def rsk_reply_to(referee)
    referee.club&.state_association&.effective_rsk_email.presence || REPLY_TO
  end

  # SBK-Adresse des Spielbetriebs (Landesverband des game_operation, aufgelöst
  # über Game#state_association); ohne eigenen Eintrag greift der übergeordnete
  # Verbund, zuletzt das Ansetzungs-Postfach aus REPLY_TO.
  def sbk_reply_to(game)
    game.state_association&.effective_sbk_email.presence || REPLY_TO
  end
end
