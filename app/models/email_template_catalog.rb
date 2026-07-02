# Statischer Katalog aller vom System verschickten E-Mails. Code-definierte Keys
# (Mailer + Action) mit Default-Betreff (als {{platzhalter}}-Template), Default-
# Absender/Reply-To und der Liste der im Betreff verfügbaren Platzhalter (für die
# Admin-UI). Quelle der Wahrheit für die Defaults; gepflegte EmailTemplate-
# Datensätze überschreiben einzelne Felder.
#
# Eintrag-Format:
#   'MailerClass#action' => {
#     mailer_class:, action_name:, description:,
#     default_subject:   '… {{platzhalter}} …',
#     default_from:      nil | 'adresse',          # nil = ApplicationMailer-Default
#     default_reply_to:  nil | 'adresse' | :dynamic, # :dynamic = zur Laufzeit im Mailer
#     placeholders:      [{ key: 'platzhalter', description: '…' }]
#   }
module EmailTemplateCatalog # rubocop:disable Metrics/ModuleLength -- reine Daten-/Katalogdatei
  ENTRIES = {
    'UserMailer#reset_password' => {
      mailer_class: 'UserMailer',
      action_name: 'reset_password',
      description: 'Link zum Zurücksetzen des Passworts.',
      default_subject: 'Anleitung zum Passwort zurücksetzen im Saisonmanager',
      default_from: nil,
      default_reply_to: nil,
      placeholders: []
    },
    'RefereeFeedbackMailer#form_available' => {
      mailer_class: 'RefereeFeedbackMailer',
      action_name: 'form_available',
      description: 'Info an Teammanager, dass das Schiri-Feedback-Formular für ein Spiel ausfüllbar ist (Fenster öffnet mit dem Abschluss des Spielberichts).',
      default_subject: 'Schiri-Feedback möglich – {{team_name}}',
      default_from: nil,
      default_reply_to: nil,
      placeholders: [
        { key: 'team_name', description: 'Name der eigenen Mannschaft' },
        { key: 'opponent_name', description: 'Name der gegnerischen Mannschaft' },
        { key: 'league_name', description: 'Name der Liga' },
        { key: 'link', description: 'Link zur Feedback-Seite' }
      ]
    },
    'UserMailer#referee_account_created' => {
      mailer_class: 'UserMailer',
      action_name: 'referee_account_created',
      description: 'Begrüßung beim Anlegen eines Schiedsrichter-Benutzerkontos (Benutzername + Link zum Passwort-Setzen).',
      default_subject: 'Dein Schiedsrichteraccount im Saisonmanager',
      default_from: nil,
      default_reply_to: 'rsk@floorball.de',
      placeholders: [
        { key: 'username', description: 'Benutzername des Kontos (z. B. sr-3204)' },
        { key: 'link', description: 'Link zum (erstmaligen) Setzen des Passworts' }
      ]
    },
    'ClubMailer#game_day_scan_reminder' => {
      mailer_class: 'ClubMailer',
      action_name: 'game_day_scan_reminder',
      description: 'Erinnerung an den Verein, Spielbericht-Scans eines Spieltags einzureichen.',
      default_subject: 'Spielbericht-Scans einreichen – Spieltag {{game_day_date}}',
      default_from: nil,
      default_reply_to: 'system@saisonmanager.org',
      placeholders: [
        { key: 'game_day_date', description: 'Datum des Spieltags (lang formatiert)' }
      ]
    },
    'RefereeMailer#license_notification' => {
      mailer_class: 'RefereeMailer',
      action_name: 'license_notification',
      description: 'Benachrichtigung an Schiri über aktualisierte Lizenz.',
      default_subject: 'Schiedsrichterlizenz aktualisiert – {{referee_name}}',
      default_from: nil,
      default_reply_to: 'rsk@floorball.de',
      placeholders: [
        { key: 'referee_name', description: 'Vor- und Nachname des Schiris' }
      ]
    },
    'RefereeMailer#wallet_pass_issued' => {
      mailer_class: 'RefereeMailer',
      action_name: 'wallet_pass_issued',
      description: 'Benachrichtigung an Schiri über den ausgestellten digitalen Schiedsrichterausweis.',
      default_subject: 'Dein Schiedsrichterausweis | {{referee_name}}',
      default_from: nil,
      default_reply_to: 'rsk@floorball.de',
      placeholders: [
        { key: 'referee_name', description: 'Vor- und Nachname des Schiris' }
      ]
    },
    'RefereeMailer#tentative_assignment_notification' => {
      mailer_class: 'RefereeMailer',
      action_name: 'tentative_assignment_notification',
      description: 'Vorläufige Ansetzung eines Schiris für einen Termin.',
      default_subject: 'Vorläufige Ansetzung – {{date}}',
      default_from: nil,
      default_reply_to: 'sr-ansetzungen@floorball.de',
      placeholders: [
        { key: 'date', description: 'Datum der Ansetzung (lang formatiert)' }
      ]
    },
    'RefereeMailer#published_assignment_notification' => {
      mailer_class: 'RefereeMailer',
      action_name: 'published_assignment_notification',
      description: 'Veröffentlichte Ansetzung eines Schiris für ein konkretes Spiel.',
      default_subject: 'Ansetzung – {{game_date}} {{home_team}} vs. {{guest_team}}',
      default_from: nil,
      default_reply_to: 'sr-ansetzungen@floorball.de',
      placeholders: [
        { key: 'game_date', description: 'Datum des Spieltags' },
        { key: 'home_team', description: 'Name der Heimmannschaft' },
        { key: 'guest_team', description: 'Name der Gastmannschaft' },
        { key: 'coach_name', description: 'Name des/der Schiedsrichtercoach/in (leer, falls keine/r angesetzt)' }
      ]
    },
    'RefereeMailer#published_coach_notification' => {
      mailer_class: 'RefereeMailer',
      action_name: 'published_coach_notification',
      description: 'Veröffentlichte Ansetzung an den/die Schiedsrichtercoach/in (mit Lizenzlisten und Spieltag-Details).',
      default_subject: 'Schiedsrichtercoach-Ansetzung – {{game_date}} {{home_team}} vs. {{guest_team}}',
      default_from: nil,
      default_reply_to: 'sr-ansetzungen@floorball.de',
      placeholders: [
        { key: 'game_date', description: 'Datum des Spieltags' },
        { key: 'home_team', description: 'Name der Heimmannschaft' },
        { key: 'guest_team', description: 'Name der Gastmannschaft' },
        { key: 'officials', description: 'Namen der angesetzten Schiedsrichter/innen' }
      ]
    },
    'RefereeMailer#updated_assignment_notification' => {
      mailer_class: 'RefereeMailer',
      action_name: 'updated_assignment_notification',
      description: 'Änderung der Besetzung einer bereits veröffentlichten Ansetzung – an alte und neue Schiris/Coach.',
      default_subject: 'Ansetzung geändert – {{game_date}} {{home_team}} vs. {{guest_team}}',
      default_from: nil,
      default_reply_to: 'sr-ansetzungen@floorball.de',
      placeholders: [
        { key: 'game_date', description: 'Datum des Spieltags' },
        { key: 'home_team', description: 'Name der Heimmannschaft' },
        { key: 'guest_team', description: 'Name der Gastmannschaft' },
        { key: 'officials', description: 'Namen der aktuell angesetzten Schiedsrichter/innen' },
        { key: 'coach_name', description: 'Name des/der Schiedsrichtercoach/in (leer, falls keine/r angesetzt)' }
      ]
    },
    'RefereeMailer#incident_report_reminder' => {
      mailer_class: 'RefereeMailer',
      action_name: 'incident_report_reminder',
      description: 'Erinnerung an die Schiris, das Berichtsformular fristgerecht einzureichen.',
      default_subject: 'Spielnummer {{game_number}} | 24h Zeit für Berichtsformular',
      default_from: nil,
      default_reply_to: nil,
      placeholders: [
        { key: 'game_number', description: 'Spielnummer' }
      ]
    },
    'RefereeMailer#referee_report_to_vsk' => {
      mailer_class: 'RefereeMailer',
      action_name: 'referee_report_to_vsk',
      description: 'Weiterleitung des eingereichten Berichtsformulars an die VSK/SBK (mit PDF-Anhang).',
      default_subject: 'Berichtsformular eingereicht – Spielnummer {{game_number}}',
      default_from: nil,
      default_reply_to: nil,
      placeholders: [
        { key: 'game_number', description: 'Spielnummer' }
      ]
    },
    'TransferRequestMailer#new_request_to_former_club' => {
      mailer_class: 'TransferRequestMailer',
      action_name: 'new_request_to_former_club',
      description: 'Neue Transfer-/Freigabe-Anfrage an den abgebenden Verein und den Spieler.',
      default_subject: 'Neue {{request_noun}}: {{player_name}}',
      default_from: nil,
      default_reply_to: nil,
      placeholders: [
        { key: 'request_noun', description: 'Bezeichnung der Anfrage (Transferanfrage/Spielerfreigabe-Anfrage)' },
        { key: 'player_name', description: 'Vor- und Nachname des Spielers' }
      ]
    },
    'TransferRequestMailer#player_confirmation_request' => {
      mailer_class: 'TransferRequestMailer',
      action_name: 'player_confirmation_request',
      description: 'Anfrage an den Spieler, dem Transfer/der Freigabe zuzustimmen.',
      default_subject: '{{request_noun}}: Deine Zustimmung wird benoetigt - {{player_name}}',
      default_from: nil,
      default_reply_to: nil,
      placeholders: [
        { key: 'request_noun', description: 'Bezeichnung der Anfrage (Transferanfrage/Spielerfreigabe-Anfrage)' },
        { key: 'player_name', description: 'Vor- und Nachname des Spielers' }
      ]
    },
    'TransferRequestMailer#pending_lv_notification' => {
      mailer_class: 'TransferRequestMailer',
      action_name: 'pending_lv_notification',
      description: 'Benachrichtigung an den Landesverband, dass ein Antrag zur Genehmigung vorliegt.',
      default_subject: '{{request_noun}} zur Genehmigung: {{player_name}}',
      default_from: nil,
      default_reply_to: nil,
      placeholders: [
        { key: 'request_noun', description: 'Bezeichnung des Antrags (Transferantrag/Spielerfreigabe-Antrag)' },
        { key: 'player_name', description: 'Vor- und Nachname des Spielers' }
      ]
    },
    'TransferRequestMailer#clubs_informed_lv_pending' => {
      mailer_class: 'TransferRequestMailer',
      action_name: 'clubs_informed_lv_pending',
      description: 'Information an die Vereine und den Spieler, dass der Antrag beim Landesverband liegt.',
      default_subject: '{{request_noun}} liegt beim Landesverband: {{player_name}}',
      default_from: nil,
      default_reply_to: nil,
      placeholders: [
        { key: 'request_noun', description: 'Bezeichnung des Antrags (Transferantrag/Spielerfreigabe-Antrag)' },
        { key: 'player_name', description: 'Vor- und Nachname des Spielers' }
      ]
    },
    'TransferRequestMailer#secondary_club_notification' => {
      mailer_class: 'TransferRequestMailer',
      action_name: 'secondary_club_notification',
      description: 'Information an einen Zweitverein, dass Zusatzlizenz/Freigabe durch einen Transfer entzogen wurde.',
      default_subject: 'Zusatzlizenz/Freigabe entzogen durch Transfer: {{player_name}}',
      default_from: nil,
      default_reply_to: nil,
      placeholders: [
        { key: 'player_name', description: 'Vor- und Nachname des Spielers' }
      ]
    },
    'TransferRequestMailer#transfer_completed' => {
      mailer_class: 'TransferRequestMailer',
      action_name: 'transfer_completed',
      description: 'Bestätigung an Vereine, Spieler und abgebenden LV, dass der Transfer/die Freigabe vollzogen wurde.',
      default_subject: '{{completion_noun}}: {{player_name}}',
      default_from: nil,
      default_reply_to: nil,
      placeholders: [
        { key: 'completion_noun', description: 'Abschluss-Bezeichnung (Transfer vollzogen/Spielerfreigabe erteilt)' },
        { key: 'player_name', description: 'Vor- und Nachname des Spielers' }
      ]
    },
    'TransferRequestMailer#transfer_completed_receiving_lv' => {
      mailer_class: 'TransferRequestMailer',
      action_name: 'transfer_completed_receiving_lv',
      description: 'Bestätigung an den aufnehmenden Landesverband, dass der Transfer/die Freigabe vollzogen wurde.',
      default_subject: '{{completion_noun}}: {{player_name}}',
      default_from: nil,
      default_reply_to: nil,
      placeholders: [
        { key: 'completion_noun', description: 'Abschluss-Bezeichnung (Transfer vollzogen (aufnehmender LV)/Spielerfreigabe erteilt (aufnehmender LV))' },
        { key: 'player_name', description: 'Vor- und Nachname des Spielers' }
      ]
    },
    'TransferRequestMailer#rejected_notification' => {
      mailer_class: 'TransferRequestMailer',
      action_name: 'rejected_notification',
      description: 'Benachrichtigung an den anfragenden Verein, dass der Antrag abgelehnt wurde.',
      default_subject: '{{request_noun}} abgelehnt: {{player_name}}',
      default_from: nil,
      default_reply_to: nil,
      placeholders: [
        { key: 'request_noun', description: 'Bezeichnung des Antrags (Transferantrag/Spielerfreigabe-Antrag)' },
        { key: 'player_name', description: 'Vor- und Nachname des Spielers' }
      ]
    },
    'TransferRequestMailer#player_rejected_clubs_notification' => {
      mailer_class: 'TransferRequestMailer',
      action_name: 'player_rejected_clubs_notification',
      description: 'Benachrichtigung an die Vereine, dass der Spieler den Antrag abgelehnt hat.',
      default_subject: '{{request_noun}} abgelehnt durch Spieler: {{player_name}}',
      default_from: nil,
      default_reply_to: nil,
      placeholders: [
        { key: 'request_noun', description: 'Bezeichnung des Antrags (Transferantrag/Spielerfreigabe-Antrag)' },
        { key: 'player_name', description: 'Vor- und Nachname des Spielers' }
      ]
    },
    'GameMailer#checklist_confirmation' => {
      mailer_class: 'GameMailer',
      action_name: 'checklist_confirmation',
      description: 'Bestätigung an den Ausrichterverein über den eingereichten Spielbericht (mit Veto-Link).',
      default_subject: 'Spielbericht Nr. {{game_number}} eingereicht – {{home_team}} vs. {{guest_team}}',
      default_from: nil,
      default_reply_to: nil,
      placeholders: [
        { key: 'game_number', description: 'Spielnummer' },
        { key: 'home_team', description: 'Name der Heimmannschaft' },
        { key: 'guest_team', description: 'Name der Gastmannschaft' }
      ]
    },
    'GameMailer#checklist_referee_portal_notice' => {
      mailer_class: 'GameMailer',
      action_name: 'checklist_referee_portal_notice',
      description: 'Hinweis an die Schiris, den Spieltag im Portal zu bestätigen.',
      default_subject: 'Spieltag bestätigen – {{home_team}} vs. {{guest_team}}',
      default_from: nil,
      default_reply_to: nil,
      placeholders: [
        { key: 'home_team', description: 'Name der Heimmannschaft' },
        { key: 'guest_team', description: 'Name der Gastmannschaft' }
      ]
    },
    'GameMailer#checklist_veto_notification' => {
      mailer_class: 'GameMailer',
      action_name: 'checklist_veto_notification',
      description: 'Benachrichtigung über einen eingereichten Einspruch zum Spielbericht.',
      default_subject: 'Einspruch eingereicht – Spielbericht Nr. {{game_number}} – {{home_team}} vs. {{guest_team}}',
      default_from: nil,
      default_reply_to: nil,
      placeholders: [
        { key: 'game_number', description: 'Spielnummer' },
        { key: 'home_team', description: 'Name der Heimmannschaft' },
        { key: 'guest_team', description: 'Name der Gastmannschaft' }
      ]
    },
    'GameDayMailer#referee_checklist_veto' => {
      mailer_class: 'GameDayMailer',
      action_name: 'referee_checklist_veto',
      description: 'Information an die SBK, dass ein Schiri einen Spieltag als nicht ordnungsgemäß gemeldet hat.',
      default_subject: 'Spieltag nicht ordnungsgemäß gemeldet – {{league_name}} am {{game_day_date}}',
      default_from: nil,
      default_reply_to: nil,
      placeholders: [
        { key: 'league_name', description: 'Name der Liga' },
        { key: 'game_day_date', description: 'Datum des Spieltags' }
      ]
    },
    'GameDayMailer#team_checklist_veto' => {
      mailer_class: 'GameDayMailer',
      action_name: 'team_checklist_veto',
      description: 'Information an die SBK, dass eine Gastmannschaft einen Spieltag als nicht ordnungsgemäß gemeldet hat.',
      default_subject: 'Spieltag nicht ordnungsgemäß gemeldet – {{league_name}} am {{game_day_date}}',
      default_from: nil,
      default_reply_to: nil,
      placeholders: [
        { key: 'league_name', description: 'Name der Liga' },
        { key: 'game_day_date', description: 'Datum des Spieltags' }
      ]
    },
    'GameDayMailer#published_referees_to_host' => {
      mailer_class: 'GameDayMailer',
      action_name: 'published_referees_to_host',
      description: 'Zusammenfassung an den Ausrichter, sobald alle Spiele eines Spieltags veröffentlichte Schiedsrichter-Ansetzungen haben.',
      default_subject: 'Schiedsrichteransetzungen – {{league_name}} am {{game_day_date}}',
      default_from: nil,
      default_reply_to: 'sr-ansetzungen@floorball.de',
      placeholders: [
        { key: 'league_name', description: 'Name der Liga' },
        { key: 'game_day_date', description: 'Datum des Spieltags' }
      ]
    },
    'GameDayMailer#updated_referees_to_host' => {
      mailer_class: 'GameDayMailer',
      action_name: 'updated_referees_to_host',
      description: 'Hinweis an den Ausrichter, dass sich die Schiedsrichter-/Coach-Besetzung eines bereits veröffentlichten Spiels geändert hat.',
      default_subject: 'Schiedsrichteransetzung geändert – {{league_name}} am {{game_day_date}}',
      default_from: nil,
      default_reply_to: 'sr-ansetzungen@floorball.de',
      placeholders: [
        { key: 'league_name', description: 'Name der Liga' },
        { key: 'game_day_date', description: 'Datum des Spieltags' }
      ]
    },
    'PlayerMailer#express_license_requested' => {
      mailer_class: 'PlayerMailer',
      action_name: 'express_license_requested',
      description: 'Benachrichtigung an die SBK über eine beantragte Expresslizenz.',
      default_subject: 'Expresslizenz beantragt: {{player_name}} ({{team_name}})',
      default_from: nil,
      default_reply_to: nil,
      placeholders: [
        { key: 'player_name', description: 'Vor- und Nachname des Spielers' },
        { key: 'team_name', description: 'Name der Mannschaft' }
      ]
    },
    'PlayerMailer#license_approved' => {
      mailer_class: 'PlayerMailer',
      action_name: 'license_approved',
      description: 'Benachrichtigung an den Spieler über die erteilte Lizenz.',
      default_subject: 'Lizenz erteilt – {{team_name}} ({{league_name}}) - {{season}}',
      default_from: nil,
      default_reply_to: nil,
      placeholders: [
        { key: 'team_name', description: 'Name der Mannschaft' },
        { key: 'league_name', description: 'Name der Liga (sofern vorhanden)' },
        { key: 'season', description: 'Name der Saison' }
      ]
    }
  }.freeze

  def self.entries
    ENTRIES.values
  end

  def self.find(mailer_class, action_name)
    ENTRIES["#{mailer_class}##{action_name}"]
  end

  # Roh-Quelltext des ERB-Views einer Action = Code-Default-Body, der verschickt
  # wird, solange kein eigener Body gepflegt ist. Dient der Admin-UI als Referenz
  # ("was geht aktuell raus?"). Bevorzugt das HTML-View, fällt auf das Text-View
  # zurück; nil, wenn kein View existiert.
  def self.default_body(mailer_class, action_name)
    dir = Rails.root.join('app', 'views', mailer_class.underscore)
    %w[html text].each do |type|
      path = dir.join("#{action_name}.#{type}.erb")
      return path.read if path.exist?
    end
    nil
  end
end
