# lib/tasks/staging_anonymize.rake
#
# Anonymisiert personenbezogene Daten auf der STAGING-Datenbank, nachdem ein
# Prod-Klon eingespielt wurde (siehe saisonmanager-docker: scripts/staging-db-refresh.sh).
# Scrubt Namen, E-Mail-Adressen, Geburtsdaten und Pass-/Sicherheitsnummern und
# setzt alle Benutzer-Passwörter auf einen bekannten Wert, damit Test-Logins
# funktionieren. Rollen (permissions) und Login-Handles (user_name) bleiben
# erhalten, damit pro Rolle getestet werden kann.
#
# Aufruf (im Staging-Container): bundle exec rails staging:anonymize
# Test-Passwort optional via STAGING_USER_PASSWORD (Default: 'staging-password').
#
# SCHUTZ: Läuft ausschließlich gegen die Staging-DB (DB_HOST enthält 'staging').
# Auf dem Prod-Container bricht der Task ab, bevor irgendetwas geändert wird.

namespace :staging do
  desc 'Anonymisiert PII auf der Staging-DB und setzt alle Login-Passwörter zurück.'
  task anonymize: :environment do
    db_host = ENV.fetch('DB_HOST', '')
    unless db_host.include?('staging')
      abort "ABBRUCH: staging:anonymize läuft nur gegen die Staging-DB " \
            "(DB_HOST muss 'staging' enthalten, ist: #{db_host.inspect})."
    end

    require 'bcrypt'
    password = ENV['STAGING_USER_PASSWORD'].presence || 'staging-password'
    digest = BCrypt::Password.create(password)

    conn = ActiveRecord::Base.connection
    log = ->(msg) { puts "[staging:anonymize] #{msg}" }

    ActiveRecord::Base.transaction do
      # Users: Namen/E-Mail scrubben, ALLE Passwörter auf einen bekannten Wert.
      # user_name (Login-Handle) und permissions (Rollen) bleiben erhalten.
      users = conn.update(<<~SQL.squish)
        UPDATE users SET
          first_name = 'Test',
          last_name  = CONCAT('User', id),
          email      = CONCAT('user', id, '@staging.saisonmanager.dev'),
          password_digest = #{conn.quote(digest)},
          password_reset_token = NULL,
          hash_id = NULL,
          description = NULL
      SQL
      log.call("users anonymisiert: #{users}")

      # Players: Name, Geburtsdatum, E-Mail und Pass (security_id) scrubben.
      players = conn.update(<<~SQL.squish)
        UPDATE players SET
          first_name  = 'Spieler',
          last_name   = CONCAT('#', id),
          birthdate   = '2000-01-01',
          email       = NULL,
          security_id = CONCAT('ANON-', id)
      SQL
      log.call("players anonymisiert: #{players}")

      # Referees: Name, Geburtsdatum, Kontakt und Adresse scrubben.
      # lizenznummer bleibt (funktionaler, semi-öffentlicher Schlüssel);
      # Wallet-Pass-Links auf echte Passmeister-Pässe werden entfernt.
      referees = conn.update(<<~SQL.squish)
        UPDATE referees SET
          vorname = 'Schiri',
          nachname = CONCAT('#', id),
          geburtsdatum = '2000-01-01',
          email = NULL,
          telefonnummer = NULL,
          strasse = NULL,
          hausnummer = NULL,
          plz = NULL,
          ort = NULL,
          wallet_pass_url = NULL,
          wallet_pass_issued_at = NULL
      SQL
      log.call("referees anonymisiert: #{referees}")
    end

    log.call("Fertig. Alle Benutzer-Passwörter lauten jetzt: #{password.inspect}")
  end
end
