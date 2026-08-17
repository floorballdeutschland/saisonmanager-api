require 'test_helper'

# Ansprechpersonen der Vereine und Mannschaften, gebündelt für die SBK.
module Admin
  class ContactsControllerTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting, current_season_id: '18')
      @sa = create(:state_association, name: 'Floorball-Verband Ost')
      @go = create(:game_operation, state_association_id: @sa.id, name: 'SBK Ost')
      @league = create(:league, game_operation: @go, season_id: '18', name: 'Regionalliga Ost')

      @club = create(:club, name: 'Aal Berlin', contact_email: 'info@aal.example',
                            state_association_id: @sa.id)
      @team = create(:team, league: @league, club: @club, name: 'Aal Berlin 1',
                            contact_person: 'Carla Wolf', contact_email: 'team1@aal.example')

      @vm = create(:user, :vm, club_id: @club.id, first_name: 'Anna', last_name: 'Meier',
                               email: 'anna@aal.example')
      @tm = create(:user, :tm, team_id: @team.id, first_name: 'Bruno', last_name: 'Sanchez',
                               email: 'bruno@aal.example')
      # „Zusätzlich informieren" in der Vereinsverwaltung.
      @club.update!(notify_user_ids: [@vm.id])
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end

    def get_contacts(params = {})
      get '/api/v2/admin/contacts.json', params: params
      JSON.parse(response.body)
    end

    test 'die SBK sieht Vereins- und Mannschaftskontakte ihres Spielbetriebs' do
      login(create(:user, :sbk_scoped, game_operation_id: @go.id))

      body = get_contacts

      assert_response :success
      assert_equal '18', body['season_id']
      club = body['clubs'].sole

      assert_equal 'Aal Berlin', club['name']
      assert_equal 'info@aal.example', club['contact_email']
      assert_equal 'Floorball-Verband Ost', club['state_association_name']
      assert_equal ['anna@aal.example'], club['notify_managers'].pluck('email')
      assert_equal ['Anna Meier'], club['notify_managers'].pluck('name')

      team = club['teams'].sole

      assert_equal 'Aal Berlin 1', team['name']
      assert_equal 'Regionalliga Ost', team['league_name']
      assert_equal 'Carla Wolf', team['contact_person']
      assert_equal 'team1@aal.example', team['contact_email']
      assert_equal ['bruno@aal.example'], team['managers'].pluck('email')
    end

    test 'eine Mannschaft ohne Teammanager bleibt sichtbar' do
      @tm.update!(teams: [])
      login(create(:user, :sbk_scoped, game_operation_id: @go.id))

      team = get_contacts['clubs'].sole['teams'].sole

      assert_equal 'Aal Berlin 1', team['name']
      assert_empty team['managers']
    end

    test 'fremde Spielbetriebe bleiben draussen' do
      other_go = create(:game_operation, state_association_id: create(:state_association).id)
      other_league = create(:league, game_operation: other_go, season_id: '18')
      create(:team, league: other_league, club: create(:club, name: 'Zander Ulm'))

      login(create(:user, :sbk_scoped, game_operation_id: @go.id))

      assert_equal ['Aal Berlin'], get_contacts['clubs'].pluck('name')
    end

    test 'der Admin sieht alle Spielbetriebe' do
      other_go = create(:game_operation, state_association_id: create(:state_association).id)
      other_league = create(:league, game_operation: other_go, season_id: '18')
      create(:team, league: other_league, club: create(:club, name: 'Zander Ulm'))

      login(create(:user, :admin))

      assert_equal ['Aal Berlin', 'Zander Ulm'], get_contacts['clubs'].pluck('name')
    end

    test 'eine Gastmannschaft aus einem anderen Landesverband zaehlt mit' do
      guest_club = create(:club, name: 'Barsch Bremen', state_association_id: create(:state_association).id)
      create(:team, league: @league, club: guest_club, name: 'Barsch Bremen 1')

      login(create(:user, :sbk_scoped, game_operation_id: @go.id))

      assert_equal ['Aal Berlin', 'Barsch Bremen'], get_contacts['clubs'].pluck('name')
    end

    test 'nur die laufende Saison, eine mitgeschickte Saison aendert nichts' do
      next_league = create(:league, game_operation: @go, season_id: '19', name: 'Regionalliga Ost')
      create(:team, league: next_league, club: create(:club, name: 'Zander Ulm'))

      login(create(:user, :sbk_scoped, game_operation_id: @go.id))

      body = get_contacts(season_id: '19')

      assert_equal '18', body['season_id']
      assert_equal ['Aal Berlin'], body['clubs'].pluck('name')
    end

    test 'archivierte Konten stehen nicht als Ansprechperson drin' do
      @vm.archive!(@vm.id)
      login(create(:user, :sbk_scoped, game_operation_id: @go.id))

      assert_empty get_contacts['clubs'].sole['notify_managers']
    end

    test 'ein Vereinsmanager ohne club_id-Spalte kommt ueber die Rolle mit' do
      @vm.update!(club_id: nil)
      login(create(:user, :sbk_scoped, game_operation_id: @go.id))

      assert_equal ['anna@aal.example'], get_contacts['clubs'].sole['notify_managers'].pluck('email')
    end

    test 'ein nicht markierter Vereinsmanager steht nicht drin' do
      @club.update!(notify_user_ids: [])
      login(create(:user, :sbk_scoped, game_operation_id: @go.id))

      club = get_contacts['clubs'].sole

      assert_empty club['notify_managers']
      # Die Kontaktadresse des Vereins bleibt davon unberührt.
      assert_equal 'info@aal.example', club['contact_email']
    end

    test 'markiert wird nur, wer heute noch Vereinsmanager dieses Vereins ist' do
      other_club = create(:club, name: 'Barsch Bremen')
      stranger = create(:user, :vm, club_id: other_club.id, email: 'fremd@barsch.example')
      @club.update!(notify_user_ids: [@vm.id, stranger.id, 999_999])

      login(create(:user, :sbk_scoped, game_operation_id: @go.id))

      assert_equal ['anna@aal.example'], get_contacts['clubs'].sole['notify_managers'].pluck('email')
    end

    test 'ein Verein ohne Kontaktadresse und ohne Markierung bleibt sichtbar' do
      @club.update!(contact_email: nil, notify_user_ids: [])
      login(create(:user, :sbk_scoped, game_operation_id: @go.id))

      club = get_contacts['clubs'].sole

      assert_equal 'Aal Berlin', club['name']
      assert_nil club['contact_email']
      assert_empty club['notify_managers']
    end

    test 'eine Alt-Rolle mit der Gruppen-ID als String zaehlt mit' do
      legacy = create(:user, first_name: 'Dana', last_name: 'Fischer', email: 'dana@aal.example',
                             permissions: [{ 'user_group_id' => '4', 'club_id' => @club.id.to_s }])
      @club.update!(notify_user_ids: [legacy.id])

      login(create(:user, :sbk_scoped, game_operation_id: @go.id))

      assert_equal ['dana@aal.example'], get_contacts['clubs'].sole['notify_managers'].pluck('email')
    end

    test 'ohne Spielbetriebsrolle ist die Liste gesperrt' do
      login(create(:user, :vm, club_id: @club.id))

      get '/api/v2/admin/contacts.json'

      assert_response :forbidden
    end

    test 'ohne Anmeldung ist die Liste gesperrt' do
      get '/api/v2/admin/contacts.json'

      assert_response :unauthorized
    end
  end
end
