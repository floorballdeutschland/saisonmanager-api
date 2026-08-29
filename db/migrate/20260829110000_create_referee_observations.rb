# Beobachtungsbogen des Schiedsrichtercoaches (Ablösung des Microsoft-Forms
# „Referee Coaching Form / Beobachtungsformular"). Aufbau wie das Vereins-
# Feedback (CreateRefereeFeedbacks), mit zwei Unterschieden: Der Bogen bewertet
# jede Person des Gespanns einzeln (Kindtabelle) und ist für die beobachtete
# Person selbst sichtbar.
class CreateRefereeObservations < ActiveRecord::Migration[7.2]
  def change
    create_table :referee_observations do |t|
      t.references :game, null: false, foreign_key: true
      # Der beobachtende Coach als Referee-PK. Nicht nullable: ohne Coach gibt es
      # keinen Bogen. Die Zuordnung überlebt eine Zusammenführung, weil
      # Referee#merge_into! die Spalte mitzieht.
      t.bigint :coach_id, null: false
      # Gesetzt, wenn der Coach für dieses Spiel angesetzt war. Leer, wenn er das
      # Spiel im Verbands-Scope selbst gewählt hat (Spielbetrieb ohne
      # personenscharfe Ansetzung).
      t.bigint :referee_assignment_id
      # Denormalisiert beim Anlegen: trägt das Verbands-Scoping der Lesesicht
      # ohne Join über game_day → league.
      t.bigint :game_operation_id, null: false
      t.bigint :created_by_user_id, null: false
      # Klartext-Snapshot, analog referee_feedbacks.referee_names.
      t.string :coach_name

      # Fragen 5, 11, 13, 15, 17, 18, 19 des Formulars. Im Original alle Pflicht;
      # erzwungen wird das in der Modell-Validierung, die Spalten bleiben
      # nullable, damit ein späteres Lockern keine Migration braucht.
      t.text :match_description
      t.text :stick_play_comment
      t.text :physical_play_comment
      t.text :penalty_line_comment
      t.text :game_management_comment
      t.text :other_matters
      t.text :final_comments

      # Zeile „Pair / Team" der fünf Bewertungsmatrizen (Fragen 10, 12, 14, 16, 20).
      # Sie gehört an den Bogen und nicht in die personenbezogene Kindtabelle:
      # das Gespann ist keine Person.
      t.integer :pair_stick_play_rating
      t.integer :pair_physical_play_rating
      t.integer :pair_penalty_line_rating
      t.integer :pair_game_management_rating
      t.integer :pair_overall_rating

      # 'visible' (Standard) oder 'hidden' (von Admin/RSK zurückgenommen).
      t.string :status, null: false, default: 'visible'
      t.datetime :submitted_at, null: false

      t.timestamps
    end

    # Ein Bogen je Spiel und Coach – eine zweite Abgabe liefert den ersten zurück.
    add_index :referee_observations, %i[game_id coach_id], unique: true
    add_index :referee_observations, :coach_id
    add_index :referee_observations, :game_operation_id

    create_table :referee_observation_ratings do |t|
      t.references :referee_observation, null: false, foreign_key: true, index: { name: 'index_ror_on_observation' }
      t.bigint :referee_id, null: false
      # Klartext-Snapshot, überlebt Zusammenführung und Löschung.
      t.string :referee_name
      # 1 oder 2 – Slot im Gespann, entspricht „Referee 1"/„Referee 2" im Formular.
      t.integer :position, null: false

      t.integer :stick_play_rating
      t.integer :physical_play_rating
      t.integer :penalty_line_rating
      t.integer :game_management_rating
      t.integer :overall_rating

      t.timestamps
    end

    add_index :referee_observation_ratings, %i[referee_observation_id referee_id],
              unique: true, name: 'index_ror_on_observation_and_referee'
    add_index :referee_observation_ratings, :referee_id
  end
end
