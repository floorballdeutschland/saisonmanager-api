require 'test_helper'

# Merge-Anträge: ein VM schlägt vor, ein Duplikat (secondary_player) in den
# Spieler des Antrags (Master) zusammenzuführen; die Ausführung beim Genehmigen
# delegiert an Player#merge_into!.
class PlayerChangeRequestMergeTest < ActiveSupport::TestCase
  setup do
    @club = create(:club)
    @master = create(:player, clubs: [{ 'club_id' => @club.id, 'home_club' => true }])
    @duplicate = create(:player, first_name: @master.first_name, last_name: @master.last_name)
  end

  def build_merge(secondary: @duplicate)
    PlayerChangeRequest.new(player: @master, club: @club, correction_type: 'merge',
                            status: 'pending', secondary_player: secondary, requested_by_user_id: 1)
  end

  test 'merge-Antrag braucht keinen new_value, aber einen secondary_player' do
    assert_predicate build_merge, :valid?

    request = build_merge(secondary: nil)
    assert_not request.valid?
    assert request.errors[:secondary_player].any?
  end

  test 'secondary darf nicht der Spieler selbst sein' do
    assert_not build_merge(secondary: @master).valid?
  end

  test 'bereits zusammengeführter secondary wird beim Anlegen abgelehnt' do
    @duplicate.update_columns(merged_into_id: @master.id)
    assert_not build_merge.valid?
  end

  test 'gemeinsames Spiel in der Aufstellung blockiert den Antrag' do
    create_game_with_both_players
    request = build_merge
    assert_not request.valid?
    assert request.errors[:base].any?
  end

  test 'apply! führt zusammen, deaktiviert das Duplikat und genehmigt den Antrag' do
    request = build_merge.tap(&:save!)
    request.apply!(42)

    assert_equal 'approved', request.reload.status
    assert_equal 42, request.reviewed_by_user_id

    @duplicate.reload
    assert_equal @master.id, @duplicate.merged_into_id
    assert_predicate @duplicate.deactivated_at, :present?
  end

  test 'apply! übersetzt Merge-Fehler in RecordInvalid und lässt den Antrag pending' do
    request = build_merge.tap(&:save!)
    # Zustand hat sich seit Antragstellung geändert: anderweitig zusammengeführt
    @duplicate.update_columns(merged_into_id: @master.id)

    assert_raises(ActiveRecord::RecordInvalid) { request.apply!(42) }
    assert_equal 'pending', request.reload.status
  end

  private

  def create_game_with_both_players
    go = GameOperation.create!(name: 'GO', short_name: 'GO')
    league = League.create!(game_operation: go, name: 'Liga', season_id: '18', table_modus: 'classic')
    arena = Arena.create!(name: 'Halle', city: 'Stadt')
    game_day = GameDay.create!(league: league, arena: arena, club: @club, number: 1, date: '2026-02-01')
    home = Team.create!(league: league, club: @club, name: 'H')
    guest = Team.create!(league: league, club: @club, name: 'G')
    Game.create!(game_day: game_day, home_team: home, guest_team: guest, forfait: 0,
                 overtime: false, legacy: false, events: [],
                 players: { 'home' => [{ 'player_id' => @master.id }],
                            'guest' => [{ 'player_id' => @duplicate.id }] })
  end
end
