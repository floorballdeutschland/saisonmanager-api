Rails.application.routes.draw do
  # For details on the DSL available within this file, see https://guides.rubyonrails.org/routing.html
  resources :arenas
  resources :clubs
  resources :games
  resources :game_day
  resources :game_operations do
    member do
      get :leagues, to: 'game_operations#index_leagues'
    end

    collection do
      get 'by_shortname/:name', to: 'game_operations#by_shortname'
    end
  end
  resources :leagues do
    member do
      get :schedule
      get :table
      get :scorer
      get :meta
    end
  end
  resources :players
  resources :teams
  resources :users

  resources :license_fees

  get 'calendar/teams/:id', to: 'teams#show', constraints: ->(req) { req.format == :ics }
  get 'calendar/leagues/:id', to: 'leagues#show', constraints: ->(req) { req.format == :ics }
  get 'calendar/games/:id', to: 'games#show', constraints: ->(req) { req.format == :ics }

  get 'api/v1/ticker/:game_operation_id/:season_id/leagues', to: 'api#leagues'
  get 'api/v1/ticker/games/:id', to: 'api#games'
  get 'api/v1/upcoming_games', to: 'games#users_games'

  get 'internal/update_games/update_start_end', to: 'games#update_start_end'

  scope 'api' do
    scope 'v2' do
      # session handling
      post 'login' => 'sessions#login'
      post 'logout' => 'sessions#logout'

      post 'lost_password' => 'sessions#lost_password'
      post 'reset_password' => 'users#reset_password_token'

      get 'teams/:id', to: 'teams#show'
      get 'teams/:id/stats', to: 'teams#stats'
      get 'players/:id/stats', to: 'players#stats'

      resources :leagues do
        member do
          get 'game_days/current/schedule', to: 'leagues#current_schedule'
          get 'game_days/:game_day_number/schedule', to: 'leagues#game_day_schedule'
          get :schedule
          get :table
          get :grouped_table
          get :scorer
          get :meta
          get :license_list
        end
      end

      scope 'admin' do
        resources :game
        resources :game_day
      end

      get 'admin/leagues', to: 'leagues#admin_league_index'
      get 'admin/league_classes', to: 'leagues#admin_league_classes'

      post 'admin/leagues', to: 'leagues#admin_league_update'

      post 'admin/leagues/import_schedule', to: 'leagues#admin_schedule_import_games'

      get 'admin/leagues/:id/teams', to: 'leagues#admin_league_team_index'
      get 'admin/leagues/:id/game_schedule', to: 'leagues#admin_game_schedule'
      get 'admin/leagues/:id/schedule_import_template', to: 'leagues#admin_schedule_import_template'
      get 'admin/leagues/:id/additional_references', to: 'leagues#additional_references'
      get 'admin/leagues/:id/licenses', to: 'players#admin_licenses'
      post 'admin/leagues/:id/copy_preround_licenses', to: 'leagues#copy_preround_licenses'
      post 'admin/leagues/:id/import_teams', to: 'leagues#admin_import_teams'
      post 'admin/leagues/:id/upload_banner', to: 'leagues#admin_upload_banner'
      delete 'admin/leagues/:id/banner', to: 'leagues#admin_delete_banner'

      post 'admin/game_operations/:id/upload_banner', to: 'game_operations#admin_upload_banner'
      delete 'admin/game_operations/:id/banner', to: 'game_operations#admin_delete_banner'
      patch 'admin/game_operations/:id/banner_link', to: 'game_operations#admin_update_banner_link'

      get 'admin/teams/:id', to: 'teams#admin_get_team'
      get 'admin/league/clubs/:callType/:id', to: 'clubs#admin_get_go_clubs'
      get 'admin/game_operations', to: 'game_operations#admin_game_operations'

      post 'admin/teams', to: 'teams#admin_team_update'

      get 'admin/clubs/all', to: 'clubs#admin_club_all'
      get 'admin/clubs', to: 'clubs#admin_club_index'
      get 'admin/clubs/:id', to: 'clubs#admin_club'
      post 'admin/clubs', to: 'clubs#admin_club_update'
      post 'admin/clubs/:id/upload_logo', to: 'clubs#admin_upload_logo'
      post 'admin/clubs/:id/deactivate', to: 'clubs#admin_club_deactivate'
      post 'admin/clubs/:id/reactivate', to: 'clubs#admin_club_reactivate'

      post 'admin/teams/:id/upload_logo', to: 'teams#admin_upload_logo'

      post 'admin/players/:id/transfer', to: 'players#transfer'
      post 'admin/players/:id/add_additional_club', to: 'players#add_additional_club'
      post 'admin/players/:id/remove_additional_club', to: 'players#remove_additional_club'
      post 'admin/players/:id/deactivate', to: 'players#deactivate'
      post 'admin/players/:id/reactivate', to: 'players#reactivate'
      post 'admin/players/:id/merge', to: 'players#merge'
      get   'admin/vm/players', to: 'players#vm_players_index'
      patch 'admin/vm/players/:id/email', to: 'players#update_email'

      post 'admin/players/:id/handle_license_request', to: 'players#handle_license_request'

      get    'admin/players/:player_id/license_documents',     to: 'admin/license_documents#index'
      post   'admin/players/:player_id/license_documents',     to: 'admin/license_documents#create'
      get    'admin/players/:player_id/license_documents/:id', to: 'admin/license_documents#show'
      delete 'admin/players/:player_id/license_documents/:id', to: 'admin/license_documents#destroy'

      get    'admin/players/:player_id/suspensions',     to: 'admin/player_suspensions#index'
      post   'admin/players/:player_id/suspensions',     to: 'admin/player_suspensions#create'
      delete 'admin/players/:player_id/suspensions/:id', to: 'admin/player_suspensions#destroy'

      get 'admin/clubs/:club_id/players', to: 'players#admin_players_index'
      get 'admin/players/search', to: 'players#global_search'
      get 'admin/players/:id', to: 'players#admin_player'
      post 'admin/players', to: 'players#admin_player_update'

      get 'admin/game_operations/:id/clubs', to: 'game_operations#admin_club_index'

      get 'game_operations/:id/leagues/:season_id', to: 'game_operations#index_leagues'
      get 'game_operations/:id/leagues', to: 'game_operations#index_leagues'

      get 'user/clubs_and_teams', to: 'clubs#user_clubs_and_teams'
      get 'user/team/:id/licenses', to: 'clubs#user_team_licenses'

      post 'user/games/:id/starting/:side/:position/set_player', to: 'games#set_starting_player'
      post 'user/games/:id/award/:side/:award/set_player', to: 'games#set_player_award'

      post 'user/games/:id/lineup/:side/add_player', to: 'games#add_player_to_lineup'
      post 'user/games/:id/lineup/:side/remove_player', to: 'games#remove_player'
      post 'user/games/:id/lineup/:side/add_coach/:number', to: 'games#add_coach'
      post 'user/games/:id/lineup/:side/remove_coach/:number', to: 'games#remove_coach'
      post 'user/games/:id/lineup/:side/set_captain', to: 'games#set_captain'
      post 'user/games/:id/events/add', to: 'games#add_event'
      post 'user/games/:id/events/remove', to: 'games#remove_event'
      post 'user/games/:id/events/update', to: 'games#update_event'
      post 'user/games/:id/referees/:referee_number', to: 'games#set_referee'
      post 'user/games/:id/game_status', to: 'games#set_game_status'
      post 'user/games/:id/reopen', to: 'games#reopen_game'

      get 'user/games/:id/editable', to: 'games#editable'

      post 'user/games/:id/set_flag', to: 'games#set_flag'
      post 'user/games/:id/set_field', to: 'games#set_string'

      post 'user/games/:id/checklist_answers', to: 'games#set_checklist_answers'

      get  'games/:id/checklist_veto', to: 'games#show_checklist_veto'
      post 'games/:id/checklist_veto', to: 'games#submit_checklist_veto'

      get  'games/:game_id/referee_report', to: 'game_referee_reports#show'
      post 'games/:game_id/referee_report', to: 'game_referee_reports#create'

      get  'user/games/:game_id/scan', to: 'game_scans#show'
      post 'user/games/:game_id/scan', to: 'game_scans#create'
      delete 'user/games/:game_id/scan', to: 'game_scans#destroy'

      get 'user/games/:id/additional_fields', to: 'games#show_hidden'

      get 'user/leagues/penalties', to: 'leagues#penalties'
      get 'user/leagues/penalty_codes', to: 'leagues#penalty_codes'

      get 'user/leagues/licenses/index', to: 'leagues#user_leagues_license_list_index'
      get 'user/leagues/:id/licenses', to: 'players#user_licenses_temp'

      post 'user/players/:id/request_license', to: 'players#request_license'
      post 'user/players/:id/withdraw_license', to: 'players#withdraw_license_request'
      post 'user/players/:id/reenable_license_request', to: 'players#reenable_license_request'
      get 'user/players/nations', to: 'players#user_get_nations'

      get 'referee/profile', to: 'referee_profile#show'
      put 'referee/profile', to: 'referee_profile#update'

      get 'user/referees/:id', to: 'referees#show'
      get 'referees/search', to: 'referees#search'
      get 'referees/:id/games', to: 'referees#games'

      get  'referee/online_tests',            to: 'referee_online_tests#index'
      get  'referee/online_tests/:id',        to: 'referee_online_tests#show'
      post 'referee/online_tests/:id/start',  to: 'referee_online_tests#start'
      post 'referee/online_tests/:id/submit', to: 'referee_online_tests#submit'

      get  'referee/game_days',                        to: 'referee_game_day_confirmations#index'
      post 'referee/game_days/:game_day_id/confirm',   to: 'referee_game_day_confirmations#confirm'

      get  'referee/blocked_dates',          to: 'referee_blocked_dates#index'
      post 'referee/blocked_dates',          to: 'referee_blocked_dates#create'
      post 'referee/blocked_dates/bulk',     to: 'referee_blocked_dates#bulk_create'
      delete 'referee/blocked_dates/:id',    to: 'referee_blocked_dates#destroy'

      get 'referee/history/games', to: 'referee_history#games'
      get 'referee/history/tests', to: 'referee_history#tests'

      namespace :admin do
        resources :leagues, only: [] do
          resources :qualifications, only: %i[create update destroy],
                                     controller: 'league_qualifications'
        end
        resources :referees, only: %i[index show create update destroy] do
          get :games, on: :member
          get :club_stats, on: :member
          post :wallet_pass, on: :member
          post :merge, on: :member
          post :create_user, on: :member
          get :incorrect_assignments, on: :collection
          get :next_lizenznummer, on: :collection
        end
        resources :referee_qualification_types, only: %i[index create update destroy]
        resources :referee_license_levels, only: %i[index create update destroy]
        resources :referee_course_imports, only: %i[index show create destroy] do
          post :submit, on: :member
        end
        resources :referee_course_results, only: %i[index update] do
          post :approve, on: :member
          post :reject, on: :member
        end
        resources :referee_assignments, only: %i[index create update] do
          post :notify, on: :member
          post :publish, on: :member
          get :available, on: :collection
          get :games, on: :collection
        end
        resources :state_associations, only: %i[index show create update destroy] do
          resources :checklist_items, only: %i[create update destroy],
                                      controller: 'state_association_checklist_items'
          resources :releases, only: %i[create destroy],
                               controller: 'state_association_releases' do
            get :candidates, on: :collection
          end
          member do
            post :upload_banner
            delete :banner, action: :delete_banner
            post :upload_logo
            delete :logo, action: :delete_logo
          end
        end
        resources :api_keys, only: %i[index create update destroy]
        resources :email_logs, only: [:index] do
          collection { post :send_test }
        end
        resources :licenses, only: [:index]
        resources :player_change_requests, only: %i[index create] do
          member do
            patch :approve
            patch :reject
          end
        end
        resources :transfer_requests, only: %i[index show create] do
          collection do
            get :search_player
            get :player_approve
            get :player_reject
          end
          member do
            patch :approve_club
            patch :reject_club
            patch :approve_lv
            patch :reject_lv
            patch :execute
            patch :revoke
            patch :withdraw
          end
        end
        resources :users, only: %i[index show create update] do
          member { post :trigger_password_reset }
        end
        resource :analytics, only: [:show]
        resources :arenas, only: %i[index create update destroy]
        resources :online_tests do
          member do
            post :publish
            get  :results
          end
          resources :questions, controller: 'online_test_questions', only: %i[create update destroy]
          resources :assignments, controller: 'online_test_assignments', only: %i[index create destroy]
        end
        get  'settings/seasons',        to: 'settings#seasons'
        post 'settings/seasons',        to: 'settings#create_season'
        patch 'settings/current_season', to: 'settings#update_season'
      end

      namespace :vm do
        resources :referees, only: %i[index]
      end

      get 'state_associations', to: 'state_associations#index'

      get 'transfers/public', to: 'players#transfers_public'

      get 'public/license_list', to: 'public_license_list#show'
      get 'public/secretary', to: 'public_secretary#show'

      post 'user/game_days/:game_day_id/secretary_link', to: 'game_day_secretary_links#create'
      get  'user/game_days/:game_day_id/secretary_link', to: 'game_day_secretary_links#show'

      resources :games
      resources :game_days

      get 'init', to: 'settings#init'
      get 'version', to: 'version#show'

      get 'admin/fixer/players/:id/fix_double_license', to: 'players#handle_license_doublication'
      get 'admin/fixer/games/:id/reopen', to: 'games#reopen_game'
    end
  end

  post 'login' => 'sessions#login'
  # For details on the DSL available within this file, see http://guides.rubyonrails.org/routing.html
end
