require 'test_helper'

# Datenintegritäts-Invarianten für Transfer-Workflows.
# Prüft Postconditions nach execute_transfer! und generelle Konsistenzregeln.
class TransferConsistencyTest < ActiveSupport::TestCase
  setup do
    create(:setting, current_season_id: '18')
    @league     = create(:league, :current_season)
    @team       = create(:team, league: @league)
    @admin      = create(:user, :admin)
    @club_a     = create(:club)
    @club_b     = create(:club)
  end

  def create_open_transfer(player:, from: @club_a, to: @club_b, status: 'pending_lv')
    TransferRequest.create!(
      player: player,
      requesting_club: to,
      former_club: from,
      season_id: Setting.current_season_id.to_i,
      status: status,
      request_type: 'transfer',
      created_by: @admin.id
    )
  end

  # --- Postconditions nach execute_transfer! ---

  test 'nach execute_transfer!: Status ist approved' do
    player = create(:player)
    player.clubs = [{ 'club_id' => @club_a.id, 'home_club' => true, 'valid_until' => nil }]
    player.save!
    tr = create_open_transfer(player: player)

    tr.execute_transfer!(@admin.id)

    assert_equal 'approved', tr.reload.status
  end

  test 'nach execute_transfer!: Player#clubs enthält genau einen home_club=true-Eintrag' do
    player = create(:player)
    player.clubs = [{ 'club_id' => @club_a.id, 'home_club' => true, 'valid_until' => nil }]
    player.save!
    tr = create_open_transfer(player: player)

    tr.execute_transfer!(@admin.id)
    player.reload

    home_entries = player.clubs.select { |c| c['home_club'] == true && c['valid_until'].nil? }
    assert_equal 1, home_entries.size,
                 'Nach execute_transfer! darf es genau einen aktiven home_club=true-Eintrag geben'
    assert_equal @club_b.id, home_entries.first['club_id'].to_i,
                 'Der neue home_club muss der aufnehmende Verein sein'
  end

  test 'nach execute_transfer!: alter Club-Eintrag hat valid_until gesetzt' do
    player = create(:player)
    player.clubs = [{ 'club_id' => @club_a.id, 'home_club' => true, 'valid_until' => nil }]
    player.save!
    tr = create_open_transfer(player: player)

    tr.execute_transfer!(@admin.id)
    player.reload

    old_entry = player.clubs.find { |c| c['club_id'].to_i == @club_a.id }
    assert old_entry, "Eintrag für alten Club (#{@club_a.id}) muss noch vorhanden sein"
    assert old_entry['valid_until'].present?,
           'Alter Club-Eintrag muss valid_until gesetzt haben nach Transfer'
  end

  # --- Konsistenz-Invarianten ---

  test 'ein deaktivierter Player darf keinen offenen TransferRequest haben' do
    player = create(:player, with_licenses: [{ team: @team, status: License::APPROVED }])
    player.clubs = [{ 'club_id' => @club_a.id, 'home_club' => true, 'valid_until' => nil }]
    player.save!

    player.deactivate!(@admin.id)
    player.reload

    # Der deaktivierte Spieler sollte nicht transfierbar sein — das ist eine
    # Invariante, die durch Validierungen oder Checks im Workflow erzwungen wird.
    # Wir dokumentieren sie als Erwartung: wenn ein Antrag trotzdem existiert,
    # ist das ein Data-Health-Problem.
    open_transfers = TransferRequest.active.where(player: player)
    assert open_transfers.empty?,
           'Ein deaktivierter Player darf keine offenen TransferRequests haben'
  end

  test 'keine zwei offenen Transfers für denselben Spieler in derselben Saison' do
    player = create(:player)
    player.clubs = [{ 'club_id' => @club_a.id, 'home_club' => true }]
    player.save!

    create_open_transfer(player: player, status: 'pending_club')

    open = TransferRequest.active.where(player: player, season_id: Setting.current_season_id.to_i)
    assert_equal 1, open.size,
                 'Es darf nur einen offenen Transfer pro Spieler und Saison geben'
  end

  test 'expired-Transfer ist nicht mehr im active-Scope' do
    player = create(:player)
    tr = create_open_transfer(player: player, status: 'pending_club')
    tr.update_column(:created_at, (TransferRequest::EXPIRE_AFTER_DAYS + 1).days.ago)

    tr.expire!

    assert_equal 'expired', tr.reload.status
    refute TransferRequest.active.exists?(id: tr.id),
           'Abgelaufener Transfer muss aus dem active-Scope entfernt sein'
  end

  test 'approved-Transfer hat lv_approved_at gesetzt' do
    player = create(:player)
    player.clubs = [{ 'club_id' => @club_a.id, 'home_club' => true, 'valid_until' => nil }]
    player.save!
    tr = create_open_transfer(player: player)

    tr.execute_transfer!(@admin.id)

    assert tr.reload.lv_approved_at.present?,
           'lv_approved_at muss nach execute_transfer! gesetzt sein'
  end
end
