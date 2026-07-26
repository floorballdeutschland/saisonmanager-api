# lib/tasks/staging_prune_limited_users.rake
#
# Entfernt auf der STAGING-Datenbank alle Benutzerkonten, deren Rollen
# ausschließlich Vereinsmanager (VM), Teammanager (TM) oder Schiedsrichter-
# Self-Service sind. Läuft nach dem 1:1-Prod-Klon (siehe saisonmanager-docker:
# scripts/staging-db-refresh.sh) und VOR dem Demo-User-Seed.
#
# Hintergrund: Der Klon spielt alle echten Prod-User inkl. Passwörtern ein.
# Auf Staging sollen aber nur die administrativen Konten (Admin/SBK/RSK/
# Ansetzer) als echte Logins landen; die zahlreichen reinen VM-/TM-/Schiri-
# Konten werden nicht übertragen (Datenminimierung). Die entsprechenden Rollen
# lassen sich weiterhin über die Demo-Konten testen (staging:seed_demo_users).
#
# Rollen-IDs (user_group_id): 1 Admin, 2 SBK, 3 RSK, 4 VM, 5 TM,
# 6 Schiedsrichter (Self-Service), 7 Ansetzer.
# Behalten wird ein Konto, sobald es mindestens eine Rolle aus {1,2,3,7} hat.
#
# Aufruf (im Staging-Container): bundle exec rails staging:prune_limited_users
#
# SCHUTZ: Läuft ausschließlich gegen die Staging-DB (verbundener Host muss
# 'staging' enthalten). Gegen die Prod-DB bricht der Task ab, bevor etwas
# geändert wird.

namespace :staging do
  desc 'Entfernt reine VM-/TM-/Schiedsrichter-Konten auf der Staging-DB.'
  task prune_limited_users: :environment do
    current_host = ActiveRecord::Base.connection_db_config.configuration_hash[:host].to_s
    unless current_host.include?('staging')
      abort "ABBRUCH: staging:prune_limited_users läuft nur gegen die Staging-DB " \
            "(verbundener Host muss 'staging' enthalten, ist: #{current_host.inspect})."
    end

    keep_groups = [1, 2, 3, 7] # Admin, SBK, RSK, Ansetzer
    log = ->(msg) { puts "[staging:prune_limited_users] #{msg}" }

    # Demo-Konten nie anfassen (die legt staging:seed_demo_users an; falls dieser
    # Task versehentlich nach dem Seed läuft, bleiben sie so trotzdem erhalten).
    candidates = User.where('user_name NOT ILIKE ?', 'demo_%')
    remove = candidates.select do |u|
      perms = u.permissions || []
      perms.none? { |p| keep_groups.include?(p['user_group_id'].to_i) }
    end
    remove_ids = remove.map(&:id)

    if remove_ids.empty?
      log.call('Keine reinen VM-/TM-/Schiri-Konten gefunden – nichts zu tun.')
      next
    end

    # Fallback-Benutzer, auf den vereinzelte Tracking-Referenzen (created_by/
    # uploaded_by) umgehängt werden, damit die betroffenen Konten löschbar sind
    # (drei dieser FK-Spalten sind NOT NULL). Bevorzugt ein verbleibender Admin.
    survivors = User.where('user_name NOT ILIKE ?', 'demo_%').where.not(id: remove_ids)
    fallback = survivors.detect { |u| (u.permissions || []).any? { |p| p['user_group_id'].to_i == 1 } } ||
               survivors.first
    abort 'ABBRUCH: kein Fallback-Benutzer für die FK-Umhängung gefunden.' if fallback.nil?

    # Alle Fremdschlüssel, die auf users zeigen (aus db/schema.rb).
    fk_columns = {
      'game_day_secretary_links' => 'created_by_id',
      'game_referee_reports' => 'uploaded_by_id',
      'game_scans' => 'uploaded_by_id',
      'license_documents' => 'uploaded_by_id',
      'referee_course_imports' => 'uploaded_by_user_id',
      'referee_course_results' => 'reviewed_by_user_id'
    }

    conn = ActiveRecord::Base.connection
    id_list = remove_ids.join(',')

    ActiveRecord::Base.transaction do
      fk_columns.each do |table, col|
        n = conn.update("UPDATE #{table} SET #{col} = #{fallback.id} WHERE #{col} IN (#{id_list})")
        log.call("#{table}.#{col}: #{n} Referenz(en) auf #{fallback.user_name.inspect} umgehängt") if n.positive?
      end
      deleted = User.where(id: remove_ids).delete_all
      log.call("Benutzerkonten entfernt (nur VM/TM/Schiri): #{deleted}")
    end

    log.call("Verbleibende Benutzer: #{User.count} (davon demo_*: " \
             "#{User.where('user_name ILIKE ?', 'demo_%').count})")
  end
end
