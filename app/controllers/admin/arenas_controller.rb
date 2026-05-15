module Admin
  class ArenasController < ApplicationController
    before_action :authenticate_user
    before_action :authorize!

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

    private

    def authorize!
      ph = current_user.permission_hash
      return if ph[:admin].present? || ph[:sbk].present?

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
