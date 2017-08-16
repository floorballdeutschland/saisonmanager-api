
json.id @league.id
json.order_key @league.order_key
json.season_id @league.season_id
json.league_category @league.league_category
json.league_class @league.league_class
json.league_system @league.league_system
json.male !@league.female

json.short_name @league.short_name
json.name @league.name

json.games @league.games.each do |game|
  json.id game.id
  json.home_team game.home_team_name
  json.guest_team game.guest_team_name
end
