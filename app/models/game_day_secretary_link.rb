class GameDaySecretaryLink < ApplicationRecord
  belongs_to :created_by, class_name: 'User'
  has_many :game_day_secretary_link_game_days, dependent: :destroy
  has_many :game_days, through: :game_day_secretary_link_game_days

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
  #
  # Alle noch laufenden Links, die einen der Spieltage abdecken, werden ersetzt.
  # Sonst blieben nach einer Neuausgabe zwei gültige Tokens mit
  # unterschiedlichem Umfang für denselben Spieltag im Umlauf.
  def self.generate!(game_days:, created_by:)
    days = Array(game_days).compact.uniq
    raise ArgumentError, 'mindestens ein Spieltag erforderlich' if days.empty?

    raw_token = SecureRandom.urlsafe_base64(32)

    link = nil
    transaction do
      covering(days.map(&:id)).destroy_all

      link = create!(
        created_by: created_by,
        token_digest: Digest::SHA256.hexdigest(raw_token),
        expires_at: VALIDITY.from_now
      )
      link.game_days = days
    end

    [link, raw_token]
  end

  # Spieltag-IDs des Links. Bewusst ohne Preload-Umweg, damit der Aufruf pro
  # Request einmal cached und nicht bei jeder Spielprüfung neu lädt.
  def covered_game_day_ids
    @covered_game_day_ids ||= game_day_secretary_link_game_days.pluck(:game_day_id)
  end

  def covers_game_day?(game_day_id)
    game_day_id.present? && covered_game_day_ids.include?(game_day_id)
  end
end
