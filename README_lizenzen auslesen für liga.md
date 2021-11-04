l=League.find 949

teams = Team.where(league_id: l.id).or(Team.where("#{l.id} = ANY (cup_leagues)")).order(:name)

team_ids = teams.map(&:id)


team_licenses = {}
teams.each do |team|
 team_licenses[team.id.to_s] = Player.find_by_team_id team.id
end



player = 

status = {"1"=> "erteilt", "2"=> "beantragt", "3"=> "abgelehnt", "4"=> "gelöscht", "5"=> "Löschung beantragt", "6"=> "Transfer", "7"=> "ignoriert"}
teams.each do |team|

puts team.name
team_licenses[team.id.to_s].each do |player|
  license = player.licenses.select{|l| l["team_id"]==team.id.to_s}.first

  last_status = license["history"].last
  last_status_id = last_status["license_status_id"]
  last_status_code = status[last_status_id.to_s]

  approved_at = if last_status_id == 1
    last_status["created_at"].to_datetime.strftime("%d.%m.%Y %H:%M:%S")
  end
  requested_at = license["history"].select{|lh| lh["license_status_id"]==2}.last["created_at"].to_datetime.strftime("%d.%m.%Y %H:%M:%S")

  puts "#{player.last_name},#{player.first_name},#{last_status_code},#{requested_at},#{approved_at ? approved_at : '-'},#{team.name}"
end

nil
end

license = player.licenses.select{|l| l["team_id"]==team.id.to_s}