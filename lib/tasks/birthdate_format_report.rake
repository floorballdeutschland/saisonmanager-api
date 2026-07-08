# Read-only-Analyse der players.birthdate-Werte vor der Umstellung auf eine
# echte date-Spalte (ChangePlayersBirthdateToDate). Zeigt die Formatverteilung
# und listet alle Werte, die die Migration nicht automatisch lesen kann.
namespace :players do
  desc 'Formatverteilung von players.birthdate melden (read-only)'
  task birthdate_format_report: :environment do
    require Rails.root.join('db/migrate/20260708120000_change_players_birthdate_to_date')

    buckets = Hash.new { |h, k| h[k] = [] }
    Player.pluck(:id, :birthdate).each do |id, raw|
      buckets[birthdate_bucket_for(raw)] << [id, raw]
    end

    total = buckets.values.sum(&:size)
    puts "players gesamt: #{total}"
    %i[iso deutsch leer nulldatum unlesbar].each do |bucket|
      rows = buckets[bucket]
      puts format('  %-10<name>s %6<count>d', name: bucket, count: rows.size)
    end

    problem_rows = buckets[:unlesbar]
    if problem_rows.any?
      puts "\nNicht automatisch lesbar (Migration würde abbrechen):"
      problem_rows.first(50).each { |id, raw| puts "  ##{id}: #{raw.inspect}" }
      puts "  … #{problem_rows.size - 50} weitere" if problem_rows.size > 50
      exit 1
    else
      puts "\nAlle Werte sind automatisch normalisierbar."
    end
  end

  def birthdate_bucket_for(raw)
    str = raw.to_s.strip
    return :leer if str.empty?
    return :nulldatum if str.start_with?('0000')

    normalized = ChangePlayersBirthdateToDate.normalize(str)
    return :unlesbar if normalized == :invalid

    str.match?(ChangePlayersBirthdateToDate::ISO_FORMAT) ? :iso : :deutsch
  end
end
