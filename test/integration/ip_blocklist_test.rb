require 'test_helper'

# Dauerhaft abgewiesene IPs (Rack::Attack.blocklist). Anlass war eine Adresse,
# die im 42-Sekunden-Takt vier Pfade abfragte und auf alle nur 401 oder 404
# bekam — kein Angriff, aber rund 6500 FATAL-Zeilen Log am Tag, die echte
# Fehler verdecken.
#
# Wichtiger als der Bann selbst ist hier, dass er nicht per Header umgangen
# werden kann: Wuerde `req.ip` dem Client folgen, waere jede IP-Regel in dieser
# Datei wirkungslos — auch die Drosselungen gegen Mail-Fluten.
class IpBlocklistTest < ActionDispatch::IntegrationTest
  GEBANNT = '198.51.100.5'.freeze

  setup do
    create(:setting)
    @key, = ApiKey.generate(name: 'Test')
    BlockedIp.create!(ip: GEBANNT, reason: 'Test')
  end

  test 'eine gebannte IP bekommt 404, auch mit gueltigem API-Key' do
    get '/api/v2/init', headers: { 'X-Api-Key' => @key }, env: { 'REMOTE_ADDR' => GEBANNT }

    assert_response :not_found
  end

  test 'eine andere IP kommt mit gueltigem Key weiterhin durch' do
    get '/api/v2/init', headers: { 'X-Api-Key' => @key }, env: { 'REMOTE_ADDR' => '203.0.113.7' }

    assert_response :success
  end

  # Der Kern: nginx haengt die echte Adresse per $proxy_add_x_forwarded_for
  # HINTEN an eine mitgeschickte Kette, und Rack nimmt die letzte nicht
  # vertraute Adresse. Ein vorangestellter X-Forwarded-For verschiebt req.ip
  # deshalb nicht.
  test 'ein vorangestellter X-Forwarded-For hebt den Bann nicht auf' do
    get '/api/v2/init',
        headers: { 'X-Api-Key' => @key, 'X-Forwarded-For' => "203.0.113.9, #{GEBANNT}" },
        env: { 'REMOTE_ADDR' => GEBANNT }

    assert_response :not_found
  end

  # Gegenrichtung: Wer nicht gebannt ist, darf sich nicht durch einen
  # mitgeschickten Header eine Sperre einfangen.
  test 'ein fremder X-Forwarded-For bannt keine unbeteiligte IP' do
    get '/api/v2/init',
        headers: { 'X-Api-Key' => @key, 'X-Forwarded-For' => "#{GEBANNT}, 203.0.113.7" },
        env: { 'REMOTE_ADDR' => '203.0.113.7' }

    assert_response :success
  end

  # Der Bann greift vor dem Router, also auch fuer Pfade, die es nicht gibt.
  # Genau das war der Anlass: Der Routing-Fehler soll nicht mehr entstehen.
  test 'der Bann greift auch auf unbekannte Pfade, ohne Routing-Fehler' do
    get '/api/v2/fvd/leagues.json', env: { 'REMOTE_ADDR' => GEBANNT }

    assert_response :not_found
    assert_equal '{}', response.body, 'kein Rails-Fehlerrumpf, also kein RoutingError'
  end

  # Der Sinn der Verwaltungsmaske: Eine Freigabe muss ohne Deploy und ohne
  # Neustart wirken. Der Cache wird dafuer beim Loeschen verworfen (after_commit).
  test 'eine Freigabe wirkt sofort' do
    with_real_cache do
      get '/api/v2/init', headers: { 'X-Api-Key' => @key }, env: { 'REMOTE_ADDR' => GEBANNT }
      assert_response :not_found

      BlockedIp.find_by!(ip: GEBANNT).destroy!

      get '/api/v2/init', headers: { 'X-Api-Key' => @key }, env: { 'REMOTE_ADDR' => GEBANNT }
      assert_response :success, 'nach der Freigabe darf die Adresse nicht mehr haengen bleiben'
    end
  end

  # Gegenrichtung: Eine neu eingetragene Sperre greift ebenso ohne Neustart.
  test 'eine neue Sperre wirkt sofort' do
    with_real_cache do
      frisch = '198.51.100.99'
      get '/api/v2/init', headers: { 'X-Api-Key' => @key }, env: { 'REMOTE_ADDR' => frisch }
      assert_response :success

      BlockedIp.create!(ip: frisch, reason: 'Test')

      get '/api/v2/init', headers: { 'X-Api-Key' => @key }, env: { 'REMOTE_ADDR' => frisch }
      assert_response :not_found
    end
  end

  test 'ohne Bann fuehrt derselbe Pfad zum Routing-Fehler' do
    assert_raises(ActionController::RoutingError) do
      get '/api/v2/fvd/leagues.json', env: { 'REMOTE_ADDR' => '203.0.113.7' }
    end
  end
end
