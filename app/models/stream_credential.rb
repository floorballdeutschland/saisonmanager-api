# frozen_string_literal: true

# Der gespeicherte YouTube-Zugang des Livestream-Waechters.
#
# EINE ZEILE, NICHT MEHR: Es gibt genau einen Verbandskanal. `current` legt sie
# bei Bedarf an, `connected?` beantwortet, ob wirklich ein Token darin liegt.
#
# WARUM UEBERHAUPT IN DER DATENBANK: Bis hierher kam der Token ausschliesslich
# aus `YOUTUBE_REFRESH_TOKEN` am Container. Laeuft er ab oder wird er widerrufen,
# steht der Waechter, und das Erneuern braucht einen SSH-Zugang, eine Handzeile
# in der `.env` und einen Neustart des Containers. Ueber die Oberflaeche ist es
# eine Anmeldung bei Google.
#
# DER TOKEN LIEGT VERSCHLUESSELT, mit einem Schluessel aus `YOUTUBE_TOKEN_KEY`
# und NICHT aus `RAILS_MASTER_KEY`. Der Unterschied ist der ganze Zweck: Die
# Staging-Umgebung traegt einen 1:1-Klon der Produktionsdatenbank. Mit dem
# Master-Key entschluesselte `.dev` den Token mit und koennte laufende
# Uebertragungen des echten Kanals beenden -- fuer eine Testumgebung die
# denkbar schlechteste Eigenschaft. Ohne die Variable ist die Zeile dort
# unlesbar, und `connected?` sagt schlicht nein.
class StreamCredential < ApplicationRecord
  KEY_ENV = 'YOUTUBE_TOKEN_KEY'

  belongs_to :connected_by, class_name: 'User', foreign_key: :connected_by_user_id,
                            optional: true, inverse_of: false

  def self.current
    find_by(singleton: 0)
  end

  # Die eine Zeile, angelegt falls noetig. Der eindeutige Index auf `singleton`
  # macht eine zweite unmoeglich -- zwei gleichzeitige Verbindungen koennten
  # sonst zwei Zeilen erzeugen, von denen die Oberflaeche die eine und der
  # Waechter die andere benutzt.
  def self.singleton
    find_or_initialize_by(singleton: 0)
  end

  # Kann an dieser Stelle ueberhaupt etwas gespeichert oder gelesen werden?
  def self.key?
    ENV[KEY_ENV].present?
  end

  # Gemerkt, weil `KeyGenerator` eine PBKDF2-Ableitung ueber 2^16 Runden ist und
  # ein Zustandsabruf den Token mehrfach liest. Der gemerkte Wert haengt am
  # SCHLUESSEL und nicht nur an der Klasse: Sonst bliebe nach einem Wechsel der
  # alte Rechner stehen und entschluesselte Zeilen, die er nicht mehr duerfte --
  # in Produktion theoretisch, im Test die Gegenprobe zum fremden Schluessel.
  def self.encryptor
    schluessel = ENV.fetch(KEY_ENV)
    if @encryptor_fuer != schluessel
      @encryptor = ActiveSupport::MessageEncryptor.new(
        ActiveSupport::KeyGenerator.new(schluessel).generate_key('youtube-refresh-token', 32)
      )
      @encryptor_fuer = schluessel
    end
    @encryptor
  end

  # Der einsatzbereite Zugang oder nil. Nil heisst hier immer "nimm die
  # Umgebungsvariablen" -- der Aufrufer muss nicht wissen, warum.
  def self.credentials
    satz = current
    return nil if satz.nil?

    token = satz.refresh_token
    return nil if token.blank?

    # DAS WEB-PAAR, NICHT DAS DESKTOP-PAAR: Eingeloest wurde der Code von
    # `YoutubeOauth` mit `YOUTUBE_WEB_CLIENT_ID`, und Google erneuert einen
    # Token ausschliesslich gegen den Client, der ihn ausgegeben hat. Stuende
    # hier das Paar aus `YOUTUBE_CLIENT_ID` (dem Desktop-Client des alten
    # Weges), meldete die Oberflaeche „verbunden", und der Waechter scheiterte
    # beim naechsten Lauf an `invalid_grant` -- genau der stille Ausfall bis
    # zum Spieltag, den dieser Weg abschaffen soll.
    client_id = ENV.fetch('YOUTUBE_WEB_CLIENT_ID', nil)
    client_secret = ENV.fetch('YOUTUBE_WEB_CLIENT_SECRET', nil)
    return nil if client_id.blank? || client_secret.blank?

    # Wurde die Kennung in der Google Cloud ausgetauscht, passt der gespeicherte
    # Token nicht mehr. Lieber auf die Umgebung zurueckfallen und „nicht
    # verbunden" melden, als in einen Fehlschlag beim naechsten Lauf zu rennen.
    return nil if satz.client_id.present? && satz.client_id != client_id

    { client_id: client_id, client_secret: client_secret, refresh_token: token, source: 'db' }
  end

  def connected?
    refresh_token.present?
  end

  def refresh_token
    return nil if refresh_token_ciphertext.blank? || !self.class.key?

    encryptor.decrypt_and_verify(refresh_token_ciphertext)
  rescue ActiveSupport::MessageEncryptor::InvalidMessage, ActiveSupport::MessageVerifier::InvalidSignature
    # Falscher oder gewechselter Schluessel. Das ist der Normalfall auf Staging
    # und kein Fehler, ueber den etwas stolpern soll -- nur eben kein Zugang.
    nil
  end

  def refresh_token=(wert)
    # LEEREN GEHT IMMER, auch ohne Schluessel: Das Trennen muss selbst dann
    # funktionieren, wenn der Schluessel gewechselt wurde und die Zeile
    # unlesbar geworden ist -- sonst bliebe ein unbrauchbarer Zugang stehen,
    # den niemand mehr loswird.
    if wert.blank?
      self.refresh_token_ciphertext = nil
      return
    end

    unless self.class.key?
      raise ArgumentError, "#{KEY_ENV} ist nicht gesetzt, der Zugang kann nicht gespeichert werden"
    end

    self.refresh_token_ciphertext = encryptor.encrypt_and_sign(wert.to_s)
  end

  private

  def encryptor
    self.class.encryptor
  end
end
