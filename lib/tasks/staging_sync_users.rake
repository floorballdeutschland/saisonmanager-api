# lib/tasks/staging_sync_users.rake
#
# Zieht den Benutzerkontenstand von Prod auf die STAGING-Datenbank nach, ohne
# den Rest der Datenbank anzufassen. Gedacht für die Zeit zwischen zwei vollen
# Refreshes: Konten, die auf Prod nach dem letzten Klon angelegt oder geändert
# wurden (neue SBK-Kolleginnen, geänderte Rollen, neues Passwort), fehlen auf
# Staging sonst bis zum nächsten `staging-db-refresh.sh` – und der verwirft
# alle nur auf Staging aufgebauten Testdaten.
#
# Der Task liest die Prod-Konten als JSON von STDIN; das Auslesen erledigt
# saisonmanager-docker: scripts/staging-sync-users.sh, das den Weg von der
# Prod- in die Staging-Datenbank kennt (der Staging-Container erreicht die
# Prod-Datenbank absichtlich nicht).
#
# Abgeglichen wird über `user_name`, nicht über die ID: Die auf Staging
# vergebenen IDs weichen von Prod ab (die Demo-Konten sind nach dem Klon
# angelegt worden) und werden von Tracking-Spalten wie `uploaded_by_id`
# referenziert. Bestehende Konten behalten deshalb ihre Staging-ID.
#
# Regeln, die die Entscheidungen zum Staging-System fortschreiben:
#
#   * `demo_*` wird nie angefasst. Diese Konten gehören dem Testsystem
#     (staging:seed_demo_users) und haben ein bekanntes Passwort.
#   * Konten, deren Rollen ausschließlich Vereinsmanager, Teammanager oder
#     Schiedsrichter-Self-Service sind, werden NICHT neu angelegt
#     (Datenminimierung, dieselbe Regel wie staging:prune_limited_users).
#     Existiert ein solches Konto schon, wird es trotzdem aktualisiert – sonst
#     behielte es auf Staging Rechte, die es auf Prod nicht mehr hat. Der Task
#     nennt diese Konten am Ende; sie lassen sich mit
#     staging:prune_limited_users entfernen, der auch die Fremdschlüssel
#     umhängt.
#   * `teams` wird bewusst nicht übernommen: Team-IDs sind zwischen Prod und
#     einem älteren Klon nicht stabil, ein übernommener Wert zeigte also
#     womöglich auf eine fremde Mannschaft. Die behaltenen Rollen arbeiten
#     nicht team-bezogen.
#   * `referee_id` und `club_id` werden nur übernommen, wenn der Datensatz auf
#     Staging existiert (auf `users.referee_id` liegt ein Fremdschlüssel).
#
# Konten, die es nur auf Staging gibt (auf Prod gelöscht oder umbenannt),
# werden gemeldet, aber nicht gelöscht: Das Löschen braucht die
# Fremdschlüssel-Umhängung aus staging:prune_limited_users und soll nicht
# beiläufig passieren.
#
# Aufruf (im Staging-Container):
#   bundle exec rails staging:sync_users < prod_users.json
#   DRY_RUN=true bundle exec rails staging:sync_users < prod_users.json
#
# SCHUTZ: Läuft ausschließlich gegen die Staging-DB (verbundener Host muss
# 'staging' enthalten). Gegen die Prod-DB bricht der Task ab, bevor etwas
# geändert wird.

