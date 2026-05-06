namespace :game_scans do
  desc 'Delete expired game scan files and records'
  task cleanup: :environment do
    expired = GameScan.where('expires_at < ?', Time.current)
    count = expired.count
    expired.each { |gs| gs.scan_file.purge if gs.scan_file.attached? }
    expired.destroy_all
    puts "Deleted #{count} expired game scan(s)."
  end
end
