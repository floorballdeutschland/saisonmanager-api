namespace :penalties do
  # Bringt den Strafen-Katalog (Setting#penalties, das „Strafe"-Dropdown im
  # Spielbericht) auf den aktuellen Regelstand. Anders als die Strafcodes
  # (Setting#penalty_codes) hat dieser Katalog keine Admin-Oberflaeche, daher
  # diese einmalige, idempotente Wartungs-Task.
  #
  # Zielzustand (aktive Eintraege, in dieser Reihenfolge):
  #   2 Minuten, 2+2 Minuten, 10 Minuten, Matchstrafe, Matchstrafe (technisch)
  # Veraltet und daher ausgeblendet (disabled, NICHT geloescht, damit
  # historische Ereignis-Referenzen erhalten bleiben): 5 Minuten sowie
  # Spielstrafe 1/2/3.
  #
  # Adressiert wird ueber das stabile `mapping`, nicht ueber die id, damit die
  # Task auf Prod und Staging unabhaengig von der konkreten id-Vergabe wirkt.
  #
  # Standardmaessig Dry-Run; zum Anwenden: DRY_RUN=false rails penalties:normalize_catalog
  desc 'Strafen-Katalog (Setting#penalties) auf aktuellen Regelstand bringen (DRY_RUN=false zum Anwenden)'
  task normalize_catalog: :environment do
    dry_run = ENV.fetch('DRY_RUN', 'true') != 'false'

    # mapping => [Zielname, Reihenfolge]
    rename = {
      'penalty_2' => ['2 Minuten', 1],
      'penalty_2and2' => ['2+2 Minuten', 2],
      'penalty_10' => ['10 Minuten', 3],
      'penalty_ms_full' => ['Matchstrafe', 4],
      'penalty_ms_tech' => ['Matchstrafe (technisch)', 5]
    }
    disable_mappings = %w[penalty_5 penalty_ms1 penalty_ms2 penalty_ms3]

    setting = Setting.current
    penalties = (setting.penalties || {}).deep_dup
    changes = []

    penalties.each do |id, entry|
      next unless entry.is_a?(Hash)

      mapping = entry['mapping']
      if rename.key?(mapping)
        name, order = rename[mapping]
        next if entry['name'] == name && entry['order'] == order && !entry['disabled']

        changes << "##{id} (#{mapping}): \"#{entry['name']}\" -> \"#{name}\" (Reihenfolge #{order}, aktiv)"
        entry['name'] = name
        entry['order'] = order
        entry.delete('disabled')
      elsif disable_mappings.include?(mapping)
        next if entry['disabled']

        changes << "##{id} (#{mapping}): \"#{entry['name']}\" -> ausgeblendet"
        entry['disabled'] = true
      end
    end

    if changes.empty?
      puts 'Strafen-Katalog ist bereits im Zielzustand, keine Aenderung noetig.'
    elsif dry_run
      puts "[DRY RUN] #{changes.size} Aenderung(en) wuerden angewendet (DRY_RUN=false zum Anwenden):"
      changes.each { |c| puts "  #{c}" }
    else
      setting.penalties = penalties
      setting.save!
      Rails.cache.delete('settings/init')
      puts "#{changes.size} Aenderung(en) angewendet:"
      changes.each { |c| puts "  #{c}" }
    end
  end
end
