require 'test_helper'

# Sperrliste, gepflegt vom Admin unter "System". Der wichtigste Teil ist nicht
# das Sperren, sondern der Riegel gegen das eigene Netz: Wer sich selbst
# aussperrt, kann die Sperre auch nicht mehr ueber die Maske loesen.
class BlockedIpTest < ActiveSupport::TestCase
  test 'eine oeffentliche Adresse laesst sich sperren' do
    blocked = BlockedIp.new(ip: '198.51.100.5', reason: 'Dauerhaft 401')
    assert blocked.valid?, blocked.errors.full_messages.join(' ')
  end

  test 'Grund ist Pflicht' do
    blocked = BlockedIp.new(ip: '198.51.100.5')
    assert_not blocked.valid?
    assert_includes blocked.errors.attribute_names, :reason
  end

  test 'unsinnige Eingaben werden abgewiesen' do
    ['keine-ip', '', '999.1.1.1', '1.2.3', 'example.com'].each do |wert|
      blocked = BlockedIp.new(ip: wert, reason: 'Test')
      assert_not blocked.valid?, "#{wert.inspect} haette abgelehnt werden muessen"
    end
  end

  # Der Riegel. Ohne ihn nimmt ein Tippfehler die eigene Seite vom Netz: Das
  # eigene nginx spricht Rails ueber das Docker-Netz an, liegt also in einem
  # privaten Bereich.
  test 'eigenes und privates Netz sind nicht sperrbar' do
    ['127.0.0.1', '::1', '10.0.5.7', '172.18.0.3', '192.168.1.1', '169.254.1.1',
     'fe80::1', 'fc00::1'].each do |wert|
      blocked = BlockedIp.new(ip: wert, reason: 'Test')
      assert_not blocked.valid?, "#{wert} haette geschuetzt sein muessen"
      assert_match(/privaten Netz/, blocked.errors.full_messages.join(' '))
    end
  end

  test 'dieselbe Adresse nur einmal' do
    BlockedIp.create!(ip: '198.51.100.5', reason: 'Test')
    assert_not BlockedIp.new(ip: '198.51.100.5', reason: 'Nochmal').valid?
  end

  test 'blocked? erkennt gesperrte und freie Adressen' do
    BlockedIp.create!(ip: '198.51.100.5', reason: 'Test')

    assert BlockedIp.blocked?('198.51.100.5')
    assert_not BlockedIp.blocked?('198.51.100.6')
    assert_not BlockedIp.blocked?(nil)
    assert_not BlockedIp.blocked?('')
  end

  # Ausgewertet wird bei JEDER Anfrage, deshalb der Cache — und deshalb muss die
  # Invalidierung sitzen. Ohne sie wirkte eine Freigabe bis zu zwei Minuten nicht.
  test 'Anlegen und Loeschen wirken sofort auf blocked?' do
    # Echter Store, sonst prueft der Test nichts: Der :null_store des Test-Env
    # fuehrt jeden fetch-Block neu aus, die Invalidierung waere unsichtbar.
    with_real_cache do
      assert_not BlockedIp.blocked?('198.51.100.5')

      blocked = BlockedIp.create!(ip: '198.51.100.5', reason: 'Test')
      assert BlockedIp.blocked?('198.51.100.5'), 'neue Sperre muss den Cache verwerfen'

      blocked.destroy!
      assert_not BlockedIp.blocked?('198.51.100.5'), 'Freigabe muss den Cache verwerfen'
    end
  end

  test 'die Liste wird tatsaechlich zwischengespeichert' do
    with_real_cache do
      BlockedIp.create!(ip: '198.51.100.5', reason: 'Test')
      BlockedIp.all_ips

      # Am Cache vorbei loeschen: Ohne Zwischenspeicher waere die Adresse sofort
      # frei, mit Zwischenspeicher bleibt sie es bis zur Invalidierung.
      BlockedIp.where(ip: '198.51.100.5').delete_all
      assert BlockedIp.blocked?('198.51.100.5'), 'die Liste kommt aus dem Cache'

      BlockedIp.clear_cache
      assert_not BlockedIp.blocked?('198.51.100.5')
    end
  end

  # Eine kaputte Sperrliste darf nicht den Betrieb abwuergen: Die Liste ist eine
  # Aufraeummassnahme, keine Sicherheitsschranke.
  test 'bei einem Datenbankfehler wird nicht gesperrt' do
    BlockedIp.stub(:all_ips, ->(*) { raise ActiveRecord::StatementInvalid, 'kaputt' }) do
      assert_not BlockedIp.blocked?('198.51.100.5')
    end
  end

  test 'Aenderungen sind nachvollziehbar' do
    blocked = BlockedIp.create!(ip: '198.51.100.5', reason: 'Test')
    assert_equal 1, blocked.versions.count, 'papertrail muss das Anlegen festhalten'
  end
end
