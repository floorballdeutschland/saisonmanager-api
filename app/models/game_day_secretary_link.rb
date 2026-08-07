class GameDaySecretaryLink < ApplicationRecord
  belongs_to :created_by, class_name: 'User'
  has_many :game_day_secretary_link_game_days, dependent: :destroy
  has_many :game_days, through: :game_day_secretary_link_game_days

  # Ein Link ohne Spieltag erlaubt nichts. Beim Anlegen ist das ein Fehler;
  # später darf er leer werden, wenn seine Spieltage gelöscht wurden (siehe
  # GameDay) – deshalb nur `on: :create`.
  validates :game_days, presence: true, on: :create

  scope :active, -> { where('expires_at > ?', Time.current) }
  scope :covering, lambda { |game_day_ids|
    joins(:game_day_secretary_link_game_days)
      .where(game_day_secretary_link_game_days: { game_day_id: game_day_ids })
      .distinct
  }

  VALIDITY = 72.hours

  def self.find_by_token(raw_token)
    return nil if raw_token.blank?

    digest = Digest::SHA256.hexdigest(raw_token)
    active.find_by(token_digest: digest)
  end

  # Erzeugt einen Link über die übergebenen Spieltage und liefert
  # [link, raw_token]. Die Auswahl der Spieltage samt Rechteprüfung trifft der
  # Aufrufer (GameDaySecretaryLinksController) – das Model prüft sie nicht.
  def self.generate!(game_days:, created_by:)
    days = Array(game_days).compact.uniq
    raise ArgumentError, 'mindestens ein Spieltag erforderlich' if days.empty?

    raw_token = SecureRandom.urlsafe_base64(32)

    link = nil
    transaction do
      # Die betroffenen Spieltage sperren, bevor gelesen und geschrieben wird.
      # Ohne die Sperre sähen zwei gleichzeitige Ausgaben (zwei Vereine, eine
      # Halle) jeweils keinen bestehenden Link, entzögen nichts und legten beide
      # an – zwei gültige Tokens für denselben Spieltag, während die Oberfläche
      # zusagt, dass der vorherige ungültig wird. Nach ID sortiert, damit sich
      # zwei Anfragen mit überlappenden Spieltagen nicht verklemmen.
      GameDay.where(id: days.map(&:id)).order(:id).lock.pluck(:id)

      revoke_coverage_of(days.map(&:id))

      link = create!(
        created_by: created_by,
        token_digest: Digest::SHA256.hexdigest(raw_token),
        expires_at: VALIDITY.from_now,
        game_days: days
      )
    end

    [link, raw_token]
  end

  # Nimmt den betroffenen Spieltagen ihren bisherigen Link, damit für einen
  # Spieltag nie zwei gültige Tokens mit unterschiedlichem Umfang im Umlauf
  # sind. Entzogen wird gezielt nur die Zuordnung zu diesen Spieltagen, nicht
  # der ganze Link: Ein Link über zwei Ligen einer Halle würde sonst komplett
  # sterben, sobald ein Verein für seine eigene Liga neu ausgibt – und die
  # fremde Liga stünde mitten am Spieltag ohne Token da, ohne Ersatz und ohne
  # Hinweis. Bleibt einem Link kein Spieltag mehr, wird er entfernt.
  def self.revoke_coverage_of(game_day_ids)
    affected = active.covering(game_day_ids).to_a
    return if affected.empty?

    GameDaySecretaryLinkGameDay
      .where(game_day_secretary_link: affected, game_day_id: game_day_ids)
      .delete_all

    where(id: affected.map(&:id))
      .where.missing(:game_day_secretary_link_game_days)
      .destroy_all
  end

  # Spieltag-IDs des Links. In den Listen-Endpunkten ist
  # `game_day_secretary_link_game_days` vorgeladen, `pluck` bedient sich dann
  # aus der geladenen Association. Auf dem Token-Pfad (`find_by_token`) ist
  # nichts vorgeladen, dort fragt jeder Aufruf neu. Bewusst nicht memoisiert:
  # revoke_coverage_of ändert die Zuordnung innerhalb einer Anfrage, ein Memo
  # würde dann veraltete Rechte behaupten.
  def covered_game_day_ids
    game_day_secretary_link_game_days.pluck(:game_day_id)
  end

  def covers_game_day?(game_day_id)
    game_day_id.present? && covered_game_day_ids.include?(game_day_id)
  end
end
