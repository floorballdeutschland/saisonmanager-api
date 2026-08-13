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
    flush_setting_caches
  end

  def down
    remove_column :settings, :info_links
    Setting.reset_column_information
    flush_setting_caches
  end

  private

  # Wirkt nur dort, wo der Cache prozessübergreifend liegt. Produktion nutzt
  # `:memory_store` und migriert in einem Wegwerf-Container
  # (`docker compose run --rm`); das Löschen trifft dort den eigenen, leeren
  # Store und nicht den des laufenden Servers. Sauber ist der Deploy trotzdem,
  # weil deploy.sh den rails-api-Container danach neu erzeugt und der Cache
  # damit ohnehin leer startet. Wer diese Migration ohne Container-Neustart
  # einspielt, muss den Cache selbst verwerfen.
  def flush_setting_caches
    Rails.cache.delete('settings/current')
    Rails.cache.delete('settings/init')
  end
end
