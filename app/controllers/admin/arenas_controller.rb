module Admin
  class ArenasController < ApplicationController
    before_action :authenticate_user
    before_action :authorize!
    # Spielorte sind verbandsübergreifend geteilte Stammdaten – Anlegen/Bearbeiten
    # bleibt jedem SBK möglich. Löschen und Zusammenführen sind dagegen destruktiv
    # und verbandsübergreifend (merge hängt Spieltage anderer Verbände um), daher
    # nur für globale Admins und die global gescopte FD-SBK (ph[:sbk] enthält 0);
    # regionale SBK bleiben ausgeschlossen (#62).
    before_action :authorize_arena_lifecycle!, only: %i[destroy merge]

    def index
      render json: Arena.order(:city, :name).map(&:full_hash)
    end

    def create
      unless ActiveModel::Type::Boolean.new.cast(params[:force])
        duplicates = find_duplicates
        if duplicates.any?
          return render json: { warning: 'Möglicherweise existiert bereits ein Spielort an dieser Adresse.',
                                duplicates: duplicates.map(&:full_hash) }, status: :conflict
        end
      end

      arena = Arena.new(arena_params)
      if arena.save
        render json: arena.full_hash, status: :created
      else
        render json: { errors: arena.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def update
      arena = Arena.find_by(id: params[:id])
      return render json: { error: 'Nicht gefunden' }, status: :not_found unless arena

      if arena.update(arena_params)
        render json: arena.full_hash
      else
        render json: { errors: arena.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def destroy
      arena = Arena.find_by(id: params[:id])
      return render json: { error: 'Nicht gefunden' }, status: :not_found unless arena

      if arena.game_days.exists?
        return render json: { error: 'Spielort wird in Spieltagen verwendet und kann nicht gelöscht werden.' },
                      status: :unprocessable_entity
      end

      arena.destroy
      head :no_content
    end

    # POST /api/v2/admin/arenas/:id/merge  (id = verbleibender Ziel-Spielort)
    def merge
      master = Arena.find_by(id: params[:id])
      return render json: { error: 'Ziel-Spielort nicht gefunden' }, status: :not_found unless master

      secondary = Arena.find_by(id: params[:secondary_id])
      return render json: { error: 'Quell-Spielort nicht gefunden' }, status: :not_found unless secondary

      moved = secondary.merge_into!(master)
      render json: { message: 'Spielorte zusammengeführt.', master: master.full_hash, moved_game_days: moved }
    rescue ArgumentError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    private

    def authorize!
      ph = current_user.permission_hash
      return if ph[:admin].present? || ph[:sbk].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    def authorize_arena_lifecycle!
      ph = current_user.permission_hash
      return if ph[:admin].present? || (ph[:sbk].present? && ph[:sbk].include?(0))

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    def arena_params
      params.permit(:name, :city, :street, :housenumber, :postcode)
    end

    def find_duplicates
      city = params[:city]&.strip
      street = params[:street]&.strip
      housenumber = params[:housenumber]&.strip
      name = params[:name]&.strip
      return [] if city.blank?

      scope = Arena.where('LOWER(city) = ?', city.downcase)
      by_address = street.present? && housenumber.present? ?
        scope.where('LOWER(street) = ? AND LOWER(housenumber) = ?', street.downcase, housenumber.downcase) :
        Arena.none
      by_name = name.present? ? scope.where('LOWER(name) = ?', name.downcase) : Arena.none

      (by_address.to_a + by_name.to_a).uniq(&:id)
    end
  end
end
