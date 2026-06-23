# frozen_string_literal: true

module LegacyImport
  # Kuratierte Mappings zwischen den Controlled-Vocabularies des Altsystems
  # (MariaDB, Tabellen `global_*`) und dem neuen Rails-Modell bzw. den
  # `Setting`-JSONB-Hashes.
  #
  # Siehe produktivdaten/MAPPING_KONZEPT_altdaten_2010-2014.md, §3–§4.
  module Vocab
    # Alt `global_saison.id_saison` entspricht 1:1 der neuen `season_id`
    # (15 = 2023/24 ⇒ rückwärts: 5 = 2013/14 … 1 = 2009/10). Kein Offset nötig.
    # season_id ist in `leagues` ein String.
    def self.season_id(old_id_saison)
      old_id_saison.to_s
    end

    # global_klasse.id_klasse → leagues.league_class_id (String-Key in
    # Setting.league_classes). Jugend/Damen haben keinen 1:1-Key und werden
    # über age_group / female abgebildet (siehe klasse_extras).
    KLASSE_TO_CLASS = {
      10 => '1fbl', # 1. Bundesliga
      20 => '2fbl', # 2. Bundesliga
      30 => 'rl',   # Regionalliga
      40 => 'vl',   # Verbandsliga
      50 => 'll'    # Landesliga
    }.freeze

    # Jugendklassen (global_klasse.jugend = 1): id → age_group-Label.
    KLASSE_AGE_GROUP = (200..360).step(10).each_with_object({}) do |id, h|
      # 200=U23, 210=U22, … 360=U7  (Schrittweite 10, fallend ab U23)
      h[id] = "U#{23 - ((id - 200) / 10)}"
    end.merge(370 => 'Ü30').freeze

    # global_kategorie.id_kategorie wird 1:1 als leagues.league_category_id
    # übernommen (1=GF, 2=KF, 3=Pokal KF, 4=Pokal GF, 5=Mixed, 100=DM, 101=DM
    # Quali, 102=GF DM). WICHTIG: Das alte Klein-Int-Schema MUSS erhalten bleiben –
    # League#forfait_goals / #period_count_normal_game / #league_type branchen für
    # legacy_league genau darauf (z. B. {1,4,102} = Großfeld). Der Bestand der
    # bereits importierten Alt-Saisons (6–16) nutzt dieselben Werte.

    # Alt-Verband-ID == neue GameOperation-ID (Name/Kürzel deckungsgleich);
    # Schlüssel ist der Tabellen-Präfix aus global_verband.pfad.
    VERBAND_GO = {
      'fvd' => 1, 'fvn' => 2, 'fvbb' => 3, 'fvbw' => 4, 'flvsh' => 5,
      'sbkost' => 6, 'fvh' => 8, 'fvb' => 9, 'nwuv' => 10
    }.freeze

    # global_verband.id → Tabellen-Präfix (für begegnung.id_verband_team1/2).
    VERBAND_ID_PATH = {
      1 => 'fvd', 2 => 'fvn', 3 => 'fvbb', 4 => 'fvbw', 5 => 'flvsh',
      6 => 'sbkost', 8 => 'fvh', 9 => 'fvb', 10 => 'nwuv'
    }.freeze

    # global_spielsystem.id_spielsystem → Punkte-/Tabellenmodus.
    # (Nicht zu verwechseln mit dem neuen league_system_id = Runden-Struktur.)
    SPIELSYSTEM_TABLE_MODUS = {
      1 => 'three_point', # 3 Punkte
      2 => 'two_point',   # 2 Punkte
      4 => 'other'        # Anderes
    }.freeze

    # global_strafe.id_strafe → penalty_id (Setting.penalties, Schema nach
    # fix_imported_game_format.rake: 1=2', 3=5', 4=10', 7/8/9=Spielstrafe).
    STRAFE_TO_PENALTY_ID = {
      1 => 1, # 2'
      2 => 3, # 5'
      3 => 4, # 10'
      4 => 7, # M I  → Spielstrafe 1
      5 => 8, # M II → Spielstrafe 2
      6 => 9  # M III→ Spielstrafe 3
    }.freeze

    # global_lizenzstatus.id_lizenzstatus → License-Status (License::NAMES).
    LIZENZSTATUS = {
      1 => 'erteilt',
      2 => 'beantragt',
      3 => 'abgelehnt',
      4 => 'gelöscht',
      5 => 'loeschung_beantragt',
      6 => 'transfer'
    }.freeze

    # id_lizenzstatus → license_status_id (License-Konstanten) für die
    # licenses-History. Glücksfall: Alt 1–6 entspricht 1:1 den neuen IDs.
    LIZENZSTATUS_TO_STATUS_ID = {
      1 => License::APPROVED,
      2 => License::REQUESTED,
      3 => License::DENIED,
      4 => License::DELETED,
      5 => License::DELETE_REQUESTED,
      6 => License::TRANSFER
    }.freeze

    # Liefert league_class_id + Zusatzattribute (age_group/female) für eine
    # Alt-Klasse. Unbekannte Klassen → class_id nil + :unmapped-Flag, damit der
    # Dry-Run sie reportet, statt still falsch zu mappen.
    def self.klasse_attrs(id_klasse, klasse_name = nil)
      id = id_klasse.to_i
      return { league_class_id: KLASSE_TO_CLASS[id] } if KLASSE_TO_CLASS.key?(id)

      if KLASSE_AGE_GROUP.key?(id)
        return { league_class_id: 'll', age_group: KLASSE_AGE_GROUP[id] }
      end

      female = klasse_name.to_s.match?(/dam|frau|female/i) || nil
      { league_class_id: nil, female:, unmapped: id }.compact
    end

    # Alt-Kategorie-ID 1:1 als league_category_id (String) übernehmen; 0/leer → nil.
    def self.kategorie_attrs(id_kategorie)
      id = id_kategorie.to_i
      { league_category_id: id.positive? ? id.to_s : nil }
    end
  end
end
