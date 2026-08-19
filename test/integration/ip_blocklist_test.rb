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

  # Der Kern des Features, und die Stelle, an der die Testkonstruktion zaehlt.
  #
  # Rack::Request#ip nimmt aus REMOTE_ADDR die LETZTE nicht vertraute Adresse
  # (reverse_each); X-Forwarded-For wird nur gelesen, wenn REMOTE_ADDR
  # ausschliesslich vertraute Adressen enthaelt. Was vertraut ist, entscheidet
  # `Rack::Request.ip_filter` — voreingestellt Loopback, die privaten Netze und
  # Link-Local.
  #
  # In Produktion ist REMOTE_ADDR die Docker-Adresse von nginx, also vertraut,
  # und erst dann entscheidet die Kette. Ein Test mit oeffentlicher REMOTE_ADDR
  # wuerde den Header-Pfad also GAR NICHT ausfuehren und trotzdem gruen sein —
  # deshalb steht hier PROXY davor.
  PROXY = '172.18.0.5'.freeze

  # nginx haengt die echte Adresse per $proxy_add_x_forwarded_for HINTEN an eine
  # mitgeschickte Kette, und Rack nimmt daraus die letzte nicht vertraute
  # Adresse. Ein vom Client vorangestellter Wert verschiebt req.ip deshalb nicht.
  test 'ein vorangestellter X-Forwarded-For hebt den Bann nicht auf' do
    get '/api/v2/init',
        headers: { 'X-Api-Key' => @key, 'X-Forwarded-For' => "203.0.113.9, #{GEBANNT}" },
        env: { 'REMOTE_ADDR' => PROXY }

    assert_response :not_found
  end

  # Gegenrichtung, und der Test, der rot wird, falls die Auswahl je auf die
  # ERSTE Adresse der Kette kippt: Wer nicht gebannt ist, darf sich nicht durch
  # einen mitgeschickten Header eine Sperre einfangen.
  test 'ein fremder X-Forwarded-For bannt keine unbeteiligte IP' do
    get '/api/v2/init',
        headers: { 'X-Api-Key' => @key, 'X-Forwarded-For' => "#{GEBANNT}, 203.0.113.7" },
        env: { 'REMOTE_ADDR' => PROXY }

    assert_response :success
  end

  # Rack wertet seit 3.1 zuerst den RFC-7239-Header `Forwarded` aus; nginx setzt
  # ihn nicht und reicht einen mitgeschickten unveraendert durch. Ohne die
  # Zuweisung forwarded_priority am Kopf von rack_attack.rb bestimmte der Client
  # damit selbst, was req.ip liefert — und koennte den Bann abschuetteln.
  test 'ein mitgeschickter Forwarded-Header hebt den Bann nicht auf' do
    get '/api/v2/init',
        headers: { 'X-Api-Key' => @key,
                   'Forwarded' => 'for=203.0.113.9',
                   'X-Forwarded-For' => GEBANNT },
        env: { 'REMOTE_ADDR' => PROXY }

    assert_response :not_found
  end

  # Die Sperre greift vor allem anderen, auch vor der Pflegemaske: Wer eine
  # oeffentliche Adresse sperrt, hinter der er selbst sitzt, kommt nicht mehr an
  # die Maske und muss ueber die Konsole heraus. UNBLOCKABLE hilft dagegen NICHT
  # (es deckt nur private Netze, und die kann req.ip hinter nginx nie sein) —
  # deshalb steht dieser Fall hier ausfuehrbar, statt als beruhigende Annahme.
  test 'die Sperre trifft auch die Pflegemaske selbst' do
    admin = create(:user, :admin)
    post '/api/v2/login', params: { username: admin.user_name, password: 'password123' }
    assert_response :success

    get '/api/v2/admin/blocked_ips', env: { 'REMOTE_ADDR' => GEBANNT }
    assert_response :not_found
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

  # IPv6 kommt in mehreren Schreibweisen vor. Eingetragen wird hier die Langform,
  # req.ip liefert die komprimierte — ohne normalize_ip im Modell griffe die
  # Sperre nie, und in der Tabelle sahen beide identisch aus.
  test 'eine IPv6-Adresse greift auch in anderer Schreibweise' do
    BlockedIp.create!(ip: '2001:0DB8:0000:0000:0000:0000:0000:0001', reason: 'Test')

    get '/api/v2/init', headers: { 'X-Api-Key' => @key }, env: { 'REMOTE_ADDR' => '2001:db8::1' }
    assert_response :not_found
  end

  test 'ohne Bann fuehrt derselbe Pfad zum Routing-Fehler' do
    assert_raises(ActionController::RoutingError) do
      get '/api/v2/fvd/leagues.json', env: { 'REMOTE_ADDR' => '203.0.113.7' }
    end
  end
end
