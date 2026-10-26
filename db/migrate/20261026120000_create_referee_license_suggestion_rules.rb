# Regeln für den Lizenzvorschlag bei Kursen im System (api#861). Je Kurstyp
# eine geordnete Liste: Die erste Regel, deren Stufe der Kurs vergibt und deren
# Mindestzahl an Spielen erreicht ist, wird vorgeschlagen. Pflege nur durch
# Admin, bundesweit gleich.
#
# Vorbelegt mit den Regeln, nach denen FD bisher von Hand entscheidet:
# J-Kurs → J1 bzw. J2 (je nachdem, welche Stufe der Kurs vergibt), G-Kurs → L3,
# F-Kurs → L1 ab vier Spielen Großfeld ab U15 in der maßgeblichen Saison, sonst
# L2. N1 und N2 bleiben ohne Regel. Fehlt eine Stufe im Katalog, entfällt die
# Regel still; sie lässt sich danach in der Maske anlegen.
class CreateRefereeLicenseSuggestionRules < ActiveRecord::Migration[7.2]
  DEFAULT_RULES = [
    ['j', 'J1', nil, 'all', false],
    ['j', 'J2', nil, 'all', false],
    ['g', 'L3', nil, 'all', false],
    ['f', 'L1', 4, 'GF', true],
    ['f', 'L2', nil, 'all', false]
  ].freeze

  def up
    create_table :referee_license_suggestion_rules do |t|
      t.string :course_type, null: false
      t.references :referee_license_level, null: false, foreign_key: true
      t.integer :position, null: false, default: 0
      t.integer :min_games, comment: 'NULL: ohne Bedingung'
      t.string :field_size, null: false, default: 'all', comment: 'all | KF | GF'
      t.string :age_groups, array: true, null: false, default: [],
                            comment: 'Gezählte Altersklassen (leagues.age_group). Leer: alle.'
      t.timestamps
    end
    add_index :referee_license_suggestion_rules, %i[course_type position]

    seed_defaults
  end

  def down
    drop_table :referee_license_suggestion_rules
  end

  private

  def seed_defaults
    levels = select_rows('SELECT name, id FROM referee_license_levels').to_h
    older = select_values('SELECT DISTINCT age_group FROM leagues WHERE age_group IS NOT NULL') - ['']
    older = older.reject { |ag| ag[/\AU(\d+)/, 1].to_i.between?(1, 14) }.sort

    DEFAULT_RULES.each_with_index do |(course_type, level, min_games, field_size, u15_plus), position|
      next unless levels[level]

      ages = u15_plus ? older : []
      execute <<~SQL.squish
        INSERT INTO referee_license_suggestion_rules
          (course_type, referee_license_level_id, position, min_games, field_size, age_groups, created_at, updated_at)
        VALUES (#{quote(course_type)}, #{levels[level]}, #{position}, #{min_games || 'NULL'},
                #{quote(field_size)}, ARRAY[#{ages.map { |a| quote(a) }.join(',')}]::varchar[], NOW(), NOW())
      SQL
    end
  end
end
