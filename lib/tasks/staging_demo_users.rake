# lib/tasks/staging_demo_users.rake
#
# Legt die kuratierten Demo-/Test-Benutzer (ein Login je Rolle) auf der
# STAGING-Datenbank an, nachdem ein 1:1-Prod-Klon eingespielt wurde (siehe
# saisonmanager-docker: scripts/staging-db-refresh.sh).
#
# Hintergrund: Der Refresh ersetzt die Staging-users-Tabelle vollständig durch
# die echten Prod-User. Damit sich auf Staging beliebige Rollen testen lassen,
# ohne echte Prod-Passwörter zu kennen, ergänzt dieser Task anschließend die
# Demo-Konten mit einem bekannten Passwort. Die Definitionen liegen in
# db/staging_demo_users.json.
#
# Idempotent: Konten werden per user_name gesucht und angelegt bzw. aktualisiert.
# Rollen-Referenzen (game_operation_id/club_id) sind stabile IDs; Team-IDs eines
# Teammanagers wandern zwischen Prod-Ständen und werden daher frisch über den
# Club der aktuellen Saison aufgelöst. Fehlende Referenzen werden nur gemeldet,
# nicht als Abbruch behandelt.
#
# Aufruf (im Staging-Container): bundle exec rails staging:seed_demo_users
# Passwort optional via STAGING_USER_PASSWORD (Default: 'staging-password').
#
# SCHUTZ: Läuft ausschließlich gegen die Staging-DB (verbundener Host muss
# 'staging' enthalten). Gegen die Prod-DB bricht der Task ab, bevor etwas
# geändert wird.

namespace :staging do
  desc 'Legt die Demo-/Test-Benutzer (je Rolle) auf der Staging-DB an.'
  task seed_demo_users: :environment do
    # Schutz gegen die TATSÄCHLICHE Verbindung (nicht nur eine ENV-Variable):
    # die Staging-DB läuft auf Host `postgres-staging`.
    current_host = ActiveRecord::Base.connection_db_config.configuration_hash[:host].to_s
    unless current_host.include?('staging')
      abort "ABBRUCH: staging:seed_demo_users läuft nur gegen die Staging-DB " \
            "(verbundener Host muss 'staging' enthalten, ist: #{current_host.inspect})."
    end

    require 'json'
    password = ENV['STAGING_USER_PASSWORD'].presence || 'staging-password'
    definitions = JSON.parse(Rails.root.join('db', 'staging_demo_users.json').read)

    log = ->(msg) { puts "[staging:seed_demo_users] #{msg}" }
    warnings = []

    definitions.each do |defn|
      user_name = defn['user_name']
      permissions = defn['permissions'] || []

      # Referenzen gegen die frischen Prod-Daten prüfen (nur warnen):
      permissions.each do |p|
        go_id = p['game_operation_id'].to_i
        if p.key?('game_operation_id') && go_id != 0 && !GameOperation.exists?(go_id)
          warnings << "#{user_name}: game_operation_id #{go_id} existiert nicht"
        end
        if p['club_id'].present? && !Club.exists?(p['club_id'].to_i)
          warnings << "#{user_name}: club_id #{p['club_id']} existiert nicht"
        end
      end

      # Teams eines Teammanagers frisch über den Club der aktuellen Saison
      # auflösen (Team-IDs sind zwischen Prod-Ständen nicht stabil).
      teams = []
      Array(defn['team_club_ids']).each do |club_id|
        club_teams = Team.where(club_id: club_id).select do |t|
          t.leagues.any? { |l| l.season_id.to_i == Setting.current_season_id }
        end.map(&:id)
        warnings << "#{user_name}: kein aktuelles Team für club_id #{club_id}" if club_teams.empty?
        teams.concat(club_teams)
      end

      user = User.find_or_initialize_by(user_name: user_name)
      user.assign_attributes(
        first_name: 'Demo',
        last_name: user_name.sub(/\Ademo_/, '').tr('_', ' '),
        email: "#{user_name}@staging.saisonmanager.dev",
        permissions: permissions,
        teams: teams,
        language: 'de',
        password: password,
        archived_at: nil,
        archived_by: nil
      )
      user.save!
    end

    log.call("Demo-Benutzer angelegt/aktualisiert: #{definitions.size}")
    log.call("Passwort aller Demo-Konten lautet jetzt: #{password.inspect}")
    if warnings.any?
      log.call("WARNUNGEN (#{warnings.size}) – Referenzen nach dem Klon prüfen:")
      warnings.each { |w| log.call("  - #{w}") }
    else
      log.call('Alle Rollen-Referenzen aufgelöst.')
    end
  end
end
