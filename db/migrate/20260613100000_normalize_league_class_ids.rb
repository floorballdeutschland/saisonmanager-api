class NormalizeLeagueClassIds < ActiveRecord::Migration[7.0]
  # Issue #297: leagues.league_class_id enthielt drei Wertewelten (Legacy-Zahlen
  # wie "10".."520", die Settings-Map-Keys "1".."10" und die neuen Formular-Codes).
  # Diese Migration vereinheitlicht alle Saisons auf die fünf Codes des
  # Liga-Formulars (1fbl/2fbl/rl/vl/ll); Wettbewerbe ohne Ligaklasse
  # (DM, Pokal, Trophy, Sonderrunden ohne klare Zuordnung) werden ''.
  # NULL bleibt NULL. Die Lizenz-Kopien in players.licenses[].league_class_id
  # folgen der Liga ihres Teams; Lizenzen ohne auflösbares Team/Liga fallen auf
  # das Wert-Mapping zurück. Zum Schluss wird die league_classes-Settings-Map
  # auf die Codes umgeschlüsselt.

  CODES = %w[1fbl 2fbl rl vl ll].freeze

  # Eindeutige Namensmuster gewinnen vor dem Wert-Mapping, weil einzelne
  # Legacy-Werte gemischt belegt sind: "280" steht z.B. für U15-Regionalligen
  # (Wert-Mapping => rl) UND U15-Deutsche-Meisterschaften (DM-Muster => '').
  # Der Lookbehind im DM-Muster nimmt Süd-/Nord-/...deutsche Meisterschaften
  # aus — das sind überregionale Runden, keine nationale Endrunde (die aktuelle
  # Saison führt die Süddeutsche Meisterschaft als rl).
  NAME_PATTERNS = [
    [/(?<![a-zäöü])deutsche meisterschaft/i, ''],
    [/1\.\s*(floorball[\s-]*)?(bundesliga|fbl)/i, '1fbl'],
    [/2\.\s*(floorball[\s-]*)?(bundesliga|fbl)/i, '2fbl'],
    [/regionalliga/i, 'rl'],
    [/verbandsliga/i, 'vl'],
    [/landesliga/i, 'll']
  ].freeze

  # Wert-Mapping als Fallback, abgeleitet aus den dominanten Liganamen je
  # Legacy-Wert (Prod-Analyse 2026-06-10, Saisons 6-17). Nicht gelistete Werte
  # ("0", "25", "200", "260", "370", "500", "505", "520") sind — soweit nicht
  # schon von den Namensmustern erfasst — DM-/Pokal-/Trophy-/Sonderwettbewerbe
  # ohne Ligaklassen-Rang => ''. Jeder ''-Fallback wird unten protokolliert
  # (Deploy-Log), da die Originalwerte nicht wiederherstellbar sind.
  VALUE_MAP = {
    '1' => '1fbl', '10' => '1fbl',
    '20' => '2fbl',
    '30' => 'rl', '240' => 'rl', '250' => 'rl', '270' => 'rl', '280' => 'rl',
    '290' => 'rl', '300' => 'rl', '310' => 'rl', '320' => 'rl', '340' => 'rl',
    '40' => 'vl', '330' => 'vl',
    '50' => 'll'
  }.freeze

  NEW_SETTINGS_MAP = {
    '1fbl' => { 'name' => '1. Floorball Bundesliga' },
    '2fbl' => { 'name' => '2. Floorball Bundesliga' },
    'rl' => { 'name' => 'Regionalliga' },
    'vl' => { 'name' => 'Verbandsliga' },
    'll' => { 'name' => 'Landesliga' }
  }.freeze

  def up
    say_with_time 'Ligen normalisieren' do
      blanked = Hash.new { |h, k| h[k] = [] }

      League.unscoped.find_each do |league|
        new_code = self.class.normalize(league.league_class_id, league.name)
        next if new_code == league.league_class_id.to_s

        blanked[league.league_class_id] << "#{league.id} (S#{league.season_id}) #{league.name}" if new_code == ''
        league.update_columns(league_class_id: new_code)
      end

      blanked.sort.each do |old, leagues|
        say "'#{old}' -> '' (#{leagues.size} Ligen): #{leagues.first(5).join(' | ')}", true
      end
    end

    say_with_time 'Lizenz-Kopien in players.licenses normalisieren' do
      class_by_league = League.unscoped.pluck(:id, :league_class_id).to_h
      class_by_team = Team.pluck(:id, :league_id).to_h { |tid, lid| [tid, class_by_league[lid]] }
      orphans = Hash.new(0)

      Player.find_each do |player|
        next if player.licenses.blank?

        changed = false
        licenses = player.licenses.map do |license|
          old = license['league_class_id'].to_s
          next license if old.blank? || CODES.include?(old)

          new_code = class_by_team[license['team_id'].to_i]
          if new_code.nil?
            new_code = self.class.normalize(old, nil)
            orphans[old] += 1
          end
          changed = true
          license.merge('league_class_id' => new_code)
        end

        player.update_columns(licenses:) if changed
      end

      orphans.sort.each do |old, count|
        say "#{count} Lizenz(en) ohne auflösbares Team/Liga: '#{old}' per Wert-Mapping -> '#{self.class.normalize(old, nil)}'", true
      end
    end

    if (setting = Setting.first)
      setting.update_columns(league_classes: NEW_SETTINGS_MAP)
    else
      say 'WARNUNG: Keine Settings-Zeile vorhanden — league_classes-Map nicht umgeschlüsselt'
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  def self.normalize(value, name)
    v = value.to_s.strip
    return v if v.blank? || CODES.include?(v)

    NAME_PATTERNS.each { |pattern, code| return code if name.to_s.match?(pattern) }
    VALUE_MAP.fetch(v, '')
  end
end
