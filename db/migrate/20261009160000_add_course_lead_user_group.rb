# Name der neuen Benutzergruppe 8 „Kursleitung" in Setting#user_groups. Die
# Verwaltung zeigt Rollen ueber diese Namen an. Bestehende Eintraege bleiben
# unangetastet.
class AddCourseLeadUserGroup < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL.squish
      UPDATE settings
      SET user_groups = COALESCE(user_groups, '{}'::jsonb) || '{"8": {"name": "Kursleitung"}}'::jsonb
      WHERE NOT (COALESCE(user_groups, '{}'::jsonb) ? '8')
    SQL
    Setting.flush_current_cache if defined?(Setting)
  end

  def down
    execute "UPDATE settings SET user_groups = user_groups - '8'"
    Setting.flush_current_cache if defined?(Setting)
  end
end
