require 'test_helper'

# Datenintegritäts-Invarianten für Player-Lizenzen.
# Diese Tests prüfen Postconditions nach lizenzbezogenen Operationen
# (deactivate!, reactivate!) und generelle Konsistenzregeln.
class LicenseConsistencyTest < ActiveSupport::TestCase
  setup do
    create(:setting, current_season_id: '18')
    @league = create(:league, :current_season)
    @team   = create(:team, league: @league)
    @admin  = create(:user, :admin)
  end

  # --- Strukturelle Invarianten ---

  test 'pro Player und (season_id, team_id) existiert höchstens eine APPROVED-Lizenz' do
    player = create(:player, with_licenses: [
      { team: @team, status: License::APPROVED }
    ])

    approved_count = player.licenses.count do |lic|
      last = lic['history'].max_by { |h| h['created_at'] }
      last['license_status_id'].to_i == License::APPROVED &&
        lic['season_id'].to_s == '18' &&
        lic['team_id'].to_i == @team.id
    end

    assert_equal 1, approved_count,
                 'Genau eine APPROVED-Lizenz pro (player, season_id, team_id) erwartet'
  end

  test 'Lizenz-History ist chronologisch geordnet (max_by ergibt letzten Eintrag)' do
    player = create(:player, with_licenses: [
      { team: @team, status: License::APPROVED, created_at: 2.days.ago.iso8601 }
    ])

    player.licenses.each do |lic|
      history = lic['history']
      sorted = history.sort_by { |h| h['created_at'] }
      assert_equal sorted.map { |h| h['created_at'] },
                   history.map { |h| h['created_at'] },
                   'History-Einträge müssen aufsteigend nach created_at geordnet sein'
    end
  end

  test 'APPROVED-Lizenz hat mindestens einen History-Eintrag mit created_at' do
    player = create(:player, with_licenses: [
      { team: @team, status: License::APPROVED }
    ])

    player.licenses.each do |lic|
      last = lic['history'].max_by { |h| h['created_at'] }
      next unless last['license_status_id'].to_i == License::APPROVED

      assert last['created_at'].present?,
             "APPROVED-History-Eintrag muss created_at haben (Lizenz: #{lic['id']})"
    end
  end

  # --- Postconditions nach deactivate! ---

  test 'nach deactivate!: keine APPROVED-Lizenz mehr aktiv' do
    player = create(:player, with_licenses: [
      { team: @team, status: License::APPROVED }
    ])

    player.deactivate!(@admin.id)
    player.reload

    active = player.licenses.any? do |lic|
      last = lic['history']&.max_by { |h| h['created_at'] }
      License::ACTIVE_STATUSES.include?(last&.dig('license_status_id').to_i)
    end

    refute active, 'Nach deactivate! darf keine APPROVED/REQUESTED-Lizenz mehr aktiv sein'
  end

  test 'nach deactivate!: keine REQUESTED-Lizenz mehr aktiv' do
    player = create(:player, with_licenses: [
      { team: @team, status: License::REQUESTED }
    ])

    player.deactivate!(@admin.id)
    player.reload

    active = player.licenses.any? do |lic|
      last = lic['history']&.max_by { |h| h['created_at'] }
      last&.dig('license_status_id').to_i == License::REQUESTED
    end

    refute active, 'Nach deactivate! darf keine REQUESTED-Lizenz mehr vorhanden sein'
  end

  test 'nach deactivate!: bereits DELETED-Lizenz bleibt unverändert' do
    player = create(:player, with_licenses: [
      { team: @team, status: License::DELETED }
    ])
    history_count_before = player.licenses.first['history'].size

    player.deactivate!(@admin.id)
    player.reload

    assert_equal history_count_before, player.licenses.first['history'].size,
                 'Eine bereits DELETED-Lizenz darf durch deactivate! nicht nochmals markiert werden'
  end

  test 'nach deactivate!: Spieler hat deactivated_at gesetzt' do
    player = create(:player, with_licenses: [{ team: @team, status: License::APPROVED }])

    player.deactivate!(@admin.id, reason: 'Karriereende')
    player.reload

    assert player.deactivated_at.present?, 'deactivated_at muss nach deactivate! gesetzt sein'
    assert_equal @admin.id, player.deactivated_by
  end

  # --- Postconditions nach reactivate! ---

  test 'nach reactivate!: system-deaktivierte Lizenzen werden wiederhergestellt' do
    player = create(:player, with_licenses: [
      { team: @team, status: License::APPROVED }
    ])

    player.deactivate!(@admin.id, reason: 'Deaktiviert')
    history_after_deactivate = player.reload.licenses.first['history'].size

    player.reactivate!
    player.reload

    assert_equal history_after_deactivate - 1,
                 player.licenses.first['history'].size,
                 'reactivate! muss den DELETED-Eintrag aus deactivate! entfernen'
    last = player.licenses.first['history'].max_by { |h| h['created_at'] }
    assert_equal License::APPROVED, last['license_status_id'].to_i,
                 'Nach reactivate! muss die Lizenz wieder APPROVED sein'
  end

  test 'nach reactivate!: manuell gelöschte Lizenzen bleiben gelöscht' do
    player = create(:player, with_licenses: [
      { team: @team, status: License::DELETED }
    ])
    player.update_column(:deactivated_by, @admin.id)

    player.reactivate!
    player.reload

    last = player.licenses.first['history'].max_by { |h| h['created_at'] }
    assert_equal License::DELETED, last['license_status_id'].to_i,
                 'Manuell gelöschte Lizenz darf durch reactivate! nicht wiederhergestellt werden'
  end

  test 'nach reactivate!: deactivated_at und deactivated_by werden gelöscht' do
    player = create(:player, with_licenses: [{ team: @team, status: License::APPROVED }])
    player.deactivate!(@admin.id)

    player.reactivate!
    player.reload

    assert_nil player.deactivated_at, 'deactivated_at muss nach reactivate! nil sein'
    assert_nil player.deactivated_by, 'deactivated_by muss nach reactivate! nil sein'
  end
end
