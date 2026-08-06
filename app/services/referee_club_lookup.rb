# Ordnet einen Vereinsnamen aus der FD-Schiedsrichterliste einem Club zu.
#
# Die Reihenfolge ist verbindlich und nicht beliebig:
#
#   1. Alias-Liste (config/referee_club_aliases.yml)
#   2. exakt clubs.name
#   3. exakt clubs.long_name
#   4. exakt clubs.short_name
#   5. normalisiert (ohne „e.V.", ohne Satzzeichen) gegen name, dann long_name
#
# Der Alias muss vorn stehen, weil ein exakter Namenstreffer sonst auf eine
# Dublette zeigen kann: „SVGO Bremen" existierte kurzzeitig als eigener Verein
# neben dem echten „SV Grambke-Oslebshausen". Genau so hingen im Juli 2025 23
# Schiedsrichter am Duplikat „SV Espenau Rangers" statt am Master.
#
# Deaktivierte Vereine bleiben bewusst suchbar: Manche Ziele sind legitim
# deaktiviert (DJK Hansa Dortmund), und ein historischer Schiedsrichter gehört
# an seinen historischen Verein.
#
# Mehrdeutige normalisierte Treffer werden NICHT geraten, sondern als
# :ambiguous gemeldet — lieber kein Verein als der falsche.
class RefereeClubLookup
  Result = Struct.new(:club_id, :match_type, keyword_init: true) do
    def matched? = club_id.present?
  end

  ALIAS_PATH = Rails.root.join('config/referee_club_aliases.yml')

  # Die Excel führt im Vereinsfeld teilweise einen Status statt eines Vereins.
  # Ohne diese Liste sucht der Import nach einem Verein namens „Karriere
  # beendet" (51 Beendete und 4 Aktive, Stand Juli 2025).
  PLACEHOLDERS = ['karriere beendet', 'ohne verein', 'kein verein', '-'].freeze

  attr_reader :missing_alias_targets

  def initialize(clubs: Club.all, aliases: self.class.load_aliases)
    @clubs = clubs.to_a
    build_indexes
    @aliases = normalize_alias_keys(aliases)
    @missing_alias_targets = @aliases.values.uniq.reject { |id| @clubs_by_id.key?(id) }
  end

  def self.load_aliases
    return {} unless File.exist?(ALIAS_PATH)

    YAML.safe_load_file(ALIAS_PATH) || {}
  end

  # Nur zum Normalisieren des Vergleichs, nie zum Anzeigen: „e.V." raus,
  # Satzzeichen raus, Mehrfach-Leerzeichen zusammen. Jahreszahlen bleiben
  # stehen, sie unterscheiden Vereine („TSV Calw 1846").
  #
  # Punkte werden ersatzlos entfernt, alle anderen Zeichen werden zu einem
  # Leerzeichen. Sonst zerfällt eine Abkürzung mit Punkten in Einzelbuchstaben
  # („T.S.V. Hochdahl" ergäbe „t s v hochdahl" statt „tsv hochdahl"), während
  # ein Bindestrich weiterhin Wörter trennen muss („Bochum-Altenbochum").
  def self.normalize(value)
    value.to_s.downcase
         .gsub('ß', 'ss')
         .gsub(/e\.\s*v\.?/, ' ')
         .gsub(/\be\s*v\b/, ' ')
         .delete('.')
         .gsub(/[^a-zäöü0-9]+/, ' ')
         .squeeze(' ')
         .strip
  end

  def call(name)
    key = name.to_s.strip.downcase
    return Result.new(club_id: nil, match_type: :blank) if key.empty?
    return Result.new(club_id: nil, match_type: :placeholder) if PLACEHOLDERS.include?(key)

    alias_id = @aliases[key]
    return Result.new(club_id: alias_id, match_type: :alias) if alias_id && @clubs_by_id.key?(alias_id)

    exact_match(key) || normalized_match(name) || Result.new(club_id: nil, match_type: :none)
  end

  private

  def build_indexes
    @clubs_by_id = @clubs.index_by(&:id)
    @by_name  = index_exact(:name)
    @by_long  = index_exact(:long_name)
    @by_short = index_exact(:short_name)
    @by_normalized_name = index_normalized(:name)
    @by_normalized_long = index_normalized(:long_name)
  end

  def index_exact(attribute)
    @clubs.reject { |c| c.public_send(attribute).blank? }
          .group_by { |c| c.public_send(attribute).to_s.strip.downcase }
  end

  def index_normalized(attribute)
    @clubs.reject { |c| c.public_send(attribute).blank? }
          .group_by { |c| self.class.normalize(c.public_send(attribute)) }
  end

  def normalize_alias_keys(aliases)
    aliases.to_h { |name, id| [name.to_s.strip.downcase, id.to_i] }
  end

  def exact_match(key)
    { name: @by_name, long_name: @by_long, short_name: @by_short }.each do |match_type, index|
      candidates = index[key]
      next if candidates.blank?

      return Result.new(club_id: candidates.first.id, match_type: match_type) if candidates.one?

      return Result.new(club_id: nil, match_type: :ambiguous)
    end
    nil
  end

  def normalized_match(name)
    normalized = self.class.normalize(name)
    return nil if normalized.empty?

    { normalized_name: @by_normalized_name, normalized_long_name: @by_normalized_long }.each do |match_type, index|
      candidates = index[normalized]
      next if candidates.blank?

      return Result.new(club_id: candidates.first.id, match_type: match_type) if candidates.one?

      return Result.new(club_id: nil, match_type: :ambiguous)
    end
    nil
  end
end
