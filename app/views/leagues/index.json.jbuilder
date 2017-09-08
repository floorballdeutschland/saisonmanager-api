json.array! @leagues do |league|
  json.id league.id

  json.operation_id league.game_operation_id
  json.game_operation @gos[league.game_operation_id]["name"]
  json.season league.season_id

  json.name league.name
  json.order_key league.order_key
  json.link league_path(league.id, format: :json)
end