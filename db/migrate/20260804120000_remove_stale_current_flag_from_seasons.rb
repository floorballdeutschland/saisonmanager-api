class RemoveStaleCurrentFlagFromSeasons < ActiveRecord::Migration[7.1]
  # Setting.seasons trug bei alten Saisons noch ein gespeichertes
  # `current: true`. Maßgeblich ist längst systems['1']['current_season_id']
  # (Setting.current_season_id); geschrieben wird das Flag von nirgends mehr,
  # create_season legt es gar nicht erst an. Auf Produktion stand es zuletzt auf
  # Saison 17, während die aktive Saison 18 war — eine stille Falle für jede
  # Auswertung, die es liest.
  #
  # Idempotent und ohne Down-Migration-Bedarf: Das Flag ist reine Altlast, es
  # wieder einzufügen hätte keinen Empfänger.
  def up
    setting = Setting.first
    return if setting.nil?

    seasons = setting.seasons
    return if seasons.blank?

    cleaned = seasons.transform_values do |season|
      season.is_a?(Hash) ? season.except('current') : season
    end

    return if cleaned == seasons

    setting.update_columns(seasons: cleaned, updated_at: Time.current)
    Rails.cache.delete('settings/init')
  end

  def down
    # Bewusst leer: Das Flag ist Altlast, ein Rückbau hätte keinen Nutzen.
  end
end
