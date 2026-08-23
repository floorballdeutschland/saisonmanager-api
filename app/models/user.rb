class User < ApplicationRecord
  include UserTracker

  LANGUAGES = %w[de en].freeze

  # Benutzernamen werden kleinschreibungsneutral geführt: Der Login vergleicht
  # gegen LOWER(user_name) (siehe self.login), daher darf ein Name sowohl in
  # Groß- als auch Kleinschreibung eingegeben werden. Erlaubt sind Buchstaben
  # (A–Z, a–z), Ziffern, Punkt, Bindestrich und Unterstrich; Empfehlung bleibt
  # vorname.nachname. Umlaute/ß und sonstige Sonderzeichen sind nicht erlaubt.
  # Bestandsnamen werden nicht umgeschrieben; die Format-Prüfung greift nur
  # beim Setzen oder Ändern des Namens.
  USER_NAME_FORMAT = /\A[a-zA-Z0-9._-]+\z/

  # Schiedsrichter-Selfservice-Rolle. Sie hängt am verknüpften Referee und ist
  # bewusst mit keiner anderen Rolle kombinierbar (siehe
  # referee_role_not_combined).
  REFEREE_ROLE_ID = 6

  # Welche Rollen ein Konto anderen Konten zuweisen darf, je eigener Rolle.
  # Quelle für die Rollenprüfung im Admin::UsersController und für die Auswahl
  # in der Benutzermaske (permissions_items). Die Admin-Rolle (1) darf nur Admin
  # selbst vergeben; SBK und RSK bleiben auf ihre eigene Ebene und darunter
  # beschränkt (der Verbund-Scope wird zusätzlich im Controller geprüft, ein
  # national gescoptes FD-Konto ist dort global).
  #
  # Ausnahme: Der VM-Zweig in Admin::UsersController#create prüft absichtlich
  # weiter selbst auf 4/5, weil er die Berechtigung vereinsgebunden und ohne
  # Verbund baut. Eine Rolle mit Verbund-Scope darf dort nicht durchlaufen, sie
  # landete sonst ohne game_operation_id und damit global im Konto.
  ASSIGNABLE_ROLE_IDS = {
    admin: [1, 2, 3, 4, 5, 6, 7],
    sbk: [2, 3, 4, 5, 7],
    rsk: [3, 7],
    vm: [4, 5]
  }.freeze

  has_secure_password
  before_validation :normalize_user_name
  validates :user_name, presence: true
  # Eindeutigkeit kleinschreibungsneutral prüfen, aber nur wenn der Name gesetzt
  # oder geändert wird. Sonst würde ein routinemäßiger Save (z. B. last_login_at
  # beim Login) an einer kleinschreibungsneutralen Alt-Dublette scheitern und
  # das betroffene Konto aussperren.
  validates :user_name,
            uniqueness: { case_sensitive: false },
            if: -> { user_name_changed? }
  # Format nur prüfen, wenn der Name gesetzt oder geändert wird. So kann kein
  # Bestandskonto mit Altnamen beim routinemäßigen Speichern (z. B.
  # last_login_at beim Login) an der Validierung scheitern und ausgesperrt
  # werden.
  validates :user_name,
            format: {
              with: USER_NAME_FORMAT,
              message: 'darf nur Buchstaben, Ziffern, Punkt, Bindestrich und Unterstrich enthalten (keine Umlaute, kein ß)'
            },
            if: -> { user_name.present? && user_name_changed? }
  validates :language, inclusion: { in: LANGUAGES }
  # Nur bei geänderten Rollen prüfen: Bestandskonten, die die Regel verletzen,
  # sollen sich weiter einloggen können (der Login speichert last_login_at) und
  # per Rollen-Entzug reparierbar bleiben.
  validate :referee_role_not_combined, if: -> { permissions_changed? }

  belongs_to :referee, optional: true

  scope :not_archived, -> { where(archived_at: nil) }

  def archived?
    archived_at.present?
  end

  # Archivierte Konten können sich nicht mehr einloggen (Prüfung in
  # ApplicationController#current_user bzw. SessionsController#login).
  def archive!(user_id)
    update!(archived_at: Time.current, archived_by: user_id)
  end

  def unarchive!
    update!(archived_at: nil, archived_by: nil)
  end

  def login_hash
    perms = permissions_items
    {
      id:,
      email:,
      pending_email: email_change_pending? ? pending_email : nil,
      username: user_name,
      name: fullname,
      # Einzelfelder zusätzlich zum zusammengesetzten name, damit der
      # Self-Service unter „Mein Konto" das Formular vorbelegen kann.
      first_name:,
      last_name:,
      permissions: perms,
      club_ids:,
      referee_id: referee_id,
      language:,
      receive_info_mails:,
      # Info-Mail-Opt-out ist NUR für Teammanager wählbar (nicht für VM o. a.).
      can_manage_mail_preferences: permission_hash[:tm].present?,
      login_blocked_message: login_blocked_message(perms)
    }
  end

  # Grund der TM-Sperre im Klartext, sonst nil. Die Sperre selbst wird nicht hier
  # entschieden, sondern in permissions_items (dort hängt sie an mehreren Rollen);
  # eine zweite Ableitung würde davon abdriften.
  #
  # Drei Ursachen, drei Texte. Ohne jede Zuordnung verwies der frühere
  # Einheitstext auf die Saison und schickte die Fehlersuche in die falsche
  # Richtung; zeigen die IDs auf gelöschte Teams, stimmt er ebenso nicht.
  # perms spart die zweite (teure) Auswertung, wenn der Aufrufer sie schon hat.
  def login_blocked_message(perms = permissions_items)
    return nil unless perms[:login_blocked]

    if teams.blank?
      'Deinem Konto ist kein Team zugewiesen. Bitte wende dich an den Vereinsmanager deines Vereins.'
    elsif !Team.where(id: teams).exists?
      'Die zugewiesenen Teams existieren nicht mehr. Bitte wende dich an den Vereinsmanager deines Vereins.'
    else
      'Keine Teams in der aktuellen Saison.'
    end
  end

  def fullname
    [first_name, last_name].join ' '
  end

  def full_with_username
    "#{fullname} (#{user_name})"
  end

  # Fehler, bei denen die Gegenstelle nicht erreichbar war oder die Zustellung
  # abgebrochen ist. Nur diese werden abgefangen: Sie gehen niemanden ausser
  # dem Aufrufer etwas an, treffen alle Nutzer gleichermassen zufaellig und
  # koennen beim naechsten Versuch klappen.
  #
  # Alles andere bleibt bewusst ein Serverfehler. Der Mailtext wird nicht aus
  # einer Datei gerendert, sondern von TemplatedMailer aus der Tabelle
  # email_templates geholt, die Admins unter /verwaltung/email-vorlagen
  # bearbeiten – und zwar erst innerhalb von deliver_now. Eine dort eingetragene
  # kaputte Absenderadresse oder ein defekter Platzhalter wuerde als
  # StandardError hier landen und den Passwort-Reset systemweit und dauerhaft
  # stumm ausser Betrieb setzen. Solche Fehler muessen laut auffallen.
  #
  # Die drei Net-Timeouts stehen einzeln in der Liste: Sie erben nicht von
  # IOError, sondern von Timeout::Error und darueber von RuntimeError. Ueber
  # IOError waeren sie nicht abgedeckt, und Timeout::Error als Ganzes zu fangen
  # waere zu weit gegriffen.
  #
  # Net::SMTPError ist ein Modul, kein Klasse; rescue prueft mit ===, das
  # funktioniert fuer Module genauso.
  MAIL_TRANSPORT_ERRORS = [
    Net::SMTPError, Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout,
    IOError, SocketError,
    Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, OpenSSL::SSL::SSLError
  ].freeze

  # Setzt ein frisches Reset-Token und verschickt den Link. Liefert zurück, ob
  # die Mail vom Mailserver angenommen wurde.
  #
  # Das setzt voraus, dass action_mailer.raise_delivery_errors aktiv ist
  # (config/environments/production.rb) – direkt darüber steht die
  # auskommentierte Gegenvariante. Wird die scharf geschaltet, schluckt
  # deliver_now den Fehler selbst, diese Methode liefert immer true, und der
  # ganze Rückgabewert wird still bedeutungslos. Kein Test schlägt dann an.
  #
  # Der Versand läuft synchron im Request (es gibt kein Job-Backend). Ein
  # hängender oder abweisender SMTP-Server darf den Aufrufer deshalb nicht mit
  # einem Serverfehler abbrechen: Das Token ist an dieser Stelle bereits
  # rotiert, beim Anlegen eines Kontos ist der Datensatz schon gespeichert. Der
  # Aufrufer entscheidet, ob der Fehlschlag sichtbar wird – die offene
  # „Passwort vergessen"-Route antwortet bewusst immer gleich, die Verwaltung
  # meldet ihn (Sentry SAISONMANAGER-1X).
  #
  # Das save steht ausserhalb des rescue: Ein Schreibfehler ist ein
  # Datenbankproblem und darf nicht als Mailproblem gemeldet werden.
  def send_reset_information
    self.password_reset_token = SecureRandom.uuid
    return false unless save(validate: false)

    begin
      UserMailer.reset_password(self).deliver_now
      true
    rescue *MAIL_TRANSPORT_ERRORS => e
      Rails.logger.error(
        "Passwort-Reset-Mail fehlgeschlagen (Transport) – User #{id}: #{e.class}: #{e.message}"
      )
      Sentry.capture_exception(e) if defined?(Sentry)
      false
    end
  end

  # --- E-Mail-Änderung mit Bestätigung (Double-Opt-In) ---------------------
  # Die neue Adresse wird als pending_email vorgemerkt und erst wirksam, wenn
  # der Bestätigungslink innerhalb der Frist geklickt wurde. Gespeichert wird
  # nur der SHA256-Digest des Tokens (analog GameDaySecretaryLink).

  EMAIL_CONFIRMATION_VALIDITY = 24.hours
  # Frühestens nach dieser Wartezeit darf dasselbe Konto die nächste
  # Bestätigungsmail anfordern (bremst Mail-Bombing an fremde Adressen –
  # Cookie-Requests laufen nicht durch die Rack::Attack-Key-Throttles).
  EMAIL_CONFIRMATION_RESEND_INTERVAL = 1.minute

  # Startet die Änderung und liefert das Roh-Token für den Mail-Link zurück.
  # Eine noch offene Änderung wird dabei überschrieben.
  def start_email_change!(new_email)
    raw_token = SecureRandom.urlsafe_base64(32)
    update!(
      pending_email: new_email,
      email_confirmation_token_digest: Digest::SHA256.hexdigest(raw_token),
      email_confirmation_expires_at: EMAIL_CONFIRMATION_VALIDITY.from_now
    )
    raw_token
  end

  def confirm_email_change!
    new_email = pending_email
    transaction do
      # Die operative Schiri-Adresse (Ansetzungen, RSK-Mails) zieht mit: Bei
      # Schiris mit Benutzerkonto ist „Mein Konto" die einzige Stelle, an der
      # die Adresse gepflegt wird (das Profil-Feld ist dort read-only).
      # save(validate: false): Es ändert sich nur die E-Mail (auf Referee
      # unvalidiert) – ein in anderen Feldern invalider Alt-Datensatz darf die
      # Bestätigung nicht mit schiri-fremden Fehlermeldungen abbrechen.
      if referee
        referee.email = new_email
        referee.save!(validate: false)
      end
      update!(
        email: new_email,
        pending_email: nil,
        email_confirmation_token_digest: nil,
        email_confirmation_expires_at: nil
      )
    end
  end

  def email_change_pending?
    pending_email.present? && email_confirmation_expires_at&.future?
  end

  # Zeitpunkt des letzten Anstoßens, abgeleitet aus dem Ablaufzeitpunkt
  # (spart ein eigenes sent_at-Feld).
  def email_change_started_at
    email_confirmation_expires_at && email_confirmation_expires_at - EMAIL_CONFIRMATION_VALIDITY
  end

  # Leere Tokens dürfen nie zu einem NULL-Vergleich werden (Account-Übernahme-
  # Falle, siehe UsersController#reset_password_token) – daher erst normalisieren.
  def self.find_by_email_confirmation_token(raw_token)
    token = raw_token.to_s.presence
    return nil unless token

    # not_archived: Wer zwischen Anstoßen und Bestätigen archiviert wurde, kann
    # sich nicht mehr einloggen – dann soll auch der Link nichts mehr ändern.
    not_archived
      .where('email_confirmation_expires_at > ?', Time.current)
      .find_by(email_confirmation_token_digest: Digest::SHA256.hexdigest(token))
  end

  # Wie send_reset_information, aber mit Begrüßungs-Mail (Benutzername + Link zum
  # erstmaligen Passwort-Setzen) für ein frisch angelegtes Schiedsrichter-Konto.
  #
  # deliver_later für die Massenanlage: Hundert Zustellungen im Request wären ein
  # Timeout, und der Abbruch träfe die Konten, die dann schon angelegt sind.
  # Liefert zurück, ob die Mail auf den Weg gebracht wurde.
  def send_referee_account_information(deliver_later: false)
    self.password_reset_token = SecureRandom.uuid
    return false unless save(validate: false)

    mail = UserMailer.referee_account_created(self)
    deliver_later ? mail.deliver_later : mail.deliver_now
    true
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def permissions_items
    result = {}
    ph = permission_hash

    has_tm_role = permissions.any? { |p| p['user_group_id'].to_i == 5 }
    has_schiri_role = permissions.any? { |p| p['user_group_id'].to_i == 6 }
    # Ein TM ohne Team wird nur dann für den Login gesperrt, wenn er/sie auch
    # sonst keine nutzbare Rolle hat. RSK, Ansetzer und die
    # Schiri-Selfservice-Rolle sind eigenständige Rollen und dürfen nicht
    # durch die TM-Sperre ausgesperrt werden (sonst greift der Early-Return
    # unten und alle Schiedsrichter-Rechte fehlen).
    tm_blocked = has_tm_role && ph[:tm].blank? &&
                 ph[:admin].blank? && ph[:sbk].blank? && ph[:vm].blank? &&
                 ph[:rsk].blank? && ph[:ansetzer].blank? && !has_schiri_role
    result[:login_blocked] = tm_blocked

    return result if tm_blocked

    if has_schiri_role && !ph[:admin].present? && !ph[:sbk].present? && !ph[:rsk].present? && !ph[:ansetzer].present? && !ph[:vm].present? && !ph[:tm].present?
      result[:menu_item_referee_profile] = true
      result[:show_page_referee_profile] = true
      return result
    end

    # Expliziter Admin-Boolean für das Frontend: Der ans Frontend gesendete
    # `permissions`-Hash ist dieser permissions_items-Hash (NICHT permission_hash),
    # daher braucht das Frontend hier einen eigenen Schlüssel, um „ist Admin?" zu
    # prüfen (z. B. für die Pflege bundesweiter Kataloge wie Lizenzstufen).
    result[:admin] = ph[:admin].present?

    # show league admin menu item
    result[:menu_item_league_admin] = ph[:admin].present? || ph[:sbk].present?
    # Vereinsverwaltung: Verband sieht seine Vereine, der Vereinsmanager den
    # eigenen. Was er darin ändern darf, regelt club_edit_restricted.
    result[:menu_item_club_admin] = ph[:admin].present? || ph[:sbk].present? || ph[:vm].present?
    # SBK-Übersicht „Spielberichte": Kontrolle der abgegebenen Berichte.
    result[:menu_item_match_report_admin] = ph[:admin].present? || ph[:sbk].present?
    # Ansprechpersonen der Vereine und Mannschaften: gleiche Ebene wie die
    # Ligaverwaltung – wer den Spielbetrieb führt, führt auch den Schriftverkehr.
    result[:menu_item_contact_admin] = ph[:admin].present? || ph[:sbk].present?
    result[:menu_item_player_admin] = ph[:admin].present? || ph[:sbk].present?
    result[:menu_item_player_admin_vm] = ph[:vm].present?

    result[:menu_item_licence_list] =
      ph[:admin].present? || ph[:sbk].present? || ph[:vm].present? || ph[:tm].present?
    result[:menu_item_licence_club_admin] = ph[:vm].present? || ph[:tm].present?
    result[:menu_item_licence_admin] = ph[:admin].present? || ph[:sbk].present?
    # Dokumentarten-Katalog (Lizenz-Pflichtdokumente): Admin global, SBK für den eigenen Verband
    result[:menu_item_document_type_admin] = ph[:admin].present? || ph[:sbk].present?
    has_full_referee_access = ph[:admin].present? || (ph[:rsk].present? && ph[:rsk].include?(0))
    # Schiedsrichterdaten (inkl. Lizenzlisten) sind dem Schiedsrichterwesen
    # vorbehalten: Admin und RSK. Ansetzer brauchen Lesezugriff für die
    # Ansetzung, bekommen aber – wie LV-RSK – nur eingeschränkten Zugriff (kein
    # Anlegen/Volledit). Die SBK (Spielbetrieb) hat hier bewusst KEINEN Zugriff.
    result[:menu_item_referee_admin] = ph[:admin].present? || ph[:rsk].present? || ph[:ansetzer].present?
    result[:referee_edit_restricted] = !has_full_referee_access if result[:menu_item_referee_admin]
    # Neue Schiedsrichter anlegen: nur Admin + FD-RSK (global). LV-RSK bearbeitet
    # nur Bestandsdaten.
    result[:referee_can_create] = has_full_referee_access if result[:menu_item_referee_admin]
    # Benutzerkonto für einen bestehenden Schiri anlegen: auch LV-RSK erlaubt.
    result[:referee_can_create_user] = ph[:admin].present? || ph[:rsk].present? if result[:menu_item_referee_admin]
    result[:referee_can_delete_user] = ph[:admin].present? if result[:menu_item_referee_admin]
    # E-Mail-Import und Massenanlage von Konten: Beides greift in einem Zug über
    # alle Verbände hinweg und bleibt daher der Verwaltung vorbehalten.
    result[:referee_account_tools] = ph[:admin].present? if result[:menu_item_referee_admin]
    # Ansetzungen macht die Ansetzer-Rolle (in manchen LV von der RSK getrennt).
    # Sichtbar nur, wenn die Ansetzungslogik für den Landesverband freigeschaltet
    # ist (referee_assignment_enabled). National (FD, ohne LV) ist immer aktiv.
    ansetzer_active = referee_assignment_active_for_ansetzer?(ph)
    # Weg 3: Wo ein Verband die Ansetzung außerhalb der SBK erlaubt, aber nicht
    # auf Personenebene, pflegt die RSK dieselbe Liste in einem reduzierten Modus
    # (Verein oder Freitext) – derselbe Menüpunkt, andere Ansicht.
    rsk_club_mode = referee_assignment_club_mode_for_rsk?(ph)
    result[:menu_item_referee_assignments] = ph[:admin].present? || ansetzer_active || rsk_club_mode
    # Sagt dem Frontend, welche der beiden Ansichten der Menüpunkt zeigt. Die
    # Personenebene gewinnt, damit sich nie beide Wege auf dasselbe Spiel legen:
    # wer in Verband A ansetzt und in Verband B RSK ist, bekommt die
    # personenscharfe Ansicht (zwei Reiter sind bewusst nicht gebaut, siehe #403).
    result[:referee_assignment_club_mode] = rsk_club_mode && !ansetzer_active && ph[:admin].blank?
    # Wochenend-Verfügbarkeitsübersicht der Schiris („war room") – gehört zur
    # personenscharfen Ansetzung (Weg 2) und bleibt deshalb an ansetzer_active
    # gebunden; im reduzierten Modus gibt es keine Verfügbarkeiten zu sichten.
    result[:menu_item_referee_availability] = ph[:admin].present? || ansetzer_active
    # Anträge der Schiris auf Vereins-Ausschlüsse und deren Pflege am Schiri-Profil
    # – dieselbe Rolle wie die Ansetzung, weil die Liste nur dort wirkt.
    result[:menu_item_referee_exclusions] = ph[:admin].present? || ansetzer_active
    # Korrekturanträge zu den Stammdaten (Name, Geburtsdatum, Verein) entscheidet
    # die RSK des zuständigen Landesverbands, nicht die Ansetzung: Es geht um
    # Stammdaten und nicht um Ansetzbarkeit.
    result[:menu_item_referee_change_requests] = ph[:admin].present? || ph[:rsk].present?
    # Strafcode-Verwaltung („Einstellungen" im Schiedsrichterwesen) – nur Admin.
    result[:menu_item_referee_settings] = ph[:admin].present?
    # Schiri-Feedback der Vereine ist nur am Schiri-Profil sichtbar – für Admin
    # sowie die global gescopten FD-Rollen (RSK/Ansetzer mit Spielbetrieb 0).
    result[:referee_feedback_view] =
      ph[:admin].present? ||
      (ph[:rsk].present? && ph[:rsk].include?(0)) ||
      (ph[:ansetzer].present? && ph[:ansetzer].include?(0))
    result[:menu_item_referee_course_import] = has_full_referee_access
    result[:menu_item_referee_course_review] = has_full_referee_access || lv_rsk_review_enabled?(ph)
    result[:menu_item_referee_vm] = ph[:vm].present?
    result[:menu_item_player_vm] = ph[:vm].present? || ph[:tm].present?
    # Portal „Meine Auswärtsspieltage" für Gastmannschafts-Bestätigung (TM/VM).
    # Der Menüpunkt erscheint nur, wenn für eine der verantworteten Mannschaften
    # überhaupt eine Spieltagscheckliste greift, denn ohne Checkliste gibt es
    # nichts zu bestätigen.
    result[:menu_item_team_game_days] = manages_game_day_checklist_team?(ph)
    # Der Zugriff auf die Seite bleibt bewusst rein rollenbasiert (Route-Guard im
    # Frontend). Grund: Der Berechtigungs-Hash entsteht beim Login und liegt
    # danach im localStorage. Legt ein Landesverband seine erste Checklistenfrage
    # mitten in der Saison an, wäre die Seite für bereits angemeldete TM/VM sonst
    # auch per Direktlink gesperrt – und die Bestätigung ist nur 48 Stunden lang
    # möglich, danach gilt ein Spieltag automatisch als bestätigt.
    result[:page_team_game_days] = ph[:tm].present? || ph[:vm].present?
    # Portal „Spielsekretariat" – Vereine geben sich selbst den Einmal-Link für
    # den Tisch. Rein rollenbasiert wie page_team_game_days: ob für einen
    # konkreten Spieltag ein Link erzeugt werden darf, entscheidet ohnehin erst
    # der Endpunkt (GameDaySecretaryLinksController). Admin und SBK erzeugen ihre
    # Links weiterhin in der Spielplan-Verwaltung, für sie wäre die Liste der
    # halbe Spielplan – sie bekommen den Menüpunkt deshalb nicht über die Rolle.
    result[:menu_item_secretary_links] = ph[:tm].present? || ph[:vm].present?
    result[:page_secretary_links] = ph[:tm].present? || ph[:vm].present?
    # Portal „Schiri-Feedback" – verpflichtende Rückmeldung der Vereine nach dem
    # Spiel. Nur sichtbar, wenn der/die Nutzer:in tatsächlich eine Mannschaft in
    # einer feedback-pflichtigen Liga (referee_feedback_enabled, z. B. 1. BL)
    # verantwortet – als TM (eigene Teams) oder VM (Teams des eigenen Vereins).
    result[:menu_item_referee_feedback] = manages_referee_feedback_team?(ph)
    # Globaler Admin und global gescopter SBK (z. B. FD-SBK, ph[:sbk] enthält 0)
    # bekommen den vollen Verbandsverwaltungs-View über alle Landesverbände.
    global_sbk = ph[:sbk].present? && ph[:sbk].include?(0)
    result[:menu_item_state_association_admin] = ph[:admin].present? || global_sbk
    result[:menu_item_state_association_sbk] = sbk_state_association_menu_item?(ph)
    # Anlegen/Löschen ganzer Landesverbände sowie das Umhängen des übergeordneten
    # Verbands bleiben globalen Admins vorbehalten (Backend: authorize_admin! /
    # parent_id-Strip). Der globale SBK verwaltet alle LVs, aber nicht deren Lebenszyklus.
    result[:state_association_manage_lifecycle] = ph[:admin].present?
    # Spielbetriebe anlegen und pflegen: nur BUNDESWEITE Admins, also `0` im
    # Scope. Strenger als jeder andere Punkt hier, weil an einem Spielbetrieb
    # zwei Felder haengen, die Rechte verschieben: `state_association_id` holt
    # die Vereine eines fremden Verbandsbaums herueber, `national` hebt SBK, RSK
    # und Ansetzer dieses Spielbetriebs auf globalen Scope. Begruendung im
    # Langen an Admin::GameOperationsController.
    result[:menu_item_game_operation_admin] = ph[:admin].present? && ph[:admin].include?(0)
    result[:menu_item_api_key_admin] = ph[:admin].present?
    result[:menu_item_transfer_requests] = ph[:admin].present? || ph[:sbk].present? || ph[:vm].present?
    result[:menu_item_transfer_requests_sbk] = ph[:admin].present? || ph[:sbk].present?
    # SBK-Menüpunkt „Verfahrensvorschläge" (manueller VSK-Workflow). Nur
    # sichtbar, wenn mindestens einer der zugeordneten Landesverbände die
    # manuelle Verfahrenseröffnung aktiviert hat – sonst gehen die Berichte
    # automatisch an die VSK und der Menüpunkt bliebe dauerhaft leer.
    result[:menu_item_proceeding_proposal_admin] = ph[:admin].present? || manual_proceeding_active_for_sbk?(ph)
    result[:menu_item_player_change_requests] = ph[:admin].present? || ph[:sbk].present? || ph[:vm].present?
    result[:create_player_change_request] = ph[:vm].present? || ph[:admin].present?
    result[:approve_player_change_request] = ph[:admin].present? || ph[:sbk].present?
    # RSK verwaltet die eigenen Schiedsrichterwesen-Konten (RSK/Ansetzer) selbst;
    # der Scope steckt in scoped_users bzw. require_admin_for_elevated_target!.
    result[:menu_item_user_admin] = ph[:admin].present? || ph[:sbk].present? || ph[:rsk].present?
    result[:user_delete] = ph[:admin].present?
    # Mehrfachrollen (Rollen je Konto hinzufügen/entfernen, z. B. RSK + Ansetzer).
    # Welche Rolle dabei vergeben werden darf, sagen die assign_role_*-Flags.
    result[:manage_user_roles] = ph[:admin].present? || ph[:sbk].present? || ph[:rsk].present?
    # VM dürfen TM-/VM-Konten im Scope ihres Vereins anlegen (Backend:
    # UsersController#create + authorize_user_management!).
    result[:menu_item_user_create] =
      ph[:admin].present? || ph[:sbk].present? || ph[:rsk].present? || ph[:vm].present?
    # Welche Rollen die Maske zur Auswahl stellen darf. Einzeln als Boolean,
    # weil der ans Frontend gehende permissions-Hash flach ist; Quelle der
    # Wahrheit ist ASSIGNABLE_ROLE_IDS, geprüft wird serverseitig im
    # Admin::UsersController.
    assignable = assignable_role_ids(ph)
    result[:assign_role_admin]    = assignable.include?(1)
    result[:assign_role_sbk]      = assignable.include?(2)
    result[:assign_role_rsk]      = assignable.include?(3)
    result[:assign_role_vm]       = assignable.include?(4)
    result[:assign_role_tm]       = assignable.include?(5)
    result[:assign_role_ansetzer] = assignable.include?(7)
    result[:menu_item_user_vm] = ph[:vm].present?
    result[:menu_item_arena_admin] = ph[:admin].present? || ph[:sbk].present?
    # Spielorte löschen/zusammenführen ist destruktiv und verbandsübergreifend
    # (merge hängt Spieltage anderer Verbände um) – nur Admin und die global
    # gescopte FD-SBK (global_sbk); regionale SBK bleiben ausgeschlossen (Backend:
    # Admin::ArenasController#authorize_arena_lifecycle!, #62).
    result[:arena_manage_lifecycle] = ph[:admin].present? || global_sbk
    result[:menu_item_season_admin] = ph[:admin].present?
    result[:menu_item_analytics_admin] = ph[:admin].present?
    result[:menu_item_email_log_admin] = ph[:admin].present?
    result[:menu_item_email_template_admin] = ph[:admin].present?
    # Betriebszustand des Servers (Speicherplatz, Uploads, Datenbankgröße). Reine
    # Serverinnenansicht ohne fachlichen Bezug, daher nur Admin.
    result[:menu_item_system_health] = ph[:admin].present?

    # show permissions
    result[:show_league_index_admin] = ph[:admin].present? || ph[:sbk].present?

    # update permissions
    result[:update_player] = ph[:admin].present? || ph[:sbk].present?
    # Bedingungslos wahr und deshalb keine Antwort auf die Frage, wer anlegen
    # darf: Das Flag schaltet im Spielerformular nur die Beschriftung des
    # Anlegen-Modus. Die echte Entscheidung ist vereinsgebunden und fällt in
    # `Club#user_permissions` (:create_player), geprüft in
    # PlayersController#admin_player_update.
    result[:create_player] = true
    result[:player_transfer] = ph[:admin].present? || ph[:sbk].present?
    result[:player_add_additional_clubs] = ph[:admin].present? || ph[:sbk].present?
    result[:player_remove_additional_clubs] = ph[:admin].present? || ph[:sbk].present?

    result[:player_deactivate] = ph[:admin].present? || ph[:sbk].present? || ph[:vm].present? || ph[:tm].present?
    result[:update_player_email] = ph[:vm].present? || ph[:tm].present?
    result[:player_set_license_to_transfer] = ph[:admin].present?
    # Erst-/Zweitlizenz-Zuordnung (GF-Erwachsenenbereich) setzen/tauschen
    result[:player_set_gf_role] = ph[:admin].present? || ph[:sbk].present?
    result[:player_merge] = ph[:admin].present? || ph[:sbk].present?
    result[:player_suspend] = ph[:admin].present? || ph[:sbk].present?
    result[:referee_merge] = ph[:admin].present? || ph[:rsk].present?

    result[:club_deactivate] = ph[:admin].present? || ph[:sbk].present?
    # Vereinsanlage bleibt beim Verband: Der Landesverband entscheidet, wer den
    # Verein verwaltet, und den kann der Vereinsmanager nicht setzen.
    result[:club_create] = ph[:admin].present? || ph[:sbk].present?
    # Eingeschränktes Vereinsformular: Bundesland, Landesverband und
    # Spielbetrieb ordnen den Verein ein und bleiben dem Verband vorbehalten
    # (Gegenstück zu ClubsController#restricted_club_params).
    result[:club_edit_restricted] = !(ph[:admin].present? || ph[:sbk].present?)
    result[:team_delete] = ph[:admin].present? || ph[:sbk].present?

    result
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def club_ids
    permission_hash[:vm]
  end

  def sbk_state_association_menu_item?(perm_hash)
    !perm_hash[:admin].present? &&
      perm_hash[:sbk].present? &&
      !perm_hash[:sbk]&.include?(0)
  end

  # LV-RSK sieht die Kursergebnis-Freigabe nur, wenn mindestens einer seiner
  # Landesverbände den Kontrollprozess aktiviert hat
  # (effective_referee_license_review_enabled). Admin/globaler FD-RSK sind über
  # has_full_referee_access bereits abgedeckt.
  def lv_rsk_review_enabled?(perm_hash)
    go_ids = perm_hash[:rsk].to_a.reject(&:zero?)
    return false if go_ids.empty?

    sa_ids = GameOperation.where(id: go_ids).pluck(:state_association_id).compact.uniq
    StateAssociation.where(id: sa_ids).any?(&:effective_referee_license_review_enabled)
  end

  # True, wenn die Ansetzungslogik für den/die Ansetzer:in aktiv ist. Globale
  # (nationale, FD-)Ansetzer (Spielbetrieb 0) sind immer aktiv; sonst muss
  # mindestens einer der zugeordneten Landesverbände referee_assignment_enabled
  # gesetzt haben.
  def referee_assignment_active_for_ansetzer?(perm_hash)
    return false unless perm_hash[:ansetzer].present?
    return true if perm_hash[:ansetzer].include?(0)

    referee_assignment_mode_reached?(perm_hash[:ansetzer], :person)
  end

  # True, wenn die RSK den reduzierten Modus (Weg 3: Verein oder Freitext) sieht:
  # mindestens einer der zugeordneten Landesverbände hat den Hauptschalter aktiv
  # und die Personenebene aus. Ist die Personenebene an, setzt dort die
  # Ansetzer-Rolle an und die RSK bekommt den Punkt über diesen Weg nicht.
  #
  # Global (Spielbetrieb 0) gescopte RSK und der nationale Spielbetrieb liegen
  # immer auf der Personenebene, also nie im reduzierten Modus.
  def referee_assignment_club_mode_for_rsk?(perm_hash)
    return false if perm_hash[:rsk].blank?
    return false if perm_hash[:rsk].include?(0)

    referee_assignment_mode_reached?(perm_hash[:rsk], :club)
  end

  # Hat mindestens einer der Landesverbände hinter diesen Spielbetrieben den
  # gesuchten Ansetzungsmodus? Die Auswertung der drei gestaffelten Schalter liegt
  # ausschließlich in StateAssociation#referee_assignment_mode – hier wird nur
  # gefragt, nie selbst kombiniert.
  def referee_assignment_mode_reached?(go_ids, mode)
    sa_ids = GameOperation.where(id: go_ids).pluck(:state_association_id).compact.uniq
    return false if sa_ids.empty?

    StateAssociation.where(id: sa_ids).any? { |sa| sa.referee_assignment_mode == mode }
  end

  # True, wenn für die SBK überhaupt Verfahrensvorschläge entstehen können: Der
  # zugehörige Landesverband muss die manuelle Verfahrenseröffnung aktiviert
  # haben (ProceedingProposal wird sonst gar nicht erst erzeugt, siehe
  # GameRefereeReportsController#_send_to_vsk). Die global gescopte FD-SBK
  # (Spielbetrieb 0) sieht den Punkt, sobald irgendein Verband ihn nutzt.
  def manual_proceeding_active_for_sbk?(perm_hash)
    return false if perm_hash[:sbk].blank?

    # Kein `where(manual_proceeding_creation: true)` mehr: Ein untergeordneter
    # Landesverband erbt den Schalter vom übergeordneten Verbund, in seiner
    # eigenen Zeile steht dann false – und umgekehrt ist ein dort stehendes true
    # nach dem Anhängen eines Verbunds nur noch ein Überbleibsel und darf den
    # Menüpunkt nicht mehr einblenden. Rund 15 Datensätze, das Laden kostet
    # weniger als die Vererbung in SQL nachzubauen; die Kette selbst löst
    # StateAssociation#settings_source über den je Request zwischengespeicherten
    # Verbandsbaum auf, hier ist also kein eigenes Vorladen nötig.
    return StateAssociation.all.any?(&:effective_manual_proceeding_creation) if perm_hash[:sbk].include?(0)

    sa_ids = GameOperation.where(id: perm_hash[:sbk]).pluck(:state_association_id).compact.uniq
    StateAssociation.where(id: sa_ids).any?(&:effective_manual_proceeding_creation)
  end

  # True, wenn der/die Nutzer:in mindestens eine Mannschaft verantwortet, die in
  # einer feedback-pflichtigen Liga der aktuellen Saison aktiv ist (TM: eigene
  # Teams; VM: Teams des eigenen Vereins). Berücksichtigt auch Pokal-/Zusatzligen
  # eines Teams (Team#all_league_ids).
  def manages_referee_feedback_team?(perm_hash)
    return false unless perm_hash[:tm].present? || perm_hash[:vm].present?

    enabled_league_ids = League.current_season.where(referee_feedback_enabled: true).pluck(:id)
    return false if enabled_league_ids.empty?

    team_ids = Array(perm_hash[:tm])
    team_ids += Team.where(club_id: Array(perm_hash[:vm])).pluck(:id) if perm_hash[:vm].present?
    return false if team_ids.empty?

    Team.where(id: team_ids).any? { |team| (team.all_league_ids & enabled_league_ids).present? }
  end

  # True, wenn der/die Nutzer:in mindestens eine Mannschaft verantwortet, die in
  # der aktuellen Saison in einem Spielbetrieb spielt, dessen Landesverband eine
  # Spieltagscheckliste hinterlegt hat (mindestens eine Frage). Ohne Checkliste
  # gibt es am Spieltag nichts zu bestätigen (siehe
  # TeamGameDayConfirmationsController#checklist_items_for), der Menüpunkt bleibt
  # dann verborgen. Aufbau analog zu manages_referee_feedback_team?, inklusive
  # Pokal-/Zusatzligen eines Teams (Team#all_league_ids).
  def manages_game_day_checklist_team?(perm_hash)
    return false unless perm_hash[:tm].present? || perm_hash[:vm].present?

    # Kein `distinct` auf der Relation: der default_scope sortiert nach
    # position/id, was zusammen mit SELECT DISTINCT in Postgres scheitert.
    sa_ids = StateAssociationChecklistItem.pluck(:state_association_id).uniq
    return false if sa_ids.empty?

    go_ids = GameOperation.where(state_association_id: sa_ids).pluck(:id)
    checklist_league_ids = go_ids.present? ? League.current_season.where(game_operation_id: go_ids).pluck(:id) : []
    return false if checklist_league_ids.empty?

    team_ids = Array(perm_hash[:tm])
    team_ids += Team.where(club_id: Array(perm_hash[:vm])).pluck(:id) if perm_hash[:vm].present?
    return false if team_ids.empty?

    Team.where(id: team_ids).any? { |team| (team.all_league_ids & checklist_league_ids).present? }
  end

  def permission_hash
    result = {}

    tm_team_ids = []
    vm_club_ids = []
    sbk_go_ids = []
    rsk_go_ids = []
    ans_go_ids = []
    admin_go_ids = []

    all_league_ids = League.current_season.pluck(:id)

    permissions.each do |perm|
      go_id = perm['game_operation_id'].to_i

      case perm['user_group_id'].to_i
      when 5 # Teammanager
        tm_team_ids << Team.where(id: teams, league_id: all_league_ids).pluck(:id)
      when 4 # Vereinsmanager
        vm_club_ids << perm['club_id'].to_i if perm['club_id'].present?
      when 7 # Ansetzer
        ans_go_ids << go_id
      when 3 # RSK
        rsk_go_ids << go_id
      when 2 # SBK
        sbk_go_ids << go_id
      when 1 # Admin
        admin_go_ids << go_id
      when 6 # Schiedsrichter (self-service, no go_id needed)
        nil
      end
    end

    tm_team_ids.flatten!
    tm_team_ids.uniq!
    tm_team_ids.sort!
    rsk_go_ids.sort!.uniq!
    ans_go_ids.sort!.uniq!
    sbk_go_ids.sort!.uniq!
    admin_go_ids.sort!.uniq!

    # SBK/RSK/Ansetzer for a national-level GO (e.g. FD) gets global scope.
    # "National" is marked explicitly via GameOperation#national — it can no
    # longer be inferred from a missing state_association_id, since the FD
    # GameOperation is linked to its StateAssociation (for the federation logo).
    if sbk_go_ids.any? && !sbk_go_ids.include?(0) && GameOperation.where(id: sbk_go_ids, national: true).exists?
      sbk_go_ids = [0]
    end
    if rsk_go_ids.any? && !rsk_go_ids.include?(0) && GameOperation.where(id: rsk_go_ids, national: true).exists?
      rsk_go_ids = [0]
    end
    if ans_go_ids.any? && !ans_go_ids.include?(0) && GameOperation.where(id: ans_go_ids, national: true).exists?
      ans_go_ids = [0]
    end

    # Alle vorhandenen Spielbetriebe, und nicht mehr eine im Code gepflegte
    # Liste: Seit Spielbetriebe ueber die Oberflaeche entstehen (#492),
    # verschiebt jeder neue diesen Vergleich. Eine Rolle, die jeden einzelnen
    # Spielbetrieb aufzaehlt statt `0` zu tragen, fiele mit dem naechsten neuen
    # aus dem globalen Scope -- und verlöre dabei genau den Menuepunkt, ueber
    # den der neue Spielbetrieb angelegt wurde
    # (menu_item_game_operation_admin verlangt `0`).
    #
    # GameOperation.by_id ist je Request einmal geladen (Current), die Ableitung
    # kostet also keine zusaetzliche Abfrage.
    all_go = GameOperation.by_id.keys.sort

    result[:tm] = tm_team_ids if tm_team_ids.present?
    result[:vm] = vm_club_ids.uniq.sort if vm_club_ids.present?
    result[:rsk] = (all_go == rsk_go_ids ? [0] : rsk_go_ids) if rsk_go_ids.present?
    result[:ansetzer] = (all_go == ans_go_ids ? [0] : ans_go_ids) if ans_go_ids.present?
    result[:sbk] = (all_go == sbk_go_ids ? [0] : sbk_go_ids) if sbk_go_ids.present?
    result[:admin] = (all_go == admin_go_ids ? [0] : admin_go_ids) if admin_go_ids.present?

    result
  end

  def self.login(login, password)
    return nil if login.blank? || password.blank?

    # Login ausschließlich per Benutzername, kleinschreibungsneutral. Der
    # eingehende Wert ist bereits kleingeschrieben (SessionsController); wir
    # vergleichen daher gegen LOWER(user_name), damit auch Bestandsnamen mit
    # Großbuchstaben anmeldbar sind.
    #
    # Die E-Mail-Adresse ist bewusst KEINE Login-Kennung: Sie darf mehrfach
    # vergeben sein (Schiri- und Vereinsmanager-Konto derselben Person, mehrere
    # Vereinsmanager an einem Vereins-Sammelpostfach). Ein E-Mail-Login würde
    # bei jeder solchen Doppelvergabe still aufhören zu funktionieren.
    user = User.where('LOWER(user_name) = ?', login.to_s.downcase).first

    return nil if user.blank?

    # Ein Konto ohne Hash kann sich nicht anmelden. Fachlich braucht das keine
    # eigene Prüfung, weil authenticate aus has_secure_password selbst auf
    # present? testet und dann false liefert, statt BCrypt mit einem leeren Hash
    # aufzurufen (activemodel, secure_password.rb).
    #
    # Gemeldet wird es dennoch: Ein leerer Hash ist ein Datendefekt und kein
    # normales Anmelde-Ergebnis. Solche Konten kann sonst niemand mehr benutzen,
    # und ohne diesen Eintrag sähe der Betrieb nur ein leeres 401 wie bei einem
    # Tippfehler. Bis zum Entfernen des MD5-Zweigs war das der Einstieg in die
    # Passwort-Migration, seither gibt es dafür keinen gültigen Fall mehr.
    if user.password_digest.blank?
      Rails.logger.error("Anmeldung abgelehnt, password_digest fehlt (User #{user.id})")
      Sentry.capture_message("login with blank password_digest, user: #{user.id}") if defined?(Sentry)
      return nil
    end

    return nil unless user.authenticate(password)

    # Archivierte Konten weist der Controller ab. Ihr last_login_at bleibt
    # unangetastet, damit der Inaktiv-Status nicht verfälscht wird.
    return user if user.archived?

    stamp_last_login(user)
    user
  end

  # last_login_at ist Buchhaltung, keine Anmeldebedingung. Das Passwort ist an
  # dieser Stelle bereits geprüft, die Identität also belegt.
  #
  # Bewusst update_column statt update: update lässt den ganzen Datensatz
  # validieren und gibt bei einem Fehler nur false zurück. Der Rückgabewert
  # entschied früher über die Anmeldung, womit ein Konto mit gültigem Passwort
  # an einem ganz anderen Feld scheitern konnte, ohne jede Spur in Log oder
  # Sentry. Nachgewiesen ausgesperrt haben:
  #
  # - Altname mit Leerzeichen am Rand plus kleinschreibungsneutrale Dublette.
  #   Die Gates auf `user_name_changed?` (siehe oben bei den Validierungen)
  #   sollen genau das verhindern, greifen hier aber nicht: normalize_user_name
  #   strippt den Namen und setzt damit selbst `user_name_changed?`.
  # - Altname mit Leerzeichen am Rand und Umlaut, über dieselbe Mechanik am
  #   Format-Validator.
  # - language außerhalb von LANGUAGES. Der Validator dort hat bewusst kein
  #   if-Gate, greift also bei jedem Speichern.
  #
  # update_column umgeht Validierungen UND Callbacks, schreibt also weder einen
  # gestrippten Namen zurück noch stolpert es über fremde Felder. Ein
  # Fehlschlag bleibt trotzdem melderelevant: Er heißt, dass die Zeile nicht
  # geschrieben wurde, und der Inaktiv-Status baut darauf auf.
  def self.stamp_last_login(user)
    return if user.update_column(:last_login_at, Time.now)

    Rails.logger.error("last_login_at konnte nicht geschrieben werden (User #{user.id})")
    Sentry.capture_message("last_login_at write failed, user: #{user.id}") if defined?(Sentry)
  rescue StandardError => e
    # Der Login darf hieran nicht scheitern: Die Anmeldung ist berechtigt, nur
    # der Zeitstempel fehlt dann.
    Rails.logger.error("last_login_at konnte nicht geschrieben werden (User #{user.id}): #{e.class}")
    Sentry.capture_exception(e) if defined?(Sentry)
  end

  # Rollen-IDs, die dieses Konto anderen Konten zuweisen (und wieder entziehen)
  # darf. Rollen werden additiv ausgewertet: Wer SBK und RSK ist, darf beides.
  # perm_hash ist durchreichbar, damit Aufrufer mit bereits geladenem
  # permission_hash (permissions_items) keine zweite Auflösung auslösen.
  def assignable_role_ids(perm_hash = permission_hash)
    ASSIGNABLE_ROLE_IDS.select { |own_role, _| perm_hash[own_role].present? }.values.flatten.uniq.sort
  end

  private

  # Die Schiedsrichter-Rolle steht für das Selfservice-Konto eines Schiris und
  # ist mit keiner anderen Rolle kombinierbar – in beide Richtungen. Sonst
  # bekäme ein Konto, das über sich selbst Auskunft gibt, zusätzlich
  # Verwaltungsrechte (bzw. umgekehrt), und permissions_items müsste zwei
  # widersprüchliche Menüs bedienen.
  def referee_role_not_combined
    role_ids = Array(permissions).map { |p| p['user_group_id'].to_i }.uniq
    return unless role_ids.include?(REFEREE_ROLE_ID) && role_ids.length > 1

    errors.add(:permissions, 'Die Schiedsrichter-Rolle kann nicht mit anderen Rollen kombiniert werden')
  end

  # Benutzernamen vor der Validierung nur um Rand-Whitespace bereinigen. Die
  # Groß-/Kleinschreibung bleibt erhalten; der Login vergleicht ohnehin
  # kleinschreibungsneutral (siehe self.login), sodass Bestandsnamen mit
  # Großbuchstaben weiterhin anmeldbar sind und nicht umgeschrieben werden.
  def normalize_user_name
    self.user_name = user_name.strip if user_name.present?
  end
end
