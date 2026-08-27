require 'test_helper'

# Stehen nach dem Zusammenfuehren zwei Heimatvereine offen, entschied allein das juengere
# `created_at`. Die Fehlanlage einer Dublette traegt aber regelmaessig genau das juengere
# Datum und nie eine Lizenz, weil sie ueberhaupt nur entstand, weil das echte Profil nicht
# gefunden wurde. Gemeldet am 27.08.2026 an Spieler 4876: bei UHC Weissenfels angelegt,
# dort nie lizenziert, alle sechs Lizenzen bei UHC Elster.
#
# Die Gegenprobe auf Produktion widerlegt die naheliegende Regel "der Master bestimmt die
# Vereinshistorie": Bei 161 der 1238 Merge-Ziele stammt der offene Heimatverein aus der
# Dublette, und in 126 dieser Faelle bestaetigt die zuletzt erteilte Lizenz genau diesen
# Verein -- gegen nur 9 fuer den Master. Der Master ist die kleinste ID, nicht der bessere
# Datensatz. Entschieden wird deshalb nach Beleg, nicht nach Herkunft.
class PlayerMergeLicenseEvidenceTest < ActiveSupport::TestCase
  setup do
    create(:setting, current_season_id: '18')
    @user = create(:user)
  end

  # Bewusst `valid_until.blank?` und nicht `open_home_club_entries`: Dessen
  # Stichtagsvergleich ist tagesgenau, ein heute geschlossener Eintrag gilt dort bis
  # Mitternacht weiter. Massgeblich ist der gespeicherte Zustand.
  def offene_heimat(player)
    offen = Array(player.clubs).select do |c|
      ActiveModel::Type::Boolean.new.cast(c['home_club']) && c['valid_until'].blank?
    end
    offen.map { |c| c['club_id'] }
  end

  def heimat(club, created_at)
    { 'club_id' => club.id, 'home_club' => true, 'created_at' => created_at.iso8601 }
  end

  def lizenz(team, erteilt_am, status: License::APPROVED)
    { 'team_id' => team.id, 'season_id' => '18',
      'history' => [{ 'license_status_id' => status, 'created_at' => erteilt_am.iso8601 }] }
  end

  test 'die zuletzt erteilte Lizenz schlaegt das juengere Datum der Fehlanlage' do
    elster = create(:club, name: 'UHC Elster')
    weissenfels = create(:club, name: 'UHC Weissenfels')
    elster_team = create(:team, club: elster)

    master = create(:player, clubs: [heimat(elster, 5.years.ago)],
                             licenses: [lizenz(elster_team, 1.year.ago)])
    dublette = create(:player, clubs: [heimat(weissenfels, 2.years.ago)])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_equal [elster.id], offene_heimat(master),
                 'der belegte Verein bleibt offen, obwohl die Fehlanlage juenger ist'
  end

  # Die Umkehrung, und auf Produktion der weit haeufigere Fall (126 zu 9): Die Dublette ist
  # das aktuelle Profil, der Master der abgelegte Altbestand.
  test 'die Lizenz haelt auch den Verein der Dublette, wenn der Master aelter belegt ist' do
    alt = create(:club)
    aktuell = create(:club)
    aktuell_team = create(:team, club: aktuell)

    master = create(:player, clubs: [heimat(alt, 10.years.ago)])
    dublette = create(:player, clubs: [heimat(aktuell, 1.year.ago)],
                               licenses: [lizenz(aktuell_team, 3.months.ago)])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_equal [aktuell.id], offene_heimat(master)
  end

  # Der Beleg kommt aus dem GEMEINSAMEN Lizenzbestand. Traegt nur die Dublette die Lizenz,
  # muss sie trotzdem fuer den Verein des Masters zaehlen koennen -- deshalb fuehrt
  # `merge_into!` die Lizenzen vor den Vereinen zusammen.
  test 'eine Lizenz der Dublette belegt auch einen Verein des Masters' do
    elster = create(:club)
    fehlanlage = create(:club)
    elster_team = create(:team, club: elster)

    master = create(:player, clubs: [heimat(elster, 5.years.ago)])
    dublette = create(:player, clubs: [heimat(fehlanlage, 1.year.ago)],
                               licenses: [lizenz(elster_team, 6.months.ago)])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_equal [elster.id], offene_heimat(master)
  end

  test 'bei mehreren erteilten Lizenzen zaehlt die zuletzt erteilte' do
    frueher = create(:club)
    spaeter = create(:club)
    frueher_team = create(:team, club: frueher)
    spaeter_team = create(:team, club: spaeter)

    master = create(:player, clubs: [heimat(spaeter, 5.years.ago)],
                             licenses: [lizenz(spaeter_team, 2.months.ago)])
    dublette = create(:player, clubs: [heimat(frueher, 1.year.ago)],
                               licenses: [lizenz(frueher_team, 3.years.ago)])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_equal [spaeter.id], offene_heimat(master)
  end

  # Nur `erteilt` belegt. Ein Antrag, eine Ablehnung oder eine geloeschte Lizenz sagen
  # nichts darueber, wo jemand tatsaechlich spielberechtigt war.
  test 'ein blosser Lizenzantrag ist kein Beleg' do
    alt = create(:club)
    neu = create(:club)
    alt_team = create(:team, club: alt)

    master = create(:player, clubs: [heimat(alt, 5.years.ago)],
                             licenses: [lizenz(alt_team, 1.month.ago, status: License::REQUESTED)])
    dublette = create(:player, clubs: [heimat(neu, 1.year.ago)])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_equal [neu.id], offene_heimat(master), 'ohne Beleg entscheidet weiter das Datum'
  end

  # Eine spaeter wegen eines Transfers ungueltig gewordene Lizenz belegt weiterhin, dass die
  # Person damals fuer diesen Verein spielberechtigt war. Massgeblich ist der Zeitpunkt der
  # Erteilung, nicht der heutige Status.
  test 'eine spaeter ungueltig gewordene Lizenz belegt den Verein weiterhin' do
    elster = create(:club)
    fehlanlage = create(:club)
    elster_team = create(:team, club: elster)
    entwertet = lizenz(elster_team, 2.years.ago)
    entwertet['history'] << { 'license_status_id' => License::TRANSFER,
                              'created_at' => 1.year.ago.iso8601 }

    master = create(:player, clubs: [heimat(elster, 5.years.ago)], licenses: [entwertet])
    dublette = create(:player, clubs: [heimat(fehlanlage, 6.months.ago)])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_equal [elster.id], offene_heimat(master)
  end

  # Der Alltagsfall: Wechsel nach der letzten Lizenz. Der Beleg nennt einen Verein, der gar
  # nicht zur Auswahl steht, und darf dann nichts entscheiden.
  test 'ein Beleg auf einen dritten Verein laesst das Datum entscheiden' do
    dritter = create(:club)
    alt = create(:club)
    neu = create(:club)
    dritter_team = create(:team, club: dritter)

    master = create(:player, clubs: [heimat(alt, 5.years.ago)],
                             licenses: [lizenz(dritter_team, 1.month.ago)])
    dublette = create(:player, clubs: [heimat(neu, 1.year.ago)])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_equal [neu.id], offene_heimat(master)
  end

  # Der Beleg wirkt nur innerhalb der Stufe "echter Verein". Eine Ablage kann er ohnehin
  # nicht gewinnen lassen, wohl aber den echten Verein, aus dem heraus jemand nach Art. 21
  # DSGVO widersprochen hat. Der Widerspruch bleibt darueber.
  test 'der Beleg hebt einen Widerspruch nicht auf' do
    sperrung = create(:club, name: 'Ablage Sperrung')
    verein = create(:club, name: 'UHC Elster')
    verein_team = create(:team, club: verein)

    master = create(:player, clubs: [heimat(sperrung, 5.years.ago)],
                             licenses: [lizenz(verein_team, 1.month.ago)])
    dublette = create(:player, clubs: [heimat(verein, 1.year.ago)])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_equal [sperrung.id], offene_heimat(master),
                 'der Widerspruch gewinnt gegen jeden Beleg'
  end

  # Gemischte UTC-Offsets kehren einen reinen Zeichenketten-Vergleich still um:
  # "…T23:59:00+02:00" liegt lexikalisch VOR "…T18:25:00+00:00", ist aber der spaetere
  # Zeitpunkt. Verglichen wird deshalb ueber geparste Zeitpunkte.
  test 'gemischte Zeitzonen-Offsets kehren die Auswahl nicht um' do
    frueher = create(:club)
    spaeter = create(:club)
    frueher_team = create(:team, club: frueher)
    spaeter_team = create(:team, club: spaeter)

    alt = { 'team_id' => frueher_team.id, 'season_id' => '18',
            'history' => [{ 'license_status_id' => License::APPROVED,
                            'created_at' => '2026-08-12T23:59:00.000+02:00' }] }
    neu = { 'team_id' => spaeter_team.id, 'season_id' => '18',
            'history' => [{ 'license_status_id' => License::APPROVED,
                            'created_at' => '2026-08-12T22:25:00.000+00:00' }] }

    master = create(:player, clubs: [heimat(spaeter, 5.years.ago)], licenses: [alt, neu])
    dublette = create(:player, clubs: [heimat(frueher, 1.year.ago)])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_equal [spaeter.id], offene_heimat(master),
                 '22:25 UTC ist spaeter als 23:59+02:00, auch wenn die Zeichenkette es umdreht'
  end

  test 'ein unlesbarer Zeitstempel kippt die Auswahl nicht' do
    alt = create(:club)
    neu = create(:club)
    alt_team = create(:team, club: alt)
    kaputt = { 'team_id' => alt_team.id, 'season_id' => '18',
               'history' => [{ 'license_status_id' => License::APPROVED,
                               'created_at' => 'kein Datum' }] }

    master = create(:player, clubs: [heimat(alt, 5.years.ago)], licenses: [kaputt])
    dublette = create(:player, clubs: [heimat(neu, 1.year.ago)])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_equal [neu.id], offene_heimat(master)
  end

  test 'eine Lizenz auf ein geloeschtes Team ergibt keinen Beleg' do
    alt = create(:club)
    neu = create(:club)
    verwaist = { 'team_id' => 0, 'season_id' => '18',
                 'history' => [{ 'license_status_id' => License::APPROVED,
                                 'created_at' => 1.month.ago.iso8601 }] }

    master = create(:player, clubs: [heimat(alt, 5.years.ago)], licenses: [verwaist])
    dublette = create(:player, clubs: [heimat(neu, 1.year.ago)])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_equal [neu.id], offene_heimat(master)
  end

  # Der Beleg entscheidet nur zwischen mehreren OFFENEN Heimatvereinen. Er darf keinen
  # abgeschlossenen Eintrag wieder aufmachen und keinen einzelnen offenen schliessen.
  test 'ein einzelner offener Heimatverein bleibt unberuehrt' do
    aktuell = create(:club)
    frueher = create(:club)
    frueher_team = create(:team, club: frueher)

    master = create(:player, clubs: [heimat(aktuell, 1.year.ago)],
                             licenses: [lizenz(frueher_team, 5.years.ago)])
    dublette = create(:player, clubs: [{ 'club_id' => frueher.id, 'home_club' => true,
                                        'created_at' => 8.years.ago.iso8601,
                                        'valid_until' => 6.years.ago.iso8601 }])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_equal [aktuell.id], offene_heimat(master)
  end
end
