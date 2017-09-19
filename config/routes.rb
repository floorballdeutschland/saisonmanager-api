Rails.application.routes.draw do
  apipie
  resources :arenas
  resources :clubs
  resources :games
  resources :game_day
  resources :game_operations
  resources :leagues do
    member do
      get :schedule
    end
  end
  resources :players
  resources :settings
  resources :teams
  resources :transfers
  resources :users

  post 'login' => 'sessions#login'
  # For details on the DSL available within this file, see http://guides.rubyonrails.org/routing.html
end
