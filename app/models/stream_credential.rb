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
    first
  end

  # Kann an dieser Stelle ueberhaupt etwas gespeichert oder gelesen werden?
  def self.key?
    ENV[KEY_ENV].present?
  end

  # Der einsatzbereite Zugang oder nil. Nil heisst hier immer "nimm die
  # Umgebungsvariablen" -- der Aufrufer muss nicht wissen, warum.
  def self.credentials
    satz = current
    return nil if satz.nil?

    token = satz.refresh_token
    return nil if token.blank?

    # Ohne Client-Paar ist der Token wertlos: Google erneuert ihn nur gegen das
    # Paar, mit dem er ausgegeben wurde.
    client_id = ENV.fetch('YOUTUBE_CLIENT_ID', nil)
    client_secret = ENV.fetch('YOUTUBE_CLIENT_SECRET', nil)
    return nil if client_id.blank? || client_secret.blank?

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
    schluessel = ActiveSupport::KeyGenerator.new(ENV.fetch(KEY_ENV))
                                            .generate_key('youtube-refresh-token', 32)
    ActiveSupport::MessageEncryptor.new(schluessel)
  end
end
