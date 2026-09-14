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

  # Kurzcode zum Abtippen. Der Vereinsrechner am Spieltisch hat kein
  # Benutzerkonto und meist auch kein Postfach, in dem der Link laege -- er wird
  # abgeschrieben, und die 43 Zeichen des Tokens sind dafuer nicht zu
  # gebrauchen.
  #
  # Alphabet ist Crockfords Base32: ohne I, L, O und U. Die ersten drei
  # entstehen beim Abtippen ohnehin aus 1 und 0, weshalb `normalize_code` sie
  # darauf abbildet statt den Code abzulehnen; U fehlt, damit aus dem Zufall
  # kein lesbares Schimpfwort wird. Acht Zeichen sind damit genau 40 Bit, rund
  # 1,1 Billionen Moeglichkeiten.
  CODE_ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'.freeze
  CODE_LENGTH = 8

  def self.find_by_token(raw_token)
    return nil if raw_token.blank?

    digest = Digest::SHA256.hexdigest(raw_token)
    active.find_by(token_digest: digest)
  end

  # Loest den abgetippten Code gegen den regulaeren Token ein und liefert
  # [link, raw_token] oder nil.
  #
  # Der Code ist bewusst NICHT das Geheimnis, mit dem am Tisch gearbeitet wird:
  # Er wird einmal eingeloest, danach haengt wie bisher der 43-Zeichen-Token an
  # jeder Anfrage. Damit bleibt das Durchprobieren auf diesen einen Endpunkt
  # beschraenkt, den Rack::Attack drosselt (`secretary-code/ip`) -- ein Code,
  # der ueberall gilt, waere an jedem Weg des Spielberichts zu raten, und die
  # dortigen Toepfe sind auf Spielbetrieb ausgelegt, nicht auf Rateversuche.
  #
  # Weil der Token nirgends im Klartext liegt, laesst er sich beim Einloesen
  # nicht nachschlagen. Er wird deshalb aus dem Code abgeleitet. Die Ableitung
  # ist deterministisch: Derselbe Code liefert beliebig oft denselben Token.
  # Das ist kein Detail, sondern der Grund gegen die naheliegende Alternative,
  # beim Einloesen einen frischen Token auszustellen -- `sessionStorage` gilt je
  # Registerkarte, und die zweite Registerkarte am selben Tisch haette die erste
  # mitten im Spiel ausgesperrt.
  def self.redeem(raw_code)
    normalized = normalize_code(raw_code)
    return nil if normalized.nil?

    link = active.find_by(code_digest: code_digest_for(normalized))
    return nil if link.nil?

    raw_token = link.code_salt.present? && token_for(normalized, link.code_salt)
    # Der abgeleitete Token wird gegen den gespeicherten Digest gehalten, bevor
    # er hinausgeht. Ohne diese Pruefung antwortete der Endpunkt mit 200 und
    # einem Token, den `find_by_token` gleich darauf abweist -- ein Fehlschlag,
    # ausgeliefert als Erfolg, und das Sekretariat tippt denselben Code endlos
    # neu. Eintreten kann das nur ueber einen Datenfehler (eine Zeile, der
    # jemand nachtraeglich einen Code verpasst, waehrend `token_digest` noch aus
    # der Zufallsausgabe stammt), und genau solche Zeilen sollen laut auffallen
    # statt als "unbekannter Code" durchzufallen.
    if raw_token.blank? || Digest::SHA256.hexdigest(raw_token) != link.token_digest
      Rails.logger.error("GameDaySecretaryLink##{link.id}: Code passt, abgeleiteter Token nicht zu token_digest")
      return nil
    end

    [link, raw_token]
  end

  # Bringt Eingetipptes auf die gespeicherte Schreibweise oder liefert nil, wenn
  # daraus kein moeglicher Code werden kann. Trennzeichen fliegen raus (der Code
  # wird in zwei Vierergruppen angezeigt, und wer ihn abschreibt, tippt den
  # Bindestrich oder ein Leerzeichen mit), O/I/L werden auf 0/1/1 abgebildet.
  #
  # Die Pruefung auf Laenge und Alphabet spart die Abfrage. Aus dem Drossel-Topf
  # haelt sie einen Tippfehler NICHT heraus -- Rack::Attack sitzt vor dem Router
  # und zaehlt, bevor diese Methode laeuft. Dafuer prueft die Maske im Frontend
  # dieselben zwei Bedingungen, bevor sie ueberhaupt absendet.
  def self.normalize_code(raw_code)
    return nil if raw_code.blank?

    normalized = raw_code.to_s.upcase.gsub(/[^0-9A-Z]/, '').tr('OIL', '011')
    return nil unless normalized.length == CODE_LENGTH
    return nil unless normalized.each_char.all? { |char| CODE_ALPHABET.include?(char) }

    normalized
  end

  # Gepfeffert mit dem Anwendungsschluessel statt blank gehasht. `token_digest`
  # durfte ein nackter SHA256 sein, weil darunter 256 Zufallsbits liegen; acht
  # Zeichen aus 32 sind dagegen 40 Bit, und 1,1 Billionen SHA256 sind auf einer
  # Grafikkarte Minutenarbeit. Ohne den Schluessel stuende nach einer
  # Datenbankkopie jeder gueltige Code im Klartext da -- und mit ihm ueber
  # `token_for` der Token, denn `code_salt` liegt offen in derselben Zeile.
  #
  # Der Schluessel steckt in den Credentials, nicht in der Tabelle. Wechselt er,
  # sind laufende Codes unbrauchbar; bei 72 Stunden Gueltigkeit ist das
  # hinnehmbar.
  def self.code_digest_for(normalized_code)
    OpenSSL::HMAC.hexdigest('SHA256', Rails.application.secret_key_base, normalized_code)
  end

  # HMAC statt Zufall: Der Salt steht offen in der Zeile, der Code nicht. Wer
  # die Datenbank hat, kommt an den Token also nur ueber den Code -- und der ist
  # dank `code_digest_for` daraus nicht zu gewinnen. Base64 in derselben Laenge
  # wie SecureRandom.urlsafe_base64(32), damit Token aus beiden Wegen
  # ununterscheidbar sind.
  def self.token_for(normalized_code, code_salt)
    Base64.urlsafe_encode64(
      OpenSSL::HMAC.digest('SHA256', code_salt, normalized_code),
      padding: false
    )
  end

  def self.random_code
    Array.new(CODE_LENGTH) { CODE_ALPHABET[SecureRandom.random_number(CODE_ALPHABET.length)] }.join
  end

  # Der eindeutige Index ueber `code_digest` gilt fuer alle Zeilen, auch fuer
  # abgelaufene. Bei 40 Bit ist eine Kollision rechnerisch kaum zu erwarten,
  # aber ein Insert-Fehler mitten im Spieltag waere die teuerste Art, das
  # herauszufinden.
  def self.unused_code
    5.times do
      candidate = random_code
      return candidate unless exists?(code_digest: code_digest_for(candidate))
    end

    raise "Kein freier Sekretariats-Code nach 5 Versuchen (code_digest-Index pruefen)"
  end

  # Erzeugt einen Link über die übergebenen Spieltage und liefert
  # [link, raw_token, raw_code]. Die Auswahl der Spieltage samt Rechteprüfung
  # trifft der Aufrufer (GameDaySecretaryLinksController) – das Model prüft sie
  # nicht.
  def self.generate!(game_days:, created_by:)
    days = Array(game_days).compact.uniq
    raise ArgumentError, 'mindestens ein Spieltag erforderlich' if days.empty?

    code_salt = SecureRandom.hex(16)
    raw_code = nil
    raw_token = nil

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

      raw_code = unused_code
      raw_token = token_for(raw_code, code_salt)

      link = create!(
        created_by: created_by,
        token_digest: Digest::SHA256.hexdigest(raw_token),
        code_digest: code_digest_for(raw_code),
        code_salt: code_salt,
        expires_at: VALIDITY.from_now,
        game_days: days
      )
    end

    [link, raw_token, raw_code]
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
