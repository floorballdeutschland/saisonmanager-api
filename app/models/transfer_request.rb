class TransferRequest < ApplicationRecord
  STATUSES = %w[pending_club pending_player pending_lv scheduled approved
                rejected_by_club rejected_by_player rejected_by_lv revoked withdrawn expired].freeze

  # Die beiden Antragsarten. Validiert und nicht bloss dokumentiert, seit die
  # Eindeutigkeit am Spaltenwert haengt: Die partiellen Unique-Indizes greifen
  # nur bei genau diesen Literalen (siehe
  # 20260902100000_split_transfer_request_active_index). Ein dritter Wert --
  # 'Release' aus einem kuenftigen Import genuegte -- faellt aus BEIDEN
  # Indizes und aus `blocked_request_types` heraus und liesse damit beliebig
  # viele laufende Antraege je Spieler zu.
  REQUEST_TYPES = %w[transfer release].freeze

  # Offene Anträge ohne vollständige Genehmigung werden nach dieser Frist
  # automatisch annulliert (siehe rake transfers:expire / Status "expired").
  EXPIRE_AFTER_DAYS = 14

  # Transfersperrfrist: Nach einem erfolgreich abgeschlossenen Transfer kann für
  # den Spieler für diesen Zeitraum (ab Abschlusszeitpunkt) kein neuer
  # Transferantrag gestellt werden. Freigaben (request_type "release") lösen die
  # Sperre nicht aus.
  TRANSFER_LOCK_PERIOD = 4.weeks

  # Die Konten, die an einem Antrag gehandelt haben können. Auswahl und
  # Reihenfolge spiegeln die Statusmaschine.
  #
  # Nicht darin, weil es dazu kein Konto gibt: der Fristablauf (#expire!, läuft
  # aus rake transfers:expire) und die Bestätigung oder Ablehnung durch die
  # Person selbst (tokenbasiert, ohne Anmeldung). Die Beendigung durch eine
  # Vereinsdeaktivierung dagegen HAT ein Konto und schreibt es seit dieser
  # Änderung nach withdrawn_by (siehe end_for_deactivated_club).
  ACTOR_COLUMNS = %i[created_by approved_by_club_user_id approved_by_lv_user_id
                     rejected_by revoked_by withdrawn_by].freeze

  belongs_to :player
  belongs_to :requesting_club, class_name: 'Club'
  belongs_to :former_club, class_name: 'Club'

  validates :status, inclusion: { in: STATUSES }
  validates :request_type, inclusion: { in: REQUEST_TYPES }
  validates :rejection_reason, presence: true, if: -> { status.in?(%w[rejected_by_club rejected_by_lv]) }
  validates :revocation_reason, presence: true, if: -> { status == 'revoked' }

  before_create :generate_player_confirmation_token

  scope :active, -> { where(status: %w[pending_club pending_player pending_lv scheduled]) }
  # Nach Antragsart getrennt, weil die Eindeutigkeitsregeln auseinanderlaufen:
  # je Spieler hoechstens ein laufender Transfer, je Spieler und Zielverein
  # hoechstens eine laufende Freigabe. Mehrere Freigaben auf verschiedene
  # Vereine sind der Regelfall -- ein Spieler kann fuer mehr als einen Verein
  # eine Freigabe brauchen (siehe die beiden partiellen Unique-Indizes
  # index_transfer_requests_on_player_id_active_transfer/_release).
  scope :active_transfers, -> { active.where(request_type: 'transfer') }
  scope :active_releases, -> { active.where(request_type: 'release') }
  # Noch nicht abgeschlossene Anträge (Genehmigungen unvollständig), die die
  # Frist überschritten haben. "scheduled" ist bereits vollständig genehmigt und
  # wartet nur auf das Wirksamkeitsdatum – wird daher NICHT annulliert.
  scope :expirable, lambda {
    where(status: %w[pending_club pending_player pending_lv])
      .where('created_at < ?', EXPIRE_AFTER_DAYS.days.ago)
  }
  scope :pending_for_club, ->(club_id) { where(former_club_id: club_id, status: 'pending_club') }
  scope :pending_for_lv, lambda { |go_ids|
    club_ids = go_ids.include?(0) ? Club.pluck(:id) : Club.home_clubs_of(go_ids).pluck(:id)
    where(former_club_id: club_ids, status: 'pending_lv')
  }
  scope :for_requesting_club, ->(club_id) { where(requesting_club_id: club_id) }
  scope :for_former_club, ->(club_id) { where(former_club_id: club_id) }

  # Beendet die laufenden Antraege AUF einen Verein, der gerade deaktiviert
  # wurde, und liefert sie zurueck (der Aufrufer verschickt die Mails, siehe
  # Club#deactivate!).
  #
  # api#528: Ohne diesen Schritt bleibt ein Antrag auf einen aufgeloesten Verein
  # stehen und ist unerfuellbar, denn seit api#512 weist der Transferprozess
  # einen deaktivierten aufnehmenden Verein an jedem Schritt ab. Schlimmer noch:
  # `active` deckt genau diese vier Status ab und wird in #create geprueft -- ein
  # gestrandeter Antrag blockierte damit JEDEN neuen Antrag desselben Spielers,
  # auch auf einen ganz anderen Verein. Seit der Aufteilung des Unique-Index
  # sperrt er nur noch die eigene Antragsart (Transfers untereinander, Freigaben
  # je Zielverein) -- ein gestrandeter Antrag bleibt aber auch dann eine Sperre,
  # die niemand aufloest.
  #
  # Antraege AUS dem Verein bleiben unberuehrt, ein aufgeloester Verein gibt
  # seine Spieler ja gerade ab. Freigaben laufen mit: Sie legen ueber
  # `add_secondary_club_membership!` ebenfalls eine Mitgliedschaft im
  # aufnehmenden Verein an und sind genauso unerfuellbar.
  #
  # Status `withdrawn` wie bei #cancel und #withdraw, statt eines eigenen: Der
  # Antrag ist annulliert, und die vier laufenden Status sind dieselben.
  #
  # Das ist damit der dritte Weg in den Status `withdrawn` neben #withdraw und
  # #cancel. user_id ist das Konto, das den Verein deaktiviert hat: Es war hier
  # bisher nicht bekannt, obwohl Club#deactivate! es kennt und nach
  # clubs.deactivated_by schreibt -- ohne Konto und Zeitpunkt waere ein so
  # beendeter Vorgang in der Chronik der einzige ohne jeden Abschlussschritt.
  # Pflichtargument und kein Vorgabewert, damit ein kuenftiger Aufrufer nicht
  # still wieder den Zustand herstellt, den das gerade beseitigt.
  def self.end_for_deactivated_club(club_id, user_id)
    active.where(requesting_club_id: club_id).to_a.select do |tr|
      transaction do
        tr.lock!
        # Innerhalb der Sperre erneut lesen, wie in #expire!: Eine
        # zwischenzeitliche Genehmigung darf nicht ueberschrieben werden.
        next false unless tr.status.in?(%w[pending_club pending_player pending_lv scheduled])

        tr.update!(status: 'withdrawn', withdrawn_by: user_id, withdrawn_at: Time.current,
                   player_confirmation_token: nil)
      end
    end
  end

  # Annulliert einen noch offenen Antrag automatisch (Fristablauf).
  # Sperrt und prüft den Status erneut innerhalb der Transaktion, damit eine
  # zwischenzeitliche Genehmigung (execute_transfer!/approve_lv) nicht
  # überschrieben wird (gleiches Muster wie execute_transfer!/revoke_release!).
  def expire!
    TransferRequest.transaction do
      lock!
      return unless status.in?(%w[pending_club pending_player pending_lv])

      update!(status: 'expired', player_confirmation_token: nil)
    end
  end

  def actor_user_ids
    ACTOR_COLUMNS.map { |column| self[column] }.compact.uniq
  end

  # Namen der beteiligten Konten für mehrere Anträge in einer Abfrage. Die
  # Übersicht rendert sonst je Antrag eine eigene User-Abfrage, und die Liste
  # wächst mit jeder Saison.
  #
  # fullname und nicht full_with_username: Diese Ansicht steht auch den
  # Vereinsmanagern beider beteiligter Vereine offen (siehe transfer_visible?),
  # angemeldet wird sich in diesem Projekt allein über den Benutzernamen, und
  # für die Frage "wer war das" trägt der Name zusammen mit der mitgelieferten
  # Konto-ID die Aussage bereits.
  def self.actor_names_for(records)
    ids = Array(records).flat_map(&:actor_user_ids).uniq
    return {} if ids.empty?

    # strip.presence, weil fullname bei einem Konto ohne Vor- und Nachnamen ein
    # blosses Leerzeichen liefert und nicht nil -- User validiert die beiden
    # Felder nicht. Ungefiltert waere das in der Chronik ein "gueltiger" Name,
    # der nichts aussagt und zugleich den Rueckfall auf die Konto-ID verdeckt.
    User.where(id: ids).index_by(&:id).transform_values { |u| u.fullname.strip.presence }
  end

  # actors: vorab aufgelöste Namen (siehe actor_names_for). Ohne die Option löst
  # der Antrag sie für sich allein auf – richtig, aber eine Abfrage je Datensatz,
  # deshalb reicht die Übersicht die gemeinsame Auflösung durch.
  #
  # Ausgegeben werden Konto-ID *und* Name: Der Name ist die Anzeige, die ID
  # bleibt die belastbare Angabe, wenn ein Konto zwischenzeitlich umbenannt oder
  # gelöscht wurde. Ein nicht mehr auffindbares Konto liefert einen leeren
  # Namen, die ID steht weiterhin.
  def as_json(options = nil)
    actors = (options.is_a?(Hash) && options[:actors]) || TransferRequest.actor_names_for([self])

    {
      id:,
      status:,
      request_type:,
      direct:,
      season_id:,
      rejection_reason:,
      revocation_reason:,
      effective_date: effective_date&.iso8601,
      created_at: created_at&.iso8601,
      created_by:,
      created_by_name: actors[created_by],
      club_approved_at: club_approved_at&.iso8601,
      approved_by_club_user_id:,
      approved_by_club_user_name: actors[approved_by_club_user_id],
      player_approved_at: player_approved_at&.iso8601,
      player_rejected_at: player_rejected_at&.iso8601,
      lv_approved_at: lv_approved_at&.iso8601,
      approved_by_lv_user_id:,
      approved_by_lv_user_name: actors[approved_by_lv_user_id],
      rejected_at: rejected_at&.iso8601,
      rejected_by:,
      rejected_by_name: actors[rejected_by],
      revoked_at: revoked_at&.iso8601,
      revoked_by:,
      revoked_by_name: actors[revoked_by],
      withdrawn_at: withdrawn_at&.iso8601,
      withdrawn_by:,
      withdrawn_by_name: actors[withdrawn_by],
      player: player_hash,
      requesting_club: club_hash(requesting_club),
      former_club: club_hash(former_club)
    }
  end

  def execute_transfer!(user_id = nil)
    raise ActiveRecord::RecordInvalid, self unless status.in?(%w[pending_lv scheduled])

    secondary_club_ids = nil
    annulled_releases = []

    TransferRequest.transaction do
      player.lock!
      lock!
      raise ActiveRecord::RecordInvalid, self unless status.in?(%w[pending_lv scheduled])

      secondary_club_ids = player.clubs.select do |c|
        c['home_club'] == false && c['valid_until'].nil?
      end.map { |c| c['club_id'] }

      invalidate_licenses!
      player.transfer(requesting_club_id, user_id || approved_by_lv_user_id)
      annulled_releases = annul_pending_releases!(user_id || approved_by_lv_user_id)
      update!(
        status: 'approved',
        approved_by_lv_user_id: approved_by_lv_user_id || user_id,
        lv_approved_at: lv_approved_at || Time.current,
        player_confirmation_token: nil
      )
    end

    Rails.cache.delete('transfers')
    send_completion_emails(secondary_club_ids)
    annulled_releases.each do |release|
      TransferRequestMailer.release_annulled_by_transfer(release, self).deliver_later
    end
  end

  def execute_release!(user_id)
    raise ActiveRecord::RecordInvalid, self unless status == 'pending_lv'
    raise ActiveRecord::RecordInvalid, self unless request_type == 'release'

    TransferRequest.transaction do
      player.lock!
      lock!
      raise ActiveRecord::RecordInvalid, self unless status == 'pending_lv'

      add_secondary_club_membership!(user_id)
      update!(
        status: 'approved',
        approved_by_lv_user_id: user_id,
        lv_approved_at: Time.current,
        player_confirmation_token: nil
      )
    end

    Rails.cache.delete('transfers')
    TransferRequestMailer.transfer_completed(self).deliver_later
    return unless notify_receiving_lv?

    TransferRequestMailer.transfer_completed_receiving_lv(self).deliver_later
  end

  def revoke_release!(user_id, reason)
    raise ActiveRecord::RecordInvalid, self unless status == 'approved'
    raise ActiveRecord::RecordInvalid, self unless request_type == 'release'

    TransferRequest.transaction do
      player.lock!
      lock!
      raise ActiveRecord::RecordInvalid, self unless status == 'approved'

      invalidate_release_licenses!(user_id)
      expire_secondary_club_membership!(user_id)
      update!(
        status: 'revoked',
        revoked_by: user_id,
        revoked_at: Time.current,
        revocation_reason: reason,
        player_confirmation_token: nil
      )
    end

    Rails.cache.delete('transfers')
  end

  private

  # Ein Vereinswechsel schliesst JEDE bestehende Zugehoerigkeit, auch die
  # Zweitspielrechte (siehe Player#transfer). Ein noch laufender Freigabeantrag
  # geht damit ins Leere: Genehmigt wuerde er vom alten Heimatverein und dessen
  # Landesverband -- also von einer Stelle, die den Spieler nicht mehr hat --
  # und traege eine Zugehoerigkeit ein, ueber die nun der neue Heimatverein zu
  # entscheiden haette. Deshalb enden die offenen Freigaben mit dem Vollzug.
  #
  # Status `withdrawn` wie bei #cancel, #withdraw und
  # .end_for_deactivated_club: Der Antrag ist annulliert, nicht abgelehnt.
  #
  # Innerhalb der Transaktion von #execute_transfer! und deshalb ohne eigene:
  # Die Zeilen werden einzeln gesperrt und ihr Status danach erneut gelesen,
  # damit eine parallel durchlaufende Genehmigung (#execute_release!) nicht
  # ueberschrieben wird. Beide Wege sperren zuerst die Spielerzeile, sie koennen
  # sich also nicht ueberholen.
  #
  # Rueckgabe sind die tatsaechlich beendeten Antraege -- die Mails verschickt
  # der Aufrufer nach dem Commit.
  def annul_pending_releases!(user_id)
    TransferRequest.active_releases.where(player_id:).where.not(id:).to_a.select do |release|
      release.lock!
      next false unless release.status.in?(%w[pending_club pending_player pending_lv scheduled])

      release.update!(status: 'withdrawn', withdrawn_by: user_id, withdrawn_at: Time.current,
                      player_confirmation_token: nil)
    end
  end

  def generate_player_confirmation_token
    self.player_confirmation_token = SecureRandom.urlsafe_base64(32)
  end

  def add_secondary_club_membership!(user_id)
    already_member = player.clubs.any? do |c|
      c['club_id'] == requesting_club_id &&
        !c['home_club'] &&
        (c['valid_until'].nil? || c['valid_until'].to_time > Time.now)
    end
    return if already_member

    valid_until = Date.new(Date.today.year, 7, 15).to_time
    valid_until += 1.year if valid_until < Time.now

    player.clubs << {
      'club_id' => requesting_club_id,
      'home_club' => false,
      'created_by' => user_id,
      'valid_set_by' => user_id,
      'created_at' => Time.now,
      'valid_until' => valid_until
    }
    # Wer eine Freigabe erhaelt, spielt im aufnehmenden Verein – siehe
    # Player#clear_deactivation.
    player.clear_deactivation
    player.save!(validate: false)
  end

  def expire_secondary_club_membership!(user_id)
    player.clubs.map! do |c|
      if c['club_id'] == requesting_club_id && !c['home_club'] &&
         (c['valid_until'].nil? || c['valid_until'].to_time > Time.now)
        c['valid_until'] = Time.now
        c['valid_set_by'] = user_id
      end
      c
    end
    player.save!(validate: false)
  end

  def invalidate_release_licenses!(user_id)
    team_ids = Team.where(club_id: requesting_club_id).pluck(:id).to_set

    player.licenses.each do |license|
      next unless team_ids.include?(license['team_id'].to_i)

      last_status = license['history']&.last&.dig('license_status_id').to_i
      next unless last_status.in?([License::APPROVED, License::REQUESTED])

      license['history'] << {
        'license_status_id' => License::WITHDRAWN,
        'reason' => 'Freigabe zurueckgezogen',
        'created_by' => user_id,
        'created_at' => Time.now
      }
    end
    player.save!(validate: false)
  end

  def invalidate_licenses!
    requesting_team_ids = Team.where(club_id: requesting_club_id).pluck(:id).to_set

    player.licenses.each do |license|
      next if requesting_team_ids.include?(license['team_id'].to_i)

      last_status = license['history']&.last&.dig('license_status_id').to_i
      next unless last_status.in?([License::APPROVED, License::REQUESTED])

      license['history'] << {
        'license_status_id' => License::TRANSFER,
        'reason' => 'Transfer',
        'created_by' => nil,
        'created_at' => Time.now
      }
    end
    player.save!(validate: false)
  end

  # Zusatzmail an den aufnehmenden Landesverband nur, wenn dahinter ein anderes
  # Postfach steht. Der Vergleich läuft über die effektive Adresse, nicht über
  # state_association_id: Zwei Vereine in verschiedenen Kind-LVs desselben
  # Verbunds haben unterschiedliche IDs, erben aber dasselbe SBK-Postfach, das
  # sonst zwei Mails zum selben Vorgang bekäme (die zweite mit dem Zusatz
  # „aufnehmender LV", der dann eine zweite Instanz suggeriert).
  def notify_receiving_lv?
    receiving = requesting_club.state_association&.effective_sbk_email
    return false if receiving.blank?

    receiving != former_club.state_association&.effective_sbk_email
  end

  def send_completion_emails(secondary_club_ids)
    TransferRequestMailer.transfer_completed(self).deliver_later

    TransferRequestMailer.transfer_completed_receiving_lv(self).deliver_later if notify_receiving_lv?

    secondary_club_ids.each do |club_id|
      club = Club.find_by(id: club_id)
      next if club&.notification_emails.blank?

      TransferRequestMailer.secondary_club_notification(self, club).deliver_later
    end
  end

  def player_hash
    {
      id: player.id,
      first_name: player.first_name,
      last_name: player.last_name,
      birthdate: player.birthdate
    }
  end

  def club_hash(club)
    { id: club.id, name: club.name }
  end
end
