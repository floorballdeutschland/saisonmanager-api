require 'test_helper'

# Zugriff auf ein Spielerprofil nur über eine gültige Vereinszugehörigkeit (#309).
#
# `PlayersController#vm_can_access_player?` / `#tm_can_access_player?` lasen den
# rohen clubs-Hash ohne `valid_until`. Wer je Mitglied eines Vereins war, blieb
# für diesen Verein dauerhaft erreichbar, also auch `deactivate!`-bar. Am
# 16.07.2026 haben drei VM-Konten so 68 Spieler deaktiviert, deren offene
# Heimatzugehörigkeit einem anderen Verein gehörte; deren laufende Lizenzen
# standen danach auf DELETED, und weil `Club#players` über `Player.active`
# filtert, fielen die Profile aus der Vereinsspielerliste des echten Vereins.
#
# Eigene Datei, weil `players_controller_test.rb` sonst über Metrics/ClassLength
# läuft.
class PlayersMembershipAccessTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @game_operation = create(:game_operation)
    @club = create(:club)
    @league = create(:league, :current_season, game_operation: @game_operation)
    @team = create(:team, league: @league, club: @club)
    @player = create(:player, clubs: [{ 'club_id' => @club.id, 'home_club' => true,
                                        'created_at' => 1.day.ago.iso8601 }])
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  # Ein Profil, das @club vor zwei Jahren verlassen hat und heute bei einem
  # anderen Verein beheimatet ist. Mit laufender Lizenz, damit sichtbar wird,
  # ob eine abgewiesene Deaktivierung trotzdem Schaden angerichtet hat:
  # `deactivate!` setzt APPROVED und REQUESTED auf DELETED.
  def ausgetretener_spieler
    create(:player,
           clubs: [
             { 'club_id' => @club.id, 'home_club' => true,
               'created_at' => 3.years.ago.iso8601, 'valid_until' => 2.years.ago.iso8601 },
             { 'club_id' => create(:club).id, 'home_club' => true,
               'created_at' => 2.years.ago.iso8601 }
           ],
           with_licenses: [{ team: @team, status: License::APPROVED }])
  end

  # Ein gemeinsamer Zeitpunkt für `valid_until` und `deactivated_at`, auf die
  # Sekunde gerundet: `iso8601` schneidet die Mikrosekunden ab, und
  # Player::DEACTIVATION_CLOSE_WINDOW ist nur eine Sekunde breit. Zwei getrennte
  # `7.days.ago`-Aufrufe fielen sonst gelegentlich auseinander. Übernommen aus
  # players_controller_test.rb, wo der SBK-Zwilling dieser Tests steht.
  def deaktiviert_am
    @deaktiviert_am ||= 7.days.ago.change(usec: 0)
  end

  # Ein vor einer Woche deaktiviertes Profil des eigenen Vereins, so wie es nach
  # `deactivate!` in der Datenbank liegt.
  #
  # Der Zeitpunkt ist entscheidend: `deactivate!` stempelt `valid_until` auf
  # JETZT, und `membership_current?` lässt einen heute endenden Eintrag noch
  # gelten. Am Tag der Deaktivierung trägt deshalb bereits Zweig (a), der
  # Deaktivierungs-Zweig (b) wird gar nicht befragt. Erst ab dem Folgetag prüfen
  # diese Tests, was sie prüfen sollen.
  def vor_einer_woche_deaktiviert(by:)
    create(:player,
           clubs: [{ 'club_id' => @club.id, 'home_club' => true,
                     'created_at' => 2.years.ago.iso8601,
                     'valid_until' => deaktiviert_am.iso8601,
                     'valid_set_by' => by.id }],
           deactivated_at: deaktiviert_am, deactivated_by: by.id,
           deactivation_reason: 'Temporäre Pause')
  end

  test 'VM des Altvereins kann einen ausgetretenen Spieler nicht mehr deaktivieren' do
    weg = ausgetretener_spieler
    login_as(create(:user, :vm, club_id: @club.id))

    post "/api/v2/admin/players/#{weg.id}/deactivate", params: { reason: 'Vereinsaustritt' }

    assert_response :forbidden
    assert_nil weg.reload.deactivated_at
    # Der eigentliche Schaden aus #309: deactivate! setzt die laufenden Lizenzen
    # auf DELETED. Die Absage muss VOR der Mutation stehen.
    geloescht = weg.licenses.select { |l| l['history']&.last&.dig('license_status_id') == License::DELETED }
    assert_empty geloescht
    assert_equal License::APPROVED, weg.licenses.first['history'].last['license_status_id']
  end

  test 'VM des Altvereins sieht das Profil und die E-Mail nicht mehr' do
    weg = ausgetretener_spieler
    login_as(create(:user, :vm, club_id: @club.id))

    get "/api/v2/admin/players/#{weg.id}.json"
    assert_response :forbidden

    patch "/api/v2/admin/vm/players/#{weg.id}/email", params: { email: 'neu@example.org' }
    assert_response :forbidden
    assert_not_equal 'neu@example.org', weg.reload.email
  end

  test 'TM des Altvereins kommt ueber sein Team nicht mehr an das Profil' do
    weg = ausgetretener_spieler
    login_as(create(:user, :tm, team_id: @team.id))

    get "/api/v2/admin/players/#{weg.id}.json"
    assert_response :forbidden

    get "/api/v2/admin/players/#{@player.id}.json"
    assert_response :success, 'der eigene, aktuelle Spieler muss erreichbar bleiben'
  end

  # Gegenprobe: Die Regel darf den laufenden Betrieb nicht treffen.
  test 'VM des aktuellen Vereins deaktiviert weiterhin' do
    login_as(create(:user, :vm, club_id: @club.id))

    post "/api/v2/admin/players/#{@player.id}/deactivate", params: { reason: 'Karriereende' }

    assert_response :success
    assert @player.reload.deactivated_at.present?
  end

  # Die Zugehörigkeit, die `deactivate!` selbst geschlossen hat, muss weiter
  # zählen: sonst verlöre der Verein den Zugriff auf sein eigenes Profil und käme
  # nicht mehr an `reactivate`. Eine Woche nach der Deaktivierung, sonst trägt
  # noch Zweig (a) und der Test prüfte den Zweig gar nicht (siehe Hilfsmethode).
  test 'VM liest und reaktiviert sein vor Tagen deaktiviertes Profil' do
    vm = create(:user, :vm, club_id: @club.id)
    deaktiviert = vor_einer_woche_deaktiviert(by: vm)
    login_as(vm)

    get "/api/v2/admin/players/#{deaktiviert.id}.json"
    assert_response :success, 'das eigene deaktivierte Profil muss lesbar bleiben'

    post "/api/v2/admin/players/#{deaktiviert.id}/reactivate"
    assert_response :success
    assert_nil deaktiviert.reload.deactivated_at
  end

  # Auch wenn eine andere Stelle deaktiviert hat: Der Stempel trägt deren id,
  # geschlossen wurde trotzdem die gültige Mitgliedschaft dieses Vereins.
  test 'VM nimmt eine Deaktivierung der SBK zurueck' do
    sbk = create(:user, :sbk_scoped, game_operation_id: @game_operation.id)
    deaktiviert = vor_einer_woche_deaktiviert(by: sbk)
    login_as(create(:user, :vm, club_id: @club.id))

    post "/api/v2/admin/players/#{deaktiviert.id}/reactivate"

    assert_response :success
    assert_nil deaktiviert.reload.deactivated_at
  end

  # Gegenprobe zum Zeitfenster: Der Stempel allein genügt nicht. Deaktiviert
  # dieselbe Person Jahre später ein Profil, zählte eine längst abgelaufene
  # Zugehörigkeit sonst als "durch die Deaktivierung geschlossen", und der
  # Altverein bekäme das Profil samt unbefristeter Mitgliedschaft zurück.
  test 'passender Stempel ausserhalb des Zeitfensters gibt keinen Zugriff' do
    vm = create(:user, :vm, club_id: @club.id)
    alt = create(:player,
                 clubs: [{ 'club_id' => @club.id, 'home_club' => true,
                           'created_at' => 5.years.ago.iso8601,
                           'valid_until' => 3.years.ago.iso8601,
                           'valid_set_by' => vm.id }],
                 deactivated_at: deaktiviert_am, deactivated_by: vm.id)
    login_as(vm)

    get "/api/v2/admin/players/#{alt.id}.json"

    assert_response :forbidden
  end

  # Der Riegel gilt auch für die Rücknahme: Eine vor zwei Jahren beendete
  # Mitgliedschaft erfüllt `membership_closed_by_deactivation?` nicht (weder
  # Stempel noch Zeitfenster), der Altverein kann ein fremdes Profil also nicht
  # über den Umweg der Reaktivierung einsammeln.
  test 'VM des Altvereins reaktiviert ein fremdes Profil nicht' do
    weg = ausgetretener_spieler
    weg.deactivate!(create(:user, :admin).id, reason: 'Karriereende')
    login_as(create(:user, :vm, club_id: @club.id))

    post "/api/v2/admin/players/#{weg.id}/reactivate"

    assert_response :forbidden
    assert weg.reload.deactivated_at.present?
  end

  # --- Zweitspielrecht: mehrere gleichzeitig gültige Vereine ------------------
  #
  # Der häufigste Fall im Bestand und die Hauptzusage der Änderung („am
  # laufenden Betrieb ändert sich nichts").

  test 'Verein des laufenden Zweitspielrechts kommt an das Profil' do
    gast = create(:club)
    spieler = create(:player, clubs: [
      { 'club_id' => @club.id, 'home_club' => true, 'created_at' => 2.years.ago.iso8601 },
      { 'club_id' => gast.id, 'home_club' => false,
        'created_at' => 1.month.ago.iso8601, 'valid_until' => 3.months.from_now.iso8601 }
    ])
    login_as(create(:user, :vm, club_id: gast.id))

    get "/api/v2/admin/players/#{spieler.id}.json"

    assert_response :success
  end

  test 'abgelaufenes Zweitspielrecht gibt keinen Zugriff mehr' do
    gast = create(:club)
    spieler = create(:player, clubs: [
      { 'club_id' => @club.id, 'home_club' => true, 'created_at' => 2.years.ago.iso8601 },
      { 'club_id' => gast.id, 'home_club' => false,
        'created_at' => 2.years.ago.iso8601, 'valid_until' => 1.year.ago.iso8601 }
    ])
    login_as(create(:user, :vm, club_id: gast.id))

    get "/api/v2/admin/players/#{spieler.id}.json"

    assert_response :forbidden
  end

  # Spielgemeinschaft: `tm_club_ids` löst über `Team#all_club_ids` die
  # Partnervereine mit auf. Der Spieler gehört dem Partnerverein, das Team dem
  # anderen.
  test 'TM einer Spielgemeinschaft erreicht den Spieler des Partnervereins' do
    partner = create(:club)
    sg_team = create(:team, league: @league, club: @club, syndicate: true, syndicate_clubs: [partner.id])
    spieler = create(:player, clubs: [{ 'club_id' => partner.id, 'home_club' => true,
                                        'created_at' => 1.year.ago.iso8601 }])
    ausgetreten = create(:player, clubs: [{ 'club_id' => partner.id, 'home_club' => true,
                                           'created_at' => 3.years.ago.iso8601,
                                           'valid_until' => 2.years.ago.iso8601 }])
    login_as(create(:user, :tm, team_id: sg_team.id))

    get "/api/v2/admin/players/#{spieler.id}.json"
    assert_response :success

    get "/api/v2/admin/players/#{ausgetreten.id}.json"
    assert_response :forbidden
  end

  # --- Datenfehler bleiben Datenfehler ----------------------------------------
  #
  # Der VM/TM-Zweig hat vor dieser Änderung überhaupt kein Datum gelesen. Ohne
  # `membership_current?` würde ein unlesbares valid_until aus dem Altbestand
  # („unbekannt", „0000-00-00") jetzt in `Date.parse` fliegen und aus der
  # Rechteentscheidung einen 500er machen. Vorbild und Gegenstück:
  # players_controller_test.rb, 'Unlesbares valid_until zaehlt nicht als
  # Mitgliedschaft und wird gemeldet'.
  test 'unlesbares valid_until ergibt eine Absage und wird gemeldet, keinen Serverfehler' do
    kaputt = create(:player, clubs: [{ 'club_id' => @club.id, 'home_club' => true,
                                       'valid_until' => '0000-00-00' }])
    login_as(create(:user, :vm, club_id: @club.id))

    logged = []
    Rails.logger.stub(:error, ->(msg) { logged << msg }) do
      get "/api/v2/admin/players/#{kaputt.id}.json"
    end

    assert_response :forbidden
    assert(logged.any? { |m| m.to_s.include?('valid_until') }, "Datenfehler wurde nicht gemeldet: #{logged.inspect}")
  end

  # Ein einzelner kaputter Alteintrag darf die Prüfung nicht kippen: Die gültige
  # Zugehörigkeit desselben Vereins entscheidet.
  test 'ein kaputter Alteintrag nimmt der gueltigen Zugehoerigkeit nichts' do
    spieler = create(:player, clubs: [
      { 'club_id' => create(:club).id, 'valid_until' => 'unbekannt' },
      { 'club_id' => @club.id, 'home_club' => true, 'created_at' => 1.year.ago.iso8601 }
    ])
    login_as(create(:user, :vm, club_id: @club.id))

    get "/api/v2/admin/players/#{spieler.id}.json"

    assert_response :success
  end

  # Die Kette aus dem Vorfall, über beide Endpunkte: Was in der Vereinsliste
  # steht, muss sich auch öffnen lassen. `Club#players(include_deactivated: true)`
  # und `membership_grants_access?` sind zwei getrennt gepflegte Methoden, die
  # Invariante hält nur, solange beide dieselben zwei Fälle kennen.
  test 'jeder Eintrag der VM-Spielerliste laesst sich auch oeffnen' do
    vm = create(:user, :vm, club_id: @club.id)
    vor_einer_woche_deaktiviert(by: vm)
    create(:player, clubs: [{ 'club_id' => @club.id, 'home_club' => true,
                              'created_at' => 1.year.ago.iso8601 }])
    login_as(vm)

    get '/api/v2/admin/vm/players.json', params: { club_id: @club.id }
    assert_response :success
    ids = JSON.parse(response.body).map { |p| p['id'] }
    assert_operator ids.size, :>=, 3, 'Liste sollte den aktiven, den deaktivierten und @player enthalten'

    ids.each do |id|
      get "/api/v2/admin/players/#{id}.json"
      assert_response :success, "Spieler #{id} steht in der Liste, ist aber nicht zu öffnen"
    end
  end
end