namespace :staging do
  desc 'Gleicht die Benutzerkonten der Staging-DB mit einem Prod-Export (JSON auf STDIN) ab.'
  task sync_users: :environment do
    current_host = ActiveRecord::Base.connection_db_config.configuration_hash[:host].to_s
    unless current_host.include?('staging')
      abort "ABBRUCH: staging:sync_users läuft nur gegen die Staging-DB " \
            "(verbundener Host muss 'staging' enthalten, ist: #{current_host.inspect})."
    end

    require 'json'

    log = ->(msg) { puts "[staging:sync_users] #{msg}" }
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV['DRY_RUN']).present?
    log.call('DRY_RUN: es wird nichts geschrieben.') if dry_run

    keep_groups = [1, 2, 3, 7] # Admin, SBK, RSK, Ansetzer

    raw = $stdin.read
    abort 'ABBRUCH: kein Export auf STDIN. Aufruf: rails staging:sync_users < prod_users.json' if raw.blank?

    begin
      records = JSON.parse(raw)
    rescue JSON::ParserError => e
      abort "ABBRUCH: Export ist kein gültiges JSON (#{e.message})."
    end
    abort 'ABBRUCH: Export ist keine Liste von Konten.' unless records.is_a?(Array)
    abort 'ABBRUCH: Export ist leer – das wäre kein plausibler Prod-Stand.' if records.empty?

    # Spalten, die übernommen werden. Nicht dabei: id (Staging vergibt eigene),
    # teams (volatile Team-IDs), die Zeitstempel und die Felder laufender
    # Vorgänge (Passwort-Reset, E-Mail-Bestätigung) – die gehören zur Sitzung
    # auf Prod und haben auf Staging nichts verloren.
    synced_columns = %w[email first_name last_name password_digest permissions
                        language receive_info_mails privacy_approved description
                        archived_at]

    created = []
    updated = []
    skipped_limited = []
    downgraded = []
    warnings = []
    unchanged = 0

    keeps_access = lambda do |permissions|
      Array(permissions).any? { |p| keep_groups.include?(p['user_group_id'].to_i) }
    end

    records.each do |record|
      user_name = record['user_name'].to_s.strip
      if user_name.blank?
        warnings << 'Datensatz ohne user_name übersprungen'
        next
      end

      # Demo-Konten gehören dem Testsystem. Ein Prod-Konto mit einem
      # `demo_`-Namen dürfte es nicht geben, aber überschreiben würde hier das
      # bekannte Passwort und die kuratierte Rolle zerstören.
      if user_name.downcase.start_with?('demo_')
        warnings << "#{user_name}: Demo-Name im Prod-Export – übersprungen"
        next
      end

      existing = User.find_by(user_name: user_name)
      privileged = keeps_access.call(record['permissions'])

      if existing.nil? && !privileged
        skipped_limited << user_name
        next
      end

      attributes = record.slice(*synced_columns)
      attributes['permissions'] = Array(record['permissions'])

      # Auf users.referee_id liegt ein Fremdschlüssel, und der Klon kennt nur
      # die Schiedsrichter seines Stands. Ein unbekannter Wert würde den
      # Datensatz unrettbar scheitern lassen, deshalb lieber ohne Verknüpfung
      # anlegen und das melden.
      referee_id = record['referee_id']
      if referee_id.present? && !Referee.exists?(referee_id)
        warnings << "#{user_name}: referee_id #{referee_id} gibt es auf Staging nicht – ohne Verknüpfung übernommen"
        referee_id = nil
      end
      attributes['referee_id'] = referee_id

      club_id = record['club_id']
      if club_id.present? && !Club.exists?(club_id)
        warnings << "#{user_name}: club_id #{club_id} gibt es auf Staging nicht – ohne Verein übernommen"
        club_id = nil
      end
      attributes['club_id'] = club_id

      user = existing || User.new(user_name: user_name)
      user.assign_attributes(attributes)

      if existing && !user.changed?
        unchanged += 1
        next
      end

      changed_columns = user.changed
      if dry_run
        existing ? updated << "#{user_name} (#{changed_columns.join(', ')})" : created << user_name
      elsif user.save
        existing ? updated << "#{user_name} (#{changed_columns.join(', ')})" : created << user_name
      else
        warnings << "#{user_name}: nicht gespeichert (#{user.errors.full_messages.join('; ')})"
        next
      end

      downgraded << user_name if existing && !privileged
    end

    exported_names = records.filter_map { |r| r['user_name'].to_s.strip.presence }
    only_on_staging = User.where.not(user_name: exported_names)
                          .where('user_name NOT ILIKE ?', 'demo_%')
                          .pluck(:user_name)

    log.call("Export: #{records.size} Konto/Konten von Prod")
    log.call("Neu angelegt: #{created.size}#{" – #{created.join(', ')}" if created.any?}")
    log.call("Aktualisiert: #{updated.size}")
    updated.each { |u| log.call("  - #{u}") }
    log.call("Unverändert: #{unchanged}")
    if skipped_limited.any?
      log.call("Nicht angelegt (nur VM/TM/Schiri): #{skipped_limited.size}")
    end
    if downgraded.any?
      log.call("Rechte auf Prod-Stand zurückgenommen, jetzt ohne Admin/SBK/RSK/Ansetzer-Rolle " \
               "(#{downgraded.size}) – mit staging:prune_limited_users entfernbar:")
      downgraded.each { |u| log.call("  - #{u}") }
    end
    if only_on_staging.any?
      log.call("Nur auf Staging vorhanden, auf Prod nicht (nicht gelöscht) (#{only_on_staging.size}):")
      only_on_staging.each { |u| log.call("  - #{u}") }
    end
    if warnings.any?
      log.call("WARNUNGEN (#{warnings.size}):")
      warnings.each { |w| log.call("  - #{w}") }
    end
    log.call("Benutzer auf Staging jetzt: #{User.count} " \
             "(davon demo_*: #{User.where('user_name ILIKE ?', 'demo_%').count})")
  end
end
