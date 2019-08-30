json.array! @games do |game|
 json.id game.id
 json.league game.game_day.league.short_name
 json.game_number game.game_number
 json.date game.game_day.date
 json.start_time game.start_time
end
