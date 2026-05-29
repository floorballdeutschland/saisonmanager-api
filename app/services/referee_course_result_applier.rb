class RefereeCourseResultApplier
  class Error < StandardError; end
  class AlreadyApplied < Error; end
  class InvalidResult < Error; end

  # Postgres advisory-lock-Key für die Lizenznummer-Auto-Vergabe in diesem
  # Service. Solange nur dieser Service Lizenznummern auto-vergibt, ist der
  # Key lokal eindeutig.
  LIZENZNUMMER_LOCK_KEY = 78_201_001

  def initialize(result, performed_by_user:)
    @result = result
    @performed_by_user = performed_by_user
  end

  # Wendet einen Course-Result auf einen Referee an. Wenn `review_required`
  # true ist, bleibt der Result auf `pending_review` stehen und nur die
  # Lizenzdaten (sowie die Neuanlage selbst) werden übernommen — die
  # Stammdaten-Korrekturen wartet der LV ab.
  def call(review_required:)
    raise AlreadyApplied, "Result #{@result.id} ist bereits angewendet" \
      if @result.status == 'applied'

    raise InvalidResult, "Lizenzstufe fehlt für Result #{@result.id}" \
      if @result.lizenzstufe.blank?
    raise InvalidResult, "Gültigkeitsdatum fehlt für Result #{@result.id}" \
      if @result.gueltigkeit.blank?

    ActiveRecord::Base.transaction do
      referee = @result.referee || create_new_referee
      apply_license_fields(referee)
      apply_master_fields(referee) unless review_required

      @result.referee = referee
      if review_required
        @result.status = 'pending_review'
      else
        @result.status = 'applied'
        @result.applied_at = Time.current
        @result.reviewed_by_user = @performed_by_user
        @result.reviewed_at = Time.current
      end
      @result.save!
    end

    @result
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    raise Error, "Anwendung fehlgeschlagen: #{e.message}"
  end

  # Pro Request einmal laden statt zwei find_by-Queries pro Result (bei 100
  # Zeilen sonst 200 Extra-Queries beim Submit). Memoization am Klassen-Level
  # ist hier okay, weil RefereeLicenseLevel-Positionen administrativ verwaltet
  # werden und sich waehrend eines Submit-Laufs nicht aendern.
  def self.license_level_positions
    Thread.current[:referee_license_level_positions] ||=
      RefereeLicenseLevel.pluck(:name, :position).to_h
  end

  def self.reset_license_level_positions_cache!
    Thread.current[:referee_license_level_positions] = nil
  end

  private

  def create_new_referee
    attrs = {
      vorname:      @result.master_vorname_final.presence || 'Unbekannt',
      nachname:     @result.master_nachname_final.presence || 'Unbekannt',
      geburtsdatum: @result.master_geburtsdatum_final,
      email:        @result.master_email_final,
      club_id:      @result.master_club_id_final,
      guest:        false
    }

    # Advisory-Lock serialisiert konkurrierende Auto-Vergaben über parallele
    # Transaktionen hinweg, sodass MAX(lizenznummer) + 1 nicht zwischen Read
    # und INSERT durch eine Parallel-Transaktion kollidieren kann. Der Lock
    # wird automatisch beim COMMIT/ROLLBACK freigegeben. Eine vom Importeur
    # explizit gesetzte Nummer respektieren wir wie angegeben — eine Kollision
    # schlägt als RecordNotUnique durch und wird vom Submit-Endpoint mit
    # Zeilenkontext gerendert.
    ActiveRecord::Base.connection.execute(
      "SELECT pg_advisory_xact_lock(#{LIZENZNUMMER_LOCK_KEY})"
    )
    lizenznummer = @result.master_lizenznummer_final.presence ||
                   (Referee.where(guest: false).maximum(:lizenznummer).to_i + 1)

    referee = Referee.create!(attrs.merge(lizenznummer: lizenznummer))
    @result.new_referee_created = true
    @result.master_lizenznummer_final = lizenznummer
    @result.master_lizenznummer_by_importer ||= lizenznummer
    referee
  end

  def apply_license_fields(referee)
    log_downgrade_if_any(referee)
    referee.update!(
      lizenzstufe: @result.lizenzstufe,
      gueltigkeit: @result.gueltigkeit
    )
  end

  # Eine Lizenzstufen-Tabelle hat eine `position` (siehe RefereeLicenseLevel).
  # Niedrigere Position = höhere Stufe (z.B. A=1 vor G=4). Wenn ein Course-
  # Result eine Lizenzstufe einsetzt, deren Position höher (= niedrigere Stufe)
  # als die aktuelle ist, ist das ein Downgrade — wir lassen es zu (kann
  # gewollt sein nach einer Neuabnahme), loggen es aber, damit auffällige Fälle
  # auditierbar sind.
  def log_downgrade_if_any(referee)
    return if referee.lizenzstufe.blank?
    return if referee.lizenzstufe == @result.lizenzstufe

    positions = self.class.license_level_positions
    current_pos = positions[referee.lizenzstufe]
    new_pos = positions[@result.lizenzstufe]
    return unless current_pos && new_pos
    return if new_pos <= current_pos

    Rails.logger.warn(
      "[RefereeCourseResultApplier] Lizenz-Downgrade Referee ##{referee.id}: " \
      "#{referee.lizenzstufe} (pos #{current_pos}) → #{@result.lizenzstufe} " \
      "(pos #{new_pos}) via Course-Result ##{@result.id}"
    )
  end

  def apply_master_fields(referee)
    # Vorname/Nachname sind auf Referee NOT NULL — leere Strings darf der
    # Importeur/LV also nicht produzieren. Für optionale Felder (geburtsdatum,
    # email, club_id) übernehmen wir explizit auch nil, damit der LV bewusst
    # Felder leeren kann (z.B. eine falsche E-Mail entfernen).
    attrs = {
      vorname:      @result.master_vorname_final.presence || referee.vorname,
      nachname:     @result.master_nachname_final.presence || referee.nachname,
      geburtsdatum: @result.master_geburtsdatum_final,
      email:        @result.master_email_final,
      club_id:      @result.master_club_id_final
    }
    # Lizenznummer nur bei Neuanlage setzen — danach gilt sie als unveränderlich.
    if @result.master_lizenznummer_final.present? && referee.lizenznummer.blank?
      attrs[:lizenznummer] = @result.master_lizenznummer_final
    end

    referee.update!(attrs)
  end
end
