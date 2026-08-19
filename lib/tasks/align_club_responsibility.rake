# lib/tasks/align_club_responsibility.rake
#
# Begleitet die Umstellung der Vereins-Zustaendigkeit auf den Landesverband
# (Club#main_game_operation_id).
#
# Vorher entschied ein zweites, am Verein gepflegtes Feld ueber die
# Zustaendigkeit: der Heimat-Eintrag in `clubs.game_operations_hash`. Es konnte
# dem Landesverband widersprechen, und weil das Bearbeiten-Formular es nicht
# zeigte, war der Widerspruch ueber die Oberflaeche nicht zu sehen. Aufgefallen
# ist das am ETV Hamburg, der mit Landesverband Hamburg in der Vereinsliste von
# Floorball Niedersachsen stand.
#
# ZWEI AUFGABEN, ZWEI TASKS
#
#   :report   Vergleicht die frueher gespeicherte Zustaendigkeit mit der jetzt
#             abgeleiteten und nennt jeden Verein, bei dem sie auseinanderfaellt.
#             Das ist das Tor vor dem Deploy: Jede Zeile ist ein Verein, der
#             seinen Verband wechselt, ohne dass es jemand angeordnet hat.
#             Rein lesend.
#
#   :fbh      Haengt den Floorball Bund Hamburg unter den Floorballverband
#             Schleswig-Holstein und raeumt dabei auf, was daran haengt.
#             Beleg unten.
#
# Der Bericht laeuft nur, solange `clubs.game_operations_hash` noch existiert.
# Mit dem Abbau der Spalte entfaellt er, dann gibt es keinen zweiten Wert mehr,
# gegen den man vergleichen koennte -- und genau das ist das Ziel.

