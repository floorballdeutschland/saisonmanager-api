require 'test_helper'

# Freigabedatum in der Lizenzliste einer Liga (League#licenses).
#
# Fachlicher Hintergrund: Lizenzordnung und SPO setzen je eine Frist fuer die
# Freigabe und fuer die Beantragung. Vereine, Ausrichter und SBK sollen beides
# in der Lizenzliste ablesen koennen, statt es je Spieler nachzufragen. Die
# Fristen selbst stehen in der Ordnung und werden derzeit beraten -- der
# Saisonmanager prueft sie NICHT und markiert nichts. Hier stehen deshalb
# bewusst keine Fristdaten, sonst veraltet die Datei ohne ein einziges Assert.
#
# Die Negativfaelle pruefen jeweils gepaart: erst der Beinahe-Treffer (leer),
# dann dasselbe Objekt mit dem einen umgestellten Merkmal (Datum da). Ein
# blosses assert_nil waere auch ohne die Zuordnungslogik gruen.
class LeagueLicenseReleaseDateTest < ActiveSupport::TestCase
  RELEASED_AT = Time.zone.parse('2026-01-10 09:00')

  setup do
    create(:setting, current_season_id: '18')
    @league = create(:league, :current_season)
    @club   = create(:club)
    @team   = create(:team, league: @league, club: @club)
    @former = create(:club)
    @admin  = create(:user, :admin)
  end

  def player_with_license(team: @team, status: License::APPROVED)
    create(:player, with_licenses: [{ team: team, status: status }])
  end

  def release(player, to: @club, status: 'approved', season: 18, approved_at: RELEASED_AT)
    TransferRequest.create!(
      player: player,
      requesting_club: to,
      former_club: @former,
      season_id: season,
      status: status,
      request_type: 'release',
      created_by: @admin.id,
      lv_approved_at: status == 'approved' ? approved_at : nil
    )
  end

  # Ohne &. beim Aufruf: Fehlt der Spieler in der Liste, bricht der Test mit
  # NoMethodError ab, statt still gruen durchzulaufen.
  def team_license_for(player, league: @league)
    item = league.licenses.first
    item[:players].find { |p| p[:id] == player.id }&.dig(:team_license)
  end

  test 'genehmigte Freigabe fuer den Verein der Mannschaft liefert das Datum' do
    player = player_with_license
    release(player)

    assert_equal RELEASED_AT, team_license_for(player)[:released_at]
  end

  test 'ohne Freigabe bleibt das Feld leer' do
    player = player_with_license

    assert_nil team_license_for(player)[:released_at]
  end

  test 'eine Zweitvereins-Zugehoerigkeit ohne Freigabeverfahren zaehlt nicht' do
    # Ein blosser clubs-Eintrag ohne Vorgang: So sieht der Altbestand aus, und so
    # sah bis api#572 auch aus, was `add_additional_club` schrieb. Sein created_at
    # belegt fuer sich genommen keine Freigabe. Seit api#572 legt der Controller
    # den Vorgang mit an und erscheint deshalb sehr wohl in dieser Liste (siehe
    # players_release_transfer_request_test); hier wird bewusst am Controller
    # vorbei geschrieben, um den Restbestand ohne Vorgang zu pruefen.
    player = player_with_license
    player.clubs = [{ 'club_id' => @club.id, 'home_club' => false,
                      'created_at' => RELEASED_AT, 'valid_until' => nil }]
    player.save!

    assert_nil team_license_for(player)[:released_at]

    release(player)

    assert_equal RELEASED_AT, team_license_for(player)[:released_at],
                 'derselbe Spieler zaehlt, sobald ein genehmigter Antrag dahintersteht'
  end

  test 'noch nicht genehmigte Freigabe zaehlt nicht' do
    player = player_with_license
    tr = release(player, status: 'pending_lv')

    assert_nil team_license_for(player)[:released_at]

    tr.update!(status: 'approved', lv_approved_at: RELEASED_AT)

    assert_equal RELEASED_AT, team_license_for(player)[:released_at],
                 'derselbe Antrag zaehlt, sobald nur der Status stimmt'
  end

  test 'zurueckgezogene Freigabe zaehlt nicht' do
    player = player_with_license
    tr = release(player)
    tr.update!(status: 'revoked', revoked_by: @admin.id, revoked_at: Time.current,
               revocation_reason: 'Test')

    assert_nil team_license_for(player)[:released_at]

    tr.update!(status: 'approved')

    assert_equal RELEASED_AT, team_license_for(player)[:released_at],
                 'derselbe Antrag zaehlt, sobald nur der Status stimmt'
  end

  test 'ein Transfer ist keine Freigabe' do
    player = player_with_license
    tr = release(player)
    tr.update!(request_type: 'transfer')

    assert_equal 'transfer', tr.reload.request_type, 'Vorbedingung: die Umstellung hat gegriffen'
    assert_nil team_license_for(player)[:released_at]

    tr.update!(request_type: 'release')

    assert_equal RELEASED_AT, team_license_for(player)[:released_at],
                 'derselbe Antrag zaehlt, sobald nur die Antragsart stimmt'
  end

  test 'Freigabe an einen anderen Verein zaehlt nicht' do
    player = player_with_license
    tr = release(player, to: create(:club))

    assert_nil team_license_for(player)[:released_at]

    tr.update!(requesting_club: @club)

    assert_equal RELEASED_AT, team_license_for(player)[:released_at],
                 'derselbe Antrag zaehlt, sobald nur der Verein stimmt'
  end

  test 'Freigabe aus einer anderen Saison zaehlt nicht' do
    player = player_with_license
    tr = release(player, season: 17)

    assert_nil team_license_for(player)[:released_at]

    tr.update!(season_id: 18)

    assert_equal RELEASED_AT, team_license_for(player)[:released_at],
                 'derselbe Antrag zaehlt, sobald nur die Saison stimmt'
  end

  test 'bei mehreren Freigaben an denselben Verein zaehlt die frueheste' do
    # Absichtlich in absteigender Reihenfolge angelegt: Faellt die Sortierung
    # in license_release_dates weg, gewinnt sonst die Einfuegereihenfolge und
    # der Test waere auch ohne sie gruen.
    player = player_with_license
    release(player, approved_at: Time.zone.parse('2026-04-02 09:00'))
    release(player, approved_at: Time.zone.parse('2026-01-05 09:00'))

    assert_equal Time.zone.parse('2026-01-05 09:00'), team_license_for(player)[:released_at],
                 'freigegeben ist der Spieler ab der ersten wirksamen Freigabe'
  end

  test 'Spielgemeinschaft: Freigabe an einen der beteiligten Vereine genuegt' do
    partner = create(:club)
    @team.update!(syndicate: true, syndicate_clubs: [partner.id])
    player = player_with_license
    release(player, to: partner)

    assert_equal RELEASED_AT, team_license_for(player)[:released_at]
  end

  test 'Spielgemeinschaft: bei Freigaben an beide Vereine zaehlt die frueheste' do
    partner = create(:club)
    @team.update!(syndicate: true, syndicate_clubs: [partner.id])
    player = player_with_license
    release(player, to: partner, approved_at: Time.zone.parse('2026-01-10 09:00'))
    release(player, to: @club, approved_at: Time.zone.parse('2026-03-05 09:00'))

    assert_equal Time.zone.parse('2026-01-10 09:00'), team_license_for(player)[:released_at],
                 'die Freigabe an den Partnerverein macht den Spieler bereits spielberechtigt'
  end

  test 'ein Spieler in zwei Teams: das Datum haengt am Verein des jeweiligen Teams' do
    other_club = create(:club)
    other_team = create(:team, league: @league, club: other_club)
    player = create(:player, with_licenses: [{ team: @team }, { team: other_team }])
    release(player, to: @club)

    items = @league.licenses
    with_release = items.find { |t| t[:id] == @team.id }[:players]
                        .find { |p| p[:id] == player.id }
    without = items.find { |t| t[:id] == other_team.id }[:players]
                   .find { |p| p[:id] == player.id }

    assert_equal RELEASED_AT, with_release[:team_license][:released_at]
    assert_nil without[:team_license][:released_at],
               'die Zuordnung laeuft je Team, nicht spielerweit'
  end

  test 'mehrere Ligen in einem Aufruf vermischen die Freigaben nicht' do
    other_league = create(:league, :current_season)
    other_club = create(:club)
    other_team = create(:team, league: other_league, club: other_club)
    player_a = player_with_license
    player_b = create(:player, with_licenses: [{ team: other_team }])
    release(player_a, to: @club)

    result = League.licenses_for([@league, other_league])

    a = result[@league.id].first[:players].find { |p| p[:id] == player_a.id }
    b = result[other_league.id].first[:players].find { |p| p[:id] == player_b.id }

    assert_equal RELEASED_AT, a[:team_license][:released_at]
    assert_nil b[:team_license][:released_at]
  end

  test 'with_release_dates: false laesst das Feld leer' do
    # Der Weg der Verbands-Lizenzuebersicht: Sie zeigt die Freigabe nicht und
    # soll die Abfrage ueber alle Spieler einer Saison nicht bezahlen.
    player = player_with_license
    release(player)

    result = League.licenses_for([@league], team_hash: :light, with_other_licenses: false,
                                            with_release_dates: false)
    item = result[@league.id].first[:players].find { |p| p[:id] == player.id }

    assert_nil item[:team_license][:released_at]
  end

  test 'Beantragungsdatum bleibt nach der Erteilung neben dem Erteilungsdatum stehen' do
    # Regressionsschutz fuer die Fachzusage der Lizenzliste: "beantragt am"
    # darf nicht durch "erteilt am" ersetzt werden, die SBK liest daran die
    # Fristwahrung ab. Das Verhalten gab es vorher schon, behauptet hat es
    # niemand.
    player = create(:player, with_licenses: [{ team: @team, status: License::REQUESTED,
                                               created_at: 3.days.ago.iso8601 }])
    player.licenses.first['history'] << {
      'license_status_id' => License::APPROVED,
      'created_by' => @admin.id,
      'created_at' => 1.day.ago.iso8601
    }
    player.save!

    team_license = team_license_for(player)

    assert_not_nil team_license[:requested_at], 'beantragt am bleibt sichtbar'
    assert_not_nil team_license[:approved_at], 'erteilt am steht daneben'
    assert_operator team_license[:requested_at], :<, team_license[:approved_at]
  end

  test 'Status-IDs als String liefern Beantragungs- und Erteilungsdatum' do
    # JSONB-Status-IDs sind nicht typgarantiert. Ohne .to_i stand eine solche
    # Lizenz zwar in der Liste, aber ohne die beiden Daten, um die es hier geht.
    player = create(:player, with_licenses: [{ team: @team, status: '2',
                                               created_at: 3.days.ago.iso8601 }])
    player.licenses.first['history'] << {
      'license_status_id' => '1',
      'created_by' => @admin.id,
      'created_at' => 1.day.ago.iso8601
    }
    player.save!

    team_license = team_license_for(player)

    assert_not_nil team_license, 'die Lizenz steht in der Liste'
    assert_not_nil team_license[:requested_at], 'beantragt am trotz String-Status'
    assert_not_nil team_license[:approved_at], 'erteilt am trotz String-Status'
  end
end
