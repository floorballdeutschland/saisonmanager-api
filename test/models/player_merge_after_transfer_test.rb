require 'test_helper'

# Eine Zusammenlegung am Tag eines Vereinswechsels schloss den frisch gesetzten
# Heimatverein und liess das Profil ganz ohne Zugehoerigkeit zurueck.
#
# Spieler 1047 auf Produktion, 09.09.2026: Der Landesverband genehmigt um 11:30 den
# Transferantrag von den Berlin Rockets zum SSV Rapid -- der Rockets-Eintrag bekommt sein
# Enddatum, der Rapid-Eintrag wird angehaengt. Um 11:37 fuehrt derselbe Benutzer eine
# Dublette in das Profil. `_close_surplus_home_clubs` sieht dabei ZWEI offene
# Heimatvereine, weil `open_home_club_entries` tagesgenau vergleicht und den sieben
# Minuten zuvor beendeten Rockets-Eintrag bis Mitternacht weiter als laufend zaehlt. Der
# Lizenzbeleg entscheidet daraufhin fuer die Rockets -- die Lizenzen liegen dort, die des
# neuen Vereins war um 11:33 erst BEANTRAGT --, also wird Rapid geschlossen. Behalten wird
# ein Eintrag, der schon geschlossen war. Ergebnis: `home_club_entry` = nil, das Profil
# steht in keiner Vereinsliste, ist nicht lizenzierbar und nicht transferierbar.
class PlayerMergeAfterTransferTest < ActiveSupport::TestCase
  setup do
    create(:setting, current_season_id: '18')
    @user = create(:user)
  end

  def offene_heimat(player)
    Array(player.clubs).select do |c|
      ActiveModel::Type::Boolean.new.cast(c['home_club']) && c['valid_until'].blank?
    end
  end

  # Die Heimat-Eintraege, die WIRKLICH noch laufen: ohne Enddatum oder mit einem Ende nach
  # heute. Ein heute beendeter Eintrag zaehlt hier nicht mehr mit -- anders als bei
  # `open_home_club_entries`, das bis Mitternacht tagesgenau vergleicht.
  def laufende_heimat(player)
    Array(player.clubs).select do |c|
      next false unless ActiveModel::Type::Boolean.new.cast(c['home_club'])

      c['valid_until'].blank? || Date.parse(c['valid_until'].to_s) > Date.current
    end
  end

  def heimat(club, created_at, valid_until: nil)
    eintrag = { 'club_id' => club.id, 'home_club' => true, 'created_at' => created_at.iso8601 }
    eintrag['valid_until'] = valid_until.iso8601 if valid_until
    eintrag
  end

  def lizenz(team, erteilt_am, status: License::APPROVED)
    { 'team_id' => team.id, 'season_id' => '18',
      'history' => [{ 'license_status_id' => status, 'created_at' => erteilt_am.iso8601 }] }
  end

  # Der Bestand von Spieler 1047, Zeile fuer Zeile: alter Verein heute beendet, neuer
  # Verein offen, die einzige erteilte Lizenz beim alten Verein.
  def profil_nach_transfer(alt, neu, alt_team, wechsel_um)
    create(:player,
           clubs: [heimat(alt, 10.years.ago, valid_until: wechsel_um), heimat(neu, wechsel_um)],
           licenses: [lizenz(alt_team, 10.years.ago)])
  end

  test 'der heute vollzogene Wechsel ueberlebt die Zusammenlegung' do
    rockets = create(:club, name: 'Berlin Rockets')
    rapid = create(:club, name: 'SSV Rapid')
    rockets_team = create(:team, club: rockets)
    rapid_team = create(:team, club: rapid)
    wechsel_um = 7.minutes.ago

    master = profil_nach_transfer(rockets, rapid, rockets_team, wechsel_um)
    # Die Lizenz beim neuen Verein ist am Tag des Wechsels erst beantragt und belegt
    # deshalb nichts -- genau deshalb gewann der alte Verein den Beleg.
    dublette = create(:player, clubs: [heimat(rapid, 3.days.ago)],
                               licenses: [lizenz(rapid_team, 4.minutes.ago, status: License::REQUESTED)])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_equal [rapid.id], offene_heimat(master).map { |c| c['club_id'] },
                 'der frisch gesetzte Heimatverein muss offen bleiben'
    assert_equal rapid.id, master.home_club_entry&.dig('club_id')
    assert_equal rapid.id, master.home_club(Date.current)&.id
  end

  # Der zweite Schaden desselben Zugriffs, hier ohne Lizenz: Dann entscheidet das Datum und
  # haelt den frischen Eintrag -- der heute
  # beendete stand trotzdem in `offen` und wurde mitgeschlossen -- `valid_until = Time.now`
  # ueberschrieb dabei den Zeitpunkt, den der Transfer gesetzt hatte. Der Vorgang von 11:30
  # truege danach 11:37: Die Zusammenlegung haette den Wechsel umdatiert.
  test 'die Zusammenlegung datiert den Transfer nicht um' do
    alt = create(:club)
    neu = create(:club)
    fehlanlage = create(:club)
    wechsel_um = 7.minutes.ago

    master = create(:player, clubs: [heimat(alt, 10.years.ago, valid_until: wechsel_um),
                                     heimat(neu, wechsel_um)])
    dublette = create(:player, clubs: [heimat(fehlanlage, 2.years.ago)])

    dublette.merge_into!(master, @user.id)
    master.reload

    geschlossen = master.clubs.find { |c| c['club_id'] == alt.id }
    assert_equal wechsel_um.iso8601, geschlossen['valid_until']
    assert_nil geschlossen['valid_set_by'],
               'der Transfer hat den Eintrag geschlossen, nicht die Zusammenlegung'
  end

  # Gegenprobe: Der Riegel darf die Entdoppelung nicht ueberhaupt abschalten. Stehen neben
  # dem heute beendeten Eintrag zwei WIRKLICH laufende Heimatvereine, bleibt genau einer.
  test 'zwei laufende Heimatvereine werden weiter entdoppelt' do
    alt = create(:club)
    neu = create(:club)
    fehlanlage = create(:club)
    wechsel_um = 7.minutes.ago

    master = create(:player, clubs: [heimat(alt, 10.years.ago, valid_until: wechsel_um),
                                     heimat(neu, wechsel_um)])
    dublette = create(:player, clubs: [heimat(fehlanlage, 2.years.ago)])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_equal([neu.id], offene_heimat(master).map { |c| c['club_id'] })
  end

  # Ein Ende in der ZUKUNFT laeuft noch und zaehlt deshalb weiter mit -- sonst haette der
  # Riegel ein befristetes Zweitspielrecht als Heimat aus der Entdoppelung genommen.
  test 'ein Ende in der Zukunft zaehlt als laufend' do
    befristet = create(:club)
    unbefristet = create(:club)

    master = create(:player, clubs: [heimat(befristet, 1.year.ago, valid_until: 60.days.from_now)])
    dublette = create(:player, clubs: [heimat(unbefristet, 2.years.ago)])

    dublette.merge_into!(master, @user.id)
    master.reload

    laufend = laufende_heimat(master)
    assert_equal [befristet.id], laufend.map { |c| c['club_id'] },
                 "genau ein laufender Heimatverein, gefunden: #{laufend.inspect}"
  end

  # Die Nachbedingung, die am 09.09.2026 gefehlt hat, fuer sich genommen: Eine
  # Zusammenlegung darf ein Profil nie ohne Heimatverein zuruecklassen.
  test 'nach der Zusammenlegung bleibt mindestens ein Heimatverein' do
    alt = create(:club)
    neu = create(:club)
    alt_team = create(:team, club: alt)

    master = profil_nach_transfer(alt, neu, alt_team, 7.minutes.ago)
    dublette = create(:player, clubs: [heimat(neu, 3.days.ago)])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_not_nil master.home_club_entry, 'das Profil haette keinen Heimatverein mehr'
    assert_not_empty offene_heimat(master)
  end
end
