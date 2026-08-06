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
#     Staging existiert und frei ist (auf `users.referee_id` liegen ein
#     Fremdschlüssel und ein partieller Unique-Index, im Modell steht dazu
#     keine Validierung).
#   * `archived_by` bleibt leer, auch wenn `archived_at` übernommen wird: Die
#     ID zeigte auf einen Prod-Benutzer und wäre auf Staging eine andere Person.
#
# Konten, die es nur auf Staging gibt (auf Prod gelöscht oder umbenannt),
# werden gemeldet, aber nicht gelöscht: Das Löschen braucht die
# Fremdschlüssel-Umhängung aus staging:prune_limited_users und soll nicht
# beiläufig passieren.
#
# Scheitert ein Konto, läuft der Rest trotzdem durch (der Task ist
# wiederholbar), die Zusammenfassung nennt es unter FEHLER und der Task endet
# mit einem Fehler-Exit. Ein Lauf, der die Hälfte nicht schreiben konnte, darf
# nicht wie ein erfolgreicher aussehen.
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
    demo_skipped = []
    # Hinweise zu Datensätzen, die übernommen wurden (eine Verknüpfung fehlt),
    # streng getrennt von Fehlern: Nach einem Fehler steht das Konto NICHT auf
    # Prod-Stand, behält also womöglich Rechte, die es dort nicht mehr hat. Das
    # darf nicht zwischen zwanzig Zeilen „referee_id gibt es nicht" untergehen.
    notes = []
    failures = []
    unchanged = 0

    # permissions kommt aus einer JSONB-Spalte und ist nicht garantiert die
    # erwartete Liste von Objekten. Eine kaputte Form darf nicht dazu führen,
    # dass ein Admin-Konto stillschweigend als „nur VM/TM/Schiri" durchgeht.
    keeps_access = lambda do |permissions, user_name|
      unless permissions.nil? || permissions.is_a?(Array)
        notes << "#{user_name}: permissions ist kein Array (#{permissions.class}) – als eingeschränkt behandelt"
        return false
      end

      Array(permissions).any? { |p| p.is_a?(Hash) && keep_groups.include?(p['user_group_id'].to_i) }
    end

    # Der Abgleich muss so vergleichen, wie das Modell vergleicht: Die
    # Eindeutigkeit von user_name ist case-insensitive (User#validates), der
    # Name selbst wird aber nur getrimmt, nicht kleingeschrieben. Ein
    # `find_by(user_name:)` verfehlte „Max.Mustermann" gegenüber
    # „max.mustermann", legte neu an und scheiterte danach an der Validierung –
    # und zwar bei jedem Lauf aufs Neue.
    find_user = ->(name) { User.where('LOWER(user_name) = ?', name.downcase).first }

    records.each_with_index do |record, index|
      unless record.is_a?(Hash)
        failures << "Datensatz ##{index} ist kein Objekt (#{record.class})"
        next
      end

      user_name = record['user_name'].to_s.strip
      if user_name.blank?
        failures << "Datensatz ##{index} ohne user_name übersprungen (E-Mail: #{record['email'].inspect})"
        next
      end

      # Demo-Konten gehören dem Testsystem. Ein Prod-Konto mit einem
      # `demo_`-Namen dürfte es nicht geben, aber überschreiben würde hier das
      # bekannte Passwort und die kuratierte Rolle zerstören.
      if user_name.downcase.start_with?('demo_')
        demo_skipped << user_name
        next
      end

      existing = find_user.call(user_name)
      privileged = keeps_access.call(record['permissions'], user_name)

      if existing.nil? && !privileged
        skipped_limited << user_name
        next
      end

      attributes = record.slice(*synced_columns)
      attributes['permissions'] = Array(record['permissions'])

      # Auf users.referee_id liegt ein Fremdschlüssel UND ein partieller
      # Unique-Index, im Modell steht dazu keine Validierung. Ein unbekannter
      # oder schon vergebener Wert brächte also keine Fehlermeldung, sondern
      # eine RecordNotUnique bzw. eine Fremdschlüsselverletzung mitten im Lauf.
      # Vergeben ist er realistisch, wenn ein Konto auf Prod umbenannt wurde:
      # Der alte Datensatz steht auf Staging noch (gelöscht wird hier nie) und
      # hält denselben Schiedsrichter.
      referee_id = record['referee_id']
      if referee_id.present? && !Referee.exists?(referee_id)
        notes << "#{user_name}: referee_id #{referee_id} gibt es auf Staging nicht – ohne Verknüpfung übernommen"
        referee_id = nil
      elsif referee_id.present? &&
            User.where(referee_id: referee_id).where.not(id: existing&.id).exists?
        notes << "#{user_name}: referee_id #{referee_id} hängt auf Staging an einem anderen Konto – " \
                 'ohne Verknüpfung übernommen'
        referee_id = nil
      end
      attributes['referee_id'] = referee_id

      club_id = record['club_id']
      if club_id.present? && !Club.exists?(club_id)
        notes << "#{user_name}: club_id #{club_id} gibt es auf Staging nicht – ohne Verein übernommen"
        club_id = nil
      end
      attributes['club_id'] = club_id

      user = existing || User.new(user_name: user_name)
      user.assign_attributes(attributes)

      # Auch ohne Änderung melden, sonst verschwindet ein bereits herabgestuftes
      # Konto ab dem zweiten Lauf aus der Liste der Prune-Kandidaten.
      downgraded << user_name if existing && !privileged

      if existing && !user.changed?
        unchanged += 1
        next
      end

      changed_columns = user.changed
      applied = "#{user_name} (#{changed_columns.join(', ')})"

      # Der Probelauf prüft mit, statt nur zu zählen: Sonst meldete er „12 neu"
      # und der scharfe Lauf legte 9 an, weil drei an einer Validierung
      # scheitern. Genau dafür läuft man ihn.
      begin
        if dry_run
          if user.valid?
            existing ? updated << applied : created << user_name
          else
            failures << "#{user_name}: würde scheitern (#{user.errors.full_messages.join('; ')})"
          end
        elsif user.save
          existing ? updated << applied : created << user_name
        else
          failures << "#{user_name}: nicht gespeichert (#{user.errors.full_messages.join('; ')})"
        end
      rescue StandardError => e
        # Ohne dieses rescue reißt ein einzelner Datensatz den ganzen Lauf ab,
        # nachdem er schon geschrieben hat, und die Zusammenfassung unten wird
        # nie ausgegeben: Der Operator wüsste nicht, was angekommen ist.
        failures << "#{user_name}: #{e.class} – #{e.message}"
      end
    end

    exported_names = records.filter_map do |r|
      r.is_a?(Hash) ? r['user_name'].to_s.strip.downcase.presence : nil
    end
    # `demo\_%`: In LIKE ist `_` ein Platzhalter für ein beliebiges Zeichen,
    # ungeschützt fiele also auch ein „demo.tester" aus dem Bericht. Der
    # Abgleich passiert in Ruby, damit eine leere Namensliste kein `IN ()`
    # erzeugt und die Kleinschreibung dieselbe ist wie oben beim Suchen.
    only_on_staging = User.where('user_name NOT ILIKE ?', 'demo\_%')
                          .pluck(:user_name)
                          .reject { |name| exported_names.include?(name.downcase) }

    log.call("Export: #{records.size} Konto/Konten von Prod")
    log.call("Neu angelegt: #{created.size}#{" – #{created.join(', ')}" if created.any?}")
    log.call("Aktualisiert: #{updated.size}")
    updated.each { |u| log.call("  - #{u}") }
    log.call("Unverändert: #{unchanged}")
    if skipped_limited.any?
      # Mit Namen, nicht nur als Zahl: Steht hier jemand, den man als Admin oder
      # SBK kennt, stimmt etwas mit den Rollen im Export nicht.
      log.call("Nicht angelegt (nur VM/TM/Schiri): #{skipped_limited.size}")
      skipped_limited.each { |u| log.call("  - #{u}") }
    end
    log.call("Demo-Namen im Export übersprungen: #{demo_skipped.size}") if demo_skipped.any?
    if downgraded.any?
      log.call("Ohne Admin/SBK/RSK/Ansetzer-Rolle, auf Prod-Stand zurückgenommen " \
               "(#{downgraded.size}) – mit staging:prune_limited_users entfernbar:")
      downgraded.each { |u| log.call("  - #{u}") }
    end
    if only_on_staging.any?
      log.call("Nur auf Staging vorhanden, auf Prod nicht (nicht gelöscht) (#{only_on_staging.size}):")
      only_on_staging.each { |u| log.call("  - #{u}") }
    end
    if notes.any?
      log.call("HINWEISE (#{notes.size}) – diese Konten sind übernommen, eine Verknüpfung fehlt:")
      notes.each { |n| log.call("  - #{n}") }
    end
    log.call("Benutzer auf Staging jetzt: #{User.count} " \
             "(davon demo_*: #{User.where('user_name ILIKE ?', 'demo\_%').count})")

    # Gegenprobe: Jeder exportierte Datensatz muss in genau einem Topf gelandet
    # sein. Geht die Rechnung nicht auf, fehlt oben ein Zweig, und das Ergebnis
    # ist nicht das, was der Bericht behauptet.
    accounted = created.size + updated.size + unchanged + skipped_limited.size +
                demo_skipped.size + failures.size
    if accounted != records.size
      log.call("WARNUNG: #{records.size - accounted} Datensätze tauchen in keiner Kategorie auf.")
    end

    # Ohne Exit-Code hätte ein Lauf, der die Hälfte der Konten nicht schreiben
    # konnte, dasselbe Ergebnis wie ein erfolgreicher: Das Wrapper-Skript läuft
    # unter `set -e` und meldete am Ende „abgeglichen". Ein fehlgeschlagenes
    # Konto behält auf Staging womöglich Rechte, die es auf Prod nicht mehr hat.
    #
    # Kein `return` hier: Im Rake-Block wäre das ein LocalJumpError.
    if failures.any?
      warn "[staging:sync_users] FEHLER (#{failures.size}) – diese Konten stehen NICHT auf Prod-Stand:"
      failures.each { |f| warn "  - #{f}" }
      abort "ABBRUCH: #{failures.size} von #{records.size} Konten nicht übernommen. " \
            'Ursache beheben und erneut laufen lassen, der Task ist wiederholbar.'
    end
  end
end
