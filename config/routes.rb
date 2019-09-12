Rails.application.routes.draw do
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
      get :meta
    end
  end
  resources :players
  resources :settings
  resources :teams
  resources :transfers
  resources :users

  resources :license_fees

  get 'api/v1/ticker/:game_operation_id/:season_id/leagues', to: 'api#leagues'
  get 'api/v1/ticker/games/:id', to: 'api#games'
  get 'api/v1/upcoming_games', to: 'games#users_games'

  get 'internal/update_games/update_start_end', to: 'games#update_start_end'

  post 'login' => 'sessions#login'
  # For details on the DSL available within this file, see http://guides.rubyonrails.org/routing.html
end