namespace :clubs do
  desc 'Vergleicht gespeicherte und abgeleitete Zustaendigkeit je Verein (rein lesend).'
  task responsibility_report: :environment do
    wechsel = []
    ohne_zustaendigkeit = []

    Club.order(:id).each do |club|
      # Der frueher gepflegte Wert, direkt aus der Spalte: Club#main_game_operation_id
      # leitet inzwischen ab und taugt hier nicht als Vergleichsgroesse.
      alt = club.game_operations_hash
                .filter { |h| ActiveModel::Type::Boolean.new.cast(h['home_game_operation']) }
                .map { |h| h['game_operation_id'].to_i }.first
      neu = club.main_game_operation_id

      ohne_zustaendigkeit << [club, alt] if neu.nil?
      wechsel << [club, alt, neu] if neu.present? && alt.present? && alt != neu
    end

    namen = GameOperation.pluck(:id, :name).to_h
    verbaende = StateAssociation.pluck(:id, :name).to_h

    puts "=== Zustaendigkeit: gespeichert gegen abgeleitet ==="
    puts "Vereine: #{Club.count}\n\n"

    puts "-- Zustaendigkeit wechselt (#{wechsel.size}) --"
    puts '   Jede Zeile ist ein Verein, der den Verband wechselt. Entweder ist sein'
    puts '   Landesverband falsch gepflegt, oder der Wechsel ist gewollt.'
    wechsel.each do |club, alt, neu|
      puts "   #{club.id.to_s.ljust(5)} #{club.name.to_s.ljust(34)} " \
           "#{namen[alt] || alt} -> #{namen[neu] || neu} " \
           "(LV: #{verbaende[club.state_association_id]&.strip || '-'})"
    end

    puts "\n-- Kein Verband zustaendig (#{ohne_zustaendigkeit.size}) --"
    puts '   Diese Vereine sieht nur die Bundesebene. Drei Ursachen: kein'
    puts '   Landesverband, ein Landesverband den es nicht gibt, oder ein Verbund'
    puts '   ohne Spielbetrieb (siehe Club.unassigned).'
    ohne_zustaendigkeit.each do |club, alt|
      grund = if club.state_association_id.blank?
                'kein Landesverband'
              elsif verbaende.key?(club.state_association_id)
                'Verbund ohne Spielbetrieb'
              else
                "Landesverband #{club.state_association_id} existiert nicht"
              end
      puts "   #{club.id.to_s.ljust(5)} #{club.name.to_s.ljust(34)} " \
           "vorher #{namen[alt] || '-'} (#{grund})"
    end

    puts "\nOK: beide Wege sagen ueberall dasselbe." if wechsel.empty? && ohne_zustaendigkeit.empty?
  end

  # BELEG
  #
  # Der Floorball Bund Hamburg (LV) hat keinen eigenen Spielbetrieb. Nach der
  # Umstellung waere fuer seine sechs Vereine niemand zustaendig: `permissions`
  # kennen nur `game_operation_id`, ohne Spielbetrieb laesst sich niemand fuer
  # Hamburg berechtigen.
  #
  # Fuenf der sechs Vereine (28, 91, 200, 276, 292) trugen ohnehin den
  # Spielbetrieb des FLV-SH, der sechste (81, ETV Hamburg) den von Niedersachsen,
  # obwohl seine Mannschaften in den Saisons 15-17 fast ausschliesslich in der
  # Regionalliga Nord (FLV-SH) und in den Bundesligen spielen. Mit dem
  # Elternverband bleiben die fuenf, wo sie waren, und der sechste kommt dorthin,
  # wo er spielt.
  #
  # Entscheidung des Nutzers vom 19.08.2026: "FBH richtet sich ganz nach SH".
  # Damit sind zwei Folgen ausdruecklich gewollt:
  #
  #   - Die Postfaecher (heute dreimal info@floorball.hamburg, am Morgen des
  #     19.08. von Hand eingetragen) werden geleert. Sie sollen auf die des
  #     FLV-SH zurueckfallen, was sie nur bei leerem eigenem Feld tun
  #     (StateAssociation#effective_sbk_email und Geschwister).
  #   - Expresslizenz und Kursergebnis-Freigabe des FLV-SH greifen fuer Hamburg
  #     mit. Beides folgt aus der Vererbungsrichtung und laesst sich am Kind
  #     nicht abschalten.
  #
  # Die Vereins-Freigabe von Hamburg an den FLV-SH wird damit redundant; sie
  # nimmt der Nutzer selbst zurueck. Der Task laesst sie stehen: Eine ueberzaehlige
  # Freigabe zeigt keinen Verein doppelt an (siehe den Test dazu in club_test.rb).
  #
  # Auflösung ueber die Kuerzel und nicht ueber feste IDs, aus demselben Grund wie
  # Club::FALLBACK_STATE_ASSOCIATION_SHORT_NAME: In db/seeds.rb liegen unter
  # denselben IDs andere Verbaende.
  #
  # Dry-Run (Standard):
  #   bundle exec rails clubs:fbh_under_flvsh
  # Ausfuehren:
  #   bundle exec rails clubs:fbh_under_flvsh DRY_RUN=false
  desc 'Haengt den Floorball Bund Hamburg unter den FLV-SH. DRY_RUN=false zum Ausfuehren.'
  task fbh_under_flvsh: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'

    fbh = StateAssociation.find_by(short_name: 'FBH')
    flvsh = StateAssociation.find_by(short_name: 'FLV-SH')

    abort 'FBH nicht gefunden (short_name FBH)' if fbh.nil?
    abort 'FLV-SH nicht gefunden (short_name FLV-SH)' if flvsh.nil?

    puts "=== FBH unter FLV-SH #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="
    puts "#{fbh.name.strip} (#{fbh.id}) -> #{flvsh.name.strip} (#{flvsh.id})"
    puts "  parent_id:  #{fbh.parent_id.inspect} -> #{flvsh.id}"
    %i[sbk_email vsk_email rsk_email].each do |feld|
      puts "  #{"#{feld}:".ljust(11)} #{fbh[feld].inspect} -> nil (faellt auf den FLV-SH zurueck)"
    end

    ziel_go = GameOperation.find_by(state_association_id: flvsh.id)
    abort "FLV-SH (#{flvsh.id}) hat keinen Spielbetrieb -- sonst bleibt Hamburg herrenlos" if ziel_go.nil?

    betroffen = Club.where(state_association_id: fbh.id).order(:id)
    puts "\n  Vereine, deren Zustaendigkeit dadurch #{ziel_go.name} wird (#{betroffen.count}):"
    betroffen.each do |c|
      puts "    #{c.id.to_s.ljust(5)} #{c.name.to_s.ljust(30)} vorher #{c.main_game_operation_id.inspect}"
    end

    if dry_run
      puts "\nDRY RUN -- nichts geschrieben. Mit DRY_RUN=false ausfuehren."
      next
    end

    fbh.update!(parent: flvsh, sbk_email: nil, vsk_email: nil, rsk_email: nil)
    # settings/init cached die Verbaende 30 Minuten; ohne Leerung zeigt die
    # Oberflaeche den alten Baum weiter.
    Rails.cache.delete('settings/init')

    puts "\nGeschrieben. Zustaendig fuer Hamburg ist jetzt: " \
         "#{Club.where(state_association_id: fbh.id).first&.main_game_operation_id.inspect}"
  end
end
