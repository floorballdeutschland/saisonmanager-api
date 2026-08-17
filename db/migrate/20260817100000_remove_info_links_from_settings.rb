class RemoveInfoLinksFromSettings < ActiveRecord::Migration[7.1]
  # Gegenstück zu 20260813120000: Der Mechanismus für redaktionell pflegbare
  # Links auf Informationsblätter wird wieder ausgebaut (#456). Es gab genau
  # einen Key (`minor_privacy_bundesliga`) mit genau einer globalen Adresse, und
  # die zeigte auf ein Bundesliga-PDF. Für eine Regionalliga, die die
  # Elternzustimmung ebenfalls verlangt, passt dieses Blatt inhaltlich nicht –
  # pro Liga pflegbar zu machen war der Aufwand nicht wert, also verweist die
  # Art.-13-Mail ab jetzt durchgehend auf den Verein.
  #
  # Die einführende Migration bleibt stehen, sie ist auf Produktion gelaufen.
  #
  # Die Adresse steht im `down` fest im Code, nicht aus der Spalte gelesen: Ein
  # `up` verwirft sie, ein Rollback muss ohne diesen Wert auskommen. Der Text ist
  # derselbe wie in der einführenden Migration; die Konstante dort ist nach dem
  # `up` nicht mehr erreichbar, weil die Spalte fehlt.
  MINOR_PRIVACY_URL =
    'https://floorball.de/wp-content/uploads/2026/06/' \
    '2026-07-01-Info-zur-Datenverarbeitung-minderjaehriger-Bundesligaspieler.pdf'.freeze

  def up
    # Den ausgehenden Wert ins Deploy-Log schreiben, bevor er weg ist. Genau
    # dafür gab es den Mechanismus: floorball.de verschiebt die PDFs, die Adresse
    # kann also seit dem 13.08. von Hand korrigiert worden sein. Ohne diese Zeile
    # wäre eine solche Korrektur nach dem Deploy nirgends mehr nachweisbar, denn
    # `down` unten kennt nur den Ausgangswert.
    say "info_links vor dem Entfernen: #{Setting.first&.attributes&.dig('info_links').inspect}"

    remove_column :settings, :info_links
    Setting.reset_column_information
    flush_setting_caches
  end

  # Rekonstruktion, keine Wiederherstellung: Der gelöschte Inhalt ist nicht mehr
  # lesbar, deshalb wird der Ausgangswert vom 13.08. gesetzt. War die Adresse
  # zwischenzeitlich korrigiert, steht hier die veraltete; war sie bewusst geleert
  # (der alte Controller löschte den Key bei leerer Eingabe), legt der Rollback
  # einen Link an, wo keiner sein sollte.
  #
  # Deshalb nur setzen, wenn nichts drinsteht, statt bedingungslos zu schreiben:
  # Wer nach dem Rollback selbst eine Adresse pflegt, soll sie beim nächsten
  # `down` nicht wieder überschrieben bekommen.
  #
  # Ein Rollback allein genügt ohnehin nicht: Die Leser (`Setting.info_link_url`
  # und Verbraucher) sind mit diesem PR entfernt, die Spalte wäre also wieder da
  # und unbenutzt. Ein Rollback braucht den Code-Stand dazu.
  def down
    add_column :settings, :info_links, :jsonb, default: {}, null: false
    Setting.reset_column_information

    setting = Setting.first
    return if setting.nil? || setting.attributes['info_links'].presence

    setting.update_columns(
      info_links: { 'minor_privacy_bundesliga' => { 'url' => MINOR_PRIVACY_URL } },
      updated_at: Time.current
    )
    flush_setting_caches
  end

  private

  # Siehe 20260813120000 für die Einordnung: Produktion nutzt `:memory_store` und
  # migriert in einem Wegwerf-Container, der Aufruf trifft dort den eigenen,
  # leeren Store. Sauber ist der Deploy trotzdem, weil deploy.sh den
  # rails-api-Container danach neu erzeugt. Ohne Container-Neustart muss der
  # Cache selbst verworfen werden – `settings/current` enthält sonst weiter eine
  # Setting-Instanz mit dem entfernten Attribut.
  def flush_setting_caches
    Rails.cache.delete('settings/current')
    Rails.cache.delete('settings/init')
  end
end
