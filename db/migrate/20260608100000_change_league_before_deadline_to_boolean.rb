class ChangeLeagueBeforeDeadlineToBoolean < ActiveRecord::Migration[7.0]
  # before_deadline wurde fälschlich als date-Spalte geführt, faktisch aber als
  # Ja/Nein-Flag genutzt ("geboren bis" vs "geboren ab"). Da das Frontend
  # Boolean-Strings sendet, konnten in der date-Spalte ohnehin keine sinnvollen
  # Werte gespeichert werden – bestehende Werte werden daher verworfen (NULL).
  def up
    execute <<~SQL.squish
      ALTER TABLE leagues
        ALTER COLUMN before_deadline DROP DEFAULT,
        ALTER COLUMN before_deadline TYPE boolean USING NULL::boolean,
        ALTER COLUMN before_deadline SET DEFAULT false
    SQL
  end

  def down
    execute <<~SQL.squish
      ALTER TABLE leagues
        ALTER COLUMN before_deadline DROP DEFAULT,
        ALTER COLUMN before_deadline TYPE date USING NULL::date
    SQL
  end
end
