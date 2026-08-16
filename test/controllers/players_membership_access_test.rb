require 'test_helper'

# Zugriff auf ein Spielerprofil nur über eine gültige Vereinszugehörigkeit (#309).
#
# `PlayersController#vm_can_access_player?` / `#tm_can_access_player?` lasen den
# rohen clubs-Hash ohne `valid_until`. Wer je Mitglied eines Vereins war, blieb
# für diesen Verein dauerhaft erreichbar, also auch `deactivate!`-bar. Am
# 16.07.2026 haben drei VM-Konten so 68 Spieler deaktiviert, deren offene
# Heimatzugehörigkeit einem anderen Verein gehörte; deren Lizenzen standen danach
# auf DELETED und die Profile fehlten dem echten Verein in jeder Liste, weil
# `Player.active` Suche, `Club#players` und die VM-Spielerliste filtert.
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
  # anderen Verein beheimatet ist.
  def ausgetretener_spieler
    create(:player, clubs: [
      { 'club_id' => @club.id, 'home_club' => true,
        'created_at' => 3.years.ago.iso8601, 'valid_until' => 2.years.ago.iso8601 },
      { 'club_id' => create(:club).id, 'home_club' => true,
        'created_at' => 2.years.ago.iso8601 }
    ])
  end

  test 'VM des Altvereins kann einen ausgetretenen Spieler nicht mehr deaktivieren' do
    weg = ausgetretener_spieler
    login_as(create(:user, :vm, club_id: @club.id))

    post "/api/v2/admin/players/#{weg.id}/deactivate", params: { reason: 'Vereinsaustritt' }

    assert_response :forbidden
    assert_nil weg.reload.deactivated_at
    geloescht = weg.licenses.select { |l| l['history']&.last&.dig('license_status_id') == License::DELETED }
    assert_empty geloescht
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

  # Die Zugehörigkeit, die `deactivate!` gerade selbst geschlossen hat, muss
  # weiter zählen: sonst verlöre der Verein mit dem Klick auf "Deaktivieren" den
  # Zugriff auf sein eigenes Profil und käme nicht mehr an `reactivate`.
  test 'VM nimmt die eigene Deaktivierung zurueck' do
    login_as(create(:user, :vm, club_id: @club.id))

    post "/api/v2/admin/players/#{@player.id}/deactivate", params: { reason: 'Temporäre Pause' }
    assert_response :success

    get "/api/v2/admin/players/#{@player.id}.json"
    assert_response :success, 'das eigene deaktivierte Profil muss lesbar bleiben'

    post "/api/v2/admin/players/#{@player.id}/reactivate"
    assert_response :success
    assert_nil @player.reload.deactivated_at
  end

  # Auch wenn eine andere Stelle deaktiviert hat: Der Stempel trägt deren id,
  # geschlossen wurde trotzdem die gültige Mitgliedschaft dieses Vereins.
  test 'VM nimmt eine Deaktivierung der SBK zurueck' do
    sbk = create(:user, :sbk_scoped, game_operation_id: @game_operation.id)
    @player.deactivate!(sbk.id, reason: 'Vereinsaustritt')
    login_as(create(:user, :vm, club_id: @club.id))

    post "/api/v2/admin/players/#{@player.id}/reactivate"

    assert_response :success
    assert_nil @player.reload.deactivated_at
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
end
