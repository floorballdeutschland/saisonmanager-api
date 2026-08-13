class AddInfoLinksToSettings < ActiveRecord::Migration[7.1]
  # Links auf externe Informationsblätter (floorball.de) standen bisher fest im
  # Frontend-Template. Der Link auf das Datenschutz-Informationsblatt für
  # minderjährige Bundesligaspieler*innen war dadurch monatelang tot, weil
  # floorball.de das PDF verschoben hat. Ab hier redaktionell pflegbar unter
  # /verwaltung/dokumentarten.
  MINOR_PRIVACY_URL =
    'https://floorball.de/wp-content/uploads/2026/06/' \
    '2026-07-01-Info-zur-Datenverarbeitung-minderjaehriger-Bundesligaspieler.pdf'.freeze

  def up
    add_column :settings, :info_links, :jsonb, default: {}, null: false
    Setting.reset_column_information

    setting = Setting.first
    return if setting.nil?

    setting.update_columns(
      info_links: { 'minor_privacy_bundesliga' => { 'url' => MINOR_PRIVACY_URL } },
      updated_at: Time.current
    )
    Rails.cache.delete('settings/current')
    Rails.cache.delete('settings/init')
  end

  def down
    remove_column :settings, :info_links
    Setting.reset_column_information
    Rails.cache.delete('settings/current')
    Rails.cache.delete('settings/init')
  end
end
