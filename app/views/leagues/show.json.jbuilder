
json.id @league.id

json.short_name @league.short_name
json.name @league.name

json.games @league.games.sort_by{|g| [g.game_day.number, g.game_number.try(:to_i)] }.each do |game|
  json.id game.id
  json.game_number game.game_number
  json.game_day game.game_day.number
  json.date game.game_day.date
  json.start_time game.start_time
  json.home_team game.home_team_name
  json.guest_team game.guest_team_name
  json.nominated_referees game.nominated_referee_string

  json.result game.result

  json.link game_path(game.id, format: :json)
end
