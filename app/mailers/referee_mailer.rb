class RefereeMailer < ApplicationMailer
  REPLY_TO = 'sr-ansetzungen@floorball.de'
  # Regel- und Schiedsrichterkommission von Floorball Deutschland. Auffangadresse
  # für Stammdaten, wenn kein Landesverband zu ermitteln ist.
  RSK_REPLY_TO = 'rsk@floorball.de'

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

    attach_assignment_calendar(
      game,
      recipient: referee,
      role: :referee,
      officials: partner && "#{partner.vorname} #{partner.nachname}",
      coach_name: coach && "#{coach.vorname} #{coach.nachname}",
      club_contact_email: club_contact_email,
      notes: @referee_notes
    )

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

    attach_assignment_calendar(
      game,
      recipient: coach,
      role: :coach,
      officials: official_names.presence,
      club_contact_email: club_contact_email,
      notes: @referee_notes
    )

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

  # Lizenzlisten zu den anstehenden Spielen eines Empfängers, gebündelt in einer
  # Mail (RefereeLicenseListNotifier). `entries` sind Hashes mit :game, :date,
  # :role, :url und :expires_at, aufsteigend nach Anpfiff sortiert.
  #
  # Bewusst getrennt von der Ansetzungsmail: Der Link gilt nur bis zum Tag nach
  # dem Spiel, angesetzt wird aber oft Wochen vorher.
  def license_lists_notification(recipient, entries)
    @recipient = recipient
    @entries = entries
    @date_range = date_range_label(entries.map { |entry| entry[:date] })

    templated_mail(
      to: recipient.email,
      subject: "Lizenzlisten für deine Ansetzungen (#{@date_range})",
      default_reply_to: REPLY_TO,
      placeholders: {
        first_name: recipient.vorname,
        date_range: @date_range,
        game_count: entries.size.to_s,
        game_list: entries.map { |entry| license_list_line(entry) }.join("\n")
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

  # Neuer Antrag eines Schiris auf einen Vereins-Ausschluss. Empfänger ist
  # ausnahmslos das zentrale Ansetzungs-Postfach von Floorball Deutschland.
  #
  # Bewusst NICHT an das rsk_email des Landesverbands: Entschieden werden die
  # Anträge von der Ansetzer-Rolle (menu_item_referee_exclusions), und die liegt
  # bundesweit bei der RSK von Floorball Deutschland. Ein Landesverband bekam die
  # Mail zwar, fand den Antrag aber in keiner Maske wieder, konnte ihn also weder
  # bestätigen noch ablehnen.
  def club_exclusion_requested(exclusion_request)
    @exclusion_request = exclusion_request
    @referee = exclusion_request.referee
    @club = exclusion_request.club

    templated_mail(
      to: REPLY_TO,
      subject: "Antrag Vereins-Ausschluss – #{@referee.vorname} #{@referee.nachname}",
      default_reply_to: @referee.email.presence || REPLY_TO,
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
      # Wie beim Antrag selbst: Eine Rückfrage zur Entscheidung gehört zu der
      # Stelle, die entschieden hat, und nicht zum Landesverband.
      default_reply_to: REPLY_TO,
      placeholders: {
        referee_name: "#{@referee.vorname} #{@referee.nachname}",
        first_name: @referee.vorname,
        club_name: @club&.name.to_s,
        decision: @approved ? 'genehmigt' : 'abgelehnt'
      }
    )
  end

  # Neuer Antrag eines Schiris auf Korrektur seiner Stammdaten. Geht an die RSK
  # des Landesverbands, in dem sein Verein liegt: Dort wird entschieden, und
  # dort liegen die Nachweise (Ausweis, Vereinsmeldung).
  def change_requested(change_request)
    @change_request = change_request
    @referee = change_request.referee
    recipient = lv_rsk_email(@referee)

    templated_mail(
      to: recipient,
      subject: "Antrag Stammdatenkorrektur – #{@referee.vorname} #{@referee.nachname}",
      default_reply_to: @referee.email.presence || recipient,
      placeholders: {
        referee_name: "#{@referee.vorname} #{@referee.nachname}",
        field: change_request.label.to_s,
        current_value: change_request.current_value.to_s,
        requested_value: change_request.requested_value.to_s
      }
    )
  end

  # Entscheidung der RSK über einen Korrekturantrag, adressiert an den Schiri.
  def change_decision(change_request)
    @change_request = change_request
    @referee = change_request.referee
    @approved = change_request.status == 'approved'

    templated_mail(
      to: @referee.email,
      subject: "Stammdatenkorrektur #{@approved ? 'genehmigt' : 'abgelehnt'} – #{change_request.label}",
      default_reply_to: lv_rsk_email(@referee),
      placeholders: {
        referee_name: "#{@referee.vorname} #{@referee.nachname}",
        first_name: @referee.vorname,
        field: change_request.label.to_s,
        requested_value: change_request.requested_value.to_s,
        decision: @approved ? 'genehmigt' : 'abgelehnt'
      }
    )
  end

  private

  # Postfach der RSK des Landesverbands, in dem der Schiri über seinen Verein
  # hängt; ohne eigenen Eintrag greift der übergeordnete Verband, zuletzt die
  # zentrale Adresse.
  def lv_rsk_email(referee)
    referee.club&.state_association&.effective_rsk_email.presence || RSK_REPLY_TO
  end

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

  # ICS-Anhang für eine Ansetzungsmail, damit der Termin mit einem Klick im
  # eigenen Kalender landet. Ohne lesbares Spieltagsdatum liefert der Kalender
  # nil; die Mail geht dann ohne Anhang raus statt gar nicht.
  #
  # `method=PUBLISH` gehört in den Content-Type, nicht nur in die Datei: Outlook
  # entscheidet daran, ob es den Anhang als übernehmbaren Termin anbietet.
  # Setzt @calendar_attached, damit die Vorlage den Anhang nur dann erwähnt, wenn
  # er wirklich dranhängt.
  def attach_assignment_calendar(game, **options)
    calendar = RefereeAssignmentCalendar.new(game, **options)
    ics = calendar.to_ical
    @calendar_attached = ics.present?
    return unless @calendar_attached

    attachments[calendar.filename] = {
      mime_type: 'text/calendar; charset=UTF-8; method=PUBLISH',
      content: ics
    }
  end

  # „28.02.2026" bei einem Tag, „27.02.–01.03.2026" bei mehreren.
  def date_range_label(dates)
    days = dates.compact.uniq.sort
    return '' if days.empty?
    return days.first.strftime('%d.%m.%Y') if days.size == 1

    "#{days.first.strftime('%d.%m.')}–#{days.last.strftime('%d.%m.%Y')}"
  end

  # Eine Zeile je Spiel für {{game_list}}. Nur Notnagel für einen in der Admin-UI
  # gepflegten Body: Platzhalterwerte werden dort HTML-escaped, der Link steht
  # deshalb als Text und nicht als Verweis.
  def license_list_line(entry)
    game = entry[:game]
    time = game.start_time.presence
    label = [entry[:date].strftime('%d.%m.%Y'), time].compact.join(' ')
    "#{label} #{game.home_team&.name} vs. #{game.guest_team&.name}: #{entry[:url]}"
  end

  # SBK-Adresse des Spielbetriebs (Landesverband des game_operation, aufgelöst
  # über Game#state_association); ohne eigenen Eintrag greift der übergeordnete
  # Verbund, zuletzt das Ansetzungs-Postfach aus REPLY_TO.
  def sbk_reply_to(game)
    game.state_association&.effective_sbk_email.presence || REPLY_TO
  end
end
