require 'test_helper'

class TransferRequestTest < ActiveSupport::TestCase
  def setup
    @state_association = create(:state_association)
    @requesting_club   = Club.create!(name: 'Neuer Verein', short_name: 'NV',
                                      state_association_id: @state_association.id)
    @former_club       = Club.create!(name: 'Alter Verein', short_name: 'AV',
                                      state_association_id: @state_association.id)
    @user              = create(:user, :admin)
    create(:setting, current_season_id: '18')

    @player = create(:player, clubs: [
      { 'club_id' => @former_club.id, 'home_club' => true, 'valid_until' => nil }
    ])
  end

  def build_transfer_request(attrs = {})
    TransferRequest.new({
      player:          @player,
      requesting_club: @requesting_club,
      former_club:     @former_club,
      created_by:      @user.id,
      season_id:       18,
      request_type:    'transfer'
    }.merge(attrs))
  end

  # ---------------------------------------------------------------------------
  # 1. Default status
  # ---------------------------------------------------------------------------

  test 'frischer TransferRequest hat Status pending_club' do
    tr = build_transfer_request
    tr.save!
    assert_equal 'pending_club', tr.status
  end

  # ---------------------------------------------------------------------------
  # 2. player_confirmation_token wird vor dem Speichern erzeugt
  # ---------------------------------------------------------------------------

  test 'player_confirmation_token ist nach create nicht nil und hat eine Länge' do
    tr = build_transfer_request
    assert_nil tr.player_confirmation_token, 'Vor dem Speichern darf kein Token gesetzt sein'
    tr.save!
    assert_not_nil tr.player_confirmation_token
    assert_not tr.player_confirmation_token.empty?
  end

  # ---------------------------------------------------------------------------
  # 3. execute_transfer! überträgt den Spieler zum neuen Verein
  # ---------------------------------------------------------------------------

  test 'nach execute_transfer! hat der Spieler genau einen aktiven home_club == requesting_club' do
    tr = build_transfer_request
    tr.status = 'pending_lv'
    tr.save!

    # deliver_later nicht ausführen
    TransferRequestMailer.stub(:transfer_completed, OpenStruct.new(deliver_later: nil)) do
      tr.execute_transfer!(@user.id)
    end

    @player.reload
    active_home_clubs = @player.clubs.select { |c| c['home_club'] == true && c['valid_until'].nil? }
    assert_equal 1, active_home_clubs.size, 'Genau ein aktiver Home-Club erwartet'
    assert_equal @requesting_club.id, active_home_clubs.first['club_id'],
                 'Aktiver Home-Club muss der requesting_club sein'
  end

  test 'nach execute_transfer! hat der alte Home-Club-Eintrag ein valid_until gesetzt' do
    tr = build_transfer_request
    tr.status = 'pending_lv'
    tr.save!

    TransferRequestMailer.stub(:transfer_completed, OpenStruct.new(deliver_later: nil)) do
      tr.execute_transfer!(@user.id)
    end

    @player.reload
    old_home_entries = @player.clubs.select do |c|
      c['club_id'] == @former_club.id && c['home_club'] == true
    end
    assert old_home_entries.all? { |c| c['valid_until'].present? },
           'Alle früheren Home-Club-Einträge müssen valid_until gesetzt haben'
  end

  test 'nach execute_transfer! hat der TransferRequest den Status approved' do
    tr = build_transfer_request
    tr.status = 'pending_lv'
    tr.save!

    TransferRequestMailer.stub(:transfer_completed, OpenStruct.new(deliver_later: nil)) do
      tr.execute_transfer!(@user.id)
    end

    assert_equal 'approved', tr.reload.status
  end

  # ---------------------------------------------------------------------------
  # 4. execute_release! fügt sekundären Verein hinzu, ohne home_club zu ändern
  # ---------------------------------------------------------------------------

  test 'nach execute_release! hat der Spieler zwei Club-Einträge' do
    tr = build_transfer_request(request_type: 'release')
    tr.status = 'pending_lv'
    tr.save!

    TransferRequestMailer.stub(:transfer_completed, OpenStruct.new(deliver_later: nil)) do
      tr.execute_release!(@user.id)
    end

    @player.reload
    assert_equal 2, @player.clubs.size, 'Erwartet: ursprünglicher Home-Club + neuer sekundärer Club'
  end

  test 'nach execute_release! bleibt der Home-Club unverändert' do
    tr = build_transfer_request(request_type: 'release')
    tr.status = 'pending_lv'
    tr.save!

    TransferRequestMailer.stub(:transfer_completed, OpenStruct.new(deliver_later: nil)) do
      tr.execute_release!(@user.id)
    end

    @player.reload
    active_home_clubs = @player.clubs.select { |c| c['home_club'] == true && c['valid_until'].nil? }
    assert_equal 1, active_home_clubs.size
    assert_equal @former_club.id, active_home_clubs.first['club_id'],
                 'Home-Club darf sich durch execute_release! nicht ändern'
  end

  test 'nach execute_release! ist requesting_club als sekundärer Club eingetragen' do
    tr = build_transfer_request(request_type: 'release')
    tr.status = 'pending_lv'
    tr.save!

    TransferRequestMailer.stub(:transfer_completed, OpenStruct.new(deliver_later: nil)) do
      tr.execute_release!(@user.id)
    end

    @player.reload
    secondary = @player.clubs.find { |c| c['club_id'] == @requesting_club.id }
    assert_not_nil secondary, 'requesting_club muss als sekundärer Club eingetragen sein'
    assert_equal false, secondary['home_club']
  end
end
