Rails.application.routes.draw do
  # For details on the DSL available within this file, see https://guides.rubyonrails.org/routing.html
  apipie
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
  resources :transfers
  resources :users

  resources :license_fees

  get 'api/v1/ticker/:game_operation_id/:season_id/leagues', to: 'api#leagues'
  get 'api/v1/ticker/games/:id', to: 'api#games'
  get 'api/v1/upcoming_games', to: 'games#users_games'

  get 'internal/update_games/update_start_end', to: 'games#update_start_end'

  scope 'api' do
    scope 'v2' do
      # session handling
      post 'login' => 'sessions#login'
      post 'logout' => 'sessions#logout'

      resources :leagues do
        member do
          get 'game_days/current/schedule', to: 'leagues#current_schedule'
          get 'game_days/:game_day_number/schedule', to: 'leagues#game_day_schedule'
          get :schedule
          get :table
          get :scorer
          get :meta
          get :license_list
        end
      end

      get 'admin/leagues', to: 'leagues#admin_league_index'
      get 'admin/league_classes', to: 'leagues#admin_league_classes'

      post 'admin/leagues', to: 'leagues#admin_league_update'

      get 'admin/leagues/:id/teams', to: 'leagues#admin_league_team_index'
      get 'admin/leagues/:id/game_schedule', to: 'leagues#admin_game_schedule'
      get 'admin/leagues/:id/schedule_import_template', to:'leagues#admin_schedule_import_template'
      get 'admin/teams/:id', to: 'teams#admin_get_team'
      get 'admin/league/clubs/:callType/:id', to: 'clubs#admin_get_go_clubs'

      post 'admin/teams', to: 'teams#admin_team_update'

      get 'admin/game_operations/:id/clubs', to: 'game_operations#admin_club_index'

      get 'game_operations/:id/leagues/:season_id', to: 'game_operations#index_leagues'
      get 'game_operations/:id/leagues', to: 'game_operations#index_leagues'

      get 'referees/:id/games', to: 'referee#games'

      resources :games

      get 'init', to: 'settings#init'
    end
  end

  post 'login' => 'sessions#login'
  # For details on the DSL available within this file, see http://guides.rubyonrails.org/routing.html
end
