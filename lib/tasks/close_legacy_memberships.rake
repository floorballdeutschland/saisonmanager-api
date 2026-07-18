# lib/tasks/close_legacy_memberships.rake
#
# Schließt offene Legacy-Vereinsmitgliedschaften (created_at nil & valid_until nil)
# zum Startdatum (created_at) des frühesten datierten Folgevereins.
#
# Als Folgeverein zählen nur ANDERE, echte Vereine – Einträge desselben Vereins
# (Rückkehr/Freigabe) und Platzhalter-/Ablage-Vereine (Name matcht dem Junk-Muster
# oder Verein ist deaktiviert) werden ignoriert. Bleibt danach kein datierter
# Folgeeintrag, bleibt die Mitgliedschaft offen (kein erfundenes Datum).
#
# Unterschied zu players:fix_club_valid_until: dieser Task setzt das EXAKTE
# Startdatum des Folgevereins als Ende (kein Saisonende-Heuristik, keine Lücke).
#
# Dry-Run (Standard):
#   bundle exec rails players:close_legacy_memberships
# Ausführen:
#   bundle exec rails players:close_legacy_memberships DRY_RUN=false

namespace :players do
  desc 'Schließt offene Legacy-Mitgliedschaften zum Startdatum des Folgevereins. DRY_RUN=false zum Ausführen.'
  task close_legacy_memberships: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'
    puts "=== Legacy-Mitgliedschaften schließen #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="

    ignore_ids = ignore_club_ids
    puts "Ignorierte Platzhalter-/deaktivierte Vereine (kein Folgeverein): #{ignore_ids.size} " \
         "(#{Club.where(id: ignore_ids).order(:id).pluck(:id, :name).map { |i, n| "#{i}:#{n}" }.join(', ')})"

    # Nur Spieler mit mindestens einem offenen Legacy-Eintrag laden.
    scope = Player.where(merged_into_id: nil).where(
      "EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(clubs,'[]'::jsonb)) e " \
      "WHERE e->>'created_at' IS NULL AND e->>'valid_until' IS NULL)"
    )

    closed_players = 0
    closed_entries = 0
    skipped_players = 0 # offener Eintrag, aber kein echter Folgeverein → offen gelassen

    scope.find_each do |player|
      clubs = player.clubs || []
      new_clubs, changed = LegacyImport::MembershipCloser.close(clubs, ignore_club_ids: ignore_ids)

      unless changed
        # offener Eintrag, aber (nach Ausschluss von Platzhalter/selbem Verein)
        # kein datierter Folgeverein → bleibt bewusst offen.
        has_open = clubs.any? { |c| LegacyImport::MembershipCloser.open_legacy?(c) }
        has_dated = clubs.any? { |c| c['created_at'].present? }
        skipped_players += 1 if has_open && has_dated
        next
      end

      before = clubs.count { |c| c['valid_until'].present? }
      after  = new_clubs.count { |c| c['valid_until'].present? }
      newly_closed = after - before
      closed_players += 1
      closed_entries += newly_closed

      open_entry = clubs.find { |c| LegacyImport::MembershipCloser.open_legacy?(c) }
      succ = LegacyImport::MembershipCloser.successor_start(clubs, open_entry['club_id'], ignore_ids)
      puts "--- ##{player.id} #{player.last_name}, #{player.first_name}: " \
           "#{newly_closed} Eintrag/Einträge → #{succ}#{dry_run ? ' [DRY RUN]' : ''}"

      next if dry_run

      player.clubs = new_clubs
      player.save!(validate: false)
    end

    puts "\nErgebnis: #{closed_players} Spieler, #{closed_entries} geschlossene Mitgliedschaften"
    puts "Offen gelassen (kein echter Folgeverein – nur Platzhalter/selber Verein): #{skipped_players}"
    puts '[DRY RUN] Zum Ausführen: rails players:close_legacy_memberships DRY_RUN=false' if dry_run
  end

  # club_ids, die nicht als Folgeverein zählen: Platzhalter/Ablage (Namensmuster)
  # + deaktivierte Vereine. Kuratiert im operativen Task (der MembershipCloser-
  # Service bleibt DB-frei).
  def ignore_club_ids
    junk = Club.where('name ~* ?', '(^z_|^zz|ablage|not in use|doppelung)').pluck(:id)
    deactivated = Club.where.not(deactivated_at: nil).pluck(:id)
    (junk + deactivated).uniq
  end
end
