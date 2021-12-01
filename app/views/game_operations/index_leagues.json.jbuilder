json.array! @leagues do |league|
 json.id league.id
 json.game_operation_id league.game_operation_id
 json.league_category_id league.league_category_id
 json.league_class_id league.league_class_id
 json.league_system_id league.league_system_id
 json.name league.name
 json.female league.female
 json.enable_scorer league.enable_scorer
 json.short_name league.short_name
 json.season_id league.season_id
 json.order_key league.order_key
 json.game_day_numbers league.game_days.pluck(:number).uniq.sort
end
